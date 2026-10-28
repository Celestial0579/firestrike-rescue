#!/usr/bin/env bash
# Bootet die ISO in QEMU und prüft die serielle Ausgabe.
#
#   tests/qemu-smoke.sh ISO uefi       ISO per UEFI (OVMF) booten, auf "frs ready" warten
#   tests/qemu-smoke.sh ISO bios       ISO per BIOS booten, auf "frs ready" warten
#   tests/qemu-smoke.sh ISO selftest   Kernel direkt mit frs.selftest starten, Selbsttest auswerten
set -Eeuo pipefail

ISO=${1:?ISO fehlt}
MODE=${2:-uefi}
TIMEOUT=${TIMEOUT:-900}
LOG="smoke-$MODE.log"
: >"$LOG"

ACCEL=(-accel tcg)
[[ -w /dev/kvm ]] && ACCEL=(-accel kvm -cpu host)
QEMU=(qemu-system-x86_64 "${ACCEL[@]}" -m 4096 -smp 2 -nographic -no-reboot
	-serial "file:$LOG" -monitor none -display none
	-drive "file=$ISO,media=cdrom,readonly=on,if=none,id=cd" -device "ide-cd,drive=cd")

case $MODE in
uefi)
	OVMF=""
	for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f $f ]] && { OVMF=$f; break; }; done
	[[ -n $OVMF ]] || { echo "OVMF nicht gefunden" >&2; exit 2; }
	# Beschreibbare Kopie der UEFI-Variablen, passend zur Code-Datei
	vars=$(mktemp)
	cp "${OVMF/CODE/VARS}" "$vars"
	QEMU+=(-machine q35 -drive "if=pflash,format=raw,readonly=on,file=$OVMF"
		-drive "if=pflash,format=raw,file=$vars")
	EXPECT="frs ready"
	;;
bios)
	QEMU+=(-machine pc)
	EXPECT="frs ready"
	;;
selftest)
	work=$(mktemp -d)
	xorriso -osirrox on -indev "$ISO" -extract /casper/vmlinuz "$work/vmlinuz" -extract /casper/initrd "$work/initrd" >/dev/null 2>&1
	QEMU+=(-machine q35 -kernel "$work/vmlinuz" -initrd "$work/initrd"
		-append "boot=casper live-media=/dev/disk/by-label/FRS_RESCUE noswap systemd.swap=0 fsck.mode=skip noprompt console=ttyS0,115200 frs.selftest")
	EXPECT="FRS-SELFTEST: PASS"
	;;
*) echo "Unbekannter Modus: $MODE" >&2; exit 2 ;;
esac

echo "Starte QEMU ($MODE), warte bis zu ${TIMEOUT}s auf '$EXPECT' …"
"${QEMU[@]}" &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

for ((t = 0; t < TIMEOUT; t += 5)); do
	if grep -q "$EXPECT" "$LOG"; then
		echo "OK: '$EXPECT' nach ${t}s gefunden."
		grep -a 'FRS-SELFTEST\|frs ready' "$LOG" || true
		exit 0
	fi
	if grep -q "FRS-SELFTEST: FAIL" "$LOG"; then
		echo "Selbsttest fehlgeschlagen:"
		grep -a 'FRS-SELFTEST' "$LOG"
		exit 1
	fi
	kill -0 $pid 2>/dev/null || break
	sleep 5
done
echo "FEHLER: '$EXPECT' nicht gefunden. Letzte Zeilen der seriellen Ausgabe:"
tail -n 80 "$LOG"
exit 1
