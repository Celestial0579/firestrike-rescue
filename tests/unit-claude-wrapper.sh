#!/usr/bin/env bash
# Unit-Test: "claude" startet im Rettungssystem nie mit Projekt-Einstellungen (rescue/bin/claude).
#
# Das Skript ruft die CLI immer mit --setting-sources user auf und lehnt eine eigene Angabe ab.
# Eine aktualisierte CLI in ~/.local/bin startet nur, wenn frs-claude-check sie für gut befunden
# hat, sonst die der ISO. Die CLI ist hier eine Attrappe, die ihre Argumente ausgibt. Ob die echte
# CLI die Prüfungen besteht, prüft der Selbsttest der ISO (selftest_claude).
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

W=$PWD/rescue/bin/claude
T=$(mktemp -d)
mkdir -p "$T/home/.local/bin"
printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\necho\n' >"$T/home/.local/bin/claude"
chmod +x "$T/home/.local/bin/claude"
export XDG_STATE_HOME=$T/state
S=$T/state/frs/claude-check
mkdir -p "$S"
sum() { sha256sum "$T/home/.local/bin/claude" | cut -d' ' -f1; }
# Die Attrappe gilt als geprüft. Wie die Prüfung selbst entscheidet, steht weiter unten.
: >"$S/$(sum).ok"

echo "Das Skript startet die CLI ohne Projekt-Einstellungen:"
out=$(HOME=$T/home "$W" -p "hallo welt" --verbose)
check "--setting-sources user steht vor allen anderen Argumenten" '[[ $out == "[--setting-sources][user][-p][hallo welt][--verbose]" ]]'
out=$(HOME=$T/home "$W")
check "auch ohne Argumente" '[[ $out == "[--setting-sources][user]" ]]'
out=$(HOME=$T/home "$W" install stable)
check "auch vor Unterbefehlen" '[[ $out == "[--setting-sources][user][install][stable]" ]]'

echo "Eine eigene Angabe der Quellen wird abgelehnt:"
for a in "--setting-sources project" "--setting-sources=user,project" "-p x --setting-sources local"; do
	# shellcheck disable=SC2086
	out=$(HOME=$T/home "$W" $a 2>&1)
	rc=$?
	check "claude $a" '[[ $rc == 2 && $out == *"fest auf \"user\""* && $out != *"["* ]]'
done

echo "Eine aktualisierte CLI startet nur nach bestandener Prüfung:"
rm -f "${S:?}"/*
printf '\n# zweite Version\n' >>"$T/home/.local/bin/claude"
out=$(HOME=$T/home "$W" -p x 2>"$T/fehler")
rc=$?
check "eine neue Version wird geprüft, bevor sie startet" 'grep -q "Neue Version von Claude Code" "$T/fehler"'
check "die Attrappe besteht nicht: Sie führt keinen Befehl aus" '[[ -e $S/$(sum).fail ]] && grep -q "nicht prüfbar" "$S/$(sum).fail"'
check "sie startet nicht, statt ihrer die CLI der ISO" '[[ $out != *"["* && $rc != 0 ]] && grep -q "geprüfte Claude-Code-CLI aus der ISO" "$T/fehler"'
start=$SECONDS
HOME=$T/home "$W" -p x >/dev/null 2>"$T/fehler"
check "beim nächsten Start wird nicht noch einmal geprüft" 'grep -q "schon einmal nicht bestanden" "$T/fehler" && ! grep -q "Neue Version" "$T/fehler" && ((SECONDS - start < 3))'
: >"$S/$(sum).ok"
rm "$S/$(sum).fail"
out=$(HOME=$T/home "$W" -p x 2>/dev/null)
check "bestanden: Sie startet" '[[ $out == "[--setting-sources][user][-p][x]" ]]'
printf '\n# dritte Version\n' >>"$T/home/.local/bin/claude"
HOME=$T/home "$W" -p x >/dev/null 2>"$T/fehler"
check "jede geänderte Datei wird neu geprüft" 'grep -q "Neue Version von Claude Code" "$T/fehler"'
n=$(find "$S" -type f ! -name .lock | wc -l)
out=$(bash rescue/bin/frs-claude-check --ohne-merken "$T/home/.local/bin/claude" 2>&1)
rc=$?
check "frs-claude-check --ohne-merken prüft und merkt nichts" '[[ $rc == 1 && $out == *"nicht prüfbar"* && $(find "$S" -type f ! -name .lock | wc -l) == "$n" ]]'

echo "Welche CLI das Skript nimmt:"
check "ohne aktualisierte CLI die der ISO aus /usr/local/lib/frs" 'grep -q "^cli=/usr/local/lib/frs/claude-cli$" "$W"'
check "der Build legt die CLI der ISO dort ab, nicht unter /usr/local/bin" 'grep -q "install -m 0755 \"\$claude_real\" /usr/local/lib/frs/claude-cli" build/chroot-setup.sh && ! grep -q "/usr/local/bin/claude$" build/chroot-setup.sh'
check "der Build kopiert das Skript als /usr/local/bin/claude" 'grep -q "for f in \"\$SRC\"/rescue/bin/\*" build/build.sh'
check "jede interaktive Shell ruft das Skript, auch wenn ~/.local/bin vorn im PATH steht" 'grep -q "^claude() { /usr/local/bin/claude \"\$@\"; }$" build/chroot-setup.sh'
check "der Login hängt ~/.local/bin hinten an den PATH" 'grep -q "^export PATH=\"\$PATH:\$HOME/.local/bin\"$" build/overlay/etc/skel/.bash_profile'
check "der Assistent startet Claude über das Skript" 'grep -q "^CLAUDE_CMD=/usr/local/bin/claude$" rescue/lib/claude.sh && grep -q "\"\$CLAUDE_CMD\")" rescue/lib/claude.sh'
check "der Selbsttest prüft über das Skript" 'grep -q "^SELFTEST_CLAUDE=(/usr/local/bin/claude)$" rescue/frs'
check "der Selbsttest prüft frs-claude-check mit der CLI der ISO" 'grep -q "frs-claude-check --ohne-merken /usr/local/lib/frs/claude-cli" rescue/frs'
check "nach der Aktualisierung im Hintergrund wird die neue Version gleich geprüft" 'grep -q "install stable && frs-claude-check \"\$HOME/.local/bin/claude\"" rescue/lib/claude.sh'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
