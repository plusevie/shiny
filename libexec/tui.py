#!/usr/bin/python3
"""shiny tui — browse, preview, apply and create themes.

Stdlib only (runs under /usr/bin/python3 3.9). Raw ANSI truecolour, no curses.

  tui.py                         interactive
  tui.py --snapshot themes|wizard-schemes [--cols N --rows N] [--theme NAME] [--image PATH]
"""
import atexit, hashlib, json, os, re, select, shutil, signal, subprocess, sys, tempfile, unicodedata
import termios, threading, time, tty

HERE = os.path.dirname(os.path.abspath(__file__))
SHINY_HOME = os.environ.get("SHINY_HOME") or os.path.dirname(HERE)
CLI = os.path.join(SHINY_HOME, "bin", "shiny")
PALETTE = os.path.join(SHINY_HOME, "libexec", "palette.py")
STATE_DIR = os.path.expanduser("~/.config/shiny")
USER_THEMES = os.environ.get("SHINY_USER_THEMES") or os.path.join(STATE_DIR, "themes")
STOCK_THEMES = os.path.join(SHINY_HOME, "themes")
THUMB_DIR = os.path.expanduser("~/Library/Caches/shiny/thumbs")
THUMB_SIZE = 192
ROLES = ["BG", "BG_DARK", "SURFACE", "SELECTION", "MUTED", "COMMENT", "FG", "FG_DIM", "ACCENT", "ACCENT2"]
DEFAULT = {"BG": "#1A1B26", "BG_DARK": "#16161E", "SURFACE": "#292E42", "SELECTION": "#283457",
           "MUTED": "#414868", "COMMENT": "#565F89", "FG": "#C0CAF5", "FG_DIM": "#A9B1D6",
           "ACCENT": "#7AA2F7", "ACCENT2": "#FF9E64"}
RED, YELLOW = (224, 108, 117), (229, 192, 123)
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
BOLD, DIM, UNDER = 1, 2, 4
LOGO = ["███████╗██╗  ██╗██╗███╗   ██╗██╗   ██╗",
        "██╔════╝██║  ██║██║████╗  ██║╚██╗ ██╔╝",
        "███████╗███████║██║██╔██╗ ██║ ╚████╔╝ ",
        "╚════██║██╔══██║██║██║╚██╗██║  ╚██╔╝  ",
        "███████║██║  ██║██║██║ ╚████║   ██║   ",
        "╚══════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝   ╚═╝   "]
HELP = [("↑/↓  j/k", "move"), ("g / G", "top / bottom"), ("/", "filter by name"),
        ("enter", "apply theme"), ("n", "new theme from an image"), ("e", "edit palette"),
        ("d", "remove (your themes only)"), ("r", "reload current theme"), ("u", "update shiny"),
        ("s", "run setup"), ("?", "this help"), ("q / esc", "quit")]


# ── colours ───────────────────────────────────────────────────────────────────
def rgb(h):
    h = (h or "").strip().lstrip("#")
    try:
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    except ValueError:
        return (255, 0, 255)

def mix(a, b, t):
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))

def pal_rgb(p):
    return {r: rgb(p.get(r) or DEFAULT[r]) for r in ROLES}


# ── canvas: a cell buffer rendered once per frame ─────────────────────────────
def cell_width(c):
    if unicodedata.combining(c):
        return 0
    return 2 if unicodedata.east_asian_width(c) in "WF" else 1

def text_width(s):
    return sum(cell_width(c) for c in s)


class Canvas:
    def __init__(self, w, h, fg, bg):
        self.w, self.h, self.fg, self.bg = w, h, fg, bg
        self.ch = [[" "] * w for _ in range(h)]
        self.st = [[(fg, bg, 0)] * w for _ in range(h)]

    def put(self, x, y, s, fg=None, bg=None, attr=0, maxw=None):
        """Write s at (x, y); fg/bg None keep what's there. Returns x after the text."""
        if not 0 <= y < self.h:
            return x + text_width(s)
        end = x + max(0, maxw) if maxw is not None else None
        for c in s:
            cw = cell_width(c)
            if end is not None and x + cw > end:
                break
            for i in range(cw):  # a wide character fills two cells; the second is a "" placeholder
                if 0 <= x + i < self.w:
                    ofg, obg, _ = self.st[y][x + i]
                    self.ch[y][x + i] = c if i == 0 else ""
                    self.st[y][x + i] = (fg or ofg, bg or obg, attr)
            x += cw
        return x

    def fill(self, x, y, w, h, bg, ch=" ", fg=None):
        for yy in range(y, y + h):
            self.put(x, yy, ch * w, fg=fg, bg=bg)

    def box(self, x, y, w, h, fg, bg=None, title=""):
        if bg:
            self.fill(x, y, w, h, bg)
        self.put(x, y, "╭" + "─" * (w - 2) + "╮", fg)
        for yy in range(y + 1, y + h - 1):
            self.put(x, yy, "│", fg); self.put(x + w - 1, yy, "│", fg)
        self.put(x, y + h - 1, "╰" + "─" * (w - 2) + "╯", fg)
        if title:
            self.put(x + 2, y, " %s " % title, fg, attr=BOLD, maxw=w - 4)

    def render(self, positioned=True):
        out, last = [], None
        for y in range(self.h):
            out.append("\033[%d;1H" % (y + 1) if positioned else "")
            for x in range(self.w):
                st = self.st[y][x]
                if st != last:
                    fg, bg, a = st
                    sgr = "0"
                    if a & BOLD: sgr += ";1"
                    if a & DIM: sgr += ";2"
                    if a & UNDER: sgr += ";4"
                    out.append("\033[%s;38;2;%d;%d;%d;48;2;%d;%d;%dm" % ((sgr,) + fg + bg))
                    last = st
                out.append(self.ch[y][x])
            if not positioned:
                out.append("\033[0m\n"); last = None
        return "".join(out)


# ── themes ────────────────────────────────────────────────────────────────────
LINE_RE = re.compile(r"""^\s*([A-Z_][A-Z0-9_]*)=(?:"([^"]*)"|'([^']*)'|([^\s#]*))""")

def parse_palette(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE_RE.match(line)
            if m:
                out[m.group(1)] = next(g for g in m.groups()[1:] if g is not None)
    return out

def load_themes():
    themes, seen = [], set()
    for root, kind in ((USER_THEMES, "yours"), (STOCK_THEMES, "stock")):
        try:
            names = sorted(os.listdir(root))
        except OSError:
            continue
        for n in names:
            pf = os.path.join(root, n, "palette.sh")
            if n in seen or not os.path.isfile(pf):
                continue
            seen.add(n)
            try:
                p = parse_palette(pf)
            except OSError:
                continue
            wp = os.path.join(root, n, p.get("WALLPAPER") or "wallpaper.jpg")
            themes.append({"name": n, "kind": kind, "palette": p, "path": pf, "wallpaper": wp})
    return themes

def current_name():
    try:
        with open(os.path.join(STATE_DIR, "current")) as f:
            return f.read().strip()
    except OSError:
        return ""


# ── images: sips → BMP → cached RGB thumbnail ────────────────────────────────
def read_bmp(path):
    b = open(path, "rb").read()
    off = int.from_bytes(b[10:14], "little")
    w = int.from_bytes(b[18:22], "little", signed=True)
    h = int.from_bytes(b[22:26], "little", signed=True)
    n = int.from_bytes(b[28:30], "little") // 8
    row = (w * n + 3) // 4 * 4
    rows = []
    for y in range(abs(h)):
        base = off + y * row
        rows.append([(b[base + x * n + 2], b[base + x * n + 1], b[base + x * n]) for x in range(w)])
    if h > 0:  # bottom-up
        rows.reverse()
    return w, abs(h), rows

def thumb_key(path):
    st = os.stat(path)
    return hashlib.sha1(("%s|%d|%d|%d" % (path, st.st_mtime_ns, st.st_size, THUMB_SIZE)).encode()).hexdigest()

def load_thumb(path):
    """(w, h, rows) for an image, via the on-disk cache. Raises on unreadable images."""
    cache = os.path.join(THUMB_DIR, thumb_key(path) + ".rgb")
    try:
        with open(cache, "rb") as f:
            hdr, data = f.read().split(b"\n", 1)
        w, h = map(int, hdr.split())
        return w, h, [[tuple(data[(y * w + x) * 3:(y * w + x) * 3 + 3]) for x in range(w)] for y in range(h)]
    except (OSError, ValueError):
        pass
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "t.bmp")
        r = subprocess.run(["sips", "-Z", str(THUMB_SIZE), "-s", "format", "bmp", path, "--out", out],
                           capture_output=True, text=True)
        if r.returncode or not os.path.exists(out):
            raise RuntimeError((r.stderr or r.stdout or "sips failed").strip())
        w, h, rows = read_bmp(out)
    try:
        os.makedirs(THUMB_DIR, exist_ok=True)
        with open(cache + ".tmp", "wb") as f:
            f.write(b"%d %d\n" % (w, h) + bytes(c for row in rows for px in row for c in px))
        os.replace(cache + ".tmp", cache)
    except OSError:
        pass
    return w, h, rows

def resample(img, tw, th):
    w, h, rows = img
    out = []
    for ty in range(th):
        y0, y1 = ty * h // th, max(ty * h // th + 1, (ty + 1) * h // th)
        line = []
        for tx in range(tw):
            x0, x1 = tx * w // tw, max(tx * w // tw + 1, (tx + 1) * w // tw)
            r = g = b = n = 0
            for yy in range(y0, y1):
                for px in rows[yy][x0:x1]:
                    r += px[0]; g += px[1]; b += px[2]; n += 1
            line.append((r // n, g // n, b // n))
        out.append(line)
    return out

def screen_aspect():
    """Width/height of the main display, so previews are shaped like the desktop they'll be on."""
    try:
        r = subprocess.run(["osascript", "-l", "JavaScript", "-e",
                            'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.frame; f.size.width / f.size.height'],
                           capture_output=True, text=True, timeout=3)
        a = float(r.stdout)
        if 0.3 < a < 5:
            return a
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return 16 / 10

SCREEN_ASPECT = screen_aspect()

def cover(img, aspect):
    """Centre-crop an image to aspect (w/h) — what macOS's "Fill Screen" shows."""
    w, h, rows = img
    if w / h > aspect:
        cw = max(1, round(h * aspect)); x0 = (w - cw) // 2
        return cw, h, [r[x0:x0 + cw] for r in rows]
    ch = max(1, round(w / aspect)); y0 = (h - ch) // 2
    return w, ch, rows[y0:y0 + ch]

def fit(aspect, maxw, maxh):
    """Cell size (cols, rows) of the largest aspect-shaped box in maxw×maxh cells (half-blocks ≈ square pixels)."""
    tw, th = maxw, max(2, round(maxw / aspect))
    if th > maxh * 2:
        th = maxh * 2; tw = max(1, round(th * aspect))
    return tw, (th + 1) // 2


# ── background jobs (thumbnails, lint, candidates) ───────────────────────────
class Jobs:
    def __init__(self, wake):
        self.wake, self.results, self.pending = wake, {}, []
        self.cv = threading.Condition()
        self.queued = set()
        threading.Thread(target=self._run, daemon=True).start()

    def get(self, key, fn, urgent=True):
        """Result for key, or None while it's computing (queued on first ask)."""
        if key in self.results:
            return self.results[key]
        with self.cv:
            if key not in self.queued:
                self.queued.add(key)
                self.pending.insert(0, (key, fn)) if urgent else self.pending.append((key, fn))
                self.cv.notify()
            elif urgent:
                for i, (k, f) in enumerate(self.pending):
                    if k == key:
                        self.pending.insert(0, self.pending.pop(i)); break
        return None

    def _run(self):
        while True:
            with self.cv:
                while not self.pending:
                    self.cv.wait()
                key, fn = self.pending.pop(0)
            try:
                res = ("ok", fn())
            except Exception as e:  # noqa: BLE001 — shown to the user
                res = ("err", str(e) or e.__class__.__name__)
            self.results[key] = res
            with self.cv:
                self.queued.discard(key)
            self.wake()

    def forget(self, prefix):
        for k in [k for k in self.results if k[0] == prefix]:
            del self.results[k]

class SyncJobs:
    """Same interface, computed inline (snapshot mode)."""
    def __init__(self):
        self.results = {}
    def get(self, key, fn, urgent=True):
        if key not in self.results:
            try:
                self.results[key] = ("ok", fn())
            except Exception as e:  # noqa: BLE001
                self.results[key] = ("err", str(e))
        return self.results[key]
    def forget(self, prefix):
        pass

def run_check(path):
    r = subprocess.run(["/usr/bin/python3", PALETTE, "--check", path, "--json"], capture_output=True, text=True)
    if r.returncode not in (0, 1):
        return []
    try:
        data = json.loads(r.stdout)
        return [d for d in data if isinstance(d, dict) and "msg" in d]
    except ValueError:
        return []

def run_candidates(img):
    r = subprocess.run(["/usr/bin/python3", PALETTE, img, "--candidates", "--top", "8"],
                       capture_output=True, text=True)
    if r.returncode:
        err = [l for l in (r.stderr or r.stdout or "").strip().splitlines() if l.strip()]
        if "Traceback (most recent call last)" in (r.stderr or ""):  # keep just the exception
            err = ["palette.py failed — is this an image sips can read?", "", err[-1][:240]]
        raise RuntimeError("\n".join(err[-6:]) or "palette.py failed (exit %d)" % r.returncode)
    try:
        data = json.loads(r.stdout)
        if not data.get("schemes"):
            raise ValueError
        return data["schemes"]
    except (ValueError, AttributeError):
        raise RuntimeError("palette.py --candidates gave unexpected output:\n" + (r.stdout or r.stderr)[:400])


# ── input ─────────────────────────────────────────────────────────────────────
SEQ = {"[A": "up", "[B": "down", "[C": "right", "[D": "left", "OA": "up", "OB": "down", "OC": "right",
       "OD": "left", "[H": "home", "[F": "end", "[1~": "home", "[4~": "end", "[5~": "pgup",
       "[6~": "pgdn", "[3~": "delete", "OH": "home", "OF": "end"}

def parse_keys(data):
    keys, i = [], 0
    s = data.decode("utf-8", errors="replace")
    while i < len(s):
        c = s[i]
        if c == "\x1b":
            m = re.match(r"\x1b(\[[0-9;]*[A-Za-z~]|O[A-Za-z])", s[i:])
            if m:
                keys.append(SEQ.get(m.group(1), "unknown")); i += len(m.group(0)); continue
            keys.append("esc"); i += 1; continue
        keys.append({"\r": "enter", "\n": "enter", "\x7f": "backspace", "\x08": "backspace", "\t": "tab",
                     "\x15": "ctrl-u", "\x03": "ctrl-c", "\x17": "ctrl-w"}.get(c, c))
        i += 1
    return keys

def clean_path(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        s = s[1:-1]
    s = re.sub(r"\\(.)", r"\1", s)
    return os.path.expanduser(s.strip())

def slug(path):
    s = os.path.splitext(os.path.basename(path))[0].lower()
    s = re.sub(r"^shiny-", "", s)
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")

class LineEdit:
    def __init__(self, text=""):
        self.text, self.pos = text, len(text)
    def key(self, k):
        if k == "backspace" and self.pos:
            self.text = self.text[:self.pos - 1] + self.text[self.pos:]; self.pos -= 1
        elif k == "delete":
            self.text = self.text[:self.pos] + self.text[self.pos + 1:]
        elif k == "ctrl-u":
            self.text, self.pos = self.text[self.pos:], 0
        elif k == "ctrl-w":
            head = re.sub(r"\S*\s*$", "", self.text[:self.pos])
            self.text, self.pos = head + self.text[self.pos:], len(head)
        elif k == "left":
            self.pos = max(0, self.pos - 1)
        elif k == "right":
            self.pos = min(len(self.text), self.pos + 1)
        elif k == "home":
            self.pos = 0
        elif k == "end":
            self.pos = len(self.text)
        elif len(k) == 1 and k.isprintable():
            self.text = self.text[:self.pos] + k + self.text[self.pos:]; self.pos += 1
        else:
            return False
        return True


# ── app ───────────────────────────────────────────────────────────────────────
class Wizard:
    def __init__(self):
        self.step = "image"           # image → schemes → accent → name → confirm
        self.path = LineEdit()
        self.error = ""
        self.image = ""
        self.schemes, self.sel = None, 0
        self.accents, self.acc_cur, self.acc_phase, self.acc = [], 0, 0, [0, 0]
        self.digits, self.digit_t = "", 0.0
        self.name = LineEdit()

    def scheme(self):
        return self.schemes[self.sel] if self.schemes else None

    def palette(self):
        s = self.scheme()
        if not s:
            return dict(DEFAULT)
        p = dict(DEFAULT); p.update(s.get("roles") or {})
        if self.step in ("accent", "name", "confirm") and self.accents:
            p["ACCENT"], p["ACCENT2"] = self.accents[self.acc[0]], self.accents[self.acc[1]]
        else:
            p["ACCENT"], p["ACCENT2"] = s.get("accent", p["ACCENT"]), s.get("accent2", p["ACCENT2"])
        p["THEME_BASE"] = s.get("name", "")
        return p


class App:
    def __init__(self, cols=80, rows=24, jobs=None):
        self.cols, self.rows = cols, rows
        self.jobs = jobs or SyncJobs()
        self.mode = "themes"          # themes | filter | confirm | help | wizard
        self.filter = LineEdit()
        self.sel, self.top = 0, 0
        self.wiz = None
        self.message = None           # (title, text) box over everything
        self.quit = False
        self.pending_cmd = None       # (argv, stdin_devnull, select_after) run by the loop
        self.tick = 0
        self.reload()

    # data
    def reload(self, select=None):
        prev = select or (self.shown()[self.sel]["name"] if getattr(self, "themes", None) and self.shown() else None)
        self.themes = load_themes()
        self.current = current_name()
        self.jobs.forget("lint")
        cur = next((t for t in self.themes if t["name"] == self.current), None)
        self.ui = pal_rgb(cur["palette"] if cur else DEFAULT)
        self.ui_base = cur["palette"].get("THEME_BASE", "") if cur else ""
        names = [t["name"] for t in self.shown()]
        target = prev if prev in names else self.current
        self.sel = names.index(target) if target in names else 0

    def shown(self):
        q = self.filter.text.lower()
        return [t for t in self.themes if q in t["name"].lower()]

    def thumb(self, path, urgent=True):
        return self.jobs.get(("thumb", path), lambda: load_thumb(path), urgent)

    def lint(self, t):
        return self.jobs.get(("lint", t["path"]), lambda: run_check(t["path"]))

    # ── keys ──
    def key(self, k):
        if k == "ctrl-c":
            self.quit = True; return
        if self.message:
            self.message = None; return
        getattr(self, "key_" + self.mode)(k)

    def key_help(self, k):
        self.mode = "themes"

    def key_confirm(self, k):
        t = self.shown()[self.sel]
        self.mode = "themes"
        if k in ("y", "Y"):
            self.pending_cmd = (["theme", "remove", t["name"]], True, None)

    def key_filter(self, k):
        if k == "esc":
            self.filter = LineEdit(); self.mode = "themes"; self.sel = 0
        elif k in ("enter", "up", "down"):
            self.mode = "themes"
            if k != "enter":
                self.key_themes(k)
        elif self.filter.key(k):
            self.sel = 0

    def key_themes(self, k):
        shown = self.shown()
        n = len(shown)
        t = shown[self.sel] if n else None
        if k in ("q", "esc"):
            if k == "esc" and self.filter.text:
                self.filter = LineEdit(); self.reload(); return
            self.quit = True
        elif k in ("down", "j") and n:
            self.sel = min(n - 1, self.sel + 1)
        elif k in ("up", "k") and n:
            self.sel = max(0, self.sel - 1)
        elif k in ("g", "home"):
            self.sel = 0
        elif k in ("G", "end") and n:
            self.sel = n - 1
        elif k == "pgdn" and n:
            self.sel = min(n - 1, self.sel + 10)
        elif k == "pgup":
            self.sel = max(0, self.sel - 10)
        elif k == "/":
            self.mode = "filter"
        elif k == "?":
            self.mode = "help"
        elif k == "n":
            self.wiz = Wizard(); self.mode = "wizard"
        elif k == "enter" and t:
            self.pending_cmd = (["theme", "set", t["name"]], False, t["name"])
        elif k == "e" and t:
            self.pending_cmd = (["theme", "edit", t["name"]], False, t["name"])
        elif k == "d" and t:
            if t["kind"] == "yours":
                self.mode = "confirm"
            else:
                self.message = ("can't remove", "'%s' is a stock theme and ships with shiny — only your own "
                                "themes can be removed." % t["name"])
        elif k == "r":
            self.pending_cmd = (["theme", "reload"], False, None)
        elif k == "u":
            self.pending_cmd = (["update"], False, None)
        elif k == "s":
            self.pending_cmd = (["setup"], False, None)

    def key_wizard(self, k):
        w = self.wiz
        if w.step == "image":
            if k == "esc":
                self.mode, self.wiz = "themes", None
            elif k == "enter":
                p = clean_path(w.path.text)
                if not p:
                    w.error = "drop an image here, or type its path"
                elif not os.path.isfile(p):
                    w.error = "no such file: " + p
                else:
                    w.image, w.error, w.schemes = os.path.abspath(p), "", None
                    w.step = "loading"
                    self.thumb(w.image)
            elif w.path.key(k):
                w.error = ""
        elif w.step == "loading":
            if k == "esc":
                w.step = "image"
        elif w.step == "schemes":
            if k == "esc":
                w.step = "image"
            elif k in ("down", "j"):
                w.sel = min(len(w.schemes) - 1, w.sel + 1)
            elif k in ("up", "k"):
                w.sel = max(0, w.sel - 1)
            elif k == "enter":
                s = w.scheme()
                acc = [a.upper() for a in s.get("accents") or []]
                for a in (s.get("accent2"), s.get("accent")):
                    if a and a.upper() not in acc:
                        acc.insert(0, a.upper())
                w.accents = acc or [DEFAULT["ACCENT"], DEFAULT["ACCENT2"]]
                ix = lambda h, d: acc.index(h.upper()) if h and h.upper() in acc else d
                w.acc = [ix(s.get("accent"), 0), ix(s.get("accent2"), min(1, len(w.accents) - 1))]
                w.acc_phase, w.acc_cur, w.step = 0, w.acc[0], "accent"
        elif w.step == "accent":
            n = len(w.accents)
            if k == "esc":
                if w.acc_phase:
                    w.acc_phase, w.acc_cur = 0, w.acc[0]
                else:
                    w.step = "schemes"
            elif k in ("right", "l", "down", "j", "tab"):
                w.acc_cur = (w.acc_cur + 1) % n
            elif k in ("left", "h", "up", "k"):
                w.acc_cur = (w.acc_cur - 1) % n
            elif k.isdigit():
                # Digits jump to an accent; a second digit within a second makes 10–99.
                now = time.time()
                num = int(w.digits + k) if w.digits and now - w.digit_t < 1.0 else int(k)
                if not 1 <= num <= n:
                    num = int(k)
                w.digits, w.digit_t = (str(num) if num * 10 <= n else ""), now
                if 1 <= num <= n:
                    w.acc_cur = num - 1
            elif k == "enter":
                w.acc[w.acc_phase] = w.acc_cur
                if w.acc_phase == 0:
                    w.acc_phase, w.acc_cur = 1, w.acc[1]
                else:
                    w.step = "name"
                    if not w.name.text:
                        w.name = LineEdit(slug(w.image) or "my-theme")
            if w.step == "accent":
                w.acc[w.acc_phase] = w.acc_cur  # live preview
        elif w.step == "name":
            if k == "esc":
                w.step, w.acc_phase, w.acc_cur = "accent", 1, w.acc[1]
            elif k == "enter":
                if NAME_RE.match(w.name.text):
                    w.error, w.step = "", "confirm"
                else:
                    w.error = "lowercase letters, numbers and dashes (start with a letter or number)"
            elif w.name.key(k):
                w.error = ""
        elif w.step == "confirm":
            if k == "esc":
                w.step = "name"
            elif k in ("s", "a"):
                s = w.scheme()
                argv = ["theme", "new", "-i", w.image, "-n", w.name.text, "--scheme", s["id"],
                        "--accent", w.accents[w.acc[0]], "--accent2", w.accents[w.acc[1]]]
                if k == "a":
                    argv.append("--set")
                self.pending_cmd = (argv, False, w.name.text)
                self.mode, self.wiz = "themes", None

    def poll(self):
        """Advance async state (wizard loading)."""
        w = self.wiz
        if self.mode == "wizard" and w and w.step == "loading":
            res = self.jobs.get(("cand", w.image), lambda: run_candidates(w.image))
            if res and res[0] == "ok":
                w.schemes, w.sel, w.step = res[1], 0, "schemes"
            elif res:
                self.jobs.results.pop(("cand", w.image), None)
                w.step = "image"
                self.message = ("couldn't read colours", res[1])

    # ── drawing ──
    def draw(self):
        self.tick += 1
        self.poll()
        u = self.ui
        c = Canvas(self.cols, self.rows, u["FG"], u["BG"])
        if self.cols < 56 or self.rows < 16:
            msg = ["make the window bigger", "(%d×%d, need 56×16)" % (self.cols, self.rows)]
            for i, m in enumerate(msg):
                c.put(max(0, (self.cols - text_width(m)) // 2), self.rows // 2 - 1 + i, m, u["FG"] if i == 0 else u["COMMENT"])
            return c
        y = self.draw_header(c)
        body_h = self.rows - y - 1
        if self.mode == "wizard":
            self.draw_wizard(c, y, body_h)
        else:
            self.draw_themes(c, y, body_h)
        self.draw_footer(c)
        if self.mode == "help":
            self.draw_help(c)
        elif self.mode == "confirm":
            t = self.shown()[self.sel]
            self.draw_box(c, "remove theme", "Delete '%s' from your themes?\n\n[y] yes   [N] no" % t["name"])
        if self.message:
            self.draw_box(c, self.message[0], self.message[1] + "\n\npress any key")
        return c

    def draw_header(self, c):
        u, sub = self.ui, "%s · %s" % (self.current or "no theme", self.ui_base or "custom")
        if self.cols < 70 or self.rows < 30:
            x = c.put(1, 0, "✦ shiny", u["ACCENT"], attr=BOLD)
            c.put(x + 2, 0, sub, u["COMMENT"], maxw=self.cols - x - 3)
            return 2
        lw = len(LOGO[0])
        x0 = (self.cols - lw) // 2
        for i, line in enumerate(LOGO):
            for j, ch in enumerate(line):
                if ch == " ":
                    continue
                col = mix(u["ACCENT"], u["ACCENT2"], j / (lw - 1))
                c.put(x0 + j, 1 + i, ch, col if ch == "█" else mix(col, u["BG"], 0.55))
        c.put((self.cols - text_width(sub)) // 2, 7, sub, u["FG_DIM"])
        return 9

    def draw_footer(self, c):
        u = self.ui
        if self.mode == "filter":
            hints = [("type", "filter"), ("enter", "keep"), ("esc", "clear")]
        elif self.mode == "wizard":
            hints = {"image": [("enter", "next"), ("ctrl-u", "clear"), ("esc", "back")],
                     "loading": [("esc", "cancel")],
                     "schemes": [("↑/↓", "scheme"), ("enter", "next"), ("esc", "back")],
                     "accent": [("←/→ 1-9", "accent"), ("enter", "pick"), ("esc", "back")],
                     "name": [("enter", "next"), ("esc", "back")],
                     "confirm": [("s", "save"), ("a", "apply + save"), ("esc", "back")]}[self.wiz.step]
        else:
            hints = [("↵", "apply"), ("n", "new"), ("e", "edit"), ("d", "remove"), ("/", "filter"),
                     ("r", "reload"), ("u", "update"), ("s", "setup"), ("?", "help"), ("q", "quit")]
        if sum(len(k) + len(v) + 3 for k, v in hints) > self.cols - 2:
            hints = [hk for hk in hints if hk[0] not in ("r", "u", "s", "e")]
        y, x = self.rows - 1, 1
        c.fill(0, y, self.cols, 1, u["BG_DARK"])
        for k, what in hints:
            if x + len(k) + len(what) + 3 > self.cols:
                break
            x = c.put(x, y, k, u["ACCENT"], attr=BOLD)
            x = c.put(x + 1, y, what, u["COMMENT"]) + 2

    def draw_themes(self, c, y, h):
        u, shown = self.ui, self.shown()
        namew = min(16, max([text_width(t["name"]) for t in self.themes] + [8]))
        lw = min(self.cols // 2, namew + 23)
        # left: list
        title = "themes"
        if self.mode == "filter" or self.filter.text:
            title = "/" + self.filter.text + ("▏" if self.mode == "filter" else "")
        c.put(2, y, title, u["ACCENT"] if self.mode == "filter" else u["FG_DIM"], attr=BOLD, maxw=lw - 3)
        list_h = h - 2
        if not shown:
            c.put(2, y + 2, "no themes found" if not self.themes else "no matches", u["COMMENT"])
        self.sel = min(self.sel, max(0, len(shown) - 1))
        self.top = min(max(self.top, self.sel - list_h + 1), self.sel)
        self.top = max(0, min(self.top, max(0, len(shown) - list_h)))
        for i, t in enumerate(shown[self.top:self.top + list_h]):
            ry, here = y + 2 + i, self.top + i == self.sel
            if here:
                c.fill(1, ry, lw - 2, 1, u["SELECTION"])
                c.put(1, ry, "▌", u["ACCENT"])
            c.put(2, ry, "*" if t["name"] == self.current else " ", u["ACCENT2"], attr=BOLD)
            c.put(4, ry, t["name"][:lw - 23], u["FG"] if here else u["FG_DIM"], attr=BOLD if here else 0)
            p = pal_rgb(t["palette"])
            sx = lw - 17
            for j, r in enumerate(("BG", "SURFACE", "FG", "ACCENT", "ACCENT2")):
                c.put(sx + j * 2, ry, "  ", bg=p[r])
            c.put(lw - 6, ry, t["kind"], u["ACCENT"] if t["kind"] == "yours" else u["COMMENT"])
        if len(shown) > list_h:
            c.put(lw - 6, y, "%d/%d" % (self.sel + 1, len(shown)), u["COMMENT"])
        for yy in range(y, y + h):
            c.put(lw, yy, "│", u["SURFACE"])
        # right: preview
        if shown:
            self.draw_preview(c, shown[self.sel], lw + 2, y, self.cols - lw - 3, h)
        elif not self.themes:
            c.put(lw + 2, y + 2, "Make one from an image with n, or check %s" % STOCK_THEMES, u["COMMENT"],
                  maxw=self.cols - lw - 3)

    def draw_preview(self, c, t, x, y, w, h):
        u, p = self.ui, t["palette"]
        c.put(x, y, t["name"], u["FG"], attr=BOLD)
        c.put(x + text_width(t["name"]) + 2, y, "%s · ghostty: %s" % (p.get("THEME_BASE", "custom"), p.get("GHOSTTY_THEME", "?")),
              u["COMMENT"], maxw=w - text_width(t["name"]) - 2)
        lint = self.lint(t)
        lint = lint[1] if lint and lint[0] == "ok" else []
        bh = self.draw_palette(c, pal_rgb(p), x, None, w)  # measure only
        lint_h = min(len(lint), 4, max(1, h - 3 - bh - 7))  # keep ≥ 6 rows for the wallpaper
        ly = y + h - lint_h - (1 if lint_h else 0) - bh
        self.draw_image(c, t["wallpaper"], x, y + 2, w, ly - y - 3)
        self.draw_palette(c, pal_rgb(p), x, ly, w)
        for i, d in enumerate(lint[:lint_h]):
            lvl = d.get("level", "warn")
            col = RED if lvl == "error" else YELLOW
            yy = y + h - lint_h + i
            xx = c.put(x, yy, "✖ " if lvl == "error" else "▲ ", col)
            if d.get("role"):
                xx = c.put(xx, yy, d["role"] + " ", col, attr=BOLD)
            more = len(lint) - lint_h if i == lint_h - 1 and len(lint) > lint_h else 0
            tail = "  +%d more" % more if more else ""
            xx = c.put(xx, yy, d.get("msg", ""), u["FG_DIM"], maxw=x + w - xx - len(tail))
            c.put(xx, yy, tail, u["COMMENT"])

    def draw_palette(self, c, p, x, y, w):
        """Roles + mock window, side by side when there's room. y=None just measures. Returns height."""
        if w - 44 >= 30:
            cols, mx, mw, mock_y, bh = 2, x + 44, min(w - 44, 46), 0, 9
        elif w - 22 >= 22:
            cols, mx, mw, mock_y, bh = 1, x + 22, min(w - 22, 46), 0, 10
        else:
            cols, mx, mw, mock_y, bh = 1, x, min(w, 46), 11, 20
        if y is not None:
            self.draw_roles(c, p, x, y + (2 if cols == 2 else 0), cols)
            self.draw_mock(c, p, mx, y + mock_y, mw)
        return bh

    def draw_image(self, c, path, x, y, w, h):
        u = self.ui
        if h < 3 or w < 6:
            return
        res = self.thumb(path)
        if not res:
            c.put(x, y + h // 2, "%s loading preview…" % SPIN[self.tick % len(SPIN)], u["COMMENT"])
            return
        if res[0] != "ok":
            c.put(x, y + h // 2, "(no preview: %s)" % res[1].splitlines()[0][:w - 14], u["COMMENT"], maxw=w)
            return
        # Every preview is the same size: the screen's shape, filled like the desktop.
        tw, th = fit(SCREEN_ASPECT, w, h)
        key = ("px", path, tw, th)
        px = self.jobs.results.get(key)
        if px is None:
            px = self.jobs.results[key] = resample(cover(res[1], SCREEN_ASPECT), tw, th * 2)
        for ry in range(th):
            top, bot = px[ry * 2], px[ry * 2 + 1] if ry * 2 + 1 < len(px) else px[ry * 2]
            for rx in range(tw):
                c.put(x + rx, y + ry, "▀", top[rx], bot[rx])

    def draw_roles(self, c, p, x, y, cols=2):
        u, per = self.ui, 5 if cols == 2 else 10
        for i, r in enumerate(ROLES):
            cx, cy = x + (i // per) * 22, y + i % per
            c.put(cx, cy, "  ", bg=p[r])
            c.put(cx + 3, cy, r, u["FG_DIM"])
            c.put(cx + 13, cy, "#%02X%02X%02X" % p[r], u["COMMENT"])

    def draw_mock(self, c, p, x, y, w):
        """A tiny editor/terminal window drawn in the palette: 9 rows."""
        if w < 22:
            return
        c.fill(x, y, w, 9, p["BG"])
        c.box(x, y, w, 9, p["SURFACE"])
        c.fill(x + 1, y + 1, w - 2, 1, p["BG_DARK"])
        c.put(x + 2, y + 1, "● ● ●", p["MUTED"])
        c.put(x + 9, y + 1, "shine.py", p["FG_DIM"])
        iw = w - 4
        rows = [[("def ", p["ACCENT"], 0), ("shine", p["FG"], BOLD), ("(img):", p["FG"], 0)],
                [("  # one image, ten roles", p["COMMENT"], 0)],
                [("  roles = palette(img)", p["FG"], 0)],
                [("  return ", p["ACCENT"], 0), ("roles", p["FG_DIM"], 0)],
                [("  see ", p["FG_DIM"], 0), ("plusevie/shiny", p["ACCENT"], UNDER)],
                [("❯ ", p["ACCENT2"], BOLD), ("shiny theme set ", p["FG"], 0)]]
        for i, parts in enumerate(rows):
            ry = y + 2 + i
            if i == 2:
                c.fill(x + 1, ry, w - 2, 1, p["SELECTION"])
            xx = x + 2
            for s, fg, a in parts:
                xx = c.put(xx, ry, s, fg, attr=a, maxw=x + 2 + iw - xx)
            if i == 5 and xx < x + w - 2:
                c.put(xx, ry, " ", bg=p["ACCENT2"])

    def draw_box(self, c, title, text):
        u = self.ui
        bw = min(self.cols - 4, max(36, min(72, max(len(l) for l in text.splitlines()) + 6)))
        lines = []
        for para in text.splitlines():
            while len(para) > bw - 4:
                cut = para.rfind(" ", 0, bw - 4)
                cut = cut if cut > 0 else bw - 4
                lines.append(para[:cut]); para = para[cut:].lstrip()
            lines.append(para)
        lines = lines[:self.rows - 6]
        bh = len(lines) + 4
        bx, by = (self.cols - bw) // 2, max(0, (self.rows - bh) // 2)
        c.box(bx, by, bw, bh, u["ACCENT"], u["BG_DARK"], title)
        for i, l in enumerate(lines):
            c.put(bx + 2, by + 2 + i, l, u["FG"])

    def draw_help(self, c):
        self.draw_box(c, "keys", "\n".join("%-10s %s" % kv for kv in HELP))

    # wizard
    def draw_wizard(self, c, y, h):
        u, w = self.ui, self.wiz
        steps = [("image", "image"), ("schemes", "scheme"), ("accent", "accents"), ("name", "name"), ("confirm", "save")]
        cur = "schemes" if w.step == "loading" else w.step
        x = c.put(2, y, "new theme  ", u["FG"], attr=BOLD)
        for i, (k, label) in enumerate(steps):
            on = k == cur
            x = c.put(x, y, "%d %s" % (i + 1, label), u["ACCENT"] if on else u["COMMENT"], attr=BOLD if on else 0)
            if i < len(steps) - 1:
                x = c.put(x, y, "  ›  ", u["MUTED"])
        y, h = y + 2, h - 2
        if w.step == "image":
            bw = min(self.cols - 4, 80)
            c.put(2, y, "Drag an image from Finder into this window, or type its path:", u["FG_DIM"])
            c.box(2, y + 1, bw, 3, u["ACCENT"])
            t = w.path.text
            vis = max(0, w.path.pos - (bw - 6))
            c.put(4, y + 2, t[vis:vis + bw - 5], u["FG"])
            cx = 4 + w.path.pos - vis
            c.put(cx, y + 2, (t[w.path.pos:w.path.pos + 1] or " "), u["BG"], u["ACCENT2"])
            if w.error:
                c.put(4, y + 4, w.error, RED, maxw=self.cols - 6)
            c.put(4, y + 6, "Quotes and backslash-escaped spaces are fine; ~ is expanded.", u["COMMENT"])
            return
        lw = max(32, min(48, self.cols * 2 // 5))
        for yy in range(y, y + h):
            c.put(lw, yy, "│", u["SURFACE"])
        # left: image, then the step's widget
        widget_h = {"loading": 3, "schemes": 10, "accent": 4 + 2 * ((len(w.accents) - 1) // max(1, (lw - 3) // 5) + 1) + 2, "name": 6, "confirm": 9}[w.step]
        img_h = max(0, min(h - widget_h - 1, (lw - 4) * 9 // 32 + 1))
        self.draw_image(c, w.image, 2, y, lw - 4, img_h)
        wy = y + img_h + 1 if img_h >= 3 else y
        getattr(self, "draw_wiz_" + w.step)(c, w, 2, wy, lw - 4, y + h - wy)
        # right: palette + mock
        if w.step != "loading":
            rx, rw = lw + 2, self.cols - lw - 3
            p = w.palette()
            c.put(rx, y, w.name.text or slug(w.image) or "new theme", u["FG"], attr=BOLD)
            c.put(rx, y + 1, "%s · ghostty: %s" % (p.get("THEME_BASE"), w.scheme().get("ghostty", "?")), u["COMMENT"], maxw=rw)
            if self.draw_palette(c, pal_rgb(p), rx, None, rw) <= h - 3:
                self.draw_palette(c, pal_rgb(p), rx, y + 3, rw)
            else:
                self.draw_roles(c, pal_rgb(p), rx, y + 3, 1 if rw < 44 else 2)

    def draw_wiz_loading(self, c, w, x, y, wd, h):
        c.put(x, y, "%s reading colours…" % SPIN[self.tick % len(SPIN)], self.ui["ACCENT"])
        c.put(x, y + 1, os.path.basename(w.image), self.ui["COMMENT"], maxw=wd)

    def draw_wiz_schemes(self, c, w, x, y, wd, h):
        u = self.ui
        c.put(x, y, "from the image, or the closest schemes", u["FG_DIM"], attr=BOLD, maxw=wd)
        top = max(0, min(w.sel - (h - 2) + 1, len(w.schemes) - (h - 1)))
        for i, s in enumerate(w.schemes[top:top + h - 1]):
            ry, here = y + 1 + i, top + i == w.sel
            if here:
                c.fill(x - 1, ry, wd + 2, 1, u["SELECTION"]); c.put(x - 1, ry, "▌", u["ACCENT"])
            sw = 2 if wd >= 40 else 1
            c.put(x + 1, ry, s.get("name", s.get("id", "?"))[:wd - 8 - 5 * sw], u["FG"] if here else u["FG_DIM"],
                  attr=BOLD if here else 0)
            p = dict(DEFAULT); p.update(s.get("roles") or {})
            p["ACCENT"], p["ACCENT2"] = s.get("accent", p["ACCENT"]), s.get("accent2", p["ACCENT2"])
            p = pal_rgb(p)
            for j, r in enumerate(("BG", "SURFACE", "FG", "ACCENT", "ACCENT2")):
                c.put(x + wd - 6 - 5 * sw + j * sw, ry, " " * sw, bg=p[r])
            sc = s.get("score")
            c.put(x + wd - 5, ry, "%5.1f" % sc if isinstance(sc, (int, float)) else "", u["COMMENT"])

    def draw_wiz_accent(self, c, w, x, y, wd, h):
        u = self.ui
        c.put(x, y, "pick " + ("ACCENT · focus, links" if w.acc_phase == 0 else "ACCENT2 · cursor, search"),
              u["FG_DIM"], attr=BOLD, maxw=wd)
        per = max(1, (wd + 1) // 5)
        for i, a in enumerate(w.accents):
            ax, ay, col = x + (i % per) * 5, y + 2 + (i // per) * 2, rgb(a)
            ink = (0, 0, 0) if sum(col) > 384 else (255, 255, 255)
            c.put(ax, ay, "%3d " % (i + 1), ink, col, attr=BOLD if i == w.acc_cur else 0)
            if i == w.acc_cur:
                mark, mc = "▔▔▔▔", u["ACCENT2"]
            else:
                mark = "".join(t for t, j in (("A1", 0), ("A2", 1)) if w.acc[j] == i)[:4]
                mc = u["COMMENT"]
            c.put(ax, ay + 1, mark, mc)
        ly = y + 2 + ((len(w.accents) - 1) // per + 1) * 2 + 1
        for i, r in enumerate(("ACCENT", "ACCENT2")):
            hx = w.accents[w.acc[i]]
            c.put(x, ly + i, "  ", bg=rgb(hx))
            c.put(x + 3, ly + i, "%-8s %s" % (r, hx), u["FG"] if i == w.acc_phase else u["COMMENT"],
                  attr=BOLD if i == w.acc_phase else 0)

    def draw_wiz_name(self, c, w, x, y, wd, h):
        u = self.ui
        c.put(x, y, "theme name", u["FG_DIM"], attr=BOLD)
        c.box(x, y + 1, wd, 3, u["ACCENT"])
        c.put(x + 2, y + 2, w.name.text[:wd - 5], u["FG"])
        c.put(x + 2 + w.name.pos, y + 2, w.name.text[w.name.pos:w.name.pos + 1] or " ", u["BG"], u["ACCENT2"])
        if w.error:
            c.put(x, y + 4, w.error, RED, maxw=wd)
        elif any(t["name"] == w.name.text for t in self.themes):
            c.put(x, y + 4, "exists — you'll be asked to overwrite", YELLOW, maxw=wd)

    def draw_wiz_confirm(self, c, w, x, y, wd, h):
        u, s = self.ui, w.scheme()
        rows = [("name", w.name.text), ("image", os.path.basename(w.image)), ("scheme", s.get("name", s["id"])),
                ("accent", w.accents[w.acc[0]]), ("accent2", w.accents[w.acc[1]])]
        for i, (k, v) in enumerate(rows):
            c.put(x, y + i, "%-8s" % k, u["COMMENT"]); c.put(x + 9, y + i, v, u["FG"], maxw=wd - 9)
        xx = c.put(x, y + 6, "[s]", u["ACCENT"], attr=BOLD)
        xx = c.put(xx, y + 6, " save   ", u["FG_DIM"])
        xx = c.put(xx, y + 6, "[a]", u["ACCENT2"], attr=BOLD)
        c.put(xx, y + 6, " apply + save", u["FG_DIM"])


# ── terminal ──────────────────────────────────────────────────────────────────
class Term:
    def __init__(self):
        self.fd = sys.stdin.fileno()
        self.saved = termios.tcgetattr(self.fd)
        self.active = False
        self.in_child = False
        self.rd, self.wr = os.pipe()
        os.set_blocking(self.wr, False)

    def wake(self):
        try:
            os.write(self.wr, b"x")
        except OSError:
            pass

    def enter(self):
        tty.setraw(self.fd)
        sys.stdout.write("\033[?1049h\033[?25l\033[2J")
        sys.stdout.flush()
        self.active = True

    def leave(self):
        if not self.active:
            return
        self.active = False
        sys.stdout.write("\033[0m\033[2J\033[?25h\033[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(self.fd, termios.TCSAFLUSH, self.saved)

    def size(self):
        s = shutil.get_terminal_size((80, 24))
        return s.columns, s.lines

    def read_keys(self, timeout):
        r, _, _ = select.select([self.fd, self.rd], [], [], timeout)
        if self.rd in r:
            os.read(self.rd, 4096)
        if self.fd not in r:
            return []
        data = os.read(self.fd, 4096)
        if data == b"\x1b":  # a lone ESC, or the start of a sequence split across reads
            r, _, _ = select.select([self.fd], [], [], 0.03)
            if r:
                data += os.read(self.fd, 4096)
        return parse_keys(data)

    def run(self, argv, devnull):
        """Leave the TUI, run the CLI visibly, wait for a key."""
        self.leave()
        print("\033[1m==> shiny %s\033[0m\n" % " ".join(argv), flush=True)
        self.in_child = True
        try:
            rc = subprocess.call([CLI] + argv, stdin=subprocess.DEVNULL if devnull else None)
        except OSError as e:
            print("couldn't run %s: %s" % (CLI, e)); rc = 127
        finally:
            self.in_child = False
        print("\n\033[2m%s — press any key to return\033[0m" % ("done" if rc == 0 else "exit %d" % rc), flush=True)
        tty.setraw(self.fd)
        termios.tcflush(self.fd, termios.TCIFLUSH)
        os.read(self.fd, 64)
        self.enter()
        return rc


def interactive():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        sys.exit("shiny tui needs a terminal")
    term = Term()
    resized = [True]

    def on_signal(sig, _frame):
        if sig == signal.SIGWINCH:
            resized[0] = True; term.wake(); return
        if term.in_child:  # the child gets ^C; we wait for it
            return
        raise SystemExit(130 if sig == signal.SIGINT else 143)

    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGWINCH, signal.SIGHUP):
        signal.signal(s, on_signal)
    atexit.register(term.leave)
    jobs = Jobs(term.wake)
    cols, rows = term.size()
    app = App(cols, rows, jobs)
    for t in app.themes:  # warm the thumbnail cache in the background
        app.thumb(t["wallpaper"], urgent=False)
    try:
        term.enter()
        while not app.quit:
            if resized[0]:
                resized[0] = False
                app.cols, app.rows = term.size()
                sys.stdout.write("\033[2J")
            sys.stdout.write("\033[H" + app.draw().render() + "\033[0m")
            sys.stdout.flush()
            busy = (app.mode == "wizard" and app.wiz and app.wiz.step == "loading") or \
                any(k[0] in ("thumb", "cand") for k in jobs.queued)
            for k in term.read_keys(0.1 if busy else None):
                app.key(k)
                if app.pending_cmd:
                    argv, devnull, select_after = app.pending_cmd
                    app.pending_cmd = None
                    term.run(argv, devnull)
                    app.reload(select=select_after)
                    resized[0] = True
                    break
    finally:
        term.leave()


def snapshot(args):
    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default
    screen = args[0] if args else "themes"
    cols, rows = int(opt("--cols", 120)), int(opt("--rows", 40))
    app = App(cols, rows, SyncJobs())
    if opt("--theme"):
        names = [t["name"] for t in app.shown()]
        if opt("--theme") in names:
            app.sel = names.index(opt("--theme"))
    if screen == "wizard-schemes":
        img = opt("--image") or (app.themes[0]["wallpaper"] if app.themes else "")
        app.mode, app.wiz = "wizard", Wizard()
        app.wiz.path = LineEdit(img)
        app.key("enter")
        app.poll()
        for k in opt("--keys", "").split(","):
            if k:
                app.key(k)
    elif screen == "help":
        app.mode = "help"
    elif screen != "themes":
        sys.exit("snapshot screens: themes, wizard-schemes, help")
    sys.stdout.write(app.draw().render(positioned=False))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--snapshot":
        snapshot(sys.argv[2:])
    else:
        interactive()
