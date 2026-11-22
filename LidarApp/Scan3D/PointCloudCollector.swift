import ARKit
import CoreImage
import CoreLocation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import simd

/// Parametry zbierania chmury i zdjęć.
struct CollectorSettings: Equatable {
    var maxDepth: Float = 5.0
    var minDepth: Float = 0.2
    var voxelSize: Float = 0.01
    /// 2 = tylko wysoka pewność, 1 = także średnia.
    var minConfidence: UInt8 = 2
    var maxPoints = 3_000_000
    var capturePhotos = false
    var photoMinDistance: Float = 0.5
    var photoMinAngleDegrees: Float = 15
}

/// Pozycja i kalibracja kamery dla jednego zdjęcia (do fotogrametrii).
struct PhotoRecord {
    let fileName: String
    let timestamp: TimeInterval
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let width: Int
    let height: Int
    let location: CLLocation?
}

/// Zbiera kolorową chmurę punktów z mapy głębi LiDAR (ARFrame.sceneDepth) i opcjonalnie zdjęcia do fotogrametrii.
/// Punkty są odszumiane siatką wokseli – każdy woksel trzyma jeden punkt.
/// Delegat ARSession jest wołany na wątku głównym; ciężkie liczenie idzie na osobnych kolejkach.
final class PointCloudCollector: NSObject, ARSessionDelegate {

    // Tylko wątek główny:
    var isCollecting = true
    var latestLocation: CLLocation?
    private(set) var settings = CollectorSettings()
    private(set) var photoFolder: URL?
    private var lastTimestamp: TimeInterval = 0
    private var busy = false
    private var photoBusy = false
    private var lastPhotoTransform: simd_float4x4?
    private var photoIndex = 0

    /// Wołane z kolejki roboczej (liczba punktów łącznie).
    var onCountChanged: ((Int) -> Void)?
    /// Wołane z kolejki zdjęć (liczba zdjęć łącznie).
    var onPhotoCountChanged: ((Int) -> Void)?
    /// Wołane na wątku głównym przy każdej klatce z pozycją kamery (do georeferencji).
    var onCameraPosition: ((SIMD3<Float>) -> Void)?

    let interval: TimeInterval = 0.33
    let sampleStep = 2

    private let queue = DispatchQueue(label: "pl.lidarskaner.pointcloud", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "pl.lidarskaner.photos", qos: .utility)
    private static let ciContext = CIContext()

    private let lock = NSLock()
    private var positions: [SIMD3<Float>] = []
    private var colors: [SIMD3<UInt8>] = []
    private var voxels = Set<SIMD3<Int32>>()
    private var photos: [PhotoRecord] = []

    // MARK: Sterowanie (wątek główny)

    /// Nowe ustawienia + nowy, pusty skan. `photoFolder` – folder na zdjęcia (tworzony przy pierwszym zdjęciu).
    func configure(_ settings: CollectorSettings, photoFolder: URL?) {
        self.settings = settings
        self.photoFolder = photoFolder
        lastTimestamp = 0
        lastPhotoTransform = nil
        photoIndex = 0
        lock.lock()
        positions.removeAll(keepingCapacity: false)
        colors.removeAll(keepingCapacity: false)
        voxels.removeAll(keepingCapacity: false)
        photos.removeAll()
        lock.unlock()
        onCountChanged?(0)
        onPhotoCountChanged?(0)
    }

    // MARK: Dostęp do danych

    func snapshot() -> (positions: [SIMD3<Float>], colors: [SIMD3<UInt8>]) {
        lock.lock()
        defer { lock.unlock() }
        return (positions, colors)
    }

    func photoRecords() -> [PhotoRecord] {
        lock.lock()
        defer { lock.unlock() }
        return photos
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        let t = frame.camera.transform
        onCameraPosition?(SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z))

        guard isCollecting else { return }
        maybeCapturePhoto(frame)

        guard !busy, frame.timestamp - lastTimestamp >= interval else { return }
        guard let depth = frame.sceneDepth else { return }

        lastTimestamp = frame.timestamp
        busy = true

        let input = FrameInput(
            depthMap: depth.depthMap,
            confidenceMap: depth.confidenceMap,
            image: frame.capturedImage,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            cameraTransform: t,
            settings: settings
        )

        queue.async { [weak self] in
            guard let self else { return }
            let batch = self.unproject(input)
            let total = self.merge(batch, settings: input.settings)
            self.onCountChanged?(total)
            DispatchQueue.main.async { self.busy = false }
        }
    }

    // MARK: Zdjęcia do fotogrametrii

    private func maybeCapturePhoto(_ frame: ARFrame) {
        guard settings.capturePhotos, !photoBusy, let folder = photoFolder else { return }
        let t = frame.camera.transform
        if let last = lastPhotoTransform {
            let p0 = SIMD3<Float>(last.columns.3.x, last.columns.3.y, last.columns.3.z)
            let p1 = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let moved = simd_distance(p0, p1)
            let f0 = -SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z)
            let f1 = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            let cosAngle = max(-1, min(1, simd_dot(simd_normalize(f0), simd_normalize(f1))))
            let angle = acos(cosAngle) * 180 / .pi
            if moved < settings.photoMinDistance && angle < settings.photoMinAngleDegrees { return }
        }

        lastPhotoTransform = t
        photoIndex += 1
        photoBusy = true

        let fileName = String(format: "IMG_%04d.jpg", photoIndex)
        let buffer = frame.capturedImage
        let record = PhotoRecord(fileName: fileName,
                                 timestamp: frame.timestamp,
                                 transform: t,
                                 intrinsics: frame.camera.intrinsics,
                                 width: CVPixelBufferGetWidth(buffer),
                                 height: CVPixelBufferGetHeight(buffer),
                                 location: latestLocation)

        photoQueue.async { [weak self] in
            guard let self else { return }
            let saved = Self.writeJPEG(buffer, location: record.location,
                                       to: folder.appendingPathComponent(fileName))
            var count = 0
            self.lock.lock()
            if saved { self.photos.append(record) }
            count = self.photos.count
            self.lock.unlock()
            self.onPhotoCountChanged?(count)
            DispatchQueue.main.async { self.photoBusy = false }
        }
    }

    private static func writeJPEG(_ buffer: CVPixelBuffer, location: CLLocation?, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }

        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let location {
            let lat = location.coordinate.latitude
            let lon = location.coordinate.longitude
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(lat),
                kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lon),
                kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
                kCGImagePropertyGPSHPositioningError: location.horizontalAccuracy
            ]
            if location.verticalAccuracy > 0 {
                gps[kCGImagePropertyGPSAltitude] = abs(location.altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = location.altitude < 0 ? 1 : 0
            }
            props[kCGImagePropertyGPSDictionary] = gps
        }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Przeliczanie głębi na punkty

    private struct FrameInput {
        let depthMap: CVPixelBuffer
        let confidenceMap: CVPixelBuffer?
        let image: CVPixelBuffer
        let intrinsics: simd_float3x3
        let imageResolution: CGSize
        let cameraTransform: simd_float4x4
        let settings: CollectorSettings
    }

    private struct Batch {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
    }

    private func unproject(_ input: FrameInput) -> Batch {
        var batch = Batch()
        let minDepth = input.settings.minDepth
        let maxDepth = input.settings.maxDepth
        let minConfidence = input.settings.minConfidence

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
                    if c < minConfidence { continue }
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

    private func merge(_ batch: Batch, settings: CollectorSettings) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let inv: Float = 1 / settings.voxelSize
        for i in batch.positions.indices {
            if positions.count >= settings.maxPoints { break }
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
