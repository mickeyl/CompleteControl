# Widget-Lab-Rework: Demo-Browser statt Unit-Tasten

Stand 2026-07-12, Plan zur Iteration. Ziel: Die gewachsene Demo (4338-Zeilen-
`main.swift`, 8 Units auf F1–F8, INSTANCE-Cycling mit inzwischen 10 Combos
allein im Scene-Lab) wird zu einem **Demo-Browser**: Top-Level eine
filterbare Liste aus Standard-Elementen, 4D-Press öffnet eine Demo
exklusiv, SCENE verlässt sie.

---

## 1. Ziele

1. **Navigation:** Top-Level = filterbare Demo-Liste (Standard-Elemente:
   `MK2SelectionListElement` + `MK2SelectionInputElement` +
   Kategorie-Filter), kategorisiert in *Calibration*, *Look & Feel*,
   *Kit Catalogue*. 4D-Press öffnet die fokussierte Demo.
2. **Exklusive Demos:** Eine geöffnete Demo besitzt **alle** Tasten,
   Encoder und Lampen — nur **SCENE** bleibt der Shell reserviert und
   führt zurück in den Browser. Damit können Demos endlich Transport,
   F-Tasten und INSTANCE selbst belegen (bisher global verplant).
3. **Konsolidierung:** Duplikate zusammenlegen, Platzhalter abreißen,
   `main.swift` in kleine Dateien zerlegen (eine Demo = eine Datei).
4. **Erhalten:** REPL (inkl. LED/Light-Guide-Overrides), Snapshot-Harness
   (`WIDGETLAB_SNAPSHOT_DIR`), Simulator-Sounds, Wire-Kompatibilität.

## 2. Ist-Inventar mit Konsolidierungs-Urteil

Heute: 8 Units (F1–F8) mit Sub-Demos via INSTANCE — insgesamt ~19 Screens.

| Heute | Inhalt | Urteil |
|---|---|---|
| A FONT · surfaceFont | SurfaceFont-Specimen (Faces, Gewichte, Scale, Farben) | **Merge** mit typography → „Type Specimen" |
| A FONT · typography | FreeType-Größen, Ligaturen, Kontext | ↑ |
| A FONT · icons | Phosphor-Icon-Browser (List/Grid/Filter) | Eigenständig → „Icon Browser" |
| A FONT · actionDialog | Dialog-Karte + Icon-Größen-Sweep (handgezeichnet) | Eigenständig → „Dialog Card" |
| B BROWSER | RegularScreen-Detail + Picker (List/Grid/Filter) | **Merge** mit D → „Selection & Browser" |
| C METER | Multi-Kanal-Meter horizontal/vertikal | Bleibt → „Meter" |
| D SELECTION | Status + Picker (List/Grid/Filter) | **Merge** mit B (nahezu identische Picker) |
| E PATTERN | Tracker-Grid, Shift-Layer, Transport, M/S, Modal via SHIFT+CLEAR | Bleibt → „Tracker Pattern"; **Modal-Dialog herauslösen** als eigene Demo (heute kaum auffindbar) |
| F WAVEFORM | 4 Varianten (pluck/sparse/quiet/empty) | Bleibt → „Waveform" |
| G KEYS | Platzhalter „NOT BUILT YET" | **Ersatzlos**; stattdessen neue Demo „Light Guide & LEDs" aus den led/guide-REPL-Overrides (interaktiv statt REPL-only) |
| H SCENE · titleOnly…footerOnly (6 Combos) | Chrome-Slot-Kombinationen | **Eine** Demo „Chrome Slots" mit internem Varianten-Cycling |
| H SCENE · splash | Panorama + Bezel-Gap-Kalibrierung (E5 Gap, E6 Brightness) | **Merge** mit hero → „Panorama & Bezel Gap" (Bildquelle umschaltbar) |
| H SCENE · hero | Foto-Panorama | ↑ |
| H SCENE · granularity | ENCODER FEEL Rig | Eigenständig → „Encoder Feel" |
| H SCENE · forms | HEADER & RULER FORMS Katalog | Eigenständig → „Header & Ruler Forms" |

**Ergebnis: 13 Demos in 4 Kategorien** *(beschlossen 2026-07-12)*

- **Calibration:** Encoder Feel · Panorama & Bezel Gap
- **Look & Feel:** Type Specimen · Icon Browser · Dialog Card · Chrome Slots · Header & Ruler Forms
- **Kit Catalogue:** Selection & Browser · Meter · Waveform · Tracker Pattern · Modal Dialog
- **Diagnostics:** Light Guide & LEDs *(neu)*

**Querschnittsregel (beschlossen):** Alle sichtbaren Texte auf Englisch —
die Demo zielt auf ein internationales Release. Bestehende deutsche Labels
(Feel-Rig, Formen-Katalog) werden beim Umzug übersetzt; die deutschen
Kit2-Strings (ModalDialog „AKTIONEN", SelectionView „Keine Einträge" —
D2 im DSL-Review) laufen als eigener kleiner Commit mit.

*(Kandidat für später, nicht Teil dieses Umbaus: „Value-Cell Deboss" als
Look-&-Feel-Demo — das Backlog wünscht OLED-Tuning der Gradient-Faktoren.)*

## 3. Ziel-Architektur

### 3.1 Navigations-Zustandsmaschine

```swift
enum LabMode { case browser; case demo(DemoID) }
```

- **Browser-Modus:** Links die Demo-Liste (Titel + Kategorie-Badge,
  Selektion via 4D-Jog, `MK2SelectionNavigation`-Lampen), Kategorie-Filter
  auf einem Filter-Encoder (`ALL / CAL / L&F / CAT` — 4 Werte, unter dem
  Filter-Limit von 4). Rechts das Detail der fokussierten Demo
  (`MK2BrowserDetailElement`: Beschreibung, welche Controls sie benutzt).
  4D-Press = öffnen. F-Tasten/Transport unbelegt und dunkel. SCENE aus.
- **Demo-Modus:** Die Demo liefert die komplette `MK2SurfaceScene2`
  (Screens, Lampen, Bindings, Shift-Layer). Die Shell injiziert danach
  ausschließlich: das SCENE-Binding (Exit), die SCENE-Lampe (dim weiß =
  „hier geht's raus") und die REPL-LED/Guide-Overrides. Alles andere —
  inklusive F1–F8, INSTANCE, Transport — gehört der Demo.

### 3.2 Demo-Kontrakt

```swift
enum DemoCategory: String, CaseIterable { case calibration, lookAndFeel, catalogue }

struct DemoDescriptor {
    let id: String              // "encoder-feel" — auch REPL- und Snapshot-Name
    let title: String           // "ENCODER FEEL"
    let category: DemoCategory
    let summary: String         // Listen-Detail
    let detail: [String]        // Browser-Detailpane (verwendete Controls etc.)
    let snapshotVariants: [String]  // [] = nur Default
}

protocol LabDemo: AnyObject {
    static var descriptor: DemoDescriptor { get }
    func scene(_ context: LabContext) -> MK2SurfaceScene2
    func replCommands() -> [ReplCommand]              // demo-lokale REPL
    func handleRepl(_ line: String, _ context: LabContext) -> Bool
    func prepareSnapshot(variant: String)             // Harness stellt Variante ein
}
```

`LabContext` liefert: `renderer`, `sounds`, `refresh()` (Re-Present
anstoßen). Isolation: Demos sind Klassen, die ausschließlich vom
`LabShell`-Actor gehalten und aufgerufen werden; Binding-Closures gehen
über `context.update { … }` (Shell führt Mutation auf ihrem Executor aus
und re-presented) — dasselbe Muster wie heute (`Task { await self?.… }`),
nur pro Demo gekapselt statt global verfilzt.

### 3.3 Datei-Layout

```
Tools/MK2WidgetLabDemo/
  main.swift                 Entry (~50 Zeilen)
  LabShell.swift             Actor: Mode, Render-Loop, SCENE-Exit, REPL-Dispatch,
                             LED/Guide-Overrides, Snapshot-Harness
  LabDemo.swift              Protokoll, Descriptor, Kategorie, Kontext, Registry
  DemoBrowser.swift          Liste + Filter + Detailpane + 4D
  Demos/
    EncoderFeelDemo.swift    PanoramaDemo.swift      LightGuideDemo.swift
    TypeSpecimenDemo.swift   IconBrowserDemo.swift   DialogCardDemo.swift
    ChromeSlotsDemo.swift    FormsDemo.swift
    SelectionBrowserDemo.swift  MeterDemo.swift      WaveformDemo.swift
    TrackerPatternDemo.swift    ModalDialogDemo.swift
  LineReader.swift, PhosphorIcons.generated.swift    (unverändert)
  BrowserLab.swift, SelectionLab.swift               (Fixtures wandern in
                                                      SelectionBrowserDemo)
```

### 3.4 REPL

- **Global (Shell):** `help`, `quit`, `list` (Demos + IDs), `open <id>`,
  `exit`, `snap`/`screenshot`, `push`/`jog` (4D-Emulation),
  `led`/`ledclear`/`ledlist`, `guide`/`guideclear`.
- **Demo-lokal:** Der aktive Demo-Descriptor registriert seine Kommandos
  (die heutigen `text`/`face`/`icon…` → Type-Specimen/Icon-Browser;
  `play`/`stop`/`row`/`mute`… → Tracker Pattern). `help` zeigt global +
  aktiv. Entfallen: `unit a-h` und alle `*mode`/`*demo`-Cycling-Kommandos
  (Navigation macht der Browser, Varianten die Demo selbst).

### 3.5 Snapshot-Harness

`WIDGETLAB_SNAPSHOT_DIR` bleibt. Die Harness iteriert die Registry statt
des Unit-Enums: Browser-Screen (einmal pro Kategorie-Filter) + jede Demo
mit ihren `snapshotVariants` (`prepareSnapshot`). Dateinamen:
`widgetlab-<demo-id>[-<variant>].png`; der Shift-Layer-Snapshot des
Trackers bleibt (`-shift`). Alte Dateinamen ändern sich — bekannte
Referenzen (Session-Notizen) sind Wegwerf-Artefakte, keine Doku-Pfade.

## 4. Was ersatzlos verschwindet

- `Unit`-Enum, `functionLED`-Mapping, globale F1–F8-Unit-Bindings.
- Globales INSTANCE-Cycling (`SceneChromeCombo`, `FontSubDemo`,
  `BrowserDemoMode`, `SelectionDemoMode`, `WaveformLabVariant` als
  *globale* Zustände — Varianten leben fortan in ihrer Demo).
- Global gebundene Transport-/CLEAR-/PAGE-Tasten (wandern in Tracker
  Pattern) und die font-lab-spezifischen PRESET/PAGE-Bindings (wandern in
  Icon Browser).
- `comingSoonFrame`/`placeholderRightFrame` (kein Platzhalter mehr nötig).
- Doppelte Picker-Fixtures aus BrowserLab/SelectionLab.

## 5. Phasenplan (je Phase ein Commit, Build + Snapshots + Simulator-Rauchtest)

**Stand 2026-07-12 abends:** Phase 1 geliefert (`4b92c98` + Polish
`7a09504`: Browser mit E4-Kategorie-Filter, SCENE-Exit, hellblauer
Akzent). Phase 2 geliefert (`4ca2a09`: Scene-Lab → Chrome Slots,
Panorama & Bezel Gap, Encoder Feel, Header & Ruler Forms als
LabDemo-Klassen; LabSupport mit geteilter Palette). Phase 3 begonnen:
FreeType-Helfer sind bereits geteilte freie Funktionen; die Aufspaltung
des Font-Labs in Type Specimen / Icon Browser / Dialog Card steht aus.
Noch offen außerdem: REPL-Hooks am LabDemo-Protokoll (demo-lokale
Kommandos laufen bis dahin über die Legacy-Wrapper).

1. **Gerüst:** `LabShell`/`LabDemo`/`DemoBrowser` + SCENE-Exit + Registry.
   Alle acht Alt-Units zunächst als je **eine Wrapper-Demo** registriert
   (Inhalt und Sub-Cycling unverändert, INSTANCE dann demo-lokal) — die
   Navigation ist damit komplett neu, ohne dass ein Screen umzieht.
   REPL `list`/`open`/`exit`; Snapshot-Harness auf Registry.
2. **Scene-Lab aufspalten:** Chrome Slots, Panorama (splash+hero-Merge),
   Encoder Feel, Header & Ruler Forms als echte Demos;
   `SceneChromeCombo` stirbt.
3. **Font-Lab aufspalten:** Type Specimen (surfaceFont+typography-Merge),
   Icon Browser, Dialog Card; Font-REPL-Kommandos demo-lokal.
4. **Picker-Merge:** Selection & Browser (aus B+D), Meter und Waveform in
   eigene Dateien.
5. **Tracker & Modal:** Tracker Pattern mit demo-lokalem Transport;
   Modal Dialog als eigene Demo; **Light Guide & LEDs** neu (interaktive
   Fassung der Overrides: Keys anfassen → Farbe, Encoder für Palette).
6. **Abriss & Doku:** Unit-Enum + tote Helfer raus, `main.swift` auf
   Entry reduziert; CLAUDE.md-Produktzeile („widget lab, snapshots, REPL")
   und Backlog-Einträge aktualisieren.

Phase 1 ist der größte Brocken; danach ist jede Phase klein und einzeln
revertierbar.

## 6. Entschieden (2026-07-12)

1. **Vier Kategorien** inkl. Diagnostics (Light Guide & LEDs). Das
   vermeintliche Filter-Limit betraf die Slot-Anzahl, nicht die Werte.
2. **Alle Merge-Verdikte bestätigt.**
3. **Modal Dialog** wird eigenständige **Kit-Catalogue**-Demo; Calibration
   bleibt Hardware-Physik (Feel/Bezel/LED) vorbehalten.
4. **REPL-Umfang bleibt** (demo-lokal registriert).
5. **Alle sichtbaren Texte Englisch** (internationales Release als Ziel).
