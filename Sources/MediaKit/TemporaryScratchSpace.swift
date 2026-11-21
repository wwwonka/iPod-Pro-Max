import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Session-owned work files. A later launch only reaps sessions whose process is
/// known to have exited; age alone cannot establish that a file is abandoned.
final class TemporaryScratchSpace {
    private let root: URL
    private let session: URL

    init(root: URL) {
        self.root = root
        session = root.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
    }

    func url(extension suffix: String) -> URL {
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        return session.appendingPathComponent(UUID().uuidString + "." + suffix)
    }

    func cleanupAbandonedSessions() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders {
            let parts = folder.lastPathComponent.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]), pid > 0,
                  UUID(uuidString: String(parts[1])) != nil,
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  Self.processHasExited(pid) else { continue }
            try? manager.removeItem(at: folder)
        }
        // Old flat Scratch files have no owner. Leave them to the OS rather
        // than unlinking a file an older build could still be using.
    }

    private static func processHasExited(_ pid: Int32) -> Bool {
        #if os(Windows)
        if let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) {
            CloseHandle(handle)
            return false
        }
        return GetLastError() == ERROR_INVALID_PARAMETER
        #else
        // Permission denied and PID reuse both mean "keep", never "delete".
        return kill(pid, 0) != 0 && errno == ESRCH
        #endif
    }
}
