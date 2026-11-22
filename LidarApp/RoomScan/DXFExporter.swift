import Foundation
import RoomPlan
import simd

/// Rzut pomieszczenia do DXF. Jednostki: metry. Widok z góry: oś X = X świata, oś Y = −Z świata.
enum DXFExporter {

    static func floorPlan(for room: CapturedRoom) -> String {
        var doc = DXFDocument()

        for wall in room.walls {
            let (a, b) = endpoints(wall)
            doc.line(a.x, a.y, 0, b.x, b.y, 0, layer: "SCIANY", color: 7)
            addLengthLabel(&doc, a: a, b: b, length: Double(wall.dimensions.x))
        }
        for door in room.doors {
            let (a, b) = endpoints(door)
            doc.line(a.x, a.y, 0, b.x, b.y, 0, layer: "DRZWI", color: 3)
        }
        for window in room.windows {
            let (a, b) = endpoints(window)
            doc.line(a.x, a.y, 0, b.x, b.y, 0, layer: "OKNA", color: 5)
        }
        for opening in room.openings {
            let (a, b) = endpoints(opening)
            doc.line(a.x, a.y, 0, b.x, b.y, 0, layer: "OTWORY", color: 4)
        }
        for object in room.objects {
            addFootprint(&doc, transform: object.transform, dimensions: object.dimensions,
                         label: String(describing: object.category))
        }
        return doc.build()
    }

    // MARK: Geometria

    private static func plan(_ p: SIMD3<Float>) -> SIMD2<Double> {
        SIMD2<Double>(Double(p.x), Double(-p.z))
    }

    private static func position(_ t: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    private static func axis(_ c: SIMD4<Float>) -> SIMD3<Float> {
        simd_normalize(SIMD3<Float>(c.x, c.y, c.z))
    }

    private static func endpoints(_ s: CapturedRoom.Surface) -> (SIMD2<Double>, SIMD2<Double>) {
        let center = position(s.transform)
        let dirX = axis(s.transform.columns.0)
        let half: Float = s.dimensions.x / 2
        let p1: SIMD3<Float> = center - dirX * half
        let p2: SIMD3<Float> = center + dirX * half
        return (plan(p1), plan(p2))
    }

    private static func addLengthLabel(_ doc: inout DXFDocument, a: SIMD2<Double>, b: SIMD2<Double>, length: Double) {
        let mid: SIMD2<Double> = (a + b) / 2
        let d: SIMD2<Double> = b - a
        var angle: Double = atan2(d.y, d.x) * 180 / .pi
        if angle > 90 { angle -= 180 }
        if angle < -90 { angle += 180 }
        doc.text(String(format: "%.2f", length), x: mid.x, y: mid.y,
                 height: 0.08, rotation: angle, layer: "WYMIARY", color: 2)
    }

    private static func addFootprint(_ doc: inout DXFDocument, transform: simd_float4x4,
                                     dimensions: SIMD3<Float>, label: String) {
        let c = position(transform)
        let ax: SIMD3<Float> = axis(transform.columns.0) * (dimensions.x / 2)
        let az: SIMD3<Float> = axis(transform.columns.2) * (dimensions.z / 2)
        let p1: SIMD3<Float> = c - ax - az
        let p2: SIMD3<Float> = c + ax - az
        let p3: SIMD3<Float> = c + ax + az
        let p4: SIMD3<Float> = c - ax + az
        let corners: [SIMD2<Double>] = [plan(p1), plan(p2), plan(p3), plan(p4)]
        for i in 0..<4 {
            let a = corners[i]
            let b = corners[(i + 1) % 4]
            doc.line(a.x, a.y, 0, b.x, b.y, 0, layer: "OBIEKTY", color: 1)
        }
        let center = plan(c)
        doc.text(label, x: center.x, y: center.y, height: 0.06, layer: "OBIEKTY", color: 1)
    }
}
