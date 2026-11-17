#!/usr/bin/env bash
# Unit-Test (GHSA-cwvh-chmr-9xg8): Der BitLocker-Wiederherstellungsschlüssel, den der Techniker
# eingibt, geht nur an dislocker. Er steht weder im Protokoll noch in der Kopie im Fallordner noch
# im Zustand für Claude. Ein Schlüssel, den eine ältere Fassung ins Protokoll geschrieben hat,
# kommt von dort nicht mehr weiter und wird im persistenten Speicher bereinigt.
#
# Hier wird nichts entschlüsselt und nichts eingehängt: sudo, findmnt, mountpoint, lsblk und die
# Eingabe sind Attrappen. Der Schlüssel ist ausgedacht (Ziffern der Eulerschen Zahl).
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh
# shellcheck disable=SC1091
. rescue/lib/claude.sh
LF_RUN="$T/run"
LF_PERSIST="$T/persist"
mkdir -p "$LF_RUN" "$T/case" "$T/claude" "$T/persist/logs"
LF_LOG="$LF_RUN/lf-test.log"
: >"$LF_LOG"

KEY="271828-182845-904523-536028-747135-266249-775724-709369"
DIGITS=${KEY//-/}
# So tippen Techniker den Schlüssel oft ab: mit Leerzeichen statt Bindestrichen.
INPUT="271828 182845 904523 536028 747135 266249 775724 709369"

ui_input() { printf '%s\n' "$INPUT"; }
ui_msg() { :; }
lsblk() { :; }
disks_overview() { echo "sda  500 GB  Etikett mit Notiz: $KEY"; }
mountpoint() { [[ -s $T/mounted ]]; }
findmnt() {
	[[ -s $T/mounted ]] || return 1
	if [[ " $* " == *" SOURCE "* ]]; then cat "$T/source"; else cat "$T/mounted"; fi
}
sudo() {
	printf '%s\n' "$*" >>"$T/sudo"
	case $1 in
	blkid) echo BitLocker ;;
	# Wie ein gesprächiges dislocker: Es nennt den Schlüssel in seiner Ausgabe.
	dislocker) echo "dislocker: recovery password $KEY" ;;
	mount)
		echo "ro,nodev,nosuid,noexec,nosymfollow" >"$T/mounted"
		echo "$LF_RUN/dislocker-loop0p2/dislocker-file" >"$T/source"
		;;
	esac
	return 0
}

# has_key DATEI   Steht der Schlüssel darin, mit Bindestrichen oder als 48 Ziffern am Stück?
has_key() { grep -qE -- "$KEY|$DIGITS" "$1" 2>/dev/null; }

# no_raw_paths   Im Code geht der Schlüssel nirgends über run, und das Protokoll kommt nirgends
#   ungefiltert in den Fallordner.
no_raw_paths() {
	! grep -nE '(^|[[:space:]])run sudo dislocker' rescue/lib/*.sh rescue/lf rescue/bin/* &&
		! grep -nF 'cp -f --remove-destination "$LF_LOG"' rescue/lib/*.sh rescue/lf rescue/bin/*
}

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "Eingabe des Schlüssels:"
check "Leerzeichen und Bindestriche werden zu 8 Gruppen zu 6 Ziffern" '[[ $(bitlocker_key_normalize "$INPUT") == "$KEY" && $(bitlocker_key_normalize "$DIGITS") == "$KEY" ]]'
check "47 oder 49 Ziffern, Buchstaben und eine leere Eingabe sind kein Schlüssel" '! bitlocker_key_normalize "${DIGITS:1}" && ! bitlocker_key_normalize "${DIGITS}1" && ! bitlocker_key_normalize "${KEY/7/a}" && ! bitlocker_key_normalize ""'

echo "Entsperren im Assistenten:"
part_mount_ro /dev/loop0p2 /mnt/lf-image/loop0p2
RC=$?
check "dislocker bekommt den Schlüssel, die Partition wird eingehängt" '[[ $RC == 0 ]] && grep -qF -- "dislocker -r -V /dev/loop0p2 -p$KEY -- " "$T/sudo"'
check "im Protokoll steht weder im Befehl noch in der Ausgabe der Schlüssel" '! has_key "$LF_LOG" && grep -qF -- "-p$LF_RECOVERY_KEY_MASK" "$LF_LOG" && grep -qF "recovery password $LF_RECOVERY_KEY_MASK" "$LF_LOG"'
log "Notiz mit Schlüssel $KEY und als Ziffern $DIGITS"
check "auch ein gewöhnlicher Protokolleintrag verliert ihn" '! has_key "$LF_LOG"'

: >"$T/sudo"
: >"$T/mounted"
INPUT="1234-5678"
part_mount_ro /dev/loop0p2 /mnt/lf-image/loop0p2
RC=$?
check "kein gültiger Schlüssel: kein dislocker, nichts eingehängt" '[[ $RC != 0 ]] && ! grep -q dislocker "$T/sudo" && [[ ! -s $T/mounted ]]'
INPUT="271828 182845 904523 536028 747135 266249 775724 709369"

echo "Protokoll einer älteren Fassung (Schlüssel steht noch darin):"
printf '%s\n' "2026-11-16 10:00:00 \$ sudo dislocker -r -V /dev/sdb2 -p$KEY -- /run/lf/dislocker-sdb2" >>"$LF_LOG"
NAME=$(basename "$LF_LOG")
log_copy_masked "$LF_LOG" "$T/case"
check "die Kopie im Fallordner enthält keinen Schlüssel" '[[ -f $T/case/$NAME ]] && ! has_key "$T/case/$NAME" && grep -qF "$LF_RECOVERY_KEY_MASK" "$T/case/$NAME"'
echo original >"$T/anderswo"
rm -f "$T/case/$NAME"
ln -s "$T/anderswo" "$T/case/$NAME"
log_copy_masked "$LF_LOG" "$T/case"
check "eine Verknüpfung im Fallordner wird ersetzt, nicht durchschrieben" '[[ ! -L $T/case/$NAME && -f $T/case/$NAME && $(cat "$T/anderswo") == original ]]'
check "die Kopie liegt ohne Reste einer Zwischendatei im Fallordner" '[[ -z $(find "$T/case" -name ".lf-log.*") ]]'

claude_context "$T/claude"
STATE="$T/claude/$CLAUDE_STATE_FILE"
check "der Zustand für Claude enthält keinen Schlüssel, auch nicht aus dem alten Protokoll" '[[ -s $STATE ]] && ! has_key "$STATE" && grep -qF "$LF_RECOVERY_KEY_MASK" "$STATE"'
LONG="$(printf 'x%.0s' {1..380})$KEY"
check "an der Grenze von 400 Zeichen bleibt kein halber Schlüssel stehen" '[[ $(printf "%s\n" "$LONG" | claude_data_filter) != *271828-182845* ]]'

echo "Persistenter Speicher:"
printf 'alt: -p%s\n' "$KEY" >"$T/persist/logs/lf-20261115-120000.log"
printf 'ohne Schlüssel\n' >"$T/persist/logs/lf-20261115-130000.log"
log_scrub_dir "$T/persist/logs"
check "ältere Protokolle werden bereinigt, andere bleiben unverändert" '! has_key "$T/persist/logs/lf-20261115-120000.log" && grep -qF "$LF_RECOVERY_KEY_MASK" "$T/persist/logs/lf-20261115-120000.log" && [[ $(cat "$T/persist/logs/lf-20261115-130000.log") == "ohne Schlüssel" ]]'

echo "Code:"
check "der Schlüssel geht nirgends über run, das Protokoll nirgends ungefiltert in den Fallordner" 'no_raw_paths >/dev/null'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
