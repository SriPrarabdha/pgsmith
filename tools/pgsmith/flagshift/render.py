"""Plan output: terraform-style text and Markdown (for pull-request comments)."""
from __future__ import annotations

import json
from collections import defaultdict


def _v(x) -> str:
    if x is None:
        return "null"
    return json.dumps(x, ensure_ascii=False) if not isinstance(x, str) else json.dumps(x, ensure_ascii=False)


def _md(x) -> str:
    """Text from the configuration, made inert inside a Markdown PR comment:
    no table breaks, no HTML, no @-mentions, no code-span escapes."""
    s = str(x)
    for a, b in (("\\", "\\\\"), ("|", "\\|"), ("`", "'"), ("<", "&lt;"), (">", "&gt;"),
                 ("@", "@\u200b"), ("\r", " "), ("\n", " ")):
        s = s.replace(a, b)
    return s


def _onoff(x) -> str:
    return "on" if x else "off"


def _group(rows):
    by = defaultdict(list)
    for r in rows:
        by[r["feature"]].append(r)
    return by


def _transitions(rs):
    """Human lines for the changed groups of one feature, biggest first."""
    lines = []
    for r in sorted([r for r in rs if r["changed"]], key=lambda r: -r["users"]):
        parts = []
        if r["from_enabled"] != r["to_enabled"]:
            parts.append(f"enabled {_onoff(r['from_enabled'])} → {_onoff(r['to_enabled'])}")
        if r["from_value"] != r["to_value"]:
            parts.append(f"value {_v(r['from_value'])} → {_v(r['to_value'])}")
        if r["from_variant"] != r["to_variant"]:
            parts.append(f"variant {r['from_variant'] or '-'} → {r['to_variant'] or '-'}")
        reason = (f"reason {r['from_reason']} → {r['to_reason']}" if r["from_reason"] != r["to_reason"]
                  else f"reason {r['to_reason']}")
        lines.append((r["users"], ", ".join(parts) or "metadata", reason, r["sample"] or []))
    return lines


def render_text(res: dict, color: bool = False) -> str:
    c = (lambda code, s: f"\033[{code}m{s}\033[0m") if color else (lambda code, s: s)
    by = _group(res["rows"])
    total = {f: sum(r["users"] for r in rs) for f, rs in by.items()}
    changed = {f: sum(r["users"] for r in rs if r["changed"]) for f, rs in by.items()}
    pop = max(total.values()) if total else 0
    out = [f"flagshift plan  {res['source']} → {res['environment']}   population: {res['population']} "
           f"({pop:,} identities)   snapshots {res['live_snapshot']} → {res['candidate_snapshot']}", ""]
    for f in sorted(by, key=lambda f: (-changed[f], f)):
        if changed[f]:
            out.append(c("33", f"~ {f:<22} {changed[f]:,} users change ({100 * changed[f] / max(total[f], 1):.1f}%)"))
            for users, what, reason, sample in _transitions(by[f])[:6]:
                out.append(f"    {what:<44} {users:>8,} users   {reason}")
                if sample:
                    out.append(c("2", f"{'':<6}e.g. {', '.join(sample[:3])}"))
            if f in res.get("overlap", {}) and res["overlap"][f]["pct"] < 99.95:
                o = res["overlap"][f]
                out.append(c("31", f"  ! cohort overlap: {o['pct']:.1f}% of {res['source']}'s {o['in_source']:,} targeted "
                                   f"users are targeted the same way in {res['environment']}"))
        else:
            out.append(c("2", f"= {f:<22} no users change"))
            o = res.get("overlap", {}).get(f)
            if o and o["pct"] < 99.95:
                out.append(c("31", f"  ! same rules, different people: only {o['pct']:.1f}% of {res['source']}'s "
                                   f"{o['in_source']:,} targeted users are targeted in {res['environment']} "
                                   "(splits hash environment-specific keys)"))
    for w in res.get("warnings", []):
        out.append(c("31", f"  ! {w}"))
    n = sum(1 for f in by if changed[f])
    out += ["", f"Plan: {n} feature(s) change for {sum(changed.values()):,} identity-flag pairs; "
                f"{len(by) - n} unchanged.  (evaluated in {res['seconds']}s inside Postgres)"]
    return "\n".join(out)


def render_markdown(res: dict) -> str:
    by = _group(res["rows"])
    total = {f: sum(r["users"] for r in rs) for f, rs in by.items()}
    changed = {f: sum(r["users"] for r in rs if r["changed"]) for f, rs in by.items()}
    pop = max(total.values()) if total else 0
    n = sum(1 for f in by if changed[f])
    out = [f"### FlagShift plan: `{_md(res['source'])}` → `{_md(res['environment'])}`", "",
           f"Population `{_md(res['population'])}`: **{pop:,}** identities. "
           f"**{n}** feature(s) change, **{len(by) - n}** unchanged. "
           f"Evaluated inside Postgres with pg_flagsmith in {res['seconds']}s "
           f"(live snapshot {res['live_snapshot']}, candidate {res['candidate_snapshot']}).", ""]
    if n:
        out += ["| Feature | Users changing | Change | Reason |", "|---|---:|---|---|"]
        for f in sorted(by, key=lambda f: (-changed[f], f)):
            if not changed[f]:
                continue
            for i, (users, what, reason, _) in enumerate(_transitions(by[f])[:4]):
                out.append(f"| {'`' + _md(f) + '`' if i == 0 else ''} | {users:,} | {_md(what)} | {_md(reason)} |")
        out.append("")
    for f, o in res.get("overlap", {}).items():
        if o["pct"] >= 99.95:
            continue
        out.append(f"> ⚠️ `{_md(f)}`: only **{o['pct']:.1f}%** of {_md(res['source'])}'s targeted users are targeted "
                   f"the same way in {_md(res['environment'])} (bucketing hashes environment-specific keys).")
    for w in res.get("warnings", []):
        out.append(f"> ⚠️ {_md(w)}")
    unchanged = [f for f in sorted(by) if not changed[f]]
    if unchanged:
        out += ["", "<details><summary>Unchanged</summary>", "", ", ".join(f"`{_md(f)}`" for f in unchanged),
                "</details>"]
    return "\n".join(out)
