import SwiftUI
import ARKit
import Combine
import CoreLocation
import RealityKit

@MainActor
final class Scan3DModel: ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let collector = PointCloudCollector()
    let location = LocationManager()

    @Published var settings = ScanSettings.interior
    @Published var pointCount = 0
    @Published var photoCount = 0
    @Published var meshCount = 0
    @Published var isCollecting = true
    @Published var isExporting = false
    @Published var showMesh = true
    @Published var shareItem: ShareItem?
    @Published var errorMessage: String?
    @Published var savedFolderName: String?
    @Published var geoSampleCount = 0
    @Published var gpsAccuracy: Double?

    private var sessionFolder: URL
    private var sessionName: String
    private var geoSamples: [GeoSample] = []
    private var lastCameraPosition: SIMD3<Float>?
    private var cancellables = Set<AnyCancellable>()
    private var isRunning = false

    /// Próbki GPS przyjmowane do georeferencji.
    private let maxGeoAccuracy: Double = 15

    init() {
        let session = Self.newSessionFolder()
        sessionName = session.0
        sessionFolder = session.1
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.delegate = collector

        collector.onCountChanged = { [weak self] count in
            Task { @MainActor in
                guard let self else { return }
                self.pointCount = count
                self.meshCount = self.currentMeshAnchors().count
            }
        }
        collector.onPhotoCountChanged = { [weak self] count in
            Task { @MainActor in self?.photoCount = count }
        }
        collector.onCameraPosition = { [weak self] position in
            self?.lastCameraPosition = position
        }

        location.$current
            .compactMap { $0 }
            .sink { [weak self] loc in
                self?.handleLocation(loc)
            }
            .store(in: &cancellables)
    }

    private static func newSessionFolder() -> (String, URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "Skan3D_\(formatter.string(from: Date()))"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return (name, docs.appendingPathComponent(name, isDirectory: true))
    }

    private var needsLocation: Bool {
        settings.georeference || settings.capturePhotos
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = [.horizontal, .vertical]
        // Georeferencja: osie zgodne z kierunkami świata (X = wschód, −Z = północ wg kompasu).
        config.worldAlignment = settings.georeference ? .gravityAndHeading : .gravity
        return config
    }

    // MARK: Sterowanie

    func start() {
        guard !isRunning else { return }
        isRunning = true
        beginNewScan(resetSession: false)
    }

    func pause() {
        isRunning = false
        arView.session.pause()
        location.stop()
    }

    func apply(_ newSettings: ScanSettings) {
        settings = newSettings
        beginNewScan(resetSession: true)
    }

    func reset() {
        beginNewScan(resetSession: true)
    }

    private func beginNewScan(resetSession: Bool) {
        let session = Self.newSessionFolder()
        sessionName = session.0
        sessionFolder = session.1
        geoSamples.removeAll()
        geoSampleCount = 0
        savedFolderName = nil
        pointCount = 0
        photoCount = 0
        meshCount = 0
        isCollecting = true
        collector.isCollecting = true
        collector.configure(settings.collector,
                            photoFolder: sessionFolder.appendingPathComponent("zdjecia", isDirectory: true))

        let options: ARSession.RunOptions = resetSession ? [.resetTracking, .removeExistingAnchors] : []
        arView.session.run(makeConfiguration(), options: options)

        if needsLocation {
            location.start()
        } else {
            location.stop()
        }
    }

    func toggleCollecting() {
        isCollecting.toggle()
        collector.isCollecting = isCollecting
    }

    func toggleMesh() {
        showMesh.toggle()
        if showMesh {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    // MARK: GPS

    private func handleLocation(_ loc: CLLocation) {
        gpsAccuracy = loc.horizontalAccuracy > 0 ? loc.horizontalAccuracy : nil
        collector.latestLocation = loc
        guard settings.georeference, isCollecting,
              loc.horizontalAccuracy > 0, loc.horizontalAccuracy <= maxGeoAccuracy,
              let camera = lastCameraPosition else { return }
        let sample = GeoSample(latitude: loc.coordinate.latitude,
                               longitude: loc.coordinate.longitude,
                               altitude: loc.verticalAccuracy > 0 ? loc.altitude : nil,
                               horizontalAccuracy: loc.horizontalAccuracy,
                               verticalAccuracy: loc.verticalAccuracy > 0 ? loc.verticalAccuracy : nil,
                               local: camera)
        geoSamples.append(sample)
        geoSampleCount = geoSamples.count
    }

    var geoStatus: String? {
        guard settings.georeference else { return nil }
        if geoSampleCount < GeoReference.minSamples {
            return "Georeferencja: \(geoSampleCount)/\(GeoReference.minSamples) próbek GPS"
        }
        return "Georeferencja: \(geoSampleCount) próbek GPS"
    }

    // MARK: Eksport

    private func currentMeshAnchors() -> [ARMeshAnchor] {
        arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    }

    func export() {
        guard !isExporting else { return }
        let anchors = currentMeshAnchors()
        let cloud = collector.snapshot()
        let photos = collector.photoRecords()
        guard !anchors.isEmpty || !cloud.positions.isEmpty || !photos.isEmpty else {
            errorMessage = "Brak danych – najpierw zeskanuj otoczenie."
            return
        }

        let geo: GeoReference? = settings.georeference ? GeoReference.solve(geoSamples) : nil
        if settings.georeference {
            if geo == nil {
                errorMessage = "Za mało próbek GPS do georeferencji (\(geoSamples.count)/\(GeoReference.minSamples)). Eksportuję w układzie lokalnym – skanuj dłużej na otwartym terenie."
            }
        }

        isExporting = true
        let folder = sessionFolder
        let name = sessionName

        DispatchQueue.global(qos: .userInitiated).async {
            var urls: [URL] = []
            var failure: String?
            let mapping = Scan3DExporter.mapping(for: geo)
            let suffix = geo != nil ? "_PL2000" : ""
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !cloud.positions.isEmpty {
                    let ply = folder.appendingPathComponent("chmura\(suffix).ply")
                    try Scan3DExporter.writePLY(positions: cloud.positions, colors: cloud.colors,
                                                mapping: mapping, useDouble: geo != nil, to: ply)
                    urls.append(ply)
                }
                if !anchors.isEmpty {
                    let obj = folder.appendingPathComponent("siatka\(suffix).obj")
                    try Scan3DExporter.writeOBJ(meshAnchors: anchors, mapping: mapping, to: obj)
                    urls.append(obj)
                }
                if !photos.isEmpty {
                    let csv = folder.appendingPathComponent("zdjecia_pozycje.csv")
                    try Scan3DExporter.writePhotoPoses(photos, mapping: mapping,
                                                       georeferenced: geo != nil, to: csv)
                    urls.append(csv)
                }
                if let geo {
                    let info = folder.appendingPathComponent("georeferencja.txt")
                    try geo.report.write(to: info, atomically: true, encoding: .utf8)
                    urls.append(info)
                }
            } catch {
                failure = "Eksport nie powiódł się: \(error.localizedDescription)"
            }
            let result = urls
            let message = failure
            Task { @MainActor in
                self.isExporting = false
                if let message {
                    self.errorMessage = message
                } else {
                    self.savedFolderName = name
                    self.shareItem = ShareItem(urls: result)
                }
            }
        }
    }
}

struct Scan3DView: View {
    @StateObject private var model = Scan3DModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            ARViewContainer(arView: model.arView)
                .ignoresSafeArea()

            VStack {
                stats
                Spacer()
                controls
            }
            .padding()
        }
        .navigationTitle("Skan 3D")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.pause() }
        .sheet(isPresented: $showSettings) {
            ScanSettingsView(settings: model.settings) { newSettings in
                model.apply(newSettings)
            }
        }
        .sheet(item: $model.shareItem) { item in
            ActivityView(items: item.urls)
        }
        .alert("Uwaga", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var stats: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Text(model.settings.preset.name).bold()
                Label(Self.formatCount(model.pointCount), systemImage: "circle.dotted")
                Label("\(model.meshCount)", systemImage: "square.grid.3x3")
                if model.settings.capturePhotos {
                    Label("\(model.photoCount)", systemImage: "camera")
                }
                if !model.isCollecting {
                    Text("PAUZA").bold().foregroundStyle(.orange)
                }
            }
            if let geo = model.geoStatus {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                    Text(geo)
                    if let acc = model.gpsAccuracy {
                        Text(String(format: "(±%.0f m)", acc))
                    }
                }
                .foregroundStyle(model.geoSampleCount >= GeoReference.minSamples ? Color.green : Color.orange)
            }
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var hint: String {
        if model.settings.preset == .exterior || model.settings.maxDepth > 5 {
            return "Idź wolno wzdłuż obiektu w odległości 2–5 m, telefon trzymaj stabilnie. Dłuższe obiekty skanuj odcinkami (eksport → kosz → dalej)."
        }
        return "Poruszaj się powoli, 0,5–4 m od powierzchni. Punkty o niskiej pewności są pomijane."
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Text(hint)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let saved = model.savedFolderName {
                Text("Zapisano: Pliki → LiDAR Skaner → \(saved)")
                    .font(.caption)
            }

            HStack {
                Button {
                    model.toggleCollecting()
                } label: {
                    Image(systemName: model.isCollecting ? "pause.fill" : "record.circle")
                }
                .buttonStyle(.bordered)

                Button {
                    model.toggleMesh()
                } label: {
                    Image(systemName: model.showMesh ? "eye" : "eye.slash")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    model.reset()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)

                Button {
                    model.export()
                } label: {
                    if model.isExporting {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Eksport", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExporting)
            }
            .controlSize(.large)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2f mln", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0f tys.", Double(n) / 1_000) }
        return "\(n)"
    }
}
