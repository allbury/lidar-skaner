import SwiftUI
import ARKit
import RealityKit

@MainActor
final class Scan3DModel: ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let collector = PointCloudCollector()

    @Published var pointCount = 0
    @Published var meshCount = 0
    @Published var isCollecting = true
    @Published var isExporting = false
    @Published var showMesh = true
    @Published var shareItem: ShareItem?
    @Published var errorMessage: String?
    @Published var savedFolderName: String?

    init() {
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.delegate = collector
        collector.onCountChanged = { [weak self] count in
            Task { @MainActor in
                guard let self else { return }
                self.pointCount = count
                self.meshCount = self.currentMeshAnchors().count
            }
        }
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
        return config
    }

    func start() {
        arView.session.run(makeConfiguration())
    }

    func pause() {
        arView.session.pause()
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

    func reset() {
        collector.reset()
        arView.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        pointCount = 0
        meshCount = 0
        savedFolderName = nil
    }

    private func currentMeshAnchors() -> [ARMeshAnchor] {
        arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    }

    func export() {
        guard !isExporting else { return }
        let anchors = currentMeshAnchors()
        let cloud = collector.snapshot()
        guard !anchors.isEmpty || !cloud.positions.isEmpty else {
            errorMessage = "Brak danych – najpierw zeskanuj otoczenie."
            return
        }
        isExporting = true

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "Skan3D_\(formatter.string(from: Date()))"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent(name, isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            var urls: [URL] = []
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !cloud.positions.isEmpty {
                    let ply = folder.appendingPathComponent("chmura.ply")
                    try Scan3DExporter.writePLY(positions: cloud.positions, colors: cloud.colors, to: ply)
                    urls.append(ply)
                }
                if !anchors.isEmpty {
                    let obj = folder.appendingPathComponent("siatka.obj")
                    try Scan3DExporter.writeOBJ(meshAnchors: anchors, to: obj)
                    urls.append(obj)
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
        .onAppear { model.start() }
        .onDisappear { model.pause() }
        .sheet(item: $model.shareItem) { item in
            ActivityView(items: item.urls)
        }
        .alert("Błąd", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var stats: some View {
        HStack(spacing: 16) {
            Label(Self.formatCount(model.pointCount), systemImage: "circle.dotted")
            Label("\(model.meshCount)", systemImage: "square.grid.3x3")
            if !model.isCollecting {
                Text("PAUZA").bold().foregroundStyle(.orange)
            }
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Text("Poruszaj się powoli, 0,5–4 m od powierzchni. Punkty o niskiej pewności są pomijane.")
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
                        Label("PLY + OBJ", systemImage: "square.and.arrow.up")
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
        if n >= 1_000_000 { return String(format: "%.2f mln pkt", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0f tys. pkt", Double(n) / 1_000) }
        return "\(n) pkt"
    }
}
