#!/usr/bin/python3
"""cider-config.py — point Cider's settings (spa-config.yml) at a shiny theme.

    cider-config.py <spa-config.yml> <theme.css> <accent #RRGGBB> [api-token]
    cider-config.py --off <spa-config.yml>   put the settings shiny changed back
                                             (values from the backup), no custom CSS

With api-token, also registers it as a playback-only token for Cider's local
API (127.0.0.1:10767), which SketchyBar uses to show what's playing.

Cider rewrites this file while it runs, so only call it with Cider quit.
Stdlib only (no PyYAML): edits are line-based and keyed by indentation, which
is enough for the handful of scalar settings changed here. A backup of the
first untouched version is kept next to it as spa-config.yml.shiny-bak.
"""
import json, os, shutil, sys

SETTINGS = {  # key path → YAML scalar
    ("visual", "transparency"): "true",          # see-through window → macOS vibrancy shows
    ("visual", "matchPageToArtwork"): "false",   # don't recolour pages from album art
    ("visual", "matchPageGlow"): "false",
    ("visual", "useAdaptiveColors"): "false",
    ("visual", "appearance"): "dark",
    ("visual", "ui_custom", "useSystemAccentColor"): "false",
    ("visual", "ui_custom", "customAccentColor"): "true",
}


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def find_key(lines, path):
    """Index of the line holding `path` (nested mapping keys), or None."""
    start, end, depth = 0, len(lines), 0
    for i, key in enumerate(path):
        want = depth
        hit = None
        for j in range(start, end):
            ln = lines[j]
            if not ln.strip() or ln.lstrip().startswith("#"):
                continue
            ind = indent_of(ln)
            if ind < want:
                break
            if ind == want and ln.strip().startswith(key + ":"):
                hit = j
                break
        if hit is None:
            return None
        if i == len(path) - 1:
            return hit
        # descend: children are the following lines indented deeper
        start = hit + 1
        child = next((indent_of(l) for l in lines[start:] if l.strip()), want + 2)
        depth = child
        end = next((k for k in range(start, len(lines))
                    if lines[k].strip() and indent_of(lines[k]) <= want), len(lines))
    return None


def value_span(lines, i):
    """Lines [i, j) making up key i's value (handles block / multi-line scalars)."""
    base = indent_of(lines[i])
    j = i + 1
    while j < len(lines) and (not lines[j].strip() or indent_of(lines[j]) > base):
        j += 1
    while j > i + 1 and not lines[j - 1].strip():   # keep trailing blank lines outside
        j -= 1
    return j


def set_value(lines, path, scalar):
    i = find_key(lines, path)
    if i is None:
        raise SystemExit("cider-config: setting %s not found" % ".".join(path))
    pad = " " * indent_of(lines[i])
    lines[i:value_span(lines, i)] = ["%s%s: %s\n" % (pad, path[-1], scalar)]


def ensure_token(lines, token):
    i = find_key(lines, ("connectivity", "apiTokens"))
    if i is None:
        raise SystemExit("cider-config: setting connectivity.apiTokens not found")
    j = value_span(lines, i)
    if any(token in l for l in lines[i:j]):
        return
    pad = " " * indent_of(lines[i])
    item = ["%s  - name: shiny (SketchyBar)\n" % pad,
            "%s    token: %s\n" % (pad, json.dumps(token)),
            "%s    scopes:\n" % pad,
            "%s      - playback\n" % pad]
    if lines[i].rstrip().endswith("[]"):
        lines[i:j] = ["%sapiTokens:\n" % pad] + item
    else:
        lines[j:j] = item


def off(cfg):
    bak = cfg + ".shiny-bak"
    lines = open(cfg).read().splitlines(keepends=True)
    old = open(bak).read().splitlines(keepends=True) if os.path.exists(bak) else []
    for path in list(SETTINGS) + [("visual", "ui_custom", "customAccentColorValue")]:
        i, k = find_key(lines, path), find_key(old, path)
        if i is not None and k is not None:
            lines[i:value_span(lines, i)] = old[k:value_span(old, k)]
    if find_key(lines, ("visual", "customCSS")) is not None:
        set_value(lines, ("visual", "customCSS"), '""')
    tmp = cfg + ".shiny-tmp"
    with open(tmp, "w") as f:
        f.writelines(lines)
    os.replace(tmp, cfg)


def main():
    if sys.argv[1:2] == ["--off"]:
        return off(sys.argv[2])
    cfg, css_file, accent = sys.argv[1:4]
    token = sys.argv[4] if len(sys.argv) > 4 else None
    bak = cfg + ".shiny-bak"
    if not os.path.exists(bak):
        shutil.copy2(cfg, bak)
    lines = open(cfg).read().splitlines(keepends=True)
    for path, scalar in SETTINGS.items():
        set_value(lines, path, scalar)
    set_value(lines, ("visual", "ui_custom", "customAccentColorValue"), json.dumps(accent))
    # One double-quoted YAML string (JSON escapes are valid YAML escapes).
    set_value(lines, ("visual", "customCSS"), json.dumps(open(css_file).read()))
    if token:
        ensure_token(lines, token)
    tmp = cfg + ".shiny-tmp"
    with open(tmp, "w") as f:
        f.writelines(lines)
    os.replace(tmp, cfg)


if __name__ == "__main__":
    main()
