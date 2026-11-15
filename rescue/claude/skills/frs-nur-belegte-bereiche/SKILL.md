---
name: frs-nur-belegte-bereiche
description: Bei NTFS nur die belegten Cluster oder einzelne wichtige Dateien zuerst lesen, über eine Domain-Mapfile für ddrescue aus der Belegungs-Bitmap oder der MFT. Nutzen, wenn die Quelle groß und nur zum Teil belegt ist, wenn sie hängt oder wenn bestimmte Dateien zuerst gerettet werden müssen.
---

# Nur belegte Bereiche lesen (NTFS)

Ist eine Disk nur zu einem Viertel belegt, sind drei Viertel der Lesezugriffe auf die kranke Disk
überflüssig. ddrescue kann sich auf eine Domain beschränken: eine Mapfile, die nur die Bereiche
nennt, die gelesen werden sollen. Das Image bleibt sparse und belegt nur so viel Platz wie die Daten.

## Reihenfolge

1. **Partitionstabelle und Lage des Volumes:** `sudo frs-lesen partitionen /dev/sdX`. Bei dynamischen
   Datenträgern (LDM) zuerst Skill `frs-partitionen-ldm`, dort steht, wo das Volume wirklich beginnt.
2. **Verwaltung zuerst:** GPT am Anfang und Ende, Bootsektor des Volumes, die MFT. Sie sind klein
   und müssen vollständig gelesen sein, bevor der Rest beginnt (siehe `frs-image-zuerst`, Lehren).
3. **Belegte Cluster:** Domain aus der NTFS-Bitmap (`ddru_ntfsbitmap` aus ddrutility). Damit liest
   ddrescue nur Cluster, in denen Daten liegen.
4. **Wichtiges vorziehen (optional):** Aus der geretteten MFT lassen sich die Datenläufe einzelner
   Dateien berechnen (Pfad passt auf ein Muster) und als eigene Domain vor allen anderen lesen.
5. **Der Rest:** freie Bereiche zuletzt, wenn noch Zeit ist und die Disk durchhält.

## Wer was macht

- Die Rettung mit Domain kann `frs-aufgabe` noch nicht starten: `frs-aufgabe retten` liest die ganze
  Disk in Phasen. **Den Domain-Lauf richtet der Techniker ein**, mit ddrescue und der Option `-m`
  in derselben Mapfile wie der Rettungsfall. Danach setzt `sudo frs-aufgabe fortsetzen FALL /dev/sdX`
  den vollständigen Lauf fort, ohne schon Gelesenes erneut zu lesen.
- Claude kann vorbereiten und erklären: Lage des Volumes, Clustergröße (`sudo frs-lesen dateisystem`),
  welche Pfade wichtig sind, wie viel Platz belegt ist.

## Stolpersteine

- Das Ziel für ein sparse Image muss sparse Dateien können: ext4 ja. Auf NTFS legte der
  Kerneltreiber ntfs3 die Datei in einem Fall nicht sparse an, ntfs-3g schon. exFAT kann es nicht.
- Eine Domain aus der Bitmap enthält keine Daten aus freiem Platz. Gelöschte Dateien, die nur
  noch im freien Bereich liegen, findet erst ein vollständiger Lauf mit Carving (Skill `frs-carving`).
