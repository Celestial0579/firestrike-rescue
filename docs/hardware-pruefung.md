Prüfung an echter Hardware
==========================

Die CI prüft Firestrike Rescue nur mit Attrappen, Loop-Geräten und in QEMU. Diese Anleitung ist
die Liste für einen Testrechner mit echten Disks (Issue #34). Hake erledigte Punkte im Issue ab.
Jede Abweichung wird ein eigenes Issue mit Version, Rechner und Foto oder Protokoll.

Bis alle Punkte geprüft sind, bleibt jedes Release eine Beta.

Vorbereitung
------------

- **Version:** das neueste Release, mit Prüfsumme (`sha256sum -c SHA256SUMS`) und Herkunft (`gh attestation verify <iso> --repo Celestial0579/firestrike-rescue`) geprüft
- **Sticks:** zwei USB-Sticks ab 8 GB, mit Rufus (DD-Modus), balenaEtcher oder `dd` beschrieben
- **Testrechner:**
  - einer mit UEFI, bei dem sich Secure Boot ein- und ausschalten lässt
  - einer mit BIOS oder CSM
- **Disks:**
  - eine Disk mit bekannten Lesefehlern, sonst eine alte HDD mit schlechten SMART-Werten
  - eine gesunde Windows-Disk mit BitLocker, dazu der Wiederherstellungsschlüssel
  - zwei Ziel-Disks: eine kleiner, eine größer als die Quelle
- **Adapter:** zwei baugleiche USB-SATA-Adapter
- **Fürs Protokoll:** ein Handy für Fotos vom Bildschirm. Die Protokolle des Assistenten liegen unter `/persist/logs` (mit persistentem Speicher) oder `/run/frs/logs` (ohne).

Notiere zu jedem Punkt die Version (`frs --version`), das Rechnermodell und das Ergebnis.

1 Start
-------

| Prüfung | Erwartet |
|---|---|
| UEFI mit Secure Boot, vom Stick | Bootmenü „Firestrike Rescue“, nach 10 s startet der Assistent auf tty1 |
| UEFI ohne Secure Boot | wie oben, zusätzlich der Eintrag memtest86+ |
| BIOS oder CSM | wie oben |
| Eintrag „in den RAM laden“, Stick danach abziehen | Der Assistent und die Werkzeuge laufen weiter |
| Sicherer Grafikmodus | Bild ohne Grafiktreiber |

Nach jedem Start in der Shell (Werkzeuge > Shell):

```bash
cat /run/frs-boot.env
```

`FRS_BOOT_DEV` ist der Stick, `FRS_BOOT_DISKS=1`.

2 Startkette mit fremden Disks (GHSA-fgc3-pr99-9chm)
----------------------------------------------------

Das Rettungssystem darf nur vom eigenen, geprüften Medium starten, auch wenn fremde Disks
angeschlossen sind.

1. **Fremde Disk mit GRUB-Konfiguration:**
   - Einen zweiten Stick mit FAT32 formatieren und die Dateien `/.disk/info` (beliebiger Text) und `/boot/grub/grub.cfg` mit diesem Inhalt anlegen:
     ```
     echo "GEKAPERT"
     sleep 30
     ```
   - Beide Sticks anstecken, den fremden möglichst an den ersten Anschluss, und per UEFI vom Firestrike-Stick starten.
   - Erwartet: Vor dem Bootmenü steht kurz „Firestrike Rescue: Startmedium (…) auf derselben Disk“, nie „GEKAPERT“.
2. **Zwei Sticks mit derselben ISO:**
   - Den zweiten Stick mit derselben ISO beschreiben. Beide anstecken und von einem starten.
   - Erwartet: Das System startet. `cat /run/frs-boot.env` zeigt `FRS_BOOT_DISKS=2`. Der Assistent bindet keinen persistenten Speicher ein, und das Anlegen eines Speichers lehnt er mit einer Meldung ab.
3. **Nur der fremde Stick aus Schritt 1** und die Firmware startet von ihm: Er bootet nichts, was wie Firestrike Rescue aussieht. Das ist eine Gegenprobe, kein Fehler.

3 Persistenter Speicher
-----------------------

1. Frischen Stick starten. Beim ersten Start einen verschlüsselten Speicher mit 2 GiB anlegen, neu starten, Passphrase eingeben.
   Erwartet: `findmnt /persist` zeigt die Partition `FRS-DATA` auf dem Stick, mit `nodev,nosuid`.
2. Dasselbe mit einem unverschlüsselten Speicher auf dem zweiten Stick: Der Assistent fragt vor dem Einbinden nach.
3. Eine Partition mit dem Label `FRS-DATA` auf einer anderen Disk anlegen und anschließen: Der Assistent verwendet sie nie, er weist nur auf sie hin.
4. **Wirkung von `nosuid`.** Der Selbsttest läuft als root und kann das nicht prüfen. Als Live-Benutzer in der Shell:
   ```bash
   sudo cp /usr/bin/id /persist/id-probe && sudo chmod 4755 /persist/id-probe
   /persist/id-probe -u; sudo rm /persist/id-probe
   ```
   Erwartet: Die Zahl ist die eigene Benutzer-ID (meist 999), nicht 0.

4 Datenrettung
--------------

1. **Defekte Disk über einen USB-Adapter retten,** Ziel ist eine ext4-Disk.
   Erwartet:
   - Die Quelle ist sofort schreibgeschützt (`blockdev --getro` ergibt 1).
   - Alle drei Phasen laufen.
   - `report.txt` und `smart-before.txt`/`smart-after.txt` liegen unter `FRS/…`.
2. **Während Phase 1 den USB-Adapter der Quelle abziehen, wieder anstecken** und „Unterbrochene Rettung fortsetzen“ wählen.
   Erwartet: Es geht an der Stelle weiter, an der der Lauf aufgehört hat. Mit einer anderen Disk statt der Quelle lehnt der Assistent ab.
3. **Neustart während der Rettung,** dann fortsetzen: wie Schritt 2.
4. **Ziel exFAT und Ziel NTFS** (eine vorhandene NTFS-Partition mit genug Platz): Die Rettung läuft, und das Image ist danach unter Windows lesbar.

5 Klonen
--------

1. **Auf eine größere Disk**, mit „Ziel ersetzt die Quelle“, dann nur das Ziel einbauen und starten.
   Erwartet: Windows oder Linux startet, und die Hauptpartition ist gewachsen.
2. **Auf eine kleinere Disk**, wenn die Daten passen.
   Erwartet: Der Assistent verkleinert die Hauptpartition, die Quelle bleibt unverändert (Prüfsumme der Quelle vorher und nachher). Das Ziel startet.
3. Klon mit „Beide bleiben“, dann beide Disks gleichzeitig anschließen: Beide starten, ohne sich zu verwechseln.

6 Image weiterverwenden
-----------------------

1. **BitLocker-Disk retten,** dann aus dem Image Dateien kopieren: Die Partition lässt sich mit dem Wiederherstellungsschlüssel öffnen. `findmnt` zeigt `ro,nodev,nosuid,noexec`.
2. Image in VHDX umwandeln und unter Windows einbinden.

7 Zwei baugleiche USB-Adapter
-----------------------------

Quelle und Ziel hängen an zwei baugleichen Adaptern.

Erwartet:
- Der Assistent unterscheidet die Disks.
- Die Auswahl passt zu der Disk, die du meinst: Abziehen und Disk-Liste aktualisieren.
- Melden beide Adapter dieselbe feste Seriennummer, verwendet der Assistent sie für keine der beiden Disks als Kennung, sondern das nächste Merkmal.

Notiere, was `lsblk -d -o NAME,MODEL,SERIAL,WWN,TRAN` für beide Disks zeigt.

8 Claude
--------

Nur mit Internet und eigenem Konto.

1. **Claude (CLI) über das Menü starten, `/login`.**
   Erwartet: Claude liest `zustand.txt`. Bitte Claude, eine Quell-Disk mit `blockdev --setrw` beschreibbar zu machen: Das Rettungssystem lehnt ab, ohne Rückfrage.
2. **Einen schreibenden Befehl von Claude vorschlagen lassen,** zum Beispiel `dd` auf eine Testdatei.
   Erwartet: Die Rückfrage nennt den Grund, „nicht mehr fragen“ gibt es nicht.
3. **In der Shell in einem Ordner auf einem fremden Datenträger `claude` starten.** Der Ordner hat eine `.claude/settings.json` mit `{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:9"}}`.
   Erwartet: Claude Code verbindet sich normal. Die Einstellung des Ordners gilt nicht.
4. **Neue Version der CLI:** Mit persistentem Speicher startet beim nächsten Start eine Aktualisierung.
   Erwartet: Vor dem ersten Start der neuen Version steht „Neue Version von Claude Code … wird geprüft“, danach „Bestanden.“. Das Ergebnis steht in `~/.local/state/frs/claude-check/`.
5. **Claude Desktop:** Die App startet im Vollbild, Login klappt, und nach Strg+Q geht es im Assistenten weiter. Prüfe außerdem, ob die Rückfragen aus Schritt 2 auch in der App kommen. Das ist bisher ungeprüft.

9 Selbsttest auf echter Hardware
--------------------------------

```bash
sudo frs --selftest | tee /persist/selftest-$(date +%F).txt
```

Erwartet: Die letzte Zeile ist `FRS-SELFTEST: PASS`. Die Datei gehört ins Issue.
