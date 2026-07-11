# DSL-Standardisierungs-Review: Custom-Renderer-Inventar und Kandidaten

Stand 2026-07-11. Analysebasis: Kit2-Widget-Katalog (`Sources/KontrolSurfaceKit2`),
MK2WidgetLabDemo (`Tools/MK2WidgetLabDemo`), Paulinche-Renderer
(`Sources/PaulincheSurfaceKit`) sowie `Paulinche/BACKLOG.md`
(Sektion „Kit2-DSL-Review").

Zweck: Wo sind wir custom, und welche Elemente sollten durch bestehende,
neu zu parametrierende oder neu zu entwickelnde Standardelemente ersetzt
werden, um DSL-lastiger zu werden. Jeder Punkt trägt ein Kommentarfeld
zum Einzelreview.

---

## 1. Ausgangslage

Kit2 hat einen soliden Widget-Bestand: `ContentText`, `StatusLine`,
`ValueCell`, `ParameterPage`, `FunctionKeyBar`, `Meter`, `WaveformDisplay`,
`SelectionList/Grid`, `ModalDialog`, `ImageElement`, `ProgressBar`,
`TabBar`, `PageIndicator`, dazu Binding-Elemente (`ButtonBinding`,
`EncoderBinding`, `Lamp`, `KeyColor`) und die Shift-Ebene
(`MK2ShiftBranch`, `shiftSlots`). Escape-Hatches: `MK2RenderBlock`
(reines Zeichnen) und `MK2AnyScreenElement` (Zeichnen + Bindings/Lampen).

Die WidgetLab-Regel („If a unit needs something the kit can't express
yet, that capability goes into the kit first", `main.swift:6-9`) wird an
mehreren Stellen nicht gelebt — genau dort entsteht Duplikation zwischen
WidgetLab und Paulinche.

Hardware-Realität als Leitplanke: **Function-Keys existieren nur oben,
4 pro Screen** (F1–F4 links, F5–F8 rechts). Encoder-Zellen sind
bottom-flush, F-Key-Slots top-flush, beide auf demselben X-Raster
(`ScreenLayout.swift:147-167`).

## 2. Custom-Inventar

### 2.1 Paulinche (`Sources/PaulincheSurfaceKit`)

| Renderer | Standard genutzt | Custom |
|---|---|---|
| **Pattern** | StatusLine (rechts), ParameterPage, ButtonToggleDisplay, EncoderBinding | Linker Screen fast komplett: `drawGridStatusLine` (:182), `drawChannelHeaders` (:193), `drawPatternGrid` (:208, Playhead/Cursor/Stripe-Fills, Ruler), `drawTrackerCell` (:239), `drawPatternOverview` (:284, Minimap) |
| **Instrument** | WaveformDisplay, ParameterPage ×2, FunctionKeyBar (inkl. Shift), EncoderBinding | Title/Subtitle via FreeType direkt (:115), `drawKindTag`-Pill (:177), Info-Zeilen (:163) |
| **Song** | RegularScreenDSL (Header/Footer), ProgressBar | `drawOrders`-Tabelle (:136), `drawFooterSoftKeys` → `drawSoftKeyStrip` (:169), `drawParameterSlots` statt ParameterPage (:111) |
| **Splash** | FullScreenDSL, ImageElement, ContentText | nur die prozedurale Artwork-*Daten*-Generierung (`PaulincheSplashArtwork`) — läuft standardkonform über ImageElement |

`PaulincheRendererSupport.swift` (geteilte Custom-Helfer):
`Palette` (~40 RGB565-Farben), `drawSoftKeyStrip` (:45),
`drawParameterSlots` (:67), `drawText`/`drawWrappedText`-Wrapper,
Textstil-Fabriken, `MK2PixelFrame`-Extensions `hline`/`dottedVLine` (:189).

### 2.2 WidgetLab (`Tools/MK2WidgetLabDemo`)

- **Pur-DSL-Vorzeigeeinheiten:** Browser-Lab (B), Meter-Lab (C),
  Selection-Lab (D) — saubere Referenzen.
- **Font-Lab (A):** bewusst Raw-Frame-Spezimenbank (Font-Sweeps,
  Icon-Browser, Dialog-Karten) — akzeptabler Sonderfall.
- **Pattern-Lab (E):** zweites, unabhängig handgebautes Tracker-Grid
  (`trackerGridFrame` :1686, `drawTrackerCell` :1800) samt Minimap
  (`drawPatternOverview` :1890) — dieselben Elemente wie in Paulinche,
  zweimal implementiert.
- **Waveform-Lab (F):** handgebauter Header über `MK2WaveformDisplay`
  in Raw-Frame (:2943), Statuszeile im Escape-Hatch (:2981).
- **Scene-Lab (H):** Escape-Hatch-Inhalte sind Debug-Visualisierungen
  der Layout-Rects — legitimer Escape-Hatch-Einsatz.
- **Keys-Lab (G):** Platzhalter („BUILD ITS WIDGETS INTO KIT2 FIRST").
- WidgetLab definiert `hline`/`dottedVLine` als eigene Extensions
  (:4156) — dieselben wie in PaulincheRendererSupport.

## 3. Empfehlungen

### A. Sofort ersetzbar durch bestehende Widgets

**A1 — Song-Renderer `drawParameterSlots` → `MK2ParameterPageElement`.**
Handgerollter Nachbau dessen, was Pattern- und Instrument-Renderer längst
über das echte Widget beziehen. Klarster Fall im Inventar.
> Kommentar:

**A2 — Song-Renderer Footer-Softkeys → Standard-`MK2FunctionKeyBarElement`
(top-flush, 4 Slots/Screen).** `drawSoftKeyStrip` zeichnet einen
8-Slot-Strip *unten* auf einem Screen — die Hardware hat die F-Keys aber
nur *oben*, je 4 pro Screen. Der Strip ist damit doppelt nicht-standard
(falsche Kante, falsche Slot-Zahl) und mappt räumlich auf keine Taste.
Kein DSL-Ausbau nötig, sondern Umbau der Song-Szene auf die echte Bar;
bei >4 Aktionen pro Screen: auf beide Screens verteilen oder auf die
Shift-Ebene ausweichen.
> Kommentar:

**A3 — Pattern-Renderer `drawGridStatusLine` → `MK2StatusLineElement`.**
Feste x-Positionen mit Einzeltexten ist exakt dessen Modell; der rechte
Screen nutzt `MK2StatusLine` bereits.
> Kommentar:

**A4 — Instrument-Renderer Title/Subtitle → `MK2ContentText`** statt
direkter FreeType-Aufrufe über `Support.drawText`.
> Kommentar:

**A5 — `hline`/`dottedVLine` ins Kit heben.** Beide Codebases definieren
identische private `MK2PixelFrame`-Extensions. Primitiven auf
`fill`-Niveau — gehören neben `stroke` in `PixelFrame.swift`.
> Kommentar:

### B. Bestehende Widgets neu parametrieren

**B1 — Encoder-Touch-Highlight als DSL-Default** in
`MK2ParameterPageElement`/`MK2EncoderBindingElement`, mit Opt-out.
Backlog-Kandidat, durch die Analyse bestätigt: Der Pattern-Editor baut
den `.encoderTouch`→App-State→`isFocused`-Roundtrip nach, der
Instrument-Editor nicht (kein Highlight), und
`SurfaceUIState.touchedEncoderIndex` existiert als dritte, von niemandem
konsumierte Inkarnation. Die Runtime kennt den Touch-Zustand lokal —
das Highlight kann wie die Shift-Ebene ohne App-Roundtrip aus der DSL
kommen.
> Kommentar:

**B2 — `ValueCell`-Familie um Tag/Chip-Erscheinung ergänzen** (oder
Mini-Widget `MK2TagElement`): deckt den `drawKindTag`-Pill im
Instrument-Renderer ab (SAMPLE/WAVETABLE).
> Kommentar:

**B3 — `SelectionList` um Spalten erweitern.** Die Order-Tabelle des
Song-Renderers (Index/Pattern/Titel/Rows, Selektions-Fill,
Playback-Marker) ist strukturell eine SelectionList mit Spalten statt
Icon+Badge. Eine `columns:`-Parametrierung erspart ein eigenes
Table-Widget und gäbe der Song-Szene gratis die vorhandene
`MK2SelectionInputElement`-Navigation (Jog/Encoder, Lampen).
> Kommentar:

### C. Neu zu entwickelnde Widgets

**C1 — `MK2PatternGridElement` (Tracker-Grid) und
`MK2OverviewScrollbarElement` (Minimap).** Stärkstes Argument ist die
Duplikation: Grid, Zellen-Triaden, Playhead/Stripe-Fills, Ruler und
Minimap existieren zweimal (WidgetLab ↔ Paulinche). Nach der
WidgetLab-Regel gehört das ins Kit. Datenmodell ist mit
`MK2PaulinchePatternCell` faktisch definiert — es fehlt die Heimat.
Die Minimap ist separat wiederverwendbar (jede scrollende Szene).
> Kommentar:

**C2 — Kein neues Widget für den Splash.** Prozedurale
Artwork-Generierung ist *Daten*-Erzeugung über das standardkonforme
`MK2ImageElement` — bereits das richtige Muster.
> Kommentar:

### D. Kit-interne Hygiene (beim Umbau mitnehmen)

**D1 —** `insetBy`, `scale565`/`scaled`, `drawRoundedPanel`,
Wrap-Helper sind privat über
ScreenDSL/ScreenLayout/ValueCell/Meter/ModalDialog/SelectionView
dupliziert — einmalig konsolidieren.
> Kommentar:

**D2 —** Hartcodierte deutsche Strings in `ModalDialog`
(„4D: Auswahl und Bestätigung", „AKTIONEN") und `SelectionView`
(„Keine Einträge") — spätestens bei einer Kit-Öffnung ein Thema.
> Kommentar:

## 4. Verzahnung mit dem Backlog-Review

Die Backlog-These („Bindings und Lamp-States sind nicht genug
formalisiert") wird gestützt, aber das Display-Inventar zeigt: Die
Widget-Seite ist weiter als die Binding/Lampen-Seite. Empfohlene
Reihenfolge:

1. **A1–A5** — risikolos, baut Support-Code ab.
2. **B1** (Touch-Highlight in die DSL) — löst den dreifach
   halb-verdrahteten Roundtrip, passt zum gelieferten Shift-Muster
   („Runtime-lokal, ohne App-Roundtrip").
3. **B2/B3** opportunistisch, wenn die jeweilige Szene angefasst wird;
   B3 idealerweise *vor* der SCENE/Arranger-Hardware-Szene aus dem
   Backlog, damit die nicht als dritter Custom-Renderer startet.
4. **C1** als eigener Schritt — größter Brocken, beseitigt die größte
   Duplikation.
5. Parallel die offenen Backlog-Punkte: per-Ebene-Lampen (lügende
   UNDO-Lampe), `isHardwareShiftPressed`-Abbau, `ControlLampName`-Enum
   und typisierte Bindings — die Analyse liefert dafür die vollständige
   Lampen-/Binding-Landkarte.

## Anhang: Verworfene Ideen

- **`FunctionKeyBar` mit `edge: .bottom`** — verworfen: Die Hardware hat
  Function-Keys nur oben; eine Bottom-Variante würde Labels ohne
  räumlich zugeordnete Taste erzeugen. Der Footer gehört Encoder-Zellen
  (bottom-flush, gleiche X-Slots), nicht F-Key-Labels. Stattdessen A2.
