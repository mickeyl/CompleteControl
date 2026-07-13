# DSL-Standardisierungs-Review

Review von 2026-07-11, abgearbeitet bis 2026-07-13. Umgesetzt sind die
Empfehlungen A1–A5, B1, B2, B3 und D2 (A1/A2 wurden durch die Entfernung des
Song-Renderers gegenstandslos), dazu backlog-seitig die per-Ebene-Lampen, der
`isHardwareShiftPressed`-Abbau und das `ControlLampName`-Enum. Die vollständige
Analyse und die erledigten Punkte stehen in der git-Historie dieses Dokuments.

**Offen bleibt nur D1.**

## C1 — Tracker-Grid + Minimap ins Kit (erledigt 2026-07-13)

`MK2PatternGridElement` (Tracker-Grid) und `MK2OverviewScrollbarElement`
(Minimap) leben jetzt im Kit, mit `MK2PatternGridColors`/
`MK2OverviewScrollbarColors` als Single-Source der hardware-approved Palette
(2026-07-13). WidgetLab `TrackerPatternDemo` und Paulinche
`PaulinchePatternRenderer` konsumieren beide — die je fünf Draw-Helfer und die
inline-Geometrie-Konstanten sind weg. Vor/Nach pixel-identisch (Snapshot-Diff 0
Pixel für Base und Shift; die sechs Paulinche-Renderer-Tests unverändert grün),
plus acht neue fokussierte Kit-Tests.

Sorgfältige Divergenz-Prüfung vorab (Nutzer-Verdacht: Paulinche-only Beat-Zellen):
Die Beat-Stripe war bereits pixel-identisch in beiden (alle 4 Rows, 0x1083). Die
eine echte Divergenz war die Zell-Färbung — WidgetLab färbte ganze Zellen
(`isEmpty`), Paulinche pro Feld (`== nil`); das gemeinsame Element übernimmt die
korrektere Per-Feld-Variante. Das Datenmodell ist Paulinches Optional-Triade
(`note?/instrument?/effect?`); WidgetLabs totes `volume`-Grid-Feld entfällt. Neu:
`BeatStripe` ist konfigurierbar (`.every(interval, phase:)`/`.none`), damit
ungerade Taktarten auf dem Beat streifen — App-seitige Verdrahtung an die
Taktart steht im Backlog.

## D1 — Kit-interne Helfer-Konsolidierung

`insetBy`, `scale565`/`scaled`, `drawRoundedPanel` und die Wrap-Helper sind
privat über mehrere Kit-Dateien dupliziert (ScreenDSL, ScreenLayout, ValueCell,
Meter, ModalDialog, SelectionView, DialogCard, Tag, FunctionKeyBar) — einmalig
in eine geteilte Stelle konsolidieren.

## Anhang: Verworfene Ideen

- **`FunctionKeyBar` mit `edge: .bottom`** — verworfen: Die Hardware hat
  Function-Keys nur oben; eine Bottom-Variante würde Labels ohne räumlich
  zugeordnete Taste erzeugen. Der Footer gehört Encoder-Zellen (bottom-flush,
  gleiche X-Slots), nicht F-Key-Labels.
