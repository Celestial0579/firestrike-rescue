# shellcheck shell=bash
# Werkzeuge: SMART, Speichertest, Netzwerk, SSH, Protokolle, Shell.

tools_menu() {
	local c
	while true; do
		c=$(ui_menu "Werkzeuge" "" -- \
			smart "SMART-Details und Selbsttest" \
			mem "Arbeitsspeicher kurz testen (memtester)" \
			net "Netzwerk / WLAN verbinden (nmtui)" \
			ssh "Fernzugriff per SSH ein/aus" \
			persist "Persistenter Speicher" \
			logs "Protokolle ansehen" \
			hw "Hardware-Übersicht" \
			mc "Dateimanager (Midnight Commander)" \
			shell "Shell (Rückkehr mit exit)") || return 0
		case $c in
		smart) tools_smart ;;
		mem) tools_mem ;;
		net) nmtui ;;
		ssh) tools_ssh ;;
		persist) persist_menu ;;
		logs) tools_logs ;;
		hw) sudo lshw -short >"$FRS_RUN/hw.txt" 2>&1; ui_textfile "Hardware" "$FRS_RUN/hw.txt" ;;
		mc) mc ;;
		shell) clear; echo "Shell. Zurück zum Assistenten mit 'exit'."; bash -i ;;
		esac
	done
}

tools_smart() {
	local id dev a
	id=$(disk_pick "SMART" "Welche Disk?") || return 0
	dev=$(disk_resolve "$id")
	a=$(ui_menu "SMART" "$dev" -- \
		show "Alle SMART-Daten anzeigen" \
		short "Kurztest starten (ca. 2 Minuten)" \
		long "Langtest starten (Stunden; NICHT bei defekten Disks)" \
		result "Testergebnisse anzeigen") || return 0
	case $a in
	show | result)
		sudo smartctl -x "$dev" >"$FRS_RUN/smart.txt" 2>&1
		ui_textfile "SMART $dev" "$FRS_RUN/smart.txt"
		;;
	short) run sudo smartctl -t short "$dev"; ui_msg "SMART" "Kurztest läuft. Ergebnis in ca. 2 Minuten unter 'Testergebnisse'." ;;
	long)
		ui_yesno "Langtest" "Der Langtest liest die ganze Disk. Bei einer kranken Disk kann das den Zustand verschlechtern.\nVorher retten! Trotzdem starten?" --defaultno &&
			run sudo smartctl -t long "$dev" && ui_msg "SMART" "Langtest läuft im Laufwerk selbst."
		;;
	esac
	rm -f "$FRS_RUN/smart-$(basename "$dev")"
}

tools_mem() {
	local free mb
	free=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
	mb=$(ui_input "memtester" "Wie viele MB testen? (verfügbar: $free MB)\nFür einen gründlichen Test besser memtest86+ aus dem Bootmenü." "$((free * 7 / 10))") || return 0
	[[ $mb =~ ^[0-9]+$ ]] || return 0
	tmux_run "frs-memtest" bash -c "sudo memtester ${mb}M 1; read -r -p 'Fertig. Enter … ' _"
}

tools_ssh() {
	if systemctl is-active -q ssh; then
		ui_yesno "SSH" "SSH ist an. Ausschalten?" && run sudo systemctl stop ssh
		return 0
	fi
	is_online || { ui_msg "SSH" "Keine Netzwerkverbindung."; return 0; }
	local pw ips
	pw=$(tr -dc 'a-km-zA-HJ-NP-Z2-9' </dev/urandom | head -c 12)
	echo "$(id -un):$pw" | sudo chpasswd
	run sudo systemctl start ssh
	ips=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
	log "SSH eingeschaltet (Einmal-Passwort gesetzt)"
	ui_msg "SSH ist an" "Verbinden mit:\n\n   ssh $(id -un)@${ips%% *}\n\nAdressen: $ips\nPasswort (nur für diese Sitzung): $pw\n\nLaufende Rettung ansehen: tmux attach -t frs-rettung"
}

tools_logs() {
	local items=() f
	for f in "$FRS_PERSIST"/logs/*.log "$FRS_RUN"/logs/*.log; do
		[[ -f $f ]] && items+=("$f" "$(date -r "$f" '+%F %T') $(human "$(stat -c %s "$f")")")
	done
	((${#items[@]})) || { ui_msg "Protokolle" "Keine Protokolle gefunden."; return 0; }
	f=$(ui_menu "Protokolle" "Welches Protokoll?" -- "${items[@]}") || return 0
	ui_textfile "$(basename "$f")" "$f"
}
