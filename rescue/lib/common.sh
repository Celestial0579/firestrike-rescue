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
	whiptail --backtitle "$UI_BACKTITLE" --title "$title" "${opts[@]}" \
		--ok-button "Weiter" --cancel-button "Zurück" \
		--menu "$text" "$UI_H" "$UI_W" "$mh" "$@" 3>&1 1>/dev/tty 2>&3
}

ui_input() {
	_ui_size
	whiptail --backtitle "$UI_BACKTITLE" --title "$1" --ok-button "OK" --cancel-button "Abbrechen" \
		--inputbox "$2" 12 "$UI_W" "${3:-}" 3>&1 1>/dev/tty 2>&3
}

ui_password() {
	_ui_size
	whiptail --backtitle "$UI_BACKTITLE" --title "$1" --ok-button "OK" --cancel-button "Abbrechen" \
		--passwordbox "$2" 12 "$UI_W" 3>&1 1>/dev/tty 2>&3
}

ui_textfile() {
	_ui_size
	whiptail --backtitle "$UI_BACKTITLE" --title "$1" --scrolltext --textbox "$2" "$UI_H" "$UI_W" >/dev/tty
}

ui_text() {
	local f
	f=$(mktemp)
	printf '%s\n' "$2" >"$f"
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
