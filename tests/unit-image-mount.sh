#!/usr/bin/env bash
# Unit-Test: Eine Partition aus einem Image wird nur mit Schutzoptionen eingehängt (ro, nodev,
# nosuid, noexec, nosymfollow), und der Assistent prüft danach am Einhängepunkt, ob sie gelten.
#
# Ein Image ist der Inhalt einer fremden Disk. Bisher wurde es nur mit "ro" eingehängt:
# Gerätedateien, Programme mit Setuid und Verknüpfungen aus dem Image wirkten wie eigene. Eine
# Verknüpfung nach /etc oder in den persistenten Speicher zeigte auf Dateien des Rettungssystems,
# die beim Durchsehen oder Kopieren wie Dateien des Kunden aussehen.
#
# Hier wird nichts eingehängt. sudo, mount und findmnt sind Attrappen: Ein gedachter Kernel merkt
# sich, was am Einhängepunkt gilt. Ob der echte Kernel die Optionen durchsetzt, prüft der
# Selbsttest im gebooteten System (frs --selftest).
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh
FRS_RUN="$T/run"
MP=/mnt/frs-image/loop0p2

log() { printf '%s\n' "$*" >>"$T/log"; }
run() { "$@"; }
die() {
	printf '%s\n' "$*" >>"$T/log"
	return 1
}
ui_input() {
	echo x >>"$T/input"
	echo "111111-222222-333333-444444-555555-666666-777777-888888"
}
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
	blkid) echo "$FS" ;;
	mount | ntfs-3g) kernel_mount "$@" ;;
	umount)
		((UMOUNT_OK)) || return 32
		: >"$T/mounted"
		;;
	esac
}
# Der gedachte Kernel. Er übernimmt von den verlangten Schutzoptionen alle außer $IGNORED und
# lehnt Aufrufe ab, deren Text zu $REFUSE passt.
kernel_mount() {
	local tool=$1 opts="" have="relatime" o dev="" all="$*"
	shift
	while (($#)); do
		case $1 in
		-o) opts=$2; shift ;;
		/dev/* | */dislocker-file) dev=$1 ;;
		esac
		shift
	done
	[[ -n $REFUSE && $all == *$REFUSE* ]] && return 32
	if [[ ",$opts," == *,remount,* ]]; then
		((REMOUNT_OK)) || return 32
	elif [[ $tool == ntfs-3g && ",$opts," == *,nosymfollow,* ]]; then
		return 1 # ntfs-3g kennt die Option nicht
	fi
	for o in ro nodev nosuid noexec nosymfollow; do
		[[ ",$opts," == *",$o,"* && " $IGNORED " != *" $o "* ]] && have+=",$o"
	done
	echo "$have" >"$T/mounted"
	[[ -z $dev ]] || echo "$dev" >"$T/source"
}

# mount_ro DATEISYSTEM   Ruft part_mount_ro auf. Ergebnis: RC, CALLS (Aufrufe hinter sudo),
# OPTS (was am Einhängepunkt gilt), LOG.
mount_ro() {
	FS=$1
	rm -f "$T/sudo" "$T/log" "$T/input"
	part_mount_ro /dev/loop0p2 "$MP"
	RC=$?
	CALLS=$(cat "$T/sudo" 2>/dev/null)
	OPTS=$(cat "$T/mounted" 2>/dev/null)
	LOG=$(cat "$T/log" 2>/dev/null)
}
reset() {
	REMOUNT_OK=1 UMOUNT_OK=1 IGNORED="" REFUSE=""
	: >"$T/mounted"
	rm -f "$T/source"
}
safe() { [[ ",$OPTS," == *,ro,* && ",$OPTS," == *,nodev,* && ",$OPTS," == *,nosuid,* && ",$OPTS," == *,noexec,* && ",$OPTS," == *,nosymfollow,* ]]; }
ALL="ro,nodev,nosuid,noexec,nosymfollow"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "ext4 (auch ext2, ext3):"
for fs in ext4 ext3 ext2; do
	reset
	mount_ro "$fs"
	check "$fs: eingehängt, alle Schutzoptionen gelten, Journal wird nicht nachgespielt" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -o $ALL,noload /dev/loop0p2 $MP"* ]]'
done

echo "XFS und Btrfs:"
reset
mount_ro xfs
check "xfs: Schutzoptionen und norecovery" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -o $ALL,norecovery /dev/loop0p2 $MP"* ]]'
reset
mount_ro btrfs
check "btrfs: Schutzoptionen und rescue=usebackuproot" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -o $ALL,rescue=usebackuproot /dev/loop0p2 $MP"* ]]'
reset
REFUSE="usebackuproot"
mount_ro btrfs
check "btrfs, zweiter Versuch: auch er mit allen Schutzoptionen" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -o $ALL,rescue=all /dev/loop0p2 $MP"* ]]'

echo "NTFS:"
reset
mount_ro ntfs
check "über den Kerneltreiber, mit allen Schutzoptionen" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -t ntfs3 -o $ALL /dev/loop0p2 $MP"* && $CALLS != *ntfs-3g* ]]'
reset
REFUSE="-t ntfs3"
mount_ro ntfs
check "über ntfs-3g: ro, nodev, nosuid, noexec im Aufruf" '[[ $CALLS == *"ntfs-3g -o ro,nodev,nosuid,noexec,recover /dev/loop0p2 $MP"* ]]'
check "über ntfs-3g: nosymfollow wird nachgesetzt, danach gilt alles" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -i -o remount,bind,$ALL $MP"* ]]'

echo "Anderes Dateisystem und keines:"
reset
mount_ro vfat
check "vfat: eingehängt mit allen Schutzoptionen" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"mount -o $ALL /dev/loop0p2 $MP"* ]]'
reset
mount_ro ""
check "kein Dateisystem erkannt: nichts eingehängt" '[[ $RC != 0 && -z $OPTS && $CALLS != *"mount "* ]]'

echo "BitLocker:"
reset
mount_ro BitLocker
check "Schlüssel erfragt, entschlüsselt, mit allen Schutzoptionen eingehängt" '[[ $RC == 0 && -s $T/input ]] && safe && [[ $CALLS == *"dislocker -r -V /dev/loop0p2"* && $CALLS == *"mount -o $ALL,loop $FRS_RUN/dislocker-loop0p2/dislocker-file $MP"* ]]'
reset
REFUSE=",loop"
mount_ro BitLocker
check "Ersatzweg ntfs-3g: Schutzoptionen im Aufruf, nosymfollow nachgesetzt" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"ntfs-3g -o ro,nodev,nosuid,noexec $FRS_RUN/dislocker-loop0p2/dislocker-file $MP"* ]]'

echo "Der Kernel übernimmt eine Option nicht:"
for o in ro nodev nosuid noexec nosymfollow; do
	reset
	IGNORED=$o REMOUNT_OK=0
	mount_ro ext4
	check "$o fehlt und lässt sich nicht nachsetzen: abgelehnt, wieder ausgehängt" '[[ $RC != 0 && -z $OPTS && $LOG == *"Einhängen abgelehnt"* ]]'
done

echo "Am Einhängepunkt hängt schon etwas:"
reset
mount_ro ext4
UMOUNT_OK=0
mount_ro ext4
check "dieselbe Partition, geschützt: bleibt, nichts wird aus- oder eingehängt" '[[ $RC == 0 ]] && safe && [[ $CALLS != *mount* ]]'
reset
echo "relatime,ro" >"$T/mounted"
echo /dev/loop0p2 >"$T/source"
mount_ro ext4
check "dieselbe Partition, nur mit ro: wird neu und geschützt eingehängt" '[[ $RC == 0 ]] && safe && [[ $CALLS == *"umount $MP"*"mount -o $ALL,noload"* ]]'
reset
echo "relatime,$ALL" >"$T/mounted"
echo /dev/loop1p1 >"$T/source"
UMOUNT_OK=0
mount_ro ext4
check "eine andere Partition, in Benutzung: Abbruch, nichts wird darüber eingehängt" '[[ $RC != 0 && $CALLS != *"mount -"* && $LOG == *"noch in Benutzung"* ]]'

echo "Über alle Fälle:"
rm -f "$T/alle"
for fs in ext4 xfs btrfs ntfs exfat vfat hfsplus BitLocker; do
	for REFUSE in "" "-t ntfs3" "usebackuproot" ",loop"; do
		REMOUNT_OK=1 UMOUNT_OK=1 IGNORED=""
		: >"$T/mounted"
		rm -f "$T/source"
		mount_ro "$fs"
		echo "$CALLS" >>"$T/alle"
	done
done
check "kein Einhängen ohne ro, nodev, nosuid und noexec" '! grep -E "^(mount|ntfs-3g) " "$T/alle" | grep -v -q "ro,nodev,nosuid,noexec"'
check "es gab Einhänge-Aufrufe" '[[ $(grep -c -E "^(mount|ntfs-3g) " "$T/alle") -ge 30 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
