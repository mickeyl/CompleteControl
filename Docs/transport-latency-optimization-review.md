# Transport-Latenz: Maßnahmenplan

**Stand:** 2026-07-09
**Status:** Beschlossen

Dieses Dokument enthält ausschließlich die geplanten Latenzmaßnahmen und die
bewusst verworfenen Alternativen. Die aktuelle Architektur bleibt grundsätzlich
bestehen: asynchrone libusb-IN-Transfers, kqueue für USB- und Socket-Readiness,
drei getrennte Unix-Sockets sowie unabhängige Display- und State-Report-Queues.

## Reihenfolge

1. Tick-on-Present implementieren und auf Hardware messen.
2. Dirty-Row-Verteilung in einer echten Paulinche-Session erfassen.
3. Multi-Rect-Blits nur bei bestätigter Laufzeitrelevanz implementieren.
4. Den Hex-Roundtrip beim nächsten Eingriff in den Push-Pfad nebenbei entfernen.

## AP1: Tick-on-Present

### Ziel

`MK2Surface2.present(_:)` ersetzt heute nur die Szene. Die Ausgabe wartet danach
auf den nächsten 60-Hz-Timer-Tick. Paulinche verliert dadurch strukturell
0–16,7 ms, im Mittel etwa 8,3 ms. Eine neue Szene soll nach Ruhe sofort
reconciliert werden, ohne bei schnellen Updates eine Tick-Warteschlange zu
erzeugen.

### Umsetzung

- `present(_:)` ruft nach dem Setzen von `scene` einen actor-isolierten
  `requestPresentTick()` auf.
- Der erste Tick nach mindestens 8 ms Ruhe läuft sofort auf dem Surface-Actor.
- Weitere Presents innerhalb dieses 8-ms-Fensters werden in genau einem
  Trailing-Tick zusammengefasst. Das begrenzt Present-Ticks auf 125 Hz und stellt
  trotzdem sicher, dass der letzte Zustand eines Bursts ausgegeben wird.
- Der Trailing-Task wird gespeichert, in `stop()` abgebrochen und prüft vor dem
  Tick erneut `running`.
- `lastTick` bleibt die gemeinsame Zeitbasis für Timer- und Present-Ticks.
- Der bestehende Timer bleibt für Lampenanimationen, Heartbeat, Reconnect und als
  Sicherheitsnetz aktiv.
- Der bestehende `TickGate` bleibt auf dem Timer-Pfad. Ein Present-Tick braucht
  keinen zusätzlichen Task-Hop, weil `present(_:)` bereits auf dem Actor läuft.

Der Trigger gehört ausdrücklich in `present(_:)`, nicht ans Ende der
Input-Verarbeitung: Ein Binding mutiert das App-Modell und präsentiert die neue
Szene erst in einem späteren Actor-Job. Ein Tick direkt nach dem Input würde noch
die alte Szene ausgeben.

### Tests und Abnahme

- Unit-Test: erstes Present nach Ruhe tickt sofort.
- Unit-Test: mehrere Presents innerhalb von 8 ms erzeugen höchstens einen
  Trailing-Tick und geben den letzten Zustand aus.
- Unit-Test: `stop()` verhindert einen noch armierten Trailing-Tick.
- Bestehende Timer-, Reconnect- und Display-Reconciler-Tests bleiben grün.
- Hardware: Bei einem einzelnen Encoder-Detent beginnt der zugehörige
  `display worker` im Ruhefall innerhalb von ungefähr 5 ms nach `push surface`.
- Hardware: Schneller Encoder-Spin bleibt bei höchstens 125 Present-Ticks/s,
  erzeugt keinen Actor-Backlog und endet auf dem korrekten Wert.

## AP2: Dirty-Row-Messung und atomare Multi-Rect-Blits

### Ziel

`PixelDisplayReconciler2` sendet heute pro Screen ein volles, breites Band von
der ersten bis zur letzten geänderten Zeile. Weit auseinanderliegende kleine
Änderungen übertragen deshalb auch alle sauberen Zeilen dazwischen. Der aktuelle
Paulinche-Renderer kann solche Formen erzeugen; beispielsweise wurden bei einer
Cursorbewegung 44 geänderte Zeilen innerhalb eines 194-Zeilen-Bands mit einer
140-Zeilen-Lücke beobachtet.

### Phase 1: Produktionsdaten messen

Vor der Protokolländerung wird in einem Debug-Build pro erzeugtem Blit geloggt:

- Screen und Bandhöhe,
- Anzahl tatsächlich geänderter Zeilen,
- größte saubere Lücke im Band,
- resultierende Payload-Größe.

Gemessen werden normales Editieren, Encoder-Spins, Playback, Scrubbing und
Szenenwechsel in Paulinche. Die Umsetzung geht nur weiter, wenn große saubere
Lücken regelmäßig auftreten und die daraus vermeidbare USB-Zeit relevant ist.
Als Richtwert gelten wiederkehrende Lücken von mehr als ungefähr 50 Zeilen.

### Phase 2: Reconciler und Protokoll

Falls Phase 1 den Nutzen bestätigt:

- Dirty Rows werden an sauberen Lücken von mindestens 12 Zeilen getrennt.
- Es bleiben höchstens vier Full-Width-Rects pro Screen und Tick. Bei mehr
  Kandidaten werden die kleinsten Lücken wieder zusammengeführt.
- Die Full-Width-Geometrie bleibt erhalten; das Panel verarbeitet breite Bänder
  schneller als schmale Fenster.
- Der Binärcodec erhält einen Multi-Rect-Displayframe mit Screen, Rect-Liste und
  den zugehörigen RGB565-Payloads.
- Der Daemon behandelt alle Rects eines Screens und Ticks als eine atomare
  Pending-Einheit. Newest-wins ersetzt immer ein vollständiges Rect-Set.
- Bestehende Einzel-Blits bleiben für ältere Clients gültig.

Die atomare Einheit ist zwingend: Die heutige Daemon-Queue hält pro Screen nur
einen Pending-Blit. Mehrere lose Split-Blits desselben Ticks könnten einander
ersetzen und dauerhaft nicht übertragene Regionen hinterlassen.

### Tests und Abnahme

- Reconciler-Tests für Schwelle, Bandlimit, eine Zeile, Full-Frame und exakt auf
  der Schwelle liegende Lücken.
- Codec-Tests für mehrere Rects, Payload-Längen und fehlerhafte Geometrie.
- Daemon-Tests: Newest-wins ersetzt vollständige Sets, niemals einzelne Rects.
- Hardware: Die Summe der Transferzeiten liegt im gemessenen Paulinche-Szenario
  deutlich unter der bisherigen Einzelband-Zeit.
- Hardware: Kein Tearing und keine stale Regionen bei schnellem Scrubbing.

## AP3: Binären Event-Payload direkt erzeugen

Kein eigenes Optimierungsprojekt. Beim nächsten Eingriff in
`pushInputToClients` oder `pushMidiToClients` wird der bereits vorhandene
Timestamp zusammen mit den Raw-Bytes direkt an
`KKDaemonBinaryCodec.eventPayload(timestamp:bytes:)` übergeben.

Der Hex-Text bleibt für Logs und alte Text-Clients erhalten. Nur der heutige
Raw-Bytes → Hex-String → Split → Raw-Bytes-Roundtrip für Binärclients entfällt,
und die binäre Payload wird vor dem Daemon-Lock aufgebaut. Erwarteter Gewinn:
Mikrosekunden, keine wahrnehmbare Latenzänderung.

## Machen wir nicht

### Keine Änderungen am Input-Transport

Surface- und MIDI-IN laufen bereits über dauerhaft resubmittete asynchrone
libusb-Transfers. Der Daemon beobachtet die libusb-pollfds mit kqueue und pumpt
Events ohne Polling-Intervall. Socket-`poll()` wacht bei Daten sofort auf; sein
Timeout ist nur eine Leerlaufgrenze. Hier gibt es keinen strukturellen
Millisekunden-Hebel.

### Keine asynchronen USB-OUT-Transfers

Display und State Reports besitzen bereits getrennte Queues und dürfen libusb
parallel auf verschiedenen Endpoints benutzen. Ein asynchroner Display-OUT-Pfad
würde Buffer-Lifetime, Completion- und Fehlerlogik erheblich verkomplizieren,
ohne die Gerätezeit zu verkürzen oder andere Arbeit freizugeben.

### Keine Fire-and-forget-Socket-Schreibweise ohne Ack

Display- und State-Report-Acks bestätigen bereits nur das Enqueue, nicht den
USB-Abschluss. Die kurze Roundtrip-Prüfung erhält Fehlererkennung sowie die
Timeout-/Probe-/Reconnect-Logik. Ihr Wegfall spart zu wenig und schwächt die
Session-Sicherheit.

### Keine höhere Default-Tickrate

Paulinche setzt bereits 60 Hz. Nach AP1 hängen Inhaltsänderungen nicht mehr vom
Timer-Raster ab. Der 30-Hz-Default bleibt für andere Clients bestehen; später
kann für Paulinche sogar geprüft werden, ob 30 Hz für Animationen und Heartbeat
genügen.

### Keine Kompression

Das Display erwartet rohes RGB565. Kompression könnte nur den schnellen
Unix-Socket-Weg verkürzen; vor USB müsste der Daemon wieder dekomprimieren und
dieselbe Pixelmenge übertragen. Row-Diffing und gegebenenfalls Multi-Rect-Blits
reduzieren die Daten dort, wo es zählt: vor dem USB-Transfer.

### Kein Shared-Memory-Framebuffer und kein In-Process-Daemon

Der gemessene IPC-Anteil liegt unter 1 ms, während USB und Panel mehrere
Millisekunden benötigen. Privilegtrennung, Crash-Isolation und eine über
Client-Neustarts stabile Hardware-Session sind wertvoller. Shared Memory bleibt
nur ein Escape-Hatch, falls zukünftiges Profiling den Socket-Transport wider
Erwarten als Engpass ausweist.

### Kein Spalten-Cropping

Display-Diffs bleiben Full-Width. Die Hardwaremessungen zeigen einen
Ingest-Penalty für schmale Fenster; AP2 trennt nur Zeilenbänder.
