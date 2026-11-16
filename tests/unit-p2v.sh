#!/usr/bin/env bash
# Unit-Test: Umzug in eine Proxmox-VM (rescue/lib/p2v.sh) gegen die Attrappe eines Knotens.
#
# Der P2V-Assistent schickt Befehle als root an einen Proxmox-Knoten und liest dessen Antworten.
# Werte stammen vom Techniker, vom Knoten und vom Quellrechner (DMI). Der Test prüft:
#   - jeder Wert muss seinem Muster entsprechen, bevor er in einen Befehl kommt,
#   - auf dem Knoten kommt genau die Argumentliste an, nichts davon wird zu Shell-Code,
#   - Antworten des Knotens, die keinem Muster entsprechen, werden nicht übernommen,
#   - der SSH-Schlüssel gilt erst nach der richtigen Eingabe, eine leere bestätigt nie,
#   - ssh läuft ohne Benutzer-Konfiguration und nur mit dem bestätigten Schlüssel,
#   - der Kopier-Job entsteht nur für schreibgeschützte Quellen und aus geprüften Angaben.
# Ohne root, ohne Netz und ohne Disks: ssh ist eine Attrappe, die den Befehl wie die Shell des
# Knotens auswertet (bash -c), qm, pvesm und pvesh sind Skripte. Den echten sshd, qemu-nbd und
# die Kopie prüft der Selbsttest der ISO (selftest_p2v).
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8
REPO=$PWD

T=$(mktemp -d)
LF_RUN="$T/run"
LF_LOG="$T/log"
LF_VERSION="test"
mkdir -p "$LF_RUN"
# shellcheck disable=SC1091
. rescue/lib/common.sh
LF_RUN="$T/run"
# shellcheck disable=SC1091
. rescue/lib/disks.sh
# shellcheck disable=SC1091
. rescue/lib/safety.sh
# shellcheck disable=SC1091
. rescue/lib/clone.sh
# shellcheck disable=SC1091
. rescue/lib/p2v.sh

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}
markers() { compgen -G "$T/MARKE-*" >/dev/null; }

# ---------------------------------------------------------------------------
# Die Attrappe des Knotens. Jeder Aufruf steht in $K/aufrufe, die Argumente durch | getrennt.
# ---------------------------------------------------------------------------
K="$T/knoten"
mkdir -p "$K/bin" "$K/vms"
cat >"$K/bin/qm" <<EOF
#!/bin/bash
printf '%s|' qm "\$@" >>$K/aufrufe; echo >>$K/aufrufe
[[ \$1 == create ]] && touch $K/vms/\$2
exit 0
EOF
cat >"$K/bin/pvesm" <<EOF
#!/bin/bash
printf '%s|' pvesm "\$@" >>$K/aufrufe; echo >>$K/aufrufe
case \$1 in
status) printf '%s\n' "\$PVESM_STATUS" ;;
alloc) echo "\${PVESM_ALLOC:-successfully created '\$2:\$4'}" ;;
path) echo "\${PVESM_PATH:-/dev/pve/\${2#*:}}" ;;
esac
EOF
cat >"$K/bin/pvesh" <<EOF
#!/bin/bash
case "\$2 \${3:-} \${4:-}" in
"/cluster/nextid --vmid "*) [[ -e $K/vms/\$4 ]] && exit 1; echo \$4 ;;
"/cluster/nextid "*) echo "\${PVESH_NEXTID:-100}" ;;
/nodes/*) echo "\$PVESH_BRIDGES" ;;
/cluster/sdn/*) echo "\${PVESH_VNETS:-[]}" ;;
esac
EOF
printf '#!/bin/sh\necho "${MOCK_UID:-0}"\n' >"$K/bin/id"
printf '#!/bin/sh\necho "${MOCK_HOSTNAME:-pve1}"\n' >"$K/bin/hostname"
printf '#!/bin/sh\necho "pve-manager/9.0.0"\n' >"$K/bin/pveversion"
for t in qemu-nbd mktemp; do printf '#!/bin/sh\nexit 0\n' >"$K/bin/$t"; done
chmod 755 "$K"/bin/*
export PVESM_STATUS PVESH_BRIDGES PVESH_VNETS PVESH_NEXTID PVESM_ALLOC PVESM_PATH MOCK_UID MOCK_HOSTNAME

# ssh: merkt sich die Optionen und wertet den Befehl aus wie die Shell des Knotens.
ssh() {
	local host="" opts=() a
	while (($#)); do
		a=$1
		shift
		case $a in
		-F | -p | -l | -o | -i | -O | -L) opts+=("$a" "$1"); shift ;;
		-f | -N | -fN) opts+=("$a") ;;
		*) host=$a; break ;;
		esac
	done
	printf '%s\n' "${opts[*]}" >>"$T/ssh-opts"
	[[ " ${opts[*]} " == *" -O "* ]] && return 0
	if [[ " ${opts[*]} " == *" -fN "* ]]; then
		[[ -z ${MOCK_LOGIN_FAIL:-} ]]
		return
	fi
	[[ $host == "$P2V_HOST" ]] || return 255
	(($#)) || return 0
	PATH="$K/bin:$PATH" bash -c "$*"
}
sudo() { "$@"; }
blockdev() {
	case $1 in
	--getsize64) echo 34603008 ;;
	--getro) [[ " ${RO_DEVS:-} " == *" $2 "* ]] && echo 1 || echo 0 ;;
	esac
}
ui_msg() { :; }
P2V_HOST=pve.example P2V_PORT=22 P2V_USER=root P2V_HKALG=ssh-ed25519
P2V_NBD=() P2V_PIDS=() P2V_VOLS=() P2V_RDIR=""

# ---------------------------------------------------------------------------
echo "Werte, die in einen Befehl kommen:"
check "Rechnername, IPv4 und IPv6 gelten" 'p2v_ok host pve1.example.org && p2v_ok host 192.0.2.10 && p2v_ok host fd00::10'
check "ein Rechnername mit Shell-Zeichen oder Option gilt nicht" '! p2v_ok host "pve;reboot" && ! p2v_ok host "-oProxyCommand=x" && ! p2v_ok host "a b" && ! p2v_ok host ""'
check "Benutzer: root ja, Shell-Zeichen und Optionen nein" 'p2v_ok user root && ! p2v_ok user "root;id" && ! p2v_ok user -l'
check "Port: 1 bis 65535" 'p2v_ok port 22 && p2v_ok port 65535 && ! p2v_ok port 0 && ! p2v_ok port 65536 && ! p2v_ok port 22x'
check "VM-ID: Zahl ab 100" 'p2v_ok vmid 100 && p2v_ok vmid 123456789 && ! p2v_ok vmid 99 && ! p2v_ok vmid "100;x" && ! p2v_ok vmid 0100'
check "VM-Name: DNS-Name, keine Shell-Zeichen" 'p2v_ok name PC-01.buero && ! p2v_ok name "pc 01" && ! p2v_ok name "x;touch a" && ! p2v_ok name -x && ! p2v_ok name x- && ! p2v_ok name "\$(id)"'
check "VLAN: leer oder 1 bis 4094" 'p2v_ok vlan "" && p2v_ok vlan 4094 && ! p2v_ok vlan 0 && ! p2v_ok vlan 4095 && ! p2v_ok vlan "10,trunks=1"'
check "Bridge: kurzer Name, keine Zeichen für Optionen der Netzkarte" 'p2v_ok bridge vmbr0 && ! p2v_ok bridge "vmbr0,firewall=0" && ! p2v_ok bridge "x;y"'
check "Speicher, Typ, CPU und Betriebssystem nur aus der Liste" 'p2v_ok stor local-lvm && ! p2v_ok stor "a b" && p2v_ok styp lvmthin && ! p2v_ok styp foo && p2v_ok cpu host && ! p2v_ok cpu "host,flags=+x" && p2v_ok ostype win11 && ! p2v_ok ostype win12'
check "Arbeitsspeicher und Kerne: Zahlen in Grenzen" 'p2v_ok mem 4096 && ! p2v_ok mem 128 && ! p2v_ok mem 4G && p2v_ok cores 8 && ! p2v_ok cores 0'
P2V_STOR=local-lvm
check "Volume: nur auf dem gewählten Speicher" 'p2v_ok volid local-lvm:vm-100-disk-0 && ! p2v_ok volid other:vm-100-disk-0 && ! p2v_ok volid "local-lvm:vm 100" && ! p2v_ok volid "local-lvm:../x"'
check "Pfad vom Knoten: ohne Leerzeichen, Anführungszeichen und .." 'p2v_ok path /dev/pve/vm-100-disk-0 && p2v_ok path "rbd:pool/vm-100-disk-0:conf=/etc/pve/ceph.conf" && ! p2v_ok path "/x y" && ! p2v_ok path "/x;y\"" && ! p2v_ok path /dev/../etc/shadow'
check "Socket-Ordner auf dem Knoten: nur das Muster von mktemp" 'p2v_ok rdir /run/lf-p2v.Ab12Cd34 && ! p2v_ok rdir / && ! p2v_ok rdir /run/lf-p2v.x && ! p2v_ok rdir "/run/lf-p2v.Ab12Cd34/../x"'
check "Text vom Quellrechner: nur harmlose Zeichen" '[[ $(p2v_text "Dell Inc. \$(touch x); \`id\` \"a\"") == "Dell Inc. touch x id a" ]]'

# ---------------------------------------------------------------------------
echo "SSH-Schlüssel des Knotens:"
ssh-keygen -q -t ed25519 -N '' -C test -f "$T/hostkey"
ssh-keygen -q -t ed25519 -N '' -C test -f "$T/anderer"
ssh-keyscan() {
	local t=""
	while (($#)); do [[ $1 == -t ]] && t=$2; shift; done
	[[ $t == ed25519 ]] && echo "pve.example $(cut -d' ' -f1,2 "$T/hostkey.pub")"
	[[ $t == rsa ]] && echo "pve.example ssh-rsa A;B"
	return 0
}
want=$(ssh-keygen -l -E sha256 -f "$T/hostkey.pub" | awk '{print $2}')
p2v_hostkey_scan
check "ed25519 wird genommen, der Fingerabdruck ist der des Schlüssels" '[[ $P2V_HKTYPE == ed25519 && $P2V_HKALG == ssh-ed25519 && $P2V_FP == "$want" ]]'
check "leere Eingabe bestätigt nie" '! p2v_hostkey_accept "" && ! p2v_hostkey_accept "   " && [[ ! -e $P2V_DIR/known_hosts ]]'
check "falsche Eingabe bestätigt nicht" '! p2v_hostkey_accept "abcd" && [[ ! -e $P2V_DIR/known_hosts ]]'
other=$(tr 'A-Za-z' 'a-zA-Z' <<<"${P2V_FP: -4}")
[[ $other == "${P2V_FP: -4}" ]] && other=XXXX
check "Groß- und Kleinschreibung zählen" '! p2v_hostkey_accept "$other"'
check "richtige Eingabe: known_hosts enthält genau diesen Schlüssel" 'p2v_hostkey_accept " ${P2V_FP: -4} " && [[ $(cat "$P2V_DIR/known_hosts") == "pve.example $(cut -d" " -f1,2 "$T/hostkey.pub")" ]]'
check "der Ordner ist nur für den Benutzer" '[[ $(stat -c %a "$P2V_DIR") == 700 ]]'
ssh-keyscan() { echo "pve.example ssh-ed25519 A;B C"; }
check "eine Antwort, die kein Schlüssel ist, gilt nicht" '! p2v_hostkey_scan && [[ -z $P2V_FP ]]'

check "ohne bestätigten Schlüssel kein ssh" '! p2v_ssh_set && ((${#P2V_SSH[@]} == 0))'
ssh-keyscan() { [[ $* == *ed25519* ]] && echo "pve.example $(cut -d' ' -f1,2 "$T/hostkey.pub")"; return 0; }
p2v_hostkey_scan
p2v_ssh_set
sshopts=" ${P2V_SSH[*]} "
check "ssh ohne Benutzer-Konfiguration" '[[ $sshopts == *" -F /dev/null "* ]]'
check "ssh nur mit der eigenen known_hosts, streng, nur mit dem bestätigten Algorithmus" '[[ $sshopts == *"UserKnownHostsFile=$P2V_DIR/known_hosts"* && $sshopts == *"GlobalKnownHostsFile=/dev/null"* && $sshopts == *"StrictHostKeyChecking=yes"* && $sshopts == *"HostKeyAlgorithms=ssh-ed25519"* && $sshopts == *"UpdateHostKeys=no"* ]]'
check "ssh ohne Agent und X11" '[[ $sshopts == *"ForwardAgent=no"* && $sshopts == *"ForwardX11=no"* ]]'

# ---------------------------------------------------------------------------
echo "Anmeldung:"
check "Knoten mit root und allen Werkzeugen: angemeldet" 'p2v_login && [[ $P2V_NODE == pve1 ]]'
MOCK_UID=1000
p2v_login
check "Benutzer ohne root: abgelehnt" '[[ $? == 2 ]]'
MOCK_UID=0 MOCK_HOSTNAME='pve1;reboot'
p2v_login
check "Knotenname mit Shell-Zeichen: abgelehnt" '[[ $? == 3 ]]'
MOCK_HOSTNAME=pve1 MOCK_LOGIN_FAIL=1
p2v_login
check "keine Verbindung: abgelehnt" '[[ $? == 1 ]]'
unset MOCK_LOGIN_FAIL
p2v_login

echo "Antworten des Knotens:"
PVESM_STATUS="Name Type Status Total Used Available %
local dir active 100 0 104857600 0%
local-lvm lvmthin active 100 0 209715200 0%
aus lvmthin disabled 100 0 209715200 0%
x;reboot lvmthin active 100 0 209715200 0%
fremd foo active 100 0 209715200 0%"
out=$(p2v_storages)
check "nur aktive Speicher mit gültigem Namen und bekanntem Typ" '[[ $out == "local dir 100"$'"'"'\n'"'"'"local-lvm lvmthin 200" ]]'
PVESH_BRIDGES='[{"iface":"vmbr0"},{"iface":"vmbr1"},{"iface":"x;reboot"},{"iface":"vmbr0,tag=5"}]' PVESH_VNETS='[{"vnet":"vnet1"}]'
out=$(p2v_bridges | tr '\n' ' ')
check "Bridges und VNets, nur gültige Namen" '[[ $out == "vmbr0 vmbr1 vnet1 " ]]'
check "freie VM-ID wird erkannt" 'p2v_vmid_free 100'
touch "$K/vms/101"
check "vergebene VM-ID wird erkannt" '! p2v_vmid_free 101'
check "ungültige VM-ID wird gar nicht erst gefragt" '! p2v_vmid_free "100;touch $T/MARKE-vmid" && ! markers'

# ---------------------------------------------------------------------------
echo "VM anlegen:"
setvm() {
	P2V_NODE=pve1 P2V_STOR=local-lvm P2V_STYP=lvmthin P2V_VMID=100 P2V_BRIDGE=vmbr0 P2V_VLAN=""
	P2V_NAME=pc-01 P2V_MEM=4096 P2V_CORES=2 P2V_CPU=x86-64-v2-AES P2V_OSTYPE=win11
	P2V_FIRMWARE=uefi P2V_TPM=1 P2V_SRC=(/dev/sdx) P2V_SYS=0
	rm -f "$K/aufrufe" "$K"/vms/100
	unset PVESM_ALLOC PVESM_PATH
}
calls() { cat "$K/aufrufe" 2>/dev/null; }
setvm
P2V_VLAN=20
check "angelegt" 'p2v_create'
check "qm create mit genau diesen Argumenten" '[[ $(calls | grep "^qm|create|") == "qm|create|100|--name|pc-01|--memory|4096|--cores|2|--sockets|1|--cpu|x86-64-v2-AES|--ostype|win11|--machine|q35|--scsihw|virtio-scsi-single|--net0|e1000e,bridge=vmbr0,tag=20|--tablet|1|--vga|std|--description|P2V vom "*" mit Leuchtfeuer test. Quelle: "*"|" ]]'
check "Volume in MiB auf dem gewählten Speicher" 'calls | grep -qx "pvesm|alloc|local-lvm|100|vm-100-disk-0|33M|"'
check "Volume, EFI-Disk, TPM und Startreihenfolge" 'calls | grep -qx "qm|set|100|--sata0|local-lvm:vm-100-disk-0,discard=on,ssd=1|" && calls | grep -qx "qm|set|100|--bios|ovmf|--efidisk0|local-lvm:1,efitype=4m,pre-enrolled-keys=1|" && calls | grep -qx "qm|set|100|--tpmstate0|local-lvm:1,version=v2.0|" && calls | grep -qx "qm|set|100|--boot|order=sata0|"'
check "P2V_VOLS kennt das Volume" '[[ ${P2V_VOLS[*]} == local-lvm:vm-100-disk-0 ]]'
setvm
P2V_STOR=local P2V_STYP=dir P2V_TPM=0
p2v_create
check "Verzeichnisspeicher: qcow2, auch für die EFI-Disk" 'calls | grep -qx "pvesm|alloc|local|100|vm-100-disk-0.qcow2|33M|--format|qcow2|" && calls | grep -qx "qm|set|100|--bios|ovmf|--efidisk0|local:1,efitype=4m,pre-enrolled-keys=1,format=qcow2|" && ! calls | grep -q tpmstate'

for bad in "P2V_NAME=x;touch $T/MARKE-name" "P2V_NAME=\$(touch $T/MARKE-name2)" "P2V_VLAN=5,trunks=1" "P2V_BRIDGE=vmbr0,firewall=0" \
	"P2V_MEM=4096;touch $T/MARKE-mem" "P2V_CPU=host,flags=+x" "P2V_STOR=a;b" "P2V_SRC=/dev/sdx;x" "P2V_TPM=2"; do
	setvm
	if [[ $bad == P2V_SRC=* ]]; then P2V_SRC=("${bad#*=}"); else printf -v "${bad%%=*}" '%s' "${bad#*=}"; fi
	p2v_create
	rc=$?
	check "ungültig ($bad): nichts angelegt, nichts ausgeführt" '[[ $rc != 0 ]] && ! calls | grep -q "^qm|" && ! markers'
done
setvm
touch "$K/vms/100"
p2v_create
check "vergebene VM-ID: nichts angelegt" '[[ $? != 0 ]] && ! calls | grep -q "^qm|create"'

echo "Beschreibung mit präparierten DMI-Angaben:"
setvm
cat() {
	case $1 in
	/sys/class/dmi/id/sys_vendor) echo "Evil\$(touch $T/MARKE-dmi)\`touch $T/MARKE-dmi2\`" ;;
	/sys/class/dmi/id/product_name) echo "PC'; touch $T/MARKE-dmi3; '" ;;
	/sys/class/dmi/id/product_serial) echo "SN\"; touch $T/MARKE-dmi4; \"" ;;
	*) command cat "$@" ;;
	esac
}
p2v_create
unset -f cat
check "angelegt, nichts ausgeführt" '! markers && calls | grep -q "^qm|create|"'
desc=$(calls | grep "^qm|create|" | sed "s/.*|--description|//")
check "die Beschreibung ist ein Argument" '[[ $desc == "P2V vom "*"|" && $desc != *"|"*"|" ]]'
check "die Beschreibung enthält keine Shell-Zeichen" '[[ $desc != *[\$\`\;\"\(\)]* && $desc != *"'"'"'"* ]]'

echo "Antworten des Knotens beim Anlegen:"
setvm
export PVESM_ALLOC="successfully created 'other:vm-100-disk-0'"
p2v_create
check "Volume auf einem anderen Speicher: nicht angehängt" '[[ $? != 0 ]] && ! calls | grep -q "^qm|set|100|--sata0"'
setvm
export PVESM_ALLOC="successfully created 'local-lvm:vm-100-disk-0,file=/dev/sda'"
p2v_create
check "Volume mit Optionen: nicht angehängt" '[[ $? != 0 ]] && ! calls | grep -q "^qm|set|100|--sata0"'

# ---------------------------------------------------------------------------
echo "Kopier-Job:"
lsblk() {
	case "$*" in
	"-dnb -o SERIAL,WWN,SIZE /dev/sdx") echo "WD-123 0x5000 34603008" ;;
	"-lnp -o NAME,TYPE /dev/sdx") printf '/dev/sdx disk\n%s part\n%s part\n%s part\n' "${PARTS[@]}" ;;
	esac
}
blkid() {
	local dev=${!#}
	case "$*" in
	*PTTYPE*) echo "${PTTYPE:-gpt}" ;;
	*TYPE*) case $dev in /dev/sdx1) echo vfat ;; /dev/sdx2) echo ntfs ;; /dev/sdx3) echo "${FS3:-}" ;; esac ;;
	esac
}
p2v_partnum() { echo "${1##*[!0-9]}"; }
PARTS=(/dev/sdx1 /dev/sdx2 /dev/sdx3)
setvm
P2V_NBD=(/dev/nbd1) P2V_VOLS=(local-lvm:vm-100-disk-0)
RO_DEVS=""
check "Quelle nicht schreibgeschützt: kein Job" '! p2v_job "$T/job" "$T/status" && [[ ! -s $T/job ]]'
RO_DEVS="/dev/sdx"
check "Job erzeugt" 'p2v_job "$T/job" "$T/status" && bash -n "$T/job"'
JOB=$(command cat "$T/job")
check "der Job prüft vor jeder Partition Disk und Schreibschutz" '[[ $(grep -c "^same '"'"'/dev/sdx'"'"' " "$T/job") == 4 ]] && grep -q "blockdev --getro" "$T/job"'
check "Tabelle: erstes MiB, dann GPT ans Ende" '[[ $JOB == *"dd if='"'"'/dev/sdx'"'"' of='"'"'/dev/nbd1'"'"' bs=1M count=1"* && $JOB == *"sgdisk -e '"'"'/dev/nbd1'"'"'"* ]]'
check "Partitionen mit partclone, sonst dd" '[[ $JOB == *"partclone.vfat -b -s '"'"'/dev/sdx1'"'"' -o '"'"'/dev/nbd1p1'"'"'"* && $JOB == *"partclone.ntfs -b -s '"'"'/dev/sdx2'"'"' -o '"'"'/dev/nbd1p2'"'"'"* && $JOB == *"dd if='"'"'/dev/sdx3'"'"' of='"'"'/dev/nbd1p3'"'"'"* ]]'
check "das Volume muss mindestens so groß sein wie die Quelle" 'grep -q "getsize64 '"'"'/dev/nbd1'"'"'.*>=.*getsize64 '"'"'/dev/sdx'"'"'" "$T/job"'
PTTYPE=dos
p2v_job "$T/job" "$T/status"
check "MBR: Tabelle mit logischen Laufwerken" 'grep -q "sfdisk -d '"'"'/dev/sdx'"'"' | sfdisk --no-reread --no-tell-kernel '"'"'/dev/nbd1'"'"'" "$T/job" && ! grep -q "sgdisk -e" "$T/job"'
PTTYPE=none
p2v_job "$T/job" "$T/status"
check "ohne Tabelle: die ganze Disk mit Lückenerkennung" 'grep -q "dd if='"'"'/dev/sdx'"'"' of='"'"'/dev/nbd1'"'"' bs=4M iflag=fullblock conv=sparse,fsync" "$T/job" && ! grep -q partclone "$T/job"'
PTTYPE=gpt FS3="ext4;touch"
check "Dateisystemname mit Shell-Zeichen: kein Job" '! p2v_job "$T/job" "$T/status"'
FS3="" PARTS=(/dev/sdx1 /dev/sdx2 "/dev/sdx3';touch")
check "Partitionspfad mit Shell-Zeichen: kein Job" '! p2v_job "$T/job" "$T/status"'
PARTS=(/dev/sdx1 /dev/sdx2 /dev/sdx3) P2V_NBD=(/dev/sda)
check "Ziel ist kein NBD-Gerät: kein Job" '! p2v_job "$T/job" "$T/status"'
check "nichts wurde ausgeführt: keine Markerdatei" '! markers'

# ---------------------------------------------------------------------------
echo "Einbau:"
check "p2v steht in der Ladeliste und im Hauptmenü" 'grep -q "clone p2v resize" "$REPO/rescue/lf" && grep -q "p2v) p2v_wizard" "$REPO/rescue/lf"'
check "nbd-client steht in der Paketliste" 'grep -qx nbd-client "$REPO/build/packages.list"'
check "der Selbsttest prüft P2V gegen die Attrappe" 'grep -q "selftest_p2v \"\$dir\" || ok=0" "$REPO/rescue/lf"'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
