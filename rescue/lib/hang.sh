# shellcheck shell=bash
# Hängende Disk (#54): Hilfen für lf-rescue-run.
#
# Manche Disks (oft SSD-Controller) hängen nach einigen Minuten Betrieb, egal wo gelesen wird.
# Im Modus "hängende Disk" (HANG_TIMEOUT in der Falldatei) gilt deshalb:
#   - Kurze SCSI-Timeouts für die Quelle, ddrescue gibt mit -T auf, statt zu warten.
#   - Nach einem Hänger liest der Lauf hinter der Hängerstelle weiter. Die Lücke holen spätere
#     Phasen nach.
#   - Ist die Disk weg, wartet der Lauf auf genau diese Disk: Seriennummer und WWN (soweit
#     bekannt) und Größe müssen stimmen, und es darf nur eine solche Disk geben. Neu starten
#     muss sie der Techniker. Das Rettungssystem schaltet keine Steckdosen und keine Geräte.
#
# Die Mapfile liegt im Fallordner auf der Ziel-Disk. Bevor eine Zahl daraus gerechnet wird,
# muss sie die Form einer Hexadezimalzahl haben. Bash rechnet sonst auch mit Ausdrücken.

# Wurzel von sysfs. Nur die Tests setzen sie anders.
HANG_SYS=${HANG_SYS:-/sys}

# hang_hex WERT   Ist WERT eine Hexadezimalzahl, wie ddrescue sie in die Mapfile schreibt?
hang_hex() {
	[[ $1 =~ ^0[xX][0-9A-Fa-f]{1,15}$ ]]
}

# hang_map_pos MAPFILE   Gibt die aktuelle Position (current_pos) in Bytes aus.
hang_map_pos() {
	local a _
	[[ -f $1 && ! -L $1 ]] || return 1
	while read -r a _; do
		[[ -z $a || $a == \#* ]] && continue
		hang_hex "$a" || return 1
		echo "$((a))"
		return 0
	done <"$1"
	return 1
}

# hang_map_rescued MAPFILE   Gibt aus, wie viele Bytes die Mapfile als gerettet ("+") führt.
hang_map_rescued() {
	local a b s _ first=1 sum=0
	[[ -f $1 && ! -L $1 ]] || { echo 0; return 0; }
	while read -r a b s _; do
		[[ -z $a || $a == \#* ]] && continue
		if ((first)); then
			first=0
			continue
		fi
		[[ $s == + ]] && hang_hex "$b" && sum=$((sum + b))
	done <"$1"
	echo "$sum"
}

# hang_find SERIENNUMMER WWN GRÖSSE
# Gibt den Pfad der einen ganzen Disk aus, deren Seriennummer und WWN (jeweils nur, wenn
# bekannt) und Größe übereinstimmen. Rückgabe 1: keine, 2: mehrere. Ohne Seriennummer und
# ohne WWN wird nichts gesucht: Eine Größe allein ist keine Kennung.
hang_find() {
	local s=$1 w=$2 z=$3 list n
	[[ -n $s || -n $w ]] || return 1
	[[ $z =~ ^[0-9]{1,20}$ ]] || return 1
	list=$(lsblk -J -b -d -o PATH,SERIAL,WWN,SIZE,TYPE 2>/dev/null | jq -r --arg s "$s" --arg w "$w" --arg z "$z" '
		.blockdevices[]? | select(.type == "disk")
		| select(($s == "" or ((.serial // "") | gsub("^\\s+|\\s+$"; "")) == $s)
			and ($w == "" or (.wwn // "") == $w)
			and ((.size // "") | tostring) == $z)
		| .path' 2>/dev/null)
	n=$(grep -c . <<<"$list")
	((n == 0)) && return 1
	((n > 1)) && return 2
	printf '%s\n' "$list"
}

# hang_present GERÄT   Ist GERÄT als Blockgerät gemeldet?
hang_present() {
	[[ -n $(lsblk -dn -o PATH "$1" 2>/dev/null) ]]
}

# hang_set_timeout GERÄT SEKUNDEN   Kurze SCSI-Timeouts (Befehl und Fehlerbehandlung).
# Rückgabe 1, wenn das Gerät keinen einstellbaren Timeout hat (etwa NVMe oder device-mapper).
hang_set_timeout() {
	local n=${1##*/} d
	d=$HANG_SYS/block/$n/device
	[[ $n =~ ^[a-z][a-z0-9]{0,31}$ && -w $d/timeout ]] || return 1
	echo "$2" >"$d/timeout" 2>/dev/null || return 1
	[[ -w $d/eh_timeout ]] && echo "$2" >"$d/eh_timeout" 2>/dev/null
	return 0
}

# hang_ddrescue_timeout SCHRITT SEKUNDEN   Wert für ddrescue -T: so lange ohne erfolgreiches
# Lesen, bis ddrescue aufgibt. In Phase 3 liest ddrescue Fehlerstellen einzeln mit
# Wiederholungen, da bleibt Erfolg auch ohne Hänger lange aus. Dort gilt deshalb mehr.
hang_ddrescue_timeout() {
	local t=$2 v
	if [[ $1 == 3 ]]; then
		v=$((t * 20))
		((v < 120)) && v=120
	else
		v=$((t * 4))
		((v < 12)) && v=12
	fi
	echo "${v}s"
}
