import ARKit
import simd

/// Eksport skanu 3D.
/// - Bez georeferencji: układ lokalny, metry, Z w górę (X = X ARKit, Y = −Z ARKit, Z = Y ARKit) – jak rzut DXF.
/// - Z georeferencją: PL-2000 w konwencji CAD (X = wschód / Y 2000, Y = północ / X 2000, Z = H), liczby double.
enum Scan3DExporter {

    /// Przekształcenie punktu ARKit na współrzędne pliku.
    typealias Mapping = (SIMD3<Float>) -> SIMD3<Double>

    static let localZUp: Mapping = { p in
        SIMD3<Double>(Double(p.x), Double(-p.z), Double(p.y))
    }

    static func mapping(for geo: GeoReference?) -> Mapping {
        guard let geo else { return localZUp }
        return { geo.cad($0) }
    }

    // MARK: PLY (chmura punktów, binarny, z kolorem)

    static func writePLY(positions: [SIMD3<Float>], colors: [SIMD3<UInt8>],
                         mapping: Mapping, useDouble: Bool, to url: URL) throws {
        let count = min(positions.count, colors.count)
        let type = useDouble ? "double" : "float"
        let header = """
        ply
        format binary_little_endian 1.0
        comment LiDAR Skaner - metry, Z w gore
        element vertex \(count)
        property \(type) x
        property \(type) y
        property \(type) z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        let coordSize = useDouble ? 8 : 4
        let recordSize = coordSize * 3 + 3
        var body = [UInt8](repeating: 0, count: count * recordSize)
        body.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                let o = i * recordSize
                let p = mapping(positions[i])
                if useDouble {
                    raw.storeBytes(of: p.x.bitPattern.littleEndian, toByteOffset: o, as: UInt64.self)
                    raw.storeBytes(of: p.y.bitPattern.littleEndian, toByteOffset: o + 8, as: UInt64.self)
                    raw.storeBytes(of: p.z.bitPattern.littleEndian, toByteOffset: o + 16, as: UInt64.self)
                } else {
                    raw.storeBytes(of: Float(p.x).bitPattern.littleEndian, toByteOffset: o, as: UInt32.self)
                    raw.storeBytes(of: Float(p.y).bitPattern.littleEndian, toByteOffset: o + 4, as: UInt32.self)
                    raw.storeBytes(of: Float(p.z).bitPattern.littleEndian, toByteOffset: o + 8, as: UInt32.self)
                }
                let c = colors[i]
                let co = o + coordSize * 3
                raw[co] = c.x
                raw[co + 1] = c.y
                raw[co + 2] = c.z
            }
        }
        var data = Data(header.utf8)
        data.append(contentsOf: body)
        try data.write(to: url, options: .atomic)
    }

    // MARK: OBJ (siatka z ARMeshAnchor)

    static func writeOBJ(meshAnchors: [ARMeshAnchor], mapping: Mapping, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        handle.write(Data("# LiDAR Skaner - siatka, metry, Z w gore\n".utf8))

        var vertexOffset = 1
        for (n, anchor) in meshAnchors.enumerated() {
            let geometry = anchor.geometry
            let vertexCount = geometry.vertices.count
            let faceCount = geometry.faces.count
            var chunk = "o fragment_\(n)\n"
            chunk.reserveCapacity(vertexCount * 40 + faceCount * 24)

            for i in 0..<vertexCount {
                let local = geometry.vertex(at: i)
                let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let p = mapping(SIMD3<Float>(world4.x, world4.y, world4.z))
                chunk += String(format: "v %.4f %.4f %.4f\n", p.x, p.y, p.z)
            }
            for f in 0..<faceCount {
                let idx = geometry.faceIndices(at: f)
                guard idx.count == 3 else { continue }
                let a = idx[0] + vertexOffset
                let b = idx[1] + vertexOffset
                let c = idx[2] + vertexOffset
                chunk += "f \(a) \(b) \(c)\n"
            }
            vertexOffset += vertexCount
            handle.write(Data(chunk.utf8))
        }
    }

    // MARK: Zdjęcia – pozycje kamer (Metashape / RealityCapture: import referencji)

    static func writePhotoPoses(_ records: [PhotoRecord], mapping: Mapping, georeferenced: Bool, to url: URL) throws {
        var lines: [String] = []
        let coordNames = georeferenced ? "E_PL2000,N_PL2000,H" : "x_lok,y_lok,z_lok"
        lines.append("plik,szer_geogr,dl_geogr,wys_gps,dokl_gps_m,\(coordNames),omega_deg,phi_deg,kappa_deg,fx_px,fy_px,cx_px,cy_px,szer_px,wys_px")
        for r in records {
            let pos = SIMD3<Float>(r.transform.columns.3.x, r.transform.columns.3.y, r.transform.columns.3.z)
            let p = mapping(pos)
            let angles = eulerDegrees(r.transform)
            var gps = ",,,"
            if let loc = r.location {
                gps = String(format: "%.8f,%.8f,%.2f,%.1f",
                             loc.coordinate.latitude, loc.coordinate.longitude,
                             loc.altitude, loc.horizontalAccuracy)
            }
            let line = String(format: "%@,%@,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f,%.2f,%ld,%ld",
                              r.fileName, gps, p.x, p.y, p.z,
                              angles.x, angles.y, angles.z,
                              Double(r.intrinsics[0][0]), Double(r.intrinsics[1][1]),
                              Double(r.intrinsics[2][0]), Double(r.intrinsics[2][1]),
                              r.width, r.height)
            lines.append(line)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Kąty orientacji kamery (przybliżone, w układzie ARKit) – pomocniczo; programy fotogrametryczne liczą je same.
    private static func eulerDegrees(_ m: simd_float4x4) -> SIMD3<Double> {
        let r20 = Double(m.columns.0.z)
        let r21 = Double(m.columns.1.z)
        let r22 = Double(m.columns.2.z)
        let r10 = Double(m.columns.0.y)
        let r00 = Double(m.columns.0.x)
        let omega = atan2(r21, r22)
        let phi = asin(max(-1, min(1, -r20)))
        let kappa = atan2(r10, r00)
        return SIMD3<Double>(omega, phi, kappa) * (180 / .pi)
    }
}

extension ARMeshGeometry {
    func vertex(at index: Int) -> SIMD3<Float> {
        let byteOffset = vertices.offset + vertices.stride * index
        let base = vertices.buffer.contents()
        let x = base.load(fromByteOffset: byteOffset, as: Float.self)
        let y = base.load(fromByteOffset: byteOffset + 4, as: Float.self)
        let z = base.load(fromByteOffset: byteOffset + 8, as: Float.self)
        return SIMD3<Float>(x, y, z)
    }

    func faceIndices(at index: Int) -> [Int] {
        let perFace = faces.indexCountPerPrimitive
        let bytes = faces.bytesPerIndex
        let base = faces.buffer.contents()
        var result: [Int] = []
        result.reserveCapacity(perFace)
        for k in 0..<perFace {
            let offset = (index * perFace + k) * bytes
            if bytes == 4 {
                result.append(Int(base.load(fromByteOffset: offset, as: UInt32.self)))
            } else {
                result.append(Int(base.load(fromByteOffset: offset, as: UInt16.self)))
            }
        }
        return result
    }
}
