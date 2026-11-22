import Foundation
import CoreLocation

/// Odległość i kierunek z bieżącej pozycji GPS do punktu (liczone w PL-2000).
enum TargetNavigation {
    struct Result {
        let distance: Double
        /// Azymut siatkowy 0–360° (0 = północ). Różnica względem północy geograficznej ≤ ~1,5°.
        let azimuth: Double
        let cardinal: String

        var short: String {
            distance < 1000
                ? String(format: "%.0f m %@", distance, cardinal)
                : String(format: "%.1f km %@", distance / 1000, cardinal)
        }

        var long: String {
            String(format: "%.1f m, kierunek %.0f° (%@)", distance, azimuth, cardinal)
        }
    }

    static func describe(from location: CLLocation, to point: SurveyPoint) -> Result? {
        guard location.horizontalAccuracy > 0,
              let x = point.x2000, let y = point.y2000,
              let zone = point.zone2000 ?? PL2000.zone(forEasting: y) else { return nil }
        let here = PL2000.convert(latitude: location.coordinate.latitude,
                                  longitude: location.coordinate.longitude, zone: zone)
        let dNorth = x - here.x
        let dEast = y - here.y
        let distance = (dNorth * dNorth + dEast * dEast).squareRoot()
        var azimuth = atan2(dEast, dNorth) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((azimuth + 22.5) / 45) % 8
        return Result(distance: distance, azimuth: azimuth, cardinal: names[index])
    }
}
