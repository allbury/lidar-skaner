import Foundation
import CoreLocation
import simd

/// Podkład DXF (np. mapa zasadnicza / GESUT) wczytany do wyboru elementów do inwentaryzacji.
/// Obsługiwane encje (DXF tekstowy, dowolna wersja): LINE, LWPOLYLINE, POLYLINE/VERTEX, CIRCLE, ARC,
/// POINT, INSERT (bloki – np. symbole studni), TEXT, MTEXT. Współrzędne w CAD jak w pliku.
struct DXFBackground {

    struct Polyline {
        var layer: String
        var color: Int
        var points: [SIMD2<Double>]
    }

    enum CandidateKind: String {
        case circle, block, point

        var name: String {
            switch self {
            case .circle: return "okrąg"
            case .block: return "blok"
            case .point: return "punkt"
            }
        }
    }

    /// Element, który można wskazać jako obiekt do inwentaryzacji (okrąg, blok, punkt).
    struct Candidate {
        var kind: CandidateKind
        var layer: String
        var blockName: String
        var radius: Double
        var position: SIMD2<Double>
        var label: String?
    }

    struct Label {
        var layer: String
        var position: SIMD2<Double>
        var text: String
    }

    var polylines: [Polyline] = []
    var candidates: [Candidate] = []
    var labels: [Label] = []
    var layerColors: [String: Int] = [:]

    var isEmpty: Bool { polylines.isEmpty && candidates.isEmpty }

    var layers: [String] {
        var set = Set<String>()
        for p in polylines { set.insert(p.layer) }
        for c in candidates { set.insert(c.layer) }
        return set.sorted()
    }

    // MARK: Odczyt

    enum ImportError: LocalizedError {
        case unreadable, binary, noEntities
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Nie udało się odczytać pliku."
            case .binary: return "Binarny DXF nie jest obsługiwany – zapisz rysunek jako DXF tekstowy (ASCII)."
            case .noEntities: return "W pliku nie znaleziono obsługiwanych elementów (linie, polilinie, okręgi, bloki)."
            }
        }
    }

    static func load(from url: URL) throws -> DXFBackground {
        let data = try Data(contentsOf: url)
        if data.starts(with: Array("AutoCAD Binary DXF".utf8)) { throw ImportError.binary }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1250)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable
        }
        var result = parse(text)
        guard !result.isEmpty else { throw ImportError.noEntities }
        result.attachLabels()
        return result
    }

    private static func parse(_ text: String) -> DXFBackground {
        var result = DXFBackground()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })

        var section = ""
        var entityType = ""
        var entity: [(Int, String)] = []
        var openPolyline: Polyline?
        var openPolylineClosed = false

        func finishEntity() {
            guard !entityType.isEmpty else { return }
            if section == "TABLES" {
                if entityType == "LAYER" {
                    let name = value(entity, 2) ?? ""
                    let color = abs(Int(value(entity, 62) ?? "") ?? 7)
                    if !name.isEmpty { result.layerColors[name] = color }
                }
            } else if section == "ENTITIES" {
                handle(entityType, entity, into: &result,
                       openPolyline: &openPolyline, openPolylineClosed: &openPolylineClosed)
            }
        }

        var i = 0
        while i + 1 < lines.count {
            let code = Int(lines[i].trimmingCharacters(in: .whitespaces)) ?? -1
            let val = String(lines[i + 1]).trimmingCharacters(in: .whitespaces)
            i += 2

            if code == 0 {
                finishEntity()
                entity.removeAll(keepingCapacity: true)
                entityType = val
                if val == "SECTION" {
                    section = ""
                } else if val == "ENDSEC" {
                    section = ""
                    entityType = ""
                } else if val == "EOF" {
                    break
                }
                continue
            }
            if entityType == "SECTION" && code == 2 {
                section = val
                entityType = ""
                continue
            }
            entity.append((code, val))
        }
        finishEntity()
        return result
    }

    private static func value(_ entity: [(Int, String)], _ code: Int) -> String? {
        entity.first { $0.0 == code }?.1
    }

    private static func double(_ entity: [(Int, String)], _ code: Int) -> Double? {
        value(entity, code).flatMap { Double($0) }
    }

    private static func handle(_ type: String, _ e: [(Int, String)], into result: inout DXFBackground,
                               openPolyline: inout Polyline?, openPolylineClosed: inout Bool) {
        let layer = value(e, 8) ?? "0"
        let colorCode = Int(value(e, 62) ?? "") ?? 256
        let color = (colorCode == 256 || colorCode == 0) ? (result.layerColors[layer] ?? 7) : abs(colorCode)

        switch type {
        case "LINE":
            if let x1 = double(e, 10), let y1 = double(e, 20), let x2 = double(e, 11), let y2 = double(e, 21) {
                result.polylines.append(Polyline(layer: layer, color: color,
                                                 points: [SIMD2(x1, y1), SIMD2(x2, y2)]))
            }

        case "LWPOLYLINE":
            var points: [SIMD2<Double>] = []
            var pendingX: Double?
            for (code, v) in e {
                if code == 10 {
                    pendingX = Double(v)
                } else if code == 20, let x = pendingX, let y = Double(v) {
                    points.append(SIMD2(x, y))
                    pendingX = nil
                }
            }
            let flags = Int(value(e, 70) ?? "0") ?? 0
            if flags & 1 == 1, let first = points.first { points.append(first) }
            if points.count >= 2 {
                result.polylines.append(Polyline(layer: layer, color: color, points: points))
            }

        case "POLYLINE":
            openPolyline = Polyline(layer: layer, color: color, points: [])
            openPolylineClosed = (Int(value(e, 70) ?? "0") ?? 0) & 1 == 1

        case "VERTEX":
            if openPolyline != nil, let x = double(e, 10), let y = double(e, 20) {
                openPolyline?.points.append(SIMD2(x, y))
            }

        case "SEQEND":
            if var poly = openPolyline {
                if openPolylineClosed, let first = poly.points.first { poly.points.append(first) }
                if poly.points.count >= 2 { result.polylines.append(poly) }
            }
            openPolyline = nil

        case "CIRCLE":
            if let cx = double(e, 10), let cy = double(e, 20), let r = double(e, 40), r > 0 {
                result.polylines.append(Polyline(layer: layer, color: color,
                                                 points: arc(cx, cy, r, 0, 360)))
                if r <= 3 {
                    result.candidates.append(Candidate(kind: .circle, layer: layer, blockName: "",
                                                       radius: r, position: SIMD2(cx, cy)))
                }
            }

        case "ARC":
            if let cx = double(e, 10), let cy = double(e, 20), let r = double(e, 40), r > 0 {
                let start = double(e, 50) ?? 0
                var end = double(e, 51) ?? 360
                if end <= start { end += 360 }
                result.polylines.append(Polyline(layer: layer, color: color,
                                                 points: arc(cx, cy, r, start, end)))
            }

        case "POINT":
            if let x = double(e, 10), let y = double(e, 20) {
                result.candidates.append(Candidate(kind: .point, layer: layer, blockName: "",
                                                   radius: 0, position: SIMD2(x, y)))
            }

        case "INSERT":
            if let x = double(e, 10), let y = double(e, 20) {
                let name = value(e, 2) ?? ""
                result.candidates.append(Candidate(kind: .block, layer: layer, blockName: name,
                                                   radius: 0, position: SIMD2(x, y)))
            }

        case "TEXT", "MTEXT":
            if let x = double(e, 10), let y = double(e, 20) {
                var parts = e.filter { $0.0 == 3 }.map(\.1)
                if let main = value(e, 1) { parts.append(main) }
                let text = cleanText(parts.joined())
                if !text.isEmpty {
                    result.labels.append(Label(layer: layer, position: SIMD2(x, y), text: text))
                }
            }

        default:
            break
        }
    }

    private static func arc(_ cx: Double, _ cy: Double, _ r: Double, _ startDeg: Double, _ endDeg: Double) -> [SIMD2<Double>] {
        let span = endDeg - startDeg
        let segments = max(8, min(48, Int(span / 360 * 32)))
        var pts: [SIMD2<Double>] = []
        pts.reserveCapacity(segments + 1)
        for k in 0...segments {
            let a = (startDeg + span * Double(k) / Double(segments)) * .pi / 180
            pts.append(SIMD2(cx + r * cos(a), cy + r * sin(a)))
        }
        return pts
    }

    /// Usuwa formatowanie MTEXT ({\fArial;…}, \P) i zamienia kody \U+XXXX na znaki.
    static func cleanText(_ raw: String) -> String {
        var s = raw
        while let range = s.range(of: #"\\U\+[0-9A-Fa-f]{4}"#, options: .regularExpression) {
            let hex = String(s[range].dropFirst(3))
            let ch = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            s.replaceSubrange(range, with: ch)
        }
        s = s.replacingOccurrences(of: #"\\[PpNn]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\[A-Za-z][^;\\{}]*;"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        s = s.replacingOccurrences(of: "%%c", with: "Ø").replacingOccurrences(of: "%%C", with: "Ø")
        s = s.replacingOccurrences(of: "%%d", with: "°").replacingOccurrences(of: "%%p", with: "±")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Przypisuje kandydatom najbliższy tekst (do 3 m) – np. numer studni.
    private mutating func attachLabels() {
        guard !labels.isEmpty, !candidates.isEmpty else { return }
        let cell = 5.0
        var grid: [SIMD2<Int>: [Int]] = [:]
        for (i, label) in labels.enumerated() {
            let key = SIMD2<Int>(Int((label.position.x / cell).rounded(.down)),
                                 Int((label.position.y / cell).rounded(.down)))
            grid[key, default: []].append(i)
        }
        for ci in candidates.indices {
            let p = candidates[ci].position
            let kx = Int((p.x / cell).rounded(.down))
            let ky = Int((p.y / cell).rounded(.down))
            var best: (Double, String)?
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let ids = grid[SIMD2(kx + dx, ky + dy)] else { continue }
                    for id in ids {
                        let d = simd_distance(labels[id].position, p)
                        if d <= 3, d < (best?.0 ?? .infinity) {
                            best = (d, labels[id].text)
                        }
                    }
                }
            }
            candidates[ci].label = best?.1
        }
    }
}

/// Jak interpretować współrzędne CAD z DXF.
struct DXFGeoTransform: Equatable {
    /// false: X rysunku = Y 2000 (wschód), Y rysunku = X 2000 (północ) – standard w CAD.
    var swapAxes: Bool
    var zone: Int

    /// PL-2000 (X północ, Y wschód) z punktu CAD.
    func pl2000(_ p: SIMD2<Double>) -> (x: Double, y: Double) {
        swapAxes ? (p.x, p.y) : (p.y, p.x)
    }

    func cad(x2000: Double, y2000: Double) -> SIMD2<Double> {
        swapAxes ? SIMD2(x2000, y2000) : SIMD2(y2000, x2000)
    }

    func coordinate(_ p: SIMD2<Double>) -> CLLocationCoordinate2D {
        let g = pl2000(p)
        let geo = PL2000.toGeographic(x: g.x, y: g.y, zone: zone)
        return CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
    }

    /// Zgaduje układ osi i strefę z mediany współrzędnych. Nil, gdy dane nie wyglądają na PL-2000.
    static func guess(for background: DXFBackground) -> DXFGeoTransform? {
        var xs: [Double] = []
        var ys: [Double] = []
        for c in background.candidates.prefix(2000) {
            xs.append(c.position.x)
            ys.append(c.position.y)
        }
        for p in background.polylines.prefix(2000) {
            if let first = p.points.first {
                xs.append(first.x)
                ys.append(first.y)
            }
        }
        guard !xs.isEmpty else { return nil }
        let mx = xs.sorted()[xs.count / 2]
        let my = ys.sorted()[ys.count / 2]
        let northRange = 5_400_000.0...6_100_000.0
        if let z = PL2000.zone(forEasting: mx), northRange.contains(my) {
            return DXFGeoTransform(swapAxes: false, zone: z)
        }
        if let z = PL2000.zone(forEasting: my), northRange.contains(mx) {
            return DXFGeoTransform(swapAxes: true, zone: z)
        }
        return nil
    }
}
