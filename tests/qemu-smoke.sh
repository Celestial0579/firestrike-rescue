#!/usr/bin/env bash
# Bootet die ISO in QEMU und prüft die serielle Ausgabe.
#
#   tests/qemu-smoke.sh ISO uefi       ISO als CD per UEFI (OVMF) booten, auf "lf ready" warten
#   tests/qemu-smoke.sh ISO uefi-usb   ISO als USB-Stick per UEFI booten, neben einer fremden Disk
#   tests/qemu-smoke.sh ISO bios       ISO als CD per BIOS booten, auf "lf ready" warten
#   tests/qemu-smoke.sh ISO selftest   Kernel direkt mit lf.selftest starten, Selbsttest auswerten
#
# In uefi-usb und selftest hängt zusätzlich eine fremde Disk am Rechner, die sich als der Stick
# ausgibt: gleiche UUID und gleiches Label wie die ISO, /.disk/info, eine eigene grub.cfg und ein
# anderes squashfs. Weder ihre grub.cfg noch ihr squashfs dürfen zum Zug kommen.
set -Eeuo pipefail

ISO=${1:?ISO fehlt}
MODE=${2:-uefi}
TIMEOUT=${TIMEOUT:-900}
LOG="smoke-$MODE.log"
: >"$LOG"
work=$(mktemp -d)

ACCEL=(-accel tcg)
[[ -w /dev/kvm ]] && ACCEL=(-accel kvm -cpu host)
QEMU=(qemu-system-x86_64 "${ACCEL[@]}" -m 4096 -smp 2 -nographic -no-reboot
	-serial "file:$LOG" -monitor none -display none)
CD=(-drive "file=$ISO,media=cdrom,readonly=on,if=none,id=cd" -device "ide-cd,drive=cd")

ovmf() {
	local f
	OVMF=""
	for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f $f ]] && { OVMF=$f; break; }; done
	[[ -n $OVMF ]] || { echo "OVMF nicht gefunden" >&2; exit 2; }
	# Beschreibbare Kopie der UEFI-Variablen, passend zur Code-Datei
	cp "${OVMF/CODE/VARS}" "$work/vars.fd"
	QEMU+=(-machine q35 -drive "if=pflash,format=raw,readonly=on,file=$OVMF"
		-drive "if=pflash,format=raw,file=$work/vars.fd")
}

# Die fremde Disk. Die UUID der ISO leitet xorriso aus ihrem Änderungsdatum ab, die fremde Disk
# bekommt dasselbe Datum.
foreign() {
	local d=$work/fremd uuid
	uuid=$(blkid -o value -s UUID "$ISO")
	[[ $uuid =~ ^[0-9]{4}(-[0-9]{2}){6}$ ]] || { echo "UUID der ISO nicht lesbar: '$uuid'" >&2; exit 2; }
	mkdir -p "$d/.disk" "$d/boot/grub" "$d/casper"
	echo "Leuchtfeuer - fremde Disk" >"$d/.disk/info"
	cat >"$d/boot/grub/grub.cfg" <<-'EOF'
		serial --unit=0 --speed=115200
		terminal_output serial console
		echo "LF-GEKAPERT: grub.cfg von der fremden Disk"
		sleep 5
		halt
	EOF
	head -c $((1024 * 1024)) /dev/urandom >"$d/casper/filesystem.squashfs"
	xorriso -as mkisofs -r -V LEUCHTFEUER --modification-date="${uuid//-/}" -o "$work/fremd.iso" "$d" >/dev/null 2>&1
	[[ $(blkid -o value -s UUID "$work/fremd.iso") == "$uuid" ]] || { echo "Die fremde Disk hat nicht die UUID der ISO" >&2; exit 2; }
	# ide-hd nimmt kein schreibgeschütztes Laufwerk an. snapshot=on: Schreibzugriffe landen in
	# einer temporären Ebene, das Abbild bleibt unverändert. Auf q35 hat jeder IDE-Bus (AHCI-Port)
	# nur ein Gerät: Die fremde Disk bekommt einen eigenen, die CD bleibt auf ide.0 (sr0).
	FOREIGN=(-drive "file=$work/fremd.iso,format=raw,if=none,id=fremd,snapshot=on" -device "ide-hd,drive=fremd,bus=ide.2")
}

AFTER=()
case $MODE in
uefi)
	ovmf
	QEMU+=("${CD[@]}")
	EXPECT="lf ready"
	;;
uefi-usb)
	ovmf
	foreign
	QEMU+=("${FOREIGN[@]}" -device qemu-xhci
		-drive "file=$ISO,format=raw,if=none,id=stick,snapshot=on" -device "usb-storage,drive=stick,bootindex=1")
	EXPECT="lf ready"
	# Der Start-Stub auf der EFI-Partition hat das Medium auf dem Stick gewählt.
	AFTER=("Leuchtfeuer: Startmedium (")
	;;
bios)
	QEMU+=(-machine pc "${CD[@]}")
	EXPECT="lf ready"
	;;
selftest)
	foreign
	xorriso -osirrox on -indev "$ISO" -extract /casper/vmlinuz "$work/vmlinuz" -extract /casper/initrd "$work/initrd" >/dev/null 2>&1
	# Der Selbsttest schreibt auf die serielle Konsole. Der Login-Prompt dort (serial-getty,
	# Type=idle mit TTYVHangup) startet spätestens 5 Sekunden nach dem Selbsttest und hängt die
	# Leitung dabei auf: Was der Selbsttest danach ausgibt, ginge verloren, auch sein Ergebnis.
	# Deshalb gibt es in diesem Lauf keinen Login-Prompt auf der seriellen Konsole.
	QEMU+=(-machine q35 "${FOREIGN[@]}" "${CD[@]}" -kernel "$work/vmlinuz" -initrd "$work/initrd"
		-append "boot=casper live-media=/run/lf-medium noswap systemd.swap=0 fsck.mode=skip noprompt console=ttyS0,115200 lf.selftest systemd.mask=serial-getty@ttyS0.service systemd.getty_auto=0")
	EXPECT="LF-SELFTEST: PASS"
	# Gewählt ist die CD, die fremde Disk mit gleicher UUID wurde gesehen und abgelehnt.
	AFTER=("LF-SELFTEST: Boot: Live-Medium geprüft (/dev/sr0), Disks mit der UUID der ISO: 2")
	;;
*) echo "Unbekannter Modus: $MODE" >&2; exit 2 ;;
esac

echo "Starte QEMU ($MODE), warte bis zu ${TIMEOUT}s auf '$EXPECT' …"
"${QEMU[@]}" &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

for ((t = 0; t < TIMEOUT; t += 5)); do
	if grep -aq "LF-GEKAPERT" "$LOG"; then
		echo "FEHLER: Die grub.cfg der fremden Disk wurde geladen."
		tail -n 40 "$LOG"
		exit 1
	fi
	if grep -aq "$EXPECT" "$LOG"; then
		echo "OK: '$EXPECT' nach ${t}s gefunden."
		grep -a 'LF-SELFTEST\|lf ready\|Leuchtfeuer:' "$LOG" || true
		for a in "${AFTER[@]}"; do
			grep -aqF "$a" "$LOG" || { echo "FEHLER: '$a' fehlt in der seriellen Ausgabe."; exit 1; }
		done
		exit 0
	fi
	if grep -aq "LF-SELFTEST: FAIL" "$LOG"; then
		echo "Selbsttest fehlgeschlagen:"
		grep -a 'LF-SELFTEST' "$LOG"
		exit 1
	fi
	kill -0 $pid 2>/dev/null || break
	sleep 5
done
echo "FEHLER: '$EXPECT' nicht gefunden. Letzte Zeilen der seriellen Ausgabe:"
tail -n 80 "$LOG"
exit 1
