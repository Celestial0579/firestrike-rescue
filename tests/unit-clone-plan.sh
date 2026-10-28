#!/usr/bin/env bash
# Unit-Test für die Layout-Berechnung beim Klonen (clone_plan), ohne echte Disks.
# Simuliert eine Windows-Disk (EFI, MSR, C:, Wiederherstellung) und prüft
# größeres Ziel, kleineres Ziel und zu kleines Ziel.
set -u
cd "$(dirname "$0")/.." || exit 1

FRS_RUN=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/clone.sh

log() { :; }
die() { DIE_MSG="$*"; return 1; }
ui_menu() { echo "unerwarteter Dialog" >&2; return 1; }

TSIZE=0
USED=90000000000 # 90 GB belegt auf C:
sudo() {
	case "$1 $2" in
	"blockdev --getsize64") echo "$TSIZE" ;;
	"blkid -o")
		case "${*: -1}" in
		*1) echo vfat ;; *2) echo "" ;; *3) echo ntfs ;; *4) echo ntfs ;;
		esac
		;;
	"ntfsresize --info") echo "You might resize at $USED bytes" ;;
	esac
}

PT='{"partitiontable":{"label":"gpt","id":"AAAA","sectorsize":512,"partitions":[
{"node":"/dev/sda1","start":2048,"size":204800,"type":"C12A7328-F81F-11D2-BA4B-00A0C93EC93B","uuid":"u1","name":"EFI"},
{"node":"/dev/sda2","start":206848,"size":32768,"type":"E3C9E316-0B5C-4DB8-817D-F92DF00215AE","uuid":"u2"},
{"node":"/dev/sda3","start":239616,"size":975175680,"type":"EBD0A0A2-B9E5-4433-87C0-68B6B72699C7","uuid":"u3"},
{"node":"/dev/sda4","start":975415296,"size":1433600,"type":"DE94BBA4-06D1-4D40-A16A-BFD50179D6AC","uuid":"u4","attrs":"RequiredPartition GUID:63"}]}}'

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

layout_ok() {
	local last=$((TSIZE / 512 - 34)) i
	for i in 0 1 2 3; do
		((CLONE_NEW_START[i] % 2048 == 0)) || return 1
		((CLONE_NEW_START[i] + CLONE_NEW_SIZE[i] - 1 <= last)) || return 1
		((i == 0)) || ((CLONE_NEW_START[i] >= CLONE_NEW_START[i - 1] + CLONE_NEW_SIZE[i - 1])) || return 1
	done
}

echo "Ziel 1 TB (größer):"
TSIZE=1000204886016
clone_plan /dev/sda /dev/sdb "$PT"
rc=$?
check "Plan erstellt" '[[ $rc == 0 ]]'
check "C: ist Hauptpartition" '[[ $CLONE_ELASTIC == 2 ]]'
check "kein Verkleinern" '[[ $CLONE_SHRINK == 0 ]]'
check "Layout gültig" 'layout_ok'
check "EFI/MSR unverändert" '[[ ${CLONE_NEW_START[0]} == 2048 && ${CLONE_NEW_SIZE[1]} == 32768 ]]'
check "Recovery am Ende, gleiche Größe" '[[ ${CLONE_NEW_SIZE[3]} == 1433600 ]] && (( TSIZE/512 - 34 - (CLONE_NEW_START[3] + CLONE_NEW_SIZE[3]) < 2048 ))'
check "C: gewachsen" '(( CLONE_NEW_SIZE[2] > 975175680 ))'

echo "Ziel 120 GB (kleiner, Daten passen):"
TSIZE=120034123776
clone_plan /dev/sda /dev/sdb "$PT"
rc=$?
check "Plan erstellt" '[[ $rc == 0 ]]'
check "Verkleinern erkannt" '[[ $CLONE_SHRINK == 1 ]]'
check "Layout gültig" 'layout_ok'

echo "Ziel 64 GB (zu klein):"
TSIZE=64023257088
DIE_MSG=""
clone_plan /dev/sda /dev/sdb "$PT"
rc=$?
check "Plan abgelehnt" '[[ $rc != 0 ]]'
check "Begründung genannt" '[[ $DIE_MSG == *"passen nicht"* ]]'

rm -rf "$FRS_RUN"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
