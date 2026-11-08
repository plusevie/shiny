#!/usr/bin/python3
"""wallpaper-all.py — copy the most recently set desktop wallpaper to every Space.

macOS 14+ keeps a wallpaper per Space (and per display within a Space) in
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist, and
setting one (System Events, `wallpaper` CLI) only changes the current Space.
This takes the newest "Desktop" entry and writes it everywhere, then restarts
WallpaperAgent so it takes effect. Run right after setting the wallpaper.
"""
import copy, os, plistlib, subprocess

PATH = os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist")


def desktop_slots(d):
    """Yield every dict that holds a 'Desktop' entry (all spaces, all displays)."""
    yield d.setdefault("AllSpacesAndDisplays", {})
    for disp in (d.get("Displays") or {}).values():
        yield disp
    for space in (d.get("Spaces") or {}).values():
        if "Default" in space:
            yield space["Default"]
        for disp in (space.get("Displays") or {}).values():
            yield disp


def main():
    with open(PATH, "rb") as f:
        d = plistlib.load(f)
    entries = [s["Desktop"] for s in desktop_slots(d) if isinstance(s.get("Desktop"), dict)]
    if not entries:
        raise SystemExit("wallpaper-all: no desktop wallpaper entries found")
    newest = max(entries, key=lambda e: e.get("LastSet") or 0)
    for slot in desktop_slots(d):
        slot["Desktop"] = copy.deepcopy(newest)
        slot.setdefault("Type", "individual")
    tmp = PATH + ".shiny-tmp"
    with open(tmp, "wb") as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
    os.replace(tmp, PATH)
    subprocess.run(["killall", "WallpaperAgent"], capture_output=True)


if __name__ == "__main__":
    main()
