# shellcheck shell=bash
# Disk anpassen: Partition vergrößern/verkleinern, GPT reparieren, MBR->GPT, sicher löschen.

resize_wizard() {
	local choice
	choice=$(ui_menu "Disk anpassen" "Was soll geändert werden?" -- \
		grow "Partition bis zum Ende vergrößern (z. B. nach Klon auf größere Disk)" \
		shrink "Partition verkleinern" \
		gptfix "GPT prüfen und reparieren" \
		mbr2gpt "MBR in GPT umwandeln (nur Linux-Systeme, Windows: mbr2gpt.exe)" \
		erase "Disk sicher löschen" \
		gdisk "Experte: gdisk / parted interaktiv") || return 0
	case $choice in
	grow) resize_part grow ;;
	shrink) resize_part shrink ;;
	gptfix) resize_gptfix ;;
	mbr2gpt) resize_mbr2gpt ;;
	erase) resize_erase ;;
	gdisk) resize_expert ;;
	esac
}

resize_pick_part() {
	local dev=$1 items=() p
	while IFS= read -r p; do
		items+=("$(jq -r .path <<<"$p")" "$(printf '%-8s %-10s %s' "$(jq -r '.fstype // "–"' <<<"$p")" "$(human "$(jq -r .size <<<"$p")")" "$(jq -r '.label // .partlabel // ""' <<<"$p")")")
	done < <(disk_parts "$dev")
	((${#items[@]})) || { ui_msg "Partition" "Keine Partitionen gefunden."; return 1; }
	ui_menu "Partition" "Welche Partition?" -- "${items[@]}"
}

resize_part() {
	local mode=$1 tid dev part num fs st
	tid=$(disk_pick "Disk anpassen" "Welche Disk?") || return 0
	safety_check_target "$tid" || return 0
	dev=$(disk_resolve "$tid")
	st=$(disk_smart "$dev" | cut -d'|' -f1)
	if [[ $st == DEFEKT ]]; then
		ui_yesno "Achtung" "SMART meldet diese Disk als DEFEKT. Größenänderungen verschieben Daten und können auf einer kranken Disk zu Datenverlust führen.\n\nErst eine Datenrettung machen. Trotzdem weiter?" --defaultno || return 0
	fi
	part=$(resize_pick_part "$dev") || return 0
	num=$(part_num "$part")
	fs=$(sudo blkid -o value -s TYPE "$part")
	safety_release "$dev" || { die "Partitionen auf $dev sind eingehängt/in Benutzung."; return 0; }

	if [[ $mode == grow ]]; then
		safety_confirm_target "$tid" "$part wird bis zum nächsten belegten Bereich vergrößert." || return 0
		clear
		echo "Vergrößere $part …"
		[[ $(sudo sfdisk --dump "$dev" | grep -c '^label: gpt') == 1 ]] && runv sudo sgdisk -e "$dev"
		echo ", +" | runv sudo sfdisk --no-reread -N "$num" "$dev" || { pause; return 0; }
		runv sudo partprobe "$dev"
		sudo udevadm settle
		case $fs in
		ntfs) yes y | runv sudo ntfsresize --force "$part" ;;
		ext2 | ext3 | ext4) runv sudo e2fsck -fy "$part"; runv sudo resize2fs "$part" ;;
		xfs | btrfs)
			local m
			m=$(mktemp -d)
			runv sudo mount "$part" "$m" && {
				if [[ $fs == xfs ]]; then runv sudo xfs_growfs "$m"; else runv sudo btrfs filesystem resize max "$m"; fi
				runv sudo umount "$m"
			}
			;;
		*) echo "Dateisystem '$fs' wird nicht automatisch vergrößert, nur die Partition." ;;
		esac
		pause
		return 0
	fi

	# Verkleinern: erst Dateisystem, dann Partition
	local cur min want
	cur=$(sudo blockdev --getsize64 "$part")
	case $fs in
	ntfs | ext2 | ext3 | ext4) clone_min_size "$part" "$fs" || return 0 ;;
	*) die "$fs kann nicht verkleinert werden."; return 0 ;;
	esac
	min=$CLONE_MIN
	want=$(ui_input "Verkleinern" "$part ($fs)\nAktuell: $(human "$cur")\nMinimum: $(human "$min") (+ Reserve empfohlen)\n\nNeue Größe in GiB:" "$(((min / 1073741824) + 5))") || return 0
	[[ $want =~ ^[0-9]+$ ]] || { ui_msg "Eingabe" "Bitte eine ganze Zahl in GiB eingeben."; return 0; }
	local bytes=$((want * 1073741824))
	((bytes > min + min / 20)) || { ui_msg "Zu klein" "$want GiB ist kleiner als das Minimum + 5 % Reserve."; return 0; }
	((bytes < cur)) || { ui_msg "Zu groß" "$want GiB ist nicht kleiner als die aktuelle Größe."; return 0; }
	safety_confirm_target "$tid" "$part wird auf $want GiB verkleinert." || return 0
	clear
	echo "Verkleinere Dateisystem auf $part …"
	case $fs in
	ntfs) yes y | runv sudo ntfsresize --force -s "$((bytes - 1048576))" "$part" || { pause; return 0; } ;;
	*) runv sudo e2fsck -fy "$part"; runv sudo resize2fs "$part" "$(((bytes - 1048576) / 1024))K" || { pause; return 0; } ;;
	esac
	echo "Verkleinere Partition …"
	echo ", ${want}GiB" | runv sudo sfdisk --no-reread -N "$num" "$dev"
	runv sudo partprobe "$dev"
	pause
}

resize_gptfix() {
	local tid dev
	tid=$(disk_pick "GPT reparieren" "Welche Disk?") || return 0
	dev=$(disk_resolve "$tid")
	clear
	echo "Prüfung von $dev (nur lesend):"
	runv sudo sgdisk -v "$dev"
	pause
	local a
	a=$(ui_menu "GPT reparieren" "Was soll passieren?" -- \
		end "Backup-GPT ans Disk-Ende verschieben (nach Klon/Vergrößerung)" \
		primary "Primäre GPT aus der Backup-GPT wiederherstellen (gdisk)" \
		none "Nichts ändern") || return 0
	case $a in
	end)
		safety_check_target "$tid" || return 0
		safety_confirm_target "$tid" "Backup-GPT wird ans Ende verschoben." || return 0
		runv sudo sgdisk -e "$dev"
		pause
		;;
	primary)
		safety_check_target "$tid" || return 0
		ui_msg "gdisk" "gdisk startet jetzt interaktiv.\n\nTastenfolge: r (Recovery) > c (load backup partition table) > v (prüfen) > w (schreiben).\nMit q beendest du ohne zu speichern."
		sudo gdisk "$dev"
		;;
	esac
}

resize_mbr2gpt() {
	local tid dev
	tid=$(disk_pick "MBR -> GPT" "Welche Disk?") || return 0
	safety_check_target "$tid" || return 0
	dev=$(disk_resolve "$tid")
	ui_yesno "MBR -> GPT" "Achtung:\n - Windows startet danach nur noch per UEFI und braucht eine EFI-Partition. Für Windows besser mbr2gpt.exe in Windows/WinRE verwenden.\n - Für Linux ggf. eine BIOS-Boot-Partition (1 MiB) bzw. EFI-Partition nötig.\n\nFortfahren?" --defaultno || return 0
	safety_confirm_target "$tid" "Partitionstabelle wird von MBR in GPT umgewandelt." || return 0
	safety_release "$dev" || return 0
	clear
	runv sudo sgdisk -g "$dev"
	runv sudo sgdisk -v "$dev"
	pause
}

resize_erase() {
	local tid dev j tran rota
	tid=$(disk_pick "Sicher löschen" "Welche Disk soll unwiderruflich gelöscht werden?") || return 0
	safety_check_target "$tid" || return 0
	j=$(disk_info "$tid")
	dev=$(jq -r .path <<<"$j")
	tran=$(jq -r '.tran // ""' <<<"$j")
	rota=$(jq -r '.rota' <<<"$j")
	local items=()
	[[ $tran == nvme ]] && items+=(nvme "NVMe Format mit Secure Erase (Sekunden)")
	[[ $rota == false || $rota == 0 ]] && items+=(discard "TRIM/Discard der ganzen SSD (Sekunden)")
	[[ $tran == sata || $tran == ata ]] && items+=(ata "ATA Secure Erase (Firmware, Minuten bis Stunden)")
	items+=(zero "Mit Nullen überschreiben (langsam, funktioniert immer)")
	local m
	m=$(ui_menu "Sicher löschen" "$(disk_label "$j")" -- "${items[@]}") || return 0
	safety_confirm_target "$tid" "ALLE DATEN auf dieser Disk werden unwiderruflich gelöscht." || return 0
	ui_yesno "Letzte Warnung" "Wirklich $(disk_label "$j") löschen?\n\nDas kann nicht rückgängig gemacht werden." --defaultno || return 0
	safety_release "$dev" || return 0
	clear
	case $m in
	nvme) runv sudo nvme format "$dev" --ses=1 --force ;;
	discard) runv sudo blkdiscard -f "$dev" ;;
	ata)
		if sudo hdparm -I "$dev" | grep -q 'not.*frozen'; then
			runv sudo hdparm --user-master u --security-set-pass frs "$dev" &&
				runv sudo hdparm --user-master u --security-erase frs "$dev"
		else
			echo "Die Disk ist 'frozen'. Rechner in den Standby schicken (Werkzeuge > Shell: systemctl suspend) und danach erneut versuchen,"
			echo "oder Disk im laufenden Betrieb kurz ab- und wieder anstecken."
		fi
		;;
	zero) runv sudo dd if=/dev/zero of="$dev" bs=4M oflag=direct status=progress ;;
	esac
	pause
}

resize_expert() {
	local tid dev t
	tid=$(disk_pick "Experte" "Welche Disk?") || return 0
	dev=$(disk_resolve "$tid")
	t=$(ui_menu "Experte" "Werkzeug für $dev:" -- gdisk "gdisk (GPT)" fdisk "fdisk" parted "parted" cfdisk "cfdisk (Menü)") || return 0
	ui_msg "Hinweis" "Änderungen in diesen Werkzeugen sind sofort wirksam. Der Schreibschutz des Assistenten gilt hier nur für als Quelle markierte Disks."
	sudo "$t" "$dev"
}
