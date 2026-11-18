#!/usr/bin/env bash
# Unit-Test: Was die Quell-Disk über sich meldet, wird im Klon-Job nie zum Befehl.
#
# Der Klon-Job und das sfdisk-Skript sind erzeugter Text und laufen als root. Das Label einer
# Swap-Partition der Quelle stand ungeprüft in einer mkswap-Zeile: Ein Label wie ';reboot;'
# (16 Zeichen sind erlaubt) wurde dort zum Befehl. Der Name einer GPT-Partition stand ungeprüft
# im sfdisk-Skript, wo ein Anführungszeichen den Namen beendet und der Rest als weitere Angaben
# zur Partition gilt. Der Test prüft:
#   - ein präpariertes Swap-Label oder eine präparierte UUID wird weggelassen, nichts läuft,
#   - Gerätepfade und Dateisystemnamen werden geprüft, sonst entsteht kein Job,
#   - ein präparierter Partitionsname steht nicht im sfdisk-Skript.
# Ohne root und ohne Disks: blkid, sfdisk und tmux sind Attrappen. Der Job wird nie gestartet.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
LF_RUN="$T/run"
LF_LOG="$T/lf.log"
mkdir -p "$LF_RUN" "$T/lauf"
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/clone.sh
LF_RUN="$T/run"
# Präparierte Texte legen Markerdateien im Arbeitsverzeichnis an, falls sie ausgeführt werden.
cd "$T/lauf" || exit 1

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
markers() { compgen -G "$T/lauf/MARKE*" >/dev/null; }

die() {
	DIE_MSG="$*"
	return 1
}
ui_msg() { :; }
sleep() { :; }
tmux() { return 1; }
tmux_run() { printf '%s\n' "$*" >>"$T/tmux"; }
# Wie tmux_run, dazu die Disk, die der Job beschreibt (Jobliste für lf-aufgabe).
tmux_run_writing() { printf '%s\n' "$1 ${*:3}" >>"$T/tmux"; printf '%s\n' "$2" >>"$T/writes"; }
# blkid meldet, was die Quell-Partition über sich sagt. sfdisk bekommt sein Skript auf der
# Standardeingabe: Es wird nur mitgeschrieben.
sudo() {
	case "$*" in
	"blkid -o value -s UUID "*) printf '%s\n' "$SWAP_UUID" ;;
	"blkid -o value -s LABEL "*) printf '%s\n' "$SWAP_LABEL" ;;
	"sfdisk "*) cat >"$T/sfdisk-skript" ;;
	esac
	return 0
}

# lsblk meldet Seriennummer, WWN und Größe einer Disk (Fingerabdruck für den Klon-Job).
IDENT_SRC="S5Y1NJ0R123456 0x5002538f12345678 500107862016"
IDENT_DST="WD-WX12A34B5C6D 0x50014ee2b1234567 1000204886016"
lsblk() {
	case "${*: -1}" in
	/dev/sda) printf '%s\n' "$IDENT_SRC" ;;
	/dev/sdb) printf '%s\n' "$IDENT_DST" ;;
	esac
}

GOOD_UUID="0f0f0f0f-1111-2222-3333-444444444444"

# swap_line   Erzeugt die Zeile des Jobs für eine Swap-Partition und führt sie so aus, wie der
# Job es täte. mkswap schreibt nur seine Argumente mit. Ergebnis: LINE, ARGS.
swap_line() {
	rm -f "$T/mkswap"
	LINE=$(clone_cmd_copy /dev/sda3 /dev/sdb3 swap)
	bash -c "mkswap() { printf '%s|' \"\$@\" >>'$T/mkswap'; }; fail() { :; }; $LINE" >/dev/null 2>&1
	ARGS=$(cat "$T/mkswap" 2>/dev/null)
}

# ---------------------------------------------------------------------------
echo "Swap-Partition mit gewöhnlichem Label:"
SWAP_UUID=$GOOD_UUID SWAP_LABEL="swap-1"
swap_line
check "UUID und Label werden übernommen" '[[ $ARGS == "-U|$GOOD_UUID|-L|swap-1|/dev/sdb3|" ]]'
SWAP_LABEL="Linux Swap"
swap_line
check "Label mit Leerzeichen bleibt ein Argument" '[[ $ARGS == "-U|$GOOD_UUID|-L|Linux Swap|/dev/sdb3|" ]]'
SWAP_LABEL=""
swap_line
check "ohne Label: nur die UUID" '[[ $ARGS == "-U|$GOOD_UUID|/dev/sdb3|" ]]'

echo "Präpariertes Swap-Label:"
# shellcheck disable=SC2016
for label in "';touch MARKE;'" '$(touch MARKE)' '`touch MARKE`' "a'b" 'a"b' "a;touch MARKE" "a|b" 'a\b' $'a\ntouch MARKE' "Müll"; do
	SWAP_UUID=$GOOD_UUID SWAP_LABEL=$label
	swap_line
	check "$(printf '%q' "$label"): weggelassen, Partition wird ohne Label angelegt" '[[ $ARGS == "-U|$GOOD_UUID|/dev/sdb3|" && $LINE != *MARKE* ]]'
done
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'
check "im Protokoll steht, dass das Label nicht übernommen wurde" 'grep -q "Swap-Label von /dev/sda3 nicht übernommen" "$LF_LOG"'

echo "Präparierte UUID:"
for uuid in "x';touch MARKE-uuid;'" '$(touch MARKE-uuid)' "0f0f0f0f-1111-2222-3333-44444444444" "$GOOD_UUID extra"; do
	SWAP_UUID=$uuid SWAP_LABEL="swap"
	swap_line
	check "$(printf '%q' "$uuid"): weggelassen" '[[ $ARGS == "-L|swap|/dev/sdb3|" && $LINE != *MARKE* ]]'
done
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# ---------------------------------------------------------------------------
# plan TEILE...   Füllt, was clone_plan sonst berechnet. Jedes TEIL ist "KNOTEN DATEISYSTEM".
plan() {
	local part i=0
	CLONE_PARTS=() CLONE_FS=() CLONE_NEW_SIZE=() CLONE_NEW_START=()
	CLONE_ELASTIC=-1 CLONE_SHRINK=0 CLONE_SS=512 CLONE_LABEL=gpt
	for part in "$@"; do
		CLONE_PARTS[i]=$(jq -cn --arg n "${part% *}" '{node: $n, start: 2048, size: 204800, type: "0FC63DAF-8483-4772-8E79-3D69D8477DE4", uuid: "u"}')
		CLONE_FS[i]=${part##* }
		CLONE_NEW_START[i]=2048
		CLONE_NEW_SIZE[i]=204800
		i=$((i + 1))
	done
}
# job   Erzeugt den Klon-Job, ohne ihn zu starten. Ergebnis: RC, JOB (Text des Jobs), DIE_MSG.
job() {
	rm -f "$LF_RUN/clone-job.sh" "$T/tmux"
	DIE_MSG=""
	clone_copy /dev/sda /dev/sdb
	RC=$?
	JOB=$(cat "$LF_RUN/clone-job.sh" 2>/dev/null)
	STARTED=$(cat "$T/tmux" 2>/dev/null)
}

echo "Klon-Job für eine gewöhnliche Disk:"
SWAP_UUID=$GOOD_UUID SWAP_LABEL="swap"
plan "/dev/sda1 vfat" "/dev/sda2 ext4" "/dev/sda3 swap" "/dev/sda4 "
job
check "Job erzeugt und gestartet" '[[ -n $JOB && $STARTED == "lf-klon sudo $LF_RUN/clone-job.sh" ]]'
check "die Ziel-Disk steht für den Job in der Jobliste (GHSA-p86q-3456-f288)" '[[ $(tail -n1 "$T/writes" 2>/dev/null) == /dev/sdb ]]'
check "der Job ist gültiges Shell-Skript" 'bash -n "$LF_RUN/clone-job.sh"'
check "jede Partition hat ihre Zeile" '[[ $JOB == *"partclone.vfat -b -s '"'"'/dev/sda1'"'"' -o '"'"'/dev/sdb1'"'"'"* && $JOB == *"partclone.extfs -b -s '"'"'/dev/sda2'"'"'"* && $JOB == *"mkswap -U $GOOD_UUID -L '"'"'swap'"'"' '"'"'/dev/sdb3'"'"'"* && $JOB == *"dd if='"'"'/dev/sda4'"'"' of='"'"'/dev/sdb4'"'"'"* ]]'

echo "Der Klon-Job prüft vor jedem Schritt, dass Quelle und Ziel noch dieselben Disks sind:"
hex='[0-9a-f]{64}'
check "vor jeder der vier Partitionen stehen beide Prüfungen" '[[ $(grep -cE "^same ./dev/sda. .$hex.\$" <<<"$JOB") == 4 && $(grep -cE "^same ./dev/sdb. .$hex.\$" <<<"$JOB") == 4 ]]'
check "die Prüfung steht vor dem Schritt, nicht danach" '[[ $(grep -nE "^(same|step) " <<<"$JOB" | head -n 3 | cut -d: -f2 | cut -d" " -f1 | tr "\n" " ") == "same same step " ]]'
check "im Job steht nur der Hashwert, keine Angabe des Geräts" '[[ $JOB != *S5Y1NJ0R123456* && $JOB != *WD-WX12A34B5C6D* && $JOB != *0x5002538f12345678* ]]'
# guard GERÄT   Führt die Prüfung des Jobs für GERÄT so aus, wie der Job es täte. lsblk meldet
# dabei, was in IDENT_SRC und IDENT_DST steht. Ergebnis: GUARD ("JOB-LAEUFT" oder die Meldung).
guard() {
	local line
	line=$(grep -E "^same '$1' " <<<"$JOB" | head -n 1)
	GUARD=$(SRC=$IDENT_SRC DST=$IDENT_DST bash -c "lsblk() { case \"\${*: -1}\" in /dev/sda) printf '%s\n' \"\$SRC\" ;; /dev/sdb) printf '%s\n' \"\$DST\" ;; esac; }
		read() { :; }
		$(grep -E '^(fail|ident|same)\(\) ' <<<"$JOB")
		$line
		echo JOB-LAEUFT" 2>&1)
}
guard /dev/sdb
check "unverändert: der Job läuft weiter" '[[ $GUARD == JOB-LAEUFT ]]'
keep=$IDENT_DST
IDENT_DST=$IDENT_SRC
guard /dev/sdb
check "hinter dem Namen des Ziels steht jetzt die Quelle: Abbruch vor dem Schreiben" '[[ $GUARD == *FEHLER*"nicht mehr die Disk vom Start"* && $GUARD != *JOB-LAEUFT* ]]'
IDENT_DST=""
guard /dev/sdb
check "das Ziel ist verschwunden: Abbruch" '[[ $GUARD == *FEHLER* && $GUARD != *JOB-LAEUFT* ]]'
IDENT_DST="WD-WX12A34B5C6D 0x50014ee2b1234567 2000398934016"
guard /dev/sdb
check "gleiche Seriennummer, andere Größe: Abbruch" '[[ $GUARD == *FEHLER* && $GUARD != *JOB-LAEUFT* ]]'
IDENT_DST=$keep
keep=$IDENT_SRC
IDENT_SRC="\x27;touch MARKE;\x27 - 500107862016"
IDENT_SRC=$(printf '%b' "$IDENT_SRC")
job
check "präparierte Seriennummer der Quelle: Job gültig, die Angabe steht nicht darin" '[[ -n $JOB && $JOB != *MARKE* ]] && bash -n "$LF_RUN/clone-job.sh"'
IDENT_SRC=""
job
check "die Quelle ist nicht mehr zu erkennen: kein Job, nichts gestartet" '[[ $RC != 0 && -z $JOB && -z $STARTED && $DIE_MSG == *"nicht mehr zu erkennen"* ]]'
IDENT_SRC=$keep
job

echo "Klon-Job mit präpariertem Swap-Label:"
SWAP_LABEL="';touch MARKE;'"
job
check "Job erzeugt, gültiges Shell-Skript" '[[ -n $JOB ]] && bash -n "$LF_RUN/clone-job.sh"'
check "das Label steht nirgends im Job" '[[ $JOB != *MARKE* && $JOB == *"mkswap -U $GOOD_UUID  '"'"'/dev/sdb3'"'"'"* ]]'

echo "Angaben, die in keinem Befehl stehen dürfen:"
SWAP_LABEL="swap"
plan "/dev/sda1 vfat" "/dev/sda2'; touch MARKE; ' ext4"
job
check "Gerätepfad mit Anführungszeichen: kein Job, nichts gestartet" '[[ $RC != 0 && -z $JOB && -z $STARTED && $DIE_MSG == *"wird nicht gestartet"* ]]'
plan "/dev/sda1 vfat" "/dev/sda2 ext4';touch"
job
check "Dateisystemname mit Anführungszeichen: kein Job, nichts gestartet" '[[ $RC != 0 && -z $JOB && -z $STARTED ]]'
plan '/dev/sda1 vfat' '/dev/$(touch MARKE)2 ext4'
job
check "Gerätepfad mit Befehlsersetzung: kein Job, nichts gestartet" '[[ $RC != 0 && -z $JOB && -z $STARTED ]]'
plan "/dev/../etc/sda1 vfat"
job
check "Pfad, der aus /dev hinausführt: kein Job" '[[ $RC != 0 && -z $JOB ]]'
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# ---------------------------------------------------------------------------
# table NAME...   Schreibt die Partitionstabelle für Partitionen mit diesen Namen. Ergebnis: SCRIPT.
table() {
	local name i=0
	CLONE_PARTS=() CLONE_SS=512 CLONE_LABEL=gpt
	CLONE_PT='{"partitiontable":{"id":"AAAAAAAA-0000-0000-0000-000000000000"}}'
	CLONE_NEW_START=() CLONE_NEW_SIZE=()
	for name in "$@"; do
		CLONE_PARTS[i]=$(jq -cn --arg n "/dev/sda$((i + 1))" --arg name "$name" '{node: $n, start: 2048, size: 204800, type: "0FC63DAF-8483-4772-8E79-3D69D8477DE4", uuid: "11111111-2222-3333-4444-555555555555", name: $name, attrs: "RequiredPartition GUID:63"}')
		CLONE_NEW_START[i]=$((2048 + i * 204800))
		CLONE_NEW_SIZE[i]=204800
		i=$((i + 1))
	done
	rm -f "$T/sfdisk-skript"
	clone_write_table /dev/sdb replace
	SCRIPT=$(cat "$T/sfdisk-skript" 2>/dev/null)
}

echo "Partitionsnamen im sfdisk-Skript:"
table "EFI System Partition" "Basic data partition" "Daten für Müller"
check "gewöhnliche Namen stehen im Skript, auch mit Umlauten" '[[ $SCRIPT == *"name=\"EFI System Partition\""* && $SCRIPT == *"name=\"Basic data partition\""* && $SCRIPT == *"name=\"Daten für Müller\""* ]]'
check "Attribute bleiben erhalten" '[[ $(grep -c "attrs=\"RequiredPartition GUID:63\"" <<<"$SCRIPT") == 3 ]]'
table 'x", size=1, name="y' "gut"
check "Name mit Anführungszeichen: weggelassen, keine fremde Angabe im Skript" '[[ $SCRIPT != *"size=1,"* && $SCRIPT != *"name=\"x"* && $SCRIPT == *"name=\"gut\""* ]]'
check "jede Partition behält ihre eigene Größe" '[[ $(grep -c "size=204800," <<<"$SCRIPT") == 2 ]]'
table $'eins\n/dev/sdb9 : start=1, size=1' 'a\b' ""
check "Name mit Zeilenumbruch: keine zusätzliche Zeile im Skript" '[[ $(grep -c "^/dev/sdb" <<<"$SCRIPT") == 3 && $SCRIPT != *"/dev/sdb9"* ]]'
check "Name mit Backslash und leerer Name: kein Name im Skript" '[[ $SCRIPT != *"name="* ]]'
check "im Protokoll steht, welcher Name nicht übernommen wurde" 'grep -q "Partitionsname von /dev/sda1 nicht übernommen" "$LF_LOG"'

cd / || exit 1
rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
