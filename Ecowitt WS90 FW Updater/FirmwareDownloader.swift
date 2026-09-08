//
//  FirmwareDownloader.swift
//  Ecowitt WS90 FW Updater
//

import Foundation
import Observation

/// Checks Ecowitt's WS90 product page for the newest published firmware and
/// downloads it. The page is plain server-rendered HTML with direct links to
/// oss.ecowitt.net; there is no supported API, so parsing is defensive and
/// failures fall back to pointing the user at the downloads page.
@Observable
final class FirmwareDownloader {
    enum State: Equatable {
        case idle
        case checking
        case available(version: String, url: URL)
        case downloading(version: String)
        case downloaded(version: String)
        case failed(String)
    }

    /// Ecowitt's quickstart page for the WS90 (product id 249).
    static let productPage = URL(string: "https://www.ecowitt.com/api/quickstart/product?id=249")!
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

    /// Fetches the product page and finds the highest-versioned WS90
    /// firmware zip linked from it (filenames look like "WS90_V1.6.2.zip").
    func check() async {
        state = .checking
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.productPage)
            guard let html = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            let matches = html.matches(of: #/href="(https://oss\.ecowitt\.net/uploads/[^"]*WS90[^"]*V([0-9][0-9.]*[0-9])[^"]*\.zip)"/#)
            guard let best = matches.max(by: { isVersion($0.2, olderThan: $1.2) }) else {
                throw DownloadError.pageFormatChanged
            }
            let href = String(best.1).replacingOccurrences(of: " ", with: "%20")
            guard let url = URL(string: href) else {
                throw DownloadError.pageFormatChanged
            }
            state = .available(version: String(best.2), url: url)
        } catch {
            state = .failed("Could not check for firmware: \(error.localizedDescription)")
        }
    }

    /// Downloads the zip found by `check()`, extracts it, validates that it
    /// contains a well-formed DfuSe file, and returns the extracted file's
    /// location in Application Support.
    func download() async -> URL? {
        guard case .available(let version, let url) = state else { return nil }
        state = .downloading(version: version)
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

            state = .downloaded(version: version)
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
    private func isVersion(_ a: Substring, olderThan b: Substring) -> Bool {
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
