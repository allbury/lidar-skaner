# LiDAR Skaner (iOS)

Aplikacja na iPhone'a lub iPada z LiDAR-em, pisana bez Maca. Kod Swift leży tutaj, kompilacja odbywa się w chmurze (GitHub Actions, macOS), a instalacja z Windowsa przez **Sideloadly** z darmowym Apple ID.

## Funkcje

| Moduł | Co robi | Wynik |
|---|---|---|
| Skan pomieszczenia | Apple RoomPlan: ściany, drzwi, okna, otwory, meble | `model.usdz`, `rzut.dxf`, `pomieszczenie.json` |
| Pomiar odległości | Krzyżyk na środku ekranu, punkt → punkt | lista pomiarów w cm |
| Skan 3D (etap 2) | Kolorowa chmura punktów z mapy głębi LiDAR (odszumianie wokselami 1 cm, tylko punkty o wysokiej pewności, 0,2–5 m) + siatka ARKit | `chmura.ply`, `siatka.obj` |
| Inwentaryzacja sieci (etap 3) | Punkty (studnie, wpusty, zasuwy, hydranty…) z GPS uśrednianym 10 s → PL-2000 (strefy 5–8), głębokość mierzona LiDAR-em, zdjęcia, odcinki sieci (KS, KD, W, G…) | `punkty.csv`, `rury.csv`, `inwentaryzacja.dxf`, `inwentaryzacja.json`, zdjęcia |

**Mapa w inwentaryzacji (wybór studni do zinwentaryzowania):**
- Geoportal (GUGiK, WMS EPSG:3857, na żywo): ortofotomapa, działki i budynki (KIEG), uzbrojenie terenu (KIUT/GESUT). Przytrzymanie palca przy włączonym uzbrojeniu pobiera opis obiektu z GESUT (GetFeatureInfo), np. „zasuwa lub zawór (w)”.
- Podkład DXF w PL-2000 (tekstowy DXF, dowolna wersja): linie, polilinie, okręgi, łuki, bloki, punkty i teksty. Okrąg, blok lub punkt można wskazać jako studnię, a numer jest brany z najbliższego tekstu (do 3 m). Strefę i układ osi aplikacja wykrywa sama, a w razie potrzeby można je zmienić ręcznie.
- Wskazane elementy trafiają do listy „Do inwentaryzacji” (pomarańczowe na mapie). W terenie aplikacja pokazuje odległość i kierunek do punktu; po pomiarze zaznacz „Zinwentaryzowany”.
- Odwrotne przeliczenie PL-2000 → WGS84 zweryfikowane: po przeliczeniu tam i z powrotem błąd jest poniżej 1 mm.

**Skan 3D z zewnątrz (budynki, mosty)** – ⚙︎ w Skanie 3D → tryb „Budynek / most”:
- zasięg LiDAR do 8 m (powyżej ~5 m szum rośnie), siatka 2 cm, punkty średniej pewności, do 4 mln punktów;
- **georeferencja PL-2000**: ARKit w orientacji wg kompasu + przesunięcie z GPS uśrednione z całego obchodu (próbki ≤ 15 m), z uwzględnieniem zbieżności południków (zweryfikowane z odwzorowaniem) → `chmura_PL2000.ply` (double), `siatka_PL2000.obj`, `georeferencja.txt`. Dokładność to ok. 1–3 m dla położenia i kilka stopni dla obrotu. Do celów geodezyjnych dopasuj chmurę do punktów RTK, np. w CloudCompare;
- **zdjęcia do fotogrametrii**: automatycznie co 0,5 m lub 15°, z GPS w EXIF, oraz `zdjecia_pozycje.csv` (pozycje kamer i kalibracja). Służą do partii poza zasięgiem LiDAR-u (wysokie elewacje, spód i ustroje mostów), do obróbki w Agisoft Metashape, RealityCapture lub Meshroom;
- **fotogrametria (rozszerzona):**
  - zdjęcia w pełnej rozdzielczości aparatu (ARKit `captureHighResolutionFrame`);
  - odstęp między zdjęciami liczony z odległości do obiektu (LiDAR) dla zadanego nakładania (60–85%);
  - odrzucanie poruszonych klatek (ostrość < 50% mediany) i ostrzeżenie przy ruchu > 1 m/s;
  - w EXIF: GPS i ogniskowa 35 mm;
  - eksport: `metashape_referencje.csv` (pozycje kamer w PL-2000 z ARKit), `realitycapture_flightlog.csv`, `INSTRUKCJA_fotogrametria.txt` i ZIP całego skanu;
- **fotopunkty** (◎): znacznik wskazany krzyżykiem i opcjonalnie współrzędne RTK. Z 2 lub więcej fotopunktami z RTK georeferencja przestaje zależeć od kompasu i GPS (obrót i przesunięcie dopasowane metodą najmniejszych kwadratów). Eksport: `fotopunkty.csv` z odchyłkami i `fotopunkty_na_zdjeciach.csv`, czyli gdzie szukać znacznika na każdym zdjęciu;
- długie obiekty skanuj odcinkami (eksport → kosz → kolejny odcinek), bo śledzenie ARKit dryfuje na dużych odległościach.

**Inwentaryzacja – ważne:**
- GPS telefonu ma dokładność zwykle 2–5 m. Do map do celów projektowych trzeba wpisać współrzędne z odbiornika GNSS RTK (pola X/Y/H są edytowalne).
- Wysokość H z telefonu jest orientacyjna (±10 m).
- PL-2000: X = północ, Y = wschód (np. 7 500 000). W DXF: X rysunku = Y(2000), Y rysunku = X(2000), Z = H; jednostki: metry. Przeliczenie (szereg Krügera, GRS80, m0 = 0,999923) zweryfikowane z niezależnym wzorem – różnice < 0,1 mm.
- CSV: średnik i przecinek dziesiętny (Excel PL).
- Głębokość: punkt 1 na krawędzi włazu, punkt 2 na dnie; wynik to różnica wysokości. LiDAR mierzy do ok. 5 m, a woda na dnie może przekłamać pomiar.

**LAS (domyślny format chmury):** LAS 1.2, punkty z kolorem RGB, rozdzielczość 1 mm. Przy georeferencji plik zawiera kod EPSG PL-2000 (2176–2179), więc ReCap, CloudCompare, QGIS i Civil 3D (przez ReCap) od razu znają układ. Format można przełączyć w ⚙︎ na PLY albo LAS + PLY.

**Przenoszenie na Windows:**
- **Bez kabla:** w aplikacji Eksport → Zapisz w Plikach → Dysk Google; pliki pojawiają się w `G:\Mój dysk`.
- **Kablem:** iTunes → telefon → Udostępnianie plików → LiDAR Skaner.
- ZIP ze zdjęciami powstaje tylko na czas udostępniania i jest kasowany po zamknięciu okna, więc nie zajmuje drugi raz miejsca.

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
