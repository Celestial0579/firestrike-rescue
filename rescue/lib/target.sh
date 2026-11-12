# shellcheck shell=bash
# Ziel-Disk für Images vorbereiten und einhängen (nach $FRS_TARGET_MNT).

# Dateisysteme, auf denen Images > 4 GiB abgelegt werden können.
TARGET_FS_OK="ext4 ext3 xfs btrfs exfat ntfs"

# Schutzoptionen für jedes Ziel-Dateisystem. Was auf einer Ziel-Disk liegt, hat jemand anderes
# dorthin gelegt. Der Assistent braucht dort nur gewöhnliche Dateien und Ordner:
#   nodev        Gerätedateien auf dem Ziel öffnen kein Gerät (image.img als Gerätedatei).
#   nosuid       Setuid- und Setgid-Bits auf dem Ziel wirken nicht.
#   noexec       Vom Ziel wird nichts ausgeführt.
#   nosymfollow  Verknüpfungen auf dem Ziel werden nicht verfolgt (FRS, Fallordner oder
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
	own="uid=$(id -u),gid=$(id -g)"
	case $fs in
	ntfs) run sudo mount -t ntfs3 -o "$opts,$own" "$part" "$FRS_TARGET_MNT" || target_mount_ntfs3g "$part" ;;
	exfat) run sudo mount -o "$opts,$own" "$part" "$FRS_TARGET_MNT" ;;
	*) run sudo mount -o "$opts" "$part" "$FRS_TARGET_MNT" ;;
	esac
}

# Ersatzweg für NTFS, wenn der Kerneltreiber ntfs3 ablehnt. ntfs-3g (FUSE) kennt nosymfollow
# nicht. Die Option setzt target_mount_secure danach am Einhängepunkt.
target_mount_ntfs3g() {
	run sudo ntfs-3g -o "nodev,nosuid,noexec,uid=$(id -u),gid=$(id -g)" "$1" "$FRS_TARGET_MNT"
}

# Gelten am Einhängepunkt wirklich alle Schutzoptionen? Gefragt wird der Kernel (findmnt),
# nicht der eigene Aufruf.
target_mount_has_opts() {
	local line opt n=0
	while IFS= read -r line; do
		n=$((n + 1))
		for opt in "${TARGET_MOUNT_OPTS[@]}"; do
			[[ ",$line," == *",$opt,"* ]] || return 1
		done
	done < <(findmnt -n -o VFS-OPTIONS -M "$FRS_TARGET_MNT" 2>/dev/null)
	((n > 0))
}

# Setzt fehlende Schutzoptionen am Einhängepunkt nach. Gelten danach nicht alle, wird das Ziel
# wieder ausgehängt: lieber kein Ziel als eines ohne Schutz.
# "remount,bind" ändert nur die Optionen des Einhängepunkts, nicht das Dateisystem. Mit -i ruft
# mount dafür kein Hilfsprogramm des Dateisystems auf (ntfs-3g kann nicht neu einhängen).
target_mount_secure() {
	target_mount_has_opts && return 0
	run sudo mount -i -o "remount,bind,$(target_mount_optstring)" "$FRS_TARGET_MNT"
	target_mount_has_opts && return 0
	log "Ziel abgelehnt: Die Schutzoptionen $(target_mount_optstring) gelten nicht. Vorhanden: $(findmnt -n -o VFS-OPTIONS -M "$FRS_TARGET_MNT" 2>/dev/null | tr '\n' ' ')"
	run sudo umount "$FRS_TARGET_MNT"
	return 1
}

target_mount_part() {
	local part=$1 fs
	fs=$(lsblk -no FSTYPE "$part")
	sudo install -d "$FRS_TARGET_MNT"
	# Zwei Dateisysteme übereinander am selben Punkt gibt es nicht: Dann ließe sich nicht mehr
	# sagen, für welches die geprüften Optionen gelten.
	if mountpoint -q "$FRS_TARGET_MNT" && ! run sudo umount "$FRS_TARGET_MNT"; then
		log "Ziel abgelehnt: $FRS_TARGET_MNT ist noch in Benutzung und lässt sich nicht aushängen."
		return 1
	fi
	target_mount_raw "$part" "$fs" || return 1
	target_mount_secure || return 1
	case $fs in
	ntfs | exfat) ;;
	*) run sudo chown "$(id -u):$(id -g)" "$FRS_TARGET_MNT" ;;
	esac
}

target_fs() { findmnt -no FSTYPE "$FRS_TARGET_MNT" 2>/dev/null; }

target_free() { df -B1 --output=avail "$FRS_TARGET_MNT" | tail -n1 | tr -d ' '; }

# Ganze Disk neu einrichten: GPT, eine Partition, ext4 oder exFAT.
target_format() {
	local tid=$1 dev fs
	dev=$(disk_resolve "$tid")
	fs=$(ui_menu "Ziel formatieren" "Welches Dateisystem soll das Ziel bekommen?" -- \
		ext4 "Empfohlen. Schnell, große Dateien, Images können sparse sein." \
		exfat "Auch unter Windows und macOS lesbar.") || return 1
	safety_confirm_target "$tid" "Die GESAMTE Disk wird gelöscht und als $fs formatiert." || return 1
	safety_release "$dev" || { die "Partitionen auf $dev sind noch in Benutzung."; return 1; }
	ui_info "Ziel formatieren" "Formatiere $dev als $fs …"
	run sudo wipefs -a "$dev" &&
		run sudo sgdisk -Z "$dev" &&
		run sudo sgdisk -n 1:0:0 -t 1:"$([[ $fs == exfat ]] && echo 0700 || echo 8300)" -c 1:FRS-TARGET "$dev" &&
		run sudo partprobe "$dev" && sleep 2 || { die "Partitionieren von $dev fehlgeschlagen. Details im Protokoll."; return 1; }
	local part
	part=$(lsblk -nr -o PATH "$dev" | sed -n 2p)
	if [[ $fs == exfat ]]; then
		run sudo mkfs.exfat -L FRS-TARGET "$part"
	else
		run sudo mkfs.ext4 -F -L FRS-TARGET -m 0 -T largefile "$part"
	fi || { die "Formatieren fehlgeschlagen. Details im Protokoll."; return 1; }
	target_mount_part "$part"
}

# target_prepare ZIEL-ID BENÖTIGTE-BYTES   -> Ziel ist danach unter $FRS_TARGET_MNT beschreibbar.
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
	log "Ziel bereit: $FRS_TARGET_MNT ($(target_fs), $(human "$free") frei)"
}

# Sucht auf einer Ziel-Disk nach Rettungsfällen (FRS/*/case.env) und hängt die Partition ein.
target_find_cases() {
	local tid=$1 dev p path fs
	dev=$(disk_resolve "$tid")
	while IFS= read -r p; do
		path=$(jq -r .path <<<"$p")
		fs=$(jq -r '.fstype // ""' <<<"$p")
		[[ " $TARGET_FS_OK " == *" $fs "* ]] || continue
		target_mount_part "$path" || continue
		if compgen -G "$FRS_TARGET_MNT/FRS/*/case.env" >/dev/null; then
			return 0
		fi
		run sudo umount "$FRS_TARGET_MNT"
	done < <(disk_parts "$dev")
	return 1
}
