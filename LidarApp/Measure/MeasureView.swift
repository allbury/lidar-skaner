import SwiftUI
import ARKit
import RealityKit

@MainActor
final class MeasureModel: ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published var measurements: [Double] = []   // w metrach, najnowszy pierwszy
    @Published var hasPendingPoint = false
    @Published var status = "Wyceluj krzyżykiem i dodaj pierwszy punkt."

    private var pendingPoint: SIMD3<Float>?
    private var anchors: [AnchorEntity] = []

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        arView.session.run(config)
    }

    func pause() {
        arView.session.pause()
    }

    func addPoint() {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first else {
            status = "Nie wykryto powierzchni – porusz powoli telefonem."
            return
        }
        let t = hit.worldTransform.columns.3
        let point = SIMD3<Float>(t.x, t.y, t.z)
        addMarker(at: point)

        if let start = pendingPoint {
            let distance = simd_distance(start, point)
            addLine(from: start, to: point)
            measurements.insert(Double(distance), at: 0)
            pendingPoint = nil
            hasPendingPoint = false
            status = "Wynik: \(Self.format(Double(distance))). Dodaj kolejny punkt startowy."
        } else {
            pendingPoint = point
            hasPendingPoint = true
            status = "Wyceluj w drugi punkt i dodaj go."
        }
    }

    func reset() {
        anchors.forEach { arView.scene.removeAnchor($0) }
        anchors.removeAll()
        measurements.removeAll()
        pendingPoint = nil
        hasPendingPoint = false
        status = "Wyceluj krzyżykiem i dodaj pierwszy punkt."
    }

    static func format(_ meters: Double) -> String {
        String(format: "%.1f cm", meters * 100)
    }

    // MARK: Wizualizacja

    private func addMarker(at p: SIMD3<Float>) {
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.008),
                                 materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)])
        let anchor = AnchorEntity(world: p)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        anchors.append(anchor)
    }

    private func addLine(from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let length = simd_distance(a, b)
        let mid = (a + b) / 2
        let box = ModelEntity(mesh: .generateBox(size: [0.003, 0.003, length]),
                              materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)])
        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        anchor.addChild(box)
        arView.scene.addAnchor(anchor)
        box.look(at: b, from: mid, relativeTo: nil)
        anchors.append(anchor)
    }
}

struct MeasureView: View {
    @StateObject private var model = MeasureModel()

    var body: some View {
        ZStack {
            ARViewContainer(arView: model.arView)
                .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white)
                .shadow(radius: 2)

            VStack {
                Spacer()
                panel
            }
            .padding()
        }
        .navigationTitle("Pomiar")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .onDisappear { model.pause() }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            Text(model.status)
                .font(.footnote)
                .multilineTextAlignment(.center)

            if !model.measurements.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.measurements.enumerated()), id: \.offset) { index, value in
                            Text("\(model.measurements.count - index). \(MeasureModel.format(value))")
                                .font(.body.monospacedDigit())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            HStack {
                Button(role: .destructive) {
                    model.reset()
                } label: {
                    Label("Wyczyść", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Button {
                    model.addPoint()
                } label: {
                    Label(model.hasPendingPoint ? "Punkt końcowy" : "Punkt początkowy",
                          systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
