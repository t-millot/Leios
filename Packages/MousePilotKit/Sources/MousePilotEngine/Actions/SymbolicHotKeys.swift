// SymbolicHotKeys.swift
// MousePilot Engine — triggers macOS symbolic hotkeys (Mission Control, Launchpad, …) by synthesizing the key
// combination bound to them, rebinding to an unreachable key if the user disabled the shortcut.
// Ports Helper/Core/Actions/SymbolicHotKeys.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import Carbon.HIToolbox
import CPrivateShim

enum SymbolicHotKeys {

    private static let keyEquivalentNull: UInt16 = 65535
    private static let vkcNull: Int = 65535
    /// A virtual key code no real keyboard produces.
    private static let vkcOutOfReach = 400

    /// Posts the hotkey. Uses TIS APIs, so it always runs on the main thread.
    static func post(_ shk: Int) {
        DispatchQueue.main.async {
            postOnMain(shk)
        }
    }

    private static func postOnMain(_ shk: Int) {
        var keq: UInt16 = 0
        var vkc: UInt16 = 0
        var mods: CGSModifierFlags = 0
        CGSGetSymbolicHotKeyValue(CGSSymbolicHotKey(shk), &keq, &vkc, &mods)

        var vkcReachable = vkcNull
        if CGSIsSymbolicHotKeyEnabled(CGSSymbolicHotKey(shk)) {
            if keq == keyEquivalentNull {
                vkcReachable = Int(vkc)
            } else {
                let keqString = String(utf16CodeUnits: [keq], count: 1)
                vkcReachable = KeyboardLayout.searchVKC(for: keqString, bestGuess: Int(vkc), flags: 0) ?? vkcNull
            }
        }

        if vkcReachable != vkcNull {
            KeyboardShortcuts.postKeyEvents(keyCode: vkcReachable, flags: UInt64(mods))
        } else {
            // Permanently bind the hotkey to an unreachable key so it always works without changing the keyboard's behavior.
            CGSSetSymbolicHotKeyEnabled(CGSSymbolicHotKey(shk), true)
            let newVkc = UInt16(shk + vkcOutOfReach)
            let newMods = CGSModifierFlags(kCGSNumericPadKeyMask | kCGSFunctionKeyMask)
            let err = CGSSetSymbolicHotKeyValue(CGSSymbolicHotKey(shk), keyEquivalentNull, newVkc, newMods)
            if err != .success {
                Log.actions.error("CGSSetSymbolicHotKeyValue failed: \(err.rawValue)")
            }
            KeyboardShortcuts.postKeyEvents(keyCode: Int(newVkc), flags: UInt64(newMods))
        }
    }
}

/// Keyboard-layout aware virtual-key-code lookup (ports searchVKCForStr / getStrForVKC / getCurrentKeyboardLayoutForKbShortcuts).
enum KeyboardLayout {

    private static let firstAppleKey = 0x80

    /// The key code that produces `string` on the current layout (falling back to ABC for non-ASCII-capable layouts).
    /// Main thread only (TIS).
    static func searchVKC(for string: String, bestGuess: Int?, flags: UInt64) -> Int? {
        guard !string.isEmpty else { return nil }
        guard let layout = currentLayoutForShortcuts() else { return nil }
        let kbType = KeyboardShortcuts.currentKeyboardType
        if let guess = bestGuess, guess < firstAppleKey, character(forVKC: guess, layout: layout, keyboardType: kbType, flags: flags) == string {
            return guess
        }
        for vkc in 0..<firstAppleKey {
            if character(forVKC: vkc, layout: layout, keyboardType: kbType, flags: flags) == string {
                return vkc
            }
        }
        return nil
    }

    private static func character(forVKC vkc: Int, layout: UnsafePointer<UCKeyboardLayout>, keyboardType: UInt32, flags: UInt64) -> String? {
        var modifierKeyState: UInt32 = 0
        if flags & CGEventFlags.maskCommand.rawValue != 0 { modifierKeyState |= UInt32(cmdKey) }
        if flags & CGEventFlags.maskShift.rawValue != 0 { modifierKeyState |= UInt32(shiftKey) }
        if flags & CGEventFlags.maskAlphaShift.rawValue != 0 { modifierKeyState |= UInt32(alphaLock) }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { modifierKeyState |= UInt32(optionKey) }
        if flags & CGEventFlags.maskControl.rawValue != 0 { modifierKeyState |= UInt32(controlKey) }
        modifierKeyState = (modifierKeyState >> 8) & 0xFF

        var deadKeyState: UInt32 = 0
        let maxLength = 255
        var actualLength = 0
        var chars = [UniChar](repeating: 0, count: maxLength + 1)
        let status = UCKeyTranslate(layout, UInt16(vkc), UInt16(kUCKeyActionDisplay), modifierKeyState, keyboardType, 0, &deadKeyState, maxLength, &actualLength, &chars)
        guard status == noErr else { return nil }
        if actualLength > 0, let scalar = Unicode.Scalar(chars[0]), CharacterSet.controlCharacters.contains(scalar) {
            return ""
        }
        return String(utf16CodeUnits: chars, count: actualLength)
    }

    /// Layout data pointer for the current keyboard layout, or the ABC layout when the current one is not ASCII capable.
    private static func currentLayoutForShortcuts() -> UnsafePointer<UCKeyboardLayout>? {
        guard let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        var source = current
        if let ascii = TISGetInputSourceProperty(current, kTISPropertyInputSourceIsASCIICapable) {
            let isASCII = Unmanaged<CFBoolean>.fromOpaque(ascii).takeUnretainedValue()
            if !CFBooleanGetValue(isASCII) {
                let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.ABC"] as CFDictionary
                if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], let abc = list.first {
                    source = abc
                }
            }
        }
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue()
        // The CFData is owned by the input source, which TIS keeps alive for the process.
        return UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
    }
}
