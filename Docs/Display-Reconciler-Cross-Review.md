# Display-Reconciler: Cross-Review gegen den Stream-Deck-Stack

**Stand:** 2026-08-23
**Status:** Umgesetzt und durch Messung abgeschlossen — Ü1, Ü2, Ü3-Stufe 1 auf `wip/performance`; Ü3-Stufe 2/3 und Ü4 (AP2) am 2026-09-06 durch Benchmark geschlossen bzw. verworfen; siehe Umsetzungsstand

Dieses Dokument hält einen Quervergleich zwischen `PixelDisplayReconciler2`
(hier) und dem `PageReconciler` des Stream-Deck-Projekts
(`auriteq-flow-hacking/elgato/`) fest. Schwerpunkt ist bewusst die Richtung
**„was CompleteControl übernehmen sollte“**; die Gegenrichtung ist am Ende nur so
weit zusammengefasst, wie sie den Kontext der Vorschläge trägt.

Die beiden Reconciler lösen dasselbe Problem auf verschiedenen Ebenen, weil die
Hardware es erzwingt. Nichts hier ist ein Aufruf, die Architekturen anzugleichen.

## Umsetzungsstand

**2026-09-02, Branch `wip/performance`:** Ü1, Ü2 und die `reserveCapacity`-Zeile
aus Ü3 sind umgesetzt. Der Hardware-Benchmark vom 2026-09-06 (Branch gegen
Master, je 12 Iterationen pro Fixture, adaptive) hat danach beide offenen
Fragen entschieden: Ü3 Stufe 2/3 sind latenzseitig bedeutungslos und damit
geschlossen, und Ü4 (AP2) ist durch Messung verworfen — siehe unten.

Zwei Korrekturen gegenüber diesem Dokument:

- Der Kit2-Default-Tick liegt bei 30 Hz (`MK2Surface2.Options.tickHz`), nicht
  60; Paulinche betreibt die Surface aber mit 60 Hz (siehe
  Transport-Review), sodass die Absolutwerte in Ü1 für den Hauptclient
  gültig bleiben. Das Strukturargument ist davon unberührt.
- Ü3 sind vier Kopien, nicht drei: `KKDaemonBinaryFrame.encoded()` materialisiert
  den Payload ein viertes Mal (kapazitätsreserviert, aber vollständig).

Der Komposit-Cache ist ein selbstvalidierender Cache in
`displaysWithTouchOverlays`: Basis-Frames (CoW-Identität) plus jedes aktive
Overlay (Screen, Rect, Pixel-Buffer-Identität) bilden den Key. Overlay-Inhalt
ist Teil des Keys, weil ein Szenewechsel dieselben Basis-Buffer mit getauschten
Overlay-Pixeln zurückgeben kann — der oben vorgeschlagene Key „Basis-Identität +
Overlay-Menge“ hätte diese Lücke. Held-Layer-Wechsel braucht keine explizite
Invalidierung (Layer-Frames haben andere Identität, `?? base` fällt auf die
unveränderte Basis zurück); beides ist durch Tests gepinnt
(`TouchOverlayCompositeCacheTests`). `blit(_:into:)` kopiert zeilenweise per
`memcpy` (Guard unverändert, Differenzial-Test über 100 deterministische
Rects), und die Overlay-Komposition läuft deterministisch in aufsteigender
Encoder-Ordnung statt in Dictionary-Ordnung.

Messpunkte aus `PixelPipelinePerfTests` (arm64) — jedes Paar misst die neue
Implementierung gegen die Referenzimplementierung des alten Pfads im selben
Lauf:

| Messpunkt | Debug | Release |
|---|---|---|
| Overlay-Blit 464×57: memcpy vs. replaceSubrange | 0,008 vs. 0,011 ms/op | 0,001 vs. 0,001 ms/op |
| Held-Overlay-Tick: Cache vs. frische Identität | 0,001 vs. 0,038 ms/op | ~0,000 vs. 0,011 ms/op |
| Display-Payload Full-Frame: reserviert vs. unreserviert | 0,005 vs. 0,005 ms/op | 0,004 vs. 0,004 ms/op |

Einordnung: Der Held-Overlay-Tick wird um den Faktor ~30–40 billiger — absolut
kein Notfall (~0,01–0,04 ms pro Tick und Screen), wie schon in Ü1 vermutet. Das
`reserveCapacity` ist medianneutral; sein Gewinn ist Allokations-Churn und
Tail-Varianz im Timeout-kritischen Replay-Pfad, nicht Medianzeit. Der
Blit-Memcpy ist vor allem Debug-Build-Konsistenz mit der Bulk-Policy der Datei.

### Hardware-Benchmark 2026-09-06: Branch gegen Master

Je 12 Iterationen pro Fixture, adaptive Encodierung, Release-Builds, S61 MK2.
Ergebnis: **Transport-Bytes über alle sieben Fixtures byte-identisch**;
USB-Median und Wall-P90 innerhalb des Einzel-Lauf-Rauschens beidseitig
gestreut (kleine Fixtures scheinbar −18…−43 %, große +5…+7 %; P90-Treffer wie
rotary 2,32 ms bei 0,33 ms Median sind Einzel-Sample-Hiccups). `usbMedian`
stammt aus den physischen Transportzählern des Daemons und ist vom Client-Zweig
prinzipiell unbeeinflussbar — kein Mechanismus des Branches kann diese Deltas
erzeugt haben. Damit:

- **Sicherheitsgate bestanden**: null Transport-Fehler, byte-identische
  Payloads — die `reserveCapacity`-Abnahme ist erledigt.
- **Ü3 Stufe 2/3 geschlossen**: der Kopieranteil am Full-Frame-Replay liegt bei
  ≤0,2 % der Wand-Zeit (vier Materialisierungen à 261 KB ≈ 25–50 µs gegen ~21 ms
  Transfer); ein Restwert wäre reine Allocator-Hygiene.
- **Ü4 (AP2) verworfen**: das Gap-Fixture schickt 190 080 logische Bytes als
  **368 Transport-Bytes in 0,742 ms USB** über den Draht. Die adaptive
  Skip-Encodierung kollabiert saubere Lücken auf Wire-Ebene und liefert damit
  bereits, was AP2 mit Protokolländerung, atomarer Daemon-Queue-Semantik und
  Hardware-Abnahme erreichen wollte. AP2s eigene Phase-1-Gate („nur weiter,
  wenn … die daraus vermeidbare USB-Zeit relevant ist") ist damit negativ
  beantwortet; der historische Motivator („Band verschmilzt bis zur vollen
  Frame-Höhe → ~24 ms") greift nur bei inkompressiblen Bändern — und die haben
  keine sauberen Lücken zum Splitten.

**Zur Attribution, ehrlich:** Das Transport-Review (2026-07-09) war zum
Schreibzeitpunkt korrekt — seine Prämisse (rohe Band-Bytes über USB) wurde erst
am 2026-07-15 durch den Default-Wechsel auf adaptive Encodierung entfernt. Aber
der Protokoll-Guide dokumentiert genau seit dem 15.07., dass verkettete
skip/literal/repeat-Segmente den AP2-Zweck in *einem* Transfer billiger
erreichen (AP2 zahlte pro Rect 16-Byte-Header + 12-Byte-Trailer + einen eigenen
`libusb_bulk_transfer`). Die Ü4-Aussage dieses Reviews („bestätigt die
Priorisierung nur") hat die im Repo vorhandene Gegenstelle nicht abgewogen und
dachte in Client-Band- statt in Wire-Segment-Granularität. Das ist der
eigentliche Fehler dieses Dokuments; die Empfehlung ist zurückgezogen.

**Nebenbefund (im Protokoll-Guide festgehalten):** USB-Zeit ist paketgranular,
nicht bytegranular — Meter-Step 11 646 B in 7,21 ms (~620 ns/B) gegen
Large-Noise 153 632 B in 14,72 ms (~96 ns/B). Der einzig verbliebene messbare
Display-Pfad-Hebel ist Segment-Koaleszierung im adaptiven Encoder (Literal über
kleine Lücken ziehen, wenn das Segment-Overhead die ersparten Bytes übersteigt)
— daemon-intern, gleiches Wire-Format; als Beobachtung ins Backlog, nicht
implementiert.

## Ausgangslage

| | CompleteControl | Stream Deck |
|---|---|---|
| Wire-Format | rohes RGB565, beliebige Rects blitbar | JPEG, Button ist atomar |
| Diff-Ebene | Pixel: CoW-Identität → `memcmp` pro Zeile → ein Full-Width-Band | Semantik: Descriptor-Vergleich, überspringt das Rendern |
| Zweite Stufe | – | 64-Bit-Fingerprint über die JPEG-Bytes, überspringt den Transport |
| Dritte Stufe | ein In-Flight-Batch, latest-wins pro Frame | Job-Queue mit Key-Coalescing, newest-wins pro Button/Window |
| Fehlerpfad | `reconciler.reset()`, Cooldown, `pendingForcedDisplayReplay` | fehlt (wird dort gerade nachgezogen) |

Die für uns interessante Asymmetrie: Der Stream-Deck-Reconciler entscheidet
**vor** dem Rendern, ob überhaupt etwas zu tun ist. Wir rendern die Szene immer
und entscheiden danach anhand der Pixel. Das ist für uns meistens richtig — der
CoW-Identitätscheck ist billiger als jeder Descriptor-Vergleich und kann nicht
unvollständig werden, wenn jemand ein neues Feld vergisst. Es gibt aber einen
Pfad, auf dem diese Voraussetzung heute bricht.

## Ü1: Komposit-Cache für Touch-Overlays

**Das ist der eine Punkt, an dem wir strukturell Arbeit verschenken.**

`activeDisplays` (`MK2Surface2.swift:812`) ruft pro Tick
`displaysWithTouchOverlays(scene.displays)`. Ohne aktives Overlay bleiben die
Frames unangetastet, die CoW-Identität überlebt, und `reconcile` steigt in O(1)
aus — genau wie entworfen.

Sobald ein Encoder-Touch-Overlay aktiv ist, passiert dagegen pro Tick:

```swift
guard isActive, var frame = displays[overlay.screen] else { continue }
frame.blit(overlay.pixels, into: overlay.rect)   // MK2Surface2.swift:832-835
```

`var frame` + Mutation erzwingt eine CoW-Kopie des kompletten Framebuffers
(480×272×2 = 261.120 Bytes), das Overlay wird erneut hineinkopiert, und weil der
Buffer nun eine neue Identität hat, scannt `dirtyRowBand` anschließend den
ganzen Frame zeilenweise durch — nur um festzustellen, dass sich nichts geändert
hat, und `lastSent` auf einen bitgleichen Buffer zu setzen.

Bei `behavior == .latched` (`MK2Surface2.swift:830`, gesetzt in
`MK2Surface2.swift:1154`) steht das Overlay über viele Sekunden. Bei 60 Hz sind
das rund 15 MB/s Kopie plus 30 MB/s Vergleich pro betroffenem Screen für ein
Standbild. Absolut ist das kein Notfall; strukturell ist es der Fall, für den
der Reconciler den O(1)-Pfad überhaupt hat.

**Vorschlag:** einen Komposit-Cache im Surface, gekeyt auf
(Identität des Basis-Frames, Menge der aktiven Overlays). Trifft der Key, wird
der zwischengespeicherte komponierte Frame **unverändert** zurückgegeben — damit
greift `isIdentical` wieder und der Tick kostet nichts. Nur wenn sich die Szene
oder die Overlay-Menge ändert, wird neu komponiert.

Das ist die hiesige Entsprechung dessen, was der `PageReconciler` mit seinem
Descriptor-Diff macht: die Frage „hat sich inhaltlich etwas geändert?“ wird
beantwortet, *bevor* Pixel angefasst werden. Der Unterschied ist, dass wir dafür
keine Feld-für-Feld-Gleichheit brauchen — Buffer-Identität plus ein Set von
Overlay-Keys genügt.

**Tests und Abnahme**

- Unit-Test: aktives, unverändertes Overlay über N Ticks erzeugt genau einen
  Kompositvorgang und keine Blits.
- Unit-Test: Szenenwechsel bei aktivem Overlay invalidiert den Cache.
- Unit-Test: Wechsel `.momentary` → losgelassen gibt den Basis-Frame ohne Kopie
  zurück.
- `PixelPipelinePerfTests`: neuer Messpunkt „tick mit gehaltenem Overlay“ vor
  und nach der Änderung.

## Ü2: `blit(_:into:)` folgt der eigenen Bulk-Policy nicht

`MK2PixelFrame` dokumentiert ausdrücklich, dass die heißen Pfade bewusst
`memset_pattern4`/`memcmp`/`memcpy` benutzen, weil elementweise Swift-Schleifen
in unoptimierten Builds einbrechen (`PixelFrame.swift:44-48`). Der
Tile-Blit hält sich daran (`PixelFrame.swift:196`, `memcpy` pro Zeile).

Der öffentliche `blit(_ sourcePixels: [UInt16], into rect:)`
(`PixelFrame.swift:423`) ist der Ausreißer: er kopiert pro Zeile über
`pixels.replaceSubrange(_:with:)`. Das ist genau der Aufruf aus Ü1, also der
Pfad, der pro Tick läuft. Zeilenweises `memcpy` unter
`withUnsafeMutableBufferPointer` — analog zum Tile-Blit — macht ihn konsistent
und in Debug-Builds messbar schneller.

Kleiner Eingriff, unabhängig von Ü1 sinnvoll, aber am selben Code.

## Ü3: Drei Kopien des Bands vor dem Socket-Write

Ein Blit wird auf dem Weg zum Daemon dreimal vollständig kopiert:

1. `let pixels = Array(frame.pixels[…])` — Band aus dem Frame heraus
   (`PixelDisplayReconciler2.swift:50`)
2. `blit.pixels.withUnsafeBytes { Array($0) }` — nach `[UInt8]`
   (`MK2DisplayBlitWriter.swift:51`)
3. `payload.append(contentsOf: pixelsRGB565BE)` in `displayBlitPayload`
   (`DaemonBinaryProtocol.swift:378`) — dort ohne `reserveCapacity`, das Array
   startet mit zwei Elementen

Bei einem Full-Frame-Replay sind das 3 × 261 KB pro Screen, und zwar exakt in
dem Lastfall, der laut Header-Kommentar des Writers (`MK2DisplayBlitWriter.swift:14-18`)
historisch in die Timeout→Resend→Timeout-Schleife geführt hat. Der
Stream-Deck-Stack hat hier den saubereren Zuschnitt: er reicht `std::span` bis
zur Report-Erzeugung durch und kopiert erst beim Bauen der Chunks.

**Vorschlag, in aufsteigender Eingriffstiefe:**

- Sofort und risikolos: `reserveCapacity(14 + pixels.count)` in
  `displayBlitPayload`.
- Kopie 2 entfällt, wenn `sendDisplayBlit` die Pixel als
  `UnsafeRawBufferPointer` (oder `some Sequence<UInt8>`) statt als `[UInt8]`
  entgegennimmt.
- Kopie 1 entfällt, wenn `MK2PixelBlit` den Frame und den Zeilenbereich hält
  statt eines eigenen Arrays. Das Band ist bei Full-Width-Geometrie ohnehin
  zusammenhängend — genau die Eigenschaft, die `pixels(in:)`
  (`PixelFrame.swift:436`) bereits ausnutzt.

Die letzte Stufe berührt den Blit-Typ und die Tests; sie lohnt sich nur, wenn
Ü1 und Kopie 2 nicht schon genügen.

## Ü4: Multi-Rect — keine neue Idee, nur ein Zusatzargument

*(Zurückgezogen am 2026-09-06 — die adaptive Skip-Encodierung erfüllt den Zweck
bereits auf Wire-Ebene; siehe Umsetzungsstand sowie den Ergebnisblock in
`transport-latency-optimization-review.md` AP2. Der folgende Text bleibt als
historische Begründung stehen.)*

`Docs/transport-latency-optimization-review.md` AP2 plant das bereits
vollständig (Schwelle 12 Zeilen, maximal vier Full-Width-Rects, atomare
Pending-Einheit im Daemon). Der Quervergleich bestätigt die Priorisierung nur:
Der `PageReconciler` hat dieses Problem gar nicht, weil seine Granularität die
Kachel ist — ein oberer Statusbereich und ein unterer Meter sind dort zwei
unabhängige Uploads, während sie bei uns zu einem Band bis zu voller Frame-Höhe
verschmelzen.

Ein Detail, das in AP2 noch nicht steht: Die Break-Even-Konstante für den Split
lässt sich aus `MK2DisplayBlitWriter.ackTimeoutUsec(forPixelBytes:)`
(`MK2DisplayBlitWriter.swift:43`) ableiten — 50 ms Grundbudget plus
1 µs je 5 Bytes. Das Verhältnis von Fixkosten zu Bytekosten ist damit schon
einmal empirisch bestimmt worden und kann die Schwelle „12 Zeilen“ in Phase 1
gegen echte Messdaten stützen, statt sie zu setzen.

Die Telemetrie für Phase 1 ist bereits vorhanden und env-gated
(`KONTROL_SURFACE_KIT2_RECONCILER_TELEMETRY=1`,
`PixelDisplayReconciler2.swift:62-101`) und liefert genau `gaps`/`largestGap`.

## Ausdrücklich nicht übernehmen

- **Byte-Fingerprint-Dedup vor dem Transport.** Im Stream-Deck-Stack die zweite
  Verteidigungslinie, weil dort ein JPEG-Encode zwischen Semantik und Bytes
  liegt. Unser Pixel-Diff ist strikt stärker; ein Hash darüber wäre reine
  Zusatzarbeit.
- **Feld-für-Feld-Descriptor-Vergleich.** Der `PageReconciler` zahlt dafür
  echten Preis (tiefe Vergleiche über Zeilen- und Spaltenvektoren, plus eine
  tiefe Kopie der ganzen Page pro Present) und trägt das bekannte Risiko, dass
  ein neu hinzugefügtes Feld im Vergleich vergessen wird. Unsere
  Buffer-Identität leistet dasselbe in O(1) und kann nicht unvollständig sein.
  Ü1 holt sich nur den *Zeitpunkt* der Entscheidung, nicht ihre Mechanik.
- **Spalten-Cropping.** Bleibt verworfen, siehe AP2 („Kein Spalten-Cropping“).
  Der Stream-Deck-Stack macht an einer Stelle das Gegenteil — schmale
  Vollhöhen-Spalten für die Zonen des Modal-Choice-Fensters — und muss dafür
  nachmessen; unsere Hardwaremessung liegt bereits vor.

## Gegenrichtung, zur Einordnung

Was der Stream-Deck-Stack von hier übernimmt (dort in Umsetzung, hier nur zur
Vollständigkeit):

1. **Invalidierungs-Epoche.** Dort fehlt der Rückkanal „die Senke hat deine
   Pixel verworfen“ vollständig: Screensaver, `show_logo()` und Fullscreen-Upload
   invalidieren den Treiber-Cache, aber der Reconciler oberhalb glaubt weiter, sein
   Stand stehe auf dem Gerät — nach dem Aufwachen malt ein unveränderter
   Descriptor nichts neu. Wir haben dafür `displayReconciler.reset()`,
   `pendingForcedDisplayReplay` und `replaySurfaceState()`.
2. **Dirty-Row-Band vor dem JPEG-Encode**, für das 1200×100-Touch-Fenster.
3. **Backpressure statt blind rendern** — unser `guard !displayWriter.isBusy`
   spart dort den kompletten JPEG-Encode, den die Queue ohnehin verwirft.

## Offene Messungen

- ~~Kosten eines Ticks mit gehaltenem Overlay, vor und nach Ü1.~~ Beantwortet
  (siehe Umsetzungsstand): Faktor ~30–40 billiger, absolut ~0,01–0,04 ms pro
  Tick und Screen.
- ~~`replaceSubrange` vs. zeilenweises `memcpy` in `blit(_:into:)`, Debug und
  Release.~~ Beantwortet (siehe Umsetzungsstand): Debug ~1,4×, Release neutral.
- ~~Anteil der Kopierzeit am Full-Frame-Replay, um zu entscheiden, ob Ü3 über
  die `reserveCapacity`-Zeile hinaus lohnt.~~ Beantwortet (Hardware-Benchmark
  2026-09-06, siehe Umsetzungsstand): ≤0,2 % der Wand-Zeit — Ü3 Stufe 2/3
  geschlossen, AP2 verworfen.
