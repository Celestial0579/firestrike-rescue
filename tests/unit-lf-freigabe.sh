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
#     nur wenn Name, Programm, Optionen, Quelle und Einhängepunkt zusammenpassen und er sonst genau
#     so aussieht, wie systemd-run ihn anlegt: keine weiteren Befehle, keine Umgebung, Wurzel oder
#     Drop-ins, und der laufende Prozess ist genau dieses ntfs-3g (F12, je Eigenschaft ein Lockvogel).
#   - Ebenso eine Rettung, die lf-aufgabe retten oder fortsetzen startet (start_rescue): nur genau
#     so, wie systemd-run sie anlegt (auch Ein- und Ausgabe, Neustart, Abhängigkeiten, Arbeitsordner,
#     Gruppen, Slice, nur mit der Umgebung des Managers vom Freischalten; die Werte wie auf dem
#     ISO), und nur wenn lf-aufgabe pruefen-rettung die Argumente annimmt
#     und die Kette der Grundregel unverändert ist. Ein fremder Prozess in einem Dienst, der bleibt,
#     wird beendet (F16).
#   - Die Umgebung des systemd-Managers ist am Ende wie beim Freischalten, ins Protokoll kommen nur
#     die Namen; was sich nicht zurücksetzen lässt, ist ein Rückstand, ebenso eine Umgebung, die
#     sich beim Freischalten nicht lesen ließ. Jeder Dienst, den
#     lf-freigabe, recover.sh und lf-aufgabe starten, erbt LD_PRELOAD und Co. nicht (F13).
#   - Wege zu root ohne laufenden Prozess sind ein Rückstand: geänderte Konten, PAM, polkit, SSH,
#     modprobe, setuid-Dateien, capabilities, Dateien unter /usr, Kernel-Einstellungen und
#     Einhängungen (auch über lf-lesen), der Inhalt der Credentials von Diensten (getty und login
#     lesen daraus login.noauth und agetty.autologin) und ihre Ablagen. Eine neue ld.so.preload wird
#     gesperrt, eine geänderte Kette der Grundregel (lf-aufgabe) sperrt die Grundregel bis zum
#     Neustart (F14).
#   - Nach jeder Freigabe sagt status bis zum Neustart "aus, Neustart empfohlen (…)" (F15).
#
# Hier läuft nichts als root: Eine Kopie von lf-freigabe arbeitet mit eigenen Ordnern statt
# /etc/sudoers.d, /run/lf, /proc und /sys/fs/cgroup, und mit einer eigenen Wurzel (WROOT) für die
# Dateien, die das Ende prüft. sudo, systemctl, systemd-run, loginctl, atq, atrm, visudo, logger,
# id, busctl, getcap und lf-aufgabe sind Attrappen. Beendet werden nur sleep-Prozesse, die der
# Test selbst startet.
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
echo "lf-claude ALL=(root) NOPASSWD: /usr/local/bin/lf-lesen, /usr/local/bin/lf-aufgabe" >"$T/sudoers.d/lf-claude"
# Die Wurzel für die Pfade, die das Ende ohne laufenden Prozess prüft (WROOT): Konten, PAM, SSH,
# modprobe, die Kette der Grundregel und /usr. Dazu Kernel-Einstellungen in der Attrappe von /proc.
W="$T/w"
mkdir -p "$W/etc/pam.d" "$W/etc/ssh" "$W/etc/modprobe.d" "$W/root/.ssh" "$W/usr/local/bin" "$W/usr/local/sbin" \
	"$W/usr/local/lib/lf" "$W/usr/bin" "$W/usr/lib/x86_64-linux-gnu/security" "$W/var/tmp" "$W/run" "$W/sys/kernel" \
	"$T/proc/sys/kernel" "$T/proc/sys/fs/binfmt_misc"
for f in passwd shadow group gshadow ld.so.conf ld.so.cache sudo.conf nsswitch.conf; do echo "$f" >"$W/etc/$f"; done
echo "auth required pam_unix.so" >"$W/etc/pam.d/common-auth"
echo "PermitRootLogin no" >"$W/etc/ssh/sshd_config"
for f in lf-aufgabe lf-lesen lf-rescue-run lf-freigabe; do printf '#!/bin/bash\n# %s\n' "$f" >"$W/usr/local/bin/$f"; done
ln -s lf-aufgabe "$W/usr/local/bin/frs-aufgabe"
echo "# common" >"$W/usr/local/lib/lf/common.sh"
# Wie die Claude-CLI: zu groß für eine Prüfsumme, es zählen Größe und ctime.
truncate -s 17M "$W/usr/local/lib/lf/claude-cli"
for f in bash systemd-run ntfs-3g; do echo "$f" >"$W/usr/bin/$f"; done
# Wie auf dem ISO sind sudo und env Verknüpfungen: sudo-rs über alternatives, env aus uutils.
mkdir -p "$W/usr/lib/cargo/bin/coreutils" "$W/etc/alternatives"
echo sudo >"$W/usr/lib/cargo/bin/sudo" && echo env >"$W/usr/lib/cargo/bin/coreutils/env"
ln -s "$W/usr/lib/cargo/bin/sudo" "$W/etc/alternatives/sudo" && ln -s "$W/etc/alternatives/sudo" "$W/usr/bin/sudo"
ln -s ../lib/cargo/bin/coreutils/env "$W/usr/bin/env"
CS=$(readlink -f "$W/usr/bin/sudo") CE=$(readlink -f "$W/usr/bin/env")
echo "|/usr/lib/systemd/systemd-coredump %P" >"$T/proc/sys/kernel/core_pattern"
echo /sbin/modprobe >"$T/proc/sys/kernel/modprobe"
: >"$W/sys/kernel/uevent_helper"
echo enabled >"$T/proc/sys/fs/binfmt_misc/status"
: >"$T/proc/sys/fs/binfmt_misc/register"
# Credentials von Diensten wie auf dem ISO: tmpfs, die Einhängung rw, ihr Superblock ro. Dazu eine
# in einem anderen Dateisystem, die das Ende nicht lesen darf (sie könnte hängen).
CRED=$W/run/credentials
CRED_LINES=("47 30 0:41 / $CRED/getty@tty1.service rw,nosuid,nodev,noexec,relatime,nosymfollow shared:7 - tmpfs none ro,size=1024k,nr_inodes=1024,mode=700"
	"48 30 0:42 / $CRED/getty@tty2.service rw,nosuid,nodev,noexec,relatime,nosymfollow shared:8 - tmpfs none ro,size=1024k,nr_inodes=1024,mode=700"
	"49 30 0:43 / $CRED/systemd-journald.service rw,nosuid,nodev,noexec,relatime,nosymfollow shared:10 - tmpfs none ro,size=1024k,nr_inodes=1024,mode=700"
	"50 30 0:44 / $CRED/fremd.service rw,nosuid,nodev,noexec,relatime shared:11 - fuse.x x rw")
mkdir -p "$CRED/getty@tty1.service" "$CRED/getty@tty2.service" "$CRED/systemd-journald.service" "$CRED/fremd.service"
echo rescue >"$CRED/getty@tty1.service/agetty.autologin"
# pid1   PID 1 in der Attrappe von /proc: Mount-Namensraum und Einhängungen (WROOT beschreibbar und
#   ohne nosuid, darunter ein tmpfs mit nosuid, die Credentials). Nach dem Aufräumen von /proc neu
#   angelegt.
pid1() {
	mkdir -p "$T/proc/1/ns"
	: >>"$T/proc/1/ns/mnt"
	printf '%s\n' "22 1 0:30 / $W rw,relatime shared:1 - overlay overlay rw" \
		"30 22 0:40 / $W/run rw,nosuid,nodev shared:5 - tmpfs tmpfs rw" "${CRED_LINES[@]}" >"$T/proc/1/mountinfo"
}
cleanproc() {
	rm -rf "$T/proc/"[0-9]*
	pid1
}
pid1
# Die Umgebung des systemd-Managers (busctl, systemctl set-environment).
echo '["LANG=C.UTF-8","PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]' >"$T/menv.json"
ENV_UNSAFE=$(sed -n 's/^ENV_UNSAFE="\(.*\)"$/\1/p' rescue/bin/lf-freigabe)
F="$T/lf-freigabe"
sed -e "s|^PATH=.*|PATH=$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|" \
	-e "s|/etc/sudoers.d/|$T/sudoers.d/|g" -e "s|^SUDOERS=.*|SUDOERS=$T/sudoers|" -e "s|/run/lf|$T/run|g" \
	-e "s|/proc/|$T/proc/|g" -e "s|^SUDO_EXE=.*|SUDO_EXE=$T/bin/sudo|" -e "s|^CGROOT=.*|CGROOT=$T/cg|" \
	-e "s|^LINGER=.*|LINGER=$T/linger|" -e "s|^CRON_PATHS=.*|CRON_PATHS=($T/cron.d)|" -e "s|^TTY=.*|TTY=$T/tty|" \
	-e "s|^SYS_BLOCK=.*|SYS_BLOCK=$T/sysblock|" -e "s|^NTFS3G=.*|NTFS3G=$T/bin/ntfs-3g|" \
	-e "s|^WROOT=.*|WROOT=$W|" -e "s|^AUFGABE=.*|AUFGABE=$T/bin/lf-aufgabe|" -e "s|^SCAN_TIMEOUT=.*|SCAN_TIMEOUT=5|" \
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
		# Nur die Eigenschaften, nach denen -p fragt (wie systemctl).
		want=" "
		while ((\$#)); do [[ \$1 == -p ]] && { want+="\${2//,/ } "; shift; }; shift; done
		while IFS= read -r l; do [[ \$want == *" \${l%%=*} "* ]] && printf '%s\n' "\$l"; done <"$T/unit/\$u" 2>/dev/null
	fi
	;;
stop) [[ -f "$T/unit/\$u" ]] && sed -i 's/^ActiveState=.*/ActiveState=inactive/' "$T/unit/\$u" ;;
# Mit der Datei menv-fest lässt sich die Umgebung nicht ändern (Rückstand).
set-environment | unset-environment)
	[[ -e "$T/menv-fest" ]] && exit 1
	c=\$1
	shift
	[[ \$1 == -- ]] && shift
	for a in "\$@"; do
		jq -c --arg a "\$a" --arg c "\$c" '[.[] | select(split("=")[0] != (\$a | split("=")[0]))] + (if \$c == "set-environment" then [\$a] else [] end)' "$T/menv.json" >"$T/menv.neu" &&
			mv "$T/menv.neu" "$T/menv.json"
	done
	;;
esac
exit 0
MOCK
# Mit der Datei menv-kaputt antwortet busctl nicht.
cat >"$T/bin/busctl" <<MOCK
#!/bin/bash
[[ -e "$T/menv-kaputt" ]] && exit 1
[[ "\$*" == "--json=short get-property org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager Environment" ]] || exit 1
jq -c '{type: "as", data: .}' "$T/menv.json"
MOCK
# Hängende Zugriffe (wie FUSE ohne Antwort): sha256sum für eine Datei haengt, getcap für
# haengt-cap, lf-aufgabe für den Fall ok-haengt. Die PIDs stehen in haengt.pids.
cat >"$T/bin/sha256sum" <<MOCK
#!/bin/bash
for f in "\$@"; do [[ \$f == */haengt ]] && { echo \$\$ >>"$T/haengt.pids"; exec sleep 3600; }; done
exec $(command -v sha256sum) "\$@"
MOCK
# getcap: capabilities nur für Dateien, die in caps stehen.
cat >"$T/bin/getcap" <<MOCK
#!/bin/bash
for f in "\$@"; do [[ \$f == */haengt-cap ]] && { echo \$\$ >>"$T/haengt.pids"; exec sleep 3600; }; done
for f in "\$@"; do grep -qxF -- "\$f" "$T/caps" 2>/dev/null && echo "\$f cap_setuid=ep"; done
exit 0
MOCK
# lf-aufgabe pruefen-rettung: nimmt nur Fälle unter /mnt/lf-target/LF/ an, deren Name mit ok
# beginnt, und die Quelle /dev/sdb.
cat >"$T/bin/lf-aufgabe" <<MOCK
#!/bin/bash
echo "\$*" >>"$T/aufgabe.log"
[[ \$2 == */ok-haengt ]] && { echo \$\$ >>"$T/haengt.pids"; exec sleep 3600; }
[[ \$1 == pruefen-rettung && \$# == 3 && \$2 == /mnt/lf-target/LF/ok* && \$3 == /dev/sdb ]]
MOCK
printf '#!/bin/bash\necho "$*" >>"%s/systemd-run.log"\n' "$T" >"$T/bin/systemd-run"
printf '#!/bin/bash\necho "$*" >>"%s/loginctl.log"\n[[ $1 == disable-linger ]] && rm -f "%s/linger/$2"\nexit 0\n' "$T" "$T" >"$T/bin/loginctl"
printf '#!/bin/bash\ncat "%s/atq" 2>/dev/null\n' "$T" >"$T/bin/atq"
printf '#!/bin/bash\necho "$*" >>"%s/atrm.log"\n' "$T" >"$T/bin/atrm"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/visudo"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/logger"
# Das Programm ntfs-3g (Ziel von /proc/PID/exe des echten Dienstes) und ein anderes.
printf '#!/bin/bash\nexit 0\n' >"$T/bin/ntfs-3g"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/anderes"
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
	# Wie der Kernel: jede Variable mit \0 am Ende.
	if [[ -n ${5:-} ]]; then printf '%s|' "$5" | tr '|' '\0'; fi >"$T/proc/$1/environ"
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
# aus_n   Sagt status "aus, Neustart empfohlen (letzte Freigabe bis HH:MM)" (F15)?
aus_n() { [[ $(bash "$F" status) =~ ^aus,\ Neustart\ empfohlen\ \(letzte\ Freigabe\ bis\ [0-9]{2}:[0-9]{2}\)$ ]]; }

echo "status:"
check "ohne Regel: aus" '[[ $(bash "$F" status) == aus ]]'
bash "$F" aus >"$T/out" 2>&1
check "aus ohne Freigabe: weiter aus, kein Hinweis auf einen Neustart" '[[ $(bash "$F" status) == aus && ! -e $T/run/claude-freigabe-zuletzt ]]'
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
check "der Dienst des Ablaufs erbt LD_PRELOAD und Co. nicht vom Manager (F13)" 'grep -qF -- "-p Type=oneshot -p UnsetEnvironment=$ENV_UNSAFE /usr/local/bin/lf-freigabe ablauf" "$T/systemd-run.log" && [[ $ENV_UNSAFE == "LD_PRELOAD "*" PS4" ]]'
check "Freischalten hält Manager-Umgebung, Dateien, Kette, Einhängungen und Kernel-Einstellungen fest" 'grep -qxF "\"LANG=C.UTF-8\"" "$SNAP/menv" && grep -q " $W/etc/shadow$" "$SNAP/files" && grep -qE "^[0-9a-f]{64}  $W/usr/local/bin/lf-aufgabe$" "$SNAP/chain" && grep -qE "^gross:17825792:[0-9.]+  $W/usr/local/lib/lf/claude-cli$" "$SNAP/chain" && grep -qxF "art:l:lf-aufgabe  $W/usr/local/bin/frs-aufgabe" "$SNAP/chain" && grep -qE "^[0-9a-f]{64}  $CS$" "$SNAP/chain" && grep -qE "^[0-9a-f]{64}  $CE$" "$SNAP/chain" && grep -qxF "art:l:$W/etc/alternatives/sudo  $W/usr/bin/sudo" "$SNAP/chain" && grep -q " $W rw" "$SNAP/mounts" && grep -qxF "$T/proc/sys/kernel/core_pattern=|/usr/lib/systemd/systemd-coredump %P " "$SNAP/knobs" && [[ -e $SNAP/zeit ]]'
check "Freischalten hält den Inhalt der Credentials fest, nur für root lesbar; ein anderes Dateisystem dort liest es nicht" 'grep -qE "^$CRED/getty@tty1.service [0-9a-f]{64}$" "$SNAP/creds" && grep -qxF "$CRED/fremd.service art:fuse.x" "$SNAP/creds" && [[ $(stat -c %a "$SNAP/creds") == 600 ]]'
check "die Schnappschüsse, die comm vergleicht, sind ganzzeilig sortiert (wie lf-freigabe: C.UTF-8)" '(for f in units at cron sudoers menv chain knobs mounts; do LC_ALL=C.UTF-8 sort -c "$SNAP/$f" 2>/dev/null || exit 1; done)'

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
check "aus aus der cgroup von Claude: das Ende läuft als eigener Dienst, ohne LD_PRELOAD und Co." 'grep -qF -- "--unit=lf-claude-freigabe-ende-aus -p UnsetEnvironment=$ENV_UNSAFE /usr/local/bin/lf-freigabe aus" "$T/systemd-run.log" && [[ -e $RULE ]]'
self /user.slice/user-1000.slice/session-1.scope
rm -f "$T/timers.json"
cleanproc

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
check "schon beim Freischalten gibt es die Marke für den Hinweis auf einen Neustart, mit dem geplanten Ende (F15)" '[[ -s $T/run/claude-freigabe-bis && $(cat "$T/run/claude-freigabe-zuletzt") == "$(cat "$T/run/claude-freigabe-bis")" ]]'
PLAN=$(cat "$T/run/claude-freigabe-bis")
bash "$F" aus >"$T/out" 2>&1
RC=$?
check "nach dem Ende nennt die Marke das tatsächliche Ende, nicht das geplante" '(($(cat "$T/run/claude-freigabe-zuletzt") < PLAN))'
check "Regel weg, status aus mit Hinweis auf einen Neustart (F15)" '[[ $RC == 0 && ! -e $RULE ]] && aus_n && [[ $(bash "$F" status) == *"bis $(date -d "@$(cat "$T/run/claude-freigabe-zuletzt")" +%H:%M))" ]]'
check "die Statuszeile von Claude Code nennt den Neustart" '[[ $(bash "$F" zeile </dev/null) == "Leuchtfeuer: Claude arbeitet mit lf-lesen und lf-aufgabe, Neustart empfohlen (letzte Freigabe bis "* ]]'
check "beendet, was lf-claude mit der Freigabe gestartet hat, auch ohne SUDO_USER und als anderer Benutzer" '! kill -0 "$P1" 2>/dev/null && ! kill -0 "$P4" 2>/dev/null && ! kill -0 "$P6" 2>/dev/null && grep -q "beendet: $P1 sleep 300" "$LOG" && grep -q "beendet: $P4" "$LOG"'
check "Jobs von lf-aufgabe, Prozesse des Technikers und setuid-Programme ohne sudo laufen weiter" 'kill -0 "$P2" 2>/dev/null && kill -0 "$P3" 2>/dev/null && kill -0 "$P5" 2>/dev/null'
kill "$P2" "$P3" "$P5" "$P1" "$P4" "$P6" 2>/dev/null
cleanproc

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
# Nur der Name des eigenen Endes: gestoppt, ausgenommen ist nur der Dienst, in dem das Ende läuft.
unit lf-claude-freigabe-ende-aus.service yes /system.slice/lf-claude-freigabe-ende-aus.service "" "{ path=/usr/local/bin/lf-freigabe ; argv[]=/usr/local/bin/lf-freigabe aus ; }"
# Nur der Name einer Rettung (F16: gestoppt)
unit lf-claude-rettung-sdb.service yes /system.slice/lf-claude-rettung-sdb.service "" "{ path=/usr/local/bin/lf-rescue-run ; argv[]=/usr/local/bin/lf-rescue-run /dev/sdb ; }"
unit session-5.scope yes /user.slice/user-1000.slice/session-5.scope
unit run-u9.scope yes /lf.slice/lf-claude.slice/run-u9.scope
unit getty@tty2.service no /system.slice/system-getty.slice/getty@tty2.service "$T/unitfiles/getty@.service"
# Was systemd-run für ntfs3g_ro und start_rescue sonst setzt, wie auf dem ISO gemessen. Requires gibt
# systemctl in keiner festen Reihenfolge aus.
SAME=$'StandardInput=null\nStandardOutput=journal\nStandardError=inherit\nRestart=no\nRestartMode=normal\nUMask=0022\nSlice=system.slice\nSuccessAction=none\nFailureAction=none\nRequires=system.slice sysinit.target'
# genv PID EINHEIT   Die Umgebung, mit der systemd einen Dienst startet, der während der Freigabe
#   entsteht: die des Managers beim Freischalten (SNAP/menv) und was systemd je Dienst setzt.
genv() {
	printf '%s|USER=root|INVOCATION_ID=%032x|JOURNAL_STREAM=8:4711|SYSTEMD_EXEC_PID=%s|MEMORY_PRESSURE_WATCH=/sys/fs/cgroup/system.slice/%s/memory.pressure|MEMORY_PRESSURE_WRITE=c29tZSAyMDAwMDAgMjAwMDAwMAA=' \
		"$(jq -rs 'join("|")' "$SNAP/menv")" "$1" "$1" "$2"
}
# ntfs-3g für eine Quelle, die lf-aufgabe während der Freigabe eingehängt hat (ntfs3g_ro), und
# Dienste, die nur so heißen: anderes Programm, andere Optionen, eine Datei als Quelle, ein
# Gerät, das der Kernel nicht kennt, ein Name, der nicht zum Einhängepunkt passt.
NT='lf-ntfs3g-mnt-lf\x2dimage-sdb1.service'
# ntfs NAME PROGRAMM OPTIONEN QUELLE EINHÄNGEPUNKT   Ein Dienst, wie systemd-run ihn für ntfs3g_ro
#   anlegt (mit UnsetEnvironment wie in recover.sh), mit laufendem ntfs-3g in der Attrappe von
#   /proc: allein in seiner cgroup, Wurzel /, dieselben Einhängungen wie PID 1, ohne LD_-Variablen.
#   NP ist die PID des Prozesses.
NP=4194399300
ntfs() {
	NP=$((NP + 1))
	unit "$1" yes "/system.slice/$1" "/run/systemd/transient/$1" "{ path=$2 ; argv[]=$2 -o $3 $4 $5 ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
	printf 'Type=forking\nMainPID=%s\nUnsetEnvironment=%s\nEnvironment=\nRootDirectory=\nRootImage=\nUser=\nOnFailure=\nOnSuccess=\nUpholds=\n%s\n' "$NP" "$ENV_UNSAFE" "$SAME" >>"$T/unit/$1"
	mkdir -p "$T/cg/system.slice/$1" "$T/proc/1/ns"
	echo "$NP" >"$T/cg/system.slice/$1/cgroup.procs"
	: >>"$T/proc/1/ns/mnt"
	fake "$NP" 0 0 1 "$(genv "$NP" "$1")" "$2 -o $3 $4 $5" "$T/bin/ntfs-3g"
	ln -s / "$T/proc/$NP/root"
	mkdir -p "$T/proc/$NP/ns" && ln -s "$T/proc/1/ns/mnt" "$T/proc/$NP/ns/mnt"
}
# prop EINHEIT SCHLÜSSEL WERT   Setzt eine Eigenschaft in der Attrappe von systemctl.
prop() { { grep -v "^$2=" "$T/unit/$1"; printf '%s=%s\n' "$2" "$3"; } >"$T/unit/$1.neu" && mv "$T/unit/$1.neu" "$T/unit/$1"; }
ntfs "$NT" /usr/bin/ntfs-3g ro,nodev,nosuid,noexec,recover /dev/sdb1 /mnt/lf-image/sdb1
# Der echte Dienst mit Requires in der anderen Reihenfolge: bleibt trotzdem.
prop "$NT" Requires "sysinit.target system.slice"
# Lockvögel (F12): Name, Befehl und Prozess wie beim echten Dienst, aber eine Eigenschaft mehr oder
# ein Prozess, der nicht passt. Mit root angelegt, liefen sie nach dem Ende weiter als root.
SPOOFS=()
spoof() {
	local m=/mnt/lf-image/f12-$1
	SP="lf-ntfs3g-$(systemd-escape --path -- "$m").service"
	ntfs "$SP" /usr/bin/ntfs-3g ro,nodev,nosuid,noexec,recover /dev/sdb1 "$m"
	SPOOFS+=("$SP")
}
X="{ path=/bin/sh ; argv[]=/bin/sh -c /var/lib/lf-claude/x ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
spoof transient && prop "$SP" Transient no
spoof fragment && prop "$SP" FragmentPath "/etc/systemd/system/$SP"
spoof type && prop "$SP" Type simple
spoof dropin && prop "$SP" DropInPaths "/run/systemd/system/$SP.d/x.conf"
for k in ExecCondition ExecStartPre ExecStartPost ExecReload ExecStop ExecStopPost; do
	spoof "${k,,}" && prop "$SP" "$k" "$X"
done
spoof environment && prop "$SP" Environment "LD_PRELOAD=/var/lib/lf-claude/x.so"
spoof envfiles && prop "$SP" EnvironmentFiles "/var/lib/lf-claude/env (ignore_errors=no)"
spoof rootdir && prop "$SP" RootDirectory /var/lib/lf-claude/root
spoof rootimage && prop "$SP" RootImage /var/lib/lf-claude/root.img
spoof user && prop "$SP" User root
spoof onfailure && prop "$SP" OnFailure x.service
spoof onsuccess && prop "$SP" OnSuccess x.service
spoof upholds && prop "$SP" Upholds x.service
spoof execstart2 && prop "$SP" ExecStart "$(sed -n 's/^ExecStart=//p' "$T/unit/$SP")"$'\n'"ExecStart=$X"
spoof nopid && prop "$SP" MainPID 0
spoof exe && ln -sfn "$T/bin/anderes" "$T/proc/$NP/exe"
spoof root && ln -sfn "$T" "$T/proc/$NP/root"
spoof mntns && rm "$T/proc/$NP/ns/mnt" && : >"$T/proc/$NP/ns/mnt"
spoof ldpreload && printf 'PATH=/usr/bin\0LD_PRELOAD=/var/lib/lf-claude/x.so\0' >"$T/proc/$NP/environ"
spoof gconv && printf 'PATH=/usr/bin\0GCONV_PATH=/var/lib/lf-claude/gconv\0' >"$T/proc/$NP/environ"
spoof locpath && printf 'LOCPATH=/var/lib/lf-claude/locale\0PATH=/usr/bin\0' >"$T/proc/$NP/environ"
spoof argv && printf '%s\0' /usr/bin/ntfs-3g -o ro,nodev,nosuid,noexec,recover /dev/sdb1 /mnt/lf-image/f12-argv -o dev,suid >"$T/proc/$NP/cmdline"
spoof unsetenv && prop "$SP" UnsetEnvironment ""
spoof bashfunc && printf 'PATH=/usr/bin\0BASH_FUNC_x%%%%=() { :; }\0' >"$T/proc/$NP/environ"
# Eine Umgebung, die nicht vom Freischalten stammt (ein Ordner von root vorn in PATH), Ausgabe in
# eine Datei (F16).
spoof path && sed -z -i 's|^PATH=|PATH=/var/lib/lf-claude/bin:|' "$T/proc/$NP/environ"
spoof stdout && prop "$SP" StandardOutput "append:/usr/local/bin/lf-aufgabe"
# Ein laufender Prozess mit LD_PRELOAD neben ntfs-3g in der cgroup
spoof member && { NM=$(spawn); fake "$NM" 0 0 "$NP" "LD_PRELOAD=/var/lib/lf-claude/x.so" "sleep 300"; echo "$NM" >>"$T/cg/system.slice/$SP/cgroup.procs"; }
# Ein Kind von ntfs-3g mit einer Funktion für bash: Die Umgebung eines Kindes prüft nur unsafe_env.
spoof memberfunc && { NB=$(spawn); fake "$NB" 0 0 "$NP" "PATH=/usr/bin|BASH_FUNC_x%%=() { :; }" "sleep 300"; echo "$NB" >>"$T/cg/system.slice/$SP/cgroup.procs"; }
# Ein fremder Prozess in der cgroup des echten Dienstes: beendet, der Dienst bleibt (F16).
NF=$(spawn)
fake "$NF" 0 0 1 "PATH=/usr/bin" "sleep 300"
echo "$NF" >>"$T/cg/system.slice/$NT/cgroup.procs"
# Ein Prozess, den es nicht mehr gibt (noch in cgroup.procs gelesen), zählt nicht.
NX=$(spawn)
kill "$NX"
for _ in $(seq 50); do kill -0 "$NX" 2>/dev/null || break; sleep 0.1; done
echo "$NX" >>"$T/cg/system.slice/$NT/cgroup.procs"
# Rettungen (F16): eine, wie start_rescue sie anlegt, und Lockvögel.
# rescue NAME FALLORDNER QUELLE   Ein Dienst wie von start_rescue, mit laufendem lf-rescue-run (bash
#   mit dem Skript davor) in der Attrappe von /proc. RP ist die PID des Prozesses.
RP=4194399500
rescue() {
	RP=$((RP + 1))
	unit "$1" yes "/system.slice/$1" "/run/systemd/transient/$1" "{ path=/usr/local/bin/lf-rescue-run ; argv[]=/usr/local/bin/lf-rescue-run $2 $3 --no-pause ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
	printf 'Type=simple\nMainPID=%s\nUnsetEnvironment=%s\nEnvironment=\nRootDirectory=\nRootImage=\nUser=\nOnFailure=\nOnSuccess=\nUpholds=\n%s\n' "$RP" "$ENV_UNSAFE" "$SAME" >>"$T/unit/$1"
	mkdir -p "$T/cg/system.slice/$1" "$T/proc/1/ns"
	echo "$RP" >"$T/cg/system.slice/$1/cgroup.procs"
	fake "$RP" 0 0 1 "$(genv "$RP" "$1")" "bash /usr/local/bin/lf-rescue-run $2 $3 --no-pause" /usr/bin/bash
	ln -s / "$T/proc/$RP/root"
	mkdir -p "$T/proc/$RP/ns" && ln -s "$T/proc/1/ns/mnt" "$T/proc/$RP/ns/mnt"
}
# runit FALLORDNER   Der Name der Einheit wie in start_rescue.
runit() { echo "lf-claude-rettung-$(printf '%s' "$1" | sha256sum | cut -c1-12).service"; }
RU=$(runit /mnt/lf-target/LF/ok-1)
rescue "$RU" /mnt/lf-target/LF/ok-1 /dev/sdb
# Sein Kind (ddrescue) bleibt, ein fremder Prozess in seiner cgroup wird beendet.
RK=$(spawn) RF=$(spawn) RX=$(spawn)
fake "$RK" 0 0 "$RP" "PATH=/usr/bin" "ddrescue x"
fake "$RF" 0 0 1 "PATH=/usr/bin" "sleep 300"
printf '%s\n' "$RK" "$RF" >>"$T/cg/system.slice/$RU/cgroup.procs"
# Einer in einer Unter-cgroup, die root im Dienst angelegt hat.
fake "$RX" 0 0 1 "PATH=/usr/bin" "sleep 300"
mkdir -p "$T/cg/system.slice/$RU/x" && echo "$RX" >"$T/cg/system.slice/$RU/x/cgroup.procs"
RSPOOFS=()
# rspoof NAME [FALLORDNER] [QUELLE]   Eine Rettung unter dem passenden Namen zu FALLORDNER (Vorgabe
#   /mnt/lf-target/LF/ok-NAME von /dev/sdb).
rspoof() {
	local c=${2:-/mnt/lf-target/LF/ok-$1}
	RS=$(runit "$c")
	rescue "$RS" "$c" "${3:-/dev/sdb}"
	RSPOOFS+=("$RS")
}
rspoof env && prop "$RS" Environment "LD_PRELOAD=/var/lib/lf-claude/x.so"
rspoof dropin && prop "$RS" DropInPaths "/run/systemd/system/$RS.d/x.conf"
rspoof stoppost && prop "$RS" ExecStopPost "$X"
rspoof type && prop "$RS" Type forking
rspoof unsetenv && prop "$RS" UnsetEnvironment "LD_PRELOAD"
rspoof user && prop "$RS" User nobody
rspoof fragment && prop "$RS" FragmentPath "/etc/systemd/system/$RS"
rspoof fall /mnt/lf-target/LF/boese
rspoof quelle /mnt/lf-target/LF/ok-quelle /dev/sdc
rspoof args && prop "$RS" ExecStart "{ path=/usr/local/bin/lf-rescue-run ; argv[]=/usr/local/bin/lf-rescue-run /mnt/lf-target/LF/ok-args /dev/sdb --no-pause --techniker=x ; ignore_errors=no ; }" &&
	printf '%s\0' bash /usr/local/bin/lf-rescue-run /mnt/lf-target/LF/ok-args /dev/sdb --no-pause --techniker=x >"$T/proc/$RP/cmdline"
rspoof programm && prop "$RS" ExecStart "{ path=/usr/local/bin/lf-aufgabe ; argv[]=/usr/local/bin/lf-aufgabe /mnt/lf-target/LF/ok-programm /dev/sdb --no-pause ; ignore_errors=no ; }"
rspoof exe && ln -sfn "$T/bin/anderes" "$T/proc/$RP/exe"
rspoof cmdline && printf '%s\0' bash -c /var/lib/lf-claude/x /mnt/lf-target/LF/ok-cmdline /dev/sdb >"$T/proc/$RP/cmdline"
rspoof ldpreload && printf 'PATH=/usr/bin\0LD_PRELOAD=/var/lib/lf-claude/x.so\0' >"$T/proc/$RP/environ"
rspoof bashenv && printf 'BASH_ENV=/var/lib/lf-claude/x\0' >"$T/proc/$RP/environ"
# Umgebung nicht vom Freischalten: ein Ordner von root vorn in PATH (systemctl set-environment
# während der Freigabe), eine Variable mehr. Ein- oder Ausgabe in eine Datei, Neustart.
rspoof path && sed -z -i 's|^PATH=|PATH=/var/lib/lf-claude/bin:|' "$T/proc/$RP/environ"
rspoof extra && printf 'HANG_SYS=/var/lib/lf-claude/sys\0' >>"$T/proc/$RP/environ"
rspoof stdin && prop "$RS" StandardInput "file:/var/lib/lf-claude/x"
rspoof stdout && prop "$RS" StandardOutput "append:/usr/local/bin/lf-aufgabe"
rspoof stderr && prop "$RS" StandardError "append:/etc/sudoers.d/lf-claude"
rspoof restart && prop "$RS" Restart always
# Was systemd-run sonst nicht setzt: Einheiten, die er beim Start, Stoppen oder Enden mitnimmt,
# Neustart nach einem Exit-Code, was systemd tut, wenn er endet, Rechte neuer Dateien, Umgebung
# vom Manager, Arbeitsordner, Gruppen, Terminal, Slice.
rspoof requires && prop "$RS" Requires "system.slice sysinit.target lf799j.service"
rspoof wants && prop "$RS" Wants lf799j.service
rspoof bindsto && prop "$RS" BindsTo lf799j.service
rspoof partof && prop "$RS" PartOf lf799j.service
rspoof requisite && prop "$RS" Requisite lf799j.service
rspoof onfailure && prop "$RS" OnFailure lf799j.service
rspoof forceexit && prop "$RS" RestartForceExitStatus 0
rspoof preventexit && prop "$RS" RestartPreventExitStatus 1
rspoof restartmode && prop "$RS" RestartMode direct
rspoof success && prop "$RS" SuccessAction reboot
rspoof failure && prop "$RS" FailureAction reboot
rspoof umask && prop "$RS" UMask 0000
rspoof passenv && prop "$RS" PassEnvironment PATH
rspoof workdir && prop "$RS" WorkingDirectory /var/lib/lf-claude
rspoof group && prop "$RS" Group lf-claude
rspoof supgroups && prop "$RS" SupplementaryGroups lf-claude
rspoof ttypath && prop "$RS" TTYPath /dev/tty9
rspoof slice && prop "$RS" Slice lf.slice
# MEMORY_PRESSURE_WATCH nennt eine andere Datei als die der eigenen cgroup (sd-event schriebe
# MEMORY_PRESSURE_WRITE dorthin), USER nicht root.
rspoof watch && sed -z -i 's|^MEMORY_PRESSURE_WATCH=.*|MEMORY_PRESSURE_WATCH=/etc/sudoers.d/lf-claude|' "$T/proc/$RP/environ"
rspoof userenv && sed -z -i 's|^USER=root$|USER=lf-claude|' "$T/proc/$RP/environ"
# Der Hauptprozess liegt nicht in der cgroup des Dienstes.
rspoof maincg && : >"$T/cg/system.slice/$RS/cgroup.procs"
# Unter dem Namen eines anderen Falls
c=/mnt/lf-target/LF/ok-name
RS=$(runit /mnt/lf-target/LF/ok-anders)
rescue "$RS" "$c" /dev/sdb
RSPOOFS+=("$RS")
# Ein laufender Prozess mit LD_PRELOAD in der cgroup, ein Kind des Hauptprozesses
rspoof member && { RM=$(spawn); fake "$RM" 0 0 "$RP" "LD_PRELOAD=/var/lib/lf-claude/x.so" "sleep 300"; echo "$RM" >>"$T/cg/system.slice/$RS/cgroup.procs"; }
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
check "Anmeldungen des Technikers, Claudes Sitzung und ältere Einheiten bleiben, auch nur neu gestartet" '! grep -qE "^(stop|kill -s KILL|freeze) (session-5.scope|run-u9.scope|getty@tty2.service|a.service|run-u6.service|c.service)$" "$T/systemctl.log"'
check "eine Rettung, wie start_rescue sie anlegt, bleibt; lf-aufgabe prüft ihre Argumente (F16)" '! grep -qxF -e "stop $RU" -e "kill -s KILL $RU" -e "freeze $RU" "$T/systemctl.log" && grep -qxF "pruefen-rettung /mnt/lf-target/LF/ok-1 /dev/sdb" "$T/aufgabe.log" && kill -0 "$RK" 2>/dev/null'
check "ein fremder Prozess in einer Rettung oder in ntfs-3g: beendet und protokolliert, der Dienst bleibt (F16)" '! kill -0 "$RF" 2>/dev/null && ! kill -0 "$RX" 2>/dev/null && grep -qF "beendet: $RX sleep 300 (fremd in $RU)" "$LOG" && ! kill -0 "$NF" 2>/dev/null && grep -qF "beendet: $RF sleep 300 (fremd in $RU)" "$LOG" && grep -qF "beendet: $NF sleep 300 (fremd in $NT)" "$LOG" && ! grep -qF "beendet: $RK" "$LOG"'
check "nur der Name des eigenen Endes: gestoppt" 'grep -qxF "stop lf-claude-freigabe-ende-aus.service" "$T/systemctl.log"'
check "nur der Name einer Rettung: gestoppt" 'grep -qxF "stop lf-claude-rettung-sdb.service" "$T/systemctl.log"'
check "Rettungen mit einer Eigenschaft mehr oder anders als von systemd-run (Ein- und Ausgabe, Abhängigkeiten, Neustart, Gruppen), anderer Umgebung, anderen Argumenten, einem anderen Namen oder Prozess: gestoppt (F16)" 'n=0; for u in "${RSPOOFS[@]}"; do grep -qxF "stop $u" "$T/systemctl.log" || { echo "    bleibt: $u"; n=$((n + 1)); }; done; ((n == 0 && ${#RSPOOFS[@]} == 44))'
check "pruefen-rettung läuft nur für Rettungen, die sonst genau passen" 'grep -qxF "pruefen-rettung /mnt/lf-target/LF/boese /dev/sdb" "$T/aufgabe.log" && ! grep -q "ok-env\|ok-dropin\|ok-programm\|ok-cmdline\|ok-path\|ok-stdout\|ok-restart\|ok-requires\|ok-umask\|ok-forceexit\|ok-slice" "$T/aufgabe.log"'
check "unter einem Namen von vorher neu angelegt oder mit neuer Ergänzung neu gestartet: gestoppt" 'grep -qx "stop run-u5.service" "$T/systemctl.log" && grep -qF "beendet: Einheit run-u5.service" "$LOG" && grep -qx "stop b.service" "$T/systemctl.log"'
check "Ergänzung, deren Pfad systemctl nicht ausgibt, oder gelöschte Unit-Datei: gestoppt" 'grep -qx "stop e.service" "$T/systemctl.log" && grep -qx "stop f.service" "$T/systemctl.log"'
check "ntfs-3g einer nur lesend eingehängten Quelle bleibt, die Quelle verschwindet nicht (GHSA-799j-44qx-x7xj)" '! grep -qxF -e "stop $NT" -e "kill -s KILL $NT" -e "freeze $NT" "$T/systemctl.log" && ! grep -qF "beendet: Einheit $NT" "$LOG"'
check "Dienste, die nur wie ntfs-3g heißen, sind gestoppt" 'n=0; for u in sdb2 sdb3 sdb4 sdb5; do grep -qxF "stop lf-ntfs3g-mnt-lf\x2dimage-$u.service" "$T/systemctl.log" && n=$((n + 1)); done; grep -qxF "stop lf-ntfs3g-x.service" "$T/systemctl.log" && ((n == 4))'
check "ntfs-3g-Dienste mit einer Eigenschaft mehr, anderer Umgebung oder Ausgabe oder einem Prozess, der nicht passt, sind gestoppt (F12, F13, F16)" 'n=0; for u in "${SPOOFS[@]}"; do grep -qxF "stop $u" "$T/systemctl.log" || { echo "    bleibt: $u"; n=$((n + 1)); }; done; ((n == 0 && ${#SPOOFS[@]} == 33))'
check "der neue at-Auftrag ist entfernt, der alte bleibt" 'grep -qx 2 "$T/atrm.log" && ! grep -qx 1 "$T/atrm.log"'
check "die neue cron-Datei ist gesperrt, nicht gelöscht; die alte bleibt" '[[ -f $T/cron.d/neu.lf-gesperrt && ! -e $T/cron.d/neu && -f $T/cron.d/alt ]]'
check "linger für lf-claude ist aufgehoben" '[[ ! -e $T/linger/lf-claude ]] && grep -qx "disable-linger lf-claude" "$T/loginctl.log"'
check "Reihenfolge: anhalten, Regel, Einheiten, root-Prozesse, weiterlaufen" 'a=$(line "Claude angehalten") u=$(line "beendet: Einheit run-u7.service") r=$(line "Regel entfernt") k=$(line "beendet: $Q1 ") w=$(line "Claude läuft weiter"); [[ -n $a && -n $u && -n $r && -n $k && -n $w ]] && ((a < r && r < u && u < k && k < w))'
check "die cgroups von Claude laufen danach weiter" '[[ $(cat "$CG/cgroup.freeze") == 0 && $(cat "$CGU/cgroup.freeze") == 0 ]]'
check "danach: status aus, Neustart empfohlen" 'aus_n'
kill "$RK" "$RM" "$NM" "$NB" 2>/dev/null

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
check "Namen mit Punkt liest sudo nicht: kein Rückstand" 'aus_n'
rm -f "$T/sudoers.d/zz.neu"
echo "[{\"next\": $(((NOW + 600) * 1000000)), \"unit\": \"lf-claude-freigabe-ende.timer\"}]" >"$T/timers.json"
check "Regel fehlt, Timer läuft: an, Rückstand" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (Regel fehlt, Timer bis $(date -d "@$((NOW + 600))" +%H:%M)), Neustart empfohlen" ]]'
rm -f "$T/timers.json"
# Nach dem sauberen Ende oben kommt eine spätere Einheit (etwa systemd-run für ein neues "an")
# nicht aus der Freigabe.
unit run-u11.service yes /system.slice/run-u11.service
check "nach einem sauberen Ende ist der Schnappschuss der Einheiten weg, eine spätere Einheit ist kein Rückstand" '[[ ! -e $SNAP/units && -e $SNAP/sudoers ]] && aus_n'
check "nach einem sauberen Ende zählen spätere Änderungen an Dateien, Kette, Einhängungen und Credentials nicht" '[[ ! -e $SNAP/files && ! -e $SNAP/chain && ! -e $SNAP/mounts && ! -e $SNAP/creds && ! -e $SNAP/knobs && ! -e $SNAP/menv && ! -e $SNAP/zeit ]]'
sed -i 's/^ActiveState=.*/ActiveState=inactive/' "$T/unit/run-u11.service"
touch "$T/linger/lf-claude"
check "linger für lf-claude: an, Rückstand" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (linger: lf-claude), Neustart empfohlen" ]]'
rm -f "$T/linger/lf-claude"
check "alles aufgeräumt: aus, Neustart empfohlen" 'aus_n'
kill "$Q1" "$Q2" "$Q3" "$Q4" "$Q5" "$Q6" "$Q7" "$Q8" 2>/dev/null
kill -KILL "$Q10" 2>/dev/null
: >"$CG/cli.scope/cgroup.procs"
: >"$CGU/cgroup.procs"
cleanproc

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
check "ohne Rückstand: nach dem Ablauf wieder aus, Neustart empfohlen" 'aus_n && [[ ! -e $T/run/claude-freigabe-rueckstand ]] && grep -q "abgelaufen" "$LOG"'
check "das nächste Ende prüft weiter gegen den Schnappschuss, erst ein sauberes Ende löscht ihn" 'grep -qx "stop run-u12.service" "$T/systemctl.log" && [[ ! -e $SNAP/units ]]'

echo "Manager-Umgebung (F13):"
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
check "nach dem Hinweis auf einen Neustart schaltet der Techniker ohne Konsole frei, mit neuem Schnappschuss" '[[ -e $RULE && -s $SNAP/menv && -s $SNAP/units ]]'
cp "$T/menv.json" "$T/menv-vorher.json"
# Während der Freigabe als root gesetzt (systemctl set-environment): neu, geändert, entfernt.
jq -c '[.[] | select(startswith("LANG=") | not)] + ["LANG=de_DE.UTF-8", "LD_PRELOAD=/var/lib/lf-claude/x.so", "BASH_ENV=/var/lib/lf-claude/rc"] | map(select(startswith("PATH=") | not))' "$T/menv-vorher.json" >"$T/menv.json"
bash "$F" aus >"$T/out" 2>&1
check "neue Variablen entfernt, geänderte und entfernte wie beim Freischalten" '[[ $(jq -c sort "$T/menv.json") == "$(jq -c sort "$T/menv-vorher.json")" ]]'
check "im Protokoll stehen nur die Namen, keine Werte" 'grep -qF "Manager-Umgebung zurückgesetzt: BASH_ENV LANG LD_PRELOAD PATH " "$LOG" && ! grep -q "x.so\|/rc\|de_DE" "$LOG"'
check "danach kein Rückstand" 'aus_n'
bash "$F" an 30 >"$T/out" 2>&1
jq -c '. + ["LD_PRELOAD=/var/lib/lf-claude/x.so"]' "$T/menv-vorher.json" >"$T/menv.json"
touch "$T/menv-fest"
: >"$LOG"
bash "$F" aus >"$T/out" 2>&1
check "lässt sich die Umgebung nicht zurücksetzen: Rückstand mit dem Namen" 'grep -qF "Manager-Umgebung ließ sich nicht zurücksetzen: LD_PRELOAD " "$LOG" && ! grep -q "Manager-Umgebung zurückgesetzt" "$LOG" && grep -qxF "Manager-Umgebung: LD_PRELOAD" "$T/run/claude-freigabe-rueckstand" && [[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (Manager-Umgebung: LD_PRELOAD), Neustart empfohlen" ]]'
rm -f "$T/menv-fest"
bash "$F" aus >"$T/out" 2>&1
check "ein weiteres aus setzt sie zurück, dann kein Rückstand mehr" 'aus_n && [[ $(jq -c sort "$T/menv.json") == "$(jq -c sort "$T/menv-vorher.json")" ]]'

echo "Rückstände ohne laufenden Prozess (F14):"
: >"$LOG"
: >"$T/systemctl.log"
bash "$F" an 30 >"$T/out" 2>&1
# Eine Rettung, während der Freigabe gestartet: bleibt nur mit unveränderter Kette.
RU2=$(runit /mnt/lf-target/LF/ok-kette)
rescue "$RU2" /mnt/lf-target/LF/ok-kette /dev/sdb
# Während der Freigabe als root eingerichtet:
echo /var/lib/lf-claude/x.so >"$W/etc/ld.so.preload"
echo "root:x:1::::::" >>"$W/etc/shadow"
echo "auth optional pam_exec.so /var/lib/lf-claude/x" >>"$W/etc/pam.d/common-auth"
mkdir -p "$W/etc/polkit-1/rules.d" && echo 'polkit.addRule(function () { return polkit.Result.YES; });' >"$W/etc/polkit-1/rules.d/00-x.rules"
echo "ssh-ed25519 AAAA x" >"$W/root/.ssh/authorized_keys"
echo "install ntfs3 /var/lib/lf-claude/x" >"$W/etc/modprobe.d/x.conf"
# ExecStopPost an einer Einheit, die schon vor der Freigabe lief (systemctl edit --runtime)
mkdir -p "$W/run/systemd/system/a.service.d" && printf '[Service]\nExecStopPost=/var/lib/lf-claude/x\n' >"$W/run/systemd/system/a.service.d/x.conf"
cp "$W/usr/bin/bash" "$W/var/tmp/sh" && chmod 4755 "$W/var/tmp/sh"
echo x >"$W/var/tmp/py" && echo "$W/var/tmp/py" >"$T/caps"
echo "# x" >>"$W/usr/local/bin/lf-aufgabe"
echo x >"$W/usr/lib/x86_64-linux-gnu/security/pam_x.so"
ln -s /dev/zero "$W/usr/local/bin/null"
mkfifo "$W/usr/local/lib/lf/fifo"
echo "|/var/lib/lf-claude/x" >"$T/proc/sys/kernel/core_pattern"
echo "enabled interpreter /var/lib/lf-claude/x flags: C" >"$T/proc/sys/fs/binfmt_misc/x"
# Credentials: in getty@tty1 überschrieben, gleich groß (die Zeile in mountinfo bleibt, wie sie war),
# in getty@tty2 eine Verknüpfung dazu, die von journald ausgehängt (der Ordner bleibt), eine Datei
# in einer Ablage, aus der Dienste beim Start Credentials laden. Im anderen Dateisystem liest das
# Ende nicht.
echo root00 >"$CRED/getty@tty1.service/agetty.autologin"
ln -s /run/lf799j-ja "$CRED/getty@tty2.service/login.noauth"
sed -i "\|$CRED/systemd-journald.service |d" "$T/proc/1/mountinfo"
mkdir -p "$W/run/credstore" && echo yes >"$W/run/credstore/login.noauth"
echo x >"$CRED/fremd.service/y"
# Einhängungen: über lf-lesen (mit nosuid), eine Quelle wie von lf-aufgabe und welche, die nur so
# aussehen: ohne noexec, ein Ordner statt der Wurzel eines Geräts, kein Gerät als Quelle, ein Name,
# den lf-aufgabe nicht vergibt.
printf '%s\n' "41 22 0:30 /var/tmp $W/usr/local/bin/lf-lesen rw,nosuid,relatime shared:1 - overlay overlay rw" \
	"42 22 8:33 / /mnt/lf-image/sdc1 ro,nosuid,nodev,noexec,relatime,nosymfollow shared:9 - ntfs3 /dev/sdc1 ro" \
	"43 22 8:34 / /mnt/lf-image/sdc2 ro,nosuid,nodev,relatime shared:9 - ntfs3 /dev/sdc2 ro" \
	"44 22 8:35 /x /mnt/lf-image/sdc3 ro,nosuid,nodev,noexec,relatime shared:9 - ext4 /dev/sdc3 ro" \
	"45 22 0:30 / /mnt/lf-image/sdc4 ro,nosuid,nodev,noexec,relatime shared:9 - tmpfs tmpfs ro" \
	"46 22 8:36 / /mnt/lf-image/dm-0 ro,nosuid,nodev,noexec,relatime shared:9 - ext4 /dev/dm-0 ro" >>"$T/proc/1/mountinfo"
timeout 120 bash "$F" aus >"$T/out" 2>&1
RC=$?
R=$T/run/claude-freigabe-rueckstand
check "das Ende läuft durch, auch mit einer Verknüpfung auf /dev/zero und einem FIFO in der Kette" '[[ $RC == 0 ]] && grep -q "Claude läuft weiter" "$LOG"'
check "eine neue ld.so.preload ist gesperrt, nicht gelöscht, und gemeldet" '[[ ! -e $W/etc/ld.so.preload && -f $W/etc/ld.so.preload.lf-gesperrt ]] && grep -qF "gesperrt: $W/etc/ld.so.preload" "$LOG" && grep -qxF "Datei neu: $W/etc/ld.so.preload.lf-gesperrt" "$R"'
check "Drop-in an einer Einheit von vorher: Rückstand" 'grep -qxF "Datei neu: $W/run/systemd/system/a.service.d/x.conf" "$R"'
check "shadow, PAM, polkit, SSH und modprobe: Rückstand" 'grep -qxF "Datei geändert: $W/etc/shadow" "$R" && grep -qxF "Datei geändert: $W/etc/pam.d/common-auth" "$R" && grep -qxF "Datei neu: $W/etc/polkit-1/rules.d/00-x.rules" "$R" && grep -qxF "Datei neu: $W/root/.ssh/authorized_keys" "$R" && grep -qxF "Datei neu: $W/etc/modprobe.d/x.conf" "$R"'
check "setuid-Kopie einer Shell und capabilities: Rückstand" 'grep -qxF "setuid/setgid: $W/var/tmp/sh" "$R" && grep -qxF "capabilities: $W/var/tmp/py cap_setuid=ep" "$R"'
check "lf-aufgabe geändert: Grundregel bis zum Neustart gesperrt, Rückstand" '[[ ! -e $T/sudoers.d/lf-claude && -f $T/sudoers.d/lf-claude.lf-gesperrt ]] && grep -qF "gesperrt: Grundregel von lf-claude ($T/sudoers.d/lf-claude) bis zum Neustart" "$LOG" && grep -qxF "Werkzeug neu oder geändert: $W/usr/local/bin/lf-aufgabe" "$R" && grep -qxF "Grundregel gesperrt bis zum Neustart: $T/sudoers.d/lf-claude.lf-gesperrt" "$R"'
check "unveränderte Werkzeuge und Programme stehen nicht im Rückstand" '! grep -qxF "Werkzeug neu oder geändert: $W/usr/local/bin/lf-lesen" "$R" && ! grep -qF "$CS" "$R"'
check "neue Verknüpfung und FIFO in der Kette: Rückstand, ohne sie zu lesen" 'grep -qxF "Werkzeug neu oder geändert: $W/usr/local/bin/null" "$R" && grep -qxF "Werkzeug neu oder geändert: $W/usr/local/lib/lf/fifo" "$R"'
check "unter /usr ist jede neue oder geänderte Datei ein Rückstand" 'grep -qxF "Systemdatei neu oder geändert: $W/usr/lib/x86_64-linux-gnu/security/pam_x.so" "$R" && grep -qxF "Systemdatei neu oder geändert: $W/usr/local/bin/null" "$R"'
check "Kernel-Einstellungen: core_pattern und ein neuer binfmt_misc-Eintrag" 'grep -qxF "Kernel-Einstellung neu oder geändert: $T/proc/sys/kernel/core_pattern" "$R" && grep -qxF "Kernel-Einstellung neu oder geändert: $T/proc/sys/fs/binfmt_misc/x" "$R"'
check "Einhängung über lf-lesen: Rückstand, auch mit nosuid; eine Quelle wie von lf-aufgabe nicht" 'grep -qxF "Einhängung neu oder geändert: $W/usr/local/bin/lf-lesen (overlay overlay)" "$R" && grep -qxF "Einhängung neu oder geändert: /mnt/lf-image/sdc2 (ntfs3 /dev/sdc2)" "$R" && ! grep -q "/mnt/lf-image/sdc1" "$R"'
check "Einhängungen, die nur wie eine Quelle von lf-aufgabe aussehen: Rückstand" 'grep -qxF "Einhängung neu oder geändert: /mnt/lf-image/sdc3 (ext4 /dev/sdc3)" "$R" && grep -qxF "Einhängung neu oder geändert: /mnt/lf-image/sdc4 (tmpfs tmpfs)" "$R" && grep -qxF "Einhängung neu oder geändert: /mnt/lf-image/dm-0 (ext4 /dev/dm-0)" "$R"'
check "eine Rettung mit geänderter Kette ist gestoppt, lf-aufgabe läuft dafür nicht" 'grep -qxF "stop $RU2" "$T/systemctl.log" && ! grep -q "ok-kette" "$T/aufgabe.log"'
check "Credentials: Inhalt geändert, ohne Einhängung, neu in einer Ablage: Rückstand; im anderen Dateisystem liest das Ende nicht" 'grep -qxF "Credentials geändert: $CRED/getty@tty1.service" "$R" && grep -qxF "Credentials geändert: $CRED/getty@tty2.service" "$R" && grep -qxF "Credentials ohne Einhängung: $CRED/systemd-journald.service" "$R" && grep -qxF "Datei neu: $W/run/credstore/login.noauth" "$R" && ! grep -q "fremd.service" "$R"'
check "status: an, Rückstand; die Statuszeile warnt" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (Grundregel gesperrt bis zum Neustart: $T/sudoers.d/lf-claude.lf-gesperrt), Neustart empfohlen" && $(bash "$F" zeile </dev/null) == ACHTUNG* ]]'
echo rescue >"$CRED/getty@tty1.service/agetty.autologin"
rm -f "$CRED/getty@tty2.service/login.noauth" "$CRED/fremd.service/y"
rm -r "$W/run/credstore"
printf '%s\n' "${CRED_LINES[2]}" >>"$T/proc/1/mountinfo"

echo "Kette über Verknüpfungen, hängende Prüfungen (F14):"
# reboot_sim   Neustart nachgestellt: Grundregel zurück, Schnappschuss und Rückstand weg.
reboot_sim() {
	if [[ -e $T/sudoers.d/lf-claude.lf-gesperrt ]]; then mv "$T/sudoers.d/lf-claude.lf-gesperrt" "$T/sudoers.d/lf-claude"; fi
	rm -rf "$SNAP" "$T/run/claude-freigabe-rueckstand"
}
# hung_alive   Läuft noch einer der hängenden Prozesse der Attrappen?
hung_alive() {
	local p
	while read -r p; do kill -0 "$p" 2>/dev/null && return 0; done <"$T/haengt.pids"
	return 1
}
hung_kill() { local p; while read -r p; do kill -KILL "$p" 2>/dev/null; done <"$T/haengt.pids"; }
: >"$T/haengt.pids"
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
check "nach dem Neustart lässt sich wieder freischalten" '[[ -e $RULE && -s $SNAP/chain && -f $T/sudoers.d/lf-claude ]]'
echo "# x" >>"$CS"
bash "$F" aus >"$T/out" 2>&1
check "geändertes Ziel der Verknüpfung /usr/bin/sudo: Grundregel gesperrt, Rückstand" '[[ -f $T/sudoers.d/lf-claude.lf-gesperrt ]] && grep -qxF "Werkzeug neu oder geändert: $CS" "$R"'
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
echo x >"$W/usr/local/lib/lf/haengt"
t0=$SECONDS
timeout 60 bash "$F" aus >"$T/out" 2>&1
RC=$? DT=$((SECONDS - t0))
check "hängt sha256sum, endet die Prüfung der Kette nach der Höchstdauer, ohne Enkel" '[[ $RC == 0 ]] && ((DT < 40)) && [[ -s $T/haengt.pids ]] && ! hung_alive'
check "eine abgebrochene Prüfung der Kette zählt wie geändert: Grundregel gesperrt" '[[ -f $T/sudoers.d/lf-claude.lf-gesperrt ]] && grep -qxF "Werkzeug neu oder geändert: $W/usr/local/bin/lf-aufgabe" "$R"'
hung_kill
: >"$T/haengt.pids"
rm -f "$W/usr/local/lib/lf/haengt"
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
RU3=$(runit /mnt/lf-target/LF/ok-haengt)
rescue "$RU3" /mnt/lf-target/LF/ok-haengt /dev/sdb
echo x >"$W/var/tmp/haengt-cap"
t0=$SECONDS
timeout 60 bash "$F" aus >"$T/out" 2>&1
RC=$? DT=$((SECONDS - t0))
check "hängen getcap und die Prüfung einer Rettung, endet das Ende nach der Höchstdauer, ohne Enkel" '[[ $RC == 0 ]] && ((DT < 40)) && (($(wc -l <"$T/haengt.pids") >= 2)) && ! hung_alive'
check "eine Rettung, deren Prüfung hängt, ist gestoppt; die Grundregel bleibt" 'grep -qxF "stop $RU3" "$T/systemctl.log" && [[ -f $T/sudoers.d/lf-claude && ! -e $T/sudoers.d/lf-claude.lf-gesperrt ]]'
check "eine abgebrochene Suche nach capabilities steht im Rückstand" 'grep -qE "^Suche nach capabilities abgebrochen \(rc (124|137)\)$" "$R"'
hung_kill
rm -f "$W/var/tmp/haengt-cap"
: >"$T/haengt.pids"

echo "Manager-Umgebung beim Freischalten nicht lesbar (F13, F16):"
reboot_sim
touch "$T/menv-kaputt"
bash "$F" an 30 >"$T/out" 2>&1
rm -f "$T/menv-kaputt"
RU4=$(runit /mnt/lf-target/LF/ok-ohne-menv)
rescue "$RU4" /mnt/lf-target/LF/ok-ohne-menv /dev/sdb
bash "$F" aus >"$T/out" 2>&1
check "nichts zu vergleichen: das Ende meldet es als Rückstand" 'grep -qxF "Manager-Umgebung: (beim Freischalten nicht lesbar)" "$R"'
check "eine Rettung, die während dieser Freigabe gestartet ist, bleibt nicht" 'grep -qxF "stop $RU4" "$T/systemctl.log"'
reboot_sim

echo "Unsichere Variable schon beim Freischalten (F13, F16):"
cp "$T/menv.json" "$T/menv-sauber.json"
jq -c '. + ["LD_PRELOAD=/var/lib/lf-claude/x.so"]' "$T/menv-sauber.json" >"$T/menv.json"
bash "$F" an 30 >"$T/out" 2>&1
RU5=$(runit /mnt/lf-target/LF/ok-preload-vorher)
rescue "$RU5" /mnt/lf-target/LF/ok-preload-vorher /dev/sdb
bash "$F" aus >"$T/out" 2>&1
check "eine Rettung mit LD_PRELOAD aus der Umgebung vom Freischalten bleibt nicht" 'grep -qxF "stop $RU5" "$T/systemctl.log"'
cp "$T/menv-sauber.json" "$T/menv.json"
reboot_sim

echo "Ein Dienst mit Credentials endet während der Freigabe:"
bash "$F" an 30 >"$T/out" 2>&1
sed -i "\|$CRED/systemd-journald.service |d" "$T/proc/1/mountinfo"
mv "$CRED/systemd-journald.service" "$T/journald-creds"
bash "$F" aus >"$T/out" 2>&1
check "seine Einhängung verschwindet mit ihrem Ordner: kein Rückstand" '! grep -qs "Credentials" "$R"'
mv "$T/journald-creds" "$CRED/systemd-journald.service"
printf '%s\n' "${CRED_LINES[2]}" >>"$T/proc/1/mountinfo"
reboot_sim

echo "Hinweise für Techniker und Claude:"
check "Anleitung: Eine Konsole, die während der Freigabe aufgeht, zeigt danach Rückstand; dann neu starten" 'grep -qF "Öffnest du während einer Freigabe eine weitere Konsole (Alt+F2 … F6), zeigt das Ende danach „Rückstand“" docs/anleitung.md && grep -qF "Starte dann neu. Bis dahin schaltest du eine neue Freigabe nur an einer Konsole des Geräts frei, mit Rückfrage dort." docs/anleitung.md'
check "der Freigabe-Dialog sagt, dass das Ende auch laufende root-Jobs von Claude beendet" 'grep -q "Am Ende der Freigabe beendet Leuchtfeuer, was Claude damit als root gestartet hat, auch mitten im Schreiben." rescue/lib/claude.sh'
check "Dialog und Anleitung: sicher endet root-Zugriff nur mit einem Neustart" '(($(grep -c "Sicher endet root-Zugriff nur mit einem Neustart" rescue/lib/claude.sh) >= 4)) && grep -q "Sicher endet root-Zugriff aber nur mit einem Neustart" docs/anleitung.md'
check "Verlängern im Dialog: Rückfrage an der Konsole, eine Ablehnung wird gemeldet" 'grep -q "Rückfrage hier an der Konsole" rescue/lib/claude.sh && grep -q "Nicht verlängert. Details im Protokoll." rescue/lib/claude.sh'
check "Freischalten und Verlängern im Dialog laufen direkt am Terminal, nicht über run (sudo-rs, GHSA-799j-44qx-x7xj)" '! grep -q "run sudo lf-freigabe an" rescue/lib/claude.sh &&grep -qxF "	sudo lf-freigabe an \"\$1\" || rc=\$?" rescue/lib/claude.sh && grep -qF "claude_freigabe_an \"\$min\" ||" rescue/lib/claude.sh && grep -qF "if claude_freigabe_an 30; then" rescue/lib/claude.sh'
check "CLI und Desktop laufen in der Slice, die lf-freigabe am Ende prüft" '[[ $(sed -n "s/^CLAUDE_SLICE=//p" rescue/lib/claude.sh) == "$(sed -n "s/^SLICE=//p" rescue/bin/lf-freigabe)" ]] && grep -q "claude_scope sh -c" rescue/lib/claude.sh && grep -qF -- "--slice=\"\$CLAUDE_SLICE\"" rescue/lib/claude-desktop-start'
check "lf-freigabe lässt genau die ntfs-3g-Dienste gelten, die part_mount_ro startet (Name, Optionen, Einhängepunkt)" 'grep -qF "ntfs3g_ro ro,nodev,nosuid,noexec,recover \"\$part\" \"\$mp\"" rescue/lib/recover.sh && grep -qF "unit=\"lf-ntfs3g-\$(systemd-escape --path -- \"\$3\").service\"" rescue/lib/recover.sh && grep -qF "\${argv[2]} == ro,nodev,nosuid,noexec,recover" rescue/bin/lf-freigabe && grep -qF "[[ \$u == \"lf-ntfs3g-\$(systemd-escape --path -- \"\${argv[4]}\").service\" ]]" rescue/bin/lf-freigabe && [[ $(sed -n "s/^IMAGE_MNT=//p" rescue/bin/lf-freigabe) == "$(sed -n "s/^LF_IMAGE_MNT=\"\(.*\)\"$/\1/p" rescue/lib/common.sh)" ]]'
check "recover.sh startet ntfs-3g so, wie lf-freigabe es verlangt: Type=forking und UnsetEnvironment, sonst nichts (F12, F13)" 'grep -qxF "	if ! run sudo systemd-run --quiet --collect --unit=\"\$unit\" -p Type=forking -p UnsetEnvironment=\"\$LF_ENV_UNSAFE\" \\" rescue/lib/recover.sh && grep -qxF "		--description=\"Leuchtfeuer: ntfs-3g, nur lesend unter \$3\" -- ntfs-3g -o \"\$1\" \"\$2\" \"\$3\"; then" rescue/lib/recover.sh && grep -qx "NTFS3G=/usr/bin/ntfs-3g" rescue/bin/lf-freigabe'
check "lf-aufgabe startet Rettungen so, wie lf-freigabe sie gelten lässt: Name, Programm, Argumente, UnsetEnvironment (F16)" 'grep -qxF "	unit=\"lf-claude-rettung-\$(printf '"'"'%s'"'"' \"\$1\" | sha256sum | cut -c1-12)\"" rescue/bin/lf-aufgabe && grep -qxF "	systemd-run --quiet --collect --unit=\"\$unit\" -p UnsetEnvironment=\"\$LF_ENV_UNSAFE\" --description=\"Leuchtfeuer: Rettung \$(basename \"\$1\")\" \\" rescue/bin/lf-aufgabe && grep -qxF "		/usr/local/bin/lf-rescue-run \"\$1\" \"\$2\" --no-pause \${LF_TECHNIKER:+\"--techniker=\$LF_TECHNIKER\"} ||" rescue/bin/lf-aufgabe && grep -qF "[[ \$u == \"lf-claude-rettung-\$(printf '"'"'%s'"'"' \"\${argv[1]}\" | sha256sum | cut -c1-12).service\" ]]" rescue/bin/lf-freigabe && grep -qx "RESCUE_RUN=/usr/local/bin/lf-rescue-run" rescue/bin/lf-freigabe && [[ $(head -n 1 rescue/bin/lf-rescue-run) == "#!/usr/bin/env bash" ]] && grep -qx "pruefen-rettung)" rescue/bin/lf-aufgabe'
check "eine Liste der Variablen für lf-freigabe und common.sh (F13)" '[[ -n $ENV_UNSAFE && $ENV_UNSAFE == "$(sed -n "s/^LF_ENV_UNSAFE=\"\(.*\)\"$/\1/p" rescue/lib/common.sh)" ]]'
check "lf-freigabe startet genau zwei Dienste, beide oben mit UnsetEnvironment geprüft (F13)" '[[ $(grep -cE "^[[:space:]]*(exec )?systemd-run " rescue/bin/lf-freigabe) == 2 ]]'
check "CLAUDE.md: lange Kopien nur über lf-aufgabe, nie direkt mit sudo" 'tr "\n" " " <rescue/claude/CLAUDE.md | grep -q "Lange Kopien (dd, ddrescue, partclone) startest du auch dann nur über lf-aufgabe, nie direkt mit sudo"'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
