#!/usr/bin/env bash
# Unit-Test: Der Name eines Fallordners bleibt ein Name.
#
# Beim Fortsetzen liest der Assistent die Ordner unter FRS/ von der Ziel-Disk. Ihr Name stand
# ungeprüft im Menü und danach in Befehlszeilen. Ein Ordner namens "--title" wurde von whiptail
# als Option gelesen, und ein Name mit einem Anführungszeichen wurde beim Umwandeln in VHDX als
# Befehl ausgeführt. Der Test prüft:
#   - casefile_dirname_ok lässt nur Namen zu, wie der Assistent sie vergibt,
#   - der Assistent vergibt selbst nur solche Namen, auch bei seltsamen Modellangaben,
#   - "Fortsetzen" bietet nur echte Ordner mit zulässigem Namen an,
#   - ein präparierter Name wird nirgends ausgeführt (keine Markerdatei).
# Ohne Disks und ohne Dialoge. Wie whiptail selbst mit solchen Einträgen umgeht, zeigt
# tests/dialog-menu-entries.sh.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8
REPO=$PWD

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/casefile.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh
# Präparierte Namen legen Markerdateien im Arbeitsverzeichnis an, falls sie ausgeführt werden.
mkdir -p "$T/lauf"
cd "$T/lauf" || exit 1

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
markers() { compgen -G "$T/lauf/MARKE-*" >/dev/null; }

# Namen, die als Option, als Befehl oder als Pfad gelesen werden könnten.
BAD=(
	"--title" "--yesno" "-x" "--output-fd=1"
	"x'; touch MARKE-quote; echo '" 'x"; touch MARKE-dquote; echo "' 'x$(touch MARKE-subst)' 'x`touch MARKE-backtick`'
	"a b" "a;b" "a&b" "a|b" "a*" "a?" "~a" "#a"
	".versteckt" ".." "." "_a"
	$'zwei\nZeilen' $'a\e[2Jb' $'a\tb'
	"Müller" ""
)

# ---------------------------------------------------------------------------
echo "Zulässige Namen:"
for name in "20261112-0900_WDC_WD10EZEX-08WN4A0_WD_WCC6Y0ABCDEF" "20261112-0900__sdb" "Kunde-Mueller_2026.2" "a" "0"; do
	check "'$name' zulässig" 'casefile_dirname_ok "$name"'
done
long=$(printf '%0200d' 0)
check "200 Zeichen zulässig" 'casefile_dirname_ok "$long"'
check "201 Zeichen abgelehnt" '! casefile_dirname_ok "${long}0"'
echo "Abgelehnte Namen:"
for name in "${BAD[@]}"; do
	check "$(printf '%q' "$name") abgelehnt" '! casefile_dirname_ok "$name"'
done
check "Prüfung hängt nicht von der Sprache ab" '! (LC_ALL=de_DE.UTF-8 casefile_dirname_ok "Müller") 2>/dev/null && ! (LC_ALL=C casefile_dirname_ok "Müller")'

# ---------------------------------------------------------------------------
# Attrappen für den Assistenten. Auswahl und Menüs laufen in $(…), deshalb in Dateien.
FRS_TARGET_MNT="$T/ziel"
FRS_LOG=/dev/null
log() { printf '%s\n' "$*" >>"$T/log"; }
tmux() { return 1; }
human() { echo "1GiB"; }
safety_set_ro() { :; }
safety_check_target() { return 0; }
target_prepare() { return 0; }
target_find_cases() { return 0; }
disk_resolve() { echo /dev/sdx; }
disk_label() { echo "Disk"; }
ddrescuelog() { :; }
ui_yesno() { return 0; }
ui_msg() { printf '%s|%s\n' "$1" "$2" >>"$T/msg"; }
die() {
	printf 'Abbruch|%s\n' "$*" >>"$T/msg"
	return 1
}
# disk_pick: erster Aufruf Quelle, zweiter Aufruf Ziel.
disk_pick() {
	echo x >>"$T/pick"
	if (($(wc -l <"$T/pick") == 1)); then echo "$SOURCE_ID"; else echo "ZIEL-0009"; fi
}
disk_info() {
	if [[ $1 == ZIEL-0009 ]]; then
		echo '{"path":"/dev/sdy","serial":"ZIEL-0009","size":2000398934016,"model":"Ziel"}'
	else
		jq -cn --arg m "$MODEL" --arg s "$1" '{path: "/dev/sdx", serial: $s, wwn: null, size: 1000204886016, model: $m, tran: "usb"}'
	fi
}
# tmux_run NAME BEFEHL...: ohne tmux, der Befehl läuft direkt. So zeigt sich, ob ein Name in
# einer Befehlszeile zum Befehl wird.
tmux_run() {
	echo "$*" >>"$T/tmux"
	shift
	"$@" </dev/null >/dev/null 2>&1
}
qemu-img() { :; }
export -f qemu-img

# ---------------------------------------------------------------------------
echo "Der Assistent vergibt nur zulässige Namen:"
recover_run() { printf '%s\n' "$1" >>"$T/run"; }
# wizard MODELL KENNUNG   Legt einen Rettungsfall an. Ergebnis: NAME (Name des Fallordners).
wizard() {
	MODEL=$1 SOURCE_ID=$2
	rm -rf "$T/ziel" "$T/pick" "$T/run" "$T/msg"
	mkdir -p "$T/ziel"
	recover_wizard
	NAME=$(basename "$(cat "$T/run" 2>/dev/null)")
}
wizard "WDC WD10EZEX-08WN4A0" "WD-WCC6Y0ABCDEF"
check "gewöhnliche Disk: Fall angelegt" '[[ -f $T/ziel/FRS/$NAME/case.env ]]'
check "gewöhnliche Disk: Modell und Kennung im Namen" '[[ $NAME == *_WDC_WD10EZEX-08WN4A0_WD_WCC6Y0ABCDEF ]]'
i=0
for model in "--title" "x'; touch MARKE-modell; echo '" 'Disk $(touch MARKE-modell2)' "Platte für Müller" "" $'Zeile1\nZeile2' "$(printf '%0300d' 0)"; do
	i=$((i + 1))
	wizard "$model" "S/N: 12 34'\"; touch MARKE-serial"
	check "Modellangabe $i: Name zulässig, Fall angelegt" 'casefile_dirname_ok "$NAME" && [[ -f $T/ziel/FRS/$NAME/case.env ]]'
done
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# ---------------------------------------------------------------------------
echo "Fortsetzen bietet nur echte Ordner mit zulässigem Namen an:"
recover_after() { printf '%s\n' "$1" >>"$T/after"; }
ui_menu() {
	shift 3
	printf '%s\n' "$@" >"$T/menu"
	echo "${PICK-$1}"
}
# zielfall NAME [ZUSTAND]   Rettungsfall auf der gedachten Ziel-Disk.
zielfall() {
	mkdir -p "$T/ziel/FRS/$1"
	printf '%s\n' 'SRC_ID="ABC"' 'SRC_SIZE="1"' "STATE=\"${2:-done}\"" >"$T/ziel/FRS/$1/case.env"
}
# resume   Ruft recover_resume auf. Ergebnis: MENU (angebotene Einträge), MSG, AFTER.
resume() {
	rm -f "$T/pick" "$T/menu" "$T/msg" "$T/after" "$T/run" "$T/tmux" "$T/log"
	recover_resume
	MENU=$(cat "$T/menu" 2>/dev/null)
	MSG=$(cat "$T/msg" 2>/dev/null)
	AFTER=$(cat "$T/after" 2>/dev/null)
	LOG=$(cat "$T/log" 2>/dev/null)
}
rm -rf "$T/ziel"
mkdir -p "$T/ziel/FRS" "$T/woanders"
zielfall 20261112-0900_WDC_gut
zielfall 20261101-1200_kaputt
echo 'touch MARKE-falldatei' >"$T/ziel/FRS/20261101-1200_kaputt/case.env"
# Jeder präparierte Name bekommt einen Ordner mit gültiger Falldatei. Namen mit Punkt am
# Anfang erfasst das Muster FRS/*/ ohnehin nicht.
hostile=0
for name in "${BAD[@]}"; do
	[[ -n $name && $name != .* ]] || continue
	zielfall "$name"
	hostile=$((hostile + 1))
done
mkdir -p "$T/ziel/FRS/Alte Sachen" # fremder Ordner ohne Falldatei: wird still übergangen
printf '%s\n' 'SRC_ID="ABC"' 'SRC_SIZE="1"' 'STATE="done"' >"$T/woanders/case.env"
ln -s "$T/woanders" "$T/ziel/FRS/verknuepft" # Verknüpfung mit zulässigem Namen: zählt mit
hostile=$((hostile + 1))
resume
check "angeboten werden genau die beiden zulässigen Ordner" '[[ $MENU == "20261101-1200_kaputt"$'"'"'\n'"'"'"[ungültig]"$'"'"'\n'"'"'"20261112-0900_WDC_gut"$'"'"'\n'"'"'"[done]" ]]'
check "die übrigen sind gezählt, mit Hinweis" '[[ $MSG == "Fortsetzen|Nicht angebotene Einträge unter FRS/: '"$hostile"'"* ]]'
check "der Hinweis nennt keinen der Namen" '[[ $MSG != *title* && $MSG != *touch* && $MSG != *MARKE* && $LOG != *touch* ]]'
check "es sind mehr als 20 präparierte Einträge" '((hostile > 20))'
check "der ungültige Fall wird gewählt und abgelehnt, nicht ausgeführt" '[[ -z $AFTER && $MSG == *"Rettungsfall nicht verwendbar"* ]]'
# Der Ordner zu diesem Namen liegt auf der Disk, mit gültiger Falldatei im Zustand "done".
PICK="x'; touch MARKE-quote; echo '"
resume
check "den Ordner zum präparierten Namen gibt es, mit gültiger Falldatei" '[[ $(casefile_peek "$T/ziel/FRS/$PICK/case.env" STATE) == "done" ]]'
check "liefert das Menü einen nicht angebotenen Namen, passiert nichts" '[[ -z $AFTER && $MSG != *"nicht verwendbar"* ]]'
unset PICK

rm -rf "$T/ziel/FRS"
mkdir -p "$T/ziel/FRS"
zielfall "--title"
zielfall "x'; touch MARKE-einzig; echo '"
resume
check "nur präparierte Ordner: kein Menü, klare Meldung" '[[ -z $MENU && $MSG == *"kein Rettungsfall, den der Assistent verwenden kann"* ]]'

rm -rf "$T/ziel/FRS"
mkdir -p "$T/echtes-frs"
ln -s "$T/echtes-frs" "$T/ziel/FRS"
zielfall 20261112-0900_WDC_gut
resume
check "FRS selbst ist eine Verknüpfung: kein Menü, abgelehnt" '[[ -z $MENU && -z $AFTER && $MSG == *"FRS auf dieser Disk ist eine Verknüpfung"* ]]'
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# ---------------------------------------------------------------------------
echo "Ein präparierter Name wird in keiner Befehlszeile zum Befehl:"
# Jetzt mit dem echten recover_after: Der Techniker wählt den Fall und "In VHDX umwandeln".
# shellcheck disable=SC1090
. "$REPO/rescue/lib/recover.sh"
rm -rf "$T/ziel/FRS"
mkdir -p "$T/ziel/FRS"
zielfall "x'; touch MARKE-vhdx; echo '"
ui_menu() {
	echo x >>"$T/menues"
	case $(wc -l <"$T/menues") in
	1) echo "$4" ;;
	2) echo vhdx ;;
	*) echo "done" ;;
	esac
}
rm -f "$T/menues" "$T/pick" "$T/tmux" "$T/msg"
recover_resume
check "über Fortsetzen: keine Befehlszeile gebaut, nichts ausgeführt" '[[ ! -e $T/tmux ]] && ! markers'
rm -f "$T/menues" "$T/tmux" "$T/msg"
echo x >"$T/menues"
recover_after "$T/ziel/FRS/x'; touch MARKE-direkt; echo '"
check "recover_after direkt: abgelehnt, keine Befehlszeile gebaut" '[[ ! -e $T/tmux && $(cat "$T/msg") == "Abbruch|Der Fallordner hat einen Namen"* ]] && ! markers'
zielfall 20261112-0900_WDC_gut
rm -f "$T/menues" "$T/tmux" "$T/msg"
echo x >"$T/menues"
recover_after "$T/ziel/FRS/20261112-0900_WDC_gut"
check "zulässiger Name: die Umwandlung wird gestartet" '[[ $(cat "$T/tmux" 2>/dev/null) == "frs-vhdx bash -c qemu-img convert"*"/FRS/20261112-0900_WDC_gut/image.vhdx"* ]]'

cd "$REPO" || exit 1
rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
