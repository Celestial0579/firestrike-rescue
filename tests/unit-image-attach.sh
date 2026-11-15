#!/usr/bin/env bash
# Unit-Test: image_attach hebt einen geerbten Schreibschutz nur auf einem Loop-Gerät auf, das es
# gerade selbst beschreibbar eingebunden hat (#48). Nur lesend bleibt nur lesend.
#
# Ohne root: losetup, blockdev und lsblk sind Attrappen. Ob der Kernel den Schutz wirklich behält
# und image_attach ihn aufhebt, prüft der Selbsttest der ISO (selftest_loop_rw).
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

T=$(mktemp -d)
LF_LOG=/dev/null
# shellcheck disable=SC1091
. rescue/lib/recover.sh
log() { :; }
run() { "$@"; }
sleep() { :; }
# Der gedachte Rechner: ATTACHED ist das Gerät, das losetup -j meldet (leer: keins).
# RO: Geräte, die schreibgeschützt sind.
sudo() {
	printf '%s\n' "$*" >>"$T/sudo"
	case "$1 $2" in
	"losetup -j") [[ -n $ATTACHED ]] && echo "$ATTACHED: []: ($3)" ;;
	"losetup --find") echo /dev/loop7 ;;
	"blockdev --getro") if [[ " $RO " == *" $3 "* ]]; then echo 1; else echo 0; fi ;;
	esac
}
lsblk() { printf '/dev/loop7\n/dev/loop7p1\n/dev/loop7p2\n'; }
attach() {
	: >"$T/sudo"
	out=$(image_attach "$T/image.img" "$1")
	calls=$(cat "$T/sudo")
}

echo "Beschreibbar, auf einem Gerät mit altem Schreibschutz:"
ATTACHED="" RO="/dev/loop7 /dev/loop7p2"
attach rw
check "eingebunden ohne -r" '[[ $out == /dev/loop7 && $calls == *"losetup --find --show -P $T/image.img"* && $calls != *" -r "* ]]'
check "Schreibschutz auf dem Gerät und der Partition aufgehoben" '[[ $calls == *"blockdev --setrw /dev/loop7"$'\''\n'\''* && $calls == *"blockdev --setrw /dev/loop7p2"* ]]'
check "eine Partition ohne Schutz bleibt unberührt" '[[ $calls != *"--setrw /dev/loop7p1"* ]]'

echo "Nur lesend:"
ATTACHED="" RO="/dev/loop7"
attach ro
check "eingebunden mit -r, kein setrw" '[[ $calls == *"losetup --find --show -P -r $T/image.img"* && $calls != *setrw* ]]'

echo "Schon eingebunden:"
ATTACHED=/dev/loop3 RO="/dev/loop3"
attach rw
check "das vorhandene Gerät wird genommen, sein Schutz bleibt" '[[ $out == /dev/loop3 && $calls != *setrw* && $calls != *"--find"* ]]'

echo "Einbau:"
check "die Reparatur bricht ab, wenn die Kopie nur lesend eingebunden ist" 'grep -q "Die Kopie ist nur lesend eingebunden" rescue/lib/recover.sh'
check "der Selbsttest prüft das Wiederverwenden" 'grep -q "selftest_loop_rw \"\$dir\" || ok=0" rescue/lf'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
