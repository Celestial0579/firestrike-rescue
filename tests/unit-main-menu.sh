#!/usr/bin/env bash
# Unit-Test: Das Hauptmenü erscheint und empfiehlt bei einer auffälligen Disk die Datenrettung.
#
# Das Hauptmenü rief disks_overview in $( … ) auf. DISKS_ANY_BAD wurde damit nur in der
# Subshell gesetzt, und lf brach unter set -u mit "DISKS_ANY_BAD: unbound variable" ab,
# bevor das Menü erschien. Der Test lädt main_menu aus rescue/lf, ersetzt Dialoge, SMART und
# lsblk durch Attrappen und prüft:
#   - das Menü erscheint, auch unter set -u, ohne Fehlermeldung,
#   - mit einer auffälligen Disk ist "rescue" vorausgewählt und die Empfehlung nennt sie,
#   - mit unauffälligen Disks ist "clone" vorausgewählt,
#   - die Übersicht mit dem Zustand jeder Disk steht im Menütext,
#   - disks_overview gibt weiter dieselbe Tabelle aus (Claude-Kontext, Tests).
# Ohne Disks und ohne Dialoge.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LF_RUN="$T/run"
LF_LOG="$T/lf.log"
mkdir -p "$LF_RUN"
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/disks.sh
LF_RUN="$T/run"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# main_menu aus rescue/lf holen, ohne den Assistenten zu starten.
eval "$(sed -n '/^main_menu() {$/,/^}$/p' rescue/lf)"
check "main_menu aus rescue/lf geladen" '[[ $(type -t main_menu) == function ]]'

# Attrappen: zwei Disks, der SMART-Befund steht in $T/smart-<Gerät>.
disks_json() {
	printf '%s\n' '{"path":"/dev/sda","model":"Alte HDD","serial":"S1","size":500107862016,"tran":"sata"}' \
		'{"path":"/dev/sdb","model":"Neue SSD","serial":"S2","size":1000204886016,"tran":"usb"}'
}
disk_smart() { cat "$T/smart-$(basename "$1")"; }
ui_info() { :; }
# Schreibt die Argumente des Menüs mit, dann wie "Abbrechen": main_menu geht zu power_menu.
ui_menu() {
	printf '%s\n' "$@" >"$T/menu"
	return 1
}
power_menu() { return 0; }
claude_freigabe_hinweis() { :; }
tmux() { return 1; }
log() { :; }

# Wert nach --default-item
vorauswahl() { sed -n '/^--default-item$/{n;p;q}' "$T/menu"; }

menue_zeigen() {
	rm -f "$T/menu"
	(main_menu) >"$T/out" 2>&1
	rc=$?
}

echo "Eine Disk auffällig:"
echo 'WARN|3 umgelagerte Sektoren' >"$T/smart-sda"
echo 'OK|' >"$T/smart-sdb"
menue_zeigen
check "kein Abbruch, keine Fehlermeldung" '((rc == 0)) && [[ ! -s $T/out ]]'
check "das Menü erscheint" '[[ -s $T/menu ]]'
check "Datenrettung ist vorausgewählt" '[[ $(vorauswahl) == rescue ]]'
check "die Empfehlung nennt die auffällige Disk" 'grep -qF "Empfehlung: Datenrettung (auffällige Disk gefunden)" "$T/menu"'
check "die Übersicht zeigt den Zustand jeder Disk" 'grep -qE "^sda +\[WARN\] +Alte HDD" "$T/menu" && grep -qE "^sdb +\[OK\] +Neue SSD" "$T/menu" && grep -qF "3 umgelagerte Sektoren" "$T/menu"'

echo "Eine Disk defekt:"
echo 'DEFEKT|SMART-Gesamtstatus FAILED' >"$T/smart-sdb"
echo 'OK|' >"$T/smart-sda"
menue_zeigen
check "Datenrettung ist vorausgewählt" '((rc == 0)) && [[ $(vorauswahl) == rescue ]]'

echo "Alle Disks unauffällig:"
echo 'OK|' >"$T/smart-sdb"
menue_zeigen
check "kein Abbruch, keine Fehlermeldung" '((rc == 0)) && [[ ! -s $T/out ]]'
check "Klonen ist vorausgewählt" '[[ $(vorauswahl) == clone ]]'
check "die Empfehlung sagt: alle unauffällig" 'grep -qF "Empfehlung: alle Disks unauffällig" "$T/menu"'

echo "Ausgabe für andere Aufrufer:"
echo 'WARN|3 umgelagerte Sektoren' >"$T/smart-sda"
text=$(disks_overview)
check "disks_overview gibt Kopf, zwei Disks und den Grund aus" '[[ $(wc -l <<<"$text") == 4 && $(head -n 1 <<<"$text") == "GERÄT"* ]]'
disks_overview_scan
check "disks_overview_scan setzt beide Werte im Aufrufer" '((DISKS_ANY_BAD == 1)) && [[ $DISKS_OVERVIEW == "$text" ]]'

if ((fails)); then
	echo "unit-main-menu: $fails Fehler"
	exit 1
fi
echo "unit-main-menu: alles ok"
