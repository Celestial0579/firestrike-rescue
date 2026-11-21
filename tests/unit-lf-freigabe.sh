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
#     und was lf-claude sonst mit der Freigabe gestartet hat. Prozesse in der cgroup, die während
#     der Freigabe gestartet sind (Startzeit in /proc/PID/stat), enden, wenn sie nicht nur als
#     lf-claude laufen (uid- und gid-Felder, Gruppen, capabilities), auch Jobs von lf-aufgabe.
#     Jobs von vorher bleiben mit allem, was nach PPid von ihnen abstammt, solange die Grundregel
#     nicht gesperrt ist (B5, nur mit Attrappen von /proc). Prozesse des Technikers laufen weiter;
#     gemeldet wird, was lf-claude danach noch darf.
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
#   - Bei beiden ist die Unit-Datei Byte für Byte die von systemd-run (systemd liest sie bei
#     daemon-reload neu) und NeedDaemonReload=no. Jede Eigenschaft eines Dienstes in systemd 259
#     ist eingeordnet (systemd-259-properties.txt), leer und gleich passen zu kept_unit.
#   - Die Umgebung des systemd-Managers ist am Ende wie beim Freischalten, ins Protokoll kommen nur
#     die Namen; was sich nicht zurücksetzen lässt, ist ein Rückstand, ebenso eine Umgebung, die
#     sich beim Freischalten nicht lesen ließ, und eine, die das Ende zurückgesetzt hat (Dienste
#     können sie geerbt haben), bis zum Neustart. Das Ende läuft ohne die Umgebung seines Aufrufs
#     (kein fremder Bus für busctl, keine .jq aus HOME). Jeder Dienst, den
#     lf-freigabe, recover.sh und lf-aufgabe starten, erbt LD_PRELOAD und Co. nicht (F13).
#   - Wege zu root ohne laufenden Prozess sind ein Rückstand: geänderte Konten, PAM, polkit, SSH,
#     modprobe, setuid-Dateien, capabilities, Dateien unter /usr, Kernel-Einstellungen (auch ein
#     Kernel für kexec) und Einhängungen (auch über lf-lesen), der Inhalt der Credentials von
#     Diensten (getty und login lesen daraus login.noauth und agetty.autologin) und ihre Ablagen.
#     Eine neue ld.so.preload und ein System für soft-reboot werden gesperrt, eine geänderte Kette
#     der Grundregel (lf-aufgabe, /etc/lf-release) sperrt die Grundregel bis zum Neustart (F14).
#   - Rückstand sind auch ganz /root, Dotfiles und ~/bin des Technikers, cron der Benutzer, die
#     Skripte von dpkg, linger und Ordner unter /run, aus denen Dienste lesen, die Dateien geladener
#     Einheiten (auch hinter Verknüpfungen außerhalb der Suchpfade), die Benutzer-Manager (Umgebung,
#     Einheiten, ihre Dateien, /run/user/UID/systemd), Prozesse des Technikers aus der Freigabe und
#     am Kernel Taint, Module und BPF-Pins. Ganz /root, tmux, mc, sudoers-rs und lf-boot.env sperren
#     die Grundregel, die Meldung nennt jeden Grund, auch jede Einhängung. Hat sich etwas geändert,
#     das von selbst als root oder als Techniker läuft, steht nach dem Hinweis auf EFI-Variablen
#     zuerst der Hinweis aufs Ausschalten (A1 bis A3, B2 bis B4, B6, B7).
#   - Nach jeder Freigabe sagt status bis zum Neustart "aus, Neustart empfohlen (…)" (F15). Der
#     Assistent startet ohne kexec und soft-reboot neu, die Anleitung rät zum Ausschalten.
#   - Vom ersten Schritt jedes Endes an hält lf-netzschalter.service (Unit-Datei aus dem Image) bei
#     logind die Sperre des Netzschalters; das Ende lässt den Dienst nur mit genau dieser Datei stehen,
#     prüft nach dem Beenden über ListInhibitors, ob logind sie führt, startet ihn neu, wenn sein
#     Prozess Code aus der Freigabe haben kann, und gibt ihn nur ohne Hinweis aufs Ausschalten am
#     Netzschalter frei. Jede Zeile, die niemand eingeordnet hat, sagt, über Beenden > Ausschalten
#     auszuschalten; geänderte Dateien auf LF-DATA haben einen eigenen Hinweis. Strg+Alt+Entf ist im
#     Image ohne Wirkung (nur Attrappen, keine Einheit mit Code beim Stoppen).
#
# Hier läuft nichts als root: Eine Kopie von lf-freigabe arbeitet mit eigenen Ordnern statt
# /etc/sudoers.d, /run/lf, /proc und /sys/fs/cgroup, und mit einer eigenen Wurzel (WROOT) für die
# Dateien, die das Ende prüft. sudo, systemctl, systemd-run, loginctl, atq, atrm, visudo, logger,
# id, busctl (auch logind), getcap und lf-aufgabe sind Attrappen. Beendet werden nur sleep-Prozesse, die der
# Test selbst startet.
set -u
cd "$(dirname "$0")/.." || exit 1
# TZ: Als root läuft lf-freigabe ohne die Umgebung des Aufrufs, die Uhrzeiten im Test kommen aus
# derselben Zone.
unset SUDO_USER SUDO_UID SUDO_COMMAND TZ

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
echo 'LF_VERSION="26.04-test"' >"$W/etc/lf-release"
# Wie auf dem ISO sind sudo und env Verknüpfungen: sudo-rs über alternatives, env aus uutils.
mkdir -p "$W/usr/lib/cargo/bin/coreutils" "$W/etc/alternatives"
echo sudo >"$W/usr/lib/cargo/bin/sudo" && echo env >"$W/usr/lib/cargo/bin/coreutils/env"
ln -s "$W/usr/lib/cargo/bin/sudo" "$W/etc/alternatives/sudo" && ln -s "$W/etc/alternatives/sudo" "$W/usr/bin/sudo"
ln -s ../lib/cargo/bin/coreutils/env "$W/usr/bin/env"
CS=$(readlink -f "$W/usr/bin/sudo") CE=$(readlink -f "$W/usr/bin/env")
echo "|/usr/lib/systemd/systemd-coredump %P" >"$T/proc/sys/kernel/core_pattern"
echo /sbin/modprobe >"$T/proc/sys/kernel/modprobe"
: >"$W/sys/kernel/uevent_helper"
# Kein Kernel für kexec geladen.
echo 0 >"$W/sys/kernel/kexec_loaded" && echo 0 >"$W/sys/kernel/kexec_crash_loaded"
echo enabled >"$T/proc/sys/fs/binfmt_misc/status"
: >"$T/proc/sys/fs/binfmt_misc/register"
# Kernel ohne Taint, zwei Module mit ihren Dateien, ein leeres BPF-Dateisystem (B6). Jetzt sind 50 s
# seit dem Start vergangen: Prozesse mit Startzeit 100 (Ticks) laufen vor dem Freischalten, die mit
# 9000 starten während der Freigabe (B5).
echo 0 >"$T/proc/sys/kernel/tainted"
printf 'loop 40960 0 - Live 0x0\nisofs 61440 1 - Live 0x0\n' >"$T/proc/modules"
KV=$(uname -r)
mkdir -p "$W/lib/modules/$KV/kernel" "$W/sys/fs/bpf" "$W/sys/module/loop" "$W/sys/module/isofs"
for m in loop isofs dummy; do echo "$m" >"$W/lib/modules/$KV/kernel/$m.ko"; done
: >"$W/sys/module/loop/taint" && : >"$W/sys/module/isofs/taint"
echo "50.00 80.00" >"$T/proc/uptime"
# Credentials von Diensten wie auf dem ISO: tmpfs, die Einhängung rw, ihr Superblock ro. Dazu eine
# in einem anderen Dateisystem, die das Ende nicht lesen darf (sie könnte hängen).
CRED=$W/run/credentials
CRED_LINES=("47 30 0:41 / $CRED/getty@tty1.service rw,nosuid,nodev,noexec,relatime,nosymfollow shared:7 - tmpfs none ro,size=1024k,nr_inodes=1024,mode=700"
	"48 30 0:42 / $CRED/getty@tty2.service rw,nosuid,nodev,noexec,relatime,nosymfollow shared:8 - tmpfs none ro,size=1024k,nr_inodes=1024,mode=700"
	"49 30 0:43 / $CRED/systemd-journald.service rw,nosuid,nodev,noexec,relatime,nosymfollow shared:10 - tmpfs none ro,size=1024k,nr_inodes=1024,mode=700"
	"50 30 0:44 / $CRED/fremd.service rw,nosuid,nodev,noexec,relatime shared:11 - fuse.x x rw")
mkdir -p "$CRED/getty@tty1.service" "$CRED/getty@tty2.service" "$CRED/systemd-journald.service" "$CRED/fremd.service"
echo rescue >"$CRED/getty@tty1.service/agetty.autologin"
# Suchpfade für Unit-Dateien (Q7): Dort legt systemd-run vorübergehende Einheiten an (TR), ein
# Generator hat beim Start geschrieben.
TR=$W/run/systemd/transient
# Der Anfang des Hinweises, vor dem Weiterarbeiten am Netzschalter auszuschalten (switch_hint).
NETZ="Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: "
# Derselbe Hinweis, wenn logind die Sperre des Netzschalters nicht führt (netz_check).
NETZK="Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten (ein kurzer Druck fährt geordnet herunter), nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: "
# Der Hinweis, über Beenden > Ausschalten auszuschalten (alles andere, was ein Weg zu root ist).
AUS="Vor dem Weiterarbeiten ausschalten (Beenden > Ausschalten): Weg zu root aus der Freigabe ("
mkdir -p "$TR" "$W/etc/systemd/system" "$W/run/systemd/system" "$W/run/systemd/generator"
printf '[Unit]\nDescription=Platzhalter\n' >"$W/run/systemd/generator/boot.mount"
# Unit-Dateien unter /usr und ein Dienst, den jeder über D-Bus startet (wie systemd-hostnamed, Q6).
mkdir -p "$W/usr/lib/systemd/system" "$W/usr/share/dbus-1/system-services"
for u in debug-shell.service systemd-hostnamed.service systemd-timedated.service systemd-localed.service systemd-machined.service serial-getty@.service user@.service user-runtime-dir@.service; do
	printf '[Unit]\nDescription=%s\n' "$u" >"$W/usr/lib/systemd/system/$u"
done
# Was systemd-run für ntfs3g_ro und start_rescue sonst setzt, wie auf dem ISO gemessen. Requires gibt
# systemctl in keiner festen Reihenfolge aus.
SAME=$'StandardInput=null\nStandardOutput=journal\nStandardError=inherit\nRestart=no\nRestartMode=normal\nUMask=0022\nSlice=system.slice\nSuccessAction=none\nFailureAction=none\nStartLimitAction=none\nJobTimeoutAction=none\nNeedDaemonReload=no\nRequires=system.slice sysinit.target'
# Die Sperre des Netzschalters mit der Unit-Datei aus dem Image (build/overlay). Ihre Eigenschaften in
# der Attrappe von systemctl folgen der Datei, sonst wie bei systemd-run (SAME), noch nicht gestartet;
# reboot_sim setzt sie darauf zurück (netz_reset).
NU=lf-netzschalter.service
NUF=build/overlay/usr/lib/systemd/system/$NU
cp "$NUF" "$W/usr/lib/systemd/system/$NU"
NA=$(sed -n 's/^ExecStart=//p' "$NUF")
{
	printf 'Transient=no\nActiveState=inactive\nMainPID=0\nControlGroup=/system.slice/%s\nFragmentPath=%s\n' "$NU" "$W/usr/lib/systemd/system/$NU"
	printf 'Type=%s\nUnsetEnvironment=%s\n' "$(sed -n 's/^Type=//p' "$NUF")" "$(sed -n 's/^UnsetEnvironment=//p' "$NUF")"
	printf 'ExecStart={ path=%s ; argv[]=%s ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n%s\n' \
		"${NA%% *}" "$NA" "$SAME"
} >"$T/netz-eigenschaften"
cp "$T/netz-eigenschaften" "$T/unit/$NU"
for n in hostname1:hostnamed timedate1:timedated locale1:localed machine1:machined; do
	printf '[D-BUS Service]\nName=org.freedesktop.%s\nExec=/bin/false\nUser=root\nSystemdService=dbus-org.freedesktop.%s.service\n' "${n%%:*}" "${n%%:*}" \
		>"$W/usr/share/dbus-1/system-services/org.freedesktop.${n%%:*}.service"
done
# Das Home des Live-Benutzers (der Techniker, sudo ohne Kennwort) mit seinen Dotfiles.
mkdir -p "$W/home/rescue/.local/bin"
echo "# profile" >"$W/home/rescue/.profile"
# Sein Benutzer-Manager (systemctl --user mit XDG_RUNTIME_DIR=/run/user/1000), noch ohne Einheiten,
# und der Ordner für linger (B4).
mkdir -p "$T/user/1000/unit" "$W/var/lib/systemd/linger"
printf 'HOME=/home/rescue\nLANG=C.UTF-8\nPATH=/usr/bin:/bin\n' >"$T/user/1000/env"
: >"$T/user/1000/units"
# EFI-Variablen (efivarfs, NAME-GUID) und der persistente Speicher LF-DATA, nicht eingehängt (Q11).
EV=$W/sys/firmware/efi/efivars
GV=8be4df61-93ca-11d2-aa0d-00e098032b8c
GM=605dab50-e046-4300-abb6-3dd810dd8b23
mkdir -p "$EV" "$W/persist"
printf '\007\000\000\000\001\000' >"$EV/BootOrder-$GV"
printf '\007\000\000\000eins' >"$EV/Boot0001-$GV"
printf '\007\000\000\000\005\000' >"$EV/Timeout-$GV"
printf '\006\000\000\000mok' >"$EV/MokListRT-$GM"
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
# boot   Eine neue boot_id wie nach einem echten Neustart (reboot_sim). Ein soft-reboot behält sie.
boot() {
	local n
	n=$(($(cat "$T/boot-n" 2>/dev/null || echo 0) + 1))
	echo "$n" >"$T/boot-n"
	mkdir -p "$T/proc/sys/kernel/random"
	printf '%08x-0000-4000-8000-%012x\n' "$n" "$n" >"$T/proc/sys/kernel/random/boot_id"
}
boot
# Die Umgebung des systemd-Managers (busctl, systemctl set-environment).
echo '["LANG=C.UTF-8","PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]' >"$T/menv.json"
ENV_UNSAFE=$(sed -n 's/^ENV_UNSAFE="\(.*\)"$/\1/p' rescue/bin/lf-freigabe)
F="$T/lf-freigabe"
sed -e "s|^PATH=.*|PATH=$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|" \
	-e "s|/etc/sudoers.d/|$T/sudoers.d/|g" -e "s|^SUDOERS=.*|SUDOERS=$T/sudoers|" -e "s#/run/lf\([^-]\|\$\)#$T/run\1#g" \
	-e "s|/proc/|$T/proc/|g" -e "s|^SUDO_EXE=.*|SUDO_EXE=$T/bin/sudo|" -e "s|^CGROOT=.*|CGROOT=$T/cg|" \
	-e "s|^LINGER=.*|LINGER=$T/linger|" -e "s|^CRON_PATHS=.*|CRON_PATHS=($T/cron.d)|" -e "s|^TTY=.*|TTY=$T/tty|" \
	-e "s|^SYS_BLOCK=.*|SYS_BLOCK=$T/sysblock|" -e "s|^NTFS3G=.*|NTFS3G=$T/bin/ntfs-3g|" \
	-e "s|^WROOT=.*|WROOT=$W|" -e "s|^AUFGABE=.*|AUFGABE=$T/bin/lf-aufgabe|" -e "s|^SCAN_TIMEOUT=.*|SCAN_TIMEOUT=5|" \
	-e "s|^PERL=.*|PERL=$T/bin/perl|" -e "s|^INHIBIT_EXE=.*|INHIBIT_EXE=$T/bin/systemd-inhibit|" -e "s|((EUID == 0))|((EUID == $(id -u)))|g" \
	-e "s|^USER_PATH=.*|USER_PATH=$T/bin:/usr/bin:/bin|" rescue/bin/lf-freigabe >"$F"

cat >"$T/bin/id" <<MOCK
#!/bin/bash
case "\$*" in
"-u lf-claude") echo 1001 ;;
"-g lf-claude") echo 1001 ;;
"-G lf-claude") echo 1001 993 ;;
"-Gn lf-claude") cat "$T/groups" ;;
"-u rescue") echo 1000 ;;
"-g 1000") echo 1000 ;;
"-g 0") echo 0 ;;
"-nu 0") echo root ;;
"-nu 1000") echo rescue ;;
"-nu 1001") echo lf-claude ;;
*) exec /usr/bin/id "\$@" ;;
esac
MOCK
# sudo -l: die Kopfzeile, die Grundregel nur, solange ihre Datei da ist (gesperrt liest sudo sie
# nicht: ein Punkt im Namen), dann die weiteren Zeilen aus sudo-l.
cat >"$T/bin/sudo" <<MOCK
#!/bin/bash
if [[ "\$*" == "-l -U lf-claude" ]]; then
	head -n 1 "$T/sudo-l"
	[[ -e "$T/sudoers.d/lf-claude" || -L "$T/sudoers.d/lf-claude" ]] && sed -n 2p "$T/sudo-l"
	sed -n '3,\$p' "$T/sudo-l"
	exit 0
fi
exit 1
MOCK
# systemctl: Timer aus timers.json, Einheiten aus units (Liste) und unit/NAME (Eigenschaften).
cat >"$T/bin/systemctl" <<MOCK
#!/bin/bash
echo "\$*" >>"$T/systemctl.log"
# --user: der Manager des Benutzers aus XDG_RUNTIME_DIR, mit seinen Einheiten unter user/UID.
D="$T"
if [[ \$1 == --user ]]; then
	shift
	D="$T/user/\${XDG_RUNTIME_DIR##*/}"
	[[ -d \$D ]] || exit 1
	[[ \$1 == show-environment ]] && { cat "\$D/env"; exit; }
fi
u=\${!#}
case \$1 in
list-timers) cat "$T/timers.json" 2>/dev/null || echo "[]" ;;
list-units)
	# Mit welchen Rechten die erste Datei des Schnappschusses dann da ist (snapshot fragt danach).
	[[ -e "$T/run/claude-freigabe-vorher/zeit" ]] && stat -c %a "$T/run/claude-freigabe-vorher/zeit" >>"$T/zeit-rechte.log"
	# Mit --type nur Einheiten dieser Arten, ohne --all nur die, die nicht inaktiv sind.
	types=""
	for a in "\$@"; do [[ \$a == --type=* ]] && types=",\${a#--type=},"; done
	while read -r n _; do
		[[ -z \$types || \$types == *",\${n##*.},"* ]] || continue
		[[ " \$* " == *" --all "* ]] || ! grep -qx ActiveState=inactive "\$D/unit/\$n" 2>/dev/null || continue
		echo "\$n loaded active running x"
	done < <(sort -u "\$D/units" 2>/dev/null)
	;;
show)
	if [[ "\$*" == "show -p ControlGroup --value lf-claude.slice" ]]; then
		echo /lf.slice/lf-claude.slice
	elif [[ " \$* " == *" -- "* ]]; then
		# Mehrere Einheiten (show -p A -p B -- EINHEIT…): wie systemctl je Einheit ein Block,
		# dazwischen eine Leerzeile.
		want=()
		while [[ \$1 != -- ]]; do [[ \$1 == -p ]] && { want+=(\${2//,/ }); shift; }; shift; done
		shift
		first=1
		for n in "\$@"; do
			((first)) || echo
			first=0
			for p in "\${want[@]}"; do
				if [[ \$p == Id ]]; then echo "Id=\$n"; else grep -m1 "^\$p=" "\$D/unit/\$n" 2>/dev/null || echo "\$p="; fi
			done
		done
	else
		# Nur die Eigenschaften, nach denen -p fragt (wie systemctl), mit --value nur die Werte.
		# FreezerState folgt freeze und thaw.
		want=" " val=0
		while ((\$#)); do
			case \$1 in -p) want+="\${2//,/ } " && shift ;; --value) val=1 ;; esac
			shift
		done
		{
			grep -v '^FreezerState=' "\$D/unit/\$u" 2>/dev/null
			if [[ -e "$T/frozen-\$u" ]]; then echo FreezerState=frozen; else echo FreezerState=running; fi
		} | while IFS= read -r l; do
			[[ \$want == *" \${l%%=*} "* ]] || continue
			if ((val)); then printf '%s\n' "\${l#*=}"; else printf '%s\n' "\$l"; fi
		done
	fi
	;;
# Angehalten (freeze) stoppt systemd 259 keine Einheit. Eine mit Prozessen ist nach kill -s KILL
# schon weg; eine ohne (Datei prozesslos-NAME, etwa user-runtime-dir@0) bleibt aktiv. Timer,
# Sockets, Pfade und Automounts lassen sich nicht anhalten, eine Einheit mit der Datei
# nicht-anhaltbar-NAME auch nicht. Mit der Datei abbruch-bei-NAME bricht das Ende ab (KILL an den
# Aufrufer), wenn es NAME anhalten will. Mit der Datei sperre-zurueck-bei-NAME hat NAME die gesperrte
# Grundregel zurückgeschoben, bevor das Ende sie anhält.
freeze)
	[[ -e "$T/abbruch-bei-\$u" ]] && { kill -KILL "\$PPID"; exit 1; }
	if [[ -e "$T/sperre-zurueck-bei-\$u" && -f "$T/sudoers.d/lf-claude.lf-gesperrt" ]]; then
		mv "$T/sudoers.d/lf-claude.lf-gesperrt" "$T/sudoers.d/lf-claude"
		# Mit der Datei sperre-fest-bei-NAME lässt sie sich danach nicht mehr verschieben (mv-fest).
		[[ -e "$T/sperre-fest-bei-\$u" ]] && touch "$T/mv-fest"
	fi
	case \$u in *.timer | *.socket | *.path | *.automount) echo "Unit \$u does not support freezing" >&2 && exit 1 ;; esac
	[[ -e "$T/nicht-anhaltbar-\$u" ]] && { echo "Failed to freeze unit \$u" >&2; exit 1; }
	touch "$T/frozen-\$u"
	;;
thaw) rm -f "$T/frozen-\$u" ;;
# Die Sperre des Netzschalters: start und restart legen den Hauptprozess systemd-inhibit mit dem Kind
# sleep neu an (neue PIDs und InvocationID, die Umgebung des Managers ohne UnsetEnvironment), start
# nur, wenn sie nicht läuft. Mit der Datei netz-startet-nicht startet sie nicht, mit
# netz-anderes-programm führt ihr Hauptprozess ein anderes Programm aus. Mit der Datei
# netz-ohne-haupt fehlen beim nächsten Start der Hauptprozess und sein Kind in ihrer cgroup, dafür
# stehen die PIDs aus der Datei darin (nur echte: Die PIDs der Attrappe sind zu groß für kill, sie
# gelten nie als beendet).
start | restart)
	[[ \$u == $NU && -f "$T/unit/\$u" && ! -e "$T/netz-startet-nicht" ]] || exit 0
	[[ \$1 == start ]] && grep -qx ActiveState=active "$T/unit/\$u" && exit 0
	T="$T"
	source "$T/fake.sh"
	old=\$(sed -n 's/^MainPID=//p' "$T/unit/\$u")
	[[ \$old =~ ^[1-9][0-9]*\$ ]] && rm -rf "$T/proc/\$old" "$T/proc/\$((old + 1))"
	n=\$((\$(cat "$T/netz-n" 2>/dev/null || echo 0) + 1))
	echo "\$n" >"$T/netz-n"
	pid=\$((4194380000 + 2 * n))
	env=\$(jq -r --arg x "\$(sed -n 's/^UnsetEnvironment=//p' "$T/unit/\$u")" '(\$x | split(" ")) as \$x | [.[] | select((split("=")[0]) as \$n | \$x | any(.[]; . == \$n) | not)] + ["INVOCATION_ID=x"] | join("|")' "$T/menv.json")
	cmd=\$(sed -n 's/^ExecStart={ path=[^ ]* ; argv\[\]=\(.*\) ; ignore_errors=no ; .*/\1/p' "$T/unit/\$u")
	x="$T/bin/systemd-inhibit"
	[[ -e "$T/netz-anderes-programm" ]] && x="$T/bin/ntfs-3g"
	fake "\$pid" 0 0 1 "\$env" "\$cmd" "\$x" 0 9000
	fake "\$((pid + 1))" 0 0 "\$pid" "\$env" "/usr/bin/sleep infinity" "" 0 9000
	for p in "\$pid" "\$((pid + 1))"; do
		ln -sfn / "$T/proc/\$p/root"
		mkdir -p "$T/proc/\$p/ns" && ln -sfn "$T/proc/1/ns/mnt" "$T/proc/\$p/ns/mnt"
	done
	mkdir -p "$T/cg/system.slice/\$u"
	if [[ -e "$T/netz-ohne-haupt" ]]; then
		cat "$T/netz-ohne-haupt" >"$T/cg/system.slice/\$u/cgroup.procs"
		rm -f "$T/netz-ohne-haupt"
	else
		printf '%s\n' "\$pid" "\$((pid + 1))" >"$T/cg/system.slice/\$u/cgroup.procs"
	fi
	{
		grep -v -e '^ActiveState=' -e '^MainPID=' -e '^InvocationID=' "$T/unit/\$u"
		printf 'ActiveState=active\nMainPID=%s\nInvocationID=%032x\n' "\$pid" "\$((n + 65536))"
	} >"$T/unit/\$u.neu" && mv "$T/unit/\$u.neu" "$T/unit/\$u"
	grep -q "^\$u " "$T/units" 2>/dev/null || echo "\$u loaded active running x" >>"$T/units"
	;;
stop)
	if [[ -e "$T/frozen-\$u" && -e "$T/prozesslos-\$u" ]]; then
		echo "Cannot stop frozen unit \$u" >&2
		exit 1
	fi
	if [[ -f "$T/unit/\$u" ]]; then
		if [[ \$u == $NU ]]; then
			old=\$(sed -n 's/^MainPID=//p' "$T/unit/\$u")
			[[ \$old =~ ^[1-9][0-9]*\$ ]] && rm -rf "$T/proc/\$old" "$T/proc/\$((old + 1))"
			rm -f "$T/cg/system.slice/\$u/cgroup.procs"
			sed -i 's/^MainPID=.*/MainPID=0/' "$T/unit/\$u"
		fi
		sed -i 's/^ActiveState=.*/ActiveState=inactive/' "$T/unit/\$u"
		# Danach räumt systemd die Einheit weg (nicht mehr geladen), eine aus /run/systemd/transient
		# mit ihrer Unit-Datei.
		U=\$u awk '\$1 != ENVIRON["U"]' "$T/units" >"$T/units.neu" && mv "$T/units.neu" "$T/units"
		rm -f "$TR/\$u"
	fi
	;;
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
# Mit der Datei menv-kaputt antwortet busctl für den Manager nicht. ListInhibitors (logind): die Sperre
# des Netzschalters, solange ihr Hauptprozess läuft (die Arten in der Reihenfolge von logind), dazu
# eine von Claude. Mit der Datei netz-ohne-sperre führt logind sie nicht, mit netz-sperre-anders nur
# für zwei Arten, mit netz-sperre-fremd für eine andere PID (das Kind sleep).
cat >"$T/bin/busctl" <<MOCK
#!/bin/bash
env >"$T/busctl.env"
echo "\$*" >>"$T/busctl.log"
if [[ "\$*" == "--json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ListInhibitors" ]]; then
	pid=\$(sed -n 's/^MainPID=//p' "$T/unit/$NU" 2>/dev/null)
	w=sleep:handle-power-key:handle-suspend-key:handle-hibernate-key:handle-lid-switch:handle-reboot-key
	[[ -e "$T/netz-sperre-anders" ]] && w=handle-power-key:handle-reboot-key
	[[ -e "$T/netz-sperre-fremd" ]] && pid=\$((pid + 1))
	c='["shutdown","Claude","x","delay",1001,77]'
	if grep -qx ActiveState=active "$T/unit/$NU" 2>/dev/null && [[ -e "$T/proc/\$pid" && ! -e "$T/netz-ohne-sperre" ]]; then
		printf '{"type":"a(ssssuu)","data":[[["%s","Leuchtfeuer","lf-freigabe","block",0,%s],%s]]}\n' "\$w" "\$pid" "\$c"
	else
		printf '{"type":"a(ssssuu)","data":[[%s]]}\n' "\$c"
	fi
	exit 0
fi
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
# systemd-run: Für "an" legt es wie systemd die Unit-Dateien von Timer und Dienst des Endes an.
cat >"$T/bin/systemd-run" <<MOCK
#!/bin/bash
echo "\$*" >>"$T/systemd-run.log"
if [[ " \$* " == *" --unit=lf-claude-freigabe-ende "* ]]; then
	printf '[Timer]\nOnActiveSec=x\n' >"$TR/lf-claude-freigabe-ende.timer"
	printf '[Service]\nExecStart=/usr/local/bin/lf-freigabe ablauf\n' >"$TR/lf-claude-freigabe-ende.service"
fi
exit 0
MOCK
# perl: kexec_file_load mit KEXEC_FILE_UNLOAD (Systemaufruf und Absturzfall stehen hinter dem
# Programmtext). Mit der Datei kexec-fest bleibt der Kernel geladen (wie nach
# kernel.kexec_load_disabled=1).
cat >"$T/bin/perl" <<MOCK
#!/bin/bash
echo "\$3 \$4" >>"$T/perl.log"
[[ -e "$T/kexec-fest" ]] && exit 1
if [[ \$4 == 1 ]]; then echo 0 >"$W/sys/kernel/kexec_crash_loaded"; else echo 0 >"$W/sys/kernel/kexec_loaded"; fi
exit 0
MOCK
# mv: Mit der Datei mv-fest lässt sich die Grundregel nicht verschieben (etwa ein Ordner, den root
# unveränderlich gemacht hat).
cat >"$T/bin/mv" <<MOCK
#!/bin/bash
if [[ -e "$T/mv-fest" ]]; then for a in "\$@"; do [[ \$a == "$T/sudoers.d/lf-claude" ]] && exit 1; done; fi
exec $(command -v mv) "\$@"
MOCK
printf '#!/bin/bash\necho "$*" >>"%s/loginctl.log"\n[[ $1 == disable-linger ]] && rm -f "%s/linger/$2"\nexit 0\n' "$T" "$T" >"$T/bin/loginctl"
printf '#!/bin/bash\ncat "%s/atq" 2>/dev/null\n' "$T" >"$T/bin/atq"
printf '#!/bin/bash\necho "$*" >>"%s/atrm.log"\n' "$T" >"$T/bin/atrm"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/visudo"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/logger"
# Das Programm systemd-inhibit (Ziel von /proc/PID/exe der Sperre des Netzschalters).
printf '#!/bin/bash\nexit 0\n' >"$T/bin/systemd-inhibit"
# Das Programm ntfs-3g (Ziel von /proc/PID/exe des echten Dienstes) und ein anderes.
printf '#!/bin/bash\nexit 0\n' >"$T/bin/ntfs-3g"
printf '#!/bin/bash\nexit 0\n' >"$T/bin/anderes"
# setpriv: führt den Befehl nach -- aus, ohne den Benutzer zu wechseln (Benutzer-Manager, B4).
printf '#!/bin/bash\nwhile (($#)) && [[ $1 != -- ]]; do shift; done\nshift\nexec "$@"\n' >"$T/bin/setpriv"
# modinfo -k KERNEL -n -- NAME: die Datei des Moduls unter WROOT/lib/modules (B6).
cat >"$T/bin/modinfo" <<MOCK
#!/bin/bash
f="$W/lib/modules/\$2/kernel/\${!#}.ko"
[[ -e \$f ]] && echo "\$f"
MOCK
chmod +x "$T/bin/"*

BASE="    (root) NOPASSWD: /usr/local/bin/lf-lesen, /usr/local/bin/lf-aufgabe"
sudo_l() { printf 'User lf-claude may run the following commands on test:\n%s\n' "$BASE" "$@" >"$T/sudo-l"; }
sudo_l
echo "lf-claude render" >"$T/groups"
LOG="$T/run/claude-aufgaben.log"
RULE="$T/sudoers.d/lf-claude-freigabe"
SNAP="$T/run/claude-freigabe-vorher"
R=$T/run/claude-freigabe-rueckstand
TTY1=$(((4 << 8) | 1))
PTS=$(((136 << 8) | 3))

# fake PID RUID EUID PPID [UMGEBUNG] [BEFEHL] [PROGRAMM] [TTY] [START]   Eintrag in der Attrappe von
#   /proc. UMGEBUNG mit | getrennt, BEFEHL mit Leerzeichen, PROGRAMM wird /proc/PID/exe, TTY die
#   Gerätenummer des steuernden Terminals, START die Startzeit in Ticks (Vorgabe 100: vor dem
#   Freischalten, 9000: während der Freigabe). gid und Gruppen folgen der EUID (lf-claude: 1001 und
#   render 993), mit EUID 0 alle Capabilities. FAKE_STATUS hängt weitere Zeilen an (und ersetzt
#   gleichnamige davor nicht: clean_claude liest jede).
fake() {
	local g gs cap=0000000000000000
	mkdir -p "$T/proc/$1"
	case $3 in 0) g=0 gs=0 cap=000001ffffffffff ;; 1001) g=1001 gs="1001 993" ;; *) g=$3 gs=$3 ;; esac
	printf 'Name:\tx\nState:\tS (sleeping)\nPid:\t%s\nPPid:\t%s\nUid:\t%s\t%s\t%s\t%s\nGid:\t%s\t%s\t%s\t%s\nGroups:\t%s\nCapPrm:\t%s\nCapEff:\t%s\nCapAmb:\t0000000000000000\n%s' \
		"$1" "$4" "$2" "$3" "$3" "$3" "$g" "$g" "$g" "$g" "$gs" "$cap" "$cap" "${FAKE_STATUS:-}" >"$T/proc/$1/status"
	# Wie der Kernel: jede Variable mit \0 am Ende.
	if [[ -n ${5:-} ]]; then printf '%s|' "$5" | tr '|' '\0'; fi >"$T/proc/$1/environ"
	printf '%s' "${6:-x}" | tr ' ' '\0' >"$T/proc/$1/cmdline"
	local cmd=${6:-x}
	cmd=${cmd%% *}
	printf '%s\n' "${cmd##*/}" >"$T/proc/$1/comm"
	rm -f "$T/proc/$1/exe"
	[[ -z ${7:-} ]] || ln -s "$7" "$T/proc/$1/exe"
	printf '%s (%s) S %s %s %s %s 0 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$1" "${cmd##*/}" "$4" "$1" "$1" "${8:-0}" "${9:-100}" >"$T/proc/$1/stat"
}
# Die Attrappe von systemctl legt die Prozesse der Sperre des Netzschalters mit fake an.
declare -f fake >"$T/fake.sh"
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
# spawn_stopped   Wie spawn, aber mit SIGSTOP angehalten: TERM bleibt anhängig wie bei einem Prozess
#   in einer angehaltenen cgroup, nur KILL beendet ihn. Der Prozess selbst tut nichts dagegen.
spawn_stopped() {
	local p
	p=$(spawn)
	kill -STOP "$p"
	echo "$p"
}
# line TEXT   Zeile, in der TEXT zum ersten Mal im Protokoll steht.
line() { grep -n -m1 -F -- "$1" "$LOG" | cut -d: -f1; }

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
NOW=$(date +%s)
# aus_n   Sagt status "aus, Neustart empfohlen (letzte Freigabe bis HH:MM)" (F15)?
aus_n() { [[ $(bash "$F" status) =~ ^aus,\ Neustart\ empfohlen\ \(letzte\ Freigabe\ bis\ [0-9]{2}:[0-9]{2}\)$ ]]; }
# netz_reset   Die Sperre des Netzschalters wie nach dem Start: nicht gestartet, ohne Prozesse, ohne die
#   Marke, dass sie fehlte.
netz_reset() {
	local p
	p=$(sed -n 's/^MainPID=//p' "$T/unit/$NU" 2>/dev/null)
	[[ $p =~ ^[1-9][0-9]*$ ]] && rm -rf "$T/proc/$p" "$T/proc/$((p + 1))"
	rm -rf "$T/cg/system.slice/$NU" "$T/run/claude-netzschalter-frei"
	cp "$T/netz-eigenschaften" "$T/unit/$NU"
	sed -i "/^$NU /d" "$T/units" 2>/dev/null
	return 0
}
# netz_pid   Der Hauptprozess der Sperre in der Attrappe von systemctl.
netz_pid() { sed -n 's/^MainPID=//p' "$T/unit/$NU"; }
# reboot_sim   Neustart nachgestellt: Grundregel zurück, Schnappschuss, Rückstand und ein System für
#   soft-reboot weg (/run liegt im RAM).
reboot_sim() {
	local d
	if [[ -f $T/sudoers.d/lf-claude.lf-gesperrt ]]; then mv "$T/sudoers.d/lf-claude.lf-gesperrt" "$T/sudoers.d/lf-claude"; fi
	for d in "$T/sudoers.d/lf-claude.lf-gesperrt".*; do
		if [[ -f $d/lf-claude ]]; then mv "$d/lf-claude" "$T/sudoers.d/lf-claude"; fi
		rm -rf "$d"
	done
	rm -rf "$SNAP" "$R" "$W/run/nextroot" "$W/run/nextroot.lf-gesperrt."*
	rm -f "$T"/frozen-* "$T"/prozesslos-* "$T"/nicht-anhaltbar-* "$T/run/claude-grundregel-sperre"
	netz_reset
	boot
}
# soft_lock   Ist die Grundregel seit dem Ende gesperrt, bis eines ohne Rückstand abschließt, nicht bis
#   zum Neustart? Die Marke gilt für diesen Start (boot_id), der Rückstand sagt es in der letzten Zeile.
soft_lock() {
	[[ ! -e $T/sudoers.d/lf-claude && -f $T/sudoers.d/lf-claude.lf-gesperrt &&
		$(cat "$T/run/claude-grundregel-sperre" 2>/dev/null) == "ende $(cat "$T/proc/sys/kernel/random/boot_id")" &&
		$(tail -n 1 "$R") == "Grundregel gesperrt, bis ein Ende ohne Rückstand abschließt: $T/sudoers.d/lf-claude.lf-gesperrt" ]] &&
		! grep -q "^Grundregel gesperrt bis zum Neustart" "$R"
}
# base_free   Ist die Grundregel frei: nicht gesperrt, ohne Marke?
base_free() { [[ -f $T/sudoers.d/lf-claude && ! -e $T/sudoers.d/lf-claude.lf-gesperrt && ! -e $T/run/claude-grundregel-sperre ]]; }
# held_ok EINHEIT   Hat das Ende EINHEIT angehalten stehen lassen: angehalten, ohne KILL, Stoppen und
#   Auftauen, im Rückstand?
held_ok() {
	grep -qxF "freeze $1" "$T/systemctl.log" && [[ -e $T/frozen-$1 ]] &&
		! grep -qxF -e "stop $1" -e "kill -s KILL $1" -e "thaw $1" "$T/systemctl.log" &&
		grep -qxF "Einheit angehalten, nicht beendet: $1" "$R"
}

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
check "Freischalten hält aktive Einheiten, Unit-Dateien (mit Timer und Dienst des Endes), NeedDaemonReload, EFI-Variablen und den Speicher fest, Summen und Namen nur für root lesbar" 'grep -qE "^[0-9a-f]{64} - $W/run/systemd/generator/boot.mount$" "$SNAP/unitpaths" && grep -qE "^[0-9a-f]{64} - $TR/lf-claude-freigabe-ende.service$" "$SNAP/unitpaths" && grep -qE "^[0-9a-f]{64} - $TR/lf-claude-freigabe-ende.timer$" "$SNAP/unitpaths" && grep -qxF "d:$(stat -c %a:%u:%g "$W/etc/systemd/system") - $W/etc/systemd/system" "$SNAP/unitpaths" && [[ -f $SNAP/units-aktiv && -f $SNAP/reload ]] && grep -qE "^[0-9a-f]{64} BootOrder-$GV$" "$SNAP/efivars" && [[ $(wc -l <"$SNAP/efivars") == 4 && $(cat "$SNAP/persist-zustand") == zu && ! -s $SNAP/persist ]] && [[ $(stat -c %a "$SNAP/unitpaths") == 600 && $(stat -c %a "$SNAP/efivars") == 600 && $(stat -c %a "$SNAP/persist") == 600 ]]'
check "Freischalten: für jeden lesbar nur Einheiten, sudo-Dateien, Beginn und Kette, alles andere nur für root, schon beim Anlegen (R2)" '(cd "$SNAP" && for f in *; do case $f in units | units-aktiv | sudoers | start | chain) m=644 ;; *) m=600 ;; esac; [[ $(stat -c %a "$f") == "$m" ]] || { echo "    $f: $(stat -c %a "$f")"; exit 1; }; done) && [[ $(stat -c %a "$SNAP/files") == 600 && $(stat -c %a "$SNAP/menv") == 600 && -s $T/zeit-rechte.log ]] && ! grep -qvx 600 "$T/zeit-rechte.log"'
check "die Schnappschüsse, die comm vergleicht, sind ganzzeilig sortiert (wie lf-freigabe: C.UTF-8)" '(for f in units units-aktiv at cron sudoers menv chain knobs mounts reload; do LC_ALL=C.UTF-8 sort -c "$SNAP/$f" 2>/dev/null || exit 1; done)'

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
# nur Umgebung und Befehlszeile wie ein Job von lf-aufgabe: zählt nicht (B5)
fake "$P2" 0 0 1 "SUDO_USER=lf-claude|SUDO_COMMAND=/usr/local/bin/lf-aufgabe klonen /dev/sdb /dev/sdc" "/bin/bash /usr/local/bin/lf-aufgabe klonen" /usr/bin/bash
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
check "Prozesse des Technikers und setuid-Programme ohne sudo laufen weiter" 'kill -0 "$P3" 2>/dev/null && kill -0 "$P5" 2>/dev/null'
check "nur Umgebung und Befehlszeile wie ein Job von lf-aufgabe: beendet (B5)" '! kill -0 "$P2" 2>/dev/null && grep -q "beendet: $P2" "$LOG"'
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
# fragment NAME BESCHREIBUNG TYP BEFEHL…   Die Unit-Datei, wie systemd 259 sie für systemd-run
#   --collect [-p Type=TYP] -p UnsetEnvironment=… --description=BESCHREIBUNG schreibt (gemessen mit
#   systemd 259.9). Ohne TYP keine Zeile Type=.
fragment() {
	local f=$TR/$1 d=$2 t=$3 a q=""
	shift 3
	for a in "$@"; do q+=${q:+ }\"$a\"; done
	rm -f "$f"
	{
		echo "# This is a transient unit file, created programmatically via the systemd API. Do not edit."
		printf '[Unit]\nDescription=%s\nCollectMode=inactive-or-failed\n\n[Service]\n' "$d"
		[[ -z $t ]] || echo "Type=$t"
		echo 'UnsetEnvironment="LD_PRELOAD" "LD_LIBRARY_PATH" "LD_AUDIT" "GLIBC_TUNABLES" "GCONV_PATH" "LOCPATH" "BASH_ENV" "ENV" "SHELLOPTS" "BASHOPTS" "PS4"'
		printf 'ExecStart=\nExecStart=%s\n' "$q"
	} >"$f"
}
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
	unit "$1" yes "/system.slice/$1" "$TR/$1" "{ path=$2 ; argv[]=$2 -o $3 $4 $5 ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
	fragment "$1" "Leuchtfeuer: ntfs-3g, nur lesend unter $5" forking "$2" -o "$3" "$4" "$5"
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
# Die, bei deren Ende systemd noch etwas ausführte: Das Ende hält sie an und beendet sie nicht.
HELD_SP=()
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
for k in ExecCondition ExecStartPre ExecStartPost ExecReload ExecReloadPost ExecStop ExecStopPost; do
	spoof "${k,,}" && prop "$SP" "$k" "$X"
	[[ $k != ExecStop* ]] || HELD_SP+=("$SP")
done
spoof environment && prop "$SP" Environment "LD_PRELOAD=/var/lib/lf-claude/x.so"
spoof envfiles && prop "$SP" EnvironmentFiles "/var/lib/lf-claude/env (ignore_errors=no)"
spoof rootdir && prop "$SP" RootDirectory /var/lib/lf-claude/root
spoof rootimage && prop "$SP" RootImage /var/lib/lf-claude/root.img
spoof user && prop "$SP" User root
spoof onfailure && prop "$SP" OnFailure x.service && HELD_SP+=("$SP")
spoof onsuccess && prop "$SP" OnSuccess x.service && HELD_SP+=("$SP")
spoof upholds && prop "$SP" Upholds x.service
# Eine PAM-Sitzung (systemd schließt sie als root), ein Laufzeitordner (systemd löscht ihn beim
# Stoppen), Aktionen bei zu vielen Starts oder einem hängenden Auftrag, eine Unit-Datei, die nicht
# mehr zu dem passt, was systemd geladen hat.
spoof pamname && prop "$SP" PAMName login
spoof runtimedir && prop "$SP" RuntimeDirectory lf
spoof startlimit && prop "$SP" StartLimitAction reboot && HELD_SP+=("$SP")
spoof jobtimeout && prop "$SP" JobTimeoutAction kexec && HELD_SP+=("$SP")
spoof needreload && prop "$SP" NeedDaemonReload yes
# Die Unit-Datei selbst (kept_fragment): eine Zeile mehr, Zeilen hinter CR in der Beschreibung
# (systemd trennt dort, sed nicht), ein NUL am Ende (in einer Shell-Variablen verschwände es), ein
# anderer Befehl nur in der Datei, eine Verknüpfung auf eine gleiche Datei, keine Datei.
spoof fragline && echo "ExecStopPost=/bin/sh -c /var/lib/lf-claude/x" >>"$TR/$SP"
spoof fragcr && sed -i "s|^Description=.*|&"$'\r'"[Service]"$'\r'"ExecStopPost=/bin/sh -c /var/lib/lf-claude/x|" "$TR/$SP"
spoof fragnul && printf '\0' >>"$TR/$SP"
spoof fragexec && sed -i 's|^ExecStart="|ExecStart="/bin/sh" "-c" "/var/lib/lf-claude/x" "|' "$TR/$SP"
spoof fraglink && mv "$TR/$SP" "$T/fraglink" && ln -s "$T/fraglink" "$TR/$SP"
spoof fragmissing && rm "$TR/$SP"
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
	unit "$1" yes "/system.slice/$1" "$TR/$1" "{ path=/usr/local/bin/lf-rescue-run ; argv[]=/usr/local/bin/lf-rescue-run $2 $3 --no-pause ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
	fragment "$1" "Leuchtfeuer: Rettung ${2##*/}" "" /usr/local/bin/lf-rescue-run "$2" "$3" --no-pause
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
RSPOOFS=() HELD_RS=()
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
rspoof stoppost && prop "$RS" ExecStopPost "$X" && HELD_RS+=("$RS")
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
rspoof onfailure && prop "$RS" OnFailure lf799j.service && HELD_RS+=("$RS")
rspoof forceexit && prop "$RS" RestartForceExitStatus 0
rspoof preventexit && prop "$RS" RestartPreventExitStatus 1
rspoof restartmode && prop "$RS" RestartMode direct
rspoof success && prop "$RS" SuccessAction reboot && HELD_RS+=("$RS")
rspoof failure && prop "$RS" FailureAction reboot && HELD_RS+=("$RS")
rspoof umask && prop "$RS" UMask 0000
rspoof passenv && prop "$RS" PassEnvironment PATH
rspoof workdir && prop "$RS" WorkingDirectory /var/lib/lf-claude
rspoof group && prop "$RS" Group lf-claude
rspoof supgroups && prop "$RS" SupplementaryGroups lf-claude
rspoof ttypath && prop "$RS" TTYPath /dev/tty9
rspoof slice && prop "$RS" Slice lf.slice
rspoof reloadpost && prop "$RS" ExecReloadPost "$X"
rspoof pamname && prop "$RS" PAMName login
rspoof runtimedir && prop "$RS" RuntimeDirectory lf
rspoof startlimit && prop "$RS" StartLimitAction reboot && HELD_RS+=("$RS")
rspoof needreload && prop "$RS" NeedDaemonReload yes
rspoof fragline && echo "ExecStopPost=/bin/sh -c /var/lib/lf-claude/x" >>"$TR/$RS"
# Die Beschreibung in der Unit-Datei nennt einen anderen Fall als die Argumente.
rspoof fragdesc && sed -i 's|^Description=.*|Description=Leuchtfeuer: Rettung ok-anders|' "$TR/$RS"
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
fake 4194399201 1001 0 4194399202 "" "sudo /usr/local/bin/lf-aufgabe einhaengen /dev/sdb1" "$T/bin/sudo"
fake 4194399202 1001 1001 1 "" "bash"
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
Q10=$(spawn_stopped)
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
check "Rettungen mit einer Eigenschaft mehr oder anders als von systemd-run (Ein- und Ausgabe, Abhängigkeiten, Neustart, Gruppen, PAM, Unit-Datei), anderer Umgebung, anderen Argumenten, einem anderen Namen oder Prozess: gestoppt (F16)" 'n=0; for u in "${RSPOOFS[@]}"; do [[ " ${HELD_RS[*]} " == *" $u "* ]] || grep -qxF "stop $u" "$T/systemctl.log" || { echo "    bleibt: $u"; n=$((n + 1)); }; done; ((n == 0 && ${#RSPOOFS[@]} == 51))'
check "Rettungen, bei deren Ende systemd noch etwas ausführte (ExecStopPost=, OnFailure=, SuccessAction=, FailureAction=, StartLimitAction=): angehalten, nicht beendet, Rückstand" 'n=0; for u in "${HELD_RS[@]}"; do held_ok "$u" || { echo "    nicht angehalten: $u"; n=$((n + 1)); }; done; ((n == 0 && ${#HELD_RS[@]} == 5))'
check "pruefen-rettung läuft nur für Rettungen, die sonst genau passen" 'grep -qxF "pruefen-rettung /mnt/lf-target/LF/boese /dev/sdb" "$T/aufgabe.log" && ! grep -q "ok-env\|ok-dropin\|ok-programm\|ok-cmdline\|ok-path\|ok-stdout\|ok-restart\|ok-requires\|ok-umask\|ok-forceexit\|ok-slice\|ok-reloadpost\|ok-pamname\|ok-needreload\|ok-fragline\|ok-fragdesc" "$T/aufgabe.log"'
check "unter einem Namen von vorher neu angelegt oder mit neuer Ergänzung neu gestartet: gestoppt" 'grep -qx "stop run-u5.service" "$T/systemctl.log" && grep -qF "beendet: Einheit run-u5.service" "$LOG" && grep -qx "stop b.service" "$T/systemctl.log"'
check "Ergänzung, deren Pfad systemctl nicht ausgibt, oder gelöschte Unit-Datei: gestoppt" 'grep -qx "stop e.service" "$T/systemctl.log" && grep -qx "stop f.service" "$T/systemctl.log"'
check "ntfs-3g einer nur lesend eingehängten Quelle bleibt, die Quelle verschwindet nicht (GHSA-799j-44qx-x7xj)" '! grep -qxF -e "stop $NT" -e "kill -s KILL $NT" -e "freeze $NT" "$T/systemctl.log" && ! grep -qF "beendet: Einheit $NT" "$LOG"'
check "Dienste, die nur wie ntfs-3g heißen, sind gestoppt" 'n=0; for u in sdb2 sdb3 sdb4 sdb5; do grep -qxF "stop lf-ntfs3g-mnt-lf\x2dimage-$u.service" "$T/systemctl.log" && n=$((n + 1)); done; grep -qxF "stop lf-ntfs3g-x.service" "$T/systemctl.log" && ((n == 4))'
check "ntfs-3g-Dienste mit einer Eigenschaft mehr, anderer Umgebung, Ausgabe oder Unit-Datei oder einem Prozess, der nicht passt, sind gestoppt (F12, F13, F16)" 'n=0; for u in "${SPOOFS[@]}"; do [[ " ${HELD_SP[*]} " == *" $u "* ]] || grep -qxF "stop $u" "$T/systemctl.log" || { echo "    bleibt: $u"; n=$((n + 1)); }; done; ((n == 0 && ${#SPOOFS[@]} == 45))'
check "ntfs-3g-Dienste, bei deren Ende systemd noch etwas ausführte (ExecStop=, ExecStopPost=, OnFailure=, OnSuccess=, StartLimitAction=, JobTimeoutAction=): angehalten, nicht beendet, Rückstand, mit dem Grund im Protokoll" 'n=0; for u in "${HELD_SP[@]}"; do held_ok "$u" || { echo "    nicht angehalten: $u"; n=$((n + 1)); }; done; ((n == 0 && ${#HELD_SP[@]} == 6)) && grep -qF "angehalten, nicht beendet: Einheit ${HELD_SP[0]} (beim Beenden liefe: ExecStop=)" "$LOG" && grep -qF "angehalten, nicht beendet: Einheit ${HELD_SP[5]} (beim Beenden liefe: JobTimeoutAction=kexec)" "$LOG"'
check "der neue at-Auftrag ist entfernt, der alte bleibt" 'grep -qx 2 "$T/atrm.log" && ! grep -qx 1 "$T/atrm.log"'
check "die neue cron-Datei ist gesperrt, nicht gelöscht; die alte bleibt" '[[ -f $T/cron.d/neu.lf-gesperrt && ! -e $T/cron.d/neu && -f $T/cron.d/alt ]]'
check "linger für lf-claude ist aufgehoben" '[[ ! -e $T/linger/lf-claude ]] && grep -qx "disable-linger lf-claude" "$T/loginctl.log"'
check "Reihenfolge: anhalten, Regel, Einheiten, root-Prozesse, weiterlaufen" 'a=$(line "Claude angehalten") u=$(line "beendet: Einheit run-u7.service") r=$(line "Regel entfernt") k=$(line "beendet: $Q1 ") w=$(line "Claude läuft weiter"); [[ -n $a && -n $u && -n $r && -n $k && -n $w ]] && ((a < r && r < u && u < k && k < w))'
check "die cgroups von Claude laufen danach weiter" '[[ $(cat "$CG/cgroup.freeze") == 0 && $(cat "$CGU/cgroup.freeze") == 0 ]]'
check "jede beendete Einheit ist bis zum Neustart ein Rückstand, die Dienste, die bleiben, nicht (Q6)" 'grep -qxF "Einheit beendet: run-u7.service" "$R" && grep -qxF "Einheit beendet: boese.timer" "$R" && grep -qxF "Einheit beendet: ${SPOOFS[0]}" "$R" && grep -qxF "Einheit beendet: ${RSPOOFS[0]}" "$R" && ! grep -qF -e "$NT" -e "$RU" "$R" && [[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: "*"Anmeldung von rescue"*")), Neustart empfohlen" ]]'
check "eine Anmeldung des Technikers aus der Freigabe läuft weiter und ist Rückstand (Q6)" 'grep -qxF "Anmeldung oder Laufzeitordner von rescue seit dem Freischalten: session-5.scope" "$R"'
check "Unit-Dateien der Dienste, die bleiben, sind kein Rückstand, die der angehaltenen schon; die Grundregel bleibt gesperrt, bis ein Ende ohne Rückstand abschließt, nicht bis zum Neustart" '[[ -z $(grep "^Unit-" "$R" | grep -vxF -f <(for u in "${HELD_SP[@]}" "${HELD_RS[@]}"; do echo "Unit-Datei neu: $TR/$u"; done)) ]] && grep -qxF "Unit-Datei neu: $TR/${HELD_SP[0]}" "$R" && soft_lock'
kill "$RK" "$RM" "$NM" "$NB" 2>/dev/null
# Neustart, dann eine Freigabe ohne Rückstand: Die Abschnitte danach brauchen ein sauberes Ende.
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
bash "$F" aus >"$T/out" 2>&1
check "nach dem Neustart: eine Freigabe ohne Änderungen endet sauber, aus, Neustart empfohlen" 'aus_n && [[ ! -e $R ]]'

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
check "nach einem sauberen Ende zählen spätere Änderungen an Dateien, Unit-Dateien, Kette, Einhängungen, Credentials, EFI-Variablen und dem Speicher nicht" '(for f in units-aktiv files unitpaths reload chain mounts creds knobs efivars persist persist-zustand menv zeit beendet; do [[ ! -e $SNAP/$f ]] || exit 1; done)'
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
check "eine weitere sudo-Regel sperrt die Grundregel bis zum Neustart (Q5)" '[[ -f $T/sudoers.d/lf-claude.lf-gesperrt && ! -e $T/sudoers.d/lf-claude ]] && grep -qxF "Grundregel gesperrt bis zum Neustart: $T/sudoers.d/lf-claude.lf-gesperrt" "$R" && grep -qF "bis zum Neustart: sudo: (ALL : ALL) NOPASSWD: ALL" "$LOG"'
check "…: zuerst der Hinweis aufs Ausschalten am Netzschalter, Beenden ruft sudo auf (Befund 3)" '[[ $(head -n 1 "$R") == "Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: sudo)" ]]'
check "bei einem Rückstand bleibt der Schnappschuss der Einheiten" '[[ -f $SNAP/units ]]'
# Nach dem Ende mit Rückstand entstanden (etwa durch das, was root dort eingerichtet hat)
unit run-u12.service yes /system.slice/run-u12.service
sudo_l
echo "lf-claude render" >"$T/groups"
bash "$F" ablauf >"$T/out" 2>&1
check "das nächste Ende prüft weiter gegen den Schnappschuss: eine Einheit von danach ist gestoppt und bleibt Rückstand" 'grep -qx "stop run-u12.service" "$T/systemctl.log" && grep -qxF "Einheit beendet: run-u12.service" "$R" && [[ -f $SNAP/units ]] && grep -q "abgelaufen" "$LOG"'
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
bash "$F" ablauf >"$T/out" 2>&1
check "nach dem Neustart, ohne Rückstand: nach dem Ablauf wieder aus, Neustart empfohlen; ein sauberes Ende löscht den Schnappschuss" 'aus_n && [[ ! -e $R && ! -e $SNAP/units ]]'

echo "status ohne Leserecht auf die Grundregel (#92):"
# Techniker und lf-claude lesen die Grundregel nicht (0440, root), root schon: Sein Schnappschuss hat
# ihre Prüfsumme. Im Test: Rechte 000, im Schnappschuss dieselben Rechte und die Prüfsumme von vorher.
cp "$SNAP/sudoers" "$T/schnappschuss-92"
cp "$T/sudoers.d/lf-claude" "$T/grundregel-92"
m92=$(stat -c %a "$T/sudoers.d/lf-claude")
chmod 000 "$T/sudoers.d/lf-claude"
awk -v b="$T/sudoers.d/lf-claude" -v m="$(stat -c %f "$T/sudoers.d/lf-claude")" '$1 == b && $2 ~ /^inhalt:/ { sub(/^inhalt:[0-9a-f]+:/, "inhalt:" m ":", $2) } { print }' "$T/schnappschuss-92" >"$SNAP/sudoers"
check "der Schnappschuss hat Rechte 000 und die Prüfsumme der Grundregel" '[[ $(grep -c "^$T/sudoers.d/lf-claude inhalt:8000:[0-9]*:[0-9]*:[0-9]*:[0-9a-f]\{64\}$" "$SNAP/sudoers") == 1 ]]'
check "ohne Leserecht nach einem sauberen Ende: aus, Neustart empfohlen, nichts auf stderr" 'aus_n && [[ -z $(bash "$F" status 2>&1 >/dev/null) ]]'
check "ohne Leserecht: die Statuszeile von Claude sagt Neustart empfohlen, kein ACHTUNG" '[[ $(bash "$F" zeile </dev/null 2>&1) =~ ^Leuchtfeuer:\ Claude\ arbeitet\ mit\ lf-lesen\ und\ lf-aufgabe,\ Neustart\ empfohlen\ \(letzte\ Freigabe\ bis\ [0-9]{2}:[0-9]{2}\)$ ]]'
chmod 004 "$T/sudoers.d/lf-claude"
check "ohne Leserecht: andere Rechte der Grundregel bleiben Rückstand" '[[ $(bash "$F" status 2>/dev/null) == "an: Rückstand nach der Freigabe (sudo-Datei neu oder geändert: $T/sudoers.d/lf-claude), Neustart empfohlen" ]]'
chmod 200 "$T/sudoers.d/lf-claude"
echo "# Platzhalter" >>"$T/sudoers.d/lf-claude"
chmod 000 "$T/sudoers.d/lf-claude"
check "ohne Leserecht: eine andere Größe der Grundregel bleibt Rückstand" '[[ $(bash "$F" status 2>/dev/null) == "an: Rückstand nach der Freigabe (sudo-Datei neu oder geändert: $T/sudoers.d/lf-claude), Neustart empfohlen" ]]'
chmod 600 "$T/sudoers.d/lf-claude"
cat "$T/grundregel-92" >"$T/sudoers.d/lf-claude"
chmod "$m92" "$T/sudoers.d/lf-claude"
cp "$T/schnappschuss-92" "$SNAP/sudoers"
rm -f "$T/grundregel-92" "$T/schnappschuss-92"
check "Grundregel und Schnappschuss wie vorher: aus, Neustart empfohlen" 'aus_n'

echo "Manager-Umgebung (F13):"
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
check "nach dem Hinweis auf einen Neustart schaltet der Techniker ohne Konsole frei, mit neuem Schnappschuss" '[[ -e $RULE && -s $SNAP/menv && -s $SNAP/units ]]'
cp "$T/menv.json" "$T/menv-vorher.json"
# Während der Freigabe als root gesetzt (systemctl set-environment): neu, geändert, entfernt.
jq -c '[.[] | select(startswith("LANG=") | not)] + ["LANG=de_DE.UTF-8", "LD_PRELOAD=/var/lib/lf-claude/x.so", "BASH_ENV=/var/lib/lf-claude/rc"] | map(select(startswith("PATH=") | not))' "$T/menv-vorher.json" >"$T/menv.json"
# Das Ende läuft mit einer Umgebung, die root vorbereitet haben kann (die Umgebung des Managers
# erbt jeder Dienst, auch der Timer des Endes): ein fremder Bus für busctl, POSIXLY_CORRECT, ein
# HOME mit einer .jq, deren split jede Umgebung für sauber erklärte.
mkdir -p "$T/jqhome" && echo 'def split($s): ["umgangen"];' >"$T/jqhome/.jq"
HOME=$T/jqhome DBUS_SYSTEM_BUS_ADDRESS=unix:path=$T/fremder-bus POSIXLY_CORRECT=1 bash "$F" aus >"$T/out" 2>&1
check "neue Variablen entfernt, geänderte und entfernte wie beim Freischalten" '[[ $(jq -c sort "$T/menv.json") == "$(jq -c sort "$T/menv-vorher.json")" ]]'
check "im Protokoll stehen nur die Namen, keine Werte" 'grep -qF "Manager-Umgebung zurückgesetzt: BASH_ENV LANG LD_PRELOAD PATH " "$LOG" && ! grep -q "x.so\|/rc\|de_DE" "$LOG"'
check "das Ende läuft ohne die Umgebung seines Aufrufs: busctl ohne fremden Bus, jq ohne die .jq aus HOME" '[[ -s $T/busctl.env ]] && ! grep -q "^DBUS_SYSTEM_BUS_ADDRESS=\|^POSIXLY_CORRECT=" "$T/busctl.env" && grep -qxF "HOME=$T/proc/self/cmdline" "$T/busctl.env" && ! grep -q umgangen "$LOG"'
check "zurückgesetzt bleibt sie bis zum Neustart ein Rückstand: Dienste können sie geerbt haben und bekommen beim Beenden TERM, also zuerst der Hinweis aufs Ausschalten am Netzschalter" 'grep -qxF "Manager-Umgebung während der Freigabe geändert, Dienste können sie geerbt haben: BASH_ENV LANG LD_PRELOAD PATH" "$R" && [[ $(head -n 1 "$R") == "${NETZ}Manager-Umgebung)" && $(bash "$F" status) == "an: Rückstand nach der Freigabe (${NETZ}Manager-Umgebung)), Neustart empfohlen" ]]'
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
jq -c '. + ["LD_PRELOAD=/var/lib/lf-claude/x.so"]' "$T/menv-vorher.json" >"$T/menv.json"
touch "$T/menv-fest"
: >"$LOG"
bash "$F" aus >"$T/out" 2>&1
check "lässt sich die Umgebung nicht zurücksetzen: Rückstand mit dem Namen, zuerst der Hinweis aufs Ausschalten am Netzschalter (Befund 3)" 'grep -qF "Manager-Umgebung ließ sich nicht zurücksetzen: LD_PRELOAD " "$LOG" && ! grep -q "Manager-Umgebung zurückgesetzt" "$LOG" && grep -qxF "Manager-Umgebung: LD_PRELOAD" "$T/run/claude-freigabe-rueckstand" && [[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: Manager-Umgebung)), Neustart empfohlen" && $(sed -n 2p "$R") == "Manager-Umgebung: LD_PRELOAD" && $(stat -c %a "$SNAP/menv-zurueckgesetzt") == 600 ]]'
rm -f "$T/menv-fest"
bash "$F" aus >"$T/out" 2>&1
check "ein weiteres aus setzt sie zurück, der Rückstand bleibt bis zum Neustart, mit dem Hinweis aufs Ausschalten am Netzschalter" '[[ $(jq -c sort "$T/menv.json") == "$(jq -c sort "$T/menv-vorher.json")" ]] && grep -qxF "Manager-Umgebung während der Freigabe geändert, Dienste können sie geerbt haben: LD_PRELOAD" "$R" && ! grep -q "^Manager-Umgebung: " "$R" && [[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (${NETZ}Manager-Umgebung)), Neustart empfohlen" ]]'
reboot_sim
check "nach dem Neustart kein Rückstand mehr" 'aus_n'

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
# Ein Kernel für kexec (systemctl reboot startete ihn statt neu), ein System für soft-reboot, Code
# in /etc/lf-release (common.sh und lf-rescue-run lesen es als root ein).
echo 1 >"$W/sys/kernel/kexec_loaded"
mkdir -p "$W/run/nextroot/etc" && echo x >"$W/run/nextroot/etc/os-release"
echo 'LF_VERSION=$(id)' >>"$W/etc/lf-release"
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
check "das Ende läuft durch, auch mit einer Verknüpfung auf /dev/zero und einem FIFO in der Kette" '[[ $RC == 0 ]] && grep -q "Claude läuft weiter" "$LOG"'
check "eine neue ld.so.preload ist gesperrt, nicht gelöscht, und gemeldet" '[[ ! -e $W/etc/ld.so.preload && -f $W/etc/ld.so.preload.lf-gesperrt ]] && grep -qF "gesperrt: $W/etc/ld.so.preload" "$LOG" && grep -qxF "Datei neu: $W/etc/ld.so.preload.lf-gesperrt" "$R"'
check "Drop-in an einer Einheit von vorher: Rückstand" 'grep -qxF "Unit-Datei neu: $W/run/systemd/system/a.service.d/x.conf" "$R" && grep -qxF "Unit-Ordner neu: $W/run/systemd/system/a.service.d" "$R"'
check "shadow, PAM, polkit, SSH und modprobe: Rückstand" 'grep -qxF "Datei geändert: $W/etc/shadow" "$R" && grep -qxF "Datei geändert: $W/etc/pam.d/common-auth" "$R" && grep -qxF "Datei neu: $W/etc/polkit-1/rules.d/00-x.rules" "$R" && grep -qxF "Datei neu: $W/root/.ssh/authorized_keys" "$R" && grep -qxF "Datei neu: $W/etc/modprobe.d/x.conf" "$R"'
check "setuid-Kopie einer Shell und capabilities: Rückstand" 'grep -qxF "setuid/setgid: $W/var/tmp/sh" "$R" && grep -qxF "capabilities: $W/var/tmp/py cap_setuid=ep" "$R"'
check "lf-aufgabe geändert: Grundregel bis zum Neustart gesperrt, Rückstand" '[[ ! -e $T/sudoers.d/lf-claude && -f $T/sudoers.d/lf-claude.lf-gesperrt ]] && grep -qF "gesperrt: Grundregel von lf-claude ($T/sudoers.d/lf-claude) bis zum Neustart" "$LOG" && grep -qxF "Werkzeug neu oder geändert: $W/usr/local/bin/lf-aufgabe" "$R" && grep -qxF "Grundregel gesperrt bis zum Neustart: $T/sudoers.d/lf-claude.lf-gesperrt" "$R"'
check "unveränderte Werkzeuge und Programme stehen nicht im Rückstand" '! grep -qxF "Werkzeug neu oder geändert: $W/usr/local/bin/lf-lesen" "$R" && ! grep -qF "$CS" "$R"'
check "neue Verknüpfung und FIFO in der Kette: Rückstand, ohne sie zu lesen" 'grep -qxF "Werkzeug neu oder geändert: $W/usr/local/bin/null" "$R" && grep -qxF "Werkzeug neu oder geändert: $W/usr/local/lib/lf/fifo" "$R"'
check "unter /usr ist jede neue oder geänderte Datei ein Rückstand" 'grep -qxF "Systemdatei neu oder geändert: $W/usr/lib/x86_64-linux-gnu/security/pam_x.so" "$R" && grep -qxF "Systemdatei neu oder geändert: $W/usr/local/bin/null" "$R"'
check "Kernel-Einstellungen: core_pattern, ein neuer binfmt_misc-Eintrag" 'grep -qxF "Kernel-Einstellung neu oder geändert: $T/proc/sys/kernel/core_pattern" "$R" && grep -qxF "Kernel-Einstellung neu oder geändert: $T/proc/sys/fs/binfmt_misc/x" "$R"'
check "ein Kernel für kexec, während der Freigabe geladen: entladen (kexec_file_load), danach kein Rückstand dafür (9)" 'grep -qF "entladen: Kernel für kexec (kexec_loaded)" "$LOG" && grep -qxE "(320|294) 0" "$T/perl.log" && [[ $(cat "$W/sys/kernel/kexec_loaded") == 0 ]] && ! grep -qF "kexec" "$R"'
check "ein System für soft-reboot ist gesperrt, nicht gelöscht, und gemeldet" 'n=("$W"/run/nextroot.lf-gesperrt.*/nextroot/etc/os-release); [[ ! -e $W/run/nextroot && -f ${n[0]} ]] && grep -qF "gesperrt: $W/run/nextroot (jetzt $W/run/nextroot.lf-gesperrt." "$LOG" && grep -qxF "System für soft-reboot: ${n[0]%/nextroot/etc/os-release}" "$R"'
check "/etc/lf-release geändert: Werkzeug der Grundregel" 'grep -qxF "Werkzeug neu oder geändert: $W/etc/lf-release" "$R"'
check "Einhängung über lf-lesen: Rückstand, auch mit nosuid; eine Quelle wie von lf-aufgabe nicht" 'grep -qxF "Einhängung neu oder geändert: $W/usr/local/bin/lf-lesen (overlay overlay)" "$R" && grep -qxF "Einhängung neu oder geändert: /mnt/lf-image/sdc2 (ntfs3 /dev/sdc2)" "$R" && ! grep -q "/mnt/lf-image/sdc1" "$R"'
check "Einhängungen, die nur wie eine Quelle von lf-aufgabe aussehen: Rückstand" 'grep -qxF "Einhängung neu oder geändert: /mnt/lf-image/sdc3 (ext4 /dev/sdc3)" "$R" && grep -qxF "Einhängung neu oder geändert: /mnt/lf-image/sdc4 (tmpfs tmpfs)" "$R" && grep -qxF "Einhängung neu oder geändert: /mnt/lf-image/dm-0 (ext4 /dev/dm-0)" "$R"'
check "eine Rettung mit geänderter Kette ist gestoppt, lf-aufgabe läuft dafür nicht" 'grep -qxF "stop $RU2" "$T/systemctl.log" && ! grep -q "ok-kette" "$T/aufgabe.log"'
check "Credentials: Inhalt geändert, ohne Einhängung, neu in einer Ablage: Rückstand; im anderen Dateisystem liest das Ende nicht" 'grep -qxF "Credentials geändert: $CRED/getty@tty1.service" "$R" && grep -qxF "Credentials geändert: $CRED/getty@tty2.service" "$R" && grep -qxF "Credentials ohne Einhängung: $CRED/systemd-journald.service" "$R" && grep -qxF "Datei neu: $W/run/credstore/login.noauth" "$R" && ! grep -q "fremd.service" "$R"'
check "status: an, Rückstand; zuerst der Hinweis aufs Ausschalten am Netzschalter (PAM, modprobe, Drop-in), dann die Sperre; die Statuszeile warnt (A3, Befund 3)" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: $W/etc/pam.d/common-auth, $W/etc/modprobe.d/x.conf, $W/run/systemd/system/a.service.d/x.conf, …)), Neustart empfohlen" && $(sed -n 2p "$R") == "Grundregel gesperrt bis zum Neustart: $T/sudoers.d/lf-claude.lf-gesperrt" && $(bash "$F" zeile </dev/null) == ACHTUNG* ]]'
echo rescue >"$CRED/getty@tty1.service/agetty.autologin"
rm -f "$CRED/getty@tty2.service/login.noauth" "$CRED/fremd.service/y"
rm -r "$W/run/credstore"
printf '%s\n' "${CRED_LINES[2]}" >>"$T/proc/1/mountinfo"

echo "Kette über Verknüpfungen, hängende Prüfungen (F14):"
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
check "eine Rettung, deren Prüfung hängt, ist gestoppt; die Grundregel bleibt gesperrt, bis ein Ende ohne Rückstand abschließt, nicht bis zum Neustart" 'grep -qxF "stop $RU3" "$T/systemctl.log" && soft_lock'
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

echo "Einheiten aus Unit-Dateien des Systems, Konsolen und Benutzer (Q6):"
reboot_sim
: >"$T/systemctl.log"
: >"$LOG"
US=$W/usr/lib/systemd/system
printf '[Unit]\nDescription=vorher\n' >"$US/vorher.service"
touch -d '-2 minutes' "$US/vorher.service"
unit vorher.service no /system.slice/vorher.service "$US/vorher.service"
bash "$F" an 30 >"$T/out" 2>&1
# Lief schon beim Freischalten und startet nur neu (neue InvocationID, Unit-Datei unverändert).
unit vorher.service no /system.slice/vorher.service "$US/vorher.service"
# Während der Freigabe gestartet: debug-shell (eine Shell als root an tty9) und zwei Dienste, die
# jeder über D-Bus startet, einer davon mit einem Drop-in (ein Platzhalter, nur Description).
unit debug-shell.service no /system.slice/debug-shell.service "$US/debug-shell.service"
unit systemd-hostnamed.service no /system.slice/systemd-hostnamed.service "$US/systemd-hostnamed.service"
prop systemd-hostnamed.service Names "systemd-hostnamed.service dbus-org.freedesktop.hostname1.service"
prop systemd-hostnamed.service Restart no
# Derselbe Fall mit Restart= (eine Abweichung vom Dienst des Systems, die nur Platzhalter ist).
unit systemd-localed.service no /system.slice/systemd-localed.service "$US/systemd-localed.service"
prop systemd-localed.service Names "systemd-localed.service dbus-org.freedesktop.locale1.service"
prop systemd-localed.service Restart on-failure
unit systemd-machined.service no /system.slice/systemd-machined.service "$US/systemd-machined.service"
prop systemd-machined.service Names "systemd-machined.service dbus-org.freedesktop.machine1.service"
prop systemd-machined.service Restart no
prop systemd-machined.service ExecStopPost "{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no }"
mkdir -p "$W/run/systemd/system/systemd-timedated.service.d"
printf '[Unit]\nDescription=Platzhalter\n' >"$W/run/systemd/system/systemd-timedated.service.d/q6.conf"
unit systemd-timedated.service no /system.slice/systemd-timedated.service "$US/systemd-timedated.service" "" "$W/run/systemd/system/systemd-timedated.service.d/q6.conf"
prop systemd-timedated.service Names "systemd-timedated.service dbus-org.freedesktop.timedate1.service"
# Eine serielle Konsole; Benutzerdienst, Laufzeitordner und Anmeldung des Technikers und von root.
unit serial-getty@ttyS0.service no /system.slice/serial-getty@ttyS0.service "$US/serial-getty@.service"
unit user@1000.service no /user.slice/user-1000.slice/user@1000.service "$US/user@.service"
unit user-runtime-dir@1000.service no /user.slice/user-1000.slice/user-runtime-dir@1000.service "$US/user-runtime-dir@.service"
unit session-7.scope yes /user.slice/user-1000.slice/session-7.scope
unit user@0.service no /user.slice/user-0.slice/user@0.service "$US/user@.service"
unit user-runtime-dir@0.service no /user.slice/user-0.slice/user-runtime-dir@0.service "$US/user-runtime-dir@.service"
unit session-8.scope yes /user.slice/user-0.slice/session-8.scope
# Eine Anmeldung von lf-claude und eine eines anderen Benutzers mit seinem Laufzeitordner (mit
# ExecStop= wie in systemd 259; nur die Eigenschaft in der Attrappe).
unit session-9.scope yes /user.slice/user-1001.slice/session-9.scope
unit session-10.scope yes /user.slice/user-1002.slice/session-10.scope
unit user-runtime-dir@1002.service no /user.slice/user-1002.slice/user-runtime-dir@1002.service "$US/user-runtime-dir@.service"
prop user-runtime-dir@1002.service ExecStop "{ path=/usr/lib/systemd/systemd-user-runtime-dir ; argv[]=/usr/lib/systemd/systemd-user-runtime-dir stop 1002 ; ignore_errors=no }"
# Ohne eigene Prozesse: eine Einhängung (die prüft mounts_changed) und ein Ziel.
unit mnt-q6.mount no "" "$W/run/systemd/generator/boot.mount"
unit q6.target no "" ""
# Ein Dienst ohne Prozess (oneshot mit RemainAfterExit), den systemd angehalten nicht stoppt.
unit q6-ohne-prozess.service yes /system.slice/q6-ohne-prozess.service
touch "$T/prozesslos-q6-ohne-prozess.service"
bash "$F" aus >"$T/out" 2>&1
check "debug-shell.service (eine Shell als root an tty9), während der Freigabe gestartet: gestoppt und Rückstand (Q6)" 'grep -qx "stop debug-shell.service" "$T/systemctl.log" && grep -qxF "Einheit beendet: debug-shell.service" "$R"'
check "ein Dienst des Systems, den jeder über D-Bus startet (systemd-hostnamed): gestoppt, ohne Rückstand" 'grep -qx "stop systemd-hostnamed.service" "$T/systemctl.log" && ! grep -qF "systemd-hostnamed" "$R"'
check "derselbe Dienst ist nicht angehalten (systemd 259 startete ihn sonst bis zum Neustart nicht mehr)" '! grep -qx "freeze systemd-hostnamed.service" "$T/systemctl.log" && grep -qx "kill -s KILL systemd-hostnamed.service" "$T/systemctl.log"'
check "ein solcher Dienst mit Restart=: angehalten, gestoppt und Rückstand" 'grep -qx "freeze systemd-localed.service" "$T/systemctl.log" && grep -qx "stop systemd-localed.service" "$T/systemctl.log" && grep -qxF "Einheit beendet: systemd-localed.service" "$R"'
check "derselbe mit ExecStopPost=: angehalten, nicht beendet, Rückstand" 'held_ok systemd-machined.service'
check "derselbe Dienst mit einem Drop-in (systemd-timedated): gestoppt und Rückstand, das Drop-in auch" 'grep -qx "stop systemd-timedated.service" "$T/systemctl.log" && grep -qxF "Einheit beendet: systemd-timedated.service" "$R" && grep -qxF "Unit-Datei neu: $W/run/systemd/system/systemd-timedated.service.d/q6.conf" "$R"'
check "Konsolen, Benutzerdienst, Laufzeitordner und Anmeldung des Technikers bleiben; die von root nicht" '! grep -qE "^(stop|freeze|kill -s KILL) (serial-getty@ttyS0.service|user@1000.service|user-runtime-dir@1000.service|session-7.scope)$" "$T/systemctl.log" && grep -qx "stop user@0.service" "$T/systemctl.log" && grep -qx "stop user-runtime-dir@0.service" "$T/systemctl.log" && grep -qx "stop session-8.scope" "$T/systemctl.log" && grep -qxF "Einheit beendet: user@0.service" "$R"'
check "Anmeldung von lf-claude: bleibt, kein Rückstand; die eines anderen Benutzers: gestoppt, sein Laufzeitordner mit ExecStop= angehalten, nicht beendet (Q6)" '! grep -qE "^(stop|freeze|kill -s KILL) session-9.scope$" "$T/systemctl.log" && ! grep -qF "session-9.scope" "$R" && grep -qx "stop session-10.scope" "$T/systemctl.log" && grep -qxF "Einheit beendet: session-10.scope" "$R" && held_ok user-runtime-dir@1002.service'
check "Anmeldung, Laufzeitordner und Benutzer-Manager des Technikers aus der Freigabe: Rückstand, zuerst der Hinweis aufs Ausschalten (Q6)" 'grep -qxF "Anmeldung oder Laufzeitordner von rescue seit dem Freischalten: session-7.scope user-runtime-dir@1000.service" "$R" && grep -qxF "Benutzer-Manager neu: user@1000.service" "$R" && [[ $(head -n 1 "$R") == "Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: "*"Anmeldung von rescue"* ]]'
check "lief schon beim Freischalten, nur neu gestartet, Unit-Datei unverändert: bleibt" '! grep -qx "stop vorher.service" "$T/systemctl.log"'
check "Einheiten ohne eigene Prozesse (Einhängung, Ziel): nicht gestoppt" '! grep -qE "^stop (mnt-q6.mount|q6.target)$" "$T/systemctl.log"'
check "beendete Dienste des Systems sperren die Grundregel nur, bis ein Ende ohne Rückstand abschließt, nicht bis zum Neustart" 'soft_lock'
check "ein Dienst ohne Prozess, den systemd angehalten nicht stoppt: bleibt angehalten, ein Versuch je Freigabe, Rückstand ohne beendet" '[[ $(grep -cx "stop q6-ohne-prozess.service" "$T/systemctl.log") == 1 && -e $T/frozen-q6-ohne-prozess.service ]] && ! grep -qx "thaw q6-ohne-prozess.service" "$T/systemctl.log" && grep -qxF "Einheit angehalten, nicht beendet: q6-ohne-prozess.service" "$R" && ! grep -qxF "Einheit beendet: q6-ohne-prozess.service" "$R" && grep -qE "^Einheiten: (.* )?q6-ohne-prozess.service( |$)" "$R" && [[ $(grep -c "angehalten, nicht beendet: Einheit q6-ohne-prozess.service" "$LOG") == 1 ]]'
rm -r "$W/run/systemd/system/systemd-timedated.service.d"
# Mit geänderter Umgebung des Managers (ein Platzhalter) liefe ein neuer Start über D-Bus mit ihr.
reboot_sim
: >"$T/systemctl.log"
cp "$T/menv.json" "$T/menv-q6.json"
bash "$F" an 30 >"$T/out" 2>&1
unit systemd-hostnamed.service no /system.slice/systemd-hostnamed.service "$US/systemd-hostnamed.service"
prop systemd-hostnamed.service Names "systemd-hostnamed.service dbus-org.freedesktop.hostname1.service"
prop systemd-hostnamed.service Restart no
jq -c '. + ["LQ6=platzhalter"]' "$T/menv-q6.json" >"$T/menv.json"
bash "$F" aus >"$T/out" 2>&1
check "derselbe Dienst bei geänderter Umgebung des Managers: angehalten, gestoppt und Rückstand" 'grep -qx "freeze systemd-hostnamed.service" "$T/systemctl.log" && grep -qx "stop systemd-hostnamed.service" "$T/systemctl.log" && grep -qxF "Einheit beendet: systemd-hostnamed.service" "$R"'
cp "$T/menv-q6.json" "$T/menv.json"

echo "Suchpfade für Unit-Dateien (Q7):"
reboot_sim
: >"$T/systemctl.log"
: >"$LOG"
# Schon beim Freischalten nicht so geladen, wie es auf der Platte steht: kommt nicht aus der Freigabe.
prop a.service NeedDaemonReload yes
printf '[Unit]\nDescription=gleich\n' >"$W/run/systemd/generator/gleich.mount"
bash "$F" an 30 >"$T/out" 2>&1
# Platzhalter: ein Drop-in, das nur Description setzt, eine neue Verknüpfung in .wants, eine
# Generator-Datei mit anderem Inhalt und eine mit gleichem Inhalt neu geschrieben (wie bei
# daemon-reload). c.service: Unit-Datei geändert, noch nicht neu geladen.
mkdir -p "$W/etc/systemd/system/c.service.d" "$W/etc/systemd/system/multi-user.target.wants"
printf '[Unit]\nDescription=Platzhalter\n' >"$W/etc/systemd/system/c.service.d/q7.conf"
ln -s "$US/debug-shell.service" "$W/etc/systemd/system/multi-user.target.wants/debug-shell.service"
printf '[Unit]\nDescription=Platzhalter 2\n' >"$W/run/systemd/generator/boot.mount"
cp "$W/run/systemd/generator/gleich.mount" "$T/gleich.mount" && mv -f "$T/gleich.mount" "$W/run/systemd/generator/gleich.mount"
prop c.service NeedDaemonReload yes
bash "$F" aus >"$T/out" 2>&1
check "neues Drop-in, das nur Description setzt: Rückstand, mit seinem Ordner (Q7)" 'grep -qxF "Unit-Datei neu: $W/etc/systemd/system/c.service.d/q7.conf" "$R" && grep -qxF "Unit-Ordner neu: $W/etc/systemd/system/c.service.d" "$R"'
check "neue Verknüpfung in multi-user.target.wants: Rückstand" 'grep -qxF "Unit-Datei neu: $W/etc/systemd/system/multi-user.target.wants/debug-shell.service" "$R"'
check "Generator-Datei mit anderem Inhalt: Rückstand; mit gleichem Inhalt neu geschrieben nicht" 'grep -qxF "Unit-Datei geändert: $W/run/systemd/generator/boot.mount" "$R" && ! grep -qF "gleich.mount" "$R"'
check "NeedDaemonReload=yes am Ende: Rückstand; schon beim Freischalten: nicht" 'grep -qxF "Einheit mit geänderter Unit-Datei (NeedDaemonReload): c.service" "$R" && ! grep -qF "NeedDaemonReload): a.service" "$R"'
check "Timer und Dienst des Endes, wie systemd-run sie anlegt: kein Rückstand" '! grep -qF "lf-claude-freigabe-ende" "$R"'
check "nichts davon betrifft einen Dienst der Grundregel: Sie bleibt nur gesperrt, bis ein Ende ohne Rückstand abschließt" 'soft_lock'
prop a.service NeedDaemonReload no
prop c.service NeedDaemonReload no
rm -r "$W/etc/systemd/system/c.service.d" "$W/etc/systemd/system/multi-user.target.wants"

echo "Grundregel bis zum Neustart gesperrt (Q5):"
# q5 ÄNDERUNG   Freigabe an, ÄNDERUNG (eine Funktion: ein harmloser Platzhalter, während der
#   Freigabe), aus. Ist die Grundregel danach gesperrt, mit dem Grund im Protokoll?
q5() {
	reboot_sim
	: >"$LOG"
	bash "$F" an 30 >"$T/out" 2>&1
	"$1"
	bash "$F" aus >"$T/out" 2>&1
	[[ -f $T/sudoers.d/lf-claude.lf-gesperrt && ! -e $T/sudoers.d/lf-claude ]] &&
		grep -qF "gesperrt: Grundregel von lf-claude ($T/sudoers.d/lf-claude) bis zum Neustart: " "$LOG"
}
q5_usr() { echo "# Platzhalter" >"$W/usr/lib/x86_64-linux-gnu/q5.txt"; }
q5_opt() { mkdir -p "$W/opt/q5"; }
q5_ldso() { mkdir -p "$W/etc/ld.so.conf.d" && echo "# Platzhalter" >"$W/etc/ld.so.conf.d/q5.conf"; }
q5_nss() { echo "# Platzhalter" >>"$W/etc/nsswitch.conf"; }
q5_pam() { echo "# Platzhalter" >>"$W/etc/pam.d/sudo"; }
q5_security() { mkdir -p "$W/etc/security" && echo "# Platzhalter" >>"$W/etc/security/limits.conf"; }
q5_env() { echo "# Platzhalter" >>"$W/etc/environment"; }
q5_locale() { mkdir -p "$W/etc/default" && echo "# Platzhalter" >>"$W/etc/default/locale"; }
q5_sudoconf() { echo "# Platzhalter" >>"$W/etc/sudo.conf"; }
q5_sudoers() { echo "# Platzhalter" >"$T/sudoers.d/q5"; }
q5_mount() { echo "60 22 0:50 / /mnt/q5 rw,nosuid,nodev,noexec shared:20 - tmpfs tmpfs rw" >>"$T/proc/1/mountinfo"; }
q5_dropin() { mkdir -p "$W/run/systemd/system/service.d" && printf '[Unit]\nDescription=Platzhalter\n' >"$W/run/systemd/system/service.d/q5.conf"; }
q5_prefix() { mkdir -p "$W/run/systemd/system.control/lf-.service.d" && printf '[Unit]\nDescription=Platzhalter\n' >"$W/run/systemd/system.control/lf-.service.d/q5.conf"; }
q5_own() { echo "Description=Platzhalter" >>"$TR/lf-claude-freigabe-ende.service"; }
q5_reload() { prop "$NT" NeedDaemonReload yes; }
q5_kexec() { echo 1 >"$W/sys/kernel/kexec_crash_loaded" && touch "$T/kexec-fest"; }
n=0
for c in usr opt ldso nss pam security env locale sudoconf sudoers mount dropin prefix own reload kexec; do
	q5 "q5_$c" || { echo "    nicht gesperrt: $c"; n=$((n + 1)); }
done
check "Dateien unter /usr und /opt, Lader, NSS, PAM, sudo, die Umgebung von sudo, eine Einhängung, Unit-Dateien für Dienste der Grundregel und ihr Ende: Grundregel bis zum Neustart gesperrt" '((n == 0))'
check "ein Kernel für den Absturzfall, der sich nicht entladen lässt: Rückstand, Grundregel gesperrt (9)" 'grep -qF "ließ sich nicht entladen: Kernel für kexec (kexec_crash_loaded)" "$LOG" && grep -qxE "(320|294) 1" "$T/perl.log" && grep -qxF "Kernel-Einstellung neu oder geändert: $W/sys/kernel/kexec_crash_loaded" "$R"'
rm -f "$T/kexec-fest" "$T/sudoers.d/q5"
echo 0 >"$W/sys/kernel/kexec_crash_loaded"
sed -i '\| /mnt/q5 |d' "$T/proc/1/mountinfo"
prop "$NT" NeedDaemonReload no
rm -r "$W/run/systemd/system/service.d" "$W/run/systemd/system.control"
# Andere Dateien in /etc und in den Homes, eine neue Konsole und eine Quelle wie von lf-aufgabe.
reboot_sim
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
echo q5 >"$W/etc/hostname"
echo "# Platzhalter" >>"$W/home/rescue/.profile"
echo "# Platzhalter" >"$W/home/rescue/.local/bin/q5"
echo "61 22 8:49 / /mnt/lf-image/sdd1 ro,nosuid,nodev,noexec,relatime shared:9 - ntfs3 /dev/sdd1 ro" >>"$T/proc/1/mountinfo"
mkdir -p "$CRED/getty@tty3.service"
echo "62 30 0:51 / $CRED/getty@tty3.service rw,nosuid,nodev,noexec,relatime,nosymfollow shared:21 - tmpfs none ro,size=1024k,nr_inodes=1024,mode=700" >>"$T/proc/1/mountinfo"
bash "$F" aus >"$T/out" 2>&1
check "andere Dateien in /etc, Dotfiles, eine neue Konsole: Rückstand, die Grundregel nicht bis zum Neustart gesperrt; eine Quelle wie von lf-aufgabe ist nichts" 'soft_lock && grep -qxF "Datei neu: $W/etc/hostname" "$R" && grep -qxF "Datei geändert: $W/home/rescue/.profile" "$R" && grep -qxF "Datei neu: $W/home/rescue/.local/bin/q5" "$R" && grep -qxF "Einhängung neu oder geändert: $CRED/getty@tty3.service (tmpfs none)" "$R" && ! grep -q "/mnt/lf-image/sdd1" "$R"'
sed -i -e '\| /mnt/lf-image/sdd1 |d' -e "\| $CRED/getty@tty3.service |d" "$T/proc/1/mountinfo"
rm -r "$CRED/getty@tty3.service"
# Dienste der Grundregel, während der Freigabe gestartet, bei gesperrter Grundregel.
reboot_sim
: >"$T/systemctl.log"
bash "$F" an 30 >"$T/out" 2>&1
NT7='lf-ntfs3g-mnt-lf\x2dimage-sdb7.service'
ntfs "$NT7" /usr/bin/ntfs-3g ro,nodev,nosuid,noexec,recover /dev/sdb1 /mnt/lf-image/sdb7
RU6=$(runit /mnt/lf-target/LF/ok-gesperrt)
rescue "$RU6" /mnt/lf-target/LF/ok-gesperrt /dev/sdb
echo "# Platzhalter" >"$W/usr/lib/x86_64-linux-gnu/q5-dienste.txt"
bash "$F" aus >"$T/out" 2>&1
check "gesperrte Grundregel: ntfs-3g und Rettungen aus der Freigabe sind gestoppt und Rückstand, ältere Dienste bleiben (F16)" 'grep -qxF "stop $NT7" "$T/systemctl.log" && grep -qxF "stop $RU6" "$T/systemctl.log" && grep -qxF "Einheit beendet: $NT7" "$R" && grep -qxF "Einheit beendet: $RU6" "$R" && ! grep -qxF "stop $NT" "$T/systemctl.log" && [[ -f $T/sudoers.d/lf-claude.lf-gesperrt ]]'
# Die Grundregel lässt sich nicht verschieben, oder an ihrem Platz steht ein Ordner.
reboot_sim
touch "$T/mv-fest"
bash "$F" an 30 >"$T/out" 2>&1
echo "# Platzhalter" >"$W/usr/lib/x86_64-linux-gnu/q5-fest.txt"
bash "$F" aus >"$T/out" 2>&1
check "lässt sie sich nicht verschieben: gleich nach dem Hinweis aufs Ausschalten am Netzschalter (ihre Jobs, /usr) im Rückstand, einmal; Menü und Statuszeile zeigen den Hinweis" '[[ -f $T/sudoers.d/lf-claude && $(head -n 1 "$R") == "${NETZ}Jobs der Grundregel, $W/usr/lib/x86_64-linux-gnu, $W/usr/lib/x86_64-linux-gnu/q5-fest.txt)" && $(sed -n 2p "$R") == "Grundregel ließ sich nicht sperren: $T/sudoers.d/lf-claude" && $(grep -c "^Grundregel ließ sich nicht sperren" "$R") == 1 && $(bash "$F" status) == "an: Rückstand nach der Freigabe (Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: "* ]]'
rm -f "$T/mv-fest"
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
mkdir -p "$T/sudoers.d/lf-claude.lf-gesperrt/lf-claude"
echo "# Platzhalter" >"$W/usr/lib/x86_64-linux-gnu/q5-ordner.txt"
bash "$F" aus >"$T/out" 2>&1
check "steht an ihrem Platz ein Ordner, kommt sie in einen neuen" 'd=("$T/sudoers.d/lf-claude.lf-gesperrt".*); [[ ! -e $T/sudoers.d/lf-claude && -f ${d[0]}/lf-claude ]] && grep -qxF "Grundregel gesperrt bis zum Neustart: ${d[0]}/lf-claude" "$R"'
rm -r "$T/sudoers.d/lf-claude.lf-gesperrt"

echo "Kernel für kexec (9):"
reboot_sim
echo 1 >"$W/sys/kernel/kexec_loaded"
: >"$T/perl.log"
bash "$F" an 30 >"$T/out" 2>&1
bash "$F" aus >"$T/out" 2>&1
check "ein Kernel für kexec, der schon beim Freischalten geladen war: bleibt geladen, kein Rückstand dafür" '[[ $(cat "$W/sys/kernel/kexec_loaded") == 1 && ! -s $T/perl.log ]] && ! grep -qsF kexec "$R"'
echo 0 >"$W/sys/kernel/kexec_loaded"
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
echo 1 >"$W/sys/kernel/kexec_crash_loaded"
bash "$F" aus >"$T/out" 2>&1
check "ein Kernel für den Absturzfall aus der Freigabe: entladen, kein Rückstand dafür" 'grep -qxE "(320|294) 1" "$T/perl.log" && [[ $(cat "$W/sys/kernel/kexec_crash_loaded") == 0 ]] && ! grep -qsF kexec "$R"'

echo "EFI-Variablen und der Speicher LF-DATA (Q11):"
reboot_sim
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
cp "$EV/BootOrder-$GV" "$T/bootorder"
printf '\007\000\000\000zwei' >"$EV/Boot0002-$GV"
printf '\007\000\000\000\002\000\001\000' >"$EV/BootOrder-$GV"
rm "$EV/Timeout-$GV"
printf '\007\000\000\000neu' >"$EV/MokNew-$GM"
printf '\007\000\000\000x' >"$EV/HerstellerX-12345678-1234-1234-1234-123456789abc"
# Dazu ein Hook, der von selbst als root läuft: Der Hinweis aufs Ausschalten folgt dem zu EFI.
mkdir -p "$W/etc/update-motd.d"
printf '#!/bin/sh\n' >"$W/etc/update-motd.d/98-efi"
bash "$F" aus >"$T/out" 2>&1
check "neue, geänderte und entfernte EFI-Variablen: Rückstand; zurückgeschrieben wird nichts" 'grep -qxF "EFI-Variable neu: Boot0002-$GV" "$R" && grep -qxF "EFI-Variable geändert: BootOrder-$GV" "$R" && grep -qxF "EFI-Variable entfernt: Timeout-$GV" "$R" && grep -qxF "EFI-Variable neu: HerstellerX-12345678-1234-1234-1234-123456789abc" "$R" && [[ -e $EV/Boot0002-$GV && ! -e $EV/Timeout-$GV ]] && ! cmp -s "$EV/BootOrder-$GV" "$T/bootorder"'
H="EFI-Variablen für den Start geändert (BootOrder, Boot0002, MokNew): vor dem nächsten Start die Startreihenfolge im Firmware-Setup prüfen und eine unerwartete MOK-Abfrage ablehnen"
check "Variablen für den Start: zuerst der Hinweis für den Techniker, auch in Menü und Statuszeile" '[[ $(head -n 1 "$R") == "$H" && $(bash "$F" status) == "an: Rückstand nach der Freigabe ($H), Neustart empfohlen" ]]'
check "danach der Hinweis aufs Ausschalten: Ausschalten setzt EFI-Variablen nicht zurück (A3)" '[[ $(sed -n 2p "$R") == "${AUS}$W/etc/update-motd.d/98-efi"* ]]'
check "EFI-Variablen sperren die Grundregel nicht bis zum Neustart" 'soft_lock'
rm -f "$W/etc/update-motd.d/98-efi"
rmdir "$W/etc/update-motd.d" 2>/dev/null
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
mkdir -p "$W/persist/config" "$W/persist/home"
echo "63 22 8:50 / $W/persist rw,nosuid,nodev,noatime shared:22 - ext4 /dev/sdb3 rw" >>"$T/proc/1/mountinfo"
bash "$F" aus >"$T/out" 2>&1
check "LF-DATA während der Freigabe eingehängt: Rückstand, Inhalt ungeprüft; die neue Einhängung sperrt die Grundregel" 'grep -qxF "Speicher LF-DATA während der Freigabe eingehängt, Inhalt ungeprüft: $W/persist" "$R" && grep -qxF "Einhängung neu oder geändert: $W/persist (ext4 /dev/sdb3)" "$R" && [[ -f $T/sudoers.d/lf-claude.lf-gesperrt ]]'
check "…: zuerst der Hinweis, LF-DATA vor dem nächsten Entsperren zu prüfen (der Inhalt bleibt nach dem Ausschalten), dann über Beenden > Ausschalten" '[[ $(head -n 1 "$R") == "Speicher LF-DATA geändert (Inhalt ungeprüft): bleibt nach dem Ausschalten, vor dem nächsten Entsperren prüfen oder neu anlegen" && $(sed -n 2p "$R") == "${AUS}$W/persist, LF-DATA)" ]]'
reboot_sim
echo "LF_TECHNIKER=vorher" >"$W/persist/config/lf.conf"
bash "$F" an 30 >"$T/out" 2>&1
check "beim Freischalten offen: der Inhalt von config und home steht im Schnappschuss" '[[ $(cat "$SNAP/persist-zustand") == offen ]] && grep -qF " $W/persist/config/lf.conf" "$SNAP/persist"'
echo "LF_TECHNIKER=nachher" >"$W/persist/config/lf.conf"
mkdir -p "$W/persist/home/.ssh" && echo "# Platzhalter" >"$W/persist/home/.ssh/authorized_keys"
mkdir -p "$W/persist/claude-home" && echo "# Platzhalter" >"$W/persist/claude-home/notiz"
bash "$F" aus >"$T/out" 2>&1
check "offen geblieben: Änderungen in config und home sind Rückstand, claude-home nicht" 'grep -qxF "Datei auf LF-DATA geändert: $W/persist/config/lf.conf" "$R" && grep -qxF "Ordner auf LF-DATA neu: $W/persist/home/.ssh" "$R" && grep -qxF "Datei auf LF-DATA neu: $W/persist/home/.ssh/authorized_keys" "$R" && ! grep -q claude-home "$R"'
check "…: zuerst der Hinweis auf LF-DATA mit den Pfaden, dann über Beenden > Ausschalten; status zeigt den Hinweis auf LF-DATA" '[[ $(head -n 1 "$R") == "Speicher LF-DATA geändert ($W/persist/config/lf.conf, $W/persist/home/.ssh/authorized_keys, $W/persist/home/.ssh): bleibt nach dem Ausschalten, vor dem nächsten Entsperren prüfen oder neu anlegen" && $(sed -n 2p "$R") == "${AUS}LF-DATA)" && $(bash "$F" status) == "an: Rückstand nach der Freigabe (Speicher LF-DATA geändert ("* ]] && ! grep -qF Netzschalter "$R"'
# Dazu eine Datei, die finalrd beim Ausschalten als root ausführte (Platzhalter): Der Hinweis auf
# LF-DATA hängt an der Zeile zum Netzschalter.
reboot_sim
mkdir -p "$W/run/finalrd"
bash "$F" an 30 >"$T/out" 2>&1
echo "LF_TECHNIKER=danach" >"$W/persist/config/lf.conf"
printf '#!/bin/sh\n' >"$W/run/finalrd/q11.finalrd"
bash "$F" aus >"$T/out" 2>&1
check "…: mit Hinweis aufs Ausschalten am Netzschalter steht der Hinweis auf LF-DATA in derselben Zeile danach" '[[ $(head -n 1 "$R") == "${NETZ}$W/run/finalrd/q11.finalrd). Danach: Speicher LF-DATA geändert ($W/persist/config/lf.conf): bleibt nach dem Ausschalten, vor dem nächsten Entsperren prüfen oder neu anlegen" ]]'
rm -rf "$W/run/finalrd"
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
sed -i "\| $W/persist |d" "$T/proc/1/mountinfo"
bash "$F" aus >"$T/out" 2>&1
check "während der Freigabe ausgehängt: Rückstand, Inhalt ungeprüft" 'grep -qxF "Speicher LF-DATA während der Freigabe ausgehängt, Inhalt ungeprüft: $W/persist" "$R"'

echo "Jobs über LF_JOB_RUN (sudo bash JOB, #72):"
reboot_sim
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
J1=$(spawn) J2=$(spawn)
# Ein Klon des Technikers in tmux (lf, LF_JOB_RUN): sudo bash JOB.
fake 4194399601 1000 1000 1 "" "tmux new-session -d -s lf-klon"
fake 4194399602 1000 0 4194399601 "" "sudo bash /run/lf/klon.sh" "$T/bin/sudo"
fake "$J1" 0 0 4194399602 "SUDO_USER=rescue|SUDO_UID=1000|SUDO_COMMAND=/usr/bin/bash /run/lf/klon.sh" "bash /run/lf/klon.sh" /usr/bin/bash
# Derselbe Aufruf von lf-claude mit der Freigabe.
fake 4194399603 1001 1001 1 "" "bash"
fake 4194399604 1001 0 4194399603 "" "sudo bash /var/lib/lf-claude/job.sh" "$T/bin/sudo"
fake "$J2" 0 0 4194399604 "SUDO_USER=lf-claude|SUDO_UID=1001|SUDO_COMMAND=/usr/bin/bash /var/lib/lf-claude/job.sh" "bash /var/lib/lf-claude/job.sh" /usr/bin/bash
bash "$F" aus >"$T/out" 2>&1
check "ein Job des Technikers über LF_JOB_RUN läuft weiter und ist kein Rückstand; derselbe Aufruf von lf-claude ist beendet (#72)" 'kill -0 "$J1" 2>/dev/null && ! kill -0 "$J2" 2>/dev/null && grep -qF "beendet: $J2 bash /var/lib/lf-claude/job.sh" "$LOG" && ! grep -qsF "$J1" "$R"'
check "die Grundregel erlaubt nie bash, und lf-aufgabe startet nichts über LF_JOB_RUN" '[[ $(sed -n "s/^BASE_RULE=//p" rescue/bin/lf-freigabe) != *bash* ]] && grep -qx "lf-claude ALL=(root) NOPASSWD: /usr/local/bin/lf-lesen, /usr/local/bin/lf-aufgabe" build/chroot-setup.sh && [[ $(sed -n "s/^LF_JOB_RUN=//p" rescue/lib/common.sh) == "(sudo bash)" ]] && ! grep -q "LF_JOB_RUN" rescue/bin/lf-aufgabe'
kill "$J1" 2>/dev/null
cleanproc
reboot_sim

echo "Prozesse und Jobs aus der Freigabe (B5, nur Attrappen von /proc):"
reboot_sim
: >"$T/systemctl.log"
bash "$F" an 30 >"$T/out" 2>&1
check "Freischalten hält fest, wann die Freigabe beginnt (Ticks seit dem Start wie in /proc/PID/stat)" '[[ $(cat "$SNAP/start") == 5000 ]]'
C1=$(spawn) C2=$(spawn) C3=$(spawn) C4=$(spawn) C5=$(spawn) C6=$(spawn) C7=$(spawn) C8=$(spawn)
C9=$(spawn) C10=$(spawn) C11=$(spawn) C12=$(spawn) C13=$(spawn) C14=$(spawn) C15=$(spawn)
# Mit der Freigabe gestartet (Startzeit 9000), als lf-claude in jedem uid- und gid-Feld, nur mit
# dessen Gruppen und ohne capabilities.
fake "$C1" 1001 1001 1 "" "sleep 300" "" 0 9000
# Ebenso, aber mit einer capability (effektiv, erlaubt, ambient), einer Gruppe mehr, gid 0 oder
# gespeicherter uid 0.
fake "$C2" 1001 1001 1 "" "sleep 300" "" 0 9000 && sed -i 's/^CapEff:.*/CapEff:\t0000000000200000/' "$T/proc/$C2/status"
fake "$C3" 1001 1001 1 "" "sleep 300" "" 0 9000 && sed -i 's/^CapPrm:.*/CapPrm:\t0000000000000001/' "$T/proc/$C3/status"
fake "$C4" 1001 1001 1 "" "sleep 300" "" 0 9000 && sed -i 's/^CapAmb:.*/CapAmb:\t0000000000000400/' "$T/proc/$C4/status"
fake "$C5" 1001 1001 1 "" "sleep 300" "" 0 9000 && sed -i 's/^Groups:.*/Groups:\t1001 993 27/' "$T/proc/$C5/status"
fake "$C6" 1001 1001 1 "" "sleep 300" "" 0 9000 && sed -i 's/^Gid:.*/Gid:\t1001\t1001\t0\t1001/' "$T/proc/$C6/status"
fake "$C7" 1001 1001 1 "" "sleep 300" "" 0 9000 && sed -i 's/^Uid:.*/Uid:\t1001\t1001\t0\t1001/' "$T/proc/$C7/status"
# Ein Job von lf-aufgabe aus der Freigabe, von sudo, das lf-claude aufgerufen hat: Root kann an
# einem Prozess, den es startet, alles fälschen.
fake 4194399711 1001 0 4194399712 "" "sudo /usr/local/bin/lf-aufgabe einhaengen /dev/sdb1" "$T/bin/sudo" 0 9000
fake 4194399712 1001 1001 1 "" "bash"
fake "$C8" 0 0 4194399711 "" "/bin/bash /usr/local/bin/lf-aufgabe einhaengen /dev/sdb1" /usr/bin/bash 0 9000
# Ein Job von vorher, Kind und Enkel aus der Freigabe (als root).
fake 4194399713 1001 0 4194399714 "" "sudo /usr/local/bin/lf-aufgabe klonen /dev/sdb /dev/sdc" "$T/bin/sudo"
fake 4194399714 1001 1001 1 "" "bash"
fake "$C9" 0 0 4194399713 "" "/bin/bash /usr/local/bin/lf-aufgabe klonen /dev/sdb /dev/sdc" /usr/bin/bash
fake "$C10" 0 0 "$C9" "" "ddrescue /dev/sdb /dev/sdc" "" 0 9000
fake "$C11" 0 0 "$C10" "" "sleep 300" "" 0 9000
# Jobs von vorher, die nicht genau passen: mit LD_PRELOAD, mit gespeicherter uid von lf-claude,
# ein anderes Programm als bash, von sudo eines anderen Benutzers.
fake 4194399715 1001 0 4194399716 "" "sudo /usr/local/bin/lf-lesen smart /dev/sdb" "$T/bin/sudo"
fake 4194399716 1001 1001 1 "" "bash"
fake "$C12" 0 0 4194399715 "LD_PRELOAD=/var/lib/lf-claude/x.so" "/bin/bash /usr/local/bin/lf-lesen smart /dev/sdb" /usr/bin/bash
fake "$C13" 0 0 4194399715 "" "/bin/bash /usr/local/bin/lf-lesen smart /dev/sdb" /usr/bin/bash && sed -i 's/^Uid:.*/Uid:\t0\t0\t1001\t0/' "$T/proc/$C13/status"
fake "$C14" 0 0 4194399715 "" "/bin/bash /usr/local/bin/lf-lesen smart /dev/sdb" /usr/bin/sleep
fake 4194399717 1000 0 4194399718 "" "sudo /usr/local/bin/lf-lesen smart /dev/sdb" "$T/bin/sudo"
fake "$C15" 0 0 4194399717 "" "/bin/bash /usr/local/bin/lf-lesen smart /dev/sdb" /usr/bin/bash
printf '%s\n' "$C1" "$C2" "$C3" "$C4" "$C5" "$C6" "$C7" "$C8" "$C9" "$C10" "$C11" "$C12" "$C13" "$C14" "$C15" >"$CG/cli.scope/cgroup.procs"
bash "$F" aus >"$T/out" 2>&1
check "aus der Freigabe, als lf-claude ohne weitere Rechte: läuft weiter" 'kill -0 "$C1" 2>/dev/null && ! grep -qF "beendet: $C1 " "$LOG"'
check "aus der Freigabe, mit einer capability, einer Gruppe, gid 0 oder gespeicherter uid 0: beendet" '(for p in "$C2" "$C3" "$C4" "$C5" "$C6" "$C7"; do ! kill -0 "$p" 2>/dev/null && grep -qF "beendet: $p sleep 300" "$LOG" || exit 1; done)'
check "ein Job von lf-aufgabe aus der Freigabe: beendet" '! kill -0 "$C8" 2>/dev/null && grep -qF "beendet: $C8 /bin/bash /usr/local/bin/lf-aufgabe einhaengen" "$LOG"'
check "ein Job von vorher läuft weiter, mit Kind und Enkel aus der Freigabe (nach PPid)" 'kill -0 "$C9" 2>/dev/null && kill -0 "$C10" 2>/dev/null && kill -0 "$C11" 2>/dev/null'
check "Jobs von vorher mit LD_PRELOAD, anderer uid, anderem Programm oder sudo eines anderen Benutzers: beendet" '(for p in "$C12" "$C13" "$C14" "$C15"; do ! kill -0 "$p" 2>/dev/null && grep -qF "beendet: $p /bin/bash /usr/local/bin/lf-lesen" "$LOG" || exit 1; done)'
kill "$C1" "$C9" "$C10" "$C11" 2>/dev/null
cleanproc
# Nach einer Sperre der Grundregel enden auch Jobs von vorher: Die Kette kann sich geändert haben.
reboot_sim
bash "$F" an 30 >"$T/out" 2>&1
C16=$(spawn) C17=$(spawn) C18=$(spawn)
fake 4194399721 1001 0 4194399722 "" "sudo /usr/local/bin/lf-aufgabe klonen /dev/sdb /dev/sdc" "$T/bin/sudo"
fake 4194399722 1001 1001 1 "" "bash"
fake "$C16" 0 0 4194399721 "" "/bin/bash /usr/local/bin/lf-aufgabe klonen /dev/sdb /dev/sdc" /usr/bin/bash
fake "$C17" 0 0 "$C16" "" "ddrescue /dev/sdb /dev/sdc"
# Ein Kind des Jobs, das nicht als root läuft: Das beendet erst stop_granted nach der Sperre.
fake "$C18" 1000 1000 "$C16" "" "sleep 300"
printf '%s\n' "$C16" "$C17" "$C18" >"$CG/cli.scope/cgroup.procs"
echo "# Platzhalter" >"$W/usr/lib/x86_64-linux-gnu/b5-sperre.txt"
bash "$F" aus >"$T/out" 2>&1
check "nach einer Sperre der Grundregel enden auch Jobs von vorher und ihre Kinder" '[[ -f $T/sudoers.d/lf-claude.lf-gesperrt ]] && ! kill -0 "$C16" 2>/dev/null && ! kill -0 "$C17" 2>/dev/null && grep -qF "beendet: $C16 /bin/bash /usr/local/bin/lf-aufgabe klonen" "$LOG"'
check "auch ein Kind des Jobs, das nicht als root läuft" '! kill -0 "$C18" 2>/dev/null && grep -qF "beendet: $C18 sleep 300" "$LOG"'
rm -f "$W/usr/lib/x86_64-linux-gnu/b5-sperre.txt"
cleanproc

echo "Benutzer-Manager und Prozesse des Technikers (B4):"
reboot_sim
: >"$T/systemctl.log"
# Eine Einheit im Benutzer-Manager des Technikers, ihre Datei außerhalb der Pfade aus WATCH; ein
# zweiter Benutzer-Manager; der Laufzeitordner mit units/ (dort legt systemd je Aufruf eine
# Verknüpfung an).
US4=$W/srv/b4
mkdir -p "$US4" "$W/run/user/1000/systemd/units" "$W/run/user/1000/systemd/generator.late"
printf '[Unit]\nDescription=Platzhalter\n' >"$US4/b4.service"
printf 'ActiveState=active\nFragmentPath=%s\nDropInPaths=\nInvocationID=%032x\n' "$US4/b4.service" 4001 >"$T/user/1000/unit/b4.service"
echo "b4.service loaded active running x" >"$T/user/1000/units"
unit user@4711.service no /user.slice/user-4711.slice/user@4711.service "$US/user@.service"
mkdir -p "$T/user/4711/unit" && : >"$T/user/4711/env" && : >"$T/user/4711/units"
bash "$F" an 30 >"$T/out" 2>&1
check "Freischalten hält je Benutzer-Manager Umgebung, Einheiten und deren Dateien fest, nur für root lesbar" 'grep -qxF "PATH=/usr/bin:/bin" "$SNAP/benutzer-1000-umgebung" && grep -qE "^b4\.service [0-9a-f]{32}$" "$SNAP/benutzer-1000-einheiten" && grep -qE "^[0-9a-f]{64} $US4/b4.service$" "$SNAP/benutzer-1000-dateien" && [[ -f $SNAP/benutzer-4711-umgebung && $(stat -c %a "$SNAP/benutzer-1000-dateien") == 600 && $(stat -c %a "$SNAP/userpaths") == 600 ]]'
echo "LD_PRELOAD=/var/lib/lf-claude/x.so" >>"$T/user/1000/env"
printf 'ActiveState=active\nFragmentPath=\nDropInPaths=\nInvocationID=%032x\n' 4002 >"$T/user/1000/unit/b4neu.service"
echo "b4neu.service loaded active running x" >>"$T/user/1000/units"
echo "ExecStartPre=/bin/true" >>"$US4/b4.service"
printf '[Unit]\nDescription=Platzhalter\n' >"$W/run/user/1000/systemd/generator.late/b4.service"
ln -s /dev/null "$W/run/user/1000/systemd/units/invocation:b4neu.service"
rm -r "$T/user/4711"
unit user@4712.service no /user.slice/user-4712.slice/user@4712.service "$US/user@.service"
touch "$W/var/lib/systemd/linger/rescue"
K1=$(spawn) K2=$(spawn)
fake "$K1" 1000 1000 1 "" "sleep 300" "" 0 9000
fake "$K2" 1000 1000 1 "" "sleep 300"
bash "$F" aus >"$T/out" 2>&1
check "Umgebung, neue Einheit und geänderte Datei im Benutzer-Manager: Rückstand" 'grep -qxF "Umgebung des Benutzer-Managers geändert (rescue): LD_PRELOAD" "$R" && grep -qxF "Benutzer-Einheit neu oder neu gestartet (rescue): b4neu.service" "$R" && grep -qxF "Datei einer geladenen Benutzer-Einheit geändert (rescue): $US4/b4.service" "$R"'
check "neue Datei unter /run/user/UID/systemd: Rückstand, units/ nicht" 'grep -qxF "Datei neu: $W/run/user/1000/systemd/generator.late/b4.service" "$R" && ! grep -qF "/systemd/units" "$R"'
check "neuer Benutzer-Manager eines anderen Benutzers: beendet, Rückstand; einer antwortet nicht mehr, eine neue linger-Datei: Rückstand (Q6)" 'grep -qx "stop user@4712.service" "$T/systemctl.log" && grep -qxF "Einheit beendet: user@4712.service" "$R" && grep -qxF "Benutzer-Manager antwortet nicht (4711)" "$R" && grep -qxF "Datei neu: $W/var/lib/systemd/linger/rescue" "$R"'
check "ein Prozess des Technikers aus der Freigabe: Rückstand, er läuft weiter; einer von vorher nicht" 'grep -qxF "Prozesse von rescue seit dem Freischalten: $K1 (sleep)" "$R" && kill -0 "$K1" 2>/dev/null && ! grep -qF "$K2 (sleep)" "$R"'
check "zuerst der Hinweis aufs Ausschalten am Netzschalter: Prozesse von rescue, Benutzer-Manager, /run/user (A3, Befund 3)" '[[ $(head -n 1 "$R") == "Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: Prozesse von rescue, Benutzer-Manager, $W/run/user/1000/systemd/generator.late/b4.service)" ]]'
kill "$K1" "$K2" 2>/dev/null
cleanproc
awk '$1 != "user@4711.service" && $1 != "user@4712.service"' "$T/units" >"$T/units.neu" && mv "$T/units.neu" "$T/units"
printf 'HOME=/home/rescue\nLANG=C.UTF-8\nPATH=/usr/bin:/bin\n' >"$T/user/1000/env"
: >"$T/user/1000/units"
rm -rf "$T/user/1000/unit/"* "$W/run/user" "$W/var/lib/systemd/linger/rescue" "$US4"

echo "Dateien geladener Einheiten (B2):"
reboot_sim
: >"$T/systemctl.log"
# Eine Einheit über eine Verknüpfung in /etc/systemd/system auf eine Datei außerhalb der Suchpfade,
# mit Drop-in daneben; eine, die schon beim Freischalten neu zu laden ist; eine Einhängung aus
# einer fstab (SourcePath).
mkdir -p "$W/srv/b2"
printf '[Unit]\nDescription=Platzhalter\n' >"$W/srv/b2/b2.service"
ln -s "$W/srv/b2/b2.service" "$W/etc/systemd/system/b2.service"
printf '[Service]\nEnvironment=X=1\n' >"$W/srv/b2/b2.conf"
printf '[Unit]\nDescription=Platzhalter\n' >"$W/srv/b2/b2r.service"
echo "/dev/sdz1 /mnt/b2 ext4 ro 0 0" >"$W/srv/b2/fstab"
unit b2.service no /system.slice/b2.service "$W/etc/systemd/system/b2.service" "" "$W/srv/b2/b2.conf"
unit b2r.service no /system.slice/b2r.service "$W/srv/b2/b2r.service"
prop b2r.service NeedDaemonReload yes
unit mnt-b2.mount no "" ""
prop mnt-b2.mount SourcePath "$W/srv/b2/fstab"
bash "$F" an 30 >"$T/out" 2>&1
check "Freischalten hält den Inhalt der Dateien geladener Einheiten fest, auch hinter einer Verknüpfung, nur für root lesbar" 'grep -qxF "$(sha256sum <"$W/srv/b2/b2.service" | cut -c1-64) $W/etc/systemd/system/b2.service" "$SNAP/unitfiles" && grep -qE "^[0-9a-f]{64} $W/srv/b2/b2.conf$" "$SNAP/unitfiles" && grep -qE "^[0-9a-f]{64} $W/srv/b2/fstab$" "$SNAP/unitfiles" && [[ $(stat -c %a "$SNAP/unitfiles") == 600 ]]'
echo "ExecStartPre=/bin/true" >>"$W/srv/b2/b2.service"
echo "Environment=LD_PRELOAD=/x.so" >>"$W/srv/b2/b2.conf"
echo "ExecStartPre=/bin/true" >>"$W/srv/b2/b2r.service"
echo "/dev/sdz2 /mnt/b2 ext4 rw 0 0" >"$W/srv/b2/fstab"
bash "$F" aus >"$T/out" 2>&1
check "geändertes Ziel einer Verknüpfung, Drop-in und Quelle außerhalb der Suchpfade: Rückstand" 'grep -qxF "Datei einer geladenen Einheit geändert: $W/etc/systemd/system/b2.service" "$R" && grep -qxF "Datei einer geladenen Einheit geändert: $W/srv/b2/b2.conf" "$R" && grep -qxF "Datei einer geladenen Einheit geändert: $W/srv/b2/fstab" "$R"'
check "auch wenn die Einheit schon beim Freischalten neu zu laden war (NeedDaemonReload)" 'grep -qxF "Datei einer geladenen Einheit geändert: $W/srv/b2/b2r.service" "$R"'
check "zuerst der Hinweis aufs Ausschalten am Netzschalter, mit den geänderten Dateien (A3, Befund 3)" 'l=$(head -n 1 "$R"); [[ $l == "Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: "*", …)" && ($l == *"$W/etc/systemd/system/b2.service"* || $l == *"$W/srv/b2/"*) ]]'
awk '$1 !~ /^(b2|b2r)\.service$/ && $1 != "mnt-b2.mount"' "$T/units" >"$T/units.neu" && mv "$T/units.neu" "$T/units"
rm -rf "$W/srv/b2" "$W/etc/systemd/system/b2.service"

echo "Kernel: Taint, Module und BPF-Pins (B6):"
reboot_sim
: >"$T/systemctl.log"
# Ein Modul mit Datei von vorher, das erst während der Freigabe geladen wird, eins mit Taint.
mkdir -p "$W/sys/module/b6t"
echo b6t >"$W/lib/modules/$KV/kernel/b6t.ko"
bash "$F" an 30 >"$T/out" 2>&1
check "Freischalten hält Taint, Module und BPF-Pins fest" 'grep -qxF "taint 0" "$SNAP/kernel" && grep -qxF "modul loop 40960" "$SNAP/kernel" && ! grep -q "^bpf " "$SNAP/kernel"'
echo 4096 >"$T/proc/sys/kernel/tainted"
mkdir -p "$W/sys/fs/bpf/b6" && : >"$W/sys/fs/bpf/b6/map"
echo b6neu >"$W/lib/modules/$KV/kernel/b6neu.ko"
echo O >"$W/sys/module/b6t/taint"
printf 'dummy 16384 0 - Live 0x0\nb6x 16384 0 - Live 0x0\nb6neu 16384 0 - Live 0x0\nb6t 16384 0 - Live 0x0\n' >>"$T/proc/modules"
bash "$F" aus >"$T/out" 2>&1
check "neues Taint-Bit und neue BPF-Pins: Rückstand" 'grep -qxF "Kernel: neues Taint-Bit (0, jetzt 4096)" "$R" && grep -qxF "Kernel: BPF-Pin neu: $W/sys/fs/bpf/b6" "$R" && grep -qxF "Kernel: BPF-Pin neu: $W/sys/fs/bpf/b6/map" "$R"'
check "neue Module ohne Datei, mit neuer Datei oder mit Taint: Rückstand; eins mit Datei von vorher nicht" '(for m in b6x b6neu b6t; do grep -qxF "Kernel: Modul ohne unveränderte Datei unter /lib/modules: $m" "$R" || exit 1; done) && ! grep -qF "/lib/modules: dummy" "$R"'
check "zuerst der Hinweis aufs Ausschalten am Netzschalter: Kernel (A3, Befund 3)" '[[ $(head -n 1 "$R") == "Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: "*"Kernel"* ]]'
echo 0 >"$T/proc/sys/kernel/tainted"
printf 'loop 40960 0 - Live 0x0\nisofs 61440 1 - Live 0x0\n' >"$T/proc/modules"
rm -r "$W/sys/fs/bpf/b6" "$W/sys/module/b6t" "$W/lib/modules/$KV/kernel/b6t.ko" "$W/lib/modules/$KV/kernel/b6neu.ko"

echo "Ganz /root, das Home des Technikers, Hooks und weitere Pfade (A1 bis A3, B3, B7):"
reboot_sim
: >"$T/systemctl.log"
mkdir -p "$W/home/rescue/bin" "$W/home/rescue/Dokumente" "$W/var/lib/dpkg/info" "$W/var/spool/cron/crontabs" \
	"$W/run/NetworkManager/conf.d" "$W/run/modules-load.d" "$W/etc/mc" "$W/etc/update-motd.d"
bash "$F" an 30 >"$T/out" 2>&1
echo x >"$W/root/notiz"
echo '{}' >"$W/root/.jq"
echo "set -g status off" >"$W/etc/tmux.conf"
echo x >"$W/etc/mc/mc.ext.ini"
echo "LF_LIVE_DISK=sdz" >"$W/run/lf-boot.env"
echo "Defaults !env_reset" >"$W/etc/sudoers-rs"
echo "alias ls=x" >"$W/home/rescue/.bashrc"
echo x >"$W/home/rescue/bin/x"
echo x >"$W/home/rescue/Dokumente/notiz.txt"
echo x >"$W/var/lib/dpkg/info/x.postinst"
echo "* * * * * true" >"$W/var/spool/cron/crontabs/rescue"
echo "[main]" >"$W/run/NetworkManager/conf.d/x.conf"
echo dummy >"$W/run/modules-load.d/x.conf"
printf '#!/bin/sh\n' >"$W/etc/update-motd.d/99-x"
# Eine neue Einhängung und eine mit anderen Optionen (ohne nosuid).
echo "70 22 0:70 / $W/mnt/b3 rw,relatime shared:30 - tmpfs tmpfs rw" >>"$T/proc/1/mountinfo"
sed -i "s|^30 22 0:40 / $W/run rw,nosuid,nodev |30 22 0:40 / $W/run rw,nodev |" "$T/proc/1/mountinfo"
bash "$F" aus >"$T/out" 2>&1
check "ganz /root: Rückstand und Sperre der Grundregel (A1, A2)" 'grep -qxF "Datei neu: $W/root/notiz" "$R" && grep -qxF "Datei neu: $W/root/.jq" "$R" && [[ -f $T/sudoers.d/lf-claude.lf-gesperrt ]]'
check "die Sperre nennt jeden Grund: /root, tmux, mc, lf-boot.env, sudoers-rs und beide Einhängungen (A2, B3)" '(l=$(grep "gesperrt: Grundregel" "$LOG" | tail -n 1); for p in "Datei neu: $W/root/notiz" "Datei neu: $W/root/.jq" "Datei neu: $W/etc/tmux.conf" "Datei neu: $W/etc/mc/mc.ext.ini" "Datei neu: $W/run/lf-boot.env" "Datei neu: $W/etc/sudoers-rs" "Einhängung neu oder geändert: $W/mnt/b3 (tmpfs tmpfs)" "Einhängung neu oder geändert: $W/run (tmpfs tmpfs)"; do [[ $l == *"$p"* ]] || exit 1; done)'
check "Dotfiles und ~/bin des Technikers, Skripte von dpkg, cron und /run für NetworkManager und modules-load: Rückstand (A1, B7)" '(for p in "$W/home/rescue/.bashrc" "$W/home/rescue/bin/x" "$W/var/lib/dpkg/info/x.postinst" "$W/var/spool/cron/crontabs/rescue" "$W/run/NetworkManager/conf.d/x.conf" "$W/run/modules-load.d/x.conf" "$W/etc/update-motd.d/99-x"; do grep -qxF "Datei neu: $p" "$R" || exit 1; done)'
check "andere Dateien im Home des Technikers: kein Rückstand" '! grep -qF "$W/home/rescue/Dokumente" "$R"'
check "zuerst der Hinweis aufs Ausschalten am Netzschalter: sudo und die Einhängung über /run, nicht /root, tmux, mc und /mnt (A3, Befund 3)" '[[ $(head -n 1 "$R") == "Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: $W/etc/sudoers-rs, $W/run)" ]]'
rm -rf "$W/root/notiz" "$W/root/.jq" "$W/etc/tmux.conf" "$W/etc/mc" "$W/run/lf-boot.env" "$W/etc/sudoers-rs" "$W/home/rescue/.bashrc" \
	"$W/home/rescue/bin" "$W/home/rescue/Dokumente" "$W/var/lib/dpkg" "$W/var/spool/cron" "$W/run/NetworkManager" "$W/run/modules-load.d" \
	"$W/etc/update-motd.d"
# Nur Hooks, was Dienste lesen, die von selbst starten (/etc/default), und das Home des Technikers:
# Beim Ausschalten läuft davon nichts.
reboot_sim
mkdir -p "$W/home/rescue/bin" "$W/var/lib/dpkg/info" "$W/etc/update-motd.d" "$W/etc/default"
bash "$F" an 30 >"$T/out" 2>&1
echo "SSHD_OPTS=x" >"$W/etc/default/q9-ssh"
echo "alias ls=x" >"$W/home/rescue/.bashrc"
echo x >"$W/home/rescue/bin/x"
echo x >"$W/var/lib/dpkg/info/x.postinst"
printf '#!/bin/sh\n' >"$W/etc/update-motd.d/99-x"
bash "$F" aus >"$T/out" 2>&1
check "nur Hooks, /etc/default und das Home des Technikers: zuerst der Hinweis aufs Ausschalten über Beenden > Ausschalten, keiner zum Netzschalter (A3)" '[[ $(head -n 1 "$R") == "${AUS}$W/etc/default/q9-ssh, $W/etc/update-motd.d/99-x, $W/home/rescue/.bashrc, …)" ]] && ! grep -qF "Netzschalter" "$R" && soft_lock'
rm -rf "$W/home/rescue/.bashrc" "$W/home/rescue/bin" "$W/var/lib/dpkg" "$W/etc/update-motd.d" "$W/etc/default/q9-ssh"
cleanproc
reboot_sim

# Was beim Beenden läuft, ohne Einheit aus der Freigabe: Hooks von finalrd auch unter /run (sonst
# nicht geprüft), eine Alternative (awk in Skripten beim Beenden) und eine Unit-Datei, die root ohne
# Einheit unter /run/systemd/transient abgelegt hat (systemd liest sie dort wie unter
# /run/systemd/system).
mkdir -p "$W/run/finalrd"
ln -sfn "$W/usr/bin/mawk" "$W/etc/alternatives/q9-awk"
bash "$F" an 30 >"$T/out" 2>&1
printf '#!/bin/sh\n' >"$W/run/finalrd/q9.finalrd"
ln -sfn "$T/q9-awk" "$W/etc/alternatives/q9-awk"
printf '[Service]\nExecStart=/bin/true\n' >"$TR/q9-abgelegt.service"
bash "$F" aus >"$T/out" 2>&1
check "Hooks von finalrd unter /run, eine geänderte Alternative und eine abgelegte Unit-Datei: Rückstand" 'grep -qxF "Datei neu: $W/run/finalrd/q9.finalrd" "$R" && grep -qxF "Datei geändert: $W/etc/alternatives/q9-awk" "$R" && grep -qxF "Unit-Datei neu: $TR/q9-abgelegt.service" "$R"'
check "…: zuerst der Hinweis aufs Ausschalten am Netzschalter, die Unit-Datei unter dem Namen ihrer Einheit" '[[ $(head -n 1 "$R") == "${NETZ}$W/etc/alternatives/q9-awk, $W/run/finalrd/q9.finalrd, q9-abgelegt.service)" ]] && soft_lock'
rm -rf "$W/run/finalrd" "$W/etc/alternatives/q9-awk" "$TR/q9-abgelegt.service"
cleanproc
reboot_sim

echo "Sperre des Netzschalters bei logind, Strg+Alt+Entf und die Einordnung der Zeilen (GHSA-799j-44qx-x7xj):"
NF_=$T/run/claude-netzschalter-frei
NW=$(sed -n 's/^NETZ_WHAT=//p' rescue/bin/lf-freigabe)
check "die Unit-Datei aus dem Image: genau der Befehl aus lf-freigabe (NETZ_ARGV), Type=exec, UnsetEnvironment wie ENV_UNSAFE, ohne [Install], ihre Prüfsumme ist NETZ_SHA" '[[ -n $NW && $NA == "/usr/bin/systemd-inhibit --what=$NW --who=Leuchtfeuer --why=lf-freigabe --mode=block /usr/bin/sleep infinity" && $(grep -c "^ExecStart" "$NUF") == 1 && $(sed -n "s/^Type=//p" "$NUF") == exec && $(sed -n "s/^UnsetEnvironment=//p" "$NUF") == "$ENV_UNSAFE" ]] && ! grep -q "^\[Install\]" "$NUF" && [[ $(sed -n "s/^NETZ_SHA=//p" rescue/bin/lf-freigabe) == "$(sha256sum <"$NUF" | cut -d" " -f1)" ]] && grep -qxF "handle-power-key:handle-reboot-key:handle-suspend-key:handle-hibernate-key:handle-lid-switch:sleep" <<<"$NW"'
check "das Image maskiert ctrl-alt-del.target, und sieben Mal Strg+Alt+Entf in zwei Sekunden tut nichts (CtrlAltDelBurstAction=none); build.sh kopiert das Overlay" 'grep -qx "systemctl mask ctrl-alt-del.target" build/chroot-setup.sh && grep -qx "CtrlAltDelBurstAction=none" build/overlay/usr/lib/systemd/system.conf.d/lf-strg-alt-entf.conf && grep -qx "\[Manager\]" build/overlay/usr/lib/systemd/system.conf.d/lf-strg-alt-entf.conf && grep -qF "cp -a --no-preserve=ownership \"\$SRC/build/overlay/.\" \"\$CHROOT/\"" build/build.sh'
# Ein Ende ohne Rückstand.
reboot_sim
: >"$T/systemctl.log" && : >"$T/busctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
bash "$F" aus >"$T/out" 2>&1
check "die Sperre gilt vom ersten Schritt an: nach dem Sperren der Grundregel, vor dem Anhalten von Claude" 'a=$(line "gesperrt: Grundregel von lf-claude ($T/sudoers.d/lf-claude) während des Endes: Ende der Freigabe") b=$(line "Ende der Freigabe: Netzschalter gesperrt ($NU)") c=$(line "Ende der Freigabe: Claude angehalten"); [[ -n $a && -n $b && -n $c ]] && ((a < b && b < c)) && grep -qxF "start --no-block $NU" "$T/systemctl.log"'
check "…: nach dem Beenden fragt das Ende logind (ListInhibitors), ohne Rückstand gibt es die Sperre frei, ohne Neustart des Dienstes" 'grep -qF ListInhibitors "$T/busctl.log" && grep -qxF "stop $NU" "$T/systemctl.log" && grep -qx ActiveState=inactive "$T/unit/$NU" && grep -qF "Ende der Freigabe: Netzschalter wieder frei ($NU)" "$LOG" && ! grep -qxF "restart --no-block $NU" "$T/systemctl.log" && [[ ! -e $R && ! -e $NF_ ]] && base_free && ! grep -qF "Netzschalter nicht gesperrt" "$LOG"'
# Rückstand, der beim Beenden als root liefe: finalrd, ein Dienst für D-Bus unter /run und eine
# Einstellung von systemd selbst (Platzhalter).
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
mkdir -p "$W/run/finalrd" "$W/run/dbus-1/system-services" "$W/etc/systemd/system.conf.d"
bash "$F" an 30 >"$T/out" 2>&1
printf '#!/bin/sh\n' >"$W/run/finalrd/q10.finalrd"
printf '[D-BUS Service]\nName=q10\nExec=/bin/true\nUser=root\n' >"$W/run/dbus-1/system-services/q10.service"
printf '[Manager]\nCtrlAltDelBurstAction=reboot-force\n' >"$W/etc/systemd/system.conf.d/q10.conf"
bash "$F" aus >"$T/out" 2>&1
check "mit Hinweis aufs Ausschalten am Netzschalter (finalrd, D-Bus, systemd): die Sperre bleibt, auch über Strg+Alt+Entf sagt der Hinweis etwas" '[[ $(head -n 1 "$R") == "${NETZ}$W/etc/systemd/system.conf.d/q10.conf, $W/run/dbus-1/system-services/q10.service, $W/run/finalrd/q10.finalrd)" ]] && ! grep -qxF "stop $NU" "$T/systemctl.log" && grep -qx ActiveState=active "$T/unit/$NU" && grep -qF "Ende der Freigabe: Netzschalter bleibt gesperrt" "$LOG" && ! grep -qF "Netzschalter nicht gesperrt" "$R" && [[ ! -e $NF_ ]] && soft_lock'
# Das nächste Ende, ohne den Rückstand: Es gibt die Sperre frei.
rm -rf "$W/run/finalrd/q10.finalrd" "$W/run/dbus-1/system-services/q10.service" "$W/etc/systemd/system.conf.d/q10.conf"
: >"$T/systemctl.log"
bash "$F" aus >"$T/out" 2>&1
check "…: ein späteres Ende ohne Rückstand gibt sie frei" '[[ ! -e $R ]] && grep -qxF "stop $NU" "$T/systemctl.log" && grep -qx ActiveState=inactive "$T/unit/$NU" && base_free'
rm -rf "$W/run/finalrd" "$W/run/dbus-1" "$W/etc/systemd/system.conf.d"
# logind führt die Sperre nicht (Attrappe), mit Rückstand und ohne.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
mkdir -p "$W/run/finalrd"
bash "$F" an 30 >"$T/out" 2>&1
printf '#!/bin/sh\n' >"$W/run/finalrd/q10.finalrd"
touch "$T/netz-ohne-sperre"
bash "$F" aus >"$T/out" 2>&1
rm -f "$T/netz-ohne-sperre"
check "führt logind die Sperre nicht: einmal neu gestartet, dann eine Zeile im Rückstand, der Hinweis sagt, dass ein kurzer Druck geordnet herunterfährt" '[[ $(head -n 1 "$R") == "${NETZK}$W/run/finalrd/q10.finalrd, Netzschalter)" && $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 && -e $NF_ ]] && grep -qxF "Netzschalter nicht gesperrt: $NU" "$R" && grep -qF "Netzschalter nicht gesperrt: logind führt keine Sperre von $NU" "$LOG" && ! grep -qxF "stop $NU" "$T/systemctl.log" && soft_lock'
check "…: status zeigt den Hinweis mit dem kurzen Druck" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (${NETZK}"* ]]'
rm -rf "$W/run/finalrd"
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
touch "$T/netz-sperre-anders"
bash "$F" aus >"$T/out" 2>&1
rm -f "$T/netz-sperre-anders"
check "eine Sperre nur für einen Teil der Tasten zählt nicht; ohne Rückstand steht dafür nichts im Rückstand, das Ende gibt den Dienst frei" '[[ ! -e $R && ! -e $NF_ ]] && grep -qF "Netzschalter nicht gesperrt: logind führt keine Sperre von $NU" "$LOG" && grep -qxF "stop $NU" "$T/systemctl.log" && base_free'
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
touch "$T/netz-sperre-fremd"
bash "$F" aus >"$T/out" 2>&1
rm -f "$T/netz-sperre-fremd"
check "eine Sperre, die ein anderer Prozess als der Hauptprozess hält, zählt nicht: einmal neu gestartet, dann im Protokoll" '[[ ! -e $R && ! -e $NF_ && $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 ]] && grep -qF "Netzschalter nicht gesperrt: logind führt keine Sperre von $NU" "$LOG" && base_free'
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
mkdir -p "$W/run/finalrd"
bash "$F" an 30 >"$T/out" 2>&1
printf '#!/bin/sh\n' >"$W/run/finalrd/q10.finalrd"
touch "$T/netz-anderes-programm"
bash "$F" aus >"$T/out" 2>&1
rm -f "$T/netz-anderes-programm"
check "führt der Hauptprozess ein anderes Programm aus als systemd-inhibit, zählt seine Sperre nicht: mit Rückstand sagt der Hinweis, dass ein kurzer Druck geordnet herunterfährt" '[[ $(head -n 1 "$R") == "$NETZK"* && -e $NF_ && $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 ]] && grep -qxF "Netzschalter nicht gesperrt: $NU" "$R"'
rm -rf "$W/run/finalrd"
# Die Unit-Datei der Sperre geändert (eine Zeile mehr) oder ein Drop-in dazu.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
cp "$W/usr/lib/systemd/system/$NU" "$T/netz-datei"
bash "$F" an 30 >"$T/out" 2>&1
echo "ExecStopPost=/bin/sh -c /var/lib/lf-claude/x" >>"$W/usr/lib/systemd/system/$NU"
bash "$F" aus >"$T/out" 2>&1
cp "$T/netz-datei" "$W/usr/lib/systemd/system/$NU"
check "Unit-Datei der Sperre geändert: das Ende startet den Dienst nicht, Rückstand, der Hinweis sagt, dass ein kurzer Druck geordnet herunterfährt" '! grep -qE "^(re)?start .*$NU$" "$T/systemctl.log" && grep -qF "Ende der Freigabe: $NU nicht wie im Image, Netzschalter nicht gesperrt" "$LOG" && grep -qxF "Systemdatei neu oder geändert: $W/usr/lib/systemd/system/$NU" "$R" && [[ $(head -n 1 "$R") == "$NETZK"* ]] && grep -qxF "Netzschalter nicht gesperrt: $NU" "$R"'
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
"$T/bin/systemctl" start "$NU"
prop "$NU" DropInPaths "/run/systemd/system/$NU.d/x.conf"
bash "$F" aus >"$T/out" 2>&1
check "mit einem Drop-in und von root gestartet: nicht ausgenommen, das Ende stoppt ihn wie jede Einheit aus der Freigabe" '! grep -qxF "start --no-block $NU" "$T/systemctl.log" && grep -qxF "stop $NU" "$T/systemctl.log" && grep -qxF "Einheit beendet: $NU" "$R" && grep -qF "Ende der Freigabe: $NU nicht wie im Image" "$LOG"'
# Von root während der Freigabe gestartet, mit einem fremden Prozess darin und einer geänderten
# Umgebung des Managers: Der fremde Prozess endet, das Ende startet den Dienst neu (ohne die
# Variable), er bleibt mit dem Rückstand.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
jq -c '. + ["Q10=x"]' "$T/menv.json" >"$T/menv.neu" && mv "$T/menv.neu" "$T/menv.json"
"$T/bin/systemctl" start "$NU"
P0=$(netz_pid)
NG=$(spawn)
fake "$NG" 0 0 1 "PATH=/usr/bin" "sleep 300"
echo "$NG" >>"$T/cg/system.slice/$NU/cgroup.procs"
check "…: der Prozess von root hat die Variable" 'grep -qzx Q10=x "$T/proc/$P0/environ"'
bash "$F" aus >"$T/out" 2>&1
P1=$(netz_pid)
check "von root gestartet: bleibt (nicht gestoppt), ein fremder Prozess darin endet, protokolliert" '! kill -0 "$NG" 2>/dev/null && grep -qF "beendet: $NG sleep 300 (fremd in $NU)" "$LOG" && ! grep -qxF "stop $NU" "$T/systemctl.log" && ! grep -qxF "Einheit beendet: $NU" "$R"'
check "…: das Ende startet ihn nach dem Zurücksetzen der Umgebung einmal neu, der neue Prozess hat die Variable nicht, logind führt seine Sperre" '[[ $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 && -n $P1 && $P1 != "$P0" && ! -e $T/proc/$P0 && ! -e $NF_ ]] && ! grep -qzx Q10=x "$T/proc/$P1/environ" && grep -qx ActiveState=active "$T/unit/$NU" && [[ $(head -n 1 "$R") == "${NETZ}Manager-Umgebung)" ]]'
# F1: Fehlt der Hauptprozess in der cgroup der Sperre (root hat ihn und sein Kind hinausgeschoben
# und einen eigenen Prozess hineingelegt), ist jeder Prozess darin fremd: Er endet wie jeder fremde.
# Auch danach stimmt die Sperre nicht (netz_ok), und das Ende startet sie einmal neu.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
NG=$(spawn)
fake "$NG" 0 0 1 "PATH=/usr/bin" "sleep 300"
echo "$NG" >"$T/netz-ohne-haupt"
bash "$F" aus >"$T/out" 2>&1
rm -f "$T/netz-ohne-haupt"
check "F1: fehlt der Hauptprozess in der cgroup der Sperre, ist jeder Prozess darin fremd: endet, protokolliert, die Sperre bleibt ausgenommen" '! kill -0 "$NG" 2>/dev/null && grep -qF "beendet: $NG sleep 300 (fremd in $NU)" "$LOG" && ! grep -qF "beendet: Einheit $NU" "$LOG"'
check "…: die Sperre stimmt so nicht, das Ende startet sie einmal neu, danach führt logind sie, ohne Rückstand frei" '[[ ! -e $R && ! -e $NF_ && $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 ]] && grep -qxF "stop $NU" "$T/systemctl.log" && base_free'
# Ebenso ein Prozess, der vom fehlenden Hauptprozess abstammt.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
"$T/bin/systemctl" start "$NU"
P0=$(netz_pid)
NC=$(spawn)
fake "$NC" 0 0 "$P0" "PATH=/usr/bin" "sleep 300"
NG=$(spawn)
fake "$NG" 0 0 1 "PATH=/usr/bin" "sleep 300"
printf '%s\n' "$NC" "$NG" >"$T/cg/system.slice/$NU/cgroup.procs"
bash "$F" aus >"$T/out" 2>&1
check "…: auch einer, der vom fehlenden Hauptprozess abstammt, ist fremd und endet" '! kill -0 "$NC" 2>/dev/null && ! kill -0 "$NG" 2>/dev/null && grep -qF "beendet: $NC sleep 300 (fremd in $NU)" "$LOG" && grep -qF "beendet: $NG sleep 300 (fremd in $NU)" "$LOG" && ! grep -qF "beendet: Einheit $NU" "$LOG"'
# Ohne Hauptprozess, aber mit einem Prozess in der cgroup: Der ist fremd.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
"$T/bin/systemctl" start "$NU"
P0=$(netz_pid)
rm -rf "$T/proc/$P0" "$T/proc/$((P0 + 1))"
NG=$(spawn)
fake "$NG" 0 0 1 "PATH=/usr/bin" "sleep 300"
echo "$NG" >"$T/cg/system.slice/$NU/cgroup.procs"
prop "$NU" MainPID 0
bash "$F" aus >"$T/out" 2>&1
check "F1: ohne Hauptprozess, aber mit einem Prozess in der cgroup: der ist fremd, endet, protokolliert; die Sperre startet neu" '! kill -0 "$NG" 2>/dev/null && grep -qF "beendet: $NG sleep 300 (fremd in $NU)" "$LOG" && ! grep -qF "beendet: Einheit $NU" "$LOG" && [[ $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 && ! -e $NF_ ]]'
# Läuft die Sperre und lässt sich ihre cgroup nicht lesen: nicht ausgenommen, das Ende stoppt sie
# wie jede Einheit aus der Freigabe und startet sie gleich wieder (netz_shows: wie oft es ihren
# Zustand nach dem Stoppen abfragte, bevor es sie neu startete; mit netz_wait wären es 30).
netz_shows() { awk -v u="$NU" '$0 == "stop " u {s = 1; n = 0; next} s && $0 == "restart --no-block " u {print n; exit} s && $1 == "show" && $NF == u {n++}' "$T/systemctl.log"; }
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
"$T/bin/systemctl" start "$NU"
rm -f "$T/cg/system.slice/$NU/cgroup.procs"
bash "$F" aus >"$T/out" 2>&1
check "F1: läuft die Sperre und lässt sich ihre cgroup nicht lesen, bleibt sie nicht: beendet wie eine Einheit aus der Freigabe, Rückstand" 'grep -qF "beendet: Einheit $NU" "$LOG" && grep -qxF "Einheit beendet: $NU" "$R" && ! grep -qF "(fremd in $NU)" "$LOG"'
check "…: das Ende startet sie gleich wieder, logind führt die Sperre" '[[ $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 && ! -e $NF_ && -n $(netz_shows) && $(netz_shows) -lt 10 ]] && grep -qF ListInhibitors "$T/busctl.log"'
# Ebenso, wenn die cgroup fehlt, obwohl der Dienst einen Hauptprozess hat.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
"$T/bin/systemctl" start "$NU"
rm -rf "$T/cg/system.slice/$NU"
bash "$F" aus >"$T/out" 2>&1
check "…: ebenso, wenn die cgroup fehlt, obwohl die Sperre einen Hauptprozess hat" 'grep -qF "beendet: Einheit $NU" "$LOG" && grep -qxF "Einheit beendet: $NU" "$R" && [[ $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 && ! -e $NF_ ]]'
# Dasselbe, wenn find die cgroup nicht ganz lesen kann (eine Unter-cgroup ohne Leserecht; als root
# nicht nachzustellen): Auch nach dem Neustart lässt sie sich nicht prüfen, die Sperre fehlt.
if (($(id -u) != 0)); then
	reboot_sim
	: >"$T/systemctl.log" && : >"$LOG"
	bash "$F" an 30 >"$T/out" 2>&1
	"$T/bin/systemctl" start "$NU"
	mkdir "$T/cg/system.slice/$NU/x" && chmod 000 "$T/cg/system.slice/$NU/x"
	bash "$F" aus >"$T/out" 2>&1
	chmod 755 "$T/cg/system.slice/$NU/x"
	check "…: auch wenn find die cgroup nicht lesen kann: beendet wie eine Einheit aus der Freigabe, danach fehlt die Sperre, der Hinweis sagt, dass ein kurzer Druck geordnet herunterfährt" 'grep -qF "beendet: Einheit $NU" "$LOG" && grep -qxF "Einheit beendet: $NU" "$R" && grep -qF "Netzschalter nicht gesperrt: logind führt keine Sperre von $NU" "$LOG" && grep -qxF "Netzschalter nicht gesperrt: $NU" "$R" && [[ $(head -n 1 "$R") == "$NETZK"* ]]'
fi
# Startet die Sperre noch und hat keinen Prozess (keine cgroup, kein Hauptprozess): Sie bleibt
# ausgenommen wie bisher.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
"$T/bin/systemctl" start "$NU"
P0=$(netz_pid)
rm -rf "$T/proc/$P0" "$T/proc/$((P0 + 1))" "$T/cg/system.slice/$NU"
prop "$NU" ActiveState activating
prop "$NU" MainPID 0
touch "$T/netz-startet-nicht"
bash "$F" aus >"$T/out" 2>&1
rm -f "$T/netz-startet-nicht"
check "F1: startet die Sperre noch und hat keinen Prozess, bleibt sie ausgenommen: nicht beendet, nichts fremd" '! grep -qF "beendet: Einheit $NU" "$LOG" && ! grep -qF "(fremd in $NU)" "$LOG" && ! grep -qsxF "Einheit beendet: $NU" "$R"'
reboot_sim
# Die Umgebung des Managers während der Freigabe geändert, die Sperre startet erst das Ende (und erbt
# die Variable): Nach dem Zurücksetzen startet es sie neu.
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
jq -c '. + ["Q10=x"]' "$T/menv.json" >"$T/menv.neu" && mv "$T/menv.neu" "$T/menv.json"
bash "$F" aus >"$T/out" 2>&1
P1=$(netz_pid)
check "eine geänderte Umgebung des Managers: das Ende startet die Sperre nach dem Zurücksetzen einmal neu, ohne die Variable" '[[ $(grep -c "^start --no-block $NU$" "$T/systemctl.log") == 1 && $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 && -n $P1 ]] && ! grep -qzx Q10=x "$T/proc/$P1/environ" && grep -qx ActiveState=active "$T/unit/$NU" && [[ $(head -n 1 "$R") == "${NETZ}Manager-Umgebung)" ]]'
reboot_sim
# Nur von root gestartet (die Umgebung unverändert): Neustart, weil root den Prozess ändern konnte.
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
"$T/bin/systemctl" start "$NU"
bash "$F" aus >"$T/out" 2>&1
check "lief der Dienst schon vor dem Ende: einmal neu gestartet, dann ohne Rückstand freigegeben" '[[ ! -e $R ]] && [[ $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 ]] && grep -qxF "start --no-block $NU" "$T/systemctl.log" && grep -qxF "stop $NU" "$T/systemctl.log" && ! grep -qF "beendet: Einheit $NU" "$LOG" && base_free'
# Eine neue ld.so.preload: Die Sperre startete davor und kann ihre Bibliothek geladen haben.
reboot_sim
: >"$T/systemctl.log" && : >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
echo "/var/lib/lf-claude/x.so" >"$W/etc/ld.so.preload"
bash "$F" aus >"$T/out" 2>&1
check "eine gesperrte ld.so.preload: das Ende startet die Sperre danach einmal neu" 'grep -qF "gesperrt: $W/etc/ld.so.preload" "$LOG" && [[ $(grep -c "^restart --no-block $NU$" "$T/systemctl.log") == 1 ]] && a=$(grep -n -m1 "^start --no-block $NU$" "$T/systemctl.log" | cut -d: -f1) && b=$(grep -n -m1 "^restart --no-block $NU$" "$T/systemctl.log" | cut -d: -f1) && ((a < b))'
rm -f "$W/etc/ld.so.preload" "$W/etc/ld.so.preload.lf-gesperrt"
reboot_sim
# Die Einordnung jeder Art von Zeile (hint_item), direkt aus der Kopie von lf-freigabe: Was niemand
# eingeordnet hat, sagt Beenden > Ausschalten.
head -n $(($(grep -n '^case \${1:-} in$' "$F" | cut -d: -f1) - 1)) "$F" >"$T/lib.sh"
# klasse ZEILE   KLASSE NAME, wie hint_item sie für ZEILE setzt ("-" für keine).
klasse() { bash -c 'source "$1" && hint_item "$2" && echo "${HC:--} $HN"' _ "$T/lib.sh" "$1" 2>/dev/null; }
check "Klassen: polkit, Konten, /root, Credentials, setuid, capabilities, cron, Gruppen, linger, Einhängungen unter /mnt, LF-DATA und jede Zeile, die niemand eingeordnet hat: Beenden > Ausschalten" '(for l in "Datei neu: $W/etc/polkit-1/rules.d/x.rules" "Datei geändert: $W/etc/passwd" "Datei neu: $W/root/.ssh/authorized_keys" "Datei neu: $W/run/credstore/x" "setuid/setgid: $W/var/tmp/x" "capabilities: $W/var/tmp/x cap_setuid=ep" "cron: $W/var/spool/cron/crontabs/root" "Gruppen: lf-claude render sudo" "linger: lf-claude" "Einhängung neu oder geändert: $W/mnt/x (ext4 /dev/sdb1)" "Datei auf LF-DATA neu: $W/persist/home/x" "Speicher LF-DATA während der Freigabe ausgehängt, Inhalt ungeprüft: $W/persist" "Credentials geändert: $W/run/credentials/@system/x" "eine neue Art von Zeile: $W/etc/x" "noch eine neue Art"; do [[ $(klasse "$l") == "aus "* ]] || { echo "    $l: $(klasse "$l")"; exit 1; }; done)'
check "…: der Name ist der Pfad, sonst was vor dem Doppelpunkt steht" '[[ $(klasse "capabilities: $W/var/tmp/x cap_setuid=ep") == "aus $W/var/tmp/x" && $(klasse "Gruppen: lf-claude render sudo") == "aus Gruppen" && $(klasse "Datei auf LF-DATA neu: $W/persist/home/x") == "aus LF-DATA" && $(klasse "noch eine neue Art") == "aus noch eine neue Art" && $(klasse "Suche nach capabilities abgebrochen (rc 137)") == "aus capabilities" ]]'
check "…: keine Klasse nur für die Sperre der Grundregel, beendete Einheiten, Werkzeuge, gesperrte Kopien für soft-reboot und EFI-Variablen" '(for l in "Grundregel gesperrt bis zum Neustart: x" "Grundregel gesperrt, bis ein Ende ohne Rückstand abschließt: x" "Grundregel ließ sich nicht wieder freigeben: x" "Einheit beendet: x.service" "Werkzeug neu oder geändert: x" "System für soft-reboot: $W/run/nextroot.lf-gesperrt.abc" "EFI-Variable neu: Boot0001-$GV" "EFI-Variable geändert: BootOrder-$GV" "EFI-Variable entfernt: Timeout-$GV" ""; do [[ $(klasse "$l") == "- " ]] || { echo "    $l: $(klasse "$l")"; exit 1; }; done)'
check "…: casper.conf, D-Bus (/etc und /run), system.conf(.d) von systemd und pam.conf: am Netzschalter" '(for p in "$W/etc/casper.conf" "$W/etc/dbus-1/system.d/x.conf" "$W/etc/dbus-1/system-services/x.service" "$W/run/dbus-1/system-services/x.service" "$W/etc/systemd/system.conf" "$W/etc/systemd/system.conf.d/x.conf" "$W/run/systemd/system.conf.d/x.conf" "$W/etc/pam.conf"; do [[ $(klasse "Datei neu: $p") == "netz $p" ]] || { echo "    $p: $(klasse "Datei neu: $p")"; exit 1; }; done) && [[ $(klasse "Netzschalter nicht gesperrt: $NU") == "netz Netzschalter" && $(klasse "Einhängung neu oder geändert: $W/etc/x (tmpfs tmpfs)") == "netz $W/etc/x" ]]'

echo "Das Ende sperrt zuerst, Einheiten mit Code beim Beenden bleiben angehalten (GHSA-799j-44qx-x7xj):"
# Ein Ende, das abbricht (KILL beim Anhalten einer Einheit, nur in der Attrappe von systemctl).
reboot_sim
: >"$T/systemctl.log"
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
unit q8-abbruch.service no /system.slice/q8-abbruch.service
touch "$T/abbruch-bei-q8-abbruch.service"
bash "$F" aus >"$T/out" 2>&1
RC=$?
rm -f "$T/abbruch-bei-q8-abbruch.service"
B1=$(cat "$T/proc/sys/kernel/random/boot_id")
check "ein abgebrochenes Ende: Regel weg, Grundregel gesperrt, die Marke mit der boot_id dieses Starts" '[[ $RC == 137 && ! -e $RULE && ! -e $T/sudoers.d/lf-claude && -f $T/sudoers.d/lf-claude.lf-gesperrt && $(cat "$T/run/claude-grundregel-sperre") == "ende $B1" ]]'
check "…: die Sperre steht im Protokoll vor dem Anhalten von Claude" 'a=$(line "gesperrt: Grundregel von lf-claude ($T/sudoers.d/lf-claude) während des Endes: Ende der Freigabe") b=$(line "Ende der Freigabe: Claude angehalten"); [[ -n $a && -n $b ]] && ((a < b))'
check "…: die Sperre des Netzschalters gilt schon und bleibt" 'grep -qxF "start --no-block $NU" "$T/systemctl.log" && ! grep -qxF "stop $NU" "$T/systemctl.log" && grep -qx ActiveState=active "$T/unit/$NU"'
# Ein soft-reboot behält /etc, /run und die boot_id, nur die Prozesse sind weg.
cleanproc
O=". Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf"
check "nach einem soft-reboot: weiter gesperrt, der Rückstand sagt zuerst, dass die Prüfung nicht abgeschlossen ist und dass der Techniker am Netzschalter ausschalten soll, status zeigt das" '[[ ! -e $T/sudoers.d/lf-claude && $(cat "$T/run/claude-grundregel-sperre") == "ende $B1" && $(head -n 1 "$R") == "Prüfung des Rückstands nicht abgeschlossen, Ende seit "[0-9][0-9]:[0-9][0-9]"$O" && $(bash "$F" status) == "an: Rückstand nach der Freigabe (Prüfung des Rückstands nicht abgeschlossen, Ende seit "[0-9][0-9]:[0-9][0-9]"$O), Neustart empfohlen" ]]'
bash "$F" aus >"$T/out" 2>&1
check "das nächste Ende schließt ab und ersetzt die Zeile; mit Rückstand bleibt die Grundregel gesperrt, bis ein Ende ohne Rückstand abschließt" '! grep -qF "Prüfung des Rückstands nicht abgeschlossen" "$R" && grep -qxF "Einheit beendet: q8-abbruch.service" "$R" && soft_lock'
# Gilt die Marke nicht für diesen Start (andere boot_id) oder fehlt sie: wie bis zum Neustart.
boot
bash "$F" aus >"$T/out" 2>&1
check "eine Marke aus einem anderen Start: gesperrt bis zum Neustart" 'grep -qxF "Grundregel gesperrt bis zum Neustart: $T/sudoers.d/lf-claude.lf-gesperrt" "$R" && ! grep -qF "Grundregel gesperrt, bis ein Ende" "$R" && [[ ! -e $T/sudoers.d/lf-claude ]]'
rm -f "$T/run/claude-grundregel-sperre"
bash "$F" aus >"$T/out" 2>&1
check "ohne Marke: gesperrt bis zum Neustart" 'grep -qxF "Grundregel gesperrt bis zum Neustart: $T/sudoers.d/lf-claude.lf-gesperrt" "$R" && [[ ! -e $T/sudoers.d/lf-claude ]]'
# Rückstand ohne Grund für eine Sperre bis zum Neustart (ein Platzhalter in /etc), dann ein Ende ohne.
reboot_sim
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
echo q8 >"$W/etc/q8"
bash "$F" aus >"$T/out" 2>&1
check "Rückstand: die Grundregel bleibt gesperrt, bis ein Ende ohne Rückstand abschließt" 'grep -qxF "Datei neu: $W/etc/q8" "$R" && soft_lock && ! grep -qF "wieder frei:" "$LOG"'
rm "$W/etc/q8"
bash "$F" aus >"$T/out" 2>&1
check "ein Ende ohne Rückstand gibt sie wieder frei, mit Eintrag im Protokoll; status: aus" 'base_free && [[ ! -e $R ]] && grep -qF "wieder frei: Grundregel von lf-claude ($T/sudoers.d/lf-claude), das Ende fand keinen Rückstand" "$LOG" && aus_n'
# Eine Einheit aus der Freigabe außerhalb der cgroup von Claude schiebt die gesperrte Grundregel
# zurück, bevor das Ende sie anhält (nur in der Attrappe von systemctl, Datei sperre-zurueck-bei-NAME):
# Mit Rückstand sperrt das Ende sie wieder (R1).
reboot_sim
: >"$T/systemctl.log"
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
unit q8-zurueck.service no /system.slice/q8-zurueck.service
touch "$T/sperre-zurueck-bei-q8-zurueck.service"
bash "$F" aus >"$T/out" 2>&1
rm -f "$T/sperre-zurueck-bei-q8-zurueck.service"
check "hebt eine Einheit aus der Freigabe die Sperre während des Endes auf: mit Rückstand wieder gesperrt, bis ein Ende ohne Rückstand abschließt (R1)" 'grep -qxF "freeze q8-zurueck.service" "$T/systemctl.log" && grep -qxF "Einheit beendet: q8-zurueck.service" "$R" && soft_lock && grep -qF "gesperrt: Grundregel von lf-claude ($T/sudoers.d/lf-claude) während des Endes: Rückstand am Ende" "$LOG"'
# Lässt sie sich danach nicht wieder sperren: Das steht im Rückstand und im Hinweis aufs Ausschalten
# am Netzschalter (ihre Jobs laufen weiter), auch wenn die erste Prüfung des Endes es nicht sah.
reboot_sim
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
unit q8-fest.service no /system.slice/q8-fest.service
touch "$T/sperre-zurueck-bei-q8-fest.service" "$T/sperre-fest-bei-q8-fest.service"
bash "$F" aus >"$T/out" 2>&1
rm -f "$T/sperre-zurueck-bei-q8-fest.service" "$T/sperre-fest-bei-q8-fest.service" "$T/mv-fest"
check "…und lässt sie sich dann nicht wieder sperren: im Rückstand, einmal, zuerst der Hinweis aufs Ausschalten am Netzschalter (ihre Jobs)" '[[ -f $T/sudoers.d/lf-claude && $(head -n 1 "$R") == "${NETZ}Jobs der Grundregel)" && $(grep -c "^Grundregel ließ sich nicht sperren: $T/sudoers.d/lf-claude$" "$R") == 1 ]] && grep -qxF "Einheit beendet: q8-fest.service" "$R" && grep -qF "ließ sich nicht sperren: Grundregel von lf-claude ($T/sudoers.d/lf-claude): Rückstand am Ende" "$LOG"'
# Die Datei der Grundregel: eine neue ctime (wie beim Sperren) ist kein Rückstand, anderer Inhalt schon.
reboot_sim
: >"$LOG"
bash "$F" an 30 >"$T/out" 2>&1
touch "$T/sudoers.d/lf-claude"
bash "$F" aus >"$T/out" 2>&1
check "Grundregel mit neuer ctime, gleichem Inhalt: kein Rückstand, wieder frei" '[[ ! -e $R ]] && base_free'
reboot_sim
: >"$LOG"
cp "$T/sudoers.d/lf-claude" "$T/lf-claude.vorher"
bash "$F" an 30 >"$T/out" 2>&1
echo "# Platzhalter" >>"$T/sudoers.d/lf-claude"
bash "$F" aus >"$T/out" 2>&1
check "Grundregel mit anderem Inhalt: Rückstand, gesperrt bis zum Neustart" 'grep -qxF "sudo-Datei neu oder geändert: $T/sudoers.d/lf-claude" "$R" && grep -qxF "Grundregel gesperrt bis zum Neustart: $T/sudoers.d/lf-claude.lf-gesperrt" "$R" && grep -qF "bis zum Neustart: sudo-Datei neu oder geändert: $T/sudoers.d/lf-claude" "$LOG"'
reboot_sim
cp "$T/lf-claude.vorher" "$T/sudoers.d/lf-claude"
# Einheiten aus der Freigabe, bei deren Ende systemd noch etwas ausführte, und eine, deren Beenden
# eine von vorher mitnähme (nur Eigenschaften in der Attrappe von systemctl), dazu eine geänderte
# EFI-Variable (Platzhalter).
: >"$T/systemctl.log"
: >"$LOG"
cp "$EV/Boot0001-$GV" "$T/boot0001"
bash "$F" an 30 >"$T/out" 2>&1
printf '\007\000\000\000drei' >"$EV/Boot0001-$GV"
unit q8-stop.service no /system.slice/q8-stop.service
prop q8-stop.service ExecStopPost "$X"
unit q8-fehler.service no /system.slice/q8-fehler.service
prop q8-fehler.service OnFailure q8-x.service
unit q8-aktion.service no /system.slice/q8-aktion.service
prop q8-aktion.service FailureAction reboot
unit q8-teil.service no /system.slice/q8-teil.service
prop q8-teil.service ConsistsOf a.service
unit q8-frei.service no /system.slice/q8-frei.service
# Ein Dienst mit ExecStop= in der Slice von Claude, sein Prozess (root, aus der Freigabe) dort.
unit q8-claude.service no /lf.slice/lf-claude.slice/q8-claude.service
prop q8-claude.service ExecStop "$X"
mkdir -p "$CG/q8-claude.service"
QH=$(spawn)
fake "$QH" 0 0 1 "" "sleep 300" "" 0 9000
echo "0::/lf.slice/lf-claude.slice/q8-claude.service" >"$T/proc/$QH/cgroup"
echo "$QH" >"$CG/q8-claude.service/cgroup.procs"
bash "$F" aus >"$T/out" 2>&1
check "ExecStopPost=, OnFailure=, FailureAction= oder ein Beenden, das eine Einheit von vorher mitnähme: angehalten, nicht beendet, Rückstand" '(for u in q8-stop.service q8-fehler.service q8-aktion.service q8-teil.service q8-claude.service; do held_ok "$u" || exit 1; done)'
check "…: das Protokoll nennt den Grund" 'grep -qF "angehalten, nicht beendet: Einheit q8-stop.service (beim Beenden liefe: ExecStopPost=)" "$LOG" && grep -qF "angehalten, nicht beendet: Einheit q8-aktion.service (beim Beenden liefe: FailureAction=reboot)" "$LOG" && grep -qF "angehalten, nicht beendet: Einheit q8-teil.service (das Beenden nähme mit: ConsistsOf=a.service)" "$LOG"'
check "eine neue Einheit ohne so etwas: angehalten, beendet, gestoppt, Rückstand" 'grep -qx "freeze q8-frei.service" "$T/systemctl.log" && grep -qx "kill -s KILL q8-frei.service" "$T/systemctl.log" && grep -qx "stop q8-frei.service" "$T/systemctl.log" && grep -qxF "Einheit beendet: q8-frei.service" "$R"'
check "der root-Prozess des angehaltenen Dienstes in der Slice von Claude: nicht beendet (sonst endete der Dienst)" 'kill -0 "$QH" 2>/dev/null && ! grep -qF "beendet: $QH " "$LOG"'
check "angehaltene Einheiten: ganz oben am Netzschalter ausschalten, nicht sofort, nicht über Beenden, EFI in derselben Zeile (Befund 1); die Grundregel bleibt gesperrt, bis ein Ende ohne Rückstand abschließt" '[[ $(head -n 1 "$R") == "Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (beim Beenden liefe als root oder rescue Code aus der Freigabe: "*"q8-aktion.service"*"). Danach: EFI-Variablen für den Start geändert (Boot0001): vor dem nächsten Start die Startreihenfolge im Firmware-Setup prüfen und eine unerwartete MOK-Abfrage ablehnen" && $(head -n 1 "$R") != *"$TR/"* ]] && ! grep -q -e "^Sofort ausschalten" -e "^Vor dem Weiterarbeiten ausschalten (Beenden > Ausschalten)" "$R" && soft_lock'
kill "$QH" 2>/dev/null
rm -r "$CG/q8-claude.service"
cp "$T/boot0001" "$EV/Boot0001-$GV"
cleanproc
# Lässt sich so eine nicht anhalten (ein Timer mit OnSuccess=), läuft sie weiter, und jede andere
# aus der Freigabe bleibt angehalten; ein Timer ohne so etwas endet. Dazu eine geänderte
# EFI-Variable und eine Datei für modprobe (Platzhalter).
reboot_sim
: >"$T/systemctl.log"
: >"$LOG"
cp "$EV/Boot0001-$GV" "$T/boot0001"
mkdir -p "$W/etc/modprobe.d"
bash "$F" an 30 >"$T/out" 2>&1
unit q8-zeit.timer no ""
prop q8-zeit.timer OnSuccess q8-x.service
unit q8-leer.timer no ""
unit q8-frei.service no /system.slice/q8-frei.service
echo "# Platzhalter" >"$W/etc/modprobe.d/q8.conf"
printf '\007\000\000\000zwei' >"$EV/Boot0001-$GV"
bash "$F" aus >"$T/out" 2>&1
check "ein Timer mit OnSuccess=, der sich nicht anhalten lässt: läuft weiter, nicht gestoppt, Rückstand" '! grep -qxF -e "stop q8-zeit.timer" -e "kill -s KILL q8-zeit.timer" "$T/systemctl.log" && grep -qxF "Einheit läuft weiter, ließ sich nicht anhalten: q8-zeit.timer" "$R" && grep -qF "nicht angehalten und nicht beendet: Einheit q8-zeit.timer (beim Beenden liefe: OnSuccess=)" "$LOG"'
check "…: jede andere Einheit aus der Freigabe bleibt angehalten, ein Timer ohne so etwas endet" 'held_ok q8-frei.service && grep -qxF "stop q8-leer.timer" "$T/systemctl.log" && grep -qxF "Einheit beendet: q8-leer.timer" "$R"'
check "…: ganz oben sofort am Netzschalter ausschalten, nicht über Beenden > Ausschalten oder Neustart, EFI in derselben Zeile, kein weiterer Hinweis" '[[ $(head -n 1 "$R") == "Sofort ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (läuft weiter, beim Beenden liefe Code aus der Freigabe: q8-zeit.timer). Danach: EFI-Variablen für den Start geändert (Boot0001): vor dem nächsten Start die Startreihenfolge im Firmware-Setup prüfen und eine unerwartete MOK-Abfrage ablehnen" ]] && ! grep -q "^Vor dem Weiterarbeiten ausschalten" "$R" && soft_lock'
check "…: status zeigt den Hinweis" '[[ $(bash "$F" status) == "an: Rückstand nach der Freigabe (Sofort ausschalten: Netzschalter gedrückt halten, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (läuft weiter, "* ]]'
cp "$T/boot0001" "$EV/Boot0001-$GV"
rm -f "$W/etc/modprobe.d/q8.conf"
reboot_sim

echo "Eigenschaften eines Dienstes in systemd 259 (F16):"
# props [KLASSE]   Die Namen aus systemd-259-properties.txt (einer Klasse), sortiert.
P=tests/systemd-259-properties.txt
props() { grep -v '^#' "$P" | awk -v k="${1:-}" 'k == "" || $2 == k {print $1}' | LC_ALL=C sort; }
# kept LISTE   Die Namen aus KEPT_EMPTY oder KEPT_SAME in lf-freigabe, sortiert.
kept() { sed -n "/^$1=(/,/)/p" rescue/bin/lf-freigabe | tr -s ' \t()' '\n' | sed -n "s/^$1=//; s/=.*//; /./p" | LC_ALL=C sort; }
QUERY=$(sed -n '/^unit_info() {/,/^}/p' rescue/bin/lf-freigabe | grep -oE -- '-p [A-Za-z,]+' | cut -c4- | tr ',' '\n' | LC_ALL=C sort -u)
check "jede Eigenschaft genau einmal, in einer der Klassen" '[[ -z $(props | uniq -d) && $(props | wc -l) == 464 && $(grep -v "^#" "$P" | awk "{print \$2}" | LC_ALL=C sort -u | tr "\n" " ") == "geprueft gleich laufzeit leer namensraum ohne spiegel " ]]'
check "leer ist genau KEPT_EMPTY, gleich genau KEPT_SAME" '[[ -n $(kept KEPT_EMPTY) && $(props leer) == "$(kept KEPT_EMPTY)" && $(props gleich) == "$(kept KEPT_SAME)" ]]'
check "unit_info fragt nach jeder Eigenschaft aus leer, gleich und geprueft, und nur nach bekannten" '[[ -z $(comm -23 <({ props leer; props gleich; props geprueft; } | LC_ALL=C sort) <(echo "$QUERY")) && -z $(comm -13 <(props) <(echo "$QUERY")) ]]'

echo "Hinweise für Techniker und Claude:"
check "Anleitung: ein kurzer Druck tut nichts, solange der Hinweis aufs Ausschalten am Netzschalter steht; Gedrückthalten bricht Schreiben auf angeschlossene Disks ab; Strg+Alt+Entf ohne Wirkung" 'grep -qF "Ein kurzer Druck tut dann nichts: Vom ersten Schritt des Endes an sperrt Leuchtfeuer den Netzschalter und die Tasten für Neustart und Ruhezustand, bis ein Ende ohne so eine Zeile abschließt, sonst bis zum Neustart. Erst Gedrückthalten schaltet aus." docs/anleitung.md && grep -qF "der Hinweis sagt, dass schon ein kurzer Druck geordnet herunterfährt." docs/anleitung.md && grep -qF "Gedrückthalten nimmt den Strom sofort: Was gerade auf angeschlossene Disks schreibt, bricht ab, auch ein Job von lf-aufgabe, der nach dem Ende weiterläuft." docs/anleitung.md && grep -qF "**Strg+Alt+Entf** startet auf Leuchtfeuer keinen Neustart, auch mehrmals schnell hintereinander nicht." docs/anleitung.md'
check "Anleitung und Code: der Hinweis über Beenden > Ausschalten nennt einen Weg zu root, LF-DATA hat einen eigenen Hinweis" 'grep -qF "Bleibt sonst ein Weg zu root aus der Freigabe, für Claude oder jeden anderen," docs/anleitung.md && grep -qF "echo \"Vor dem Weiterarbeiten ausschalten (Beenden > Ausschalten): Weg zu root aus der Freigabe (" rescue/bin/lf-freigabe && grep -qF "Prüfe LF-DATA dann vor dem nächsten Entsperren oder lege den Speicher neu an." docs/anleitung.md && grep -qF "vor dem nächsten Entsperren prüfen oder neu anlegen\"" rescue/bin/lf-freigabe'
check "Anleitung: Eine Konsole, die während der Freigabe aufgeht, zeigt danach Rückstand; dann neu starten" 'grep -qF "Öffnest du während einer Freigabe eine weitere Konsole (Alt+F2 … F6), zeigt das Ende danach „Rückstand“" docs/anleitung.md && grep -qF "Starte dann neu. Bis dahin schaltest du eine neue Freigabe nur an einer Konsole des Geräts frei, mit Rückfrage dort." docs/anleitung.md'
check "der Freigabe-Dialog sagt, dass das Ende auch laufende root-Jobs von Claude beendet" 'grep -q "Am Ende der Freigabe beendet Leuchtfeuer, was Claude damit als root gestartet hat, auch mitten im Schreiben." rescue/lib/claude.sh'
check "Dialog und Anleitung: sicher endet root-Zugriff nur mit einem Neustart" '(($(grep -c "Sicher endet root-Zugriff nur mit einem Neustart" rescue/lib/claude.sh) >= 4)) && grep -q "Sicher endet root-Zugriff aber nur mit einem Neustart" docs/anleitung.md'
check "Verlängern im Dialog: Rückfrage an der Konsole, eine Ablehnung wird gemeldet" 'grep -q "Rückfrage hier an der Konsole" rescue/lib/claude.sh && grep -q "Nicht verlängert. Details im Protokoll." rescue/lib/claude.sh'
check "Freischalten und Verlängern im Dialog laufen direkt am Terminal, nicht über run (sudo-rs, GHSA-799j-44qx-x7xj)" '! grep -q "run sudo lf-freigabe an" rescue/lib/claude.sh &&grep -qxF "	sudo lf-freigabe an \"\$1\" || rc=\$?" rescue/lib/claude.sh && grep -qF "claude_freigabe_an \"\$min\" ||" rescue/lib/claude.sh && grep -qF "if claude_freigabe_an 30; then" rescue/lib/claude.sh'
check "claude.sh liest lf-freigabe status überall ohne stderr: ohne root stört keine Meldung den Dialog (#92)" '(($(grep -cF "\$(lf-freigabe status" rescue/lib/claude.sh) == $(grep -cF "\$(lf-freigabe status 2>/dev/null)" rescue/lib/claude.sh)))'
check "CLI und Desktop laufen in der Slice, die lf-freigabe am Ende prüft" '[[ $(sed -n "s/^CLAUDE_SLICE=//p" rescue/lib/claude.sh) == "$(sed -n "s/^SLICE=//p" rescue/bin/lf-freigabe)" ]] && grep -q "claude_scope sh -c" rescue/lib/claude.sh && grep -qF -- "--slice=\"\$CLAUDE_SLICE\"" rescue/lib/claude-desktop-start'
check "lf-freigabe lässt genau die ntfs-3g-Dienste gelten, die part_mount_ro startet (Name, Optionen, Einhängepunkt)" 'grep -qF "ntfs3g_ro ro,nodev,nosuid,noexec,recover \"\$part\" \"\$mp\"" rescue/lib/recover.sh && grep -qF "unit=\"lf-ntfs3g-\$(systemd-escape --path -- \"\$3\").service\"" rescue/lib/recover.sh && grep -qF "\${argv[2]} == ro,nodev,nosuid,noexec,recover" rescue/bin/lf-freigabe && grep -qF "[[ \$u == \"lf-ntfs3g-\$(systemd-escape --path -- \"\${argv[4]}\").service\" ]]" rescue/bin/lf-freigabe && [[ $(sed -n "s/^IMAGE_MNT=//p" rescue/bin/lf-freigabe) == "$(sed -n "s/^LF_IMAGE_MNT=\"\(.*\)\"$/\1/p" rescue/lib/common.sh)" ]]'
check "recover.sh startet ntfs-3g so, wie lf-freigabe es verlangt: Type=forking und UnsetEnvironment, sonst nichts (F12, F13)" 'grep -qxF "	if ! run sudo systemd-run --quiet --collect --unit=\"\$unit\" -p Type=forking -p UnsetEnvironment=\"\$LF_ENV_UNSAFE\" \\" rescue/lib/recover.sh && grep -qxF "		--description=\"Leuchtfeuer: ntfs-3g, nur lesend unter \$3\" -- ntfs-3g -o \"\$1\" \"\$2\" \"\$3\"; then" rescue/lib/recover.sh && grep -qx "NTFS3G=/usr/bin/ntfs-3g" rescue/bin/lf-freigabe'
check "lf-aufgabe startet Rettungen so, wie lf-freigabe sie gelten lässt: Name, Programm, Argumente, UnsetEnvironment (F16)" 'grep -qxF "	unit=\"lf-claude-rettung-\$(printf '"'"'%s'"'"' \"\$1\" | sha256sum | cut -c1-12)\"" rescue/bin/lf-aufgabe && grep -qxF "	systemd-run --quiet --collect --unit=\"\$unit\" -p UnsetEnvironment=\"\$LF_ENV_UNSAFE\" --description=\"Leuchtfeuer: Rettung \$(basename \"\$1\")\" \\" rescue/bin/lf-aufgabe && grep -qxF "		/usr/local/bin/lf-rescue-run \"\$1\" \"\$2\" --no-pause \${LF_TECHNIKER:+\"--techniker=\$LF_TECHNIKER\"} ||" rescue/bin/lf-aufgabe && grep -qF "[[ \$u == \"lf-claude-rettung-\$(printf '"'"'%s'"'"' \"\${argv[1]}\" | sha256sum | cut -c1-12).service\" ]]" rescue/bin/lf-freigabe && grep -qx "RESCUE_RUN=/usr/local/bin/lf-rescue-run" rescue/bin/lf-freigabe && [[ $(head -n 1 rescue/bin/lf-rescue-run) == "#!/usr/bin/env bash" ]] && grep -qx "pruefen-rettung)" rescue/bin/lf-aufgabe'
check "eine Liste der Variablen für lf-freigabe und common.sh (F13)" '[[ -n $ENV_UNSAFE && $ENV_UNSAFE == "$(sed -n "s/^LF_ENV_UNSAFE=\"\(.*\)\"$/\1/p" rescue/lib/common.sh)" ]]'
check "lf-freigabe startet genau zwei Dienste, beide oben mit UnsetEnvironment geprüft (F13)" '[[ $(grep -cE "^[[:space:]]*(exec )?systemd-run " rescue/bin/lf-freigabe) == 2 ]]'
check "Neustart im Assistenten: echt, ohne kexec und soft-reboot; sonst startet nichts unter rescue/ neu" 'grep -qxF "		sudo env SYSTEMCTL_SKIP_AUTO_KEXEC=1 SYSTEMCTL_SKIP_AUTO_SOFT_REBOOT=1 systemctl \"\$c\"" rescue/lf && [[ -z $(grep -rhE "systemctl[^|;]* (\"\\\$c\"|reboot|soft-reboot|kexec)" rescue | grep -v "^[[:space:]]*#" | grep -v "SYSTEMCTL_SKIP_AUTO_KEXEC=1 SYSTEMCTL_SKIP_AUTO_SOFT_REBOOT=1 systemctl") ]]'
check "Anleitung: auch eigene Änderungen zeigen Rückstand; sicher ist Ausschalten, über Beenden > Ausschalten nur ohne Zeile zum Netzschalter; Beenden > Neustart übergeht nur kexec und nextroot" 'grep -qF "Leuchtfeuer sieht nicht, wer etwas geändert hat." docs/anleitung.md && grep -qF "Am sichersten ist Ausschalten. **Beenden > Ausschalten** ist dafür nur sicher, wenn das letzte Ende abgeschlossen ist und im Rückstand keine Zeile mit „Netzschalter“ steht" docs/anleitung.md && grep -qF "Steht im Rückstand eine Zeile mit „Netzschalter“ oder „Prüfung des Rückstands nicht abgeschlossen“, halte gleich den Netzschalter gedrückt." docs/anleitung.md && grep -qF "ein \`reboot\` in der Shell nicht. Eine Umleitung im Neustart selbst übergeht es nicht." docs/anleitung.md && ! grep -qF "Starte über **Beenden > Neustart** neu" docs/anleitung.md'
check "Hardware-Prüfung: nach der Freigabe bis zum Neustart der Hinweis auf einen Neustart" 'grep -qF "Bis zum Neustart steht im Hauptmenü „Hinweis: Claude hatte volles sudo, Neustart empfohlen (letzte Freigabe bis HH:MM)“" docs/hardware-pruefung.md'
check "CLAUDE.md: lange Kopien nur über lf-aufgabe, nie direkt mit sudo" 'tr "\n" " " <rescue/claude/CLAUDE.md | grep -q "Lange Kopien (dd, ddrescue, partclone) startest du auch dann nur über lf-aufgabe, nie direkt mit sudo"'
check "Anleitung: Änderungen an dem, was die Grundregel als root ausführt, und neue Einhängungen sperren lf-lesen und lf-aufgabe bis zum Neustart (Q5)" 'grep -qF "sperrt Leuchtfeuer diese beiden Werkzeuge für Claude bis zum Neustart und beendet Rettungen und Einhängungen, die während der Freigabe gestartet sind. Wähle das Ziel und entsperre LF-DATA darum vor dem Freischalten." docs/anleitung.md'
check "Anleitung: geänderte EFI-Variablen zuerst im Rückstand, dann Startreihenfolge und MOK prüfen; Firmware, Disks und Hardware erkennt Leuchtfeuer nicht" 'grep -qF "Hat sich eine EFI-Variable für den Start geändert, zeigt der Rückstand das zuerst: Prüfe dann vor dem nächsten Start die Startreihenfolge im Firmware-Setup und lehne eine unerwartete MOK-Abfrage ab." docs/anleitung.md && grep -qF "Was root sonst in der Firmware, auf angeschlossenen Disks oder an der Hardware ändert, erkennt Leuchtfeuer nicht, und ein Neustart setzt es nicht zurück." docs/anleitung.md'
check "Anleitung und Code nennen denselben Schritt für geänderte EFI-Variablen" 'grep -qF "vor dem nächsten Start die Startreihenfolge im Firmware-Setup prüfen und eine unerwartete MOK-Abfrage ablehnen" rescue/bin/lf-freigabe'
check "Anleitung: Startet ein beendeter Dienst danach nicht (frozen unit), hilft nur ein Neustart" 'grep -qF "Startet ein solcher Dienst danach nicht („frozen unit“), hilft nur ein Neustart." docs/anleitung.md'
check "CLAUDE.md: apt, PAM, sudo oder eine eigene Einhängung sperren lf-lesen und lf-aufgabe bis zum Neustart" 'tr "\n" " " <rescue/claude/CLAUDE.md | grep -qF "sperrt Leuchtfeuer am Ende auch lf-lesen und lf-aufgabe bis zum Neustart und beendet Rettungen aus der Freigabe. Sag das dem Techniker vorher."'
check "CLAUDE.md: lange Jobs vor dem Freischalten oder nach dem Ende; Jobs und Prozesse aus der Freigabe enden, nach einer Sperre auch Jobs von vorher (B5)" 'c=$(tr "\n" " " <rescue/claude/CLAUDE.md); [[ $c == *"lange Jobs startest du vor dem Freischalten oder nach dem Ende, nicht während einer Freigabe"* && $c == *"auch Jobs von lf-aufgabe"* && $c == *"Laufende Jobs von lf-lesen und lf-aufgabe enden dann auch, wenn du sie vor dem Freischalten gestartet hast."* && $c != *"Jobs von lf-aufgabe laufen weiter."* ]]'
check "Anleitung: Jobs aus der Freigabe enden, nach einer Sperre auch die von vorher; Programme als rescue und der Hinweis aufs Ausschalten (A3, B4, B5)" 'grep -qF "Auch Jobs von lf-aufgabe, die Claude während der Freigabe startet, und jeder andere Prozess aus der Freigabe mit mehr Rechten als \`lf-claude\` enden dann." docs/anleitung.md && grep -qF "Laufende Jobs der beiden Werkzeuge enden dann auch, wenn sie vor der Freigabe gestartet sind." docs/anleitung.md && grep -qF "Darum zeigt der Rückstand auch Programme und Anmeldungen, die du während der Freigabe startest, und lässt sie laufen" docs/anleitung.md && grep -qF "steht im Rückstand oben „Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten“. Halte dann den Netzschalter gedrückt, bevor du weiterarbeitest." docs/anleitung.md && grep -qF "steht dort „Vor dem Weiterarbeiten ausschalten (Beenden > Ausschalten)“. Schalte das Gerät dann so aus, bevor du weiterarbeitest." docs/anleitung.md'
check "Anleitung und Code nennen dieselben Hinweise aufs Ausschalten, am Netzschalter und über Beenden" 'grep -qF "„Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten“" docs/anleitung.md && grep -qF "echo \"Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten\$k, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (" rescue/bin/lf-freigabe && grep -qF "„Vor dem Weiterarbeiten ausschalten (Beenden > Ausschalten)“" docs/anleitung.md && grep -qF "echo \"Vor dem Weiterarbeiten ausschalten (Beenden > Ausschalten): " rescue/bin/lf-freigabe'
check "Anleitung: Das Ende sperrt zuerst lf-lesen und lf-aufgabe, mit Rückstand bis zu einem Ende ohne; ein abgebrochenes Ende steht oben im Rückstand, mit demselben Text wie im Code" 'grep -qF "Als Erstes sperrt das Ende lf-lesen und lf-aufgabe für Claude. Findet es keinen Rückstand, gibt es beide wieder frei, sonst bleiben sie gesperrt, bis ein Ende ohne Rückstand abschließt, meist also bis zum Neustart." docs/anleitung.md && grep -qF "Bricht das Ende ab, steht im Rückstand oben „$(sed -n "s/^END_OPEN=\"\(.*\)\"$/\1/p" rescue/bin/lf-freigabe)“, mit dem Hinweis, am Netzschalter auszuschalten." docs/anleitung.md'
check "Anleitung und Code: Dienste mit Code beim Beenden bleiben angehalten, dann am Netzschalter ausschalten; lässt sich einer nicht anhalten, sofort; nie über Beenden (Befund 1)" 'grep -qF "beendet Leuchtfeuer nicht: Er bleibt angehalten und steht im Rückstand, ganz oben mit „Vor dem Weiterarbeiten ausschalten: Netzschalter gedrückt halten“." docs/anleitung.md && grep -qF "steht dort „Sofort ausschalten“: Halte dann sofort den Netzschalter gedrückt. Wähle in beiden Fällen weder **Beenden > Ausschalten** noch **Beenden > Neustart**" docs/anleitung.md && grep -qF "echo \"Sofort ausschalten: Netzschalter gedrückt halten\$k, nicht Beenden > Ausschalten oder Neustart, nicht Strg+Alt+Entf (" rescue/bin/lf-freigabe'
check "Anleitung: Anmeldungen des Technikers aus der Freigabe laufen weiter und sind Rückstand, die von root enden (Q6)" 'grep -qF "Anmeldungen und Benutzerdienste von root aus der Freigabe beendet es." docs/anleitung.md'
check "CLAUDE.md: mit Rückstand bleiben lf-lesen und lf-aufgabe gesperrt; keine Dienste und Timer mit Code beim Beenden" 'c=$(tr "\n" " " <rescue/claude/CLAUDE.md); [[ $c == *"Zeigt das Ende „Rückstand“, bleiben lf-lesen und lf-aufgabe gesperrt, bis ein Ende ohne Rückstand abschließt"* && $c == *"Richte mit der Freigabe keinen Dienst und keinen Timer ein, bei dessen Ende systemd noch etwas ausführt"* && $c == *"der Techniker muss das Gerät am Netzschalter ausschalten, sofort, wenn er sich nicht anhalten lässt."* ]]'
check "CLAUDE.md: mit der Freigabe nur sudo BEFEHL, nie eine Anmelde-Shell als root (R4)" 'c=$(tr "\n" " " <rescue/claude/CLAUDE.md); [[ $c == *"Mit der Freigabe nutzt du nur \`sudo BEFEHL\`, nie eine Anmelde-Shell als root (\`sudo -i\`, \`sudo su -\`, \`su -\`): Ihre Sitzung startet den Laufzeitordner von root (user-runtime-dir@0), und den lässt das Ende angehalten stehen."* ]]'

echo "Menü Claude-Freigabe (#92):"
# menue STATUS WAHL JANEIN [MINUTEN]   claude_freigabe_menu aus rescue/lib/claude.sh mit Attrappen:
#   lf-freigabe status sagt STATUS, ui_menu wählt WAHL (leer: Abbruch), ui_yesno gibt JANEIN zurück,
#   ui_input gibt MINUTEN (leer: Abbruch). Dialoge und sudo schreiben nach $T/menue.
menue() {
	: >"$T/menue"
	(
		ms=$1 mw=$2 mj=$3 mm=${4:-}
		lf-freigabe() { [[ $1 == status ]] && echo "$ms"; }
		sudo() { echo "sudo $*" >>"$T/menue"; }
		run() { "$@"; }
		log() { :; }
		clear() { :; }
		ui_menu() { echo "menü $*" >>"$T/menue"; [[ -n $mw ]] && echo "$mw"; }
		ui_msg() { echo "meldung $2" >>"$T/menue"; }
		ui_yesno() { echo "janein $1" >>"$T/menue"; return "$mj"; }
		ui_input() { echo "eingabe $2" >>"$T/menue"; [[ -n $mm ]] && echo "$mm"; }
		# shellcheck disable=SC1091
		. rescue/lib/claude.sh
		claude_freigabe_menu
	) </dev/null >/dev/null 2>&1
}
# folge   Dialoge und sudo-Aufrufe in ihrer Reihenfolge.
folge() { cut -d' ' -f1 "$T/menue" | tr '\n' ' '; }
RS="an: Rückstand nach der Freigabe (sudo-Datei neu oder geändert: /etc/sudoers.d/lf-claude), Neustart empfohlen"
menue "$RS" "" 1
check "Rückstand ohne Regel: kein Verlängern, nur Ende wiederholen oder neu freischalten" 'grep -q "^menü Claude-Freigabe Die Regel ist zurückgenommen, aber: an: Rückstand" "$T/menue" && grep -qF -- "-- aus Ende wiederholen, Rückstand neu prüfen neu Neu freischalten" "$T/menue" && ! grep -q "verlängern" "$T/menue"'
menue "$RS" neu 0 45
check "Rückstand ohne Regel, neu freischalten: erst die Warnung, dann die Dauer, dann sudo lf-freigabe an 45" '[[ $(folge) == "menü janein eingabe sudo meldung " ]] && grep -qx "sudo lf-freigabe an 45" "$T/menue"'
menue "$RS" aus 1
check "Rückstand ohne Regel, Ende wiederholen: sudo lf-freigabe aus, dann das Ergebnis" '[[ $(folge) == "menü sudo meldung " ]] && grep -qx "sudo lf-freigabe aus" "$T/menue"'
menue "" "" 1
check "status ohne Antwort: kein Verlängern, der Text sagt das" 'grep -q "^menü Claude-Freigabe lf-freigabe meldet keinen Zustand\." "$T/menue" && grep -qF -- "-- aus Ende wiederholen, Rückstand neu prüfen neu Neu freischalten" "$T/menue" && ! grep -q "verlängern" "$T/menue"'
menue "an bis 20:30" "" 1
check "laufende Freigabe: Sofort beenden und Verlängern wie bisher" 'grep -q "^menü Claude-Freigabe Claude hat volles sudo (an bis 20:30)" "$T/menue" && grep -qF -- "-- aus Sofort beenden mehr Um 30 Minuten ab jetzt verlängern (Rückfrage hier an der Konsole)" "$T/menue"'
menue "aus, Neustart empfohlen (letzte Freigabe bis 20:30)" "" 1
check "nach einer Freigabe ohne Rückstand: Hinweis, dann der Dialog für eine neue Freigabe, kein Menü" '[[ $(folge) == "meldung janein " ]] && grep -q "^meldung Nach der letzten Freigabe: Neustart empfohlen (letzte Freigabe bis 20:30)\." "$T/menue"'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
