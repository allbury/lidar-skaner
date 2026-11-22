# LiDAR Skaner (iOS)

Aplikacja na iPhone'a lub iPada z LiDAR-em, pisana bez Maca. Kod Swift leży tutaj, kompilacja odbywa się w chmurze (GitHub Actions, macOS), a instalacja z Windowsa przez **Sideloadly** z darmowym Apple ID.

## Funkcje

| Moduł | Co robi | Wynik |
|---|---|---|
| Skan pomieszczenia | Apple RoomPlan: ściany, drzwi, okna, otwory, meble | `model.usdz`, `rzut.dxf`, `pomieszczenie.json` |
| Pomiar odległości | Krzyżyk na środku ekranu, punkt → punkt | lista pomiarów w cm |
| Skan 3D (etap 2) | Kolorowa chmura punktów z mapy głębi LiDAR (odszumianie wokselami 1 cm, tylko punkty o wysokiej pewności, 0,2–5 m) + siatka ARKit | `chmura.ply`, `siatka.obj` |
| Inwentaryzacja sieci (etap 3) | Punkty (studnie, wpusty, zasuwy, hydranty…) z GPS uśrednianym 10 s → PL-2000 (strefy 5–8), głębokość mierzona LiDAR-em, zdjęcia, odcinki sieci (KS, KD, W, G…) | `punkty.csv`, `rury.csv`, `inwentaryzacja.dxf`, `inwentaryzacja.json`, zdjęcia |

**Inwentaryzacja – ważne:**
- GPS telefonu ma dokładność zwykle 2–5 m. Do map do celów projektowych trzeba wpisać współrzędne z odbiornika GNSS RTK (pola X/Y/H są edytowalne).
- Wysokość H z telefonu jest orientacyjna (±10 m).
- PL-2000: X = północ, Y = wschód (np. 7 500 000). W DXF: X rysunku = Y(2000), Y rysunku = X(2000), Z = H; jednostki: metry. Przeliczenie (szereg Krügera, GRS80, m0 = 0,999923) zweryfikowane z niezależnym wzorem – różnice < 0,1 mm.
- CSV: średnik i przecinek dziesiętny (Excel PL).
- Głębokość: punkt 1 na krawędzi włazu, punkt 2 na dnie; wynik to różnica wysokości. LiDAR mierzy do ok. 5 m, a woda na dnie może przekłamać pomiar.

**PLY/OBJ:** metry, oś Z w górę (zgodnie z rzutem DXF). Otwierają się w CloudCompare, MeshLab, Blenderze, a po konwersji (np. CloudCompare → LAS/E57) w Civil 3D/Recap.

Najnowszy plik instalacyjny: https://github.com/allbury/lidar-skaner/releases/download/latest/LidarSkaner.ipa

Pliki skanów są w **Pliki → Na moim iPhonie → LiDAR Skaner → Skan_RRRR-MM-DD_…**, a przycisk *Eksportuj* od razu otwiera udostępnianie (AirDrop, mail, Dysk Google).

**Rzut DXF:** jednostki to metry, widok z góry. Warstwy: `SCIANY`, `DRZWI`, `OKNA`, `OTWORY`, `OBIEKTY`, `WYMIARY` (długości ścian).

Wymagania: iPhone 12 Pro lub nowszy (Pro/Pro Max) albo iPad Pro z LiDAR-em, iOS 17+.

## Struktura

```
project.yml                     – definicja projektu (XcodeGen generuje .xcodeproj w chmurze)
LidarApp/
  LidarSkanerApp.swift          – punkt startowy
  ContentView.swift             – menu główne
  RoomScan/                     – RoomPlan + eksport USDZ/DXF/JSON
  Measure/                      – pomiar odległości (ARKit + RealityKit)
.github/workflows/build-ipa.yml – budowanie niepodpisanego .ipa
```

## Budowanie (jednorazowa konfiguracja)

1. Załóż konto na github.com i utwórz repozytorium (np. `lidar-skaner`). Przy repozytorium publicznym budowanie jest darmowe bez limitu; przy prywatnym limit to ok. 200 min macOS miesięcznie (jedno budowanie trwa ok. 5–10 min).
2. Wyślij ten folder do repozytorium (`git push`).
3. Zakładka **Actions** → *Build IPA* uruchamia się sama po każdym pushu (albo ręcznie: *Run workflow*).
4. Po zakończeniu pobierz z dołu strony artefakt **LidarSkaner-ipa** (zip z plikiem `LidarSkaner.ipa`).

## Instalacja na telefonie (Sideloadly, Windows)

1. Zainstaluj **iTunes i iCloud w wersji ze strony apple.com** (nie z Microsoft Store). Sideloadly potrzebuje ich sterowników.
2. Zainstaluj **Sideloadly** (sideloadly.io).
3. Podłącz iPhone'a kablem i na telefonie wybierz „Ufaj temu komputerowi”.
4. W Sideloadly przeciągnij `LidarSkaner.ipa`, wpisz swój Apple ID i kliknij **Start**. Hasło wpisujesz sam, w Sideloadly; najlepiej użyj osobnego Apple ID do testów.
5. Na telefonie:
   - **Ustawienia → Prywatność i ochrona → Tryb dewelopera** → włącz (telefon się zrestartuje);
   - **Ustawienia → Ogólne → VPN i urządzenia zarządzane** → zaufaj swojemu Apple ID.
6. Przy darmowym Apple ID aplikacja działa **7 dni**. Potem wystarczy ponownie kliknąć Start w Sideloadly (dane w aplikacji zostają). Limit to 3 aplikacje naraz.

## Plan dalszych etapów

- ~~Etap 2: chmura punktów i siatka 3D~~ – zrobione (PLY/OBJ).
- ~~Etap 3: inwentaryzacja sieci z GPS / PL-2000~~ – zrobione (CSV/DXF).
