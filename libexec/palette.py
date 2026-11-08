#!/usr/bin/env python3
"""palette.py — build a shiny theme palette from an image.

    palette.py <image> [--scheme ID] [--accent HEX] [--accent2 HEX] [--json]
    palette.py <image> --top N | --candidates [--top N]
    palette.py <image> --scheme image --ghostty-out FILE   (built from the image, no base scheme)
    palette.py --check <palette.sh> [--json]

Picks the existing colour scheme (libexec/schemes.json, colours from Ghostty's
theme files) that best fits the image, then picks that scheme's accents that
best match the image's most striking colours. Prints a palette.sh to stdout
(or the ranking with --top, every candidate fully built with --candidates — the
TUI's wizard uses that — or a JSON blob with --json). --check lints a palette.

Stdlib only: pixels come from `sips` (macOS) as a tiny BMP.
"""
import argparse, colorsys, json, math, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
THEME_DIRS = [
    os.path.join(HERE, "ghostty-themes"),
    "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
]

# ── colour maths ──────────────────────────────────────────────────────────────
def hex2rgb(h):
    h = h.lstrip("#"); return tuple(int(h[i:i+2], 16) / 255 for i in (0, 2, 4))

def rgb2hex(c):
    return "#" + "".join(f"{max(0, min(255, round(v * 255))):02X}" for v in c)

def _lin(v): return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4

def rgb2lab(c):
    r, g, b = (_lin(v) for v in c)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = (0.2126 * r + 0.7152 * g + 0.0722 * b)
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    fx, fy, fz = f(x), f(y), f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))

def rgb2ok(c):
    """OKLab, scaled to CIELAB-like numbers (L 0-100, a/b ×400). Used for hue
    matching: CIELAB bends saturated blues towards purple, so a deep-blue sky
    and a pastel-blue accent read 20° apart there but line up in OKLab."""
    r, g, b = (_lin(v) for v in c)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (100 * (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s),
            400 * (1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s),
            400 * (0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s))

def chroma(lab): return math.hypot(lab[1], lab[2])
def hue(lab): return math.degrees(math.atan2(lab[2], lab[1])) % 360
def de(a, b): return math.dist(a, b)
def hue_diff(a, b): d = abs(a - b) % 360; return min(d, 360 - d)

def mix(a, b, t):
    a, b = hex2rgb(a), hex2rgb(b); return rgb2hex(tuple(x + (y - x) * t for x, y in zip(a, b)))

# ── image → pixels → tint + colour families ───────────────────────────────────
# How a theme is picked (a person's reasoning, made explicit):
#   1. image: its overall tint, and its colour families (hues that belong together).
#   2. scheme: BG tint suits the image tint + its palette holds the image's
#      colours + it has a light accent for the main/second colour  (score)
#   3. accents: ACCENT = the main family's hue; ACCENT2 = a second family if the
#      image clearly has one (big, or a vivid contrasting highlight), else an
#      analogous neighbour that deepens the image's warm/cool mood  (pick_accents)
#   4. selection: kept unless it clashes with ACCENT  (match_selection)
# Hues are compared in OKLab: CIELAB bends saturated blues towards purple.
def read_pixels(path, size=96):
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "p.bmp")
        subprocess.run(["sips", "-Z", str(size), "-s", "format", "bmp", path, "--out", out],
                       check=True, capture_output=True)
        b = open(out, "rb").read()
    off = int.from_bytes(b[10:14], "little")
    w = int.from_bytes(b[18:22], "little", signed=True)
    h = int.from_bytes(b[22:26], "little", signed=True)
    n = int.from_bytes(b[28:30], "little") // 8
    row = (w * n + 3) // 4 * 4
    px = []
    for y in range(abs(h)):
        base = off + y * row
        for x in range(w):
            p = base + x * n
            px.append((b[p + 2] / 255, b[p + 1] / 255, b[p] / 255))
    return px

NEUTRAL = 4  # OKLab chroma (×400) at or below this reads as grey

def hue_families(oks, bins=36):
    """The image's colour families, biggest first.

    Each pixel votes for its hue with weight (chroma - NEUTRAL), so grey pixels
    don't count and vivid ones count more. Families are the hills of that hue
    histogram; two neighbouring hills with only a shallow dip between them are
    one family (a forest's greens and teals), a deep dip or an empty gap splits
    them (a blue scene's orange window). Per family: `share` of all colour
    weight, chroma-weighted mean `hue`, `chroma` and `L`, and `peak` (its 90th
    percentile chroma: how vivid its brightest bits are)."""
    w, members = [0.0] * bins, [[] for _ in range(bins)]
    for l in oks:
        c = chroma(l)
        if c > NEUTRAL:
            b = int(hue(l) * bins / 360) % bins
            w[b] += c - NEUTRAL; members[b].append(l)
    total = sum(w)
    if not total:
        return []
    s = [(w[i - 1] + 2 * w[i] + w[(i + 1) % bins]) / 4 for i in range(bins)]  # light smoothing
    live = [w[i] > 0.002 * total for i in range(bins)]
    # Climb each bin to its local maximum: bins sharing a peak form a hill.
    def climb(i):
        while True:
            j = max((i - 1) % bins, (i + 1) % bins, key=lambda k: s[k])
            if s[j] <= s[i]: return i
            i = j
    root = {i: climb(i) for i in range(bins) if live[i]}
    find = lambda i: i if root.get(i, i) == i else find(root[i])
    # Merge neighbouring hills unless the dip between them is deep (< half the smaller peak).
    changed = True
    while changed:
        changed = False
        for i in range(bins):
            j = (i + 1) % bins
            if live[i] and live[j]:
                a, b = find(i), find(j)
                if a != b and min(s[i], s[j]) > 0.5 * min(s[a], s[b]):
                    root[min(a, b, key=lambda k: s[k])] = max(a, b, key=lambda k: s[k]); changed = True
    fams = {}
    for i in root:
        fams.setdefault(find(i), []).append(i)
    out = []
    for idx in fams.values():
        px = [l for i in idx for l in members[i]]
        ws = [chroma(l) - NEUTRAL for l in px]; sw = sum(ws)
        x = sum(wt * l[1] / chroma(l) for wt, l in zip(ws, px))
        y = sum(wt * l[2] / chroma(l) for wt, l in zip(ws, px))
        cs = sorted(chroma(l) for l in px)
        out.append({"share": sum(w[i] for i in idx) / total,
                    "hue": math.degrees(math.atan2(y, x)) % 360,
                    "chroma": sum(wt * chroma(l) for wt, l in zip(ws, px)) / sw,
                    "L": sum(wt * l[0] for wt, l in zip(ws, px)) / sw,
                    "peak": cs[int(0.9 * (len(cs) - 1))]})
    return sorted(out, key=lambda f: -f["share"])

def image_features(path):
    """tint: the image's average colour (OKLab) — shiny's windows are translucent
    over a blur of the wallpaper, so this is what a window background sits on.
    families: its colour families (hue_families)."""
    oks = [rgb2ok(p) for p in read_pixels(path)]
    if not oks:
        raise ValueError("no pixels")
    tint = tuple(sum(o[i] for o in oks) / len(oks) for i in range(3))
    return {"tint": tint, "families": hue_families(oks)}

# ── schemes ───────────────────────────────────────────────────────────────────
def read_ghostty_theme(name):
    for d in THEME_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            t = {"palette": {}}
            for line in open(p):
                if "=" not in line: continue
                k, v = (s.strip() for s in line.split("=", 1))
                if k == "palette":
                    i, c = v.split("=", 1); t["palette"][int(i)] = c.strip()
                else:
                    t[k] = v
            return t
    raise SystemExit(f"Ghostty theme not found: {name}")

def load_schemes():
    out = []
    for s in json.load(open(os.path.join(HERE, "schemes.json")))["schemes"]:
        t = read_ghostty_theme(s["ghostty"])
        bg, fg, pal = t["background"].upper(), t["foreground"].upper(), t["palette"]
        roles = {
            "BG": bg, "FG": fg,
            "BG_DARK": mix(bg, "#000000", 0.18),
            "SURFACE": mix(bg, fg, 0.10),
            "SELECTION": t.get("selection-background", mix(bg, pal.get(4, fg), 0.3)).upper(),
            "MUTED": mix(bg, fg, 0.28),
            "COMMENT": mix(bg, fg, 0.42),
            "FG_DIM": mix(bg, fg, 0.82),
        }
        roles.update({k: v.upper() for k, v in s.get("roles", {}).items()})
        if roles["BG_DARK"] == roles["BG"]:  # frames must read darker than the window
            roles["BG_DARK"] = mix(bg, "#000000", 0.18)
        accents, normal, bright = [], (1, 2, 3, 4, 5, 6), (9, 10, 11, 12, 13, 14)
        mean_l = lambda idx: sum(rgb2ok(hex2rgb(pal[i]))[0] for i in idx if i in pal) / len(idx)
        if mean_l(bright) < mean_l(normal):  # bright row darker: light-mode colours (Everforest), off-character
            bright = ()
        for c in [pal.get(i) for i in normal + bright] + s.get("extra_accents", []):
            if c and c.upper() not in accents and chroma(rgb2lab(hex2rgb(c))) > 14:
                accents.append(c.upper())
        out.append({**s, "roles": roles, "accents": accents})
    return out

UI_L = 72  # OKLab lightness an accent should have to read well on a dark theme

def too_dark(ok, floor=UI_L):
    return max(0, floor - ok[0]) * 1.6

def ui_penalty(ok):
    # Accents sit on dark backgrounds: prefer light/pastel over deep ANSI tones
    # (strongly below UI_L, and a little all the way up: the bright variant
    # of a colour over the normal one).
    return too_dark(ok) + (100 - ok[0]) * 0.1

def want_chroma(fam):
    # An accent (L≈75) as saturated as the image colour has chroma C·75/L: a
    # deep red sky asks for the vivid red, a misty teal for the pastel one.
    return min(60, max(15, fam["chroma"] * 75 / max(fam["L"], 20)))

def hue_dist(fam, acc):
    # Match accents to image colours by hue first (wallpapers are often dark or
    # muted, so plain colour distance would just pick the dullest accent), then
    # by saturation.
    return hue_diff(fam["hue"], hue(acc)) * 0.8 + abs(chroma(acc) - want_chroma(fam)) * 0.25

def targets(feat):
    """(primary, secondary) colour targets for the accents.

    Primary: the image's biggest colour family. Secondary: a family that is
    clearly a second colour — a different hue (>= 45° away) covering a real
    part of the image (>= 15% of its colour), or a contrasting hue (>= 90°)
    at least as vivid as the main colour (a lit window, a beam of light).
    Otherwise None: a one-colour image, the second accent stays analogous."""
    fams = feat["families"]
    if not fams:  # greyscale image: its faint overall tint, or plain UI blue if none
        t = feat["tint"]
        h = hue(t) if chroma(t) > 2 else 255
        fams = [{"hue": h, "chroma": chroma(t), "L": t[0], "share": 1, "peak": chroma(t)}]
    p = fams[0]
    sec = next((f for f in fams[1:] if
                (f["share"] >= 0.15 and hue_diff(f["hue"], p["hue"]) >= 45) or
                (f["peak"] >= p["peak"] and hue_diff(f["hue"], p["hue"]) >= 90)), None)
    return p, sec

def _oks(scheme):
    return [(a, rgb2ok(hex2rgb(a))) for a in scheme["accents"]]

TINT_CAP = 14  # OKLab chroma (×400) where the image tint saturates; scheme BGs reach ~15
W_COLOURS, W_ACCENTS = 0.3, 0.5  # vs the tint term (all three are OKLab×400-ish distances)

def score(scheme, feat):
    """Lower is better. The three things a person checks when matching a scheme
    to a wallpaper:
      tint     does the window background's tint suit the image's overall tint?
               (squashed: scheme BGs are only faintly tinted, so a deep-blue
               image just wants a blue-ish BG, not the most saturated one)
      colours  does the scheme's palette (deep ANSI colours included: the
               terminal shows them) contain the image's colour families, at
               their real lightness and saturation? Mean distance to the 2
               nearest, so a long list can't win on one lucky hit.
      accents  does it have a usable (light) accent in the image's main hue, and
               in its second colour if it has one?"""
    bg = rgb2ok(hex2rgb(scheme["roles"]["BG"]))
    t = feat["tint"]
    tc = chroma(t)
    k = TINT_CAP * math.tanh(tc / TINT_CAP) / tc if tc else 1
    tint = math.hypot(bg[1] - t[1] * k, bg[2] - t[2] * k)
    accs = [a for _, a in _oks(scheme)]
    fams = feat["families"][:3]
    colours, tw = 0, 0
    for f in fams:
        h = math.radians(f["hue"])
        pt = (f["L"], f["chroma"] * math.cos(h), f["chroma"] * math.sin(h))
        d = sorted(math.sqrt((0.5 * (pt[0] - a[0])) ** 2 + (pt[1] - a[1]) ** 2 + (pt[2] - a[2]) ** 2) for a in accs)
        colours += f["share"] ** 0.5 * sum(d[:2]) / len(d[:2]); tw += f["share"] ** 0.5
    colours /= tw or 1
    # Like hue_dist + ui_penalty, but forgiving the last few degrees (image hues
    # are fuzzy) and only ruling out clearly dark accents (Nord's L≈70 blues are fine).
    def fit(f):
        return min(20 * (1 - math.cos(math.radians(hue_diff(f["hue"], hue(a)))))
                   + abs(chroma(a) - want_chroma(f)) * 0.25 + too_dark(a, UI_L - 4) for a in accs)
    p, sec = targets(feat)
    accents = fit(p) + (0.5 * fit(sec) if sec else 0)
    return tint + W_COLOURS * colours + W_ACCENTS * accents

WARM, COOL = 55, 235  # OKLab hues of orange and cyan-blue: the temperature poles

def pick_accents(scheme, feat):
    accs = _oks(scheme)
    p, sec = targets(feat)
    first = min(accs, key=lambda a: hue_dist(p, a[1]) + ui_penalty(a[1]))
    rest = [a for a in accs if hue_diff(hue(a[1]), hue(first[1])) >= 20]
    if not rest:
        return first[0], first[0]
    if sec:
        second = min(rest, key=lambda a: hue_dist(sec, a[1]) + ui_penalty(a[1]))
    else:
        # One-colour image: an analogous neighbour ~35° away, on the side that
        # deepens the image's temperature (fire → orange, ice → cyan, a purple
        # → blue-lavender): turn away from the warm pole for cool hues, towards
        # it for warm ones.
        h = hue(first[1])
        warm = hue_diff(h, WARM) < hue_diff(h, COOL)
        pole = WARM if warm else COOL
        step = 35 if (pole - h) % 360 < 180 else -35
        target = (h + step) % 360
        second = min(rest, key=lambda a: hue_diff(hue(a[1]), target) * 0.8 + ui_penalty(a[1]))
    return first[0], second[0]

def match_selection(sel, bg, acc):
    # Selected rows sit next to the accent everywhere (Alfred, Ghostty, macOS),
    # so a scheme selection in a clashing hue (e.g. Everforest's mauve on a
    # green theme) is swapped for a dark wash of the accent.
    s, a = rgb2lab(hex2rgb(sel)), rgb2lab(hex2rgb(acc))
    # Some schemes (Iceberg) use a light, inverted selection: unusable as a row tint.
    if s[0] > 45 or (chroma(s) > 8 and hue_diff(hue(s), hue(a)) > 45):
        return mix(bg, acc, 0.22)
    return sel

def macos_preset(hex_):
    lab = rgb2lab(hex2rgb(hex_))
    if chroma(lab) < 15: return -1
    h = colorsys.rgb_to_hsv(*hex2rgb(hex_))[0] * 360
    presets = [(0, 0), (30, 1), (52, 2), (120, 3), (215, 4), (275, 5), (325, 6), (360, 0)]
    return min(presets, key=lambda p: abs(p[0] - h))[1]

# ── a scheme built from the image itself ─────────────────────────────────────
def ok2rgb(ok):
    """Inverse of rgb2ok (same scaling); may be out of sRGB gamut."""
    L, a, b = ok[0] / 100, ok[1] / 400, ok[2] / 400
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    lin = (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
           -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
           -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    enc = lambda v: 12.92 * v if v <= 0.0031308 else 1.055 * max(v, 0) ** (1 / 2.4) - 0.055
    return tuple(enc(v) for v in lin)

def lch(L, C, h):
    """OKLCh (L 0–100, C in rgb2ok's ×400 units) → #RRGGBB, chroma reduced until it fits sRGB."""
    r = math.radians(h)
    while True:
        c = ok2rgb((L, C * math.cos(r), C * math.sin(r)))
        if all(-0.001 <= v <= 1.001 for v in c) or C <= 0:
            return rgb2hex(c)
        C -= 1

# Terminal colours keep their meaning (red is still red); each is pulled part of
# the way towards the image's nearest colour family so the terminal matches it.
ANSI_HUES = {1: 27, 2: 145, 3: 95, 4: 260, 5: 320, 6: 200}   # OKLab hues: red green yellow blue magenta cyan
DERIVED = {"BG": 21.5, "BG_DARK": 18, "SURFACE": 29, "MUTED": 42, "COMMENT": 56, "FG_DIM": 80, "FG": 90}  # OKLab L, ≈ the curated schemes

def derive_scheme(feat):
    """A scheme made only from the image: neutral roles in the image's own tint,
    accents from its colour families, terminal colours nudged towards them.
    Lightness steps match the curated dark schemes, so contrast stays the same."""
    t, fams = feat["tint"], feat["families"]
    if fams:
        th = hue(t) if chroma(t) > 1.5 else fams[0]["hue"]
    else:
        th = hue(t)
    tc = chroma(t)
    tint_c = 3 + 9 * math.tanh(tc / 12) if fams or tc > 1.5 else 0   # BG chroma 3–12: tinted, never coloured
    roles = {}
    for k, L in DERIVED.items():
        c = tint_c * {"FG": 0.6, "FG_DIM": 0.8}.get(k, 1)   # text keeps a hint of the tint, like curated schemes
        roles[k] = lch(L, c, th)
    vivid = max([f["chroma"] for f in fams] + [20])
    sat = min(1.0, vivid / 40)          # how colourful the image is overall: 0 (misty) … 1 (neon)
    accents = []
    for f in [f for f in fams if f["share"] >= 0.03][:6]:
        C = min(65, max(22, want_chroma(f)))
        accents += [lch(76, C, f["hue"]), lch(84, C * 0.8, f["hue"])]
    ansi = {}
    for i, h0 in ANSI_HUES.items():
        near = min(fams, key=lambda f: hue_diff(f["hue"], h0), default=None)
        h = h0
        if near and hue_diff(near["hue"], h0) < 30:
            d = (near["hue"] - h0 + 180) % 360 - 180
            h = (h0 + 0.6 * d) % 360
        C = 28 + 30 * sat
        ansi[i], ansi[i + 8] = lch(68, C, h), lch(78, C * 0.85, h)
        for c in (ansi[i + 8],):
            if c not in accents: accents.append(c)
    ansi[0], ansi[8] = lch(30, tint_c, th), lch(46, tint_c, th)
    ansi[7], ansi[15] = roles["FG_DIM"], roles["FG"]
    sel = lch(31, max(tint_c, 10), fams[0]["hue"] if fams else th)
    roles["SELECTION"] = sel
    return {"id": "image", "name": "From the image", "ghostty": "ghostty-theme",
            "roles": roles, "accents": accents, "ansi": ansi}

def ghostty_theme(scheme, roles):
    """Ghostty theme file text for a derived scheme (written next to palette.sh)."""
    lines = ["# made by shiny from the wallpaper (palette.py derive_scheme)"]
    lines += [f"palette = {i}={scheme['ansi'][i]}" for i in range(16)]
    lines += [f"background = {roles['BG']}", f"foreground = {roles['FG']}", f"cursor-color = {roles['ACCENT2']}",
              f"selection-background = {roles['SELECTION']}", f"selection-foreground = {roles['FG']}"]
    return "\n".join(lines) + "\n"

# ── palette files ─────────────────────────────────────────────────────────────
ROLES = ["BG", "BG_DARK", "SURFACE", "SELECTION", "MUTED", "COMMENT", "FG", "FG_DIM", "ACCENT", "ACCENT2"]
ROLE_DOC = {
    "BG": "window background", "BG_DARK": "frames, omnibox", "SURFACE": "borders, dividers, inactive window border",
    "SELECTION": "selected rows, text selection", "MUTED": "shortcuts, scrollbar", "COMMENT": "subtext, inactive tabs",
    "FG": "primary text", "FG_DIM": "secondary text",
    "ACCENT": "primary accent: focus border, icons, links, text highlight, icon tint",
    "ACCENT2": "secondary accent: cursor, shortcuts, search selection",
}

def build(scheme, feat, accent=None, accent2=None):
    """Final roles for a scheme + image: accents picked (or given), selection matched."""
    acc, acc2 = pick_accents(scheme, feat)
    acc, acc2 = (accent or acc).upper(), (accent2 or acc2).upper()
    r = dict(scheme["roles"])
    r["SELECTION"] = match_selection(r["SELECTION"], r["BG"], acc)
    r["ACCENT"], r["ACCENT2"] = acc, acc2
    return r

def palette_sh(scheme, roles, image, wallpaper="wallpaper.jpg"):
    lines = [
        f"# Generated by `shiny theme new` from {os.path.basename(image)}",
        (f"# Base scheme: {scheme['name']} — https://github.com/mbadolato/iTerm2-Color-Schemes (via Ghostty)"
         if scheme["id"] != "image" else "# Built from the image alone; terminal colours are in ghostty-theme next to this file."),
        "# Edit freely (see THEMES.md); `shiny theme check` lints it, `shiny theme set <name>` re-applies.",
        f'THEME_BASE="{scheme["name"]}"',
        f'GHOSTTY_THEME="{scheme["ghostty"]}"   # ' + ("file next to palette.sh" if scheme["id"] == "image" else "built-in: ghostty +list-themes"),
        f"ACCENT_PRESET={macos_preset(roles['ACCENT'])}   # macOS accent: -1 graphite 0 red 1 orange 2 yellow 3 green 4 blue 5 purple 6 pink",
        f'WALLPAPER="{wallpaper}"', "",
    ]
    for k in ROLES:
        lines.append(f'{k}="{roles[k]}"'.ljust(22) + f"# {ROLE_DOC[k]}")
    return "\n".join(lines)

def read_palette(path):
    """KEY="value" lines of a palette.sh, without sourcing it."""
    out = {}
    for line in open(path):
        m = re.match(r'\s*([A-Z_][A-Z0-9_]*)=("([^"]*)"|\'([^\']*)\'|([^\s#]*))', line)
        if m:
            out[m.group(1)] = next(g for g in (m.group(3), m.group(4), m.group(5)) if g is not None)
    return out

# ── lint ──────────────────────────────────────────────────────────────────────
def luminance(h):
    return sum(w * _lin(v) for w, v in zip((0.2126, 0.7152, 0.0722), hex2rgb(h)))

def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)

# (role, against, error below, warn below, what it's for)
CONTRAST_RULES = [
    ("FG", "BG", 4.5, 7.0, "primary text"),
    ("FG_DIM", "BG", 3.0, 4.5, "secondary text"),
    ("COMMENT", "BG", 1.8, 2.3, "subtext"),
    ("ACCENT", "BG", 2.0, 3.0, "links, focus border"),
    ("ACCENT2", "BG", 2.0, 3.0, "cursor, shortcuts"),
    ("FG", "SELECTION", 3.0, 4.5, "text on selected rows"),
    ("BG", "ACCENT", 2.0, 3.0, "text on the active bar pill"),
]

def check(path):
    """Problems with a palette.sh: [{level, role, msg}]. Errors break shiny-apply; warnings are taste."""
    p, out = read_palette(path), []
    err = lambda role, msg: out.append({"level": "error", "role": role, "msg": msg})
    warn = lambda role, msg: out.append({"level": "warn", "role": role, "msg": msg})
    ok = {}
    for r in ROLES:
        v = p.get(r, "")
        if re.fullmatch(r"#[0-9A-Fa-f]{6}", v): ok[r] = v.upper()
        else: err(r, f"missing or not #RRGGBB ({v or 'unset'})")
    g = p.get("GHOSTTY_THEME")
    if not g: err("GHOSTTY_THEME", "not set")
    elif not any(os.path.exists(os.path.join(d, g)) for d in THEME_DIRS + [os.path.dirname(os.path.abspath(path))]):
        warn("GHOSTTY_THEME", f"'{g}' not found next to palette.sh, in libexec/ghostty-themes or Ghostty.app")
    try:
        if int(p.get("ACCENT_PRESET", "4")) not in range(-1, 7): raise ValueError
    except ValueError:
        err("ACCENT_PRESET", "must be -1…6")
    wp = os.path.join(os.path.dirname(os.path.abspath(path)), p.get("WALLPAPER", "wallpaper.jpg"))
    if not os.path.isfile(wp): err("WALLPAPER", f"{os.path.basename(wp)} not found next to palette.sh")
    for role, other, bad, meh, what in CONTRAST_RULES:
        if role in ok and other in ok:
            c = contrast(ok[role], ok[other])
            if c < bad: err(role, f"{c:.1f}:1 against {other} — unreadable {what} (want ≥ {meh})")
            elif c < meh: warn(role, f"{c:.1f}:1 against {other} — low contrast for {what} (want ≥ {meh})")
    if "BG" in ok and "BG_DARK" in ok and luminance(ok["BG_DARK"]) > luminance(ok["BG"]):
        warn("BG_DARK", "lighter than BG — frames should read darker than the window")
    if "BG" in ok and "SURFACE" in ok and contrast(ok["SURFACE"], ok["BG"]) < 1.08:
        warn("SURFACE", "barely differs from BG — borders and the bar will vanish")
    if "ACCENT" in ok and "ACCENT2" in ok and ok["ACCENT"] == ok["ACCENT2"]:
        warn("ACCENT2", "same as ACCENT")
    if "BG" in ok and luminance(ok["BG"]) > 0.2:
        warn("BG", "light background — shiny's templates and blur are tuned for dark themes")
    return out

# ── main ──────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Build or lint a shiny theme palette.")
    ap.add_argument("image", nargs="?")
    ap.add_argument("--scheme", help="base scheme id (see: shiny theme schemes)")
    ap.add_argument("--accent", help="override primary accent (#RRGGBB)")
    ap.add_argument("--accent2", help="override secondary accent (#RRGGBB)")
    ap.add_argument("--wallpaper", default="wallpaper.jpg")
    ap.add_argument("--top", type=int, help="print the N best-fitting schemes")
    ap.add_argument("--candidates", action="store_true", help="JSON: the --top N (default 8) schemes, fully built")
    ap.add_argument("--json", action="store_true", help="JSON instead of palette.sh (or with --check)")
    ap.add_argument("--check", metavar="PALETTE", help="lint a palette.sh (exit 1 on errors)")
    ap.add_argument("--ghostty-out", metavar="FILE", help="with --scheme image: write its Ghostty theme here")
    a = ap.parse_args()
    for o in ("accent", "accent2"):
        v = getattr(a, o)
        if v and not re.fullmatch(r"#?[0-9A-Fa-f]{6}", v): ap.error(f"--{o} must be #RRGGBB")
        if v: setattr(a, o, "#" + v.lstrip("#"))

    if a.check:
        probs = check(a.check)
        if a.json: print(json.dumps(probs))
        else:
            for p in probs: print(f"{p['level']:5s}  {p['role']:<13s} {p['msg']}")
            if not probs: print("ok")
        sys.exit(1 if any(p["level"] == "error" for p in probs) else 0)
    if not a.image: ap.error("an image is required")

    try:
        feat = image_features(a.image)
    except (subprocess.CalledProcessError, OSError, ValueError, IndexError):
        raise SystemExit(f"palette.py: can't read image {a.image} (not an image sips understands?)")
    schemes = load_schemes()
    ranked = sorted(schemes, key=lambda s: score(s, feat))
    derived = derive_scheme(feat)
    if a.candidates:
        out = []
        for s in [derived] + ranked[:a.top or 8]:
            r = build(s, feat)
            out.append({"id": s["id"], "name": s["name"], "ghostty": s["ghostty"], "score": None if s is derived else round(score(s, feat), 1),
                        "roles": {k: r[k] for k in ROLES[:8]}, "accents": s["accents"],
                        "accent": r["ACCENT"], "accent2": r["ACCENT2"], "accent_preset": macos_preset(r["ACCENT"])})
        print(json.dumps({"image": os.path.abspath(a.image), "schemes": out}))
        return
    if a.top:
        for s in ranked[:a.top]:
            print(f"{score(s, feat):6.1f}  {s['id']:24s} {s['name']}")
        return
    if a.scheme:
        best = next((s for s in schemes + [derived] if s["id"] == a.scheme), None)
        if not best: raise SystemExit(f"unknown scheme {a.scheme} (see: shiny theme schemes)")
    else:
        best = ranked[0]
    r = build(best, feat, a.accent, a.accent2)
    if a.json:
        print(json.dumps({"scheme": best["id"], "roles": {k: r[k] for k in ROLES[:8]}, "accent": r["ACCENT"], "accent2": r["ACCENT2"]}))
        return
    if best is derived:
        if not a.ghostty_out: raise SystemExit("--scheme image needs --ghostty-out FILE for its terminal colours")
        with open(a.ghostty_out, "w") as f: f.write(ghostty_theme(best, r))
    print(palette_sh(best, r, a.image, a.wallpaper))

if __name__ == "__main__":
    main()
