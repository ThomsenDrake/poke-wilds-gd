from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import argparse
import sys

import check_architecture
import check_quality_docs
import check_repo_contracts
from legibility_lib import repo_root

BASELINE_DIR = repo_root() / "docs" / "generated" / "visual-baselines"


def _load_tool(name: str):
    """Importlib-load a sibling tool (same pattern as run_playtests/region diff);
    returns the module, or None if it cannot load so the report degrades to a
    note instead of crashing."""
    path = Path(__file__).resolve().with_name(f"{name}.py")
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        return None
    try:
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception:  # a broken tool must not take down the whole report
        return None
    return module


def contrast_section() -> tuple[list[str], int]:
    """WCAG rendered-pixel contrast on the committed battle baselines (design-time
    evidence; the fresh-pixel path lives in the run_playtests visual_sweep
    post-step). Shows each label's measured ratio; contrast_low counts are
    advisory until the determinism proof + clean history graduate them to red."""
    lines = ["## Contrast (WCAG rendered-pixel)", ""]
    cc = _load_tool("contrast_check")
    if cc is None or not BASELINE_DIR.is_dir():
        lines.append("Skipped: contrast_check or the visual baselines are unavailable.")
        lines.append("")
        return lines, 0
    rows: list[str] = []
    low = 0
    for png in sorted(BASELINE_DIR.glob("*.png")):
        sidecar_path = png.with_name(png.name + ".sidecar.json")
        if not sidecar_path.exists():
            continue
        try:
            sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
            width, height, pixels = cc.visual_diff.decode_png_rgba(png)
        except (OSError, ValueError, cc.visual_diff.PngError):
            continue
        for entry in cc.label_rects_from_sidecar(sidecar if isinstance(sidecar, dict) else {}):
            measured = cc.contrast_ratio(pixels, width, height, entry["rect"])
            if measured is None:
                continue
            # Decide on the raw ratio (the rounded `ratio` is display-only) so
            # the report agrees with contrast_check's boundary decision.
            ok = measured["_raw"] >= measured["need"]
            if not ok:
                low += 1
            rows.append("- {shot} \"{text}\" ratio {ratio} (need {need}) {mark}".format(
                shot=png.name, text=entry["text"], mark="ok" if ok else "LOW", **measured))
    if low:
        lines.append(f"contrast_low findings: {low} (quarantine-tier until graduated to coded red)")
    else:
        lines.append("No contrast_low findings (all measured labels meet the WCAG AA bar).")
    lines.append("")
    lines.extend(rows)
    lines.append("")
    return lines, low


def cvd_section() -> tuple[list[str], int]:
    """Machado-Oliveira-Fernandes 2009 CVD simulation over the HP-bar triple and
    the committed sidecar canary palettes. cvd_collapse findings are
    QUARANTINE-FOREVER accessibility evidence -- recorded here, never red."""
    lines = ["## Color-vision deficiency (Machado 2009)", ""]
    cvd = _load_tool("cvd_sim")
    if cvd is None:
        lines.append("Skipped: cvd_sim is unavailable.")
        lines.append("")
        return lines, 0
    result = cvd.run_cvd(BASELINE_DIR if BASELINE_DIR.is_dir() else None)
    findings = result["findings"]
    lines.append("Severity 1.0 (full dichromacy); collapse = a pair with original CIE76 "
                 f"deltaE >= {cvd.DELTA_E_THRESHOLD} falling below it under simulation. "
                 "Quarantine-forever: accessibility evidence, never a red gate.")
    lines.append("")
    if not findings:
        lines.append("No cvd_collapse findings.")
        lines.append("")
        return lines, 0
    lines.append(f"cvd_collapse findings: {len(findings)} (quarantine-forever)")
    lines.append("")
    for finding in findings:
        lines.append("- [{deficiency}] {source}: {pair} deltaE {original_delta_e} -> "
                     "{simulated_delta_e} (< {threshold})".format(**finding))
    lines.append("")
    return lines, len(findings)


def generate(output_path: Path) -> int:
    checks = {
        "repo_contracts": check_repo_contracts.run(),
        "architecture": check_architecture.run(),
        "quality_docs": check_quality_docs.run(),
    }
    findings = sum(len(items) for items in checks.values())
    contrast_lines, contrast_low = contrast_section()
    cvd_lines, cvd_collapses = cvd_section()
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")

    lines = [
        "Status: generated",
        f"Last verified: {datetime.now(timezone.utc).date().isoformat()}",
        "Review cadence days: 7",
        "Source paths: tools/generate_legibility_report.py, tools/check_repo_contracts.py, "
        "tools/check_architecture.py, tools/check_quality_docs.py, tools/contrast_check.py, "
        "tools/cvd_sim.py",
        "",
        "# Legibility Report",
        "",
        f"- Generated at: {timestamp}",
        f"- Total findings: {findings}",
        f"- contrast_low findings (advisory, quarantine-tier): {contrast_low}",
        f"- cvd_collapse findings (accessibility evidence, quarantine-forever): {cvd_collapses}",
        "",
    ]

    for check_name, issues in checks.items():
        lines.append(f"## {check_name.replace('_', ' ').title()}")
        lines.append("")
        if not issues:
            lines.append("No findings.")
            lines.append("")
            continue
        for issue in issues:
            lines.append(f"- {issue}")
        lines.append("")

    lines.extend(contrast_lines)
    lines.extend(cvd_lines)

    output_path.write_text("\n".join(lines), encoding="utf-8")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="Where to write the markdown report.")
    parser.add_argument("--fail-on-findings", action="store_true")
    args = parser.parse_args()

    findings = generate(Path(args.output))
    if findings and args.fail_on_findings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
