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
	# Modus hängende Disk (#54): kurze Timeouts, Abbruch statt Warten, danach hinter der
	# Hängerstelle weiter. Den Neustart der Disk macht der Techniker.
	local hang=()
	if ui_yesno "Hängende Disk?" "Hängt die Disk nach kurzer Zeit oder verschwindet sie (typisch für defekte SSD-Controller)?\n\nDann liest die Rettung mit kurzen Timeouts (5 s) und bricht bei einem Hänger ab, statt zu warten. Danach liest sie hinter der Hängerstelle weiter, die Lücke holt sie später nach. Ist die Disk weg, wartet sie bis zu 30 Minuten auf genau diese Disk (Seriennummer oder WWN und Größe).\n\nNeu starten musst du die Disk selbst: Strom trennen, etwa 10 Sekunden warten, wieder anschließen." --defaultno; then
		hang=("HANG_TIMEOUT=5")
	fi

	local model name case
	model=$(jq -r '.model // "Disk"' <<<"$sj" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')
	# "Fortsetzen" bietet später nur Ordner an, deren Name casefile_dirname_ok besteht.
	name="$(date +%Y%m%d-%H%M)_${model}_${sid//[^A-Za-z0-9]/_}"
	name=${name:0:200}
	casefile_dirname_ok "$name" || name="$(date +%Y%m%d-%H%M)_Disk"
	case="$LF_TARGET_MNT/LF/$name"
	mkdir -p "$case" || { die "Kann $case nicht anlegen."; return 0; }
	# Eine Kennung, die sich in der Falldatei nicht darstellen lässt, wird durch den Gerätepfad
	# ersetzt. Die Disk wird darüber genauso gefunden, solange sie nicht umgesteckt wird.
	casefile_value_ok SRC_ID "$sid" || sid=$sdev
	casefile_value_ok TARGET_ID "$tid" || tid=$(disk_resolve "$tid")
	if ! casefile_create "$case/case.env" "SRC_ID=$sid" "SRC_SIZE=$size" \
		"SRC_LABEL=$(casefile_clean_text "$(disk_label "$sj")")" "TARGET_ID=$tid" "STATE=new" "${hang[@]}"; then
		die "Der Rettungsfall konnte nicht angelegt werden: $CASEFILE_ERROR"
		return 0
	fi
	log "Neuer Rettungsfall: $case"
	recover_run "$case" "$sdev"
}

# recover_run FALLORDNER QUELL-GERÄT
# QUELL-GERÄT ist die Disk, die der Techniker in dieser Sitzung als Quelle gewählt hat.
# lf-rescue-run liest nur von ihr und prüft sie selbst noch einmal gegen die Falldatei.
recover_run() {
	local case=$1 sdev=$2 opts=()
	# Der Name aus der lf.conf steht im Bericht. Er ist ein eigenes Argument, nie Befehlstext.
	[[ -n ${LF_TECHNIKER:-} ]] && opts=("--techniker=$LF_TECHNIKER")
	tmux_run "lf-rettung" sudo lf-rescue-run "$case" "$sdev" "${opts[@]}"
	# Läuft die Sitzung noch (Ansicht verlassen), zurück ins Hauptmenü.
	if tmux has-session -t lf-rettung 2>/dev/null; then
		ui_msg "Rettung läuft weiter" "Die Rettung läuft im Hintergrund weiter.\n\nZurück zur Ansicht: Hauptmenü > Laufende Rettung anzeigen\noder auf tty2 (Alt+F2): tmux attach -t lf-rettung"
		return 0
	fi
	# Liegt im Fallordner schon etwas unter diesem Namen, wird es ersetzt und nie durchschrieben.
	# Wiederherstellungsschlüssel kommen nie mit (GHSA-cwvh-chmr-9xg8).
	log_copy_masked "$LF_LOG" "$case" 2>/dev/null || true
	local state
	if ! state=$(casefile_peek "$case/case.env" STATE); then
		recover_case_invalid "$case"
	elif [[ $state == "done" ]]; then
		recover_after "$case"
	else
		ui_msg "Rettung unterbrochen" "Die Rettung wurde unterbrochen (Status: $state).\n\nFortsetzen: Hauptmenü > Unterbrochene Rettung fortsetzen.\nDer bisherige Stand bleibt erhalten."
	fi
}

# Sagt, warum ein Rettungsfall nicht verwendet wird. Die Falldatei kommt von der Ziel-Disk und
# wird nur gelesen und geprüft (lib/casefile.sh).
recover_case_invalid() {
	casefile_load "$1/case.env" || true
	log "Falldatei abgelehnt: $1/case.env: $CASEFILE_ERROR"
	ui_msg "Rettungsfall nicht verwendbar" "Die Falldatei von $(basename "$1") ist ungültig:\n\n$CASEFILE_ERROR\n\nDie Datei wurde nur gelesen, nichts daraus wurde ausgeführt. Stammt die Disk aus fremder Hand, ist Vorsicht angebracht. Image und Protokoll im Fallordner bleiben unberührt."
}

recover_resume() {
	if tmux has-session -t lf-rettung 2>/dev/null; then
		tmux attach -t lf-rettung
		return 0
	fi
	local tid
	tid=$(disk_pick "Fortsetzen" "Auf welcher Ziel-Disk liegt die unterbrochene Rettung?") || return 0
	target_find_cases "$tid" || { ui_msg "Fortsetzen" "Auf dieser Disk wurde kein Rettungsfall (Ordner LF/) gefunden."; return 0; }
	# Was unter LF/ liegt, kommt von der Ziel-Disk. Angeboten werden nur echte Ordner mit einem
	# Namen, wie der Assistent ihn vergibt (casefile_dirname_ok). Jeder andere Name könnte als
	# Option oder als Befehl gelesen werden, sobald er in einem Menü oder einer Befehlszeile
	# steht. Solche Einträge werden gezählt, ihr Name wird nirgends ausgegeben.
	# Bis hierher ist die Disk nur lesend eingehängt und auf Kernelebene schreibgeschützt
	# (target_find_cases). Jeder Ausstieg vor der Wahl eines Falls endet mit target_search_end.
	local root
	root=$(target_cases_dir)
	if [[ -L $LF_TARGET_MNT/$root ]]; then
		log "Fortsetzen abgelehnt: $root auf der Ziel-Disk ist eine Verknüpfung"
		ui_msg "Fortsetzen" "Der Ordner $root auf dieser Disk ist eine Verknüpfung. Der Assistent legt $root immer als Ordner an und verwendet diese Disk so nicht.\n\nStammt die Disk aus fremder Hand, ist Vorsicht angebracht."
		target_search_end
		return 0
	fi
	local items=() c name st skipped=0
	for c in "$LF_TARGET_MNT/$root"/*/; do
		c=${c%/}
		name=${c##*/}
		if [[ -L $c ]]; then
			skipped=$((skipped + 1))
			continue
		fi
		if ! casefile_dirname_ok "$name"; then
			[[ -e $c/case.env || -L $c/case.env ]] && skipped=$((skipped + 1))
			continue
		fi
		[[ -f $c/case.env ]] || continue
		st=$(casefile_peek "$c/case.env" STATE) || st="ungültig"
		items+=("$name" "[$st]")
	done
	if ((skipped)); then
		log "Fortsetzen: $skipped Einträge unter $root/ nicht angeboten (unzulässiger Name oder Verknüpfung)"
		ui_msg "Fortsetzen" "Nicht angebotene Einträge unter $root/: $skipped\n\nIhr Name enthält andere Zeichen als Buchstaben, Ziffern, Punkt, Unterstrich und Bindestrich, beginnt nicht mit einem Buchstaben oder einer Ziffer, oder der Eintrag ist eine Verknüpfung. Der Assistent vergibt solche Namen nicht.\n\nStammt die Disk aus fremder Hand, ist Vorsicht angebracht. Hast du einen Fallordner selbst umbenannt, gib ihm einen Namen aus den erlaubten Zeichen."
	fi
	if ((${#items[@]} == 0)); then
		ui_msg "Fortsetzen" "Auf dieser Disk liegt kein Rettungsfall, den der Assistent verwenden kann."
		target_search_end
		return 0
	fi
	local pick
	if ! pick=$(ui_menu "Fortsetzen" "Welcher Rettungsfall?" -- "${items[@]}") || ! casefile_dirname_ok "$pick"; then
		target_search_end
		return 0
	fi
	# Der Techniker hat die Disk als Ziel genannt und einen Rettungsfall auf ihr gewählt. Erst
	# jetzt wird sie beschreibbar eingehängt. Eine Disk, die in dieser Sitzung als Quelle
	# geschützt wurde, bleibt geschützt.
	if ! safety_check_target "$tid"; then
		target_search_end
		return 0
	fi
	if ! target_case_writable; then
		die "Die Partition mit dem Rettungsfall ließ sich nicht beschreibbar einhängen. Details im Protokoll."
		return 0
	fi
	c="$LF_TARGET_MNT/$root/$pick"
	if ! casefile_load "$c/case.env"; then
		recover_case_invalid "$c"
		return 0
	fi
	# Ältere Fassungen legten das Protokoll ungefiltert in den Fallordner, samt BitLocker-
	# Wiederherstellungsschlüssel (GHSA-cwvh-chmr-9xg8). Wer den Fall wieder öffnet, bereinigt es.
	log_scrub_case "$c"
	st=$(casefile_get STATE)
	if [[ $st == "done" ]]; then
		recover_after "$c"
		return 0
	fi
	# Die Quelle wählt der Techniker, nie die Falldatei. Die Datei liegt auf der Ziel-Disk; nennt
	# sie eine andere Disk als die gewählte, etwa eine interne, wird nicht fortgesetzt. Was die
	# Datei über die Quelle sagt, erscheint deshalb auch nicht in der Auswahl.
	local sid sj sdev
	sid=$(disk_pick "Fortsetzen: Quelle" "Welche Disk ist die Quelle dieses Rettungsfalls?\n\nVon ihr wird gelesen, ihr Inhalt kommt in das Image auf der Ziel-Disk.\nDer Assistent prüft danach, ob die Disk zu diesem Fall gehört." "$tid") || return 0
	sj=$(disk_info "$sid")
	sdev=$(jq -r '.path // ""' <<<"$sj")
	[[ -n $sdev ]] || { die "Die Disk $sid ist nicht mehr zu finden."; return 0; }
	casefile_source_check "$(jq -r '.serial // ""' <<<"$sj")" "$(jq -r '.wwn // ""' <<<"$sj")" "$(jq -r '.size // ""' <<<"$sj")"
	case $? in
	0) ;;
	3)
		ui_yesno "Quelle nur an der Größe erkennbar" "Dieser Rettungsfall kennt von seiner Quelle keine Seriennummer und keinen WWN. Ob die gewählte Disk die Quelle ist, lässt sich deshalb nur an der Größe prüfen. Die stimmt überein.\n\nGewählt: $(disk_label "$sj")\n\nIst das die Disk, deren Rettung unterbrochen wurde?" --defaultno || return 0
		;;
	*)
		log "Fortsetzen abgelehnt: $sdev passt nicht zum Fall $(basename "$c"): $CASEFILE_ERROR"
		ui_msg "Falsche Quelle" "Die gewählte Disk ist nicht die Quelle dieses Rettungsfalls:\n\n$(disk_label "$sj")\n\nGrund: $CASEFILE_ERROR.\n\nEs wurde nichts gelesen und nichts geschrieben.\n\nMeldet die Disk über einen anderen Adapter eine andere Seriennummer, schließe sie so an wie zu Beginn der Rettung. Hast du diesen Fall nicht selbst angelegt, ist Vorsicht angebracht: Der Fallordner liegt auf der Ziel-Disk."
		return 0
		;;
	esac
	safety_set_ro "$sdev"
	recover_run "$c" "$sdev"
}

# ---------------------------------------------------------------------------
# Arbeiten mit dem fertigen Image
# ---------------------------------------------------------------------------
recover_after() {
	local case=$1 img="$1/image.img" choice
	# Der Pfad des Fallordners steht unten in Befehlszeilen. Ein Name, den der Assistent nicht
	# vergibt, kommt dort nicht an.
	if ! casefile_dirname_ok "$(basename "$case")"; then
		die "Der Fallordner hat einen Namen, den der Assistent nicht vergibt. Er wird nicht verwendet."
		return 0
	fi
	while true; do
		choice=$(ui_menu "Image weiterverwenden" "Rettung abgeschlossen: $(basename "$case")\n\n$(ddrescuelog -t "$case/image.map" 2>/dev/null | grep -E 'rescued|bad' | head -n 3 | text_clean)\n\nWas soll mit dem Image passieren?" -- \
			copy "Dateien aus dem Image kopieren" \
			disk "Image auf eine neue Disk schreiben (Größe wird angepasst)" \
			repair "Dateisystem auf einer Kopie des Images reparieren" \
			carve "Gelöschte/verlorene Dateien suchen (PhotoRec)" \
			vhdx "In VHDX umwandeln (Hyper-V, Windows einbinden)" \
			report "Bericht anzeigen" \
			claude "Claude um Rat fragen" \
			"done" "Fertig") || choice="done"
		case $choice in
		copy) image_copy_files "$case" "$img" ;;
		disk) image_to_disk "$case" "$img" ;;
		repair) image_repair "$case" "$img" ;;
		carve) image_carve "$case" "$img" ;;
		# Pfade sind eigene Argumente, nie Teil des Befehlstexts (auch unten bei rsync und cp).
		vhdx) tmux_run "lf-vhdx" bash -c 'qemu-img convert -p -O vhdx -o subformat=dynamic "$1" "$2"; echo; read -r -p "Fertig. Enter … " _' _ "$img" "$case/image.vhdx" ;;
		report) ui_textfile "Bericht" "$case/report.txt" ;;
		claude) claude_start "$case" ;;
		done)
			# Was die Menüs hier eingehängt und eingebunden haben, belegte sonst das Ziel (#83).
			image_release "$case" ||
				ui_msg "Image noch in Benutzung" "Das Image bleibt eingebunden, das Ziel ist damit noch belegt:\n\n$IMAGE_BUSY\n\nIst das erledigt, gibt lf das Image frei, sobald du ein anderes Ziel einhängst oder 'Image weiterverwenden' wieder mit 'Fertig' verlässt."
			return 0
			;;
		esac
	done
}

# Image als Loop-Device einbinden (nur lesend, mit Partitionen). Gibt /dev/loopN aus.
image_attach() {
	local img=$1 mode=${2:-ro} loop new=0
	loop=$(sudo losetup -j "$img" | cut -d: -f1 | head -n1)
	if [[ -z $loop ]]; then
		if [[ $mode == ro ]]; then
			loop=$(sudo losetup --find --show -P -r "$img")
		else
			loop=$(sudo losetup --find --show -P "$img")
			new=1
		fi
	fi
	sleep 1
	((new)) && image_attach_clear_ro "$loop"
	echo "$loop"
}

# image_attach_clear_ro LOOP   Ein Loop-Gerät, das der Kernel wiederverwendet, behält einen
#   Schreibschutz, den blockdev --setro früher auf ihm gesetzt hat (#48). Das gilt auch für seine
#   Partitionen. Aufgehoben wird er nur hier, für ein Gerät, das image_attach gerade selbst
#   beschreibbar eingebunden hat. Quellen sind nie Loop-Geräte, die so entstehen.
image_attach_clear_ro() {
	local p
	local -a parts
	mapfile -t parts < <(lsblk -nr -o PATH "$1" 2>/dev/null | tail -n +2)
	for p in "$1" "${parts[@]}"; do
		[[ $(sudo blockdev --getro "$p" 2>/dev/null) == 1 ]] || continue
		log "Loop-Gerät $p trug noch einen alten Schreibschutz, aufgehoben"
		run sudo blockdev --setrw "$p"
	done
}

# Jobs, die aus einem Image lesen können, auch zwischen zwei Schritten, in denen sie es gerade
# nicht offen haben: lf-klon und lf-p2v ("Image auf eine neue Disk"). Solange eine solche Sitzung
# besteht, auch wenn sie nur noch auf Enter wartet, bleibt jedes Image eingebunden. Ein gelöstes
# Loop-Gerät ließe den Job abbrechen, oder er läse im nächsten Schritt ein anderes Image, das
# inzwischen dieselbe Nummer bekommen hat.
IMAGE_LOOP_JOBS="lf-klon lf-p2v"

# image_loops ORDNER   Loop-Geräte, deren Datei in ORDNER liegt (ein Fallordner oder das Ziel).
image_loops() {
	losetup -J -O NAME,BACK-FILE 2>/dev/null |
		jq -r --arg d "${1%/}/" '.loopdevices[]? | select((."back-file" // "") | startswith($d)) | .name'
}

# image_release ORDNER   Gibt die Images frei, die in ORDNER liegen (ein Fallordner oder das
#   Ziel): hängt aus, was von ihnen unter $LF_IMAGE_MNT eingehängt ist (auch die reparierte Kopie
#   und bei BitLocker die entschlüsselte Partition), und löst die Loop-Geräte. Sonst bleibt das
#   Ziel belegt, und lf hängt bis zum Neustart kein anderes ein (#83).
#   Ausgehängt wird nie mit Gewalt: Benutzt etwas einen Einhängepunkt noch, etwa rsync in
#   lf-kopie (sein Arbeitsverzeichnis liegt in der Quelle), bleibt er samt Loop-Gerät. Was bleibt,
#   steht danach in IMAGE_BUSY. Rückgabe 0, wenn von diesen Images nichts mehr eingebunden ist.
image_release() {
	local j loop p d mp x i busy
	local -a loops parts mps
	IMAGE_BUSY=""
	mapfile -t loops < <(image_loops "$1")
	((${#loops[@]})) || return 0
	for j in $IMAGE_LOOP_JOBS; do
		tmux has-session -t "=$j" 2>/dev/null || continue
		IMAGE_BUSY="Der Job $j ist noch offen (er läuft oder wartet auf Enter) und liest womöglich aus dem Image. Ansicht: tmux attach -t $j"
		log "Images in $1 bleiben eingebunden: $IMAGE_BUSY"
		return 1
	done
	for loop in "${loops[@]}"; do
		busy=""
		mapfile -t parts < <(lsblk -nr -o PATH "$loop" 2>/dev/null)
		for p in "${parts[@]}"; do
			# BitLocker: Eingehängt ist die Datei, die dislocker aus der Partition entschlüsselt,
			# über ein eigenes Loop-Gerät oder direkt mit ntfs-3g (part_mount_ro).
			d="$LF_RUN/dislocker-$(basename "$p")"
			mapfile -t mps < <(
				findmnt -rn -o TARGET -S "$p" 2>/dev/null || true
				if mountpoint -q "$d"; then
					findmnt -rn -o TARGET -S "$d/dislocker-file" 2>/dev/null || true
					for x in $(losetup -n -O NAME -j "$d/dislocker-file" 2>/dev/null); do
						findmnt -rn -o TARGET -S "$x" 2>/dev/null || true
					done
				fi
			)
			for mp in "${mps[@]}"; do
				[[ $mp == "$LF_IMAGE_MNT"/?* ]] || continue
				run sudo umount "$mp" || busy+="$mp wird noch benutzt. "
			done
			if mountpoint -q "$d"; then
				run sudo umount "$d" || busy+="$d wird noch benutzt. "
			fi
		done
		# Eingehängt außerhalb von $LF_IMAGE_MNT (von Hand) bleibt eingehängt, das Gerät auch.
		if [[ -z $busy ]] && lsblk -nr -o MOUNTPOINTS "$loop" 2>/dev/null | grep -q .; then
			busy="$(basename "$loop") ist noch außerhalb von $LF_IMAGE_MNT eingehängt. "
		fi
		if [[ -z $busy ]]; then
			if run sudo losetup -d "$loop"; then
				# Hat noch etwas das Gerät offen, löst es der Kernel erst danach. ntfs-3g etwa
				# endet erst kurz nach dem Aushängen.
				for i in 1 2 3; do
					[[ -n $(losetup -n -O BACK-FILE "$loop" 2>/dev/null) ]] || break
					sleep 1
				done
				[[ -n $(losetup -n -O BACK-FILE "$loop" 2>/dev/null) ]] && busy+="$(basename "$loop") ist noch geöffnet und wird gelöst, sobald es frei ist. "
			else
				busy+="$(basename "$loop") ließ sich nicht lösen. "
			fi
		fi
		IMAGE_BUSY+=$busy
	done
	[[ -z $IMAGE_BUSY ]] && return 0
	log "Images in $1 bleiben teils eingebunden: $IMAGE_BUSY"
	return 1
}

# Schutzoptionen für jede Partition aus einem Image. Ein Image ist der Inhalt einer fremden
# Disk: Was darin liegt, wird gelesen und kopiert, sonst nichts.
#   ro           Es wird nicht geschrieben.
#   nodev        Gerätedateien im Image öffnen kein Gerät.
#   nosuid       Setuid- und Setgid-Bits im Image wirken nicht.
#   noexec       Aus dem Image wird nichts ausgeführt.
#   nosymfollow  Verknüpfungen im Image werden nicht verfolgt. Eine Verknüpfung nach /etc oder
#                in den persistenten Speicher zeigte sonst auf Dateien des Rettungssystems.
#                Kopiert werden Verknüpfungen weiterhin, als Verknüpfungen.
IMAGE_MOUNT_OPTS=(ro nodev nosuid noexec nosymfollow)

# ntfs3g_ro OPTIONEN QUELLE EINHÄNGEPUNKT   ntfs-3g (FUSE) für eine nur lesend eingehängte Quelle.
#   ntfs-3g läuft weiter, solange die Quelle eingehängt ist. Es startet deshalb als eigener Dienst
#   (lf-ntfs3g-<Einhängepunkt>.service), nicht als Kind des Aufrufers: Hängt Claude eine Quelle mit
#   lf-aufgabe ein, läge ntfs-3g sonst in Claudes cgroup, und das Ende einer Claude-Freigabe hielte
#   es an und beendete es mit allen root-Prozessen dort (lf-freigabe, GHSA-799j-44qx-x7xj).
#   Type=forking: systemd-run kehrt zurück, wenn ntfs-3g eingehängt und sich gelöst hat.
#   UnsetEnvironment: ntfs-3g erbt keine Variable aus LF_ENV_UNSAFE vom Manager. Nach dem
#   Aushängen endet ntfs-3g und mit ihm der Dienst. Was ntfs-3g meldet, steht im Journal des
#   Dienstes, bei einem Fehler auch im Protokoll.
ntfs3g_ro() {
	local unit
	unit="lf-ntfs3g-$(systemd-escape --path -- "$3").service"
	# Ein Dienst vom letzten Einhängen an derselben Stelle wäre schon ausgehängt (part_mount_ro).
	sudo systemctl stop "$unit" >/dev/null 2>&1
	if ! run sudo systemd-run --quiet --collect --unit="$unit" -p Type=forking -p UnsetEnvironment="$LF_ENV_UNSAFE" \
		--description="Leuchtfeuer: ntfs-3g, nur lesend unter $3" -- ntfs-3g -o "$1" "$2" "$3"; then
		sudo journalctl -q -o cat -n 20 -u "$unit" >>"${LF_LOG:-/dev/null}" 2>&1
		return 1
	fi
}

# Partition nur lesend einhängen; behandelt NTFS, ext*, XFS, Btrfs und BitLocker.
# Danach wird am Einhängepunkt geprüft, ob alle Schutzoptionen gelten (mount_enforce).
part_mount_ro() {
	local part=$1 mp=$2 fs opts
	opts=$(
		IFS=,
		echo "${IMAGE_MOUNT_OPTS[*]}"
	)
	fs=$(sudo blkid -o value -s TYPE "$part")
	sudo install -d "$mp"
	if mountpoint -q "$mp"; then
		# Hängt genau diese Partition schon geschützt dort, bleibt sie eingehängt.
		if [[ $(findmnt -n -o SOURCE -M "$mp" 2>/dev/null) == "$part" ]] && mount_has_opts "$mp" "${IMAGE_MOUNT_OPTS[@]}"; then
			return 0
		fi
		# Über etwas anderes wird nicht eingehängt: Sonst wäre unklar, wofür die Prüfung gilt.
		if ! run sudo umount "$mp"; then
			log "Einhängen abgelehnt: $mp ist noch in Benutzung und lässt sich nicht aushängen."
			return 1
		fi
	fi
	case $fs in
	BitLocker)
		local key
		key=$(ui_input "BitLocker" "$(basename "$part") ist mit BitLocker verschlüsselt.\n\nWiederherstellungsschlüssel (48 Ziffern, mit Bindestrichen):") || return 1
		key=$(bitlocker_key_normalize "$key") ||
			{ die "Das ist kein BitLocker-Wiederherstellungsschlüssel (8 Gruppen zu 6 Ziffern)."; return 1; }
		sudo install -d "$LF_RUN/dislocker-$(basename "$part")"
		# Der Schlüssel geht nur an dislocker, über die Standardeingabe einer root-Shell und nie über
		# eine Befehlszeile: sudo schreibt seine Befehlszeile ins Journal, und ps zeigt sie, solange
		# dislocker den Schlüssel ableitet. dislocker überschreibt -p beim Start selbst mit X
		# (hide_opt); sein eigener Prompt liest nur von /dev/tty. Die Ausgabe steht maskiert im
		# Protokoll (run_masked, GHSA-cwvh-chmr-9xg8).
		printf '%s\n' "$key" |
			run_masked sudo bash -c 'IFS= read -r k && exec dislocker -r -V "$1" -p"$k" -- "$2"' lf-dislocker \
				"$part" "$LF_RUN/dislocker-$(basename "$part")" ||
			{ die "Entschlüsselung fehlgeschlagen. Schlüssel prüfen."; return 1; }
		run sudo mount -o "$opts,loop" "$LF_RUN/dislocker-$(basename "$part")/dislocker-file" "$mp" ||
			run sudo ntfs-3g -o ro,nodev,nosuid,noexec "$LF_RUN/dislocker-$(basename "$part")/dislocker-file" "$mp"
		;;
	ntfs) run sudo mount -t ntfs3 -o "$opts" "$part" "$mp" || ntfs3g_ro ro,nodev,nosuid,noexec,recover "$part" "$mp" ;;
	ext2 | ext3 | ext4) run sudo mount -o "$opts,noload" "$part" "$mp" ;;
	xfs) run sudo mount -o "$opts,norecovery" "$part" "$mp" ;;
	btrfs) run sudo mount -o "$opts,rescue=usebackuproot" "$part" "$mp" || run sudo mount -o "$opts,rescue=all" "$part" "$mp" ;;
	"") return 1 ;;
	*) run sudo mount -o "$opts" "$part" "$mp" ;;
	esac || return 1
	mount_enforce "$mp" "${IMAGE_MOUNT_OPTS[@]}"
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
	mp="$LF_IMAGE_MNT/$(basename "$part")"
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
		# ntfs3 liefert Windows-Attribute wie $LXUID als erweiterte Attribute ohne Namensraum, auch für
		# Dateien, die Linux angelegt hat. rsync kann sie auf dem Ziel nicht setzen und meldet für jede
		# Datei einen Fehler (#78). Maßgeblich ist, was eingehängt ist: so zählen ntfs-3g und BitLocker
		# (fuseblk) mit.
		case $(findmnt -n -o FSTYPE -M "$mp" 2>/dev/null) in ntfs3 | ntfs | fuseblk) ropts="-aH" ;; esac
		[[ $(target_fs) == exfat || $(target_fs) == ntfs* || $(target_fs) == fuseblk ]] && ropts="-rt --modify-window=2"
		# $1 sind die Optionen von rsync (fester Text von oben) und werden mit Absicht in Wörter zerlegt.
		# Die Startzeile steht da, bevor rsync etwas ausgibt. Bei großen Quellen dauert das (#79).
		tmux_run "lf-kopie" bash -c 'printf "%s\n" "Kopiere $2" "nach $3" "rsync zählt zuerst die Dateien, die Anzeige kommt danach. Protokoll: $4" ""; sudo rsync $1 --info=progress2 --ignore-errors "$2/" "$3/" 2>&1 | tee -a "$4"; echo; read -r -p "Fertig. Enter … " _' _ "$ropts" "$mp" "$dst" "$case/kopie.log"
		;;
	mc) sudo mc "$mp" "$dst" ;;
	shell) (cd "$mp" && PS1="[lf image] \w \$ " bash --norc -i) ;;
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
		tmux_run "lf-kopie" bash -c 'cp --sparse=always "$1" "$2" && echo Kopie fertig; read -r -p "Enter … " _' _ "$img" "$copy"
	fi
	loop=$(image_attach "$copy" rw)
	if [[ $(sudo blockdev --getro "$loop" 2>/dev/null) == 1 ]]; then
		die "Die Kopie ist nur lesend eingebunden ($loop). Sie ist schon anderswo nur lesend eingebunden, oder das Gerät lässt sich nicht beschreibbar machen."
		return 0
	fi
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
	part_mount_ro "$part" "$LF_IMAGE_MNT/repair-$(basename "$part")" &&
		ui_msg "Eingehängt" "Reparierte Partition liegt nur lesend unter $LF_IMAGE_MNT/repair-$(basename "$part")"
}

image_carve() {
	local case=$1 img=$2
	mkdir -p "$case/photorec"
	ui_msg "PhotoRec" "PhotoRec sucht Dateien anhand ihrer Inhalte, auch ohne funktionierendes Dateisystem.\n\nIm nächsten Schritt: Partition wählen > Dateisystemtyp > 'Whole' > Ziel ist schon gesetzt (mit C bestätigen).\nErgebnisse landen in $case/photorec/"
	sudo photorec /log /d "$case/photorec/recup" "$img"
	sudo chown -R "$(id -u):$(id -g)" "$case/photorec" 2>/dev/null || true
}
