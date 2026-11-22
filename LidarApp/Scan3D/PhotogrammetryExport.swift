import Foundation
import simd

/// Paczka do obróbki fotogrametrycznej (Agisoft Metashape, RealityCapture, Meshroom).
enum PhotogrammetryExport {

    /// Zapisuje pliki pomocnicze do folderu skanu; zwraca ich adresy.
    static func write(photos: [PhotoRecord], controlPoints: [ControlPoint], geo: GeoReference?,
                      to folder: URL) throws -> [URL] {
        var urls: [URL] = []

        let refURL = folder.appendingPathComponent("metashape_referencje.csv")
        try referenceCSV(photos, geo: geo).write(to: refURL, atomically: true, encoding: .utf8)
        urls.append(refURL)

        let rcURL = folder.appendingPathComponent("realitycapture_flightlog.csv")
        try flightLogCSV(photos, geo: geo).write(to: rcURL, atomically: true, encoding: .utf8)
        urls.append(rcURL)

        if !controlPoints.isEmpty {
            let gcpURL = folder.appendingPathComponent("fotopunkty.csv")
            try controlPointsCSV(controlPoints, geo: geo).write(to: gcpURL, atomically: true, encoding: .utf8)
            urls.append(gcpURL)

            let projURL = folder.appendingPathComponent("fotopunkty_na_zdjeciach.csv")
            try projectionsCSV(photos, controlPoints).write(to: projURL, atomically: true, encoding: .utf8)
            urls.append(projURL)
        }

        let readme = folder.appendingPathComponent("INSTRUKCJA_fotogrametria.txt")
        try instructions(photoCount: photos.count, geo: geo, hasControlPoints: !controlPoints.isEmpty)
            .write(to: readme, atomically: true, encoding: .utf8)
        urls.append(readme)
        return urls
    }

    // MARK: Pozycje kamer

    private static func cameraPosition(_ r: PhotoRecord) -> SIMD3<Float> {
        SIMD3<Float>(r.transform.columns.3.x, r.transform.columns.3.y, r.transform.columns.3.z)
    }

    /// Metashape → Reference → Import: kolumny Label, X(Easting), Y(Northing), Z, Accuracy.
    /// Z georeferencją: pozycje kamer z ARKit w PL-2000 (spójne względem siebie), bez niej – GPS WGS84.
    static func referenceCSV(_ photos: [PhotoRecord], geo: GeoReference?) -> String {
        var lines: [String] = []
        if let geo {
            let accuracy = geo.isFromControlPoints ? max(0.05, geo.rmsHorizontal * 2) : max(2, geo.rmsHorizontal)
            lines.append("# Układ: PL-2000 strefa \(geo.zone) (EPSG:\(geo.epsg)); Easting = Y(2000), Northing = X(2000)")
            lines.append("Label,Easting,Northing,Altitude,Accuracy_m")
            for r in photos {
                let p = geo.cad(cameraPosition(r))
                lines.append(String(format: "%@,%.3f,%.3f,%.3f,%.2f", r.fileName, p.x, p.y, p.z, accuracy))
            }
        } else {
            lines.append("# Układ: WGS84 (EPSG:4326) z GPS telefonu")
            lines.append("Label,Longitude,Latitude,Altitude,Accuracy_m")
            for r in photos {
                guard let loc = r.location else { continue }
                lines.append(String(format: "%@,%.8f,%.8f,%.2f,%.1f", r.fileName,
                                    loc.coordinate.longitude, loc.coordinate.latitude,
                                    loc.altitude, max(loc.horizontalAccuracy, 1)))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// RealityCapture → Import → Flight log: name, lat, lon, alt (WGS84).
    static func flightLogCSV(_ photos: [PhotoRecord], geo: GeoReference?) -> String {
        var lines = ["#name,lat,lon,alt"]
        for r in photos {
            if let geo {
                let p = geo.cad(cameraPosition(r))
                let g = PL2000.toGeographic(x: p.y, y: p.x, zone: geo.zone)
                lines.append(String(format: "%@,%.9f,%.9f,%.3f", r.fileName, g.latitude, g.longitude, p.z))
            } else if let loc = r.location {
                lines.append(String(format: "%@,%.9f,%.9f,%.2f", r.fileName,
                                    loc.coordinate.latitude, loc.coordinate.longitude, loc.altitude))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Fotopunkty

    static func controlPointsCSV(_ points: [ControlPoint], geo: GeoReference?) -> String {
        var lines = ["Nazwa,X2000_RTK,Y2000_RTK,H_RTK,X2000_ze_skanu,Y2000_ze_skanu,H_ze_skanu,odchylka_m"]
        for p in points {
            let rtkX = p.x2000.map { String(format: "%.3f", $0) } ?? ""
            let rtkY = p.y2000.map { String(format: "%.3f", $0) } ?? ""
            let rtkH = p.height.map { String(format: "%.3f", $0) } ?? ""
            var est = ",,,"
            if let geo {
                let c = geo.cad(p.local)
                var residual = ""
                if let x = p.x2000, let y = p.y2000 {
                    residual = String(format: "%.3f", ((c.y - x) * (c.y - x) + (c.x - y) * (c.x - y)).squareRoot())
                }
                est = String(format: "%.3f,%.3f,%.3f,", c.y, c.x, c.z) + residual
            }
            lines.append("\(p.name),\(rtkX),\(rtkY),\(rtkH),\(est)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Gdzie fotopunkt powinien być widoczny na każdym zdjęciu (piksele; z pozycji ARKit – do szybkiego odszukania).
    static func projectionsCSV(_ photos: [PhotoRecord], _ points: [ControlPoint]) -> String {
        var lines = ["Zdjecie,Fotopunkt,x_px,y_px"]
        for r in photos {
            let toCamera = simd_inverse(r.transform)
            let fx = r.intrinsics[0][0]
            let fy = r.intrinsics[1][1]
            let cx = r.intrinsics[2][0]
            let cy = r.intrinsics[2][1]
            for p in points {
                let c = toCamera * SIMD4<Float>(p.local.x, p.local.y, p.local.z, 1)
                let depth = -c.z
                guard depth > 0.1 else { continue }
                let u = c.x * fx / depth + cx
                let v = -c.y * fy / depth + cy
                guard u >= 0, v >= 0, u < Float(r.width), v < Float(r.height) else { continue }
                lines.append(String(format: "%@,%@,%.1f,%.1f", r.fileName, p.name, Double(u), Double(v)))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Instrukcja

    static func instructions(photoCount: Int, geo: GeoReference?, hasControlPoints: Bool) -> String {
        var t = """
        FOTOGRAMETRIA – paczka z LiDAR Skaner
        Zdjęć: \(photoCount) (folder „zdjecia”, JPEG z GPS i ogniskową 35 mm w EXIF)

        """
        if let geo {
            t += "Georeferencja: \(geo.method), PL-2000 strefa \(geo.zone) = EPSG:\(geo.epsg)\n"
        } else {
            t += "Georeferencja: brak – pozycje zdjęć tylko z GPS telefonu (WGS84).\n"
        }
        t += """

        AGISOFT METASHAPE
        1. Workflow → Add Folder… → folder „zdjecia”.
        2. Reference → Import Reference → metashape_referencje.csv
           (Coordinate System: \(geo.map { "EPSG:\($0.epsg)" } ?? "WGS 84"), kolumny: Label, X=Easting, Y=Northing, Z, Accuracy).
        3. Workflow → Align Photos (Accuracy: High, Reference preselection: Source).
        """
        if hasControlPoints {
            t += """

        4. Fotopunkty: Reference → Import → fotopunkty.csv (Nazwa, X=Y2000_RTK, Y=X2000_RTK, Z=H_RTK).
           Ustaw je na zdjęciach (fotopunkty_na_zdjeciach.csv podpowiada, gdzie ich szukać), odznacz kamery w Reference
           i kliknij Optimize Cameras – dokładność centymetrowa zależy od fotopunktów.
        """
        }
        t += """

        5. Build Point Cloud / Build Model / Build Texture → eksport (LAS, E57, OBJ, DXF przekroje).

        REALITYCAPTURE (Windows, karta NVIDIA)
        1. Inputs → folder „zdjecia”.
        2. Import → Flight log → realitycapture_flightlog.csv (WGS84, kolumny name, lat, lon, alt).
        3. Alignment → Align Images → Reconstruction → Normal/High Detail → Texture → Export.
        \(hasControlPoints ? "4. Ground Control: dodaj fotopunkty i ich współrzędne RTK (fotopunkty.csv), oznacz na zdjęciach, Align ponownie.\n" : "")
        MESHROOM (darmowy, Windows + NVIDIA)
        Przeciągnij folder „zdjecia” i kliknij Start. Skalę i położenie nadaj potem w CloudCompare (fotopunkty).

        WSKAZÓWKI
        - Nakładanie zdjęć 70–80%, obiekt z kilku wysokości/kątów; unikaj gładkich, błyszczących i jednolitych powierzchni.
        - Fotopunkty: min. 3–5, rozmieszczone na krańcach obiektu, kontrastowe znaczniki (szachownica A4/A3).
        - Chmura LiDAR (chmura*.ply) i model z fotogrametrii mają ten sam układ – można je łączyć w CloudCompare.
        """
        return t
    }

    // MARK: ZIP

    /// Pakuje folder do ZIP (systemowo, NSFileCoordinator .forUploading).
    static func zip(folder: URL, to zipURL: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading],
                                       error: &coordinatorError) { tempZip in
            do {
                if FileManager.default.fileExists(atPath: zipURL.path) {
                    try FileManager.default.removeItem(at: zipURL)
                }
                try FileManager.default.copyItem(at: tempZip, to: zipURL)
            } catch {
                copyError = error
            }
        }
        if let e = coordinatorError { throw e }
        if let e = copyError { throw e }
    }
}
