#!/usr/bin/env bash
# Unit-Test: lf-aufgabe lehnt ab, bevor etwas geschieht, und lf-freigabe schaltet ohne root
# nichts frei (rescue/bin/lf-aufgabe, rescue/bin/lf-freigabe).
#
# Ohne root und ohne Disks: Die Werkzeuge, die schreiben oder einhängen würden, sind Attrappen,
# die ihren Aufruf mitschreiben. Was lf-aufgabe als root mit echten Geräten tut, prüft der
# Selbsttest der ISO (selftest_claude_aufgabe, selftest_claude_freigabe).
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

T=$(mktemp -d)
mkdir -p "$T/bin" "$T/run"
# Attrappen für alles, was schreibt, einhängt oder startet. Lesende Werkzeuge kommen vom System.
for t in mount umount blockdev rsync systemd-run systemctl losetup install mkdir ddrescue lf-rescue-run sudo tee mountpoint findmnt; do
	printf '#!/bin/sh\necho "%s $*" >>"%s/aufrufe"\nexit 1\n' "$t" "$T" >"$T/bin/$t"
	chmod +x "$T/bin/$t"
done
sed -e "s|^PATH=.*|PATH=$T/bin:/usr/bin:/bin|" -e "s|^LF_LIB=.*|LF_LIB=$PWD/rescue/lib|" \
	-e "s|^AUFGABEN_LOG=.*|AUFGABEN_LOG=$T/run/aufgaben.log|" rescue/bin/lf-aufgabe >"$T/lf-aufgabe"
chmod +x "$T/lf-aufgabe"
check "die Kopie unterscheidet sich nur in PATH, LF_LIB und dem Protokoll" '[[ $(diff rescue/bin/lf-aufgabe "$T/lf-aufgabe" | grep -c "^[<>]") == 6 ]]'
check "das Original setzt PATH und LF_LIB fest" 'grep -q "^PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$" rescue/bin/lf-aufgabe && grep -q "^LF_LIB=/usr/local/lib/lf$" rescue/bin/lf-aufgabe'

run() {
	: >"$T/aufrufe"
	out=$("$T/lf-aufgabe" "$@" 2>"$T/fehler")
	rc=$?
}
# Erlaubt sind nur lesende Aufrufe der Attrappen (mountpoint, findmnt). Alles andere wäre ein Schritt.
wrote() { grep -qvE '^(mountpoint|findmnt) ' "$T/aufrufe"; }

echo "Abgelehnt, bevor geschrieben, eingehängt oder gestartet wird:"
dev=/dev/$(find /sys/class/block -mindepth 1 -maxdepth 1 -printf "%f\n" | grep -E "^[a-z][a-z0-9]{0,31}$" | sort | head -n 1)
while IFS= read -r line; do
	read -ra a <<<"$line"
	run "${a[@]}"
	check "lf-aufgabe $line" '[[ $rc == 2 && -s $T/fehler ]] && ! wrote'
done <<EOF
loeschen $dev
einhaengen
einhaengen /etc/shadow
einhaengen /dev/../etc/shadow
einhaengen /dev/gibt-es-nicht0
einhaengen $dev $dev
aushaengen ../x
aushaengen A
aushaengen
image ../../etc
kopieren /etc/hostname
kopieren /etc/hostname x
retten $dev
retten /etc/shadow
fortsetzen ../x $dev
fortsetzen fall
stand x
notiz
notiz a b
pruefen /etc/hostname
pruefen /etc/hostname x
timeout $dev
timeout $dev 1
timeout $dev 999
timeout $dev x
timeout /etc/shadow 5
ablegen fall
ablegen ../x /etc/shadow
domain
domain fall
domain ../x $dev
domain fall /etc/shadow
retten $dev --domain
retten $dev --domain /etc/shadow
retten $dev --mehr $dev
EOF
run einhaengen "$dev -o rw"
check "lf-aufgabe einhaengen '$dev -o rw' (ein Argument)" '[[ $rc == 2 ]] && ! wrote'
run
check "ohne Aktion" '[[ $rc == 2 ]] && ! wrote'
check "ohne bestätigtes Ziel sagt lf-aufgabe, wer es bestätigt" 'run kopieren /etc/hostname; grep -q "bestätigt der Techniker im Assistenten" "$T/fehler"'
check "jeder Aufruf steht im Protokoll, Argumente maskiert" 'run notiz "a\$(id)b" c; grep -q "Claude: notiz a\\\\\$\\\\(id\\\\)b c" "$T/run/aufgaben.log"'

echo "lf-freigabe ohne root:"
F=rescue/bin/lf-freigabe
out=$(bash "$F" an 30 2>&1)
check "an verlangt root" '[[ $? == 2 && $out == *"nur mit sudo"* ]]'
out=$(bash "$F" aus 2>&1)
check "aus verlangt root" '[[ $? == 2 ]]'
check "status ohne Freigabe: aus" '[[ $(bash "$F" status) == aus ]]'
check "Statuszeile ohne Freigabe" '[[ $(echo "{}" | bash "$F" zeile) == "Leuchtfeuer: Claude arbeitet mit lf-lesen und lf-aufgabe" ]]'
check "lf-claude darf lf-freigabe nicht per sudo starten" '! grep -E "^lf-claude .*lf-freigabe" build/chroot-setup.sh'
check "ein Aufruf von lf-claude wird abgelehnt, auch als root" 'grep -q "SUDO_USER:-} == lf-claude" "$F"'
check "höchstens 240 Minuten" 'grep -q "10#\$min <= 240" "$F"'
check "die Regel wird vor dem Einsetzen mit visudo geprüft und unter einem Namen mit Punkt geschrieben" 'grep -q "visudo -cqf \"\$tmp\"" "$F" && grep -q "mktemp /etc/sudoers.d/.lf-claude-freigabe" "$F"'
check "die Statuszeile von Claude Code zeigt die Freigabe" 'jq -e ".statusLine.command == \"/usr/local/bin/lf-freigabe zeile\"" rescue/claude/managed-settings.json >/dev/null'
check "Claude Code sperrt lf-freigabe und sudoers zusätzlich" 'jq -e "[.permissions.deny[] | select(. == \"Bash(*lf-freigabe*)\" or . == \"Edit(//etc/sudoers.d/**)\")] | length == 2" rescue/claude/managed-settings.json >/dev/null'

echo "Einbau:"
check "sudo erlaubt lf-claude nur lf-lesen und lf-aufgabe" 'grep -q "^lf-claude ALL=(root) NOPASSWD: /usr/local/bin/lf-lesen, /usr/local/bin/lf-aufgabe$" build/chroot-setup.sh && [[ $(grep -c "NOPASSWD" build/chroot-setup.sh) == 1 ]]'
check "lf-claude ist nur zusätzlich in der Gruppe render" 'grep -q "^useradd --system --home-dir /var/lib/lf-claude --create-home --shell /bin/bash --groups render lf-claude$" build/chroot-setup.sh'
check "lf-rescue-run lässt je Fall nur einen Lauf zu" 'grep -q "flock -n 8" rescue/bin/lf-rescue-run'
check "Claude Desktop läuft als lf-claude" 'grep -q "exec sudo -u \"\$CLAUDE_USER\" -H env WAYLAND_DISPLAY" rescue/lib/claude-desktop-start && [[ -x rescue/lib/claude-desktop-start ]]'
check "cage legt seinen Socket in ein eigenes Verzeichnis, nicht ins Laufzeitverzeichnis des Live-Benutzers" 'grep -q "XDG_RUNTIME_DIR=\$CLAUDE_WAYLAND_DIR cage" rescue/lib/claude.sh'
check "der Selbsttest prüft Aufgaben, Freigabe und Socket" 'grep -q "selftest_claude_aufgabe \"\$dir\" || good=0" rescue/lf && grep -q "selftest_claude_freigabe || good=0" rescue/lf && grep -q "selftest_claude_wayland \"\$dir\" || good=0" rescue/lf'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
