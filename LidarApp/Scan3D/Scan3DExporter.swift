import ARKit
import simd

/// Eksport skanu 3D. Układ współrzędnych plików: metry, Z w górę
/// (X = X ARKit, Y = −Z ARKit, Z = Y ARKit) – zgodnie z rzutem DXF.
enum Scan3DExporter {

    @inline(__always)
    static func zUp(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(p.x, -p.z, p.y)
    }

    // MARK: PLY (chmura punktów, binarny, z kolorem)

    static func writePLY(positions: [SIMD3<Float>], colors: [SIMD3<UInt8>], to url: URL) throws {
        let count = min(positions.count, colors.count)
        let header = """
        ply
        format binary_little_endian 1.0
        comment LiDAR Skaner - metry, Z w gore
        element vertex \(count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        let recordSize = 15
        var body = [UInt8](repeating: 0, count: count * recordSize)
        body.withUnsafeMutableBytes { raw in
            for i in 0..<count {
                let o = i * recordSize
                let p = zUp(positions[i])
                let c = colors[i]
                raw.storeBytes(of: p.x.bitPattern.littleEndian, toByteOffset: o, as: UInt32.self)
                raw.storeBytes(of: p.y.bitPattern.littleEndian, toByteOffset: o + 4, as: UInt32.self)
                raw.storeBytes(of: p.z.bitPattern.littleEndian, toByteOffset: o + 8, as: UInt32.self)
                raw[o + 12] = c.x
                raw[o + 13] = c.y
                raw[o + 14] = c.z
            }
        }
        var data = Data(header.utf8)
        data.append(contentsOf: body)
        try data.write(to: url, options: .atomic)
    }

    // MARK: OBJ (siatka z ARMeshAnchor)

    static func writeOBJ(meshAnchors: [ARMeshAnchor], to url: URL) throws {
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
            chunk.reserveCapacity(vertexCount * 36 + faceCount * 24)

            for i in 0..<vertexCount {
                let local = geometry.vertex(at: i)
                let world4 = anchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                let p = zUp(SIMD3<Float>(world4.x, world4.y, world4.z))
                chunk += String(format: "v %.4f %.4f %.4f\n", Double(p.x), Double(p.y), Double(p.z))
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
