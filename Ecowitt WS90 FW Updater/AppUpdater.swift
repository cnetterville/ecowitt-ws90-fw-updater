//
//  AppUpdater.swift
//  Ecowitt WS90 FW Updater
//

import AppKit
import Foundation
import Observation

/// Checks GitHub for a newer release of this app and, when one exists,
/// downloads it, replaces the running app bundle, and relaunches.
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case downloading(version: String)
        case failed(String)
    }

    /// GitHub API endpoint for the newest published release.
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/cnetterville/ecowitt-ws90-fw-updater/releases/latest")!
    /// Human-facing releases page, offered as a fallback when updating fails.
    static let releasesPage = URL(string: "https://github.com/cnetterville/ecowitt-ws90-fw-updater/releases/latest")!

    private(set) var state: State = .idle

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: true
        default: false
        }
    }

    enum UpdateError: LocalizedError {
        case noAppAsset
        case noAppInArchive
        case extractionFailed
        case translocated

        var errorDescription: String? {
            switch self {
            case .noAppAsset:
                "The latest release has no app download attached."
            case .noAppInArchive:
                "The downloaded archive did not contain the app."
            case .extractionFailed:
                "The downloaded archive could not be extracted."
            case .translocated:
                "The app cannot update itself from this location. Move it to Applications and try again."
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Asks the GitHub API for the newest release and compares its tag
    /// (e.g. "v1.2.0") against the running app's version.
    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)

            let latest = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName
            guard isVersion(currentVersion[...], olderThan: latest[...]) else {
                state = .upToDate
                return
            }
            guard let asset = release.assets.first(where: {
                $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("updater")
            }) else {
                throw UpdateError.noAppAsset
            }
            state = .available(version: latest, url: asset.browserDownloadURL)
        } catch {
            state = .failed("Could not check for app updates: \(error.localizedDescription)")
        }
    }

    /// Downloads the update found by `check()`, swaps it in for the running
    /// app bundle, and relaunches. On success this does not return — the app
    /// terminates and the new version starts.
    func downloadAndInstall() async {
        guard case .available(let version, let url) = state else { return }
        state = .downloading(version: version)
        do {
            let bundleURL = Bundle.main.bundleURL
            // A quarantined app runs from a read-only translocated path and
            // cannot replace itself.
            guard !bundleURL.path.contains("/AppTranslocation/") else {
                throw UpdateError.translocated
            }

            let (tempZip, _) = try await URLSession.shared.download(from: url)
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws90-app-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            try await extractZip(at: tempZip, into: workDir)

            guard let newApp = firstApp(in: workDir) else {
                throw UpdateError.noAppInArchive
            }

            // Move the running app aside (macOS allows this — the binary
            // stays mapped), put the new version in its place, and restore
            // the old one if that fails.
            let aside = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws90-app-old-\(UUID().uuidString).app")
            try FileManager.default.moveItem(at: bundleURL, to: aside)
            do {
                try FileManager.default.moveItem(at: newApp, to: bundleURL)
            } catch {
                try? FileManager.default.moveItem(at: aside, to: bundleURL)
                throw error
            }
            try? FileManager.default.removeItem(at: workDir)

            relaunch(appAt: bundleURL)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    /// Reopens the app at the given path after a short delay, then quits.
    private func relaunch(appAt url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open \"\(url.path)\""]
        try? process.run()
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }

    private func firstApp(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory,
                                                        includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension.lowercased() == "app" {
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
            throw UpdateError.extractionFailed
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
