//
//  FFmpeg.swift
//  iPod Pro Max
//
//  Shared ffmpeg process plumbing: finding the binary and running it. On the Mac it covers the jobs
//  AVFoundation is a poor fit for (audiobook chapters); on Linux and Windows it does all conversions.
//

import Foundation
import iPodKit

public enum FFmpeg {
    #if os(Windows)
    static let executableName = "ffmpeg.exe"
    static let platformFolder = "Windows"
    #elseif os(macOS)
    static let executableName = "ffmpeg"
    static let platformFolder = "macOS"
    #else
    static let executableName = "ffmpeg"
    static let platformFolder = "Linux"
    #endif

    /// Where ffmpeg is looked for, first match wins: `IPODPROMAX_FFMPEG`, next to the running
    /// executable, a `Tools/<OS>/` folder next to it or one level up (the layout on the iPod, see
    /// docs/Données/Sur l'iPod.md), the PATH, then the usual Homebrew and system locations.
    public static func binaryPath() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let explicit = env["IPODPROMAX_FFMPEG"], !explicit.isEmpty { candidates.append(explicit) }
        // The running binary's real location: argv[0] is just "ipodpromax" when launched from the PATH.
        let exeURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let exeDir = exeURL.resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent(executableName).path)
        for base in [exeDir, exeDir.deletingLastPathComponent(), exeDir.deletingLastPathComponent().deletingLastPathComponent()] {
            candidates.append(base.appendingPathComponent("Tools").appendingPathComponent(platformFolder).appendingPathComponent(executableName).path)
        }
        #if os(Windows)
        let separator: Character = ";"
        #else
        let separator: Character = ":"
        #endif
        for dir in (env["PATH"] ?? env["Path"] ?? "").split(separator: separator) where !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent(executableName).path)
        }
        #if !os(Windows)
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        #endif
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// A path for an ffmpeg concat list, where backslashes are escapes: forward slashes on Windows.
    static func concatPath(_ url: URL) -> String {
        #if os(Windows)
        return FileOps.nativePath(url).replacingOccurrences(of: "\\", with: "/")
        #else
        return FileOps.nativePath(url)
        #endif
    }

    /// The binary, or an error that tells the user how to get one.
    public static func requireBinary(for job: String) throws -> String {
        if let path = binaryPath() { return path }
        #if os(macOS)
        let hint = "Install it with “brew install ffmpeg”"
        #elseif os(Windows)
        let hint = "Put ffmpeg.exe next to ipodpromax.exe or in your PATH (winget install ffmpeg)"
        #else
        let hint = "Install it with your package manager (e.g. “sudo dnf install ffmpeg-free” or “sudo apt install ffmpeg”)"
        #endif
        throw IPodDBError.unsupported("\(job) needs ffmpeg. \(hint), then try again.")
    }

    /// Runs ffmpeg and waits. stdout lines go to `onOutput` (used with `-progress pipe:1`).
    public static func run(_ binary: String, _ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Without -nostdin, ffmpeg polls the console for keys and spins at 100 % CPU under Windows when
        // started without one.
        process.arguments = ["-nostdin"] + arguments
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe
        process.standardInput = FileHandle.nullDevice
        // Both pipes are drained while the process runs: a full pipe would block ffmpeg forever.
        let errorText = OutputCollector()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errorText.append(d) }
        }
        let lines = LineSplitter(onLine: onOutput)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { lines.append(d) }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errorText.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    if p.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: IPodDBError.io("ffmpeg failed: \(errorText.text.suffix(400))"))
                    }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs ffmpeg and returns its stderr even when it exits with an error (`ffmpeg -i file` prints
    /// the stream info there and exits 1 because no output is given).
    public static func probe(_ binary: String, _ arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Without -nostdin, ffmpeg polls the console for keys and spins at 100 % CPU under Windows when
        // started without one.
        process.arguments = ["-nostdin"] + arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let text = OutputCollector()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { text.append(d) }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                errPipe.fileHandleForReading.readabilityHandler = nil
                text.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume()
            }
            do { try process.run() } catch { cont.resume() }
        }
        return text.text
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) {
        lock.lock(); data.append(d); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ d: Data) {
        guard let onLine else { return }
        lock.lock()
        pending.append(d)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            pending.removeSubrange(pending.startIndex...nl)
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }
}
