---
name: lf-partitionen-ldm
description: Partitionstabellen, dynamische Windows-Datenträger (LDM) und verlorene Partitionen untersuchen, nur lesend. Nutzen, wenn Partitionen fehlen, ein Volume nicht einhängbar ist oder die Disk unter Windows als dynamischer Datenträger eingerichtet war.
---

# Partitionen und dynamische Datenträger

## Ablauf

1. **Tabelle lesen:** `sudo lf-lesen partitionen /dev/sdX` (bei einem Image: zuerst
   `sudo lf-aufgabe image FALL`, dann das Loop-Gerät). GPT oder MBR, Lage und Größe jeder Partition.
2. **Dateisysteme erkennen:** `sudo lf-lesen dateisystem /dev/sdXN` für jede Partition.
3. **Dynamischer Datenträger (LDM):** Eine Partition vom Typ "Microsoft LDM metadata" bzw.
   "LDM data" zeigt das an. `sudo lf-lesen ldm /dev/sdX` liest die LDM-Metadaten und nennt die
   Volumes mit ihrem Anfang. Wichtig: einfaches Volume, Spiegel, Stripe oder übergreifend? Nur ein
   einfaches Volume lässt sich direkt aus dem Image einhängen.
4. **Einhängen zum Prüfen:** `sudo lf-aufgabe einhaengen /dev/loopNpM`, immer nur lesend.

## Verlorene oder beschädigte Partitionstabelle

- testdisk findet Partitionen anhand ihrer Signaturen. Es läuft **nur auf dem Image** und nur mit
  "Analyse", nie mit "Write". Es ist interaktiv. **Den Techniker bitten**, es im Assistenten
  (Werkzeuge > Shell) auf dem Image zu starten. Claude erklärt, was die Ausgabe bedeutet.
- Eine Partitionstabelle wird nie auf der Quelle geschrieben. Eine Korrektur gehört auf eine Kopie
  des Images und ist eine Entscheidung des Technikers.

## Nicht tun

- Kein `fdisk`, `sgdisk`, `parted`, `testdisk … Write` auf Quelle oder Image. Mit den lf-Werkzeugen
  geht das ohnehin nicht. Vorschlagen ja, ausführen nein.
- BitLocker: Die Partition braucht den Wiederherstellungsschlüssel. Das Einhängen macht der
  Techniker im Assistenten (Image weiterverwenden > Dateien kopieren).
