#!/usr/bin/env python3
"""eval-palette.py — how well does palette.py reproduce the hand-picked stock themes?

    tests/eval-palette.py [-v] [--no-cache] [THEME ...]

The stock themes (themes/<name>/{wallpaper.jpg,palette.sh}) were curated by hand,
so their THEME_BASE / ACCENT / ACCENT2 / SELECTION are the ground truth. For each:
  rank   where palette.score() puts the hand-picked scheme among all schemes
  top3   the three best-scoring schemes
  A A2 S whether pick_accents()/match_selection() reproduce ACCENT, ACCENT2 and
         SELECTION when the right scheme is forced (S also passes within ΔE 3,
         since some stock palettes mixed it against a slightly different BG)
  fam    whether the #1 pick is at least a sibling of the hand-picked scheme
         (same id prefix, e.g. catppuccin-*, or the same background colour)
Summary: #1 hits, sibling #1 hits, top-3 hits, mean rank, accent hits, and a
combined score (3 per #1, 1 per top-3, 1 per matching A / A2 / S; max 70).

Pixels are cached in $TMPDIR/shiny-eval-cache (keyed on path+mtime) so that
iterating on image_features() / score() stays fast; --no-cache bypasses it.
"""
import json, os, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "libexec"))
sys.dont_write_bytecode = True  # no libexec/__pycache__ (and no stale .pyc while editing palette.py)
import palette  # noqa: E402

CACHE = os.path.join(tempfile.gettempdir(), "shiny-eval-cache")

def cached_pixels(orig):
    def read(path, *a, **kw):
        st = os.stat(path)
        key = "%s-%d-%d-%s.json" % (os.path.basename(os.path.dirname(path)), st.st_size,
                                    int(st.st_mtime), "-".join(map(str, a)) or "d")
        f = os.path.join(CACHE, key)
        if os.path.exists(f):
            return [tuple(p) for p in json.load(open(f))]
        px = orig(path, *a, **kw)
        os.makedirs(CACHE, exist_ok=True)
        json.dump(px, open(f, "w"))
        return px
    return read

def siblings(a, b):
    return a["id"].split("-")[0] == b["id"].split("-")[0] or a["roles"]["BG"] == b["roles"]["BG"]

def close(a, b, tol=3.0):
    return palette.de(palette.rgb2lab(palette.hex2rgb(a)), palette.rgb2lab(palette.hex2rgb(b))) <= tol

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    verbose = "-v" in sys.argv
    if "--no-cache" not in sys.argv:
        palette.read_pixels = cached_pixels(palette.read_pixels)
    schemes = palette.load_schemes()
    by_name = {s["name"]: s for s in schemes}
    # Stock themes, plus your own (~/.config/shiny/themes): every theme you build
    # in the TUI is one more labelled example. Themes built from the image
    # itself (or on a scheme that's gone) have no scheme to rank, so are skipped.
    dirs = {}
    for tdir in (os.path.join(ROOT, "themes"),
                 os.environ.get("SHINY_USER_THEMES", os.path.expanduser("~/.config/shiny/themes"))):
        if os.path.isdir(tdir):
            for n in sorted(os.listdir(tdir)):
                if os.path.exists(os.path.join(tdir, n, "palette.sh")):
                    dirs.setdefault(n, os.path.join(tdir, n))
    names = [n for n in (args or sorted(dirs)) if n in dirs and
             palette.read_palette(os.path.join(dirs[n], "palette.sh")).get("THEME_BASE") in by_name]

    rows, tot = [], {"r1": 0, "fam": 0, "top3": 0, "rank": 0, "A": 0, "A2": 0, "S": 0}
    for n in names:
        truth = palette.read_palette(os.path.join(dirs[n], "palette.sh"))
        feat = palette.image_features(os.path.join(dirs[n], truth.get("WALLPAPER", "wallpaper.jpg")))
        ranked = sorted(schemes, key=lambda s: palette.score(s, feat))
        want = by_name[truth["THEME_BASE"]]
        rank = [s["id"] for s in ranked].index(want["id"]) + 1
        r = palette.build(want, feat)
        A = r["ACCENT"] == truth["ACCENT"].upper()
        A2 = r["ACCENT2"] == truth["ACCENT2"].upper()
        S = close(r["SELECTION"], truth["SELECTION"])
        fam = siblings(ranked[0], want)
        tot["r1"] += rank == 1; tot["fam"] += fam; tot["top3"] += rank <= 3; tot["rank"] += rank
        tot["A"] += A; tot["A2"] += A2; tot["S"] += S
        mark = lambda ok, got: "ok" if ok else got
        rows.append((n, rank, "y" if fam else "-", ", ".join(s["id"] for s in ranked[:3]),
                     mark(A, r["ACCENT"]), mark(A2, r["ACCENT2"]), mark(S, r["SELECTION"]),
                     "%s/%s" % (truth["ACCENT"].upper(), truth["ACCENT2"].upper())))
        if verbose:
            print("── %s" % n)
            t = feat["tint"]
            print("   tint L%.0f C%.1f h%.0f" % (t[0], palette.chroma(t), palette.hue(t)))
            for f in feat["families"]:
                print("   family h%3.0f share %.3f C%3.0f L%3.0f peak %3.0f" % (f["hue"], f["share"], f["chroma"], f["L"], f["peak"]))
            for s in ranked[:5]:
                print("   %6.1f %s" % (palette.score(s, feat), s["id"]))
    n = len(rows)
    print("%-11s %4s %3s  %-62s %-8s %-8s %-8s %s" % ("theme", "rank", "fam", "top3", "ACCENT", "ACCENT2", "SELECT", "want A/A2"))
    for row in rows:
        print("%-11s %4d %3s  %-62s %-8s %-8s %-8s %s" % row)
    score = 3 * tot["r1"] + tot["top3"] + tot["A"] + tot["A2"] + tot["S"]
    print("\n#1 %d/%d (sibling %d/%d) · top-3 %d/%d · mean rank %.1f · ACCENT %d/%d · ACCENT2 %d/%d · SELECTION %d/%d · score %d/%d"
          % (tot["r1"], n, tot["fam"], n, tot["top3"], n, tot["rank"] / n, tot["A"], n, tot["A2"], n, tot["S"], n, score, 7 * n))

if __name__ == "__main__":
    main()
