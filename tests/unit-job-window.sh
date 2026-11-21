#!/usr/bin/env bash
# Unit-Test: Ein Job-Fenster (tmux_start) ist so groß wie das Terminal, an das sich lf danach
# anhängt. Die erste Zeile des Jobs bleibt nach dem Anhängen zu sehen.
#
# tmux_start legte jedes Fenster mit 200×50 an. Hängte sich lf aus einem schmaleren Terminal an,
# brach tmux die Ausgabe neu um. Wurde dabei eine Zeile zweizeilig, schob tmux 3.6 oben Zeilen in
# den Verlauf: Im Fenster lf-kopie fehlte die Zeile "Kopiere <Quelle>" (#82).
# Mit echtem tmux in einem Pseudo-Terminal (script von util-linux), mit eigenem tmux-Server im
# Testordner.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d)
export TMUX_TMPDIR=$T
unset TMUX

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
ende() {
	tmux kill-server 2>/dev/null
	wait
	rm -rf "$T"
	((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
}

for p in tmux script setsid; do
	command -v "$p" >/dev/null || { echo "  FAIL $p fehlt (Pakete tmux, util-linux)"; fails=$((fails + 1)); }
done
((fails == 0)) || ende

# im_terminal SPALTEN ZEILEN SKRIPT ARG …   Führt SKRIPT in einem Pseudo-Terminal dieser Größe aus.
im_terminal() {
	local c=$1 r=$2
	shift 2
	TERM=xterm-256color script -qec "stty cols $c rows $r; bash $*" /dev/null </dev/null
}

echo "Größe für ein neues Fenster (tmux_size):"
cat >"$T/groesse.sh" <<'EOF'
. rescue/lib/common.sh
tmux_size
EOF
check "Terminal 120×40: 120×39, eine Zeile bleibt für die Statuszeile" '[[ $(im_terminal 120 40 "$T/groesse.sh" | tr -d "\r") == "120 39" ]]'
check "Terminal 80×24: 80×23" '[[ $(im_terminal 80 24 "$T/groesse.sh" | tr -d "\r") == "80 23" ]]'
check "Terminal meldet 0×0 (serielle Konsole): bisherige 200×50" '[[ $(im_terminal 0 0 "$T/groesse.sh" | tr -d "\r") == "200 50" ]]'
check "ohne Terminal: bisherige 200×50, ohne Meldung" '[[ $(setsid bash "$T/groesse.sh" </dev/null 2>&1) == "200 50" ]]'

# Ein Job wie lf-kopie: Startzeile, Zielzeile, eine Hinweiszeile, die breiter ist als das
# Terminal, dann wartet er. Angehängt wird wie in tmux_run gleich nach tmux_start, hier aber erst,
# wenn die Ausgabe dasteht: In lf liegen dazwischen die Aufrufe von tmux set-option, und das
# Fenster hat seine Ausgabe meist schon. Hängt sich tmux früher an, kommt sie erst nach dem
# Anpassen der Größe, und es gibt nichts neu umzubrechen.
cat >"$T/job.sh" <<'EOF'
. rescue/lib/common.sh
hinweis="rsync zählt zuerst die Dateien, die Anzeige kommt danach. Protokoll: /mnt/lf-target/LF/$(printf 'x%.0s' {1..60})/kopie.log"
job='printf "%s\n" "Kopiere /mnt/lf-image/loop4p1" "nach /mnt/lf-target/LF/fall/dateien/loop4p1" "$1" ""; exec sleep 60'
if [[ ${1:-} == alt ]]; then
	# Gegenprobe: so, wie tmux_start das Fenster bisher anlegte
	tmux new-session -d -s lf-test -x 200 -y 50 bash -c "$job" _ "$hinweis"
else
	tmux_start lf-test bash -c "$job" _ "$hinweis"
fi
for i in $(seq 50); do
	tmux capture-pane -p -t lf-test | grep -q '^nach ' && break
	sleep 0.1
done
tmux attach -t lf-test
EOF

# angehaengt   Wartet, bis ein Client an lf-test hängt (höchstens 10 s).
angehaengt() {
	local i
	for i in $(seq 50); do
		[[ -n $(tmux list-clients -t lf-test 2>/dev/null) ]] && { sleep 0.5; return 0; }
		sleep 0.2
	done
	return 1
}
fenster() { tmux display-message -p -t lf-test "$1" 2>/dev/null; }

echo "Fenster lf-kopie, angehängt aus einem Terminal mit 120×40 (#82):"
im_terminal 120 40 "$T/job.sh" >/dev/null 2>&1 &
check "lf hängt sich an das Fenster an" 'angehaengt'
check "das Terminal ist 120×40 groß" '[[ $(fenster "#{client_width}x#{client_height}") == 120x40 ]]'
check "das Fenster ist von Anfang an 120×39 groß, nichts wird neu umbrochen" '[[ $(fenster "#{window_width}x#{window_height}") == 120x39 ]]'
check "nichts ist in den Verlauf gerutscht" '[[ $(fenster "#{history_size}") == 0 ]]'
check "die erste Zeile ist zu sehen: Kopiere <Quelle>" '[[ $(tmux capture-pane -p -t lf-test | head -n 1) == "Kopiere /mnt/lf-image/loop4p1" ]]'
check "die lange Hinweiszeile steht vollständig da (zweizeilig)" '[[ $(tmux capture-pane -p -J -t lf-test | grep -c "/kopie.log$") == 1 ]]'
tmux kill-server 2>/dev/null
wait

echo "Gegenprobe: Fenster fest mit 200×50 wie bisher:"
im_terminal 120 40 "$T/job.sh" alt >/dev/null 2>&1 &
check "lf hängt sich an das Fenster an" 'angehaengt'
check "beim Anhängen ändert tmux die Größe auf 120×39 und bricht die Ausgabe neu um" '[[ $(fenster "#{window_width}x#{window_height}") == 120x39 ]]'
# Ob dabei oben eine Zeile in den Verlauf rutscht, hängt von der Version von tmux ab (3.6: ja).
echo "  info $(tmux -V): Verlauf $(fenster "#{history_size}") Zeile(n), erste sichtbare Zeile: $(tmux capture-pane -p -t lf-test | head -n 1)"

ende
