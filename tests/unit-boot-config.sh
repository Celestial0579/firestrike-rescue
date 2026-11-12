#!/usr/bin/env bash
# Unit-Test: Beim Booten wird kein fremder Datenträger durchsucht oder eingehängt.
#
# Die README sagt: "Fremde Disks werden nie automatisch eingehängt." Im Boot-Skript von Ubuntu
# (casper) gilt das nur mit zwei Einstellungen zusammen:
#   - live-media=… im Bootmenü nennt das Medium, auf dem das Live-System liegt,
#   - LIVEMEDIA_TIMEOUT in /etc/casper.conf verhindert, dass casper alle Blockgeräte durchsucht
#     und ihre Dateisysteme einhängt, sobald dieses Medium beim ersten Versuch noch fehlt.
# Der Test prüft, dass der Build beides setzt. Ob die Einstellung in der initrd steht, mit der
# das System wirklich startet, prüft der Selbsttest der ISO (selftest_boot).
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

SETUP=build/chroot-setup.sh
GRUB=build/grub/grub.cfg

echo "casper sucht nur das benannte Medium:"
conf=$(sed -n "/^cat >\/etc\/casper.conf <<'EOF'\$/,/^EOF\$/p" "$SETUP")
check "der Build schreibt /etc/casper.conf" '[[ -n $conf ]]'
check "darin steht LIVEMEDIA_TIMEOUT" 'grep -Eq "^export LIVEMEDIA_TIMEOUT=[0-9]+\$" <<<"$conf"'
t=$(sed -n 's/^export LIVEMEDIA_TIMEOUT=\([0-9]*\)$/\1/p' <<<"$conf")
check "der Wert liegt über den 60 Sekunden, die casper sucht: Die Suche über alle Geräte beginnt nie" '[[ ${t:-0} -gt 60 ]]'
line_conf=$(grep -n "^cat >/etc/casper.conf" "$SETUP" | cut -d: -f1)
line_init=$(grep -n "^update-initramfs " "$SETUP" | tail -n 1 | cut -d: -f1)
check "die initrd wird danach gebaut, die Datei kommt also hinein" '[[ -n $line_conf && -n $line_init && $line_conf -lt $line_init ]]'

echo "Jeder Eintrag des Bootmenüs nennt das Medium:"
args=$(sed -n 's/^set frs_args="\(.*\)"$/\1/p' "$GRUB")
check "die gemeinsamen Kernelparameter nennen live-media" '[[ " $args " == *" live-media=/dev/disk/by-label/FRS_RESCUE "* ]]'
check "kein Swap von fremden Disks, keine Prüfläufe auf fremden Dateisystemen" '[[ " $args " == *" noswap "* && " $args " == *" systemd.swap=0 "* && " $args " == *" fsck.mode=skip "* ]]'
n=$(grep -c '^[[:space:]]*linux /casper/vmlinuz ' "$GRUB")
with=$(grep -c '^[[:space:]]*linux /casper/vmlinuz \$frs_args ' "$GRUB")
check "alle $n Einträge, die das Rettungssystem starten, benutzen diese Parameter" '[[ $n -ge 3 && $n == "$with" ]]'
check "der Boot-Test der CI startet mit demselben Medium" 'grep -q "live-media=/dev/disk/by-label/FRS_RESCUE" tests/qemu-smoke.sh'

echo "Der Selbsttest prüft die initrd des gebauten Systems:"
check "selftest_boot läuft im Selbsttest" 'grep -q "selftest_boot \"\$dir\" || ok=0" rescue/frs'

((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
