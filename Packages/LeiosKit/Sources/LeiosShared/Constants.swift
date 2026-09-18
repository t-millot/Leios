// Constants.swift
// Leios — identifiers shared by the app and the helper.

import Foundation

public enum LeiosConstants {
    public static let appBundleID = "com.tmillot.Leios"
    public static let helperBundleID = "com.tmillot.Leios.Helper"
    public static let launchdLabel = helperBundleID
    public static let launchdPlistName = "com.tmillot.Leios.Helper.plist"
    public static let machServiceName = "com.tmillot.Leios.Helper.xpc"
    /// The CloudKit container settings sync through. The app carries the matching entitlement;
    /// the helper deliberately does not, so it never needs re-provisioning.
    public static let iCloudContainerID = "iCloud.com.tmillot.Leios"
    /// Path of the helper bundle relative to the main app bundle.
    public static let helperRelativePath = "Contents/Library/LoginItems/LeiosHelper.app"
    /// Path of the main app bundle relative to the helper bundle.
    public static let mainAppRelativePathFromHelper = "../../../../"

    public static let minButton = 3
    public static let maxButton = 32

    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let appleAccountSettingsURL = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!

    /// CGEventFlags values for keyboard modifiers (device independent bits).
    public enum ModifierFlag {
        public static let shift: UInt64 = 0x20000
        public static let control: UInt64 = 0x40000
        public static let option: UInt64 = 0x80000
        public static let command: UInt64 = 0x100000
    }
}
