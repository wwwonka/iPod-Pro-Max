import Foundation
import iPodKit
#if os(macOS)
import IOKit
#elseif os(Windows)
import CWinDevices
#endif

/// Read-only OS identity; never creates a marker on the computer.
public enum HostIdentity {
    public static func current() -> String? {
        var raw: String?
        #if os(macOS)
        let entry = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            raw = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }
        #elseif os(Windows)
        var buffer = [UInt16](repeating: 0, count: 256)
        if ipm_machine_id(&buffer, buffer.count) != 0 {
            raw = String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
        }
        #else
        raw = try? String(contentsOfFile: "/etc/machine-id", encoding: .utf8)
        #endif
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
        // Do not expose the raw platform identifier in the portable registry.
        return SHA1.hash(Array(("ipodpromax.host:" + value).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
