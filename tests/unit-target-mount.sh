#!/usr/bin/env bash
# Unit-Test: Ein Ziel-Dateisystem wird nur mit Schutzoptionen eingehängt (nodev, nosuid,
# noexec, nosymfollow), und der Assistent prüft danach am Einhängepunkt, ob sie gelten.
#
# Was auf einer Ziel-Disk liegt, hat jemand anderes dorthin gelegt: Gerätedateien, Programme
# mit Setuid, Verknüpfungen an Stelle von FRS, Fallordner oder image.img. Ohne die Optionen
# führt eine Verknüpfung image.img -> /dev/sda dazu, dass der Assistent die interne Disk für das
# Image hält.
#
# Hier wird nichts eingehängt. sudo, mount und findmnt sind Attrappen: Ein gedachter Kernel
# merkt sich, welche Optionen am Einhängepunkt gelten. Ob der echte Kernel die Optionen
# durchsetzt, prüft der Selbsttest im gebooteten System (frs --selftest).
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/target.sh
FRS_TARGET_MNT=/mnt/frs-target

log() { printf '%s\n' "$*" >>"$T/log"; }
run() { "$@"; }
id() { echo 1000; }
lsblk() { echo "$FS"; }
# $T/mounted: Optionen, die am Einhängepunkt gelten. Leer oder fehlend: nichts eingehängt.
# $T/source: das Gerät, das dort eingehängt ist.
mountpoint() { [[ -s $T/mounted ]]; }
findmnt() {
	[[ -s $T/mounted ]] || return 1
	if [[ " $* " == *" SOURCE "* ]]; then cat "$T/source"; else cat "$T/mounted"; fi
}
sudo() {
	printf '%s\n' "$*" >>"$T/sudo"
	case $1 in
	mount | ntfs-3g) kernel_mount "$@" ;;
	umount)
		((UMOUNT_OK)) || return 32
		: >"$T/mounted"
		;;
	esac
}
# Der gedachte Kernel. Er übernimmt von den verlangten Schutzoptionen alle außer $IGNORED.
kernel_mount() {
	local tool=$1 type="" opts="" have="rw,relatime" o dev=""
	shift
	while (($#)); do
		case $1 in
		-t) type=$2; shift ;;
		-o) opts=$2; shift ;;
		/dev/*) dev=$1 ;;
		esac
		shift
	done
	[[ $type == ntfs3 ]] && ((!NTFS3_OK)) && return 32
	if [[ ",$opts," == *,remount,* ]]; then
		((REMOUNT_OK)) || return 32
	elif [[ $tool == ntfs-3g && ",$opts," == *,nosymfollow,* ]]; then
		return 1 # ntfs-3g kennt die Option nicht
	fi
	for o in nodev nosuid noexec nosymfollow; do
		[[ ",$opts," == *",$o,"* && " $IGNORED " != *" $o "* ]] && have+=",$o"
	done
	echo "$have" >"$T/mounted"
	[[ -z $dev ]] || echo "$dev" >"$T/source"
}

# mount_part DATEISYSTEM   Ruft target_mount_part auf. Ergebnis: RC, CALLS (Aufrufe hinter
# sudo), OPTS (was am Einhängepunkt gilt), LOG.
mount_part() {
	FS=$1
	rm -f "$T/sudo" "$T/log"
	target_mount_part /dev/sdz1
	RC=$?
	CALLS=$(cat "$T/sudo" 2>/dev/null)
	OPTS=$(cat "$T/mounted" 2>/dev/null)
	LOG=$(cat "$T/log" 2>/dev/null)
}
# Nach jedem Fall: alles zurück auf den Normalzustand, nichts eingehängt.
reset() {
	NTFS3_OK=1 REMOUNT_OK=1 UMOUNT_OK=1 IGNORED=""
	: >"$T/mounted"
	rm -f "$T/source"
}
safe() { [[ ",$OPTS," == *,nodev,* && ",$OPTS," == *,nosuid,* && ",$OPTS," == *,noexec,* && ",$OPTS," == *,nosymfollow,* ]]; }
ALL="nodev,nosuid,noexec,nosymfollow"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

for fs in ext4 xfs btrfs ""; do
	echo "Dateisystem '${fs:-unbekannt}':"
	reset
	mount_part "$fs"
	check "eingehängt, am Einhängepunkt gelten alle Schutzoptionen" '[[ $RC == 0 ]] && safe'
	check "Aufruf verlangt die Optionen" '[[ $CALLS == *"mount -o $ALL /dev/sdz1 /mnt/frs-target"* ]]'
	check "kein Nachsetzen nötig" '[[ $CALLS != *remount* ]]'
done

echo "exFAT:"
reset
mount_part exfat
check "eingehängt mit Schutzoptionen und Besitzer" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -o $ALL,uid=1000,gid=1000 /dev/sdz1 /mnt/frs-target"* ]]'

echo "NTFS über den Kerneltreiber:"
reset
mount_part ntfs
check "eingehängt mit Schutzoptionen und Besitzer" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -t ntfs3 -o $ALL,uid=1000,gid=1000 /dev/sdz1 /mnt/frs-target"* ]]'
check "ntfs-3g wird nicht gebraucht" '[[ $CALLS != *ntfs-3g* ]]'

echo "NTFS über ntfs-3g (Kerneltreiber lehnt ab):"
reset
NTFS3_OK=0
mount_part ntfs
check "ntfs-3g bekommt nodev, nosuid und noexec" '[[ $CALLS == *"ntfs-3g -o nodev,nosuid,noexec,uid=1000,gid=1000 /dev/sdz1 /mnt/frs-target"* ]]'
check "nosymfollow wird am Einhängepunkt nachgesetzt" '[[ $CALLS == *"mount -i -o remount,bind,$ALL /mnt/frs-target"* ]]'
check "danach gelten alle Schutzoptionen" '[[ $RC == 0 ]] && safe'
reset
NTFS3_OK=0 REMOUNT_OK=0
mount_part ntfs
check "Nachsetzen scheitert: Ziel abgelehnt und wieder ausgehängt" '[[ $RC != 0 && -z $OPTS && $CALLS == *"umount /mnt/frs-target"* ]]'
check "Grund steht im Protokoll" '[[ $LOG == *"Einhängen abgelehnt"*"nosymfollow"* ]]'

echo "Der Kernel übernimmt eine Option nicht:"
for o in nodev nosuid noexec nosymfollow; do
	reset
	IGNORED=$o REMOUNT_OK=0
	mount_part ext4
	check "$o fehlt und lässt sich nicht nachsetzen: Ziel abgelehnt, ausgehängt" '[[ $RC != 0 && -z $OPTS ]]'
done
reset
IGNORED="nodev nosuid noexec nosymfollow" REMOUNT_OK=0
mount_part exfat
check "gar keine Option gilt: Ziel abgelehnt, ausgehängt" '[[ $RC != 0 && -z $OPTS ]]'

echo "Am Einhängepunkt hängt noch etwas:"
reset
echo "rw,relatime" >"$T/mounted"
mount_part ext4
check "das Alte wird ausgehängt, das Neue gilt mit Schutzoptionen" '[[ $RC == 0 ]] && safe && [[ $(head -n2 "$T/sudo" | tail -n1) == "umount /mnt/frs-target" ]]'
reset
echo "rw,relatime" >"$T/mounted"
UMOUNT_OK=0
mount_part ext4
check "Aushängen scheitert: Abbruch, nichts wird darüber eingehängt" '[[ $RC != 0 && $CALLS != *"mount -"* && $LOG == *"noch in Benutzung"* ]]'

echo "Dieselbe Partition hängt schon dort:"
reset
mount_part ext4
UMOUNT_OK=0
mount_part ext4
check "geschützt eingehängt und in Benutzung: bleibt, kein Aushängen, kein Einhängen" '[[ $RC == 0 ]] && safe && [[ $CALLS != *mount* ]]'
reset
echo "rw,relatime" >"$T/mounted"
echo /dev/sdz1 >"$T/source"
mount_part ext4
check "ohne Schutzoptionen eingehängt: wird nicht übernommen, sondern neu eingehängt" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"umount /mnt/frs-target"*"mount -o $ALL /dev/sdz1"* ]]'
reset
echo "rw,relatime,$ALL" >"$T/mounted"
echo /dev/sdy1 >"$T/source"
mount_part ext4
check "eine andere Partition hängt dort: wird ausgehängt, die gewählte eingehängt" '[[ $RC == 0 && $(cat "$T/source") == /dev/sdz1 && $CALLS == *"umount /mnt/frs-target"*"mount -o $ALL /dev/sdz1"* ]]'
reset
echo "rw,relatime,$ALL" >"$T/mounted"
echo /dev/sdy1 >"$T/source"
UMOUNT_OK=0
mount_part ext4
check "eine andere Partition hängt dort und ist in Benutzung: Abbruch" '[[ $RC != 0 && $CALLS != *"mount -"* ]]'

echo "Über alle Fälle:"
reset
rm -f "$T/alle"
for fs in ext4 ext3 xfs btrfs exfat ntfs ""; do
	for NTFS3_OK in 1 0; do
		: >"$T/mounted"
		mount_part "$fs"
		echo "$CALLS" >>"$T/alle"
	done
done
check "kein Einhängen ohne nodev, nosuid und noexec" '! grep -E "^(mount|ntfs-3g) " "$T/alle" | grep -v -q "nodev,nosuid,noexec"'
check "es gab Einhänge-Aufrufe" '[[ $(grep -c -E "^(mount|ntfs-3g) " "$T/alle") -ge 14 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
