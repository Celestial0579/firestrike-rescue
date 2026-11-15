#!/usr/bin/env bash
# Unit-Test: Die initrd nimmt nur das geprüfte Live-Medium (casper-premount/lf_medium).
#
# Das Skript läuft in der initrd, bevor casper ein Medium sucht. Kandidaten sind die Geräte mit
# der UUID der ISO. Eines gilt nur, wenn casper/ genau filesystem.squashfs enthält und dessen
# SHA-256-Summe die beim Build berechnete ist. Der Test spielt Rechner mit fremden Disks durch,
# die sich als der Stick ausgeben. Ohne root und ohne Disks: blkid, mount und umount sind
# Attrappen, "Geräte" sind Ordner. Das Skript läuft mit sh, wie in der initrd.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

SCRIPT=$PWD/build/overlay/etc/initramfs-tools/scripts/casper-premount/lf_medium
T=$(mktemp -d)
UUID=2026-11-15-10-02-44-00

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# Attrappen. Ein "Gerät" ist der Ordner $T/dev/NAME. blkid meldet die Geräte aus $T/uuid-geraete.
mkdir -p "$T/bin"
cat >"$T/bin/blkid" <<'EOF'
#!/bin/sh
# blkid -c /dev/null -t UUID=… -o device
echo "blkid $*" >>"$FAKE/aufrufe"
case "$*" in *"-t UUID=$FAKE_UUID -o device"*) cat "$FAKE/uuid-geraete" ;; esac
EOF
cat >"$T/bin/mount" <<'EOF'
#!/bin/sh
# mount -t iso9660 -o ro GERÄT ZIEL: das Gerät als Verknüpfung an Stelle des Ziels
echo "mount $*" >>"$FAKE/aufrufe"
[ "$1 $2 $3 $4" = "-t iso9660 -o ro" ] || exit 1
d=$FAKE/dev/${5##*/}
[ -d "$d" ] || exit 1
rmdir "$6" && ln -s "$d" "$6"
EOF
cat >"$T/bin/umount" <<'EOF'
#!/bin/sh
echo "umount $*" >>"$FAKE/aufrufe"
rm "$1" && mkdir "$1"
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/bin/sleep"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/modprobe"
chmod +x "$T/bin"/*

GOOD=$T/squashfs-echt
head -c 300000 /dev/urandom >"$GOOD"
SUM=$(sha256sum "$GOOD" | cut -d' ' -f1)

# scene   Neuer Rechner ohne Geräte, mit gültiger lf-medium.conf.
scene() {
	R=$T/root
	rm -rf "$R"
	mkdir -p "$R/conf" "$R/run" "$R/sys/class/block" "$R/sys/devices" "$R/dev"
	printf 'LF_ISO_UUID=%s\nLF_SQUASHFS_SHA256=%s\n' "$UUID" "$SUM" >"$R/conf/lf-medium.conf"
	: >"$R/uuid-geraete"
	: >"$R/aufrufe"
}
# device NAME [DISK] SQUASHFS [WEITERE-DATEI]   Ein Gerät mit der UUID der ISO. DISK: Es ist eine
# Partition dieser Disk. SQUASHFS: Datei, die als casper/filesystem.squashfs dort liegt.
device() {
	local name=$1 disk=$2 sq=$3 extra=${4:-}
	mkdir -p "$R/dev/$name/casper"
	cp "$sq" "$R/dev/$name/casper/filesystem.squashfs"
	[[ -n $extra ]] && cp "$sq" "$R/dev/$name/casper/$extra"
	echo "/dev/$name" >>"$R/uuid-geraete"
	if [[ -n $disk ]]; then
		mkdir -p "$R/sys/devices/pci/$disk/$name"
		: >"$R/sys/devices/pci/$disk/$name/partition"
		ln -s "$R/sys/devices/pci/$disk/$name" "$R/sys/class/block/$name"
	else
		mkdir -p "$R/sys/devices/pci/$name"
		ln -s "$R/sys/devices/pci/$name" "$R/sys/class/block/$name"
	fi
}
# boot   Startet das Skript. Ergebnis: RC, OUT, ENV (Inhalt von /run/lf-boot.env), MNT (was unter
# /run/lf-medium hängt: Name des Geräts oder leer).
boot() {
	OUT=$(LF_TEST_ROOT=$R FAKE=$R FAKE_UUID=$UUID PATH="$T/bin:$PATH" sh "$SCRIPT" 2>&1)
	RC=$?
	ENV=$(cat "$R/run/lf-boot.env" 2>/dev/null)
	MNT=""
	[[ -L $R/run/lf-medium ]] && MNT=$(basename "$(readlink "$R/run/lf-medium")")
}
env_has() { grep -qx "$1" <<<"$ENV"; }

BAD=$T/squashfs-fremd
head -c 300000 /dev/urandom >"$BAD"

echo "Der Stick allein:"
scene
device sdb "" "$GOOD"
device sdb1 sdb "$GOOD"
boot
check "das Medium ist gewählt und bleibt eingehängt" '[[ $RC == 0 && $MNT == sdb ]] && env_has LF_BOOT_DEV=/dev/sdb && env_has LF_BOOT_DISK=sdb'
check "ganze Disk und erste Partition zählen als eine Disk" 'env_has LF_BOOT_DISKS=1'
check "die Prüfsumme steht im Ergebnis" 'env_has "LF_SQUASHFS_SHA256=$SUM" && env_has "LF_ISO_UUID=$UUID"'
check "blkid sucht nur nach der UUID der ISO, ohne Zwischenspeicher" '! grep -v -- "-c /dev/null -t UUID=$UUID -o device" "$R/aufrufe" | grep -q "^blkid"'

echo "Eine fremde Disk gibt sich als Stick aus (gleiche UUID, anderes squashfs), sie wird zuerst gemeldet:"
scene
device sda "" "$BAD"
device sr0 "" "$GOOD"
boot
check "gewählt ist das Medium mit der richtigen Prüfsumme" '[[ $RC == 0 && $MNT == sr0 ]] && env_has LF_BOOT_DEV=/dev/sr0'
check "die fremde Disk wurde eingehängt, geprüft und wieder ausgehängt" 'grep -q "^mount -t iso9660 -o ro /dev/sda " "$R/aufrufe" && grep -q "^umount " "$R/aufrufe"'
check "sie wird gemeldet und gezählt" '[[ $OUT == *"/dev/sda trägt die UUID der ISO, aber ein anderes squashfs"* ]] && env_has LF_BOOT_DISKS=2'
check "der Techniker erfährt, dass kein persistenter Speicher eingebunden wird" '[[ $OUT == *"Persistenter Speicher wird nicht eingebunden"* ]]'

echo "Eine fremde Disk mit dem echten squashfs und einem zweiten Abbild darüber:"
scene
device sda "" "$GOOD" zz-schicht.squashfs
device sr0 "" "$GOOD"
boot
check "sie wird nicht verwendet: casper hinge das zweite Abbild als Schicht darüber" '[[ $RC == 0 && $MNT == sr0 ]] && [[ $OUT == *"weiteres Abbild zz-schicht.squashfs"* ]]'
scene
device sda "" "$GOOD"
mkdir -p "$R/dev/sda/casper/mehr.dir"
device sr0 "" "$GOOD"
boot
check "auch ein Abbild als Ordner (*.dir) zählt" '[[ $RC == 0 && $MNT == sr0 ]]'

echo "Nur fremde Disks:"
scene
device sda "" "$BAD"
device sdc "" "$GOOD" extra.ext2
boot
check "kein Start: Abbruch mit Meldung" '[[ $RC != 0 && $OUT == *"PANIC: Leuchtfeuer: Kein Gerät mit dem geprüften Live-Medium"* ]]'
check "nichts bleibt eingehängt, kein Ergebnis" '[[ -z $MNT && -z $ENV ]]'
check "jede Disk wurde nur einmal geprüft, obwohl das Skript wartet" '[[ $(grep -c "^mount .* /dev/sda " "$R/aufrufe") == 1 && $(grep -c "^mount .* /dev/sdc " "$R/aufrufe") == 1 ]]'
scene
boot
check "gar kein Gerät mit der UUID: kein Start" '[[ $RC != 0 && -z $MNT ]]'

echo "Ein Gerät, das sich nicht einhängen lässt, wird übergangen:"
scene
echo /dev/sdx >>"$R/uuid-geraete"
device sdb "" "$GOOD"
boot
check "der Stick dahinter wird gewählt" '[[ $RC == 0 && $MNT == sdb ]]'

echo "Ohne gültige lf-medium.conf startet nichts:"
for c in "" "LF_ISO_UUID=$UUID" "LF_SQUASHFS_SHA256=$SUM" "LF_ISO_UUID=$UUID
LF_SQUASHFS_SHA256=${SUM:0:63}" "LF_ISO_UUID=x\$(id)
LF_SQUASHFS_SHA256=$SUM"; do
	scene
	device sdb "" "$GOOD"
	printf '%s\n' "$c" >"$R/conf/lf-medium.conf"
	boot
	check "conf: $(tr '\n' ' ' <<<"${c:-leer}" | cut -c1-60)" '[[ $RC != 0 && -z $MNT && $OUT == *"PANIC"* ]] && ! grep -q "^mount" "$R/aufrufe"'
done
scene
device sdb "" "$GOOD"
rm "$R/conf/lf-medium.conf"
boot
check "conf fehlt: kein Start" '[[ $RC != 0 && -z $MNT ]]'

echo "Außerhalb einer initrd und ohne Testwurzel läuft das Skript nicht:"
OUT=$(PATH="$T/bin:$PATH" sh "$SCRIPT" 2>&1)
check "Abbruch" '[[ $? != 0 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
