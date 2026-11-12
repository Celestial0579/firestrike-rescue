#!/usr/bin/env bash
# Unit-Test: Von welcher Disk gelesen wird, bestimmt der Techniker, nie die Falldatei.
#
# Der Fallordner liegt auf der Ziel-Disk. Eine präparierte Falldatei kann als Quelle eine Disk
# nennen, die der Techniker nie gewählt hat, zum Beispiel die interne. Beim Fortsetzen landete
# deren Abbild dann auf der fremden Ziel-Disk. Der Test prüft beide Stellen:
#   - frs-rescue-run (läuft als root) liest nur von der Disk, die der Aufruf nennt, und nur,
#     wenn Kennung und Größe aus der Falldatei zu ihr passen.
#   - recover_resume (Assistent) fragt den Techniker nach der Quelle und setzt nur fort, wenn
#     die Falldatei seiner Wahl nicht widerspricht.
# Ohne root und ohne Disks: lsblk, ddrescue und die Dialoge sind Attrappen.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/casefile.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# Vier gedachte Disks: die defekte Quelle (sdx), eine interne Disk (sdy), eine Disk hinter
# einem Adapter, der weder Seriennummer noch WWN meldet (sdw), und eine baugleiche Disk mit
# derselben Größe wie die Quelle (sdv).
DEFEKT='{"path":"/dev/sdx","serial":"DEFEKT-0001","wwn":"0x5000c500aaaaaaaa","size":1000204886016,"model":"Defekte Disk","tran":"usb"}'
INTERN='{"path":"/dev/sdy","serial":"INTERN-0002","wwn":"0x5002538fbbbbbbbb","size":2000398934016,"model":"Interne Disk","tran":"nvme"}'
NAMENLOS='{"path":"/dev/sdw","serial":"","wwn":null,"size":500107862016,"model":"Adapter","tran":"usb"}'
ZWILLING='{"path":"/dev/sdv","serial":"ZWILLING-0003","wwn":"0x5000c500cccccccc","size":1000204886016,"model":"Defekte Disk","tran":"usb"}'

# ---------------------------------------------------------------------------
# Teil 1: frs-rescue-run
# ---------------------------------------------------------------------------
mkdir -p "$T/attrappen"
# "lsblk … GERÄT" nennt genau dieses Gerät, ohne Gerät alle.
cat >"$T/attrappen/lsblk" <<EOF
#!/bin/sh
for last; do :; done
case \$last in
/dev/sdx) echo '{"blockdevices":[$DEFEKT]}' ;;
/dev/sdy) echo '{"blockdevices":[$INTERN]}' ;;
/dev/sdw) echo '{"blockdevices":[$NAMENLOS]}' ;;
/dev/sdv) echo '{"blockdevices":[$ZWILLING]}' ;;
/dev/*) echo "lsblk: \$last: not a block device" >&2; exit 32 ;;
*) echo '{"blockdevices":[$DEFEKT,$INTERN,$NAMENLOS,$ZWILLING]}' ;;
esac
EOF
# ddrescue [-S] OPTIONEN QUELLE IMAGE MAP: Aufruf mitschreiben, Mapfile anlegen.
cat >"$T/attrappen/ddrescue" <<'EOF'
#!/bin/sh
echo "$*" >>"$DDRESCUE_CALLS"
for last; do :; done
: >>"$last"
EOF
for tool in blockdev smartctl ddrescuelog; do printf '#!/bin/sh\nexit 0\n' >"$T/attrappen/$tool"; done
printf '#!/bin/sh\necho ext4\n' >"$T/attrappen/findmnt"
chmod +x "$T/attrappen"/*

# fall NAME KENNUNG GRÖSSE   Legt einen unterbrochenen Rettungsfall an.
fall() {
	mkdir -p "$T/$1"
	casefile_create "$T/$1/case.env" "SRC_ID=$2" "SRC_SIZE=$3" "SRC_LABEL=Testdisk" "STATE=interrupted"
}
# rescue NAME [QUELLE ...]   Startet das echte Skript. Ergebnis: RC, OUT, READ (ddrescue-Aufrufe).
rescue() {
	local name=$1
	shift
	: >"$T/aufrufe"
	OUT=$(PATH="$T/attrappen:$PATH" DDRESCUE_CALLS="$T/aufrufe" bash rescue/bin/frs-rescue-run "$T/$name" "$@" --no-pause 2>&1 </dev/null)
	RC=$?
	READ=$(cat "$T/aufrufe")
}
field() { casefile_peek "$T/$1/case.env" "$2"; }

echo "Falldatei nennt die interne Disk, gewählt ist die defekte:"
fall fremd INTERN-0002 2000398934016
sum=$(md5sum <"$T/fremd/case.env")
rescue fremd /dev/sdx
check "Abbruch mit Rückgabe 2" '[[ $RC == 2 && $OUT == *"nicht die Quelle dieses Rettungsfalls"* ]]'
check "von keiner Disk gelesen" '[[ -z $READ ]]'
check "kein Image, kein Protokoll, Falldatei unverändert" '[[ ! -e $T/fremd/image.img && ! -e $T/fremd/rescue.log && $(md5sum <"$T/fremd/case.env") == "$sum" ]]'
rescue fremd
check "ohne Quelle im Aufruf: Abbruch, die Falldatei wählt keine Disk" '[[ $RC == 2 && -z $READ && $OUT == *"Aufruf: frs-rescue-run CASE_DIR QUELLE"* ]]'
fall fremdpfad /dev/sdy 2000398934016
rescue fremdpfad /dev/sdx
check "Falldatei nennt den Pfad der internen Disk: Abbruch, nichts gelesen" '[[ $RC == 2 && -z $READ ]]'
rescue fremdpfad
check "dieselbe Datei ohne Quelle im Aufruf: nichts gelesen" '[[ $RC == 2 && -z $READ ]]'

echo "Gewählt ist die Quelle des Falls:"
fall echt DEFEKT-0001 1000204886016
rescue echt /dev/sdx
check "drei Phasen, gelesen nur von der gewählten Disk" '[[ $RC == 0 && $(grep -c " /dev/sdx " <<<"$READ") == 3 && $READ != *"/dev/sdy"* && $READ != *"/dev/sdw"* ]]'
check "Zustand done, Pfad der Quelle vermerkt" '[[ $(field echt STATE) == "done" && $(field echt SRC_PATH) == /dev/sdx ]]'
fall wwn 0x5000c500aaaaaaaa 1000204886016
rescue wwn /dev/sdx
check "Kennung ist der WWN: Rettung läuft" '[[ $RC == 0 && $READ == *" /dev/sdx "* ]]'

echo "Größe passt, Kennung nicht (baugleiche Disk):"
fall zwilling DEFEKT-0001 1000204886016
rescue zwilling /dev/sdv
check "Abbruch, nichts gelesen, Grund genannt" '[[ $RC == 2 && -z $READ && $OUT == *"Seriennummer und WWN der Disk stimmen nicht"* ]]'
check "Falldatei unverändert" '[[ $(field zwilling STATE) == interrupted && -z $(field zwilling SRC_PATH) ]]'

echo "Kennung passt, Größe nicht:"
fall groesse DEFEKT-0001 500107862016
rescue groesse /dev/sdx
check "Abbruch, nichts gelesen, Grund genannt" '[[ $RC == 2 && -z $READ && $OUT == *"Größe der Disk stimmt nicht"* ]]'

echo "Falldatei kennt nur einen Gerätepfad (Disk ohne Seriennummer und WWN):"
fall pfad /dev/sdb 500107862016
rescue pfad /dev/sdw
check "gleiche Größe: Rettung läuft von der gewählten Disk, mit Hinweis" '[[ $RC == 0 && $READ == *" /dev/sdw "* && $OUT == *"allein die Größe"* ]]'
fall pfadgroesse /dev/sdb 500107862016
rescue pfadgroesse /dev/sdx
check "andere Größe: Abbruch, nichts gelesen" '[[ $RC == 2 && -z $READ ]]'

echo "Quelle fehlt oder ist kein Gerätepfad:"
fall weg DEFEKT-0001 1000204886016
rescue weg /dev/sdq
check "nicht angeschlossen: Rückgabe 1, Zustand interrupted, nichts gelesen" '[[ $RC == 1 && -z $READ && $OUT == *"/dev/sdq ist nicht (mehr) angeschlossen"* && $(field weg STATE) == interrupted ]]'
for arg in sdx /etc/passwd /dev/../etc/passwd "/dev/sdx; touch $T/MARKE-quelle" '/dev/$(touch MARKE)'; do
	rescue weg "$arg"
	check "Quelle '$arg': Abbruch, nichts gelesen" '[[ $RC == 2 && -z $READ ]]'
done
rescue weg /dev/sdx /dev/sdy
check "zwei Quellen im Aufruf: Abbruch, nichts gelesen" '[[ $RC == 2 && -z $READ ]]'
check "nichts wurde ausgeführt: keine Markerdatei" '! compgen -G "$T/MARKE-*" >/dev/null && [[ ! -e MARKE ]]'

# ---------------------------------------------------------------------------
# Teil 2: Assistent (recover_resume)
# ---------------------------------------------------------------------------
FRS_TARGET_MNT="$T/ziel"
mkdir -p "$FRS_TARGET_MNT/FRS"
# zielfall NAME KENNUNG GRÖSSE [ZUSTAND]   Rettungsfall auf der gedachten Ziel-Disk.
zielfall() {
	mkdir -p "$FRS_TARGET_MNT/FRS/$1"
	casefile_create "$FRS_TARGET_MNT/FRS/$1/case.env" "SRC_ID=$2" "SRC_SIZE=$3" "SRC_LABEL=Testdisk" "STATE=${4:-interrupted}"
}
zielfall fremd INTERN-0002 2000398934016
zielfall echt DEFEKT-0001 1000204886016
zielfall pfad /dev/sdb 500107862016
zielfall fertig DEFEKT-0001 1000204886016 "done"

log() { :; }
tmux() { return 1; }              # keine Rettung im Hintergrund
target_find_cases() { return 0; } # das Ziel gilt als eingehängt
target_search_end() { echo ende >>"$T/suche"; }
safety_check_target() { return 0; }
target_case_writable() { echo beschreibbar >>"$T/suche"; }
# Erster Aufruf: Ziel-Disk. Zweiter Aufruf: Quelle. Läuft in $(…), deshalb in Dateien.
disk_pick() {
	printf '%s\n' "$*" >>"$T/pick"
	if (($(wc -l <"$T/pick") == 1)); then
		echo "ZIEL-0009"
		return 0
	fi
	[[ -n $PICK_SOURCE ]] || return 1
	echo "$PICK_SOURCE"
}
disk_info() {
	case $1 in
	DEFEKT-0001) echo "$DEFEKT" ;;
	INTERN-0002) echo "$INTERN" ;;
	/dev/sdw) echo "$NAMENLOS" ;;
	ZWILLING-0003) echo "$ZWILLING" ;;
	esac
}
disk_resolve() { disk_info "$1" | jq -r .path; }
disk_label() { jq -r '"\(.path) \(.model)"' <<<"$1"; }
ui_menu() { echo "$PICK_CASE"; }
ui_msg() { printf '%s|%s\n' "$1" "$2" >>"$T/msg"; }
ui_yesno() {
	printf '%s|%s\n' "$1" "$2" >>"$T/yesno"
	return "$YESNO_RC"
}
die() {
	printf 'Abbruch|%s\n' "$*" >>"$T/msg"
	return 1
}
safety_set_ro() { echo "$1" >>"$T/ro"; }
recover_run() { printf '%s|%s\n' "$1" "${2:-}" >>"$T/run"; }
recover_after() { echo "$1" >>"$T/after"; }

# resume FALL QUELLE   Ruft recover_resume auf: Der Techniker wählt FALL und als Quelle QUELLE
# (leer = Auswahl abgebrochen). Ergebnis: RUN, RO, MSG, YESNO, AFTER, PICKS.
resume() {
	rm -f "$T/pick" "$T/msg" "$T/yesno" "$T/ro" "$T/run" "$T/after"
	PICK_CASE=$1 PICK_SOURCE=$2
	recover_resume
	RUN=$(cat "$T/run" 2>/dev/null)
	RO=$(cat "$T/ro" 2>/dev/null)
	MSG=$(cat "$T/msg" 2>/dev/null)
	YESNO=$(cat "$T/yesno" 2>/dev/null)
	AFTER=$(cat "$T/after" 2>/dev/null)
	PICKS=$(wc -l <"$T/pick")
}
YESNO_RC=1

echo "Assistent, Falldatei nennt die interne Disk, der Techniker wählt die defekte:"
resume fremd DEFEKT-0001
check "keine Rettung gestartet" '[[ -z $RUN ]]'
check "die Disk aus der Falldatei wird nicht angefasst" '[[ -z $RO ]]'
check "Meldung: falsche Quelle, nichts gelesen" '[[ $MSG == "Falsche Quelle|"*"nichts gelesen"* ]]'
check "die Meldung gibt nichts aus der Falldatei wieder" '[[ $MSG != *"INTERN-0002"* && $MSG != *"/dev/sdy"* && $MSG != *"2000398934016"* ]]'
check "die Quelle wird erfragt, die Ziel-Disk steht dabei nicht zur Wahl" '[[ $PICKS == 2 && $(sed -n 2p "$T/pick") == *" ZIEL-0009" ]]'
check "die Frage nach der Quelle gibt nichts aus der Falldatei wieder" '[[ $(sed -n 2p "$T/pick") != *"INTERN"* && $(sed -n 2p "$T/pick") != *"Testdisk"* ]]'

echo "Assistent, der Techniker wählt die Quelle des Falls:"
resume echt DEFEKT-0001
check "Quelle schreibgeschützt" '[[ $RO == /dev/sdx ]]'
check "Rettung mit der gewählten Disk gestartet" '[[ $RUN == "$FRS_TARGET_MNT/FRS/echt|/dev/sdx" ]]'
check "keine Rückfrage, keine Meldung" '[[ -z $YESNO && -z $MSG ]]'
resume echt ""
check "Auswahl der Quelle abgebrochen: nichts gestartet, nichts angefasst" '[[ -z $RUN && -z $RO ]]'
resume echt ZWILLING-0003
check "baugleiche Disk mit gleicher Größe: abgelehnt, nichts angefasst" '[[ -z $RUN && -z $RO && $MSG == "Falsche Quelle|"*"Seriennummer und WWN"* ]]'

echo "Assistent, Falldatei kennt nur einen Gerätepfad:"
YESNO_RC=1
resume pfad /dev/sdw
check "Rückfrage, weil nur die Größe geprüft ist" '[[ $YESNO == "Quelle nur an der Größe erkennbar|"* ]]'
check "Nein: nichts gestartet, nichts angefasst" '[[ -z $RUN && -z $RO ]]'
YESNO_RC=0
resume pfad /dev/sdw
check "Ja: Rettung mit der gewählten Disk gestartet" '[[ $RO == /dev/sdw && $RUN == "$FRS_TARGET_MNT/FRS/pfad|/dev/sdw" ]]'
resume pfad DEFEKT-0001
check "andere Größe: keine Rückfrage, nichts gestartet" '[[ -z $YESNO && -z $RUN && -z $RO ]]'

echo "Assistent, abgeschlossener Fall:"
resume fertig ""
check "weiter mit dem Image, ohne Frage nach einer Quelle" '[[ $AFTER == "$FRS_TARGET_MNT/FRS/fertig" && $PICKS == 1 && -z $RUN ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
