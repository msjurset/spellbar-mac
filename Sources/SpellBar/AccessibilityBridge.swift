import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

public struct PasteboardSnapshotItem {
    public let typesAndData: [(NSPasteboard.PasteboardType, Data)]
}

public final class AccessibilityBridge {
    public static let shared = AccessibilityBridge()

    /// Caches the most recent valid Quartz screen rect of the selected word.
    private var lastKnownWordQuartzRect: CGRect?
    private var cachedCheckMenuItem: (pid: pid_t, element: AXUIElement)?
    private var manualAXEnabledPIDs = Set<pid_t>()

    public init() {}

    // MARK: - Permissions

    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public func promptForTrustIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - On-Demand Accessibility Activation

    /// Enables `AXManualAccessibility` on demand for the target app without setting `AXEnhancedUserInterface`
    /// (which would otherwise trigger heavy screen-reader DOM sync in Gmail/Chrome).
    public func ensureManualAccessibility(for pid: pid_t) {
        guard !manualAXEnabledPIDs.contains(pid) else { return }
        manualAXEnabledPIDs.insert(pid)
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElem, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Target App & Word Selection

    /// Triggers native "Check Document Now" (`Cmd + ;`) ONCE to highlight the nearest red-squiggly word.
    /// Only falls back to `Opt + Shift + Left` if `Check Document Now` produced zero selection and `fallbackToWordLeftOfCaret` is true.
    public func selectMisspelledOrCurrentWord(
        in pid: pid_t,
        hadActiveSelectionFromSpellBar: Bool,
        fallbackToWordLeftOfCaret: Bool = true,
        temporarilyBypassHotkey: (() -> Void) -> Void
    ) -> String? {
        lastKnownWordQuartzRect = nil
        ensureManualAccessibility(for: pid)

        // If SpellBar previously highlighted a word that was dismissed, collapse it first
        if hadActiveSelectionFromSpellBar {
            collapseSelectionToRightEdge()
            for _ in 0..<5 {
                usleep(12_000)
                let cur = readSelectionAndBoundsViaAX(in: pid)?.text ?? ""
                if cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
            }
        }

        // 1. Trigger native Check Document Now ONCE
        let menuTriggered = triggerCheckDocumentNowMenuItem(in: pid)
        if !menuTriggered {
            temporarilyBypassHotkey {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_Semicolon), flags: .maskCommand)
            }
        }

        // Poll up to 180ms for Chrome's Blink renderer IPC to highlight the red-squiggly word
        for _ in 0..<12 {
            usleep(15_000)
            if let (axText, axRect) = readSelectionAndBoundsViaAX(in: pid),
               !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let r = axRect {
                    lastKnownWordQuartzRect = r
                }
                return axText
            }
        }

        // Try pasteboard copy once in case the app does not expose AX text attributes
        if let copied = copySelectedTextPreservingPasteboard(),
           !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let (_, axRect) = readSelectionAndBoundsViaAX(in: pid), let r = axRect {
                lastKnownWordQuartzRect = r
            }
            return copied
        }

        // Direct AX document spell scan fallback (for apps without a standard Edit menu like JrnlBar)
        if let axMisspelled = scanAndSelectNextMisspelledViaAX(in: pid, fromCurrentCaret: true) {
            return axMisspelled
        }

        guard fallbackToWordLeftOfCaret else {
            return nil
        }

        // 2. ONLY if nothing at all is selected: select the single word immediately to the left of the caret
        let currentAXText = readSelectionAndBoundsViaAX(in: pid)?.text ?? ""
        if currentAXText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            postKeyStroke(keyCode: CGKeyCode(kVK_LeftArrow), flags: [.maskAlternate, .maskShift])

            for _ in 0..<8 {
                usleep(15_000)
                if let (axText, axRect) = readSelectionAndBoundsViaAX(in: pid),
                   !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let r = axRect {
                        lastKnownWordQuartzRect = r
                    }
                    return axText
                }
            }

            if let copied = copySelectedTextPreservingPasteboard(),
               !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return copied
            }
        }

        return nil
    }

    /// Advances to the next misspelled word in the active field (`Cmd + ;` again).
    public func advanceToNextMisspelledWord(
        in pid: pid_t,
        collapseCurrentSelectionFirst: Bool = false,
        allowCopyFallback: Bool = true,
        temporarilyBypassHotkey: (() -> Void) -> Void
    ) -> String? {
        let beforeText = readSelectionAndBoundsViaAX(in: pid)?.text

        if collapseCurrentSelectionFirst {
            collapseSelectionToRightEdge()
            for _ in 0..<6 {
                usleep(12_000)
                let cur = readSelectionAndBoundsViaAX(in: pid)?.text ?? ""
                if cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
            }
            usleep(20_000)
        }

        let menuTriggered = triggerCheckDocumentNowMenuItem(in: pid)
        if !menuTriggered {
            temporarilyBypassHotkey {
                postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_Semicolon), flags: .maskCommand)
            }
        }

        for _ in 0..<12 {
            usleep(15_000)
            if let (axText, axRect) = readSelectionAndBoundsViaAX(in: pid),
               !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let r = axRect {
                    lastKnownWordQuartzRect = r
                }
                if collapseCurrentSelectionFirst || axText != beforeText {
                    return axText
                }
            }
        }

        if let (axText, axRect) = readSelectionAndBoundsViaAX(in: pid),
           !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let r = axRect {
                lastKnownWordQuartzRect = r
            }
            return axText
        }

        if allowCopyFallback,
           let copied = copySelectedTextPreservingPasteboard(),
           !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return copied
        }

        // Direct AX document spell scan fallback for accessory / menu-bar-less apps
        if let axMisspelled = scanAndSelectNextMisspelledViaAX(in: pid, fromCurrentCaret: true) {
            return axMisspelled
        }

        return nil
    }

    // MARK: - Transient Pasteboard Metadata Types

    public static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let autoGeneratedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    public static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Writes `string` to the pasteboard marked with transient/autogenerated metadata
    /// so clipboard history managers (Raycast, Alfred, Maccy, Paste, 1Password) ignore it.
    public func writeTransientString(_ string: String, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        item.setData(Data(), forType: AccessibilityBridge.transientPasteboardType)
        item.setData(Data(), forType: AccessibilityBridge.autoGeneratedPasteboardType)
        item.setData(Data(), forType: AccessibilityBridge.concealedPasteboardType)
        pb.writeObjects([item])
    }

    /// Replaces the currently selected text directly via macOS Accessibility API (`kAXSelectedTextAttribute`).
    /// In native Cocoa / AppKit applications (and Safari / WebKit), this replaces the text in place
    /// without touching `NSPasteboard.general` or synthesizing clipboard shortcut keys.
    @discardableResult
    public func replaceSelectionDirectViaAX(with replacement: String, in pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let appElem = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return false
        }

        var candidates: [AXUIElement] = [focused as! AXUIElement]
        var curr: AXUIElement = focused as! AXUIElement
        for _ in 0..<8 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(curr, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else {
                break
            }
            let parentElem = parent as! AXUIElement
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(parentElem, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String,
               role == "AXWebArea" {
                candidates.append(parentElem)
                break
            }
            curr = parentElem
        }

        for elem in candidates {
            var isSettable: DarwinBoolean = false
            let settableStatus = AXUIElementIsAttributeSettable(elem, kAXSelectedTextAttribute as CFString, &isSettable)
            if settableStatus == .success && isSettable.boolValue {
                let setStatus = AXUIElementSetAttributeValue(elem, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef)
                if setStatus == .success {
                    return true
                }
            }
        }
        return false
    }

    /// Collapses an active selection to its right edge so the caret returns to normal typing position.
    public func collapseSelectionToRightEdge() {
        postKeyStroke(keyCode: CGKeyCode(kVK_RightArrow), flags: [])
    }

    /// Replaces the currently highlighted selection in the active app.
    /// Prefers direct Accessibility replacement (zero clipboard touch).
    /// If unsupported by the target app, falls back to pasting via pasteboard with transient metadata
    /// so clipboard history managers (Raycast, Alfred, Maccy) ignore the item, and immediately restores original clipboard.
    public func replaceSelection(with replacement: String, in pid: pid_t = 0) {
        if pid > 0 && replaceSelectionDirectViaAX(with: replacement, in: pid) {
            return
        }

        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)

        writeTransientString(replacement, to: pb)

        usleep(12_000)
        postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        // Restore original clipboard after target app processes paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            self.restorePasteboard(pb, from: saved)
        }
    }

    /// Replaces the active selection immediately without scheduling pasteboard restoration (used during batch auto-fix passes).
    public func replaceSelectionDirect(with replacement: String, in pid: pid_t = 0) {
        if pid > 0 && replaceSelectionDirectViaAX(with: replacement, in: pid) {
            return
        }

        let pb = NSPasteboard.general
        writeTransientString(replacement, to: pb)

        usleep(15_000)
        postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    /// Replaces the active selection and waits for the target application to process the change before returning.
    public func replaceSelectionAndWait(with replacement: String, previousSelection: String, in pid: pid_t) {
        if pid > 0 && replaceSelectionDirectViaAX(with: replacement, in: pid) {
            // Direct AX replacement succeeded with zero clipboard interaction.
            usleep(25_000)
            return
        }

        let pb = NSPasteboard.general
        writeTransientString(replacement, to: pb)

        usleep(15_000)
        postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        for _ in 0..<12 {
            usleep(15_000)
            let current = readSelectionAndBoundsViaAX(in: pid)?.text ?? ""
            if current.isEmpty || current != previousSelection {
                break
            }
        }

        // Allow web editor DOM and spellcheck markers to settle after paste
        usleep(65_000)
    }

    // MARK: - AX Selection & Exact Word Screen Bounds

    /// Reads both the selected text and its exact Quartz screen rectangle using `AXSelectedTextMarkerRange` (Chrome/WebKit)
    /// and `kAXSelectedTextRangeAttribute` (Standard AppKit/Electron).
    public func readSelectionAndBoundsViaAX(in pid: pid_t) -> (text: String, rect: CGRect?)? {
        let appElem = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return nil
        }

        // Build candidate elements: the focused element itself, plus any ancestor AXWebArea
        var candidates: [AXUIElement] = [focused as! AXUIElement]
        var curr: AXUIElement = focused as! AXUIElement
        for _ in 0..<8 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(curr, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else {
                break
            }
            let parentElem = parent as! AXUIElement
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(parentElem, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String,
               role == "AXWebArea" {
                candidates.append(parentElem)
                break
            }
            curr = parentElem
        }

        var foundText: String?
        var foundRect: CGRect?

        for elem in candidates {
            // Method 1: AXSelectedTextMarkerRange (Chrome / Safari contenteditable & DOM inputs)
            var markerRangeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, "AXSelectedTextMarkerRange" as CFString, &markerRangeRef) == .success,
               let markerRange = markerRangeRef {
                if foundText == nil {
                    var strRef: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(
                        elem,
                        "AXStringForTextMarkerRange" as CFString,
                        markerRange,
                        &strRef
                    ) == .success,
                       let s = strRef as? String,
                       !s.isEmpty {
                        foundText = s
                    }
                }
                if foundRect == nil {
                    var boundsRef: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(
                        elem,
                        "AXBoundsForTextMarkerRange" as CFString,
                        markerRange,
                        &boundsRef
                    ) == .success,
                       let boundsVal = boundsRef,
                       CFGetTypeID(boundsVal) == AXValueGetTypeID() {
                        var r = CGRect.zero
                        if AXValueGetValue(boundsVal as! AXValue, .cgRect, &r),
                           isValidScreenRect(r) {
                            foundRect = r
                        }
                    }
                }
            }

            // Method 2: Standard kAXSelectedTextAttribute + kAXSelectedTextRangeAttribute -> kAXBoundsForRangeParameterizedAttribute
            if foundText == nil {
                var selTextRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(elem, kAXSelectedTextAttribute as CFString, &selTextRef) == .success,
                   let s = selTextRef as? String,
                   !s.isEmpty {
                    foundText = s
                }
            }

            if foundRect == nil {
                var rangeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
                   let rangeVal = rangeRef {
                    var boundsRef: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(
                        elem,
                        kAXBoundsForRangeParameterizedAttribute as CFString,
                        rangeVal,
                        &boundsRef
                    ) == .success,
                       let boundsVal = boundsRef,
                       CFGetTypeID(boundsVal) == AXValueGetTypeID() {
                        var r = CGRect.zero
                        if AXValueGetValue(boundsVal as! AXValue, .cgRect, &r),
                           isValidScreenRect(r) {
                            foundRect = r
                        }
                    }
                }
            }

            if foundText != nil && foundRect != nil {
                break
            }
        }

        if let text = foundText {
            return (text, foundRect)
        }
        return nil
    }

    private func isValidScreenRect(_ r: CGRect) -> Bool {
        guard !r.isNull, !r.isInfinite else { return false }
        guard r.origin.x > 1, r.origin.y > 1 else { return false }
        return r.width >= 2 && r.height >= 6 && r.height < 200
    }

    // MARK: - Screen Coordinates for Floating Pill

    /// Determines the best screen coordinate (in AppKit bottom-left screen space) directly under the selected word.
    public func locateSelectionAnchor(for pid: pid_t) -> NSPoint {
        // 1. Use cached word rect from the selection step if valid
        if let cached = lastKnownWordQuartzRect, isValidScreenRect(cached) {
            return quartzRectToAppKitAnchor(cached)
        }

        // 2. Query live selection bounds via AXSelectedTextMarkerRange / AXBoundsForRange
        if let (_, rect) = readSelectionAndBoundsViaAX(in: pid),
           let validRect = rect,
           isValidScreenRect(validRect) {
            return quartzRectToAppKitAnchor(validRect)
        }

        // 3. Fallback to the focused element's frame (input / textarea / editor box)
        let appElem = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef {
            let elem = focused as! AXUIElement
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(elem, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let posVal = posRef,
               let sizeVal = sizeRef {
                var pt = CGPoint.zero
                var sz = CGSize.zero
                if AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
                   AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz),
                   pt != .zero,
                   sz.height > 0 && sz.height < 500 {
                    // Place near the top-left / middle of the text editor box
                    let anchorRect = CGRect(x: pt.x + 16, y: pt.y + min(sz.height, 42), width: min(sz.width, 200), height: 22)
                    return quartzRectToAppKitAnchor(anchorRect)
                }
            }
        }

        // 4. Fallback to frontmost window center-top if all element queries fail
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let win = winRef {
            let winElem = win as! AXUIElement
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(winElem, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(winElem, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let posVal = posRef,
               let sizeVal = sizeRef {
                var pt = CGPoint.zero
                var sz = CGSize.zero
                if AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
                   AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz),
                   sz.width > 0 {
                    let rect = CGRect(x: pt.x + sz.width * 0.35, y: pt.y + sz.height * 0.35, width: 100, height: 24)
                    return quartzRectToAppKitAnchor(rect)
                }
            }
        }

        let mouse = NSEvent.mouseLocation
        return NSPoint(x: mouse.x, y: mouse.y - 12)
    }

    private func quartzRectToAppKitAnchor(_ quartzRect: CGRect) -> NSPoint {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let appKitBottomY = primaryScreenHeight - quartzRect.origin.y - quartzRect.size.height
        return NSPoint(x: quartzRect.origin.x, y: appKitBottomY)
    }

    // MARK: - Menu Item Trigger ("Check Document Now")

    private func triggerCheckDocumentNowMenuItem(in pid: pid_t) -> Bool {
        if let cached = cachedCheckMenuItem, cached.pid == pid {
            if AXUIElementPerformAction(cached.element, kAXPressAction as CFString) == .success {
                return true
            }
            cachedCheckMenuItem = nil
        }

        let appElem = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            return false
        }

        if let item = findMenuItem(titled: "Check Document Now", in: (menuBar as! AXUIElement), depth: 0) {
            cachedCheckMenuItem = (pid, item)
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        return false
    }

    private func findMenuItem(titled targetTitle: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 8 else { return nil }

        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            if title == targetTitle || title.hasPrefix("Check Document Now") {
                return element
            }
            if depth == 1 && title != "Edit" && !title.isEmpty {
                return nil
            }
            if depth == 3 && title != "Spelling and Grammar" && !title.isEmpty {
                return nil
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let found = findMenuItem(titled: targetTitle, in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - Pasteboard-Safe Copy Probe

    private func copySelectedTextPreservingPasteboard() -> String? {
        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)

        // Clear pasteboard first so we can NEVER read stale clipboard contents
        pb.clearContents()
        let clearedCount = pb.changeCount

        postKeyStroke(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)

        var copied: String? = nil
        for _ in 0..<16 {
            usleep(6_000)
            if pb.changeCount != clearedCount {
                copied = pb.string(forType: .string)
                break
            }
        }

        restorePasteboard(pb, from: saved)
        return copied
    }

    public func snapshotPasteboard(_ pb: NSPasteboard = .general) -> [[(NSPasteboard.PasteboardType, Data)]] {
        guard let items = pb.pasteboardItems else { return [] }
        var snapshot: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    pairs.append((type, data))
                }
            }
            if !pairs.isEmpty {
                snapshot.append(pairs)
            }
        }
        return snapshot
    }

    public func restorePasteboard(_ pb: NSPasteboard = .general, from snapshot: [[(NSPasteboard.PasteboardType, Data)]]) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        var newItems: [NSPasteboardItem] = []
        for itemPairs in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in itemPairs {
                item.setData(data, forType: type)
            }
            newItems.append(item)
        }
        pb.writeObjects(newItems)
    }

    // MARK: - Key Event Synthesis

    public func postKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Direct AX Spell Scan Fallback

    /// Directly scans the text of the focused AX text element for misspellings using `NSSpellChecker`
    /// and selects the misspelled range via `kAXSelectedTextRangeAttribute`.
    /// Used for accessory/status-bar apps (like JrnlBar) that lack a standard "Check Document Now" menu item.
    public func scanAndSelectNextMisspelledViaAX(in pid: pid_t, fromCurrentCaret: Bool = true) -> String? {
        let appElem = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return nil
        }
        let elem = focused as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String,
              !fullText.isEmpty else {
            return nil
        }

        let nsText = fullText as NSString
        var searchStart = 0

        if fromCurrentCaret {
            var rangeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
               let rangeVal = rangeRef,
               CFGetTypeID(rangeVal) == AXValueGetTypeID() {
                var cfRange = CFRange()
                if AXValueGetValue(rangeVal as! AXValue, .cfRange, &cfRange) {
                    searchStart = cfRange.location + cfRange.length
                }
            }
        }

        if searchStart > nsText.length {
            searchStart = 0
        }

        let checker = NSSpellChecker.shared
        let language = checker.language()

        // 1. Scan forward from searchStart
        var miss = checker.checkSpelling(
            of: fullText,
            startingAt: searchStart,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )

        // 2. Wrap around to start if not found forward and we started mid-document
        if miss.location == NSNotFound && searchStart > 0 {
            let wrapMiss = checker.checkSpelling(
                of: fullText,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            if wrapMiss.location != NSNotFound && wrapMiss.location < searchStart {
                miss = wrapMiss
            }
        }

        guard miss.location != NSNotFound, miss.length > 0,
              miss.location + miss.length <= nsText.length else {
            return nil
        }

        // Programmatically select the misspelled range in the target app
        var targetRange = CFRange(location: miss.location, length: miss.length)
        if let axVal = AXValueCreate(.cfRange, &targetRange) {
            AXUIElementSetAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, axVal)
            usleep(20_000)
        }

        if let (axText, axRect) = readSelectionAndBoundsViaAX(in: pid),
           !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let r = axRect {
                lastKnownWordQuartzRect = r
            }
            return axText
        }

        let extracted = nsText.substring(with: miss)
        return extracted
    }
}
