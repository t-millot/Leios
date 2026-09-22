// DeviceName.swift
// Leios — the name this Mac goes by, as a label for iCloud records and statistics.

import Foundation
import SystemConfiguration

public enum DeviceName {

    /// The computer name from System Settings → General → Sharing ("Thomas's MacBook Pro").
    ///
    /// Read from the dynamic store rather than through `Host.current()`, which builds the host's
    /// whole list of names and addresses first and can sit on name resolution for seconds when
    /// the network is unwell — and this is asked on the main actor on every settings upload.
    /// `hostName` is only the last resort: it can resolve too, and reads as "macbook-pro.local".
    public static var current: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName
    }
}
