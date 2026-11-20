#!/usr/bin/env bash
# Unit-Test (GHSA-799j-44qx-x7xj): lf-freigabe beim Freischalten und am Ende einer Freigabe.
#   - status sagt "an", solange die Regel besteht, auch wenn sich die Uhr umgestellt hat; das
#     Ende kommt aus dem Timer. Ohne Regel sagt status erst "aus", wenn kein Timer mehr läuft und
#     kein Rückstand zu sehen ist (root-Prozess bei Claude, neue sudo-Datei, neue Einheit, linger).
#     Nach einem sauberen Ende zählen spätere Einheiten nicht mehr, bei einem Rückstand weiter.
#   - "an" erkennt lf-claude auch ohne SUDO_USER an den Vorfahren und an der cgroup. Solange
#     Claude root hat, verlängert "an" nur von einer Konsole (tty1 bis tty63) mit "j" dort, auch
#     unter sudo-rs (reale UID des Technikers in sudo und seinem Überwacher am eigenen pts).
#   - "aus" und der Ablauf halten die cgroup von Claude an und beenden darin jeden root-Prozess
#     (außer sudo, Jobs von lf-lesen und lf-aufgabe, chrome-sandbox), dazu neue Einheiten (auch
#     unter einem Namen von vorher neu angelegt: neue InvocationID), at-Aufträge und cron-Dateien
#     und was lf-claude sonst mit der Freigabe gestartet hat. Jobs von lf-aufgabe und Prozesse
#     des Technikers laufen weiter; gemeldet wird, was lf-claude danach noch darf.
#   - ntfs-3g für eine Quelle, die lf-aufgabe nur lesend eingehängt hat, läuft als eigener Dienst
#     (ntfs3g_ro in recover.sh). Er bleibt am Ende einer Freigabe und zählt nicht als Rückstand,
#     nur wenn Name, Programm, Optionen, Quelle und Einhängepunkt zusammenpassen.
#
# Hier läuft nichts als root: Eine Kopie von lf-freigabe arbeitet mit eigenen Ordnern statt
# /etc/sudoers.d, /run/lf, /proc und /sys/fs/cgroup. sudo, systemctl, systemd-run, loginctl, atq,
# atrm, visudo, logger und id sind Attrappen. Beendet werden nur sleep-Prozesse, die der Test
# selbst startet.
set -u
cd "$(dirname "$0")/.." || exit 1
unset SUDO_USER SUDO_UID SUDO_COMMAND

T=$(mktemp -d)
mkdir -p "$T/bin" "$T/sudoers.d" "$T/run" "$T/proc" "$T/unit" "$T/unitfiles" "$T/cron.d" "$T/linger" "$T/sysblock/sdb1"
# Die cgroups von Claude: lf-claude.slice mit der Sitzung der CLI und die Benutzer-Slice von lf-claude.
CG="$T/cg/lf.slice/lf-claude.slice"
CGU="$T/cg/user.slice/user-1001.slice"
mkdir -p "$CG/cli.scope" "$CGU"
for c in "$CG" "$CGU"; do
	echo 0 >"$c/cgroup.freeze"
	echo "frozen 1" >"$c/cgroup.events"
done
: >"$CG/cli.scope/cgroup.procs"
: >"$CGU/cgroup.procs"
touch "$T/sudoers"
F="$T/lf-freigabe"
sed -e "s|^PATH=.*|PATH=$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|" \
	-e "s|/etc/sudoers.d/|$T/sudoers.d/|g" -e "s|^SUDOERS=.*|SUDOERS=$T/sudoers|" -e "s|/run/lf|$T/run|g" \
	-e "s|/proc/|$T/proc/|g" -e "s|^SUDO_EXE=.*|SUDO_EXE=$T/bin/sudo|" -e "s|^CGROOT=.*|CGROOT=$T/cg|" \
	-e "s|^LINGER=.*|LINGER=$T/linger|" -e "s|^CRON_PATHS=.*|CRON_PATHS=($T/cron.d)|" -e "s|^TTY=.*|TTY=$T/tty|" \
	-e "s|^SYS_BLOCK=.*|SYS_BLOCK=$T/sysblock|" -e "s|((EUID == 0))|((EUID == $(id -u)))|g" rescue/bin/lf-freigabe >"$F"

cat >"$T/bin/id" <<MOCK
#!/bin/bash
case "\$*" in
"-u lf-claude") echo 1001 ;;
"-Gn lf-claude") cat "$T/groups" ;;
"-nu 1000") echo rescue ;;
"-nu 1001") echo lf-claude ;;
*) exec /usr/bin/id "\$@" ;;
esac
MOCK
cat >"$T/bin/sudo" <<MOCK
#!/bin/bash
[[ "\$*" == "-l -U lf-claude" ]] && { cat "$T/sudo-l"; exit 0; }
exit 1
MOCK
# systemctl: Timer aus timers.json, Einheiten aus units (Liste) und unit/NAME (Eigenschaften).
cat >"$T/bin/systemctl" <<MOCK
#!/bin/bash
echo "\$*" >>"$T/systemctl.log"
u=\${!#}
case \$1 in
list-timers) cat "$T/timers.json" 2>/dev/null || echo "[]" ;;
list-units)
	# Ohne --all nur Einheiten, die nicht inaktiv sind.
	while read -r n _; do
		[[ " \$* " == *" --all "* ]] || ! grep -qx ActiveState=inactive "$T/unit/\$n" 2>/dev/null || continue
		echo "\$n loaded active running x"
	done < <(cat "$T/units" 2>/dev/null)
	;;
show)
	if [[ "\$*" == "show -p ControlGroup --value lf-claude.slice" ]]; then
		echo /lf.slice/lf-claude.slice
	elif [[ "\$*" == "show -p Id -p InvocationID -- "* ]]; then
		# Wie systemctl: je Einheit ein Block, dazwischen eine Leerzeile.
		shift 5
		for n in "\$@"; do
			[[ \$n == "\$1" ]] || echo
			echo "Id=\$n"
			grep '^InvocationID=' "$T/unit/\$n" 2>/dev/null || echo "InvocationID="
		done
	else
		cat "$T/unit/\$u" 2>/dev/null
	fi
	;;
stop) [[ -f "$T/unit/\$u" ]] && sed -i 's/^ActiveState=.*/ActiveState=inactive/' "$T/unit/\$u" ;;
esac
exit 0
MOCK
printf '#!/bin/bash\necho "$*" >>"%s/systemd-run.log"\n' "$T" >"$T/bin/systemd-run"
printf '#!/bin/bash\necho "$*" >>"%s/loginctl.log"\n[[ $1 == disable-linger ]] && rm -f "%s/linger/$2"\nexit 0\n' "$T" "$T" >"$T/bin/loginctl"
printf '#!/bin/bash\ncat "%s/atq" 2>/dev/null\n' "$T" >"$T/bin/atq"
printf '#!/bin/bash\necho "$*" >>"%s/atrm.log"\n' "$T" >"$T/bin/atrm"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/visudo"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/logger"
chmod +x "$T/bin/"*

BASE="    (root) NOPASSWD: /usr/local/bin/lf-lesen, /usr/local/bin/lf-aufgabe"
sudo_l() { printf 'User lf-claude may run the following commands on test:\n%s\n' "$BASE" "$@" >"$T/sudo-l"; }
sudo_l
echo "lf-claude render" >"$T/groups"
LOG="$T/run/claude-aufgaben.log"
RULE="$T/sudoers.d/lf-claude-freigabe"
SNAP="$T/run/claude-freigabe-vorher"
TTY1=$(((4 << 8) | 1))
PTS=$(((136 << 8) | 3))

# fake PID RUID EUID PPID [UMGEBUNG] [BEFEHL] [PROGRAMM] [TTY]   Eintrag in der Attrappe von /proc.
#   UMGEBUNG mit | getrennt, BEFEHL mit Leerzeichen, PROGRAMM wird /proc/PID/exe, TTY die
#   Gerätenummer des steuernden Terminals.
fake() {
	mkdir -p "$T/proc/$1"
	printf 'Name:\tx\nState:\tS (sleeping)\nPPid:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$4" "$2" "$3" "$3" "$3" >"$T/proc/$1/status"
	printf '%s' "${5:-}" | tr '|' '\0' >"$T/proc/$1/environ"
	printf '%s' "${6:-x}" | tr ' ' '\0' >"$T/proc/$1/cmdline"
	local cmd=${6:-x}
	cmd=${cmd%% *}
	printf '%s\n' "${cmd##*/}" >"$T/proc/$1/comm"
	rm -f "$T/proc/$1/exe"
	[[ -z ${7:-} ]] || ln -s "$7" "$T/proc/$1/exe"
	printf '%s (%s) S %s %s %s %s 0 0\n' "$1" "${cmd##*/}" "$4" "$1" "$1" "${8:-0}" >"$T/proc/$1/stat"
}
# self CGROUP   Die cgroup dieses Aufrufs (/proc/self/cgroup).
self() { mkdir -p "$T/proc/self" && echo "0::$1" >"$T/proc/self/cgroup"; }
self /user.slice/user-1000.slice/session-1.scope
# unit NAME TRANSIENT CGROUP [UNIT-DATEI] [EXECSTART] [DROP-INS]   Eine laufende Einheit für die
#   Attrappe von systemctl. Jeder Aufruf startet sie (neu): Sie bekommt eine neue InvocationID.
INV=0
unit() {
	INV=$((INV + 1))
	printf 'Transient=%s\nActiveState=active\nControlGroup=%s\nFragmentPath=%s\nDropInPaths=%s\nExecStart=%s\nInvocationID=%032x\n' \
		"$2" "$3" "${4:-}" "${6:-}" "${5:-}" "$INV" >"$T/unit/$1"
	echo "$1 loaded active running x" >>"$T/units"
}
# spawn   Startet sleep losgelöst (nicht als Kind dieses Tests) und gibt die PID aus.
spawn() { (sleep 300 >/dev/null 2>&1 &
	echo $!); }
# spawn_noterm   Wie spawn, aber sleep übergeht TERM (wie ein Prozess in einer angehaltenen cgroup).
spawn_noterm() { (bash -c 'trap "" TERM; exec sleep 300' >/dev/null 2>&1 &
	echo $!); }
# line TEXT   Zeile, in der TEXT zum ersten Mal im Protokoll steht.
line() { grep -n -m1 -F -- "$1" "$LOG" | cut -d: -f1; }

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
NOW=$(date +%s)

echo "status:"
check "ohne Regel: aus" '[[ $(bash "$F" status) == aus ]]'
echo "lf-claude ALL=(ALL:ALL) NOPASSWD: ALL" >"$RULE"
# Nach dem Freischalten hat sich die Uhr umgestellt: Die Wanduhr-Zeit in der Datei ist vorbei,
# der monotone Timer läuft noch 10 Minuten.
echo $((NOW - 3600)) >"$T/run/claude-freigabe-bis"
echo "[{\"next\": $(((NOW + 600) * 1000000)), \"unit\": \"lf-claude-freigabe-ende.timer\"}]" >"$T/timers.json"
check "Regel da, Uhr umgestellt: an, das Ende kommt aus dem Timer" '[[ $(bash "$F" status) == "an bis $(date -d "@$((NOW + 600))" +%H:%M)" ]]'
rm -f "$T/timers.json"
check "Regel da, kein Timer: an, ohne Ablauf" '[[ $(bash "$F" status) == "an, ohne Ablauf" ]]'
check "die Statuszeile von Claude Code warnt" '[[ $(bash "$F" zeile </dev/null) == ACHTUNG* ]]'
rm -f "$RULE" "$T/run/claude-freigabe-bis"

echo "an:"
# Vorfahren des Aufrufs: dieser Test (root wie sudo), darüber eine Shell von lf-claude.
fake $$ 0 0 4194399001
fake 4194399001 1001 1001 1 "" "bash"
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "aus der Sitzung von lf-claude, ohne SUDO_USER: abgelehnt und protokolliert" '[[ $RC == 2 && ! -e $RULE ]] && grep -q "nur der Techniker" "$T/out" && grep -q "abgelehnt" "$LOG"'
fake 4194399001 1000 1000 1 "" "bash"
rm -f "$RULE"
SUDO_USER=lf-claude bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "SUDO_USER=lf-claude: abgelehnt (wie im Selbsttest der ISO)" '[[ $RC == 2 && ! -e $RULE ]]'
rm -f "$RULE"
SUDO_UID=1001 bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "SUDO_UID von lf-claude: abgelehnt" '[[ $RC == 2 && ! -e $RULE ]]'
rm -f "$RULE"
self /lf.slice/lf-claude.slice/cli.scope
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "aus der cgroup von Claude, Vorfahren unauffällig: abgelehnt" '[[ $RC == 2 && ! -e $RULE ]] && grep -q "nur der Techniker" "$T/out"'
self /user.slice/user-1000.slice/session-1.scope
# Das erste Freischalten braucht keine Konsole: Der Selbsttest der ISO schaltet aus einem Dienst frei.
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "vom Techniker: frei, mit Ablauf, im Protokoll mit seinem Namen" '[[ $RC == 0 && -e $RULE ]] && grep -q -- "--on-active=30min" "$T/systemd-run.log" && grep -q "freigegeben von rescue" "$LOG"'

echo "Verlängern, solange Claude root hat:"
echo "[{\"next\": $(((NOW + 600) * 1000000)), \"unit\": \"lf-claude-freigabe-ende.timer\"}]" >"$T/timers.json"
# Vorfahren: dieser Test (root wie sudo), darüber die Shell des Technikers an tty1.
fake $$ 0 0 4194399101
fake 4194399101 1000 1000 1 "" "bash" "" "$TTY1"
: >"$T/systemd-run.log"
rm -rf "$T/tty"
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "an der Konsole ohne Antwort: nicht verlängert" '[[ $RC == 2 && ! -s $T/systemd-run.log ]] && grep -q "Nicht verlängert" "$T/out" && grep -q "ohne Bestätigung" "$LOG"'
printf 'n\n' >"$T/tty"
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "an der Konsole mit n: nicht verlängert" '[[ $RC == 2 && ! -s $T/systemd-run.log ]]'
printf 'j\n' >"$T/tty"
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "an der Konsole mit j: verlängert, die Rückfrage stand am Terminal" '[[ $RC == 0 ]] && grep -q -- "--on-active=30min" "$T/systemd-run.log" && grep -q "Freigabe für 30 Minuten ab jetzt" "$T/tty" && grep -q "verlängert an der Konsole von rescue" "$LOG"'
: >"$T/systemd-run.log"
fake 4194399101 1000 1000 1 "" "bash" "" "$PTS"
printf 'j\n' >"$T/tty"
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "über ein Pseudo-Terminal (SSH, tmux), auch mit j: abgelehnt" '[[ $RC == 2 && ! -s $T/systemd-run.log ]] && grep -q "Verlängern nicht von einer Konsole" "$LOG"'
# Wie unter sudo-rs: sudo und sein Überwacher behalten die reale UID des Technikers (nur die
# effektive ist 0), der Überwacher sitzt an einem eigenen Pseudo-Terminal.
fake $$ 1000 0 4194399112 "" "sudo lf-freigabe an 30" "$T/bin/sudo" "$PTS"
fake 4194399112 1000 0 4194399101 "" "sudo lf-freigabe an 30" "$T/bin/sudo" "$TTY1"
fake 4194399101 1000 1000 1 "" "bash" "" "$TTY1"
: >"$T/systemd-run.log"
printf 'j\n' >"$T/tty"
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "unter sudo-rs an der Konsole mit j: verlängert (GHSA-799j-44qx-x7xj)" '[[ $RC == 0 ]] && grep -q -- "--on-active=30min" "$T/systemd-run.log" && tail -n 1 "$LOG" | grep -q "verlängert an der Konsole von rescue"'
fake 4194399112 1000 0 4194399101 "" "sudo lf-freigabe an 30" "$T/bin/sudo" "$PTS"
fake 4194399101 1000 1000 1 "" "bash" "" "$PTS"
: >"$T/systemd-run.log"
printf 'j\n' >"$T/tty"
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "unter sudo-rs über ein Pseudo-Terminal, auch mit j: abgelehnt" '[[ $RC == 2 && ! -s $T/systemd-run.log ]]'
# Wie "sudo systemd-run lf-freigabe an": Elternprozess PID 1, keine Umgebung von sudo.
fake $$ 0 0 1
printf 'j\n' >"$T/tty"
bash "$F" an 240 >"$T/out" 2>&1
RC=$?
check "wie über systemd-run (Elternprozess PID 1), auch mit j: abgelehnt" '[[ $RC == 2 && ! -s $T/systemd-run.log ]]'
# "aus" aus der cgroup von Claude hielte sich selbst an: Das Ende läuft als eigener Dienst.
self /lf.slice/lf-claude.slice/cli.scope
bash "$F" aus >"$T/out" 2>&1
check "aus aus der cgroup von Claude: das Ende läuft als eigener Dienst" 'grep -q -- "--unit=lf-claude-freigabe-ende-aus" "$T/systemd-run.log" && [[ -e $RULE ]]'
self /user.slice/user-1000.slice/session-1.scope
rm -f "$T/timers.json"
rm -rf "$T/proc/"[0-9]*

echo "aus:"
P1=$(spawn) P2=$(spawn) P3=$(spawn) P4=$(spawn) P5=$(spawn) P6=$(spawn)
fake "$P1" 0 0 1 "SUDO_USER=lf-claude|SUDO_COMMAND=/usr/bin/sleep 300" "sleep 300"
fake "$P2" 0 0 1 "SUDO_USER=lf-claude|SUDO_COMMAND=/usr/local/bin/lf-aufgabe klonen /dev/sdb /dev/sdc" "ddrescue a"
fake "$P3" 0 0 1 "SUDO_USER=rescue|SUDO_COMMAND=/usr/bin/ddrescue" "ddrescue b"
# Umgebung geleert (sudo env -i ...), aber über sudo aus einer Shell von lf-claude gestartet
fake "$P4" 0 0 4194399003 "" "sleep 300"
fake 4194399003 1001 0 4194399002 "" "sudo env -i sleep 300"
fake 4194399002 1001 1001 1 "" "bash"
# setuid-Hilfsprogramm von Claude Desktop, ohne sudo gestartet: bleibt
fake "$P5" 1001 0 4194399004 "SUDO_USER=rescue|SUDO_COMMAND=/usr/bin/claude-desktop" "/opt/claude/chrome-sandbox"
fake 4194399004 1001 1001 1 "SUDO_USER=rescue" "/opt/claude/claude-desktop"
# mit der Freigabe als ein anderer Benutzer gestartet (sudo -u rescue ...)
fake "$P6" 1000 1000 1 "SUDO_USER=lf-claude|SUDO_COMMAND=/usr/bin/sleep 300" "sleep 300"
bash "$F" aus >"$T/out" 2>&1
RC=$?
check "Regel weg, status aus" '[[ $RC == 0 && ! -e $RULE && $(bash "$F" status) == aus ]]'
check "beendet, was lf-claude mit der Freigabe gestartet hat, auch ohne SUDO_USER und als anderer Benutzer" '! kill -0 "$P1" 2>/dev/null && ! kill -0 "$P4" 2>/dev/null && ! kill -0 "$P6" 2>/dev/null && grep -q "beendet: $P1 sleep 300" "$LOG" && grep -q "beendet: $P4" "$LOG"'
check "Jobs von lf-aufgabe, Prozesse des Technikers und setuid-Programme ohne sudo laufen weiter" 'kill -0 "$P2" 2>/dev/null && kill -0 "$P3" 2>/dev/null && kill -0 "$P5" 2>/dev/null'
kill "$P2" "$P3" "$P5" "$P1" "$P4" "$P6" 2>/dev/null
rm -rf "$T/proc/"[0-9]*

echo "aus, cgroup von Claude:"
rm -rf "$SNAP"
: >"$T/units"
: >"$LOG"
: >"$T/systemctl.log"
touch -d '-2 minutes' "$T/unitfiles/a.service" "$T/unitfiles/getty@.service" "$T/unitfiles/b.service" "$T/unitfiles/c.service"
unit a.service no /system.slice/a.service "$T/unitfiles/a.service"
# Laufen schon vor der Freigabe: vorübergehende Einheiten und Dienste aus Unit-Dateien.
unit run-u5.service yes /system.slice/run-u5.service
unit run-u6.service yes /system.slice/run-u6.service
unit b.service no /system.slice/b.service "$T/unitfiles/b.service"
unit c.service no /system.slice/c.service "$T/unitfiles/c.service"
echo 1 >"$T/atq"
echo "* * * * * root true" >"$T/cron.d/alt"
fake $$ 0 0 4194399001
fake 4194399001 1000 1000 1 "" "bash"
bash "$F" an 30 >"$T/out" 2>&1
check "Freischalten hält fest, was es schon gab (Einheiten mit InvocationID)" '[[ -e $RULE ]] && grep -qE "^a\.service [0-9a-f]{32}$" "$SNAP/units" && grep -qx 1 "$SNAP/at" && grep -q "/cron.d/alt " "$SNAP/cron"'
touch -d '-1 minute' "$SNAP/units"
# Unter einem Namen von vorher (neue InvocationID): run-u5 gestoppt und neu angelegt, b neu
# gestartet mit einer neuen Ergänzung (systemctl edit --runtime), c nur neu gestartet. run-u6
# läuft unverändert weiter. e hat eine Ergänzung, deren Pfad systemctl nicht ausgibt (Leerzeichen),
# f eine Unit-Datei, die es nicht mehr gibt.
unit run-u5.service yes /system.slice/run-u5.service
mkdir -p "$T/unitfiles/b.service.d"
touch "$T/unitfiles/b.service.d/override.conf"
unit b.service no /system.slice/b.service "$T/unitfiles/b.service" "" "$T/unitfiles/b.service.d/override.conf"
unit c.service no /system.slice/c.service "$T/unitfiles/c.service"
unit e.service no /system.slice/e.service "$T/unitfiles/c.service" "" "[unprintable]"
unit f.service no /system.slice/f.service "$T/unitfiles/weg.service"
# Während der Freigabe entstanden: Einheiten, ein at-Auftrag, eine cron-Datei, linger.
unit run-u7.service yes /system.slice/run-u7.service
touch "$T/unitfiles/boese.timer"
unit boese.timer no "" "$T/unitfiles/boese.timer"
unit lf-claude-rettung-sdb.service yes /system.slice/lf-claude-rettung-sdb.service "" "{ path=/usr/local/bin/lf-rescue-run ; argv[]=/usr/local/bin/lf-rescue-run /dev/sdb ; }"
unit session-5.scope yes /user.slice/user-1000.slice/session-5.scope
unit run-u9.scope yes /lf.slice/lf-claude.slice/run-u9.scope
unit getty@tty2.service no /system.slice/system-getty.slice/getty@tty2.service "$T/unitfiles/getty@.service"
# ntfs-3g für eine Quelle, die lf-aufgabe während der Freigabe eingehängt hat (ntfs3g_ro), und
# Dienste, die nur so heißen: anderes Programm, andere Optionen, eine Datei als Quelle, ein
# Gerät, das der Kernel nicht kennt, ein Name, der nicht zum Einhängepunkt passt.
NT='lf-ntfs3g-mnt-lf\x2dimage-sdb1.service'
ntfs() { unit "$1" yes "/system.slice/$1" "" "{ path=$2 ; argv[]=$2 -o $3 $4 $5 ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"; }
ntfs "$NT" /usr/bin/ntfs-3g ro,nodev,nosuid,noexec,recover /dev/sdb1 /mnt/lf-image/sdb1
ntfs 'lf-ntfs3g-mnt-lf\x2dimage-sdb2.service' /usr/bin/bash ro,nodev,nosuid,noexec,recover /dev/sdb1 /mnt/lf-image/sdb2
ntfs 'lf-ntfs3g-mnt-lf\x2dimage-sdb3.service' /usr/bin/ntfs-3g ro,dev,suid,exec /dev/sdb1 /mnt/lf-image/sdb3
ntfs 'lf-ntfs3g-mnt-lf\x2dimage-sdb4.service' /usr/bin/ntfs-3g ro,nodev,nosuid,noexec,recover /var/lib/lf-claude/x.img /mnt/lf-image/sdb4
ntfs 'lf-ntfs3g-mnt-lf\x2dimage-sdb5.service' /usr/bin/ntfs-3g ro,nodev,nosuid,noexec,recover /dev/sdz9 /mnt/lf-image/sdb5
ntfs lf-ntfs3g-x.service /usr/bin/ntfs-3g ro,nodev,nosuid,noexec,recover /dev/sdb1 /mnt/lf-image/sdb6
printf '1\n2\n' >"$T/atq"
echo "* * * * * root true" >"$T/cron.d/neu"
touch "$T/linger/lf-claude"
# Prozesse in den cgroups von Claude
Q1=$(spawn) Q2=$(spawn) Q3=$(spawn) Q4=$(spawn) Q5=$(spawn) Q6=$(spawn) Q7=$(spawn) Q8=$(spawn)
# abgekoppelt, ohne Umgebung von sudo: nur an der cgroup zu erkennen
fake "$Q1" 0 0 1 "" "sleep 300"
# Claude selbst
fake "$Q2" 1001 1001 1 "" "claude"
# sudo, das Claude als lf-claude gestartet hat (claude_scope)
fake "$Q3" 0 0 1 "" "sudo -u lf-claude -H sh -c x" "$T/bin/sudo"
# Job der Grundregel: bash mit lf-aufgabe, von sudo gestartet, und sein Kind
fake 4194399201 0 0 1 "" "sudo /usr/local/bin/lf-aufgabe einhaengen /dev/sdb1" "$T/bin/sudo"
fake "$Q4" 0 0 4194399201 "" "/bin/bash /usr/local/bin/lf-aufgabe einhaengen /dev/sdb1" /usr/bin/bash
fake "$Q5" 0 0 "$Q4" "" "mount -o ro /dev/sdb1 /mnt"
# sieht aus wie lf-aufgabe, kommt aber nicht von sudo
fake "$Q6" 0 0 1 "" "/bin/bash /usr/local/bin/lf-aufgabe x" /usr/bin/bash
# chrome-sandbox von Claude Desktop
fake "$Q7" 1001 0 1 "" "/opt/claude/chrome-sandbox --type=zygote" /opt/claude/chrome-sandbox
# root in der Benutzer-Slice von lf-claude
fake "$Q8" 0 0 1 "" "sleep 300"
# mit der Freigabe als ein anderer Benutzer gestartet, in der angehaltenen cgroup: TERM käme
# erst nach dem Auftauen an
Q10=$(spawn_noterm)
fake "$Q10" 1000 1000 1 "SUDO_USER=lf-claude|SUDO_COMMAND=/usr/bin/sleep 300" "sleep 300"
printf '%s\n' "$Q1" "$Q2" "$Q3" "$Q4" "$Q5" "$Q6" "$Q7" "$Q10" >"$CG/cli.scope/cgroup.procs"
echo "$Q8" >"$CGU/cgroup.procs"
bash "$F" aus >"$T/out" 2>&1
RC=$?
check "Regel weg" '[[ $RC == 0 && ! -e $RULE ]]'
check "jeder root-Prozess in den cgroups von Claude ist beendet, auch abgekoppelt und in der Benutzer-Slice" '! kill -0 "$Q1" 2>/dev/null && ! kill -0 "$Q6" 2>/dev/null && ! kill -0 "$Q8" 2>/dev/null && grep -q "beendet: $Q1 sleep 300" "$LOG"'
check "mit der Freigabe gestartet, in der angehaltenen cgroup: gleich KILL, ohne auf TERM zu warten" '! kill -0 "$Q10" 2>/dev/null && grep -q "beendet: $Q10 sleep 300 (KILL, angehalten)" "$LOG"'
check "Claude selbst, sudo, Jobs der Grundregel und chrome-sandbox laufen weiter" 'kill -0 "$Q2" 2>/dev/null && kill -0 "$Q3" 2>/dev/null && kill -0 "$Q4" 2>/dev/null && kill -0 "$Q5" 2>/dev/null && kill -0 "$Q7" 2>/dev/null'
check "neue Einheiten und Timer sind gestoppt" 'grep -qx "kill -s KILL run-u7.service" "$T/systemctl.log" && grep -qx "stop run-u7.service" "$T/systemctl.log" && grep -qx "stop boese.timer" "$T/systemctl.log"'
check "Rettungen, Anmeldungen des Technikers, Claudes Sitzung und ältere Einheiten bleiben, auch nur neu gestartet" '! grep -qE "^(stop|kill -s KILL|freeze) (lf-claude-rettung-sdb.service|session-5.scope|run-u9.scope|getty@tty2.service|a.service|run-u6.service|c.service)$" "$T/systemctl.log"'
check "unter einem Namen von vorher neu angelegt oder mit neuer Ergänzung neu gestartet: gestoppt" 'grep -qx "stop run-u5.service" "$T/systemctl.log" && grep -qF "beendet: Einheit run-u5.service" "$LOG" && grep -qx "stop b.service" "$T/systemctl.log"'
check "Ergänzung, deren Pfad systemctl nicht ausgibt, oder gelöschte Unit-Datei: gestoppt" 'grep -qx "stop e.service" "$T/systemctl.log" && grep -qx "stop f.service" "$T/systemctl.log"'
check "ntfs-3g einer nur lesend eingehängten Quelle bleibt, die Quelle verschwindet nicht (GHSA-799j-44qx-x7xj)" '! grep -qxF -e "stop $NT" -e "kill -s KILL $NT" -e "freeze $NT" "$T/systemctl.log" && ! grep -qF "beendet: Einheit $NT" "$LOG"'
check "Dienste, die nur wie ntfs-3g heißen, sind gestoppt" 'n=0; for u in sdb2 sdb3 sdb4 sdb5; do grep -qxF "stop lf-ntfs3g-mnt-lf\x2dimage-$u.service" "$T/systemctl.log" && n=$((n + 1)); done; grep -qxF "stop lf-ntfs3g-x.service" "$T/systemctl.log" && ((n == 4))'
check "der neue at-Auftrag ist entfernt, der alte bleibt" 'grep -qx 2 "$T/atrm.log" && ! grep -qx 1 "$T/atrm.log"'
check "die neue cron-Datei ist gesperrt, nicht gelöscht; die alte bleibt" '[[ -f $T/cron.d/neu.lf-gesperrt && ! -e $T/cron.d/neu && -f $T/cron.d/alt ]]'
check "linger für lf-claude ist aufgehoben" '[[ ! -e $T/linger/lf-claude ]] && grep -qx "disable-linger lf-claude" "$T/loginctl.log"'
check "Reihenfolge: anhalten, Regel, Einheiten, root-Prozesse, weiterlaufen" 'a=$(line "Claude angehalten") u=$(line "beendet: Einheit run-u7.service") r=$(line "Regel entfernt") k=$(line "beendet: $Q1 ") w=$(line "Claude läuft weiter"); [[ -n $a && -n $u && -n $r && -n $k && -n $w ]] && ((a < r && r < u && u < k && k < w))'
check "die cgroups von Claude laufen danach weiter" '[[ $(cat "$CG/cgroup.freeze") == 0 && $(cat "$CGU/cgroup.freeze") == 0 ]]'
check "danach: status aus" '[[ $(bash "$F" status) == aus ]]'

echo "status ohne Regel, mit Rückstand:"
Q9=$(spawn)
fake "$Q9" 0 0 1 "" "sleep 300"
echo "$Q9" >>"$CG/cli.scope/cgroup.procs"
check "root-Prozess bei Claude: an, Rückstand, Neustart empfohlen" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (root-Prozesse bei Claude: $Q9 ), Neustart empfohlen" && $(bash "$F" zeile </dev/null) == ACHTUNG* ]]'
kill "$Q9" 2>/dev/null
sed -i "/^$Q9\$/d" "$CG/cli.scope/cgroup.procs"
echo "lf-claude ALL=(ALL) NOPASSWD: ALL" >"$T/sudoers.d/zz-neu"
check "neue sudo-Datei: an, Rückstand" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (sudo-Datei neu oder geändert: $T/sudoers.d/zz-neu), Neustart empfohlen" ]]'
mv "$T/sudoers.d/zz-neu" "$T/sudoers.d/zz.neu"
check "Namen mit Punkt liest sudo nicht: kein Rückstand" '[[ $(bash "$F" status) == aus ]]'
rm -f "$T/sudoers.d/zz.neu"
echo "[{\"next\": $(((NOW + 600) * 1000000)), \"unit\": \"lf-claude-freigabe-ende.timer\"}]" >"$T/timers.json"
check "Regel fehlt, Timer läuft: an, Rückstand" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (Regel fehlt, Timer bis $(date -d "@$((NOW + 600))" +%H:%M)), Neustart empfohlen" ]]'
rm -f "$T/timers.json"
# Nach dem sauberen Ende oben kommt eine spätere Einheit (etwa systemd-run für ein neues "an")
# nicht aus der Freigabe.
unit run-u11.service yes /system.slice/run-u11.service
check "nach einem sauberen Ende ist der Schnappschuss der Einheiten weg, eine spätere Einheit ist kein Rückstand" '[[ ! -e $SNAP/units && -e $SNAP/sudoers && $(bash "$F" status) == aus ]]'
sed -i 's/^ActiveState=.*/ActiveState=inactive/' "$T/unit/run-u11.service"
touch "$T/linger/lf-claude"
check "linger für lf-claude: an, Rückstand" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (linger: lf-claude), Neustart empfohlen" ]]'
rm -f "$T/linger/lf-claude"
check "alles aufgeräumt: aus" '[[ $(bash "$F" status) == aus ]]'
kill "$Q1" "$Q2" "$Q3" "$Q4" "$Q5" "$Q6" "$Q7" "$Q8" 2>/dev/null
kill -KILL "$Q10" 2>/dev/null
: >"$CG/cli.scope/cgroup.procs"
: >"$CGU/cgroup.procs"
rm -rf "$T/proc/"[0-9]*

echo "Rückstände:"
bash "$F" an 30 >"$T/out" 2>&1
# Während der Freigabe eingerichtet: eine zweite sudo-Regel und die Gruppe sudo
sudo_l "    (ALL : ALL) NOPASSWD: ALL"
echo "lf-claude render sudo" >"$T/groups"
bash "$F" aus >"$T/out" 2>&1
check "status bleibt an, mit Rückstand und Neustart-Empfehlung" '[[ $(bash "$F" status) == "an: Rückstand"*"Neustart empfohlen" && $(bash "$F" zeile </dev/null) == ACHTUNG* ]]'
check "das Protokoll warnt und nennt Regel und Gruppe" 'grep "WARNUNG: lf-claude darf nach der Freigabe" "$LOG" | grep -q "NOPASSWD: ALL.*Gruppen: lf-claude render sudo"'
check "bei einem Rückstand bleibt der Schnappschuss der Einheiten" '[[ -f $SNAP/units ]]'
# Nach dem Ende mit Rückstand entstanden (etwa durch das, was root dort eingerichtet hat)
unit run-u12.service yes /system.slice/run-u12.service
sudo_l
echo "lf-claude render" >"$T/groups"
bash "$F" ablauf >"$T/out" 2>&1
check "ohne Rückstand: nach dem Ablauf wieder aus" '[[ $(bash "$F" status) == aus && ! -e $T/run/claude-freigabe-rueckstand ]] && grep -q "abgelaufen" "$LOG"'
check "das nächste Ende prüft weiter gegen den Schnappschuss, erst ein sauberes Ende löscht ihn" 'grep -qx "stop run-u12.service" "$T/systemctl.log" && [[ ! -e $SNAP/units ]]'

echo "Hinweise für Techniker und Claude:"
check "der Freigabe-Dialog sagt, dass das Ende auch laufende root-Jobs von Claude beendet" 'grep -q "Am Ende der Freigabe beendet Leuchtfeuer, was Claude damit als root gestartet hat, auch mitten im Schreiben." rescue/lib/claude.sh'
check "Dialog und Anleitung: sicher endet root-Zugriff nur mit einem Neustart" '(($(grep -c "Sicher endet root-Zugriff nur mit einem Neustart" rescue/lib/claude.sh) >= 4)) && grep -q "Sicher endet root-Zugriff aber nur mit einem Neustart" docs/anleitung.md'
check "Verlängern im Dialog: Rückfrage an der Konsole, eine Ablehnung wird gemeldet" 'grep -q "Rückfrage hier an der Konsole" rescue/lib/claude.sh && grep -q "Nicht verlängert. Details im Protokoll." rescue/lib/claude.sh'
check "Freischalten und Verlängern im Dialog laufen direkt am Terminal, nicht über run (sudo-rs, GHSA-799j-44qx-x7xj)" '! grep -q "run sudo lf-freigabe an" rescue/lib/claude.sh &&grep -qxF "	sudo lf-freigabe an \"\$1\" || rc=\$?" rescue/lib/claude.sh && grep -qF "claude_freigabe_an \"\$min\" ||" rescue/lib/claude.sh && grep -qF "if claude_freigabe_an 30; then" rescue/lib/claude.sh'
check "CLI und Desktop laufen in der Slice, die lf-freigabe am Ende prüft" '[[ $(sed -n "s/^CLAUDE_SLICE=//p" rescue/lib/claude.sh) == "$(sed -n "s/^SLICE=//p" rescue/bin/lf-freigabe)" ]] && grep -q "claude_scope sh -c" rescue/lib/claude.sh && grep -qF -- "--slice=\"\$CLAUDE_SLICE\"" rescue/lib/claude-desktop-start'
check "lf-freigabe lässt genau die ntfs-3g-Dienste gelten, die part_mount_ro startet (Name, Optionen, Einhängepunkt)" 'grep -qF "ntfs3g_ro ro,nodev,nosuid,noexec,recover \"\$part\" \"\$mp\"" rescue/lib/recover.sh && grep -qF "unit=\"lf-ntfs3g-\$(systemd-escape --path -- \"\$3\").service\"" rescue/lib/recover.sh && grep -qF -- "-o ro,nodev,nosuid,noexec,recover (/dev/[^ ]+) ($(sed -n "s/^LF_IMAGE_MNT=\"\(.*\)\"$/\1/p" rescue/lib/common.sh)/" rescue/bin/lf-freigabe && grep -qF "[[ \$1 == \"lf-ntfs3g-\$(systemd-escape --path -- \"\$mp\").service\" ]]" rescue/bin/lf-freigabe'
check "CLAUDE.md: lange Kopien nur über lf-aufgabe, nie direkt mit sudo" 'tr "\n" " " <rescue/claude/CLAUDE.md | grep -q "Lange Kopien (dd, ddrescue, partclone) startest du auch dann nur über lf-aufgabe, nie direkt mit sudo"'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
