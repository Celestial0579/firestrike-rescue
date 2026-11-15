#!/usr/bin/env bash
# Unit-Test: Die Skills zur Datenrettung (rescue/claude/skills) sind gültig, halten sich an das
# Rechtemodell und enthalten keine Angaben aus echten Fällen.
#
# Ob Claude Code sie im Rettungssystem für frs-claude lädt, prüft der Selbsttest der ISO
# (selftest_claude_skills).
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

S=rescue/claude/skills
mapfile -t skills < <(find "$S" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
check "es gibt Skills" '((${#skills[@]} >= 8))'

for s in "${skills[@]}"; do
	f=$S/$s/SKILL.md
	echo "$s:"
	check "SKILL.md vorhanden, sonst keine Dateien" '[[ -f $f && $(find "$S/$s" -type f | wc -l) == 1 ]]'
	head=$(sed -n '1{/^---$/!q};2,/^---$/p' "$f")
	check "Kopf mit name gleich dem Ordnernamen" 'grep -qx "name: $s" <<<"$head"'
	check "Kopf mit Beschreibung" 'grep -qE "^description: .{40,}" <<<"$head"'
	check "Name mit frs- vorn, nur Kleinbuchstaben und Bindestrich" '[[ $s =~ ^frs-[a-z-]+$ ]]'
	# sudo nur für die frs-Werkzeuge aus dem Rechtemodell.
	other=$(grep -oE 'sudo [^ `]+' "$f" | grep -vE '^sudo (frs-lesen|frs-aufgabe)$' | sort -u)
	check "sudo nur mit frs-lesen und frs-aufgabe" '[[ -z $other ]]'
	# Aktionen der Werkzeuge, die es auch gibt.
	bad=""
	while read -r tool act; do
		case $tool in
		frs-lesen) grep -q "^$act)" rescue/bin/frs-lesen || bad+=" $tool $act" ;;
		frs-aufgabe) grep -q "^$act)" rescue/bin/frs-aufgabe || bad+=" $tool $act" ;;
		esac
	done < <(grep -oE 'sudo frs-(lesen|aufgabe) [a-z]+' "$f" | sed 's/^sudo //' | sort -u)
	check "jede genannte Aktion gibt es im Werkzeug" '[[ -z $bad ]]'
	# Keine Fallangaben: keine Pfade aus Benutzerverzeichnissen oder Wechseldatenträgern, keine
	# Kennungen, die wie Seriennummern aussehen, keine Gerätenamen aus /dev/disk/by-id.
	check "keine Pfade aus Home oder Wechseldatenträgern" '! grep -qE "/home/|/run/media/|/media/[A-Za-z]" "$f"'
	check "keine Seriennummern" '! grep -qE "\b(S[0-9A-Z]{13,14}|WD-[A-Z0-9]{8,}|[A-Z0-9]{16,})\b" "$f"'
	check "keine Gerätenamen aus by-id" '! grep -q "by-id" "$f"'
	# Wo ein Mensch entscheidet, sagt der Skill es: fett gesetzt und mit "Techniker".
	check "nennt, was der Techniker entscheidet oder tut" 'grep -qE "\*\*[^*]*Techniker[^*]*\*\*|Entscheidung des Technikers|Wann der Techniker entscheidet" "$f"'
done

echo "Einbau:"
check "der Build legt die Skills unter /etc/claude-code/.claude/skills ab" 'grep -q "\$CHROOT/etc/claude-code/.claude/skills/\$(basename \"\$s\")/SKILL.md" build/build.sh'
check "Skills aus ~/.claude und Projekten bleiben gesperrt" 'jq -e ".strictPluginOnlyCustomization == true" rescue/claude/managed-settings.json >/dev/null'
check "der Selbsttest prüft die Herkunft der Skills" 'grep -q "selftest_claude_skills || good=0" rescue/frs'
check "die Diagnose spielt nie Firmware auf" 'grep -q "Firmware wird nie aufgespielt" "$S/frs-diagnose/SKILL.md"'

((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
