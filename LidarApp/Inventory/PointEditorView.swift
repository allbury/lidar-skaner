import SwiftUI
import CoreLocation

/// Wersja robocza punktu – pola liczbowe jako tekst (obsługa przecinka dziesiętnego).
struct PointDraft {
    var id: UUID
    var number: String
    var kind: PointKind
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var gpsSamples: Int?
    var zone: Int?
    var xText = ""
    var yText = ""
    var hText = ""
    var depthText = ""
    var dimension = ""
    var material = ""
    var note = ""
    var photos: [String] = []
    var createdAt = Date()
    var isDone = true
    var source: CoordinateSource?
    var mapInfo: String?

    init(point: SurveyPoint) {
        id = point.id
        number = point.number
        kind = point.kind
        latitude = point.latitude
        longitude = point.longitude
        horizontalAccuracy = point.horizontalAccuracy
        gpsSamples = point.gpsSamples
        zone = point.zone2000
        xText = Self.text(point.x2000, 3)
        yText = Self.text(point.y2000, 3)
        hText = Self.text(point.height, 2)
        depthText = Self.text(point.depth, 2)
        dimension = point.dimension
        material = point.material
        note = point.note
        photos = point.photos
        createdAt = point.createdAt
        isDone = !point.isPlanned
        source = point.source
        mapInfo = point.mapInfo
    }

    init(kind: PointKind, number: String) {
        id = UUID()
        self.kind = kind
        self.number = number
    }

    static func text(_ v: Double?, _ digits: Int) -> String {
        guard let v else { return "" }
        return String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    static func parse(_ s: String) -> Double? {
        let cleaned = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    mutating func apply(_ fix: GPSFix) {
        latitude = fix.latitude
        longitude = fix.longitude
        horizontalAccuracy = fix.horizontalAccuracy
        gpsSamples = fix.samples
        let c = PL2000.convert(latitude: fix.latitude, longitude: fix.longitude)
        zone = c.zone
        source = .gps
        xText = Self.text(c.x, 3)
        yText = Self.text(c.y, 3)
        if let alt = fix.altitude { hText = Self.text(alt, 2) }
    }

    func makePoint() -> SurveyPoint {
        var p = SurveyPoint(id: id, number: number.trimmingCharacters(in: .whitespaces), kind: kind)
        p.latitude = latitude
        p.longitude = longitude
        p.horizontalAccuracy = horizontalAccuracy
        p.gpsSamples = gpsSamples
        p.x2000 = Self.parse(xText)
        p.y2000 = Self.parse(yText)
        p.height = Self.parse(hText)
        p.depth = Self.parse(depthText)
        if let y = p.y2000 {
            // Strefa wynika z pierwszej cyfry Y (5–8).
            p.zone2000 = zone ?? Int(y / 1_000_000)
        }
        p.dimension = dimension
        p.material = material
        p.note = note
        p.photos = photos
        p.createdAt = createdAt
        p.status = isDone ? .done : .planned
        p.source = source
        p.mapInfo = mapInfo
        return p
    }
}

struct PointEditorView: View {
    let survey: Survey
    let photoFolder: URL
    let onSave: (SurveyPoint) -> Void
    @ObservedObject var location: LocationManager

    @Environment(\.dismiss) private var dismiss
    @State private var draft: PointDraft
    @State private var isNew: Bool
    @State private var showDepth = false
    @State private var showCamera = false
    @State private var gpsMessage: String?

    init(survey: Survey, point: SurveyPoint?, photoFolder: URL,
         location: LocationManager, onSave: @escaping (SurveyPoint) -> Void) {
        self.survey = survey
        self.photoFolder = photoFolder
        self.location = location
        self.onSave = onSave
        if let point {
            _draft = State(initialValue: PointDraft(point: point))
            _isNew = State(initialValue: false)
        } else {
            let kind = PointKind.studnia
            _draft = State(initialValue: PointDraft(kind: kind, number: survey.nextNumber(for: kind)))
            _isNew = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Punkt") {
                    Picker("Rodzaj", selection: $draft.kind) {
                        ForEach(PointKind.allCases) { kind in
                            Label(kind.name, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .onChange(of: draft.kind) { _, newKind in
                        if isNew { draft.number = survey.nextNumber(for: newKind) }
                    }
                    LabeledContent("Numer") {
                        TextField("np. S1", text: $draft.number)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Zinwentaryzowany", isOn: $draft.isDone)
                }

                if !draft.isDone || draft.mapInfo != nil {
                    targetSection
                }

                gpsSection

                Section {
                    numberRow("X (północ)", text: $draft.xText)
                    numberRow("Y (wschód)", text: $draft.yText)
                    numberRow("H [m]", text: $draft.hText)
                } header: {
                    Text("Współrzędne PL-2000" + (draft.zone.map { ", strefa \($0)" } ?? ""))
                } footer: {
                    Text("Wypełniane z GPS, ale można je wpisać ręcznie, np. z odbiornika GNSS. H z telefonu jest tylko orientacyjne (±10 m).")
                }

                Section("Parametry") {
                    HStack {
                        numberRow("Głębokość [m]", text: $draft.depthText)
                        Button {
                            showDepth = true
                        } label: {
                            Image(systemName: "ruler")
                        }
                        .buttonStyle(.bordered)
                    }
                    LabeledContent("Wymiar / DN") {
                        TextField("np. DN1000", text: $draft.dimension)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Materiał") {
                        TextField("np. beton", text: $draft.material)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Opis / uwagi", text: $draft.note, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Zdjęcia (\(draft.photos.count))") {
                    if !draft.photos.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(draft.photos, id: \.self) { name in
                                    thumbnail(name)
                                }
                            }
                        }
                    }
                    Button {
                        showCamera = true
                    } label: {
                        Label("Zrób zdjęcie", systemImage: "camera")
                    }
                }
            }
            .navigationTitle(isNew ? "Nowy punkt" : draft.number)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        onSave(draft.makePoint())
                        dismiss()
                    }
                    .disabled(draft.number.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fullScreenCover(isPresented: $showDepth) {
                DepthMeasureView { depth in
                    draft.depthText = PointDraft.text(depth, 2)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    savePhoto(image)
                }
                .ignoresSafeArea()
            }
        }
    }

    /// Punkt wskazany na mapie: skąd pochodzi i jak do niego dojść.
    private var targetSection: some View {
        Section {
            if let source = draft.source {
                LabeledContent("Źródło położenia", value: source.name)
            }
            if let info = draft.mapInfo {
                Text(info)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let here = location.current,
               let nav = TargetNavigation.describe(from: here, to: draft.makePoint()) {
                Label("Do punktu: \(nav.long)", systemImage: "location.north.line.fill")
                    .foregroundStyle(nav.distance <= max(here.horizontalAccuracy, 3) ? Color.green : Color.orange)
                if nav.distance <= max(here.horizontalAccuracy, 3) {
                    Text("Jesteś przy punkcie (w granicach dokładności GPS).")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Cel z mapy")
        } footer: {
            Text("Współrzędne z podkładu DXF są zwykle dokładniejsze niż GPS telefonu – nie nadpisuj ich pozycją GPS, jeśli studnia zgadza się z mapą. Po pomiarze głębokości i zdjęciach zaznacz „Zinwentaryzowany”.")
        }
    }

    private var gpsSection: some View {
        Section {
            if let loc = location.current {
                LabeledContent("Bieżąca dokładność", value: String(format: "±%.1f m", loc.horizontalAccuracy))
            } else {
                Text("Oczekiwanie na GPS…").foregroundStyle(.secondary)
            }
            if location.isReducedAccuracy {
                Label("Włącz „Dokładna lokalizacja” dla tej aplikacji w Ustawieniach.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            if let range = location.averagingRange {
                ProgressView(timerInterval: range, countsDown: false) {
                    Text("Uśrednianie pozycji…")
                }
            } else {
                Button {
                    location.average(seconds: 10) { fix in
                        if let fix {
                            draft.apply(fix)
                            gpsMessage = String(format: "Uśredniono %d próbek, ±%.1f m", fix.samples, fix.horizontalAccuracy)
                        } else {
                            gpsMessage = "Brak próbek GPS o dokładności ≤ 30 m – wyjdź na otwarty teren."
                        }
                    }
                } label: {
                    Label("Pobierz pozycję (uśrednij 10 s)", systemImage: "location.fill")
                }
            }
            if let gpsMessage {
                Text(gpsMessage).font(.footnote).foregroundStyle(.secondary)
            }
            if let lat = draft.latitude, let lon = draft.longitude {
                Text(String(format: "φ %.7f°  λ %.7f°", lat, lon))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("GPS")
        } footer: {
            Text("GPS telefonu daje zwykle 2–5 m. Stań nad punktem, trzymaj telefon nieruchomo i odczekaj uśrednianie.")
        }
    }

    private func numberRow(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("—", text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func thumbnail(_ name: String) -> some View {
        let url = photoFolder.appendingPathComponent(name)
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    Button(role: .destructive) {
                        draft.photos.removeAll { $0 == name }
                        try? FileManager.default.removeItem(at: url)
                    } label: {
                        Label("Usuń zdjęcie", systemImage: "trash")
                    }
                }
        }
    }

    private func savePhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let safeNumber = draft.number.isEmpty ? "punkt" : draft.number.replacingOccurrences(of: "/", with: "-")
        let name = "\(safeNumber)_\(UUID().uuidString.prefix(6)).jpg"
        let url = photoFolder.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            draft.photos.append(name)
        } catch {
            gpsMessage = "Nie udało się zapisać zdjęcia."
        }
    }
}
