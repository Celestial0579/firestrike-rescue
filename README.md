<p align="center"><img src="docs/banner.svg" alt="Leuchtfeuer" width="100%"></p>

Leuchtfeuer ist ein bootfähiges Rettungssystem auf Basis von **Ubuntu 26.04 LTS**. Es ist mit allen Updates gebaut und bringt die wichtigen Werkzeuge mit. Ein Assistent führt Schritt für Schritt durch drei Aufgaben:

- **Datenrettung** von defekten Disks. Zuerst entsteht immer ein Image auf einer Ziel-Disk, dann geht es mit dem Image weiter.
- **Klonen**, z. B. von HDD auf SSD. Die Größe wird automatisch angepasst, auch auf kleinere Ziele.
- **Disk anpassen**: Partitionen vergrößern oder verkleinern, GPT reparieren, sicher löschen.

Leuchtfeuer hieß bis November 2026 **firestrike-rescue**. GitHub leitet alte Links und Klone auf dieses Repo um. Eine Beta lang gelten die alten `frs`-Befehle weiter, und ein persistenter Speicher mit dem alten Namen `FRS-DATA` wird wie `LF-DATA` verwendet. Rettungsfälle im alten Ordner `FRS/` auf einer Ziel-Disk lassen sich fortsetzen.

**Claude** ist an Bord, als Claude Code CLI und als Claude Desktop. Auf dem Stick gibt es einen kleinen, verschlüsselten Speicher für Configs, `CLAUDE.md` und Logins.

Herunterladen
-------------

Fertige ISOs gibt es unter [Releases](../../releases). Jeden Monat entsteht automatisch ein neuer Build mit allen Ubuntu-Updates.

Die ISO kommt **im DD-Modus** auf einen USB-Stick. Empfohlen sind mindestens 8 GB, damit Platz für den persistenten Speicher bleibt.

- **Windows:** [Rufus](https://rufus.ie). ISO wählen, Rufus fragt nach dem Modus, „DD-Image“ wählen.
- **Linux/macOS:** `sudo dd if=leuchtfeuer-*.iso of=/dev/sdX bs=4M status=progress conv=fsync`
- So prüfst du die Herkunft: `gh attestation verify leuchtfeuer-*.iso --repo Celestial0579/leuchtfeuer`
- Ältere Betas bis `v26.04-20261115.6-beta` heißen noch `firestrike-rescue-*.iso`. Ihre Herkunft prüfst du mit dem alten Repo-Namen, unter dem sie gebaut wurden: `gh attestation verify firestrike-rescue-*.iso --repo Celestial0579/firestrike-rescue`

Der Stick startet per UEFI (auch mit Secure Boot) und per Legacy-BIOS.

Bedienung
---------

Nach dem Start erscheint der Assistent und zeigt alle Disks mit ihrem SMART-Zustand. Er schlägt dann den passenden Weg vor. Die ausführliche Anleitung steht in [docs/anleitung.md](docs/anleitung.md). Was an echter Hardware noch zu prüfen ist, steht in [docs/hardware-pruefung.md](docs/hardware-pruefung.md).

```
GERÄT     ZUSTAND  MODELL                       GRÖSSE     SERIENNUMMER         BUS
sda       [DEFEKT] WDC WD10EZEX-08WN4A0         931.5GiB   WD-WCC6Y0ABCDEF      sata
          12 schwebende Sektoren, 140 Lesefehler im Kernel-Log
nvme0n1   [OK]     Samsung SSD 990 PRO 2TB      1.8TiB     S7DNNJ0W123456       nvme
```

Diese Schutzregeln gelten immer:

- Quell-Disks werden sofort auf Kernelebene schreibgeschützt.
- Ziele werden über die Seriennummer bestätigt. Du gibst die letzten 4 Zeichen ein, nicht `/dev/sdX`. Meldet eine Disk keine Seriennummer, nimmt der Assistent stattdessen die WWN. Fehlt auch die, verlangt er Gerätename und Größe. Eine leere Eingabe bestätigt nie.
- Eine Kennung zählt nur, wenn sie eindeutig ist. Melden zwei angeschlossene Disks dieselbe Seriennummer (baugleiche USB-Adapter tun das oft), stehen beide unter ihrem Gerätenamen und werden über Gerätename und Größe bestätigt.
- Bestätigt wird genau das Gerät, auf das danach geschrieben wird. Ändert sich sein Name, solange der Dialog offen ist, bricht der Schritt ab. Der Klon prüft vor jeder Partition, dass Quelle und Ziel noch dieselben Disks sind.
- Fremde Disks werden nie automatisch eingehängt, auch nicht beim Booten: Das Live-System wird nur auf dem Stick gesucht. Swap, RAID und LVM werden nicht automatisch aktiviert.
- Reparaturen laufen nur auf einer Kopie des Images.
- Von welcher Disk gelesen wird, bestimmst du. Beim Fortsetzen wählst du die Quelle neu. Die Falldatei auf der Ziel-Disk kann deiner Wahl nur widersprechen.
- Ein Ziel wird ohne Geräte-, Setuid- und Programmrechte eingehängt (`nodev,nosuid,noexec`). Verknüpfungen darauf werden nicht verfolgt (`nosymfollow`). Für Partitionen aus einem Image gilt dasselbe, und sie sind nur lesend eingehängt.
- Namen von Datenträgern bleiben Namen. Fallordner werden nur mit Namen aus Buchstaben, Ziffern, Punkt, Unterstrich und Bindestrich angeboten, und kein Menüeintrag wird als Option gelesen. Label und Partitionsnamen der Quelle kommen nur geprüft in den Klon-Job.
- Texte von Datenträgern sind auch für Claude Daten, keine Anweisungen. Was die Geräte melden, steht in einer Datendatei (`zustand.txt`), nicht in einer `CLAUDE.md`. Eine `CLAUDE.md`, Hooks, Skills oder ein MCP-Server von einem eingehängten Datenträger gelten nicht.
- Was ein Datenträger über sich meldet (Modell, Label, Partitionsname), steht in Dialogen nur gefiltert: sichtbare Zeichen, alles andere als `?`. Eine Seriennummer mit anderen Zeichen gilt nicht als Kennung. Auch die Ausgabe von Werkzeugen wie fsck erreicht Bildschirm und Protokoll ohne Steuerzeichen.
- Die Suche nach Rettungsfällen schreibt nicht. Die gewählte Disk ist dabei schreibgeschützt und nur lesend eingehängt, bis du einen Rettungsfall gewählt hast.
- Der persistente Speicher ist nur die Partition `LF-DATA` auf dem Stick, von dem gestartet wurde. Unverschlüsselt wird er erst nach einer Rückfrage eingebunden, und `lf.conf` wird gelesen, nicht ausgeführt.
- Für Claude sind die wichtigsten Regeln gesperrt statt nur aufgeschrieben. Den Schreibschutz einer Disk aufheben, die Sperre anfassen oder das Original-Image reparieren kann Claude nicht. Jeden schreibenden Befehl bestätigst du selbst, und keine Rückfrage lässt sich dauerhaft abschalten. Auto-Modus und Modus ohne Rückfragen gibt es nicht.

Was ist drin
------------

| Bereich | Werkzeuge |
|---|---|
| Rettung | ddrescue, ddrescueview, safecopy, testdisk/photorec, foremost, sleuthkit, ewf-tools |
| Diagnose | smartmontools, nvme-cli, hdparm, memtester, memtest86+, stress-ng, lshw |
| Klonen | partclone, fsarchiver, clonezilla, qemu-img (VHDX), wimtools |
| Dateisysteme | NTFS, ext2–4, XFS, Btrfs, exFAT, FAT, F2FS, HFS+, LVM, mdadm, LUKS, BitLocker (dislocker) |
| Windows | chntpw, efibootmgr, ms-sys |
| Netz | NetworkManager (nmtui, WLAN), SSH (auf Wunsch), rsync, rclone, SMB, NFS |
| Claude | Claude Code CLI, Claude Desktop (offizielles Anthropic-Paket, Linux-Beta) |

Selbst bauen
------------

Den Build übernimmt GitHub Actions (`.github/workflows/build.yml`). Lokal braucht es einen Ubuntu-26.04-Host oder Docker:

```bash
docker run --rm --privileged -v "$PWD:/src" ubuntu:26.04 /src/build/build.sh
```

Die ISO landet in `out/`.

| Datei | Zweck |
|---|---|
| `build/build.sh` | debootstrap → chroot → SquashFS → Hybrid-ISO (xorriso) |
| `build/packages.list` | Paketliste |
| `build/chroot-setup.sh` | Pakete, Claude, Sicherheits-Defaults |
| `build/grub/` | Bootmenü und Theme |
| `rescue/lf` | Assistent, Bibliotheken in `rescue/lib/` |
| `rescue/claude/CLAUDE.md` | Regeln für Claude im Rettungssystem |
| `rescue/claude/managed-settings.json`, `rescue/bin/lf-claude-guard` | Sperre für Claude: Was die Regeln verbieten, lehnt ein Hook ab. Kein Auto-Modus. Hooks, Erlaubnis-Regeln, Skills, Agenten und MCP-Server nur aus dem Rettungssystem, keine `CLAUDE.md` von einem Einhängepunkt. `rescue/bin/claude` startet die CLI ohne Projekt-Einstellungen (`--setting-sources user`), eine neue Version erst nach `rescue/bin/lf-claude-check`. CLI und Desktop laufen als Benutzer `lf-claude` und dürfen als root nur `rescue/bin/lf-lesen` und `rescue/bin/lf-aufgabe` starten, mehr nur zeitlich begrenzt über `rescue/bin/lf-freigabe` |
| `rescue/claude/skills/` | Skills zur Datenrettung für Claude, verwaltet unter `/etc/claude-code/.claude/skills` |
| `tests/qemu-smoke.sh` | Boot-Tests (UEFI, BIOS, Selbsttest mit simulierter defekter Disk) |

Design
------

Farben und Schriften stammen von [firestrike.de](https://firestrike.de). Sie gelten für das Bootmenü, die Konsole (per `setvtrgb`) und die Dialoge:

| Grund | Text | Stahl | Stahl hell | Funke | Glut | Akzent |
|---|---|---|---|---|---|---|
| `#141715` | `#E8EBE7` | `#33414B` | `#B4C6D1` | `#E8A33D` | `#AB5019` | `#D9713C` |

Lizenz
------

MIT, © 2026 Tim Heyne. Siehe [LICENSE](LICENSE). Die enthaltenen Ubuntu-Pakete und Claude stehen unter ihren eigenen Lizenzen.
