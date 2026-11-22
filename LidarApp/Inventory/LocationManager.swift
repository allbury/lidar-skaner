import Foundation
import CoreLocation

struct GPSFix: Equatable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    /// Średnia dokładność pozioma próbek [m] (wg raportu iOS).
    let horizontalAccuracy: Double
    let samples: Int
}

/// GPS telefonu z uśrednianiem pozycji (średnia ważona 1/σ² z próbek o dokładności ≤ 30 m).
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var current: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isReducedAccuracy = false
    @Published private(set) var averagingRange: ClosedRange<Date>?

    private let manager = CLLocationManager()
    private var samples: [CLLocation] = []
    private var averagingTask: Task<Void, Never>?

    let maxSampleAccuracy: Double = 30

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        averagingTask?.cancel()
        averagingTask = nil
        averagingRange = nil
    }

    var isAveraging: Bool { averagingRange != nil }

    /// Zbiera próbki przez `seconds` sekund i zwraca uśrednioną pozycję (albo nil, gdy brak dobrych próbek).
    func average(seconds: Double = 10, completion: @escaping (GPSFix?) -> Void) {
        averagingTask?.cancel()
        samples.removeAll()
        if let current, current.horizontalAccuracy > 0, current.horizontalAccuracy <= maxSampleAccuracy {
            samples.append(current)
        }
        let now = Date()
        averagingRange = now...now.addingTimeInterval(seconds)
        averagingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let fix = self.computeAverage()
            self.averagingRange = nil
            self.averagingTask = nil
            completion(fix)
        }
    }

    private func computeAverage() -> GPSFix? {
        guard !samples.isEmpty else { return nil }
        var sumW = 0.0
        var lat = 0.0
        var lon = 0.0
        var altSum = 0.0
        var altW = 0.0
        var accSum = 0.0
        for s in samples {
            let acc = max(s.horizontalAccuracy, 0.5)
            let w = 1 / (acc * acc)
            sumW += w
            lat += s.coordinate.latitude * w
            lon += s.coordinate.longitude * w
            accSum += s.horizontalAccuracy
            if s.verticalAccuracy > 0 {
                let va = max(s.verticalAccuracy, 0.5)
                let vw = 1 / (va * va)
                altSum += s.altitude * vw
                altW += vw
            }
        }
        let altitude: Double? = altW > 0 ? altSum / altW : nil
        return GPSFix(latitude: lat / sumW,
                      longitude: lon / sumW,
                      altitude: altitude,
                      horizontalAccuracy: accSum / Double(samples.count),
                      samples: samples.count)
    }

    private func handle(_ location: CLLocation) {
        current = location
        if isAveraging, location.horizontalAccuracy > 0, location.horizontalAccuracy <= maxSampleAccuracy {
            samples.append(location)
        }
    }

    private func handleAuthorization() {
        authorization = manager.authorizationStatus
        isReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.handle(last) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.handleAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
