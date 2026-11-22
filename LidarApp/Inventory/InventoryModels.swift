import Foundation

enum PointKind: String, Codable, CaseIterable, Identifiable {
    case studnia, wpust, zasuwa, hydrant, kratka, trojnik, zalamanie, punktTrasy, inne

    var id: String { rawValue }

    var name: String {
        switch self {
        case .studnia: return "Studnia"
        case .wpust: return "Wpust uliczny"
        case .zasuwa: return "Zasuwa"
        case .hydrant: return "Hydrant"
        case .kratka: return "Kratka / odwodnienie"
        case .trojnik: return "Trójnik / odgałęzienie"
        case .zalamanie: return "Załamanie trasy"
        case .punktTrasy: return "Punkt trasy"
        case .inne: return "Inny"
        }
    }

    var prefix: String {
        switch self {
        case .studnia: return "S"
        case .wpust: return "W"
        case .zasuwa: return "Z"
        case .hydrant: return "H"
        case .kratka: return "K"
        case .trojnik: return "T"
        case .zalamanie: return "L"
        case .punktTrasy: return "P"
        case .inne: return "X"
        }
    }

    var symbol: String {
        switch self {
        case .studnia: return "circle.circle"
        case .wpust: return "square.grid.2x2"
        case .zasuwa: return "xmark.square"
        case .hydrant: return "drop.fill"
        case .kratka: return "line.3.horizontal"
        case .trojnik: return "arrow.triangle.branch"
        case .zalamanie: return "arrow.turn.up.right"
        case .punktTrasy: return "smallcircle.filled.circle"
        case .inne: return "mappin"
        }
    }

    var dxfLayer: String {
        switch self {
        case .studnia: return "STUDNIE"
        case .wpust: return "WPUSTY"
        case .zasuwa: return "ZASUWY"
        case .hydrant: return "HYDRANTY"
        case .kratka: return "KRATKI"
        case .trojnik: return "TROJNIKI"
        case .zalamanie: return "ZALAMANIA"
        case .punktTrasy: return "PUNKTY_TRASY"
        case .inne: return "INNE"
        }
    }

    /// Promień symbolu w DXF [m].
    var dxfRadius: Double {
        switch self {
        case .studnia: return 0.5
        case .wpust, .kratka: return 0.3
        default: return 0.2
        }
    }
}

enum NetworkKind: String, Codable, CaseIterable, Identifiable {
    case sanitarna, deszczowa, ogolnosplawna, wodociag, gaz, cieplownicza, teletechnika, energetyka, inna

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sanitarna: return "Kanalizacja sanitarna"
        case .deszczowa: return "Kanalizacja deszczowa"
        case .ogolnosplawna: return "Kanalizacja ogólnospławna"
        case .wodociag: return "Wodociąg"
        case .gaz: return "Gazociąg"
        case .cieplownicza: return "Sieć ciepłownicza"
        case .teletechnika: return "Teletechnika"
        case .energetyka: return "Energetyka"
        case .inna: return "Inna"
        }
    }

    var code: String {
        switch self {
        case .sanitarna: return "KS"
        case .deszczowa: return "KD"
        case .ogolnosplawna: return "KO"
        case .wodociag: return "W"
        case .gaz: return "G"
        case .cieplownicza: return "C"
        case .teletechnika: return "T"
        case .energetyka: return "E"
        case .inna: return "INNA"
        }
    }

    /// Kolory ACI zbliżone do kolorystyki GESUT.
    var dxfColor: Int {
        switch self {
        case .sanitarna: return 32
        case .deszczowa: return 34
        case .ogolnosplawna: return 36
        case .wodociag: return 5
        case .gaz: return 2
        case .cieplownicza: return 6
        case .teletechnika: return 30
        case .energetyka: return 1
        case .inna: return 3
        }
    }
}

enum PointStatus: String, Codable {
    /// Wskazany na mapie – do zinwentaryzowania w terenie.
    case planned
    /// Zinwentaryzowany.
    case done
}

enum CoordinateSource: String, Codable {
    case gps, dxf, geoportal, map, manual

    var name: String {
        switch self {
        case .gps: return "GPS"
        case .dxf: return "podkład DXF"
        case .geoportal: return "Geoportal (GESUT)"
        case .map: return "wskazanie na mapie"
        case .manual: return "wpisane ręcznie"
        }
    }
}

struct SurveyPoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var number: String
    var kind: PointKind
    var latitude: Double?
    var longitude: Double?
    /// Wysokość nad poziomem morza z GPS telefonu (orientacyjna) lub wpisana ręcznie.
    var height: Double?
    var horizontalAccuracy: Double?
    var gpsSamples: Int?
    var x2000: Double?
    var y2000: Double?
    var zone2000: Int?
    /// Głębokość (np. studni od włazu do dna) [m].
    var depth: Double?
    var dimension: String = ""
    var material: String = ""
    var note: String = ""
    var photos: [String] = []
    var createdAt = Date()
    // Pola dodane później – opcjonalne, żeby starsze pliki JSON nadal się wczytywały.
    var status: PointStatus?
    var source: CoordinateSource?
    /// Opis z mapy (np. informacja z GESUT, warstwa/blok z DXF).
    var mapInfo: String?

    var hasCoordinates: Bool { x2000 != nil && y2000 != nil }
    var isPlanned: Bool { status == .planned }

    /// Pozycja geograficzna: z GPS, a gdy jej brak – przeliczona z PL-2000.
    var coordinate: (latitude: Double, longitude: Double)? {
        if let latitude, let longitude { return (latitude, longitude) }
        guard let x = x2000, let y = y2000,
              let zone = zone2000 ?? PL2000.zone(forEasting: y) else { return nil }
        return PL2000.toGeographic(x: x, y: y, zone: zone)
    }
}

struct PipeSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    var fromID: UUID
    var toID: UUID
    var network: NetworkKind
    var diameter: String = ""
    var material: String = ""
    var note: String = ""
}

struct Survey: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var points: [SurveyPoint] = []
    var pipes: [PipeSegment] = []
    /// Podkład DXF (nazwa pliku w folderze inwentaryzacji) i sposób odczytu współrzędnych.
    var backgroundFile: String?
    var backgroundSwapAxes: Bool?
    var backgroundZone: Int?

    func point(_ id: UUID) -> SurveyPoint? {
        points.first { $0.id == id }
    }

    func nextNumber(for kind: PointKind) -> String {
        let used = Set(points.map(\.number))
        var n = points.filter { $0.kind == kind }.count + 1
        while used.contains("\(kind.prefix)\(n)") { n += 1 }
        return "\(kind.prefix)\(n)"
    }

    /// Długość odcinka w płaszczyźnie PL-2000 [m].
    func length(of pipe: PipeSegment) -> Double? {
        guard let a = point(pipe.fromID), let b = point(pipe.toID),
              let ax = a.x2000, let ay = a.y2000, let bx = b.x2000, let by = b.y2000 else { return nil }
        let dx = bx - ax
        let dy = by - ay
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Zapis inwentaryzacji jako JSON w Dokumenty/Inwentaryzacje.
@MainActor
final class SurveyStore: ObservableObject {
    @Published private(set) var surveys: [Survey] = []

    let folder: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Inwentaryzacje", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [Survey] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let survey = try? Self.decoder.decode(Survey.self, from: data) {
                result.append(survey)
            }
        }
        surveys = result.sorted { $0.createdAt > $1.createdAt }
    }

    func survey(_ id: UUID) -> Survey? {
        surveys.first { $0.id == id }
    }

    func fileURL(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    func photoFolder(for id: UUID) -> URL {
        let url = folder.appendingPathComponent("\(id.uuidString)_zdjecia", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func backgroundURL(for survey: Survey) -> URL? {
        survey.backgroundFile.map { folder.appendingPathComponent($0) }
    }

    /// Kopiuje wybrany plik DXF do folderu inwentaryzacji i zwraca jego nazwę.
    func importBackground(from source: URL, for surveyID: UUID) throws -> String {
        let name = "\(surveyID.uuidString)_podklad.dxf"
        let target = folder.appendingPathComponent(name)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
        return name
    }

    @discardableResult
    func create(name: String) -> Survey {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let survey = Survey(name: trimmed.isEmpty ? "Inwentaryzacja" : trimmed)
        save(survey)
        return survey
    }

    func save(_ survey: Survey) {
        if let data = try? Self.encoder.encode(survey) {
            try? data.write(to: fileURL(for: survey.id), options: .atomic)
        }
        if let index = surveys.firstIndex(where: { $0.id == survey.id }) {
            surveys[index] = survey
        } else {
            surveys.insert(survey, at: 0)
        }
    }

    func delete(_ survey: Survey) {
        try? FileManager.default.removeItem(at: fileURL(for: survey.id))
        let photos = folder.appendingPathComponent("\(survey.id.uuidString)_zdjecia", isDirectory: true)
        try? FileManager.default.removeItem(at: photos)
        if let background = backgroundURL(for: survey) {
            try? FileManager.default.removeItem(at: background)
        }
        surveys.removeAll { $0.id == survey.id }
    }
}
