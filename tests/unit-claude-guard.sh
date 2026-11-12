#!/usr/bin/env bash
# Unit-Test: Die Sperre für Claude entscheidet, nicht das Modell.
#
# /etc/claude-code/CLAUDE.md nennt Regeln, an die sich Claude halten soll. Eine Regel ist aber nur
# Text im Kontext des Modells: Ein präparierter Datenträger oder ein Irrtum können das Modell
# dazu bringen, sie zu brechen. rescue/bin/frs-claude-guard ist ein PreToolUse-Hook von Claude
# Code. Er bekommt jeden Werkzeugaufruf vor der Ausführung und entscheidet selbst:
#   Rückgabe 2             gesperrt, der Aufruf läuft nicht,
#   Rückgabe 0 mit "ask"   der Techniker muss selbst bestätigen,
#   Rückgabe 0 ohne Text   keine Entscheidung.
# Der Test füttert das Skript mit Anfragen in der Form, in der Claude Code sie übergibt, und
# prüft die Entscheidung. Dazu prüft er die verwalteten Einstellungen, die das Skript eintragen.
# Dass Claude Code selbst sich daran hält, zeigt der Selbsttest der ISO (frs --selftest): Dort
# läuft die echte CLI gegen eine Attrappe der API.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

GUARD=rescue/bin/frs-claude-guard
SETTINGS=rescue/claude/managed-settings.json
T=$(mktemp -d)

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

# guard_json WERKZEUG EINGABE   Übergibt dem Skript eine Anfrage mit der Eingabe (JSON) des
#                               Werkzeugs. Ergebnis: RC, OUT (stdout), ERR, DECISION.
guard_json() {
	jq -cn --arg t "$1" --argjson i "$2" '{session_id: "s", cwd: "/run/frs/claude-session", permission_mode: "default",
		hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i, tool_use_id: "toolu_1"}' |
		"$GUARD" >"$T/out" 2>"$T/err"
	RC=$?
	OUT=$(cat "$T/out")
	ERR=$(cat "$T/err")
	DECISION=$(jq -r '.hookSpecificOutput.permissionDecision // ""' <<<"$OUT" 2>/dev/null)
}
# guard BEFEHL [WERKZEUG]   Anfrage eines Werkzeugs, das einen Shell-Befehl ausführt.
guard() { guard_json "${2:-Bash}" "$(jq -cn --arg c "$1" '{command: $c, description: "Test"}')"; }
# guard_file WERKZEUG PFAD [FELD]   Anfrage eines Werkzeugs, das eine Datei schreibt oder liest.
guard_file() { guard_json "$1" "$(jq -cn --arg p "$2" --arg k "${3:-file_path}" '{($k): $p, content: "x"}')"; }
denied() { [[ $RC == 2 && -z $OUT && $ERR == "Gesperrt vom Rettungssystem:"* ]]; }
asked() { [[ $RC == 0 && $DECISION == ask && -z $ERR ]]; }
passed() { [[ $RC == 0 && -z $OUT && -z $ERR ]]; }

# ---------------------------------------------------------------------------
echo "Gesperrt: Schreibschutz aufheben"
while IFS= read -r c; do
	[[ -n $c ]] || continue
	guard "$c"
	check "$c" denied
done <<'EOF'
blockdev --setrw /dev/sdb
sudo blockdev --setrw /dev/sdb
/usr/sbin/blockdev --setrw /dev/sdb1
sudo -n /sbin/blockdev  --setrw   /dev/nvme0n1
lsblk && sudo blockdev --setrw /dev/sdb
echo ok; blockdev --setrw /dev/sdb
bash -c 'blockdev --setrw /dev/sdb'
sudo sh -c "blockdev --setrw /dev/sdb && echo fertig"
blockdev --set''rw /dev/sdb
block"dev" --setr\w /dev/sdb
for d in /dev/sd?; do sudo blockdev --setrw $d; done
B=blockdev; sudo $B --setrw /dev/sdb
echo $(blockdev --setrw /dev/sdb)
timeout 5 blockdev --setrw /dev/sdb
hdparm -r0 /dev/sdb
sudo hdparm -r 0 /dev/sdb
echo 0 | sudo tee /sys/block/sdb/ro
sudo sh -c 'echo 0 > /sys/class/block/sdb1/ro'
echo 0 > /sys/block/mmcblk0/force_ro
grep x `sudo blockdev --setrw /dev/sdb`
python3 -c 'import fcntl,os; fcntl.ioctl(os.open("/dev/sdb",0), 0x125D, b"\0\0\0\0")'
sudo busybox blockdev --setrw /dev/sdb
sudo hdparm -r0 /dev/sdb; echo ok
sudo dd if=/dev/zero of=/sys/block/sdb/ro
EOF
guard $'lsblk\nsudo blockdev --setrw /dev/sdb'
check "über zwei Zeilen" denied
check "die Begründung nennt die Regel und sagt, was Claude tun soll" '[[ $ERR == *"Schreibschutz"*"Sag dem Techniker"* ]]'

echo "Gesperrt: Sperre, Regeln und Liste der Quell-Disks"
while IFS= read -r c; do
	[[ -n $c ]] || continue
	guard "$c"
	check "$c" denied
done <<'EOF'
sudo rm /etc/claude-code/managed-settings.json
sudo sed -i 's/deny/allow/' /etc/claude-code/managed-settings.json
cat /etc/claude-code/CLAUDE.md
sudo mv /usr/local/bin/frs-claude-guard /tmp/
sudo chmod -x /usr/local/bin/frs-claude-guard
echo > /run/frs/readonly
sudo rm -f /run/frs/readonly
sudo sed -i '/sdb/d' /run/frs/readonly
sudo tee /run/frs/readonly </dev/null
sudo chattr -i /run/frs/readonly
: > /run/frs/readonly
sudo cp /usr/local/bin/frs-claude-guard /tmp/x
sudo sed -i -e /sdb/d /run/frs/readonly
sudo truncate -s 0 /run/frs/readonly
EOF

echo "Gesperrt: Reparatur auf dem Original-Image"
while IFS= read -r c; do
	[[ -n $c ]] || continue
	guard "$c"
	check "$c" denied
done <<'EOF'
sudo ntfsfix /mnt/frs-target/FRS/x/image.img
sudo e2fsck -fy /mnt/frs-target/FRS/x/image.img
fsck.ext4 -y "/mnt/frs-target/FRS/x/image.img"
sudo xfs_repair /mnt/frs-target/FRS/x/image.img
sudo testdisk /mnt/frs-target/FRS/x/image.img
sudo e2fsck /mnt/frs-target/FRS/x/image.img
cd /mnt/frs-target/FRS/x && sudo ntfsfix image.img
IMG=/mnt/frs-target/FRS/x/image.img; sudo ntfsfix "$IMG"
for f in /mnt/frs-target/FRS/x/image.img; do sudo e2fsck -y $f; done
sudo btrfs check --repair /mnt/frs-target/FRS/x/image.img
sudo btrfs rescue zero-log /mnt/frs-target/FRS/x/image.img
sudo debugfs -w /mnt/frs-target/FRS/x/image.img
sudo ls -n /tmp; sudo e2fsck -y /mnt/frs-target/FRS/x/image.img
EOF
# Die Kopie reparieren und das Original nur lesend prüfen ist nicht gesperrt.
guard "cp --reflink=auto /mnt/frs-target/FRS/x/image.img /mnt/frs-target/FRS/x/image.img.repair && sudo ntfsfix /mnt/frs-target/FRS/x/image.img.repair"
check "Kopie anlegen und die Kopie reparieren: nicht gesperrt, aber zu bestätigen" asked
guard "sudo e2fsck -n /mnt/frs-target/FRS/x/image.img"
check "das Original nur lesend prüfen (e2fsck -n): keine Entscheidung" passed
guard "sudo xfs_repair -n /mnt/frs-target/FRS/x/image.img"
check "das Original nur lesend prüfen (xfs_repair -n): keine Entscheidung" passed

echo "Der Techniker bestätigt selbst: schreibende Befehle"
while IFS= read -r c; do
	[[ -n $c ]] || continue
	guard "$c"
	check "$c" asked
done <<'EOF'
sudo dd if=/dev/zero of=/dev/sdc bs=4M
dd if=image.img of=/dev/sdc
sudo mkfs.ext4 /dev/sdc1
sudo mkfs -t ext4 /dev/sdc1
/usr/sbin/mkfs.ntfs -Q /dev/sdc1
sudo mkswap /dev/sdc2
sudo sfdisk /dev/sdc < tabelle
sudo sgdisk -Z /dev/sdc
sudo sgdisk -p /dev/sdb; sudo sgdisk -Z /dev/sdc
sudo sgdisk -p -o /dev/sdc
sudo sgdisk -e /dev/sdc
sudo sfdisk --delete /dev/sdc 1
sudo fdisk -l /dev/sdb && sudo fdisk /dev/sdc
sudo parted -s /dev/sdc mkpart primary ext4 1MiB 100%
sudo parted /dev/sdb print; sudo parted /dev/sdc rm 1
sudo gdisk /dev/sdc
sudo cfdisk /dev/sdc
sudo wipefs --all /dev/sdc
sudo sfdisk</tmp/tabelle /dev/sdc
sudo sfdisk /dev/sdc < /tmp/tabelle
echo ",,L" | sudo sfdisk /dev/sdc
sudo sgdisk /dev/sdc
sudo sgdisk -pZ /dev/sdc
echo $(sudo sgdisk -Z /dev/sdc)
sudo parted /dev/sdc
sudo parted /dev/sdb print >/dev/sdc
sudo parted /dev/sdc mklabel gpt
sudo fdisk /dev/sdc
sudo wipefs -a /dev/sdc
sudo blkdiscard /dev/sdc
sudo ntfsfix /dev/sdc1
sudo ntfsfix /mnt/frs-target/FRS/x/image.img.repair
sudo e2fsck -fy /dev/sdc1
sudo fsck /dev/sdc1
sudo fsck.vfat -a /dev/sdc1
sudo xfs_repair /dev/sdc1
sudo btrfs check --repair /dev/sdc1
sudo resize2fs /dev/sdc1
sudo ntfsresize -s 100G /dev/sdc1
sudo mount /dev/sdc1 /mnt/x
sudo mount -o rw /dev/sdc1 /mnt/x
sudo mount -o remount,rw /mnt/x
sudo mount -t ntfs3 /dev/sdc1 /mnt/x
sudo losetup -fP image.img
sudo qemu-nbd -c /dev/nbd0 image.img
sudo ddrescue /dev/sdb image.img image.map
sudo partclone.ntfs -b -s /dev/sdb1 -o /dev/sdc1
sudo nvme format /dev/nvme0n1 --ses=1
sudo hdparm --security-erase frs /dev/sdc
sudo smartctl -t long /dev/sdb
sudo badblocks -sv /dev/sdb
sudo shred -n1 /dev/sdc
sudo cryptsetup luksFormat /dev/sdc1
sudo cryptsetup open /dev/sdc1 daten
sudo vgchange -ay
sudo mdadm --assemble --scan
sudo lvcreate -L 10G -n neu vg0
echo x | sudo tee /dev/sdc
cat image.img > /dev/sdc
sudo sh -c 'cat image.img >/dev/nvme0n1'
sudo grub-install /dev/sdc
sudo mount /dev/sdc1 /mnt/x; ls -r /mnt
sudo mount /dev/sdc1 /mnt/a; sudo mount -o ro /dev/sdb1 /mnt/b
sudo mount -o ro,rw /dev/sdb1 /mnt/x
sudo systemd-mount /dev/sdb1 /mnt/x
sudo losetup -fP image.img; ls -l /dev/loop*
sudo fsck /dev/sdc1; sort -n liste
sudo wipefs -a /dev/sdc; sort -n liste
sudo qemu-nbd -c /dev/nbd0 image.img; ls -s
sudo kpartx -a image.img
sudo ntfs-3g /dev/sdb1 /mnt/x
sudo mount.ntfs /dev/sdb1 /mnt/x
sudo dislocker -V /dev/sdb2 -u -- /mnt/dl
sudo swapon /dev/sdb3
sudo cp image.img /dev/sdc
sudo md5sum /dev/sdb
sudo cat /dev/sdb | gzip > /mnt/frs-target/sdb.gz
sudo dd if=/dev/sdb bs=1M | zstd > /mnt/frs-target/sdb.zst
sudo grep -a geheim /dev/sdb1
sudo strings -n 8 /dev/sdb
gzip -c </dev/sdb >x.gz
rm /mnt/frs-target/FRS/x/image.img
mv /mnt/frs-target/FRS/x/image.map /tmp/
: > /mnt/frs-target/FRS/x/image.map
cp /dev/null /mnt/frs-target/FRS/x/image.img
truncate -s 0 /mnt/frs-target/FRS/x/image.img
sudo cryptsetup luksErase --readonly /dev/sdb2
sudo cryptsetup luksDump /dev/sdb2; sudo cryptsetup luksFormat /dev/sdc1
sudo qemu-img convert -O raw x.qcow2 /dev/sdc
sudo qemu-img check -r all x.qcow2
sudo smartctl -s on /dev/sdb
sudo smartctl -l scterc,70,70 /dev/sdb
sudo hdparm -Y /dev/sdb
sudo hdparm -tT /dev/sdb
sudo hdparm -N p1000000 /dev/sdb
sudo nvme set-feature /dev/nvme0 -f 2 -v 0
sudo nvme sanitize /dev/nvme0n1
sudo sdparm --set WCE=0 /dev/sdb
sudo dmsetup remove_all
sudo vgimport vg0
sudo btrfs scrub start /mnt/x
sudo xfs_repair /dev/sdc1
sudo tune2fs -O ^has_journal /dev/sdc1
sudo debugfs -w /dev/sdc1
sudo efibootmgr -b 0001 -B
sudo os-prober
sudo safecopy /dev/sdb x.img
echo 1 | sudo tee /sys/block/sdb/device/delete
sudo frs-rescue-run /mnt/frs-target/FRS/x /dev/sdb
bash -c '. /usr/local/lib/frs/common.sh; . /usr/local/lib/frs/target.sh; target_mount_part /dev/sdc1 ext4'
grep x `sudo nvme format /dev/nvme0n1`
echo $(grep -c x f; sudo mkfs.ext4 /dev/sdc1)
sudo mount -o ro -w /dev/sdb1 /mnt/x
rm -rf /mnt/frs-target/FRS/20261112-0900_Modell_1234
sudo sed -i s/a/b/ /usr/local/lib/frs/safety.sh
echo "true" | sudo tee -a /usr/local/lib/frs/common.sh
sudo cp /tmp/frs /usr/local/bin/frs
sudo parted --script /dev/sdc mklabel gpt
EOF
guard "sudo mkfs.ext4 /dev/sdc1"
check "die Rückfrage sagt dem Techniker, warum" '[[ $(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$OUT") == "Rettungssystem: ein Dateisystem wird neu angelegt. Der Techniker bestätigt"*"Seriennummer"* && $(jq -r .hookSpecificOutput.hookEventName <<<"$OUT") == PreToolUse ]]'

# Suchwerkzeuge fallen aus der Prüfung der Programmnamen heraus ("dmesg | grep -i nvme"). Das darf
# keinen Befehl verstecken.
echo "Der Techniker bestätigt selbst: Befehle hinter oder in einem Suchwerkzeug"
while IFS= read -r c; do
	[[ -n $c ]] || continue
	guard "$c"
	check "$c" asked
done <<'EOF'
grep "x$(sudo nvme format /dev/nvme0n1)" datei
grep "${ sudo nvme format /dev/nvme0n1; }" datei
grep 'a|b' datei; sudo mkfs.ext4 /dev/sdc1
grep 'a|b' datei && sudo nvme format /dev/nvme0n1
which nvme && sudo nvme format /dev/nvme0n1
grep x datei | sudo tee /dev/sdc
grep -r x . > /mnt/frs-target/FRS/x/image.img
/tmp/grep nvme format /dev/nvme0n1
grep -q x datei || { sudo swapon /dev/sdb3; }
pgrep ddrescue || sudo ddrescue /dev/sdb image.img image.map
EOF
guard $'grep x <<EOF\nit\'s\nEOF\nsudo nvme format /dev/nvme0n1 # don\'t'
check "Here-Dokument mit Anführungszeichen vor einem schreibenden Befehl" asked
guard $'grep x datei # it\'s\nsudo nvme format /dev/nvme0n1 # don\'t'
check "Kommentar mit Anführungszeichen hinter einem Suchwerkzeug, Befehl in der nächsten Zeile" asked
guard 'echo "Systeme: `sudo os-prober`"'
check "Befehl in Backticks, direkt vor dem schließenden Backtick" asked
guard $'grep x datei \\\n  | sudo tee /dev/sdc'
check "Zeilenfortsetzung vor einer Pipe auf ein Blockgerät" asked
guard $'sudo mount /dev/sdb1 /mnt/x \\\n  -o ro,noload'
check "Zeilenfortsetzung: mount mit ro in der zweiten Zeile bleibt lesend" passed

echo "Keine Entscheidung: lesende Befehle"
while IFS= read -r c; do
	[[ -n $c ]] || continue
	guard "$c"
	check "$c" passed
done <<'EOF'
lsblk -o NAME,SIZE,MODEL,SERIAL,RO
sudo smartctl -x /dev/sdb
sudo smartctl -a /dev/sdb | head -40
dmesg | tail -50
sudo blkid /dev/sdb1
sudo blockdev --getro /dev/sdb
sudo blockdev --setro /dev/sdb
sudo file -s /dev/sdb1
ddrescuelog -t /mnt/frs-target/FRS/x/image.map
cat /run/frs/readonly
sort -u /run/frs/readonly | wc -l
sudo mount -o ro,noload /dev/sdb1 /mnt/x
sudo mount -t ntfs3 -o ro /dev/sdb1 /mnt/x
sudo mount -r /dev/sdb1 /mnt/x
sudo mount --read-only /dev/sdb1 /mnt/x
mount | grep frs
mount
findmnt /mnt/frs-target
sudo umount /mnt/x
sudo e2fsck -n /dev/sdb1
sudo fsck -fn /dev/sdb1
sudo losetup -r -fP image.img
sudo losetup -a
sudo losetup -d /dev/loop3
sudo qemu-nbd -r -c /dev/nbd0 image.img
sudo cryptsetup luksDump /dev/sdb2
sudo cryptsetup open --readonly /dev/sdb2 daten
sudo hdparm -I /dev/sdb
sudo nvme smart-log /dev/nvme0n1
sudo sgdisk -p /dev/sdb
sudo sgdisk -v /dev/sdb
sudo sgdisk -i 2 /dev/sdb
sudo sfdisk -d /dev/sdb
sudo sfdisk -J /dev/sdb | jq .
sudo sfdisk -l
sudo fdisk -l /dev/sdb
sudo fdisk -l
sudo gdisk -l /dev/sdb
sudo parted /dev/sdb print
sudo parted -s /dev/sdb unit MiB print free
sudo parted -l
sudo parted -s /dev/sdb print 2>/dev/null
sudo parted -s /dev/sdb print 2>&1 | head -20
sudo sfdisk -d /dev/sdb > /tmp/tabelle.txt
sudo wipefs /dev/sdb
sudo wipefs -n -a /dev/sdb
ls -la /mnt/frs-image/loop0p2
rsync -a /mnt/frs-image/loop0p2/Users/ /mnt/frs-target/FRS/x/dateien/
tmux attach -t frs-rettung
dd if=/dev/sdb bs=512 count=1 | xxd | head
cat /mnt/frs-target/FRS/x/report.txt
grep -r mountpoint /usr/local/lib/frs
dmesg | grep -i nvme
sudo dmesg | grep -iE 'ata|nvme|I/O error'
ps aux | grep ddrescue
lsmod | grep btrfs
lsblk -f | grep -i ntfs
grep -rn "mount " /usr/local/lib/frs/target.sh
which sgdisk parted ddrescue
ls /dev/nvme*
ls -l /dev/disk/by-id/
sudo mount -t btrfs -o ro,rescue=nologreplay /dev/sdb1 /mnt/x
sudo mount -o ro -t ntfs-3g /dev/sdb1 /mnt/x
sudo mount -o ro /dev/sdb1 /mnt/x; ls -l /mnt/x
sudo ntfs-3g -o ro,norecover /dev/sdb1 /mnt/x
sudo dislocker -r -V /dev/sdb2 -u -- /mnt/dl
sudo xxd -l 512 /dev/sdb
sudo hexdump -C -n 512 /dev/sdb
sudo dd if=/dev/sdb bs=512 count=8 | xxd | head
sudo kpartx -l image.img
sudo kpartx -ar image.img
sudo qemu-img info x.qcow2
sudo cryptsetup close daten
sudo mdadm --detail /dev/md0
sudo mdadm --examine --scan
sudo dmsetup ls
sudo btrfs filesystem show
sudo tune2fs -l /dev/sdb1
sudo xfs_repair -n /dev/sdb1
sudo efibootmgr -v
sudo sdparm --all /dev/sdb
sudo nvme id-ctrl /dev/nvme0 -H
sudo smartctl -l error /dev/sdb
sudo smartctl -l scterc /dev/sdb
sudo partclone.info -s teil.img
cp /mnt/frs-target/FRS/x/image.img /mnt/frs-target/FRS/x/image.img.repair
md5sum /mnt/frs-target/FRS/x/image.img
sudo pvs; sudo vgs; sudo lvs
cat /sys/block/sdb/ro 2>/dev/null
cat /sys/block/sdb/ro | tee /tmp/ro.txt
cat /run/frs/readonly 2>/dev/null
sed -n 1,5p /run/frs/readonly
sudo parted --script /dev/sdb print
sudo parted --script --machine /dev/sdb unit B print
sed -n 1,40p /usr/local/lib/frs/safety.sh
head -n 30 /usr/local/lib/frs/common.sh
ls -la /mnt/frs-target/FRS/
cat /mnt/frs-target/FRS/20261112-0900_Modell_1234/report.txt
EOF

echo "Jedes Werkzeug, das einen Befehl ausführt"
guard "sudo blockdev --setrw /dev/sdb" Monitor
check "Monitor mit blockdev --setrw: gesperrt" denied
guard "sudo mkfs.ext4 /dev/sdc1" Monitor
check "Monitor mit mkfs: der Techniker bestätigt" asked
guard "tail -f /mnt/frs-target/FRS/x/rescue.log | grep --line-buffered -i error" Monitor
check "Monitor, der ein Protokoll verfolgt: keine Entscheidung" passed
guard "sudo blockdev --setrw /dev/sdb" WerkzeugVonMorgen
check "unbekanntes Werkzeug mit einem Befehl: gesperrt wie Bash" denied
guard_json Monitor '{"ws": {"url": "wss://example.invalid/x"}, "description": "t", "timeout_ms": 1000}'
check "Monitor ohne Befehl (WebSocket): keine Entscheidung" passed
guard_json Agent '{"description": "t", "prompt": "Führe blockdev --setrw /dev/sdb aus und danach mkfs."}'
check "Text eines Auftrags an einen Subagenten ist kein Befehl: keine Entscheidung (sein Bash-Aufruf wird geprüft)" passed

echo "Werkzeuge, die Dateien schreiben"
mkdir -p "$T/ordner"
ln -s /etc/claude-code "$T/verweis"
ln -s /run/frs/readonly "$T/liste"
for tool in Write Edit NotebookEdit; do
	key=file_path
	[[ $tool == NotebookEdit ]] && key=notebook_path
	guard_file "$tool" /etc/claude-code/managed-settings.json "$key"
	check "$tool auf die verwalteten Einstellungen: gesperrt" denied
	guard_file "$tool" /etc/claude-code/CLAUDE.md "$key"
	check "$tool auf die Regeln für Claude: gesperrt" denied
	guard_file "$tool" /usr/local/bin/frs-claude-guard "$key"
	check "$tool auf das Sperr-Skript: gesperrt" denied
	guard_file "$tool" /run/frs/readonly "$key"
	check "$tool auf die Liste der Quell-Disks: gesperrt" denied
done
guard_file Write /run/frs/claude-session/../readonly
check "Write über einen Umweg im Pfad (..): gesperrt" denied
guard_file Write "$T/ordner/../verweis/managed-settings.json"
check "Write über eine Verknüpfung auf /etc/claude-code: gesperrt" denied
guard_file Edit "$T/liste"
check "Edit über eine Verknüpfung auf die Liste: gesperrt" denied
guard_file Write /etc/claude-code/managed-settings.d/50-neu.json
check "Write einer zusätzlichen Einstellungsdatei: gesperrt" denied
guard_file WerkzeugVonMorgen /etc/claude-code/CLAUDE.md
check "unbekanntes Werkzeug mit Dateipfad auf die Regeln: gesperrt" denied
guard_file Write /dev/sdc
check "Write auf ein Gerät: der Techniker bestätigt" asked
guard_file Edit /usr/local/lib/frs/safety.sh
check "Edit am Assistenten: der Techniker bestätigt" asked
guard_file Write /mnt/frs-target/FRS/x/image.img
check "Write auf das Original-Image: der Techniker bestätigt" asked
guard_file Read /etc/claude-code/CLAUDE.md
check "Read auf die Regeln: keine Entscheidung (Claude darf sie lesen)" passed
guard_file Write /run/frs/claude-session/notiz.txt
check "Write im Arbeitsverzeichnis: keine Entscheidung" passed
guard_file Edit /mnt/frs-target/FRS/x/report.txt
check "Edit am Bericht: keine Entscheidung" passed
guard_json Read '{"file_path": "/run/frs/claude-session/zustand.txt"}'
check "Read der Zustandsdatei: keine Entscheidung" passed
guard_json Grep '{"pattern": "setrw", "path": "/usr/local/lib/frs"}'
check "Grep: keine Entscheidung" passed
guard_json ToolSearch '{"query": "x", "max_results": 3}'
check "Werkzeug ohne Befehl und Pfad: keine Entscheidung" passed

echo "Unlesbare Anfragen"
guard_json Write '{"file_path": ["/etc/claude-code/CLAUDE.md"], "content": "x"}'
check "Pfad ist kein Text: gesperrt" '[[ $RC == 2 ]]'
guard_json Bash '"blockdev --setrw /dev/sdb"'
check "Eingabe ist kein Objekt: gesperrt" '[[ $RC == 2 ]]'
"$GUARD" </dev/null >"$T/out" 2>"$T/err"
rc=$?
check "leere Anfrage: gesperrt" '[[ $rc == 2 && $(cat "$T/err") == "Gesperrt vom Rettungssystem:"* ]]'
echo '{kein JSON' | "$GUARD" >"$T/out" 2>"$T/err"
rc=$?
check "kein JSON: gesperrt" '[[ $rc == 2 ]]'
echo '{"tool_name":"Bash","tool_input":{}}' | "$GUARD" >"$T/out" 2>"$T/err"
rc=$?
check "Bash ohne Befehl: gesperrt" '[[ $rc == 2 ]]'
echo '{"tool_name":"Bash","tool_input":{"command":["blockdev","--setrw"]}}' | "$GUARD" >"$T/out" 2>"$T/err"
rc=$?
check "Befehl ist kein Text: gesperrt" '[[ $rc == 2 ]]'
PATH=/nirgends "$GUARD" </dev/null >"$T/out" 2>"$T/err"
rc=$?
check "ohne jq und andere Werkzeuge im PATH: kein Durchwinken" '[[ $rc != 0 ]]'

# ---------------------------------------------------------------------------
echo "Verwaltete Einstellungen ($SETTINGS):"
check "gültiges JSON" 'jq -e . "$SETTINGS" >/dev/null'
check "der Hook gilt für jedes Werkzeug und ruft das Sperr-Skript unter seinem Pfad in der ISO auf" '[[ $(jq -r ".hooks.PreToolUse[] | select(.matcher == \"*\") | .hooks[0] | .type + \" \" + .command" "$SETTINGS") == "command /usr/local/bin/frs-claude-guard" ]]'
check "es gibt nur diesen einen Hook" '[[ $(jq -r "[.hooks[][] | .hooks[]] | length" "$SETTINGS") == 1 ]]'
check "scheitert der Hook, wird gesperrt (onFailure: block)" '[[ $(jq -r ".hooks.PreToolUse[0].hooks[0].onFailure" "$SETTINGS") == block ]]'
check "der Hook hat eine kurze Frist" '[[ $(jq -r ".hooks.PreToolUse[0].hooks[0].timeout" "$SETTINGS") =~ ^([1-9]|[12][0-9]|30)$ ]]'
check "Deny-Regeln als zweite Schicht für das Aufheben des Schreibschutzes" 'jq -e ".permissions.deny | index(\"Bash(*--setrw*)\") != null and index(\"Bash(*hdparm*-r0*)\") != null" "$SETTINGS" >/dev/null'
check "Deny-Regeln für die Dateiwerkzeuge: Einstellungen, Sperr-Skript und Liste der Quell-Disks" 'jq -e ".permissions.deny | index(\"Edit(//etc/claude-code/**)\") != null and index(\"Edit(//usr/local/bin/frs-claude-guard)\") != null and index(\"Edit(//run/frs/readonly)\") != null" "$SETTINGS" >/dev/null'
check "der Modus ohne Rückfragen ist abgeschaltet" '[[ $(jq -r ".permissions.disableBypassPermissionsMode" "$SETTINGS") == disable ]]'
check "der Auto-Modus ist abgeschaltet: Über Befehle entscheidet der Techniker, kein Klassifikator" '[[ $(jq -r ".disableAutoMode" "$SETTINGS") == disable ]]'
check "Hooks kommen nur aus dem Rettungssystem, nicht aus einem Projektordner" '[[ $(jq -r ".allowManagedHooksOnly" "$SETTINGS") == true ]]'
check "Erlaubnis-Regeln gelten nur aus dem Rettungssystem: Keine Regel von außen schaltet eine Rückfrage ab" '[[ $(jq -r ".allowManagedPermissionRulesOnly" "$SETTINGS") == true ]]'
check "keine Regel erlaubt etwas von selbst" '[[ $(jq -r ".permissions.allow // [] | length" "$SETTINGS") == 0 ]]'
check "das Sperr-Skript ist ausführbar und liegt bei den Programmen des Assistenten" '[[ -x $GUARD ]] && grep -q "rescue/bin/\*" build/build.sh'
check "der Build legt die Einstellungen dorthin, wo Claude Code sie als verwaltet liest" 'grep -q "rescue/claude/managed-settings.json\" \"\$CHROOT/etc/claude-code/managed-settings.json\"" build/build.sh'
check "die Regeln für Claude nennen die Sperre" 'grep -q "frs-claude-guard" rescue/claude/CLAUDE.md'
check "der Selbsttest der ISO prüft die Sperre mit der echten CLI" 'grep -q "selftest_claude \"\$dir\" || ok=0" rescue/frs && [[ -f rescue/lib/selftest-claude-api.py ]]'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
