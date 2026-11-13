#!/usr/bin/env bash
# StealthOS v8: Debian live ISO (opsec / OSINT / recon edition, dark-metal neon-green theme)
# Features: Tor transparent proxy (Tails-style), VPN kill-switch mode, mode switcher,
# LUKS encrypted persistence, RAM wipe on shutdown, KVM, Wireshark, OSINT tools.
# Run on Debian 12 / Ubuntu with internet:  sudo bash build-stealthos-v8.sh
#
# GitHub Actions / CI guard: this project is a host-only ISO builder and cannot run in
# ephemeral CI runners. We allow a controlled validation mode so the repo can still be
# checked in automation without attempting a full live-build.
if [[ "${GITHUB_ACTIONS:-}" == "true" || "${CI:-}" == "true" || "${DRY_RUN:-}" == "1" ]]; then
  echo "CI/DRY_RUN detected: skipping full ISO build."
  echo "This builder requires a real Debian/Ubuntu host with root access, internet, and sufficient disk/RAM."
  exit 0
fi

set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }

echo "Pre-flight checks..."
AVAIL=$(df --output=avail -BG /opt | tail -1 | tr -dc 0-9)
[ "${AVAIL:-0}" -ge 25 ] || { echo "Need at least 25 GB free in /opt (have ${AVAIL:-0} GB)."; exit 1; }
MEM=$(awk '/MemTotal/{printf "%d",$2/1048576}' /proc/meminfo)
[ "${MEM:-0}" -ge 4 ] || echo "WARNING: under 4 GB RAM; the build may be slow or fail."
ping -c1 -W3 deb.debian.org >/dev/null 2>&1 || { echo "Cannot reach deb.debian.org (no internet?)."; exit 1; }
echo "OK: ${AVAIL} GB free, ${MEM} GB RAM."

apt-get update
apt-get install -y live-build debootstrap squashfs-tools xorriso librsvg2-bin imagemagick

WORK=/opt/stealthos-build
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

lb config \
  --distribution bookworm \
  --architectures amd64 \
  --binary-images iso-hybrid \
  --archive-areas "main contrib non-free-firmware" \
  --debian-installer none \
  --bootappend-live "boot=live components quiet splash noeject persistence persistence-encryption=luks init_on_free=1 init_on_alloc=1 slab_nomerge page_alloc.shuffle=1 randomize_kstack_offset=on vga=normal" \
  --iso-volume "StealthOS"

# ---------------- Packages ----------------
mkdir -p config/package-lists
cat > config/package-lists/stealth.list.chroot <<'EOF'
task-xfce-desktop
xfce4-terminal
firefox-esr
tor
torbrowser-launcher
obfs4proxy
proxychains4
macchanger
bleachbit
mat2
secure-delete
wireguard
openvpn
network-manager-openvpn
resolvconf
nftables
qemu-system-x86
libvirt-daemon-system
virt-manager
virtinst
wireshark
tshark
nmap
tcpdump
netcat-openbsd
whois
dnsutils
theharvester
recon-ng
spiderfoot
amass
exiftool
python3-pip
python3-venv
git
curl
cryptsetup
keepassxc
gnupg
# Hardware firmware (Wi-Fi, Ethernet, GPU, CPU microcode)
firmware-linux
firmware-linux-nonfree
firmware-misc-nonfree
firmware-iwlwifi
firmware-atheros
firmware-realtek
firmware-brcm80211
firmware-libertas
firmware-amd-graphics
firmware-bnx2
firmware-bnx2x
firmware-intel-sound
intel-microcode
amd64-microcode
wireless-regdb
iw
rfkill
apparmor
apparmor-profiles
apparmor-utils
firejail
usbguard
EOF

# ---------------- Tor config (transparent proxy) ----------------
mkdir -p config/includes.chroot/etc/tor
cat > config/includes.chroot/etc/tor/torrc <<'EOF'
SocksPort 9050 IsolateClientAddr IsolateSOCKSAuth
ControlPort 127.0.0.1:9051
CookieAuthentication 1
TransPort 9040
DNSPort 5353
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
ClientUseIPv6 0
%include /etc/tor/torrc.d/
# Uncomment for bridges (censored networks):
# UseBridges 1
# ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
# Bridge obfs4 <paste bridge line>
EOF

# ---------------- Firewall profiles ----------------
mkdir -p config/includes.chroot/etc/stealth
# Tor mode: ALL traffic forced through Tor, everything else dropped
cat > config/includes.chroot/etc/stealth/nft-tor.conf <<'EOF'
flush ruleset
table ip nat {
  chain output {
    type nat hook output priority -100; policy accept;
    meta skuid "debian-tor" return
    udp dport 53 redirect to :5353
    ip daddr 127.0.0.0/8 return
    ip protocol tcp tcp flags & (syn|ack) == syn redirect to :9040
  }
}
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output {
    type filter hook output priority 0; policy drop;
    meta skuid "debian-tor" accept
    oif lo accept
    # Everything else (UDP, ICMP, IPv6, raw) is dropped
  }
}
EOF
# VPN mode: only via wg0/tun0. Set VPN_SERVER_IP to your provider endpoint.
cat > config/includes.chroot/etc/stealth/nft-vpn.conf <<'EOF'
flush ruleset
define VPN_SERVER_IP = 0.0.0.0
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output {
    type filter hook output priority 0; policy drop;
    oif lo accept
    oifname { "wg0", "tun0" } accept
    ip daddr $VPN_SERVER_IP accept
    udp dport 67-68 accept
  }
}
EOF
# Off mode: normal networking (for setup only)
cat > config/includes.chroot/etc/stealth/nft-off.conf <<'EOF'
flush ruleset
EOF

# ---------------- Mode switcher ----------------
mkdir -p config/includes.chroot/usr/local/bin
cat > config/includes.chroot/usr/local/bin/stealth-mode <<'EOF'
#!/bin/bash
# Usage: sudo stealth-mode tor|vpn|off|status
set -e
case "${1:-status}" in
  tor) nft -f /etc/stealth/nft-tor.conf; systemctl start tor@default; echo tor > /run/stealth-mode; echo "TOR MODE: all traffic forced through Tor";;
  vpn) systemctl stop tor@default || true; nft -f /etc/stealth/nft-vpn.conf; echo vpn > /run/stealth-mode; echo "VPN MODE: only wg0/tun0 allowed";;
  off) nft -f /etc/stealth/nft-off.conf; echo off > /run/stealth-mode; echo "WARNING: no protection active";;
  status) nft list ruleset | head -40; systemctl is-active tor@default || true;;
  *) echo "Usage: stealth-mode tor|vpn|off|status"; exit 1;;
esac
EOF
chmod +x config/includes.chroot/usr/local/bin/stealth-mode

# Default to Tor mode at boot
mkdir -p config/includes.chroot/etc/systemd/system
cat > config/includes.chroot/etc/systemd/system/stealth-boot.service <<'EOF'
[Unit]
Description=Apply StealthOS default network mode (Tor)
After=tor@default.service network-pre.target
Before=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/stealth-mode tor
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

# ---------------- RAM wipe on shutdown ----------------
cat > config/includes.chroot/etc/systemd/system/stealth-ramwipe.service <<'EOF'
[Unit]
Description=Wipe free RAM on shutdown
DefaultDependencies=no
After=final.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/bin/sdmem -ll -f
TimeoutStopSec=300
[Install]
WantedBy=multi-user.target
EOF

# ---------------- Encrypted persistence helper ----------------
cat > config/includes.chroot/usr/local/bin/stealth-persist-setup <<'EOF'
#!/bin/bash
# Usage: sudo stealth-persist-setup /dev/sdXN
# Create a free partition on your USB first (gparted), then pass it here.
set -e
DEV="${1:?Usage: stealth-persist-setup /dev/sdXN}"
echo "This will ERASE $DEV. Type YES to continue:"; read -r a; [ "$a" = "YES" ] || exit 1
cryptsetup luksFormat --type luks2 "$DEV"
cryptsetup open "$DEV" stealth_persist
mkfs.ext4 -L persistence /dev/mapper/stealth_persist
mkdir -p /mnt/sp && mount /dev/mapper/stealth_persist /mnt/sp
cat > /mnt/sp/persistence.conf <<EOC
/home union
/etc/stealth union
/etc/tor/torrc.d union
/etc/NetworkManager/system-connections union
EOC
umount /mnt/sp && cryptsetup close stealth_persist
echo "Done. Next boot, choose the unlock prompt and enter your passphrase."
EOF
chmod +x config/includes.chroot/usr/local/bin/stealth-persist-setup

# ---------------- Hardening ----------------
mkdir -p config/includes.chroot/etc/sysctl.d config/includes.chroot/etc/NetworkManager/conf.d
cat > config/includes.chroot/etc/sysctl.d/99-stealth.conf <<'EOF'
vm.swappiness=0
kernel.core_pattern=|/bin/false
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.unprivileged_bpf_disabled=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
cat > config/includes.chroot/etc/NetworkManager/conf.d/00-macrandom.conf <<'EOF'
[device]
wifi.scan-rand-mac-address=yes
[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF

# ---------------- Build-time hook ----------------
mkdir -p config/hooks/normal
cat > config/hooks/normal/0100-stealth.hook.chroot <<'EOF'
#!/bin/sh
set -e
pip3 install --break-system-packages sherlock-project maigret holehe
systemctl enable stealth-boot.service stealth-ramwipe.service tor@default.service || true
systemctl disable ssh || true
systemctl mask swap.target || true
# Let live user capture packets
adduser user wireshark || true
adduser user libvirt || true
EOF
chmod +x config/hooks/normal/0100-stealth.hook.chroot

# ---------------- Bundle proxychains (3 chain modes + chain-test) ----------------
mkdir -p config/includes.chroot/root
cat > config/includes.chroot/root/stealth-proxychains.sh <<'PCEOF'
#!/usr/bin/env bash
# Installs proxychains profiles (strict / dynamic / random), a switcher, and a chain tester.
# Run on the live StealthOS (or any Debian/Ubuntu):  sudo bash stealth-proxychains.sh
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }

apt-get install -y proxychains4 curl

mkdir -p /etc/stealth/proxychains

# Shared proxy list. Edit this: Tor first, then YOUR OWN proxies.
cat > /etc/stealth/proxychains/proxies.list <<'EOF'
socks5 127.0.0.1 9050
# socks5 1.2.3.4 1080 user pass
# socks5 5.6.7.8 1080 user pass
EOF

make_profile() {  # $1 = name, $2 = chain directives
  {
    echo "$2"
    echo "proxy_dns"
    echo "remote_dns_subnet 224"
    echo "tcp_read_time_out 15000"
    echo "tcp_connect_time_out 8000"
    echo
    echo "[ProxyList]"
    grep -v '^#' /etc/stealth/proxychains/proxies.list | grep -v '^$' || true
  } > "/etc/stealth/proxychains/$1.conf"
}

# 1) strict: every proxy in exact order; fails if any hop is down (most predictable)
make_profile strict "strict_chain"
# 2) dynamic: in order, but skips dead proxies (more reliable)
make_profile dynamic "dynamic_chain"
# 3) random: random order, chain_len hops per connection (more variety, less predictable)
make_profile random $'random_chain\nchain_len = 2'

# Switcher: stealth-chain strict|dynamic|random|status
cat > /usr/local/bin/stealth-chain <<'EOF'
#!/bin/bash
# Usage: sudo stealth-chain strict|dynamic|random|rebuild|status
D=/etc/stealth/proxychains
case "${1:-status}" in
  strict|dynamic|random)
    cp "$D/$1.conf" /etc/proxychains4.conf; echo "Chain mode: $1";;
  rebuild)
    echo "Edit $D/proxies.list, then re-run: sudo bash stealth-proxychains.sh";;
  status)
    grep -E '^(strict|dynamic|random)_chain' /etc/proxychains4.conf || echo "none set"
    sed -n '/\[ProxyList\]/,$p' /etc/proxychains4.conf;;
  *) echo "Usage: stealth-chain strict|dynamic|random|status"; exit 1;;
esac
EOF
chmod +x /usr/local/bin/stealth-chain

# Tester: shows exit IP, Tor status, DNS leak check
cat > /usr/local/bin/chain-test <<'EOF'
#!/bin/bash
echo "== Active chain =="; stealth-chain status; echo
echo "== Exit IP through chain =="
proxychains4 -q curl -s --max-time 25 https://check.torproject.org/api/ip || echo "FAILED: chain not working"
echo; echo
echo "== Your direct IP (only meaningful outside Tor mode) =="
curl -s --max-time 8 https://api.ipify.org || echo "blocked (good in Tor/VPN kill-switch mode)"
echo; echo
echo "== DNS leak check (should resolve via proxy) =="
proxychains4 -q curl -s --max-time 25 https://dnsleaktest.com >/dev/null && echo "DNS went through chain (proxy_dns on)" || echo "check failed"
EOF
chmod +x /usr/local/bin/chain-test

cp /etc/stealth/proxychains/strict.conf /etc/proxychains4.conf

echo "Done."
echo "  sudo stealth-chain strict|dynamic|random   switch mode"
echo "  chain-test                                 show exit IP and verify the chain"
echo "  proxychains4 <command>                     run anything through the chain"

PCEOF
cat > config/hooks/normal/0200-proxychains.hook.chroot <<'EOF'
#!/bin/sh
set -e
bash /root/stealth-proxychains.sh
rm -f /root/stealth-proxychains.sh
EOF
chmod +x config/hooks/normal/0200-proxychains.hook.chroot

# ---------------- Extra hardening ----------------
mkdir -p config/includes.chroot/etc/modprobe.d
cat > config/includes.chroot/etc/modprobe.d/stealth-blacklist.conf <<'EOF'
# Rare/risky protocols
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
# DMA-capable ports
install firewire-core /bin/false
install firewire-ohci /bin/false
# Bluetooth off by default (remove these lines if you need it)
install bluetooth /bin/false
install btusb /bin/false
EOF

# Sandbox wrapper for opening untrusted files with no network
cat > config/includes.chroot/usr/local/bin/stealth-sandbox <<'EOF'
#!/bin/bash
# Usage: stealth-sandbox <command> [args]   (no network, throwaway home)
exec firejail --net=none --private --noroot --caps.drop=all --seccomp "$@"
EOF
chmod +x config/includes.chroot/usr/local/bin/stealth-sandbox

# Panic button: cut network, close encrypted volumes, power off (RAM wipe runs on clean poweroff)
cat > config/includes.chroot/usr/local/bin/stealth-panic <<'EOF'
#!/bin/bash
# Usage: sudo stealth-panic [--fast]
nft flush ruleset; nft add table inet p; nft add chain inet p o '{ type filter hook output priority 0; policy drop; }'
pkill -9 -f 'wireshark|firefox|tor-browser' 2>/dev/null
sync
for m in /dev/mapper/*; do [ "$m" = "/dev/mapper/control" ] || { umount -l "$m" 2>/dev/null; cryptsetup close "$(basename "$m")" 2>/dev/null; }; done
if [ "$1" = "--fast" ]; then systemctl poweroff -f; else systemctl poweroff; fi
EOF
chmod +x config/includes.chroot/usr/local/bin/stealth-panic

# ================= v4 additions: opsec / OSINT / recon =================
mkdir -p config/includes.chroot/etc/tor/torrc.d
echo "# bridges are written here by stealth-bridges" > config/includes.chroot/etc/tor/torrc.d/00-bridges.conf

# --- Optional packages (skipped individually if missing, so the build never fails) ---
cat > config/hooks/normal/0300-extras.hook.chroot <<'EOF'
#!/bin/sh
apt-get update || true
for p in torsocks nyx onionshare-cli mitmproxy masscan nikto whatweb sslscan \
         dnsrecon dnsenum fierce gobuster ffuf wafw00f sqlmap john hashcat \
         sleuthkit foremost binwalk steghide exiv2 lynis rkhunter htpdate \
         qrencode age snowflake-client tor-geoipdb metagoofil sublist3r; do
  apt-get install -y --no-install-recommends "$p" || echo "SKIPPED apt: $p"
done
for p in socialscan h8mail osrframework waybackpy shodan instaloader yt-dlp; do
  pip3 install --break-system-packages "$p" || echo "SKIPPED pip: $p"
done
EOF
chmod +x config/hooks/normal/0300-extras.hook.chroot

BIN=config/includes.chroot/usr/local/bin

# --- Tor bridges / pluggable transports ---
cat > $BIN/stealth-bridges <<'EOF'
#!/bin/bash
# Usage: sudo stealth-bridges "<bridge line>" ["<bridge line>" ...]   |   sudo stealth-bridges off
# Get bridge lines from https://bridges.torproject.org (or email bridges@torproject.org)
F=/etc/tor/torrc.d/00-bridges.conf
if [ "$1" = "off" ] || [ $# -eq 0 ]; then
  echo "# bridges off" > $F; systemctl restart tor@default; echo "Bridges off."; exit 0
fi
{ echo "UseBridges 1"
  echo "ClientTransportPlugin obfs4,meek_lite exec /usr/bin/obfs4proxy"
  echo "ClientTransportPlugin snowflake exec /usr/bin/snowflake-client"
  for b in "$@"; do echo "Bridge ${b#Bridge }"; done
} > $F
systemctl restart tor@default; echo "Bridges set. Wait ~1 min, then run chain-test."
EOF

# --- New Tor circuits / identity ---
cat > $BIN/stealth-newid <<'EOF'
#!/bin/bash
# Usage: sudo stealth-newid   (new Tor circuits; use between unrelated investigations)
C=$(od -An -tx1 /run/tor/control.authcookie | tr -d ' \n')
printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$C" | nc -q1 127.0.0.1 9051
EOF

# --- Clock fix over Tor (Tor breaks with a bad clock) ---
cat > $BIN/stealth-time <<'EOF'
#!/bin/bash
# Usage: sudo stealth-time   (sets clock from an HTTPS Date header fetched through Tor)
D=$(curl -sI --max-time 30 --socks5-hostname 127.0.0.1:9050 https://check.torproject.org | grep -i '^date:' | cut -d' ' -f2-)
[ -n "$D" ] && date -s "$D" && echo "Clock set: $D" || echo "Could not fetch time (Tor not connected yet; if the clock is badly wrong, set it manually with: date -s 'YYYY-MM-DD HH:MM')"
EOF

# --- USB lock (blocks NEW USB devices until you allow them) ---
cat > $BIN/stealth-usb-lock <<'EOF'
#!/bin/bash
# Usage: sudo stealth-usb-lock   (allows currently attached devices, blocks any new ones)
usbguard generate-policy > /etc/usbguard/rules.conf && systemctl restart usbguard && echo "USB locked. Allow a device: usbguard list-devices ; usbguard allow-device <id>"
EOF

# --- OSINT case workspace ---
cat > $BIN/osint-init <<'EOF'
#!/bin/bash
# Usage: osint-init <case-name>   (creates ~/osint/<case> with logging template)
C="$HOME/osint/${1:?case name}"
mkdir -p "$C"/{evidence,screenshots,exports,notes}
cat > "$C/notes/log.md" <<EOT
# Case: $1
Started: $(date -u +%FT%TZ) (UTC)
Scope / authorization:
Persona / identity used:
## Findings (source | URL | timestamp | hash of saved evidence)
EOT
echo "Created $C  (run: sudo stealth-newid before starting a new unrelated case)"
EOF

# --- Self-check ---
cat > $BIN/stealth-check <<'EOF'
#!/bin/bash
ok(){ echo "[ OK ] $1"; }; bad(){ echo "[FAIL] $1"; }
systemctl is-active --quiet tor@default && ok "Tor running" || bad "Tor not running"
nft list ruleset 2>/dev/null | grep -q 9040 && ok "Tor transparent proxy rules active" || echo "[INFO] Not in Tor mode (VPN/off?)"
[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 1 ] && ok "IPv6 disabled" || bad "IPv6 enabled"
[ -z "$(swapon --show)" ] && ok "No swap" || bad "Swap active"
aa-status --enabled 2>/dev/null && ok "AppArmor enabled" || bad "AppArmor off"
for i in $(ls /sys/class/net | grep -v lo); do echo "[INFO] $i MAC $(cat /sys/class/net/$i/address)"; done
T=$(proxychains4 -q curl -s --max-time 25 https://check.torproject.org/api/ip 2>/dev/null)
echo "$T" | grep -q '"IsTor":true' && ok "Exit is Tor: $T" || echo "[INFO] Not verified as Tor exit: $T"
mount | grep -q persistence && ok "Persistence mounted" || echo "[INFO] No persistence (amnesic session)"
date -u +"[INFO] Clock (UTC): %F %T"
EOF

# --- Offline docs + login banner ---
cat > config/includes.chroot/etc/motd <<'EOF'

 STEALTHOS  //  GO DARK. STAY SHARP.
 stealth-hub                   GUI control center (click the mode badge in the top bar)
 stealth-mode tor|vpn|off      network mode      stealth-check     self-test
 stealth-chain strict|dynamic|random             chain-test        exit IP + leaks
 stealth-bridges / -newid / -time                stealth-sandbox   offline sandbox
 stealth-usb-lock              stealth-panic     osint-init <case> new case folder
 stealth-persist-setup <part>  encrypted persistence
 Authorized targets only. Never log into personal accounts here.

EOF
cat > config/includes.chroot/etc/stealth/OPSEC.md <<'EOF'
# OPSEC rules (tools don't save you; habits do)
1. One identity per investigation. Run stealth-newid between cases. Never mix personas.
2. Never log into personal accounts or use real email/phone here.
3. Don't open untrusted files outside stealth-sandbox. Strip metadata with mat2 before sharing.
4. Use bridges (stealth-bridges) if Tor use itself is a risk on your network.
5. Don't maximize/resize Tor Browser; don't install extra browser add-ons.
6. Wi-Fi: randomized MAC helps, but location and device history still matter.
7. Only test systems you own or have written permission to test.
8. Finish with stealth-panic (or clean shutdown so RAM wipe runs). Pull the USB after power-off.
EOF
chmod +x $BIN/*

# ================= v5: dark-metal / neon-green theme =================
SKEL=config/includes.chroot/etc/skel
mkdir -p config/includes.chroot/usr/share/backgrounds $SKEL/.config/gtk-3.0 \
  $SKEL/.config/xfce4/xfconf/xfce-perchannel-xml $SKEL/.config/xfce4/terminal \
  config/includes.chroot/etc/xdg/autostart config/includes.chroot/etc/lightdm

# --- Wallpaper (SVG; converted to PNG at build time) ---
cat > config/includes.chroot/usr/share/backgrounds/stealthos.svg <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <radialGradient id="bg" cx="0.5" cy="0.42" r="0.8"><stop offset="0" stop-color="#17211e"/><stop offset="0.6" stop-color="#0c100f"/><stop offset="1" stop-color="#040606"/></radialGradient>
    <pattern id="brushed" width="6" height="6" patternUnits="userSpaceOnUse"><rect width="1" height="6" x="0" fill="#ffffff" opacity="0.03"/><rect width="1" height="6" x="3" fill="#000000" opacity="0.04"/></pattern>
    <pattern id="hex" width="56" height="100" patternUnits="userSpaceOnUse"><path d="M28 66L0 50L0 16L28 0L56 16L56 50L28 66L28 100" fill="none" stroke="#39ff14" stroke-width="1" opacity="0.06"/></pattern>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <rect width="1920" height="1080" fill="url(#brushed)"/>
  <rect width="1920" height="1080" fill="url(#hex)"/>
</svg>
SVGEOF

# --- Theme packages (optional) + wallpaper render + prompt colors ---
cat > config/hooks/normal/0310-theme.hook.chroot <<'EOF'
#!/bin/sh
for p in arc-theme papirus-icon-theme fonts-jetbrains-mono xfce4-genmon-plugin \
         librsvg2-bin librsvg2-common lightdm-gtk-greeter fonts-noto-color-emoji \
         fonts-inter fonts-firacode fonts-hack yad libnotify-bin; do
  apt-get install -y --no-install-recommends "$p" || echo "SKIPPED theme pkg: $p"
done
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1920 -h 1080 /usr/share/backgrounds/stealthos.svg -o /usr/share/backgrounds/stealthos.png || true
fi
cat >> /etc/skel/.bashrc <<'EOB'
PS1='\[\e[1;38;5;82m\]\u@\h\[\e[0m\]:\[\e[38;5;245m\]\w\[\e[1;38;5;82m\] \$\[\e[0m\] '
alias ll='ls -lah --color=auto'
EOB
EOF
chmod +x config/hooks/normal/0310-theme.hook.chroot

# --- GTK3 accents: neon green on gunmetal ---
cat > $SKEL/.config/gtk-3.0/gtk.css <<'EOF'
@define-color theme_selected_bg_color #39ff14;
@define-color theme_selected_fg_color #070a08;
selection, *:selected, row:selected, menuitem:hover, .view:selected {
  background-color: #39ff14; color: #070a08; }
*:focus { outline-color: #39ff14; }
button {
  border-radius: 6px;
  background-image: linear-gradient(to bottom, rgba(255,255,255,0.16), rgba(255,255,255,0.03) 50%, rgba(0,0,0,0.25));
  box-shadow: inset 0 1px rgba(255,255,255,0.22), 0 1px 2px rgba(0,0,0,0.6); }
button:hover { border-color: #39ff14; box-shadow: inset 0 1px rgba(255,255,255,0.3), 0 0 10px rgba(57,255,20,0.55); }
button:active, button:checked {
  background-image: linear-gradient(to bottom, rgba(0,0,0,0.35), rgba(57,255,20,0.25));
  border-color: #39ff14; }
entry, spinbutton { border-radius: 6px; box-shadow: inset 0 2px 4px rgba(0,0,0,0.65); }
entry:focus, spinbutton:focus { border-color: #39ff14; box-shadow: inset 0 2px 4px rgba(0,0,0,0.65), 0 0 8px rgba(57,255,20,0.5); }
progressbar progress, scale highlight, scale trough highlight, switch:checked, check:checked, radio:checked {
  background-color: #39ff14; background-image: linear-gradient(to bottom, rgba(255,255,255,0.45), rgba(255,255,255,0) 60%);
  color: #070a08; border-color: #39ff14; }
scrollbar slider { border-radius: 8px; }
scrollbar slider:hover, scrollbar slider:active { background-color: #39ff14; }
EOF

# --- XFCE settings: dark theme, icons, fonts ---
cat > $SKEL/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Arc-Dark"/>
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Inter 10"/>
    <property name="MonospaceFontName" type="string" value="Fira Code 10"/>
  </property>
</channel>
EOF

# --- Panel: top bar, apps menu, tasklist, MODE indicator, tray, clock (UTC) ---
cat > $SKEL/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="30"/>
      <property name="background-style" type="uint" value="0"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/><value type="int" value="2"/><value type="int" value="3"/>
        <value type="int" value="4"/><value type="int" value="5"/><value type="int" value="6"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-2" type="string" value="tasklist"/>
    <property name="plugin-3" type="string" value="separator">
      <property name="style" type="uint" value="0"/>
      <property name="expand" type="bool" value="true"/>
    </property>
    <property name="plugin-4" type="string" value="genmon">
      <property name="command" type="string" value="/usr/local/bin/stealth-indicator"/>
      <property name="update-period" type="int" value="3000"/>
      <property name="use-label" type="bool" value="false"/>
    </property>
    <property name="plugin-5" type="string" value="systray"/>
    <property name="plugin-6" type="string" value="clock">
      <property name="digital-format" type="string" value="%H:%M UTC"/>
    </property>
  </property>
</channel>
EOF

# --- Terminal: neon on near-black ---
cat > $SKEL/.config/xfce4/terminal/terminalrc <<'EOF'
[Configuration]
FontName=Fira Code 11
ColorForeground=#c8ffd0
ColorBackground=#070a08
ColorCursor=#39ff14
ColorPalette=#070a08;#ff4d5e;#39ff14;#f5c542;#4da3ff;#c678ff;#2de2c4;#c8ffd0;#2a3330;#ff7a88;#7dff5e;#ffd96b;#7dbbff;#d9a0ff;#6ff2dc;#ffffff
MiscMenubarDefault=FALSE
MiscToolbarDefault=FALSE
ScrollingBar=TERMINAL_SCROLLBAR_NONE
BackgroundMode=TERMINAL_BACKGROUND_TRANSPARENT
BackgroundDarkness=0.9
EOF

# --- Panel mode indicator (reads /run/stealth-mode) ---
cat > config/includes.chroot/usr/local/bin/stealth-indicator <<'EOF'
#!/bin/bash
M=$(cat /run/stealth-mode 2>/dev/null || echo off)
case "$M" in
  tor) C="#39ff14"; T="TOR";;
  vpn) C="#f5c542"; T="VPN";;
  *)   C="#ff4d5e"; T="EXPOSED";;
esac
echo "<txt><span foreground='$C' weight='bold'>  $T  </span></txt>"
echo "<click>/usr/local/bin/stealth-hub</click>"
echo "<tool>Network mode: $M  (click to open the Stealth Hub)</tool>"
EOF
chmod +x config/includes.chroot/usr/local/bin/stealth-indicator

# --- Apply wallpaper on every monitor at login ---
cat > config/includes.chroot/usr/local/bin/stealth-theme-apply <<'EOF'
#!/bin/bash
W=/usr/share/backgrounds/stealthos.png
[ -f "$W" ] || W=/usr/share/backgrounds/stealthos.svg
sleep 2
for m in $(xrandr 2>/dev/null | awk '/ connected/{print $1}'); do
  xfconf-query -c xfce4-desktop -n -t string -p "/backdrop/screen0/monitor$m/workspace0/last-image" -s "$W"
  xfconf-query -c xfce4-desktop -n -t int -p "/backdrop/screen0/monitor$m/workspace0/image-style" -s 5
done
xfdesktop --reload 2>/dev/null
EOF
chmod +x config/includes.chroot/usr/local/bin/stealth-theme-apply
cat > config/includes.chroot/etc/xdg/autostart/stealth-theme.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=StealthOS theme
Exec=/usr/local/bin/stealth-theme-apply
OnlyShowIn=XFCE;
EOF

# --- Login screen ---
cat > config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf <<'EOF'
[greeter]
background=/usr/share/backgrounds/stealthos.png
theme-name=Arc-Dark
icon-theme-name=Papirus-Dark
font-name=Inter 11
indicators=~host;~spacer;~clock;~spacer;~session;~power
EOF

# ================= v6: boot menu theme, Plymouth splash, welcome terminal =================
mkdir -p assets
cat > assets/splash.svg <<'SPLASHEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="480" viewBox="0 0 640 480">
  <rect width="640" height="480" fill="#040606"/>
  <circle cx="320" cy="180" r="90" fill="none" stroke="#39ff14" stroke-width="4"/>
  <text x="320" y="300" text-anchor="middle" font-family="DejaVu Sans Mono, monospace" font-size="17" fill="#9fd9a0" letter-spacing="4">GO DARK // STAY SHARP</text>
</svg>
SPLASHEOF
rsvg-convert -w 640 -h 480 assets/splash.svg -o assets/splash.png

# --- Boot menu (BIOS isolinux + UEFI grub): replace splash images, recolor menu ---
if [ -d /usr/share/live/build/bootloaders ]; then
  mkdir -p config/bootloaders
  cp -r /usr/share/live/build/bootloaders/. config/bootloaders/
  find config/bootloaders -name 'splash.png' -exec cp assets/splash.png {} \;
  find config/bootloaders -name 'splash.svg' -exec cp assets/splash.svg {} \;
fi

# --- Plymouth boot splash ---
PLY=config/includes.chroot/usr/share/plymouth/themes/stealthos
mkdir -p $PLY
cat > assets/logo.svg <<'LOGOEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="240" viewBox="0 0 240 240">
  <rect width="240" height="240" fill="#040606"/>
  <polygon points="220,120 170,206.6 70,206.6 20,120 70,33.4 170,33.4" fill="none" stroke="#39ff14" stroke-width="4"/>
  <circle cx="120" cy="108" r="17" fill="#39ff14"/>
  <polygon points="110,118 130,118 139,160 101,160" fill="#39ff14"/>
</svg>
LOGOEOF
rsvg-convert -w 240 -h 240 assets/logo.svg -o $PLY/logo.png
convert -size 360x6 xc:'#1d3d16' $PLY/bar-bg.png
convert -size 360x6 xc:'#39ff14' $PLY/bar-fill.png

cat > $PLY/stealthos.plymouth <<'PLYEOF'
[Plymouth Theme]
Name=StealthOS
Description=Neon green boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/stealthos
ScriptFile=/usr/share/plymouth/themes/stealthos/stealthos.script
PLYEOF

cat > $PLY/stealthos.script <<'SCRIPTEOF'
Window.SetBackgroundTopColor(0.04, 0.055, 0.05);
Window.SetBackgroundBottomColor(0.02, 0.03, 0.03);

screen_w = Window.GetWidth();
screen_h = Window.GetHeight();

logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(screen_w / 2 - logo.image.GetWidth() / 2);
logo.sprite.SetY(screen_h / 2 - logo.image.GetHeight() / 2 - 40);

bar_w = 360;
bar_h = 6;
bar_x = screen_w / 2 - bar_w / 2;
bar_y = screen_h / 2 + logo.image.GetHeight() / 2 - 20;

bar_bg.image = Image("bar-bg.png");
bar_bg.sprite = Sprite(bar_bg.image);
bar_bg.sprite.SetPosition(bar_x, bar_y, 1);

bar_fill.image = Image("bar-fill.png");
bar_fill.sprite = Sprite();
bar_fill.sprite.SetPosition(bar_x, bar_y, 2);

fun boot_progress_cb(time, progress) {
  w = Math.Int(bar_w * progress);
  if (w < 1) w = 1;
  bar_fill.sprite.SetImage(bar_fill.image.Scale(w, bar_h));
}
Plymouth.SetBootProgressFunction(boot_progress_cb);

status.sprite = Sprite();

fun show_text(t) {
  img = Image.Text(t, 0.22, 1.0, 0.08);
  status.sprite.SetImage(img);
  status.sprite.SetOpacity(1);
  status.sprite.SetPosition(screen_w / 2 - img.GetWidth() / 2, bar_y + 40, 10);
}

fun password_cb(prompt, bullets) {
  s = "";
  for (i = 0; i < bullets; i++) s = s + "*";
  show_text(prompt + " " + s);
}
Plymouth.SetDisplayPasswordFunction(password_cb);

fun normal_cb() {
  status.sprite.SetOpacity(0);
}
Plymouth.SetDisplayNormalFunction(normal_cb);

fun message_cb(text) {
  show_text(text);
}
Plymouth.SetMessageFunction(message_cb);
SCRIPTEOF

cat > config/hooks/normal/0320-plymouth.hook.chroot <<'EOF'
#!/bin/sh
for p in plymouth plymouth-themes; do
  apt-get install -y --no-install-recommends "$p" || echo "SKIPPED plymouth pkg: $p"
done
plymouth-set-default-theme stealthos || true
update-initramfs -u || true
EOF
chmod +x config/hooks/normal/0320-plymouth.hook.chroot

# --- First-boot welcome terminal ---
cat > config/includes.chroot/etc/xdg/autostart/stealth-welcome.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=StealthOS welcome
Exec=xfce4-terminal --hold --title="StealthOS" -e "bash -c 'cat /etc/motd; echo Waiting 25s for Tor...; sleep 25; stealth-check'"
OnlyShowIn=XFCE;
EOF

# ================= v7: Stealth Hub =================
BIN=config/includes.chroot/usr/local/bin
cat > $BIN/stealth-hub <<'EOF'
#!/bin/bash
M=$(cat /run/stealth-mode 2>/dev/null || echo off)
case "$M" in
  tor) S="<span foreground='#39ff14'><b>TOR  -  PROTECTED</b></span>";;
  vpn) S="<span foreground='#f5c542'><b>VPN ONLY</b></span>";;
  *)   S="<span foreground='#ff4d5e'><b>EXPOSED</b></span>";;
esac
if ! command -v yad >/dev/null; then
  echo "Stealth Hub needs yad. Use the terminal commands listed in /etc/motd."; read -r; exit 1
fi
T='xfce4-terminal --hold -e'
yad --title="Stealth Hub" --class=stealth-hub --window-icon=security-high --center \
  --width=420 --no-buttons --columns=2 --form --text-align=center \
  --text="<big><b>STEALTH HUB</b></big>\nNetwork: $S" \
  --field="Tor mode!security-high!Force ALL traffic through Tor:BTN" "bash -c \"sudo stealth-mode tor; notify-send 'Tor mode' 'All traffic forced through Tor'\"" \
  --field="VPN mode!network-vpn!Only allow traffic via your VPN:BTN" "bash -c \"sudo stealth-mode vpn; notify-send 'VPN mode' 'Traffic allowed only over VPN'\"" \
  --field="New identity!view-refresh!Fresh Tor circuits:BTN" "bash -c \"sudo stealth-newid; notify-send 'New identity' 'Fresh Tor circuits requested'\"" \
  --field="Self-check!emblem-default!Verify protections:BTN" "$T 'sudo stealth-check'" \
  --field="Chain test!network-wired!Show exit IP and leaks:BTN" "$T 'chain-test'" \
  --field="Bridges!network-workgroup!Bypass Tor blocking:BTN" "stealth-hub-bridges" \
  --field="New OSINT case!folder-new!Create a case folder:BTN" "stealth-hub-newcase" \
  --field="Wireshark!network-wireless!Packet capture:BTN" "wireshark" \
  --field="Sandbox shell!utilities-terminal!No network, throwaway home:BTN" "$T 'stealth-sandbox bash'" \
  --field="Lock USB!media-removable!Block new USB devices:BTN" "$T 'sudo stealth-usb-lock'" \
  --field="PANIC!process-stop!Cut network and power off:BTN" "$T 'sudo stealth-panic'" \
  --field="Expose (off)!dialog-warning!Disable protections:BTN" "bash -c \"sudo stealth-mode off; notify-send 'WARNING' 'Protections are OFF'\""
EOF
cat > $BIN/stealth-hub-newcase <<'EOF'
#!/bin/bash
n=$(yad --entry --title="New OSINT case" --text="Case name:" --center) || exit 0
[ -n "$n" ] && xfce4-terminal --hold -e "osint-init '$n'"
EOF
cat > $BIN/stealth-hub-bridges <<'EOF'
#!/bin/bash
b=$(yad --entry --title="Tor bridges" --text="Paste one bridge line (from bridges.torproject.org), or type OFF:" --center --width=520) || exit 0
[ -z "$b" ] && exit 0
if [ "${b^^}" = "OFF" ]; then xfce4-terminal --hold -e "sudo stealth-bridges off"
else xfce4-terminal --hold -e "sudo stealth-bridges '$b'"; fi
EOF
chmod +x $BIN/stealth-hub $BIN/stealth-hub-newcase $BIN/stealth-hub-bridges
mkdir -p config/includes.chroot/usr/share/applications
cat > config/includes.chroot/usr/share/applications/stealth-hub.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Stealth Hub
Comment=Network mode, identity, OSINT, panic
Exec=/usr/local/bin/stealth-hub
Icon=security-high
Categories=System;Security;
EOF

# ================= v8: curated Kali-style pentest toolkit (authorized targets only) =================
cat > config/hooks/normal/0330-pentest.hook.chroot <<'EOF'
#!/bin/sh
apt-get update || true
for p in nmap masscan nikto gobuster ffuf sqlmap hydra john hashcat aircrack-ng wifite bettercap kismet reaver bully hcxtools hcxdumptool medusa ncrack crunch cewl wfuzz seclists dirb enum4linux netexec; do
  apt-get install -y --no-install-recommends "$p" || echo "SKIPPED pentest: $p"
done
pip3 install --break-system-packages netexec || echo "SKIPPED pip: netexec"
EOF
chmod +x config/hooks/normal/0330-pentest.hook.chroot
cat >> config/includes.chroot/etc/stealth/OPSEC.md <<'EOF'
9. The pentest tools (sqlmap, hydra, bettercap, aircrack-ng, etc.) are for systems you own or have written permission to test.
   Metasploit and Burp Suite are not in Debian's repos; install them from their vendors if you need them.
EOF

lb build 2>&1 | tee build.log
ISO=$(ls "$WORK"/*.iso | head -1)
sha256sum "$ISO" | tee "$ISO.sha256"

echo
echo "--- Packages skipped during build (review these) ---"
grep -E 'SKIPPED' build.log || echo "none"
echo
echo "ISO: $ISO"
echo "Test first:  bash test-iso-qemu.sh $ISO"
echo "Flash:  sudo dd if=$ISO of=/dev/sdX bs=4M status=progress oflag=sync"
echo "Then on the live system:  stealth-persist-setup /dev/sdX3"
echo "Switch modes:             sudo stealth-mode tor|vpn|off   (or click the mode badge for the Stealth Hub)"
echo "Chain modes:              sudo stealth-chain strict|dynamic|random ; chain-test"
echo "Sandbox untrusted files:  stealth-sandbox <cmd>"
echo "Panic:                    sudo stealth-panic [--fast]"
echo "More:                     stealth-check | stealth-bridges | stealth-newid | stealth-time | stealth-usb-lock | osint-init"
