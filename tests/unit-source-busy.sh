#!/usr/bin/env bash
# Unit-Test (GHSA-p86q-3456-f288): lf-aufgabe nimmt keine Quelle, auf die gerade ein Job schreibt
# (dd oder partclone eines laufenden Klons), und kein Hilfsgerät (nbd: Overlay eines Klons,
# zram). Ein blockdev --setro darauf ließe den Job mitten im Lauf scheitern. Maßgeblich ist die
# Jobliste des Assistenten, denn zwischen zwei Kopierschritten hat niemand die Ziel-Disk offen;
# offene Schreibzugriffe und schreibbar eingehängte Dateisysteme fangen den Rest ab.
#
# Hier wird nichts eingehängt: Die "Disk" sind gewöhnliche Dateien, lsblk, disk_of, boot_disk,
# target_disk und fail sind Attrappen. Ein losgelöster sleep hält eine Datei offen wie dd.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
echo "Quellen für lf-aufgabe:"
# Die Funktionen aus lf-aufgabe, mit Attrappen für Disks und fail. Die "Disk" sind gewöhnliche
# Dateien; ein losgelöster Prozess hält eine davon zum Schreiben offen wie dd im Klon.
sed -n '/^disk_written() {/,/^}/p; /^disk_mounted_rw() {/,/^}/p; /^source_ok() {/,/^}/p' rescue/bin/lf-aufgabe >"$T/aufgabe-fns.sh"
# Die Jobliste aus common.sh: eintragen (Assistent) und lesen (lf-aufgabe).
sed -n '/^tmux_start() {/,/^}/p; /^tmux_run_writing() {/,/^}/p; /^job_register() {/,/^}/p; /^job_starttime() {/,/^}/p; /^job_disks() {/,/^}/p' rescue/lib/common.sh >>"$T/aufgabe-fns.sh"
# shellcheck disable=SC1091
. "$T/aufgabe-fns.sh"
LF_JOBS="$T/jobs"
findmnt() { cat "$T/mounts" 2>/dev/null; }
: >"$T/sdz" && : >"$T/sdz1" && : >"$T/sdz2"
lsblk() { printf '%s\n' "$T/sdz" "$T/sdz1" "$T/sdz2"; }
disk_of() { echo "$1"; }
boot_disk() { echo /dev/sdy; }
target_disk() { echo /dev/sdx; }
fail() { echo "abgelehnt: $*"; exit 2; }
(exec 3<"$T/sdz2" && exec sleep 300) >/dev/null 2>&1 &
READER=$!
check "nur lesend offen (etwa ddrescue auf der Quelle): keine Schreib-Disk" '! disk_written "$T/sdz"'
(exec 3>>"$T/sdz1" && exec sleep 300) >/dev/null 2>&1 &
WRITER=$!
sleep 0.3
check "eine Partition zum Schreiben offen (dd, partclone): erkannt" 'disk_written "$T/sdz"'
check "source_ok lehnt diese Disk ab" '[[ $( (source_ok "$T/sdz") ; echo "rc=$?") == *"wird gerade beschrieben"*"rc=2" ]]'
kill "$WRITER" "$READER" 2>/dev/null
wait "$WRITER" "$READER" 2>/dev/null
check "source_ok lehnt nbd (Overlay des Klons) und zram ab" '[[ $( (source_ok /dev/nbd0); echo "rc=$?") == *"Hilfsgerät"*"rc=2" && $( (source_ok /dev/zram0); echo "rc=$?") == *"rc=2" ]]'
check "eine Disk ohne Schreibzugriff bleibt Quelle" '[[ $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'

echo "Jobliste des Assistenten:"
# Ein Klon zwischen zwei Schritten: Sein Prozess lebt, aber niemand hat die Ziel-Disk offen.
(exec sleep 300) >/dev/null 2>&1 &
JOB=$!
tmux() {
	case $1 in
	has-session) return 1 ;;
	display-message) echo "$JOB" ;;
	esac
	return 0
}
tmux_run_writing lf-klon "$T/sdz" sudo /run/lf/clone-job.sh
check "tmux_run_writing trägt den Prozess der Sitzung mit der Ziel-Disk ein" '[[ $(cut -d" " -f1,3 "$LF_JOBS/lf-klon") == "$JOB $T/sdz" && $(job_disks) == "$T/sdz" ]]'
check "source_ok lehnt das Ziel eines laufenden Klons ab, auch ohne offenen Schreibzugriff" '! disk_written "$T/sdz" && [[ $( (source_ok "$T/sdz"); echo "rc=$?") == *"Ziel eines laufenden Jobs"*"rc=2" ]]'
start=0
read -r _ start _ <"$LF_JOBS/lf-klon" 2>/dev/null
printf '%s %s %s\n' "$JOB" "$((start + 1))" "$T/sdz" >"$LF_JOBS/lf-klon"
check "eine neu vergebene PID (andere Startzeit) gilt nicht als derselbe Job" '[[ -z $(job_disks) && $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'
printf '%s %s %s\n' "$JOB" "$start" "$T/sdz" >"$LF_JOBS/lf-klon"
kill "$JOB" 2>/dev/null
wait "$JOB" 2>/dev/null
check "ist der Job beendet, ist die Disk wieder Quelle" '[[ -z $(job_disks) && $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'
check "beide Klon-Wege tragen ihre Ziel-Disk ein" '[[ $(grep -c "tmux_run_writing \"lf-klon\" \"\$tdev\" " rescue/lib/clone.sh) == 2 ]] && ! grep -q "tmux_run \"lf-klon\"" rescue/lib/clone.sh'

echo "Schreiber über ein Dateisystem:"
printf '%s rw,relatime\n' "$T/sdz1" >"$T/mounts"
check "eine schreibbar eingehängte Partition: abgelehnt" '[[ $( (source_ok "$T/sdz"); echo "rc=$?") == *"schreibbar eingehängt"*"rc=2" ]]'
printf '%s ro,nosuid,nodev,noexec\n' "$T/sdz1" >"$T/mounts"
check "nur lesend eingehängt (etwa von lf-aufgabe selbst): weiter Quelle" '[[ $( (source_ok "$T/sdz"); echo "rc=$?") == "rc=0" ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
