import SwiftUI
import MapKit
import UniformTypeIdentifiers
import simd

// MARK: - Dane mapy

struct MapLayerSettings: Equatable {
    enum Base: String, CaseIterable, Identifiable {
        case standard, hybrid, satellite
        var id: String { rawValue }
        var name: String {
            switch self {
            case .standard: return "Mapa"
            case .hybrid: return "Hybryda"
            case .satellite: return "Satelita"
            }
        }
    }

    var base: Base = .standard
    var ortho = false
    var parcels = false
    var utilities = true
    var dxf = true

    var geoportalLayers: [GeoportalLayer] {
        var result: [GeoportalLayer] = []
        if ortho { result.append(.ortho) }
        if parcels { result.append(.parcels) }
        if utilities { result.append(.utilities) }
        return result
    }
}

/// Podkład DXF przeliczony na współrzędne geograficzne do rysowania.
struct DXFMapData {
    struct Group {
        let color: Int
        let lines: [[CLLocationCoordinate2D]]
    }

    let id = UUID()
    let groups: [Group]
    let candidateCoordinates: [CLLocationCoordinate2D]
    let bounds: MKMapRect

    init(background: DXFBackground, transform: DXFGeoTransform) {
        var byColor: [Int: [[CLLocationCoordinate2D]]] = [:]
        var rect = MKMapRect.null
        for poly in background.polylines {
            let coords = poly.points.map { transform.coordinate($0) }
            byColor[poly.color, default: []].append(coords)
            for c in coords.prefix(1) {
                let p = MKMapPoint(c)
                rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
        }
        // Symbole bloków i punktów: mały krzyżyk ±0,3 m.
        var crosses: [[CLLocationCoordinate2D]] = []
        var candidates: [CLLocationCoordinate2D] = []
        for c in background.candidates {
            let center = transform.coordinate(c.position)
            candidates.append(center)
            if c.kind != .circle {
                let d = 0.3
                let p = c.position
                crosses.append([transform.coordinate(p + SIMD2(-d, -d)), transform.coordinate(p + SIMD2(d, d))])
                crosses.append([transform.coordinate(p + SIMD2(-d, d)), transform.coordinate(p + SIMD2(d, -d))])
            }
            let mp = MKMapPoint(center)
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0))
        }
        if !crosses.isEmpty {
            byColor[-1, default: []].append(contentsOf: crosses)
        }
        groups = byColor.map { Group(color: $0.key, lines: $0.value) }
        candidateCoordinates = candidates
        bounds = rect
    }

    static func color(aci: Int) -> UIColor {
        switch aci {
        case -1: return .systemPink
        case 1: return .systemRed
        case 2: return .systemYellow
        case 3: return .systemGreen
        case 4: return .systemTeal
        case 5: return .systemBlue
        case 6: return .systemPurple
        case 30...39: return .brown
        case 7, 255: return .label
        default: return .darkGray
        }
    }
}

// MARK: - Widok MKMapView

final class ColoredMultiPolyline: MKMultiPolyline {
    var color: UIColor = .gray
    var width: CGFloat = 1
}

final class ColoredPolyline: MKPolyline {
    var color: UIColor = .gray
    var width: CGFloat = 3
}

final class SurveyPointAnnotation: NSObject, MKAnnotation {
    let pointID: UUID
    let planned: Bool
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(point: SurveyPoint, coordinate: CLLocationCoordinate2D) {
        pointID = point.id
        planned = point.isPlanned
        self.coordinate = coordinate
        title = point.number
        subtitle = point.kind.name + (point.isPlanned ? " – do inwentaryzacji" : "")
    }
}

struct SurveyMapView: UIViewRepresentable {
    let survey: Survey
    let dxf: DXFMapData?
    let layers: MapLayerSettings
    let focusToken: Int
    let onLongPress: (CLLocationCoordinate2D, Double) -> Void
    let onOpenPoint: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsScale = true
        map.showsCompass = true
        map.pointOfInterestFilter = .excludingAll
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleLongPress(_:)))
        press.minimumPressDuration = 0.45
        map.addGestureRecognizer(press)
        context.coordinator.update(map, initial: true)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(map, initial: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: SurveyMapView
        private var lastLayers: MapLayerSettings?
        private var lastDXF: UUID?
        private var lastDXFVisible = false
        private var lastSurvey: Survey?
        private var lastFocus = -1
        private var tileOverlays: [GeoportalLayer: WMSTileOverlay] = [:]
        private var dxfOverlays: [MKOverlay] = []
        private var pipeOverlays: [MKOverlay] = []

        init(_ parent: SurveyMapView) { self.parent = parent }

        func update(_ map: MKMapView, initial: Bool) {
            let layers = parent.layers
            if lastLayers?.base != layers.base {
                switch layers.base {
                case .standard: map.preferredConfiguration = MKStandardMapConfiguration()
                case .hybrid: map.preferredConfiguration = MKHybridMapConfiguration()
                case .satellite: map.preferredConfiguration = MKImageryMapConfiguration()
                }
            }

            if lastLayers?.geoportalLayers != layers.geoportalLayers {
                // Kolejność rysowania: ortofoto → działki → uzbrojenie → DXF → rury.
                map.removeOverlays(Array(tileOverlays.values))
                map.removeOverlays(dxfOverlays)
                map.removeOverlays(pipeOverlays)
                tileOverlays.removeAll()
                for layer in layers.geoportalLayers {
                    let overlay = WMSTileOverlay(layer: layer)
                    tileOverlays[layer] = overlay
                    map.addOverlay(overlay, level: .aboveLabels)
                }
                map.addOverlays(dxfOverlays, level: .aboveLabels)
                map.addOverlays(pipeOverlays, level: .aboveLabels)
            }

            let dxfVisible = layers.dxf && parent.dxf != nil
            if parent.dxf?.id != lastDXF || dxfVisible != lastDXFVisible {
                map.removeOverlays(dxfOverlays)
                dxfOverlays.removeAll()
                if dxfVisible, let dxf = parent.dxf {
                    for group in dxf.groups {
                        let polylines = group.lines.map { coords -> MKPolyline in
                            var c = coords
                            return MKPolyline(coordinates: &c, count: c.count)
                        }
                        let multi = ColoredMultiPolyline(polylines)
                        multi.color = DXFMapData.color(aci: group.color)
                        multi.width = group.color == -1 ? 2 : 1
                        dxfOverlays.append(multi)
                    }
                    map.addOverlays(dxfOverlays, level: .aboveLabels)
                    // Rury mają być nad podkładem.
                    map.removeOverlays(pipeOverlays)
                    map.addOverlays(pipeOverlays, level: .aboveLabels)
                }
                lastDXF = parent.dxf?.id
                lastDXFVisible = dxfVisible
            }

            if lastSurvey != parent.survey {
                refreshSurvey(map)
                lastSurvey = parent.survey
            }

            if initial || parent.focusToken != lastFocus {
                focus(map)
                lastFocus = parent.focusToken
            }
            lastLayers = layers
        }

        private func refreshSurvey(_ map: MKMapView) {
            map.removeAnnotations(map.annotations.filter { $0 is SurveyPointAnnotation })
            var annotations: [SurveyPointAnnotation] = []
            for p in parent.survey.points {
                guard let c = p.coordinate else { continue }
                annotations.append(SurveyPointAnnotation(
                    point: p, coordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)))
            }
            map.addAnnotations(annotations)

            map.removeOverlays(pipeOverlays)
            pipeOverlays.removeAll()
            for pipe in parent.survey.pipes {
                guard let a = parent.survey.point(pipe.fromID)?.coordinate,
                      let b = parent.survey.point(pipe.toID)?.coordinate else { continue }
                var coords = [CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude),
                              CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)]
                let line = ColoredPolyline(coordinates: &coords, count: 2)
                line.color = DXFMapData.color(aci: pipe.network.dxfColor)
                line.width = 4
                pipeOverlays.append(line)
            }
            map.addOverlays(pipeOverlays, level: .aboveLabels)
        }

        private func focus(_ map: MKMapView) {
            var rect = MKMapRect.null
            for p in parent.survey.points {
                if let c = p.coordinate {
                    let mp = MKMapPoint(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
                    rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0))
                }
            }
            if rect.isNull, let dxf = parent.dxf, !dxf.bounds.isNull {
                rect = dxf.bounds
            }
            if !rect.isNull {
                let minSize = 300 / MKMetersPerMapPointAtLatitude(rect.origin.coordinate.latitude)
                let w = max(rect.size.width, minSize)
                let h = max(rect.size.height, minSize)
                let padded = MKMapRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
                map.setVisibleMapRect(padded, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                                      animated: false)
            } else if let user = map.userLocation.location {
                map.setRegion(MKCoordinateRegion(center: user.coordinate, latitudinalMeters: 300,
                                                 longitudinalMeters: 300), animated: false)
            } else {
                map.setUserTrackingMode(.follow, animated: false)
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            let mapPointsPerScreenPoint = map.visibleMapRect.width / Double(max(map.bounds.width, 1))
            let metersPerPoint = mapPointsPerScreenPoint * MKMetersPerMapPointAtLatitude(coordinate.latitude)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onLongPress(coordinate, metersPerPoint)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? WMSTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tile)
                r.alpha = tile.layer == .ortho ? 1 : 0.9
                return r
            }
            if let multi = overlay as? ColoredMultiPolyline {
                let r = MKMultiPolylineRenderer(multiPolyline: multi)
                r.strokeColor = multi.color
                r.lineWidth = multi.width
                return r
            }
            if let line = overlay as? ColoredPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = line.color
                r.lineWidth = line.width
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? SurveyPointAnnotation else { return nil }
            let id = "surveyPoint"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: id)
            view.annotation = a
            view.markerTintColor = a.planned ? .systemOrange : .systemGreen
            view.glyphImage = UIImage(systemName: a.planned ? "questionmark" : "checkmark")
            view.titleVisibility = .visible
            view.canShowCallout = true
            view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            view.displayPriority = .required
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: UIControl) {
            if let a = view.annotation as? SurveyPointAnnotation {
                parent.onOpenPoint(a.pointID)
            }
        }
    }
}

// MARK: - Ekran mapy

/// Co wskazano na mapie (przed dodaniem do inwentaryzacji).
struct MapPick: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let x2000: Double
    let y2000: Double
    let zone: Int
    let source: CoordinateSource
    let title: String
    let info: String
    let label: String?
    let suggestedKind: PointKind
}

struct SurveyMapScreen: View {
    @ObservedObject var store: SurveyStore
    let surveyID: UUID
    @ObservedObject var location: LocationManager

    @AppStorage("map.base") private var baseRaw = MapLayerSettings.Base.standard.rawValue
    @AppStorage("map.ortho") private var ortho = false
    @AppStorage("map.parcels") private var parcels = false
    @AppStorage("map.utilities") private var utilities = true
    @AppStorage("map.dxf") private var showDXF = true

    @State private var background: DXFBackground?
    @State private var dxfData: DXFMapData?
    @State private var transform: DXFGeoTransform?
    @State private var isLoading = false
    @State private var showImporter = false
    @State private var showLayers = false
    @State private var pick: MapPick?
    @State private var editingPointID: UUID?
    @State private var message: String?
    @State private var focusToken = 0

    private var survey: Survey { store.survey(surveyID) ?? Survey(name: "") }

    private var layers: MapLayerSettings {
        MapLayerSettings(base: MapLayerSettings.Base(rawValue: baseRaw) ?? .standard,
                         ortho: ortho, parcels: parcels, utilities: utilities, dxf: showDXF)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            SurveyMapView(survey: survey, dxf: dxfData, layers: layers, focusToken: focusToken,
                          onLongPress: { coordinate, metersPerPoint in
                              Task { await handlePick(at: coordinate, metersPerPoint: metersPerPoint) }
                          },
                          onOpenPoint: { id in editingPointID = id })
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 6) {
                if isLoading {
                    ProgressView("Wczytywanie…")
                }
                Text(hintText)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
        .navigationTitle("Mapa")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    focusToken += 1
                } label: {
                    Image(systemName: "scope")
                }
                Button {
                    showLayers = true
                } label: {
                    Image(systemName: "square.3.layers.3d")
                }
            }
        }
        .onAppear {
            location.start()
            loadBackground()
        }
        .sheet(isPresented: $showLayers) {
            layersSheet
                .presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "dxf") ?? .data, .data],
                      allowsMultipleSelection: false) { result in
            importDXF(result)
        }
        .confirmationDialog(pick?.title ?? "", isPresented: Binding(
            get: { pick != nil },
            set: { if !$0 { pick = nil } }
        ), titleVisibility: .visible, presenting: pick) { p in
            Button("Dodaj jako: \(p.suggestedKind.name)") { addPlanned(p, kind: p.suggestedKind) }
            ForEach([PointKind.studnia, .wpust, .zasuwa, .hydrant, .kratka, .inne].filter { $0 != p.suggestedKind }) { kind in
                Button(kind.name) { addPlanned(p, kind: kind) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { p in
            Text(p.info)
        }
        .sheet(item: Binding(
            get: { editingPointID.map { IdentifiedID(id: $0) } },
            set: { editingPointID = $0?.id }
        )) { item in
            PointEditorView(survey: survey, point: survey.point(item.id),
                            photoFolder: store.photoFolder(for: surveyID), location: location) { p in
                var s = survey
                if let i = s.points.firstIndex(where: { $0.id == p.id }) { s.points[i] = p }
                store.save(s)
            }
        }
        .alert("Informacja", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var hintText: String {
        var parts = ["Przytrzymaj palec na studni / elemencie, aby dodać go do inwentaryzacji."]
        if utilities { parts.append("Uzbrojenie (GESUT) widać po przybliżeniu.") }
        if background == nil { parts.append("Podkład DXF: ikona warstw → Wczytaj DXF.") }
        return parts.joined(separator: " ")
    }

    // MARK: Warstwy

    private var layersSheet: some View {
        NavigationStack {
            Form {
                Section("Mapa bazowa") {
                    Picker("Mapa bazowa", selection: $baseRaw) {
                        ForEach(MapLayerSettings.Base.allCases) { b in
                            Text(b.name).tag(b.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle(GeoportalLayer.ortho.name, isOn: $ortho)
                    Toggle(GeoportalLayer.parcels.name, isOn: $parcels)
                    Toggle(GeoportalLayer.utilities.name, isOn: $utilities)
                } header: {
                    Text("Geoportal (GUGiK)")
                } footer: {
                    Text("Dane pobierane na żywo z geoportal.gov.pl – wymagają internetu. Działki od skali ok. 1:5000, uzbrojenie od ok. 1:2500. Przytrzymanie palca przy włączonym uzbrojeniu pobiera opis obiektu z GESUT.")
                }
                Section {
                    if let background {
                        Toggle("Pokaż podkład DXF", isOn: $showDXF)
                        LabeledContent("Elementy", value: "\(background.polylines.count) linii, \(background.candidates.count) symboli")
                        if let transform {
                            Picker("Strefa PL-2000", selection: Binding(
                                get: { transform.zone },
                                set: { updateTransform(DXFGeoTransform(swapAxes: transform.swapAxes, zone: $0)) }
                            )) {
                                ForEach(5...8, id: \.self) { z in Text("\(z)").tag(z) }
                            }
                            Toggle("Zamień osie X/Y", isOn: Binding(
                                get: { transform.swapAxes },
                                set: { updateTransform(DXFGeoTransform(swapAxes: $0, zone: transform.zone)) }
                            ))
                        }
                        Button(role: .destructive) {
                            removeBackground()
                        } label: {
                            Label("Usuń podkład", systemImage: "trash")
                        }
                    }
                    Button {
                        showLayers = false
                        showImporter = true
                    } label: {
                        Label(background == nil ? "Wczytaj DXF…" : "Wczytaj inny DXF…", systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Podkład DXF")
                } footer: {
                    Text("DXF w układzie PL-2000 (np. mapa do celów projektowych, GESUT z ODGiK). Standardowo X rysunku = Y(2000), Y rysunku = X(2000) – jeśli podkład jest obrócony/przesunięty, użyj „Zamień osie”. Wybierać można okręgi, bloki i punkty; numer studni jest brany z najbliższego tekstu.")
                }
            }
            .navigationTitle("Warstwy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotowe") { showLayers = false }
                }
            }
        }
    }

    // MARK: Podkład DXF

    private func loadBackground() {
        guard background == nil, let url = store.backgroundURL(for: survey) else { return }
        let s = survey
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try DXFBackground.load(from: url) }
            await MainActor.run {
                isLoading = false
                switch result {
                case .success(let bg):
                    background = bg
                    let t: DXFGeoTransform
                    if let zone = s.backgroundZone {
                        t = DXFGeoTransform(swapAxes: s.backgroundSwapAxes ?? false, zone: zone)
                    } else {
                        t = DXFGeoTransform.guess(for: bg) ?? DXFGeoTransform(swapAxes: false, zone: 7)
                    }
                    applyTransform(t, to: bg)
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }

    private func importDXF(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        do {
            let name = try store.importBackground(from: url, for: surveyID)
            var s = survey
            s.backgroundFile = name
            s.backgroundZone = nil
            s.backgroundSwapAxes = nil
            store.save(s)
            background = nil
            dxfData = nil
            loadBackgroundAfterImport()
        } catch {
            message = "Nie udało się wczytać pliku: \(error.localizedDescription)"
        }
    }

    private func loadBackgroundAfterImport() {
        guard let url = store.backgroundURL(for: survey) else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try DXFBackground.load(from: url) }
            await MainActor.run {
                isLoading = false
                switch result {
                case .success(let bg):
                    background = bg
                    if let guess = DXFGeoTransform.guess(for: bg) {
                        updateTransform(guess, focus: true)
                    } else {
                        updateTransform(DXFGeoTransform(swapAxes: false, zone: 7), focus: true)
                        message = "Współrzędne podkładu nie wyglądają na PL-2000. Sprawdź strefę i „Zamień osie” w Warstwach."
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }

    private func applyTransform(_ t: DXFGeoTransform, to bg: DXFBackground) {
        transform = t
        dxfData = DXFMapData(background: bg, transform: t)
    }

    private func updateTransform(_ t: DXFGeoTransform, focus: Bool = false) {
        guard let bg = background else { return }
        applyTransform(t, to: bg)
        var s = survey
        s.backgroundZone = t.zone
        s.backgroundSwapAxes = t.swapAxes
        store.save(s)
        if focus { focusToken += 1 }
    }

    private func removeBackground() {
        if let url = store.backgroundURL(for: survey) {
            try? FileManager.default.removeItem(at: url)
        }
        var s = survey
        s.backgroundFile = nil
        s.backgroundZone = nil
        s.backgroundSwapAxes = nil
        store.save(s)
        background = nil
        dxfData = nil
        transform = nil
    }

    // MARK: Wybór elementu

    private func handlePick(at coordinate: CLLocationCoordinate2D, metersPerPoint: Double) async {
        let tolerance = max(1.0, metersPerPoint * 30)

        // 1) Najbliższy symbol z podkładu DXF.
        if showDXF, let bg = background, let t = transform {
            let grid = PL2000.convert(latitude: coordinate.latitude, longitude: coordinate.longitude, zone: t.zone)
            let cadPoint = t.cad(x2000: grid.x, y2000: grid.y)
            var best: (Double, DXFBackground.Candidate)?
            for c in bg.candidates {
                let d = simd_distance(c.position, cadPoint)
                if d <= tolerance, d < (best?.0 ?? .infinity) { best = (d, c) }
            }
            if let found = best {
                let c = found.1
                let g = t.pl2000(c.position)
                let geo = PL2000.toGeographic(x: g.x, y: g.y, zone: t.zone)
                var infoParts = ["Warstwa: \(c.layer)"]
                if !c.blockName.isEmpty { infoParts.append("Blok: \(c.blockName)") }
                if c.kind == .circle { infoParts.append(String(format: "Okrąg r = %.2f m", c.radius)) }
                if let label = c.label { infoParts.append("Opis: \(label)") }
                infoParts.append(String(format: "X = %.2f  Y = %.2f", g.x, g.y))
                let info = infoParts.joined(separator: "\n")
                pick = MapPick(coordinate: CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude),
                               x2000: g.x, y2000: g.y, zone: t.zone, source: .dxf,
                               title: "Element z DXF" + (c.label.map { ": \($0)" } ?? ""),
                               info: info, label: c.label,
                               suggestedKind: Self.kind(fromDXF: c))
                return
            }
        }

        // 2) Obiekt z GESUT (Geoportal) – opis z GetFeatureInfo, pozycja = miejsce wskazania.
        let grid = PL2000.convert(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if utilities {
            isLoading = true
            let info = await Geoportal.utilityInfo(at: coordinate, radiusMeters: tolerance)
            isLoading = false
            if let info {
                pick = MapPick(coordinate: coordinate, x2000: grid.x, y2000: grid.y, zone: grid.zone,
                               source: .geoportal, title: "Obiekt z Geoportalu (GESUT)",
                               info: info + String(format: "\n\nPozycja wskazania: X = %.2f  Y = %.2f\n(dokładną pozycję ustal w terenie)", grid.x, grid.y),
                               label: nil, suggestedKind: Geoportal.suggestedKind(for: info))
                return
            }
        }

        // 3) Dowolne miejsce na mapie.
        pick = MapPick(coordinate: coordinate, x2000: grid.x, y2000: grid.y, zone: grid.zone,
                       source: .map, title: "Punkt na mapie",
                       info: String(format: "X = %.2f  Y = %.2f (PL-2000, strefa %d)", grid.x, grid.y, grid.zone),
                       label: nil, suggestedKind: .studnia)
    }

    private static func kind(fromDXF c: DXFBackground.Candidate) -> PointKind {
        let text = (c.layer + " " + c.blockName + " " + (c.label ?? "")).lowercased()
        if text.contains("wpust") { return .wpust }
        if text.contains("hydr") { return .hydrant }
        if text.contains("zasuw") { return .zasuwa }
        if text.contains("krat") { return .kratka }
        return .studnia
    }

    private func addPlanned(_ p: MapPick, kind: PointKind) {
        var s = survey
        var number = s.nextNumber(for: kind)
        if let label = p.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty, label.count <= 12,
           !s.points.contains(where: { $0.number == label }) {
            number = label
        }
        var point = SurveyPoint(number: number, kind: kind)
        point.latitude = p.coordinate.latitude
        point.longitude = p.coordinate.longitude
        point.x2000 = p.x2000
        point.y2000 = p.y2000
        point.zone2000 = p.zone
        point.status = .planned
        point.source = p.source
        point.mapInfo = p.info
        s.points.append(point)
        store.save(s)
    }
}

struct IdentifiedID: Identifiable {
    let id: UUID
}
