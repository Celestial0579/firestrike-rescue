#!/usr/bin/env bash
# Unit-Test: Was die Quell-Disk über sich meldet, wird im Klon-Job nie zum Befehl.
#
# Der Klon-Job und das sfdisk-Skript sind erzeugter Text und laufen als root. Das Label einer
# Swap-Partition der Quelle stand ungeprüft in einer mkswap-Zeile: Ein Label wie ';reboot;'
# (16 Zeichen sind erlaubt) wurde dort zum Befehl. Der Name einer GPT-Partition stand ungeprüft
# im sfdisk-Skript, wo ein Anführungszeichen den Namen beendet und der Rest als weitere Angaben
# zur Partition gilt. Der Test prüft:
#   - ein präpariertes Swap-Label oder eine präparierte UUID wird weggelassen, nichts läuft,
#   - Gerätepfade und Dateisystemnamen werden geprüft, sonst entsteht kein Job,
#   - ein präparierter Partitionsname steht nicht im sfdisk-Skript.
# Ohne root und ohne Disks: blkid, sfdisk und tmux sind Attrappen. Der Job wird nie gestartet.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
export LC_ALL=C.UTF-8

T=$(mktemp -d)
LF_RUN="$T/run"
LF_LOG="$T/lf.log"
mkdir -p "$LF_RUN" "$T/lauf"
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/clone.sh
LF_RUN="$T/run"
# Präparierte Texte legen Markerdateien im Arbeitsverzeichnis an, falls sie ausgeführt werden.
cd "$T/lauf" || exit 1

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
markers() { compgen -G "$T/lauf/MARKE*" >/dev/null; }

die() {
	DIE_MSG="$*"
	return 1
}
ui_msg() { :; }
sleep() { :; }
tmux() { return 1; }
tmux_run() { printf '%s\n' "$*" >>"$T/tmux"; }
# Wie tmux_run, dazu die Disk, die der Job beschreibt (Jobliste für lf-aufgabe).
tmux_run_writing() { printf '%s\n' "$1 ${*:3}" >>"$T/tmux"; printf '%s\n' "$2" >>"$T/writes"; }
# blkid meldet, was die Quell-Partition über sich sagt. sfdisk bekommt sein Skript auf der
# Standardeingabe: Es wird nur mitgeschrieben.
sudo() {
	case "$*" in
	"blkid -o value -s UUID "*) printf '%s\n' "$SWAP_UUID" ;;
	"blkid -o value -s LABEL "*) printf '%s\n' "$SWAP_LABEL" ;;
	"sfdisk "*) cat >"$T/sfdisk-skript" ;;
	esac
	return 0
}

# lsblk meldet Seriennummer, WWN und Größe einer Disk (Fingerabdruck für den Klon-Job).
IDENT_SRC="S5Y1NJ0R123456 0x5002538f12345678 500107862016"
IDENT_DST="WD-WX12A34B5C6D 0x50014ee2b1234567 1000204886016"
lsblk() {
	case "${*: -1}" in
	/dev/sda) printf '%s\n' "$IDENT_SRC" ;;
	/dev/sdb) printf '%s\n' "$IDENT_DST" ;;
	esac
}

GOOD_UUID="0f0f0f0f-1111-2222-3333-444444444444"

# swap_line   Erzeugt die Zeile des Jobs für eine Swap-Partition und führt sie so aus, wie der
# Job es täte. mkswap schreibt nur seine Argumente mit. Ergebnis: LINE, ARGS.
swap_line() {
	rm -f "$T/mkswap"
	LINE=$(clone_cmd_copy /dev/sda3 /dev/sdb3 swap)
	bash -c "mkswap() { printf '%s|' \"\$@\" >>'$T/mkswap'; }; fail() { :; }; $LINE" >/dev/null 2>&1
	ARGS=$(cat "$T/mkswap" 2>/dev/null)
}

# ---------------------------------------------------------------------------
echo "Swap-Partition mit gewöhnlichem Label:"
SWAP_UUID=$GOOD_UUID SWAP_LABEL="swap-1"
swap_line
check "UUID und Label werden übernommen" '[[ $ARGS == "-U|$GOOD_UUID|-L|swap-1|/dev/sdb3|" ]]'
SWAP_LABEL="Linux Swap"
swap_line
check "Label mit Leerzeichen bleibt ein Argument" '[[ $ARGS == "-U|$GOOD_UUID|-L|Linux Swap|/dev/sdb3|" ]]'
SWAP_LABEL=""
swap_line
check "ohne Label: nur die UUID" '[[ $ARGS == "-U|$GOOD_UUID|/dev/sdb3|" ]]'

echo "Präpariertes Swap-Label:"
# shellcheck disable=SC2016
for label in "';touch MARKE;'" '$(touch MARKE)' '`touch MARKE`' "a'b" 'a"b' "a;touch MARKE" "a|b" 'a\b' $'a\ntouch MARKE' "Müll"; do
	SWAP_UUID=$GOOD_UUID SWAP_LABEL=$label
	swap_line
	check "$(printf '%q' "$label"): weggelassen, Partition wird ohne Label angelegt" '[[ $ARGS == "-U|$GOOD_UUID|/dev/sdb3|" && $LINE != *MARKE* ]]'
done
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'
check "im Protokoll steht, dass das Label nicht übernommen wurde" 'grep -q "Swap-Label von /dev/sda3 nicht übernommen" "$LF_LOG"'

echo "Präparierte UUID:"
for uuid in "x';touch MARKE-uuid;'" '$(touch MARKE-uuid)' "0f0f0f0f-1111-2222-3333-44444444444" "$GOOD_UUID extra"; do
	SWAP_UUID=$uuid SWAP_LABEL="swap"
	swap_line
	check "$(printf '%q' "$uuid"): weggelassen" '[[ $ARGS == "-L|swap|/dev/sdb3|" && $LINE != *MARKE* ]]'
done
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# ---------------------------------------------------------------------------
# plan TEILE...   Füllt, was clone_plan sonst berechnet. Jedes TEIL ist "KNOTEN DATEISYSTEM".
plan() {
	local part i=0
	CLONE_PARTS=() CLONE_FS=() CLONE_NEW_SIZE=() CLONE_NEW_START=()
	CLONE_ELASTIC=-1 CLONE_SHRINK=0 CLONE_SS=512 CLONE_LABEL=gpt
	for part in "$@"; do
		CLONE_PARTS[i]=$(jq -cn --arg n "${part% *}" '{node: $n, start: 2048, size: 204800, type: "0FC63DAF-8483-4772-8E79-3D69D8477DE4", uuid: "u"}')
		CLONE_FS[i]=${part##* }
		CLONE_NEW_START[i]=2048
		CLONE_NEW_SIZE[i]=204800
		i=$((i + 1))
	done
}
# job   Erzeugt den Klon-Job, ohne ihn zu starten. Ergebnis: RC, JOB (Text des Jobs), DIE_MSG.
job() {
	rm -f "$LF_RUN/clone-job.sh" "$T/tmux"
	DIE_MSG=""
	clone_copy /dev/sda /dev/sdb
	RC=$?
	JOB=$(cat "$LF_RUN/clone-job.sh" 2>/dev/null)
	STARTED=$(cat "$T/tmux" 2>/dev/null)
}

echo "Klon-Job für eine gewöhnliche Disk:"
SWAP_UUID=$GOOD_UUID SWAP_LABEL="swap"
plan "/dev/sda1 vfat" "/dev/sda2 ext4" "/dev/sda3 swap" "/dev/sda4 "
job
check "Job erzeugt und über bash gestartet (#72)" '[[ -n $JOB && $STARTED == "lf-klon sudo bash $LF_RUN/clone-job.sh" ]]'
check "die Ziel-Disk steht für den Job in der Jobliste (GHSA-p86q-3456-f288)" '[[ $(tail -n1 "$T/writes" 2>/dev/null) == /dev/sdb ]]'
check "der Job ist gültiges Shell-Skript" 'bash -n "$LF_RUN/clone-job.sh"'
check "jede Partition hat ihre Zeile" '[[ $JOB == *"partclone.vfat -b -s '"'"'/dev/sda1'"'"' -o '"'"'/dev/sdb1'"'"'"* && $JOB == *"partclone.extfs -b -s '"'"'/dev/sda2'"'"'"* && $JOB == *"mkswap -U $GOOD_UUID -L '"'"'swap'"'"' '"'"'/dev/sdb3'"'"'"* && $JOB == *"dd if='"'"'/dev/sda4'"'"' of='"'"'/dev/sdb4'"'"'"* ]]'

echo "Der Klon-Job prüft vor jedem Schritt, dass Quelle und Ziel noch dieselben Disks sind:"
hex='[0-9a-f]{64}'
check "vor jeder der vier Partitionen stehen beide Prüfungen" '[[ $(grep -cE "^same ./dev/sda. .$hex.\$" <<<"$JOB") == 4 && $(grep -cE "^same ./dev/sdb. .$hex.\$" <<<"$JOB") == 4 ]]'
check "die Prüfung steht vor dem Schritt, nicht danach" '[[ $(grep -nE "^(same|step) " <<<"$JOB" | head -n 3 | cut -d: -f2 | cut -d" " -f1 | tr "\n" " ") == "same same step " ]]'
check "im Job steht nur der Hashwert, keine Angabe des Geräts" '[[ $JOB != *S5Y1NJ0R123456* && $JOB != *WD-WX12A34B5C6D* && $JOB != *0x5002538f12345678* ]]'
# guard GERÄT   Führt die Prüfung des Jobs für GERÄT so aus, wie der Job es täte. lsblk meldet
# dabei, was in IDENT_SRC und IDENT_DST steht. Ergebnis: GUARD ("JOB-LAEUFT" oder die Meldung).
guard() {
	local line
	line=$(grep -E "^same '$1' " <<<"$JOB" | head -n 1)
	GUARD=$(SRC=$IDENT_SRC DST=$IDENT_DST bash -c "lsblk() { case \"\${*: -1}\" in /dev/sda) printf '%s\n' \"\$SRC\" ;; /dev/sdb) printf '%s\n' \"\$DST\" ;; esac; }
		read() { :; }
		$(grep -E '^(fail|ident|same)\(\) ' <<<"$JOB")
		$line
		echo JOB-LAEUFT" 2>&1)
}
guard /dev/sdb
check "unverändert: der Job läuft weiter" '[[ $GUARD == JOB-LAEUFT ]]'
keep=$IDENT_DST
IDENT_DST=$IDENT_SRC
guard /dev/sdb
check "hinter dem Namen des Ziels steht jetzt die Quelle: Abbruch vor dem Schreiben" '[[ $GUARD == *FEHLER*"nicht mehr die Disk vom Start"* && $GUARD != *JOB-LAEUFT* ]]'
IDENT_DST=""
guard /dev/sdb
check "das Ziel ist verschwunden: Abbruch" '[[ $GUARD == *FEHLER* && $GUARD != *JOB-LAEUFT* ]]'
IDENT_DST="WD-WX12A34B5C6D 0x50014ee2b1234567 2000398934016"
guard /dev/sdb
check "gleiche Seriennummer, andere Größe: Abbruch" '[[ $GUARD == *FEHLER* && $GUARD != *JOB-LAEUFT* ]]'
IDENT_DST=$keep
keep=$IDENT_SRC
IDENT_SRC="\x27;touch MARKE;\x27 - 500107862016"
IDENT_SRC=$(printf '%b' "$IDENT_SRC")
job
check "präparierte Seriennummer der Quelle: Job gültig, die Angabe steht nicht darin" '[[ -n $JOB && $JOB != *MARKE* ]] && bash -n "$LF_RUN/clone-job.sh"'
IDENT_SRC=""
job
check "die Quelle ist nicht mehr zu erkennen: kein Job, nichts gestartet" '[[ $RC != 0 && -z $JOB && -z $STARTED && $DIE_MSG == *"nicht mehr zu erkennen"* ]]'
IDENT_SRC=$keep
job

echo "Klon-Job mit präpariertem Swap-Label:"
SWAP_LABEL="';touch MARKE;'"
job
check "Job erzeugt, gültiges Shell-Skript" '[[ -n $JOB ]] && bash -n "$LF_RUN/clone-job.sh"'
check "das Label steht nirgends im Job" '[[ $JOB != *MARKE* && $JOB == *"mkswap -U $GOOD_UUID  '"'"'/dev/sdb3'"'"'"* ]]'

echo "Angaben, die in keinem Befehl stehen dürfen:"
SWAP_LABEL="swap"
plan "/dev/sda1 vfat" "/dev/sda2'; touch MARKE; ' ext4"
job
check "Gerätepfad mit Anführungszeichen: kein Job, nichts gestartet" '[[ $RC != 0 && -z $JOB && -z $STARTED && $DIE_MSG == *"wird nicht gestartet"* ]]'
plan "/dev/sda1 vfat" "/dev/sda2 ext4';touch"
job
check "Dateisystemname mit Anführungszeichen: kein Job, nichts gestartet" '[[ $RC != 0 && -z $JOB && -z $STARTED ]]'
plan '/dev/sda1 vfat' '/dev/$(touch MARKE)2 ext4'
job
check "Gerätepfad mit Befehlsersetzung: kein Job, nichts gestartet" '[[ $RC != 0 && -z $JOB && -z $STARTED ]]'
plan "/dev/../etc/sda1 vfat"
job
check "Pfad, der aus /dev hinausführt: kein Job" '[[ $RC != 0 && -z $JOB ]]'
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# ---------------------------------------------------------------------------
# table NAME...   Schreibt die Partitionstabelle für Partitionen mit diesen Namen. Ergebnis: SCRIPT.
table() {
	local name i=0
	CLONE_PARTS=() CLONE_SS=512 CLONE_LABEL=gpt
	CLONE_PT='{"partitiontable":{"id":"AAAAAAAA-0000-0000-0000-000000000000"}}'
	CLONE_NEW_START=() CLONE_NEW_SIZE=()
	for name in "$@"; do
		CLONE_PARTS[i]=$(jq -cn --arg n "/dev/sda$((i + 1))" --arg name "$name" '{node: $n, start: 2048, size: 204800, type: "0FC63DAF-8483-4772-8E79-3D69D8477DE4", uuid: "11111111-2222-3333-4444-555555555555", name: $name, attrs: "RequiredPartition GUID:63"}')
		CLONE_NEW_START[i]=$((2048 + i * 204800))
		CLONE_NEW_SIZE[i]=204800
		i=$((i + 1))
	done
	rm -f "$T/sfdisk-skript"
	clone_write_table /dev/sdb replace
	SCRIPT=$(cat "$T/sfdisk-skript" 2>/dev/null)
}

echo "Jobs laufen über bash, nie direkt: /run ist auf der ISO noexec (#72):"
klon_start='tmux_run_writing "lf-klon" "$tdev" "${LF_JOB_RUN[@]}" "$job"'
p2v_start='tmux_run "lf-p2v" "${LF_JOB_RUN[@]}" "$job"'
direkt='sudo "$job"'
check "Klon und P2V starten ihren Job über LF_JOB_RUN" 'grep -qF -- "$klon_start" "$REPO/rescue/lib/clone.sh" && grep -qF -- "$p2v_start" "$REPO/rescue/lib/p2v.sh"'
check "kein Job wird direkt als Programm gestartet" '! grep -rnF -- "$direkt" "$REPO/rescue"'
check "LF_JOB_RUN startet über bash" '[[ ${LF_JOB_RUN[*]} == "sudo bash" ]]'

echo "NTFS: der Sicherungs-Bootsektor im letzten Sektor kommt mit (#73):"
plan "/dev/sda1 ntfs" "/dev/sda2 vfat"
job
check "Job für NTFS und vfat erzeugt" '[[ -n $JOB ]] && bash -n "$LF_RUN/clone-job.sh"'
check "nur die NTFS-Partition zieht den letzten Sektor nach" '[[ $(grep -c "count=1 conv=notrunc,fsync" <<<"$JOB") == 1 && $(grep -c "^ss=\$(blockdev --getss '"'"'/dev/sda1'"'"')" <<<"$JOB") == 1 ]]'
# Die zwei Zeilen laufen lassen, mit Dateien statt Geräten: blockdev meldet hier die Dateigröße.
letzter_sektor() { # QUELLGRÖSSE ZIELGRÖSSE   Ergebnis: RC und das Ende des Ziels in $T/ende
	head -c "$1" /dev/urandom >"$T/q"
	printf 'BOOTSEKTOR-SICHERUNG' | dd of="$T/q" bs=1 seek=$(($1 - 512)) conv=notrunc status=none
	head -c "$2" /dev/zero >"$T/z"
	{
		echo 'blockdev() { case $1 in --getss) echo 512 ;; --getsize64) stat -c %s "$2" ;; esac; }'
		echo 'fail() { echo "FEHLER: $*"; exit 1; }'
		grep -A1 "^ss=" <<<"$JOB" | sed -e "s|'/dev/sda1'|'$T/q'|g" -e "s|'/dev/sdb1'|'$T/z'|g"
	} >"$T/letzter-sektor.sh"
	bash "$T/letzter-sektor.sh" >"$T/letzter-sektor.out" 2>&1
	RC=$?
	tail -c 512 "$T/z" >"$T/ende"
}
letzter_sektor 1048576 1048576
check "gleich große Partitionen: der letzte Sektor steht auf dem Ziel" '((RC == 0)) && cmp -s "$T/ende" <(tail -c 512 "$T/q")'
check "davor bleibt das Ziel unberührt" 'cmp -s -n $((1048576 - 512)) "$T/z" /dev/zero'
letzter_sektor 1048576 2097152
check "größeres Ziel (Partition wächst): nichts kopiert, ntfsresize schreibt den Sektor neu" '((RC == 0)) && cmp -s -n 2097152 "$T/z" /dev/zero'

echo "Verkleinern: Overlay auf einem freien nbd-Gerät, NTFS mit eigener Größenprüfung (#74, #75):"
SHRINK=$(clone_cmd_shrink /dev/sda3 /dev/sdb3 ntfs 6490685440)
EXT=$(clone_cmd_shrink /dev/sda2 /dev/sdb2 ext4 1073741824)
check "erzeugter Text ist gültiges bash" 'bash -n <<<"$SHRINK" && bash -n <<<"$EXT"'
check "nbd lädt wie bei P2V mit max_part=16" '[[ $SHRINK == *"modprobe nbd max_part=16"* && $SHRINK != *"max_part=0"* ]]'
check "kein festes /dev/nbd0" '[[ $SHRINK != *"/dev/nbd0"* && $EXT != *"/dev/nbd0"* ]]'
check "NTFS: partclone mit -I -C, erst nach der eigenen Größenprüfung" '(($(grep -n "Current volume size" <<<"$SHRINK" | cut -d: -f1) < $(grep -n "partclone.ntfs -I -C -b" <<<"$SHRINK" | cut -d: -f1)))'
check "ext4: partclone behält seine eigene Größenprüfung (kein -C)" '[[ $EXT == *"partclone.extfs -b -s \$nbd"* && $EXT != *" -C "* ]]'
# Die erzeugten Zeilen laufen lassen: sysfs liegt unter $T/sys, alle Programme sind Attrappen.
# schrumpf "nbdN:GRÖSSE:belegt|frei ..." VOLUMEGRÖSSE ZIELGRÖSSE   Ergebnis: RC, Aufrufe in $T/aufrufe
schrumpf() {
	local d n s b
	rm -rf "$T/sys" "$T/aufrufe"
	touch "$T/aufrufe"
	for d in $1; do
		IFS=: read -r n s b <<<"$d"
		mkdir -p "$T/sys/block/$n"
		echo "$s" >"$T/sys/block/$n/size"
		[[ $b == belegt ]] && echo 4711 >"$T/sys/block/$n/pid"
	done
	{
		echo 'set -u'
		echo 'fail() { echo "FEHLER: $*"; exit 1; }'
		echo 'step() { :; }; modprobe() { :; }; install() { :; }; mountpoint() { return 0; }; mount() { :; }; sleep() { :; }; yes() { :; }'
		echo "qemu-nbd() { echo \"qemu-nbd \$*\" >>'$T/aufrufe'; }"
		echo "partclone.ntfs() { echo \"partclone.ntfs \$*\" >>'$T/aufrufe'; }"
		echo "ntfsresize() { [[ \$* == *--info* ]] && [[ -n '$2' ]] && echo 'Current volume size: $2 bytes'; return 0; }"
		echo "blockdev() { echo $3; }"
		# Attrappen sind keine Blockgeräte: Nur diese Prüfung weicht vom erzeugten Text ab.
		sed -e "s|/sys/block/|$T/sys/block/|g" -e 's|\[\[ -b \$nbd \]\]|[[ -n $nbd ]]|' <<<"$SHRINK"
	} >"$T/schrumpf.sh"
	bash "$T/schrumpf.sh" >"$T/schrumpf.out" 2>&1
	RC=$?
}
schrumpf "nbd0:0:belegt nbd1:8:frei nbd2:0:frei nbd3:0:frei" 6489636864 6490685440
check "belegtes und verbundenes Gerät übersprungen, Overlay auf nbd2" '((RC == 0)) && grep -qx "qemu-nbd --snapshot --format=raw --fork -c /dev/nbd2 /dev/sda3" "$T/aufrufe"'
check "partclone kopiert vom Overlay mit -I -C, danach wird es getrennt" 'grep -qx "partclone.ntfs -I -C -b -s /dev/nbd2 -o /dev/sdb3" "$T/aufrufe" && [[ $(tail -n 1 "$T/aufrufe") == "qemu-nbd -d /dev/nbd2" ]]'
schrumpf "nbd0:0:frei" 6490685441 6490685440
check "Volume größer als das Ziel: Abbruch vor partclone" '((RC != 0)) && grep -q "passt nicht in /dev/sdb3" "$T/schrumpf.out" && ! grep -q partclone "$T/aufrufe" && grep -qx "qemu-nbd -d /dev/nbd0" "$T/aufrufe"'
schrumpf "nbd0:0:frei" "" 6490685440
check "Volumegröße nicht lesbar: Abbruch vor partclone" '((RC != 0)) && ! grep -q partclone "$T/aufrufe"'
schrumpf "nbd0:0:belegt nbd1:8:frei" 6489636864 6490685440
check "kein freies Gerät: Abbruch, bevor ein Overlay entsteht" '((RC != 0)) && grep -q "kein freies NBD-Gerät" "$T/schrumpf.out" && [[ ! -s $T/aufrufe ]]'

echo "Partitionsnamen im sfdisk-Skript:"
table "EFI System Partition" "Basic data partition" "Daten für Müller"
check "gewöhnliche Namen stehen im Skript, auch mit Umlauten" '[[ $SCRIPT == *"name=\"EFI System Partition\""* && $SCRIPT == *"name=\"Basic data partition\""* && $SCRIPT == *"name=\"Daten für Müller\""* ]]'
check "Attribute bleiben erhalten" '[[ $(grep -c "attrs=\"RequiredPartition GUID:63\"" <<<"$SCRIPT") == 3 ]]'
table 'x", size=1, name="y' "gut"
check "Name mit Anführungszeichen: weggelassen, keine fremde Angabe im Skript" '[[ $SCRIPT != *"size=1,"* && $SCRIPT != *"name=\"x"* && $SCRIPT == *"name=\"gut\""* ]]'
check "jede Partition behält ihre eigene Größe" '[[ $(grep -c "size=204800," <<<"$SCRIPT") == 2 ]]'
table $'eins\n/dev/sdb9 : start=1, size=1' 'a\b' ""
check "Name mit Zeilenumbruch: keine zusätzliche Zeile im Skript" '[[ $(grep -c "^/dev/sdb" <<<"$SCRIPT") == 3 && $SCRIPT != *"/dev/sdb9"* ]]'
check "Name mit Backslash und leerer Name: kein Name im Skript" '[[ $SCRIPT != *"name="* ]]'
check "im Protokoll steht, welcher Name nicht übernommen wurde" 'grep -q "Partitionsname von /dev/sda1 nicht übernommen" "$LF_LOG"'

cd / || exit 1
rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
