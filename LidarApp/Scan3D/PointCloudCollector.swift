import ARKit
import CoreVideo
import simd

/// Zbiera kolorową chmurę punktów z mapy głębi LiDAR (ARFrame.sceneDepth).
/// Punkty są odszumiane siatką wokseli (domyślnie 1 cm) – każdy woksel trzyma jeden punkt.
/// Delegat ARSession jest wołany na wątku głównym; ciężkie liczenie idzie na osobnej kolejce.
final class PointCloudCollector: NSObject, ARSessionDelegate {

    /// Ustawiane z wątku głównego.
    var isCollecting = true
    /// Wołane z kolejki roboczej po każdej porcji punktów (liczba punktów łącznie).
    var onCountChanged: ((Int) -> Void)?

    let maxPoints = 3_000_000
    let voxelSize: Float = 0.01
    let minDepth: Float = 0.2
    let maxDepth: Float = 5.0
    let sampleStep = 2
    let interval: TimeInterval = 0.33

    private let queue = DispatchQueue(label: "pl.lidarskaner.pointcloud", qos: .userInitiated)
    private let lock = NSLock()
    private var positions: [SIMD3<Float>] = []
    private var colors: [SIMD3<UInt8>] = []
    private var voxels = Set<SIMD3<Int32>>()

    // Tylko wątek główny:
    private var lastTimestamp: TimeInterval = 0
    private var busy = false

    // MARK: Dostęp do danych

    func snapshot() -> (positions: [SIMD3<Float>], colors: [SIMD3<UInt8>]) {
        lock.lock()
        defer { lock.unlock() }
        return (positions, colors)
    }

    func reset() {
        lock.lock()
        positions.removeAll(keepingCapacity: false)
        colors.removeAll(keepingCapacity: false)
        voxels.removeAll(keepingCapacity: false)
        lock.unlock()
        onCountChanged?(0)
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCollecting, !busy else { return }
        guard frame.timestamp - lastTimestamp >= interval else { return }
        guard case .normal = frame.camera.trackingState else { return }
        guard let depth = frame.sceneDepth else { return }

        lastTimestamp = frame.timestamp
        busy = true

        let input = FrameInput(
            depthMap: depth.depthMap,
            confidenceMap: depth.confidenceMap,
            image: frame.capturedImage,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            cameraTransform: frame.camera.transform
        )

        queue.async { [weak self] in
            guard let self else { return }
            let batch = self.unproject(input)
            let total = self.merge(batch)
            self.onCountChanged?(total)
            DispatchQueue.main.async { self.busy = false }
        }
    }

    // MARK: Przeliczanie

    private struct FrameInput {
        let depthMap: CVPixelBuffer
        let confidenceMap: CVPixelBuffer?
        let image: CVPixelBuffer
        let intrinsics: simd_float3x3
        let imageResolution: CGSize
        let cameraTransform: simd_float4x4
    }

    private struct Batch {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
    }

    private func unproject(_ input: FrameInput) -> Batch {
        var batch = Batch()

        let depthMap = input.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let image = input.image
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        if let conf = input.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(conf)
            confRow = CVPixelBufferGetBytesPerRow(conf)
        }
        defer {
            if let conf = input.confidenceMap {
                CVPixelBufferUnlockBaseAddress(conf, .readOnly)
            }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else {
            return batch
        }

        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)
        let depthRow = CVPixelBufferGetBytesPerRow(depthMap)

        let imgW = CVPixelBufferGetWidthOfPlane(image, 0)
        let imgH = CVPixelBufferGetHeightOfPlane(image, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cbcrRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)

        // Intrinsics dotyczą rozdzielczości obrazu kamery – skalujemy do rozdzielczości mapy głębi.
        let scaleX: Float = Float(depthW) / Float(input.imageResolution.width)
        let scaleY: Float = Float(depthH) / Float(input.imageResolution.height)
        let fx: Float = input.intrinsics[0][0] * scaleX
        let fy: Float = input.intrinsics[1][1] * scaleY
        let cx: Float = input.intrinsics[2][0] * scaleX
        let cy: Float = input.intrinsics[2][1] * scaleY

        let toImageX: Float = Float(imgW) / Float(depthW)
        let toImageY: Float = Float(imgH) / Float(depthH)
        let transform = input.cameraTransform

        let expected = (depthW / sampleStep) * (depthH / sampleStep)
        batch.positions.reserveCapacity(expected)
        batch.colors.reserveCapacity(expected)

        for v in stride(from: 0, to: depthH, by: sampleStep) {
            for u in stride(from: 0, to: depthW, by: sampleStep) {
                let d: Float = depthBase.load(fromByteOffset: v * depthRow + u * 4, as: Float32.self)
                if d < minDepth || d > maxDepth || !d.isFinite { continue }

                if let confBase {
                    let c: UInt8 = confBase.load(fromByteOffset: v * confRow + u, as: UInt8.self)
                    if c < UInt8(ARConfidenceLevel.high.rawValue) { continue }
                }

                // Kamera ARKit: X w prawo, Y w górę, patrzy w −Z. Obraz: Y w dół.
                let xc: Float = (Float(u) - cx) * d / fx
                let yc: Float = (Float(v) - cy) * d / fy
                let local = SIMD4<Float>(xc, -yc, -d, 1)
                let world = transform * local
                batch.positions.append(SIMD3<Float>(world.x, world.y, world.z))

                let ix = min(imgW - 1, Int(Float(u) * toImageX))
                let iy = min(imgH - 1, Int(Float(v) * toImageY))
                batch.colors.append(Self.rgb(yBase: yBase, yRow: yRow,
                                             cbcrBase: cbcrBase, cbcrRow: cbcrRow,
                                             x: ix, y: iy))
            }
        }
        return batch
    }

    /// Konwersja piksela YCbCr (420f, pełny zakres) na RGB.
    private static func rgb(yBase: UnsafeMutableRawPointer, yRow: Int,
                            cbcrBase: UnsafeMutableRawPointer, cbcrRow: Int,
                            x: Int, y: Int) -> SIMD3<UInt8> {
        let yy: Float = Float(yBase.load(fromByteOffset: y * yRow + x, as: UInt8.self))
        let chromaOffset = (y / 2) * cbcrRow + (x / 2) * 2
        let cb: Float = Float(cbcrBase.load(fromByteOffset: chromaOffset, as: UInt8.self)) - 128
        let cr: Float = Float(cbcrBase.load(fromByteOffset: chromaOffset + 1, as: UInt8.self)) - 128

        let r: Float = yy + 1.402 * cr
        let g: Float = yy - 0.344136 * cb - 0.714136 * cr
        let b: Float = yy + 1.772 * cb
        return SIMD3<UInt8>(clamp8(r), clamp8(g), clamp8(b))
    }

    private static func clamp8(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, v)))
    }

    private func merge(_ batch: Batch) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let inv: Float = 1 / voxelSize
        for i in batch.positions.indices {
            if positions.count >= maxPoints { break }
            let p = batch.positions[i]
            let key = SIMD3<Int32>(Int32((p.x * inv).rounded(.down)),
                                   Int32((p.y * inv).rounded(.down)),
                                   Int32((p.z * inv).rounded(.down)))
            if voxels.insert(key).inserted {
                positions.append(p)
                colors.append(batch.colors[i])
            }
        }
        return positions.count
    }
}
