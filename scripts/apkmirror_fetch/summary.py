"""Render the per-app status table and the GMS-dependency section."""
from dataclasses import dataclass


@dataclass
class Row:
    package: str
    status: str
    gms: bool = False
    gms_reason: str = ""


def any_failed(rows):
    return any(r.status.startswith("FAILED") for r in rows)


def render(rows):
    width = max((len(r.package) for r in rows), default=10)
    lines = ["", "=== APKMirror fetch summary ==="]
    for r in rows:
        lines.append("  %-*s  %s" % (width, r.package, r.status))

    gms = [r for r in rows if r.gms]
    nogms = [r for r in rows if not r.gms]
    lines.append("")
    lines.append("Apps depending on Google Mobile Services (GMS):")
    if gms:
        for r in gms:
            lines.append("  - %-*s  (%s)" % (width, r.package, r.gms_reason))
    else:
        lines.append("  (none)")
    lines.append("Apps with NO GMS dependency:")
    if nogms:
        for r in nogms:
            lines.append("  - %s" % r.package)
    else:
        lines.append("  (none)")
    return "\n".join(lines)
