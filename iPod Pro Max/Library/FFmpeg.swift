//
//  FFmpeg.swift
//  iPod Pro Max
//
//  Shared ffmpeg process plumbing (locating the binary, running it) for the handful of jobs it's a
//  better fit for than hand-rolling with AVFoundation — audiobook chapter merging and ID3 tag fixups.
//

import Foundation

enum FFmpeg {
    static func binaryPath() -> String? {
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func run(_ binary: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(throwing: IPodDBError.io("ffmpeg failed: \(text.prefix(300))"))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
