# shellcheck shell=bash
# Ziel-Disk für Images vorbereiten und einhängen (nach $LF_TARGET_MNT).

# Dateisysteme, auf denen Images > 4 GiB abgelegt werden können.
TARGET_FS_OK="ext4 ext3 xfs btrfs exfat ntfs"

# Schutzoptionen für jedes Ziel-Dateisystem. Was auf einer Ziel-Disk liegt, hat jemand anderes
# dorthin gelegt. Der Assistent braucht dort nur gewöhnliche Dateien und Ordner:
#   nodev        Gerätedateien auf dem Ziel öffnen kein Gerät (image.img als Gerätedatei).
#   nosuid       Setuid- und Setgid-Bits auf dem Ziel wirken nicht.
#   noexec       Vom Ziel wird nichts ausgeführt.
#   nosymfollow  Verknüpfungen auf dem Ziel werden nicht verfolgt (LF, Fallordner oder
#                image.img als Verknüpfung auf eine andere Stelle oder eine andere Disk).
TARGET_MOUNT_OPTS=(nodev nosuid noexec nosymfollow)

target_mount_optstring() {
	local IFS=,
	echo "${TARGET_MOUNT_OPTS[*]}"
}

# Einhängen mit den Schutzoptionen, je nach Dateisystem. Rückgabe wie mount.
target_mount_raw() {
	local part=$1 fs=$2 opts own
	opts=$(target_mount_optstring)
	# Dateien gehören dem Assistenten. umask=022: Andere Benutzer, auch Claude (lf-claude), lesen nur.
	own="uid=$(id -u),gid=$(id -g),umask=022"
	case $fs in
	ntfs)
		# ntfs3 wendet umask nur auf Dateien an, die nach dem Einhängen entstehen. Was schon auf
		# der Disk liegt, auch das Wurzelverzeichnis, kann für alle beschreibbar bleiben. Dann wird
		# mit ntfs-3g eingehängt, das die Maske auf alles anwendet. Andere Benutzer, auch Claude
		# (lf-claude), schreiben so nie aufs Ziel.
		if run sudo mount -t ntfs3 -o "$opts,$own" "$part" "$LF_TARGET_MNT"; then
			target_others_can_write || return 0
			log "ntfs3: $LF_TARGET_MNT ist für andere Benutzer beschreibbar, Wechsel zu ntfs-3g"
			run sudo umount "$LF_TARGET_MNT" || return 1
		fi
		target_mount_ntfs3g "$part"
		;;
	exfat) run sudo mount -o "$opts,$own" "$part" "$LF_TARGET_MNT" ;;
	*) run sudo mount -o "$opts" "$part" "$LF_TARGET_MNT" ;;
	esac
}

# target_others_can_write   Kann ein anderer Benutzer als der Assistent im Ziel schreiben?
target_others_can_write() {
	sudo -u nobody -n test -w "$LF_TARGET_MNT" 2>/dev/null
}

# Ersatzweg für NTFS, wenn der Kerneltreiber ntfs3 ablehnt. ntfs-3g (FUSE) kennt nosymfollow
# nicht. Die Option setzt target_mount_secure danach am Einhängepunkt.
target_mount_ntfs3g() {
	run sudo ntfs-3g -o "nodev,nosuid,noexec,uid=$(id -u),gid=$(id -g),umask=022" "$1" "$LF_TARGET_MNT"
}

# Gelten am Einhängepunkt des Ziels wirklich alle Schutzoptionen (mount_has_opts in common.sh)?
target_mount_has_opts() { mount_has_opts "$LF_TARGET_MNT" "${TARGET_MOUNT_OPTS[@]}"; }

# Setzt fehlende Schutzoptionen nach. Gelten danach nicht alle, wird das Ziel wieder ausgehängt:
# lieber kein Ziel als eines ohne Schutz (mount_enforce in common.sh).
target_mount_secure() { mount_enforce "$LF_TARGET_MNT" "${TARGET_MOUNT_OPTS[@]}"; }

# target_release_images   Vor dem Aushängen des bisherigen Ziels: Images darauf, die lf noch
#   eingebunden hat (etwa nach "Dateien kopieren"), hielten es sonst belegt (#83). Was davon noch
#   benutzt wird, bleibt und steht im Protokoll (image_release in recover.sh).
target_release_images() {
	declare -F image_release >/dev/null || return 0
	image_release "$LF_TARGET_MNT" || true
}

target_mount_part() {
	local part=$1 fs
	fs=$(lsblk -no FSTYPE "$part")
	sudo install -d "$LF_TARGET_MNT"
	if mountpoint -q "$LF_TARGET_MNT"; then
		# Hängt genau diese Partition schon geschützt und beschreibbar dort, bleibt sie
		# eingehängt. Ein Kopierlauf im Hintergrund, der das Ziel gerade benutzt, stört so nicht.
		if [[ $(findmnt -n -o SOURCE -M "$LF_TARGET_MNT" 2>/dev/null) == "$part" ]] && target_mount_has_opts && mount_has_opts "$LF_TARGET_MNT" rw; then
			return 0
		fi
		# Zwei Dateisysteme übereinander am selben Punkt gibt es nicht: Dann ließe sich nicht
		# mehr sagen, für welches die geprüften Optionen gelten.
		target_release_images
		if ! run sudo umount "$LF_TARGET_MNT"; then
			log "Ziel abgelehnt: $LF_TARGET_MNT ist noch in Benutzung und lässt sich nicht aushängen."
			return 1
		fi
	fi
	# Ein Schreibschutz, den eine abgebrochene Suche zurückgelassen hat, endet hier.
	target_search_unlock
	target_mount_raw "$part" "$fs" || return 1
	target_mount_secure || return 1
	# Ein Ziel muss beschreibbar sein. Hängt es nur lesend (Gerät schreibgeschützt, Windows im
	# Ruhezustand), wird es gleich abgelehnt und nicht erst beim Schreiben.
	if ! mount_has_opts "$LF_TARGET_MNT" rw; then
		log "Ziel abgelehnt: $part ließ sich nur lesend einhängen."
		run sudo umount "$LF_TARGET_MNT"
		return 1
	fi
	case $fs in
	ntfs | exfat) ;;
	*) run sudo chown "$(id -u):$(id -g)" "$LF_TARGET_MNT" ;;
	esac
}

target_fs() { findmnt -no FSTYPE "$LF_TARGET_MNT" 2>/dev/null; }

target_free() { df -B1 --output=avail "$LF_TARGET_MNT" | tail -n1 | tr -d ' '; }

# Ganze Disk neu einrichten: GPT, eine Partition, ext4 oder exFAT.
target_format() {
	local tid=$1 dev fs text="Welches Dateisystem soll das Ziel bekommen?" preset=()
	dev=$(disk_resolve "$tid")
	# LF_TARGET_FS aus der lf.conf wählt nur vor. Entschieden wird hier, und bestätigt danach.
	case ${LF_TARGET_FS:-} in
	ext4 | exfat)
		preset=(--default-item "$LF_TARGET_FS")
		text+="\nVorausgewählt ist $LF_TARGET_FS (LF_TARGET_FS in der lf.conf)."
		;;
	esac
	fs=$(ui_menu "Ziel formatieren" "$text" "${preset[@]}" -- \
		ext4 "Empfohlen. Schnell, große Dateien, Images können sparse sein." \
		exfat "Auch unter Windows und macOS lesbar.") || return 1
	safety_confirm_target "$tid" "Die GESAMTE Disk wird gelöscht und als $fs formatiert." "$dev" || return 1
	safety_release "$dev" || { die "Partitionen auf $dev sind noch in Benutzung."; return 1; }
	ui_info "Ziel formatieren" "Formatiere $dev als $fs …"
	run sudo wipefs -a "$dev" &&
		run sudo sgdisk -Z "$dev" &&
		run sudo sgdisk -n 1:0:0 -t 1:"$([[ $fs == exfat ]] && echo 0700 || echo 8300)" -c 1:LF-TARGET "$dev" &&
		run sudo partprobe "$dev" && sleep 2 || { die "Partitionieren von $dev fehlgeschlagen. Details im Protokoll."; return 1; }
	local part
	part=$(lsblk -nr -o PATH "$dev" | sed -n 2p)
	if [[ $fs == exfat ]]; then
		run sudo mkfs.exfat -L LF-TARGET "$part"
	else
		run sudo mkfs.ext4 -F -L LF-TARGET -m 0 -T largefile "$part"
	fi || { die "Formatieren fehlgeschlagen. Details im Protokoll."; return 1; }
	target_mount_part "$part"
}

# target_prepare ZIEL-ID BENÖTIGTE-BYTES   -> Ziel ist danach unter $LF_TARGET_MNT beschreibbar.
target_prepare() {
	local tid=$1 need=$2 dev items=() p path fs size label
	dev=$(disk_resolve "$tid")
	while IFS= read -r p; do
		path=$(jq -r .path <<<"$p")
		fs=$(jq -r '.fstype // ""' <<<"$p")
		size=$(jq -r .size <<<"$p")
		label=$(jq -r '.label // ""' <<<"$p")
		[[ " $TARGET_FS_OK " == *" $fs "* ]] || continue
		items+=("$path" "$(printf '%-6s %-10s %s' "$fs" "$(human "$size")" "$label")")
	done < <(disk_parts "$dev")
	items+=("NEU" "Ganze Disk löschen und neu formatieren")

	local choice
	choice=$(ui_menu "Ziel vorbereiten" "Wo soll das Image auf $(basename "$dev") liegen?\nBenötigt: $(human "$need") (Größe der Quell-Disk)" -- "${items[@]}") || return 1
	if [[ $choice == NEU ]]; then
		target_format "$tid" || return 1
	else
		target_mount_part "$choice" || { die "$choice konnte nicht eingehängt werden. Details im Protokoll."; return 1; }
	fi
	local free
	free=$(target_free)
	if ((free < need)); then
		if [[ $(target_fs) == ext4 || $(target_fs) == xfs || $(target_fs) == btrfs ]]; then
			ui_yesno "Wenig Platz" "Auf dem Ziel sind nur $(human "$free") frei, die Quelle hat $(human "$need").\n\nDas Image wird sparse geschrieben: leere Bereiche belegen keinen Platz. Bei voll belegten Disks reicht der Platz aber nicht.\n\nTrotzdem fortfahren?" --defaultno || return 1
		else
			die "Auf dem Ziel sind nur $(human "$free") frei, benötigt werden $(human "$need").\n\nAuf $(target_fs) können Images nicht sparse geschrieben werden. Bitte eine größere Ziel-Disk nehmen oder neu als ext4 formatieren."
			return 1
		fi
	fi
	log "Ziel bereit: $LF_TARGET_MNT ($(target_fs), $(human "$free") frei)"
}

# ---------------------------------------------------------------------------
# Suche nach Rettungsfällen ("Unterbrochene Rettung fortsetzen")
# ---------------------------------------------------------------------------
# Die Suche schreibt nicht. Solange nicht feststeht, dass die gewählte Disk ein Ziel mit einem
# Rettungsfall ist, wird jede ihrer Partitionen behandelt wie eine Quelle: schreibgeschützt auf
# Kernelebene und nur lesend eingehängt, ohne dass der Treiber ein Journal nachspielt. Wer in
# "Fortsetzen" versehentlich die defekte Disk wählt, verändert sie so nicht. Beschreibbar wird
# erst die Partition, deren Rettungsfall der Techniker gewählt hat (target_case_writable).

TARGET_SEARCH_OPTS=(ro nodev nosuid noexec nosymfollow)
TARGET_CASE_PART=""   # Partition, auf der die Suche Rettungsfälle gefunden hat
TARGET_CASE_ACTIVE=0  # 1: Sie hing schon als Ziel dieser Sitzung beschreibbar dort und bleibt so

# Dateisystem-Option, mit der der Treiber beim Einhängen nichts nachspielt und nichts schreibt.
target_search_fsopt() {
	case $1 in
	ext2 | ext3 | ext4) echo noload ;;
	xfs) echo norecovery ;;
	btrfs) echo rescue=nologreplay ;;
	esac
}

# target_search_lock PARTITION   Schreibschutz auf Kernelebene für die Dauer der Suche. Rückgabe 0,
# wenn die Partition danach schreibgeschützt ist. Welche Partition die Suche selbst gesperrt
# hat, steht in $LF_RUN/search-lock: Nur diesen Schutz hebt target_search_unlock wieder auf,
# auch nach einem Abbruch des Assistenten. Ein Schutz, der vorher schon galt (Quell-Disk),
# bleibt unberührt.
target_search_lock() {
	local part=$1
	[[ $(sudo blockdev --getro "$part" 2>/dev/null) == 1 ]] && return 0
	run sudo blockdev --setro "$part" || return 1
	echo "$part" >"$LF_RUN/search-lock"
}

target_search_unlock() {
	local part
	[[ -s $LF_RUN/search-lock ]] || return 0
	part=$(head -n1 "$LF_RUN/search-lock")
	rm -f "$LF_RUN/search-lock"
	[[ $part == /dev/* ]] || return 0
	run sudo blockdev --setrw "$part"
}

# target_mount_search PARTITION DATEISYSTEM   Hängt nur lesend und mit Schutzoptionen ein und
# prüft am Einhängepunkt, ob sie gelten.
target_mount_search() {
	local part=$1 fs=$2 opts fsopt
	opts=$(
		IFS=,
		echo "${TARGET_SEARCH_OPTS[*]}"
	)
	fsopt=$(target_search_fsopt "$fs")
	case $fs in
	ntfs) run sudo mount -t ntfs3 -o "$opts" "$part" "$LF_TARGET_MNT" ||
		run sudo ntfs-3g -o ro,norecover,nodev,nosuid,noexec "$part" "$LF_TARGET_MNT" ;;
	*) run sudo mount -o "$opts${fsopt:+,$fsopt}" "$part" "$LF_TARGET_MNT" ;;
	esac || return 1
	mount_enforce "$LF_TARGET_MNT" "${TARGET_SEARCH_OPTS[@]}"
}

# target_cases_dir   Name des Ordners mit den Rettungsfällen auf dem eingehängten Ziel: LF.
# Übergang von firestrike-rescue, gilt eine Beta lang: Liegen Fälle nur im alten Ordner FRS,
# ist es FRS. Fortgesetzt wird dann dort. Neue Fälle legt der Assistent nur unter LF an.
target_cases_dir() {
	if ! compgen -G "$LF_TARGET_MNT/LF/*/case.env" >/dev/null &&
		compgen -G "$LF_TARGET_MNT/FRS/*/case.env" >/dev/null; then
		echo FRS
	else
		echo LF
	fi
}

# target_has_cases   Liegt auf dem eingehängten Ziel ein Rettungsfall (LF/*/case.env, im
# Übergang auch FRS/*/case.env)?
target_has_cases() {
	compgen -G "$LF_TARGET_MNT/LF/*/case.env" >/dev/null || compgen -G "$LF_TARGET_MNT/FRS/*/case.env" >/dev/null
}

# target_find_cases ZIEL-ID   Sucht auf einer Disk nach Rettungsfällen (LF/*/case.env).
# Rückgabe 0: gefunden. Die Partition hängt dann nur lesend unter $LF_TARGET_MNT und steht in
# TARGET_CASE_PART. Danach folgt genau eines: target_case_writable oder target_search_end.
target_find_cases() {
	local tid=$1 dev
	dev=$(disk_resolve "$tid")
	[[ -n $dev ]] || return 1
	target_find_cases_on "$dev"
}

# target_find_cases_on GERÄT   Wie target_find_cases, für einen Gerätepfad.
target_find_cases_on() {
	local dev=$1 p path fs cur
	TARGET_CASE_PART="" TARGET_CASE_ACTIVE=0
	sudo install -d "$LF_TARGET_MNT"
	if mountpoint -q "$LF_TARGET_MNT"; then
		# Hängt eine Partition dieser Disk schon als Ziel dieser Sitzung dort (beschreibbar und
		# geschützt, etwa weil im Hintergrund noch kopiert wird), bleibt sie, wie sie ist.
		cur=$(findmnt -n -o SOURCE -M "$LF_TARGET_MNT" 2>/dev/null)
		if [[ -n $cur ]] && target_mount_has_opts && mount_has_opts "$LF_TARGET_MNT" rw &&
			lsblk -nr -o PATH "$dev" 2>/dev/null | grep -qxF -- "$cur" &&
			target_has_cases; then
			TARGET_CASE_PART=$cur TARGET_CASE_ACTIVE=1
			return 0
		fi
		target_release_images
		if ! run sudo umount "$LF_TARGET_MNT"; then
			log "Suche abgebrochen: $LF_TARGET_MNT ist noch in Benutzung und lässt sich nicht aushängen."
			return 1
		fi
	fi
	target_search_unlock
	while IFS= read -r p <&3; do
		path=$(jq -r .path <<<"$p")
		fs=$(jq -r '.fstype // ""' <<<"$p")
		[[ " $TARGET_FS_OK " == *" $fs "* ]] || continue
		# Erst der Schreibschutz, dann das Einhängen. Ohne Schreibschutz wird nicht eingehängt.
		target_search_lock "$path" || continue
		if target_mount_search "$path" "$fs"; then
			if target_has_cases; then
				TARGET_CASE_PART=$path
				return 0
			fi
			run sudo umount "$LF_TARGET_MNT"
		fi
		target_search_unlock
	done 3< <(disk_parts "$dev")
	return 1
}

# target_search_end   Beendet eine Suche, deren Fund nicht verwendet wird: aushängen und den
# eigenen Schreibschutz wieder aufheben. Ein schon aktives Ziel bleibt, wie es ist.
target_search_end() {
	if [[ -n $TARGET_CASE_PART ]] && ((!TARGET_CASE_ACTIVE)); then
		mountpoint -q "$LF_TARGET_MNT" && run sudo umount "$LF_TARGET_MNT"
		target_search_unlock
	fi
	TARGET_CASE_PART="" TARGET_CASE_ACTIVE=0
}

# target_case_writable   Hängt die Partition mit dem gewählten Rettungsfall beschreibbar ein.
# Erst jetzt wird auf die Disk geschrieben: Der Techniker hat sie als Ziel genannt und einen
# Rettungsfall auf ihr gewählt.
target_case_writable() {
	local part=$TARGET_CASE_PART active=$TARGET_CASE_ACTIVE
	TARGET_CASE_PART="" TARGET_CASE_ACTIVE=0
	[[ -n $part ]] || return 1
	((active)) && return 0
	target_mount_part "$part"
}
