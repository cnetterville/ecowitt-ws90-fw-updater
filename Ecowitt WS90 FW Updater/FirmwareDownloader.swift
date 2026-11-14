//
//  FirmwareDownloader.swift
//  Ecowitt WS90 FW Updater
//

import Foundation
import Observation

/// The station models this app can fetch firmware for. Both use the same
/// STM32 DFU bootloader, so the flashing side is identical; only the firmware
/// image differs.
enum StationModel: String, CaseIterable, Identifiable {
    case ws90 = "WS90"
    case ws80 = "WS80"

    var id: String { rawValue }

    /// Ecowitt's quickstart page for the model (product id 249 is the WS90,
    /// 46 the WS80).
    var productPage: URL {
        switch self {
        case .ws90: URL(string: "https://www.ecowitt.com/api/quickstart/product?id=249")!
        case .ws80: URL(string: "https://www.ecowitt.com/api/quickstart/product?id=46")!
        }
    }
}

/// Checks Ecowitt's product page for the newest published firmware and
/// downloads it. The page is plain server-rendered HTML with direct links to
/// oss.ecowitt.net; there is no supported API, so parsing is defensive and
/// failures fall back to pointing the user at the downloads page.
@Observable
final class FirmwareDownloader {
    enum State: Equatable {
        case idle
        case checking
        case available(model: StationModel, version: String, url: URL)
        case downloading(model: StationModel, version: String)
        case downloaded(model: StationModel, version: String)
        case failed(String)
    }

    /// Human-facing downloads page, offered as a fallback when parsing fails.
    static let manualDownloadsPage = URL(string: "https://www.ecowitt.com/support/download/")!

    private(set) var state: State = .idle

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: true
        default: false
        }
    }

    enum DownloadError: LocalizedError {
        case pageFormatChanged
        case noDfuInArchive
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .pageFormatChanged:
                "No firmware download was found on Ecowitt's page; its layout may have changed."
            case .noDfuInArchive:
                "The downloaded archive did not contain a .dfu firmware file."
            case .extractionFailed:
                "The downloaded archive could not be extracted."
            }
        }
    }

    /// Forgets the result of an earlier check, e.g. when the user picks a
    /// different model.
    func reset() {
        guard !isBusy else { return }
        state = .idle
    }

    /// Fetches the model's product page and finds the highest-versioned
    /// firmware zip for it linked from there.
    func check(for model: StationModel) async {
        state = .checking
        do {
            let (data, _) = try await URLSession.shared.data(from: model.productPage)
            guard let html = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            guard let best = Self.latestFirmware(in: html, for: model) else {
                throw DownloadError.pageFormatChanged
            }
            state = .available(model: model, version: best.version, url: best.url)
        } catch {
            state = .failed("Could not check for firmware: \(error.localizedDescription)")
        }
    }

    /// Finds the highest-versioned firmware zip for `model` among the
    /// oss.ecowitt.net links in a product page (filenames look like
    /// "WS90_V1.6.2.zip"). Zips for other models and the Windows toolkit
    /// archives, which carry no version, are ignored.
    static func latestFirmware(in html: String, for model: StationModel) -> (version: String, url: URL)? {
        var best: (version: String, url: URL)?
        for match in html.matches(of: #/href="(https://oss\.ecowitt\.net/uploads/[^"]*\.zip)"/#) {
            let href = String(match.1)
            guard let fileName = href.split(separator: "/").last,
                  fileName.contains(model.rawValue),
                  let version = fileName.firstMatch(of: #/V([0-9][0-9.]*[0-9])/#)?.1,
                  let url = URL(string: href.replacingOccurrences(of: " ", with: "%20")) else {
                continue
            }
            if best == nil || isVersion(best!.version[...], olderThan: version) {
                best = (String(version), url)
            }
        }
        return best
    }

    /// Downloads the zip found by `check()`, extracts it, validates that it
    /// contains a well-formed DfuSe file, and returns the extracted file's
    /// location in Application Support.
    func download() async -> URL? {
        guard case .available(let model, let version, let url) = state else { return nil }
        state = .downloading(model: model, version: version)
        do {
            let (tempZip, _) = try await URLSession.shared.download(from: url)
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws90-firmware-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            try await extractZip(at: tempZip, into: workDir)

            guard let dfuURL = firstDfuFile(in: workDir) else {
                throw DownloadError.noDfuInArchive
            }
            // Throws if the file is not a valid DfuSe image.
            _ = try DfuSeFile(contentsOf: dfuURL)

            let destDir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask,
                     appropriateFor: nil, create: true)
                .appendingPathComponent("Ecowitt WS90 FW Updater/Firmware", isDirectory: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destination = destDir.appendingPathComponent(dfuURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: dfuURL, to: destination)

            state = .downloaded(model: model, version: version)
            return destination
        } catch {
            state = .failed("Download failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func firstDfuFile(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory,
                                                        includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension.lowercased() == "dfu" {
                return item
            }
        }
        return nil
    }

    private func extractZip(at zip: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard process.terminationStatus == 0 else {
            throw DownloadError.extractionFailed
        }
    }

    /// Numeric component-wise comparison, so "1.10.0" beats "1.6.2".
    private static func isVersion(_ a: Substring, olderThan b: Substring) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}
