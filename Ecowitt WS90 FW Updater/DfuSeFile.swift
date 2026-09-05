//
//  DfuSeFile.swift
//  Ecowitt WS90 FW Updater
//

import Foundation

/// Minimal parser for STMicroelectronics DfuSe (.dfu) files — just enough to
/// know which flash ranges the file programs so they can be read back and
/// compared after an update.
struct DfuSeFile {
    struct Element {
        let address: UInt32
        let data: Data
    }

    let elements: [Element]

    enum ParseError: LocalizedError {
        case notDfuSe
        case truncated

        var errorDescription: String? {
            switch self {
            case .notDfuSe: "the file is not a DfuSe (.dfu) firmware image"
            case .truncated: "the firmware file is truncated or corrupt"
            }
        }
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        // Prefix: "DfuSe" <version:1> <imageSize:4> <targetCount:1>
        guard data.count > 11 + 16, data.prefix(5) == Data("DfuSe".utf8) else {
            throw ParseError.notDfuSe
        }
        let targetCount = Int(data[10])
        var offset = 11
        var elements: [Element] = []
        for _ in 0..<targetCount {
            // Target prefix: "Target" <alt:1> <isNamed:4> <name:255>
            // <targetSize:4> <elementCount:4> = 274 bytes total
            guard offset + 274 <= data.count,
                  data[offset..<offset + 6] == Data("Target".utf8) else {
                throw ParseError.truncated
            }
            let elementCount = Int(Self.readUInt32(data, at: offset + 270))
            offset += 274
            for _ in 0..<elementCount {
                guard offset + 8 <= data.count else { throw ParseError.truncated }
                let address = Self.readUInt32(data, at: offset)
                let size = Int(Self.readUInt32(data, at: offset + 4))
                offset += 8
                guard size > 0, offset + size <= data.count else { throw ParseError.truncated }
                elements.append(Element(address: address,
                                        data: data.subdata(in: offset..<offset + size)))
                offset += size
            }
        }
        guard !elements.isEmpty else { throw ParseError.truncated }
        self.elements = elements
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
