import Foundation
import simd

/// Para: pozycja GPS telefonu ↔ pozycja kamery w układzie ARKit w tej samej chwili.
struct GeoSample {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double
    let verticalAccuracy: Double?
    let local: SIMD3<Float>
}

/// Georeferencja skanu: ARKit w trybie .gravityAndHeading (X = wschód, Y = góra, −Z = północ geograficzna, wg kompasu)
/// + przesunięcie do PL-2000 wyznaczone z wielu próbek GPS (średnia ważona 1/σ²).
/// Uwzględnia zbieżność południków γ = Δλ·sin φ i skalę odwzorowania w miejscu skanu.
/// Dokładność: położenie ≈ dokładność uśrednionego GPS (zwykle 1–3 m), obrót ≈ dokładność kompasu (kilka stopni).
struct GeoReference {
    let zone: Int
    /// Zbieżność południków [rad].
    let gamma: Double
    /// Skala odwzorowania w miejscu skanu.
    let scale: Double
    let east0: Double
    let north0: Double
    let height0: Double?
    let sampleCount: Int
    /// Średni kwadratowy rozrzut próbek GPS / odchyłek fotopunktów względem rozwiązania [m].
    let rmsHorizontal: Double
    var method: String = "GPS + kompas"

    var isFromControlPoints: Bool { method.hasPrefix("fotopunkt") || method.hasPrefix("1 fotopunkt") }

    /// Kod EPSG układu PL-2000 dla strefy (5 → 2176 … 8 → 2179).
    var epsg: Int { 2171 + zone }

    static let minSamples = 5

    static func solve(_ samples: [GeoSample]) -> GeoReference? {
        guard samples.count >= minSamples else { return nil }

        let meanLat = samples.map(\.latitude).reduce(0, +) / Double(samples.count)
        let meanLon = samples.map(\.longitude).reduce(0, +) / Double(samples.count)
        let zone = PL2000.zone(forLongitude: meanLon)
        let gamma = (meanLon - Double(zone * 3)) * .pi / 180 * sin(meanLat * .pi / 180)

        let center = PL2000.convert(latitude: meanLat, longitude: meanLon, zone: zone)
        let dy = center.y - Double(zone) * 1_000_000 - 500_000
        let earthRadius = 6_381_000.0
        let scale = 0.999923 * (1 + (dy * dy) / (2 * earthRadius * earthRadius))

        var sumW = 0.0
        var sumE = 0.0
        var sumN = 0.0
        var dEs: [Double] = []
        var dNs: [Double] = []
        var hSum = 0.0
        var hW = 0.0

        for s in samples {
            let grid = PL2000.convert(latitude: s.latitude, longitude: s.longitude, zone: zone)
            let rotated = rotate(s.local, gamma: gamma, scale: scale)
            let dE = grid.y - rotated.east
            let dN = grid.x - rotated.north
            let acc = max(s.horizontalAccuracy, 0.5)
            let w = 1 / (acc * acc)
            sumW += w
            sumE += dE * w
            sumN += dN * w
            dEs.append(dE)
            dNs.append(dN)

            if let alt = s.altitude, let vAcc = s.verticalAccuracy, vAcc > 0 {
                let va = max(vAcc, 0.5)
                let vw = 1 / (va * va)
                hSum += (alt - Double(s.local.y)) * vw
                hW += vw
            }
        }

        let e0 = sumE / sumW
        let n0 = sumN / sumW
        var sq = 0.0
        for i in dEs.indices {
            let a = dEs[i] - e0
            let b = dNs[i] - n0
            sq += a * a + b * b
        }
        let rms = (sq / Double(dEs.count)).squareRoot()

        return GeoReference(zone: zone, gamma: gamma, scale: scale,
                            east0: e0, north0: n0,
                            height0: hW > 0 ? hSum / hW : nil,
                            sampleCount: samples.count, rmsHorizontal: rms)
    }

    /// Lokalny punkt ARKit → (wschód, północ) w siatce, bez przesunięcia.
    static func rotate(_ p: SIMD3<Float>, gamma: Double, scale: Double) -> (east: Double, north: Double) {
        let e = Double(p.x)
        let n = Double(-p.z)
        let c = cos(gamma)
        let s = sin(gamma)
        let east = (e * c - n * s) * scale
        let north = (n * c + e * s) * scale
        return (east, north)
    }

    /// Punkt ARKit → współrzędne CAD w PL-2000: X = wschód (Y 2000), Y = północ (X 2000), Z = H.
    func cad(_ p: SIMD3<Float>) -> SIMD3<Double> {
        let r = Self.rotate(p, gamma: gamma, scale: scale)
        let h = (height0 ?? 0) + Double(p.y)
        return SIMD3<Double>(east0 + r.east, north0 + r.north, h)
    }

    var report: String {
        var lines: [String] = []
        lines.append("Georeferencja skanu – LiDAR Skaner")
        lines.append("Metoda: \(method)")
        lines.append("Układ: PL-2000, strefa \(zone) (południk osiowy \(zone * 3)°), EPSG:\(epsg)")
        lines.append("Osie plików: X = wschód (Y 2000), Y = północ (X 2000), Z = wysokość")
        lines.append(String(format: "Początek układu lokalnego: Y2000 = %.3f, X2000 = %.3f", east0, north0))
        if let height0 {
            lines.append(String(format: "Wysokość początku (GPS, orientacyjnie): %.2f m", height0))
        } else {
            lines.append("Wysokość: brak – Z jest względem początku skanu")
        }
        lines.append(String(format: "Zbieżność południków: %.4f°", gamma * 180 / .pi))
        lines.append(String(format: "Skala odwzorowania: %.6f", scale))
        if isFromControlPoints {
            lines.append("Fotopunktów: \(sampleCount)")
            lines.append(String(format: "Odchyłki na fotopunktach (RMS): %.3f m", rmsHorizontal))
            lines.append("")
            lines.append("Dokładność zależy od rozmieszczenia fotopunktów (najlepiej ≥ 3, na krańcach obiektu) i dryfu ARKit.")
        } else {
            lines.append("Próbek GPS: \(sampleCount)")
            lines.append(String(format: "Rozrzut próbek GPS (RMS): %.2f m", rmsHorizontal))
            lines.append("")
            lines.append("UWAGA: obrót wynika z kompasu telefonu (błąd zwykle kilka stopni – na 50 m to kilka metrów).")
            lines.append("Do zastosowań geodezyjnych użyj fotopunktów z RTK lub dopasuj chmurę w CloudCompare.")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
