import SwiftUI

struct SurveyView: View {
    @ObservedObject var store: SurveyStore
    let surveyID: UUID

    @StateObject private var location = LocationManager()
    @State private var sheet: SheetKind?
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    enum SheetKind: Identifiable {
        case newPoint
        case editPoint(UUID)
        case newPipe
        case editPipe(UUID)

        var id: String {
            switch self {
            case .newPoint: return "newPoint"
            case .editPoint(let id): return "point-\(id.uuidString)"
            case .newPipe: return "newPipe"
            case .editPipe(let id): return "pipe-\(id.uuidString)"
            }
        }
    }

    private var survey: Survey {
        store.survey(surveyID) ?? Survey(name: "")
    }

    private var photoFolder: URL {
        store.photoFolder(for: surveyID)
    }

    private func update(_ change: (inout Survey) -> Void) {
        var s = survey
        change(&s)
        store.save(s)
    }

    var body: some View {
        List {
            Section {
                gpsStatus
            }

            Section("Punkty (\(survey.points.count))") {
                if survey.points.isEmpty {
                    Text("Dodaj pierwszy punkt przyciskiem +.")
                        .foregroundStyle(.secondary)
                }
                ForEach(survey.points) { point in
                    Button {
                        sheet = .editPoint(point.id)
                    } label: {
                        pointRow(point)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    update { s in
                        let ids = offsets.map { s.points[$0].id }
                        s.points.remove(atOffsets: offsets)
                        s.pipes.removeAll { ids.contains($0.fromID) || ids.contains($0.toID) }
                    }
                }
            }

            Section("Odcinki sieci (\(survey.pipes.count))") {
                if survey.pipes.isEmpty {
                    Text("Połącz punkty odcinkiem rury (min. 2 punkty).")
                        .foregroundStyle(.secondary)
                }
                ForEach(survey.pipes) { pipe in
                    Button {
                        sheet = .editPipe(pipe.id)
                    } label: {
                        pipeRow(pipe)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    update { $0.pipes.remove(atOffsets: offsets) }
                }
            }
        }
        .navigationTitle(survey.name)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    export()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(survey.points.isEmpty)

                Menu {
                    Button {
                        sheet = .newPoint
                    } label: {
                        Label("Punkt", systemImage: "mappin.and.ellipse")
                    }
                    Button {
                        sheet = .newPipe
                    } label: {
                        Label("Odcinek rury", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .disabled(survey.points.count < 2)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
        .sheet(item: $sheet) { kind in
            sheetContent(kind)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
        .alert("Błąd", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func sheetContent(_ kind: SheetKind) -> some View {
        switch kind {
        case .newPoint:
            PointEditorView(survey: survey, point: nil, photoFolder: photoFolder, location: location) { p in
                update { $0.points.append(p) }
            }
        case .editPoint(let id):
            PointEditorView(survey: survey, point: survey.point(id), photoFolder: photoFolder, location: location) { p in
                update { s in
                    if let i = s.points.firstIndex(where: { $0.id == p.id }) { s.points[i] = p }
                }
            }
        case .newPipe:
            PipeEditorView(survey: survey, pipe: nil) { pipe in
                update { $0.pipes.append(pipe) }
            }
        case .editPipe(let id):
            PipeEditorView(survey: survey, pipe: survey.pipes.first { $0.id == id }) { pipe in
                update { s in
                    if let i = s.pipes.firstIndex(where: { $0.id == pipe.id }) { s.pipes[i] = pipe }
                }
            }
        }
    }

    private var gpsStatus: some View {
        HStack {
            Image(systemName: "location.fill")
                .foregroundStyle(gpsColor)
            if let loc = location.current {
                Text(String(format: "GPS ±%.1f m", loc.horizontalAccuracy))
                    .monospacedDigit()
            } else if location.authorization == .denied || location.authorization == .restricted {
                Text("Brak zgody na lokalizację – włącz ją w Ustawieniach.")
            } else {
                Text("Szukanie GPS…")
            }
            Spacer()
            if location.isReducedAccuracy {
                Text("przybliżona!").foregroundStyle(.orange).font(.caption)
            }
        }
        .font(.footnote)
    }

    private var gpsColor: Color {
        guard let acc = location.current?.horizontalAccuracy, acc > 0 else { return .gray }
        if acc <= 5 { return .green }
        if acc <= 15 { return .orange }
        return .red
    }

    private func pointRow(_ p: SurveyPoint) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.kind.symbol)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(p.number).bold()
                    Text(p.kind.name).foregroundStyle(.secondary)
                }
                if let x = p.x2000, let y = p.y2000 {
                    Text(String(format: "X %.2f  Y %.2f", x, y))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("brak współrzędnych").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let depth = p.depth {
                    Text(String(format: "h %.2f m", depth)).font(.caption.monospacedDigit())
                }
                if let acc = p.horizontalAccuracy {
                    Text(String(format: "±%.1f m", acc)).font(.caption2).foregroundStyle(.secondary)
                }
                if !p.photos.isEmpty {
                    Label("\(p.photos.count)", systemImage: "photo").font(.caption2)
                }
            }
        }
    }

    private func pipeRow(_ pipe: PipeSegment) -> some View {
        let from = survey.point(pipe.fromID)?.number ?? "?"
        let to = survey.point(pipe.toID)?.number ?? "?"
        let length = survey.length(of: pipe).map { String(format: "%.2f m", $0) } ?? ""
        return HStack {
            Text(pipe.network.code)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: Capsule())
            Text("\(from) → \(to)")
            Text([pipe.diameter, pipe.material].filter { !$0.isEmpty }.joined(separator: " "))
                .foregroundStyle(.secondary)
            Spacer()
            Text(length).font(.caption.monospacedDigit())
        }
    }

    private func export() {
        let s = survey
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let safeName = s.name.replacingOccurrences(of: "/", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Eksport_\(safeName)_\(formatter.string(from: Date()))", isDirectory: true)
        do {
            let urls = try InventoryExporter.export(survey: s, photoFolder: photoFolder, to: folder)
            shareItem = ShareItem(urls: urls)
        } catch {
            errorMessage = "Eksport nie powiódł się: \(error.localizedDescription)"
        }
    }
}
