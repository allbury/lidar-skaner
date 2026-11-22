import Foundation
import MapKit

/// Warstwy WMS z Geoportalu (GUGiK) – sprawdzone: EPSG:3857, PNG/JPEG 256×256, GetFeatureInfo dla uzbrojenia.
enum GeoportalLayer: String, CaseIterable, Identifiable {
    case ortho, parcels, utilities

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ortho: return "Ortofotomapa"
        case .parcels: return "Działki i budynki (KIEG)"
        case .utilities: return "Uzbrojenie terenu (KIUT / GESUT)"
        }
    }

    var baseURL: String {
        switch self {
        case .ortho: return "https://mapy.geoportal.gov.pl/wss/service/PZGIK/ORTO/WMS/StandardResolution"
        case .parcels: return "https://integracja.gugik.gov.pl/cgi-bin/KrajowaIntegracjaEwidencjiGruntow"
        case .utilities: return "https://integracja.gugik.gov.pl/cgi-bin/KrajowaIntegracjaUzbrojeniaTerenu"
        }
    }

    var wmsLayers: String {
        switch self {
        case .ortho: return "Raster"
        case .parcels: return "dzialki,numery_dzialek,budynki"
        case .utilities:
            return "przewod_wodociagowy,przewod_kanalizacyjny,przewod_cieplowniczy,przewod_gazowy,"
                + "przewod_elektroenergetyczny,przewod_telekomunikacyjny,przewod_specjalny,"
                + "przewod_niezidentyfikowany,przewod_urzadzenia"
        }
    }

    var format: String { self == .ortho ? "image/jpeg" : "image/png" }

    /// Serwisy integracyjne rysują dane dopiero w dużych skalach.
    var minimumZoom: Int {
        switch self {
        case .ortho: return 6
        case .parcels: return 15
        case .utilities: return 16
        }
    }
}

/// Kafelki mapy pobierane z WMS (BBOX w EPSG:3857 wyliczany z numeru kafelka).
final class WMSTileOverlay: MKTileOverlay {
    let layer: GeoportalLayer

    init(layer: GeoportalLayer) {
        self.layer = layer
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        minimumZ = layer.minimumZoom
        maximumZ = 21
    }

    static let worldExtent = 20_037_508.342789244

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let span = 2 * Self.worldExtent / pow(2, Double(path.z))
        let minX = -Self.worldExtent + Double(path.x) * span
        let maxY = Self.worldExtent - Double(path.y) * span
        let bbox = String(format: "%.3f,%.3f,%.3f,%.3f", minX, maxY - span, minX + span, maxY)
        let size = Int(tileSize.width * path.contentScaleFactor)
        return Geoportal.getMapURL(layer: layer, bbox: bbox, width: size, height: size)
    }
}

enum Geoportal {

    static func getMapURL(layer: GeoportalLayer, bbox: String, width: Int, height: Int) -> URL {
        var c = URLComponents(string: layer.baseURL)!
        c.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "REQUEST", value: "GetMap"),
            URLQueryItem(name: "LAYERS", value: layer.wmsLayers),
            URLQueryItem(name: "STYLES", value: ""),
            URLQueryItem(name: "CRS", value: "EPSG:3857"),
            URLQueryItem(name: "BBOX", value: bbox),
            URLQueryItem(name: "WIDTH", value: String(width)),
            URLQueryItem(name: "HEIGHT", value: String(height)),
            URLQueryItem(name: "FORMAT", value: layer.format),
            URLQueryItem(name: "TRANSPARENT", value: layer == .ortho ? "FALSE" : "TRUE")
        ]
        return c.url!
    }

    /// Web Mercator (EPSG:3857) z φ, λ.
    static func mercator(_ coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let r = 6_378_137.0
        let x = r * coordinate.longitude * .pi / 180
        let latRad = coordinate.latitude * .pi / 180
        let y = r * log(tan(.pi / 4 + latRad / 2))
        return (x, y)
    }

    /// Informacja o obiektach uzbrojenia w pobliżu punktu (GetFeatureInfo, tekst bez HTML).
    /// `radiusMeters` – promień wyszukiwania w terenie.
    static func utilityInfo(at coordinate: CLLocationCoordinate2D, radiusMeters: Double) async -> String? {
        let m = mercator(coordinate)
        let half = max(radiusMeters, 1) / cos(coordinate.latitude * .pi / 180)
        let bbox = String(format: "%.3f,%.3f,%.3f,%.3f", m.x - half, m.y - half, m.x + half, m.y + half)
        let layer = GeoportalLayer.utilities
        var c = URLComponents(string: layer.baseURL)!
        c.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "REQUEST", value: "GetFeatureInfo"),
            URLQueryItem(name: "LAYERS", value: layer.wmsLayers),
            URLQueryItem(name: "QUERY_LAYERS", value: layer.wmsLayers),
            URLQueryItem(name: "STYLES", value: ""),
            URLQueryItem(name: "CRS", value: "EPSG:3857"),
            URLQueryItem(name: "BBOX", value: bbox),
            URLQueryItem(name: "WIDTH", value: "101"),
            URLQueryItem(name: "HEIGHT", value: "101"),
            URLQueryItem(name: "I", value: "50"),
            URLQueryItem(name: "J", value: "50"),
            URLQueryItem(name: "INFO_FORMAT", value: "text/html"),
            URLQueryItem(name: "FEATURE_COUNT", value: "5")
        ]
        guard let url = c.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin2)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let features = parseFeatures(html)
        if !features.isEmpty {
            return features.prefix(6).joined(separator: "\n")
        }
        let text = plainText(fromHTML: html)
        return text.isEmpty ? nil : text
    }

    /// Odpowiedź KIUT: <ROW><NAZWA_OBIEKTU>…</NAZWA_OBIEKTU><ETYKIETA>…</ETYKIETA></ROW>.
    /// Zwraca np. „zasuwa lub zawór (w)”; obiekty punktowe przed przewodami.
    static func parseFeatures(_ xml: String) -> [String] {
        let rowPattern = #"<ROW[^>]*>([\s\S]*?)</ROW>"#
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern) else { return [] }
        let ns = xml as NSString
        var points: [String] = []
        var lines: [String] = []
        for match in rowRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let row = ns.substring(with: match.range(at: 1))
            guard let name = tag("NAZWA_OBIEKTU", in: row), !name.isEmpty else { continue }
            let label = tag("ETYKIETA", in: row) ?? ""
            let entry = label.isEmpty ? name : "\(name) (\(label))"
            if name.lowercased().hasPrefix("przewód") {
                if !lines.contains(entry) { lines.append(entry) }
            } else if !points.contains(entry) {
                points.append(entry)
            }
        }
        return points + lines
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainText(fromHTML html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(br|/tr|/p|/div|/li|/h\d)[^>]*>"#, with: "\n",
                                          options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<(td|th)[^>]*>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let lines = s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression) }
            .filter { !$0.isEmpty }
            // Identyfikatory i daty aktualizacji nie są potrzebne w terenie.
            .filter { !$0.hasPrefix("PL.PZGiK") && $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil }
        return lines.prefix(12).joined(separator: "\n")
    }

    /// Rodzaj punktu na podstawie opisu z GESUT.
    static func suggestedKind(for info: String) -> PointKind {
        let t = info.lowercased()
        if t.contains("wpust") { return .wpust }
        if t.contains("hydrant") { return .hydrant }
        if t.contains("zasuw") || t.contains("zawór") { return .zasuwa }
        if t.contains("studz") || t.contains("studni") || t.contains("komora") { return .studnia }
        if t.contains("kratk") || t.contains("odwodn") { return .kratka }
        return .inne
    }
}
