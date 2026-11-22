import Foundation
import simd

/// Zapis chmury do LAS 1.2, format punktu 2 (XYZ + RGB), skala 1 mm.
/// Z georeferencją dopisuje VLR GeoKeyDirectory z kodem EPSG PL-2000 (2176–2179),
/// dzięki czemu CloudCompare, ReCap, QGIS i Civil 3D znają układ.
enum LASWriter {

    static let headerSize = 227
    static let pointRecordLength = 26
    static let scale = 0.001

    static func write(positions: [SIMD3<Float>], colors: [SIMD3<UInt8>],
                      mapping: Scan3DExporter.Mapping, epsg: Int?, to url: URL) throws {
        let count = min(positions.count, colors.count)
        var mapped: [SIMD3<Double>] = []
        mapped.reserveCapacity(count)
        var minP = SIMD3<Double>(repeating: .infinity)
        var maxP = SIMD3<Double>(repeating: -.infinity)
        for i in 0..<count {
            let p = mapping(positions[i])
            mapped.append(p)
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        if count == 0 {
            minP = .zero
            maxP = .zero
        }
        // Przesunięcie = minimum zaokrąglone do metra → małe liczby całkowite w rekordach.
        let offset = SIMD3<Double>(minP.x.rounded(.down), minP.y.rounded(.down), minP.z.rounded(.down))

        let vlr = epsg.map { geoKeyVLR(epsg: $0) } ?? Data()
        let vlrCount: UInt32 = epsg == nil ? 0 : 1
        let pointOffset = UInt32(headerSize + vlr.count)

        var data = Data()
        data.reserveCapacity(Int(pointOffset) + count * pointRecordLength)

        // --- Nagłówek (227 bajtów) ---
        data.append(contentsOf: Array("LASF".utf8))
        data.appendLE(UInt16(0))                 // File Source ID
        data.appendLE(UInt16(0))                 // Global Encoding
        data.append(Data(count: 16))             // GUID
        data.append(1)                           // Version Major
        data.append(2)                           // Version Minor
        data.appendFixedString("LiDAR Skaner iPhone", length: 32)   // System Identifier
        data.appendFixedString("LiDAR Skaner", length: 32)          // Generating Software
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        data.appendLE(UInt16(calendar.ordinality(of: .day, in: .year, for: now) ?? 1))
        data.appendLE(UInt16(calendar.component(.year, from: now)))
        data.appendLE(UInt16(headerSize))
        data.appendLE(pointOffset)
        data.appendLE(vlrCount)
        data.append(2)                           // Point Data Format 2
        data.appendLE(UInt16(pointRecordLength))
        data.appendLE(UInt32(count))
        data.appendLE(UInt32(count))             // punkty z 1. odbiciem
        for _ in 0..<4 { data.appendLE(UInt32(0)) }
        data.appendLE(scale); data.appendLE(scale); data.appendLE(scale)
        data.appendLE(offset.x); data.appendLE(offset.y); data.appendLE(offset.z)
        data.appendLE(maxP.x); data.appendLE(minP.x)
        data.appendLE(maxP.y); data.appendLE(minP.y)
        data.appendLE(maxP.z); data.appendLE(minP.z)
        precondition(data.count == headerSize, "Błędny rozmiar nagłówka LAS")

        data.append(vlr)

        // --- Punkty (26 bajtów każdy) ---
        var body = [UInt8](repeating: 0, count: count * pointRecordLength)
        body.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                let o = i * pointRecordLength
                let p = mapped[i]
                let x = Int32(((p.x - offset.x) / scale).rounded())
                let y = Int32(((p.y - offset.y) / scale).rounded())
                let z = Int32(((p.z - offset.z) / scale).rounded())
                raw.storeBytes(of: x.littleEndian, toByteOffset: o, as: Int32.self)
                raw.storeBytes(of: y.littleEndian, toByteOffset: o + 4, as: Int32.self)
                raw.storeBytes(of: z.littleEndian, toByteOffset: o + 8, as: Int32.self)
                // intensity (o+12..13) = 0
                raw[o + 14] = 0b0000_1001        // return 1 z 1
                raw[o + 15] = 1                  // klasa 1 = niesklasyfikowany
                // scan angle, user data, point source ID = 0
                let c = colors[i]
                raw.storeBytes(of: (UInt16(c.x) * 257).littleEndian, toByteOffset: o + 20, as: UInt16.self)
                raw.storeBytes(of: (UInt16(c.y) * 257).littleEndian, toByteOffset: o + 22, as: UInt16.self)
                raw.storeBytes(of: (UInt16(c.z) * 257).littleEndian, toByteOffset: o + 24, as: UInt16.self)
            }
        }
        data.append(contentsOf: body)
        try data.write(to: url, options: .atomic)
    }

    /// VLR „LASF_Projection” / 34735 (GeoKeyDirectoryTag): układ rzutowany = EPSG.
    static func geoKeyVLR(epsg: Int) -> Data {
        // Nagłówek katalogu (wersja 1.1.0, 3 klucze) + klucze po 4 × UInt16.
        let keys: [UInt16] = [
            1, 1, 0, 3,
            1024, 0, 1, 1,                   // GTModelTypeGeoKey = ModelTypeProjected
            1025, 0, 1, 1,                   // GTRasterTypeGeoKey = PixelIsArea
            3072, 0, 1, UInt16(epsg)         // ProjectedCSTypeGeoKey = EPSG
        ]
        var payload = Data()
        for k in keys { payload.appendLE(k) }

        var vlr = Data()
        vlr.appendLE(UInt16(0))                                  // Reserved
        vlr.appendFixedString("LASF_Projection", length: 16)     // User ID
        vlr.appendLE(UInt16(34735))                              // Record ID
        vlr.appendLE(UInt16(payload.count))                      // długość po nagłówku
        vlr.appendFixedString("EPSG:\(epsg) PL-2000", length: 32) // opis
        vlr.append(payload)
        return vlr
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Double) {
        appendLE(value.bitPattern)
    }

    mutating func appendFixedString(_ s: String, length: Int) {
        var bytes = Array(s.utf8.prefix(length))
        bytes += [UInt8](repeating: 0, count: length - bytes.count)
        append(contentsOf: bytes)
    }
}
