#!/usr/bin/env python3
"""Authoring-time PokeAPI catalog importer.

Regenerates the committed runtime catalog (assets/data/catalog/{species,moves,items}.json)
from a pinned PokeAPI/api-data checkout plus the vendored PokeWilds source snapshot under
assets/source/. Never a runtime dependency: the game loads only the committed JSON.

Data flow (see docs/generated/pokeapi-import.md for the latest run report):

  - tools/api_data_pin.json pins the upstream master SHA (--refresh re-resolves it).
  - --refresh downloads the codeload tarball into the gitignored tools/.cache/api-data/.
  - --fetch-pinned downloads and re-extracts the COMMITTED pin's tarball only
    (the CI cache validation/repair path): no upstream re-resolve, no pin move,
    no regeneration.
  - Default run regenerates the catalog + reports from the cache (no network).
  - --check regenerates in memory and byte-compares against the committed JSON
    (exit 0 when fresh, 1 with a diff summary when stale/missing).
  - --diff-against-asm additionally prints the parity summary and itemizes the
    expected-diff table in the parity report (the report itself,
    docs/generated/catalog-parity.md, is rewritten on every generating run with
    the always-on invariant kernel; an UNEXPECTED class hard-fails the run).

Value-source contract (stability-first; every deviation from today's runtime values is
itemized in the parity report):

  - api-data: base stats, types, catch rate, base exp, growth rate, gender ratio,
    egg groups, dex number, learnsets/egg moves (version-group preference chain),
    held items, abilities, move/item enrichment, display-name fallback.
  - Carried forward byte-identical from assets/source (PokeAPI has no equivalent or the
    current value is deliberately authored): display names already in
    pokemondisplayname.properties, spawn_biomes, field_moves, overworld_behavior,
    dex_entry, weight/height (api-data only where the ASM lacks them), tmhm, sprite
    paths, the ASM evolution lists (PokeWilds re-authored trade evolutions as stone
    evolutions; api-data only AUGMENTS with targets the ASM list never had), and the
    full moves.asm stat rows for the original 299 moves (GSC effect constants have no
    PokeAPI equivalent at all).

Only folders today's runtime loader actually parses get entries (parity: keys and the
encounter-viability rule are unchanged); art-tree folders with no parseable ASM today and
api-data pokemon with no art folder are reported, never imported.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOT = ROOT / "assets/source"
SPECIES_ROOT = SOURCE_ROOT / "pokemon/pokemon"
MOVES_ASM = SOURCE_ROOT / "pokemon/moves.asm"
MOVE_CATEGORY_FILE = SOURCE_ROOT / "pokemon/spec_phys_lookup.txt"
MOVE_NAMES_FILE = SOURCE_ROOT / "i18n/attack.properties"
SPECIES_NAMES_FILE = SOURCE_ROOT / "i18n/pokemondisplayname.properties"
ITEM_NAMES_FILE = SOURCE_ROOT / "i18n/item.properties"
ITEM_DESCRIPTIONS_FILE = SOURCE_ROOT / "i18n/itemdescription.properties"
ATTACKS_DIR = SOURCE_ROOT / "attacks"

PIN_FILE = ROOT / "tools/api_data_pin.json"
OVERRIDES_FILE = ROOT / "tools/import_overrides.json"
CACHE_DIR = ROOT / "tools/.cache"
CACHE_API_DATA = CACHE_DIR / "api-data"
CACHE_COMPLETE_MARKER = ".complete"

CATALOG_DIR = ROOT / "assets/data/catalog"
IMPORT_REPORT = ROOT / "docs/generated/pokeapi-import.md"
PARITY_REPORT = ROOT / "docs/generated/catalog-parity.md"

API_REPO = "PokeAPI/api-data"
GITHUB_API_COMMITS = "https://api.github.com/repos/%s/commits/master" % API_REPO
GITHUB_TARBALL = "https://codeload.github.com/%s/tar.gz/%%s" % API_REPO

# Version-group preference for learnsets, egg moves, evolution detail selection, and
# item prices: most recent generation first. legends-arceus sits right after
# scarlet-violet so Hisuian species/forms with no S/V data still get their origin-game
# learnsets (S/V covers every Hisuian species; LA is the fallback that keeps the
# preference chain meaningful for them).
VERSION_GROUP_CHAIN = [
    "scarlet-violet",
    "legends-arceus",
    "sword-shield",
    "ultra-sun-ultra-moon",
    "sun-moon",
    "omega-ruby-alpha-sapphire",
    "x-y",
    "black-2-white-2",
    "black-white",
    "heartgold-soulsilver",
    "platinum",
    "diamond-pearl",
    "emerald",
    "firered-leafgreen",
    "ruby-sapphire",
    "crystal",
    "gold-silver",
    "yellow",
    "red-blue",
]

# --- Token vocabularies (must match the tokens the ASM parsers emit today) -----------

# ASM egg-group line tokens after the parser's EGG_ prefix strip. api-data no-eggs maps
# to NONE (the token the ASM files use); ground/plant/humanshape/indeterminate map onto
# the pokecrystal spellings FIELD/GRASS/HUMANLIKE/AMORPHOUS.
EGG_GROUP_MAP = {
    "monster": "MONSTER",
    "water1": "WATER1",
    "water2": "WATER2",
    "water3": "WATER3",
    "bug": "BUG",
    "flying": "FLYING",
    "ground": "FIELD",
    "fairy": "FAIRY",
    "plant": "GRASS",
    "humanshape": "HUMANLIKE",
    "mineral": "MINERAL",
    "indeterminate": "AMORPHOUS",
    "ditto": "DITTO",
    "dragon": "DRAGON",
    "no-eggs": "NONE",
}

# ASM growth tokens after the parser's GROWTH_ prefix strip.
GROWTH_RATE_MAP = {
    "slow": "SLOW",
    "medium": "MEDIUM_FAST",
    "medium-slow": "MEDIUM_SLOW",
    "fast": "FAST",
    "slow-then-very-fast": "ERRATIC",
    "fast-then-very-slow": "FLUCTUATING",
}

# ASM gender tokens; api-data gender_rate is eighths-female (-1 = genderless).
GENDER_RATE_MAP = {
    -1: "GENDER_UNKNOWN",
    0: "GENDER_F0",
    1: "GENDER_F12_5",
    2: "GENDER_F25",
    4: "GENDER_F50",
    6: "GENDER_F75",
    8: "GENDER_F100",
}

# api-data time_of_day -> ASM happiness param (TR_ prefix already stripped by the parser).
HAPPINESS_TIME_MAP = {"": "ANYTIME", "day": "MORNDAY", "night": "NITE"}

# Fixed order of the field-move / overworld-property db lines in wilds_data.asm.
FIELD_MOVE_ORDER = [
    "dig", "power", "cut", "smash", "surf", "flash", "build", "charm",
    "repel", "attack", "teleport", "headbutt", "ride", "fly", "paint",
]
OVERWORLD_BEHAVIOR_ORDER = ["swim_only", "flee", "lunge", "aggression"]

TYPE_VOCAB = {
    "NORMAL", "FIRE", "WATER", "GRASS", "ELECTRIC", "ICE", "FIGHTING", "POISON",
    "GROUND", "FLYING", "PSYCHIC", "BUG", "ROCK", "GHOST", "DRAGON", "DARK",
    "STEEL", "FAIRY",
}

STAT_NAME_MAP = {
    "hp": "hp",
    "attack": "atk",
    "defense": "def",
    "speed": "spe",
    "special-attack": "sat",
    "special-defense": "sdf",
}


# --- Small shared helpers ------------------------------------------------------------


def read_text(path: Path) -> str:
    """FileAccess.get_as_text() equivalent: UTF-8 (BOM skipped), U+FFFD on bad bytes."""
    try:
        return path.read_bytes().decode("utf-8-sig", errors="replace")
    except FileNotFoundError:
        return ""


def read_latin1_text(path: Path) -> str:
    """Port of SpeciesFileParser.read_latin1_text: UTF-8 when BOM-marked, else Latin-1."""
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return ""
    if data[:3] == b"\xef\xbb\xbf":
        return data.decode("utf-8", errors="replace")
    return data.decode("latin-1")


def sanitize_species_id(raw: str) -> str:
    """Port of SpeciesFileParser.sanitize_species_id (uppercase alnum, runs -> _)."""
    out = ""
    pending_separator = False
    for character in raw.upper():
        is_alnum = ("A" <= character <= "Z") or ("0" <= character <= "9")
        if is_alnum:
            if pending_separator and out:
                out += "_"
            out += character
            pending_separator = False
        else:
            pending_separator = True
    return out


def godot_capitalize(text: str) -> str:
    """Godot String.capitalize(): lowercase everywhere, first char after a space upper."""
    out = []
    prev_space = True
    for character in text:
        if character == " ":
            prev_space = True
            out.append(character)
        elif prev_space:
            out.append(character.upper())
            prev_space = False
        else:
            out.append(character.lower())
    return "".join(out)


def humanize_slug(slug: str) -> str:
    """Port of pokemon_catalog._humanize_slug / MoveFileParser._humanize."""
    spaced = slug.replace("_", " ")
    if not spaced:
        return slug
    return godot_capitalize(spaced)


def parse_properties_file(path: Path) -> dict:
    """Port of pokemon_catalog._parse_properties_file (keys lowercased)."""
    entries = {}
    for raw_line in read_text(path).split("\n"):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        sep = line.find("=")
        if sep <= 0:
            continue
        key = line[:sep].strip().lower()
        value = line[sep + 1:].strip()
        entries[key] = value
    return entries


def norm_key(name: str) -> str:
    """Separator-insensitive comparison key (SOLARBEAM == solar-beam)."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def upper_token(name: str) -> str:
    """api-data kebab-case name -> runtime UPPERCASE_SNAKE token."""
    return name.replace("-", "_").upper()


# --- Ports of the ASM parsers (scripts/data/species_file_parser.gd @ HEAD) ------------

_STATS_RE = re.compile(r"^db\s+(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s|;|,|$)")
_PAIR_RE = re.compile(r"^db\s+([A-Z_]+)\s*,\s*([A-Z_]+)")
_INT_RE = re.compile(r"^db\s+(\d+)")
_TOKEN_RE = re.compile(r"^db\s+([A-Z0-9_]+)")
_NUMBER_RE = re.compile(r"^db\s+(-?\d+(?:\.\d+)?)")
_LEARNSET_RE = re.compile(r"^\s*db\s+([0-9]+)\s*,\s*([A-Z0-9_]+)")
_MOVE_ROW_RE = re.compile(r"^\s*move\s+([A-Z0-9_]+)\s*,\s*([A-Z0-9_]+)\s*,\s*([0-9]+)\s*,\s*([A-Z_]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)")


def _csv_tail(line: str, skip: int) -> str:
    body = line[skip:].strip()
    semi = body.find(";")
    if semi >= 0:
        body = body[:semi].strip()
    return body


def parse_base_stats(text: str) -> dict:
    """Port of SpeciesFileParser.parse_base_stats (same guards, same precedence)."""
    if not text:
        return {}

    species_id = ""
    dex_number = 0
    base_stats: dict = {}
    types: list = []
    catch_rate = 0
    base_exp = 0
    growth_rate = ""
    gender_ratio = ""
    egg_groups: list = []
    tmhm: list = []

    for raw_line in text.split("\n"):
        line = raw_line.strip()
        if not line:
            continue

        if not species_id and not base_stats and not types and line.startswith("db"):
            decl = line[2:].strip()
            if decl and "," not in decl:
                comment = ""
                semi = decl.find(";")
                if semi >= 0:
                    comment = decl[semi + 1:].strip()
                    decl = decl[:semi].strip()
                if decl and not decl.isdigit():
                    species_id = sanitize_species_id(decl)
                    if comment.isdigit():
                        dex_number = int(comment)
                    continue

        if not base_stats:
            stats_match = _STATS_RE.search(line)
            if stats_match:
                base_stats = {
                    "hp": int(stats_match.group(1)), "atk": int(stats_match.group(2)),
                    "def": int(stats_match.group(3)), "spe": int(stats_match.group(4)),
                    "sat": int(stats_match.group(5)), "sdf": int(stats_match.group(6)),
                }
                continue

        if not types:
            pair_match = _PAIR_RE.search(line)
            if pair_match and pair_match.group(1) in TYPE_VOCAB and pair_match.group(2) in TYPE_VOCAB:
                types = [pair_match.group(1), pair_match.group(2)]
                continue

        if catch_rate == 0 and "catch rate" in line:
            catch_match = _INT_RE.search(line)
            if catch_match:
                catch_rate = int(catch_match.group(1))
                continue

        if base_exp == 0 and "exp" in line:
            exp_match = _INT_RE.search(line)
            if exp_match:
                base_exp = int(exp_match.group(1))
                continue

        if not gender_ratio:
            gender_match = _TOKEN_RE.search(line)
            if gender_match and gender_match.group(1).startswith("GENDER_"):
                gender_ratio = gender_match.group(1)
                continue

        if not growth_rate and "growth" in line:
            growth_match = _TOKEN_RE.search(line)
            if growth_match:
                growth_rate = growth_match.group(1)
                if growth_rate.startswith("GROWTH_"):
                    growth_rate = growth_rate[len("GROWTH_"):]
                continue

        if not egg_groups and line.startswith("dn EGG_"):
            for group in _csv_tail(line, 3).split(","):
                group_name = group.strip()
                if group_name.startswith("EGG_"):
                    group_name = group_name[len("EGG_"):]
                if group_name:
                    egg_groups.append(group_name)
            continue

        if not tmhm and line.startswith("tmhm "):
            for move_name in _csv_tail(line, 5).split(","):
                move_id = move_name.strip()
                if move_id:
                    tmhm.append(move_id)

    if not species_id or not base_stats or not types:
        return {}

    return {
        "species_id": species_id, "dex_number": dex_number, "base_stats": base_stats,
        "types": types, "catch_rate": catch_rate, "base_exp": base_exp,
        "growth_rate": growth_rate, "gender_ratio": gender_ratio,
        "egg_groups": egg_groups, "tmhm": tmhm,
    }


def _evolution_param(raw: str):
    if raw.isdigit():
        return int(raw)
    if raw.startswith("TR_"):
        return raw[3:]
    return raw


def parse_evolutions(text: str) -> list:
    """Port of SpeciesFileParser.parse_evolutions."""
    evolutions = []
    if not text:
        return evolutions
    for raw_line in text.split("\n"):
        line = raw_line.strip()
        if "no more evolutions" in line or "no more level-up moves" in line:
            break
        if not line.startswith("db EVOLVE_"):
            continue
        body = line[3:].strip()
        semi = body.find(";")
        if semi >= 0:
            body = body[:semi].strip()
        parts = body.split(",")
        if len(parts) < 2:
            continue
        method = parts[0].strip()
        if method.startswith("EVOLVE_"):
            method = method[len("EVOLVE_"):]
        target = sanitize_species_id(parts[-1].strip())
        if not target:
            continue
        param = None
        if len(parts) >= 3:
            raw_param = parts[1].strip()
            if raw_param:
                param = _evolution_param(raw_param)
        evolutions.append({"method": method, "param": param, "target": target})
    return evolutions


def parse_egg_moves(text: str) -> list:
    """Port of SpeciesFileParser.parse_egg_moves."""
    moves = []
    for raw_line in text.split("\n"):
        line = raw_line.strip()
        if line.startswith("db "):
            move_id = _csv_tail(line, 3).split(" ")[0].strip()
            if move_id:
                moves.append(move_id)
    return moves


def _leading_number(line: str) -> float:
    match = _NUMBER_RE.search(line)
    if not match:
        return 0.0
    return float(match.group(1))


def _bracket_text(lines: list, start: int) -> str:
    text = lines[start]
    guard = 0
    while (text.find("<") >= 0
           and (text.find(">") < 0 or text.find(">") < text.find("<"))
           and start + guard + 1 < len(lines) and guard < 8):
        guard += 1
        text += " " + lines[start + guard]
    open_at = text.find("<")
    close_at = text.find(">", open_at)
    if open_at < 0 or close_at < 0:
        return ""
    return text[open_at + 1:close_at].strip()


def _db_word_list(line: str) -> list:
    words = []
    if not line.startswith("db"):
        return words
    for word in _csv_tail(line, 2).split(" "):
        token = word.strip()
        if token:
            words.append(token)
    return words


def _ordered_db_ints(lines: list, start: int, order: list) -> dict:
    values = {}
    slot = 0
    cursor = start
    while cursor < len(lines) and slot < len(order):
        line = lines[cursor].strip()
        if line.startswith("db"):
            match = _NUMBER_RE.search(line)
            if match:
                values[order[slot]] = int(float(match.group(1)))
                slot += 1
        cursor += 1
    return values


def parse_wilds_data(text: str) -> dict:
    """Port of SpeciesFileParser.parse_wilds_data."""
    result = {
        "dex_number": 0, "dex_entry": "", "weight_kg": 0.0, "height_m": 0.0,
        "spawn_biomes": [], "field_moves": {}, "overworld_behavior": {},
    }
    if not text:
        return result
    lines = text.split("\n")
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        if "; Dex number" in line:
            result["dex_number"] = int(_leading_number(line))
        elif "; Dex entry" in line:
            result["dex_entry"] = _bracket_text(lines, index)
        elif "; Weight in kg" in line:
            result["weight_kg"] = _leading_number(line)
        elif "; Height in meters" in line:
            result["height_m"] = _leading_number(line)
        elif "; Spawning biomes" in line:
            result["spawn_biomes"] = _db_word_list(line)
        elif "Field moves" in line:
            result["field_moves"] = _ordered_db_ints(lines, index + 1, FIELD_MOVE_ORDER)
        elif "Overworld properties" in line:
            result["overworld_behavior"] = _ordered_db_ints(lines, index + 1, OVERWORLD_BEHAVIOR_ORDER)
        index += 1
    return result


def parse_learnset_file(text: str) -> list:
    """Port of pokemon_catalog._parse_learnset_file."""
    learnset = []
    for raw_line in text.split("\n"):
        if "no more level-up moves" in raw_line.strip():
            break
        move_match = _LEARNSET_RE.search(raw_line)
        if not move_match:
            continue
        level = int(move_match.group(1))
        if level <= 0:
            continue
        learnset.append({"level": level, "move_id": move_match.group(2)})
    return learnset


def parse_move_categories(text: str) -> dict:
    """Port of MoveFileParser.parse_move_categories."""
    entries = {}
    for raw_line in text.split("\n"):
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split(",", 2)
        if len(parts) < 2:
            continue
        entries[parts[0].strip().upper()] = parts[1].strip().upper()
    return entries


def parse_moves(text: str, move_names: dict, move_categories: dict) -> dict:
    """Port of MoveFileParser.parse_moves."""
    entries = {}
    for raw_line in text.split("\n"):
        match = _MOVE_ROW_RE.search(raw_line)
        if not match:
            continue
        move_id = match.group(1)
        power = int(match.group(3))
        move_key = move_id.lower()
        display_name = move_names.get(move_key, humanize_slug(move_key))
        category = move_categories.get(move_id, "PHYSICAL")
        if power <= 0:
            category = "STATUS"
        entries[move_id] = {
            "move_id": move_id,
            "display_name": display_name,
            "effect": match.group(2),
            "power": power,
            "type": match.group(4),
            "accuracy": int(match.group(5)),
            "pp": int(match.group(6)),
            "effect_chance": int(match.group(7)),
            "category": category,
        }
    return entries


# --- Current-catalog port (pokemon_catalog.gd @ HEAD) --------------------------------

SPECIES_RES_ROOT = "res://assets/source/pokemon/pokemon"


def list_species_folders() -> list:
    """Port of _parse_species_directory's folder enumeration + sort."""
    names = [
        entry for entry in os.listdir(SPECIES_ROOT)
        if not entry.startswith(".") and (SPECIES_ROOT / entry).is_dir()
    ]
    names.sort()
    return names


def build_current_catalog(move_names: dict, species_names: dict) -> tuple:
    """Ports pokemon_catalog._load_species_folder for every folder.

    Returns (entries, skipped, base_by_folder) where entries maps species_id -> the
    exact dictionary today's runtime builds, skipped lists folders the loader drops
    today, and base_by_folder retains each folder's parsed base_stats.asm decl so
    placeholder detection (compute_placeholder_ids) never re-reads the tree.
    """
    entries = {}
    skipped = []
    base_by_folder = {}
    for folder_name in list_species_folders():
        base_path = SPECIES_ROOT / folder_name

        base_data = {}
        base_stats_path = base_path / "base_stats.asm"
        if base_stats_path.exists():
            base_data = parse_base_stats(read_text(base_stats_path))
        base_by_folder[folder_name] = base_data

        wilds_data = {}
        wilds_data_path = base_path / "wilds_data.asm"
        if wilds_data_path.exists():
            wilds_data = parse_wilds_data(read_latin1_text(wilds_data_path))

        if not base_data and not wilds_data:
            skipped.append(folder_name)
            continue

        slug = folder_name.lower()
        species_id = folder_name.upper()

        evos_path = base_path / "evos_attacks.asm"
        learnset = parse_learnset_file(read_text(evos_path)) if evos_path.exists() else []
        evolutions = parse_evolutions(read_text(evos_path)) if evos_path.exists() else []
        egg_moves_path = base_path / "egg_moves.asm"
        egg_moves = parse_egg_moves(read_text(egg_moves_path)) if egg_moves_path.exists() else []

        dex_number = int(wilds_data.get("dex_number", 0))
        if dex_number <= 0:
            dex_number = int(base_data.get("dex_number", 0))

        # Host-portable existence probe: Path.exists() follows the HOST
        # filesystem's case semantics, so back.png matched back.PNG on macOS
        # but not on Linux and the committed catalog flip-flopped per host
        # (9 sprite paths, incl. front_path flips that change encounter
        # viability). Match the directory listing case-insensitively instead
        # and emit the canonical requested spelling, so the catalog — and the
        # S4.5 freshness gate — are byte-stable across macOS and Linux.
        present_names = {entry.name.lower() for entry in os.scandir(base_path)}

        def _sprite(name: str) -> str:
            return "%s/%s/%s" % (SPECIES_RES_ROOT, slug, name) if name.lower() in present_names else ""

        entries[species_id] = {
            "species_id": species_id,
            "slug": slug,
            "display_name": str(species_names.get(slug, humanize_slug(slug))),
            "dex_number": dex_number,
            "types": base_data.get("types", ["NORMAL", "NORMAL"]),
            "base_stats": base_data.get("base_stats", {}),
            "learnset": learnset,
            "evolutions": evolutions,
            "catch_rate": int(base_data.get("catch_rate", 0)),
            "base_exp": int(base_data.get("base_exp", 0)),
            "growth_rate": str(base_data.get("growth_rate", "")),
            "gender_ratio": str(base_data.get("gender_ratio", "")),
            "egg_groups": base_data.get("egg_groups", []),
            "egg_moves": egg_moves,
            "tmhm": base_data.get("tmhm", []),
            "spawn_biomes": wilds_data.get("spawn_biomes", []),
            "field_moves": wilds_data.get("field_moves", {}),
            "overworld_behavior": wilds_data.get("overworld_behavior", {}),
            "dex_entry": str(wilds_data.get("dex_entry", "")),
            "weight_kg": float(wilds_data.get("weight_kg", 0.0)),
            "height_m": float(wilds_data.get("height_m", 0.0)),
            "front_path": _sprite("front.png"),
            "back_path": _sprite("back.png"),
            "overworld_path": _sprite("overworld.png"),
            "shiny_overworld_path": _sprite("overworld-shiny.png"),
        }
    return entries, skipped, base_by_folder


def is_encounter_viable(species_id: str, entry: dict) -> bool:
    """Port of the encounter_species battle-viable rule."""
    return (
        bool(entry.get("front_path")) and bool(entry.get("back_path"))
        and int(entry.get("catch_rate", 0)) > 0
        and bool(entry.get("base_stats"))
        and bool(entry.get("learnset"))
        and species_id != "EGG"
    )


# --- api-data cache access ------------------------------------------------------------


class ApiData:
    """Read-only access to the extracted PokeAPI/api-data checkout."""

    def __init__(self, root: Path):
        self.root = root
        if not (root / CACHE_COMPLETE_MARKER).is_file() \
                or not (root / "data/api/v2/pokemon/index.json").is_file():
            raise CacheMissing(
                "api-data cache missing or incomplete at %s\n"
                "Run: python3 tools/import_pokeapi.py --refresh" % root
            )
        self._indexes: dict = {}
        self._norm_indexes: dict = {}
        self._docs: dict = {}

    def index(self, category: str) -> dict:
        """category -> {name: numeric id}."""
        if category not in self._indexes:
            data = self.load("%s/index.json" % category)
            self._indexes[category] = {
                row["name"]: row["url"].rstrip("/").split("/")[-1]
                for row in data.get("results", [])
            }
        return self._indexes[category]

    def find_by_norm(self, category: str, name: str):
        """First resource name in category equal to name under norm_key, else None.

        The norm_key index is built once per category and cached — the single
        normalized-name lookup every mapper shares."""
        if category not in self._norm_indexes:
            by_norm = {}
            for resource_name in self.index(category):
                by_norm.setdefault(norm_key(resource_name), resource_name)
            self._norm_indexes[category] = by_norm
        return self._norm_indexes[category].get(norm_key(name))

    def load(self, rel: str):
        if rel not in self._docs:
            with open(self.root / "data/api/v2" / rel, encoding="utf-8") as handle:
                self._docs[rel] = json.load(handle)
        return self._docs[rel]

    def by_name(self, category: str, name: str):
        entry_id = self.index(category).get(name)
        if entry_id is None:
            return None
        return self.load("%s/%s/index.json" % (category, entry_id))


class CacheMissing(Exception):
    pass


class ParityViolation(Exception):
    """An always-on catalog invariant failed (duplicate-spelling move ids, an
    UNEXPECTED parity class, a carried-field drift). Hard-fails the run."""


# --- Overrides ------------------------------------------------------------------------


def load_overrides() -> dict:
    if not OVERRIDES_FILE.exists():
        return {}
    with open(OVERRIDES_FILE, encoding="utf-8") as handle:
        return json.load(handle)


# --- Importer -------------------------------------------------------------------------


class Importer:
    def __init__(self, api: ApiData, overrides: dict):
        self.api = api
        self.overrides = overrides
        self.move_names = parse_properties_file(MOVE_NAMES_FILE)
        self.species_names = parse_properties_file(SPECIES_NAMES_FILE)
        self.item_names = parse_properties_file(ITEM_NAMES_FILE)
        self.item_descriptions = parse_properties_file(ITEM_DESCRIPTIONS_FILE)
        self.move_categories = parse_move_categories(read_text(MOVE_CATEGORY_FILE))
        self.asm_moves = parse_moves(read_text(MOVES_ASM), self.move_names, self.move_categories)
        self.anim_dirs = {
            name for name in os.listdir(ATTACKS_DIR)
            if (ATTACKS_DIR / name).is_dir()
        } if ATTACKS_DIR.is_dir() else set()

        self.current_entries, self.skipped_folders, self.base_by_folder = \
            build_current_catalog(self.move_names, self.species_names)

        # Report accumulators.
        self.unmapped_species: list = []
        self.unmapped_moves: list = []
        self.version_group_choices: dict = {}
        self.learnset_carry_forward: list = []
        self.egg_move_sources: dict = {}
        self.evolution_augmented: list = []
        self.evolution_unmappable: list = []
        self.synthetic_species: list = []
        self.api_only_moves: list = []
        self.missing_anim_moves: list = []
        self.item_api_hits: list = []
        self.display_fallbacks: dict = {}

        # slug (folder) -> api pokemon name; populated by map_species().
        self.species_map: dict = {}
        self.move_map: dict = {}  # ASM move id -> api move name
        self.move_by_api_name: dict = {}  # api move name -> ASM move id; built once by map_moves()
        self.item_map: dict = {}  # item key (lowercase) -> api item name

    # -- mapping --

    def map_species(self) -> None:
        pokemon_index = self.api.index("pokemon")
        form_index = self.api.index("pokemon-form")
        pokemon_by_norm = {}
        for name in pokemon_index:
            pokemon_by_norm.setdefault(norm_key(name), name)
        overrides = self.overrides.get("species_map", {})
        synthetic = self.overrides.get("synthetic_species", {})

        for folder in self.current_folders():
            slug = folder
            if slug in synthetic:
                self.species_map[slug] = None
                continue
            if slug in overrides:
                target = overrides[slug]
                if target in pokemon_index:
                    self.species_map[slug] = target
                    continue
                if target in form_index:
                    self.species_map[slug] = self._form_pokemon_name(target)
                    continue
                self.unmapped_species.append((slug, "override target %r not found" % target))
                continue
            candidate = slug.replace("_", "-")
            if candidate in pokemon_index:
                self.species_map[slug] = candidate
                continue
            normed = pokemon_by_norm.get(norm_key(candidate))
            if normed:
                self.species_map[slug] = normed
                continue
            if candidate in form_index:
                self.species_map[slug] = self._form_pokemon_name(candidate)
                continue
            self.unmapped_species.append((slug, "no pokemon/pokemon-form match"))

    def _form_pokemon_name(self, form_name: str) -> str:
        form = self.api.by_name("pokemon-form", form_name)
        return form["pokemon"]["name"]

    def map_moves(self) -> None:
        api_moves = self.api.index("move")
        overrides = self.overrides.get("move_map", {})
        for move_id in self.asm_moves:
            if move_id in overrides:
                target = overrides[move_id]
                if target not in api_moves:
                    self.unmapped_moves.append((move_id, "override target %r not found" % target))
                else:
                    self.move_map[move_id] = target
                continue
            candidate = move_id.lower().replace("_", "-")
            if candidate in api_moves:
                self.move_map[move_id] = candidate
                continue
            normed = self.api.find_by_norm("move", candidate)
            if normed:
                self.move_map[move_id] = normed
                continue
            self.unmapped_moves.append((move_id, "no api-data move match"))
        # The ONE reverse index (api name -> ASM id), built over the FINAL map:
        # canonical_move_id resolves every api learnset/egg-move row against it, so
        # an api name can never fall through to a duplicate upper_token spelling
        # beside its carried ASM id.
        self.move_by_api_name = {}
        for move_id, api_name in self.move_map.items():
            self.move_by_api_name.setdefault(api_name, move_id)

    def item_keys(self) -> list:
        """Sorted union of the i18n item keys + override supplements (map + build input)."""
        supplements = self.overrides.get("item_supplements", {})
        keys = set(self.item_names.keys()) | set(self.item_descriptions.keys())
        keys |= set(supplements.keys())
        return sorted(keys)

    def map_items(self) -> None:
        api_items = self.api.index("item")
        overrides = self.overrides.get("item_map", {})
        for key in self.item_keys():
            if key in overrides:
                self.item_map[key] = overrides[key]
                continue
            candidate = key.replace("_", "-")
            if candidate in api_items:
                self.item_map[key] = candidate
                continue
            normed = self.api.find_by_norm("item", candidate)
            if normed:
                self.item_map[key] = normed
            # Unmapped PokeWilds-custom ids are expected; they stay unenriched.

    def canonical_move_id(self, api_name: str) -> str:
        """api-data move name -> catalog move id (ASM id when the move exists there)."""
        return self.move_by_api_name.get(api_name, upper_token(api_name))

    def current_folders(self) -> list:
        """Emitted folders = the ones today's loader parses, in loader order."""
        skipped = set(self.skipped_folders)
        return [f for f in list_species_folders() if f not in skipped]

    # -- species emission --

    def build_species(self) -> dict:
        self._compute_form_counts()
        entries = {}
        synthetic = self.overrides.get("synthetic_species", {})
        for folder in self.current_folders():
            species_id = folder.upper()
            current = self.current_entries[species_id]
            if folder in synthetic:
                entry = dict(current)
                entry["held_items"] = []
                entry["abilities"] = []
                entries[species_id] = entry
                self.synthetic_species.append((folder, synthetic[folder]))
                continue
            entries[species_id] = self._build_api_species(folder, current)
        return entries

    def _compute_form_counts(self) -> None:
        """Emitted-folder counts per api pokemon/species resource (cosmetic-form detection)."""
        self.pokemon_folder_count: dict = {}
        self.species_folder_count: dict = {}
        for folder, name in self.species_map.items():
            if name is None:
                continue
            self.pokemon_folder_count[name] = self.pokemon_folder_count.get(name, 0) + 1
            species_name = self.api.by_name("pokemon", name)["species"]["name"]
            self.species_folder_count[species_name] = self.species_folder_count.get(species_name, 0) + 1

    def _build_api_species(self, folder: str, current: dict) -> dict:
        pokemon_name = self.species_map[folder]
        pokemon = self.api.by_name("pokemon", pokemon_name)
        species = self.api.by_name("pokemon-species", pokemon["species"]["name"])

        stats = {}
        for row in pokemon["stats"]:
            key = STAT_NAME_MAP.get(row["stat"]["name"])
            if key:
                stats[key] = int(row["base_stat"])
        for key in ("hp", "atk", "def", "spe", "sat", "sdf"):
            stats.setdefault(key, 0)

        types = [row["type"]["name"].upper() for row in sorted(pokemon["types"], key=lambda r: r["slot"])]
        if len(types) == 1:
            types = [types[0], types[0]]
        if not types:
            types = ["NORMAL", "NORMAL"]

        growth = GROWTH_RATE_MAP.get(species["growth_rate"]["name"], "")
        gender = GENDER_RATE_MAP.get(int(species["gender_rate"]), "GENDER_UNKNOWN")
        egg_groups = [EGG_GROUP_MAP.get(g["name"], g["name"].upper()) for g in species["egg_groups"]]
        # pokecrystal convention (dn EGG_X, EGG_X): the ASM doubles a single group;
        # matching it keeps egg_groups byte-identical for every species whose group
        # SET is unchanged (breeding only ever checks membership).
        if len(egg_groups) == 1:
            egg_groups = [egg_groups[0], egg_groups[0]]

        display_name = self.species_names.get(folder)
        if display_name is None:
            display_name = self._api_display_name(pokemon, species)
            self.display_fallbacks[folder] = display_name

        learnset, learnset_group = self._extract_learnset(pokemon)
        if learnset:
            self.version_group_choices[folder] = learnset_group
        else:
            learnset = current["learnset"]
            self.learnset_carry_forward.append(folder)

        egg_moves, egg_source = self._extract_egg_moves(pokemon)
        if egg_moves is None:
            egg_moves = list(current["egg_moves"])
        self.egg_move_sources[folder] = egg_source

        evolutions = self._build_evolutions(pokemon, species, current)

        # Carried-forward fields (PokeAPI has no equivalent / authored data).
        weight = float(current["weight_kg"])
        height = float(current["height_m"])
        if weight <= 0.0:
            weight = round(int(pokemon.get("weight") or 0) / 10.0, 4)
        if height <= 0.0:
            height = round(int(pokemon.get("height") or 0) / 10.0, 4)

        held_items = sorted({upper_token(h["item"]["name"]) for h in pokemon.get("held_items", [])})
        abilities = []
        for row in sorted(pokemon.get("abilities", []), key=lambda r: r["slot"]):
            token = upper_token(row["ability"]["name"])
            if token not in abilities:
                abilities.append(token)

        base_exp = pokemon.get("base_experience")
        if base_exp is None:
            base_exp = int(current.get("base_exp", 0))

        return {
            "species_id": folder.upper(),
            "slug": folder,
            "display_name": display_name,
            "dex_number": int(species["id"]),
            "types": types,
            "base_stats": stats,
            "learnset": learnset,
            "evolutions": evolutions,
            "catch_rate": int(species["capture_rate"]),
            "base_exp": int(base_exp),
            "growth_rate": growth,
            "gender_ratio": gender,
            "egg_groups": egg_groups,
            "egg_moves": egg_moves,
            "tmhm": list(current["tmhm"]),
            "spawn_biomes": list(current["spawn_biomes"]),
            "field_moves": dict(current["field_moves"]),
            "overworld_behavior": dict(current["overworld_behavior"]),
            "dex_entry": str(current["dex_entry"]),
            "weight_kg": weight,
            "height_m": height,
            "front_path": current["front_path"],
            "back_path": current["back_path"],
            "overworld_path": current["overworld_path"],
            "shiny_overworld_path": current["shiny_overworld_path"],
            "held_items": held_items,
            "abilities": abilities,
        }

    def _api_display_name(self, pokemon: dict, species: dict) -> str:
        if not pokemon.get("is_default", True):
            for form_ref in pokemon.get("forms", []):
                form = self.api.by_name("pokemon-form", form_ref["name"])
                if form and form["pokemon"]["name"] == pokemon["name"]:
                    for name_row in form.get("names", []):
                        if name_row["language"]["name"] == "en":
                            return name_row["name"]
        for name_row in species.get("names", []):
            if name_row["language"]["name"] == "en":
                return name_row["name"]
        return humanize_slug(pokemon["name"].replace("-", "_"))

    def _extract_learnset(self, pokemon: dict):
        """Level-up moves from the most preferred version group; api level 0 -> 1."""
        per_group: dict = {}
        for move_row in pokemon.get("moves", []):
            for detail in move_row["version_group_details"]:
                if detail["move_learn_method"]["name"] != "level-up":
                    continue
                group = detail["version_group"]["name"]
                level = max(1, int(detail["level_learned_at"]))
                move_id = self.canonical_move_id(move_row["move"]["name"])
                per_group.setdefault(group, {})[move_id] = min(
                    level, per_group.setdefault(group, {}).get(move_id, level)
                )
        for group in VERSION_GROUP_CHAIN:
            if group in per_group and per_group[group]:
                pairs = sorted(
                    (level, move_id) for move_id, level in per_group[group].items()
                )
                return [{"level": level, "move_id": move_id} for level, move_id in pairs], group
        return [], None

    def _extract_egg_moves(self, pokemon: dict):
        per_group: dict = {}
        for move_row in pokemon.get("moves", []):
            for detail in move_row["version_group_details"]:
                if detail["move_learn_method"]["name"] != "egg":
                    continue
                group = detail["version_group"]["name"]
                per_group.setdefault(group, set()).add(self.canonical_move_id(move_row["move"]["name"]))
        for group in VERSION_GROUP_CHAIN:
            if group in per_group and per_group[group]:
                return sorted(per_group[group]), "api:%s" % group
        return None, "asm-carry-forward"

    def _default_pokemon_name(self, species_name: str) -> str:
        species = self.api.by_name("pokemon-species", species_name)
        for variety in species.get("varieties", []):
            if variety.get("is_default"):
                return variety["pokemon"]["name"]
        return species_name

    def _build_evolutions(self, pokemon: dict, species: dict, current: dict) -> list:
        """ASM list verbatim, augmented with api-data targets the ASM never lists.

        Rationale: PokeWilds re-authored the trade evolutions as stone evolutions
        (haunter -DUSK_STONE-> GENGAR etc.) and pokemon_rules.gd only acts on
        LEVEL*/HAPPINESS/ITEM. api-data-primary would silently revert those working
        paths to inert TRADE entries, so api-data only contributes evolutions whose
        target the ASM list lacks entirely (e.g. URSARING -> URSALUNA).
        """
        evolutions = [dict(evo) for evo in current["evolutions"]]
        asm_targets = {str(evo.get("target", "")) for evo in evolutions}

        pokemon_index = self.api.index("pokemon")
        chain_url = species["evolution_chain"]["url"]
        chain = self.api.load("evolution-chain/%s/index.json" % chain_url.rstrip("/").split("/")[-1])
        node = self._find_chain_node(chain["chain"], species["name"])
        if node is None:
            return evolutions

        reverse = {}
        for folder, api_name in self.species_map.items():
            if api_name is not None:
                reverse.setdefault(api_name, folder)

        # Node-level form preference: if ANY detail across this node's evolves_to
        # entries is qualified for our form (base_form == our pokemon name), only those
        # apply — the base_form-null details describe the default form's path
        # (yamask-galar never becomes cofagrigus). Otherwise the null ones apply.
        raw_pairs = []
        for evolves_to in node["evolves_to"]:
            for detail in evolves_to["evolution_details"]:
                raw_pairs.append((evolves_to, detail))
        matched = [p for p in raw_pairs if p[1].get("base_form") and p[1]["base_form"]["name"] == pokemon["name"]]
        if matched:
            work = [(et, d, True) for et, d in matched]
        else:
            work = [(et, d, False) for et, d in raw_pairs if d.get("base_form") is None]
        rank = {group: index for index, group in enumerate(VERSION_GROUP_CHAIN)}
        work.sort(key=lambda p: rank.get(p[1].get("version_group", {}).get("name", ""), len(VERSION_GROUP_CHAIN)))

        cosmetic_source = self.pokemon_folder_count.get(pokemon["name"], 1) > 1

        augments = []
        noted = set()
        for evolves_to, detail, form_matched in work:
            mapped = self._map_evolution_detail(detail)
            if mapped is None:
                note = (current["slug"], evolves_to["species"]["name"], detail["trigger"]["name"])
                if note not in noted:
                    noted.add(note)
                    self.evolution_unmappable.append(note)
                continue
            method, param = mapped
            # evolved_form is honored only on an explicit form-to-form path
            # (base_form matched our pokemon). Otherwise it encodes a region- or
            # gender-conditional output the runtime cannot express (pikachu ->
            # raichu-alola): fall back to the target species' default variety.
            if detail.get("evolved_form") and form_matched:
                target_pokemon = detail["evolved_form"]["name"]
            else:
                target_pokemon = self._default_pokemon_name(evolves_to["species"]["name"])
            if target_pokemon not in pokemon_index:
                note = (current["slug"], target_pokemon, "target not a pokemon resource")
                if note not in noted:
                    noted.add(note)
                    self.evolution_unmappable.append(note)
                continue
            target_folder = reverse.get(target_pokemon)
            if target_folder is None or target_folder.upper() not in self.current_entries:
                note = (current["slug"], target_pokemon, "target has no emitted catalog entry")
                if note not in noted:
                    noted.add(note)
                    self.evolution_unmappable.append(note)
                continue
            # Cosmetic-form folders share one api pokemon resource; when the target
            # species is itself split into per-form folders, api data cannot say which
            # target form a given source color produces (flabebe_red -> floette_red,
            # not the floette default). The ASM lists already carry the per-color
            # truth, so augmentation is skipped for those pairs only.
            if cosmetic_source and self.species_folder_count.get(evolves_to["species"]["name"], 1) > 1:
                note = (current["slug"], target_pokemon, "ambiguous cosmetic-form chain (ASM list kept)")
                if note not in noted:
                    noted.add(note)
                    self.evolution_unmappable.append(note)
                continue
            target_id = target_folder.upper()
            if target_id in asm_targets or any(a["target"] == target_id for a in augments):
                continue
            augments.append({"method": method, "param": param, "target": target_id})
            self.evolution_augmented.append((current["slug"], method, param, target_id))
        augments.sort(key=lambda a: (a["target"], a["method"], str(a["param"])))
        return evolutions + augments

    def _find_chain_node(self, node: dict, species_name: str):
        if node["species"]["name"] == species_name:
            return node
        for nxt in node["evolves_to"]:
            found = self._find_chain_node(nxt, species_name)
            if found is not None:
                return found
        return None

    def _map_evolution_detail(self, detail: dict):
        """api-data evolution detail -> (method, param) using the ASM token vocabulary."""
        trigger = detail["trigger"]["name"]
        if trigger == "use-item" and detail.get("item"):
            # time_of_day (e.g. ursaluna's full-moon) is unlockable flavor the runtime
            # cannot express; everything else (gender/region/...) makes it unmappable.
            if self._has_blocking_qualifiers(detail, allow_time=True):
                return None
            return "ITEM", self._evo_item_token(detail["item"]["name"])
        if trigger == "trade":
            if self._has_blocking_qualifiers(detail, allow=("held_item",), allow_time=True):
                return None
            if detail.get("held_item"):
                return "TRADEITEM", self._evo_item_token(detail["held_item"]["name"])
            return "TRADE", None
        if trigger == "level-up":
            if detail.get("min_happiness") is not None and detail.get("min_level") is None \
                    and not self._has_blocking_qualifiers(detail, allow_time=True):
                return "HAPPINESS", HAPPINESS_TIME_MAP.get(detail.get("time_of_day", ""), "ANYTIME")
            if detail.get("known_move") and self._only_qualifiers(detail, {"known_move", "min_level"}):
                move_id = self.canonical_move_id(detail["known_move"]["name"])
                return "MOVE", move_id
            if detail.get("held_item") and detail.get("min_level") is None \
                    and self._only_qualifiers(detail, {"held_item"}, allow_time=True):
                time_of_day = detail.get("time_of_day", "")
                if time_of_day == "day":
                    return "DAYHOLDITEM", self._evo_item_token(detail["held_item"]["name"])
                if time_of_day == "night":
                    return "NIGHTHOLDITEM", self._evo_item_token(detail["held_item"]["name"])
                return None
            if detail.get("min_level") is not None:
                if self._has_blocking_qualifiers(detail, allow=("min_level",), allow_time=True):
                    return None
                time_of_day = detail.get("time_of_day", "")
                level = int(detail["min_level"])
                if time_of_day == "day":
                    return "LEVELDAY", level
                if time_of_day == "night":
                    return "LEVELNIGHT", level
                return "LEVEL", level
            return None
        return None

    _QUALIFIER_FIELDS = (
        "gender", "held_item", "known_move", "known_move_type", "location",
        "min_affection", "min_beauty", "min_damage_taken", "min_level",
        "min_move_count", "min_steps", "party_species", "party_type", "region",
        "relative_physical_stats", "trade_species", "used_move",
    )
    _QUALIFIER_FLAGS = (
        "near_special_rock", "needs_multiplayer", "needs_overworld_rain",
        "turn_upside_down",
    )

    def _has_blocking_qualifiers(self, detail: dict, allow: tuple = (),
                                 allow_time: bool = False) -> bool:
        for field in self._QUALIFIER_FIELDS:
            if field in allow:
                continue
            if detail.get(field) not in (None, "", False):
                return True
        for field in self._QUALIFIER_FLAGS:
            if detail.get(field):
                return True
        if not allow_time and detail.get("time_of_day"):
            return True
        return False

    def _only_qualifiers(self, detail: dict, allowed: set, allow_time: bool = False) -> bool:
        for field in self._QUALIFIER_FIELDS:
            if field in allowed:
                continue
            if detail.get(field) not in (None, "", False):
                return False
        for field in self._QUALIFIER_FLAGS:
            if detail.get(field):
                return False
        if not allow_time and detail.get("time_of_day"):
            return False
        return True

    def _evo_item_token(self, api_item_name: str) -> str:
        """api item name -> the ASM evolution-param spelling where one exists."""
        asm_vocab = getattr(self, "_asm_evo_item_vocab", None)
        if asm_vocab is None:
            asm_vocab = {}
            for entry in self.current_entries.values():
                for evo in entry["evolutions"]:
                    param = evo.get("param")
                    if isinstance(param, str):
                        asm_vocab.setdefault(norm_key(param), param)
            self._asm_evo_item_vocab = asm_vocab
        return asm_vocab.get(norm_key(api_item_name), upper_token(api_item_name))

    # -- moves emission --

    def referenced_move_ids(self, species_entries: dict) -> list:
        # Dead spellings in carried-forward arrays (e.g. pokecrystal's PSYCHIC_M in tmhm
        # lines) alias to the canonical catalog id for union purposes only; the literal
        # tokens inside carried-forward arrays stay untouched for byte parity, so such
        # references stay exactly as resolvable (or not) as they are today.
        aliases = self.overrides.get("move_aliases", {})
        ids = set(self.asm_moves.keys())
        for entry in species_entries.values():
            for row in entry["learnset"]:
                ids.add(aliases.get(row["move_id"], row["move_id"]))
            ids.update(aliases.get(m, m) for m in entry["egg_moves"])
            ids.update(aliases.get(m, m) for m in entry["tmhm"])
        return sorted(ids)

    def build_moves(self, move_ids: list) -> dict:
        entries = {}
        for move_id in move_ids:
            if move_id in self.asm_moves:
                entry = dict(self.asm_moves[move_id])
                api_name = self.move_map.get(move_id)
                api_move = self.api.by_name("move", api_name) if api_name else None
                entry["priority"], entry["target"], entry["ailment"] = self._api_move_meta(api_move)
                entries[move_id] = entry
                continue
            api_name = move_id.lower().replace("_", "-")
            api_move = self.api.by_name("move", api_name)
            if api_move is None:
                normed = self.api.find_by_norm("move", move_id)
                api_move = self.api.by_name("move", normed) if normed else None
            if api_move is None:
                self.unmapped_moves.append((move_id, "referenced but absent from api-data"))
                continue
            priority, target, ailment = self._api_move_meta(api_move)
            power = api_move.get("power")
            power = int(power) if power is not None else 0
            damage_class = api_move["damage_class"]["name"].upper()
            category = damage_class if damage_class in ("PHYSICAL", "SPECIAL") else "STATUS"
            if power <= 0:
                category = "STATUS"
            accuracy = api_move.get("accuracy")
            pp = api_move.get("pp")
            display_name = self.move_names.get(move_id.lower()) or self._api_move_display_name(api_move)
            meta = api_move.get("meta") or {}
            entries[move_id] = {
                "move_id": move_id,
                "display_name": display_name,
                "effect": "EFFECT_NORMAL_HIT",
                "power": power,
                "type": api_move["type"]["name"].upper(),
                "accuracy": int(accuracy) if accuracy is not None else 100,
                "pp": int(pp) if pp is not None else 0,
                "effect_chance": int(meta.get("ailment_chance") or 0),
                "category": category,
                "priority": priority,
                "target": target,
                "ailment": ailment,
            }
            self.api_only_moves.append(move_id)
        return entries

    def _api_move_display_name(self, api_move: dict) -> str:
        for row in api_move.get("names", []):
            if row["language"]["name"] == "en":
                return row["name"]
        return humanize_slug(api_move["name"].replace("-", "_"))

    def _api_move_meta(self, api_move):
        if api_move is None:
            return 0, "", "NONE"
        meta = api_move.get("meta") or {}
        ailment = (meta.get("ailment") or {}).get("name", "")
        target = (api_move.get("target") or {}).get("name", "")
        # api-data spells "no ailment" as "none" and omits meta for LA moves; both -> NONE.
        ailment_token = upper_token(ailment) if ailment else "NONE"
        return int(api_move.get("priority") or 0), upper_token(target) if target else "", ailment_token

    def check_anim_assets(self, move_ids: list) -> None:
        for move_id in move_ids:
            if "%s_player_gsc" % move_id.lower() not in self.anim_dirs:
                self.missing_anim_moves.append(move_id)

    # -- items emission --

    def build_items(self) -> dict:
        supplements = self.overrides.get("item_supplements", {})
        keys = self.item_keys()

        pocket_by_category = {}
        entries = {}
        for key in keys:
            item_id = key.upper()
            supplement = supplements.get(key, {})
            if key in self.item_names or key in self.item_descriptions:
                display_name = str(self.item_names.get(key, humanize_slug(key)))
                description = str(self.item_descriptions.get(key, ""))
            else:
                display_name = str(supplement.get("display_name", humanize_slug(key)))
                description = str(supplement.get("description", ""))
            cost = 0
            pocket = str(supplement.get("pocket", ""))
            category = str(supplement.get("category", ""))
            api_name = self.item_map.get(key)
            if api_name:
                api_item = self.api.by_name("item", api_name)
                if api_item is not None:
                    cost = self._api_item_cost(api_item)
                    category_ref = api_item.get("category") or {}
                    category = upper_token(category_ref.get("name", "")) if category_ref.get("name") else ""
                    pocket = self._api_item_pocket(category_ref, pocket_by_category)
                    self.item_api_hits.append(item_id)
            entries[item_id] = {
                "item_id": item_id,
                "display_name": display_name,
                "description": description,
                "cost": cost,
                "pocket": pocket,
                "category": category,
            }
        return entries

    def _api_item_cost(self, api_item: dict) -> int:
        prices = api_item.get("prices") or []
        rank = {group: index for index, group in enumerate(VERSION_GROUP_CHAIN)}
        priced = [p for p in prices if p.get("purchase_price") is not None]
        if not priced:
            return 0
        priced.sort(key=lambda p: rank.get((p.get("version_group") or {}).get("name", ""), len(VERSION_GROUP_CHAIN)))
        return int(priced[0]["purchase_price"])

    def _api_item_pocket(self, category_ref: dict, cache: dict) -> str:
        url = category_ref.get("url")
        if not url:
            return ""
        category_id = url.rstrip("/").split("/")[-1]
        if category_id not in cache:
            doc = self.api.load("item-category/%s/index.json" % category_id)
            pocket = (doc.get("pocket") or {}).get("name", "")
            cache[category_id] = upper_token(pocket) if pocket else ""
        return cache[category_id]

    # -- expansion candidates --

    def expansion_candidates(self) -> list:
        used = {name for name in self.species_map.values() if name}
        candidates = sorted(set(self.api.index("pokemon").keys()) - used)
        return candidates


# --- Reports --------------------------------------------------------------------------

REPORT_HEADER = """Status: generated
Last verified: {date}
Review cadence days: 0
Source paths: tools/import_pokeapi.py
"""


def pin_date(pin: dict) -> str:
    return str(pin.get("fetched_at", ""))[:10]


def write_import_report(importer: Importer, pin: dict, counts: dict) -> None:
    lines = [REPORT_HEADER.format(date=pin_date(pin))]
    lines.append("# PokeAPI Catalog Import — Coverage Report\n")
    lines.append(
        "Generated by `python3 tools/import_pokeapi.py` from pinned upstream `%s` at `%s` "
        "(`tools/api_data_pin.json`). Regenerate after bumping the pin with `--refresh`.\n"
        % (pin.get("repo", ""), pin.get("sha", ""))
    )

    lines.append("## Imported counts\n")
    lines.append("| Artifact | Entries |")
    lines.append("| --- | --- |")
    lines.append("| species.json | %d |" % counts["species"])
    lines.append("| moves.json | %d (%d carried from moves.asm, %d api-data-only) |" % (
        counts["moves"], counts["moves_asm"], counts["moves_api_only"]))
    lines.append("| items.json | %d (%d enriched from api-data) |" % (counts["items"], counts["items_api"]))
    lines.append("")

    lines.append("## Unmapped art-tree folders (hard-fail set)\n")
    if importer.unmapped_species:
        for slug, reason in importer.unmapped_species:
            lines.append("- `%s` — %s" % (slug, reason))
    else:
        lines.append("None — every emitted folder resolved to a PokeAPI resource.\n")
    lines.append("")

    lines.append("## Skipped — no runtime entry today (no parseable ASM)\n")
    lines.append(
        "These art-tree folders carry no parseable `base_stats.asm`/`wilds_data.asm`, so the "
        "current loader already skips them; they stay out of the catalog to preserve the "
        "encounter-viability rule byte-for-byte.\n"
    )
    for slug in importer.skipped_folders:
        lines.append("- `%s`" % slug)
    lines.append("")

    lines.append("## Skipped — no assets (expansion candidates)\n")
    lines.append(
        "api-data pokemon resources with no art-tree folder. Adding one later = drop the "
        "folder into `assets/source/pokemon/pokemon/` and rerun the importer.\n"
    )
    candidates = importer.expansion_candidates()
    lines.append("%d candidates:" % len(candidates))
    lines.append("")
    for candidate in candidates:
        lines.append("- `%s`" % candidate)
    lines.append("")

    lines.append("## Imported moves missing anim assets\n")
    lines.append(
        "No `assets/source/attacks/<move>_player_gsc` set; runtime falls back to the "
        "synthesized lunge+flash anim (attack_anims.gd).\n"
    )
    if importer.missing_anim_moves:
        for move_id in importer.missing_anim_moves:
            lines.append("- `%s`" % move_id)
    else:
        lines.append("None.")
    lines.append("")

    lines.append("## Version-group choices (learnsets)\n")
    group_counts: dict = {}
    for group in importer.version_group_choices.values():
        group_counts[group] = group_counts.get(group, 0) + 1
    lines.append("| Version group | Species |")
    lines.append("| --- | --- |")
    for group in sorted(group_counts, key=lambda g: (-group_counts[g], g)):
        lines.append("| %s | %d |" % (group, group_counts[group]))
    lines.append("")
    if importer.learnset_carry_forward:
        lines.append("No level-up data in any chain group — ASM `evos_attacks.asm` learnset carried forward:\n")
        lines.append("`" + "`, `".join(sorted(importer.learnset_carry_forward)) + "`")
        lines.append("")

    egg_sources: dict = {}
    for source in importer.egg_move_sources.values():
        egg_sources[source] = egg_sources.get(source, 0) + 1
    lines.append("### Egg-move sources\n")
    lines.append("| Source | Species |")
    lines.append("| --- | --- |")
    for source in sorted(egg_sources):
        lines.append("| %s | %d |" % (source, egg_sources[source]))
    lines.append("")

    lines.append("## Synthetic species\n")
    if importer.synthetic_species:
        for slug, note in importer.synthetic_species:
            lines.append("- `%s` — %s" % (slug, note))
    else:
        lines.append("None.")
    lines.append("")

    lines.append("## Evolution augmentations from api-data\n")
    lines.append(
        "ASM evolution lists are carried forward verbatim (PokeWilds re-authored trade "
        "evolutions as stone evolutions; the runtime only acts on LEVEL*/HAPPINESS/ITEM). "
        "api-data adds entries only where the ASM list never had the target.\n"
    )
    if importer.evolution_augmented:
        lines.append("| Species | Method | Param | Target |")
        lines.append("| --- | --- | --- | --- |")
        for slug, method, param, target in sorted(importer.evolution_augmented):
            lines.append("| %s | %s | %s | %s |" % (slug, method, param, target))
    else:
        lines.append("None.")
    lines.append("")
    if importer.evolution_unmappable:
        lines.append("### api-data evolutions left unmapped (skipped)\n")
        for slug, target, reason in sorted(importer.evolution_unmappable):
            lines.append("- `%s` -> `%s` (%s)" % (slug, target, reason))
        lines.append("")

    lines.append("## Notable parity deltas\n")
    lines.append("See `docs/generated/catalog-parity.md` for the field-level diff report "
                 "(expected vs. unexpected classes, encounter-eligibility changes).\n")

    lines.append("## Runtime loader contract notes\n")
    lines.append(
        "For the loader rewrite consuming these JSON files:\n"
        "\n"
        "- **Encounter order**: `species.json` keys are uppercase-sorted, but today's "
        "`encounter_species` is built in lowercase folder sort order. Iterate entries "
        "sorted by `slug` when building encounter tables, or seeded rng picks shift. "
        "Apply the same viability rule (front+back paths, catch_rate > 0, base_stats, "
        "non-empty learnset, not EGG); the 9 newly-eligible species are listed in the "
        "parity report.\n"
        "- **Evolution `param` is a Variant**: int for LEVEL/LEVELDAY/LEVELNIGHT, string "
        "for ITEM/TRADEITEM/HAPPINESS/MOVE params, null for TRADE. `pokemon_rules.gd` "
        "reads both; coerce only numeric representations to int.\n"
        "- **Evolution lists are ASM-first**: existing entries reproduce today's ASM "
        "verbatim (including dead targets like `KOMMOO` — kept for parity); api-data "
        "entries are appended after them. `check_*_evolution` returns the first match, "
        "so ASM entries win.\n"
        "- **`egg` is synthetic**: no api-data resource; entry is the byte-exact current "
        "ASM state plus empty `held_items`/`abilities`.\n"
        "- **Dead move spellings stay dead**: `move_aliases` (PSYCHIC_M -> PSYCHIC plus "
        "the ASM-source spellings of carried moves, e.g. SOLAR_BEAM -> SOLARBEAM) "
        "applies only to the moves.json union computation; the literal tokens inside "
        "carried-forward `tmhm`/egg/learnset arrays are untouched, so resolvability "
        "matches today exactly.\n"
        "- **Single egg groups are doubled** (`[\"FIELD\", \"FIELD\"]`), matching the "
        "pokecrystal `dn EGG_X, EGG_X` convention today's entries use.\n"
        "- **Moves**: the original 299 moves.asm rows keep their exact GSC effect "
        "constants/stats; api-data-only moves get `EFFECT_NORMAL_HIT` + api damage "
        "class. `priority`/`target`/`ailment` are additive everywhere (`ailment` is "
        "`NONE` when the move has no meta ailment).\n"
        "- **Items**: `cost` is the purchase price from the most-preferred version "
        "group in `VERSION_GROUP_CHAIN`, 0 when upstream has no price row; `pocket`/"
        "`category` come from the item's api-data counterpart, or from the custom's "
        "`item_supplements` entry when it has none (empty strings when neither "
        "specifies them, e.g. ANCIENTPOWDER).\n"
    )
    IMPORT_REPORT.write_text("".join(line + "\n" for line in lines), encoding="utf-8")


# --- Parity (--diff-against-asm) ------------------------------------------------------

SET_COMPARE_FIELDS = {"egg_groups", "egg_moves", "tmhm", "spawn_biomes"}
DICT_COMPARE_FIELDS = {"base_stats", "field_moves", "overworld_behavior"}
ADDITIVE_FIELDS = {"held_items", "abilities"}
FIELD_ORDER = [
    "species_id", "slug", "display_name", "dex_number", "types", "base_stats",
    "learnset", "evolutions", "catch_rate", "base_exp", "growth_rate",
    "gender_ratio", "egg_groups", "egg_moves", "tmhm", "spawn_biomes",
    "field_moves", "overworld_behavior", "dex_entry", "weight_kg", "height_m",
    "front_path", "back_path", "overworld_path", "shiny_overworld_path",
    "held_items", "abilities",
]


def _fmt_value(value) -> str:
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text if len(text) <= 96 else text[:93] + "..."


def diff_species_entry(current: dict, emitted: dict, species_id: str, placeholder_ids: set) -> list:
    """Field-level diffs between today's runtime entry and the emitted one."""
    diffs = []
    for field in FIELD_ORDER:
        if field in ADDITIVE_FIELDS:
            if emitted.get(field):
                diffs.append({
                    "species": species_id, "field": field, "class": "additive-field",
                    "old": "(absent)", "new": _fmt_value(emitted[field]),
                })
            continue
        old = current.get(field)
        new = emitted.get(field)
        if field in SET_COMPARE_FIELDS:
            if sorted(old or []) == sorted(new or []):
                continue
        elif field in DICT_COMPARE_FIELDS:
            if dict(old or {}) == dict(new or {}):
                continue
        elif old == new:
            continue
        diff_class = classify_diff(species_id, field, old, new, current, placeholder_ids)
        diffs.append({
            "species": species_id, "field": field, "class": diff_class,
            "old": _fmt_value(old), "new": _fmt_value(new),
        })
    return diffs


def classify_diff(species_id: str, field: str, old, new, current: dict, placeholder_ids: set) -> str:
    if species_id in placeholder_ids:
        return "placeholder-gains-real-data"
    if field == "learnset":
        return "learnset-churn"
    if field == "egg_moves":
        return "egg-move-churn"
    if field == "evolutions":
        return "evolution-augment"
    if field == "display_name":
        return "display-name-fallback"
    if field in ("weight_kg", "height_m") and not old:
        return "weight-height-api-fallback"
    if field == "egg_groups":
        old_set, new_set = set(old or []), set(new or [])
        removed = old_set - new_set
        if removed and removed <= {"HUMANSHAPE", "GROUND", "PLANT"}:
            return "token-standardization"
        return "canon-data-update"
    if field in ("spawn_biomes", "field_moves", "overworld_behavior", "dex_entry", "tmhm"):
        return "UNEXPECTED-carried-field"  # carried forward verbatim; never expected
    if field in ("front_path", "back_path", "overworld_path", "shiny_overworld_path"):
        return "UNEXPECTED-sprite-path"
    if field == "types":
        return "type-update"
    if field == "base_stats":
        return "stat-update"
    if field in ("catch_rate", "base_exp", "growth_rate", "gender_ratio", "dex_number"):
        return "canon-data-update"
    return "UNEXPECTED"


def compute_placeholder_ids(importer: Importer) -> set:
    """Folders whose base_stats.asm is a byte-copy of ANOTHER species' file.

    Detected by: declared species constant != folder id AND the declared species'
    own base_stats.asm parses to the identical stat block. Decl spelling variants
    (punctuation, region suffixes) with their own stats are NOT placeholders.

    Pure cross-folder comparison over the parse build_current_catalog retained.
    """
    parsed_by_folder = importer.base_by_folder
    placeholder_ids = set()
    for folder in importer.current_folders():
        base = parsed_by_folder.get(folder, {})
        if not base:
            continue
        decl = base.get("species_id", "")
        if not decl or decl == folder.upper():
            continue
        other = parsed_by_folder.get(decl.lower(), {})
        if other and other.get("base_stats") == base.get("base_stats"):
            placeholder_ids.add(folder.upper())
    return placeholder_ids


def parity_kernel(importer: Importer, emitted_species: dict, emitted_moves: dict,
                  emitted_items: dict) -> dict:
    """The always-on parity kernel, re-derived from the ASM parser ports on every
    generating run.

    Returns the report data plus the invariant-violation list: UNEXPECTED species
    diffs (carried fields + sprite paths must be byte-identical), carried-ASM-move
    field diffs, and item display_name/description diffs vs their sources must ALL
    be zero; the encounter-eligibility delta is surfaced, never asserted.
    """
    placeholder_ids = compute_placeholder_ids(importer)

    all_diffs = []
    for species_id in sorted(emitted_species):
        current = importer.current_entries.get(species_id, {})
        all_diffs.extend(diff_species_entry(current, emitted_species[species_id], species_id, placeholder_ids))

    expected = [d for d in all_diffs if not d["class"].startswith("UNEXPECTED")]
    unexpected = [d for d in all_diffs if d["class"].startswith("UNEXPECTED")]

    # Encounter-eligibility delta (the one behavior-relevant set).
    current_viable = {sid for sid, e in importer.current_entries.items() if is_encounter_viable(sid, e)}
    emitted_viable = {sid for sid, e in emitted_species.items() if is_encounter_viable(sid, e)}
    gained = sorted(emitted_viable - current_viable)
    lost = sorted(current_viable - emitted_viable)

    # Moves parity: carried fields of ASM moves must be identical by construction.
    move_field_diffs = []
    for move_id, asm_entry in importer.asm_moves.items():
        emitted = emitted_moves.get(move_id)
        if emitted is None:
            move_field_diffs.append((move_id, "missing", "", ""))
            continue
        for field in ("display_name", "effect", "power", "type", "accuracy", "pp", "effect_chance", "category"):
            if emitted.get(field) != asm_entry.get(field):
                move_field_diffs.append((move_id, field, _fmt_value(asm_entry.get(field)), _fmt_value(emitted.get(field))))

    # Items parity: display_name/description must equal their sources verbatim.
    item_field_diffs = []
    supplements = importer.overrides.get("item_supplements", {})
    for key in importer.item_keys():
        item_id = key.upper()
        emitted = emitted_items.get(item_id)
        if emitted is None:
            item_field_diffs.append((item_id, "missing", "", ""))
            continue
        if key in importer.item_names or key in importer.item_descriptions:
            want_name = str(importer.item_names.get(key, humanize_slug(key)))
            want_description = str(importer.item_descriptions.get(key, ""))
        else:
            supplement = supplements.get(key, {})
            want_name = str(supplement.get("display_name", humanize_slug(key)))
            want_description = str(supplement.get("description", ""))
        if emitted.get("display_name") != want_name:
            item_field_diffs.append((item_id, "display_name", _fmt_value(want_name),
                                     _fmt_value(emitted.get("display_name"))))
        if emitted.get("description") != want_description:
            item_field_diffs.append((item_id, "description", _fmt_value(want_description),
                                     _fmt_value(emitted.get("description"))))

    violations = []
    if unexpected:
        violations.append(
            "%d UNEXPECTED species field diff(s) — carried fields and sprite paths must be "
            "byte-identical (first: %s %s)"
            % (len(unexpected), unexpected[0]["species"], unexpected[0]["field"]))
    if move_field_diffs:
        violations.append(
            "%d carried-ASM-move field diff(s) — the original moves.asm rows must be "
            "identical (first: %s %s)"
            % (len(move_field_diffs), move_field_diffs[0][0], move_field_diffs[0][1]))
    if item_field_diffs:
        violations.append(
            "%d item display_name/description diff(s) vs the i18n/supplement sources "
            "(first: %s %s)"
            % (len(item_field_diffs), item_field_diffs[0][0], item_field_diffs[0][1]))

    return {
        "expected": expected, "unexpected": unexpected,
        "gained": gained, "lost": lost,
        "move_field_diffs": move_field_diffs, "item_field_diffs": item_field_diffs,
        "violations": violations,
    }


def write_parity_report(importer: Importer, pin: dict, emitted_species: dict,
                        emitted_moves: dict, emitted_items: dict,
                        itemize_expected: bool = False) -> str:
    """Writes the parity report and returns the one-line summary.

    The invariant kernel runs on every generating run; the itemized expected-diff
    table (migration-certification evidence) is --diff-against-asm-only. Any
    kernel violation is a hard fail AFTER the report lands, so the evidence is
    on disk."""
    kernel = parity_kernel(importer, emitted_species, emitted_moves, emitted_items)
    expected = kernel["expected"]
    unexpected = kernel["unexpected"]
    gained = kernel["gained"]
    lost = kernel["lost"]
    move_field_diffs = kernel["move_field_diffs"]
    item_field_diffs = kernel["item_field_diffs"]

    lines = [REPORT_HEADER.format(date=pin_date(pin))]
    lines.append("# Catalog Parity — api-data import vs. current ASM parsers\n")
    provenance = "Regenerated by `python3 tools/import_pokeapi.py%s`." % (
        " --diff-against-asm" if itemize_expected else "")
    lines.append(
        "%s The OLD column ports the GDScript ASM parsers (scripts/data/species_file_parser.gd + "
        "move_file_parser.gd @ HEAD) to Python; the NEW column is the emitted catalog.\n"
        % provenance
    )
    if not itemize_expected:
        lines.append(
            "The itemized expected-diff table is `--diff-against-asm`-only; the invariant "
            "kernel below runs (and hard-fails on UNEXPECTED classes) on every generating run.\n"
        )

    lines.append("## Summary\n")
    lines.append("| Class | Field diffs |")
    lines.append("| --- | --- |")
    class_counts: dict = {}
    for diff in expected + unexpected:
        class_counts[diff["class"]] = class_counts.get(diff["class"], 0) + 1
    for diff_class in sorted(class_counts, key=lambda c: (c.startswith("UNEXPECTED"), c)):
        lines.append("| %s | %d |" % (diff_class, class_counts[diff_class]))
    lines.append("| **TOTAL unexpected** | **%d** |" % len(unexpected))
    lines.append("")

    lines.append("## Encounter-eligibility delta\n")
    lines.append(
        "Species entering/leaving the runtime `encounter_species` rule (front+back sprites, "
        "catch rate > 0, base stats, non-empty learnset, not EGG).\n"
    )
    lines.append("- Newly encounter-eligible (%d): %s" % (len(gained), ", ".join("`%s`" % g for g in gained) or "none"))
    lines.append("- Newly ineligible (%d): %s" % (len(lost), ", ".join("`%s`" % l for l in lost) or "none"))
    lines.append("")

    lines.append("## Moves parity (carried fields of the original moves.asm set)\n")
    if move_field_diffs:
        lines.append("| Move | Field | Old | New |")
        lines.append("| --- | --- | --- | --- |")
        for move_id, field, old, new in move_field_diffs:
            lines.append("| %s | %s | %s | %s |" % (move_id, field, old, new))
    else:
        lines.append("Zero diffs — all carried move fields are byte-identical.\n")
    lines.append("")

    if itemize_expected:
        lines.append("## Expected diffs (itemized)\n")
        if expected:
            lines.append("| Species | Field | Old | New | Class |")
            lines.append("| --- | --- | --- | --- | --- |")
            for diff in expected:
                lines.append("| %s | %s | %s | %s | %s |" % (
                    diff["species"], diff["field"], diff["old"], diff["new"], diff["class"]))
        else:
            lines.append("None.")
        lines.append("")
    else:
        lines.append("## Expected diffs\n")
        lines.append(
            "%d expected diffs across the classes in the Summary table; the itemized "
            "table is migration-certification evidence emitted only by `--diff-against-asm`.\n"
            % len(expected))
        lines.append("")

    lines.append("## UNEXPECTED diffs (must be zero — a non-zero class hard-fails the run)\n")
    if unexpected:
        lines.append("| Species | Field | Old | New | Class |")
        lines.append("| --- | --- | --- | --- | --- |")
        for diff in unexpected:
            lines.append("| %s | %s | %s | %s | %s |" % (
                diff["species"], diff["field"], diff["old"], diff["new"], diff["class"]))
    else:
        lines.append("None — every remaining difference is accounted for by the expected classes.\n")
    lines.append("")

    lines.append("## Items parity\n")
    if item_field_diffs:
        lines.append("| Item | Field | Source | Emitted |")
        lines.append("| --- | --- | --- | --- |")
        for item_id, field, want, got in item_field_diffs:
            lines.append("| %s | %s | %s | %s |" % (item_id, field, want, got))
        lines.append("")
    else:
        lines.append(
            "Zero diffs — `display_name`/`description` verified field-by-field against their "
            "sources (i18n properties + overrides supplements); `cost`/`pocket`/`category` "
            "come from api-data when available, otherwise from `item_supplements`; "
            "`cost` is `0` and pocket/category are empty only when neither source supplies "
            "them.\n"
        )
    PARITY_REPORT.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
    summary = ("parity: %d expected diffs, %d UNEXPECTED, encounter +%d/-%d, "
               "move-field diffs %d, item-field diffs %d" % (
                   len(expected), len(unexpected), len(gained), len(lost),
                   len(move_field_diffs), len(item_field_diffs)))
    if kernel["violations"]:
        raise ParityViolation(
            "parity invariant(s) violated (see docs/generated/catalog-parity.md):\n  "
            + "\n  ".join(kernel["violations"]))
    return summary


# --- Pipeline -------------------------------------------------------------------------


def dump_json(obj) -> bytes:
    return (json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def assert_move_id_hygiene(importer: Importer, species_entries: dict, moves: dict) -> None:
    """Hard-fail guard against duplicate-spelling move ids (the canonicalization
    phase-order defect class): no two emitted move keys may collide under norm_key,
    and no learnset/egg/tmhm reference may norm-collide with a carried ASM move id
    without BEING that id or a registered move_aliases dead spelling (carried arrays
    keep their literal ASM tokens for byte parity; the registry documents them)."""
    seen: dict = {}
    for move_id in moves:
        other = seen.setdefault(norm_key(move_id), move_id)
        if other != move_id:
            raise ParityViolation(
                "moves.json keys %r and %r collide under norm_key — a duplicate-spelling "
                "move pair (map_moves() must run before build_species())" % (other, move_id))
    aliases = importer.overrides.get("move_aliases", {})
    asm_by_norm = {}
    for move_id in importer.asm_moves:
        asm_by_norm.setdefault(norm_key(move_id), move_id)
    for species_id, entry in species_entries.items():
        refs = [row["move_id"] for row in entry["learnset"]]
        refs += entry["egg_moves"] + entry["tmhm"]
        for ref in refs:
            if ref in importer.asm_moves or ref in aliases:
                continue
            carried = asm_by_norm.get(norm_key(ref))
            if carried is not None:
                raise ParityViolation(
                    "%s references %r, which norm-collides with carried ASM move %r — "
                    "bind the reference to the carried id or register the dead spelling "
                    "in move_aliases" % (species_id, ref, carried))


def build_all(api: ApiData, overrides: dict):
    """Map everything, then build everything. Returns (importer, results) where
    results is (species_entries, moves, items), or None when mapping hard-failed
    (main reports the unmapped entries and never touches results)."""
    importer = Importer(api, overrides)
    # The mapping phase must COMPLETE before any build: canonical_move_id() resolves
    # api move names against the FINAL move map, so no api name can memoize a
    # duplicate upper_token spelling beside its carried ASM id.
    importer.map_species()
    importer.map_moves()
    importer.map_items()
    if importer.unmapped_species:
        return importer, None
    species_entries = importer.build_species()
    move_ids = importer.referenced_move_ids(species_entries)
    moves = importer.build_moves(move_ids)
    if importer.unmapped_moves:
        return importer, None
    importer.check_anim_assets(sorted(moves.keys()))
    items = importer.build_items()
    assert_move_id_hygiene(importer, species_entries, moves)
    return importer, (species_entries, moves, items)


def write_outputs(importer: Importer, pin: dict, species_entries: dict, moves: dict, items: dict,
                  write_reports: bool = True, itemize_expected: bool = False) -> str:
    CATALOG_DIR.mkdir(parents=True, exist_ok=True)
    (CATALOG_DIR / "species.json").write_bytes(dump_json(species_entries))
    (CATALOG_DIR / "moves.json").write_bytes(dump_json(moves))
    (CATALOG_DIR / "items.json").write_bytes(dump_json(items))
    parity_summary = ""
    if write_reports:
        counts = {
            "species": len(species_entries),
            "moves": len(moves),
            "moves_asm": sum(1 for m in moves if m in importer.asm_moves),
            "moves_api_only": len(importer.api_only_moves),
            "items": len(items),
            "items_api": len(importer.item_api_hits),
        }
        write_import_report(importer, pin, counts)
        parity_summary = write_parity_report(importer, pin, species_entries, moves, items,
                                             itemize_expected=itemize_expected)
    return parity_summary


def load_pin() -> dict:
    if not PIN_FILE.exists():
        raise CacheMissing(
            "tools/api_data_pin.json missing. Run: python3 tools/import_pokeapi.py --refresh"
        )
    with open(PIN_FILE, encoding="utf-8") as handle:
        return json.load(handle)


def _move_cache_directory(source: Path, destination: Path) -> None:
    """Publish an extracted cache with Windows' copy/remove fallback."""
    if destination.exists():
        raise FileExistsError(f"cache destination still exists: {destination}")
    shutil.move(str(source), str(destination))
    (destination / CACHE_COMPLETE_MARKER).write_text("complete\n", encoding="utf-8")


def _remove_cache_directory(path: Path) -> None:
    """Invalidate a published cache before destructive cleanup."""
    try:
        (path / CACHE_COMPLETE_MARKER).unlink()
    except FileNotFoundError:
        pass
    shutil.rmtree(path, ignore_errors=True)


def _download_and_extract(pin: dict) -> None:
    tarball = CACHE_DIR / ("api-data-%s.tar.gz" % pin["sha"])
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if not tarball.exists():
        print("downloading %s" % (GITHUB_TARBALL % pin["sha"]))
        request = urllib.request.Request(GITHUB_TARBALL % pin["sha"], headers={"User-Agent": "poke-wilds-godot-importer"})
        with urllib.request.urlopen(request, timeout=300) as response, open(tarball, "wb") as handle:
            shutil.copyfileobj(response, handle)
    extract_to = CACHE_DIR / "api-data.tmp"
    shutil.rmtree(extract_to, ignore_errors=True)
    extract_to.mkdir(parents=True)
    with tarfile.open(tarball, "r:gz") as archive:
        try:
            archive.extractall(extract_to, filter="data")
        except TypeError:  # Python < 3.12 lacks the extraction filter
            archive.extractall(extract_to)
    # Strip the single top-level api-data-<sha>/ directory.
    children = list(extract_to.iterdir())
    _remove_cache_directory(CACHE_API_DATA)
    if len(children) == 1 and children[0].is_dir():
        # ``Path.rename`` can fail with WinError 5 for an extracted non-empty
        # directory even when the destination does not exist. ``shutil.move``
        # preserves the atomic rename on platforms that support it and falls
        # back to copy/remove on Windows when the native rename is refused.
        _move_cache_directory(children[0], CACHE_API_DATA)
        shutil.rmtree(extract_to, ignore_errors=True)
    else:
        _move_cache_directory(extract_to, CACHE_API_DATA)
    print("extracted to %s" % CACHE_API_DATA.relative_to(ROOT))


def cmd_refresh() -> dict:
    request = urllib.request.Request(
        GITHUB_API_COMMITS,
        headers={"User-Agent": "poke-wilds-godot-importer", "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    pin = {
        "repo": API_REPO,
        "sha": data["sha"],
        "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(PIN_FILE, "w", encoding="utf-8") as handle:
        json.dump(pin, handle, indent=2)
        handle.write("\n")
    print("pinned %s @ %s" % (API_REPO, pin["sha"]))
    _download_and_extract(pin)
    return pin


def cmd_fetch_pinned() -> dict:
    """Download + extract the tarball for the COMMITTED pin only — never
    re-resolves upstream, never moves the pin, never regenerates. This is the
    CI cache validation/repair path: --refresh would silently re-pin to the
    latest upstream and rewrite the catalog in the working tree, making the
    S4.5 freshness gate (--check) tautological exactly when the cache is cold."""
    pin = load_pin()
    print("fetching committed pin %s @ %s" % (pin["repo"], pin["sha"]))
    _download_and_extract(pin)
    return pin


def report_unmapped(importer: Importer) -> int:
    print("import_pokeapi: UNMAPPED entries (hard fail):", file=sys.stderr)
    for slug, reason in importer.unmapped_species:
        print("  species %s: %s" % (slug, reason), file=sys.stderr)
    for move_id, reason in importer.unmapped_moves:
        print("  move %s: %s" % (move_id, reason), file=sys.stderr)
    print("Add the residue to tools/import_overrides.json and re-run.", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--refresh", action="store_true", help="re-resolve the upstream SHA, download + extract the tarball, then regenerate")
    parser.add_argument("--fetch-pinned", action="store_true", help="download + re-extract the COMMITTED pin's tarball only (CI cache validation/repair path; never moves the pin, never regenerates)")
    parser.add_argument("--check", action="store_true", help="exit 0 when committed catalog JSON matches regeneration from the pinned cache")
    parser.add_argument("--diff-against-asm", action="store_true", help="print the ASM-parity summary (report is written on every generating run)")
    args = parser.parse_args()

    try:
        if args.refresh:
            pin = cmd_refresh()
        elif args.fetch_pinned:
            pin = cmd_fetch_pinned()
        else:
            pin = load_pin()
        api = ApiData(CACHE_API_DATA)
    except CacheMissing as error:
        print("import_pokeapi: %s" % error, file=sys.stderr)
        return 1
    if args.fetch_pinned and not (args.check or args.refresh):
        return 0  # fetch-only: no regeneration, no catalog writes

    overrides = load_overrides()
    try:
        importer, results = build_all(api, overrides)
    except ParityViolation as error:
        print("import_pokeapi: %s" % error, file=sys.stderr)
        return 1
    if importer.unmapped_species or importer.unmapped_moves:
        return report_unmapped(importer)
    species_entries, moves, items = results

    if args.check:
        problems = []
        for name, obj in (("species.json", species_entries), ("moves.json", moves), ("items.json", items)):
            path = CATALOG_DIR / name
            regenerated = dump_json(obj)
            if not path.exists():
                problems.append("%s: missing (committed file absent)" % name)
                continue
            committed = path.read_bytes()
            if committed != regenerated:
                old_keys = set(json.loads(committed.decode("utf-8")).keys())
                new_keys = set(obj.keys())
                added = sorted(new_keys - old_keys)
                removed = sorted(old_keys - new_keys)
                detail = []
                if added:
                    detail.append("added keys: %s" % ", ".join(added[:8]))
                if removed:
                    detail.append("removed keys: %s" % ", ".join(removed[:8]))
                if not detail:
                    detail.append("value drift (same %d keys, bytes differ)" % len(new_keys))
                problems.append("%s: STALE — %s" % (name, "; ".join(detail)))
        if problems:
            print("import_pokeapi --check: catalog is stale:", file=sys.stderr)
            for problem in problems:
                print("  " + problem, file=sys.stderr)
            print("Run: python3 tools/import_pokeapi.py", file=sys.stderr)
            return 1
        print("import_pokeapi --check: catalog fresh (%d species, %d moves, %d items)." % (
            len(species_entries), len(moves), len(items)))
        return 0

    try:
        parity_summary = write_outputs(importer, pin, species_entries, moves, items,
                                       itemize_expected=args.diff_against_asm)
    except ParityViolation as error:
        print("import_pokeapi: %s" % error, file=sys.stderr)
        return 1
    print("import_pokeapi: wrote %d species, %d moves, %d items to %s" % (
        len(species_entries), len(moves), len(items), CATALOG_DIR.relative_to(ROOT)))

    if args.diff_against_asm:
        print("%s (see docs/generated/catalog-parity.md)" % parity_summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
