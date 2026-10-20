// Renders Moxie Timer screens with demo data for the README images.
// Built and run by render.sh against a copy of Sources/ with a fake Keychain, inside a temporary home folder,
// so it never touches the real app's data, settings or API key.
import AppKit
import SwiftUI

@MainActor
enum Demo {
    static let cal = Calendar.current
    static let now = Date()

    static let clients: [(name: String, projects: [String])] = [
        ("Northwind Studio", ["Website 2.0", "Brand refresh"]),
        ("Bluebird Bakery", ["Online shop"]),
        ("Lumen Labs", ["Product launch"]),
        ("Harbor & Co", ["Monthly retainer"]),
    ]

    static let notes = ["Hero layout, three directions", "Draft emails 1–3", "Coupon edge cases", "Client call follow-up", ""]

    /// Six weeks of believable history, plus two entries held for review today.
    static func seedHistory(_ model: AppModel) {
        guard model.history.entries.isEmpty else { return }
        for dayBack in 0..<44 {
            guard let day = cal.date(byAdding: .day, value: -dayBack, to: cal.startOfDay(for: now)) else { continue }
            if cal.isDateInWeekend(day) { continue }
            let count = dayBack == 0 ? 2 : 2 + (dayBack * 7) % 3
            var cursor = cal.date(bySettingHour: 9, minute: (dayBack * 13) % 40, second: 0, of: day)!
            for i in 0..<count {
                let client = clients[(dayBack * 3 + i) % clients.count]
                let minutes = 25 + ((dayBack * 37 + i * 53) % 110)
                let start = cursor
                let end = min(now, start.addingTimeInterval(TimeInterval(minutes * 60)))
                if start >= now { break }
                cursor = end.addingTimeInterval(TimeInterval(15 + (i * 20) % 50) * 60)
                if cal.component(.hour, from: cursor) == 12 { cursor = cursor.addingTimeInterval(3600) }
                var draft = EntryDraft()
                draft.client = Ref(id: "c-\(client.name)", name: client.name)
                draft.project = Ref(id: "p-\(client.projects[i % client.projects.count])", name: client.projects[i % client.projects.count])
                draft.notes = notes[(dayBack + i) % notes.count]
                draft.billable = (dayBack + i) % 5 != 0
                model.history.add(LoggedEntry(id: UUID().uuidString, moxieId: dayBack == 0 ? nil : "demo", start: start, end: end,
                                              draft: draft, pending: dayBack == 0 ? true : nil))
            }
            model.stats.record({
                $0.focusSeconds = TimeInterval(2400 + (dayBack * 613) % 6000)
                $0.blocksCompleted = 1 + dayBack % 3
                $0.tasksDone = (dayBack + 1) % 3
                $0.cameBack = dayBack % 3
            }, on: day)
        }
    }

    static func task(_ id: String, _ name: String, _ client: String, _ project: String, due: Int?, priority: String? = nil) -> MoxieTask {
        MoxieTask(id: id, name: name, projectId: "p-\(project)", status: nil, parentTaskId: nil, clientId: "c-\(client)",
                  client: .init(id: "c-\(client)", name: client), project: .init(id: "p-\(project)", name: project),
                  taskPriority: priority,
                  dueDate: due.map { MoxieTask.dayFormatter.string(from: cal.date(byAdding: .day, value: $0, to: now)!) })
    }

    static func seedTasks(_ model: AppModel) {
        model.inbox.tasks = [
            task("t1", "Fix checkout coupon bug", "Bluebird Bakery", "Online shop", due: -1, priority: "Urgent"),
            task("t2", "Design the new homepage hero", "Northwind Studio", "Website 2.0", due: 0, priority: "High"),
            task("t3", "Write launch email sequence", "Lumen Labs", "Product launch", due: 1, priority: "Urgent"),
            task("t4", "Logo variations for social", "Northwind Studio", "Brand refresh", due: 3, priority: "Medium"),
            task("t5", "Quarterly SEO report", "Harbor & Co", "Monthly retainer", due: 6, priority: "Medium"),
            task("t6", "Update email signatures", "Northwind Studio", "Website 2.0", due: nil),
            task("t7", "Migrate blog to the new CMS", "Northwind Studio", "Website 2.0", due: 9),
        ]
    }
}

@MainActor func render() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let model = AppModel.shared
    Demo.seedHistory(model)
    Demo.seedTasks(model)
    model.inbox.filterClient = nil
    model.ui.expand()

    let args = CommandLine.arguments
    let screen = args.count > 1 ? args[1] : "focus"
    let output = args.count > 2 ? args[2] : "/tmp/shot.png"
    var withPill = false

    switch screen {
    case "compose":
        withPill = true
        model.timer.start()
        model.timer.setDuration(17 * 60 + 32)
    case "newtask":
        model.inbox.filterClient = Ref(id: "c-Northwind Studio", name: "Northwind Studio")
        model.inbox.justAdded = ["t6"]
    case "active":
        withPill = true
        model.focus.target = FocusTarget(name: "Design the new homepage hero", taskId: "t2", clientName: "Northwind Studio",
                                         projectName: "Website 2.0", firstStep: "Sketch 3 hero layouts on paper")
        model.focus.startBlock(minutes: 25, warmup: false)
        model.focus.block?.shift(by: -(12 * 60 + 32))
        model.timer.setDuration(12 * 60 + 32 + 47 * 60)
    case "timer":
        model.ui.tab = .timer
        var draft = EntryDraft()
        draft.client = Ref(id: "c-Northwind Studio", name: "Northwind Studio")
        draft.project = Ref(id: "p-Website 2.0", name: "Website 2.0")
        draft.task = Ref(id: "t2", name: "Design the new homepage hero")
        model.timer.draft = draft
        model.timer.start()
        model.timer.setDuration(17 * 60 + 32)
    case "recent":
        model.ui.tab = .recent
    case "insights":
        model.ui.tab = .insights
    default:
        break
    }

    let card = ExpandedCard()
    let content = Group {
        if withPill {
            VStack(alignment: .trailing, spacing: 8) {
                PillBar()
                card
            }
        } else {
            card
        }
    }
    let root = content
        .environment(model.settings).environment(model.history).environment(model.catalog).environment(model.timer)
        .environment(model.ui).environment(model.clock).environment(model.updater).environment(model.ai)
        .environment(model.inbox).environment(model.focus).environment(model.idle).environment(model.activity)
        .environment(model.stats).environment(model.pet).environment(model.voice).environment(model.petLines)
        .environment(model.petSkills).environment(model.calls)
        .padding(EdgeInsets(top: 10, leading: 24, bottom: 34, trailing: 24))
        .fixedSize()

    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -6000, y: 0))
    window.orderFrontRegardless()

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // 2× pixels so the composed images stay sharp.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        if ProcessInfo.processInfo.environment["CAPTURE"] != "offscreen" {
            // A real on-screen capture (the window flashes briefly): what the window server draws, identical to
            // the running app. Offscreen caching draws stray hairlines next to capsule borders. Prefers a Retina screen.
            let display = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main!
            let area = display.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.maxX - size.width - 40, y: area.minY + 40))
            window.level = .floating
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-l\(window.windowNumber)", "-o", "-x", output]
                try? task.run()
                task.waitUntilExit()
                print("rendered \(screen) → \(output) (screen)")
                exit(0)
            }
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        print("rendered \(screen) → \(output) \(Int(size.width))×\(Int(size.height))")
        exit(0)
    }
    NSApplication.shared.run()
}

@main struct MarketingHarness {
    static func main() { MainActor.assumeIsolated { render() } }
}
