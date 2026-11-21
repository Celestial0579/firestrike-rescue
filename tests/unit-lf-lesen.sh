#!/usr/bin/env bash
# Unit-Test: lf-lesen nimmt nur, was zur Aktion passt (rescue/bin/lf-lesen).
#
# lf-lesen läuft per sudo als root, für Claude (Benutzer lf-claude). Hier läuft es ohne root:
# Geprüft wird, dass es Argumente ablehnt, bevor es ein Werkzeug startet. Dass es als root
# richtig liest und lf-claude sonst nichts darf, prüft der Selbsttest der ISO
# (selftest_claude_user). Die Werkzeuge sind Attrappen, die ihren Aufruf mitschreiben.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

L=$PWD/rescue/bin/lf-lesen
T=$(mktemp -d)
# lf-lesen setzt PATH selbst. Damit die Attrappen greifen, läuft eine Kopie, deren PATH-Zeile auf
# den Ordner der Attrappen zeigt.
mkdir -p "$T/bin"
for t in lsblk smartctl sfdisk blkid dd od dmesg tail ldmtool; do
	printf '#!/bin/sh\necho "%s $*" >>"%s/aufrufe"\n' "$t" "$T" >"$T/bin/$t"
	chmod +x "$T/bin/$t"
done
sed "s|^PATH=.*|PATH=$T/bin|" "$L" >"$T/lf-lesen"
chmod +x "$T/lf-lesen"
check "die Kopie unterscheidet sich nur in der PATH-Zeile" '[[ $(diff "$L" "$T/lf-lesen" | grep -c "^[<>]") == 2 ]]'
check "das Original setzt PATH fest, ohne Verzeichnisse des Aufrufers" 'grep -q "^PATH=/usr/sbin:/usr/bin:/sbin:/bin$" "$L"'

# Ein Gerät, das es gibt: das erste Blockgerät dieses Rechners.
dev=$(find /sys/class/block -mindepth 1 -maxdepth 1 -printf "%f\n" | grep -E "^[a-z][a-z0-9]{0,31}$" | sort | head -n 1)
run() {
	: >"$T/aufrufe"
	out=$("$T/lf-lesen" "$@" 2>"$T/fehler")
	rc=$?
}

echo "Gültige Aufrufe starten genau ein Werkzeug mit festen Optionen:"
if [[ -n $dev && -b /dev/$dev ]]; then
	run smart "/dev/$dev"
	check "smart: smartctl -x GERÄT" '[[ $rc == 0 && $(cat "$T/aufrufe") == "smartctl -x /dev/$dev" ]]'
	run identitaet "/dev/$dev"
	check "identitaet: smartctl -i GERÄT, kein Medienzugriff" '[[ $rc == 0 && $(cat "$T/aufrufe") == "smartctl -i /dev/$dev" ]]'
	run ldm "/dev/$dev"
	check "ldm: ldmtool scan GERÄT" '[[ $(cat "$T/aufrufe") == "ldmtool scan /dev/$dev" ]]'
	run partitionen "/dev/$dev"
	check "partitionen: sfdisk -d GERÄT" '[[ $(cat "$T/aufrufe") == "sfdisk -d /dev/$dev" ]]'
	run dateisystem "/dev/$dev"
	check "dateisystem: blkid -p -o export GERÄT" '[[ $(cat "$T/aufrufe") == "blkid -p -o export /dev/$dev" ]]'
	run sektoren "/dev/$dev" 0010 3
	check "sektoren: dd mit festen Optionen, führende Nullen als Dezimalzahl" 'grep -qx "dd if=/dev/$dev bs=512 skip=10 count=3 status=none" "$T/aufrufe" && [[ $(grep -c "^dd " "$T/aufrufe") == 1 ]]'
	run sektoren "/dev/$dev" 0 64
	check "sektoren: 64 Sektoren gehen" '[[ $rc == 0 ]]'
else
	echo "  (kein Blockgerät auf diesem Rechner, gültige Geräte nicht geprüft)"
fi
run disks
check "disks: lsblk" '[[ $(cat "$T/aufrufe") == lsblk* ]]'
run kernel
check "kernel: dmesg und tail" '[[ $(cat "$T/aufrufe") == *"dmesg --ctime"* ]]'

echo "Abgelehnt, ohne ein Werkzeug zu starten:"
d=/dev/${dev:-sda}
while IFS= read -r line; do
	read -ra a <<<"$line"
	run "${a[@]}"
	check "lf-lesen $line" '[[ $rc == 2 && ! -s $T/aufrufe && -z $out && -s $T/fehler ]]'
done <<EOF
lies /etc/shadow
identitaet
identitaet /etc/shadow
identitaet $d -s on
ldm /etc/shadow
ldm $d --create
smart
smart $d $d
smart --scan
smart -a
smart /etc/shadow
smart /dev/../etc/shadow
smart /dev/gibt-es-nicht0
smart /dev/null
partitionen $d --delete
sektoren $d
sektoren $d 0 65
sektoren $d 0 0
sektoren $d -1
sektoren $d 0x10
sektoren $d 1e3
sektoren $d 0 1 2
disks --output-all
kernel -C
EOF
run smart "$d;id"
check "lf-lesen smart '$d;id'" '[[ $rc == 2 && ! -s $T/aufrufe ]]'
run smart "$d -s on"
check "lf-lesen smart '$d -s on' (ein Argument mit Leerzeichen)" '[[ $rc == 2 && ! -s $T/aufrufe ]]'
run
check "ohne Aktion" '[[ $rc == 2 && ! -s $T/aufrufe ]]'

echo "Einbau:"
check "die Regel wird mit visudo geprüft" 'grep -q "^visudo -cf /etc/sudoers.d/lf-claude$" build/chroot-setup.sh'
check "der Assistent startet Claude als lf-claude, in eigener cgroup" 'grep -q "^CLAUDE_USER=lf-claude$" rescue/lib/claude.sh && grep -q "claude_scope sh -c .cd" rescue/lib/claude.sh && grep -qF -- "--slice=\"\$CLAUDE_SLICE\" -- sudo -u \"\$CLAUDE_USER\" -H \"\$@\"" rescue/lib/claude.sh'
check "das Home von Claude kommt vom Speicher, Verknüpfungen werden nicht verfolgt" 'grep -q "chown -R -h" rescue/lib/persist.sh'
check "der Selbsttest prüft lf-claude" 'grep -q "selftest_claude_user \"\$dir\" || ok=0" rescue/lf'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
