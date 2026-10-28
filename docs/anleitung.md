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

Datenrettung
------------

Du brauchst immer eine **Ziel-Disk**, die mindestens so groß ist wie die defekte Disk.

1. **Quelle wählen.** Der Assistent schützt sie sofort gegen Schreiben.
2. **Ziel wählen.** Du kannst eine vorhandene Partition mit genug Platz nehmen oder die Disk neu formatieren. ext4 ist empfohlen, exFAT ist auch unter Windows lesbar.
3. **ddrescue läuft in drei Phasen:**
   1. schneller Durchlauf, schwache Stellen überspringen
   2. rückwärts über die übersprungenen Stellen
   3. Fehlerstellen gezielt mit Wiederholungen

   Mit **Strg+B, D** verlässt du die Ansicht, die Rettung läuft weiter. Bei Stromausfall, USB-Abbruch oder Neustart geht es über **„Unterbrochene Rettung fortsetzen“** genau dort weiter, wo der Lauf aufgehört hat.
4. **Mit dem Image weiterarbeiten:**
   - Dateien kopieren (rsync oder Midnight Commander). BitLocker geht mit dem Wiederherstellungsschlüssel.
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

- **Claude (CLI):** Claude startet im Terminal und kennt den aktuellen Zustand: Disks, SMART, Rettungsfall und Protokoll. Beim ersten Mal tippst du `/login` und öffnest die angezeigte URL am Handy. Den Code fügst du dann ein.
- **Claude Desktop:** Startet die offizielle Desktop-App im Vollbild. Schließt du die App, kommst du zurück zum Assistenten. Dafür brauchst du eine funktionierende Grafik. Klappt das nicht, nimm die CLI.
- Beide brauchen Internet. LAN geht automatisch, WLAN richtest du unter Werkzeuge > Netzwerk ein.
- Für Claude gelten die Regeln aus `/etc/claude-code/CLAUDE.md`, zum Beispiel: Quelle nie beschreiben, vor schreibenden Befehlen fragen. Eigene Ergänzungen kommen in `~/.claude/CLAUDE.md` (Werkzeuge > Persistenter Speicher).

Fernzugriff
-----------

Werkzeuge > SSH schaltet SSH ein und zeigt Adresse und Einmal-Passwort. Eine laufende Rettung siehst du per SSH mit `tmux attach -t frs-rettung`.
