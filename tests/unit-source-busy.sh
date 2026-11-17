#!/usr/bin/env bash
# Unit-Test (GHSA-p86q-3456-f288): lf-aufgabe nimmt keine Quelle, auf die gerade ein Job schreibt
# (dd oder partclone eines laufenden Klons), und kein Hilfsgerät (nbd: Overlay eines Klons,
# zram). Ein blockdev --setro darauf ließe den Job mitten im Lauf scheitern.
#
# Hier wird nichts eingehängt: Die "Disk" sind gewöhnliche Dateien, lsblk, disk_of, boot_disk,
# target_disk und fail sind Attrappen. Ein losgelöster sleep hält eine Datei offen wie dd.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
echo "Quellen für lf-aufgabe:"
# Die Funktionen aus lf-aufgabe, mit Attrappen für Disks und fail. Die "Disk" sind gewöhnliche
# Dateien; ein losgelöster Prozess hält eine davon zum Schreiben offen wie dd im Klon.
sed -n '/^disk_written() {/,/^}/p; /^source_ok() {/,/^}/p' rescue/bin/lf-aufgabe >"$T/aufgabe-fns.sh"
# shellcheck disable=SC1091
. "$T/aufgabe-fns.sh"
: >"$T/sdz" && : >"$T/sdz1" && : >"$T/sdz2"
lsblk() { printf '%s\n' "$T/sdz" "$T/sdz1" "$T/sdz2"; }
disk_of() { echo "$1"; }
boot_disk() { echo /dev/sdy; }
target_disk() { echo /dev/sdx; }
fail() { echo "abgelehnt: $*"; exit 2; }
(exec 3<"$T/sdz2" && exec sleep 300) >/dev/null 2>&1 &
READER=$!
check "nur lesend offen (etwa ddrescue auf der Quelle): keine Schreib-Disk" '! disk_written "$T/sdz"'
(exec 3>>"$T/sdz1" && exec sleep 300) >/dev/null 2>&1 &
WRITER=$!
sleep 0.3
check "eine Partition zum Schreiben offen (dd, partclone): erkannt" 'disk_written "$T/sdz"'
check "source_ok lehnt diese Disk ab" '[[ $( (source_ok "$T/sdz") ; echo "rc=$?") == *"wird gerade beschrieben"*"rc=2" ]]'
kill "$WRITER" "$READER" 2>/dev/null
wait "$WRITER" "$READER" 2>/dev/null
check "source_ok lehnt nbd (Overlay des Klons) und zram ab" '[[ $( (source_ok /dev/nbd0); echo "rc=$?") == *"Hilfsgerät"*"rc=2" && $( (source_ok /dev/zram0); echo "rc=$?") == *"rc=2" ]]'
check "eine Disk ohne Schreibzugriff bleibt Quelle" '[[ $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
