//
//  ContentView.swift
//  Ecowitt WS90 FW Updater
//
//  Created by Curtis Netterville on 9/4/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var updater = DFUUpdater()
    @State private var downloader = FirmwareDownloader()
    @State private var appUpdater = AppUpdater()
    @State private var firmwareURL: URL?
    @State private var showingFilePicker = false
    @State private var showingCancelConfirmation = false
    @State private var showingAcknowledgments = false
    @AppStorage("verifyAfterUpdate") private var verifyAfterUpdate = true

    private var dfuFileType: UTType {
        UTType(filenameExtension: "dfu") ?? .data
    }

    private var readyToFlash: Bool {
        updater.dfuUtilPath != nil && updater.deviceDetected && firmwareURL != nil && !updater.isFlashing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            requirementsSection
            firmwareSection
            statusSection
            actionButtons
            logSection
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 560)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [dfuFileType]) { result in
            if case .success(let url) = result {
                firmwareURL = url
                updater.resetPhase()
            }
        }
        .confirmationDialog("Stop the firmware update?",
                            isPresented: $showingCancelConfirmation) {
            Button("Stop Update", role: .destructive) {
                updater.cancelFlash()
            }
            Button("Continue Updating", role: .cancel) {}
        } message: {
            Text("Interrupting an update can leave the station with incomplete firmware. You can recover by pressing RESET and updating again.")
        }
        .sheet(isPresented: $showingAcknowledgments) {
            AcknowledgmentsView()
        }
        .task {
            // Poll for the station while the app is open so the indicator
            // flips as soon as it is plugged in.
            while !Task.isCancelled {
                updater.refreshDfuUtilPath()
                await updater.refreshDeviceStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.sun.bolt.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("Ecowitt WS90 Firmware Updater")
                    .font(.title2.bold())
                Text("Flashes a DfuSe firmware image over USB using dfu-util")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 12) {
                    Button("Check for Updates…") {
                        Task { await appUpdater.check() }
                    }
                    .buttonStyle(.link)
                    .disabled(appUpdater.isBusy || updater.isFlashing)
                    Button("Licenses…") {
                        showingAcknowledgments = true
                    }
                    .buttonStyle(.link)
                }
                appUpdateStatus
            }
        }
    }

    @ViewBuilder
    private var appUpdateStatus: some View {
        switch appUpdater.state {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking for updates…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .upToDate:
            Text("You're on the latest version (\(appUpdater.currentVersion)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let version, _):
            HStack(spacing: 8) {
                Text("Version \(version) is available.")
                    .font(.caption)
                Button("Install & Relaunch") {
                    Task { await appUpdater.downloadAndInstall() }
                }
                .font(.caption)
                .disabled(updater.isFlashing)
            }
        case .downloading(let version):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading version \(version)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Link("Open Releases Page", destination: AppUpdater.releasesPage)
                    .font(.caption)
            }
        }
    }

    private var requirementsSection: some View {
        GroupBox("Requirements") {
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    ok: updater.dfuUtilPath != nil,
                    okText: updater.usingBundledTool
                        ? "Using the app's built-in dfu-util"
                        : "dfu-util found at \(updater.dfuUtilPath ?? "")",
                    failText: "dfu-util not found — install it with:  brew install dfu-util"
                )
                statusRow(
                    ok: updater.deviceDetected,
                    okText: "WS90 detected in DFU mode — serial \(updater.deviceInfo?.serial ?? "")",
                    failText: "No WS90 detected — connect it with a USB data cable and press RESET (LED should flash rapidly)"
                )
                if let info = updater.deviceInfo, !info.flashLayout.isEmpty {
                    Text(info.flashLayout)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var firmwareSection: some View {
        GroupBox("Firmware") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                    if let firmwareURL {
                        Text(firmwareURL.lastPathComponent)
                            .fontWeight(.medium)
                    } else {
                        Text("No firmware file selected — click Choose… to pick a .dfu file")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") {
                        showingFilePicker = true
                    }
                    .disabled(updater.isFlashing)
                }
                HStack(spacing: 8) {
                    Button("Check Ecowitt for Latest") {
                        Task { await downloader.check() }
                    }
                    .disabled(updater.isFlashing || downloader.isBusy)
                    onlineFirmwareStatus
                    Spacer()
                }
                Toggle("Verify after update (read the flash back and compare)", isOn: $verifyAfterUpdate)
                    .disabled(updater.isFlashing)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var onlineFirmwareStatus: some View {
        switch downloader.state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.small)
            Text("Checking…")
                .foregroundStyle(.secondary)
        case .available(let version, _):
            Text("Latest available: V\(version)")
            Button("Download & Use") {
                Task {
                    if let url = await downloader.download() {
                        firmwareURL = url
                        updater.resetPhase()
                    }
                }
            }
            .disabled(updater.isFlashing)
        case .downloading(let version):
            ProgressView()
                .controlSize(.small)
            Text("Downloading V\(version)…")
                .foregroundStyle(.secondary)
        case .downloaded(let version):
            Label("Downloaded V\(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Link("Open Downloads Page", destination: FirmwareDownloader.manualDownloadsPage)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        case .flashing:
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = updater.progressFraction {
                    ProgressView(value: fraction) {
                        Text("\(updater.progressStage)… \(Int(fraction * 100))%")
                    }
                } else {
                    ProgressView {
                        Text("\(updater.progressStage)…")
                    }
                    .progressViewStyle(.linear)
                }
                Text("Do not disconnect the station until the update finishes.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var actionButtons: some View {
        HStack {
            Button {
                if let firmwareURL {
                    updater.flash(firmware: firmwareURL, verify: verifyAfterUpdate)
                }
            } label: {
                Label("Update Firmware", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!readyToFlash)

            if updater.isFlashing {
                Button("Cancel") {
                    showingCancelConfirmation = true
                }
                .controlSize(.large)
            }
        }
    }

    private var logSection: some View {
        GroupBox("Log") {
            ScrollView {
                Text(updater.log.isEmpty ? "dfu-util output will appear here." : updater.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(updater.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(4)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxHeight: .infinity)
    }

    private func statusRow(ok: Bool, okText: String, failText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            Text(ok ? okText : failText)
                .foregroundStyle(ok ? .primary : .secondary)
        }
        .font(.callout)
    }
}

/// Shows the bundled third-party license texts (dfu-util and libusb).
struct AcknowledgmentsView: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        guard let url = Bundle.main.url(forResource: "Acknowledgments", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "The acknowledgments file is missing from the app bundle."
        }
        return contents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Third-Party Licenses")
                .font(.title3.bold())
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}

#Preview {
    ContentView()
}
