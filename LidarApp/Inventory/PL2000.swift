import Foundation

/// Przeliczenie WGS84/ETRF (φ, λ) → PL-2000 (odwzorowanie Gaussa-Krügera, elipsoida GRS80).
/// Szereg Krügera (3 wyrazy) – dokładność poniżej 1 mm w pasie strefy.
/// Zweryfikowane z całką łuku południka i szeregiem Redfearna (różnice < 0,1 mm).
/// Konwencja geodezyjna: X = północ, Y = wschód (z numerem strefy, np. 7 500 000).
enum PL2000 {

    struct Coordinates: Equatable {
        let x: Double
        let y: Double
        let zone: Int
    }

    /// Strefa 5–8 (południki osiowe 15°, 18°, 21°, 24°).
    static func zone(forLongitude longitude: Double) -> Int {
        let z = Int((longitude / 3).rounded())
        return min(8, max(5, z))
    }

    static func convert(latitude: Double, longitude: Double, zone: Int? = nil) -> Coordinates {
        let z = zone ?? Self.zone(forLongitude: longitude)

        let a = 6_378_137.0
        let f = 1.0 / 298.257222101
        let m0 = 0.999923

        let n = f / (2 - f)
        let n2 = n * n
        let n3 = n2 * n
        let bigA = a / (1 + n) * (1 + n2 / 4 + n2 * n2 / 64)
        let alpha1 = n / 2 - 2 * n2 / 3 + 5 * n3 / 16
        let alpha2 = 13 * n2 / 48 - 3 * n3 / 5
        let alpha3 = 61 * n3 / 240
        let alphas = [alpha1, alpha2, alpha3]

        let phi = latitude * .pi / 180
        let lambda = (longitude - Double(z * 3)) * .pi / 180

        let k = 2 * n.squareRoot() / (1 + n)
        let sinPhi = sin(phi)
        let t = sinh(atanh(sinPhi) - k * atanh(k * sinPhi))
        let xi = atan(t / cos(lambda))
        let eta = atanh(sin(lambda) / (1 + t * t).squareRoot())

        var sumNorth = xi
        var sumEast = eta
        for j in 1...3 {
            let m = Double(2 * j)
            let alpha = alphas[j - 1]
            sumNorth += alpha * sin(m * xi) * cosh(m * eta)
            sumEast += alpha * cos(m * xi) * sinh(m * eta)
        }

        let north = m0 * bigA * sumNorth
        let east = m0 * bigA * sumEast + Double(z) * 1_000_000 + 500_000
        return Coordinates(x: north, y: east, zone: z)
    }
}
