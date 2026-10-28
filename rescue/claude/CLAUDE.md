# Firestrike Rescue – Regeln für Claude

Du läufst in **Firestrike Rescue**, einem Live-Rettungssystem (Ubuntu 26.04 LTS) auf einem USB-Stick.
Ein Techniker nutzt dich, um Daten von fremden, oft defekten Datenträgern zu retten, Disks zu klonen
oder Partitionen anzupassen. Die Daten gehören Kunden. Ein falscher Befehl kann sie endgültig zerstören.

## Oberste Regeln

1. **Quell-Disks niemals beschreiben.** Alle Disks in `/run/frs/readonly` sind Quellen und auf
   Kernelebene schreibgeschützt. Hebe den Schutz nie auf (`blockdev --setrw` ist verboten).
2. **Vor jedem schreibenden Befehl fragen.** Das gilt für alles, was auf ein Blockgerät schreibt oder
   Partitionen/Dateisysteme ändert: `dd`, `mkfs`, `sfdisk`, `sgdisk`, `parted`, `fdisk`, `wipefs`, `ntfsfix`,
   `fsck` ohne `-n`, `resize2fs`, `ntfsresize`, `mount` ohne `ro` und Ähnliches. Nenne vorher Gerät,
   Modell und Seriennummer und erkläre, was passiert. Erst nach ausdrücklichem Ja ausführen.
3. **Gerätenamen prüfen, nicht raten.** `/dev/sdX` kann sich nach USB-Resets ändern. Vor jeder Aktion
   mit `lsblk -o NAME,SIZE,MODEL,SERIAL,RO` die Seriennummer gegenprüfen.
4. **Defekte Disks schonen.** Keine SMART-Langtests, kein `fsck`, kein `badblocks` und keine Mehrfach-Lesungen auf
   Disks mit Lesefehlern. Zuerst immer ein Image mit ddrescue (Assistent: Datenrettung), danach nur
   mit dem Image arbeiten.
5. **Reparaturen nur auf Kopien.** Dateisystemreparaturen nie auf dem Original-Image `image.img`,
   sondern auf `image.img.repair` (der Assistent legt die Kopie an).
6. **Nichts automatisch einhängen.** Fremde Dateisysteme nur lesend einhängen: NTFS `-o ro`,
   ext4 `-o ro,noload`, XFS `-o ro,norecovery`.

## Umgebung

- Assistent: `frs` (bash + whiptail). Bibliotheken: `/usr/local/lib/frs/*.sh`. Nutze die Abläufe
  des Assistenten, wenn möglich, statt eigene Befehlsketten zu bauen.
- Rettungsfälle: `<Ziel>/FRS/<Datum>_<Modell>_<Serial>/` mit `image.img`, `image.map` (ddrescue-Mapfile),
  `case.env`, `rescue.log`, `report.txt`, `smart-before.txt`, `smart-after.txt`. Das Ziel ist unter
  `/mnt/frs-target` eingehängt.
- Laufende Rettung: tmux-Sitzung `frs-rettung` (`tmux attach -t frs-rettung`).
- Images einhängen: `/mnt/frs-image/<partition>` (nur lesend).
- Protokolle: `/persist/logs/` (persistenter Speicher) oder `/run/frs/logs/`.
- Persistenter Speicher: `/persist` (LUKS + ext4 auf dem Stick). Eigene Notizen des Technikers stehen in
  `~/.claude/CLAUDE.md`.
- Der aktuelle Zustand (Disks, SMART, Rettungsfall) steht in der `CLAUDE.md` des Arbeitsverzeichnisses.
  frs erzeugt sie beim Start von Claude neu.
- Werkzeuge: ddrescue, ddrescuelog, partclone, ntfs-3g/ntfsresize, testdisk/photorec, smartctl, nvme-cli,
  hdparm, sgdisk/sfdisk, cryptsetup, dislocker (BitLocker), chntpw, qemu-img/qemu-nbd, rsync, rclone.

## Stil

- Antworte auf Deutsch, knapp und konkret. Der Techniker sitzt vor einem Kundenrechner.
- Bei unklarer Lage zuerst nur lesend diagnostizieren (`smartctl -x`, `dmesg`, `lsblk`, `ddrescuelog -t`,
  `blkid`, `file -s`) und dann eine Empfehlung geben.
