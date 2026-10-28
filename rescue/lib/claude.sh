# shellcheck shell=bash
# Claude Code CLI und Claude Desktop im Rettungssystem.

claude_bin() {
	if [[ -x $HOME/.local/bin/claude ]]; then echo "$HOME/.local/bin/claude"; else echo /usr/local/bin/claude; fi
}

# Hält die CLI auf der Persistenz aktuell (im Hintergrund, Fehler sind egal).
claude_update_bg() {
	persist_is_open || return 0
	is_online || return 0
	(/usr/local/bin/claude install stable >>"$FRS_LOG" 2>&1 &)
}

# Schreibt den aktuellen Zustand als CLAUDE.md in ein Sitzungsverzeichnis.
claude_context() {
	local dir=$1 case=${2:-}
	mkdir -p "$dir"
	{
		echo "# Aktueller Zustand (automatisch von frs erzeugt, $(date '+%F %T'))"
		echo
		echo "## Disks"
		echo '```'
		disks_overview
		echo '```'
		echo
		echo "## lsblk"
		echo '```'
		lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,SERIAL,MOUNTPOINT,RO 2>/dev/null
		echo '```'
		if [[ -s $FRS_RUN/readonly ]]; then
			echo
			echo "## Schreibgeschützte Quell-Disks (NIEMALS beschreiben)"
			sort -u "$FRS_RUN/readonly" | sed 's/^/- /'
		fi
		if [[ -n $case ]]; then
			echo
			echo "## Aktueller Rettungsfall: $case"
			echo '```'
			cat "$case/case.env" 2>/dev/null
			echo
			ddrescuelog -t "$case/image.map" 2>/dev/null
			echo '```'
			echo "Bericht: $case/report.txt · ddrescue-Log: $case/rescue.log"
		fi
		echo
		echo "## Protokoll der Sitzung"
		echo "$FRS_LOG (letzte Zeilen:)"
		echo '```'
		tail -n 40 "$FRS_LOG" 2>/dev/null
		echo '```'
	} >"$dir/CLAUDE.md"
}

claude_start() {
	local case=${1:-} dir="$FRS_RUN/claude-session"
	if ! is_online; then
		ui_msg "Claude" "Keine Internetverbindung.\n\nWerkzeuge > Netzwerk (nmtui) zum Verbinden, LAN-Kabel geht meist automatisch."
		return 0
	fi
	persist_is_open || ui_msg "Claude" "Hinweis: Kein persistenter Speicher eingehängt.\nDer Login gilt nur bis zum Neustart."
	ui_info "Claude" "Sammle den aktuellen Zustand für Claude …"
	claude_context "$dir" "$case"
	clear
	cat <<-EOF
		Claude Code startet im Verzeichnis $dir.
		Claude kennt den aktuellen Zustand (Disks, SMART, Rettungsfall, Protokoll) aus CLAUDE.md.

		Erster Start: /login wählen, die angezeigte URL auf dem Handy oder einem anderen
		Rechner öffnen und den Code hier einfügen. Beenden mit /exit oder Strg+D.

	EOF
	(cd "$dir" && "$(claude_bin)")
}

claude_desktop() {
	if ! is_online; then
		ui_msg "Claude Desktop" "Keine Internetverbindung."
		return 0
	fi
	if ! command -v claude-desktop >/dev/null; then
		ui_msg "Claude Desktop" "Claude Desktop ist in diesem Image nicht installiert."
		return 0
	fi
	persist_is_open || ui_msg "Claude Desktop" "Hinweis: Kein persistenter Speicher eingehängt.\nDer Login gilt nur bis zum Neustart."
	claude_context "$FRS_RUN/claude-session"
	ui_msg "Claude Desktop" "Claude Desktop startet im Vollbild (ohne Desktop drumherum).\n\nBeenden: App schließen (Strg+Q). Danach geht es hier weiter.\nFunktioniert die Grafik nicht: Strg+Alt+F2 wechselt auf eine Konsole."
	clear
	# Eigene D-Bus-Sitzung mit entsperrtem Schlüsselbund (Login-Speicher der App).
	# Der Schlüsselbund liegt in ~/.local/share/keyrings auf der (verschlüsselten) Persistenz.
	dbus-run-session -- bash -c '
		eval "$(printf "" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
		eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null)"
		export GNOME_KEYRING_CONTROL SSH_AUTH_SOCK XDG_CURRENT_DESKTOP=frs
		cd "$HOME"
		exec cage -s -- claude-desktop --ozone-platform-hint=auto
	' >>"$FRS_LOG" 2>&1 || ui_msg "Claude Desktop" "Claude Desktop wurde mit Fehler beendet. Details im Protokoll:\n$FRS_LOG"
}
