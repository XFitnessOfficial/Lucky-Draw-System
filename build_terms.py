#!/usr/bin/env python3
"""
build_terms.py — generate terms.html from TERMS.md.

TERMS.md is the single source of truth. Never hand-edit terms.html.
Usage:  python3 build_terms.py            # writes terms.html
        python3 build_terms.py --check    # verify only, no write
"""
import re, sys, pathlib

HERE = pathlib.Path(__file__).parent
MD   = HERE / "TERMS.md"
HTML = HERE / "terms.html"

# Per-language page headers (h1 + subtitle)
HEADERS = {
    "en": ("Terms &amp; Conditions", "X FITNESS 9.01 Grand Lucky Draw"),
    "zh": ("活动条款",                "X FITNESS 9.01 周年幸运抽奖"),
    "ms": ("Terma &amp; Syarat",      "X FITNESS 9.01 Grand Lucky Draw"),
}
LANG_OF = {"ENGLISH": "en", "中文": "zh", "BAHASA MALAYSIA": "ms"}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def inline(s):
    s = esc(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    return s


def render_table(rows):
    head, body = rows[0], rows[2:]          # rows[1] is the |---|---| separator
    out = ['<div class="tw"><table><thead><tr>']
    out += [f"<th>{inline(c)}</th>" for c in head]
    out.append("</tr></thead><tbody>")
    for r in body:
        out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def split_row(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def render_body(lines):
    out, i = [], 0
    while i < len(lines):
        ln = lines[i].rstrip()
        if not ln.strip() or ln.strip() == "---":
            i += 1
            continue

        # table
        if ln.lstrip().startswith("|"):
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            out.append(render_table(rows))
            continue

        # bullet list
        if ln.lstrip().startswith("- "):
            items = []
            while i < len(lines) and (lines[i].lstrip().startswith("- ") or not lines[i].strip()):
                if lines[i].strip():
                    items.append(inline(lines[i].lstrip()[2:].strip().rstrip(";")))
                    i += 1
                else:                      # blank line ends the list
                    break
            out.append("<ul>" + "".join(f"<li>{t}</li>" for t in items) + "</ul>")
            continue

        # section heading
        if ln.startswith("## "):
            out.append(f"<h2>{inline(ln[3:].strip())}</h2>")
            i += 1
            continue

        # numbered clause  "7.3 text"
        m = re.match(r"^(\d+\.\d+)\s+(.*)$", ln.strip())
        if m:
            out.append(f'<p class="cl"><span class="n">{m.group(1)}</span>{inline(m.group(2))}</p>')
            i += 1
            continue

        out.append(f"<p>{inline(ln.strip())}</p>")
        i += 1
    return out


def build():
    md = MD.read_text(encoding="utf-8")

    m = re.search(r"^Last updated:\s*(.+)$", md, re.M)
    updated = m.group(1).strip() if m else ""

    # split into language blocks on top-level "# NAME"
    blocks, cur, name = {}, [], None
    for ln in md.split("\n"):
        hm = re.match(r"^#\s+(?!#)(.+)$", ln)
        if hm and hm.group(1).strip() in LANG_OF:
            if name:
                blocks[name] = cur
            name, cur = LANG_OF[hm.group(1).strip()], []
            continue
        if name:
            cur.append(ln)
    if name:
        blocks[name] = cur

    missing = [k for k in ("en", "zh", "ms") if k not in blocks]
    if missing:
        sys.exit(f"ERROR: language block(s) missing from TERMS.md: {missing}")

    shell = HTML.read_text(encoding="utf-8")
    head = shell.split('  <section class="lang on" data-lang="en">')[0]
    tail = "  </section>\n" + shell.split("  </section>\n", 1)[1].rsplit("  </section>\n", 1)[1]

    parts = [head]
    for lang in ("en", "zh", "ms"):
        h1, sub = HEADERS[lang]
        on = " on" if lang == "en" else ""
        parts.append(f'  <section class="lang{on}" data-lang="{lang}">\n')
        parts.append(f"    <h1>{h1}</h1>\n")
        parts.append(f'    <div class="sub">{sub}</div>\n')
        parts.append(f'    <div class="upd">Last updated: {updated}</div>\n')
        parts.append("    <hr>\n")
        parts.append("\n".join(render_body(blocks[lang])) + "\n")
        if lang != "ms":
            parts.append("  </section>\n")
    parts.append(tail)
    return "".join(parts)


if __name__ == "__main__":
    out = build()
    if "--check" in sys.argv:
        cur = HTML.read_text(encoding="utf-8")
        print("IDENTICAL" if cur == out else "DIFFERS")
        if cur != out:
            import difflib
            d = list(difflib.unified_diff(cur.split("\n"), out.split("\n"),
                                          "current", "generated", lineterm="", n=1))
            print("\n".join(d[:80]))
            sys.exit(1)
    else:
        HTML.write_text(out, encoding="utf-8")
        print(f"wrote {HTML}  ({len(out)} bytes)")
