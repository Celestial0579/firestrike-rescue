# shellcheck shell=bash
# Gemeinsame Funktionen: Protokoll, Oberfläche (whiptail), Hilfen.

FRS_SHARE="${FRS_SHARE:-/usr/local/share/frs}"
FRS_RUN="/run/frs"
FRS_PERSIST="/persist"
FRS_TARGET_MNT="/mnt/frs-target"
FRS_IMAGE_MNT="/mnt/frs-image"

# shellcheck disable=SC1091
[[ -r /etc/frs-release ]] && . /etc/frs-release
FRS_VERSION="${FRS_VERSION:-dev}"

# ---------------------------------------------------------------------------
# Protokoll
# ---------------------------------------------------------------------------
# Jede Sitzung schreibt ein Protokoll. Liegt die Persistenz vor, landet es dort,
# sonst im RAM. Zusätzlich kopiert jeder Rettungsfall sein Protokoll aufs Ziel.

log_init() {
	local dir="$FRS_RUN/logs"
	mountpoint -q "$FRS_PERSIST" 2>/dev/null && dir="$FRS_PERSIST/logs"
	sudo install -d -o "$(id -u)" -g "$(id -g)" "$dir" "$FRS_RUN" 2>/dev/null || mkdir -p "$dir"
	if [[ -z ${FRS_LOG:-} || ! -f $FRS_LOG ]]; then
		FRS_LOG="$dir/frs-$(date +%Y%m%d-%H%M%S).log"
		: >"$FRS_LOG"
	elif [[ $FRS_LOG != "$dir"/* ]]; then
		# Persistenz wurde nachträglich eingehängt: Protokoll umziehen
		cp "$FRS_LOG" "$dir/" && FRS_LOG="$dir/$(basename "$FRS_LOG")"
	fi
	export FRS_LOG
}

log() {
	printf '%s %s\n' "$(date '+%F %T')" "$*" >>"${FRS_LOG:-/dev/null}"
}

# run CMD...   Führt einen Befehl aus, protokolliert Befehl, Ausgabe und Rückgabewert.
run() {
	log "\$ $*"
	local rc=0
	"$@" >>"${FRS_LOG:-/dev/null}" 2>&1 || rc=$?
	log "  -> rc=$rc"
	return "$rc"
}

# runv CMD...  Wie run, zeigt die Ausgabe aber zusätzlich auf dem Bildschirm.
runv() {
	log "\$ $*"
	local rc=0
	"$@" 2>&1 | tee -a "${FRS_LOG:-/dev/null}" || rc=${PIPESTATUS[0]}
	log "  -> rc=$rc"
	return "$rc"
}

die() {
	log "ABBRUCH: $*"
	ui_msg "Abbruch" "$*"
	return 1
}

# ---------------------------------------------------------------------------
# Oberfläche
# ---------------------------------------------------------------------------
# whiptail zeichnet immer direkt auf /dev/tty, damit Dialoge auch aus $(…) heraus sichtbar sind.
ui_init() {
	if [[ -r $FRS_SHARE/theme/newt-colors ]]; then
		NEWT_COLORS="$(grep -v '^#' "$FRS_SHARE/theme/newt-colors" | tr '\n' ' ')"
		export NEWT_COLORS
	fi
	UI_BACKTITLE="Firestrike Rescue $FRS_VERSION  ·  Protokoll: ${FRS_LOG:-–}"
}

_ui_size() {
	local lines cols
	lines=$(tput lines 2>/dev/null || echo 24)
	cols=$(tput cols 2>/dev/null || echo 80)
	UI_H=$((lines - 4))
	UI_W=$((cols > 100 ? 96 : cols - 4))
}

ui_msg() {
	_ui_size
	whiptail --backtitle "$UI_BACKTITLE" --title "$1" --msgbox "$2" "$UI_H" "$UI_W" >/dev/tty
}

# ui_yesno TITEL TEXT [--defaultno]
ui_yesno() {
	_ui_size
	whiptail --backtitle "$UI_BACKTITLE" --title "$1" ${3:+"$3"} --yes-button "Ja" --no-button "Nein" \
		--yesno "$2" "$UI_H" "$UI_W" >/dev/tty
}

# ui_menu TITEL TEXT [--default-item X] -- TAG BESCHREIBUNG ...   gibt das Tag auf stdout aus
ui_menu() {
	_ui_size
	local title=$1 text=$2
	shift 2
	local opts=()
	while [[ $# -gt 0 && $1 != -- ]]; do opts+=("$1"); shift; done
	[[ ${1:-} == -- ]] && shift
	local n=$(($# / 2))
	local mh=$((UI_H - 8 - $(printf '%s' "$text" | wc -l)))
	((mh > n)) && mh=$n
	((mh < 3)) && mh=3
	# "--" beendet die Optionen. Text und Einträge stammen oft von Datenträgern (Ordnernamen,
	# Seriennummern) und können mit "-" beginnen. whiptail liest sie sonst als Option.
	whiptail --backtitle "$UI_BACKTITLE" --title "$title" "${opts[@]}" \
		--ok-button "Weiter" --cancel-button "Zurück" \
		--menu -- "$text" "$UI_H" "$UI_W" "$mh" "$@" 3>&1 1>/dev/tty 2>&3
}

# Zeilen, die whiptail in einer Eingabebox neben dem Text belegt (Rahmen, Eingabefeld, Knöpfe).
# Gemessen sind es 6; die siebte ist Reserve, falls eine andere newt-Version anders rechnet.
UI_INPUT_FRAME=7

# ui_fold TEXT   Gibt den Text so aus, wie er im Dialog steht: "\n" wird zum Zeilenwechsel,
# überlange Zeilen werden am letzten Leerzeichen umbrochen. Erst damit lässt sich vorher sagen,
# wie viele Zeilen ein Text belegt. whiptail muss danach nichts mehr selbst umbrechen.
ui_fold() {
	_ui_size
	local width=$((UI_W - 6)) line cut left
	((width < 20)) && width=20
	while IFS= read -r line || [[ -n $line ]]; do
		while ((${#line} > width)); do
			cut=${line:0:width}
			left=${cut% *}
			# Nur am Leerzeichen trennen, wenn davor überhaupt etwas steht.
			[[ $cut == *" "* && -n ${left// /} ]] && cut=$left
			printf '%s\n' "$cut"
			line=${line:${#cut}}
			line=${line# }
		done
		printf '%s\n' "$line"
	done <<<"${1//\\n/$'\n'}"
}

# Wie viele Textzeilen eine Eingabebox auf diesem Bildschirm höchstens zeigen kann.
ui_input_room() {
	_ui_size
	echo $((UI_H - UI_INPUT_FRAME))
}

# ui_input TITEL TEXT [VORGABE]   gibt die Eingabe auf stdout aus
# Die Box wächst mit dem Text. whiptail schneidet Text, der nicht hineinpasst, ohne Hinweis ab;
# bei fester Höhe fehlte dann ausgerechnet die letzte Zeile, also die Eingabeaufforderung.
# Mehr als ui_input_room Zeilen passen nicht: Wer längere Texte hat, kürzt sie vorher selbst.
ui_input() {
	_ui_size
	local text height
	text=$(ui_fold "$2")
	height=$(($(wc -l <<<"$text") + UI_INPUT_FRAME))
	((height < 12)) && height=12
	((height > UI_H)) && height=$UI_H
	whiptail --backtitle "$UI_BACKTITLE" --title "$1" --ok-button "OK" --cancel-button "Abbrechen" \
		--inputbox "$text" "$height" "$UI_W" "${3:-}" 3>&1 1>/dev/tty 2>&3
}

ui_password() {
	_ui_size
	whiptail --backtitle "$UI_BACKTITLE" --title "$1" --ok-button "OK" --cancel-button "Abbrechen" \
		--passwordbox "$2" 12 "$UI_W" 3>&1 1>/dev/tty 2>&3
}

# ui_textfile TITEL DATEI   Zeigt eine Datei. Ihr Inhalt kann von einem Datenträger stammen
# (Bericht im Fallordner, SMART-Ausgabe, Protokoll). Gezeigt wird deshalb eine gefilterte Kopie
# (text_clean), die Datei selbst bleibt, wie sie ist.
ui_textfile() {
	_ui_size
	local f
	if [[ ! -r $2 ]]; then
		ui_msg "$1" "Die Datei gibt es nicht, oder sie ist nicht lesbar."
		return 0
	fi
	f=$(mktemp)
	expand "$2" 2>/dev/null | text_clean >"$f"
	whiptail --backtitle "$UI_BACKTITLE" --title "$1" --scrolltext --textbox "$f" "$UI_H" "$UI_W" >/dev/tty
	rm -f "$f"
}

# ui_text TITEL TEXT   Zeigt einen längeren Text zum Blättern. "\n" im Text ist ein Zeilenwechsel.
ui_text() {
	local f
	f=$(mktemp)
	printf '%s\n' "${2//\\n/$'\n'}" >"$f"
	ui_textfile "$1" "$f"
	rm -f "$f"
}

ui_info() {
	_ui_size
	TERM=${TERM:-linux} whiptail --backtitle "$UI_BACKTITLE" --title "$1" --infobox "$2" 10 "$UI_W" >/dev/tty
}

pause() {
	echo
	read -r -p "Weiter mit Enter … " _
}

# ---------------------------------------------------------------------------
# Texte von Datenträgern
# ---------------------------------------------------------------------------
# Was ein Datenträger über sich meldet (Modell, Label, Partitionsname) oder was auf ihm steht
# (Bericht, Protokoll), kommt nur gefiltert in einen Dialog und in den Zustand für Claude. Es
# bleiben sichtbare Zeichen: ASCII, lateinische Buchstaben mit Akzent, übliche Satzzeichen und
# die Linien von lsblk. Alles andere wird zu "?": Steuerzeichen und Escape-Folgen, unsichtbare
# Zeichen, Wechsel der Schreibrichtung, der Backtick und der Backslash.
# Der Backslash gehört dazu, weil whiptail die Zeichenfolge "\n" in jedem Text als Zeilenwechsel
# liest. Ein Label könnte sonst eigene Zeilen in einen Dialog setzen, etwa eine zweite
# Aufforderung zur Bestätigung.
TEXT_UNSAFE_RE='[^\x{20}-\x{5B}\x{5D}-\x{5F}\x{61}-\x{7E}\x{A1}-\x{AC}\x{AE}-\x{24F}\x{2010}-\x{2027}\x{2030}-\x{203A}\x{2500}-\x{257F}]'

# text_clean [BREITE]   Filtert die Standardeingabe Zeile für Zeile. Mit BREITE wird jede Zeile
# auf so viele Zeichen gekürzt und endet dann auf "…". Eine gekürzte Zeile wird im Dialog nicht
# umbrochen: Auch der Rest eines langen Labels kann so keine eigene Zeile bilden.
# Die Breite übergibt safety.sh. In dieser Datei allein sieht shellcheck keinen solchen Aufruf.
# shellcheck disable=SC2120
text_clean() {
	jq -Rr --arg re "$TEXT_UNSAFE_RE" --argjson w "${1:-0}" \
		'gsub($re; "?") | if $w > 1 and length > $w then .[0:$w - 1] + "…" else . end'
}

# ---------------------------------------------------------------------------
# Hilfen
# ---------------------------------------------------------------------------
human() { numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || echo "${1}B"; }

is_online() { timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; }

# tmux-Sitzung starten (falls nicht vorhanden) und anzeigen.
# Die Arbeit läuft weiter, auch wenn man die Ansicht mit Strg+B, D verlässt.
tmux_run() {
	local name=$1
	shift
	if ! tmux has-session -t "$name" 2>/dev/null; then
		tmux new-session -d -s "$name" -x 200 -y 50 "$@"
		tmux set-option -t "$name" status-style "bg=colour4,fg=colour7" >/dev/null
		tmux set-option -t "$name" status-left " Firestrike Rescue · $name " >/dev/null
		tmux set-option -t "$name" status-left-length 60 >/dev/null
		tmux set-option -t "$name" status-right " Strg+B, D = Ansicht verlassen (läuft weiter) " >/dev/null
		tmux set-option -t "$name" status-right-length 60 >/dev/null
		tmux set-option -t "$name" remain-on-exit off >/dev/null
	fi
	tmux attach -t "$name" || true
}

# ---------------------------------------------------------------------------
# Fremde Dateisysteme einhängen
# ---------------------------------------------------------------------------
# mount_has_opts EINHÄNGEPUNKT OPTION...   Gelten dort wirklich alle genannten Optionen?
# Gefragt wird der Kernel (findmnt), nicht der eigene Aufruf.
mount_has_opts() {
	local mp=$1 line opt n=0
	shift
	while IFS= read -r line; do
		n=$((n + 1))
		for opt in "$@"; do
			[[ ",$line," == *",$opt,"* ]] || return 1
		done
	done < <(findmnt -n -o VFS-OPTIONS -M "$mp" 2>/dev/null)
	((n > 0))
}

# mount_enforce EINHÄNGEPUNKT OPTION...   Setzt fehlende Optionen am Einhängepunkt nach. Gelten
# danach nicht alle, wird wieder ausgehängt: lieber nichts eingehängt als etwas ohne Schutz.
# "remount,bind" ändert nur die Optionen des Einhängepunkts, nicht das Dateisystem. Mit -i ruft
# mount dafür kein Hilfsprogramm des Dateisystems auf (ntfs-3g kann nicht neu einhängen).
mount_enforce() {
	local mp=$1 opts
	shift
	mount_has_opts "$mp" "$@" && return 0
	opts=$(
		IFS=,
		echo "$*"
	)
	run sudo mount -i -o "remount,bind,$opts" "$mp"
	mount_has_opts "$mp" "$@" && return 0
	log "Einhängen abgelehnt: An $mp gelten nicht alle Schutzoptionen ($opts). Vorhanden: $(findmnt -n -o VFS-OPTIONS -M "$mp" 2>/dev/null | tr '\n' ' ')"
	run sudo umount "$mp"
	return 1
}
