import Foundation

/// Eksport inwentaryzacji:
/// - punkty.csv, rury.csv – Excel PL (średnik, przecinek dziesiętny, UTF-8 z BOM),
/// - inwentaryzacja.dxf – w PL-2000; w CAD: X rysunku = Y(2000) (wschód), Y rysunku = X(2000) (północ), Z = H.
enum InventoryExporter {

    static func export(survey: Survey, photoFolder: URL, to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let pointsURL = folder.appendingPathComponent("punkty.csv")
        try csvData(pointsCSV(survey)).write(to: pointsURL, options: .atomic)

        let pipesURL = folder.appendingPathComponent("rury.csv")
        try csvData(pipesCSV(survey)).write(to: pipesURL, options: .atomic)

        let dxfURL = folder.appendingPathComponent("inwentaryzacja.dxf")
        try dxf(survey).write(to: dxfURL, atomically: true, encoding: .utf8)

        let jsonURL = folder.appendingPathComponent("inwentaryzacja.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(survey).write(to: jsonURL, options: .atomic)

        var urls = [pointsURL, pipesURL, dxfURL, jsonURL]
        for point in survey.points {
            for name in point.photos {
                let src = photoFolder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: src.path) {
                    urls.append(src)
                }
            }
        }
        return urls
    }

    // MARK: CSV

    private static func csvData(_ text: String) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        return data
    }

    private static func dec(_ v: Double?, _ digits: Int) -> String {
        guard let v else { return "" }
        return String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    private static func field(_ s: String) -> String {
        if s.contains(";") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func row(_ values: [String]) -> String {
        values.map(field).joined(separator: ";")
    }

    static func pointsCSV(_ survey: Survey) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var rows: [String] = [row([
            "Nr", "Rodzaj", "X [PL-2000]", "Y [PL-2000]", "Strefa", "H [m]",
            "Szer. geogr.", "Dł. geogr.", "Dokładność GPS [m]", "Próbki GPS",
            "Głębokość [m]", "Wymiar / DN", "Materiał", "Opis", "Zdjęcia", "Data",
            "Status", "Źródło położenia", "Opis z mapy"
        ])]
        for p in survey.points {
            let zone = p.zone2000.map(String.init) ?? ""
            let samples = p.gpsSamples.map(String.init) ?? ""
            let values: [String] = [
                p.number, p.kind.name,
                dec(p.x2000, 3), dec(p.y2000, 3), zone, dec(p.height, 2),
                dec(p.latitude, 8), dec(p.longitude, 8), dec(p.horizontalAccuracy, 1), samples,
                dec(p.depth, 2), p.dimension, p.material, p.note,
                p.photos.joined(separator: ", "), dateFormatter.string(from: p.createdAt),
                p.isPlanned ? "do inwentaryzacji" : "zinwentaryzowany",
                p.source?.name ?? "",
                (p.mapInfo ?? "").replacingOccurrences(of: "\n", with: " | ")
            ]
            rows.append(row(values))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    static func pipesCSV(_ survey: Survey) -> String {
        var rows: [String] = [row(["Od", "Do", "Sieć", "Kod", "Średnica", "Materiał", "Długość 2D [m]", "Opis"])]
        for pipe in survey.pipes {
            let from = survey.point(pipe.fromID)?.number ?? "?"
            let to = survey.point(pipe.toID)?.number ?? "?"
            let values: [String] = [
                from, to, pipe.network.name, pipe.network.code,
                pipe.diameter, pipe.material, dec(survey.length(of: pipe), 2), pipe.note
            ]
            rows.append(row(values))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: DXF

    static func dxf(_ survey: Survey) -> String {
        var doc = DXFDocument()
        let textHeight = 0.4

        for p in survey.points {
            guard let x2000 = p.x2000, let y2000 = p.y2000 else { continue }
            // CAD: X = wschód (Y 2000), Y = północ (X 2000).
            let cx = y2000
            let cy = x2000
            let cz = p.height ?? 0
            // Punkty jeszcze niezinwentaryzowane – osobna warstwa, kolor pomarańczowy.
            let layer = p.isPlanned ? p.kind.dxfLayer + "_DO_INWENT" : p.kind.dxfLayer
            let color = p.isPlanned ? 30 : 7
            doc.point(x: cx, y: cy, z: cz, layer: layer, color: color)
            doc.circle(x: cx, y: cy, z: cz, radius: p.kind.dxfRadius, layer: layer, color: color)
            doc.text(p.number, x: cx + p.kind.dxfRadius + 0.2, y: cy + 0.1, z: cz,
                     height: textHeight, layer: "OPISY_NUMERY", color: 7)
            var details: [String] = []
            if let depth = p.depth { details.append(String(format: "h=%.2f", depth)) }
            if !p.dimension.isEmpty { details.append(p.dimension) }
            if !details.isEmpty {
                doc.text(details.joined(separator: " "), x: cx + p.kind.dxfRadius + 0.2,
                         y: cy - textHeight - 0.1, z: cz,
                         height: textHeight * 0.75, layer: "OPISY_PARAMETRY", color: 8)
            }
        }

        for pipe in survey.pipes {
            guard let a = survey.point(pipe.fromID), let b = survey.point(pipe.toID),
                  let ax = a.y2000, let ay = a.x2000, let bx = b.y2000, let by = b.x2000 else { continue }
            let az = a.height ?? 0
            let bz = b.height ?? 0
            let layer = "SIEC_" + pipe.network.code
            doc.line(ax, ay, az, bx, by, bz, layer: layer, color: pipe.network.dxfColor)

            var label = pipe.network.code
            if !pipe.diameter.isEmpty { label += " " + pipe.diameter }
            if !pipe.material.isEmpty { label += " " + pipe.material }
            if let length = survey.length(of: pipe) { label += String(format: " L=%.2f", length) }

            let midX = (ax + bx) / 2
            let midY = (ay + by) / 2
            var angle = atan2(by - ay, bx - ax) * 180 / .pi
            if angle > 90 { angle -= 180 }
            if angle < -90 { angle += 180 }
            doc.text(label, x: midX, y: midY + 0.15, height: textHeight * 0.75,
                     rotation: angle, layer: layer + "_OPIS", color: pipe.network.dxfColor)
        }
        return doc.build()
    }
}
