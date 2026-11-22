import SwiftUI
import ARKit
import RealityKit

/// Pomiar głębokości LiDAR-em: punkt 1 = krawędź włazu / teren, punkt 2 = dno / wierzch rury.
/// Wynik = różnica wysokości (pionowo), niezależnie od pochylenia telefonu.
@MainActor
final class DepthMeasureModel: ObservableObject {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    @Published var top: SIMD3<Float>?
    @Published var bottom: SIMD3<Float>?
    @Published var message = "Wyceluj w krawędź włazu (teren) i zaznacz punkt 1."

    private var anchors: [AnchorEntity] = []

    var verticalDepth: Double? {
        guard let top, let bottom else { return nil }
        return Double(abs(top.y - bottom.y))
    }

    var slantDistance: Double? {
        guard let top, let bottom else { return nil }
        return Double(simd_distance(top, bottom))
    }

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

    func pause() { arView.session.pause() }

    func mark() {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first else {
            message = "Nie wykryto powierzchni – porusz powoli telefonem."
            return
        }
        let t = hit.worldTransform.columns.3
        let p = SIMD3<Float>(t.x, t.y, t.z)
        if top == nil {
            top = p
            addMarker(p, color: .systemGreen)
            message = "Teraz wyceluj w dno studni / wierzch rury i zaznacz punkt 2."
        } else {
            if bottom != nil { clearMarkers(keepFirst: true) }
            bottom = p
            addMarker(p, color: .systemRed)
            message = "Gotowe. Możesz zaznaczyć punkt 2 ponownie albo użyć wyniku."
        }
    }

    func reset() {
        clearMarkers(keepFirst: false)
        top = nil
        bottom = nil
        message = "Wyceluj w krawędź włazu (teren) i zaznacz punkt 1."
    }

    private func addMarker(_ p: SIMD3<Float>, color: UIColor) {
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.012),
                                 materials: [SimpleMaterial(color: color, isMetallic: false)])
        let anchor = AnchorEntity(world: p)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        anchors.append(anchor)
    }

    private func clearMarkers(keepFirst: Bool) {
        let keep = keepFirst ? Array(anchors.prefix(1)) : []
        for anchor in anchors where !keep.contains(where: { $0 === anchor }) {
            arView.scene.removeAnchor(anchor)
        }
        anchors = keep
    }
}

struct DepthMeasureView: View {
    let onResult: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DepthMeasureModel()

    var body: some View {
        ZStack {
            ARViewContainer(arView: model.arView)
                .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white)
                .shadow(radius: 2)

            VStack {
                HStack {
                    Button("Anuluj") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                Spacer()
                panel
            }
            .padding()
        }
        .onAppear { model.start() }
        .onDisappear { model.pause() }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            Text(model.message)
                .font(.footnote)
                .multilineTextAlignment(.center)

            if let depth = model.verticalDepth, let slant = model.slantDistance {
                Text(String(format: "Głębokość: %.2f m", depth))
                    .font(.title2.bold().monospacedDigit())
                Text(String(format: "odległość skośna %.2f m", slant))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(role: .destructive) {
                    model.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    model.mark()
                } label: {
                    Label(model.top == nil ? "Punkt 1 (góra)" : "Punkt 2 (dół)",
                          systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    if let depth = model.verticalDepth {
                        onResult(depth)
                        dismiss()
                    }
                } label: {
                    Text("Użyj")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.verticalDepth == nil)
            }
            .controlSize(.large)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
