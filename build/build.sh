#!/usr/bin/env bash
# Baut die Firestrike-Rescue-ISO.
# Läuft als root in einem Ubuntu-26.04-Container (privileged) oder auf einem Ubuntu-26.04-Host.
#
#   sudo build/build.sh            # vollständiger Build nach ./out
#   WORK=/tmp/frs-work build/build.sh
#
# Umgebungsvariablen:
#   SUITE   Ubuntu-Codename (Standard: resolute = 26.04 LTS)
#   MIRROR  Ubuntu-Archiv (Standard: http://archive.ubuntu.com/ubuntu)
#   WORK    Arbeitsverzeichnis (Standard: ./work)
#   OUT     Ausgabeverzeichnis (Standard: ./out)
#   FRS_VERSION  Versionsstring (Standard: 26.04-JJJJMMTT)

set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${SUITE:-resolute}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
WORK="${WORK:-$SRC/work}"
OUT="${OUT:-$SRC/out}"
FRS_VERSION="${FRS_VERSION:-26.04-$(date -u +%Y%m%d)}"
ISO_LABEL="FRS_RESCUE"
ISO_NAME="firestrike-rescue-${FRS_VERSION}-amd64.iso"

CHROOT="$WORK/chroot"
ISO="$WORK/iso"

log() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "build.sh muss als root laufen."

# ---------------------------------------------------------------------------
# Mounts im chroot, beim Beenden immer aufräumen
# ---------------------------------------------------------------------------
chroot_mount() {
	mount --bind /dev "$CHROOT/dev"
	mount --bind /dev/pts "$CHROOT/dev/pts"
	mount -t proc proc "$CHROOT/proc"
	mount -t sysfs sysfs "$CHROOT/sys"
	mount -t tmpfs tmpfs "$CHROOT/run"
	mount -t tmpfs tmpfs "$CHROOT/tmp"
}

chroot_umount() {
	local m
	for m in tmp run sys proc dev/pts dev; do
		mountpoint -q "$CHROOT/$m" 2>/dev/null && umount -lf "$CHROOT/$m" || true
	done
}
trap chroot_umount EXIT

in_chroot() { chroot "$CHROOT" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive "$@"; }

# ---------------------------------------------------------------------------
# 1. Host-Werkzeuge
# ---------------------------------------------------------------------------
host_deps() {
	log "Installiere Build-Werkzeuge auf dem Host"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends \
		debootstrap squashfs-tools xorriso mtools dosfstools \
		grub-common fonts-dejavu-core tex-gyre python3 ca-certificates curl gnupg >/dev/null
}

# ---------------------------------------------------------------------------
# 2. Root-Dateisystem
# ---------------------------------------------------------------------------
bootstrap() {
	log "debootstrap $SUITE"
	rm -rf "$WORK"
	mkdir -p "$CHROOT" "$ISO" "$OUT"
	debootstrap --arch=amd64 --variant=minbase \
		--components=main,restricted,universe,multiverse \
		"$SUITE" "$CHROOT" "$MIRROR"

	# Quellen inkl. Updates und Security, damit jeder Build alle Patches enthält
	rm -f "$CHROOT/etc/apt/sources.list"
	cat >"$CHROOT/etc/apt/sources.list.d/ubuntu.sources" <<-EOF
		Types: deb
		URIs: $MIRROR
		Suites: $SUITE $SUITE-updates $SUITE-backports
		Components: main restricted universe multiverse
		Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

		Types: deb
		URIs: http://security.ubuntu.com/ubuntu
		Suites: $SUITE-security
		Components: main restricted universe multiverse
		Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
	EOF
	echo "frs" >"$CHROOT/etc/hostname"
}

# ---------------------------------------------------------------------------
# 3. Pakete, Konfiguration, Claude
# ---------------------------------------------------------------------------
configure() {
	log "Kopiere Overlay und Assistent"
	cp -a "$SRC/build/overlay/." "$CHROOT/"
	install -d "$CHROOT/usr/local/lib/frs" "$CHROOT/usr/local/share/frs"
	cp -a "$SRC/rescue/lib/." "$CHROOT/usr/local/lib/frs/"
	cp -a "$SRC/rescue/theme" "$CHROOT/usr/local/share/frs/"
	install -m 0755 "$SRC/rescue/frs" "$CHROOT/usr/local/bin/frs"
	for f in "$SRC"/rescue/bin/*; do
		install -m 0755 "$f" "$CHROOT/usr/local/bin/$(basename "$f")"
	done
	install -D -m 0644 "$SRC/rescue/claude/CLAUDE.md" "$CHROOT/etc/claude-code/CLAUDE.md"
	install -m 0644 "$SRC/build/packages.list" "$CHROOT/tmp/packages.list"
	install -m 0755 "$SRC/build/chroot-setup.sh" "$CHROOT/tmp/chroot-setup.sh"

	cat >"$CHROOT/etc/frs-release" <<-EOF
		FRS_VERSION=$FRS_VERSION
		FRS_BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		FRS_BASE="Ubuntu 26.04 LTS ($SUITE)"
		FRS_SOURCE=https://github.com/Celestial0579/firestrike-rescue
	EOF

	log "Paketinstallation und Einrichtung im chroot"
	in_chroot /tmp/chroot-setup.sh
	rm -f "$CHROOT/tmp/chroot-setup.sh" "$CHROOT/tmp/packages.list"
}

# ---------------------------------------------------------------------------
# 4. Boot-Dateien und GRUB-Theme
# ---------------------------------------------------------------------------
# Liest den internen Fontnamen aus einer .pf2-Datei (Chunk "NAME").
pf2_name() {
	python3 - "$1" <<-'PY'
		import struct, sys
		d = open(sys.argv[1], "rb").read()
		i = 0
		while i + 8 <= len(d):
		    typ = d[i:i+4]; ln = struct.unpack(">I", d[i+4:i+8])[0]
		    if typ == b"NAME":
		        print(d[i+8:i+8+ln].rstrip(b"\0").decode()); break
		    if typ == b"CHIX": break
		    i += 8 + ln
	PY
}

# Schreibt ein einfarbiges PNG (für GRUB-Auswahlbalken), ohne ImageMagick.
solid_png() {
	python3 - "$1" "$2" <<-'PY'
		import struct, sys, zlib
		path, hexcol = sys.argv[1], sys.argv[2].lstrip("#")
		r, g, b = (int(hexcol[i:i+2], 16) for i in (0, 2, 4))
		w = h = 4
		raw = b"".join(b"\0" + bytes((r, g, b)) * w for _ in range(h))
		def chunk(t, data):
		    c = struct.pack(">I", len(data)) + t + data
		    return c + struct.pack(">I", zlib.crc32(t + data) & 0xffffffff)
		png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
		png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
		open(path, "wb").write(png)
	PY
}

boot_files() {
	log "Kernel, initrd und memtest86+ übernehmen"
	install -d "$ISO/casper" "$ISO/boot/grub" "$ISO/.disk" "$ISO/EFI/boot"
	cp "$(readlink -f "$CHROOT/boot/vmlinuz")" "$ISO/casper/vmlinuz"
	cp "$(readlink -f "$CHROOT/boot/initrd.img")" "$ISO/casper/initrd"
	for f in memtest86+x64.efi memtest86+x64.bin; do
		[[ -f "$CHROOT/boot/$f" ]] && cp "$CHROOT/boot/$f" "$ISO/boot/$f"
	done

	# Ubuntus signierter GRUB sucht /.disk/info und lädt dann /boot/grub/grub.cfg
	echo "Firestrike Rescue $FRS_VERSION - Ubuntu 26.04 LTS amd64" >"$ISO/.disk/info"
	sed "s/@VERSION@/$FRS_VERSION/g" "$SRC/build/grub/grub.cfg" >"$ISO/boot/grub/grub.cfg"
	cp "$ISO/boot/grub/grub.cfg" "$ISO/EFI/boot/grub.cfg"

	log "GRUB-Theme (Firestrike-Farben)"
	local theme="$ISO/boot/grub/themes/firestrike"
	install -d "$theme" "$ISO/boot/grub/fonts"
	cp "$SRC/build/grub/theme/theme.txt" "$theme/theme.txt"
	solid_png "$theme/select_c.png" "#AB5019"
	solid_png "$theme/select_w.png" "#AB5019"
	solid_png "$theme/select_e.png" "#AB5019"

	local pagella dejavu title_font menu_font
	pagella="$(find /usr/share -iname 'texgyrepagella-regular.otf' | head -n1)"
	dejavu="$(find /usr/share/fonts -iname 'DejaVuSansMono.ttf' | head -n1)"
	[[ -n $pagella && -n $dejavu ]] || die "Schriften für das GRUB-Theme fehlen."
	grub-mkfont -s 36 -o "$theme/title.pf2" "$pagella"
	grub-mkfont -s 18 -o "$theme/menu.pf2" "$dejavu"
	grub-mkfont -s 14 -o "$theme/small.pf2" "$dejavu"
	cp "$CHROOT/usr/share/grub/unicode.pf2" "$ISO/boot/grub/fonts/unicode.pf2"
	title_font="$(pf2_name "$theme/title.pf2")"
	menu_font="$(pf2_name "$theme/menu.pf2")"
	sed -i -e "s/@TITLE_FONT@/$title_font/" -e "s/@MENU_FONT@/$menu_font/" \
		-e "s/@SMALL_FONT@/$(pf2_name "$theme/small.pf2")/" -e "s/@VERSION@/$FRS_VERSION/" \
		"$theme/theme.txt"

	log "BIOS-Bootloader"
	install -d "$ISO/boot/grub/i386-pc"
	cp "$CHROOT"/usr/lib/grub/i386-pc/*.mod "$CHROOT"/usr/lib/grub/i386-pc/*.lst "$ISO/boot/grub/i386-pc/"
	in_chroot grub-mkimage -O i386-pc-eltorito -d /usr/lib/grub/i386-pc \
		-o /tmp/eltorito.img -p /boot/grub \
		biosdisk iso9660 part_gpt part_msdos normal search search_fs_file search_label \
		configfile linux linux16 gfxterm gfxmenu png all_video font echo test true
	mv "$CHROOT/tmp/eltorito.img" "$ISO/boot/grub/i386-pc/eltorito.img"
	cp "$CHROOT/usr/lib/grub/i386-pc/boot_hybrid.img" "$WORK/boot_hybrid.img"

	log "UEFI-Bootloader (Secure Boot: shim + signierter GRUB)"
	local shim grub mm
	shim="$(ls "$CHROOT"/usr/lib/shim/shimx64.efi.signed.latest 2>/dev/null || ls "$CHROOT"/usr/lib/shim/shimx64.efi.signed)"
	grub="$CHROOT/usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed"
	[[ -f $grub ]] || grub="$CHROOT/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
	mm="$CHROOT/usr/lib/shim/mmx64.efi"
	cp "$shim" "$ISO/EFI/boot/bootx64.efi"
	cp "$grub" "$ISO/EFI/boot/grubx64.efi"
	[[ -f $mm ]] && cp "$mm" "$ISO/EFI/boot/mmx64.efi"

	# FAT-Image für die El-Torito-UEFI-Bootoption und die angehängte ESP
	local efi="$WORK/efi.img"
	rm -f "$efi"
	mkfs.vfat -C -n FRS_EFI "$efi" 8192 >/dev/null
	mmd -i "$efi" ::/EFI ::/EFI/boot
	mcopy -i "$efi" "$ISO"/EFI/boot/* ::/EFI/boot/
}

# ---------------------------------------------------------------------------
# 5. SquashFS
# ---------------------------------------------------------------------------
squash() {
	log "Erzeuge Manifest und SquashFS"
	chroot_umount
	chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' >"$ISO/casper/filesystem.manifest"
	cp "$ISO/casper/filesystem.manifest" "$OUT/${ISO_NAME%.iso}.manifest"
	rm -f "$ISO/casper/filesystem.squashfs"
	mksquashfs "$CHROOT" "$ISO/casper/filesystem.squashfs" \
		-comp zstd -Xcompression-level 19 -b 1M -noappend -no-progress \
		-wildcards -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' 'boot/*' 'var/cache/apt/archives/*.deb'
	du -sx --block-size=1 "$CHROOT" | cut -f1 >"$ISO/casper/filesystem.size"
}

# ---------------------------------------------------------------------------
# 6. Hybrid-ISO (BIOS + UEFI, dd-fähig)
# ---------------------------------------------------------------------------
make_iso() {
	log "Erzeuge $ISO_NAME"
	(cd "$ISO" && find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum >md5sum.txt)
	xorriso -as mkisofs -r -V "$ISO_LABEL" -o "$OUT/$ISO_NAME" \
		-J -joliet-long -l -iso-level 3 \
		--grub2-mbr "$WORK/boot_hybrid.img" \
		-partition_offset 16 --mbr-force-bootable \
		-append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$WORK/efi.img" \
		-appended_part_as_gpt \
		-iso_mbr_part_type a2a0d0eb-e5b9-3344-87c0-68b6b72699c7 \
		-c boot.catalog \
		-b boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
		-eltorito-alt-boot \
		-e '--interval:appended_partition_2:::' -no-emul-boot \
		"$ISO"
	(cd "$OUT" && sha256sum "$ISO_NAME" >"$ISO_NAME.sha256")
	local size
	size=$(stat -c %s "$OUT/$ISO_NAME")
	log "Fertig: $OUT/$ISO_NAME ($((size / 1024 / 1024)) MiB)"
	if ((size >= 2 * 1024 * 1024 * 1024)); then
		die "ISO ist größer als 2 GiB und passt nicht als GitHub-Release-Asset."
	fi
}

main() {
	host_deps
	bootstrap
	chroot_mount
	configure
	boot_files
	squash
	make_iso
}

main "$@"
