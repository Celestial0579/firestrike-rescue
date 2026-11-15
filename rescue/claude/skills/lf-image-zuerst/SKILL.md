---
name: lf-image-zuerst
description: Rettung einer kranken Disk als Image mit ddrescue in Phasen und Mapfile, die Quelle wird nie beschrieben. Nutzen, wenn eine Disk Lesefehler zeigt oder ihre Daten wichtig sind, bevor irgendetwas anderes mit ihr geschieht.
---

# Image zuerst

Grundregel: **Nie auf der kranken Disk arbeiten.** Erst ein vollständiges Image mit Mapfile, danach
nur noch mit dem Image. Jeder weitere Zugriff auf die Quelle kann ihr letzter sein. Die Mapfile
merkt sich jeden gelesenen Bereich, ein Abbruch kostet deshalb nur Zeit.

## Voraussetzungen (Entscheidung des Technikers)

- **Das Ziel wählt und bestätigt der Techniker im Assistenten** (Datenrettung, Schritt 2). Es muss
  mindestens so groß sein wie die Quelle. Auf ext4 wird das Image sparse geschrieben. Ist kein Ziel
  eingehängt, sagt `lf-aufgabe` das. Dann den Techniker bitten, es im Assistenten zu wählen.
- Vorher die Diagnose (Skill `lf-diagnose`).

## Ablauf

1. `sudo lf-aufgabe retten /dev/sdX`
   - schreibschützt die Quelle auf Kernelebene (`blockdev --setro`, auch alle Partitionen),
   - legt den Rettungsfall unter `<Ziel>/LF/<Datum>_<Modell>_<Kennung>/` an,
   - startet ddrescue im Hintergrund in drei Phasen: schneller Durchlauf ohne Nachlesen,
     rückwärts über die übersprungenen Stellen, zuletzt gezieltes Nachlesen der Fehlerstellen.
2. Stand verfolgen: `sudo lf-aufgabe stand`. Wichtig sind "rescued", "bad areas" und die Zeit
   seit dem letzten erfolgreichen Lesen. Nicht in kurzen Abständen abfragen, alle paar Minuten genügt.
3. Bricht der Lauf ab (Disk weg, Hänger, Neustart): Disk wieder anschließen lassen, dann
   `sudo lf-aufgabe fortsetzen FALL /dev/sdX`. Es geht an der Stelle weiter, die die Mapfile
   nennt. Ob die Disk zum Fall gehört, prüft das Werkzeug selbst.
4. Ist der Stand "done", nur noch mit dem Image arbeiten: `sudo lf-aufgabe image FALL`, dann die
   Partitionen mit `sudo lf-aufgabe einhaengen /dev/loopNpM`.

## Wann der Techniker entscheidet

- **Die Disk hängt oder verschwindet immer wieder:** Skill `lf-haengende-disk`. Weiteres
  Nachlesen kostet dann viel Zeit und belastet die Disk.
- **Sehr viele Fehlerstellen nach Phase 1:** Weiter nachlesen oder mit dem Erreichten weiterarbeiten?
  Das ist eine Abwägung zwischen Zeit, Risiko für die Disk und Wert der fehlenden Daten.
  Vorlegen, nicht selbst entscheiden.
- **NTFS und nur zum Teil belegt:** gleich mit `sudo lf-aufgabe retten /dev/sdX --domain /dev/sdXN`
  starten (Skill `lf-nur-belegte-bereiche`). Das schont die Disk und spart viel Zeit.

## Lehren

- Die Verwaltungsstrukturen des Dateisystems (bei NTFS die MFT und die Verzeichnisblöcke) zuerst
  vollständig retten. Fehlen dort Blöcke, wirkt das Dateisystem "dirty". Eine Reparatur (`chkdsk`,
  `ntfsfix`) entfernt dann ganze Ordnerbäume. Klon-Werkzeuge ohne Mapfile verlieren genau so Daten.
- Reparaturen nie auf dem Image `image.img`, nur auf einer Kopie (`image.img.repair`, legt der
  Assistent an). Das Image bleibt, bis der Kunde alle Daten geprüft hat.
- Unlesbare Bereiche sind im Image Nullen. Welche Dateien betroffen sind, steht im Bericht
  (Skill `lf-bericht`).
