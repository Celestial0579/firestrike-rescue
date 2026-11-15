---
name: frs-carving
description: Dateien ohne funktionierendes Dateisystem anhand ihres Inhalts finden (PhotoRec), immer auf dem Image. Nutzen, wenn sich ein Dateisystem nicht einhängen lässt, Dateien gelöscht wurden oder nach der normalen Kopie noch etwas fehlt.
---

# Carving mit PhotoRec

PhotoRec sucht Dateien an ihren Signaturen (Kopf und Aufbau), auch wenn das Dateisystem zerstört
ist. Ergebnis sind Dateien ohne Namen und Ordner, sortiert nach Typ. Das ist der letzte Weg, nicht
der erste.

## Voraussetzungen

- Ein fertiges Image (Skill `frs-image-zuerst`). PhotoRec läuft nie auf der Quelle.
- Genug Platz auf dem Ziel. Carving findet oft viel mehr als erwartet, auch alte, gelöschte Dateien.

## Ablauf

1. Vorher klären, was gesucht wird (Fotos, Office-Dokumente, eine bestimmte Datei?). Das grenzt die
   Dateitypen ein und spart Zeit und Platz.
2. **Der Techniker startet PhotoRec im Assistenten:** Unterbrochene Rettung fortsetzen / Image
   weiterverwenden > "Dateien mit PhotoRec suchen". Ergebnisse landen im Rettungsfall unter
   `photorec/`. PhotoRec ist interaktiv. Claude erklärt die Auswahl: Partition, Dateisystemtyp,
   "Whole" (ganze Partition) oder "Free" (nur freier Platz, für Gelöschtes).
3. Ergebnisse sichten: Claude liest die Ordner auf dem Ziel und fasst zusammen (Anzahl je Typ,
   Größen). Welche Funde der Kunde bekommt, entscheidet der Techniker.

## Lehren

- Erst die normale Kopie aus dem eingehängten Image, dann Carving für das, was fehlt.
- Fragmentierte große Dateien (Videos, Datenbanken) kommen beim Carving oft beschädigt heraus.
  Im Bericht so benennen.
