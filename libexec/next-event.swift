// next-event.swift — the next (or current) calendar event, for SketchyBar.
//
//   next-event [--hours N]     prints "start<TAB>end<TAB>title" (unix seconds), or nothing
//
// Reads every calendar macOS Calendar knows about through EventKit. Skips
// all-day events and ones you've declined; an event in progress wins until it
// ends. Only looks N hours ahead (default 12).
//
// Built by shiny-apply with libexec/next-event.plist embedded, which gives macOS
// the reason to show in the one-time "access your calendars" prompt.
import EventKit
import Foundation

var hours = 12.0
if let i = CommandLine.arguments.firstIndex(of: "--hours"), i + 1 < CommandLine.arguments.count,
   let h = Double(CommandLine.arguments[i + 1]) { hours = h }

let store = EKEventStore()
let done = DispatchSemaphore(value: 0)
var granted = false
store.requestFullAccessToEvents { ok, _ in granted = ok; done.signal() }
_ = done.wait(timeout: .now() + 30)
guard granted else { exit(2) }

let now = Date()
let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                    end: now.addingTimeInterval(hours * 3600), calendars: nil)
let events = store.events(matching: pred).filter { e in
  guard !e.isAllDay, e.endDate > now, e.status != .canceled else { return false }
  if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return false }
  return true
}.sorted { $0.startDate < $1.startDate }

guard let e = events.first else { exit(0) }
let title = (e.title ?? "Busy").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
print("\(Int(e.startDate.timeIntervalSince1970))\t\(Int(e.endDate.timeIntervalSince1970))\t\(title)")
