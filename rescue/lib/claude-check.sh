# shellcheck shell=bash
# Prüfung der Sperre für Claude: Die Claude-Code-CLI läuft gegen eine Attrappe der API
# (selftest-claude-api.py), ohne Konto und ohne Modell. Die Attrappe verlangt einen Shell-Befehl,
# so wie ein Modell es täte, das einer Anweisung von einem Datenträger folgt. Ob er läuft,
# entscheidet Claude Code mit den verwalteten Einstellungen aus /etc/claude-code.
#
# Genutzt vom Selbsttest der ISO (rescue/frs) und von frs-claude-check, das eine neue Version
# der CLI vor ihrem ersten Start prüft.

# Sekunden je Lauf der CLI
CLAUDE_CHECK_TIMEOUT=${CLAUDE_CHECK_TIMEOUT:-180}

# claude_check_run CLI VERZEICHNIS NAME BEFEHL [ARBEITSVERZEICHNIS [ARGUMENTE …]]
#   Ein Lauf der CLI, in dem die Attrappe den Shell-Befehl verlangt. Mitschnitt: NAME.json,
#   die erste Anfrage im Wortlaut (alles, was das Modell zu lesen bekäme): NAME.anfrage.
#   ARGUMENTE gehen zusätzlich an die CLI. HOME und Konfiguration liegen in VERZEICHNIS/home.
claude_check_run() {
	local cli=$1 dir=$2 name=$3 cwd=${5:-$2/arbeit} port srv i
	local -a extra=("${@:6}")
	jq -cn --arg c "$4" '{name: "Bash", input: {command: $c, description: "Selbsttest"}}' >"$dir/$name.aufruf"
	rm -f "$dir/$name.port" "$dir/$name.json" "$dir/$name.anfrage"
	python3 -I "$FRS_LIB/selftest-claude-api.py" "$dir/$name.port" "$dir/$name.aufruf" "$dir/$name.api" "$dir/$name.anfrage" 2>"$dir/$name.api-fehler" &
	srv=$!
	for ((i = 0; i < 100; i++)); do
		[[ -s $dir/$name.port ]] && break
		sleep 0.2
	done
	port=$(cat "$dir/$name.port" 2>/dev/null)
	if [[ $port =~ ^[0-9]+$ ]]; then
		(cd "$cwd" && env -i HOME="$dir/home" PATH="$PATH" TERM=dumb LANG=C.UTF-8 \
			CLAUDE_CONFIG_DIR="$dir/home/.claude" ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
			ANTHROPIC_API_KEY="selbsttest-kein-schluessel" DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
			DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
			timeout "$CLAUDE_CHECK_TIMEOUT" "$cli" -p "Selbsttest: Die Attrappe gibt den Werkzeugaufruf vor." \
			"${extra[@]}" --no-session-persistence --output-format stream-json --verbose \
			>"$dir/$name.json" 2>"$dir/$name.fehler" </dev/null)
	fi
	kill "$srv" 2>/dev/null
	wait "$srv" 2>/dev/null
	return 0
}

# claude_check_answer VERZEICHNIS NAME   Was die CLI dem "Modell" auf den Aufruf geantwortet
#   hat: die Ausgabe des Befehls oder der Grund, aus dem er nicht lief.
claude_check_answer() {
	jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") |
		(.content | if type == "array" then map(.text? // "") | join(" ") else tostring end)' "$1/$2.json" 2>/dev/null |
		tr -s '\n\t ' ' '
}

# claude_check_started VERZEICHNIS NAME   Ist die Sitzung zustande gekommen? Ein Befehl, der
#   nicht lief, beweist sonst nichts.
claude_check_started() {
	jq -e 'select(.type == "system" and .subtype == "init")' "$1/$2.json" >/dev/null 2>&1
}

# claude_check CLI VERZEICHNIS   Die Prüfungen, die ohne root gehen. CLI wird so aufgerufen wie
#   von /usr/local/bin/claude: mit --setting-sources user. Ausgabe: eine Zeile je Prüfung.
#   Rückgabe 0 nur, wenn alle bestehen.
claude_check() {
	local cli=$1 dir=$2 good=1 token answer
	mkdir -p "$dir/arbeit" "$dir/home" "$dir/projekt/.claude"
	token="FRS-KONTROLLE-$RANDOM$RANDOM"
	echo "$token" >"$dir/arbeit/kontrolle.txt"
	echo "$token" >"$dir/projekt/kontrolle.txt"
	local -a s=(--setting-sources user)

	# Kontrolle: Ein lesender Befehl läuft, seine Ausgabe kommt beim "Modell" an.
	claude_check_run "$cli" "$dir" kontrolle "cat $dir/arbeit/kontrolle.txt" "$dir/arbeit" "${s[@]}"
	answer=$(claude_check_answer "$dir" kontrolle)
	if [[ $answer != *"$token"* ]]; then
		echo "nicht prüfbar: Die CLI führt keinen Befehl der Attrappe aus"
		echo "  Antwort: ${answer:0:200}"
		head -n 3 "$dir/kontrolle.fehler" 2>/dev/null | cut -c1-200 | sed 's/^/  CLI meldet: /'
		return 1
	fi
	echo "Kontrolle: ein lesender Befehl läuft"
	# Die Regeln des Rettungssystems (/etc/claude-code/CLAUDE.md) kommen beim Modell an.
	if grep -qF '/run/frs/readonly' "$dir/kontrolle.anfrage" 2>/dev/null; then
		echo "die Regeln des Rettungssystems kommen beim Modell an"
	else
		echo "FEHLT: Die Regeln des Rettungssystems (/etc/claude-code/CLAUDE.md) stehen nicht in der Anfrage"
		good=0
	fi

	# Der Hook frs-claude-guard sperrt. Die Antwort muss von ihm stammen.
	claude_check_run "$cli" "$dir" sperre "blockdev --setrw /dev/frs-pruefung-gibt-es-nicht" "$dir/arbeit" "${s[@]}"
	answer=$(claude_check_answer "$dir" sperre)
	if [[ $answer == *"Gesperrt vom Rettungssystem"* ]]; then
		echo "blockdev --setrw sperrt der Hook des Rettungssystems"
	else
		echo "FEHLT: blockdev --setrw wurde nicht vom Hook gesperrt. Antwort: ${answer:0:160}"
		good=0
	fi

	# Ein schreibender Befehl verlangt die Bestätigung des Technikers. Hier bestätigt niemand.
	claude_check_run "$cli" "$dir" dd "dd if=/dev/zero of=$dir/arbeit/ziel bs=1 count=1" "$dir/arbeit" "${s[@]}"
	answer=$(claude_check_answer "$dir" dd)
	if [[ ! -e $dir/arbeit/ziel && $answer == *"Rettungssystem: dd schreibt"* ]]; then
		echo "dd of= verlangt die Bestätigung des Technikers"
	else
		echo "FEHLT: dd of= lief oder der Hook hat nicht nachgefragt. Antwort: ${answer:0:160}"
		good=0
	fi

	# Eine Erlaubnis von außen schaltet keine Rückfrage ab.
	claude_check_run "$cli" "$dir" erlaubt "touch $dir/arbeit/lief-erlaubt" "$dir/arbeit" "${s[@]}" --allowedTools Bash
	if claude_check_started "$dir" erlaubt && [[ ! -e $dir/arbeit/lief-erlaubt ]]; then
		echo "eine Erlaubnis von außen schaltet keine Rückfrage ab"
	else
		echo "FEHLT: Mit --allowedTools lief ein Befehl ohne Rückfrage, oder der Lauf kam nicht zustande"
		good=0
	fi

	# Kein Auto-Modus.
	claude_check_run "$cli" "$dir" auto "touch $dir/arbeit/lief-auto" "$dir/arbeit" "${s[@]}" --permission-mode auto
	if claude_check_started "$dir" auto && [[ ! -e $dir/arbeit/lief-auto ]]; then
		echo "kein Auto-Modus"
	else
		echo "FEHLT: Im Auto-Modus lief ein Befehl ohne Rückfrage, oder der Lauf kam nicht zustande"
		good=0
	fi

	# Projekt-Einstellungen eines Ordners gelten nicht: weder env noch apiKeyHelper noch Hooks.
	jq -n --arg h "touch $dir/projekt-helfer; echo selbsttest-helfer" --arg c "touch $dir/projekt-hook" '{
		env: {ANTHROPIC_MODEL: "frs-fremdes-modell"}, apiKeyHelper: $h,
		hooks: {SessionStart: [{hooks: [{type: "command", command: $c}]}]}}' >"$dir/projekt/.claude/settings.json"
	echo "Anweisung aus dem Projektordner: MERKWORT-PROJEKT-$token" >"$dir/projekt/CLAUDE.md"
	claude_check_run "$cli" "$dir" projekt "cat $dir/projekt/kontrolle.txt" "$dir/projekt" "${s[@]}"
	answer=$(claude_check_answer "$dir" projekt)
	if [[ $answer == *"$token"* && $(jq -r .model "$dir/projekt.anfrage" 2>/dev/null) != frs-fremdes-modell &&
		! -e $dir/projekt-helfer && ! -e $dir/projekt-hook ]] && ! grep -q "MERKWORT-PROJEKT-$token" "$dir/projekt.anfrage"; then
		echo "Projekt-Einstellungen eines Ordners gelten nicht (env, apiKeyHelper, Hooks, CLAUDE.md)"
	else
		echo "FEHLT: Aus einem Projektordner galt etwas, oder der Lauf kam nicht zustande"
		good=0
	fi
	((good))
}
