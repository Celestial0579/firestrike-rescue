---
name: lf-haengende-disk
description: Rettung einer Disk, die nach kurzer Zeit hängt oder verschwindet (typisch für SSD-Controller-Fehler). Kurze Timeouts, Abbruch statt Warten, Neustart der Disk und Fortsetzen über die Mapfile. Nutzen, wenn ddrescue stehen bleibt, die Disk sich als "becoming ready" meldet oder vom Bus verschwindet.
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

1. **Kurze Timeouts für die Quelle:** `sudo lf-aufgabe timeout /dev/sdX 5`. Der Kernel wartet bei
   einem Hänger dann 5 Sekunden statt 30 und mehr, ein Hänger blockiert nicht minutenlang. Das gilt
   nur für Disks, die schon als Quelle schreibgeschützt sind, und bis zum Abziehen.
2. **Rettung starten oder fortsetzen** wie in `lf-image-zuerst`.
3. **Hängt die Disk:** **Den Techniker bitten**, sie neu zu starten: Stromzufuhr trennen (Kabel
   oder Adapter abziehen), etwa 10 Sekunden warten, wieder anschließen. Danach erneut
   `sudo lf-aufgabe timeout …` (der Wert gilt nur bis zum Abziehen) und
   `sudo lf-aufgabe fortsetzen FALL /dev/sdY`. Der Gerätename kann sich geändert haben:
   mit `sudo lf-lesen disks` an Modell und Seriennummer prüfen.
4. Wiederholen, bis der Stand "done" ist oder der Techniker abbricht. Über die Mapfile geht kein
   gelesener Bereich verloren.

## Optional: Neustart über eine schaltbare Steckdose

Hängt die Disk an einem eigenen Netzteil (Wechselrahmen, Dock), lässt sich der Neustart
automatisieren: eine schaltbare Steckdose, die der Techniker aus der Ferne aus- und einschaltet.
Ablauf pro Hänger: aus, 10 Sekunden warten, an, warten bis die Disk erscheint, Timeouts setzen,
fortsetzen. Bei wiederholtem Hänger an derselben Stelle ein Stück dahinter weiterlesen und die
Lücke später nachholen. Eingerichtet und ausgelöst wird das nur vom Techniker. Das
Rettungssystem steuert keine Geräte im Netz.

## Wann der Techniker entscheidet

- Jeder Neustart der Disk ist eine Handlung des Technikers.
- Wird die Zeit bis zum Hänger immer kürzer oder wird die Disk heiß: abbrechen und mit dem
  Erreichten weiterarbeiten? Vorlegen, nicht selbst entscheiden.
- Lieber zuerst die wichtigen Bereiche (Skill `lf-nur-belegte-bereiche`), dann den Rest.

## Nicht tun

- Die Disk nicht an Windows anschließen. Explorer, Indexdienst und Virenscanner lesen sofort die
  ganze Disk und treiben den Controller in den Hänger. Windows schreibt außerdem beim Einbinden.
- Keine Firmware-Updates, kein Secure Erase, kein TRIM.
