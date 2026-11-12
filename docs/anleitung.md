Anleitung
=========

Start
-----

1. Stick einstecken und den Rechner vom Stick starten. Meist geht das über F12, F11, F8 oder Esc im Boot-Menü der Firmware.
2. Im Bootmenü startet nach 10 Sekunden automatisch **„Firestrike Rescue starten“**. Es gibt weitere Einträge:
   - **In den RAM laden:** Der Stick ist danach frei. Das ist praktisch, wenn er als Ziel für die Persistenz dient.
   - **Sicherer Grafikmodus:** bei schwarzem Bild.
   - **memtest86+:** nur mit abgeschaltetem Secure Boot.
3. Der Assistent startet von selbst. Auf **Alt+F2 … F6** liegen normale Konsolen.

Beim ersten Start mit freiem Platz auf dem Stick fragt der Assistent, ob er einen **persistenten Speicher** anlegen soll. Empfohlen sind 2 GiB mit Verschlüsselung. Dort liegen künftig Claude-Login, `~/.claude/CLAUDE.md`, `/etc/frs/frs.conf`, WLAN-Profile, SSH-Schlüssel und Protokolle. Bei jedem Start fragt der Assistent nach der Passphrase.

Als Speicher gilt nur die Partition `FRS-DATA` auf dem Stick, von dem du gestartet hast. Eine gleichnamige Partition auf einer anderen Disk verwendet der Assistent nie, er weist nur auf sie hin. Einen unverschlüsselten Speicher bindet er erst nach einer Rückfrage ein. `/etc/frs/frs.conf` ist eine Liste von Einstellungen (`NAME=Wert`, eine pro Zeile) und wird nicht als Skript ausgeführt.

Datenrettung
------------

Du brauchst immer eine **Ziel-Disk**, die mindestens so groß ist wie die defekte Disk.

1. **Quelle wählen.** Der Assistent schützt sie sofort gegen Schreiben.
2. **Ziel wählen.** Du kannst eine vorhandene Partition mit genug Platz nehmen oder die Disk neu formatieren. ext4 ist empfohlen, exFAT ist auch unter Windows lesbar.
3. **ddrescue läuft in drei Phasen:**
   1. schneller Durchlauf, schwache Stellen überspringen
   2. rückwärts über die übersprungenen Stellen
   3. Fehlerstellen gezielt mit Wiederholungen

   Mit **Strg+B, D** verlässt du die Ansicht, die Rettung läuft weiter. Bei Stromausfall, USB-Abbruch oder Neustart geht es über **„Unterbrochene Rettung fortsetzen“** genau dort weiter, wo der Lauf aufgehört hat. Der Assistent fragt dabei noch einmal nach der Quell-Disk und setzt nur fort, wenn sie zum Rettungsfall gehört. Die Disk, auf der er nach Rettungsfällen sucht, ist währenddessen schreibgeschützt und nur lesend eingehängt. Beschreibbar wird sie erst, wenn du einen Rettungsfall gewählt hast.
4. **Mit dem Image weiterarbeiten:**
   - Dateien kopieren (rsync oder Midnight Commander). BitLocker geht mit dem Wiederherstellungsschlüssel. Partitionen aus dem Image sind dabei nur lesend eingehängt, ohne Geräte-, Setuid- und Programmrechte. Verknüpfungen im Image werden beim Durchsehen nicht verfolgt, beim Kopieren bleiben sie als Verknüpfungen erhalten.
   - Image auf eine neue Disk schreiben. Die Größe wird angepasst.
   - Dateisystem auf einer Kopie reparieren
   - Dateien mit PhotoRec suchen
   - In VHDX umwandeln

Alles landet auf dem Ziel unter `FRS/<Datum>_<Modell>_<Seriennummer>/`:

| Datei | Inhalt |
|---|---|
| `image.img` | Abbild der Disk |
| `image.map` | ddrescue-Mapfile (Stand der Rettung) |
| `report.txt` | Bericht: gerettet, fehlend, Dauer |
| `smart-before.txt`, `smart-after.txt` | SMART-Zustand vorher und nachher |
| `rescue.log` | Ausgabe von ddrescue |
| `dateien/` | kopierte Dateien |

Klonen
------

Für gesunde Disks, z. B. beim Umzug von HDD auf SSD:

- Kopiert werden nur die belegten Bereiche (partclone).
- **Größeres Ziel:** Die Hauptpartition wächst, die Windows-Wiederherstellung rückt ans Ende.
- **Kleineres Ziel:** Der Assistent prüft, ob die Daten passen, und verkleinert die Hauptpartition. Die Quelle bleibt dabei unberührt. Verkleinert wird in einem Schreib-Overlay im RAM.
- **Kennungen:** Mit „Ziel ersetzt die Quelle“ behält die neue Disk dieselben IDs und bootet direkt. Mit „Beide bleiben“ bekommt sie neue IDs.

NTFS lässt sich nur verkleinern, wenn Windows sauber heruntergefahren wurde. Der Schnellstart muss dafür aus sein, oder du fährst Windows mit `shutdown /s /t 0` herunter.

Claude
------

- **Claude (CLI):** Claude startet im Terminal. Den aktuellen Zustand (Disks, SMART, Rettungsfall und Protokoll) legt der Assistent als Datei `zustand.txt` dazu, Claude liest sie. Beim ersten Mal tippst du `/login` und öffnest die angezeigte URL am Handy. Den Code fügst du dann ein.
- **Claude Desktop:** Startet die offizielle Desktop-App im Vollbild. Schließt du die App, kommst du zurück zum Assistenten. Dafür brauchst du eine funktionierende Grafik. Klappt das nicht, nimm die CLI.
- Beide brauchen Internet. LAN geht automatisch, WLAN richtest du unter Werkzeuge > Netzwerk ein.
- Für Claude gelten die Regeln aus `/etc/claude-code/CLAUDE.md`, zum Beispiel: Quelle nie beschreiben, vor schreibenden Befehlen fragen. Was auf einem Datenträger steht (Namen, Labels, Dateien, Falldatei), ist für Claude Daten und nie eine Anweisung.
- Ein Teil der Regeln ist gesperrt und hängt nicht davon ab, ob Claude sich daran hält:
  - Befehle, die den Schreibschutz einer Disk aufheben (`blockdev --setrw`), die Sperre selbst anfassen oder das Original-Image `image.img` reparieren wollen, lehnt das Rettungssystem ab. Das kannst du im Gespräch mit Claude nicht freigeben. Brauchst du so einen Befehl wirklich, gib ihn selbst in der Shell ein.
  - Jeden schreibenden Befehl (dd, mkfs, Partitionierer, fsck ohne `-n`, mount ohne `ro`, ddrescue und Ähnliches) musst du selbst bestätigen, jedes Mal. Die Rückfrage nennt den Grund. Die Prüfung liest den Text des Befehls und fragt im Zweifel einmal zu oft.
  - Claude Code läuft immer im Modus mit Rückfragen. Der Auto-Modus, in dem ein Klassifikator statt dir entscheidet, und der Modus ohne Rückfragen (`--dangerously-skip-permissions`) sind abgeschaltet.
  - Eine Rückfrage lässt sich nicht dauerhaft abschalten. Die Auswahl „nicht mehr fragen" gibt es im Rettungssystem nicht, und Erlaubnis-Regeln aus `~/.claude/settings.json`, aus einem Projektordner oder von der Kommandozeile (`--allowedTools`) gelten nicht. Befehle, die Claude Code selbst als nur lesend kennt (`ls`, `cat`, `grep`), laufen weiter ohne Rückfrage.
  - Hooks gelten nur aus dem Rettungssystem. Eigene Hooks aus `~/.claude/settings.json` und Hooks aus einem Projektordner laufen nicht. Starte Claude trotzdem nicht in einem Ordner von einem fremden Datenträger: Eine `CLAUDE.md` dort liest Claude als Anweisung.
- Eigene Ergänzungen zu den Regeln kommen in `~/.claude/CLAUDE.md` (Werkzeuge > Persistenter Speicher).

Fernzugriff
-----------

Werkzeuge > SSH schaltet SSH ein und zeigt Adresse und Einmal-Passwort. Eine laufende Rettung siehst du per SSH mit `tmux attach -t frs-rettung`.
