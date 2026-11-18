# shellcheck shell=bash
# Umzug in eine Proxmox-VM (P2V): Die Disks dieses Rechners werden zu den Disks einer neuen VM
# auf einem Proxmox-VE-Knoten.
#
# Ablauf: Knoten wählen und seinen SSH-Schlüssel bestätigen, anmelden, Speicher und VM-Daten
# wählen, Quell-Disks wählen, VM anlegen, die Volumes der VM per NBD über SSH einbinden und
# jede Partition kopieren (partclone, nur belegte Blöcke). Die Volumes bleiben dünn.
#
# Sicherheitsregeln:
#   - Die Quell-Disks werden sofort schreibgeschützt (safety_set_ro), bevor etwas von ihnen
#     gelesen wird. Der Kopier-Job prüft vor jedem Schritt, dass es noch dieselben Disks sind.
#   - Den SSH-Schlüssel des Knotens bestätigt der Techniker, indem er die letzten 10 Zeichen des
#     Fingerabdrucks abtippt. ssh vertraut danach nur diesem einen Schlüssel (eigene
#     known_hosts-Datei im RAM, StrictHostKeyChecking=yes). Eine leere Eingabe bestätigt nie.
#   - Zugangsdaten speichert der Assistent nicht. Das Kennwort fragt ssh selbst ab, die
#     Verbindung lebt nur in dieser Sitzung (ControlMaster unter /run/lf/p2v) und wird am Ende
#     beendet. Die Benutzer-Konfiguration von ssh (~/.ssh/config) gilt hier nicht (-F /dev/null).
#   - Geschrieben wird nur in Volumes, die der Assistent eben selbst angelegt hat (pvesm alloc
#     für eine neue, freie VM-ID). Bestehende VMs und Volumes fasst er nie an. Das Ziel bestätigt
#     der Techniker, indem er die VM-ID abtippt.
#   - Was zum Knoten geht, ist geprüft und einzeln gequotet (p2v_r). Was vom Knoten kommt
#     (Speicher, Bridges, Pfade), muss einem Muster entsprechen, bevor es weiterverwendet wird.
#     Texte vom Quellrechner (DMI, Windows) kommen nur gefiltert in die Beschreibung der VM.
#   - Die NBD-Verbindung läuft über Unix-Sockets: auf dem Knoten in einem eigenen Ordner unter
#     /run, hier unter /run/lf/p2v (Modus 700). Kein TCP-Port, auch nicht auf 127.0.0.1, an
#     dem ein anderer Benutzer (etwa lf-claude) in die Volumes schreiben könnte.

P2V_DIR="$LF_RUN/p2v"
P2V_STORAGE_THIN="lvmthin zfspool rbd dir nfs cifs glusterfs btrfs cephfs"
P2V_STORAGE_QCOW2="dir nfs cifs glusterfs cephfs"
P2V_STORAGE_KNOWN="$P2V_STORAGE_THIN lvm iscsi iscsidirect zfs pbs esxi"
P2V_OSTYPES="win11 win10 win8 win7 wxp l26 other"
P2V_CPUS="x86-64-v2-AES x86-64-v3 host"
P2V_MAX_DISKS=6

# ---------------------------------------------------------------------------
# Prüfungen: Jeder Wert, der in einen Befehl kommt, muss einem dieser Muster entsprechen.
# ---------------------------------------------------------------------------
# p2v_ok ART WERT
p2v_ok() {
	local LC_ALL=C kind=$1 v=$2 re
	case $kind in
	host) re='^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$|^[0-9A-Fa-f:]{2,39}$' ;;
	user) re='^[a-z_][a-z0-9_-]{0,31}$' ;;
	port) [[ $v =~ ^[1-9][0-9]{0,4}$ ]] && ((v <= 65535)); return ;;
	node) re='^[A-Za-z0-9]([A-Za-z0-9.-]{0,62})$' ;;
	stor) re='^[A-Za-z][A-Za-z0-9._-]{0,99}$' ;;
	styp) [[ " $P2V_STORAGE_KNOWN " == *" $v "* && -n $v ]]; return ;;
	vmid) [[ $v =~ ^[1-9][0-9]{2,8}$ ]]; return ;;
	bridge) re='^[A-Za-z][A-Za-z0-9._-]{0,15}$' ;;
	vlan) [[ -z $v ]] || { [[ $v =~ ^[1-9][0-9]{0,3}$ ]] && ((v <= 4094)); }; return ;;
	name) re='^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$' ;;
	mem) [[ $v =~ ^[1-9][0-9]{2,7}$ ]] && ((v >= 256)); return ;;
	cores) [[ $v =~ ^[1-9][0-9]{0,3}$ ]] && ((v <= 1024)); return ;;
	cpu) [[ " $P2V_CPUS " == *" $v "* && -n $v ]]; return ;;
	ostype) [[ " $P2V_OSTYPES " == *" $v "* && -n $v ]]; return ;;
	firmware) [[ $v == uefi || $v == bios ]]; return ;;
	volid) re="^${P2V_STOR//./\\.}:[A-Za-z0-9._/-]+\$" ;;
	path) re='^[A-Za-z0-9/][A-Za-z0-9._/:=;+,@-]*$' ;;
	rdir) re='^/run/lf-p2v\.[A-Za-z0-9]{8,}$' ;;
	*) return 1 ;;
	esac
	[[ $v =~ $re && $v != *..* ]]
}

# p2v_text TEXT   Text vom Quellrechner (DMI) für die Beschreibung der VM: nur harmlose Zeichen.
p2v_text() {
	local LC_ALL=C s=$1
	s=${s//[^A-Za-z0-9 ._-]/}
	s=${s#"${s%%[! ]*}"}
	printf '%s' "${s:0:60}"
}

# ---------------------------------------------------------------------------
# Verbindung zum Knoten
# ---------------------------------------------------------------------------
# p2v_ssh_set   Baut die Befehlszeile für ssh (P2V_SSH). Nur der bestätigte Schlüssel gilt.
p2v_ssh_set() {
	P2V_SSH=()
	# Ohne bestätigten Schlüssel gibt es keine Verbindung.
	[[ -n ${P2V_HKALG:-} && -s $P2V_DIR/known_hosts ]] || return 1
	P2V_SSH=(ssh -F /dev/null -p "$P2V_PORT" -l "$P2V_USER"
		-o ControlPath="$P2V_DIR/ctl"
		-o UserKnownHostsFile="$P2V_DIR/known_hosts" -o GlobalKnownHostsFile=/dev/null
		-o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o HostKeyAlgorithms="$P2V_HKALG"
		-o ForwardAgent=no -o ForwardX11=no -o PermitLocalCommand=no
		-o ServerAliveInterval=15 -o ServerAliveCountMax=8)
	# Nur für den Selbsttest gegen die Attrappe eines Knotens: ein eigener Schlüssel.
	[[ -n ${P2V_TEST_IDENTITY:-} ]] && P2V_SSH+=(-o IdentitiesOnly=yes -i "$P2V_TEST_IDENTITY")
	return 0
}

# p2v_r BEFEHL ARGUMENT...   Führt einen Befehl auf dem Knoten aus. Jedes Argument wird einzeln
# gequotet: Auf dem Knoten kommt genau diese Argumentliste an, nichts davon wird zu Shell-Code.
p2v_r() {
	local cmd
	cmd=$(printf '%q ' "$@")
	"${P2V_SSH[@]}" -o BatchMode=yes "$P2V_HOST" "$cmd" 2>>"${LF_LOG:-/dev/null}"
}

# p2v_hostkey_scan   Holt den Schlüssel des Knotens (ed25519, sonst ecdsa, sonst rsa) nach
# $P2V_DIR/hostkey.scan. Setzt P2V_HKALG, P2V_FP (SHA256-Fingerabdruck) und P2V_HKTYPE.
p2v_hostkey_scan() {
	local t line alg re='^[^ ]+ (ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,2}$'
	P2V_HKALG="" P2V_FP="" P2V_HKTYPE=""
	install -d -m 700 "$P2V_DIR"
	for t in ed25519 ecdsa rsa; do
		line=$(ssh-keyscan -T 10 -p "$P2V_PORT" -t "$t" "$P2V_HOST" 2>/dev/null | grep -v '^#' | head -n 1)
		[[ $line =~ $re ]] || continue
		alg=${BASH_REMATCH[1]}
		printf '%s\n' "$line" >"$P2V_DIR/hostkey.scan"
		P2V_FP=$(ssh-keygen -l -E sha256 -f "$P2V_DIR/hostkey.scan" 2>/dev/null | awk '{print $2}')
		[[ $P2V_FP =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || { P2V_FP=""; continue; }
		P2V_HKTYPE=$t
		case $t in
		ed25519) P2V_HKALG=ssh-ed25519 ;;
		ecdsa) P2V_HKALG=$alg ;;
		rsa) P2V_HKALG=rsa-sha2-512,rsa-sha2-256 ;;
		esac
		return 0
	done
	return 1
}

# p2v_hostkey_accept EINGABE   Prüft die Eingabe gegen die letzten P2V_FP_CONFIRM Zeichen des
# Fingerabdrucks (Groß- und Kleinschreibung zählen, Base64). Erst dann gilt der Schlüssel für ssh.
# 4 Zeichen (24 Bit) trifft ein Angreifer mit einem passend erzeugten Schlüssel in Minuten,
# 10 Zeichen (60 Bit) nicht (GHSA-p86q-3456-f288).
P2V_FP_CONFIRM=10
p2v_hostkey_accept() {
	local got
	got=$(_safety_trim "$1")
	[[ -n $got && ${#P2V_FP} -gt $P2V_FP_CONFIRM && $got == "${P2V_FP: -P2V_FP_CONFIRM}" ]] || return 1
	install -m 600 "$P2V_DIR/hostkey.scan" "$P2V_DIR/known_hosts"
	log "SSH-Schlüssel von $P2V_HOST bestätigt: $P2V_FP ($P2V_HKTYPE)"
}

# p2v_login   Meldet sich an (ssh fragt das Kennwort selbst ab) und prüft, ob es ein Knoten
# von Proxmox VE ist, mit root-Rechten. Setzt P2V_NODE.
p2v_login() {
	p2v_ssh_set || return 1
	"${P2V_SSH[@]}" -O exit "$P2V_HOST" >/dev/null 2>&1
	"${P2V_SSH[@]}" -o ControlMaster=yes -o ControlPersist=8h -o NumberOfPasswordPrompts=3 -fN "$P2V_HOST" || return 1
	[[ $(p2v_r sh -c 'command -v qm >/dev/null && command -v pvesm >/dev/null && command -v pvesh >/dev/null && command -v qemu-nbd >/dev/null && id -u') == 0 ]] || return 2
	P2V_NODE=$(p2v_r hostname)
	p2v_ok node "$P2V_NODE" || return 3
	log "P2V: angemeldet an $P2V_USER@$P2V_HOST, Knoten $P2V_NODE"
}

# p2v_storages   Aktive Speicher für VM-Disks, je Zeile "NAME TYP FREI-GIB". Nur geprüfte Zeilen.
p2v_storages() {
	local name typ st avail
	while read -r name typ st _ _ avail _; do
		[[ $st == active ]] && p2v_ok stor "$name" && p2v_ok styp "$typ" && [[ $avail =~ ^[0-9]+$ ]] || continue
		echo "$name $typ $((avail / 1048576))"
	done < <(p2v_r pvesm status --content images | tail -n +2)
}

# p2v_bridges   Bridges des Knotens und SDN-VNets, je Zeile ein Name.
p2v_bridges() {
	{
		p2v_r pvesh get "/nodes/$P2V_NODE/network" --type any_bridge --output-format json | jq -r '.[]?.iface // empty' 2>/dev/null
		p2v_r pvesh get /cluster/sdn/vnets --output-format json | jq -r '.[]?.vnet // empty' 2>/dev/null
	} | while read -r b; do p2v_ok bridge "$b" && echo "$b"; done | sort -u
}

# p2v_vmid_free VMID
p2v_vmid_free() { p2v_ok vmid "$1" && p2v_r pvesh get /cluster/nextid --vmid "$1" >/dev/null; }

p2v_logout() {
	((${#P2V_SSH[@]})) && "${P2V_SSH[@]}" -O exit "$P2V_HOST" >/dev/null 2>&1
	P2V_SSH=()
	rm -f "$P2V_DIR/known_hosts" "$P2V_DIR/hostkey.scan"
	return 0
}

# ---------------------------------------------------------------------------
# VM anlegen
# ---------------------------------------------------------------------------
# p2v_check_all   Alle Werte für die VM noch einmal prüfen, bevor etwas auf dem Knoten entsteht.
p2v_check_all() {
	local d
	p2v_ok node "$P2V_NODE" && p2v_ok stor "$P2V_STOR" && p2v_ok styp "$P2V_STYP" &&
		p2v_ok vmid "$P2V_VMID" && p2v_ok bridge "$P2V_BRIDGE" && p2v_ok vlan "$P2V_VLAN" &&
		p2v_ok name "$P2V_NAME" && p2v_ok mem "$P2V_MEM" && p2v_ok cores "$P2V_CORES" &&
		p2v_ok cpu "$P2V_CPU" && p2v_ok ostype "$P2V_OSTYPE" && p2v_ok firmware "$P2V_FIRMWARE" &&
		[[ $P2V_TPM == [01] && ${#P2V_SRC[@]} -ge 1 && ${#P2V_SRC[@]} -le $P2V_MAX_DISKS ]] || return 1
	for d in "${P2V_SRC[@]}"; do clone_path_ok "$d" || return 1; done
}

# p2v_create   Legt die VM und je Quell-Disk ein Volume an. Setzt P2V_VOLS.
p2v_create() {
	local net="e1000e,bridge=$P2V_BRIDGE" desc i mib vol name fmt=() qfmt="" out boot=sata0
	P2V_VOLS=()
	p2v_check_all || { log "P2V: Werte ungültig, keine VM angelegt"; return 1; }
	[[ -n $P2V_VLAN ]] && net+=",tag=$P2V_VLAN"
	desc="P2V vom $(date '+%d.%m.%Y %H:%M') mit Leuchtfeuer $LF_VERSION. Quelle: $(p2v_text "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"), Seriennr. $(p2v_text "$(cat /sys/class/dmi/id/product_serial 2>/dev/null)")."
	p2v_vmid_free "$P2V_VMID" || { log "P2V: VM-ID $P2V_VMID ist vergeben"; return 1; }
	p2v_r qm create "$P2V_VMID" --name "$P2V_NAME" --memory "$P2V_MEM" --cores "$P2V_CORES" --sockets 1 \
		--cpu "$P2V_CPU" --ostype "$P2V_OSTYPE" --machine q35 --scsihw virtio-scsi-single \
		--net0 "$net" --tablet 1 --vga std --description "$desc" >>"$LF_LOG" || { log "P2V: qm create fehlgeschlagen"; return 1; }
	log "P2V: VM $P2V_VMID angelegt"
	[[ " $P2V_STORAGE_QCOW2 " == *" $P2V_STYP "* ]] && fmt=(--format qcow2) qfmt=",format=qcow2"
	for i in "${!P2V_SRC[@]}"; do
		# pvesm alloc rechnet ohne Einheit in KiB, mit M in MiB.
		mib=$((($(sudo blockdev --getsize64 "${P2V_SRC[i]}") + 1048575) / 1048576))
		name="vm-$P2V_VMID-disk-$i"
		((${#fmt[@]})) && name+=".qcow2"
		out=$(p2v_r pvesm alloc "$P2V_STOR" "$P2V_VMID" "$name" "${mib}M" "${fmt[@]}")
		vol=$(sed -n "s/^successfully created '\(.*\)'\$/\1/p" <<<"$out" | tail -n 1)
		p2v_ok volid "$vol" || { log "P2V: Volume für ${P2V_SRC[i]} nicht angelegt: $out"; return 1; }
		p2v_r qm set "$P2V_VMID" "--sata$i" "$vol,discard=on,ssd=1" >>"$LF_LOG" || { log "P2V: $vol nicht angehängt"; return 1; }
		P2V_VOLS+=("$vol")
		log "P2V: ${P2V_SRC[i]} -> $vol (sata$i, $mib MiB)"
	done
	if [[ $P2V_FIRMWARE == uefi ]]; then
		p2v_r qm set "$P2V_VMID" --bios ovmf --efidisk0 "$P2V_STOR:1,efitype=4m,pre-enrolled-keys=1$qfmt" >>"$LF_LOG" || return 1
	fi
	if [[ $P2V_TPM == 1 ]]; then
		p2v_r qm set "$P2V_VMID" --tpmstate0 "$P2V_STOR:1,version=v2.0" >>"$LF_LOG" || return 1
	fi
	[[ ${P2V_SYS:-} =~ ^[0-9]$ ]] && boot="sata$P2V_SYS"
	p2v_r qm set "$P2V_VMID" --boot "order=$boot" >>"$LF_LOG"
}

# ---------------------------------------------------------------------------
# Volumes einbinden (NBD über SSH, nur Unix-Sockets)
# ---------------------------------------------------------------------------
# p2v_nbd_free   Ein freies NBD-Gerät dieses Systems.
p2v_nbd_free() {
	local n d
	for ((n = 1; n < 16; n++)); do
		d=/dev/nbd$n
		[[ -b $d && $(cat "/sys/block/nbd$n/size" 2>/dev/null) == 0 && ! -e /sys/block/nbd$n/pid ]] || continue
		[[ " ${P2V_NBD[*]:-} " == *" $d "* ]] && continue
		grep -qx "$d" "$LF_RUN/readonly" 2>/dev/null && continue
		echo "$d"
		return 0
	done
	return 1
}

# p2v_attach   Exportiert jedes Volume auf dem Knoten mit qemu-nbd an einem Unix-Socket und
# bindet es hier als /dev/nbdN ein. Setzt P2V_NBD und P2V_PIDS.
p2v_attach() {
	local i vol path ifmt=raw sock rsock dev n
	P2V_NBD=() P2V_PIDS=()
	[[ " $P2V_STORAGE_QCOW2 " == *" $P2V_STYP "* ]] && ifmt=qcow2
	sudo modprobe nbd max_part=16 2>/dev/null
	# Ist das Modul schon ohne Partitionen geladen (Klonen mit Verkleinern), fehlten die
	# Partitionen der Volumes. Dann wird nicht kopiert.
	n=$(cat /sys/module/nbd/parameters/max_part 2>/dev/null)
	[[ $n =~ ^[0-9]+$ ]] && ((n >= 8)) || { log "P2V: nbd ohne Partitionen geladen (max_part=$n)"; return 1; }
	P2V_RDIR=$(p2v_r mktemp -d /run/lf-p2v.XXXXXXXX)
	p2v_ok rdir "$P2V_RDIR" || { P2V_RDIR=""; return 1; }
	for i in "${!P2V_VOLS[@]}"; do
		vol=${P2V_VOLS[i]}
		path=$(p2v_r pvesm path "$vol")
		p2v_ok path "$path" || { log "P2V: Pfad zu $vol ungültig: $path"; return 1; }
		sock="$P2V_DIR/nbd$i.sock" rsock="$P2V_RDIR/nbd$i.sock"
		rm -f "$sock"
		# qemu-nbd endet, sobald nbd-client trennt. Damit endet auch diese Verbindung.
		"${P2V_SSH[@]}" -o BatchMode=yes -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes \
			-L "$sock:$rsock" "$P2V_HOST" "$(printf '%q ' exec qemu-nbd -f "$ifmt" --cache=none --discard=unmap \
				--detect-zeroes=unmap -k "$rsock" -x p2v -- "$path")" 2>>"$LF_LOG" &
		P2V_PIDS+=("$!")
		dev=$(p2v_nbd_free) || { log "P2V: kein freies NBD-Gerät"; return 1; }
		n=0
		# -b 512: Mit 4096 verschwände die GPT einer Disk mit 512-Byte-Sektoren.
		until sudo nbd-client -unix "$sock" "$dev" -N p2v -b 512 >>"$LF_LOG" 2>&1; do
			n=$((n + 1))
			((n > 30)) && { log "P2V: NBD-Verbindung zu $vol kam nicht zustande"; return 1; }
			sleep 1
		done
		P2V_NBD+=("$dev")
		log "P2V: $vol ($path) als $dev eingebunden"
	done
}

# p2v_detach   Trennt alle Volumes und Verbindungen. Läuft auch nach einem Abbruch.
p2v_detach() {
	local d p
	sync
	for d in "${P2V_NBD[@]}"; do
		sudo blockdev --flushbufs "$d" 2>/dev/null
		run sudo nbd-client -d "$d"
	done
	P2V_NBD=()
	for p in "${P2V_PIDS[@]}"; do
		kill "$p" 2>/dev/null
		wait "$p" 2>/dev/null
	done
	P2V_PIDS=()
	[[ -n ${P2V_RDIR:-} ]] && p2v_ok rdir "$P2V_RDIR" && p2v_r rm -rf -- "$P2V_RDIR"
	P2V_RDIR=""
	rm -f "$P2V_DIR"/nbd*.sock
	return 0
}

# ---------------------------------------------------------------------------
# Kopieren
# ---------------------------------------------------------------------------
# p2v_partnum PARTITION   Nummer der Partition laut Kernel.
p2v_partnum() { cat "/sys/class/block/${1##*/}/partition" 2>/dev/null; }

# p2v_job DATEI STATUS   Schreibt den Kopier-Job (läuft als root). Er besteht aus geprüften
# Gerätepfaden, Partitionsnummern und Dateisystemnamen. Die Befehle je Partition kommen aus
# clone_cmd_copy, wie beim Klonen.
p2v_job() {
	local job=$1 status=$2 i src dst hash pt p num fs token='^[A-Za-z0-9_.+-]*$'
	for i in "${!P2V_SRC[@]}"; do
		src=${P2V_SRC[i]} dst=${P2V_NBD[i]:-}
		clone_path_ok "$src" && clone_path_ok "$dst" && [[ $dst == /dev/nbd* ]] || return 1
		safety_is_ro "$src" || { log "P2V: $src ist nicht schreibgeschützt, kein Job"; return 1; }
	done
	{
		echo '#!/usr/bin/env bash'
		echo 'set -u'
		echo "exec > >(tee -a '$LF_LOG') 2>&1"
		echo 'step() { printf "\n\033[1;33m==> %s\033[0m\n" "$*"; }'
		echo 'fail() { echo "FEHLER: $*"; echo FAIL > '"'$status'"'; [[ -t 0 ]] && read -r -p "Enter … " _; exit 1; }'
		echo 'ident() { local id; id=$(lsblk -dnb -o SERIAL,WWN,SIZE "$1" 2>/dev/null); [[ -n ${id// /} ]] || return 1; printf "%s" "$id" | sha256sum | cut -c1-64; }'
		echo 'same() { [[ $(ident "$1") == "$2" ]] || fail "$1 ist nicht mehr die Disk vom Start (Gerätename neu vergeben oder Disk abgezogen)."; [[ $(blockdev --getro "$1") == 1 ]] || fail "$1 ist nicht mehr schreibgeschützt."; }'
		echo 'part() { local n=0; until [[ -b $1 ]]; do n=$((n + 1)); ((n > 40)) && fail "Partition $1 fehlt."; sleep 0.5; partprobe "$2" 2>/dev/null; done; }'
		for i in "${!P2V_SRC[@]}"; do
			src=${P2V_SRC[i]} dst=${P2V_NBD[i]}
			hash=$(clone_ident "$src") || return 1
			pt=$(sudo blkid -o value -s PTTYPE "$src" 2>/dev/null)
			echo "step 'Disk $((i + 1)) von ${#P2V_SRC[@]}: $src -> ${P2V_VOLS[i]}'"
			echo "same '$src' '$hash'"
			echo "(( \$(blockdev --getsize64 '$dst') >= \$(blockdev --getsize64 '$src') )) || fail 'Das Volume ist kleiner als $src.'"
			if [[ $pt != gpt && $pt != dos ]]; then
				echo "dd if='$src' of='$dst' bs=4M iflag=fullblock conv=sparse,fsync status=progress || fail 'Kopie $src'"
				continue
			fi
			# Partitionstabelle und Startcode (erstes MiB). Bei GPT danach die zweite Kopie der
			# Tabelle ans Ende, bei MBR die ganze Tabelle mit logischen Laufwerken.
			echo "dd if='$src' of='$dst' bs=1M count=1 conv=fsync status=none || fail 'Partitionstabelle $dst'"
			[[ $pt == gpt ]] && echo "sgdisk -e '$dst' >/dev/null || fail 'GPT $dst'"
			[[ $pt == dos ]] && echo "sfdisk -d '$src' | sfdisk --no-reread --no-tell-kernel '$dst' >/dev/null || fail 'MBR $dst'"
			echo "blockdev --rereadpt '$dst' 2>/dev/null; partprobe '$dst' 2>/dev/null; udevadm settle"
			while IFS= read -r p; do
				num=$(p2v_partnum "$p")
				fs=$(sudo blkid -o value -s TYPE "$p" 2>/dev/null)
				[[ $num =~ ^[0-9]+$ && $fs =~ $token ]] && clone_path_ok "$p" || return 1
				echo "same '$src' '$hash'"
				echo "part '${dst}p$num' '$dst'"
				echo "step 'Partition $num (${fs:-ohne Dateisystem}): $p -> ${dst}p$num'"
				clone_cmd_copy "$p" "${dst}p$num" "$fs"
			done < <(lsblk -lnp -o NAME,TYPE "$src" | awk '$2 == "part" {print $1}')
		done
		echo 'sync'
		echo "echo OK > '$status'"
		echo 'step "Kopie abgeschlossen."'
		echo '[[ -t 0 ]] && read -r -p "Enter drücken … " _'
		echo 'exit 0'
	} >"$job"
	chmod 700 "$job"
}

# ---------------------------------------------------------------------------
# Assistent
# ---------------------------------------------------------------------------
p2v_cleanup() {
	p2v_detach
	p2v_logout
}

p2v_wizard() {
	ui_msg "Umzug in eine Proxmox-VM" "Macht aus diesem Rechner eine VM auf einem Proxmox-VE-Knoten.\n\n 1. Netzwerk prüfen\n 2. Knoten wählen, seinen SSH-Schlüssel bestätigen, anmelden\n 3. Speicher und VM-Daten wählen\n 4. Quell-Disks wählen\n 5. VM anlegen und kopieren: nur belegte Bereiche, die Volumes bleiben dünn\n\nDie Disks dieses Rechners werden nur gelesen und sofort schreibgeschützt.\n\nVoraussetzungen:\n - Windows vollständig heruntergefahren (Schnellstart aus, kein Ruhezustand)\n - BitLocker angehalten oder entschlüsselt\n - SSH-Zugang als root zum Knoten"
	install -d -m 700 "$P2V_DIR"
	P2V_NBD=() P2V_PIDS=() P2V_VOLS=() P2V_SRC=() P2V_SRC_ID=() P2V_RDIR="" P2V_SSH=()
	p2v_net_step && p2v_connect_step && p2v_vm_step && p2v_source_step && p2v_settings_step &&
		p2v_confirm_step && p2v_run_step
	p2v_cleanup
	return 0
}

p2v_net_step() {
	local ips c
	while true; do
		ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2 ": " $4}' | text_clean)
		c=$(ui_menu "1/5 Netzwerk" "Adressen dieses Rechners:\n${ips:-  keine}" -- \
			weiter "So passt es, weiter" \
			net "Netzwerk / WLAN einrichten (nmtui)" \
			neu "Neu einlesen") || return 1
		case $c in
		weiter) [[ -n $ips ]] && return 0; ui_msg "Netzwerk" "Es gibt noch keine IP-Adresse." ;;
		net) nmtui ;;
		esac
	done
}

p2v_connect_step() {
	local got rc
	P2V_HOST=${P2V_HOST:-} P2V_USER=${P2V_USER:-root} P2V_PORT=${P2V_PORT:-22}
	while true; do
		P2V_HOST=$(ui_input "2/5 Knoten" "Proxmox-VE-Knoten, auf dem die VM entstehen soll (IP oder Name):" "$P2V_HOST") || return 1
		p2v_ok host "$P2V_HOST" || { ui_msg "Knoten" "Das ist kein Rechnername und keine IP-Adresse."; continue; }
		P2V_PORT=$(ui_input "2/5 Knoten" "SSH-Port des Knotens:" "$P2V_PORT") || return 1
		p2v_ok port "$P2V_PORT" || { ui_msg "Knoten" "Der Port ist eine Zahl von 1 bis 65535."; P2V_PORT=22; continue; }
		P2V_USER=$(ui_input "2/5 Knoten" "SSH-Benutzer auf dem Knoten (braucht root-Rechte):" "$P2V_USER") || return 1
		p2v_ok user "$P2V_USER" || { ui_msg "Knoten" "Der Benutzername ist ungültig."; P2V_USER=root; continue; }
		ui_info "2/5 Knoten" "Hole den SSH-Schlüssel von $P2V_HOST …"
		if ! p2v_hostkey_scan; then
			ui_msg "Knoten" "$P2V_HOST antwortet nicht per SSH auf Port $P2V_PORT."
			continue
		fi
		got=$(ui_input "SSH-Schlüssel bestätigen" "Der Knoten $P2V_HOST meldet diesen Schlüssel ($P2V_HKTYPE):\n\n   $P2V_FP\n\nVergleiche ihn mit dem Schlüssel auf dem Knoten selbst, an seiner Konsole oder in der Shell der Proxmox-Oberfläche:\n\n   ssh-keygen -lf /etc/ssh/ssh_host_${P2V_HKTYPE}_key.pub\n\nStimmt er nicht, verbindet sich hier ein anderer Rechner. Dann abbrechen.\n\nZur Bestätigung die letzten $P2V_FP_CONFIRM Zeichen des Fingerabdrucks eingeben (Groß- und Kleinschreibung zählt):") || return 1
		if ! p2v_hostkey_accept "$got"; then
			log "P2V: SSH-Schlüssel von $P2V_HOST nicht bestätigt"
			ui_msg "Nicht bestätigt" "Die Eingabe passt nicht zum Fingerabdruck. Es wird keine Verbindung aufgebaut."
			continue
		fi
		clear
		echo "Anmeldung als $P2V_USER an $P2V_HOST."
		echo "ssh fragt das Kennwort selbst ab. Der Assistent speichert es nicht."
		echo
		p2v_login
		rc=$?
		case $rc in
		0) ui_msg "Verbunden" "Verbunden mit dem Knoten $P2V_NODE.\n$(p2v_r pveversion | head -n 1 | text_clean 80)\n\nDie VM entsteht auf diesem Knoten. Für einen anderen Knoten im Cluster verbinde dich direkt mit ihm."; return 0 ;;
		1) ui_msg "Knoten" "Keine SSH-Verbindung zu $P2V_USER@$P2V_HOST." ;;
		2) ui_msg "Knoten" "Auf $P2V_HOST fehlen qm, pvesm, pvesh oder qemu-nbd, oder der Benutzer ist nicht root.\nIst das ein Knoten von Proxmox VE?" ;;
		*) ui_msg "Knoten" "Der Knoten meldet einen Namen, den der Assistent nicht verwendet." ;;
		esac
		p2v_logout
	done
}

p2v_vm_step() {
	local lines items=() name typ free z next
	lines=$(p2v_storages)
	[[ -n $lines ]] || { die "Auf $P2V_NODE gibt es keinen aktiven Speicher für VM-Disks."; return 1; }
	while read -r name typ free; do
		[[ " $P2V_STORAGE_THIN " == *" $typ "* ]] && z="dünn" || z="NICHT dünn"
		items+=("$name" "$typ, $free GiB frei, $z")
	done <<<"$lines"
	while true; do
		P2V_STOR=$(ui_menu "3/5 Speicher" "Auf welchem Speicher sollen die Disks der VM liegen?" -- "${items[@]}") || return 1
		P2V_STYP=$(awk -v s="$P2V_STOR" '$1 == s {print $2}' <<<"$lines")
		P2V_FREE=$(awk -v s="$P2V_STOR" '$1 == s {print $3}' <<<"$lines")
		p2v_ok stor "$P2V_STOR" && p2v_ok styp "$P2V_STYP" || continue
		[[ " $P2V_STORAGE_THIN " == *" $P2V_STYP "* ]] && break
		ui_yesno "Speicher" "Der Speicher $P2V_STOR ($P2V_STYP) ist nicht dünn: Die Disks belegen dort ihre volle Größe.\n\nTrotzdem diesen Speicher nehmen?" --defaultno && break
	done
	next=$(p2v_r pvesh get /cluster/nextid | tr -d '"[:space:]')
	p2v_ok vmid "$next" || next=""
	while true; do
		P2V_VMID=$(ui_input "3/5 VM-ID" "VM-ID der neuen VM:" "${P2V_VMID:-$next}") || return 1
		p2v_ok vmid "$P2V_VMID" || { ui_msg "VM-ID" "Die VM-ID ist eine Zahl ab 100."; continue; }
		p2v_vmid_free "$P2V_VMID" && break
		ui_msg "VM-ID" "Die VM-ID $P2V_VMID ist schon vergeben. Bestehende VMs fasst der Assistent nicht an."
	done
	items=()
	while read -r name; do [[ -n $name ]] && items+=("$name" ""); done < <(p2v_bridges)
	((${#items[@]})) || { die "Der Knoten meldet keine Bridge für das Netz der VM."; return 1; }
	P2V_BRIDGE=$(ui_menu "3/5 Netz" "Netz der VM (Bridge oder SDN-VNet):" -- "${items[@]}") || return 1
	while true; do
		P2V_VLAN=$(ui_input "3/5 Netz" "VLAN-Tag für die Netzwerkkarte (leer = keiner):" "") || return 1
		p2v_ok vlan "$P2V_VLAN" && break
		ui_msg "VLAN" "Ein VLAN-Tag ist eine Zahl von 1 bis 4094."
	done
}

p2v_source_step() {
	local id sj dev ids=() i
	P2V_SRC=() P2V_SRC_ID=()
	while ((${#P2V_SRC[@]} < P2V_MAX_DISKS)); do
		id=$(disk_pick "4/5 Quelle" "Welche Disk dieses Rechners soll in die VM?\n(Der Leuchtfeuer-Stick steht nicht in der Liste.)${P2V_SRC[*]:+\n\nSchon gewählt: ${P2V_SRC[*]}}" "${ids[@]}") || break
		sj=$(disk_info "$id")
		dev=$(jq -r '.path // ""' <<<"$sj")
		[[ -n $dev ]] || continue
		# Die Quelle ist ab jetzt schreibgeschützt, bevor auch nur ein Byte von ihr gelesen wird.
		safety_set_ro "$dev"
		P2V_SRC+=("$dev") P2V_SRC_ID+=("$id") ids+=("$id")
		ui_yesno "4/5 Quelle" "Gewählt:\n$(printf '  %s\n' "${P2V_SRC[@]}")\nNoch eine Disk übernehmen?" --defaultno || break
	done
	((${#P2V_SRC[@]})) || return 1
	p2v_windows_probe
	for i in "${!P2V_SRC_ID[@]}"; do
		safety_still "${P2V_SRC_ID[i]}" "${P2V_SRC[i]}" || { die "Die Disk ${P2V_SRC[i]} ist nicht mehr dieselbe. Bitte neu beginnen."; return 1; }
	done
}

# p2v_windows_probe   Sucht die Disk mit Windows (für die Startreihenfolge) und warnt vor
# NTFS-Volumes, die nicht sauber getrennt sind (Ruhezustand, Schnellstart). Eingehängt wird nur
# lesend mit Schutzoptionen (part_mount_ro). BitLocker-Partitionen werden nicht geöffnet.
p2v_windows_probe() {
	local i p typ rc mp="$LF_IMAGE_MNT/p2v-probe" problems=""
	P2V_SYS="" P2V_WIN=0 P2V_UNCLEAN=0
	for i in "${!P2V_SRC[@]}"; do
		while IFS= read -r p; do
			typ=$(sudo blkid -o value -s TYPE "$p" 2>/dev/null)
			case $typ in
			BitLocker) problems+=" - $p ist mit BitLocker verschlüsselt: wird Block für Block kopiert (nicht dünn).\n" ;;
			ntfs)
				sudo ntfs-3g.probe --readonly "$p" >/dev/null 2>&1
				rc=$?
				if ((rc != 0)); then
					problems+=" - $p (NTFS) ist nicht sauber getrennt (Code $rc).\n"
					P2V_UNCLEAN=1
					continue
				fi
				[[ -n $P2V_SYS ]] && continue
				if part_mount_ro "$p" "$mp"; then
					[[ -f $mp/Windows/System32/config/SYSTEM && ! -L $mp/Windows ]] && P2V_SYS=$i P2V_WIN=1
					run sudo umount "$mp"
				fi
				;;
			esac
		done < <(lsblk -lnp -o NAME,TYPE "${P2V_SRC[i]}" | awk '$2 == "part" {print $1}')
	done
	log "P2V: Windows auf Disk ${P2V_SYS:-–}, Auffälligkeiten: ${problems:-keine}"
	if [[ -n $problems ]]; then
		ui_yesno "Achtung" "$problems\nEmpfehlung: abbrechen, Windows starten, Schnellstart abschalten (oder BitLocker anhalten) und vollständig herunterfahren (Umschalt + Herunterfahren).\n\nTrotzdem fortfahren? Nicht sauber getrennte Volumes werden dann Block für Block kopiert." --defaultno || return 1
	fi
	return 0
}

p2v_settings_step() {
	local pt fw ram name os
	pt=$(sudo blkid -o value -s PTTYPE "${P2V_SRC[${P2V_SYS:-0}]}" 2>/dev/null)
	[[ $pt == gpt ]] && fw=uefi || fw=bios
	ram=$((($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 + 1023) / 1024 * 1024))
	name=$(p2v_text "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" | tr ' ._' '---' | tr -s '-' | sed 's/^-*//; s/-*$//' | cut -c1-50)
	name="p2v${name:+-$name}"
	p2v_ok name "$name" || name="p2v-$P2V_VMID"
	while true; do
		P2V_NAME=$(ui_input "5/5 VM" "Name der VM (Buchstaben, Ziffern, Punkt, Bindestrich):" "$name") || return 1
		p2v_ok name "$P2V_NAME" && break
		ui_msg "Name" "Der Name passt nicht. Erlaubt sind Buchstaben, Ziffern, Punkt und Bindestrich, nicht am Anfang oder Ende."
	done
	while true; do
		P2V_MEM=$(ui_input "5/5 VM" "Arbeitsspeicher in MiB (dieser Rechner hat $ram):" "$ram") || return 1
		p2v_ok mem "$P2V_MEM" && break
	done
	while true; do
		P2V_CORES=$(ui_input "5/5 VM" "CPU-Kerne (dieser Rechner hat $(nproc)):" "$(nproc)") || return 1
		p2v_ok cores "$P2V_CORES" && break
	done
	P2V_CPU=$(ui_menu "5/5 VM" "CPU-Typ der VM:" -- \
		x86-64-v2-AES "kompatibel, zwischen den meisten Knoten migrierbar (empfohlen)" \
		x86-64-v3 "schneller, braucht AVX2 auf allen Knoten" \
		host "volle Leistung, nur auf gleicher CPU migrierbar") || return 1
	os=other
	((P2V_WIN)) && { [[ $fw == uefi ]] && os=win11 || os=win10; }
	P2V_OSTYPE=$(ui_menu "5/5 VM" "Betriebssystem der VM$( ((P2V_WIN)) && echo " (Windows gefunden)"):" --default-item "$os" -- \
		win11 "Windows 11 / Server 2022 und neuer" \
		win10 "Windows 10 / Server 2016, 2019" \
		win8 "Windows 8.x / Server 2012" \
		win7 "Windows 7 / Server 2008 R2" \
		l26 "Linux" \
		other "anderes") || return 1
	P2V_FIRMWARE=$(ui_menu "5/5 VM" "Firmware (erkannt: $fw, Partitionstabelle ${pt:-?}):" --default-item "$fw" -- \
		uefi "UEFI (OVMF)" \
		bios "BIOS (SeaBIOS)") || return 1
	P2V_TPM=0
	if [[ $P2V_FIRMWARE == uefi ]]; then
		if [[ $P2V_OSTYPE == win11 ]]; then
			ui_yesno "5/5 VM" "TPM 2.0 hinzufügen? Windows 11 verlangt es." && P2V_TPM=1
		else
			ui_yesno "5/5 VM" "TPM 2.0 hinzufügen?" --defaultno && P2V_TPM=1
		fi
	fi
	return 0
}

# p2v_confirm_step   Zeigt alles und verlangt die VM-ID. Eine leere Eingabe bestätigt nie.
p2v_confirm_step() {
	local s="" i got
	for i in "${!P2V_SRC[@]}"; do
		s+="  ${P2V_SRC[i]}  $(human "$(sudo blockdev --getsize64 "${P2V_SRC[i]}")")$([[ $i == "${P2V_SYS:-}" ]] && echo "  [Windows]")\n"
	done
	p2v_check_all || { die "Eine Angabe ist ungültig. Es wurde nichts angelegt."; return 1; }
	got=$(ui_input "Ziel bestätigen" "ACHTUNG: Neue VM anlegen und die Disks dorthin kopieren.\n\nKnoten:    $P2V_NODE ($P2V_USER@$P2V_HOST, Schlüssel ${P2V_FP: -8})\nSpeicher:  $P2V_STOR ($P2V_STYP, $P2V_FREE GiB frei)\nVM:        $P2V_VMID $P2V_NAME, $P2V_OSTYPE, $P2V_MEM MiB, $P2V_CORES Kerne, $P2V_CPU\nFirmware:  $P2V_FIRMWARE$([[ $P2V_TPM == 1 ]] && echo ", TPM 2.0")\nNetz:      $P2V_BRIDGE${P2V_VLAN:+, VLAN $P2V_VLAN}, e1000e\n\nQuell-Disks (schreibgeschützt, nur gelesen):\n$s\nDie VM startet zuerst mit SATA-Disks und e1000e, damit Windows ohne VirtIO-Treiber bootet.\n\nZur Bestätigung die VM-ID eingeben:") || return 1
	got=$(_safety_trim "$got")
	if [[ -z $got || $got != "$P2V_VMID" ]]; then
		ui_msg "Nicht bestätigt" "Die Eingabe passt nicht zur VM-ID. Es wurde nichts angelegt."
		log "P2V: Ziel nicht bestätigt (Eingabe '$got')"
		return 1
	fi
	log "P2V: Ziel bestätigt: VM $P2V_VMID auf $P2V_NODE, Speicher $P2V_STOR"
}

p2v_run_step() {
	local job="$P2V_DIR/kopie.sh" status="$P2V_DIR/kopie-status" start mins
	rm -f "$job" "$status"
	ui_info "VM anlegen" "Lege VM $P2V_VMID auf $P2V_NODE an …"
	if ! p2v_create; then
		die "Die VM ließ sich nicht vollständig anlegen. Details im Protokoll: $LF_LOG\n\nWas schon angelegt ist, steht in der Proxmox-Oberfläche unter VM $P2V_VMID."
		return 1
	fi
	if ! p2v_attach || ! p2v_job "$job" "$status"; then
		die "Die Volumes der VM ließen sich nicht einbinden. Es wurde nichts kopiert. Details im Protokoll: $LF_LOG"
		return 1
	fi
	start=$(date +%s)
	tmux_run "lf-p2v" sudo "$job"
	while tmux has-session -t lf-p2v 2>/dev/null; do
		ui_msg "Kopie läuft" "Die Kopie läuft noch im Hintergrund.\n\nOK zeigt die Ansicht wieder an." && tmux attach -t lf-p2v
	done
	p2v_detach
	if [[ $(cat "$status" 2>/dev/null) != OK ]]; then
		die "Die Kopie ist fehlgeschlagen. Details im Protokoll: $LF_LOG\n\nDie VM $P2V_VMID bleibt auf dem Knoten, bis du sie dort löschst."
		return 1
	fi
	mins=$((($(date +%s) - start) / 60))
	log "P2V: Kopie fertig nach $mins min"
	if ui_yesno "Fertig" "Fertig nach $mins Minuten.\n\nVM $P2V_VMID $P2V_NAME auf $P2V_NODE, Speicher $P2V_STOR.\n\nNächste Schritte in der VM:\n 1. Starten und anmelden, die Hardware wird neu erkannt.\n 2. VirtIO-Treiber und QEMU-Gastagent installieren (virtio-win.iso).\n 3. Danach Disks auf SCSI und Netz auf VirtIO umstellen.\n 4. Windows-Aktivierung prüfen.\n 5. Den alten Rechner nicht mehr gleichzeitig im selben Netz betreiben.\n\nVM jetzt starten?"; then
		p2v_r qm start "$P2V_VMID" >>"$LF_LOG" && ui_msg "VM läuft" "VM $P2V_VMID läuft. Die Konsole ist in der Proxmox-Oberfläche."
	fi
	return 0
}
