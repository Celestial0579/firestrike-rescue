#!/usr/bin/env bash
# Unit-Test (GHSA-799j-44qx-x7xj): lf-freigabe beim Freischalten und am Ende einer Freigabe.
#   - status sagt "an", solange die Regel besteht, auch wenn sich die Uhr umgestellt hat; das
#     Ende kommt aus dem Timer.
#   - "an" erkennt lf-claude auch ohne SUDO_USER (sudo env -u SUDO_USER ...) an den Vorfahren.
#   - "aus" und der Ablauf beenden, was lf-claude mit der Freigabe als root gestartet hat, lassen
#     Jobs von lf-aufgabe und Prozesse des Technikers laufen und melden, was lf-claude danach
#     noch darf.
#
# Hier läuft nichts als root: Eine Kopie von lf-freigabe arbeitet mit eigenen Ordnern statt
# /etc/sudoers.d, /run/lf und /proc. sudo, systemctl, systemd-run, visudo, logger und id sind
# Attrappen. Beendet werden nur sleep-Prozesse, die der Test selbst startet.
set -u
cd "$(dirname "$0")/.." || exit 1
unset SUDO_USER SUDO_UID SUDO_COMMAND

T=$(mktemp -d)
mkdir -p "$T/bin" "$T/sudoers.d" "$T/run" "$T/proc"
F="$T/lf-freigabe"
sed -e "s|^PATH=.*|PATH=$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|" \
	-e "s|/etc/sudoers.d/|$T/sudoers.d/|g" -e "s|/run/lf|$T/run|g" -e "s|/proc/|$T/proc/|g" \
	-e "s|((EUID == 0))|((EUID == $(id -u)))|g" rescue/bin/lf-freigabe >"$F"

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
cat >"$T/bin/systemctl" <<MOCK
#!/bin/bash
echo "\$*" >>"$T/systemctl.log"
[[ \$1 == list-timers ]] && { cat "$T/timers.json" 2>/dev/null || echo "[]"; }
exit 0
MOCK
printf '#!/bin/bash\necho "$*" >>"%s/systemd-run.log"\n' "$T" >"$T/bin/systemd-run"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/visudo"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/logger"
chmod +x "$T/bin/"*

BASE="    (root) NOPASSWD: /usr/local/bin/lf-lesen, /usr/local/bin/lf-aufgabe"
sudo_l() { printf 'User lf-claude may run the following commands on test:\n%s\n' "$BASE" "$@" >"$T/sudo-l"; }
sudo_l
echo "lf-claude render" >"$T/groups"
LOG="$T/run/claude-aufgaben.log"
RULE="$T/sudoers.d/lf-claude-freigabe"

# fake PID RUID EUID PPID [UMGEBUNG] [BEFEHL]   Eintrag in der Attrappe von /proc. UMGEBUNG mit |
#   getrennt, BEFEHL mit Leerzeichen.
fake() {
	mkdir -p "$T/proc/$1"
	printf 'Name:\tx\nState:\tS (sleeping)\nPPid:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$4" "$2" "$3" "$3" "$3" >"$T/proc/$1/status"
	printf '%s' "${5:-}" | tr '|' '\0' >"$T/proc/$1/environ"
	printf '%s' "${6:-x}" | tr ' ' '\0' >"$T/proc/$1/cmdline"
	local cmd=${6:-x}
	cmd=${cmd%% *}
	printf '%s\n' "${cmd##*/}" >"$T/proc/$1/comm"
}
# spawn   Startet sleep losgelöst (nicht als Kind dieses Tests) und gibt die PID aus.
spawn() { (sleep 300 >/dev/null 2>&1 &
	echo $!); }

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
bash "$F" an 30 >"$T/out" 2>&1
RC=$?
check "vom Techniker: frei, mit Ablauf, im Protokoll mit seinem Namen" '[[ $RC == 0 && -e $RULE ]] && grep -q -- "--on-active=30min" "$T/systemd-run.log" && grep -q "freigegeben von rescue" "$LOG"'
rm -rf "$T/proc/$$" "$T/proc/4194399001"

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
rm -rf "$T/proc/"*

echo "Rückstände:"
echo "lf-claude ALL=(ALL:ALL) NOPASSWD: ALL" >"$RULE"
# Während der Freigabe eingerichtet: eine zweite sudo-Regel und die Gruppe sudo
sudo_l "    (ALL : ALL) NOPASSWD: ALL"
echo "lf-claude render sudo" >"$T/groups"
bash "$F" aus >"$T/out" 2>&1
check "status bleibt an, mit Rückstand und Neustart-Empfehlung" '[[ $(bash "$F" status) == "an: Rückstand"*"Neustart empfohlen" && $(bash "$F" zeile </dev/null) == ACHTUNG* ]]'
check "das Protokoll warnt und nennt Regel und Gruppe" 'grep "WARNUNG: lf-claude darf nach der Freigabe" "$LOG" | grep -q "NOPASSWD: ALL.*Gruppen: lf-claude render sudo"'
sudo_l
echo "lf-claude render" >"$T/groups"
bash "$F" ablauf >"$T/out" 2>&1
check "ohne Rückstand: nach dem Ablauf wieder aus" '[[ $(bash "$F" status) == aus && ! -e $T/run/claude-freigabe-rueckstand ]] && grep -q "abgelaufen" "$LOG"'

echo "Hinweise für Techniker und Claude:"
check "der Freigabe-Dialog sagt, dass das Ende auch laufende root-Jobs von Claude beendet" 'grep -q "Am Ende der Freigabe beendet Leuchtfeuer, was Claude damit als root gestartet hat, auch mitten im Schreiben." rescue/lib/claude.sh'
check "CLAUDE.md: lange Kopien nur über lf-aufgabe, nie direkt mit sudo" 'tr "\n" " " <rescue/claude/CLAUDE.md | grep -q "Lange Kopien (dd, ddrescue, partclone) startest du auch dann nur über lf-aufgabe, nie direkt mit sudo"'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
