//
//  DFUUpdater.swift
//  Ecowitt WS90 FW Updater
//

import Foundation
import Observation

/// Drives `dfu-util` (bundled with the app, falling back to Homebrew) to
/// detect a WS90 in DFU mode and download a DfuSe firmware image to it.
@Observable
final class DFUUpdater {
    enum Phase: Equatable {
        case idle
        case flashing
        case success(String)
        case failure(String)
    }

    struct DeviceInfo: Equatable {
        var serial: String
        var flashLayout: String
    }

    /// The WS90 uses the stock STM32 DFU bootloader (vendor 0483, product df11).
    static let deviceID = "0483:df11"

    private(set) var dfuUtilPath: String?
    private(set) var usingBundledTool = false
    private(set) var deviceInfo: DeviceInfo?
    private(set) var phase: Phase = .idle
    private(set) var progressStage = ""
    /// 0...1 while erasing/downloading, nil when progress is unknown.
    private(set) var progressFraction: Double?
    private(set) var log = ""

    var deviceDetected: Bool { deviceInfo != nil }
    var isFlashing: Bool {
        if case .flashing = phase { return true }
        return false
    }

    private var flashProcess: Process?
    private var sleepActivity: NSObjectProtocol?

    // Signals gleaned from dfu-util's output, used to build a targeted
    // failure message instead of a generic exit-status one.
    private var sawStaleState = false
    private var sawEraseError = false
    private var sawNoDevice = false
    private var sawProgress = false

    init() {
        refreshDfuUtilPath()
    }

    func refreshDfuUtilPath() {
        if let bundled = Bundle.main.path(forResource: "dfu-util", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundled) {
            dfuUtilPath = bundled
            usingBundledTool = true
            return
        }
        usingBundledTool = false
        let candidates = [
            "/opt/homebrew/bin/dfu-util",   // Apple Silicon Homebrew
            "/usr/local/bin/dfu-util",      // Intel Homebrew
        ]
        dfuUtilPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `dfu-util -l` and extracts the WS90's serial number and flash
    /// layout from its Internal Flash (alt=0) DFU interface.
    func refreshDeviceStatus() async {
        guard let dfuUtilPath, !isFlashing else { return }
        let output = await runCapturing(dfuUtilPath, ["-l"])
        for line in output.split(separator: "\n")
        where line.contains("Found DFU: [\(Self.deviceID)]") && line.contains("alt=0") {
            let serial = line.firstMatch(of: #/serial="([^"]*)"/#).map { String($0.1) } ?? "unknown"
            let layout = line.firstMatch(of: #/name="@([^"]*)"/#).map { String($0.1) } ?? ""
            deviceInfo = DeviceInfo(serial: serial,
                                    flashLayout: layout.trimmingCharacters(in: .whitespaces))
            return
        }
        deviceInfo = nil
    }

    /// Starts `dfu-util -a 0 -d 0483:df11 -t 512 -D <firmware>` and streams
    /// its output into `log`, `progressStage`, and `progressFraction`.
    /// The target addresses come from the DfuSe file itself. When `verify`
    /// is set, the programmed flash ranges are read back and compared to the
    /// file after a successful download.
    func flash(firmware: URL, verify: Bool) {
        guard let dfuUtilPath, !isFlashing else { return }
        phase = .flashing
        progressStage = "Starting"
        progressFraction = nil
        log = ""
        sawStaleState = false
        sawEraseError = false
        sawNoDevice = false
        sawProgress = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dfuUtilPath)
        // -t 512 matches Ecowitt's official update guide; at the 1024-byte
        // transfer size the device reports, the bootloader stalls during page
        // erases and dfu-util fails with 'Error during special command
        // "ERASE_PAGE"'.
        process.arguments = ["-a", "0", "-d", Self.deviceID, "-t", "512", "-D", firmware.path]

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
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Updating WS90 firmware")

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
                if verify {
                    await self.verify(firmware: firmware, with: dfuUtilPath)
                } else {
                    progressStage = "Done"
                    progressFraction = 1.0
                    phase = .success("Firmware updated successfully. Disconnect the USB cable, then press RESET on the station.")
                }
            } else if process.terminationReason == .uncaughtSignal {
                phase = .failure("Update canceled. Press RESET on the station so its LED flashes rapidly, then update again.")
            } else {
                phase = .failure(failureMessage(status: process.terminationStatus))
            }
            if let sleepActivity {
                ProcessInfo.processInfo.endActivity(sleepActivity)
                self.sleepActivity = nil
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

    /// Reads the programmed flash ranges back with `dfu-util -U` and compares
    /// them byte-for-byte against the firmware file.
    private func verify(firmware: URL, with dfuUtilPath: String) async {
        progressStage = "Verifying"
        progressFraction = nil
        appendLog("--- Verifying flash contents ---")

        let file: DfuSeFile
        do {
            file = try DfuSeFile(contentsOf: firmware)
        } catch {
            phase = .success("Firmware updated, but it could not be verified: \(error.localizedDescription).")
            return
        }

        var verifiedBytes = 0
        for (index, element) in file.elements.enumerated() {
            let readBackFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws90-verify-\(index)-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: readBackFile) }

            let range = String(format: "0x%08X:%d", element.address, element.data.count)
            let output = await runCapturing(dfuUtilPath,
                ["-a", "0", "-d", Self.deviceID, "-s", range, "-U", readBackFile.path])
            // Drop the in-place progress spam; keep the informative lines.
            appendLog(output.split(separator: "\n")
                .filter { !$0.contains("%") }
                .joined(separator: "\n"))

            guard let readBack = try? Data(contentsOf: readBackFile),
                  readBack.count >= element.data.count else {
                phase = .success("Firmware updated, but the device did not allow reading the flash back to verify it. This is normal if the bootloader has read-out protection enabled.")
                return
            }
            guard readBack.prefix(element.data.count) == element.data else {
                phase = .failure("Verification failed: the flash contents at \(String(format: "0x%08X", element.address)) do not match the firmware file. Press RESET on the station and run the update again.")
                return
            }
            verifiedBytes += element.data.count
        }
        progressStage = "Done"
        progressFraction = 1.0
        phase = .success("Firmware updated and verified — \(verifiedBytes.formatted()) bytes read back and matched. Disconnect the USB cable, then press RESET on the station.")
    }

    private func failureMessage(status: Int32) -> String {
        if sawNoDevice {
            return "The station is not in DFU mode. Reconnect it, press RESET so the LED flashes rapidly, then try again."
        }
        if sawEraseError {
            var message = "The bootloader rejected a flash erase command"
            if sawStaleState {
                message += " — it was likely stuck mid-update from an earlier attempt"
            }
            return message + ". Press RESET on the station so its LED flashes rapidly, then try again."
        }
        if sawStaleState {
            return "The station was not in a clean DFU state when the update started. Press RESET so the LED flashes rapidly, then try again."
        }
        return "Update failed (dfu-util exited with status \(status)). Press RESET on the station so its LED flashes rapidly, then try again. See the log below for details."
    }

    private func consume(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // dfu-util redraws progress in place using carriage returns, e.g.
        // "Erase   \t[=========           ]  42%    33792 bytes"
        if let match = trimmed.firstMatch(of: #/^(Erase|Download|Upload)\s*\[[^\]]*\]\s*(\d+)%/#) {
            progressStage = switch match.1 {
            case "Erase": "Erasing"
            case "Upload": "Verifying"
            default: "Downloading"
            }
            progressFraction = (Double(match.2) ?? 0) / 100
            sawProgress = true
            return
        }

        if trimmed.contains("Error during special command") {
            sawEraseError = true
        }
        if trimmed.contains("No DFU capable USB device") {
            sawNoDevice = true
        }
        // The status line dfu-util prints when it first claims the device;
        // anything but dfuIDLE means a previous attempt left the bootloader
        // mid-transfer.
        if !sawProgress,
           let match = trimmed.firstMatch(of: #/^DFU state\(\d+\) = ([\w-]+)/#),
           match.1 != "dfuIDLE" {
            sawStaleState = true
        }
        appendLog(trimmed)
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
