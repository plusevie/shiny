#!/usr/bin/env python3
"""Build alfred/shiny-theme.alfredworkflow — keyword `theme` → pick → apply.

    python3 alfred/build.py && open alfred/shiny-theme.alfredworkflow
"""
import os, plistlib, subprocess, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SF, RS, NT = (f"5A1E0F1A-0000-4C6B-9A11-00000000000{i}" for i in (1, 2, 3))
PATH = 'export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"\n'
link = lambda d: [{"destinationuid": d, "modifiers": 0, "modifiersubtext": "", "vitoclose": False}]

info = {
    "bundleid": "shiny.theme-switcher", "name": "shiny theme", "createdby": "shiny",
    "description": "Switch the shiny colour theme", "category": "Tools", "version": "1.0",
    "readme": 'Type "theme" to pick a shiny theme. Needs the `shiny` command (see the shiny README).',
    "objects": [
        {"type": "alfred.workflow.input.scriptfilter", "uid": SF, "version": 3, "config": {
            "keyword": "theme", "withspace": True, "argumenttype": 1,
            "title": "Switch shiny theme", "subtext": "", "runningsubtext": "Loading themes…",
            "type": 0, "scriptargtype": 1, "escaping": 102, "queuemode": 1,
            "script": PATH + 'shiny theme --alfred',
            "alfredfiltersresults": True, "alfredfiltersresultsmatchmode": 0,
            "argumenttrimmode": 0, "argumenttreatemptyqueryasnil": True}},
        {"type": "alfred.workflow.action.script", "uid": RS, "version": 2, "config": {
            "type": 0, "scriptargtype": 1, "concurrently": False, "escaping": 102,
            "script": PATH + 'shiny theme set "$1" >/dev/null 2>&1 && echo "$1" || echo "failed: $1"'}},
        {"type": "alfred.workflow.output.notification", "uid": NT, "version": 1, "config": {
            "title": "Theme applied", "text": "{query}", "onlyshowifquerypopulated": True,
            "removeextension": False, "lastpathcomponent": False}},
    ],
    "connections": {SF: link(RS), RS: link(NT)},
    "uidata": {SF: {"xpos": 40, "ypos": 40}, RS: {"xpos": 240, "ypos": 40}, NT: {"xpos": 440, "ypos": 40}},
}

out = os.path.join(ROOT, "alfred", "shiny-theme.alfredworkflow")
with tempfile.TemporaryDirectory() as tmp:
    icon = os.path.join(tmp, "icon.png")
    subprocess.run(["sips", "-Z", "256", "-s", "format", "png",
                    os.path.join(ROOT, "themes/solarflare/wallpaper.jpg"), "--out", icon],
                   check=True, capture_output=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("info.plist", plistlib.dumps(info))
        z.write(icon, "icon.png")
print(out)
