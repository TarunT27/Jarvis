import Foundation
import AppKit
import Observation
import UserNotifications

struct JarvisTimer: Identifiable, Sendable {
    let id=UUID()
    let label:String
    let fires:Date
    var title:String { label.isEmpty ? "Timer" : label }
}

/// Countdowns started by set_timer. The broker validates the request; the app owns the
/// clock because only the app can notify and make a sound. Timers live in memory and
/// end with the app, which the menu says.
@MainActor @Observable final class TimerCenter:NSObject,UNUserNotificationCenterDelegate {
    private(set) var timers:[JarvisTimer]=[]
    @ObservationIgnored private var tasks:[UUID:Task<Void,Never>]=[:]
    @ObservationIgnored private var askedForNotifications=false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate=self
    }

    @discardableResult func start(seconds:Int,label:String) -> JarvisTimer {
        let timer=JarvisTimer(label:label.trimmingCharacters(in:.whitespaces),fires:Date().addingTimeInterval(TimeInterval(seconds)))
        timers.append(timer);timers.sort { $0.fires<$1.fires }
        requestNotificationsOnce()
        tasks[timer.id]=Task { [weak self] in
            do { try await Task.sleep(for:.seconds(seconds)) } catch { return }
            self?.fire(timer)
        }
        return timer
    }

    func cancel(_ id:UUID) {
        tasks.removeValue(forKey:id)?.cancel()
        timers.removeAll { $0.id==id }
    }

    /// One line per timer for the model, so "how long is left?" has a real answer.
    var summary:String {
        guard !timers.isEmpty else { return "none" }
        return timers.map { "\($0.title) ends in \(Self.remaining(until:$0.fires))" }.joined(separator:"; ")
    }

    static func remaining(until date:Date) -> String {
        let seconds=max(0,Int(date.timeIntervalSinceNow.rounded()))
        let formatter=DateComponentsFormatter()
        formatter.allowedUnits=seconds>=3600 ? [.hour,.minute] : [.minute,.second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from:TimeInterval(seconds)) ?? "\(seconds)s"
    }

    private func fire(_ timer:JarvisTimer) {
        tasks.removeValue(forKey:timer.id)
        guard timers.contains(where:{ $0.id==timer.id }) else { return }
        timers.removeAll { $0.id==timer.id }
        let content=UNMutableNotificationContent()
        content.title=timer.label.isEmpty ? "Timer done" : "\(timer.label) — done"
        content.body="Your Jarvis timer has finished."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:timer.id.uuidString,content:content,trigger:nil))
        // A banner alone is easy to miss when notifications are off or Focus is on.
        Task { for _ in 0..<3 { NSSound(named:"Glass")?.play();try? await Task.sleep(for:.milliseconds(900)) } }
    }

    private func requestNotificationsOnce() {
        guard !askedForNotifications else { return }
        askedForNotifications=true
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { _,_ in }
    }

    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification) async -> UNNotificationPresentationOptions {
        [.banner,.sound]
    }
}
