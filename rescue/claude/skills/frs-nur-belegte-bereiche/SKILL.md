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

## Ablauf mit den Werkzeugen

1. `sudo frs-lesen partitionen /dev/sdX` und `sudo frs-lesen dateisystem /dev/sdXN`: Welche Partition
   ist das NTFS mit den Daten? Bei LDM zuerst `frs-partitionen-ldm`.
2. **Neuer Fall:** `sudo frs-aufgabe retten /dev/sdX --domain /dev/sdXN`. Das Werkzeug schützt die
   Quelle, legt den Fall an, erzeugt aus der NTFS-Bitmap der Quelle zwei Domains (`domain-mft.map`
   für die MFT, `domain.map` für die belegten Cluster) und startet die Rettung. Phase 0 liest erst die
   MFT, dann die belegten Cluster. Danach holen die Phasen 1 bis 3 den Rest in derselben Mapfile.
3. **Schon angelegter Fall, noch nicht über Phase 1 hinaus** (etwa nach einem Abbruch):
   `sudo frs-aufgabe domain FALL /dev/sdXN`, dann `sudo frs-aufgabe fortsetzen FALL /dev/sdX`.
4. Stand mit `sudo frs-aufgabe stand`. Reicht die Zeit oder hält die Disk nicht durch, kann der
   Techniker nach Phase 0 abbrechen: Die belegten Daten sind dann schon im Image.

## Wann der Techniker entscheidet

- **Abbrechen nach Phase 0 oder weiterlesen?** Das ist eine Abwägung zwischen Zeit, Risiko für die
  Disk und dem Wert von Gelöschtem im freien Bereich. Vorlegen, nicht selbst entscheiden.
- **Einzelne Dateien vor allem anderen** (Datenläufe aus der MFT): Eine eigene Domain dafür kann
  `frs-aufgabe` nicht erzeugen. Der Techniker richtet sie bei Bedarf selbst ein.

## Stolpersteine

- Das Ziel für ein sparse Image muss sparse Dateien können: ext4 ja. Auf NTFS legte der
  Kerneltreiber ntfs3 die Datei in einem Fall nicht sparse an, ntfs-3g schon. exFAT kann es nicht.
- Eine Domain aus der Bitmap enthält keine Daten aus freiem Platz. Gelöschte Dateien, die nur
  noch im freien Bereich liegen, findet erst ein vollständiger Lauf mit Carving (Skill `frs-carving`).
