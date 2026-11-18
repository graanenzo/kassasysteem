# Kassasysteem

Flutter-desktopkassa voor laptop met USB EAN-scanner.

- **PLU inlezen**: export van het PLU-systeem (`B_PLU.CSV` of als `.xlsx` opgeslagen)
- **Stickerapp is leidend**: bij het opstarten (en met de ⟳-knop) haalt de kassa
  prijzen, namen en EAN-codes op uit de stickerapp (Supabase-functie
  `kassa_verpakkingen`). Voor die PLU's wint de stickerapp; zonder internet
  blijven de laatst opgehaalde prijzen in gebruik.
- **PLU exporteren**: de huidige lijst (incl. zelf toegevoegde producten) als `.xlsx`
  in dezelfde kolomindeling; prijzen aanpassen in Excel en weer inlezen
- **Scannen**: herkent EAN-codes uit de PLU-lijst, en eigen winkel-/weegschaalcodes
  (`20` + PLU 5 cijfers + prijs 5 cijfers + controlecijfer)
- **Handmatig**: PLU-nummer typen + Enter, of zoeken op naam
- **Weegartikelen** (`P` in de PLU-lijst, prijs per kg): gewicht invoeren, of
  het label van de weegschaal scannen (gewicht in grammen komt uit de barcode,
  bijv. `2000002002659` = PLU 2, 265 g)
- **Afrekenen**: pin of contant (met wisselgeld) → bon op 80 mm bonprinter
- Verkopen worden gelogd; dagomzet staat bovenin

## Opstarten

1. Installeer Flutter: https://docs.flutter.dev/get-started/install
2. In deze map, eenmalig de platformbestanden aanmaken:
   ```
   flutter create --platforms=windows,macos --org nl.kassa .
   flutter pub get
   ```
3. Starten:
   ```
   flutter run -d windows     # of: -d macos
   ```
4. Klik **PLU inlezen** en kies het exportbestand.
5. Bij **Instellingen**: winkelnaam/adres voor op de bon en de bonprinter kiezen.

### Alleen macOS
Voeg in `macos/Runner/DebugProfile.entitlements` én `Release.entitlements` toe:
```xml
<key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.print</key><true/>
```

## PLU-kolommen

| Kolom | Inhoud |
|---|---|
| A | PLU-nummer |
| B | Naam |
| C | Omschrijving (2e regel) |
| D | `P` = per kg, `C` = per stuk |
| E | Prijs in centen (`499`); een bedrag met komma (`4,99`) mag ook |
| R | EAN-code |

## Scanner

De scanner werkt als toetsenbord. Toetsen die binnen 60 ms na elkaar komen
en eindigen op Enter worden als scan gezien. Komen er rare tekens binnen,
zet de scanner dan op het juiste toetsenbord-layout (configuratiebarcode in
de handleiding).

## Nog niet ingebouwd

- Btw staat voor alle producten op 9% (in `models.dart` aan te passen per product)
- Pinautomaat koppelen (nu kies je handmatig “Pin”)
- Directe koppeling met de weegschaal
- Retouren / kortingen

## Data

Producten, instellingen en verkopen staan in de app-supportmap
(`products.json`, `settings.json`, `sales.jsonl`).
