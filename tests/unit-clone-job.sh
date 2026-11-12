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
FRS_RUN="$T/run"
FRS_LOG="$T/frs.log"
mkdir -p "$FRS_RUN" "$T/lauf"
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/clone.sh
FRS_RUN="$T/run"
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
check "im Protokoll steht, dass das Label nicht übernommen wurde" 'grep -q "Swap-Label von /dev/sda3 nicht übernommen" "$FRS_LOG"'

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
	rm -f "$FRS_RUN/clone-job.sh" "$T/tmux"
	DIE_MSG=""
	clone_copy /dev/sda /dev/sdb
	RC=$?
	JOB=$(cat "$FRS_RUN/clone-job.sh" 2>/dev/null)
	STARTED=$(cat "$T/tmux" 2>/dev/null)
}

echo "Klon-Job für eine gewöhnliche Disk:"
SWAP_UUID=$GOOD_UUID SWAP_LABEL="swap"
plan "/dev/sda1 vfat" "/dev/sda2 ext4" "/dev/sda3 swap" "/dev/sda4 "
job
check "Job erzeugt und gestartet" '[[ -n $JOB && $STARTED == "frs-klon sudo $FRS_RUN/clone-job.sh" ]]'
check "der Job ist gültiges Shell-Skript" 'bash -n "$FRS_RUN/clone-job.sh"'
check "jede Partition hat ihre Zeile" '[[ $JOB == *"partclone.vfat -b -s '"'"'/dev/sda1'"'"' -o '"'"'/dev/sdb1'"'"'"* && $JOB == *"partclone.extfs -b -s '"'"'/dev/sda2'"'"'"* && $JOB == *"mkswap -U $GOOD_UUID -L '"'"'swap'"'"' '"'"'/dev/sdb3'"'"'"* && $JOB == *"dd if='"'"'/dev/sda4'"'"' of='"'"'/dev/sdb4'"'"'"* ]]'

echo "Klon-Job mit präpariertem Swap-Label:"
SWAP_LABEL="';touch MARKE;'"
job
check "Job erzeugt, gültiges Shell-Skript" '[[ -n $JOB ]] && bash -n "$FRS_RUN/clone-job.sh"'
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
check "im Protokoll steht, welcher Name nicht übernommen wurde" 'grep -q "Partitionsname von /dev/sda1 nicht übernommen" "$FRS_LOG"'

cd / || exit 1
rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
