import SwiftUI

/// Ustawienia skanu 3D wybierane przez użytkownika.
struct ScanSettings: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case interior, exterior, custom
        var id: String { rawValue }
        var name: String {
            switch self {
            case .interior: return "Wnętrze / detal"
            case .exterior: return "Budynek / most"
            case .custom: return "Własne"
            }
        }
    }

    var preset: Preset = .interior
    var maxDepth: Double = 5
    var voxelCentimeters: Double = 1
    var allowMediumConfidence = false
    var georeference = false
    var capturePhotos = false

    static let interior = ScanSettings(preset: .interior, maxDepth: 5, voxelCentimeters: 1,
                                       allowMediumConfidence: false, georeference: false, capturePhotos: false)
    static let exterior = ScanSettings(preset: .exterior, maxDepth: 8, voxelCentimeters: 2,
                                       allowMediumConfidence: true, georeference: true, capturePhotos: true)

    var collector: CollectorSettings {
        var c = CollectorSettings()
        c.maxDepth = Float(maxDepth)
        c.voxelSize = Float(voxelCentimeters / 100)
        c.minConfidence = allowMediumConfidence ? 1 : 2
        // Większe woksele = mniej punktów na m², więc można objąć większy obiekt.
        c.maxPoints = voxelCentimeters >= 2 ? 4_000_000 : 3_000_000
        c.capturePhotos = capturePhotos
        return c
    }
}

struct ScanSettingsView: View {
    @State var settings: ScanSettings
    let onApply: (ScanSettings) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tryb", selection: $settings.preset) {
                        ForEach(ScanSettings.Preset.allCases) { p in
                            Text(p.name).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.preset) { _, preset in
                        switch preset {
                        case .interior: settings = .interior
                        case .exterior: settings = .exterior
                        case .custom: break
                        }
                    }
                } footer: {
                    Text("„Budynek / most”: zasięg 8 m, siatka 2 cm, georeferencja i zdjęcia do fotogrametrii.")
                }

                Section {
                    Picker("Zasięg LiDAR", selection: custom(\.maxDepth)) {
                        Text("3 m").tag(3.0)
                        Text("5 m").tag(5.0)
                        Text("8 m").tag(8.0)
                    }
                    Picker("Rozdzielczość chmury", selection: custom(\.voxelCentimeters)) {
                        Text("1 cm").tag(1.0)
                        Text("2 cm").tag(2.0)
                        Text("5 cm").tag(5.0)
                    }
                    Toggle("Punkty o średniej pewności", isOn: custom(\.allowMediumConfidence))
                } header: {
                    Text("Chmura punktów")
                } footer: {
                    Text("LiDAR iPhone'a mierzy dokładnie do ok. 5 m. Powyżej punkty są coraz bardziej zaszumione – dlatego w trybie zewnętrznym warto robić też zdjęcia do fotogrametrii.")
                }

                Section {
                    Toggle("Georeferencja PL-2000 (GPS + kompas)", isOn: custom(\.georeference))
                    Toggle("Zdjęcia do fotogrametrii", isOn: custom(\.capturePhotos))
                } header: {
                    Text("Obiekty zewnętrzne")
                } footer: {
                    Text("Georeferencja: chmura i siatka w PL-2000 (dokładność GPS ~1–3 m, obrót wg kompasu). Zdjęcia: automatycznie co 0,5 m lub 15°, z pozycją GPS w EXIF – do Agisoft Metashape, RealityCapture lub Meshroom.")
                }

                Section {
                    Text("Zastosowanie ustawień rozpoczyna nowy skan (bieżące, niewyeksportowane dane zostaną usunięte).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ustawienia skanu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zastosuj") {
                        onApply(settings)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Ręczna zmiana parametru przełącza tryb na „Własne”.
    private func custom<T>(_ keyPath: WritableKeyPath<ScanSettings, T>) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                settings.preset = .custom
            }
        )
    }
}
