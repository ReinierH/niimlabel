# NiimLabel

Native SwiftUI-app (macOS 14+, iPadOS/iOS 17+) voor het ontwerpen en afdrukken van labels op Niimbot-printers via Bluetooth LE. Primair gebouwd voor de **Niimbot B1**. B21, B3S, B203, D11, D110, D101 en B18 zitten er ook in, maar die zijn minder zeker.

## Downloaden

Download de nieuwste **`NiimLabel-x.y.z.dmg`** via [Releases](https://github.com/ReinierH/niimlabel/releases/latest), open hem en sleep NiimLabel naar *Apps*. Vereist macOS 14 of nieuwer.

De app is nog niet door Apple genotariseerd. De eerste keer dat je hem opent, meldt macOS dat de app niet kan worden gecontroleerd. Zo open je hem toch:

1. Open NiimLabel één keer en klik op *Gereed*.
2. Ga naar **Systeeminstellingen › Privacy en beveiliging**, scrol naar *Beveiliging* en klik bij NiimLabel op **Open toch**.
3. Bevestig met je wachtwoord. Daarna start de app gewoon.

Of via Terminal: `xattr -dr com.apple.quarantine /Applications/NiimLabel.app`

Bij de eerste start vraagt macOS om toestemming voor Bluetooth. Die is nodig om met de printer te verbinden.

> Getest op macOS 15. Het printen is ontwikkeld voor de Niimbot B1, maar nog niet op alle modellen en firmwareversies uitgeprobeerd. Lukt een afdruk niet, open dan een [issue](https://github.com/ReinierH/niimlabel/issues) en plak het protocol-logboek erin (Printer › Logboek › Kopiëren).

## Functies

**Printer**
- Zoeken en verbinden via Bluetooth, automatisch opnieuw verbinden met de laatste printer
- Model herkennen (model-ID en Bluetooth-naam), met de mogelijkheid het model of protocol handmatig te kiezen
- Live status: batterij, deksel open/dicht, labels aanwezig
- Apparaatinfo: firmware, hardware, serienummer, Bluetooth-adres
- RFID van originele labelrollen: type, resterende labels, barcode/serienummer
- Instelling voor automatisch uitschakelen, testpagina
- Protocol-logboek (TX/RX in hex), te kopiëren voor foutzoeken

**Ontwerpen**
- WYSIWYG-canvas: de preview is exact de 1-bit bitmap die naar de printer gaat
- Elementen: tekst (lettertype, grootte, vet/cursief/onderstreept, uitlijning, automatisch passend, wit-op-zwart), barcodes (Code 128, EAN-13, EAN-8, UPC-A, Code 39, ITF), QR-codes (met snelinvullers voor wifi, vCard en meer), afbeeldingen (drempel, Floyd–Steinberg, Atkinson, Bayer, omkeren), rechthoek, ellips en lijn
- Slepen, schalen, raster van 0,5 mm, pijltjestoetsen (⇧ = 2 mm, ⌥ = 0,1 mm), rotatie per element, uitlijnen, lagen, dupliceren, onbeperkt ongedaan maken
- Afbeeldingen naar het canvas slepen
- Standaardformaten per printer, of een eigen formaat. Het deel van het label buiten de printkop wordt gearceerd
- Afdrukrichting, labeltype, densiteit en uitlijncorrectie per label

**Afdrukken**
- Kopieën, nummering (`{teller}`, `{teller:4}`, met start en stap) en samenvoegen met CSV (`{Kolomnaam}`; scheidingsteken `,` `;` of tab, automatisch herkend)
- Datum/tijd-variabelen: `{datum}`, `{tijd}`, `{datumtijd}`, `{datum:dd MMM yyyy}`
- Voortgang, annuleren, duidelijke foutmeldingen (deksel open, geen labels, …)
- Identieke opeenvolgende labels worden als één pagina met een hoger aantal verstuurd

**Opslag**
- Labels worden automatisch bewaard in `~/Library/Containers/nl.computhings.niimlabel/Data/Library/Application Support/NiimLabel/labels.json`
- Import en export als JSON

## Bouwen

Vereist Xcode 16+ en [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate             # maakt NiimLabel.xcodeproj
open NiimLabel.xcodeproj      # of:
scripts/build-release.sh      # → dist/NiimLabel.app (ad-hoc gesigneerd)
scripts/make-dmg.sh           # → dist/NiimLabel-<versie>.dmg
```

Tests van het protocol, de barcodes en de renderer (zonder Xcode-project):

```sh
cd Packages/NiimbotKit && swift test
```

Voor iOS/iPadOS stel je in Xcode een Development Team in. macOS bouwt ad-hoc gesigneerd met App Sandbox en de Bluetooth-entitlement.

## Opbouw

```
Packages/NiimbotKit/
  Sources/NiimbotKit/   Protocol: pakketten, parser, BLE-transport (CoreBluetooth),
                        request/response-client, printflow, bitmap-encoder, printermodellen
  Sources/LabelKit/     Documentmodel, barcode/QR-encoders, dithering, variabelen/CSV,
                        renderer (CoreGraphics/CoreText → 1-bit)
App/Sources/            SwiftUI-app: modellen (printer, editor, opslag) en views
```

### Protocolnotities

Frame: `55 55 | cmd | len | data | xor-checksum | AA AA`. Verbinden gaat via de characteristic `bef8d6c9-9c21-4c9e-b632-bd58c1009f9f` (notify en write-without-response). De printflow voor B1 ("modern"):

1. `SetDensity 0x21`, `SetLabelType 0x23`
2. `PrintStart 0x01` met 7 bytes `[totaal u16, 0, 0, 0, 0, 0]`
3. Per pagina: `PageStart 0x03`, `SetPageSize 0x13` met 6 bytes `[rijen, kolommen, kopieën]`, rijen via `0x85` (bitmap) of `0x84` (leeg, met herhaling), daarna `PageEnd 0xE3`
4. `PrintStatus 0xA3` opvragen tot het aantal afgedrukte labels gelijk is aan het totaal, dan `PrintEnd 0xF3`

Het klassieke protocol (D11, oudere firmware) gebruikt een `PrintStart` van 1 byte, een `SetPageSize` van 4 bytes en `SetQuantity 0x15`.

Gebaseerd op het openbare reverse-engineeringwerk van [niimprint](https://github.com/AndBondStyle/niimprint) en [NiimBlue](https://github.com/MultiMote/niimblue).

## Problemen oplossen

- **Stopt halverwege of geeft strepen**: verhoog *Pauze tussen pakketten* bij Instellingen › Geavanceerd.
- **Print niets of iets vreemds**: zet het protocol handmatig op het andere type en bekijk het logboek.
- **Label verschoven**: gebruik *Uitlijning corrigeren* in het labelpaneel. Kalibreer de B1 door twee keer kort op de aan/uit-knop te drukken.
- **Bluetooth geweigerd**: Systeeminstellingen › Privacy en beveiliging › Bluetooth.
