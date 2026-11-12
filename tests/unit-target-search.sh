#!/usr/bin/env bash
# Unit-Test: Die Suche nach Rettungsfällen schreibt nicht.
#
# "Unterbrochene Rettung fortsetzen" hängte jede passende Partition der gewählten Disk
# beschreibbar ein, bis ein Rettungsfall gefunden war. Wer dort versehentlich die defekte Disk
# wählte, ließ ihre Dateisysteme beschreibbar einhängen und ihre Journale nachspielen. Der Test
# prüft:
#   - jede Partition ist vor dem Einhängen auf Kernelebene schreibgeschützt und wird nur lesend
#     eingehängt, ohne dass ein Journal nachgespielt wird,
#   - Partitionen ohne Rettungsfall sind danach wieder, wie sie waren,
#   - beschreibbar wird erst die Partition, deren Rettungsfall der Techniker gewählt hat,
#   - ein Schreibschutz, der vorher schon galt (Quell-Disk), wird nie aufgehoben.
#
# Hier wird nichts eingehängt. Ein gedachter Kernel führt Buch über den Schreibschutz der Geräte
# und über das, was am Einhängepunkt gilt. Der Einhängepunkt ist eine Verknüpfung auf einen
# Ordner mit dem Inhalt der Partition.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/casefile.sh
# shellcheck disable=SC1091
. rescue/lib/target.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh
FRS_RUN="$T/run"
FRS_TARGET_MNT="$T/mnt"
FRS_LOG=/dev/null
mkdir -p "$FRS_RUN" "$T/ro" "$T/inhalt"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# ---------------------------------------------------------------------------
# Die gedachte Disk /dev/sdz. PARTS: je Zeile "PFAD DATEISYSTEM", in der Reihenfolge von lsblk.
# Ein Ordner $T/inhalt/NAME ist der Inhalt einer Partition, $T/ro/NAME ihr Schreibschutz.
# ---------------------------------------------------------------------------
log() { printf '%s\n' "$*" >>"$T/log"; }
run() { "$@"; }
id() { echo 1000; }
disk_resolve() { [[ $1 == ZIEL-0009 ]] && echo /dev/sdz; }
disk_parts() {
	local path fs
	while read -r path fs; do
		[[ -n $path ]] && jq -cn --arg p "$path" --arg f "$fs" '{path: $p, fstype: $f}'
	done <<<"$PARTS"
}
lsblk() {
	local path fs last
	for last; do :; done
	case "$*" in
	"-no FSTYPE "*)
		while read -r path fs; do [[ $path == "$last" ]] && echo "$fs"; done <<<"$PARTS"
		;;
	"-nr -o PATH "*)
		echo /dev/sdz
		while read -r path fs; do echo "$path"; done <<<"$PARTS"
		;;
	esac
}
mountpoint() { [[ -L $T/mnt ]]; }
findmnt() {
	[[ -L $T/mnt ]] || return 1
	if [[ " $* " == *" SOURCE "* ]]; then cat "$T/source"; else cat "$T/mounted"; fi
}
sudo() {
	local name
	case "$1 ${2-}" in
	"blockdev --getro")
		[[ -e $T/ro/${3##*/} ]] && echo 1 || echo 0
		;;
	"blockdev --setro")
		name=${3##*/}
		[[ " $SETRO_FAIL " == *" $name "* ]] && return 1
		: >"$T/ro/$name"
		echo "setro $name" >>"$T/events"
		;;
	"blockdev --setrw")
		name=${3##*/}
		rm -f "$T/ro/$name"
		echo "setrw $name" >>"$T/events"
		;;
	mount\ * | ntfs-3g\ *) kernel_mount "$@" ;;
	umount\ *)
		((UMOUNT_OK)) || return 32
		rm -f "$T/mnt" "$T/mounted" "$T/source"
		echo "umount" >>"$T/events"
		;;
	esac
}
# Der gedachte Kernel beim Einhängen:
#   - Auf einem schreibgeschützten Gerät hängt er nur lesend ein, auch wenn "rw" verlangt ist.
#   - Ein Dateisystem mit offenem Journal ($DIRTY) lässt sich auf einem schreibgeschützten Gerät
#     nur einhängen, wenn die Option gegen das Nachspielen gesetzt ist.
#   - ntfs-3g kennt nosymfollow nicht. Aufrufe, deren Text zu $REFUSE passt, lehnt er ab.
kernel_mount() {
	local tool=$1 opts="" have o dev="" name all="$*"
	shift
	while (($#)); do
		case $1 in
		-o) opts=$2; shift ;;
		/dev/*) dev=$1 ;;
		esac
		shift
	done
	[[ -n $REFUSE && $all == *$REFUSE* ]] && return 32
	if [[ ",$opts," == *,remount,* ]]; then
		have=$(cut -d, -f1 "$T/mounted")
		for o in nodev nosuid noexec nosymfollow; do
			[[ ",$opts," == *",$o,"* ]] && have+=",$o"
		done
		echo "$have" >"$T/mounted"
		echo "remount $opts" >>"$T/events"
		return 0
	fi
	[[ $tool == ntfs-3g && ",$opts," == *,nosymfollow,* ]] && return 1
	name=${dev##*/}
	if [[ -e $T/ro/$name && " $DIRTY " == *" $name "* && $opts != *noload* && $opts != *norecovery* && $opts != *nologreplay* && $opts != *norecover* ]]; then
		return 32
	fi
	if [[ ",$opts," == *,ro,* || -e $T/ro/$name ]]; then have=ro; else have=rw; fi
	for o in nodev nosuid noexec nosymfollow; do
		[[ ",$opts," == *",$o,"* ]] && have+=",$o"
	done
	echo "$have" >"$T/mounted"
	echo "$dev" >"$T/source"
	ln -sfn "$T/inhalt/$name" "$T/mnt"
	echo "mount $name [$opts] geschuetzt=$([[ -e $T/ro/$name ]] && echo ja || echo nein) ergebnis=${have%%,*}" >>"$T/events"
}

# part NAME DATEISYSTEM [FALL...]   Legt den Inhalt einer Partition an, mit Rettungsfällen.
part() {
	local name=$1 c
	PARTS+="/dev/$name $2"$'\n'
	mkdir -p "$T/inhalt/$name"
	shift 2
	for c in "$@"; do
		mkdir -p "$T/inhalt/$name/FRS/$c"
		printf '%s\n' 'SRC_ID="ABC"' 'SRC_SIZE="1"' 'STATE="done"' >"$T/inhalt/$name/FRS/$c/case.env"
	done
}
# machine   Neue Maschine: nichts eingehängt, nichts geschützt, keine Partitionen.
machine() {
	rm -rf "${T:?}/inhalt" "${T:?}/ro" "${T:?}/mnt" "${T:?}/mounted" "${T:?}/source" "${T:?}/events" "${T:?}/log" "$FRS_RUN/search-lock"
	mkdir -p "$T/inhalt" "$T/ro"
	PARTS="" UMOUNT_OK=1 SETRO_FAIL="" DIRTY="" REFUSE=""
	TARGET_CASE_PART="" TARGET_CASE_ACTIVE=0
}
events() { cat "$T/events" 2>/dev/null; }
mounts() { grep '^mount ' "$T/events" 2>/dev/null; }
protected() { ls "$T/ro" | tr '\n' ' '; }
state() { cat "$T/mounted" 2>/dev/null; }
ALL="nodev,nosuid,noexec,nosymfollow"

# ---------------------------------------------------------------------------
echo "Suche auf einer Disk mit drei Partitionen, der Rettungsfall liegt auf der zweiten:"
machine
part sdz1 ext4
part sdz2 ext4 20261112-0900_WDC_X
part sdz3 xfs
DIRTY="sdz1 sdz2"
target_find_cases ZIEL-0009
rc=$?
check "Rettungsfall gefunden, auf der zweiten Partition" '[[ $rc == 0 && $TARGET_CASE_PART == /dev/sdz2 ]]'
check "jede eingehängte Partition war vorher auf Kernelebene schreibgeschützt" '[[ $(mounts | wc -l) == 2 ]] && ! mounts | grep -q "geschuetzt=nein"'
check "eingehängt wurde nur lesend, mit Schutzoptionen, ohne das Journal nachzuspielen" '[[ $(mounts | grep -c "\[ro,$ALL,noload\]") == 2 ]] && ! mounts | grep -q "ergebnis=rw"'
check "die Partition ohne Rettungsfall ist wieder ausgehängt und nicht mehr geschützt" '[[ $(events | sed -n 1,4p | tr "\n" " ") == "setro sdz1 mount sdz1 "*"umount setrw sdz1 " ]]'
check "die Partition mit dem Rettungsfall hängt nur lesend und bleibt geschützt" '[[ $(state) == "ro,$ALL" && $(protected) == "sdz2 " ]]'
check "die dritte Partition wurde nicht angefasst" '! events | grep -q sdz3'
check "der Rettungsfall ist lesbar" '[[ $(casefile_peek "$FRS_TARGET_MNT/FRS/20261112-0900_WDC_X/case.env" STATE) == "done" ]]'

echo "Die Suche wird nicht weiterverwendet (abgebrochen):"
target_search_end
check "ausgehängt, kein Schreibschutz bleibt zurück" '[[ ! -L $T/mnt && -z $(protected) && ! -e $FRS_RUN/search-lock ]]'
check "zu keiner Zeit war etwas beschreibbar eingehängt" '! mounts | grep -q "ergebnis=rw"'

echo "Der Techniker wählt den Rettungsfall:"
machine
part sdz1 ext4
part sdz2 ext4 20261112-0900_WDC_X
target_find_cases ZIEL-0009
target_case_writable
rc=$?
check "jetzt hängt die Partition beschreibbar, mit Schutzoptionen" '[[ $rc == 0 && $(state) == "rw,$ALL" && $(cat "$T/source") == /dev/sdz2 ]]'
check "ihr Schreibschutz ist aufgehoben, kein anderer wurde angefasst" '[[ -z $(protected) && $(events | grep -c "^setrw sdz2") == 1 ]]'
check "beschreibbar eingehängt wurde nur diese eine Partition, und erst zuletzt" '[[ $(mounts | grep -c "ergebnis=rw") == 1 && $(mounts | tail -n1) == "mount sdz2 [$ALL] geschuetzt=nein ergebnis=rw" ]]'

echo "Disk ohne Rettungsfall (etwa die versehentlich gewählte Quelle):"
machine
part sdz1 ntfs
part sdz2 ext4
part sdz3 xfs
part sdz4 btrfs
part sdz5 exfat
part sdz6 swap
DIRTY="sdz2 sdz3 sdz4"
target_find_cases ZIEL-0009
rc=$?
check "kein Rettungsfall gefunden" '[[ $rc != 0 && -z $TARGET_CASE_PART ]]'
check "alle fünf Dateisysteme wurden durchsucht, Swap nicht" '[[ $(mounts | wc -l) == 5 ]] && ! events | grep -q sdz6'
check "keines war je beschreibbar eingehängt" '! mounts | grep -q "ergebnis=rw" && ! mounts | grep -q "geschuetzt=nein"'
check "je Dateisystem die Option gegen das Nachspielen" 'mounts | grep -q "sdz1 \[ro,$ALL\]" && mounts | grep -q "sdz2 \[ro,$ALL,noload\]" && mounts | grep -q "sdz3 \[ro,$ALL,norecovery\]" && mounts | grep -q "sdz4 \[ro,$ALL,rescue=nologreplay\]" && mounts | grep -q "sdz5 \[ro,$ALL\]"'
check "danach ist nichts eingehängt und nichts mehr geschützt" '[[ ! -L $T/mnt && -z $(protected) ]]'

echo "NTFS über ntfs-3g (Kerneltreiber lehnt ab):"
machine
part sdz1 ntfs 20261112-0900_WDC_X
REFUSE="-t ntfs3"
target_find_cases ZIEL-0009
rc=$?
check "nur lesend, ohne Journal, nosymfollow nachgesetzt" '[[ $rc == 0 && $(state) == "ro,$ALL" ]] && mounts | grep -q "sdz1 \[ro,norecover,nodev,nosuid,noexec\] geschuetzt=ja"'

echo "Die gewählte Disk ist schon als Quelle geschützt:"
machine
part sdz1 ext4 20261112-0900_WDC_X
: >"$T/ro/sdz"
: >"$T/ro/sdz1"
target_find_cases ZIEL-0009
target_search_end
check "ihr Schreibschutz wird nie aufgehoben" '! events | grep -q setrw && [[ $(protected) == "sdz sdz1 " ]]'

echo "Der Schreibschutz lässt sich nicht setzen:"
machine
part sdz1 ext4 20261112-0900_WDC_X
SETRO_FAIL="sdz1"
target_find_cases ZIEL-0009
rc=$?
check "dann wird die Partition gar nicht eingehängt" '[[ $rc != 0 && -z $(mounts) ]]'

echo "Die Partition ist schon das Ziel dieser Sitzung (im Hintergrund wird kopiert):"
machine
part sdz1 ext4 20261112-0900_WDC_X
target_mount_part /dev/sdz1
rm -f "$T/events"
UMOUNT_OK=0
target_find_cases ZIEL-0009
rc=$?
check "Rettungsfall gefunden, ohne Schreibschutz und ohne neu einzuhängen" '[[ $rc == 0 && $TARGET_CASE_PART == /dev/sdz1 && -z $(events) && $(state) == "rw,$ALL" ]]'
target_case_writable
rc=$?
check "sie bleibt beschreibbar eingehängt" '[[ $rc == 0 && -z $(events) && $(state) == "rw,$ALL" ]]'
target_find_cases ZIEL-0009
target_search_end
check "auch ein Abbruch der Suche lässt sie, wie sie ist" '[[ -z $(events) && $(state) == "rw,$ALL" ]]'

echo "Ein Schreibschutz aus einer abgebrochenen Suche bleibt nicht hängen:"
machine
part sdz1 ext4 20261112-0900_WDC_X
target_find_cases ZIEL-0009
# Der Assistent wird hier beendet: Der Zustand in den Variablen ist weg, die Partition hängt noch.
TARGET_CASE_PART="" TARGET_CASE_ACTIVE=0
target_mount_part /dev/sdz1
rc=$?
check "als Ziel gewählt, hängt sie danach beschreibbar" '[[ $rc == 0 && $(state) == "rw,$ALL" && -z $(protected) ]]'

echo "Ein Ziel, das nur lesend einhängt:"
machine
part sdz1 ext4
: >"$T/ro/sdz1"
target_mount_part /dev/sdz1
rc=$?
check "wird abgelehnt und wieder ausgehängt" '[[ $rc != 0 && ! -L $T/mnt && $(cat "$T/log") == *"nur lesend"* ]]'
check "der fremde Schreibschutz bleibt" '[[ $(protected) == "sdz1 " ]]'

# ---------------------------------------------------------------------------
# Der ganze Weg durch "Unterbrochene Rettung fortsetzen", mit den echten Funktionen für Suche
# und Einhängen. Dialoge sind Attrappen.
tmux() { return 1; }
disk_pick() { echo ZIEL-0009; }
ui_msg() { printf '%s|%s\n' "$1" "$2" >>"$T/msg"; }
die() {
	printf 'Abbruch|%s\n' "$*" >>"$T/msg"
	return 1
}
safety_check_target() {
	echo "pruefung $(state)" >>"$T/events"
	return "$CHECK_RC"
}
recover_after() { echo "after $1 $(state)" >>"$T/events"; }
ui_menu() {
	echo "menue $(state)" >>"$T/events"
	((MENU_RC)) && return 1
	echo "$4"
}
CHECK_RC=0 MENU_RC=0

echo "Fortsetzen, der Techniker wählt einen Rettungsfall:"
machine
part sdz1 ext4
part sdz2 ext4 20261112-0900_WDC_X
rm -f "$T/msg"
recover_resume
check "die Auswahl der Fälle läuft auf der nur lesend eingehängten Disk" 'events | grep -q "^menue ro,$ALL$"'
check "vor dem beschreibbaren Einhängen wird geprüft, ob die Disk ein Ziel sein darf" '[[ $(events | grep -n "^pruefung ro," | cut -d: -f1) -lt $(events | grep -n "ergebnis=rw" | cut -d: -f1) ]]'
check "mit dem Image wird auf der beschreibbar eingehängten Partition weitergearbeitet" 'events | grep -q "^after $T/mnt/FRS/20261112-0900_WDC_X rw,$ALL$"'

echo "Fortsetzen, der Techniker bricht in der Auswahl ab:"
machine
part sdz1 ext4 20261112-0900_WDC_X
MENU_RC=1
recover_resume
check "nichts war je beschreibbar eingehängt" '! mounts | grep -q "ergebnis=rw"'
check "danach ist nichts eingehängt und nichts geschützt" '[[ ! -L $T/mnt && -z $(protected) ]]'
MENU_RC=0

echo "Fortsetzen, die Disk ist in dieser Sitzung als Quelle geschützt:"
machine
part sdz1 ext4 20261112-0900_WDC_X
: >"$T/ro/sdz"
: >"$T/ro/sdz1"
CHECK_RC=1
recover_resume
check "kein beschreibbares Einhängen, der Schreibschutz bleibt" '! mounts | grep -q "ergebnis=rw" && ! events | grep -q setrw && [[ $(protected) == "sdz sdz1 " ]]'
check "danach ist nichts eingehängt" '[[ ! -L $T/mnt ]]'
CHECK_RC=0

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
