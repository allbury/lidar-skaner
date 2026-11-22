import SwiftUI
import ARKit
import RoomPlan

struct ContentView: View {
    private let hasLidar = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    var body: some View {
        NavigationStack {
            List {
                if !hasLidar {
                    Section {
                        Label("To urządzenie nie ma skanera LiDAR. Potrzebny jest iPhone 12 Pro lub nowszy (Pro) albo iPad Pro z LiDAR-em.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Etap 1") {
                    NavigationLink {
                        RoomScanView()
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Skan pomieszczenia")
                                Text("RoomPlan → USDZ, rzut DXF, JSON")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "cube.transparent")
                        }
                    }
                    .disabled(!RoomCaptureSession.isSupported)

                    NavigationLink {
                        MeasureView()
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Pomiar odległości")
                                Text("Punkt → punkt, wynik w cm")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "ruler")
                        }
                    }
                    .disabled(!ARWorldTrackingConfiguration.isSupported)
                }

                Section("Etap 2") {
                    NavigationLink {
                        Scan3DView()
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Skan 3D")
                                Text("Wnętrza i obiekty z zewnątrz: chmura PLY, siatka OBJ, PL-2000, zdjęcia")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "circle.dotted.and.circle")
                        }
                    }
                    .disabled(!hasLidar)
                }

                Section("Etap 3") {
                    NavigationLink {
                        InventoryListView()
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Inwentaryzacja sieci")
                                Text("Studnie, rury, GPS → PL-2000, CSV + DXF")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                        }
                    }
                }

                Section("Pliki") {
                    Text("Zapisane skany znajdziesz w aplikacji Pliki → Na moim iPhonie → LiDAR Skaner.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("LiDAR Skaner")
        }
    }
}
