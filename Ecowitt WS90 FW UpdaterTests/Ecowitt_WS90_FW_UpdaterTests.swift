//
//  Ecowitt_WS90_FW_UpdaterTests.swift
//  Ecowitt WS90 FW UpdaterTests
//
//  Created by Curtis Netterville on 9/4/26.
//

import Foundation
import Testing
@testable import Ecowitt_WS90_FW_Updater

struct FirmwareLinkParsingTests {
    /// Trimmed from Ecowitt's product pages: a kit page lists firmware for
    /// several devices, plus toolkit archives that are not firmware.
    private let html = """
        <a href="https://oss.ecowitt.net/uploads/20250409/WS90 Tookit for Firmware and Help File.zip">
        <a href="https://oss.ecowitt.net/uploads/20250409/WS80 Upgrade Toolkit Windows PCs.zip">
        <a href="https://oss.ecowitt.net/uploads/20260618/Firmware V2.1.4.zip">
        <a href="https://oss.ecowitt.net/uploads/20260101/WS90_V1.6.2.zip">
        <a href="https://oss.ecowitt.net/uploads/20261113/WS90_V1.10.0.zip">
        <a href="https://oss.ecowitt.net/uploads/20260817/WS80_V1.3.3.zip">
        <a href="https://oss.ecowitt.net/uploads/20261113/WS90 Manual.pdf">
        """

    @Test func picksNewestWS90ByNumericVersion() {
        let found = FirmwareDownloader.latestFirmware(in: html, for: .ws90)
        #expect(found?.version == "1.10.0")
        #expect(found?.url.absoluteString == "https://oss.ecowitt.net/uploads/20261113/WS90_V1.10.0.zip")
    }

    @Test func picksWS80FirmwareNotToolkit() {
        let found = FirmwareDownloader.latestFirmware(in: html, for: .ws80)
        #expect(found?.version == "1.3.3")
        #expect(found?.url.absoluteString == "https://oss.ecowitt.net/uploads/20260817/WS80_V1.3.3.zip")
    }

    @Test func escapesSpacesInLinks() {
        let page = #"<a href="https://oss.ecowitt.net/uploads/20261113/WS80 firmware V1.4.0.zip">"#
        let found = FirmwareDownloader.latestFirmware(in: page, for: .ws80)
        #expect(found?.url.absoluteString == "https://oss.ecowitt.net/uploads/20261113/WS80%20firmware%20V1.4.0.zip")
    }

    @Test func returnsNilWhenModelHasNoFirmware() {
        let page = #"<a href="https://oss.ecowitt.net/uploads/20261113/WS90_V1.6.3.zip">"#
        #expect(FirmwareDownloader.latestFirmware(in: page, for: .ws80) == nil)
    }
}
