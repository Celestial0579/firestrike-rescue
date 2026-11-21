#!/usr/bin/env bash
# Unit-Test: Verlässt der Techniker "Image weiterverwenden" oder hängt er ein anderes Ziel ein,
# gibt lf die Images frei, die es eingebunden hat: Einhängepunkte unter /mnt/lf-image aushängen,
# Loop-Geräte lösen. Was noch benutzt wird, bleibt, und lf sagt das.
#
# "Dateien kopieren" hängte die Partition eines Images über ein Loop-Gerät ein und gab sie nie
# wieder frei. Das Image liegt auf dem Ziel, das Ziel blieb belegt, und ein anderes ließ sich bis
# zum Neustart nicht einhängen: "Ziel abgelehnt: /mnt/lf-target ist noch in Benutzung" (#83).
# Ohne Disks und ohne root: losetup, lsblk, findmnt, mountpoint, umount, tmux, systemctl und sudo
# sind Attrappen. Ein gedachter Kernel führt Buch über Loop-Geräte, Einhängepunkte und offene
# Geräte. Das Skript, das als root nach offenen Geräten sucht, läuft am Ende an echten Dateien.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/target.sh
# shellcheck disable=SC1091
. rescue/lib/recover.sh
LF_RUN="$T/run"
LF_IMAGE_MNT="$T/img"
LF_TARGET_MNT="$T/ziel"
F="$LF_TARGET_MNT/LF/20261121-0222_Defekte_HDD_B1BAD0006"
G="$LF_TARGET_MNT/LF/20261120-1010_Alte_HDD_S1SRC0001"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# Der gedachte Kernel, je Zeile ein Eintrag:
#   loops   GERÄT DATEI        Loop-Geräte und ihre Dateien
#   parts   GERÄT PARTITION    Partitionen der Loop-Geräte
#   mounts  QUELLE ZIEL        Einhängepunkte
#   busy    ZIEL               wird benutzt (etwa rsync mit Arbeitsverzeichnis dort)
#   open    GERÄT              ein Prozess hat es offen (etwa ddrescue)
#   kurz    GERÄT N            noch für N Suchen offen (ntfs-3g endet kurz nach dem Aushängen)
#   zwischen GERÄT             wird genau zwischen Suche und Lösen geöffnet
#   auto    GERÄT              von mount -o loop angelegt, löst sich beim Aushängen
#   sessions NAME              tmux-Sitzungen
#   units   ZEILE              laufende Rettungen von Claude (systemctl list-units)
#   ohne-root                  gibt es die Datei, scheitert die Suche nach offenen Geräten
ohne() { awk -v n="$2" -v w="$3" '$n != w' "$T/$1" >"$T/$1.neu" && mv "$T/$1.neu" "$T/$1"; }
hat() { awk -v n="$2" -v w="$3" '$n == w {f = 1} END {exit !f}' "$T/$1"; }
eingehaengt() { hat mounts 2 "$1"; }
eingebunden() { hat loops 1 "$1"; }

log() { printf '%s\n' "$*" >>"$T/log"; }
run() { "$@"; }
# Die Suche nach offenen Geräten (dev_open) läuft als root mit sudo bash -c über /proc. Hier sieht
# sie den gedachten Kernel, ihr Skript wird für die Probe am Ende aufgehoben.
sudo() {
	if [[ $1 == bash && $2 == -c && $4 == _ ]]; then
		printf '%s' "$3" >"$T/suche.sh"
		shift 4
		offen "$@"
		return
	fi
	"$@"
}
offen() {
	local n k
	printf '%s\n' "$*" >>"$T/suchen"
	[[ -e $T/ohne-root ]] && return 1
	for n; do
		hat open 1 "$n" && return 0
		k=$(awk -v d="$n" '$1 == d {print $2}' "$T/kurz")
		if [[ -n $k ]] && ((k > 0)); then
			ohne kurz 1 "$n"
			echo "$n $((k - 1))" >>"$T/kurz"
			return 0
		fi
	done
	return 3
}
systemctl() {
	printf '%s\n' "$*" >>"$T/systemctl"
	[[ $1 == list-units ]] && cat "$T/units"
}
sleep() { :; }
ui_msg() { printf '%s\n' "$2" >>"$T/msg"; }
losetup() {
	case $1 in
	-J) jq -Rn '{loopdevices: [inputs | select(length > 0) | split(" ") | {name: .[0], "back-file": .[1]}]}' <"$T/loops" ;;
	-n) if [[ $3 == NAME ]]; then
		awk -v f="$5" '$2 == f {print $1}' "$T/loops"
	else
		awk -v l="$4" '$1 == l {print $2}' "$T/loops"
	fi ;;
	-d)
		echo "$2" >>"$T/detached"
		{ hat open 1 "$2" || hat zwischen 1 "$2"; } && return 0
		ohne loops 1 "$2"
		ohne parts 1 "$2"
		;;
	*) return 1 ;;
	esac
}
lsblk() {
	local dev=${*: -1} d
	case " $* " in
	*" PATH "*)
		echo "$dev"
		awk -v l="$dev" '$1 == l {print $2}' "$T/parts"
		;;
	*" MOUNTPOINTS "*)
		for d in "$dev" $(awk -v l="$dev" '$1 == l {print $2}' "$T/parts"); do
			awk -v s="$d" '$1 == s {print $2}' "$T/mounts"
		done
		;;
	*" FSTYPE "*) echo ext4 ;;
	esac
}
findmnt() {
	local last=${*: -1}
	case " $* " in
	*" -S "*) awk -v s="$last" '$1 == s {print $2; f = 1} END {exit !f}' "$T/mounts" ;;
	*" -M "*) awk -v t="$last" '$2 == t {print $1; f = 1} END {exit !f}' "$T/mounts" ;;
	*) return 1 ;;
	esac
}
mountpoint() { eingehaengt "${*: -1}"; }
umount() {
	local mp=$1 src
	echo "$mp" >>"$T/umounts"
	hat busy 1 "$mp" && return 32
	# Belegt bleibt, worauf noch die Datei eines Loop-Geräts liegt.
	awk -v d="$mp/" 'index($2, d) == 1 {f = 1} END {exit !f}' "$T/loops" && return 32
	eingehaengt "$mp" || return 32
	src=$(awk -v t="$mp" '$2 == t {print $1}' "$T/mounts")
	ohne mounts 2 "$mp"
	if hat auto 1 "$src"; then ohne loops 1 "$src"; fi
	return 0
}
tmux() { [[ $1 == has-session && $3 == =* ]] && hat sessions 1 "${3#=}"; }

# lage   Nach "Dateien kopieren" und "Dateisystem reparieren" im Fall F: eine Partition des
#   Images und eine der reparierten Kopie eingehängt. Dazu, was bleiben muss: eine Quelle, die
#   Claude mit lf-aufgabe eingehängt hat (sdb1), ein Image aus Fall G und ein Snap des Systems.
lage() {
	local f
	for f in busy open kurz zwischen auto sessions units detached umounts msg log suchen systemctl; do : >"$T/$f"; done
	rm -f "$T/ohne-root"
	cat >"$T/loops" <<-EOF
		/dev/loop0 /var/lib/snapd/snaps/core_1.snap
		/dev/loop7 $F/image.img
		/dev/loop8 $F/image.img.repair
		/dev/loop6 $G/image.img
	EOF
	cat >"$T/parts" <<-EOF
		/dev/loop7 /dev/loop7p1
		/dev/loop7 /dev/loop7p2
		/dev/loop8 /dev/loop8p2
		/dev/loop6 /dev/loop6p1
	EOF
	cat >"$T/mounts" <<-EOF
		/dev/sdc1 $LF_TARGET_MNT
		/dev/loop0 /snap/core/1
		/dev/loop7p2 $LF_IMAGE_MNT/loop7p2
		/dev/loop8p2 $LF_IMAGE_MNT/repair-loop8p2
		/dev/sdb1 $LF_IMAGE_MNT/sdb1
		/dev/loop6p1 $LF_IMAGE_MNT/loop6p1
	EOF
}
# bleibt   Was nie freigegeben wird: die Quelle von lf-aufgabe, der Snap und das Ziel selbst.
bleibt() { eingehaengt "$LF_IMAGE_MNT/sdb1" && eingehaengt /snap/core/1 && eingebunden /dev/loop0 && eingehaengt "$LF_TARGET_MNT"; }

echo "Fertig mit dem Fall (#83):"
lage
image_release "$F"
rc=$?
check "Rückgabe 0, nichts bleibt belegt" '((rc == 0)) && [[ -z $IMAGE_BUSY ]]'
check "die Partition aus 'Dateien kopieren' ist ausgehängt" '! eingehaengt "$LF_IMAGE_MNT/loop7p2"'
check "die reparierte Kopie ist ausgehängt" '! eingehaengt "$LF_IMAGE_MNT/repair-loop8p2"'
check "beide Loop-Geräte des Falls sind gelöst" '! eingebunden /dev/loop7 && ! eingebunden /dev/loop8'
check "das Image aus Fall G bleibt eingehängt und eingebunden" 'eingehaengt "$LF_IMAGE_MNT/loop6p1" && eingebunden /dev/loop6'
check "Quelle von lf-aufgabe, Snap und Ziel bleiben" 'bleibt'
check "ausgehängt wird nur unter /mnt/lf-image, und das Ziel nicht" '! grep -qvF "$LF_IMAGE_MNT/" "$T/umounts"'

echo "Das Ziel wechseln (alle Images darauf):"
lage
image_release "$LF_TARGET_MNT"
rc=$?
check "Rückgabe 0, die Images beider Fälle sind frei" '((rc == 0)) && ! eingebunden /dev/loop7 && ! eingebunden /dev/loop8 && ! eingebunden /dev/loop6'
check "Quelle von lf-aufgabe, Snap und Ziel bleiben" 'bleibt'

echo "Noch benutzt: rsync in lf-kopie kopiert noch aus der Partition:"
lage
echo "$LF_IMAGE_MNT/loop7p2" >"$T/busy"
image_release "$F"
rc=$?
check "Rückgabe 1" '((rc == 1))'
check "die Partition bleibt eingehängt, ihr Loop-Gerät eingebunden" 'eingehaengt "$LF_IMAGE_MNT/loop7p2" && eingebunden /dev/loop7'
check "lf sagt, was noch benutzt wird, einmal" '[[ $IMAGE_BUSY == "$LF_IMAGE_MNT/loop7p2 wird noch benutzt. " ]] && grep -q "bleiben teils eingebunden" "$T/log"'
check "die reparierte Kopie, die niemand benutzt, ist trotzdem frei" '! eingehaengt "$LF_IMAGE_MNT/repair-loop8p2" && ! eingebunden /dev/loop8'

echo "Offener Job lf-klon (Image auf eine neue Disk, liest das Loop-Gerät in Schritten):"
lage
echo lf-klon >"$T/sessions"
image_release "$F"
rc=$?
check "Rückgabe 1, lf nennt den Job" '((rc == 1)) && [[ $IMAGE_BUSY == *"Job lf-klon ist noch offen"*"tmux attach -t lf-klon" ]]'
check "nichts ausgehängt, kein Loop-Gerät gelöst" '[[ ! -s $T/umounts && ! -s $T/detached ]] && eingehaengt "$LF_IMAGE_MNT/loop7p2" && eingebunden /dev/loop7 && eingebunden /dev/loop8'

echo "Eine Rettung von Claude läuft (lf-aufgabe retten oder fortsetzen, auch von einem Image):"
lage
echo "lf-claude-rettung-0123456789ab.service loaded active running Leuchtfeuer: Rettung Fall" >"$T/units"
image_release "$F"
rc=$?
check "Rückgabe 1, lf nennt die Rettung" '((rc == 1)) && [[ $IMAGE_BUSY == "Eine Rettung, die Claude gestartet hat, läuft noch und liest womöglich aus dem Image." ]]'
check "nichts ausgehängt, kein Loop-Gerät gelöst" '[[ ! -s $T/umounts && ! -s $T/detached ]] && eingehaengt "$LF_IMAGE_MNT/loop7p2" && eingebunden /dev/loop7 && eingebunden /dev/loop8'
check "gefragt wird nach laufenden und startenden Einheiten lf-claude-rettung-*" '[[ $(cat "$T/systemctl") == "list-units --plain --no-legend --state=active,activating lf-claude-rettung-*" ]]'

echo "Laufende Jobs, die nie aus einem Loop-Gerät lesen (lf-kopie, lf-vhdx, lf-rettung, lf-p2v):"
lage
printf '%s\n' lf-kopie lf-vhdx lf-rettung lf-p2v >"$T/sessions"
image_release "$F"
rc=$?
check "die Images sind trotzdem frei: ob rsync noch liest, zeigen Aushängen und offene Geräte" '((rc == 0)) && ! eingebunden /dev/loop7 && ! eingebunden /dev/loop8'

echo "Ohne eingebundenes Image fragt lf nach keinem Job:"
lage
printf '/dev/loop0 /var/lib/snapd/snaps/core_1.snap\n' >"$T/loops"
echo lf-klon >"$T/sessions"
image_release "$F"
rc=$?
check "Rückgabe 0, nichts ausgehängt, keine Suche" '((rc == 0)) && [[ ! -s $T/umounts && ! -s $T/suchen && ! -s $T/systemctl ]] && bleibt'

echo "Von Hand außerhalb von /mnt/lf-image eingehängt:"
lage
echo "/dev/loop7p1 $T/hand" >>"$T/mounts"
image_release "$F"
rc=$?
check "bleibt eingehängt, das Loop-Gerät bleibt eingebunden, lf sagt das" '((rc == 1)) && eingehaengt "$T/hand" && eingebunden /dev/loop7 && [[ $IMAGE_BUSY == "loop7 ist noch außerhalb von $LF_IMAGE_MNT eingehängt. " ]]'
check "die Partition unter /mnt/lf-image ist trotzdem ausgehängt" '! eingehaengt "$LF_IMAGE_MNT/loop7p2"'

echo "BitLocker: eingehängt ist die Datei, die dislocker entschlüsselt:"
lage
D="$LF_RUN/dislocker-loop7p1"
printf '%s\n' "dislocker $D" "/dev/loop9 $LF_IMAGE_MNT/loop7p1" >>"$T/mounts"
echo "/dev/loop9 $D/dislocker-file" >>"$T/loops"
echo /dev/loop9 >"$T/auto"
image_release "$F"
rc=$?
check "über ein Loop-Gerät: entschlüsselte Partition und dislocker ausgehängt, Image gelöst" '((rc == 0)) && ! eingehaengt "$LF_IMAGE_MNT/loop7p1" && ! eingehaengt "$D" && ! eingebunden /dev/loop9 && ! eingebunden /dev/loop7'
check "dislocker erst nach der entschlüsselten Partition" '[[ $(grep -nxF "$LF_IMAGE_MNT/loop7p1" "$T/umounts" | cut -d: -f1) -lt $(grep -nxF "$D" "$T/umounts" | cut -d: -f1) ]]'
lage
printf '%s\n' "dislocker $D" "$D/dislocker-file $LF_IMAGE_MNT/loop7p1" >>"$T/mounts"
image_release "$F"
rc=$?
check "direkt mit ntfs-3g: ebenso" '((rc == 0)) && ! eingehaengt "$LF_IMAGE_MNT/loop7p1" && ! eingehaengt "$D" && ! eingebunden /dev/loop7'

echo "Ein Programm liest noch aus einem Loop-Gerät (etwa ddrescue in einer Rettung von Claude):"
lage
echo /dev/loop8 >"$T/open"
image_release "$F"
rc=$?
check "Rückgabe 1, lf sagt, dass es noch geöffnet ist" '((rc == 1)) && [[ $IMAGE_BUSY == "loop8 ist noch geöffnet, ein Programm liest daraus. " ]]'
check "es wird nicht gelöst, auch nicht verzögert" '! grep -qx /dev/loop8 "$T/detached" && eingebunden /dev/loop8'
check "gesucht wird nach dem Gerät und seinen Partitionen, viermal in drei Sekunden" '[[ $(grep -cx "/dev/loop8 /dev/loop8 /dev/loop8p2" "$T/suchen") == 4 ]]'
check "das andere Loop-Gerät des Falls ist trotzdem frei" '! eingebunden /dev/loop7'
lage
echo /dev/loop7p1 >"$T/open"
image_release "$F"
rc=$?
check "eine offene Partition hält ihr Loop-Gerät ebenso" '((rc == 1)) && [[ $IMAGE_BUSY == "loop7 ist noch geöffnet, ein Programm liest daraus. " ]] && ! grep -qx /dev/loop7 "$T/detached" && eingebunden /dev/loop7'

echo "ntfs-3g endet erst kurz nach dem Aushängen:"
lage
echo "/dev/loop7p2 2" >"$T/kurz"
image_release "$F"
rc=$?
check "lf wartet, danach ist das Loop-Gerät gelöst" '((rc == 0)) && ! eingebunden /dev/loop7 && [[ $(grep -c "^/dev/loop7 " "$T/suchen") == 3 ]]'

echo "Jemand öffnet ein Loop-Gerät genau zwischen Suche und Lösen:"
lage
echo /dev/loop8 >"$T/zwischen"
image_release "$F"
rc=$?
check "lf sagt, dass es erst danach gelöst wird" '((rc == 1)) && [[ $IMAGE_BUSY == "loop8 ist noch geöffnet und wird gelöst, sobald es frei ist. " ]]'

echo "Die Suche nach offenen Geräten scheitert (sudo):"
lage
: >"$T/ohne-root"
image_release "$F"
rc=$?
check "die Geräte gelten als offen, keines wird gelöst" '((rc == 1)) && [[ ! -s $T/detached ]] && eingebunden /dev/loop7 && eingebunden /dev/loop8'

echo "'Image weiterverwenden' verlassen:"
casefile_dirname_ok() { return 0; }
ddrescuelog() { :; }
claude_start() { :; }
ui_menu() { [[ $WAHL == esc ]] && return 1 || echo "$WAHL"; }
for WAHL in "done" esc; do
	lage
	recover_after "$F"
	[[ $WAHL == "done" ]] && wie="mit 'Fertig'" || wie="mit Esc"
	check "$wie: die Images des Falls sind frei, ohne Meldung" '! eingebunden /dev/loop7 && ! eingebunden /dev/loop8 && [[ ! -s $T/msg ]]'
done
lage
echo "$LF_IMAGE_MNT/loop7p2" >"$T/busy"
WAHL="done"
recover_after "$F"
check "wird noch kopiert: lf sagt, was belegt bleibt" 'grep -q "$LF_IMAGE_MNT/loop7p2 wird noch benutzt" "$T/msg" && eingebunden /dev/loop7'

echo "Ein anderes Ziel einhängen:"
target_search_unlock() { :; }
target_mount_raw() { echo "$1 $LF_TARGET_MNT" >>"$T/mounts"; }
target_mount_secure() { return 0; }
target_mount_has_opts() { return 1; }
mount_has_opts() { return 0; }
lage
target_mount_part /dev/sdd1
rc=$?
check "nach 'Dateien kopieren' hängt das neue Ziel ein" '((rc == 0)) && [[ $(findmnt -n -o SOURCE -M "$LF_TARGET_MNT") == /dev/sdd1 ]]'
check "die Images vom bisherigen Ziel sind gelöst" '! eingebunden /dev/loop7 && ! eingebunden /dev/loop8 && ! eingebunden /dev/loop6'
lage
echo "$LF_IMAGE_MNT/loop7p2" >"$T/busy"
target_mount_part /dev/sdd1
rc=$?
check "kopiert noch: Ziel abgelehnt, im Protokoll steht, was belegt ist" '((rc == 1)) && grep -q "Ziel abgelehnt" "$T/log" && grep -q "loop7p2 wird noch benutzt" "$T/log" && [[ $(findmnt -n -o SOURCE -M "$LF_TARGET_MNT") == /dev/sdc1 ]]'
disk_parts() { :; }
lage
target_find_cases_on /dev/sde
check "die Suche nach Rettungsfällen hängt das bisherige Ziel ebenso aus" '! eingehaengt "$LF_TARGET_MNT" && ! eingebunden /dev/loop7 && ! eingebunden /dev/loop6'

echo "Das Skript der Suche nach offenen Geräten, an Dateien dieses Tests:"
# Ohne root sieht es nur die eigenen Prozesse. Ein losgelöster sleep hält eine Datei offen.
: >"$T/gelesen" && : >"$T/frei" && rm -f "$T/bereit"
(exec 3<"$T/gelesen" && : >"$T/bereit" && exec sleep 300) >/dev/null 2>&1 &
LESER=$!
for i in $(seq 50); do [[ -e $T/bereit ]] && break; command sleep 0.1; done
suche() { bash -c "$(cat "$T/suche.sh")" _ "$@"; }
check "das Skript ist aufgezeichnet" '[[ -s $T/suche.sh ]]'
check "eine Datei, die ein Prozess offen hat: Rückgabe 0" 'suche "$T/frei" "$T/gelesen"'
kill "$LESER" 2>/dev/null
wait "$LESER" 2>/dev/null
check "ist sie wieder zu: Rückgabe 3, keines offen" 'suche "$T/frei" "$T/gelesen"; [[ $? == 3 ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
