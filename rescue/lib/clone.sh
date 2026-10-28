# shellcheck shell=bash
# Klonen Disk -> Disk (oder Image -> Disk) mit automatischer Größenanpassung.
#
# Ablauf: Partitionstabelle der Quelle lesen, Ziel-Layout berechnen (eine "elastische"
# Hauptpartition wächst oder schrumpft, alle Partitionen dahinter rücken ans Ende,
# z. B. die Windows-Wiederherstellung), Tabelle schreiben, jede Partition mit partclone
# übertragen (nur belegte Blöcke), danach das Dateisystem der Hauptpartition anpassen.
# Die Quelle wird nie verändert: Zum Verkleinern wird ein Schreib-Overlay (qemu-nbd
# --snapshot) über die Quellpartition gelegt.

CLONE_RESIZABLE="ntfs ext4 ext3 ext2 xfs btrfs"
CLONE_ALIGN=2048 # Sektoren (1 MiB bei 512-Byte-Sektoren)

part_path() {
	local dev=$1 n=$2
	if [[ $dev =~ [0-9]$ ]]; then echo "${dev}p$n"; else echo "$dev$n"; fi
}

part_num() { sed 's/.*[^0-9]//' <<<"$1"; }

clone_wizard() {
	ui_msg "Klonen" "Klont eine gesunde Disk auf eine andere, z. B. HDD -> SSD.\n\n - Nur belegte Bereiche werden kopiert (partclone), das geht schnell.\n - Ist das Ziel größer, wächst die Hauptpartition; die Wiederherstellungspartition rückt ans Ende.\n - Ist das Ziel kleiner, wird geprüft, ob die Daten passen, und die Hauptpartition verkleinert.\n - Die Quelle wird dabei nie verändert.\n\nBei Disks mit SMART-Warnungen besser 'Datenrettung' nehmen."
	local sid sj sdev st
	sid=$(disk_pick "1/2 Quelle" "Welche Disk soll geklont werden?") || return 0
	sj=$(disk_info "$sid")
	sdev=$(jq -r .path <<<"$sj")
	st=$(disk_smart "$sdev" | cut -d'|' -f1)
	if [[ $st == DEFEKT || $st == WARN ]]; then
		ui_yesno "Quelle auffällig" "SMART meldet für diese Disk: $st\n\nKlonen liest jede belegte Stelle einmal und bricht bei Lesefehlern ab. Für kranke Disks ist 'Datenrettung' (ddrescue, danach Image auf neue Disk) der sicherere Weg.\n\nZur Datenrettung wechseln?" && { recover_wizard; return 0; }
	fi
	safety_set_ro "$sdev"
	clone_from_device "$sdev" "$(disk_label "$sj")" "$sid"
}

# clone_from_device QUELL-GERÄT BESCHREIBUNG [QUELL-ID]
clone_from_device() {
	local sdev=$1 slabel=$2 sid=${3:-} tid tdev tsize ssize
	tid=$(disk_pick "Ziel" "Auf welche Disk soll geklont werden?\nQuelle: $slabel" ${sid:+"$sid"}) || return 0
	safety_check_target "$tid" "$sid" || return 0
	tdev=$(disk_resolve "$tid")
	tsize=$(sudo blockdev --getsize64 "$tdev")
	ssize=$(sudo blockdev --getsize64 "$sdev")

	local sss tss
	sss=$(sudo blockdev --getss "$sdev")
	tss=$(sudo blockdev --getss "$tdev")
	if [[ $sss != "$tss" ]]; then
		die "Sektorgrößen unterscheiden sich (Quelle $sss, Ziel $tss Byte). Ein Partitions-Klon würde nicht booten.\nAusweg: Dateien kopieren oder Ziel über einen anderen Adapter anschließen."
		return 0
	fi

	local pt
	pt=$(sudo sfdisk -J "$sdev" 2>/dev/null)
	if [[ -z $pt ]]; then
		# Keine Partitionstabelle: ganzes Gerät 1:1
		((tsize >= ssize)) || { die "Quelle ohne Partitionstabelle und Ziel ist kleiner. Das geht nicht."; return 0; }
		safety_confirm_target "$tid" "Ziel wird mit dem Inhalt von $sdev überschrieben." || return 0
		tmux_run "frs-klon" bash -c "sudo dd if='$sdev' of='$tdev' bs=4M iflag=fullblock conv=fsync status=progress; echo; read -r -p 'Fertig. Enter … ' _"
		return 0
	fi

	clone_plan "$sdev" "$tdev" "$pt" || return 0

	local keep
	keep=$(ui_menu "Kennungen" "Soll die neue Disk die alte ersetzen?" -- \
		replace "Ja, Ziel ersetzt die Quelle (gleiche IDs, Windows/Linux booten direkt)" \
		both "Nein, beide bleiben im Rechner (neue IDs, sonst Konflikte)") || return 0

	ui_text "Klon-Plan" "Quelle: $slabel\nZiel:   $(disk_label "$(disk_info "$tid")")\n\n$CLONE_SUMMARY"
	safety_confirm_target "$tid" "Ziel wird komplett überschrieben (Klon von $sdev)." || return 0
	safety_release "$tdev" || { die "Partitionen auf $tdev sind in Benutzung."; return 0; }

	clone_write_table "$tdev" "$keep" || return 0
	clone_copy "$sdev" "$tdev" || return 0
	ui_msg "Klon fertig" "Der Klon ist abgeschlossen.\n\n$(clone_boot_hint "$keep")\n\nProtokoll: $FRS_LOG"
}

# Liest die Partitionstabelle und berechnet das Ziel-Layout.
# Setzt CLONE_PT (JSON), CLONE_PARTS (Array), CLONE_NEW_START/SIZE (Arrays), CLONE_ELASTIC, CLONE_SUMMARY.
clone_plan() {
	local sdev=$1 tdev=$2 pt=$3
	CLONE_PT=$pt
	local label ss tsec last
	label=$(jq -r .partitiontable.label <<<"$pt")
	ss=$(jq -r '.partitiontable.sectorsize // 512' <<<"$pt")
	tsec=$(($(sudo blockdev --getsize64 "$tdev") / ss))
	if [[ $label == gpt ]]; then last=$((tsec - 34)); else last=$((tsec - 1)); fi

	if [[ $label == dos ]] && jq -e '.partitiontable.partitions[] | select(.type == "5" or .type == "f" or .type == "85")' <<<"$pt" >/dev/null; then
		die "Die Quelle hat eine erweiterte MBR-Partition. Das unterstützt der Assistent nicht.\nAusweg: Clonezilla (Werkzeuge > Shell > clonezilla)."
		return 1
	fi

	mapfile -t CLONE_PARTS < <(jq -c '.partitiontable.partitions | sort_by(.start) | .[]' <<<"$pt")
	local n=${#CLONE_PARTS[@]} i
	((n > 0)) || { die "Die Quelle hat keine Partitionen."; return 1; }

	# Elastische Partition: größte mit anpassbarem Dateisystem
	local fs size best=-1 bestsize=0 cand=()
	CLONE_FS=()
	for ((i = 0; i < n; i++)); do
		fs=$(sudo blkid -o value -s TYPE "$(jq -r .node <<<"${CLONE_PARTS[i]}")" 2>/dev/null || true)
		CLONE_FS[i]=$fs
		size=$(jq -r .size <<<"${CLONE_PARTS[i]}")
		# Kandidaten ab 4 GiB; kleine Partitionen (z. B. Windows-Wiederherstellung) bleiben fix
		if [[ " $CLONE_RESIZABLE " == *" $fs "* ]] && ((size * ss >= 4294967296)); then
			cand+=("$i" "$(printf '%-16s %-6s %s' "$(basename "$(jq -r .node <<<"${CLONE_PARTS[i]}")")" "$fs" "$(human $((size * ss)))")")
			((size > bestsize)) && { best=$i; bestsize=$size; }
		fi
	done
	CLONE_ELASTIC=$best
	if ((${#cand[@]} > 2)); then
		CLONE_ELASTIC=$(ui_menu "Hauptpartition" "Welche Partition soll wachsen bzw. schrumpfen?" --default-item "$best" -- "${cand[@]}") || return 1
	fi

	# Layout: vor der elastischen alles gleich, danach von hinten aufgereiht
	CLONE_NEW_START=()
	CLONE_NEW_SIZE=()
	local e=$CLONE_ELASTIC s z end
	for ((i = 0; i < n; i++)); do
		CLONE_NEW_START[i]=$(jq -r .start <<<"${CLONE_PARTS[i]}")
		CLONE_NEW_SIZE[i]=$(jq -r .size <<<"${CLONE_PARTS[i]}")
	done
	if ((e >= 0)); then
		end=$((last + 1))
		for ((i = n - 1; i > e; i--)); do
			z=${CLONE_NEW_SIZE[i]}
			s=$(((end - z) / CLONE_ALIGN * CLONE_ALIGN))
			CLONE_NEW_START[i]=$s
			end=$s
		done
		CLONE_NEW_SIZE[e]=$(((end - CLONE_NEW_START[e]) / CLONE_ALIGN * CLONE_ALIGN))
	fi
	for ((i = 0; i < n; i++)); do
		if ((CLONE_NEW_START[i] + CLONE_NEW_SIZE[i] - 1 > last || CLONE_NEW_SIZE[i] <= 0)); then
			die "Das Ziel ist zu klein: Partition $((i + 1)) passt nicht.\nZiel: $(human $((tsec * ss)))"
			return 1
		fi
	done

	# Beim Verkleinern prüfen, ob die Daten passen
	CLONE_SHRINK=0
	if ((e >= 0)); then
		local old new min node
		old=$(jq -r .size <<<"${CLONE_PARTS[e]}")
		new=${CLONE_NEW_SIZE[e]}
		node=$(jq -r .node <<<"${CLONE_PARTS[e]}")
		if ((new < old)); then
			CLONE_SHRINK=1
			clone_min_size "$node" "${CLONE_FS[e]}" || return 1
			min=$CLONE_MIN
			# 5 % + 1 GiB Reserve
			if ((min + min / 20 + 1073741824 > new * ss)); then
				die "Die Daten passen nicht: $(basename "$node") braucht mindestens $(human "$min") (+ Reserve), auf dem Ziel wären es $(human $((new * ss))).\n\nAusweg: Daten auf der Quelle aufräumen oder größeres Ziel nehmen."
				return 1
			fi
		fi
	fi

	CLONE_SS=$ss
	CLONE_LABEL=$label
	CLONE_SUMMARY=$(
		printf '%-4s %-12s %-8s %12s %12s  %s\n' "NR" "QUELLE" "FS" "ALT" "NEU" "HINWEIS"
		for ((i = 0; i < n; i++)); do
			local note=""
			((i == e)) && note="Hauptpartition"
			((i == e && CLONE_SHRINK)) && note="wird verkleinert"
			((i > e && e >= 0)) && note="rückt ans Ende"
			printf '%-4s %-12s %-8s %12s %12s  %s\n' "$(part_num "$(jq -r .node <<<"${CLONE_PARTS[i]}")")" \
				"$(basename "$(jq -r .node <<<"${CLONE_PARTS[i]}")")" "${CLONE_FS[i]:-–}" \
				"$(human $(($(jq -r .size <<<"${CLONE_PARTS[i]}") * ss)))" "$(human $((CLONE_NEW_SIZE[i] * ss)))" "$note"
		done
		echo
		echo "Tabelle: $label · Sektorgröße $ss Byte"
	)
	log "Klon-Plan $sdev -> $tdev:"$'\n'"$CLONE_SUMMARY"
}

# Mindestgröße eines Dateisystems in Bytes (nur lesend ermittelt), Ergebnis in CLONE_MIN.
clone_min_size() {
	local part=$1 fs=$2 out
	case $fs in
	ntfs)
		out=$(sudo ntfsresize --info --force --no-action "$part" 2>&1)
		log "$out"
		CLONE_MIN=$(grep -oP 'You might resize at \K[0-9]+' <<<"$out") && return 0
		die "ntfsresize kann $(basename "$part") nicht auswerten. Meist ist Windows nicht sauber heruntergefahren (Schnellstart/Ruhezustand).\n\nIn Windows: 'shutdown /s /t 0' oder Schnellstart deaktivieren."
		return 1
		;;
	ext2 | ext3 | ext4)
		local blocks bs
		blocks=$(sudo resize2fs -P "$part" 2>/dev/null | grep -oP ':\s*\K[0-9]+$')
		bs=$(sudo dumpe2fs -h "$part" 2>/dev/null | grep -oP '^Block size:\s*\K[0-9]+')
		[[ -n $blocks && -n $bs ]] && { CLONE_MIN=$((blocks * bs)); return 0; }
		die "Mindestgröße von $(basename "$part") nicht ermittelbar (Dateisystem prüfen)."
		return 1
		;;
	*)
		die "$fs kann nicht verkleinert werden. Ausweg: größeres Ziel oder Dateien kopieren (rsync)."
		return 1
		;;
	esac
}

clone_write_table() {
	local tdev=$1 keep=$2 n=${#CLONE_PARTS[@]} i p script
	script=$(mktemp)
	{
		echo "label: $CLONE_LABEL"
		if [[ $keep == replace ]]; then
			echo "label-id: $(jq -r .partitiontable.id <<<"$CLONE_PT")"
		fi
		echo "unit: sectors"
		echo "sector-size: $CLONE_SS"
		for ((i = 0; i < n; i++)); do
			p=${CLONE_PARTS[i]}
			local num line
			num=$(part_num "$(jq -r .node <<<"$p")")
			line="$(part_path "$tdev" "$num") : start=${CLONE_NEW_START[i]}, size=${CLONE_NEW_SIZE[i]}, type=$(jq -r .type <<<"$p")"
			if [[ $CLONE_LABEL == gpt ]]; then
				[[ $keep == replace ]] && line+=", uuid=$(jq -r .uuid <<<"$p")"
				[[ $(jq -r '.name // ""' <<<"$p") != "" ]] && line+=", name=\"$(jq -r .name <<<"$p")\""
				[[ $(jq -r '.attrs // ""' <<<"$p") != "" ]] && line+=", attrs=\"$(jq -r .attrs <<<"$p")\""
			else
				[[ $(jq -r '.bootable // false' <<<"$p") == true ]] && line+=", bootable"
			fi
			echo "$line"
		done
	} >"$script"
	log "sfdisk-Skript:"$'\n'"$(cat "$script")"
	run sudo wipefs -a "$tdev"
	if ! run sudo sfdisk --wipe always --wipe-partitions always "$tdev" <"$script"; then
		rm -f "$script"
		die "Partitionstabelle konnte nicht geschrieben werden. Details im Protokoll."
		return 1
	fi
	rm -f "$script"
	run sudo partprobe "$tdev"
	sudo udevadm settle
	sleep 1
}

# Kopiert alle Partitionen. Läuft als erzeugtes Skript in tmux, damit man zusehen kann.
clone_copy() {
	local sdev=$1 tdev=$2 n=${#CLONE_PARTS[@]} i job status
	job="$FRS_RUN/clone-job.sh"
	status="$FRS_RUN/clone-status"
	rm -f "$status"
	{
		echo '#!/usr/bin/env bash'
		echo 'set -u'
		echo "exec > >(tee -a '$FRS_LOG') 2>&1"
		echo 'step() { printf "\n\033[1;33m==> %s\033[0m\n" "$*"; }'
		echo 'fail() { echo "FEHLER: $*"; echo FAIL > '"'$status'"'; read -r -p "Enter … " _; exit 1; }'
		for ((i = 0; i < n; i++)); do
			local num src dst fs
			num=$(part_num "$(jq -r .node <<<"${CLONE_PARTS[i]}")")
			src=$(jq -r .node <<<"${CLONE_PARTS[i]}")
			dst=$(part_path "$tdev" "$num")
			fs=${CLONE_FS[i]}
			echo "step 'Partition $num ($fs): $src -> $dst'"
			if ((i == CLONE_ELASTIC && CLONE_SHRINK)); then
				clone_cmd_shrink "$src" "$dst" "$fs" "$((CLONE_NEW_SIZE[i] * CLONE_SS))"
			else
				clone_cmd_copy "$src" "$dst" "$fs"
				((i == CLONE_ELASTIC)) && clone_cmd_grow "$dst" "$fs"
			fi
		done
		echo 'sync'
		echo "echo OK > '$status'"
		echo 'step "Klon abgeschlossen."'
		echo 'read -r -p "Enter drücken … " _'
	} >"$job"
	chmod +x "$job"
	log "Klon-Job: $job"
	tmux_run "frs-klon" sudo "$job"
	while tmux has-session -t frs-klon 2>/dev/null; do
		ui_msg "Klon läuft" "Der Klon läuft noch im Hintergrund.\n\nOK zeigt die Ansicht wieder an." && tmux attach -t frs-klon
	done
	[[ $(cat "$status" 2>/dev/null) == OK ]] || { die "Der Klon ist fehlgeschlagen. Details im Protokoll: $FRS_LOG"; return 1; }
}

# Gibt Shell-Befehle aus, die eine Partition 1:1 (nur belegte Blöcke) kopieren.
clone_cmd_copy() {
	local src=$1 dst=$2 fs=$3 tool=""
	case $fs in
	ntfs) tool=partclone.ntfs ;;
	ext2 | ext3 | ext4) tool=partclone.extfs ;;
	vfat) tool=partclone.vfat ;;
	exfat) tool=partclone.exfat ;;
	xfs) tool=partclone.xfs ;;
	btrfs) tool=partclone.btrfs ;;
	hfsplus) tool=partclone.hfsp ;;
	f2fs) tool=partclone.f2fs ;;
	swap)
		local uuid label
		uuid=$(sudo blkid -o value -s UUID "$src")
		label=$(sudo blkid -o value -s LABEL "$src")
		echo "mkswap ${uuid:+-U $uuid} ${label:+-L '$label'} '$dst' || fail 'mkswap $dst'"
		return
		;;
	esac
	if [[ -n $tool ]]; then
		echo "$tool -b -s '$src' -o '$dst' || { echo 'partclone fehlgeschlagen, versuche dd …'; dd if='$src' of='$dst' bs=4M iflag=fullblock conv=fsync status=progress || fail 'Kopie $src'; }"
	else
		# Unbekannt, leer, MSR, BitLocker: blockweise
		echo "dd if='$src' of='$dst' bs=4M iflag=fullblock conv=fsync status=progress || fail 'Kopie $src'"
	fi
}

clone_cmd_grow() {
	local dst=$1 fs=$2
	echo "step 'Dateisystem auf $dst an neue Größe anpassen'"
	case $fs in
	ntfs) echo "yes y | ntfsresize --force --no-progress-bar '$dst' || echo 'Hinweis: ntfsresize meldet Fehler, Windows prüft beim ersten Start.'" ;;
	ext2 | ext3 | ext4) echo "e2fsck -fy '$dst'; resize2fs '$dst' || fail 'resize2fs $dst'" ;;
	xfs) echo "m=\$(mktemp -d); mount '$dst' \$m && xfs_growfs \$m; umount \$m" ;;
	btrfs) echo "m=\$(mktemp -d); mount '$dst' \$m && btrfs filesystem resize max \$m; umount \$m" ;;
	esac
}

# Verkleinern ohne die Quelle anzufassen: Schreib-Overlay im RAM über die Quellpartition,
# dort Dateisystem verkleinern, dann von dort auf das Ziel kopieren.
clone_cmd_shrink() {
	local src=$1 dst=$2 fs=$3 bytes=$4
	cat <<-EOF
		modprobe nbd max_part=0
		install -d $FRS_RUN/cow
		mountpoint -q $FRS_RUN/cow || mount -t tmpfs -o size=60% tmpfs $FRS_RUN/cow
		TMPDIR=$FRS_RUN/cow qemu-nbd --snapshot --format=raw --fork -c /dev/nbd0 '$src' || fail 'qemu-nbd'
		sleep 1
	EOF
	case $fs in
	ntfs)
		echo "yes y | ntfsresize --force --no-progress-bar -s $((bytes - 1048576)) /dev/nbd0 || { qemu-nbd -d /dev/nbd0; fail 'ntfsresize (Overlay)'; }"
		echo "partclone.ntfs -b -s /dev/nbd0 -o '$dst' || { qemu-nbd -d /dev/nbd0; fail 'partclone.ntfs'; }"
		;;
	ext2 | ext3 | ext4)
		echo "e2fsck -fy /dev/nbd0; resize2fs /dev/nbd0 $(((bytes - 1048576) / 1024))K || { qemu-nbd -d /dev/nbd0; fail 'resize2fs (Overlay)'; }"
		echo "partclone.extfs -b -s /dev/nbd0 -o '$dst' || { qemu-nbd -d /dev/nbd0; fail 'partclone.extfs'; }"
		;;
	esac
	echo "qemu-nbd -d /dev/nbd0"
	clone_cmd_grow "$dst" "$fs"
}

clone_boot_hint() {
	if [[ $1 == replace ]]; then
		printf '%s\n' "Die neue Disk hat dieselben Kennungen wie die alte. Alte Disk ausbauen, neue einbauen, starten." \
			"Windows prüft beim ersten Start evtl. das Dateisystem (normal)."
	else
		printf '%s\n' "Die neue Disk hat neue Kennungen. Booten von ihr kann eine Reparatur des Bootloaders erfordern" \
			'(Windows: bcdboot C:\Windows aus der WinRE; Linux: Werkzeuge > Shell > grub-install).'
	fi
}
