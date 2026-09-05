//
//  DFUUpdater.swift
//  Ecowitt WS90 FW Updater
//

import Foundation
import Observation

/// Drives the Homebrew `dfu-util` command-line tool to detect a WS90 in DFU
/// mode and download a DfuSe firmware image to it.
@Observable
final class DFUUpdater {
    enum Phase: Equatable {
        case idle
        case flashing
        case success
        case failure(String)
    }

    /// The WS90 uses the stock STM32 DFU bootloader (vendor 0483, product df11).
    static let deviceID = "0483:df11"

    private(set) var dfuUtilPath: String?
    private(set) var deviceDetected = false
    private(set) var phase: Phase = .idle
    private(set) var progressStage = ""
    /// 0...1 while erasing/downloading, nil when progress is unknown.
    private(set) var progressFraction: Double?
    private(set) var log = ""

    private var flashProcess: Process?

    var isFlashing: Bool { phase == .flashing }

    init() {
        refreshDfuUtilPath()
    }

    func refreshDfuUtilPath() {
        let candidates = [
            "/opt/homebrew/bin/dfu-util",   // Apple Silicon Homebrew
            "/usr/local/bin/dfu-util",      // Intel Homebrew
        ]
        dfuUtilPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `dfu-util -l` and checks whether an STM32 bootloader is attached.
    func refreshDeviceStatus() async {
        guard let dfuUtilPath, !isFlashing else { return }
        let output = await runCapturing(dfuUtilPath, ["-l"])
        deviceDetected = output.contains("Found DFU: [\(Self.deviceID)]")
    }

    /// Starts `dfu-util -a 0 -d 0483:df11 -D <firmware>` and streams its
    /// output into `log`, `progressStage`, and `progressFraction`.
    /// The target addresses come from the DfuSe file itself.
    func flash(firmware: URL) {
        guard let dfuUtilPath, !isFlashing else { return }
        phase = .flashing
        progressStage = "Starting"
        progressFraction = nil
        log = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dfuUtilPath)
        process.arguments = ["-a", "0", "-d", Self.deviceID, "-D", firmware.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            phase = .failure("Could not launch dfu-util: \(error.localizedDescription)")
            return
        }
        flashProcess = process

        Task {
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    consume(line: line)
                }
            } catch {
                appendLog("Error reading dfu-util output: \(error.localizedDescription)")
            }
            // The pipe hit EOF, so dfu-util is exiting; wait for its status
            // without blocking the main actor.
            while process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            flashProcess = nil
            if process.terminationStatus == 0 {
                progressStage = "Done"
                progressFraction = 1.0
                phase = .success
            } else {
                phase = .failure("dfu-util exited with status \(process.terminationStatus). See the log below for details.")
            }
        }
    }

    func cancelFlash() {
        flashProcess?.terminate()
    }

    func resetPhase() {
        guard !isFlashing else { return }
        phase = .idle
        progressStage = ""
        progressFraction = nil
    }

    private func consume(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // dfu-util redraws progress in place using carriage returns, e.g.
        // "Erase   \t[=========           ]  42%    33792 bytes"
        if let match = trimmed.firstMatch(of: #/^(Erase|Download)\s*\[[^\]]*\]\s*(\d+)%/#) {
            progressStage = match.1 == "Erase" ? "Erasing" : "Downloading"
            progressFraction = (Double(match.2) ?? 0) / 100
        } else {
            appendLog(trimmed)
        }
    }

    private func appendLog(_ line: String) {
        log += line + "\n"
    }

    /// Runs a command and returns its combined stdout/stderr, without
    /// blocking the main actor.
    private func runCapturing(_ path: String, _ arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ""
        }

        var output = ""
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                output += line + "\n"
            }
        } catch {
            // Partial output is fine for detection purposes.
        }
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return output
    }
}
