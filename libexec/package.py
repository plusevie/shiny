#!/usr/bin/env python3
"""package.py — .shiny theme packages: one file with a theme's palette (and its
per-theme overrides), wallpaper and, for themes built from their image, Ghostty
colours.

    package.py export <theme dir> <name> <out.shiny>
    package.py import <file.shiny> <themes dir> [--name NAME] [--force]   → prints the name

A .shiny is a zip: shiny.json ({"format": 1, "name": …}), palette.sh, the
wallpaper palette.sh names, and optionally ghostty-theme. palette.sh is sourced
by shiny-apply, so an import only accepts plain assignments to the keys themes
use (colour roles, theme settings, templates/style.sh overrides) with literal
values: a package can't run anything. ghostty-theme only gets colour keys.
"""
import json, os, re, shutil, subprocess, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FORMAT = 1
MAX_BYTES = 64 << 20
ROLES = {"BG", "BG_DARK", "SURFACE", "SELECTION", "MUTED", "COMMENT", "FG", "FG_DIM", "ACCENT", "ACCENT2"}
SETTINGS = {"THEME_BASE", "GHOSTTY_THEME", "ACCENT_PRESET", "WALLPAPER", "ICON_TINT", "ALFRED_BLUR"}
GHOSTTY_KEYS = {"palette", "background", "foreground", "cursor-color", "cursor-text",
                "selection-background", "selection-foreground"}
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff"}
NAME = re.compile(r"[a-z0-9][a-z0-9-]*")
# KEY="literal" or KEY=bare-word, then an optional comment. No $, `, \ or quotes inside.
ASSIGN = re.compile(r'\s*([A-Z_][A-Z0-9_]*)=("[^"$`\\]*"|[A-Za-z0-9._#+-]*)\s*(#.*)?')


def die(msg):
    sys.exit("package: " + msg)


def style_keys():
    keys = set()
    for line in open(os.path.join(ROOT, "templates", "style.sh")):
        m = re.match(r"([A-Z_][A-Z0-9_]*)=", line)
        if m:
            keys.add(m.group(1))
    return keys


def check_palette(text):
    """{key: value} of a palette.sh, or die if it holds anything but allowed assignments."""
    allowed, out = ROLES | SETTINGS | style_keys(), {}
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = ASSIGN.fullmatch(line)
        if not m:
            die(f"palette.sh line {n} isn't a plain KEY=\"value\" setting: {line.strip()[:60]}")
        if m.group(1) not in allowed:
            die(f"palette.sh line {n}: {m.group(1)} isn't a theme setting")
        out[m.group(1)] = m.group(2).strip('"')
    return out


def check_ghostty(text):
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        key = s.split("=", 1)[0].strip()
        if "=" not in s or key not in GHOSTTY_KEYS:
            die(f"ghostty-theme line {n}: only colours are allowed ({key})")


def wallpaper_name(p):
    w = p.get("WALLPAPER", "wallpaper.jpg")
    if os.path.basename(w) != w or os.path.splitext(w)[1].lower() not in IMAGE_EXT:
        die(f"WALLPAPER must be an image file name next to palette.sh ({w})")
    return w


def export(theme_dir, name, out):
    pal = open(os.path.join(theme_dir, "palette.sh")).read()
    p = check_palette(pal)   # what we write must import again
    files = ["palette.sh", wallpaper_name(p)]
    if os.path.isfile(os.path.join(theme_dir, "ghostty-theme")):
        files.append("ghostty-theme")
    for f in files:
        if not os.path.isfile(os.path.join(theme_dir, f)):
            die(f"{name}: {f} is missing")
    tmp = out + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("shiny.json", json.dumps({"format": FORMAT, "name": name}, indent=2) + "\n")
        for f in files:
            z.write(os.path.join(theme_dir, f), f)
    os.replace(tmp, out)


def import_(path, themes_dir, name=None, force=False):
    try:
        z = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as e:
        die(f"{os.path.basename(path)} isn't a .shiny package ({e})")
    with z:
        entries = {i.filename: i for i in z.infolist()}
        if sum(i.file_size for i in entries.values()) > MAX_BYTES:
            die("package is too big")
        try:
            meta = json.loads(z.read("shiny.json"))
            pal = z.read("palette.sh").decode()
        except (KeyError, ValueError, UnicodeDecodeError):
            die("not a .shiny package (no shiny.json / palette.sh)")
        if meta.get("format", 0) > FORMAT:
            die("made by a newer shiny — run: shiny update")
        p = check_palette(pal)
        wp = wallpaper_name(p)
        want = {"shiny.json", "palette.sh", wp} | ({"ghostty-theme"} & entries.keys())
        if extra := entries.keys() - want:
            die("unexpected files in package: " + ", ".join(sorted(extra)))
        if wp not in entries:
            die(f"wallpaper {wp} missing from package")
        if "ghostty-theme" in entries:
            check_ghostty(z.read("ghostty-theme").decode(errors="replace"))
        name = name or meta.get("name") or os.path.splitext(os.path.basename(path))[0]
        name = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        if not NAME.fullmatch(name):
            die(f"bad theme name: {name!r}")
        dest = os.path.join(themes_dir, name)
        if os.path.exists(dest) and not force:
            print(name)
            sys.exit(3)   # exists: the caller asks, then re-runs with --force
        os.makedirs(themes_dir, exist_ok=True)
        tmp = tempfile.mkdtemp(dir=themes_dir, prefix=".import-")
        try:
            for f in want - {"shiny.json"}:
                with open(os.path.join(tmp, f), "wb") as o:   # flat names only: nothing escapes tmp
                    o.write(z.read(f))
            if subprocess.run(["sips", "-g", "pixelWidth", os.path.join(tmp, wp)],
                              capture_output=True).returncode:
                die(f"{wp} isn't an image macOS can read")
            if os.path.exists(dest):
                shutil.rmtree(dest)
            os.replace(tmp, dest)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print(name)


def main():
    a = sys.argv[1:]
    if len(a) == 4 and a[0] == "export":
        export(a[1], a[2], a[3])
    elif len(a) >= 3 and a[0] == "import":
        name = a[a.index("--name") + 1] if "--name" in a else None
        import_(a[1], a[2], name, "--force" in a)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
