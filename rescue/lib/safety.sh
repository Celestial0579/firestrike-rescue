# shellcheck shell=bash
# Sicherheitsregeln. Alle schreibenden Wege laufen hier durch.
#  - Quell-Disks werden auf Kernelebene schreibgeschützt (blockdev --setro).
#  - Ziel-Disks müssen über die letzten 4 Zeichen der Seriennummer bestätigt werden.
#  - Der Boot-Stick und die Quell-Disk sind als Ziel gesperrt.

# Disk und alle ihre Partitionen schreibschützen.
safety_set_ro() {
	local dev=$1 p
	run sudo blockdev --setro "$dev"
	for p in $(lsblk -nr -o PATH "$dev" | tail -n +2); do
		run sudo blockdev --setro "$p" || true
	done
	log "Schreibschutz aktiv: $dev"
	echo "$dev" | sudo tee -a "$FRS_RUN/readonly" >/dev/null
}

safety_is_ro() {
	[[ $(sudo blockdev --getro "$1" 2>/dev/null) == 1 ]]
}

# safety_check_target ZIEL-ID [QUELL-ID]   Prüft, ob eine Disk als Ziel erlaubt ist.
safety_check_target() {
	local tid=$1 sid=${2:-} tdev bd
	tdev=$(disk_resolve "$tid")
	[[ -n $tdev ]] || { die "Ziel-Disk $tid ist nicht mehr da."; return 1; }
	bd=$(boot_disk 2>/dev/null || true)
	if [[ $tdev == "$bd" ]]; then
		die "Der Firestrike-Rescue-Stick kann nicht als Ziel benutzt werden."
		return 1
	fi
	if [[ -n $sid && $tid == "$sid" ]]; then
		die "Quelle und Ziel sind dieselbe Disk."
		return 1
	fi
	if grep -qx "$tdev" "$FRS_RUN/readonly" 2>/dev/null || safety_is_ro "$tdev"; then
		die "$tdev ist als Quelle schreibgeschützt und kann kein Ziel sein."
		return 1
	fi
	return 0
}

# safety_confirm_target ZIEL-ID AKTION   Zeigt das Ziel und verlangt die letzten 4 Zeichen der Seriennummer.
safety_confirm_target() {
	local tid=$1 action=$2 j tdev serial want got parts
	j=$(disk_info "$tid")
	tdev=$(jq -r .path <<<"$j")
	serial=$(jq -r '.serial // ""' <<<"$j")
	[[ -z $serial ]] && serial=$(jq -r '.wwn // ""' <<<"$j")
	[[ -z $serial ]] && serial=$(basename "$tdev")
	want=${serial: -4}
	parts=$(lsblk -o NAME,SIZE,FSTYPE,LABEL "$tdev" 2>/dev/null)
	got=$(ui_input "Ziel bestätigen" "ACHTUNG: $action\n\nZiel: $(disk_label "$j")\n\n$parts\n\nZur Bestätigung die letzten 4 Zeichen der Seriennummer eingeben ($serial):") || return 1
	if [[ ${got^^} != "${want^^}" ]]; then
		ui_msg "Nicht bestätigt" "Eingabe stimmt nicht mit der Seriennummer überein. Es wurde nichts geändert."
		log "Bestätigung für $tdev abgelehnt (Eingabe '$got')"
		return 1
	fi
	log "Ziel bestätigt: $tdev ($serial) für: $action"
	return 0
}

# Hängt alle Partitionen einer Disk aus, die der Assistent selbst eingehängt hat.
safety_release() {
	local dev=$1 mp
	while read -r mp; do
		[[ -n $mp ]] && run sudo umount "$mp"
	done < <(lsblk -nr -o MOUNTPOINT "$dev" | sort -r)
	disk_in_use "$dev" && return 1
	return 0
}
