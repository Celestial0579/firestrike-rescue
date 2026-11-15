#!/usr/bin/env bash
# Unit-Test: runv meldet den Fehler eines Befehls weiter und zeigt seine Ausgabe nur gefiltert.
#
# 1. Rückgabewert. runv zeigt die Ausgabe eines Befehls an und schreibt sie ins Protokoll. Der
#    Rückgabewert war immer der von tee, also 0: "runv … || return" reagierte nie. Beim
#    Verkleinern einer Partition hieß das: Scheitert das Verkleinern des Dateisystems, wird die
#    Partition trotzdem verkleinert, und das Dateisystem ragt über ihr Ende hinaus.
# 2. Ausgabe. Werkzeuge geben Namen von fremden Datenträgern aus, also auch Steuerfolgen für das
#    Terminal. Die Ausgabe erreicht Bildschirm und Protokoll nur gefiltert (term_clean).
#
# Ohne root und ohne Disks: sudo ist eine Attrappe, die Werkzeuge scheitern auf Wunsch.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
LF_RUN=$T
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/clone.sh
# shellcheck disable=SC1091
. rescue/lib/resize.sh
LF_LOG=$T/log
: >"$LF_LOG"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# ---------------------------------------------------------------------------
echo "runv gibt den Rückgabewert des Befehls zurück:"
runv true >/dev/null
check "Erfolg: 0" '[[ $? == 0 ]]'
runv false >/dev/null
check "Fehler: 1" '[[ $? == 1 ]]'
runv bash -c 'echo ausgabe; exit 3' >"$T/out"
check "Rückgabe 3 bleibt 3, die Ausgabe kommt trotzdem an" '[[ $? == 3 && $(cat "$T/out") == ausgabe ]]'
check "das Protokoll nennt Befehl und Rückgabewert" 'grep -q -- "-> rc=3" "$LF_LOG" && grep -q "^ausgabe$" "$LF_LOG"'
if runv false >/dev/null; then r=weiter; else r=abbruch; fi
check "\"runv … || Abbruch\" reagiert auf den Fehler" '[[ $r == abbruch ]]'

echo "Die Ausgabe erreicht Bildschirm und Protokoll nur gefiltert:"
: >"$LF_LOG"
runv printf 'Datei \033[2J\033[HALLES GUT\x9b2J\xc2\x9b1m\a\x7f ende\n' >"$T/out"
check "ESC, U+009B, BEL und DEL sind entfernt" '[[ $(cat "$T/out") == "Datei [2J[HALLES GUT2J1m ende" ]]'
check "im Protokoll steht dasselbe" 'grep -qx "Datei \[2J\[HALLES GUT2J1m ende" "$LF_LOG"'
check "kein Steuerzeichen außer Zeilenwechsel bleibt" '! LC_ALL=C grep -q "[[:cntrl:]]" "$T/out"'
runv printf 'Größe: 50 %%\r 60 %%\tfertig – ß ä 😀\n' >"$T/out"
check "Umlaute, Gedankenstrich, Wagenrücklauf und Tabulator bleiben" '[[ $(cat "$T/out") == $'"'"'Größe: 50 %\r 60 %\tfertig – ß ä 😀'"'"' ]]'
runv printf 'vor\xff\x80nach\n' >"$T/out"
check "Bytes, die kein gültiges UTF-8 bilden, sind entfernt" '[[ $(cat "$T/out") == vornach ]]'
# Ein Zeichen und eine Steuerfolge, die über zwei Schreibvorgänge verteilt ankommen.
(
	printf 'a\xc3'
	read -r -t 0.3 _ </dev/zero
	printf '\xa4b\xc2'
	read -r -t 0.3 _ </dev/zero
	printf '\x9b[2Jc\n'
) | term_clean >"$T/out"
check "ein geteiltes Zeichen bleibt ganz, eine geteilte Steuerfolge wird entfernt" '[[ $(cat "$T/out") == "aäb[2Jc" ]]'

# ---------------------------------------------------------------------------
echo "Verkleinern: Scheitert das Dateisystem, bleibt die Partition, wie sie ist:"
GIB=1073741824
disk_pick() { echo ZIEL; }
safety_check_target() { return 0; }
disk_resolve() { echo /dev/sdz; }
disk_smart() { echo "OK|"; }
resize_pick_part() { echo /dev/sdz2; }
safety_release() { return 0; }
safety_confirm_target() { return 0; }
clone_min_size() { CLONE_MIN=$((10 * GIB)); }
ui_input() { echo 50; }
ui_msg() { :; }
pause() { :; }
clear() { :; }
# sudo schreibt jeden Aufruf mit. Die Werkzeuge antworten, wie die Szene es vorgibt.
sudo() {
	printf '%s\n' "$*" >>"$T/calls"
	case "$1 ${2:-}" in
	"blkid -o") echo "$FS" ;;
	"blockdev --getsize64") echo $((100 * GIB)) ;;
	"ntfsresize "*) echo "ntfsresize läuft"; return "$NTFS_RC" ;;
	"e2fsck "*) echo "e2fsck läuft"; return "$FSCK_RC" ;;
	"resize2fs "*) echo "resize2fs läuft"; return "$RESIZE_RC" ;;
	"sfdisk "*) cat >"$T/sfdisk-eingabe" ;;
	esac
}
# shrink DATEISYSTEM   Spielt "Partition verkleinern" durch. Ergebnis: CALLS, OUT.
shrink() {
	FS=$1
	rm -f "$T/calls" "$T/sfdisk-eingabe"
	OUT=$(resize_part shrink 2>&1)
	CALLS=$(cat "$T/calls" 2>/dev/null)
}
table_changed() { [[ $CALLS == *"sfdisk --no-reread -N 2 /dev/sdz"* ]]; }

NTFS_RC=0 FSCK_RC=0 RESIZE_RC=0
shrink ntfs
check "NTFS, alles gelingt: Dateisystem und danach Partition werden verkleinert" '[[ $CALLS == *"ntfsresize --force -s $((50 * GIB - 1048576)) /dev/sdz2"* ]] && table_changed && [[ $(cat "$T/sfdisk-eingabe") == ", 50GiB" ]]'
NTFS_RC=1
shrink ntfs
check "NTFS, ntfsresize scheitert: Die Partitionstabelle wird nicht angefasst" '[[ $CALLS == *ntfsresize* ]] && ! table_changed'
check "die Meldung sagt, dass die Partition bleibt" '[[ $OUT == *"Die Partition bleibt, wie sie ist"* ]]'
NTFS_RC=0

shrink ext4
check "ext4, alles gelingt: e2fsck, resize2fs, dann die Partition" '[[ $CALLS == *"e2fsck -fy /dev/sdz2"*"resize2fs /dev/sdz2 $(((50 * GIB - 1048576) / 1024))K"* ]] && table_changed'
FSCK_RC=1
shrink ext4
check "ext4, e2fsck hat Fehler behoben (Rückgabe 1): Es geht weiter" 'table_changed'
FSCK_RC=4
shrink ext4
check "ext4, e2fsck lässt Fehler stehen (Rückgabe 4): kein resize2fs, keine Partitionstabelle" '[[ $CALLS != *resize2fs* ]] && ! table_changed'
check "die Meldung sagt, dass nichts verkleinert wurde" '[[ $OUT == *"nichts verkleinert"* ]]'
FSCK_RC=0 RESIZE_RC=1
shrink ext4
check "ext4, resize2fs scheitert: Die Partitionstabelle wird nicht angefasst" '[[ $CALLS == *resize2fs* ]] && ! table_changed'
RESIZE_RC=0

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
