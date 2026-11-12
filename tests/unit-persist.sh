#!/usr/bin/env bash
# Unit-Test: Der persistente Speicher kommt nur vom eigenen Stick und nie ungefragt.
#
# Wer den Speicher stellt, bestimmt die Sitzung: Aus ihm kommen Programme (~/.local/bin), Regeln
# und Einstellungen für Claude, SSH-Schlüssel und WLAN-Profile. Bisher galt jede Partition mit dem
# Namen FRS-DATA als eigener Speicher, auf welcher Disk auch immer. War sie unverschlüsselt, wurde
# sie ohne Rückfrage eingehängt und ihre frs.conf als Shell-Code gelesen. Der Test prüft:
#   - der Boot-Stick ist das eingehängte Live-Medium, nicht irgendeine Disk mit dem Label der ISO,
#   - der Speicher ist nur die Partition FRS-DATA auf diesem Stick,
#   - ein unverschlüsselter Speicher wird nie ohne Rückfrage eingebunden,
#   - frs.conf wird als Daten gelesen: Nichts daraus wird ausgeführt.
# Ohne root und ohne Disks: lsblk, blkid, findmnt, sudo und die Dialoge sind Attrappen.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/disks.sh
# shellcheck disable=SC1091
. rescue/lib/persist.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
markers() { compgen -G "$T/MARKE-*" >/dev/null; }

FRS_RUN="$T/run"
FRS_PERSIST="$T/persist"
FRS_LOG=/dev/null
HOME="$T/home"
PERSIST_CONFIG="$T/etc-frs/frs.conf"
PERSIST_MAPPER_DEV="$T/mapper-frs-data"
mkdir -p "$FRS_RUN" "$HOME" "$T/etc-frs"

# ---------------------------------------------------------------------------
# Die gedachte Maschine. Jede Variable beschreibt, was ein Werkzeug meldet.
#   CDROM         Quelle von /cdrom laut findmnt
#   BLOCKDEVS     Pfade, die Blockgeräte sind
#   ISO_LABEL     Geräte mit dem Label FRS_RESCUE laut blkid, in dieser Reihenfolge
#   PARTS         Zeilen "PFAD DISK PARTLABEL LABEL TYP": Partitionen und ihr Inhalt laut blkid
# ---------------------------------------------------------------------------
findmnt() { [[ -n $CDROM ]] && echo "$CDROM"; }
is_blockdev() { [[ " $BLOCKDEVS " == *" $1 "* ]]; }
# blkid -t NAME=WERT -o device: alle Geräte mit diesem Merkmal, wie das echte blkid ohne
# Rücksicht darauf, auf welcher Disk sie liegen.
blkid() {
	local d path disk partlabel label type
	case "$*" in
	*LABEL=FRS_RESCUE*) for d in $ISO_LABEL; do echo "$d"; done ;;
	*PARTLABEL=FRS-DATA*)
		while read -r path disk partlabel label type; do
			[[ $partlabel == FRS-DATA ]] && echo "$path"
		done <<<"$PARTS"
		;;
	*LABEL=FRS-DATA*)
		while read -r path disk partlabel label type; do
			[[ $label == FRS-DATA ]] && echo "$path"
		done <<<"$PARTS"
		;;
	esac
	return 0
}
# Eltern-Disk eines Geräts: bei sdb1 ist das sdb, bei einer ganzen Disk nichts.
parent() {
	case $1 in
	/dev/sr0 | /dev/sda | /dev/sdb | /dev/sdc) ;;
	*) sed -E 's|^/dev/([a-z]+)[0-9]+$|\1|' <<<"$1" ;;
	esac
}
lsblk() {
	local last path disk partlabel label type
	for last; do :; done
	case "$*" in
	"-no PKNAME "*) parent "$last" ;;
	"-J -o PATH,PARTLABEL,LABEL "*)
		while read -r path disk partlabel label type; do
			[[ $disk == "$last" ]] || continue
			jq -cn --arg p "$path" --arg pl "${partlabel#-}" --arg l "${label#-}" '{path: $p, partlabel: $pl, label: $l}'
		done <<<"$PARTS" | jq -cs '{blockdevices: [{children: .}]}'
		;;
	"-J -o PATH,PKNAME,TYPE,PARTLABEL,LABEL")
		while read -r path disk partlabel label type; do
			[[ -n $path ]] || continue
			jq -cn --arg p "$path" --arg d "${disk#/dev/}" --arg pl "${partlabel#-}" --arg l "${label#-}" \
				'{path: $p, pkname: $d, type: "part", partlabel: $pl, label: $l}'
		done <<<"$PARTS" | jq -cs '{blockdevices: [{type: "disk", children: .}]}'
		;;
	esac
}
sudo() {
	local path disk partlabel label type
	printf '%s\n' "$*" >>"$T/sudo"
	case "$*" in
	"blkid -o value -s TYPE "*)
		while read -r path disk partlabel label type; do
			[[ $path == "$6" ]] && echo "$type"
		done <<<"$PARTS"
		;;
	"cryptsetup open "*) : >"$PERSIST_MAPPER_DEV" ;;
	esac
	return 0
}
mountpoint() { return 1; }
log() { printf '%s\n' "$*" >>"$T/log"; }
run() { "$@"; }
log_init() { :; }
human() { echo "1GiB"; }
ui_msg() { printf '%s|%s\n' "$1" "$2" >>"$T/msg"; }
ui_yesno() {
	printf '%s|%s\n' "$1" "$2" >>"$T/yesno"
	return "$YESNO_RC"
}
ui_password() {
	echo x >>"$T/password"
	[[ -n $PASSPHRASE ]] || return 1
	echo "$PASSPHRASE"
}

# fresh   Vergisst, was frühere Aufrufe hinterlassen haben.
fresh() {
	rm -f "$T/sudo" "$T/log" "$T/msg" "$T/yesno" "$T/password" "$T/bind" "$PERSIST_MAPPER_DEV"
	rm -f "$FRS_RUN"/persist-*
}
# Ergebnis des letzten Aufrufs: SUDO (Aufrufe hinter sudo), MSG, YESNO, BIND.
result() {
	SUDO=$(cat "$T/sudo" 2>/dev/null)
	MSG=$(cat "$T/msg" 2>/dev/null)
	YESNO=$(cat "$T/yesno" 2>/dev/null)
	BIND=$(cat "$T/bind" 2>/dev/null)
}
YESNO_RC=1 PASSPHRASE=""

# Normalfall: gestartet vom Stick sdb. Dort liegt der eigene, verschlüsselte Speicher sdb3.
# Die interne Disk sda des Kundenrechners trägt eine unverschlüsselte Partition gleichen Namens
# und zusätzlich eine mit dem Label der ISO. blkid nennt sda vor sdb.
normal() {
	CDROM=/dev/sdb1
	BLOCKDEVS="/dev/sdb1 /dev/sdb /dev/sr0"
	ISO_LABEL="/dev/sda2 /dev/sdb /dev/sdb1"
	PARTS="/dev/sda2 /dev/sda - FRS_RESCUE iso9660
/dev/sda9 /dev/sda FRS-DATA FRS-DATA ext4
/dev/sdb1 /dev/sdb - FRS_RESCUE iso9660
/dev/sdb3 /dev/sdb FRS-DATA FRS-DATA crypto_LUKS"
}

# ---------------------------------------------------------------------------
echo "Boot-Stick:"
normal
check "das eingehängte Live-Medium zählt, nicht die erste Disk mit dem Label" '[[ $(boot_disk) == /dev/sdb ]]'
CDROM=/dev/sr0
check "Start von CD: das Laufwerk selbst" '[[ $(boot_disk) == /dev/sr0 ]]'
CDROM=/dev/shm ISO_LABEL="/dev/sdb /dev/sdb1"
check "in den RAM geladen, eine Disk mit dem Label: diese Disk" '[[ $(boot_disk) == /dev/sdb ]]'
ISO_LABEL="/dev/sda2 /dev/sdb /dev/sdb1"
check "in den RAM geladen, zwei Disks mit dem Label: kein Boot-Stick" '! boot_disk >/dev/null && [[ -z $(boot_disk) ]]'
CDROM="" ISO_LABEL=""
check "kein Live-Medium, kein Label: kein Boot-Stick" '! boot_disk >/dev/null'

# ---------------------------------------------------------------------------
echo "Welche Partition ist der eigene Speicher:"
normal
check "FRS-DATA auf dem Stick, nicht die gleichnamige auf der internen Disk" '[[ $(persist_find) == /dev/sdb3 ]]'
check "die fremde Partition wird als fremd erkannt" '[[ $(persist_foreign) == /dev/sda9 ]]'
PARTS="/dev/sda9 /dev/sda FRS-DATA FRS-DATA ext4
/dev/sdb1 /dev/sdb - FRS_RESCUE iso9660"
check "nur auf der fremden Disk: kein eigener Speicher" '! persist_find >/dev/null && [[ -z $(persist_find) ]]'
PARTS="/dev/sdb1 /dev/sdb - FRS_RESCUE iso9660
/dev/sdb3 /dev/sdb FRS-DATA FRS-DATA ext4
/dev/sdb4 /dev/sdb FRS-DATA - ext4"
check "zwei Partitionen mit dem Namen auf dem Stick: kein eigener Speicher" '[[ -z $(persist_find) ]]'
PARTS="/dev/sdb1 /dev/sdb - FRS_RESCUE iso9660
/dev/sdb3 /dev/sdb - FRS-DATA ext4"
check "nur das Dateisystem trägt den Namen: gilt auf dem Stick auch" '[[ $(persist_find) == /dev/sdb3 ]]'
normal
CDROM=/dev/shm
check "Boot-Stick nicht sicher erkennbar: kein eigener Speicher" '[[ -z $(persist_find) ]]'
check "dann gelten alle gleichnamigen Partitionen als fremd" '[[ $(persist_foreign | tr "\n" " ") == "/dev/sda9 /dev/sdb3 " ]]'

# ---------------------------------------------------------------------------
# Ab hier zählt, ob eingebunden wird. persist_bind wird dafür nur mitgeschrieben.
persist_bind() { echo bind >>"$T/bind"; }

echo "Angriff: nur die fremde Disk trägt eine unverschlüsselte Partition FRS-DATA:"
normal
PARTS="/dev/sda9 /dev/sda FRS-DATA FRS-DATA ext4
/dev/sdb1 /dev/sdb - FRS_RESCUE iso9660"
# Auf dem Stick ist kein Platz für einen neuen Speicher, es folgt also kein Angebot zum Anlegen.
persist_free_bytes() { echo 0; }
fresh
YESNO_RC=0
persist_startup
result
check "nichts wird eingehängt" '[[ $SUDO != *mount* ]]'
check "nichts wird eingebunden" '[[ -z $BIND ]]'
check "keine Frage, die sich mit Ja beantworten ließe" '[[ -z $YESNO ]]'
check "der Techniker erfährt von der fremden Partition" '[[ $MSG == "Persistenter Speicher|"*"/dev/sda9"*"wird nicht verwendet"* ]]'
check "im Protokoll steht, dass sie nicht verwendet wird" '[[ $(cat "$T/log") == *"wird nicht verwendet: /dev/sda9"* ]]'
rm -f "$T/msg"
persist_startup
result
check "der Hinweis kommt je Sitzung nur einmal" '[[ -z $MSG ]]'
fresh
persist_open
rc=$?
result
check "auch \"Entsperren und einhängen\" fasst sie nicht an" '[[ $rc != 0 && $SUDO != *mount* && -z $BIND ]]'

echo "Eigener Speicher, verschlüsselt:"
normal
fresh
PASSPHRASE="geheim" YESNO_RC=1
persist_startup
result
check "die Passphrase wird verlangt, keine Ja-Nein-Frage" '[[ -s $T/password && -z $YESNO ]]'
check "entsperrt wird die Partition auf dem Stick" '[[ $SUDO == *"cryptsetup open --key-file - /dev/sdb3 frs-data"* ]]'
check "eingehängt ohne Gerätedateien und Setuid" '[[ $SUDO == *"mount -o noatime,nodev,nosuid $PERSIST_MAPPER_DEV $FRS_PERSIST"* ]]'
check "eingebunden" '[[ $BIND == bind ]]'
check "die fremde Partition wird trotzdem gemeldet und nie eingehängt" '[[ $MSG == *"/dev/sda9"* && $SUDO != *"/dev/sda9"* ]]'
fresh
PASSPHRASE=""
persist_startup
result
check "Passphrase abgebrochen: nichts eingehängt, nichts eingebunden" '[[ $SUDO != *mount* && -z $BIND ]]'

echo "Eigener Speicher, unverschlüsselt:"
normal
PARTS="/dev/sdb1 /dev/sdb - FRS_RESCUE iso9660
/dev/sdb3 /dev/sdb FRS-DATA FRS-DATA ext4"
fresh
YESNO_RC=1
persist_startup
result
check "Rückfrage, Vorgabe ist Nein" '[[ $YESNO == "Speicher nicht verschlüsselt|"*"/dev/sdb3"* ]]'
check "Nein: nichts eingehängt, nichts eingebunden" '[[ $SUDO != *mount* && -z $BIND ]]'
rm -f "$T/yesno"
persist_startup
result
check "beim nächsten Start des Assistenten keine zweite Frage" '[[ -z $YESNO && -z $BIND ]]'
persist_open
result
check "über das Menü wird wieder gefragt" '[[ $YESNO == "Speicher nicht verschlüsselt|"* ]]'
fresh
YESNO_RC=0
persist_startup
result
check "Ja: eingehängt ohne Gerätedateien und Setuid, eingebunden" '[[ $SUDO == *"mount -o noatime,nodev,nosuid /dev/sdb3 $FRS_PERSIST"* && $BIND == bind ]]'

echo "Anlegen:"
fresh
persist_create
rc=$?
result
check "gibt es auf dem Stick schon einen Speicher, wird kein zweiter angelegt" '[[ $rc != 0 && $SUDO != *sgdisk* && $MSG == *"schon eine Partition"* ]]'

# ---------------------------------------------------------------------------
echo "frs.conf wird gelesen, nicht ausgeführt:"
cat >"$PERSIST_CONFIG" <<EOF
# Eigene Einstellungen
FRS_TECHNIKER="Tim Beispiel"

  FRS_TARGET_FS=exfat
touch $T/MARKE-zeile
FRS_SSH_AUTOSTART=\$(touch $T/MARKE-ersetzung)
PATH=$T/fremd:/usr/bin
FRS_TECHNIKER="a"; touch $T/MARKE-semikolon
export FRS_TARGET_FS=ext4
FRS_TECHNIKER=\`touch $T/MARKE-backtick\`
FRS_TARGET_FS=ntfs
FRS_SSH_AUTOSTART=1 # ein
. $T/fremd.sh
EOF
echo "touch $T/MARKE-eingebunden" >"$T/fremd.sh"
old_path=$PATH
unset FRS_TECHNIKER FRS_TARGET_FS FRS_SSH_AUTOSTART
persist_config_load "$PERSIST_CONFIG"
rc=$?
check "gelesen" '[[ $rc == 0 ]]'
check "gültige Zeilen setzen ihre Einstellung" '[[ ${FRS_TECHNIKER:-} == "Tim Beispiel" && ${FRS_TARGET_FS:-} == exfat ]]'
check "ungültige Werte setzen nichts" '[[ -z ${FRS_SSH_AUTOSTART:-} ]]'
check "jede andere Zeile ist als nicht übernommen vermerkt" '[[ ${PERSIST_CONFIG_REJECTED-} == " 5 6 7 8 9 10 11 12 13" ]]'
check "PATH bleibt, wie er war" '[[ $PATH == "$old_path" ]]'
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# Dasselbe über das echte persist_bind: Dort wurde die Datei bisher per "." eingelesen.
# shellcheck disable=SC1091
. rescue/lib/persist.sh
PERSIST_CONFIG="$T/etc-frs/frs.conf"
fresh
unset FRS_TECHNIKER FRS_TARGET_FS FRS_SSH_AUTOSTART
persist_bind
result
check "persist_bind: Einstellungen übernommen" '[[ ${FRS_TECHNIKER:-} == "Tim Beispiel" && ${FRS_TARGET_FS:-} == exfat ]]'
check "persist_bind: nichts ausgeführt" '! markers && [[ $PATH == "$old_path" ]]'
check "persist_bind: der Techniker erfährt, welche Zeilen nicht übernommen wurden" '[[ $MSG == "frs.conf|"*"nicht übernommen: 5 6 7 8 9 10 11 12 13"* ]]'
rm -f "$PERSIST_CONFIG"
fresh
persist_bind
result
check "fehlt die Datei, legt persist_bind die Vorlage an, und sie ist gültig" '[[ -s $PERSIST_CONFIG && -z $MSG ]] && persist_config_load "$PERSIST_CONFIG" && [[ -z ${PERSIST_CONFIG_REJECTED-} ]]'
printf 'FRS_TARGET_FS=ext4\r\nFRS_SSH_AUTOSTART="1"\r\n' >"$PERSIST_CONFIG"
unset FRS_TARGET_FS FRS_SSH_AUTOSTART
persist_config_load "$PERSIST_CONFIG"
check "Zeilenenden von Windows, Wert mit und ohne Anführungszeichen" '[[ ${FRS_TARGET_FS:-} == ext4 && ${FRS_SSH_AUTOSTART:-} == 1 && -z $PERSIST_CONFIG_REJECTED ]]'
rm -f "$PERSIST_CONFIG"
echo 'FRS_TARGET_FS=exfat' >"$T/woanders.conf"
ln -s "$T/woanders.conf" "$PERSIST_CONFIG"
unset FRS_TARGET_FS
persist_config_load "$PERSIST_CONFIG"
rc=$?
check "eine Verknüpfung an Stelle der Datei wird nicht gelesen" '[[ $rc != 0 && -z ${FRS_TARGET_FS:-} ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
