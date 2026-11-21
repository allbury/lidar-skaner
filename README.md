# LiDAR Skaner (iOS)

Aplikacja na iPhone'a lub iPada z LiDAR-em, pisana bez Maca. Kod Swift leży tutaj, kompilacja odbywa się w chmurze (GitHub Actions, macOS), a instalacja z Windowsa przez **Sideloadly** z darmowym Apple ID.

## Funkcje – etap 1

| Moduł | Co robi | Wynik |
|---|---|---|
| Skan pomieszczenia | Apple RoomPlan: ściany, drzwi, okna, otwory, meble | `model.usdz`, `rzut.dxf`, `pomieszczenie.json` |
| Pomiar odległości | Krzyżyk na środku ekranu, punkt → punkt | lista pomiarów w cm |

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

- **Etap 2:** chmura punktów i siatka 3D (ARKit Scene Reconstruction + sceneDepth) z eksportem do PLY/OBJ/LAS.
- **Etap 3:** inwentaryzacja terenu i instalacji: znaczniki (studnia, rura, zasuwa), GPS / układ PL-2000, eksport do DXF/CSV.
