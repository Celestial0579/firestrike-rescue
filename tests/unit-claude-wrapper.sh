#!/usr/bin/env bash
# Unit-Test: "claude" startet im Rettungssystem nie mit Projekt-Einstellungen (rescue/bin/claude).
#
# Das Skript ruft die CLI immer mit --setting-sources user auf und lehnt eine eigene Angabe ab.
# Die CLI ist hier eine Attrappe in ~/.local/bin, die ihre Argumente ausgibt. Ob die echte CLI
# damit keine Projekt-Einstellungen lädt, prüft der Selbsttest der ISO (selftest_claude).
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

echo "Welche CLI das Skript nimmt:"
check "ohne aktualisierte CLI die der ISO aus /usr/local/lib/frs" 'grep -q "^cli=/usr/local/lib/frs/claude-cli$" "$W"'
check "der Build legt die CLI der ISO dort ab, nicht unter /usr/local/bin" 'grep -q "install -m 0755 \"\$claude_real\" /usr/local/lib/frs/claude-cli" build/chroot-setup.sh && ! grep -q "/usr/local/bin/claude$" build/chroot-setup.sh'
check "der Build kopiert das Skript als /usr/local/bin/claude" 'grep -q "for f in \"\$SRC\"/rescue/bin/\*" build/build.sh'
check "jede interaktive Shell ruft das Skript, auch wenn ~/.local/bin vorn im PATH steht" 'grep -q "^claude() { /usr/local/bin/claude \"\$@\"; }$" build/chroot-setup.sh'
check "der Login hängt ~/.local/bin hinten an den PATH" 'grep -q "^export PATH=\"\$PATH:\$HOME/.local/bin\"$" build/overlay/etc/skel/.bash_profile'
check "der Assistent startet Claude über das Skript" 'grep -q "^CLAUDE_CMD=/usr/local/bin/claude$" rescue/lib/claude.sh && grep -q "\"\$CLAUDE_CMD\")" rescue/lib/claude.sh'
check "der Selbsttest prüft über das Skript" 'grep -q "^SELFTEST_CLAUDE=(/usr/local/bin/claude)$" rescue/frs'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
