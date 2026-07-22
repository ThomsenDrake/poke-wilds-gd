#!/usr/bin/env python3
"""Lane-4 VLM reviewer plugin: Qwen3-VL behind the existing --reviewer-cmd socket.

This is the MODEL-REVIEWER LANE (the G2 answerer). It implements the
`tools/vision_review.py --reviewer-cmd` contract EXACTLY: it reads the bundle the
pipeline ships on stdin -- {shot, shot_kind, paths, reviewer_params,
finding_schema, window, clusters, som_legend, region_table, grounding_rules} --
and writes {"findings":[...], "answers":[...]} to stdout (schema vision-review/2).
Grounding is enforced PIPELINE-SIDE after this process returns, so this wrapper
only emits well-formed citations: a `region_id` resolvable in `region_table` with
`bbox` = that region's own rect (guaranteed intersection). It never mints a
finding_id, never enforces grounding, never goes red: output is QUARANTINE-tier
and the witness is never the geometric oracle.

TWO OUTPUT CHANNELS (matching the extended lane):
  * answers[] -- the model ANSWERS the shot-group's rubric questions (the G2
    seam). Each answer is {question_id, verdict: yes|no, region_id?, bbox?, note,
    reviewer_kind: "model-qwen3-vl"}; question_id is the SAME stable `q1-` id the
    pipeline computes (reused from vision_review.parse_rubric_questions, never
    re-implemented, so the ids join exactly). A verdict-"no" answer that cites a
    resolvable region + bbox is turned by the pipeline into a grounded
    `rubric_answer_no` quarantine finding; every valid answer marks its question
    addressed in the rubric_coverage ledger.
  * findings[] -- the COMPOSITE deterministic sidecar-consistency pass, so the
    reviewer-cmd path never loses the coded coverage (see below). Model defects
    are NOT also emitted here -- they flow through verdict-"no" answers -- so a
    defect is never double-counted.

WITNESS vs ORACLE (the named terminal-hazard guardrail): the VLM answers the
rubric JUDGMENT questions ("sprite a single clean frame?", "anything an
untextured blob?", "world uniformly dimmed?", "text clipped?") that no coded
class can express -- the 13/19 an art anchor is structurally blind to. It is NOT
asked to measure sub-pixel offsets: an 11px misalignment is the art-anchor
layer's job (G1), because a VLM downscales to a pixel budget and may not resolve
it. Model output is quarantine-FOREVER and must never be promoted to red/blocking;
only byte-derived anchors graduate.

COMPOSITE DESIGN (why degrade lives HERE, not in the pipeline): vision_review's
_run_cmd_reviewer is FAIL-CLOSED by contract -- a plugin that exits non-zero,
times out, or returns invalid JSON / non-list findings-or-answers is a tool error
(exit 2), and the deterministic default runs ONLY when no --reviewer-cmd is
configured. So when this plugin is configured, IT owns coverage: it ALWAYS runs
the deterministic sidecar-consistency pass (importlib-loading vision_review and
calling default_reviewer over the on-disk sidecars -- the sanctioned _load
pattern, not a fork) and ADDS the model pass only when the model is POSITIVELY
available. On positive unavailability (server down, model not pulled, connect
refused, per-call timeout) it records the reason in reviewer_meta, emits the
deterministic findings, prints a skipped note, and exits 0 -- a recorded degrade,
never a silent fallback and never a red run. Genuine wrapper breakage (malformed
stdin, an unexpected exception in THIS code) stays non-zero so the pipeline's
fail-closed contract is preserved.

DISCIPLINE (honoring the recorded reviewer_params {temperature 0, n:2 unanimity,
order_shuffle:true}, enforced wrapper-side because the pipeline calls a plugin
once and trusts it to spend the vote): temperature 0; n=2 = TWO separate
/api/chat calls whose answers are intersected for unanimity (a "no" finding needs
every configured pass to emit the same question_id+verdict -- an unparseable pass
votes ABSENT and blocks the "no", so unanimity never silently degrades to n=1; an
agreed "yes" from the completed passes only marks coverage, never a finding);
before/after Set-of-Mark frame order shuffled per pass
under a recorded seed (answers cite a stable question_id + region_id, so nothing
positional needs mapping back). HONEST RECORDING: at strict temperature 0 the two
calls are identical greedy decodes, so n=2 is a DETERMINISM/REPRO GUARD, not an
independent vote -- reviewer_meta says exactly that; set VLM_INDEPENDENT_VOTE=1
for temperature 0.2 + two distinct seeds (a real two-sample vote), off by
default.

RUNTIME (default `auto`): "Qwen 3.8" is served by the user's token plan as
`qwen3.8-max-preview` (a REASONING model) via the OpenAI-compatible token-plan
MaaS endpoint (DEFAULT_DASHSCOPE_BASE) -- PRIMARY when DASHSCOPE_API_KEY is set
(env only, NEVER logged); else local qwen3-vl:8b (Instruct) via Ollama's HTTP
API when pulled (verified on this box: ollama 0.31.2 live on :11434, 24GB);
else a RECORDED degrade to the deterministic default. The wrapper is PURE
STDLIB (urllib.request + json + base64; NO SDK, NO venv) and stays a CORE tool:
OPTIONAL_TOOL_EXEMPTIONS remains pinned to exactly {vision_metrics.py}. An
explicit model id is pinned, never `latest`. Hosted calls budget max_tokens=
4096 (the reasoning trace spends completion tokens) at a 180s per-call timeout,
and the endpoint rejects images with a side <=10px, so sub-11px crops are
dropped (full frames + SoM overlays always go). Ollama's grammar-constrained
`format=<schema>` guarantees output SHAPE (one defensive validate/repair
retry); the hosted path is prompt-instructed JSON so validate+repair is
mandatory there. The per-call timeout (VLM_TIMEOUT, default 180) bounds each
HTTP call; the pipeline's REVIEWER_TIMEOUT=300 bounds the whole plugin
invocation. The worst case (probe 5s + n=2 + a repair retry per pass) can
exceed the outer bound under a slow model -- the outer bound then kills the
invocation and the pipeline records a TOOL ERROR (fail-closed, never a silent
pass); for slow endpoints raise VLM_TIMEOUT and REVIEWER_TIMEOUT together.

Stdlib-only. Reuses vision_review.default_reviewer / parse_rubric_questions /
_shot_group via the sanctioned importlib pattern (never forked); geometry stays
the pipeline's single home (visual_explain.rects_overlap), never re-implemented.
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import random
import sys
import urllib.error
import urllib.request

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent

SCHEMA = "vision-review/2"
REVIEWER_KIND = "model-qwen3-vl"        # must equal vision_review.KIND_MODEL so coverage joins
DEFAULT_MODEL = "qwen3-vl:8b"           # "Qwen 3.8" -> Qwen3-VL 8B Instruct (explicit tag, never latest)
FALLBACK_MODEL = "qwen3-vl:4b"          # faster / lower-fidelity lane or memory contention
DEFAULT_OLLAMA_HOST = "http://127.0.0.1:11434"
DEFAULT_DASHSCOPE_BASE = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
DEFAULT_DASHSCOPE_MODEL = "qwen3.8-max-preview"
DEFAULT_TIMEOUT = 180                   # per call; reasoning models spend tokens thinking (keep headroom; < REVIEWER_TIMEOUT=300)
PROBE_TIMEOUT = 5
MAX_CROPS = 6                           # bound image tokens; native-res crops carry the small-diff signal
MAX_TEXT = 1600                         # cap embedded text blocks so a large bundle cannot blow the context
RUBRIC_REF = "docs/references/vision-review-rubric.md"

EXIT_OK, EXIT_ERROR = 0, 2

# JSON schema the model must return (per-question answers). Grammar-constrained
# on Ollama (guaranteed shape); prompt-instructed on DashScope (validated +
# repaired). bbox is NOT requested: the pipeline owns geometry -- the model cites
# a region_id and this wrapper sets bbox to that region's rect.
MODEL_SCHEMA = {
    "type": "object",
    "properties": {
        "answers": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "question_id": {"type": "string"},
                    "verdict": {"type": "string", "enum": ["yes", "no"]},
                    "region_id": {"type": "string"},
                    "note": {"type": "string"},
                    "explanation": {"type": "string"},
                },
                "required": ["question_id", "verdict", "note"],
            },
        }
    },
    "required": ["answers"],
}


# --------------------------------------------------------------------------
# config (env + flags; flags win over env)
# --------------------------------------------------------------------------
class Config:
    def __init__(self, args: argparse.Namespace):
        def pick(flag, env, default):
            val = getattr(args, flag, None)
            if val not in (None, ""):
                return val
            val = os.environ.get(env)
            return val if val not in (None, "") else default

        self.runtime = str(pick("runtime", "VLM_RUNTIME", "auto")).lower()
        self.model = str(pick("model", "VLM_MODEL", DEFAULT_MODEL))
        self.ollama_host = str(pick("ollama_host", "OLLAMA_HOST", DEFAULT_OLLAMA_HOST)).rstrip("/")
        self.dashscope_base = str(pick("dashscope_base", "DASHSCOPE_BASE_URL", DEFAULT_DASHSCOPE_BASE)).rstrip("/")
        self.dashscope_model = str(pick("dashscope_model", "DASHSCOPE_MODEL", DEFAULT_DASHSCOPE_MODEL))
        # SECRET: env only, never logged. Only a presence bool is recorded.
        self.dashscope_key = os.environ.get("DASHSCOPE_API_KEY", "")
        self.timeout = int(pick("timeout", "VLM_TIMEOUT", DEFAULT_TIMEOUT))
        self.base_dir = Path(pick("base_dir", "VISION_REVIEW_BASE_DIR", str(ROOT / ".godot-smoke")))
        self.baseline_dir = Path(pick("baseline_dir", "VLM_BASELINE_DIR",
                                      str(ROOT / "docs" / "generated" / "visual-baselines")))
        self.shots_dir = Path(pick("shots_dir", "VLM_SHOTS_DIR", str(ROOT / ".godot-smoke" / "shots")))
        self.seed = int(pick("seed", "VLM_SEED", 1234))
        self.no_model = bool(getattr(args, "no_model", False)) or os.environ.get("VLM_NO_MODEL") == "1"
        self.independent_vote = (bool(getattr(args, "independent_vote", False))
                                 or os.environ.get("VLM_INDEPENDENT_VOTE") == "1")
        self.send_raw_frames = os.environ.get("VLM_SEND_RAW_FRAMES") == "1"
        self.n = 2  # recorded discipline: two passes, unanimity vote

    def describe(self) -> dict:
        """reviewer_meta config block. NEVER includes secret values."""
        return {
            "runtime": self.runtime, "model": self.model, "ollama_host": self.ollama_host,
            "dashscope_base": self.dashscope_base, "dashscope_model": self.dashscope_model,
            "dashscope_key_present": bool(self.dashscope_key),  # presence only, never the value
            "temperature": 0.2 if self.independent_vote else 0,
            "n": self.n,
            "vote": "both-passes-must-emit (unanimity)",
            "vote_semantics": ("independent two-sample vote (temperature 0.2, two seeds)"
                               if self.independent_vote else
                               "determinism/repro guard (two identical greedy decodes at temperature 0)"),
            "order_shuffle": True, "per_call_timeout_s": self.timeout,
            "pixel_budget_note": "Qwen min/max_pixels is a model/server setting, not a per-request "
                                 "option; native-res crops carry the small-diff signal; crops with a "
                                 "side < 11px are dropped (the hosted endpoint rejects <=10px images)",
            "reviewer_kind": REVIEWER_KIND,
        }


# --------------------------------------------------------------------------
# sanctioned importlib load of the lane owner (never forked)
# --------------------------------------------------------------------------
_VISION_REVIEW = None


def _load_vision_review():
    global _VISION_REVIEW
    if _VISION_REVIEW is None:
        spec = importlib.util.spec_from_file_location("vision_review", TOOLS / "vision_review.py")
        if spec is None or spec.loader is None:
            raise RuntimeError("cannot load vision_review")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _VISION_REVIEW = module
    return _VISION_REVIEW


# --------------------------------------------------------------------------
# deterministic composite pass (always runs; best-effort, never fatal)
# --------------------------------------------------------------------------
def _read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def deterministic_findings(public_ctx: dict, cfg: Config) -> tuple[list[dict], str, list, bool]:
    """Run vision_review.default_reviewer over the on-disk sidecars so the
    reviewer-cmd path never loses the deterministic coverage. The public stdin
    ctx lacks the raw sidecars, so they are read from the known baseline/shots
    dirs (same layout apply_vision_review uses). Best-effort: a missing sidecar
    or a load error yields zero findings + a recorded note, never a failure.

    Returns (findings, note, anchor_unverified, anchor_kind_ran): the art-anchor
    class records, in the ctx, anchored entries it could not verify (each tagged
    with its own cause -- "anchor meta unavailable" vs "node absent from
    draw_order") -- surfaced in reviewer_meta + a stderr note for parity with the
    default lane's warning (counted, never a finding). anchor_kind_ran is True
    iff the stage-to-stage comparison actually executed (the region-table entries
    carried usable anchor meta) -- the wrapper declares deterministic-art-anchor
    in kinds_ran only on that condition, never for a comparison that never ran."""
    shot = public_ctx.get("shot")
    if not shot:
        return [], "no shot in bundle", [], False
    try:
        vr = _load_vision_review()
        base = _read_json(cfg.baseline_dir / (shot + ".sidecar.json"))
        fresh = _read_json(cfg.shots_dir / (shot + ".sidecar.json"))
        if base is None and fresh is None:
            return [], "sidecars not found (deterministic pass skipped)", [], False
        ctx = {"shot": shot,
               "region_table": public_ctx.get("region_table") or {},
               "clusters": public_ctx.get("clusters") or [],
               # the SAME documented default-capture fallback default_reviewer
               # uses -- the anchor bbox stage->display mapping must agree with
               # the region table the pipeline mapped with the real window, or
               # a grounded drift finding can fail rects_overlap and drop.
               "window": public_ctx.get("window") or [1152, 648],
               "baseline_sidecar": base, "fresh_sidecar": fresh}
        findings = vr.default_reviewer(ctx)
        return (findings, "ok", list(ctx.get("anchor_unverified") or []),
                bool(ctx.get("anchor_kind_ran")))
    except Exception as exc:  # the composite must never take the pipeline down
        return [], f"deterministic pass error: {type(exc).__name__}: {exc}", [], False


# --------------------------------------------------------------------------
# rubric question inventory (reused from vision_review; ids join exactly)
# --------------------------------------------------------------------------
def load_questions(public_ctx: dict) -> tuple[str, list[dict]]:
    """Return (group_key, [{id, text}]) for the shot's rubric group, using
    vision_review's OWN parser + id scheme so the answer question_ids match the
    pipeline's coverage ledger exactly. Reads the full rubric (same file the
    pipeline reads). Best-effort: ('', []) if unavailable."""
    shot = public_ctx.get("shot", "")
    try:
        vr = _load_vision_review()
        group = vr._shot_group(shot)
        if not group:
            return "", []
        rubric_path = ROOT / RUBRIC_REF
        text = rubric_path.read_text(encoding="utf-8") if rubric_path.exists() else ""
        inventory = vr.parse_rubric_questions(text)
        return group, inventory.get(group, [])
    except Exception:
        return "", []


# --------------------------------------------------------------------------
# model availability probes (POSITIVE detection only)
# --------------------------------------------------------------------------
def _model_in_tags(host: str, model: str) -> tuple[bool, str]:
    """True iff GET /api/tags succeeds AND lists `model` (exact, or same
    name:tag ignoring an implicit :latest). Positive detection only -- a probe
    error is treated as UNavailable so degrade is the safe default."""
    try:
        req = urllib.request.Request(host + "/api/tags", headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT) as resp:
            doc = json.loads(resp.read().decode("utf-8"))
    except (OSError, ValueError, urllib.error.URLError) as exc:
        return False, f"ollama probe failed: {type(exc).__name__}"
    names = [str(m.get("name", "")) for m in doc.get("models", []) if isinstance(m, dict)]
    if model in names:
        return True, "model present"
    bare = model.split(":")[0]  # tolerate an implicit :latest on either side
    for name in names:
        if name == model or name.split(":")[0] == bare:
            return True, "model present"
    return False, f"model {model} not pulled (have: {', '.join(names) or 'none'})"


def probe_availability(cfg: Config) -> tuple[str | None, str]:
    """Resolve the active backend. Returns (backend, reason); backend is None
    when no model is positively available (-> deterministic-only degrade)."""
    ollama_reason = "ollama not probed"
    if cfg.runtime in ("ollama", "auto"):
        ok, reason = _model_in_tags(cfg.ollama_host, cfg.model)
        if ok:
            return "ollama", reason
        ollama_reason = reason
        if cfg.runtime == "ollama":
            return None, ollama_reason
    if cfg.runtime in ("dashscope", "auto"):
        if cfg.dashscope_key:
            return "dashscope", "dashscope key present"
        dash_reason = "no DASHSCOPE_API_KEY (degrade-only)"
        if cfg.runtime == "dashscope":
            return None, dash_reason
        return None, f"{ollama_reason}; {dash_reason}"
    return None, f"unknown runtime {cfg.runtime!r}"


# --------------------------------------------------------------------------
# bundle reading + prompt construction
# --------------------------------------------------------------------------
def _abs(cfg: Config, rel: str) -> Path:
    p = Path(rel)
    return p if p.is_absolute() else cfg.base_dir / rel


def _b64(path: Path) -> str | None:
    try:
        return base64.b64encode(path.read_bytes()).decode("ascii")
    except OSError:
        return None


def _region_catalog(public_ctx: dict) -> tuple[str, list[str]]:
    """Render the groundable region catalog (mark -> region_id/kind/rect) the
    model must cite from, plus the ordered list of valid region_ids."""
    table = public_ctx.get("region_table") or {}
    legend = public_ctx.get("som_legend") or {}
    lines, valid = [], []
    for rid, entry in sorted(table.items(), key=lambda kv: (legend.get(kv[0], 999), kv[0])):
        rects = entry.get("rects") or []
        if not rects:
            continue
        valid.append(rid)
        mark = legend.get(rid)
        mark_txt = f"mark {mark}" if mark is not None else "no mark"
        lines.append(f"- {mark_txt} -> region_id \"{rid}\" (kind {entry.get('kind')}, "
                     f"source {entry.get('source')}, rect {rects[0]})")
    return "\n".join(lines) or "(no groundable regions for this shot)", valid


def _expected_strings_summary(cfg: Config, public_ctx: dict) -> str:
    doc = _read_json(_abs(cfg, (public_ctx.get("paths") or {}).get("expected_strings", "")))
    if not isinstance(doc, dict):
        return ""
    labels = [str(l.get("text")) for l in doc.get("labels", []) if isinstance(l, dict) and l.get("text")]
    strings = [str(s.get("text")) for s in doc.get("strings", []) if isinstance(s, dict) and s.get("text")]
    parts = []
    if labels:
        parts.append("labels: " + ", ".join(labels[:24]))
    if strings:
        parts.append("anchor strings: " + ", ".join(strings[:24]))
    return " | ".join(parts)[:MAX_TEXT]


def _question_lines(questions: list[dict]) -> str:
    return "\n".join(f"- {q['id']}: {q['text']}" for q in questions) or "(no rubric questions parsed)"


def build_system_prompt(public_ctx: dict, catalog: str, questions: list[dict]) -> str:
    shot = public_ctx.get("shot", "?")
    grounding = public_ctx.get("grounding_rules") or {}
    return (
        "You are a pixel-art visual-fidelity reviewer for a Game Boy Color-style Pokemon "
        "game (160x144 stage, integer-scaled to the capture window). You receive a BASE "
        "(baseline/before) and a FRESH (current/after) capture of shot '%s' as numbered "
        "Set-of-Mark overlays plus native-resolution base|fresh crops of every changed region.\n\n"
        "WITNESS, NOT ORACLE: you answer JUDGMENT questions only -- is anything an untextured "
        "blob, a garbled glyph, a sprite strip-bleed, an uneven dim, clipped text, a prop "
        "floating off its tile? Do NOT try to measure pixel offsets or exact alignment; a "
        "deterministic art-anchor layer owns sub-pixel geometry and a vision model downscales "
        "to a pixel budget, so an N-px offset is not yours to call. Report only what you can "
        "actually SEE in the frames.\n\n"
        "ANSWER EVERY RUBRIC QUESTION BELOW by its id, verdict 'yes' (no defect) or 'no' "
        "(defect present). For a 'no', cite the single most relevant region_id (or its mark "
        "number) from the catalog.\n%s\n\n"
        "GROUNDING (mandatory for a 'no'): cite ONLY a region_id from this catalog -- the only "
        "regions that exist for this shot. Numbers drawn on the Set-of-Mark overlays are the "
        "'mark N' labels below; you may cite the region_id or its mark number.\n%s\n\n"
        "Grounding rules from the pipeline: %s\n\n"
        "DISCIPLINE: when unsure, answer 'yes' (findings are quarantine-tier, but false "
        "positives are costly noise). Answer every question exactly once.\n\n"
        "OUTPUT: return ONLY a JSON object matching this schema (no prose, no markdown fences):\n"
        "{\"answers\": [{\"question_id\": <one of the ids above>, \"verdict\": \"yes\"|\"no\", "
        "\"region_id\": <catalog region_id or mark number, only for a 'no'>, "
        "\"note\": <10-word summary>, \"explanation\": <one sentence citing the visible evidence>}]}\n"
        % (shot, _question_lines(questions), catalog, json.dumps(grounding, sort_keys=True))
    )


def build_user_content(cfg: Config, public_ctx: dict, order: list[str]) -> tuple[str, list[str], list[str]]:
    """Returns (user_text, image_b64_list, image_labels). The before/after SoM
    frames are emitted in `order` (shuffled per pass) and LABELED correctly so
    the model knows which is which regardless of physical position."""
    paths = public_ctx.get("paths") or {}
    clusters = public_ctx.get("clusters") or []
    expected = _expected_strings_summary(cfg, public_ctx)
    sidecar_deltas = ""
    context_doc = _read_json(_abs(cfg, paths.get("context", ""))) if paths.get("context") else None
    if isinstance(context_doc, dict):
        sd = context_doc.get("sidecar_deltas") or []
        if sd:
            sidecar_deltas = "Sidecar deltas (coded change summary): " + "; ".join(str(x) for x in sd[:8])

    images: list[str] = []
    labels: list[str] = []
    role = {"before": "BASE (baseline/before)", "after": "FRESH (current/after)"}
    som_key = {"before": paths.get("som_before"), "after": paths.get("som_after")}
    for which in order:  # shuffled before/after order, correctly labeled
        rel = som_key.get(which)
        if rel:
            b = _b64(_abs(cfg, rel))
            if b:
                images.append(b)
                labels.append(f"Image {len(images)}: {role[which]} full-frame Set-of-Mark overlay "
                              f"(regions outlined + numbered; see catalog for mark->region_id).")
    if cfg.send_raw_frames:
        raw_key = {"before": paths.get("before"), "after": paths.get("after")}
        for which in order:
            rel = raw_key.get(which)
            if rel:
                b = _b64(_abs(cfg, rel))
                if b:
                    images.append(b)
                    labels.append(f"Image {len(images)}: {role[which]} raw full frame (no overlay).")
    for rel in (paths.get("crops") or [])[:MAX_CROPS]:
        b = _b64(_abs(cfg, rel))
        if b:
            images.append(b)
            labels.append(f"Image {len(images)}: native-resolution base|fresh twin crop of a changed "
                          f"region (BASE on the left, FRESH on the right).")

    cluster_txt = ""
    if clusters:
        rows = [f"bbox {c.get('bbox')} ({c.get('changed', 0)} px)" for c in clusters[:8]
                if isinstance(c, dict)]
        if rows:
            cluster_txt = "Changed regions: " + "; ".join(rows) + "."

    user_text = (
        "Shot %s (kind %s, window %s). Compare BASE vs FRESH and answer each rubric question by id.\n"
        "%s\n%s\n%s\n\n"
        "Images, in order:\n%s\n\n"
        "Return {\"answers\": [...]} with one entry per rubric question; a 'no' cites a catalog "
        "region_id (or mark). If every question answers 'yes', still return one 'yes' answer per "
        "question."
        % (public_ctx.get("shot", "?"), public_ctx.get("shot_kind", "?"),
           public_ctx.get("window"),
           ("Expected text that SHOULD read cleanly: " + expected) if expected else "",
           sidecar_deltas, cluster_txt,
           "\n".join(f"- {l}" for l in labels) or "(no images available)")
    )
    return user_text, images, labels


# --------------------------------------------------------------------------
# HTTP dispatch (stdlib urllib only)
# --------------------------------------------------------------------------
def _post_json(url: str, body: dict, headers: dict, timeout: int) -> dict:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


# Hosted vision endpoints reject tiny images (the token-plan endpoint refuses
# any side <= 10px). Native-res cluster crops of very small clusters can fall
# under that; drop them rather than 400 the whole call (the full frames + SoM
# overlays always go, so the region stays visible; the crop only adds detail).
_MIN_IMAGE_SIDE = 11


def _png_sides(b64: str):
    """(width, height) from the PNG header bytes, or None if unparseable."""
    try:
        head = base64.b64decode(b64[:40])
    except Exception:
        return None
    if head[:8] != b"\x89PNG\r\n\x1a\n" or len(head) < 24:
        return None
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def _images_above_minimum(images: list) -> list:
    kept = []
    for b in images:
        dims = _png_sides(b)
        if dims is None or (dims[0] >= _MIN_IMAGE_SIDE and dims[1] >= _MIN_IMAGE_SIDE):
            kept.append(b)  # unparseable header: keep and let the server judge
    return kept


def _call_ollama(cfg: Config, system: str, user_text: str, images: list[str],
                 temperature: float, seed: int) -> str:
    images = _images_above_minimum(images)
    user_msg = {"role": "user", "content": user_text}
    if images:
        user_msg["images"] = images  # Ollama wants raw base64 strings (no data: prefix)
    body = {
        "model": cfg.model, "stream": False, "format": MODEL_SCHEMA,
        "options": {"temperature": temperature, "num_predict": 1024, "seed": seed},
        "messages": [{"role": "system", "content": system}, user_msg],
    }
    doc = _post_json(cfg.ollama_host + "/api/chat", body, {}, cfg.timeout)
    return str((doc.get("message") or {}).get("content", ""))


def _call_dashscope(cfg: Config, system: str, user_text: str, images: list[str],
                    temperature: float, seed: int) -> str:
    images = _images_above_minimum(images)
    content = [{"type": "text", "text": user_text}]
    for b in images:
        content.append({"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b}"}})
    body = {
        "model": cfg.dashscope_model, "temperature": temperature, "seed": seed,
        # Reasoning models (qwen3.8-max-preview) spend completion tokens thinking;
        # 4096 leaves headroom for the reasoning trace + the JSON answer.
        "max_tokens": 4096,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": content}],
    }
    doc = _post_json(cfg.dashscope_base + "/chat/completions", body,
                     {"Authorization": f"Bearer {cfg.dashscope_key}"}, cfg.timeout)
    choices = doc.get("choices") or []
    msg = (choices[0] or {}).get("message") if choices else {}
    c = (msg or {}).get("content", "")
    if isinstance(c, list):  # some servers return content parts
        c = "".join(part.get("text", "") for part in c if isinstance(part, dict))
    return str(c)


def _call_model(cfg: Config, backend: str, system: str, user_text: str,
                images: list[str], temperature: float, seed: int) -> str:
    if backend == "ollama":
        return _call_ollama(cfg, system, user_text, images, temperature, seed)
    return _call_dashscope(cfg, system, user_text, images, temperature, seed)


# --------------------------------------------------------------------------
# structured-output parse + one repair retry
# --------------------------------------------------------------------------
def _extract_json(text: str):
    """Strip markdown fences and locate the first balanced JSON object."""
    text = text.strip()
    if text.startswith("```"):
        text = text.split("```", 2)[1]
        if text.startswith("json"):
            text = text[4:]
        text = text.rsplit("```", 1)[0]
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("no JSON object found")
    return json.loads(text[start:end + 1])


def _parse_with_repair(cfg: Config, backend: str, system: str, user_text: str,
                       images: list[str], temperature: float, seed: int,
                       content: str) -> tuple[dict | None, str]:
    try:
        doc = _extract_json(content)
        if isinstance(doc, dict) and isinstance(doc.get("answers"), list):
            return doc, "ok"
        return None, "answers not a list"
    except (ValueError, KeyError) as exc:
        first_err = exc
    # ONE repair retry (mandatory on the prompt-instructed DashScope path; a
    # defensive backstop on the grammar-constrained Ollama path).
    repair_system = (system + "\n\nYour last reply was not valid JSON matching the schema. "
                     "Return ONLY the JSON object now. Error: %s" % first_err)
    try:
        content2 = _call_model(cfg, backend, repair_system, user_text, images, temperature, seed + 7919)
        doc = _extract_json(content2)
        if isinstance(doc, dict) and isinstance(doc.get("answers"), list):
            return doc, "repaired"
        return None, f"unparseable after repair: {first_err}"
    except (ValueError, KeyError, OSError, urllib.error.URLError) as exc2:
        return None, f"unparseable after repair: {first_err} / {type(exc2).__name__}"


# --------------------------------------------------------------------------
# answer normalization + n=2 unanimity
# --------------------------------------------------------------------------
def _resolve_region(rid, public_ctx: dict, valid: list[str]) -> tuple[str | None, list[int] | None]:
    """Resolve a cited region (region_id or a mark number via som_legend) to a
    (region_id, bbox) where bbox is that region's own rect -> guaranteed
    rects_overlap + in-frame. Returns (None, None) when unresolvable."""
    legend = public_ctx.get("som_legend") or {}
    table = public_ctx.get("region_table") or {}
    if isinstance(rid, bool):
        return None, None
    if isinstance(rid, int) or (isinstance(rid, str) and rid.strip().isdigit()):
        mark = int(rid)
        rid = next((r for r, m in legend.items() if m == mark), None)
        if rid is None:
            return None, None
    if not isinstance(rid, str) or rid not in valid:
        return None, None
    rects = table.get(rid, {}).get("rects") or []
    if not rects:
        return None, None
    try:
        bbox = [int(rects[0][0]), int(rects[0][1]), int(rects[0][2]), int(rects[0][3])]
    except (TypeError, ValueError, IndexError):
        return None, None
    if bbox[2] <= 0 or bbox[3] <= 0:
        return None, None
    return rid, bbox


def _normalize_answer(raw, public_ctx: dict, question_ids: set[str],
                      valid: list[str]) -> tuple[dict | None, str]:
    """Map one model answer to a pipeline-ready rubric answer. verdict yes/no;
    question_id must be one of the shot's parsed question ids (so it joins the
    coverage ledger); a 'no' resolves its region to region_id + bbox so the
    pipeline can ground the rubric_answer_no finding it creates."""
    if not isinstance(raw, dict):
        return None, "not_object"
    qid = raw.get("question_id")
    if not isinstance(qid, str) or qid not in question_ids:
        return None, "unknown_question_id"
    verdict = raw.get("verdict")
    if verdict not in ("yes", "no"):
        return None, "bad_verdict"
    note = str(raw.get("note") or "")[:200]
    explanation = str(raw.get("explanation") or note)[:600]
    answer = {"question_id": qid, "verdict": verdict, "reviewer_kind": REVIEWER_KIND,
              "note": note or f"rubric {qid}: {verdict}", "explanation": explanation}
    if verdict == "no":
        rid, bbox = _resolve_region(raw.get("region_id"), public_ctx, valid)
        if rid is not None:
            answer["region_id"] = rid
            answer["bbox"] = bbox
        # a 'no' without a resolvable region is still a valid, counted answer
        # (marks the question addressed) but generates no finding pipeline-side.
    return answer, None


def _normalize_pass(doc: dict, public_ctx: dict, question_ids: set[str],
                    valid: list[str]) -> tuple[list[dict], dict]:
    answers, drops, reasons, seen = [], 0, {}, set()
    for raw in doc.get("answers") or []:
        answer, reason = _normalize_answer(raw, public_ctx, question_ids, valid)
        if answer is None:
            drops += 1
            reasons[reason] = reasons.get(reason, 0) + 1
            continue
        if answer["question_id"] in seen:  # one answer per question
            drops += 1
            reasons["duplicate_question"] = reasons.get("duplicate_question", 0) + 1
            continue
        seen.add(answer["question_id"])
        answers.append(answer)
    return answers, {"dropped": drops, "drop_reasons": reasons}


def _unanimous(passes: list[list[dict]], required: int | None = None) -> tuple[list[dict], dict]:
    """Keep only answers the passes agree on (identity = question_id+verdict); the
    canonical copy is pass-1's. `required` is the CONFIGURED pass count (cfg.n): an
    UNPARSEABLE/absent pass counts as a DISAGREEING vote, so a 'no' finding -- which
    becomes a quarantine finding -- needs every configured pass to emit the same
    (qid, no); with one pass missing, NO 'no' can reach unanimity (conservative:
    never a finding on a single witness). 'yes' answers create no finding, they only
    mark a question addressed, so the COMPLETED passes' agreed 'yes' is kept even
    when a twin failed (coverage is counted from a real answer, never faked).
    Records the vote arithmetic honestly (passes completed vs required)."""
    completed = len(passes)
    need = required if (required is not None and required > completed) else completed
    if not passes:
        return [], {"kept": 0, "distinct_answers": 0, "passes": 0,
                    "required": need, "failed_passes": need}

    def identity(a: dict) -> tuple:
        return (a["question_id"], a["verdict"])

    counts: dict[tuple, int] = {}
    for p in passes:
        for k in {identity(a) for a in p}:
            counts[k] = counts.get(k, 0) + 1
    # Every COMPLETED pass must agree (c == completed), AND a 'no' additionally
    # needs the full configured count (completed == need) -- an absent twin is a
    # disagreeing vote. When completed passes disagree on a question (yes in one,
    # no in the other), neither identity reaches c == completed, so the 'no' is
    # dropped (conservative: no finding) and the question isn't in the answers.
    keep = {k for k, c in counts.items()
            if c == completed and (k[1] != "no" or completed == need)}
    out, seen = [], set()
    for a in passes[0]:
        k = identity(a)
        if k in keep and a["question_id"] not in seen:
            seen.add(a["question_id"])
            out.append(a)
    return out, {"kept": len(out), "distinct_answers": len(counts), "passes": completed,
                 "required": need, "failed_passes": need - completed}


# --------------------------------------------------------------------------
# the model pass (n=2 + shuffle); never raises into the pipeline
# --------------------------------------------------------------------------
def run_model(public_ctx: dict, cfg: Config, backend: str) -> tuple[list[dict], dict]:
    group, questions = load_questions(public_ctx)
    catalog, valid = _region_catalog(public_ctx)
    if not questions:
        return [], {"ran": False, "reason": "no rubric questions parsed for this shot's group"}
    question_ids = {q["id"] for q in questions}
    if not valid:
        # No groundable regions: the model can still answer yes/no, but a 'no'
        # cannot ground a finding. Proceed -- answers still mark questions covered.
        catalog = catalog or "(no groundable regions; 'no' answers cannot ground a finding)"

    system = build_system_prompt(public_ctx, catalog, questions)
    temperature = 0.2 if cfg.independent_vote else 0.0
    passes: list[list[dict]] = []
    per_pass: list[dict] = []
    for i in range(cfg.n):
        rng = random.Random(cfg.seed + i)  # per-pass order seed, recorded
        order = ["before", "after"]
        rng.shuffle(order)
        seed = (cfg.seed * 1000 + i * 17) if cfg.independent_vote else cfg.seed
        user_text, images, _labels = build_user_content(cfg, public_ctx, order)
        content = _call_model(cfg, backend, system, user_text, images, temperature, seed)
        doc, parse_note = _parse_with_repair(cfg, backend, system, user_text, images,
                                             temperature, seed, content)
        if doc is None:
            per_pass.append({"pass": i, "order": order, "parse": parse_note, "answers": 0})
            # an unparseable pass votes ABSENT: it is never added to `passes`, and
            # _unanimous counts it against `required` (cfg.n) -- so its missing vote
            # BLOCKS every 'no' (a no finding needs all configured passes to agree)
            # while a surviving agreed 'yes' still marks coverage. Unanimity never
            # silently degrades to n=1 for findings.
            continue
        answers, norm = _normalize_pass(doc, public_ctx, question_ids, valid)
        passes.append(answers)
        per_pass.append({"pass": i, "order": order, "parse": parse_note,
                         "answers": len(answers), **norm})

    unanimous, vote = _unanimous(passes, required=cfg.n)
    meta = {"ran": True, "backend": backend, "model": cfg.model, "group": group,
            "temperature": temperature, "n": cfg.n, "passes_completed": len(passes),
            "questions_total": len(questions), "per_pass": per_pass, "vote": vote,
            "vote_semantics": ("independent two-sample vote" if cfg.independent_vote
                               else "determinism/repro guard (identical greedy decodes at temperature 0)")}
    return unanimous, meta


# --------------------------------------------------------------------------
# orchestration
# --------------------------------------------------------------------------
def run_review(public_ctx: dict, cfg: Config) -> tuple[list[dict], list[dict], dict]:
    meta: dict = {"schema": SCHEMA, "generated_by": "tools/vlm_reviewer.py",
                  "config": cfg.describe()}

    det_findings, det_note, anchor_unverified, anchor_kind_ran = deterministic_findings(public_ctx, cfg)
    meta["deterministic"] = {"count": len(det_findings), "note": det_note,
                             "reviewer_kind": "deterministic-sidecar-consistency"}
    if anchor_unverified:
        # Parity with the default lane: anchored entries this sidecar cannot
        # verify are counted, never a finding. Each entry carries its OWN cause
        # ("anchor meta unavailable" vs "node absent from draw_order") -- the
        # note never hardcodes a cause the entry did not establish.
        meta["deterministic"]["anchor_unverified"] = anchor_unverified
        print("vlm_reviewer: art-anchor live-unverified (counted, never a finding): %s"
              % "; ".join(anchor_unverified), file=sys.stderr)

    answers: list[dict] = []
    if cfg.no_model:
        meta["model"] = {"ran": False, "reason": "disabled (--no-model / VLM_NO_MODEL)"}
    else:
        backend, reason = probe_availability(cfg)
        if backend is None:
            meta["model"] = {"ran": False, "reason": reason}
            print(f"vlm_reviewer: model unavailable ({reason}); deterministic pass only",
                  file=sys.stderr)
        else:
            try:
                answers, mmeta = run_model(public_ctx, cfg, backend)
                meta["model"] = mmeta
            except Exception as exc:  # the model NEVER takes the pipeline down
                answers = []
                meta["model"] = {"ran": False,
                                 "reason": f"model pass error: {type(exc).__name__}: {exc}"}
                print(f"vlm_reviewer: model pass error ({exc}); deterministic pass only",
                      file=sys.stderr)

    meta["totals"] = {"deterministic_findings": len(det_findings),
                      "model_answers": len(answers),
                      "model_no_verdicts": sum(1 for a in answers if a["verdict"] == "no")}
    # kinds_ran — the composite contract with vision_review._run_cmd_reviewer
    # (it reads reviewer_meta.kinds_ran and folds the declared kinds into the
    # rubric-coverage ledger's RAN set): the deterministic sidecar-consistency
    # pass ALWAYS runs in this wrapper, so it is always declared — that is how
    # the composite registers its internal coded coverage even when nothing
    # self-tags a finding; deterministic-art-anchor is declared ONLY when the
    # stage-to-stage anchor comparison actually executed (anchor_kind_ran: the
    # region-table entries carried usable anchor meta — a comparison that never
    # ran must not credit the ledger); model-qwen3-vl is declared only when it
    # actually RAN (a positive-unavailable model is NOT a ran kind — the degrade
    # reason stays recorded in meta["model"]). Malformed entries are ignored
    # pipeline-side, so this list is the honest ran/kind join, never faked coverage.
    kinds_ran = ["deterministic-sidecar-consistency"]
    if anchor_kind_ran:
        kinds_ran.append("deterministic-art-anchor")
    if meta.get("model", {}).get("ran"):
        kinds_ran.append("model-qwen3-vl")
    meta["kinds_ran"] = kinds_ran
    meta["deterministic"]["anchor_kind_ran"] = anchor_kind_ran
    return det_findings, answers, meta


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------
def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runtime", choices=["ollama", "dashscope", "auto"], default=None,
                        help="model backend (default: env VLM_RUNTIME or auto: local Ollama if the model is pulled, else hosted when DASHSCOPE_API_KEY is set)")
    parser.add_argument("--model", default=None,
                        help=f"Ollama model tag, pinned explicit (default: env VLM_MODEL or {DEFAULT_MODEL})")
    parser.add_argument("--ollama-host", dest="ollama_host", default=None,
                        help=f"Ollama base URL (default: env OLLAMA_HOST or {DEFAULT_OLLAMA_HOST})")
    parser.add_argument("--dashscope-base", dest="dashscope_base", default=None,
                        help="DashScope OpenAI-compatible base URL (env DASHSCOPE_BASE_URL)")
    parser.add_argument("--dashscope-model", dest="dashscope_model", default=None,
                        help="DashScope model (env DASHSCOPE_MODEL or qwen3-vl-plus)")
    parser.add_argument("--timeout", type=int, default=None,
                        help=f"per-call wall-clock seconds (default: env VLM_TIMEOUT or {DEFAULT_TIMEOUT})")
    parser.add_argument("--base-dir", dest="base_dir", default=None,
                        help="base for bundle-relative paths (default: env VISION_REVIEW_BASE_DIR or .godot-smoke)")
    parser.add_argument("--baseline-dir", dest="baseline_dir", default=None,
                        help="baseline sidecar dir for the deterministic pass")
    parser.add_argument("--shots-dir", dest="shots_dir", default=None,
                        help="fresh sidecar dir for the deterministic pass")
    parser.add_argument("--seed", type=int, default=None, help="base RNG seed (env VLM_SEED)")
    parser.add_argument("--no-model", dest="no_model", action="store_true",
                        help="force deterministic-only (CI); never touch the model")
    parser.add_argument("--independent-vote", dest="independent_vote", action="store_true",
                        help="temperature 0.2 + two seeds for a real two-sample vote "
                             "(default off: n=2 at temperature 0 is a determinism guard)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    cfg = Config(_parse_args(argv if argv is not None else sys.argv[1:]))
    try:
        raw = sys.stdin.read()
        public_ctx = json.loads(raw) if raw.strip() else None
        if not isinstance(public_ctx, dict):
            raise ValueError("stdin is not a reviewer-bundle JSON object")
    except (ValueError, OSError) as exc:
        # Fail-closed: a malformed bundle is a real integration bug, not a degrade.
        print(f"vlm_reviewer: cannot read reviewer bundle from stdin: {exc}", file=sys.stderr)
        return EXIT_ERROR

    try:
        findings, answers, meta = run_review(public_ctx, cfg)
    except Exception as exc:  # genuine wrapper breakage (not the model) -> fail-closed
        print(f"vlm_reviewer: internal error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return EXIT_ERROR

    print(json.dumps({"findings": findings, "answers": answers, "reviewer_meta": meta},
                     sort_keys=True))
    model = meta.get("model", {})
    print("vlm_reviewer: shot=%s deterministic=%d model=%s answers=%d (no=%d)"
          % (public_ctx.get("shot"), meta.get("deterministic", {}).get("count", 0),
             "ran(%s)" % model.get("backend") if model.get("ran")
             else "unavailable(%s)" % model.get("reason", "?"),
             len(answers), meta.get("totals", {}).get("model_no_verdicts", 0)),
          file=sys.stderr)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
