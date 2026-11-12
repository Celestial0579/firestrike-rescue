# shellcheck shell=bash
# Persistenter Speicher auf dem Boot-Stick (Partition FRS-DATA, LUKS2 + ext4).
# Die ISO wird dafür nicht verändert: Die Partition wird hinter den ISO-Bereich angehängt.
#
# Wer den Speicher stellt, bestimmt die Sitzung: Aus ihm kommen Programme (~/.local/bin), die
# Regeln und Einstellungen für Claude (~/.claude), SSH-Schlüssel und WLAN-Profile. Deshalb gilt:
#   - Der eigene Speicher ist die Partition FRS-DATA auf dem Stick, von dem das System läuft,
#     und nur sie. Eine Partition gleichen Namens auf einer anderen Disk wird nie verwendet.
#   - Eingebunden wird er erst, wenn der Techniker ihn in dieser Sitzung freigibt: mit der
#     Passphrase (verschlüsselt) oder mit einem ausdrücklichen Ja (unverschlüsselt).
#   - Aus dem Speicher wird nichts als Shell-Code gelesen. frs.conf ist eine Liste von
#     Einstellungen (persist_config_load).

PERSIST_LABEL="FRS-DATA"
PERSIST_MAPPER="frs-data"
PERSIST_MAPPER_DEV="/dev/mapper/$PERSIST_MAPPER"
PERSIST_CONFIG="/etc/frs/frs.conf"
# Verzeichnisse im Home, die auf die Persistenz zeigen
PERSIST_HOME_DIRS=(.claude .config/Claude .local/share/keyrings .local/share/claude .local/bin .ssh .config/rclone)

# persist_candidates DISK   Partitionen von DISK, die den Namen des Speichers tragen.
persist_candidates() {
	lsblk -J -o PATH,PARTLABEL,LABEL "$1" 2>/dev/null |
		jq -r --arg l "$PERSIST_LABEL" '.blockdevices[0].children[]? | select(.partlabel == $l or .label == $l) | .path'
}

# Die Partition des eigenen Speichers: FRS-DATA auf dem Boot-Stick. Ist der Stick nicht sicher
# zu erkennen oder tragen dort mehrere Partitionen den Namen, gibt es keinen Speicher.
persist_find() {
	local bd parts
	bd=$(boot_disk 2>/dev/null) || return 1
	mapfile -t parts < <(persist_candidates "$bd")
	((${#parts[@]} == 1)) || return 1
	echo "${parts[0]}"
}

# Partitionen mit dem Namen des Speichers auf anderen Disks als dem Boot-Stick.
persist_foreign() {
	local bd
	bd=$(boot_disk 2>/dev/null || true)
	lsblk -J -o PATH,PKNAME,TYPE,PARTLABEL,LABEL 2>/dev/null |
		jq -r --arg l "$PERSIST_LABEL" --arg bd "$bd" '.blockdevices[] | .. | objects
			| select(.type? == "part") | select(.partlabel == $l or .label == $l)
			| select(("/dev/" + (.pkname // "")) != $bd) | .path'
}

# Sagt einmal je Sitzung, dass eine fremde Partition den Namen des Speichers trägt. Sie wird
# weder eingehängt noch sonst angefasst.
persist_foreign_notice() {
	local list
	list=$(persist_foreign | tr '\n' ' ')
	[[ -n ${list// /} ]] || return 0
	log "Partition mit dem Namen $PERSIST_LABEL auf einer anderen Disk wird nicht verwendet: $list"
	[[ -f $FRS_RUN/persist-foreign-told ]] && return 0
	touch "$FRS_RUN/persist-foreign-told"
	ui_msg "Persistenter Speicher" "Auf einer anderen Disk liegt eine Partition mit dem Namen $PERSIST_LABEL:\n\n   $list\n\nDer Speicher dieses Rettungssystems liegt nur auf dem Stick, von dem es gestartet wurde. Die Partition wird nicht verwendet und nicht eingehängt.\n\nStammt die Disk aus fremder Hand, ist Vorsicht angebracht. Ist es dein Speicher auf einem anderen Stick, starte von jenem Stick."
}

# Einstellungen, die frs.conf setzen darf, mit dem Muster ihres Wertes.
persist_config_pattern() {
	case $1 in
	FRS_TECHNIKER) echo '^[^[:cntrl:]"$`\]{0,100}$' ;;
	FRS_TARGET_FS) echo '^(ext4|exfat)$' ;;
	FRS_SSH_AUTOSTART) echo '^[01]$' ;;
	*) return 1 ;;
	esac
}

# persist_config_load DATEI   Liest frs.conf als Daten, nie als Shell-Code.
# Gültig sind Leerzeilen, Kommentare (#) und Zeilen der Form NAME=Wert oder NAME="Wert" für die
# Namen aus persist_config_pattern. Solche Zeilen setzen die gleichnamige Variable. Jede andere
# Zeile wird nicht übernommen, ihre Nummer steht danach in PERSIST_CONFIG_REJECTED.
persist_config_load() {
	local LC_ALL=C file=$1 line key value pattern n=0
	local quoted='^([A-Z_]+)="([^"]*)"$' bare='^([A-Z_]+)=([A-Za-z0-9._-]*)$'
	PERSIST_CONFIG_REJECTED=""
	[[ -f $file && ! -L $file && -r $file ]] || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		if ((n > 200)); then
			PERSIST_CONFIG_REJECTED+=" ab $n"
			break
		fi
		line=${line%$'\r'}
		line=${line#"${line%%[![:space:]]*}"}
		line=${line%"${line##*[![:space:]]}"}
		[[ -z $line || $line == \#* ]] && continue
		if [[ $line =~ $quoted || $line =~ $bare ]]; then
			key=${BASH_REMATCH[1]}
			value=${BASH_REMATCH[2]}
			if pattern=$(persist_config_pattern "$key") && [[ $value =~ $pattern ]]; then
				printf -v "$key" '%s' "$value"
				continue
			fi
		fi
		PERSIST_CONFIG_REJECTED+=" $n"
	done 2>/dev/null <"$file"
	return 0
}

persist_is_open() { mountpoint -q "$FRS_PERSIST"; }

# Persistenz entsperren und einhängen; danach Home-Verzeichnisse umlenken.
persist_open() {
	persist_is_open && return 0
	local dev
	dev=$(persist_find) || return 1
	[[ -z $dev ]] && return 1
	local fsdev=$dev
	if [[ $(sudo blkid -o value -s TYPE "$dev") == crypto_LUKS ]]; then
		if [[ ! -e $PERSIST_MAPPER_DEV ]]; then
			local pw tries=0
			while ((tries < 3)); do
				pw=$(ui_password "Persistenter Speicher" "Passphrase für den persistenten Speicher (Configs, Claude-Login):\n\nAbbrechen = ohne Persistenz weiter") || return 1
				printf '%s' "$pw" | sudo cryptsetup open --key-file - "$dev" "$PERSIST_MAPPER" 2>/dev/null && break
				tries=$((tries + 1))
				ui_msg "Falsche Passphrase" "Entsperren fehlgeschlagen ($tries/3)."
			done
			[[ -e $PERSIST_MAPPER_DEV ]] || return 1
		fi
		fsdev=$PERSIST_MAPPER_DEV
	else
		# Ohne Verschlüsselung gibt es keine Passphrase, die den Speicher als den eigenen ausweist.
		# Er wird deshalb nie ohne Rückfrage eingebunden. Beim Start fragt der Assistent nur einmal.
		[[ ${1:-} == startup && -f $FRS_RUN/persist-plain-declined ]] && return 1
		if ! ui_yesno "Speicher nicht verschlüsselt" "Der persistente Speicher auf dem Stick ($dev) ist nicht verschlüsselt.\n\nWer den Stick in der Hand hatte, kann seinen Inhalt verändert haben: Programme unter ~/.local/bin, Regeln und Einstellungen für Claude, SSH-Schlüssel, WLAN-Profile. Der Assistent bindet das alles ein.\n\nWar der Stick immer bei dir? Dann den Speicher verwenden?" --defaultno; then
			touch "$FRS_RUN/persist-plain-declined"
			log "Unverschlüsselter Speicher $dev nicht eingebunden (abgelehnt)"
			return 1
		fi
	fi
	sudo install -d "$FRS_PERSIST"
	# Im Speicher liegen Programme und Verknüpfungen (~/.local/bin). Gerätedateien und
	# Setuid-Bits braucht er nicht.
	run sudo mount -o noatime,nodev,nosuid "$fsdev" "$FRS_PERSIST" || { ui_msg "Persistenz" "Einhängen fehlgeschlagen, siehe Protokoll."; return 1; }
	persist_bind
	log "Persistenz eingehängt: $dev"
	log_init
}

persist_bind() {
	local d
	sudo install -d -o "$(id -u)" -g "$(id -g)" "$FRS_PERSIST/home" "$FRS_PERSIST/logs" "$FRS_PERSIST/config"
	for d in "${PERSIST_HOME_DIRS[@]}"; do
		install -d "$FRS_PERSIST/home/$d" "$HOME/$d"
		mountpoint -q "$HOME/$d" || run sudo mount --bind "$FRS_PERSIST/home/$d" "$HOME/$d"
	done
	chmod 700 "$HOME/.ssh" 2>/dev/null || true
	# Eigene Konfiguration: /persist/config wird zu /etc/frs
	sudo install -d /etc/frs
	mountpoint -q /etc/frs || run sudo mount --bind "$FRS_PERSIST/config" /etc/frs
	[[ -f $PERSIST_CONFIG ]] || cat >"$PERSIST_CONFIG" <<-'EOF'
		# Firestrike Rescue – eigene Einstellungen (liegt auf dem persistenten Speicher)
		# Eine Einstellung pro Zeile, NAME=Wert. Die Datei wird als Liste gelesen, nicht als Skript.
		# Firmen- bzw. Technikername für Berichte
		#FRS_TECHNIKER="Vorname Nachname"
		# Standard-Dateisystem beim Formatieren von Ziel-Disks: ext4 oder exfat
		#FRS_TARGET_FS=ext4
		# SSH beim Start automatisch einschalten (nur mit hinterlegtem Schlüssel in ~/.ssh/authorized_keys)
		#FRS_SSH_AUTOSTART=0
	EOF
	# WLAN-Profile übernehmen
	if compgen -G "/etc/frs/wifi/*.nmconnection" >/dev/null; then
		sudo install -m 600 /etc/frs/wifi/*.nmconnection /etc/NetworkManager/system-connections/
		run sudo nmcli connection reload
	fi
	# Eigene CLAUDE.md anlegen, falls es noch keine gibt
	[[ -f $HOME/.claude/CLAUDE.md ]] || cat >"$HOME/.claude/CLAUDE.md" <<-'EOF'
		# Meine Ergänzungen für Claude im Rettungssystem

		Diese Datei liegt auf dem persistenten Speicher des Sticks und wird zusätzlich zu
		/etc/claude-code/CLAUDE.md (Regeln des Rettungssystems) geladen.

		- Antworte auf Deutsch.
	EOF
	# frs.conf wird gelesen, nicht ausgeführt.
	if persist_config_load "$PERSIST_CONFIG" && [[ -n $PERSIST_CONFIG_REJECTED ]]; then
		log "frs.conf: Zeilen nicht übernommen:$PERSIST_CONFIG_REJECTED"
		ui_msg "frs.conf" "Diese Zeilen der frs.conf wurden nicht übernommen:$PERSIST_CONFIG_REJECTED\n\nDie Datei ist eine Liste von Einstellungen und wird nicht als Skript ausgeführt. Erlaubt sind, je eine pro Zeile:\n\n   FRS_TECHNIKER=\"Vorname Nachname\"\n   FRS_TARGET_FS=ext4 oder exfat\n   FRS_SSH_AUTOSTART=0 oder 1\n\nBearbeiten: Werkzeuge > Persistenter Speicher > frs.conf bearbeiten."
	fi
}

persist_close() {
	local d
	for ((i = ${#PERSIST_HOME_DIRS[@]} - 1; i >= 0; i--)); do
		d=${PERSIST_HOME_DIRS[i]}
		mountpoint -q "$HOME/$d" && run sudo umount "$HOME/$d"
	done
	mountpoint -q /etc/frs && run sudo umount /etc/frs
	persist_is_open && run sudo umount "$FRS_PERSIST"
	[[ -e /dev/mapper/$PERSIST_MAPPER ]] && run sudo cryptsetup close "$PERSIST_MAPPER"
	return 0
}

# Freier Platz hinter der letzten Partition (ISO-Bereich) auf dem Stick in Bytes.
# Die GPT der ISO endet am ISO-Ende, deshalb wird gegen die echte Gerätegröße gerechnet.
persist_free_bytes() {
	local bd=$1 total ss lastend
	total=$(sudo blockdev --getsize64 "$bd")
	ss=$(sudo blockdev --getss "$bd")
	lastend=$(sudo sfdisk -J "$bd" 2>/dev/null | jq '[.partitiontable.partitions[]? | .start + .size] | max // 0')
	echo $((total - lastend * ss - 1048576))
}

persist_create() {
	local bd
	bd=$(boot_disk) || { ui_msg "Persistenz" "Der Boot-Stick ist nicht sicher zu erkennen (Start aus dem RAM oder per Ventoy, oder mehrere Disks tragen das Label der ISO)."; return 1; }
	if [[ -n $(persist_candidates "$bd") ]]; then
		ui_msg "Persistenz" "Auf dem Stick gibt es schon eine Partition mit dem Namen $PERSIST_LABEL. Eine zweite wird nicht angelegt.\n\nEntsperren: Werkzeuge > Persistenter Speicher > Entsperren und einhängen."
		return 1
	fi
	sudo sgdisk -e "$bd" >/dev/null 2>&1 || true # Backup-GPT ans echte Ende
	local free
	free=$(persist_free_bytes "$bd")
	free=${free:-0}
	if ((free < 536870912)); then
		ui_msg "Persistenz" "Auf dem Stick ist zu wenig freier Platz ($(human "$free")).\nEin Stick ab 8 GB ist empfehlenswert."
		return 1
	fi
	local maxg=$((free / 1073741824)) size
	size=$(ui_menu "Persistenz anlegen" "Auf dem Stick sind $(human "$free") frei.\nWie groß soll der persistente Speicher werden?" -- \
		2 "2 GiB (Configs, CLAUDE.md, Claude-Login) – empfohlen" \
		4 "4 GiB (inkl. Claude-Updates)" \
		8 "8 GiB" \
		max "Ganzer freier Platz ($maxg GiB)") || return 1
	[[ $size == max ]] && size=0
	if [[ $size != 0 ]] && ((size * 1073741824 > free)); then
		ui_msg "Persistenz" "So viel Platz ist nicht frei."
		return 1
	fi
	local crypt=1 pw pw2
	if ui_yesno "Verschlüsselung" "Den Speicher mit einer Passphrase verschlüsseln (LUKS2)?\n\nEmpfohlen: Dort liegen Claude-Login, WLAN-Passwörter und SSH-Schlüssel. Ohne Verschlüsselung kann jeder, der den Stick findet, sie lesen."; then
		while true; do
			pw=$(ui_password "Passphrase" "Neue Passphrase (mind. 8 Zeichen):") || return 1
			pw2=$(ui_password "Passphrase" "Passphrase wiederholen:") || return 1
			[[ $pw == "$pw2" && ${#pw} -ge 8 ]] && break
			ui_msg "Passphrase" "Passphrasen stimmen nicht überein oder sind zu kurz."
		done
	else
		crypt=0
	fi
	ui_info "Persistenz" "Lege Partition an …"
	local sz="0"
	[[ $size != 0 ]] && sz="+${size}G"
	run sudo sgdisk -n "0:0:$sz" -t 0:8300 -c "0:$PERSIST_LABEL" "$bd" || { ui_msg "Persistenz" "Partition konnte nicht angelegt werden. Siehe Protokoll."; return 1; }
	local num part
	num=$(sudo sgdisk -p "$bd" | awk -v l="$PERSIST_LABEL" '$0 ~ l {print $1}' | tail -n1)
	run sudo partx -a -n "$num" "$bd" || run sudo partx -u "$bd" || true
	sudo udevadm settle
	part=$(part_path "$bd" "$num")
	[[ -b $part ]] || { ui_msg "Persistenz" "Die neue Partition $part ist noch nicht sichtbar. Bitte neu starten, der Speicher wird dann eingerichtet."; return 1; }
	local fsdev=$part
	if ((crypt)); then
		printf '%s' "$pw" | run sudo cryptsetup luksFormat --batch-mode --type luks2 --label "$PERSIST_LABEL" --key-file - "$part" || return 1
		printf '%s' "$pw" | sudo cryptsetup open --key-file - "$part" "$PERSIST_MAPPER" || return 1
		fsdev=/dev/mapper/$PERSIST_MAPPER
	fi
	run sudo mkfs.ext4 -q -L "$PERSIST_LABEL" "$fsdev" || return 1
	sudo install -d "$FRS_PERSIST"
	run sudo mount -o noatime,nodev,nosuid "$fsdev" "$FRS_PERSIST" || return 1
	persist_bind
	log_init
	ui_msg "Persistenz" "Persistenter Speicher ist eingerichtet ($(human "$(sudo blockdev --getsize64 "$part")")).\n\nDort liegen ab jetzt:\n - Claude-Login (CLI und Desktop) und ~/.claude/CLAUDE.md\n - /etc/frs/frs.conf und WLAN-Profile (/etc/frs/wifi/)\n - SSH-Schlüssel, rclone-Konfiguration\n - Protokolle (/persist/logs)"
}

# Beim Start: vorhandene Persistenz öffnen oder einmalig das Anlegen anbieten.
persist_startup() {
	persist_foreign_notice
	if [[ -n $(persist_find) ]]; then
		persist_open startup || true
		return 0
	fi
	[[ -f $FRS_RUN/persist-declined ]] && return 0
	local bd free
	bd=$(boot_disk 2>/dev/null) || return 0
	free=$(persist_free_bytes "$bd")
	if ((${free:-0} >= 536870912)); then
		if ui_yesno "Persistenter Speicher" "Auf dem Stick ist $(human "$free") ungenutzter Platz.\n\nSoll dort ein kleiner persistenter Speicher für Configs, CLAUDE.md und den Claude-Login angelegt werden?\nDie Rettungs-ISO selbst bleibt unverändert."; then
			persist_create || true
		else
			touch "$FRS_RUN/persist-declined"
		fi
	fi
}

persist_menu() {
	local c
	c=$(ui_menu "Persistenter Speicher" "Status: $(persist_is_open && echo "eingehängt unter $FRS_PERSIST ($(df -h --output=used,size "$FRS_PERSIST" | tail -n1 | xargs) belegt)" || echo "nicht eingehängt")" -- \
		open "Entsperren und einhängen" \
		create "Neu anlegen" \
		edit "frs.conf bearbeiten" \
		claudemd "Eigene CLAUDE.md bearbeiten" \
		wifi "Aktuelle WLAN-Verbindungen dauerhaft speichern" \
		close "Aushängen und sperren") || return 0
	case $c in
	open) persist_open || ui_msg "Persistenz" "Kein persistenter Speicher gefunden oder nicht entsperrt." ;;
	create) persist_create ;;
	edit) persist_is_open && sudo nano /etc/frs/frs.conf ;;
	claudemd) persist_is_open && nano "$HOME/.claude/CLAUDE.md" ;;
	wifi)
		persist_is_open || return 0
		sudo install -d -m 700 /etc/frs/wifi
		sudo sh -c 'cp /etc/NetworkManager/system-connections/*.nmconnection /etc/frs/wifi/ 2>/dev/null'
		ui_msg "WLAN" "Gespeichert: $(sudo ls /etc/frs/wifi | tr '\n' ' ')"
		;;
	close) persist_close ;;
	esac
}
