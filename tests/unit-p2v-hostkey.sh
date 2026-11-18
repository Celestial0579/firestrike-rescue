#!/usr/bin/env bash
# Unit-Test (GHSA-p86q-3456-f288): Der SSH-Schlüssel des Proxmox-Knotens gilt erst, wenn der
# Techniker die letzten 10 Zeichen seines Fingerabdrucks eingibt; 4 reichen nicht mehr. Und
# lf-claude meldet sich nie per SSH am Rettungssystem an.
#
# Hier wird nichts verbunden: Fingerabdruck und gescannter Schlüssel sind ausgedacht.
set -u
cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C.UTF-8

T=$(mktemp -d)
# shellcheck disable=SC1091
. rescue/lib/common.sh
# shellcheck disable=SC1091
. rescue/lib/safety.sh
# shellcheck disable=SC1091
. rescue/lib/p2v.sh
LF_LOG="$T/log"
P2V_DIR="$T"
P2V_HOST=pve.example
P2V_HKTYPE=ed25519
P2V_FP="SHA256:Xq3v9LmT0aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456A"
echo "pve.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample" >"$T/hostkey.scan"
LAST10=${P2V_FP: -10}
WRONG10="${LAST10:0:9}B"

fails=0
check() {
	if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1 ($2)"; fails=$((fails + 1)); fi
}

echo "P2V: Schlüssel des Knotens bestätigen:"
check "die letzten 4 Zeichen reichen nicht" '! p2v_hostkey_accept "${P2V_FP: -4}" && [[ ! -e $T/known_hosts ]]'
rm -f "$T/known_hosts"
check "10 Zeichen mit einem falschen: abgelehnt" '! p2v_hostkey_accept "$WRONG10" && [[ ! -e $T/known_hosts ]]'
rm -f "$T/known_hosts"
check "Groß- und Kleinschreibung zählt" '! p2v_hostkey_accept "${LAST10,,}" && [[ ! -e $T/known_hosts ]]'
rm -f "$T/known_hosts"
check "die letzten 10 Zeichen: bestätigt, erst dann known_hosts" 'p2v_hostkey_accept "$LAST10" && cmp -s "$T/hostkey.scan" "$T/known_hosts"'
check "der Dialog verlangt so viele Zeichen, wie geprüft werden" '[[ ${P2V_FP_CONFIRM:-} == 10 ]] && grep -qF "die letzten \$P2V_FP_CONFIRM Zeichen des Fingerabdrucks eingeben" rescue/lib/p2v.sh && ! grep -q "letzten 4 Zeichen des Fingerabdrucks" rescue/lib/p2v.sh'

echo "SSH-Anmeldung am Rettungssystem:"
check "lf-claude meldet sich nie per SSH an" 'grep -qx "DenyUsers lf-claude" build/overlay/etc/ssh/sshd_config.d/lf.conf && grep -qx "PermitRootLogin no" build/overlay/etc/ssh/sshd_config.d/lf.conf'

rm -rf "$T"
((fails == 0)) && echo "Alle Tests bestanden." || { echo "$fails Test(s) fehlgeschlagen."; exit 1; }
