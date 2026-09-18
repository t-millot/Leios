// ActionExecutor.swift
// Leios Engine — executes one-shot actions (ports Helper/Core/Actions/Actions.m incl. "Universal Back and Forward").
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import Carbon.HIToolbox
import LeiosShared

final class ActionExecutor {

    private let touchSim: TouchSimulator
    private let appUnderPointer: AppUnderPointerCache

    init(touchSim: TouchSimulator, appUnderPointer: AppUnderPointerCache) {
        self.touchSim = touchSim
        self.appUnderPointer = appUnderPointer
    }

    func execute(_ action: Action, phase: ActionPhase) {
        if phase == .end { return } // Phased actions are not implemented (matches Mac Mouse Fix).
        switch action {
        case .symbolicHotkey(let shk):
            SymbolicHotKeys.post(shk.rawValue)
        case .navigateBack:
            navigate(back: true)
        case .navigateForward:
            navigate(back: false)
        case .smartZoom:
            touchSim.postSmartZoom()
        case .middleClick:
            MouseButtonClicks.post(button: 3, count: 1)
        case .mouseButtonClicks(let button, let count):
            MouseButtonClicks.post(button: button, count: count)
        case .keyboardShortcut(let keyCode, let flags):
            KeyboardShortcuts.postKeyboardShortcut(keyCode: keyCode, flags: flags)
        case .systemDefinedEvent(let type, let flags):
            KeyboardShortcuts.postSystemDefinedEvent(type: type, flags: flags)
        }
    }

    // MARK: Universal Back and Forward

    private enum BackForwardMethod {
        case mouseButton, navigationSwipe, commandBracket, commandLeftRightArrow, optionCommandBracket
    }

    private func method(forBundleID bundleID: String?) -> BackForwardMethod {
        guard let bundleID, !bundleID.isEmpty else { return .mouseButton }
        func isBundle(_ prefix: String) -> Bool { bundleID.hasPrefix(prefix) }
        if isBundle("com.operasoftware.Opera") || isBundle("com.binarynights.ForkLift") { return .navigationSwipe }
        if isBundle("org.zotero.zotero") || isBundle("com.apple.systempreferences") || isBundle("com.apple.AppStore") { return .commandBracket }
        if isBundle("com.adobe.Acrobat.Pro") { return .commandLeftRightArrow }
        if isBundle("dev.warp.Warp") { return .commandBracket }
        if isBundle("com.apple.Music") { return .commandBracket }
        if isBundle("com.apple.iCal") { return .commandLeftRightArrow }
        if isBundle("com.apple.AddressBook") { return .commandBracket }
        if isBundle("com.apple.Notes") || isBundle("com.apple.freeform") { return .optionCommandBracket }
        if isBundle("com.apple.TV") || isBundle("com.apple.iBooksX") || isBundle("com.apple.Preview") { return .commandBracket }
        if isBundle("com.apple.") { return .navigationSwipe }
        return .mouseButton
    }

    private func navigate(back isLeft: Bool) {
        let bundleID = appUnderPointer.bundleID()
        let method = method(forBundleID: bundleID)
        Log.actions.debug("Universal back/forward: \(bundleID ?? "nil") → \(String(describing: method))")
        switch method {
        case .mouseButton:
            MouseButtonClicks.post(button: isLeft ? 4 : 5, count: 1)
        case .navigationSwipe:
            touchSim.postNavigationSwipe(direction: isLeft ? .left : .right)
        case .commandBracket, .optionCommandBracket:
            let flags: UInt64 = method == .commandBracket
                ? CGEventFlags.maskCommand.rawValue
                : (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
            // Localize the bracket key to the current keyboard layout (TIS APIs want the main thread).
            DispatchQueue.main.async {
                let char = isLeft ? "[" : "]"
                let bestGuess = isLeft ? Int(kVK_ANSI_LeftBracket) : Int(kVK_ANSI_RightBracket)
                let vkc = KeyboardLayout.searchVKC(for: char, bestGuess: bestGuess, flags: 0) ?? bestGuess
                KeyboardShortcuts.postKeyboardShortcut(keyCode: vkc, flags: flags)
            }
        case .commandLeftRightArrow:
            KeyboardShortcuts.postKeyboardShortcut(keyCode: isLeft ? Int(kVK_LeftArrow) : Int(kVK_RightArrow), flags: CGEventFlags.maskCommand.rawValue)
        }
    }
}
