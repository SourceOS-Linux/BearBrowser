// BearBrowserPolicyQueue — macOS status bar agent for PolicyFabric hold decisions.
//
// Watches ~/Library/Application Support/BearBrowser/policy/actions.jsonl for
// entries with decision.state == "hold" that have not been resolved. Shows a
// menubar badge with the count and a click-through menu to approve or deny each
// held action. Resolution calls bearbrowser-resolve-action.py and appends a
// signed resolution record to the same actions.jsonl file.
//
// Build:
//   swiftc -framework Cocoa native/macos/BearBrowserPolicyQueue.swift \
//          -o build/BearBrowserPolicyQueue
//
// Launch at login (optional):
//   cp build/BearBrowserPolicyQueue /usr/local/bin/
//   # Add a LaunchAgent plist pointing to it

import Cocoa
import Foundation

// MARK: — Data model

struct HoldAction {
    let actionId: String
    let actionType: String
    let profile: String
    let context: [String: String]
    let reason: String
    let timestamp: String

    var displayTitle: String {
        let type = actionType.replacingOccurrences(of: "_", with: " ")
        if let url = context["url"] ?? context["destination"] {
            let short = url.count > 60 ? String(url.prefix(57)) + "…" : url
            return "\(type): \(short)"
        }
        return type
    }

    var displayDetail: String {
        var parts: [String] = []
        if !profile.isEmpty { parts.append("profile: \(profile)") }
        if !reason.isEmpty  { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}

// MARK: — JSONL reader

func readPendingHolds(from path: URL) -> [HoldAction] {
    guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [] }

    var allActions: [(String, [String: Any])] = []
    var resolvedIds: Set<String> = []

    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }

        if let id = obj["actionId"] as? String {
            allActions.append((id, obj))
        }
        if let target = obj["target"] as? [String: Any],
           let fromId = target["resolvedFromActionId"] as? String {
            resolvedIds.insert(fromId)
        }
    }

    return allActions.compactMap { (id, obj) -> HoldAction? in
        guard resolvedIds.contains(id) == false else { return nil }
        guard let decision = obj["decision"] as? [String: Any],
              decision["state"] as? String == "hold"
        else { return nil }

        let ctx = obj["context"] as? [String: String] ?? [:]
        return HoldAction(
            actionId:   id,
            actionType: obj["actionType"] as? String ?? "unknown",
            profile:    obj["profile"]    as? String ?? "",
            context:    ctx,
            reason:     (obj["decision"] as? [String: Any])?["reason"] as? String ?? "",
            timestamp:  obj["timestamp"]  as? String ?? ""
        )
    }
}

// MARK: — PolicyFabric resolver

func resolveAction(actionId: String, decision: String, repoRoot: String, completion: @escaping (Bool) -> Void) {
    let script = "\(repoRoot)/scripts/bearbrowser-resolve-action.py"
    guard FileManager.default.fileExists(atPath: script) else {
        completion(false)
        return
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    task.arguments = [
        script,
        "--action-id", actionId,
        "--decision", decision,
        "--actor-type", "human",
        "--note", "Resolved via BearBrowser policy queue status bar"
    ]
    task.terminationHandler = { p in
        completion(p.terminationStatus == 0)
    }
    try? task.run()
}

// MARK: — App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var pollTimer: Timer!
    var pendingHolds: [HoldAction] = []
    let actionsURL: URL
    let repoRoot: String

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        actionsURL = support
            .appendingPathComponent("BearBrowser")
            .appendingPathComponent("policy")
            .appendingPathComponent("actions.jsonl")

        // Resolve repo root from this binary's path (works for both build/ and /usr/local/bin)
        let binDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
        if binDir.hasSuffix("/build") {
            repoRoot = URL(fileURLWithPath: binDir).deletingLastPathComponent().path
        } else if let env = ProcessInfo.processInfo.environment["BEARBROWSER_HOME"] {
            repoRoot = env
        } else {
            repoRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("dev/SourceOS-Linux__BearBrowser").path
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⚖"
            button.font = NSFont.systemFont(ofSize: 14)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let holds = readPendingHolds(from: self.actionsURL)
            DispatchQueue.main.async {
                self.pendingHolds = holds
                self.rebuildMenu()
            }
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        if pendingHolds.isEmpty {
            statusItem.button?.title = "⚖"
            statusItem.button?.appearsDisabled = true
            let idle = NSMenuItem(title: "No pending holds", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        } else {
            statusItem.button?.title = "⚖ \(pendingHolds.count)"
            statusItem.button?.appearsDisabled = false

            let header = NSMenuItem(title: "\(pendingHolds.count) pending hold\(pendingHolds.count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            for hold in pendingHolds {
                let titleItem = NSMenuItem(title: hold.displayTitle, action: nil, keyEquivalent: "")
                titleItem.isEnabled = false
                menu.addItem(titleItem)

                if !hold.displayDetail.isEmpty {
                    let detailItem = NSMenuItem(title: "  ↳ \(hold.displayDetail)", action: nil, keyEquivalent: "")
                    detailItem.isEnabled = false
                    detailItem.attributedTitle = NSAttributedString(
                        string: "  ↳ \(hold.displayDetail)",
                        attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                     .font: NSFont.systemFont(ofSize: 11)]
                    )
                    menu.addItem(detailItem)
                }

                let approve = NSMenuItem(
                    title: "  ✓ Allow",
                    action: #selector(approveAction(_:)),
                    keyEquivalent: ""
                )
                approve.representedObject = hold.actionId
                approve.target = self
                approve.attributedTitle = NSAttributedString(
                    string: "  ✓ Allow",
                    attributes: [.foregroundColor: NSColor.systemGreen,
                                 .font: NSFont.systemFont(ofSize: 13)]
                )
                menu.addItem(approve)

                let deny = NSMenuItem(
                    title: "  ✗ Deny",
                    action: #selector(denyAction(_:)),
                    keyEquivalent: ""
                )
                deny.representedObject = hold.actionId
                deny.target = self
                deny.attributedTitle = NSAttributedString(
                    string: "  ✗ Deny",
                    attributes: [.foregroundColor: NSColor.systemRed,
                                 .font: NSFont.systemFont(ofSize: 13)]
                )
                menu.addItem(deny)
                menu.addItem(.separator())
            }

            // Bulk actions
            let approveAll = NSMenuItem(title: "Allow all", action: #selector(approveAll), keyEquivalent: "")
            approveAll.target = self
            menu.addItem(approveAll)

            let denyAll = NSMenuItem(title: "Deny all", action: #selector(denyAll), keyEquivalent: "")
            denyAll.target = self
            menu.addItem(denyAll)
        }

        menu.addItem(.separator())
        let showQueue = NSMenuItem(title: "Show queue…", action: #selector(showQueue), keyEquivalent: "q")
        showQueue.target = self
        menu.addItem(showQueue)

        let quit = NSMenuItem(title: "Quit policy queue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc func approveAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        resolveAction(actionId: id, decision: "allow", repoRoot: repoRoot) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
        }
    }

    @objc func denyAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        resolveAction(actionId: id, decision: "deny", repoRoot: repoRoot) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
        }
    }

    @objc func approveAll() {
        let ids = pendingHolds.map(\.actionId)
        for id in ids {
            resolveAction(actionId: id, decision: "allow", repoRoot: repoRoot) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    @objc func denyAll() {
        let ids = pendingHolds.map(\.actionId)
        for id in ids {
            resolveAction(actionId: id, decision: "deny", repoRoot: repoRoot) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    @objc func showQueue() {
        let script = "\(repoRoot)/scripts/bearbrowser-governance-queue.py"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let alert = NSAlert()
        alert.messageText = "BearBrowser Policy Queue"
        alert.informativeText = output.isEmpty ? "(empty)" : output
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: — Entry point

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
