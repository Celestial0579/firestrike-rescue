---
name: lf-haengende-disk
description: Rettung einer Disk, die nach kurzer Zeit hängt oder verschwindet (typisch für SSD-Controller-Fehler). Modus hängende Disk (lf-aufgabe retten --haengt): kurze Timeouts, Abbruch statt Warten, Weiterlesen hinter der Hängerstelle, Warten auf dieselbe Disk nach ihrem Neustart. Nutzen, wenn ddrescue stehen bleibt, die Disk sich als "becoming ready" meldet oder vom Bus verschwindet.
---

# Hängende oder verschwindende Disk

Eine SSD, die "verschwindet", ist oft nicht tot. Häufig hängt sich der Controller nach einer
gewissen Betriebszeit auf, unabhängig davon, wo gerade gelesen wird. Nach einem Neustart liest sie
wieder normal. Dann lässt sich die Disk in vielen kurzen Läufen vollständig retten.

## Muster erkennen

- `sudo lf-lesen kernel`: Resets, Timeouts, "Logical unit is in process of becoming ready",
  die Disk taucht unter neuem Namen wieder auf.
- `sudo lf-aufgabe stand`: Der Lauf steht still, oder bricht immer nach ähnlicher Zeit ab.
- Bricht es nach ähnlicher Zeit ab, egal an welcher Stelle, spricht das für Controller oder
  Temperatur, nicht für defekten Speicher.

## Ablauf

1. **Rettung im Modus hängende Disk starten:** `sudo lf-aufgabe retten /dev/sdX --haengt`, oder
   eine laufende Rettung damit fortsetzen: `sudo lf-aufgabe fortsetzen FALL /dev/sdX --haengt`.
   Der Techniker wählt den Modus im Assistenten beim Anlegen des Falls ("Hängende Disk?").
   Dann gilt:
   - kurze Timeouts für die Quelle (5 s statt 30 und mehr), ddrescue gibt mit `-T` nach kurzer
     Zeit ohne erfolgreiches Lesen auf, statt minutenlang zu warten,
   - nach einem Hänger liest der Lauf 64 MiB hinter der Hängerstelle weiter. Die Lücke holen
     die späteren Phasen nach, für Phase 3 ein eigener Durchlauf,
   - antwortet die Disk nicht mehr, wartet der Lauf bis zu 30 Minuten auf genau diese Disk:
     Seriennummer oder WWN und Größe wie in der Falldatei, und nur, wenn genau eine solche Disk
     da ist. Die wiedergekehrte Disk wird sofort schreibgeschützt.
2. **Hängt die Disk:** `sudo lf-aufgabe stand` zeigt den Hänger. **Den Techniker bitten**, sie neu
   zu starten: Stromzufuhr trennen (Kabel oder Adapter abziehen), etwa 10 Sekunden warten, wieder
   anschließen. Der Lauf macht danach von selbst weiter. Fortsetzen von Hand braucht es nur,
   wenn der Lauf endet: nach 30 Minuten ohne die Disk, nach 100 Hängern, oder wenn der Fall nur
   einen Gerätepfad als Kennung hat. Dann `sudo lf-aufgabe fortsetzen FALL /dev/sdY`. Der
   Gerätename kann sich geändert haben: mit `sudo lf-lesen disks` an Modell und Seriennummer
   prüfen. Auch dann geht es hinter der Hängerstelle weiter.
3. Wiederholen, bis der Stand "done" ist oder der Techniker abbricht. Über die Mapfile geht kein
   gelesener Bereich verloren. Die Zahl der Hänger steht im Bericht.

Ohne den Modus helfen kurze Timeouts allein: `sudo lf-aufgabe timeout /dev/sdX 5`. Das gilt nur
für Disks, die schon als Quelle schreibgeschützt sind, und bis zum Abziehen.

Eine schaltbare Steckdose für den Neustart richtet nur der Techniker ein und löst nur er aus.
Das Rettungssystem steuert keine Geräte im Netz.

## Wann der Techniker entscheidet

- Jeder Neustart der Disk ist eine Handlung des Technikers.
- Wird die Zeit bis zum Hänger immer kürzer oder wird die Disk heiß: abbrechen und mit dem
  Erreichten weiterarbeiten? Vorlegen, nicht selbst entscheiden.
- Lieber zuerst die wichtigen Bereiche (Skill `lf-nur-belegte-bereiche`), dann den Rest.

## Nicht tun

- Die Disk nicht an Windows anschließen. Explorer, Indexdienst und Virenscanner lesen sofort die
  ganze Disk und treiben den Controller in den Hänger. Windows schreibt außerdem beim Einbinden.
- Keine Firmware-Updates, kein Secure Erase, kein TRIM.
