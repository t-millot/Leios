// Constants.swift
// MousePilot — identifiers shared by the app and the helper.

import Foundation

public enum MPConstants {
    public static let appBundleID = "com.tmillot.MousePilot"
    public static let helperBundleID = "com.tmillot.MousePilot.Helper"
    public static let launchdLabel = helperBundleID
    public static let launchdPlistName = "com.tmillot.MousePilot.Helper.plist"
    public static let machServiceName = "com.tmillot.MousePilot.Helper.xpc"
    /// Path of the helper bundle relative to the main app bundle.
    public static let helperRelativePath = "Contents/Library/LoginItems/MousePilotHelper.app"
    /// Path of the main app bundle relative to the helper bundle.
    public static let mainAppRelativePathFromHelper = "../../../../"

    public static let minButton = 3
    public static let maxButton = 32

    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// CGEventFlags values for keyboard modifiers (device independent bits).
    public enum ModifierFlag {
        public static let shift: UInt64 = 0x20000
        public static let control: UInt64 = 0x40000
        public static let option: UInt64 = 0x80000
        public static let command: UInt64 = 0x100000
    }
}
