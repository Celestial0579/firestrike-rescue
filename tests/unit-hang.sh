#!/usr/bin/env bash
# Unit-Test: Modus hängende Disk (#54, rescue/lib/hang.sh und rescue/bin/lf-rescue-run).
#
# Teil 1 prüft die Hilfen: Mapfile lesen, ohne Text daraus als Rechenausdruck auszuwerten,
# dieselbe Disk wiederfinden (Seriennummer/WWN und Größe, nur eindeutig), Timeouts setzen.
# Teil 2 lässt lf-rescue-run mit dem echten ddrescue laufen. Die Quelle ist eine Datei, ihre
# Fehlerstellen kommen aus dem Testmodus von ddrescue (--test-mode). Ein Lesefehler dauert dort
# 1 s, so gibt ddrescue mit -T auf wie bei einer hängenden Disk. lsblk, blockdev, findmnt,
# smartctl und sleep sind Attrappen: Mit ihnen verschwindet die Disk und kehrt zurück.
# Ohne root und ohne Disks.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC1091
. rescue/lib/casefile.sh
# shellcheck disable=SC1091
. rescue/lib/hang.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# ---------------------------------------------------------------------------
# Teil 1: Hilfen
# ---------------------------------------------------------------------------
echo "Falldatei:"
check "HANG_TIMEOUT 3 bis 120" 'casefile_value_ok HANG_TIMEOUT 3 && casefile_value_ok HANG_TIMEOUT 120 && ! casefile_value_ok HANG_TIMEOUT 2 && ! casefile_value_ok HANG_TIMEOUT 121 && ! casefile_value_ok HANG_TIMEOUT 05'
check "HANG_SKIP nur positive MiB" 'casefile_value_ok HANG_SKIP 64 && ! casefile_value_ok HANG_SKIP 0 && ! casefile_value_ok HANG_SKIP 123456'
check "HANG_STEP nur bekannte Schritte" 'casefile_value_ok HANG_STEP 0m && casefile_value_ok HANG_STEP 3 && ! casefile_value_ok HANG_STEP 4 && ! casefile_value_ok HANG_STEP "1 2"'
check "HANG_POS nur Ziffern" 'casefile_value_ok HANG_POS 0 && ! casefile_value_ok HANG_POS 0x10 && ! casefile_value_ok HANG_POS "a[1]"'
casefile_create "$T/u.env" "SRC_ID=X1" "SRC_SIZE=10" "STATE=new" "HANG_STEP=1" "HANG_POS=5"
casefile_unset "$T/u.env" HANG_STEP
check "casefile_unset entfernt den Schlüssel aus der Datei" '[[ -z $(casefile_peek "$T/u.env" HANG_STEP) && $(casefile_peek "$T/u.env" HANG_POS) == 5 ]]'
check "casefile_unset lehnt unbekannte Schlüssel ab" '! casefile_unset "$T/u.env" "X]"'

echo "Mapfile:"
printf '# Mapfile\n# Command line: ddrescue\n0x00A00000     ?               1\n0x00000000  0x00800000  +\n0x00800000  0x00200000  -\n0x00A00000  0x00100000  +\n' >"$T/gut.map"
check "aktuelle Position" '[[ $(hang_map_pos "$T/gut.map") == 10485760 ]]'
check "gerettete Bytes" '[[ $(hang_map_rescued "$T/gut.map") == $((9 * 1024 * 1024)) ]]'
printf '%s\n' 'a[$(touch '"$T"'/eingeschleust)]  ?  1' '0x0 a[$(touch '"$T"'/eingeschleust2)] +' >"$T/boese.map"
check "keine Rechenausdrücke aus der Mapfile" '! hang_map_pos "$T/boese.map" && [[ $(hang_map_rescued "$T/boese.map") == 0 && ! -e $T/eingeschleust && ! -e $T/eingeschleust2 ]]'
ln -s "$T/gut.map" "$T/link.map"
check "keine Verknüpfung als Mapfile" '! hang_map_pos "$T/link.map" && [[ $(hang_map_rescued "$T/link.map") == 0 ]]'
check "fehlende Mapfile: nichts gerettet" '[[ $(hang_map_rescued "$T/fehlt.map") == 0 ]]'

echo "Dieselbe Disk wiederfinden:"
mkdir -p "$T/a"
# Attrappe für lsblk: Die Disks stehen in $LSBLK_STATE, je Zeile PFAD SERIENNUMMER WWN GRÖSSE
# ("-" für leer). Mit -J als JSON, sonst die Pfade. Ein Gerät, das fehlt: Rückgabe 32.
cat >"$T/a/lsblk" <<'EOF'
#!/bin/bash
last=${!#}
if [[ " $* " == *" PKNAME "* ]]; then
	[[ $last == /dev/sdt1 ]] && echo sdt
	exit 0
fi
sel=()
while read -r p s w z; do
	[[ -n $p ]] || continue
	[[ $last == /dev/* && $p != "$last" ]] && continue
	sel+=("$p|$s|$w|$z")
done <"$LSBLK_STATE"
if [[ $last == /dev/* && ${#sel[@]} == 0 ]]; then
	echo "lsblk: $last: not a block device" >&2
	exit 32
fi
if [[ " $* " == *" -J "* ]]; then
	out=""
	for d in "${sel[@]}"; do
		IFS='|' read -r p s w z <<<"$d"
		[[ $s == - ]] && s=""
		if [[ $w == - ]]; then w=null; else w="\"$w\""; fi
		out+="${out:+,}{\"path\":\"$p\",\"serial\":\" $s \",\"wwn\":$w,\"size\":$z,\"type\":\"disk\"}"
	done
	echo "{\"blockdevices\":[$out]}"
else
	for d in "${sel[@]}"; do echo "${d%%|*}"; done
fi
EOF
chmod +x "$T/a/lsblk"
export LSBLK_STATE=$T/disks
find_in() {
	printf '%s\n' "$@" >"$LSBLK_STATE"
	FOUND=$(PATH="$T/a:$PATH" hang_find "$SER" "$WWN" "$SIZE")
	FRC=$?
}
SER=S-1 WWN=0x5000aaaa SIZE=1000
find_in "/dev/sdx S-1 0x5000aaaa 1000" "/dev/sdy S-2 0x5000bbbb 1000"
check "genau eine passende Disk (Leerzeichen um die Seriennummer zählen nicht)" '[[ $FRC == 0 && $FOUND == /dev/sdx ]]'
find_in "/dev/sdx S-1 0x5000aaaa 1001"
check "andere Größe: nicht dieselbe Disk" '[[ $FRC == 1 && -z $FOUND ]]'
find_in "/dev/sdx S-1 0x5000cccc 1000"
check "gleiche Seriennummer, anderer WWN: nicht dieselbe Disk" '[[ $FRC == 1 ]]'
find_in "/dev/sdx S-1 0x5000aaaa 1000" "/dev/sdz S-1 0x5000aaaa 1000"
check "zwei gleiche Disks: keine wird angenommen" '[[ $FRC == 2 && -z $FOUND ]]'
SER="" WWN=0x5000aaaa
find_in "/dev/sdq - 0x5000aaaa 1000"
check "nur WWN bekannt: WWN und Größe genügen" '[[ $FRC == 0 && $FOUND == /dev/sdq ]]'
SER="" WWN=""
find_in "/dev/sdq - - 1000"
check "ohne Seriennummer und WWN: keine Suche, die Größe allein reicht nicht" '[[ $FRC == 1 ]]'

echo "Timeouts:"
mkdir -p "$T/sys/block/sdx/device" "$T/sys/block/nvme0n1"
: >"$T/sys/block/sdx/device/timeout"
: >"$T/sys/block/sdx/device/eh_timeout"
check "Timeout und Fehlerbehandlung gesetzt" 'HANG_SYS=$T/sys hang_set_timeout /dev/sdx 5 && [[ $(<"$T/sys/block/sdx/device/timeout") == 5 && $(<"$T/sys/block/sdx/device/eh_timeout") == 5 ]]'
check "ohne einstellbaren Timeout: Rückgabe 1" '! HANG_SYS=$T/sys hang_set_timeout /dev/nvme0n1 5'
check "kein Gerätename wie .." '! HANG_SYS=$T/sys hang_set_timeout "/dev/.." 5'
check "ddrescue -T: Phasen 0 bis 2 viermal der Timeout, mindestens 12 s" '[[ $(hang_ddrescue_timeout 1 5) == 20s && $(hang_ddrescue_timeout 0m 3) == 12s ]]'
check "ddrescue -T: Phase 3 mit Wiederholungen länger, mindestens 120 s" '[[ $(hang_ddrescue_timeout 3 5) == 120s && $(hang_ddrescue_timeout 3 10) == 200s ]]'

# ---------------------------------------------------------------------------
# Teil 2: lf-rescue-run mit dem echten ddrescue
# ---------------------------------------------------------------------------
REAL_DDRESCUE=$(command -v ddrescue)
if [[ -z $REAL_DDRESCUE ]]; then
	echo "  FAIL ddrescue fehlt (Paket gddrescue)"
	exit 1
fi
export REAL_DDRESCUE
MIB=$((1024 * 1024))
SIZE=$((32 * MIB))
head -c "$SIZE" /dev/urandom >"$T/in"
export SRCFILE=$T/in

# Eine Kopie des Skripts, die nur 20 statt 1800 Sekunden auf die Disk wartet. Die Bibliothek
# liegt daneben wie im Repository.
mkdir -p "$T/x/bin"
ln -s "$PWD/rescue/lib" "$T/x/lib"
sed 's/^HANG_WAIT=1800$/HANG_WAIT=20/' rescue/bin/lf-rescue-run >"$T/x/bin/lf-rescue-run"
check "die Kopie unterscheidet sich nur in der Wartezeit" '[[ $(diff rescue/bin/lf-rescue-run "$T/x/bin/lf-rescue-run" | grep -c "^[<>]") == 2 ]]'

# ddrescue: Aufruf mitschreiben, dann das echte ddrescue im Testmodus. Die Quelle (/dev/sd*)
# ist die Datei $SRCFILE, Fehlerstellen stehen in $TESTMAP. -T wird auf 1 s verkürzt, -d
# (Direktzugriff) entfällt, tmpfs kann ihn nicht.
cat >"$T/a/ddrescue" <<'EOF'
#!/bin/bash
echo "$*" >>"$DDRESCUE_CALLS"
args=()
while (($#)); do
	case $1 in
	-T) args+=(-T 1s); shift 2; continue ;;
	-d) shift; continue ;;
	/dev/*) args+=("$SRCFILE"); shift; continue ;;
	esac
	args+=("$1")
	shift
done
exec "$REAL_DDRESCUE" -q --pause-on-error=1 --test-mode="$TESTMAP" "${args[@]}"
EOF
# sleep: zählt mit und ruft $SLEEP_HOOK mit der Nummer des Aufrufs.
cat >"$T/a/sleep" <<'EOF'
#!/bin/bash
n=$(($(cat "$SLEEP_COUNT" 2>/dev/null || echo 0) + 1))
echo "$n" >"$SLEEP_COUNT"
[[ -x $SLEEP_HOOK ]] && "$SLEEP_HOOK" "$n"
exit 0
EOF
printf '#!/bin/sh\necho "$*" >>"$BLOCKDEV_LOG"\n' >"$T/a/blockdev"
printf '#!/bin/sh\ncase "$*" in *FSTYPE*) echo ext4 ;; *SOURCE*) echo /dev/sdt1 ;; esac\n' >"$T/a/findmnt"
for tool in smartctl ddrescuelog; do printf '#!/bin/sh\nexit 0\n' >"$T/a/$tool"; done
chmod +x "$T/a"/*

# testmap NAME VON BIS   Testmodus-Mapfile: alles lesbar außer [VON, BIS) MiB. Ohne VON: alles lesbar.
testmap() {
	local f=$T/$1.tm
	if (($# == 1)); then
		printf '0x00000000 +\n0x00000000 0x%08X +\n' "$SIZE" >"$f"
	else
		printf '0x00000000 +\n0x00000000 0x%08X +\n0x%08X 0x%08X -\n0x%08X 0x%08X +\n' \
			$(($2 * MIB)) $(($2 * MIB)) $((($3 - $2) * MIB)) $(($3 * MIB)) $((SIZE - $3 * MIB)) >"$f"
	fi
}
testmap ganz
mkdir -p "$T/sys/block/sdz/device"
: >"$T/sys/block/sdz/device/timeout"

# fall NAME KENNUNG [SCHLÜSSEL=WERT …]   Neuer Rettungsfall für die Quelle (32 MiB).
fall() {
	local name=$1 id=$2
	shift 2
	rm -rf "${T:?}/$name"
	mkdir -p "$T/$name"
	casefile_create "$T/$name/case.env" "SRC_ID=$id" "SRC_SIZE=$SIZE" "SRC_LABEL=Testdisk" "STATE=new" "$@"
}
# rescue NAME QUELLE   Startet die Kopie des Skripts. Ergebnis: RC, OUT, READ (ddrescue-Aufrufe).
rescue() {
	: >"$T/aufrufe"
	: >"$T/blockdev.log"
	rm -f "$T/sleeps"
	OUT=$(PATH="$T/a:$PATH" TMPDIR=$T HANG_SYS=$T/sys DDRESCUE_CALLS=$T/aufrufe BLOCKDEV_LOG=$T/blockdev.log \
		SLEEP_COUNT=$T/sleeps SLEEP_HOOK=$T/hook timeout 120 bash "$T/x/bin/lf-rescue-run" "$T/$1" "$2" --no-pause 2>&1 </dev/null)
	RC=$?
	READ=$(cat "$T/aufrufe")
	SLEEPS=$(cat "$T/sleeps" 2>/dev/null || echo 0)
}
field() { casefile_peek "$T/$1/case.env" "$2"; }
same_image() { cmp -s "$T/in" "$T/$1/image.img"; }
disks() { printf '%s\n' "$@" >"$LSBLK_STATE"; }
QUELLE="/dev/sdx S-1 0x5000aaaa $SIZE"
ZIEL="/dev/sdt Z-9 0x5000ffff 4000000000"

echo "Ohne den Modus wie bisher:"
disks "$QUELLE" "$ZIEL"
export TESTMAP=$T/ganz.tm
rm -f "$T/hook"
fall normal S-1
rescue normal /dev/sdx
check "drei Phasen ohne -T, Image vollständig" '[[ $RC == 0 && $(grep -c . <<<"$READ") == 3 && $READ != *"-T"* ]] && same_image normal'

echo "Hänger, die Disk antwortet weiter: sofort hinter der Hängerstelle weiter:"
testmap loch 8 10
export TESTMAP=$T/loch.tm
fall weiter S-1 HANG_TIMEOUT=3 HANG_SKIP=4
rescue weiter /dev/sdx
first=$(sed -n 1p <<<"$READ")
second=$(sed -n 2p <<<"$READ")
check "Phase 1 mit -T aus dem Timeout (4 × 3 s = 12 s)" '[[ $first == "-S -T 12s -n /dev/sdx "* ]]'
check "Timeout der Quelle gesetzt" '[[ $(<"$T/sys/block/sdx/device/timeout") == 3 ]]'
pos=$(grep -o -- '-i [0-9]*' <<<"$second" | cut -d" " -f2)
check "nach dem Hänger: weiter 4 MiB hinter der Hängerstelle, nicht vor der Fehlerstelle" '[[ -n $pos ]] && ((pos >= 12 * MIB && pos <= 14 * MIB + MIB))'
check "Phase 2 rückwärts mit Versatz (-s) nach dem Hänger dort" 'grep -q -- "-n -R -s [0-9]* /dev/sdx" <<<"$READ"'
check "Phase 3 mit längerem -T (120 s)" 'grep -q -- "-T 120s -d -r3 /dev/sdx" <<<"$READ"'
# Die Fehlerstelle bleibt: In Phase 3 kommt kein Lesen mehr durch, erst dort bittet der Lauf
# um einen Neustart und wartet. Die Disk kommt nicht zurück, der Lauf endet unterbrochen.
check "Phasen 1 und 2 ohne Warten fertig, erst in Phase 3 um einen Neustart gebeten" '[[ $(field weiter PHASE_DONE) == 2 && $(field weiter HANG_STEP) == 3 && $(grep -c "Bitte neu starten" <<<"$OUT") == 1 ]]'
check "danach unterbrochen, Hänger gezählt" '[[ $RC == 1 && $(field weiter STATE) == interrupted && $(field weiter HANGS) -ge 3 ]]'

echo "Hänger, die Disk verschwindet und kehrt als /dev/sdz zurück:"
# Der Hook ist das Kabel: Beim ersten Warten ist die Disk weg, beim dritten wieder da, unter
# neuem Namen und jetzt ohne Fehlerstelle (der Controller arbeitet nach dem Neustart wieder).
cat >"$T/hook" <<EOF
#!/bin/bash
case \$1 in
1) printf '%s\n' "$ZIEL" >"\$LSBLK_STATE" ;;
3) printf '%s\n' "$ZIEL" "/dev/sdz S-1 0x5000aaaa $SIZE" >"\$LSBLK_STATE"; cp "$T/ganz.tm" "$T/aktuell.tm" ;;
esac
EOF
chmod +x "$T/hook"
# Am Anfang hängt die Disk sofort: kein erfolgreiches Lesen, also kein Weiterlesen ohne Neustart.
testmap anfang 0 2
cp "$T/anfang.tm" "$T/aktuell.tm"
export TESTMAP=$T/aktuell.tm
disks "$QUELLE" "$ZIEL"
fall zurueck S-1 HANG_TIMEOUT=3 HANG_SKIP=4
rescue zurueck /dev/sdx
check "gewartet, bis die Disk wieder da war" '((SLEEPS >= 3)) && [[ $OUT == *"Bitte neu starten"* && $OUT == *"wieder da: /dev/sdz"* ]]'
check "danach nur von /dev/sdz gelesen, ab 4 MiB hinter der Hängerstelle" '[[ $(sed -n 2p <<<"$READ") == *"-i "*" /dev/sdz "* && $(sed -n "2,\$p" <<<"$READ") != *"/dev/sdx"* ]]'
check "/dev/sdz schreibgeschützt, Timeout gesetzt, Pfad in der Falldatei" 'grep -qx -- "--setro /dev/sdz" "$T/blockdev.log" && [[ $(<"$T/sys/block/sdz/device/timeout") == 3 && $(field zurueck SRC_PATH) == /dev/sdz ]]'
check "fertig, die Lücke ist nachgeholt, Image gleich der Quelle" '[[ $RC == 0 && $(field zurueck STATE) == done && $(field zurueck HANGS) == 1 && -z $(field zurueck HANG_STEP) ]] && same_image zurueck'
check "der Bericht nennt die Hänger" 'grep -q "^Hänger:      1" "$T/zurueck/report.txt"'

echo "Zurück kommt eine Disk, die nicht eindeutig dieselbe ist:"
for variante in zwei groesse ziel; do
	case $variante in
	zwei) neu="/dev/sdz S-1 0x5000aaaa $SIZE\n/dev/sdq S-1 0x5000aaaa $SIZE" text="zwei Disks mit derselben Kennung" ;;
	groesse) neu="/dev/sdz S-1 0x5000aaaa $((SIZE + 512))" text="dieselbe Kennung, andere Größe" ;;
	ziel) neu="/dev/sdt S-1 0x5000aaaa $SIZE" text="die Ziel-Disk meldet die Kennung der Quelle" ;;
	esac
	cat >"$T/hook" <<EOF
#!/bin/bash
case \$1 in
1) printf '%s\n' "$ZIEL" >"\$LSBLK_STATE" ;;
2) printf '$neu\n' >"\$LSBLK_STATE" ;;
esac
EOF
	cp "$T/anfang.tm" "$T/aktuell.tm"
	disks "$QUELLE" "$ZIEL"
	fall "fremd-$variante" S-1 HANG_TIMEOUT=3
	rescue "fremd-$variante" /dev/sdx
	check "$text: nicht angenommen, nach der Wartezeit unterbrochen" '[[ $RC == 1 && $(field "fremd-$variante" STATE) == interrupted && $SLEEPS == 20 && $(grep -c . <<<"$READ") == 1 && $OUT == *"nicht wieder erschienen"* ]]'
	check "$text: nichts schreibgeschützt außer der Quelle" '! grep -v -- "--setro /dev/sdx" "$T/blockdev.log" | grep -q .'
done

echo "Fall nur mit Gerätepfad: kein Warten, Fortsetzen hinter der Hängerstelle:"
rm -f "$T/hook"
cp "$T/loch.tm" "$T/aktuell.tm"
disks "$QUELLE" "$ZIEL"
fall pfad /dev/sdx HANG_TIMEOUT=3 HANG_SKIP=4
rescue pfad /dev/sdx
check "nach dem Hänger unterbrochen, Schritt und Position vermerkt, nicht gewartet" '[[ $RC == 1 && $(field pfad STATE) == interrupted && $(field pfad HANG_STEP) == 1 && -n $(field pfad HANG_POS) && $SLEEPS == 0 && $OUT == *"Unterbrochene Rettung fortsetzen"* ]]'
hp=$(field pfad HANG_POS)
cp "$T/ganz.tm" "$T/aktuell.tm"
rescue pfad /dev/sdx
check "Fortsetzen beginnt 4 MiB hinter der Hängerstelle" '[[ $(sed -n 1p <<<"$READ") == *"-i $((hp + 4 * MIB)) /dev/sdx "* ]]'
check "die späteren Phasen holen die Lücke nach, Image gleich der Quelle" '[[ $RC == 0 && $(field pfad STATE) == done ]] && same_image pfad'

echo "Zu viele Hänger:"
cp "$T/anfang.tm" "$T/aktuell.tm"
fall viele S-1 HANG_TIMEOUT=3 HANGS=99
rescue viele /dev/sdx
check "beim 100. Hänger endet der Lauf, der Techniker entscheidet" '[[ $RC == 1 && $(field viele STATE) == interrupted && $(field viele HANGS) == 100 && $SLEEPS == 0 && $OUT == *"entscheidet der Techniker"* ]]'

echo
if ((fails)); then
	echo "$fails Test(s) fehlgeschlagen."
	exit 1
fi
echo "Alle Tests bestanden."
