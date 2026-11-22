import SwiftUI
import RoomPlan

@MainActor
final class RoomScanModel: ObservableObject {
    enum Phase { case scanning, processing, finished }

    @Published var phase: Phase = .scanning
    @Published var finalRoom: CapturedRoom?
    @Published var shareItem: ShareItem?
    @Published var errorMessage: String?
    @Published var savedFolderName: String?

    weak var captureController: RoomCaptureViewController?

    func finishScan() {
        phase = .processing
        captureController?.stopCapture()
    }

    func didFinish(_ room: CapturedRoom) {
        finalRoom = room
        phase = .finished
    }

    func didFail(_ error: Error) {
        errorMessage = error.localizedDescription
        phase = .finished
    }

    func export() {
        guard let room = finalRoom else { return }
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let name = "Skan_\(formatter.string(from: Date()))"
            let folder = docs.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let usdz = folder.appendingPathComponent("model.usdz")
            try room.export(to: usdz)

            let dxf = folder.appendingPathComponent("rzut.dxf")
            try DXFExporter.floorPlan(for: room).write(to: dxf, atomically: true, encoding: .utf8)

            let json = folder.appendingPathComponent("pomieszczenie.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(room).write(to: json)

            savedFolderName = name
            shareItem = ShareItem(urls: [usdz, dxf, json])
        } catch {
            errorMessage = "Eksport nie powiódł się: \(error.localizedDescription)"
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
    /// Pliki tymczasowe (np. ZIP) do skasowania po zamknięciu udostępniania.
    var cleanup: [URL] = []

    func removeTemporaryFiles() {
        for url in cleanup {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct RoomScanView: View {
    @StateObject private var model = RoomScanModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureRepresentable(model: model)
                .ignoresSafeArea()

            controls
                .padding()
        }
        .navigationTitle("Skan pomieszczenia")
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .scanning:
            Button {
                model.finishScan()
            } label: {
                Label("Zakończ skan", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .processing:
            ProgressView("Przetwarzanie skanu…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

        case .finished:
            VStack(spacing: 8) {
                if let room = model.finalRoom {
                    Text("Ściany: \(room.walls.count) · Drzwi: \(room.doors.count) · Okna: \(room.windows.count) · Otwory: \(room.openings.count) · Obiekty: \(room.objects.count)")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                if let saved = model.savedFolderName {
                    Text("Zapisano w Pliki → LiDAR Skaner → \(saved)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.export()
                } label: {
                    Label("Eksportuj (USDZ, DXF, JSON)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.finalRoom == nil)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let model: RoomScanModel

    func makeUIViewController(context: Context) -> RoomCaptureViewController {
        let controller = RoomCaptureViewController()
        controller.onFinished = { room in
            Task { @MainActor in model.didFinish(room) }
        }
        controller.onError = { error in
            Task { @MainActor in model.didFail(error) }
        }
        model.captureController = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: RoomCaptureViewController, context: Context) {}
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
