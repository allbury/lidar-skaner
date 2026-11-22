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

    enum CloudFormat: String, CaseIterable, Identifiable {
        case las, ply, both
        var id: String { rawValue }
        var name: String {
            switch self {
            case .las: return "LAS"
            case .ply: return "PLY"
            case .both: return "LAS + PLY"
            }
        }
        var includesLAS: Bool { self != .ply }
        var includesPLY: Bool { self != .las }
    }

    var preset: Preset = .interior
    /// Format chmury punktów przy eksporcie (nie zależy od trybu).
    var cloudFormat: CloudFormat = .las
    var maxDepth: Double = 5
    var voxelCentimeters: Double = 1
    var allowMediumConfidence = false
    var georeference = false
    var capturePhotos = false
    var highResPhotos = true
    var targetOverlap: Double = 0.75

    static let interior = ScanSettings(preset: .interior, maxDepth: 5, voxelCentimeters: 1,
                                       allowMediumConfidence: false, georeference: false, capturePhotos: false)
    static let exterior = ScanSettings(preset: .exterior, maxDepth: 8, voxelCentimeters: 2,
                                       allowMediumConfidence: true, georeference: true, capturePhotos: true,
                                       highResPhotos: true, targetOverlap: 0.75)

    var collector: CollectorSettings {
        var c = CollectorSettings()
        c.maxDepth = Float(maxDepth)
        c.voxelSize = Float(voxelCentimeters / 100)
        c.minConfidence = allowMediumConfidence ? 1 : 2
        // Większe woksele = mniej punktów na m², więc można objąć większy obiekt.
        c.maxPoints = voxelCentimeters >= 2 ? 4_000_000 : 3_000_000
        c.capturePhotos = capturePhotos
        c.highResPhotos = highResPhotos
        c.targetOverlap = Float(targetOverlap)
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
                        let format = settings.cloudFormat
                        switch preset {
                        case .interior: settings = .interior
                        case .exterior: settings = .exterior
                        case .custom: break
                        }
                        settings.cloudFormat = format
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
                    Picker("Format eksportu", selection: $settings.cloudFormat) {
                        ForEach(ScanSettings.CloudFormat.allCases) { f in
                            Text(f.name).tag(f)
                        }
                    }
                } header: {
                    Text("Chmura punktów")
                } footer: {
                    Text("LiDAR iPhone'a mierzy dokładnie do ok. 5 m. Powyżej punkty są coraz bardziej zaszumione – dlatego w trybie zewnętrznym warto robić też zdjęcia do fotogrametrii. LAS (z kodem EPSG układu PL-2000) otwiera się w ReCap, CloudCompare, QGIS; PLY w MeshLab/Blender.")
                }

                Section {
                    Toggle("Georeferencja PL-2000 (GPS + kompas)", isOn: custom(\.georeference))
                    Toggle("Zdjęcia do fotogrametrii", isOn: custom(\.capturePhotos))
                    if settings.capturePhotos {
                        Toggle("Pełna rozdzielczość aparatu", isOn: custom(\.highResPhotos))
                        Picker("Nakładanie zdjęć", selection: custom(\.targetOverlap)) {
                            Text("60%").tag(0.6)
                            Text("70%").tag(0.7)
                            Text("75%").tag(0.75)
                            Text("80%").tag(0.8)
                            Text("85%").tag(0.85)
                        }
                    }
                } header: {
                    Text("Obiekty zewnętrzne")
                } footer: {
                    Text("Georeferencja: chmura w PL-2000 – z GPS i kompasu (~1–3 m) albo z fotopunktów RTK (cm). Zdjęcia robią się same, gdy nakładanie z poprzednim spadnie do zadanej wartości (liczone z odległości do obiektu); poruszone klatki są odrzucane. Pełna rozdzielczość = zdjęcia ~12 Mpx zamiast klatek wideo 2 Mpx.")
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
