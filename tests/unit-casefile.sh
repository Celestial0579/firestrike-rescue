#!/usr/bin/env bash
# Unit-Test für die Falldatei (case.env): Sie wird als Daten gelesen, nie ausgeführt.
#
# Der Fallordner liegt auf der Ziel-Disk, also auf einem Datenträger aus fremder Hand. Der Test
# legt präparierte Falldateien an, deren Inhalt eine Markerdatei erzeugen würde, sobald irgendwer
# ihn als Shell-Code liest, und prüft, dass keine entsteht: mit der Bibliothek allein und mit dem
# echten frs-rescue-run (ohne root und ohne Disks, das Skript endet vor dem ersten Zugriff).
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/casefile.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# good NAME   Legt einen Fallordner mit einer Falldatei an, wie der Assistent sie schreibt.
good() {
	mkdir -p "$T/$1"
	cat >"$T/$1/case.env" <<-EOF
		SRC_ID="GIBT-ES-NICHT-0815"
		SRC_SIZE="500107862016"
		SRC_LABEL="/dev/sdb · Samsung SSD 870 EVO 500GB · 465,8GiB · SN S5Y1NJ0R123456 · usb"
		TARGET_ID="WD-WCC6Y0ABCDEF"
		STATE="new"
	EOF
}

# bad NAME   Legt einen Fallordner an, die Falldatei kommt von der Standardeingabe.
bad() {
	mkdir -p "$T/$1"
	cat >"$T/$1/case.env"
	BAD+=("$1")
}
BAD=()
markers() { compgen -G "$T/MARKE-*" >/dev/null; }

# ---------------------------------------------------------------------------
echo "Anlegen, lesen, fortschreiben:"
mkdir -p "$T/neu"
casefile_create "$T/neu/case.env" "SRC_ID=S5Y1NJ0R123456" "SRC_SIZE=500107862016" \
	"SRC_LABEL=Testdisk (500 GB)" "TARGET_ID=/dev/sdc" "STATE=new"
check "Falldatei angelegt" '[[ $? == 0 && -f $T/neu/case.env ]]'
check "Form SCHLÜSSEL=\"Wert\", feste Reihenfolge" '[[ $(head -n1 "$T/neu/case.env") == "SRC_ID=\"S5Y1NJ0R123456\"" && $(tail -n1 "$T/neu/case.env") == "STATE=\"new\"" ]]'
check "für den Assistenten lesbar (644)" '[[ $(stat -c %a "$T/neu/case.env") == 644 ]]'
casefile_load "$T/neu/case.env"
check "gelesen" '[[ $? == 0 && $(casefile_get STATE) == new && $(casefile_get SRC_SIZE) == 500107862016 ]]'
check "fehlender Schlüssel liefert die Vorgabe" '[[ $(casefile_get PHASE_DONE 0) == 0 && -z $(casefile_get STARTED) ]]'
casefile_set "$T/neu/case.env" STATE running &&
	casefile_set "$T/neu/case.env" SRC_PATH /dev/mapper/frs-bad &&
	casefile_set "$T/neu/case.env" STARTED "2026-11-12T09:33:59+01:00" &&
	casefile_set "$T/neu/case.env" PHASE_DONE 2
check "fortgeschrieben" '[[ $? == 0 ]]'
check "aus der Datei gelesen, nicht aus dem Speicher" '[[ $(casefile_peek "$T/neu/case.env" PHASE_DONE) == 2 && $(casefile_peek "$T/neu/case.env" STATE) == running ]]'
check "keine Reste im Fallordner" '[[ $(ls "$T/neu") == case.env ]]'
before=$(cat "$T/neu/case.env")
casefile_set "$T/neu/case.env" STATE "done\"; touch $T/MARKE-set; \""
check "Schreiben: Anführungszeichen im Wert abgelehnt" '[[ $? != 0 && $CASEFILE_ERROR == *"unzulässiges Zeichen"* ]]'
casefile_set "$T/neu/case.env" IMG /dev/sda
check "Schreiben: unbekannter Schlüssel abgelehnt" '[[ $? != 0 && $CASEFILE_ERROR == *"unbekannter Schlüssel IMG"* ]]'
casefile_set "$T/neu/case.env" SRC_LABEL "eins"$'\n'"zwei"
check "Schreiben: Zeilenumbruch im Wert abgelehnt" '[[ $? != 0 ]]'
casefile_set "$T/neu/case.env" SRC_PATH /dev/a/../../mnt/x
check "Schreiben: Pfad mit .. abgelehnt" '[[ $? != 0 ]]'
casefile_set "$T/neu/case.env" PHASE 7
check "Schreiben: Phase außerhalb 0–3 abgelehnt" '[[ $? != 0 ]]'
check "abgelehnte Werte ändern die Datei nicht" '[[ $(cat "$T/neu/case.env") == "$before" ]]'
dirty='A"B$(c)`d`\e'$'\t''f'
clean=$(casefile_clean_text "$dirty")
check "Text für den Bericht wird entschärft" '[[ $clean == "A_B_(c)_d__e_f" ]]'
casefile_value_ok SRC_LABEL "$(casefile_clean_text "$(printf "%0300d" 0)")"
check "überlanger Text wird gekürzt und passt" '[[ $? == 0 ]]'

# ---------------------------------------------------------------------------
echo "Falldateien, wie der bisherige Stand sie geschrieben hat:"
good alt
cat >>"$T/alt/case.env" <<-EOF
	SRC_PATH="/dev/sdb"
	STARTED="2026-11-01T10:00:00+01:00"
	PHASE="2"
	PHASE_DONE="1"
EOF
casefile_load "$T/alt/case.env"
check "alte Datei mit angehängten Schlüsseln" '[[ $? == 0 && $(casefile_get PHASE_DONE) == 1 && $(casefile_get STARTED) == 2026-11-01T10:00:00+01:00 ]]'
check "Beschriftung mit Sonderzeichen bleibt erhalten" '[[ $(casefile_get SRC_LABEL) == *"· 465,8GiB · SN S5Y1NJ0R123456 · usb" ]]'
good crlf
sed -i 's/$/\r/' "$T/crlf/case.env"
printf '\n' >>"$T/crlf/case.env"
casefile_load "$T/crlf/case.env"
check "Zeilenenden von Windows und Leerzeile am Ende" '[[ $? == 0 && $(casefile_get STATE) == new ]]'
mkdir -p "$T/pfad"
printf '%s\n' 'SRC_ID="/dev/mapper/frs-bad"' 'SRC_SIZE="67108864"' 'SRC_LABEL="Selbsttest (dm-error)"' 'STATE="done"' >"$T/pfad/case.env"
casefile_load "$T/pfad/case.env"
check "Kennung als Gerätepfad (Selbsttest)" '[[ $? == 0 && $(casefile_get SRC_ID) == /dev/mapper/frs-bad ]]'

# ---------------------------------------------------------------------------
# Präparierte Dateien. Jede würde, als Shell-Code gelesen, $T/MARKE-… anlegen oder das Skript
# umlenken. Die ersten sechs sind am bisherigen frs-rescue-run nachgestellt.
bad befehl <<EOF
SRC_ID="GIBT-ES-NICHT\$(touch $T/MARKE-befehl)"
SRC_SIZE="1"
SRC_LABEL="Testdisk"
STATE="new"
EOF
bad backtick <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
SRC_LABEL="Test\`touch $T/MARKE-backtick\`disk"
STATE="new"
EOF
bad semikolon <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
SRC_LABEL="/dev/sdb · "; touch $T/MARKE-semikolon; " · 500GiB"
STATE="new"
EOF
bad zeile <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
SRC_LABEL="Testdisk"
touch $T/MARKE-zeile
STATE="new"
EOF
mkdir -p "$T/pfadvariable/bin"
printf '#!/bin/sh\ntouch %s/MARKE-pfadvariable\necho "{\\"blockdevices\\":[]}"\n' "$T" >"$T/pfadvariable/bin/lsblk"
chmod +x "$T/pfadvariable/bin/lsblk"
bad pfadvariable <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
SRC_LABEL="Testdisk"
STATE="new"
PATH="$T/pfadvariable/bin:/usr/bin:/bin"
EOF
bad umlenkung <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
SRC_LABEL="Testdisk"
STATE="new"
LOG="$T/MARKE-umlenkung"
EOF
bad umbruch <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
SRC_LABEL="Zeile eins
\$(touch $T/MARKE-umbruch)"
STATE="new"
EOF
bad zahl <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1; touch $T/MARKE-zahl"
STATE="new"
EOF
bad doppelt <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
STATE="new"
STATE="done"
EOF
bad ohnequotes <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
STATE=done
EOF
bad export <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
export STATE="new"
EOF
bad kommentar <<EOF
# von Hand bearbeitet
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
STATE="new"
EOF
bad kleinbuchstaben <<EOF
src_id="GIBT-ES-NICHT"
SRC_SIZE="1"
STATE="new"
EOF
bad zustand <<EOF
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
STATE="fertig"
EOF
bad backslash <<'EOF'
SRC_ID="GIBT-ES-NICHT"
SRC_SIZE="1"
SRC_LABEL="Test\disk"
STATE="new"
EOF
bad auswaerts <<EOF
SRC_ID="/dev/a/../../mnt/frs-target/FRS/x/geraet"
SRC_SIZE="1"
STATE="new"
EOF
bad fehlt <<EOF
SRC_SIZE="1"
STATE="new"
EOF
bad leer </dev/null
mkdir -p "$T/lang"
{
	echo 'SRC_ID="GIBT-ES-NICHT"'
	echo 'SRC_SIZE="1"'
	echo 'STATE="new"'
	printf 'SRC_LABEL="%02000d"\n' 0
} >"$T/lang/case.env"
BAD+=(lang)
good verknuepfung-ziel
mkdir -p "$T/verknuepfung"
ln -s "$T/verknuepfung-ziel/case.env" "$T/verknuepfung/case.env"
BAD+=(verknuepfung)

echo "Präparierte Falldateien werden abgelehnt (Bibliothek):"
for name in "${BAD[@]}"; do
	sum=$(md5sum <"$T/$name/case.env")
	casefile_load "$T/$name/case.env"
	rc=$?
	check "$name: abgelehnt, mit Begründung" '[[ $rc != 0 && -n $CASEFILE_ERROR ]]'
	check "$name: nichts übernommen" '[[ ${#CASEFILE[@]} == 0 && -z $(casefile_peek "$T/$name/case.env" STATE) ]]'
	check "$name: Datei unverändert" '[[ $(md5sum <"$T/$name/case.env") == "$sum" ]]'
done
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'
casefile_load "$T/zeile/case.env"
check "Begründung nennt die Zeile" '[[ $CASEFILE_ERROR == "Zeile 4 "* ]]'
casefile_load "$T/pfadvariable/case.env"
check "Begründung nennt den unbekannten Schlüssel" '[[ $CASEFILE_ERROR == "Zeile 5: unbekannter Schlüssel PATH" ]]'
casefile_load "$T/doppelt/case.env"
check "Begründung nennt den doppelten Schlüssel" '[[ $CASEFILE_ERROR == *"STATE steht doppelt"* ]]'
casefile_load "$T/fehlt/case.env"
check "Begründung nennt den fehlenden Schlüssel" '[[ $CASEFILE_ERROR == *"SRC_ID fehlt"* ]]'

# ---------------------------------------------------------------------------
# run NAME   Startet das echte Skript auf einem Fallordner. Ergebnis: RC, OUT.
run() {
	OUT=$(bash rescue/bin/frs-rescue-run "$T/$1" --no-pause 2>&1)
	RC=$?
}

echo "Präparierte Falldateien mit dem echten frs-rescue-run:"
for name in "${BAD[@]}"; do
	sum=$(md5sum <"$T/$name/case.env")
	run "$name"
	check "$name: Abbruch mit Rückgabe 2" '[[ $RC == 2 && $OUT == *"Falldatei ist ungültig"* ]]'
	check "$name: Datei unverändert, kein Protokoll angelegt" '[[ $(md5sum <"$T/$name/case.env") == "$sum" && ! -e $T/$name/rescue.log ]]'
done
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

echo "Gültige Falldatei mit dem echten frs-rescue-run (Quelle nicht angeschlossen):"
good lauf
run lauf
check "Skript läuft bis zur Suche nach der Quelle" '[[ $RC == 1 && $OUT == *"GIBT-ES-NICHT-0815 ist nicht (mehr) angeschlossen"* ]]'
check "Zustand fortgeschrieben" '[[ $(casefile_peek "$T/lauf/case.env" STATE) == interrupted ]]'
check "übrige Werte unverändert" '[[ $(casefile_peek "$T/lauf/case.env" SRC_SIZE) == 500107862016 && $(casefile_peek "$T/lauf/case.env" TARGET_ID) == WD-WCC6Y0ABCDEF ]]'
run alt
check "alte Falldatei wird weiterverwendet" '[[ $RC == 1 && $(casefile_peek "$T/alt/case.env" STATE) == interrupted && $(casefile_peek "$T/alt/case.env" PHASE_DONE) == 1 ]]'

# ---------------------------------------------------------------------------
# Ganzer Durchlauf ohne root und ohne Disk: lsblk, ddrescue und Co. sind Attrappen im PATH.
mkdir -p "$T/attrappen"
cat >"$T/attrappen/lsblk" <<'EOF'
#!/bin/sh
echo '{"blockdevices":[{"path":"/dev/sdz","serial":"GIBT-ES-DOCH-4711","wwn":null}]}'
EOF
cat >"$T/attrappen/ddrescue" <<'EOF'
#!/bin/sh
# ddrescue [-S] OPTIONEN QUELLE IMAGE MAP: Aufruf mitschreiben, Dateien anlegen.
echo "$*" >>"$DDRESCUE_CALLS"
for last; do :; done
: >>"$last"
[ "$(wc -l <"$DDRESCUE_CALLS")" = "${DDRESCUE_FAIL_AT:-0}" ] && exit 1
exit 0
EOF
for tool in blockdev smartctl ddrescuelog; do printf '#!/bin/sh\nexit 0\n' >"$T/attrappen/$tool"; done
printf '#!/bin/sh\necho ext4\n' >"$T/attrappen/findmnt"
chmod +x "$T/attrappen"/*

# full NAME   Startet das echte Skript mit den Attrappen. Ergebnis: RC, OUT, CALLS (ddrescue-Aufrufe).
full() {
	: >"$T/aufrufe"
	OUT=$(PATH="$T/attrappen:$PATH" DDRESCUE_CALLS="$T/aufrufe" bash rescue/bin/frs-rescue-run "$T/$1" --no-pause 2>&1)
	RC=$?
	CALLS=$(wc -l <"$T/aufrufe")
}
field() { casefile_peek "$T/$1/case.env" "$2"; }

echo "Ganzer Durchlauf mit Attrappen:"
mkdir -p "$T/ganz"
casefile_create "$T/ganz/case.env" "SRC_ID=GIBT-ES-DOCH-4711" "SRC_SIZE=500107862016" \
	"SRC_LABEL=Testdisk (500 GB)" "TARGET_ID=WD-WCC6Y0ABCDEF" "STATE=new"
full ganz
check "drei Phasen, Rückgabe 0" '[[ $RC == 0 && $CALLS == 3 ]]'
check "Zustand done, alle Phasen vermerkt" '[[ $(field ganz STATE) == "done" && $(field ganz PHASE_DONE) == 3 && $(field ganz PHASE) == 3 ]]'
check "Quellpfad und Zeitstempel eingetragen" '[[ $(field ganz SRC_PATH) == /dev/sdz && -n $(field ganz STARTED) && -n $(field ganz FINISHED) ]]'
check "Bericht nennt Quelle und Beginn" '[[ $(cat "$T/ganz/report.txt") == *"Quelle:      Testdisk (500 GB)"* && $(cat "$T/ganz/report.txt") == *"Begonnen:    $(field ganz STARTED)"* ]]'
check "keine Reste im Fallordner" '! compgen -G "$T/ganz/case.env.*" >/dev/null'

mkdir -p "$T/abbruch"
casefile_create "$T/abbruch/case.env" "SRC_ID=GIBT-ES-DOCH-4711" "SRC_SIZE=1" "STATE=new"
: >"$T/aufrufe"
OUT=$(PATH="$T/attrappen:$PATH" DDRESCUE_CALLS="$T/aufrufe" DDRESCUE_FAIL_AT=2 bash rescue/bin/frs-rescue-run "$T/abbruch" --no-pause 2>&1)
RC=$?
check "Fehler in Phase 2: unterbrochen, Phase 1 vermerkt" '[[ $RC != 0 && $(field abbruch STATE) == interrupted && $(field abbruch PHASE_DONE) == 1 ]]'
started=$(field abbruch STARTED)
full abbruch
check "Fortsetzen: nur die offenen Phasen laufen" '[[ $RC == 0 && $CALLS == 2 && $(field abbruch STATE) == "done" ]]'
check "Fortsetzen: Beginn bleibt der erste Start" '[[ -n $started && $(field abbruch STARTED) == "$started" ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
