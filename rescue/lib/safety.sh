# shellcheck shell=bash
# Sicherheitsregeln. Alle schreibenden Wege laufen hier durch.
#  - Quell-Disks werden auf Kernelebene schreibgeschützt (blockdev --setro).
#  - Ziel-Disks müssen über die letzten 4 Zeichen der Seriennummer bestätigt werden,
#    ersatzweise über WWN oder Gerätename plus Größe. Eine leere Eingabe bestätigt nie.
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

# Leerraum am Anfang und Ende entfernen.
_safety_trim() {
	local s=$1
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

# safety_confirm_token DISK-JSON
# Legt fest, was zur Bestätigung einzutippen ist. Setzt
#   SAFETY_WANT  die verlangte Eingabe, nie leer
#   SAFETY_ASK   die Aufforderung im Dialog, passend zu SAFETY_WANT
#   SAFETY_ID    die Kennung fürs Protokoll
# Rückgabe 1, wenn die Disk nicht (mehr) erkennbar ist.
#
# Seriennummer, sonst WWN: Beides steht am Gerät und lässt sich dort gegenprüfen. Verlangt
# werden die letzten 4 Zeichen, bei einer kürzeren Kennung die ganze. Meldet die Disk keines
# von beiden (manche USB-Adapter, virtuelle Disks), bleibt nur, was auf dem Bildschirm steht:
# Gerätename und Größe. Der Gerätename allein reicht nicht, den tippt man aus Gewohnheit, und
# ohne Seriennummer ist er zugleich die Kennung, unter der die Disk gesucht wird. Die Größe
# ist dann das Merkmal, an dem eine vertauschte Disk auffällt.
safety_confirm_token() {
	local j=$1 path serial wwn size name what id
	SAFETY_WANT="" SAFETY_ASK="" SAFETY_ID=""
	path=$(jq -r '.path // ""' <<<"$j" 2>/dev/null)
	[[ -n $path ]] || return 1
	serial=$(_safety_trim "$(jq -r '.serial // ""' <<<"$j")")
	wwn=$(_safety_trim "$(jq -r '.wwn // ""' <<<"$j")")

	if [[ -z $serial && -z $wwn ]]; then
		name=${path##*/}
		size=$(jq -r '.size // 0' <<<"$j")
		[[ $size =~ ^[0-9]+$ ]] || size=0
		if ((size >= 1073741824)); then
			SAFETY_WANT="$name-$(((size + 536870912) / 1073741824))GiB"
		else
			SAFETY_WANT="$name-$(((size + 524288) / 1048576))MiB"
		fi
		SAFETY_ID="ohne Seriennummer und WWN, $SAFETY_WANT"
		SAFETY_ASK="Diese Disk meldet weder Seriennummer noch WWN. Bitte Modell und Größe oben genau prüfen.\nZur Bestätigung Gerätename und Größe eingeben, genau so: $SAFETY_WANT"
		return 0
	fi

	if [[ -n $serial ]]; then
		what="Seriennummer" id=$serial
	else
		what="WWN" id=$wwn
		SAFETY_ASK="Diese Disk meldet keine Seriennummer.\n"
	fi
	SAFETY_ID="$what $id"
	if ((${#id} >= 4)); then
		SAFETY_WANT=${id: -4}
		SAFETY_ASK+="Zur Bestätigung die letzten 4 Zeichen der $what eingeben ($id):"
	else
		SAFETY_WANT=$id
		SAFETY_ASK+="Die $what hat nur ${#id} Zeichen. Zur Bestätigung die ganze $what eingeben ($id):"
	fi
}

# safety_confirm_target ZIEL-ID AKTION   Zeigt das Ziel und verlangt dessen Kennung (safety_confirm_token).
# Eine leere Eingabe bestätigt nie.
safety_confirm_target() {
	local tid=$1 action=$2 j tdev intro parts room n got
	j=$(disk_info "$tid")
	if ! safety_confirm_token "$j" || [[ -z $SAFETY_WANT ]]; then
		die "Die Ziel-Disk $tid ist nicht mehr zu finden (abgezogen oder neu erkannt?). Es wurde nichts geändert."
		return 1
	fi
	tdev=$(jq -r .path <<<"$j")
	intro="ACHTUNG: $action\n\nZiel: $(disk_label "$j")"

	# Die Aufforderung steht zuletzt, direkt über dem Eingabefeld, und muss sichtbar bleiben.
	# Reicht der Bildschirm nicht für alles, wird deshalb die Partitionsliste gekürzt.
	parts=$(lsblk -o NAME,SIZE,FSTYPE,LABEL "$tdev" 2>/dev/null)
	if [[ -n $parts ]]; then
		parts=$(ui_fold "$parts")
		n=$(wc -l <<<"$parts")
		room=$(($(ui_input_room) - $(ui_fold "$intro\n\n$SAFETY_ASK" | wc -l) - 1))
		if ((n > room)); then
			if ((room >= 3)); then
				parts="$(head -n $((room - 1)) <<<"$parts")"$'\n'"… ($((n - room + 1)) weitere Einträge)"
			else
				parts=""
			fi
		fi
	fi

	got=$(ui_input "Ziel bestätigen" "$intro\n\n${parts:+$parts\n\n}$SAFETY_ASK") || return 1
	got=$(_safety_trim "$got")
	if [[ -z $got ]]; then
		ui_msg "Nicht bestätigt" "Es wurde nichts eingegeben. Ohne Bestätigung wird nichts geändert."
		log "Bestätigung für $tdev abgelehnt (leere Eingabe)"
		return 1
	fi
	if [[ ${got^^} != "${SAFETY_WANT^^}" ]]; then
		ui_msg "Nicht bestätigt" "Die Eingabe passt nicht zu dieser Disk. Es wurde nichts geändert."
		log "Bestätigung für $tdev abgelehnt (Eingabe '$got')"
		return 1
	fi
	log "Ziel bestätigt: $tdev ($SAFETY_ID) für: $action"
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
