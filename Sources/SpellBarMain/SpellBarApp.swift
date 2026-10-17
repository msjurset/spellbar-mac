import AppKit
import Carbon.HIToolbox
import SpellBarLib
import SwiftUI

private let hotKeySignature: OSType = 0x53504C42 // 'SPLB'

private func carbonHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let id = hotKeyID.id
    DispatchQueue.main.async {
        SpellBarController.shared.handleHotKey(id: id)
    }
    return noErr
}

// MARK: - LaunchAgent Helper

enum LaunchAgentManager {
    private static let label = "com.msjurset.SpellBar"
    private static var plistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(label).plist"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func setEnabled(_ enabled: Bool) {
        let uid = getuid()
        if enabled {
            let appPath = "/Applications/SpellBar.app/Contents/MacOS/SpellBar"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["bootstrap", "gui/\(uid)", plistPath]
            try? proc.run()
            proc.waitUntilExit()
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["bootout", "gui/\(uid)/\(label)"]
            try? proc.run()
            proc.waitUntilExit()
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - Main Controller

@MainActor
final class SpellBarController: NSObject {
    static let shared = SpellBarController()

    private var statusItem: NSStatusItem!
    private let state = SpellBarState()
    private var panel: FloatingPillPanel!

    private var primaryHotKeyRef: EventHotKeyRef?   // Cmd + ;
    private var instantHotKeyRef: EventHotKeyRef?   // Cmd + Shift + ;
    private var modalHotKeyRefs: [EventHotKeyRef] = []

    private var targetPID: pid_t = 0
    private var currentAnalysis: WordAnalysis?
    private var hasUncollapsedSpellBarSelection: Bool = false
    private var pillShownAt: TimeInterval = 0
    private var outsideClickMonitor: Any?
    private var outsideKeyMonitor: Any?
    private var autoDismissWorkItem: DispatchWorkItem?

    func setup() {
        panel = FloatingPillPanel(state: state)

        state.onCommitSuggestion = { [weak self] chosen in
            self?.commitReplacement(chosen)
        }
        state.onNextMisspelled = { [weak self] in
            self?.skipToNextMisspelled()
        }
        state.onDismiss = { [weak self] in
            self?.dismissPill(collapseSelection: true)
        }

        setupStatusItem()
        installCarbonEventHandler()
        registerPrimaryHotKeys()

        // Prompt for Accessibility on first launch if not yet granted
        if !AccessibilityBridge.shared.isTrusted {
            _ = AccessibilityBridge.shared.promptForTrustIfNeeded()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                Task { @MainActor in
                    if let self = self, self.panel.isVisible, app.processIdentifier != self.targetPID {
                        self.dismissPill(collapseSelection: false)
                    }
                }
            }
        }
    }

    // MARK: - Status Bar Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "textformat.abc.dottedunderline", accessibilityDescription: "SpellBar") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "Abc"
            }
        }
        rebuildMenu()
    }

    @objc private func rebuildMenu() {
        let menu = NSMenu()

        let trusted = AccessibilityBridge.shared.isTrusted
        let statusTitle = trusted ? "✓ Accessibility Active" : "⚠️ Grant Accessibility Permission…"
        let statusItemMenu = NSMenuItem(title: statusTitle, action: #selector(handlePermissionClick), keyEquivalent: "")
        statusItemMenu.target = self
        menu.addItem(statusItemMenu)

        menu.addItem(.separator())

        let checkItem = NSMenuItem(title: "Check & Fix Misspelled Word", action: #selector(triggerFromMenu), keyEquivalent: ";")
        checkItem.keyEquivalentModifierMask = [.command]
        checkItem.target = self
        menu.addItem(checkItem)

        let batchItem = NSMenuItem(title: "Batch Auto-Fix All Typos", action: #selector(triggerBatchFromMenu), keyEquivalent: ";")
        batchItem.keyEquivalentModifierMask = [.command, .shift]
        batchItem.target = self
        menu.addItem(batchItem)

        menu.addItem(.separator())

        let helpHeader = NSMenuItem(title: "Shortcuts While Bar is Open:", action: nil, keyEquivalent: "")
        helpHeader.isEnabled = false
        menu.addItem(helpHeader)

        for hint in [
            "  ⌘; or Return — Accept highlighted fix",
            "  h / l (or Tab / Arrows) — Cycle suggestions",
            "  1–5 — Pick suggestion by number",
            "  n or ⌘' — Jump to next red squiggly",
            "  ⌘⇧; — Batch auto-fix all safe typos",
            "  Esc — Dismiss"
        ] {
            let item = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAgentManager.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SpellBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func handlePermissionClick() {
        if !AccessibilityBridge.shared.isTrusted {
            _ = AccessibilityBridge.shared.promptForTrustIfNeeded()
            AccessibilityBridge.shared.openAccessibilitySettings()
        }
        rebuildMenu()
    }

    @objc private func triggerFromMenu() {
        handlePrimaryTrigger()
    }

    @objc private func triggerBatchFromMenu() {
        handleBatchAutoFixTrigger()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAgentManager.setEnabled(!LaunchAgentManager.isEnabled)
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Carbon HotKey Registration

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            nil,
            nil
        )
    }

    private func registerPrimaryHotKeys() {
        if primaryHotKeyRef == nil {
            let id1 = EventHotKeyID(signature: hotKeySignature, id: 1)
            RegisterEventHotKey(
                UInt32(kVK_ANSI_Semicolon),
                UInt32(cmdKey),
                id1,
                GetApplicationEventTarget(),
                0,
                &primaryHotKeyRef
            )
        }
        if instantHotKeyRef == nil {
            let id2 = EventHotKeyID(signature: hotKeySignature, id: 2)
            RegisterEventHotKey(
                UInt32(kVK_ANSI_Semicolon),
                UInt32(cmdKey | shiftKey),
                id2,
                GetApplicationEventTarget(),
                0,
                &instantHotKeyRef
            )
        }
    }

    private func temporarilyBypassPrimaryHotKey(_ block: () -> Void) {
        if let ref = primaryHotKeyRef {
            UnregisterEventHotKey(ref)
            primaryHotKeyRef = nil
        }
        block()
        usleep(45_000)
        let id1 = EventHotKeyID(signature: hotKeySignature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Semicolon),
            UInt32(cmdKey),
            id1,
            GetApplicationEventTarget(),
            0,
            &primaryHotKeyRef
        )
    }

    private func registerModalHotKeys() {
        unregisterModalHotKeys()

        let bindings: [(UInt32, Int, Int)] = [
            (10, kVK_Return, 0),
            (11, kVK_ANSI_KeypadEnter, 0),
            (12, kVK_Tab, 0),
            (13, kVK_Tab, shiftKey),
            (14, kVK_DownArrow, 0),
            (15, kVK_RightArrow, 0),
            (16, kVK_UpArrow, 0),
            (17, kVK_LeftArrow, 0),
            (18, kVK_Escape, 0),
            (19, kVK_ANSI_N, 0),
            (20, kVK_ANSI_Quote, cmdKey),
            (21, kVK_ANSI_1, 0),
            (22, kVK_ANSI_2, 0),
            (23, kVK_ANSI_3, 0),
            (24, kVK_ANSI_4, 0),
            (25, kVK_ANSI_5, 0),
            (26, kVK_ANSI_L, 0),
            (27, kVK_ANSI_H, 0),
            (28, kVK_ANSI_J, 0),
            (29, kVK_ANSI_K, 0)
        ]

        for (id, keyCode, mods) in bindings {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: hotKeySignature, id: id)
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(mods),
                hkID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref = ref {
                modalHotKeyRefs.append(ref)
            }
        }
    }

    private func unregisterModalHotKeys() {
        for ref in modalHotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        modalHotKeyRefs.removeAll()
    }

    // MARK: - HotKey Dispatch

    func handleHotKey(id: UInt32) {
        switch id {
        case 1:
            // Primary Cmd + ;
            if panel.isVisible, case .suggestions = state.mode {
                // Guard against any in-flight synthetic keystroke or hardware key-repeat bounce (< 140ms)
                guard CACurrentMediaTime() - pillShownAt > 0.14 else { return }
                // Second consecutive press of Cmd + ; -> immediately commit active suggestion!
                state.commitActive()
            } else {
                handlePrimaryTrigger()
            }
        case 2:
            // Cmd + Shift + ; -> Safe-calibrated batch auto-fix
            handleBatchAutoFixTrigger()
        case 10, 11:
            state.commitActive()
        case 12, 14, 15, 26, 28:
            state.advanceHighlight(forward: true)
        case 13, 16, 17, 27, 29:
            state.advanceHighlight(forward: false)
        case 18:
            dismissPill(collapseSelection: true)
        case 19, 20:
            skipToNextMisspelled()
        case 21...25:
            state.commitIndex(Int(id - 21))
        default:
            break
        }
    }

    // MARK: - Core Workflows

    private func handlePrimaryTrigger() {
        autoDismissWorkItem?.cancel()
        rebuildMenu()

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        targetPID = frontApp.processIdentifier

        guard AccessibilityBridge.shared.isTrusted else {
            _ = AccessibilityBridge.shared.promptForTrustIfNeeded()
            state.mode = .needsPermission
            pillShownAt = CACurrentMediaTime()
            registerModalHotKeys()
            panel.show(near: NSEvent.mouseLocation)
            installOutsideMonitors()
            return
        }

        let selected = AccessibilityBridge.shared.selectMisspelledOrCurrentWord(
            in: targetPID,
            hadActiveSelectionFromSpellBar: hasUncollapsedSpellBarSelection,
            temporarilyBypassHotkey: { [weak self] work in
                self?.temporarilyBypassPrimaryHotKey(work)
            }
        )
        hasUncollapsedSpellBarSelection = (selected != nil)

        presentAnalysis(for: selected)
    }

    private func handleBatchAutoFixTrigger() {
        guard AccessibilityBridge.shared.isTrusted,
              let frontApp = NSWorkspace.shared.frontmostApplication else {
            handlePrimaryTrigger()
            return
        }
        targetPID = frontApp.processIdentifier
        dismissPill(collapseSelection: false)

        let savedPb = AccessibilityBridge.shared.snapshotPasteboard()

        var fixes: [BatchFixSummary] = []
        var seenWords = Set<String>()
        let maxReplacements = 8
        let maxIterations = 16

        // 1. Select the initial misspelled word (or current word)
        var currentSelected = AccessibilityBridge.shared.selectMisspelledOrCurrentWord(
            in: targetPID,
            hadActiveSelectionFromSpellBar: hasUncollapsedSpellBarSelection,
            temporarilyBypassHotkey: { [weak self] work in
                self?.temporarilyBypassPrimaryHotKey(work)
            }
        )
        hasUncollapsedSpellBarSelection = false

        // 2. Scan and replace safe high-confidence typos
        for _ in 0..<maxIterations {
            guard let raw = currentSelected,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                break
            }

            let analysis = SpellEngine.shared.analyze(raw)
            let coreLower = analysis.coreWord.lowercased()

            // Wrap-around detection: stop if Chrome or web editor loops back to start
            if seenWords.contains(coreLower) {
                break
            }
            seenWords.insert(coreLower)

            if let safeFix = SpellEngine.shared.highConfidenceSuggestion(for: analysis) {
                let finalReplacement = analysis.formattedReplacement(using: safeFix)
                AccessibilityBridge.shared.replaceSelectionDirect(with: finalReplacement)
                fixes.append(BatchFixSummary(from: analysis.coreWord, to: safeFix))

                if fixes.count >= maxReplacements {
                    break
                }

                // Allow web editor DOM to settle after paste
                usleep(55_000)
            }

            // Advance to next misspelled word
            currentSelected = AccessibilityBridge.shared.advanceToNextMisspelledWord(
                in: targetPID,
                temporarilyBypassHotkey: { [weak self] work in
                    self?.temporarilyBypassPrimaryHotKey(work)
                }
            )
        }

        // 3. Collapse selection to right edge so user can keep typing immediately
        AccessibilityBridge.shared.collapseSelectionToRightEdge()
        hasUncollapsedSpellBarSelection = false

        // 4. Restore original pasteboard contents after a settling interval
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            AccessibilityBridge.shared.restorePasteboard(from: savedPb)
        }

        // 5. Show summary toast pill
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil

        let anchor = AccessibilityBridge.shared.locateSelectionAnchor(for: targetPID)
        state.mode = .batchResult(fixes: fixes)
        pillShownAt = CACurrentMediaTime()
        registerModalHotKeys()
        panel.show(near: anchor)
        installOutsideMonitors()
        scheduleAutoDismiss(after: fixes.isEmpty ? 2.5 : 3.5)
    }

    private func skipToNextMisspelled() {
        guard targetPID != 0 else { return }
        let selected = AccessibilityBridge.shared.advanceToNextMisspelledWord(
            in: targetPID,
            temporarilyBypassHotkey: { [weak self] work in
                self?.temporarilyBypassPrimaryHotKey(work)
            }
        )
        hasUncollapsedSpellBarSelection = (selected != nil)
        presentAnalysis(for: selected)
    }

    private func presentAnalysis(for rawSelected: String?) {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil

        let anchor = AccessibilityBridge.shared.locateSelectionAnchor(for: targetPID)

        guard let raw = rawSelected, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.mode = .cleanWord("")
            pillShownAt = CACurrentMediaTime()
            registerModalHotKeys()
            panel.show(near: anchor)
            installOutsideMonitors()
            scheduleAutoDismiss(after: 3.0)
            return
        }

        let analysis = SpellEngine.shared.analyze(raw)
        currentAnalysis = analysis

        if !analysis.suggestions.isEmpty {
            state.activeIndex = 0
            state.mode = .suggestions(analysis)
            pillShownAt = CACurrentMediaTime()
            registerModalHotKeys()
            panel.show(near: anchor)
            installOutsideMonitors()
        } else {
            state.mode = .cleanWord(analysis.coreWord)
            pillShownAt = CACurrentMediaTime()
            registerModalHotKeys()
            panel.show(near: anchor)
            installOutsideMonitors()
            scheduleAutoDismiss(after: 3.0)
        }
    }

    private func commitReplacement(_ chosenSuggestion: String) {
        let analysis = currentAnalysis
        hasUncollapsedSpellBarSelection = false
        dismissPill(collapseSelection: false)

        let finalReplacement: String
        if let analysis = analysis {
            finalReplacement = analysis.formattedReplacement(using: chosenSuggestion)
        } else {
            finalReplacement = chosenSuggestion
        }

        AccessibilityBridge.shared.replaceSelection(with: finalReplacement)
    }

    func dismissPill(collapseSelection: Bool = false) {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        unregisterModalHotKeys()
        removeOutsideMonitors()
        state.mode = .hidden
        currentAnalysis = nil
        panel.orderOut(nil)

        if collapseSelection && hasUncollapsedSpellBarSelection {
            AccessibilityBridge.shared.collapseSelectionToRightEdge()
            hasUncollapsedSpellBarSelection = false
        }
    }

    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        autoDismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.dismissPill(collapseSelection: true)
        }
        autoDismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func installOutsideMonitors() {
        removeOutsideMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hasUncollapsedSpellBarSelection = false
                self?.dismissPill(collapseSelection: false)
            }
        }
        outsideKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let modalKeyCodes: Set<Int> = [
                kVK_Tab,
                kVK_Return,
                kVK_ANSI_KeypadEnter,
                kVK_DownArrow,
                kVK_UpArrow,
                kVK_LeftArrow,
                kVK_RightArrow,
                kVK_Escape,
                kVK_ANSI_N,
                kVK_ANSI_Quote,
                kVK_ANSI_1,
                kVK_ANSI_2,
                kVK_ANSI_3,
                kVK_ANSI_4,
                kVK_ANSI_5,
                kVK_ANSI_Semicolon,
                kVK_ANSI_H,
                kVK_ANSI_L,
                kVK_ANSI_J,
                kVK_ANSI_K
            ]
            if modalKeyCodes.contains(keyCode) {
                return
            }
            Task { @MainActor in
                guard let self = self, CACurrentMediaTime() - self.pillShownAt > 0.15 else { return }
                self.hasUncollapsedSpellBarSelection = false
                self.dismissPill(collapseSelection: false)
            }
        }
    }

    private func removeOutsideMonitors() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        if let m = outsideKeyMonitor {
            NSEvent.removeMonitor(m)
            outsideKeyMonitor = nil
        }
    }
}

// MARK: - Application Entry Point

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            SpellBarController.shared.setup()
        }
    }
}

@main
struct SpellBarMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
