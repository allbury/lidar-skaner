import Foundation
import RoomPlan
import simd

/// Prosty eksport rzutu pomieszczenia do DXF (format R12 / AC1009 – czyta go praktycznie każdy CAD).
/// Jednostki: metry ($INSUNITS = 6). Układ: widok z góry, oś X = X świata, oś Y = −Z świata.
enum DXFExporter {

    static func floorPlan(for room: CapturedRoom) -> String {
        var dxf = DXFWriter()

        for wall in room.walls {
            dxf.addSurfaceLine(wall, layer: "SCIANY", color: 7)
            dxf.addLengthLabel(wall, layer: "WYMIARY")
        }
        for door in room.doors {
            dxf.addSurfaceLine(door, layer: "DRZWI", color: 3)
        }
        for window in room.windows {
            dxf.addSurfaceLine(window, layer: "OKNA", color: 5)
        }
        for opening in room.openings {
            dxf.addSurfaceLine(opening, layer: "OTWORY", color: 4)
        }
        for object in room.objects {
            dxf.addFootprint(transform: object.transform,
                             dimensions: object.dimensions,
                             label: String(describing: object.category),
                             layer: "OBIEKTY",
                             color: 1)
        }
        return dxf.finish()
    }
}

private struct DXFWriter {
    private var entities: [String] = []

    // MARK: Geometria

    /// Rzut punktu świata (ARKit: Y w górę) na płaszczyznę rysunku.
    private func plan(_ p: SIMD3<Float>) -> SIMD2<Double> {
        SIMD2(Double(p.x), Double(-p.z))
    }

    private func position(_ t: simd_float4x4) -> SIMD3<Float> {
        SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    private func axis(_ c: SIMD4<Float>) -> SIMD3<Float> {
        simd_normalize(SIMD3(c.x, c.y, c.z))
    }

    private func endpoints(_ s: CapturedRoom.Surface) -> (SIMD2<Double>, SIMD2<Double>) {
        let center = position(s.transform)
        let dirX = axis(s.transform.columns.0)
        let half = s.dimensions.x / 2
        return (plan(center - dirX * half), plan(center + dirX * half))
    }

    // MARK: Elementy

    mutating func addSurfaceLine(_ s: CapturedRoom.Surface, layer: String, color: Int) {
        let (a, b) = endpoints(s)
        addLine(a, b, layer: layer, color: color)
    }

    mutating func addLengthLabel(_ s: CapturedRoom.Surface, layer: String) {
        let (a, b) = endpoints(s)
        let mid = (a + b) / 2
        let d = b - a
        var angle = atan2(d.y, d.x) * 180 / .pi
        if angle > 90 { angle -= 180 }
        if angle < -90 { angle += 180 }
        let text = String(format: "%.2f", Double(s.dimensions.x))
        addText(text, at: mid, height: 0.08, rotation: angle, layer: layer, color: 2)
    }

    mutating func addFootprint(transform: simd_float4x4, dimensions: SIMD3<Float>, label: String, layer: String, color: Int) {
        let c = position(transform)
        let ax = axis(transform.columns.0) * (dimensions.x / 2)
        let az = axis(transform.columns.2) * (dimensions.z / 2)
        let p1: SIMD3<Float> = c - ax - az
        let p2: SIMD3<Float> = c + ax - az
        let p3: SIMD3<Float> = c + ax + az
        let p4: SIMD3<Float> = c - ax + az
        let corners: [SIMD2<Double>] = [plan(p1), plan(p2), plan(p3), plan(p4)]
        for i in 0..<4 {
            addLine(corners[i], corners[(i + 1) % 4], layer: layer, color: color)
        }
        addText(label, at: plan(c), height: 0.06, rotation: 0, layer: layer, color: color)
    }

    // MARK: Encje DXF

    private func num(_ v: Double) -> String { String(format: "%.4f", v) }

    private mutating func addLine(_ a: SIMD2<Double>, _ b: SIMD2<Double>, layer: String, color: Int) {
        entities.append("""
        0
        LINE
        8
        \(layer)
        62
        \(color)
        10
        \(num(a.x))
        20
        \(num(a.y))
        30
        0.0
        11
        \(num(b.x))
        21
        \(num(b.y))
        31
        0.0
        """)
    }

    private mutating func addText(_ text: String, at p: SIMD2<Double>, height: Double, rotation: Double, layer: String, color: Int) {
        // Tekst ASCII – bez polskich znaków, żeby uniknąć problemów z kodowaniem w starszych CAD-ach.
        let safe = text.unicodeScalars.filter { $0.isASCII }.map(String.init).joined()
        entities.append("""
        0
        TEXT
        8
        \(layer)
        62
        \(color)
        10
        \(num(p.x))
        20
        \(num(p.y))
        30
        0.0
        40
        \(num(height))
        1
        \(safe)
        50
        \(num(rotation))
        """)
    }

    func finish() -> String {
        let header = """
        0
        SECTION
        2
        HEADER
        9
        $ACADVER
        1
        AC1009
        9
        $INSUNITS
        70
        6
        0
        ENDSEC
        0
        SECTION
        2
        ENTITIES
        """
        let footer = """
        0
        ENDSEC
        0
        EOF
        """
        return ([header] + entities + [footer]).joined(separator: "\n") + "\n"
    }
}
