# shellcheck shell=bash
# Datenträger erkennen, SMART bewerten, Disks über Seriennummer/WWN auswählen.

# Gerät, von dem das Rettungssystem gestartet wurde (der Stick), z. B. /dev/sdb.
boot_disk() {
	local dev
	dev=$(blkid -t LABEL=FRS_RESCUE -o device 2>/dev/null | head -n1)
	[[ -z $dev ]] && dev=$(findmnt -no SOURCE /cdrom 2>/dev/null)
	[[ -z $dev ]] && return 1
	local pk
	pk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1)
	if [[ -n $pk ]]; then echo "/dev/$pk"; else echo "$dev"; fi
}

# Alle physischen Disks als JSON-Zeilen (ohne Loop, RAM, CD, ohne den Boot-Stick).
disks_json() {
	local bd
	bd=$(boot_disk 2>/dev/null || true)
	lsblk -J -b -d -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,TRAN,ROTA,TYPE,RM,LOG-SEC,PHY-SEC 2>/dev/null |
		jq -c --arg bd "$bd" '.blockdevices[]
			| select(.type == "disk")
			| select(.name | test("^(loop|ram|zram|sr|dm-|md)") | not)
			| select(.path != $bd)
			| .model = ((.model // "") | gsub("^\\s+|\\s+$"; ""))
			| .serial = ((.serial // "") | gsub("^\\s+|\\s+$"; ""))'
}

# Eindeutige, stabile Kennung einer Disk: Seriennummer, sonst WWN, sonst Pfad.
disk_id() {
	local j=$1
	jq -r 'if (.serial // "") != "" then .serial elif (.wwn // "") != "" then .wwn else .path end' <<<"$j"
}

# Kennung -> aktueller Gerätepfad (/dev/sdX kann sich nach Reset/Neustecken ändern).
disk_resolve() {
	local id=$1
	disks_json | jq -r --arg id "$id" 'select(.serial == $id or .wwn == $id or .path == $id) | .path' | head -n1
}

disk_info() {
	local id=$1
	disks_json | jq -c --arg id "$id" 'select(.serial == $id or .wwn == $id or .path == $id)' | head -n1
}

disk_label() {
	local j=$1
	printf '%s · %s · SN %s · %s · %s' "$(jq -r .path <<<"$j")" "$(jq -r '.model // "?"' <<<"$j")" \
		"$(human "$(jq -r .size <<<"$j")")" "$(jq -r '.serial // "–"' <<<"$j")" "$(jq -r '.tran // "?"' <<<"$j")"
}

# SMART-Bewertung: gibt "OK", "WARN", "DEFEKT" oder "UNBEKANNT" und eine Begründung aus.
# Ergebnis wird pro Sitzung zwischengespeichert, weil smartctl bei defekten Disks langsam ist.
disk_smart() {
	local dev=$1 cache
	cache="$FRS_RUN/smart-$(basename "$dev")"
	if [[ -f $cache && $(($(date +%s) - $(stat -c %Y "$cache"))) -lt 300 ]]; then
		cat "$cache"
		return
	fi
	local j state="UNBEKANNT" reasons=()
	j=$(sudo timeout 60 smartctl -j -H -A -l error "$dev" 2>/dev/null) || true
	if [[ -n $j ]] && jq -e . >/dev/null 2>&1 <<<"$j"; then
		local passed realloc pending uncorr media crit
		passed=$(jq -r '.smart_status.passed // empty' <<<"$j")
		realloc=$(jq -r '[.ata_smart_attributes.table[]? | select(.id == 5) | .raw.value][0] // 0' <<<"$j")
		pending=$(jq -r '[.ata_smart_attributes.table[]? | select(.id == 197) | .raw.value][0] // 0' <<<"$j")
		uncorr=$(jq -r '[.ata_smart_attributes.table[]? | select(.id == 198) | .raw.value][0] // 0' <<<"$j")
		media=$(jq -r '.nvme_smart_health_information_log.media_errors // 0' <<<"$j")
		crit=$(jq -r '.nvme_smart_health_information_log.critical_warning // 0' <<<"$j")
		[[ -n $passed ]] && state="OK"
		((realloc > 0)) && reasons+=("$realloc umgelagerte Sektoren")
		((pending > 0)) && reasons+=("$pending schwebende Sektoren")
		((uncorr > 0)) && reasons+=("$uncorr unkorrigierbare Sektoren")
		((media > 0)) && reasons+=("$media NVMe-Medienfehler")
		((crit > 0)) && reasons+=("NVMe-Warnung $crit")
		((${#reasons[@]} > 0)) && state="WARN"
		if [[ $passed == false ]]; then
			state="DEFEKT"
			reasons=("SMART-Gesamtstatus FAILED" "${reasons[@]}")
		fi
		((pending > 0 || uncorr > 0 || media > 0)) && [[ $state == WARN ]] && state="DEFEKT"
	else
		reasons+=("kein SMART (USB-Adapter?)")
	fi
	local ioerr
	ioerr=$(sudo dmesg 2>/dev/null | grep -c "I/O error, dev $(basename "$dev")" || true)
	if ((ioerr > 0)); then
		state="DEFEKT"
		reasons+=("$ioerr Lesefehler im Kernel-Log")
	fi
	local out
	out="$state|$(
		IFS=';'
		echo "${reasons[*]}"
	)"
	echo "$out" >"$cache"
	echo "$out"
}

# Tabelle aller Disks für den Startbildschirm. Setzt DISKS_ANY_BAD=1, wenn eine Disk auffällig ist.
disks_overview() {
	DISKS_ANY_BAD=0
	local j dev st reason
	printf '%-9s %-8s %-28s %-10s %-20s %s\n' "GERÄT" "ZUSTAND" "MODELL" "GRÖSSE" "SERIENNUMMER" "BUS"
	while IFS= read -r j; do
		[[ -z $j ]] && continue
		dev=$(jq -r .path <<<"$j")
		IFS='|' read -r st reason <<<"$(disk_smart "$dev")"
		[[ $st == WARN || $st == DEFEKT ]] && DISKS_ANY_BAD=1
		printf '%-9s %-8s %-28.28s %-10s %-20.20s %s\n' "$(basename "$dev")" "[$st]" \
			"$(jq -r '.model // "?"' <<<"$j")" "$(human "$(jq -r .size <<<"$j")")" \
			"$(jq -r '.serial // "–"' <<<"$j")" "$(jq -r '.tran // "?"' <<<"$j")"
		[[ -n $reason ]] && printf '          %s\n' "${reason//;/, }"
	done < <(disks_json)
}

# disk_pick TITEL TEXT [AUSSCHLUSS-ID ...]  -> gibt die Disk-Kennung aus
disk_pick() {
	local title=$1 text=$2
	shift 2
	local exclude=("$@") items=() j id dev st skip x
	while IFS= read -r j; do
		[[ -z $j ]] && continue
		id=$(disk_id "$j")
		skip=0
		for x in "${exclude[@]}"; do [[ $x == "$id" ]] && skip=1; done
		((skip)) && continue
		dev=$(jq -r .path <<<"$j")
		st=$(disk_smart "$dev" | cut -d'|' -f1)
		items+=("$id" "$(printf '%-8s %-8s %-26.26s %s' "$(basename "$dev")" "[$st]" "$(jq -r '.model // "?"' <<<"$j")" "$(human "$(jq -r .size <<<"$j")")")")
	done < <(disks_json)
	if ((${#items[@]} == 0)); then
		ui_msg "$title" "Keine passende Disk gefunden.\n\nIst die Disk angeschlossen und eingeschaltet? USB-Adapter brauchen manchmal ein paar Sekunden."
		return 1
	fi
	ui_menu "$title" "$text" -- "${items[@]}"
}

# Partitionen einer Disk als JSON-Zeilen (mit Dateisystem und Größe).
disk_parts() {
	lsblk -J -b -o NAME,PATH,SIZE,FSTYPE,LABEL,PARTTYPE,PARTLABEL,MOUNTPOINT,FSAVAIL "$1" 2>/dev/null |
		jq -c '.blockdevices[0].children[]?'
}

# Wird irgendeine Partition der Disk gerade benutzt?
disk_in_use() {
	local dev=$1
	lsblk -nr -o MOUNTPOINT "$dev" | grep -q . && return 0
	[[ -n $(lsblk -nr -o NAME "$dev" | tail -n +2 | while read -r n; do ls "/sys/class/block/$n/holders/" 2>/dev/null; done) ]]
}
