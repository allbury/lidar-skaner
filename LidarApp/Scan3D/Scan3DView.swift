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
    @Published var guidance = PhotoGuidance()
    @Published var controlPoints: [ControlPoint] = []
    @Published var editingControlPointID: UUID?

    private var sessionFolder: URL
    private var sessionName: String
    private var geoSamples: [GeoSample] = []
    private var lastCameraPosition: SIMD3<Float>?
    private var cancellables = Set<AnyCancellable>()
    private var isRunning = false
    private var controlAnchors: [UUID: AnchorEntity] = [:]

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
        collector.onPhotoGuidance = { [weak self] g in
            self?.guidance = g
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
        // Format wideo pozwalający robić zdjęcia w pełnej rozdzielczości aparatu.
        if settings.capturePhotos && settings.highResPhotos,
           let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
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
        guidance = PhotoGuidance()
        removeAllControlPoints()
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

    // MARK: Fotopunkty

    /// Wskazuje fotopunkt krzyżykiem w środku ekranu.
    func addControlPoint() {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first else {
            errorMessage = "Nie wykryto powierzchni pod krzyżykiem – podejdź bliżej znacznika (do ok. 5 m)."
            return
        }
        let t = hit.worldTransform.columns.3
        let p = SIMD3<Float>(t.x, t.y, t.z)
        let point = ControlPoint(name: "FP\(controlPoints.count + 1)", local: p)
        controlPoints.append(point)

        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.025),
                                 materials: [SimpleMaterial(color: .systemRed, isMetallic: false)])
        let anchor = AnchorEntity(world: p)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        controlAnchors[point.id] = anchor
        editingControlPointID = point.id
    }

    func updateControlPoint(_ point: ControlPoint) {
        if let i = controlPoints.firstIndex(where: { $0.id == point.id }) {
            controlPoints[i] = point
        }
    }

    func deleteControlPoint(_ id: UUID) {
        controlPoints.removeAll { $0.id == id }
        if let anchor = controlAnchors.removeValue(forKey: id) {
            arView.scene.removeAnchor(anchor)
        }
    }

    private func removeAllControlPoints() {
        for anchor in controlAnchors.values { arView.scene.removeAnchor(anchor) }
        controlAnchors.removeAll()
        controlPoints.removeAll()
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
        let surveyed = controlPoints.filter(\.isSurveyed).count
        if surveyed >= 2 || (surveyed == 1 && settings.georeference) {
            return "Georeferencja: fotopunkty RTK (\(surveyed))"
        }
        guard settings.georeference else { return nil }
        if geoSampleCount < GeoReference.minSamples {
            return "Georeferencja: \(geoSampleCount)/\(GeoReference.minSamples) próbek GPS"
        }
        return "Georeferencja: \(geoSampleCount) próbek GPS"
    }

    var isGeoReady: Bool {
        let surveyed = controlPoints.filter(\.isSurveyed).count
        return surveyed >= 2 || (surveyed == 1 && settings.georeference) || geoSampleCount >= GeoReference.minSamples
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
        let gcps = controlPoints
        guard !anchors.isEmpty || !cloud.positions.isEmpty || !photos.isEmpty else {
            errorMessage = "Brak danych – najpierw zeskanuj otoczenie."
            return
        }

        // Priorytet: fotopunkty RTK, potem GPS + kompas.
        let gcpGeo = GeoReference.fromControlPoints(gcps, headingAligned: settings.georeference)
        let gpsGeo: GeoReference? = settings.georeference ? GeoReference.solve(geoSamples) : nil
        let geo = gcpGeo ?? gpsGeo
        if settings.georeference && geo == nil {
            errorMessage = "Za mało próbek GPS do georeferencji (\(geoSamples.count)/\(GeoReference.minSamples)) i brak fotopunktów RTK. Eksportuję w układzie lokalnym."
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
                    urls += try PhotogrammetryExport.write(photos: photos, controlPoints: gcps,
                                                           geo: geo, to: folder)
                } else if !gcps.isEmpty {
                    let gcpURL = folder.appendingPathComponent("fotopunkty.csv")
                    try PhotogrammetryExport.controlPointsCSV(gcps, geo: geo)
                        .write(to: gcpURL, atomically: true, encoding: .utf8)
                    urls.append(gcpURL)
                }
                if let geo {
                    let info = folder.appendingPathComponent("georeferencja.txt")
                    try geo.report.write(to: info, atomically: true, encoding: .utf8)
                    urls.append(info)
                }
                // Całość (ze zdjęciami) w jednym ZIP – najwygodniej do przeniesienia na komputer.
                if !photos.isEmpty {
                    let zipURL = folder.deletingLastPathComponent().appendingPathComponent("\(name).zip")
                    try PhotogrammetryExport.zip(folder: folder, to: zipURL)
                    urls.insert(zipURL, at: 0)
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
    @State private var showControlPoints = false

    var body: some View {
        ZStack {
            ARViewContainer(arView: model.arView)
                .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .shadow(radius: 2)

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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showControlPoints = true
                } label: {
                    Label("Fotopunkty", systemImage: "scope")
                }
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
        .sheet(isPresented: $showControlPoints) {
            ControlPointListView(model: model)
        }
        .sheet(item: Binding(
            get: { model.editingControlPointID.map { IdentifiedID(id: $0) } },
            set: { model.editingControlPointID = $0?.id }
        )) { item in
            if let point = model.controlPoints.first(where: { $0.id == item.id }) {
                ControlPointEditor(point: point,
                                   onSave: { model.updateControlPoint($0) },
                                   onDelete: { model.deleteControlPoint($0) })
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
                if !model.controlPoints.isEmpty {
                    Label("\(model.controlPoints.count)", systemImage: "scope")
                }
                if !model.isCollecting {
                    Text("PAUZA").bold().foregroundStyle(.orange)
                }
            }
            if model.settings.capturePhotos {
                photoGuidance
            }
            if let geo = model.geoStatus {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                    Text(geo)
                    if let acc = model.gpsAccuracy {
                        Text(String(format: "(±%.0f m)", acc))
                    }
                }
                .foregroundStyle(model.isGeoReady ? Color.green : Color.orange)
            }
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var photoGuidance: some View {
        let g = model.guidance
        let target = Int(model.settings.targetOverlap * 100)
        return VStack(spacing: 2) {
            HStack(spacing: 10) {
                Text("Nakładanie \(g.overlap)% (cel \(target)%)")
                    .foregroundStyle(g.overlap >= target - 5 ? Color.primary : Color.orange)
                if let d = g.distance {
                    Text(String(format: "obiekt %.1f m", d))
                }
                Text(String(format: "%.1f m/s", g.speed))
                    .foregroundStyle(g.speed > 1.0 ? Color.red : Color.primary)
                if g.rejectedBlurry > 0 {
                    Label("\(g.rejectedBlurry)", systemImage: "camera.metering.unknown")
                        .foregroundStyle(.orange)
                }
            }
            if let warning = g.warning {
                Text(warning).bold().foregroundStyle(.orange)
            }
        }
    }

    private var hint: String {
        if model.settings.capturePhotos {
            return "Idź wolno wzdłuż obiektu (do ~0,7 m/s), obejmij go z kilku wysokości. Fotopunkt: celuj krzyżykiem w znacznik i dotknij ◎."
        }
        if model.settings.preset == .exterior || model.settings.maxDepth > 5 {
            return "Idź wolno wzdłuż obiektu w odległości 2–5 m, telefon trzymaj stabilnie. Dłuższe obiekty skanuj odcinkami."
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

                Button {
                    model.addControlPoint()
                } label: {
                    Image(systemName: "scope")
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

// MARK: - Fotopunkty: lista i edycja

struct ControlPointListView: View {
    @ObservedObject var model: Scan3DModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.controlPoints.isEmpty {
                        Text("Brak fotopunktów. Wyceluj krzyżykiem w środek znacznika w terenie i dotknij ◎ na dole ekranu.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.controlPoints) { p in
                        Button {
                            dismiss()
                            model.editingControlPointID = p.id
                        } label: {
                            HStack {
                                Text(p.name).bold()
                                Spacer()
                                if let x = p.x2000, let y = p.y2000 {
                                    Text(String(format: "X %.2f Y %.2f", x, y))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("bez RTK").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ model.controlPoints[$0].id }) {
                            model.deleteControlPoint(id)
                        }
                    }
                } footer: {
                    Text("Fotopunkty z współrzędnymi RTK (PL-2000) zastępują georeferencję z GPS i kompasu: 2+ fotopunkty dają obrót i położenie z dokładnością ~cm (plus dryf ARKit). Rozmieść je na krańcach obiektu. Trafiają też do paczki fotogrametrycznej.")
                }
            }
            .navigationTitle("Fotopunkty")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotowe") { dismiss() }
                }
            }
        }
    }
}

struct ControlPointEditor: View {
    @State var point: ControlPoint
    let onSave: (ControlPoint) -> Void
    let onDelete: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var xText = ""
    @State private var yText = ""
    @State private var hText = ""

    init(point: ControlPoint, onSave: @escaping (ControlPoint) -> Void, onDelete: @escaping (UUID) -> Void) {
        _point = State(initialValue: point)
        self.onSave = onSave
        self.onDelete = onDelete
        _xText = State(initialValue: PointDraft.text(point.x2000, 3))
        _yText = State(initialValue: PointDraft.text(point.y2000, 3))
        _hText = State(initialValue: PointDraft.text(point.height, 3))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Fotopunkt") {
                    LabeledContent("Nazwa") {
                        TextField("FP1", text: $point.name)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    coordinateRow("X (północ)", text: $xText)
                    coordinateRow("Y (wschód)", text: $yText)
                    coordinateRow("H [m]", text: $hText)
                } header: {
                    Text("Współrzędne z RTK (PL-2000) – opcjonalnie")
                } footer: {
                    Text("Możesz je wpisać teraz albo później w Metashape/RealityCapture. Bez nich fotopunkt służy tylko do oznaczenia na zdjęciach.")
                }
                Section {
                    Button(role: .destructive) {
                        onDelete(point.id)
                        dismiss()
                    } label: {
                        Label("Usuń fotopunkt", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(point.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        var p = point
                        p.x2000 = PointDraft.parse(xText)
                        p.y2000 = PointDraft.parse(yText)
                        p.height = PointDraft.parse(hText)
                        onSave(p)
                        dismiss()
                    }
                }
            }
        }
    }

    private func coordinateRow(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("—", text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }
}
