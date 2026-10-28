# shellcheck shell=bash
# Datenrettung: defekte Disk -> Image auf Ziel-Disk -> Dateien/Disk/VHDX daraus.

recover_wizard() {
	ui_msg "Datenrettung" "So läuft die Rettung ab:\n\n 1. Defekte Quell-Disk wählen. Sie wird sofort schreibgeschützt.\n 2. Ziel-Disk wählen. Darauf landet ein vollständiges Image (Pflicht).\n 3. ddrescue liest in drei Phasen: erst alles gut Lesbare, dann rückwärts, zuletzt die Fehlerstellen.\n    Unterbrechungen sind kein Problem: Der Stand wird laufend gespeichert.\n 4. Danach arbeitest du nur noch mit dem Image, nie mehr mit der kranken Disk:\n    Dateien kopieren, auf neue Disk schreiben, Dateien suchen oder VHDX erzeugen.\n\nTipp: Je weniger die defekte Disk läuft, desto besser. Nichts anderes an ihr ausprobieren."

	local sid tid sj tj sdev size
	sid=$(disk_pick "1/2 Quelle" "Welche Disk ist defekt bzw. soll gerettet werden?") || return 0
	sj=$(disk_info "$sid")
	sdev=$(jq -r .path <<<"$sj")
	size=$(jq -r .size <<<"$sj")
	safety_set_ro "$sdev"

	tid=$(disk_pick "2/2 Ziel (Pflicht)" "Auf welche Disk soll das Image?\nSie braucht mindestens $(human "$size") freien Platz.\n\nQuelle: $(disk_label "$sj")" "$sid") || return 0
	safety_check_target "$tid" "$sid" || return 0
	tj=$(disk_info "$tid")
	if (($(jq -r .size <<<"$tj") < size)); then
		ui_yesno "Ziel kleiner als Quelle" "Die Ziel-Disk ($(human "$(jq -r .size <<<"$tj")")) ist kleiner als die Quelle ($(human "$size")).\n\nDas geht nur, wenn große Teile der Quelle leer sind und das Ziel ext4 ist (sparse Image). Fortfahren?" --defaultno || return 0
	fi
	target_prepare "$tid" "$size" || return 0

	local model case
	model=$(jq -r '.model // "Disk"' <<<"$sj" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')
	case="$FRS_TARGET_MNT/FRS/$(date +%Y%m%d-%H%M)_${model}_${sid//[^A-Za-z0-9]/_}"
	mkdir -p "$case" || { die "Kann $case nicht anlegen."; return 0; }
	cat >"$case/case.env" <<-EOF
		SRC_ID="$sid"
		SRC_SIZE="$size"
		SRC_LABEL="$(disk_label "$sj")"
		TARGET_ID="$tid"
		STATE="new"
	EOF
	log "Neuer Rettungsfall: $case"
	recover_run "$case"
}

recover_run() {
	local case=$1
	tmux_run "frs-rettung" sudo frs-rescue-run "$case"
	# Läuft die Sitzung noch (Ansicht verlassen), zurück ins Hauptmenü.
	if tmux has-session -t frs-rettung 2>/dev/null; then
		ui_msg "Rettung läuft weiter" "Die Rettung läuft im Hintergrund weiter.\n\nZurück zur Ansicht: Hauptmenü > Laufende Rettung anzeigen\noder auf tty2 (Alt+F2): tmux attach -t frs-rettung"
		return 0
	fi
	cp -f "$FRS_LOG" "$case/" 2>/dev/null || true
	# shellcheck disable=SC1091
	local STATE=""
	. "$case/case.env"
	if [[ $STATE == done ]]; then
		recover_after "$case"
	else
		ui_msg "Rettung unterbrochen" "Die Rettung wurde unterbrochen (Status: $STATE).\n\nFortsetzen: Hauptmenü > Unterbrochene Rettung fortsetzen.\nDer bisherige Stand bleibt erhalten."
	fi
}

recover_resume() {
	if tmux has-session -t frs-rettung 2>/dev/null; then
		tmux attach -t frs-rettung
		return 0
	fi
	local tid
	tid=$(disk_pick "Fortsetzen" "Auf welcher Ziel-Disk liegt die unterbrochene Rettung?") || return 0
	target_find_cases "$tid" || { ui_msg "Fortsetzen" "Auf dieser Disk wurde kein Rettungsfall (Ordner FRS/) gefunden."; return 0; }
	local items=() c st
	for c in "$FRS_TARGET_MNT"/FRS/*/; do
		[[ -f $c/case.env ]] || continue
		st=$(grep '^STATE=' "$c/case.env" | cut -d'"' -f2)
		items+=("$(basename "$c")" "[$st]")
	done
	local pick
	pick=$(ui_menu "Fortsetzen" "Welcher Rettungsfall?" -- "${items[@]}") || return 0
	c="$FRS_TARGET_MNT/FRS/$pick"
	st=$(grep '^STATE=' "$c/case.env" | cut -d'"' -f2)
	if [[ $st == done ]]; then
		recover_after "$c"
	else
		local sid sdev
		sid=$(grep '^SRC_ID=' "$c/case.env" | cut -d'"' -f2)
		sdev=$(disk_resolve "$sid")
		[[ -n $sdev ]] && safety_set_ro "$sdev"
		recover_run "$c"
	fi
}

# ---------------------------------------------------------------------------
# Arbeiten mit dem fertigen Image
# ---------------------------------------------------------------------------
recover_after() {
	local case=$1 img="$1/image.img" choice
	while true; do
		choice=$(ui_menu "Image weiterverwenden" "Rettung abgeschlossen: $(basename "$case")\n\n$(ddrescuelog -t "$case/image.map" 2>/dev/null | grep -E 'rescued|bad' | head -n 3)\n\nWas soll mit dem Image passieren?" -- \
			copy "Dateien aus dem Image kopieren" \
			disk "Image auf eine neue Disk schreiben (Größe wird angepasst)" \
			repair "Dateisystem auf einer Kopie des Images reparieren" \
			carve "Gelöschte/verlorene Dateien suchen (PhotoRec)" \
			vhdx "In VHDX umwandeln (Hyper-V, Windows einbinden)" \
			report "Bericht anzeigen" \
			claude "Claude um Rat fragen" \
			done "Fertig") || return 0
		case $choice in
		copy) image_copy_files "$case" "$img" ;;
		disk) image_to_disk "$case" "$img" ;;
		repair) image_repair "$case" "$img" ;;
		carve) image_carve "$case" "$img" ;;
		vhdx) tmux_run "frs-vhdx" bash -c "qemu-img convert -p -O vhdx -o subformat=dynamic '$img' '$case/image.vhdx'; echo; read -r -p 'Fertig. Enter … ' _" ;;
		report) ui_textfile "Bericht" "$case/report.txt" ;;
		claude) claude_start "$case" ;;
		done) return 0 ;;
		esac
	done
}

# Image als Loop-Device einbinden (nur lesend, mit Partitionen). Gibt /dev/loopN aus.
image_attach() {
	local img=$1 mode=${2:-ro} loop
	loop=$(sudo losetup -j "$img" | cut -d: -f1 | head -n1)
	if [[ -z $loop ]]; then
		if [[ $mode == ro ]]; then
			loop=$(sudo losetup --find --show -P -r "$img")
		else
			loop=$(sudo losetup --find --show -P "$img")
		fi
	fi
	sleep 1
	echo "$loop"
}

# Partition nur lesend einhängen; behandelt NTFS, ext*, XFS, Btrfs und BitLocker.
part_mount_ro() {
	local part=$1 mp=$2 fs
	fs=$(sudo blkid -o value -s TYPE "$part")
	sudo install -d "$mp"
	case $fs in
	BitLocker)
		local key
		key=$(ui_input "BitLocker" "$(basename "$part") ist mit BitLocker verschlüsselt.\n\nWiederherstellungsschlüssel (48 Ziffern, mit Bindestrichen):") || return 1
		sudo install -d "$FRS_RUN/dislocker-$(basename "$part")"
		run sudo dislocker -r -V "$part" -p"$key" -- "$FRS_RUN/dislocker-$(basename "$part")" ||
			{ die "Entschlüsselung fehlgeschlagen. Schlüssel prüfen."; return 1; }
		run sudo mount -o ro,loop "$FRS_RUN/dislocker-$(basename "$part")/dislocker-file" "$mp" ||
			run sudo ntfs-3g -o ro "$FRS_RUN/dislocker-$(basename "$part")/dislocker-file" "$mp"
		;;
	ntfs) run sudo mount -t ntfs3 -o ro "$part" "$mp" || run sudo ntfs-3g -o ro,recover "$part" "$mp" ;;
	ext2 | ext3 | ext4) run sudo mount -o ro,noload "$part" "$mp" ;;
	xfs) run sudo mount -o ro,norecovery "$part" "$mp" ;;
	btrfs) run sudo mount -o ro,rescue=usebackuproot "$part" "$mp" || run sudo mount -o ro,rescue=all "$part" "$mp" ;;
	"") return 1 ;;
	*) run sudo mount -o ro "$part" "$mp" ;;
	esac
}

image_pick_part() {
	local loop=$1 items=() p
	while IFS= read -r p; do
		items+=("$(jq -r .path <<<"$p")" "$(printf '%-10s %-10s %s' "$(jq -r '.fstype // "?"' <<<"$p")" "$(human "$(jq -r .size <<<"$p")")" "$(jq -r '.label // ""' <<<"$p")")")
	done < <(disk_parts "$loop")
	((${#items[@]})) || items=("$loop" "ganzes Image (keine Partitionstabelle)")
	ui_menu "Partition wählen" "Welche Partition aus dem Image?" -- "${items[@]}"
}

image_copy_files() {
	local case=$1 img=$2 loop part mp dst mode
	loop=$(image_attach "$img" ro)
	part=$(image_pick_part "$loop") || return 0
	mp="$FRS_IMAGE_MNT/$(basename "$part")"
	part_mount_ro "$part" "$mp" || { ui_msg "Einhängen" "$(basename "$part") ließ sich nicht einhängen.\nTipp: 'Dateisystem auf einer Kopie reparieren' oder PhotoRec."; return 0; }
	mode=$(ui_menu "Dateien kopieren" "$part ist nur lesend unter $mp eingehängt." -- \
		all "Alles kopieren (rsync) nach $case/dateien/" \
		mc "Selbst auswählen (Midnight Commander)" \
		shell "Shell im Verzeichnis öffnen") || return 0
	dst="$case/dateien/$(basename "$part")"
	mkdir -p "$dst"
	case $mode in
	all)
		local ropts="-aHAX"
		[[ $(target_fs) == exfat || $(target_fs) == ntfs* || $(target_fs) == fuseblk ]] && ropts="-rt --modify-window=2"
		tmux_run "frs-kopie" bash -c "sudo rsync $ropts --info=progress2 --ignore-errors '$mp/' '$dst/' 2>&1 | tee -a '$case/kopie.log'; echo; read -r -p 'Fertig. Enter … ' _"
		;;
	mc) sudo mc "$mp" "$dst" ;;
	shell) (cd "$mp" && PS1="[frs image] \w \$ " bash --norc -i) ;;
	esac
}

image_to_disk() {
	local case=$1 img=$2 loop
	loop=$(image_attach "$img" ro)
	ui_msg "Image auf Disk" "Das Image wird wie eine Quell-Disk behandelt und mit dem Klon-Assistenten auf die neue Disk übertragen.\nIst die neue Disk größer oder kleiner, wird die Hauptpartition angepasst."
	clone_from_device "$loop" "Image $(basename "$case")"
}

image_repair() {
	local case=$1 img=$2 copy="$2.repair" need loop part fs
	need=$(du -B1 "$img" | cut -f1)
	if [[ ! -f $copy ]]; then
		(($(target_free) > need)) || { die "Für die Kopie fehlen $(human "$need") auf dem Ziel."; return 0; }
		ui_yesno "Reparatur" "Das Original-Image bleibt unverändert. Repariert wird eine Kopie:\n$copy\n\nDas belegt etwa $(human "$need"). Kopie jetzt anlegen?" || return 0
		tmux_run "frs-kopie" bash -c "cp --sparse=always '$img' '$copy' && echo Kopie fertig; read -r -p 'Enter … ' _"
	fi
	loop=$(image_attach "$copy" rw)
	part=$(image_pick_part "$loop") || return 0
	fs=$(sudo blkid -o value -s TYPE "$part")
	clear
	echo "Reparatur von $part ($fs) in der Kopie …"
	case $fs in
	ntfs) runv sudo ntfsfix -d "$part" ;;
	ext2 | ext3 | ext4) runv sudo e2fsck -fy "$part" ;;
	xfs) runv sudo xfs_repair "$part" || runv sudo xfs_repair -L "$part" ;;
	vfat) runv sudo fsck.vfat -a "$part" ;;
	exfat) runv sudo fsck.exfat -y "$part" ;;
	btrfs) runv sudo btrfs check --repair --force "$part" ;;
	*) echo "Für '$fs' gibt es keine automatische Reparatur." ;;
	esac
	pause
	ui_msg "Reparatur" "Fertig. Mit 'Dateien aus dem Image kopieren' kannst du jetzt aus der reparierten Kopie kopieren:\nwähle dort die Partition $(basename "$part")."
	part_mount_ro "$part" "$FRS_IMAGE_MNT/repair-$(basename "$part")" &&
		ui_msg "Eingehängt" "Reparierte Partition liegt nur lesend unter $FRS_IMAGE_MNT/repair-$(basename "$part")"
}

image_carve() {
	local case=$1 img=$2
	mkdir -p "$case/photorec"
	ui_msg "PhotoRec" "PhotoRec sucht Dateien anhand ihrer Inhalte, auch ohne funktionierendes Dateisystem.\n\nIm nächsten Schritt: Partition wählen > Dateisystemtyp > 'Whole' > Ziel ist schon gesetzt (mit C bestätigen).\nErgebnisse landen in $case/photorec/"
	sudo photorec /log /d "$case/photorec/recup" "$img"
	sudo chown -R "$(id -u):$(id -g)" "$case/photorec" 2>/dev/null || true
}
