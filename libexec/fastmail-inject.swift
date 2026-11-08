// fastmail-inject — keep a CSS file injected into the Fastmail desktop app.
//
//   fastmail-inject <file.css>
//
// Runs as the shiny.fastmail launch agent (libexec/install-fastmail).
// Fastmail is Electron with no user-CSS hook, so this launches it with
// --remote-debugging-pipe: a DevTools connection over two inherited file
// descriptors that only this process holds. (A --remote-debugging-port would
// let any local process read your mail.) Chromium quits when the pipe closes,
// so this stays alive as long as Fastmail does.
//
// When Fastmail is opened any other way (Dock, Spotlight, login item), it's
// quit and reopened through here. Every page gets a <style id="shiny-theme">,
// re-applied on reload and whenever <file.css> changes. No CSS file = hands off.

import AppKit
import Foundation

let bundleID = "com.fastmail.mac.Fastmail"
let cssPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
  : NSString(string: "~/Library/Application Support/shiny/fastmail.css").expandingTildeInPath

func log(_ s: String) { FileHandle.standardError.write("fastmail-inject: \(s)\n".data(using: .utf8)!) }
signal(SIGPIPE, SIG_IGN)

// One injector per user. Two would each see the other's Fastmail as foreign
// and quit/relaunch it forever. The lock dies with the process.
let lockPath = NSString(string: "~/Library/Application Support/shiny/fastmail-inject.lock").expandingTildeInPath
try? FileManager.default.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
  log("another fastmail-inject is already running; exiting.")
  exit(0)
}

// ── CSS file ────────────────────────────────────────────────────────────────
var css: String? = nil      // nil = file missing
var cssStamp = ""

func readCSS() -> Bool {    // true if it changed
  let a = try? FileManager.default.attributesOfItem(atPath: cssPath)
  let stamp = a.map { "\(($0[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\($0[.size] ?? 0)" } ?? ""
  if stamp == cssStamp { return false }
  cssStamp = stamp
  css = a == nil ? nil : (try? String(contentsOfFile: cssPath, encoding: .utf8))
  return true
}

func injectJS() -> String {
  let lit = String(data: try! JSONSerialization.data(withJSONObject: [css ?? ""], options: [.fragmentsAllowed]), encoding: .utf8)!
  return """
  (() => {
    if (!/(^|\\.)fastmail\\.com$/.test(location.hostname)) return;
    // A constructable sheet, not a <style>: Fastmail's bootstrap rewrites
    // <head>, and adopted sheets cascade after every document sheet.
    const sheet = (window.__shinyTheme ??= new CSSStyleSheet());
    sheet.replaceSync(\(lit)[0]);
    if (!document.adoptedStyleSheets.includes(sheet))
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  })()
  """
}

// ── DevTools pipe ───────────────────────────────────────────────────────────
var child: pid_t = 0
var toBrowser: Int32 = -1
var nextID = 1
var pending: [Int: ([String: Any]) -> Void] = [:]
var sessions: [String: String] = [:]   // targetId → sessionId
var scripts: [String: String] = [:]    // sessionId → addScriptToEvaluateOnNewDocument identifier
var attaching = Set<String>()

func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil,
          then: (([String: Any]) -> Void)? = nil) {
  guard toBrowser >= 0 else { return }
  let id = nextID; nextID += 1
  var msg: [String: Any] = ["id": id, "method": method, "params": params]
  if let session { msg["sessionId"] = session }
  if let then { pending[id] = then }
  var data = try! JSONSerialization.data(withJSONObject: msg)
  data.append(0)
  data.withUnsafeBytes { buf in
    var off = 0
    while off < buf.count {
      let n = write(toBrowser, buf.baseAddress! + off, buf.count - off)
      if n <= 0 { break }
      off += n
    }
  }
}

func style(session: String) {
  if let old = scripts.removeValue(forKey: session) {
    send("Page.removeScriptToEvaluateOnNewDocument", ["identifier": old], session: session)
  }
  let js = injectJS()
  send("Page.addScriptToEvaluateOnNewDocument", ["source": js], session: session) { r in
    if let id = (r["result"] as? [String: Any])?["identifier"] as? String { scripts[session] = id }
  }
  send("Runtime.evaluate", ["expression": js], session: session)
}

func consider(_ info: [String: Any]) {
  guard info["type"] as? String == "page", let tid = info["targetId"] as? String,
        sessions[tid] == nil, !attaching.contains(tid) else { return }
  attaching.insert(tid)
  send("Target.attachToTarget", ["targetId": tid, "flatten": true]) { r in
    attaching.remove(tid)
    guard let sid = (r["result"] as? [String: Any])?["sessionId"] as? String else { return }
    sessions[tid] = sid
    send("Page.enable", session: sid)   // new-document scripts only run with Page on
    style(session: sid)
  }
}

let debug = ProcessInfo.processInfo.environment["SHINY_DEBUG"] != nil
func handle(_ msg: [String: Any]) {
  if debug { log(String(String(describing: msg).prefix(300))) }
  if let e = msg["error"] { log("devtools error: \(e)") }
  if let id = msg["id"] as? Int { pending.removeValue(forKey: id)?(msg); return }
  let p = msg["params"] as? [String: Any] ?? [:]
  switch msg["method"] as? String {
  case "Target.targetCreated", "Target.targetInfoChanged":
    if let info = p["targetInfo"] as? [String: Any] { consider(info) }
  case "Page.domContentEventFired":    // belt and braces, idempotent
    if let sid = msg["sessionId"] as? String { send("Runtime.evaluate", ["expression": injectJS()], session: sid) }
  case "Target.targetDestroyed":
    if let tid = p["targetId"] as? String, let sid = sessions.removeValue(forKey: tid) { scripts[sid] = nil }
  case "Target.detachedFromTarget":
    if let sid = p["sessionId"] as? String {
      scripts[sid] = nil
      sessions = sessions.filter { $0.value != sid }
    }
  default: break
  }
}

func startReader(_ fd: Int32) {
  Thread.detachNewThread {
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = read(fd, &chunk, chunk.count)
      if n <= 0 { break }
      buf.append(chunk, count: n)
      while let z = buf.firstIndex(of: 0) {
        let line = buf[buf.startIndex..<z]
        buf = Data(buf[(z + 1)...])
        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
          DispatchQueue.main.async { handle(obj) }
        }
      }
    }
    close(fd)
  }
}

// ── launching Fastmail ──────────────────────────────────────────────────────
func spawnFastmail() {
  guard child == 0, css != nil,
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
        let exe = Bundle(url: app)?.executableURL else { return }
  var a = [Int32](repeating: 0, count: 2), b = [Int32](repeating: 0, count: 2)
  guard pipe(&a) == 0, pipe(&b) == 0 else { log("pipe failed"); return }
  // a: we write → Fastmail reads on fd 3.  b: Fastmail writes on fd 4 → we read.
  var fa: posix_spawn_file_actions_t? = nil
  posix_spawn_file_actions_init(&fa)
  posix_spawn_file_actions_adddup2(&fa, a[0], 3)
  posix_spawn_file_actions_adddup2(&fa, b[1], 4)
  for fd: Int32 in 0...2 { posix_spawn_file_actions_addinherit_np(&fa, fd) }
  var attr: posix_spawnattr_t? = nil
  posix_spawnattr_init(&attr)
  posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
  let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe.path), strdup("--remote-debugging-pipe"), nil]
  var pid: pid_t = 0
  let rc = posix_spawn(&pid, exe.path, &fa, &attr, argv, environ)
  argv.forEach { free($0) }
  posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr)
  close(a[0]); close(b[1])
  guard rc == 0 else { log("spawn failed: \(rc)"); close(a[1]); close(b[0]); return }

  child = pid; toBrowser = a[1]
  startReader(b[0])
  let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
  src.setEventHandler {
    var st: Int32 = 0; waitpid(pid, &st, 0)
    src.cancel()
    close(toBrowser); toBrowser = -1; child = 0
    pending = [:]; sessions = [:]; scripts = [:]; attaching = []
  }
  src.resume()
  send("Target.setDiscoverTargets", ["discover": true])
  log("launched Fastmail (pid \(pid))")
}

var relaunching = false
var takeovers: [Date] = []
func takeOver(_ app: NSRunningApplication) {  // quit a Fastmail we don't own, reopen it ours
  guard css != nil, app.processIdentifier != child, !relaunching else { return }
  // Safety brake: if something keeps relaunching Fastmail behind our back,
  // stop fighting it rather than loop.
  takeovers = takeovers.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
  guard takeovers.count <= 3 else { log("too many takeovers in a minute; leaving Fastmail alone."); return }
  relaunching = true
  app.terminate()
  var waited = 0.0
  Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
    waited += 0.2
    if waited > 8, !app.isTerminated { app.forceTerminate() }
    guard app.isTerminated else { return }
    t.invalidate(); relaunching = false
    spawnFastmail()
    NSRunningApplication(processIdentifier: child)?.activate()
  }
}

NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
  if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
     app.bundleIdentifier == bundleID { takeOver(app) }
}

_ = readCSS()
NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first.map(takeOver)
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
  guard readCSS() else { return }
  for sid in sessions.values { style(session: sid) }
}
RunLoop.main.run()
