import Foundation
import simd

/// Fotopunkt (punkt kontrolny): znacznik w terenie wskazany w AR, opcjonalnie ze współrzędnymi z GNSS RTK.
struct ControlPoint: Identifiable, Equatable {
    let id = UUID()
    var name: String
    /// Pozycja w układzie ARKit (metry).
    var local: SIMD3<Float>
    /// PL-2000 z pomiaru RTK: X = północ, Y = wschód, H = wysokość.
    var x2000: Double?
    var y2000: Double?
    var height: Double?

    var isSurveyed: Bool { x2000 != nil && y2000 != nil }
}

extension GeoReference {

    /// Georeferencja z fotopunktów RTK:
    /// - ≥ 2 fotopunkty: obrót + przesunięcie dopasowane metodą najmniejszych kwadratów (kompas niepotrzebny),
    /// - 1 fotopunkt: przesunięcie, obrót z kompasu (tylko gdy skan był w orientacji wg kompasu).
    /// Skala = skala odwzorowania PL-2000 w miejscu skanu (ARKit mierzy w metrach terenowych).
    static func fromControlPoints(_ points: [ControlPoint], headingAligned: Bool) -> GeoReference? {
        let surveyed = points.filter(\.isSurveyed)
        guard let first = surveyed.first, let firstY = first.y2000,
              let zone = PL2000.zone(forEasting: firstY) else { return nil }
        if surveyed.count == 1 && !headingAligned { return nil }

        let meanE = surveyed.compactMap(\.y2000).reduce(0, +) / Double(surveyed.count)
        let dy = meanE - Double(zone) * 1_000_000 - 500_000
        let earthRadius = 6_381_000.0
        let scale = 0.999923 * (1 + (dy * dy) / (2 * earthRadius * earthRadius))

        var gamma: Double
        if surveyed.count >= 2 {
            // Współrzędne lokalne (wschód = x, północ = −z) w skali siatki.
            let local = surveyed.map { SIMD2<Double>(Double($0.local.x) * scale, Double(-$0.local.z) * scale) }
            let grid = surveyed.map { SIMD2<Double>($0.y2000 ?? 0, $0.x2000 ?? 0) }
            let n = Double(surveyed.count)
            let cl = local.reduce(SIMD2<Double>(0, 0), +) / n
            let cg = grid.reduce(SIMD2<Double>(0, 0), +) / n
            var num = 0.0
            var den = 0.0
            for i in local.indices {
                let a = local[i] - cl
                let b = grid[i] - cg
                num += a.x * b.y - a.y * b.x
                den += a.x * b.x + a.y * b.y
            }
            gamma = atan2(num, den)
        } else {
            // Orientacja z kompasu: oś −Z ARKit = północ geograficzna → obrót o zbieżność południków.
            let x = first.x2000 ?? 0
            let geo = PL2000.toGeographic(x: x, y: firstY, zone: zone)
            gamma = (geo.longitude - Double(zone * 3)) * .pi / 180 * sin(geo.latitude * .pi / 180)
        }

        var sumE = 0.0
        var sumN = 0.0
        for p in surveyed {
            let r = rotate(p.local, gamma: gamma, scale: scale)
            sumE += (p.y2000 ?? 0) - r.east
            sumN += (p.x2000 ?? 0) - r.north
        }
        let e0 = sumE / Double(surveyed.count)
        let n0 = sumN / Double(surveyed.count)

        var sq = 0.0
        for p in surveyed {
            let r = rotate(p.local, gamma: gamma, scale: scale)
            let de = (p.y2000 ?? 0) - (e0 + r.east)
            let dn = (p.x2000 ?? 0) - (n0 + r.north)
            sq += de * de + dn * dn
        }
        let rms = (sq / Double(surveyed.count)).squareRoot()

        let withHeight = surveyed.filter { $0.height != nil }
        var h0: Double?
        if !withHeight.isEmpty {
            let s = withHeight.reduce(0.0) { $0 + ($1.height ?? 0) - Double($1.local.y) }
            h0 = s / Double(withHeight.count)
        }

        let method = surveyed.count >= 2
            ? "fotopunkty RTK (\(surveyed.count) szt.) – obrót i przesunięcie dopasowane"
            : "1 fotopunkt RTK + kompas (obrót z kompasu)"
        return GeoReference(zone: zone, gamma: gamma, scale: scale, east0: e0, north0: n0,
                            height0: h0, sampleCount: surveyed.count, rmsHorizontal: rms, method: method)
    }
}
