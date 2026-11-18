#!/usr/bin/env bash
# Unit-Test (GHSA-cwvh-chmr-9xg8): Der BitLocker-Wiederherstellungsschlüssel, den der Techniker
# eingibt, geht nur an dislocker. Er steht weder im Protokoll noch in der Kopie im Fallordner noch
# im Zustand für Claude. Ein Schlüssel, den eine ältere Fassung ins Protokoll geschrieben hat,
# kommt von dort nicht mehr weiter und wird im persistenten Speicher bereinigt, auch in den
# Verläufen und Protokollen von Claude.
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
# dislocker selbst ist ein Programm (die root-Shell startet es mit exec): Es schreibt auf, was es
# bekommt, und nennt den Schlüssel wie ein gesprächiges dislocker in seiner Ausgabe.
mkdir -p "$T/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/dislocker"\necho "dislocker: recovery password %s"\n' "$T" "$KEY" >"$T/bin/dislocker"
chmod +x "$T/bin/dislocker"
PATH="$T/bin:$PATH"
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
	# Die root-Shell, die den Schlüssel von der Standardeingabe liest und dislocker startet.
	bash) "$@" ;;
	mount)
		echo "ro,nodev,nosuid,noexec,nosymfollow" >"$T/mounted"
		echo "$LF_RUN/dislocker-loop0p2/dislocker-file" >"$T/source"
		;;
	esac
	return 0
}

# has_key DATEI   Steht der Schlüssel darin, mit Bindestrichen, mit Leerzeichen oder als 48 Ziffern
#   am Stück?
has_key() { grep -qE -- "$KEY|$INPUT|$DIGITS" "$1" 2>/dev/null; }

# no_raw_paths   Im Code geht der Schlüssel nirgends über run, und das Protokoll kommt nirgends
#   ungefiltert in den Fallordner.
no_raw_paths() {
	! grep -nE '(^|[[:space:]])run sudo dislocker|sudo dislocker .*-p' rescue/lib/*.sh rescue/lf rescue/bin/* &&
		grep -qF "IFS= read -r k && exec dislocker" rescue/lib/recover.sh &&
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
check "dislocker bekommt den Schlüssel, die Partition wird eingehängt" '[[ $RC == 0 && -s $T/mounted ]] && grep -qxF -- "-r -V /dev/loop0p2 -p$KEY -- $LF_RUN/dislocker-loop0p2" "$T/dislocker"'
check "keine Befehlszeile von sudo enthält den Schlüssel (ps, Journal)" '[[ -s $T/sudo ]] && ! has_key "$T/sudo" && grep -q "^bash -c " "$T/sudo"'
check "im Protokoll steht weder im Befehl noch in der Ausgabe der Schlüssel" '! has_key "$LF_LOG" && grep -qF "recovery password $LF_RECOVERY_KEY_MASK" "$LF_LOG"'
log "Notiz mit Schlüssel $KEY, als Ziffern $DIGITS und wie getippt $INPUT"
check "auch ein gewöhnlicher Protokolleintrag verliert ihn, auch mit Leerzeichen" '! has_key "$LF_LOG"'

: >"$T/sudo"
: >"$T/mounted"
INPUT="1234-5678"
part_mount_ro /dev/loop0p2 /mnt/lf-image/loop0p2
RC=$?
check "kein gültiger Schlüssel: kein dislocker, nichts eingehängt" '[[ $RC != 0 ]] && ! grep -q dislocker "$T/sudo" && [[ ! -s $T/mounted ]]'
: >"$T/dislocker"
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

echo "Fallordner auf der Ziel-Disk (Kopien älterer Fassungen):"
F="$T/fall"
mkdir -p "$F"
printf '2026-11-16 10:00:00 $ sudo dislocker -r -V /dev/sdb2 -p%s -- /run/lf/dislocker-sdb2\n' "$INPUT" >"$F/lf-20261116-100000.log"
printf 'Protokoll ohne Schlüssel\n' >"$F/lf-20261116-110000.log"
printf 'image %s\n' "$KEY" >"$F/image.map"
printf 'woanders %s\n' "$KEY" >"$T/woanders"
ln -s "$T/woanders" "$F/lf-verknuepfung.log"
touch -d '2026-11-16 11:00' "$F/lf-20261116-110000.log"
mt_ohne=$(stat -c %Y "$F/lf-20261116-110000.log")
log_scrub_case "$F"
check "die alte Protokollkopie im Fallordner verliert den Schlüssel" '! has_key "$F/lf-20261116-100000.log" && grep -qF "dislocker -r -V /dev/sdb2 -p$LF_RECOVERY_KEY_MASK" "$F/lf-20261116-100000.log"'
check "Kopien ohne Schlüssel, andere Dateien, Verknüpfungen und ihr Ziel bleiben" '[[ $(stat -c %Y "$F/lf-20261116-110000.log") == "$mt_ohne" && -L $F/lf-verknuepfung.log ]] && has_key "$T/woanders" && has_key "$F/image.map" && [[ -z $(find "$F" -name ".lf-log.*") ]]'
check "beim Fortsetzen wird der Fallordner bereinigt, sobald die Falldatei gültig ist" 'grep -A6 "if ! casefile_load \"\$c/case.env\"; then" rescue/lib/recover.sh | grep -qxF "	log_scrub_case \"\$c\""'

echo "Daten von Claude auf dem Speicher (von älteren Fassungen):"
H="$T/claude-home"
P="$H/.claude/projects/-var-lib-lf-claude"
LDB="$H/.config/Claude/Local Storage/leveldb"
mkdir -p "$P" "$H/.config/Claude/logs" "$LDB"
printf '{"type":"user","message":{"content":"Schlüssel ist %s"}}\n' "$INPUT" >"$P/sitzung.jsonl"
printf '{"type":"user","toolUseResult":{"stdout":"$ sudo dislocker -r -V /dev/sdb2 -p%s -- /run/lf/dislocker-sdb2"}}\n' "$KEY" >>"$P/sitzung.jsonl"
printf '{"display":"%s","timestamp":1}\n' "$DIGITS" >"$H/.claude/history.jsonl"
printf '{"projects":{"/var/lib/lf-claude":{"history":[{"display":"Schlüssel %s"}]}}}\n' "$KEY" >"$H/.claude.json"
chmod 600 "$H/.claude.json"
printf 'main: -p%s\n' "$KEY" >"$H/.config/Claude/logs/main.log"
printf 'Regeln ohne Schlüssel, mit Umlauten äöü\n' >"$H/.claude/CLAUDE.md"
# Eine Datenbank der App (Nullbytes) und eine Verknüpfung nach draußen bleiben, wie sie sind.
printf 'leveldb\0%s\n' "$KEY" >"$LDB/000003.log"
printf 'fremd %s\n' "$KEY" >"$T/fremd"
ln -s "$T/fremd" "$H/.claude/verknuepfung"
sum_ldb=$(sha256sum <"$LDB/000003.log")
sum_md=$(sha256sum <"$H/.claude/CLAUDE.md")
claude_as() { printf '%s\n' "$*" >>"$T/claude_as"; "$@"; }
log_scrub_tree claude_as -- "$H"
check "Verläufe, Eingabeverlauf, Einstellungen und Protokolle von Claude ohne Schlüssel" '! has_key "$P/sitzung.jsonl" && ! has_key "$H/.claude/history.jsonl" && ! has_key "$H/.claude.json" && ! has_key "$H/.config/Claude/logs/main.log" && [[ $(grep -cF -- "$LF_RECOVERY_KEY_MASK" "$P/sitzung.jsonl") == 2 ]] && grep -qF "$LF_RECOVERY_KEY_MASK" "$H/.claude/history.jsonl"'
check "maskiert, nicht gelöscht: gültiges JSON, der Rest jeder Zeile und die Rechte bleiben" 'jq -e . "$P/sitzung.jsonl" "$H/.claude.json" >/dev/null && grep -qF "dislocker -r -V /dev/sdb2 -p$LF_RECOVERY_KEY_MASK -- /run/lf/dislocker-sdb2" "$P/sitzung.jsonl" && [[ $(stat -c %a "$H/.claude.json") == 600 && $(sha256sum <"$H/.claude/CLAUDE.md") == "$sum_md" ]]'
check "Datenbanken, Verknüpfungen und ihr Ziel bleiben unberührt" '[[ $(sha256sum <"$LDB/000003.log") == "$sum_ldb" && -L $H/.claude/verknuepfung ]] && has_key "$T/fremd"'
check "find und sed laufen als Besitzer der Daten (claude_as)" 'grep -q "^env LC_ALL=C find $H " "$T/claude_as" && grep -q "^env LC_ALL=C sed -E -i " "$T/claude_as"'
sums() { find "$H" -type f -printf '%p %T@ ' -exec sha256sum {} \; | sort; }
before=$(sums)
: >"$T/claude_as"
log_scrub_tree claude_as -- "$H"
check "ein zweiter Lauf ändert nichts" '[[ $(sums) == "$before" ]] && ! grep -q " sed " "$T/claude_as" && ! grep -q "^env LC_ALL=C sed" "$T/claude_as"'
check "persist_bind maskiert vor dem Start von Claude: sein Home und die alten Ordner des Live-Benutzers" 'grep -A8 "^	persist_bind_claude$" rescue/lib/persist.sh | grep -qxF "	log_scrub_tree claude_as -- \"\$CLAUDE_HOME\" || true" && grep -A8 "^	persist_bind_claude$" rescue/lib/persist.sh | grep -qxF "	log_scrub_tree -- \"\$LF_PERSIST/home/.claude\" \"\$LF_PERSIST/home/.config/Claude\" || true"'

echo "Code:"
check "der Schlüssel geht nirgends über run, das Protokoll nirgends ungefiltert in den Fallordner" 'no_raw_paths >/dev/null'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
