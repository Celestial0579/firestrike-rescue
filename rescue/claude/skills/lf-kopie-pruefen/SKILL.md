---
name: lf-kopie-pruefen
description: Dateien aus dem Image auf das bestätigte Ziel kopieren und die Kopie mit Prüfsummen gegen das Image prüfen. Nutzen, wenn ein Image fertig ist und die Daten des Kunden auf das Ziel sollen.
---

# Kopie aufs Ziel und Prüfung

## Ablauf

1. **Image einbinden und einhängen** (nur lesend):
   `sudo lf-aufgabe image FALL`, dann `sudo lf-aufgabe einhaengen /dev/loopNpM`.
   Die Partition liegt dann unter `/mnt/lf-image/loopNpM`.
2. **Mit dem Techniker klären, was kopiert wird.** Meist die Benutzerordner und Datenordner, nicht
   das Betriebssystem. Papierkorb (`$RECYCLE.BIN`) und `System Volume Information` gehören in der
   Regel nicht dazu. Das Ziel bestimmt der Techniker im Assistenten.
3. **Kopieren:** `sudo lf-aufgabe kopieren /mnt/lf-image/loopNpM/<Ordner> <Name>`. Ziel ist
   `<Ziel>/LF/claude/<Name>/`. Große Kopien dauern. Den Befehl im Hintergrund laufen lassen und mit
   `sudo lf-aufgabe stand` verfolgen.
4. **Prüfen:** `sudo lf-aufgabe pruefen /mnt/lf-image/loopNpM/<Ordner> <Name>`. Es vergleicht jede
   Datei per Prüfsumme mit dem Image und schreibt das Ergebnis nach
   `<Ziel>/LF/claude/<Name>.pruefung.txt`. Erwartet: keine Abweichung.
5. **Abweichungen:** Datei für Datei nennen. Liegt eine Datei in einem unlesbaren Bereich des Images,
   ist sie dort schon beschädigt (Skill `lf-bericht`). Sonst ein zweites Mal kopieren.

## Virenscan

Das Rettungssystem bringt keinen Virenscanner mit. **Den Techniker darauf hinweisen**: Die geretteten
Dateien vor der Übergabe auf einem eigenen, aktuellen System scannen (etwa ClamAV mit frischen
Signaturen oder der Scanner des Kunden). Das Ergebnis gehört in den Bericht.

## Lehren

- Ziel unter Windows: NTFS oder exFAT, dann liest der Kunde es ohne Zusatzprogramme. Rechte und
  Eigentümer aus dem Image gehen dabei verloren, die Dateien bleiben gleich.
- Das Image erst löschen, wenn der Kunde alle Daten geprüft und bestätigt hat. Das entscheidet der
  Techniker.
