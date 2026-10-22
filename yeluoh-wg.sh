#!/usr/bin/env bash
# yeluoh WireGuard server manager for Ubuntu/Debian VPS and AWS EC2.
set -Eeuo pipefail

WG_IF="wg0"
WG_PORT="51820"
WG_NET="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1/24"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
CLIENT_DIR="/etc/wireguard/clients"

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run with sudo: sudo bash $0" >&2
    exit 1
  fi
}

is_installed() { command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; }
pause() { read -r -p $'\nPress Enter to continue...' _; }

show_status() {
  clear 2>/dev/null || true
  echo '========== WireGuard VPS Status =========='
  if ! is_installed; then
    echo 'WireGuard is not installed.'
    return
  fi
  echo "Package: installed ($(wg --version 2>/dev/null | head -n1))"
  if [[ -f "$WG_CONF" ]]; then echo "Config: $WG_CONF"; else echo "Config: not initialized ($WG_CONF not found)"; fi
  if systemctl is-active --quiet "wg-quick@$WG_IF" 2>/dev/null; then
    echo "Service: active (wg-quick@$WG_IF)"
  else
    echo "Service: inactive (wg-quick@$WG_IF)"
  fi
  if [[ -f "$WG_CONF" ]]; then
    local config_port runtime_port
    config_port=$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF" || true)
    runtime_port=$(wg show "$WG_IF" listen-port 2>/dev/null || true)
    if [[ -n "$runtime_port" ]]; then
      echo "UDP listen port: $runtime_port (active)"
      [[ "$config_port" == "$runtime_port" ]] || echo "Config file port: ${config_port:-unset} (differs from runtime)"
    else
      echo "UDP listen port: ${config_port:-unset} (service inactive; showing config value)"
    fi
    echo "Egress interface: $(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
    echo "IPv4 forwarding: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
  fi
  echo
  echo '--- Live WireGuard Status ---'
  if ip link show "$WG_IF" >/dev/null 2>&1; then
    wg show "$WG_IF" 2>&1 || true
  else
    echo "Interface $WG_IF is not up."
  fi
  echo '--- Registered Clients ---'
  if [[ -f "$WG_CONF" ]]; then
    local peers
    peers=$(list_clients)
    if [[ -n "$peers" ]]; then printf '%s\n' "$peers" | while IFS='|' read -r name ip; do printf '  %-20s %s\n' "$name" "$ip"; done
    else echo '  No clients registered by this script.'; fi
  fi
  echo '========================================'
}

list_clients() {
  [[ -f "$WG_CONF" ]] || return 0
  awk '
    /^\[Peer\][[:space:]]*$/ { if (inpeer && name != "") print name "|" ip; inpeer=1; name=""; ip=""; next }
    /^\[/ { if (inpeer && name != "") print name "|" ip; inpeer=0 }
    inpeer && /^# client-name: / { sub(/^# client-name: /, ""); name=$0 }
    inpeer && /^[[:space:]]*AllowedIPs[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); ip=$0 }
    END { if (inpeer && name != "") print name "|" ip }
  ' "$WG_CONF" | awk '!seen[$0]++'
}

install_wireguard() {
  echo 'Installing/initializing WireGuard...'
  command -v apt-get >/dev/null 2>&1 || { echo 'This script currently supports Ubuntu/Debian (apt).' >&2; return 1; }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables curl
  install -d -m 700 /etc/wireguard
  if [[ -e "$WG_CONF" ]]; then
    echo "Existing config found at $WG_CONF; it will not be overwritten. Attempting to enable the existing service."
    systemctl enable --now "wg-quick@$WG_IF"
    return
  fi
  if [[ -e /etc/wireguard/server_private.key || -e /etc/wireguard/server_public.key ]]; then
    echo 'Existing server key found but wg0.conf is missing. Initialization stopped to protect the key; inspect /etc/wireguard manually.' >&2
    return 1
  fi
  local egress server_key
  egress=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [[ -n "$egress" ]] || { echo 'Could not detect the VPS default egress interface.' >&2; return 1; }
  umask 077
  wg genkey > /etc/wireguard/server_private.key
  wg pubkey < /etc/wireguard/server_private.key > /etc/wireguard/server_public.key
  server_key=$(cat /etc/wireguard/server_private.key)
  cat > "$WG_CONF" <<EOF
[Interface]
Address = $WG_SERVER_IP
ListenPort = $WG_PORT
PrivateKey = $server_key
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s $WG_NET -o $egress -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s $WG_NET -o $egress -j MASQUERADE
EOF
  chmod 600 "$WG_CONF"
  printf '%s\n' 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-forward.conf
  sysctl --system >/dev/null
  systemctl enable --now "wg-quick@$WG_IF"
  echo "Initialization complete. Server public key: $(cat /etc/wireguard/server_public.key)"
  echo "Allow inbound UDP $WG_PORT in the AWS security group or your cloud firewall."
}

add_client() {
  [[ -f "$WG_CONF" ]] || { echo 'WireGuard is not initialized. Choose Install/Initialize first.'; return 1; }
  systemctl is-active --quiet "wg-quick@$WG_IF" || { echo 'wg0 service is inactive. Check the status and logs first.'; return 1; }
  local name pub ip n endpoint server_pub server_port profile backup
  read -r -p 'Client name (letters, numbers, _ or -, up to 32 characters): ' name
  [[ "$name" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { echo 'Invalid client name.'; return 1; }
  grep -Fq "# client-name: $name" "$WG_CONF" && { echo 'A client with this name already exists.'; return 1; }
  echo 'In the Windows WireGuard app, select Add empty tunnel and copy its generated public key.'
  read -r -p 'Paste the client public key: ' pub
  [[ "$pub" =~ ^[A-Za-z0-9+/]{42,43}=?$ ]] || { echo 'Invalid public key format.'; return 1; }
  grep -Fq "PublicKey = $pub" "$WG_CONF" && { echo 'This public key is already registered.'; return 1; }
  ip=''
  for n in $(seq 2 254); do
    if ! grep -qF "AllowedIPs = 10.8.0.$n/32" "$WG_CONF"; then ip="10.8.0.$n"; break; fi
  done
  [[ -n "$ip" ]] || { echo 'The client address pool is full.'; return 1; }
  mkdir -p "$CLIENT_DIR"; chmod 700 "$CLIENT_DIR"
  backup="$WG_CONF.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$WG_CONF" "$backup"
  printf '\n[Peer]\n# client-name: %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$ip" >> "$WG_CONF"
  if ! wg set "$WG_IF" peer "$pub" allowed-ips "$ip/32"; then
    cp -p "$backup" "$WG_CONF"
    echo 'Failed to add the peer at runtime; restored the config backup.' >&2
    return 1
  fi
  server_pub=$(cat /etc/wireguard/server_public.key)
  server_port=$(wg show "$WG_IF" listen-port 2>/dev/null || awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF")
  endpoint=$(curl -4fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n' || true)
  if [[ -z "$endpoint" ]]; then read -r -p 'Could not detect the public IPv4. Enter the server public IPv4: ' endpoint; fi
  [[ "$endpoint" =~ ^[0-9.]+$ ]] || { echo 'Invalid server public IPv4. The peer was added; complete the client config manually.' >&2; return 1; }
  profile="$CLIENT_DIR/$name.conf"
  umask 077
  cat > "$profile" <<EOF
[Interface]
PrivateKey = <REPLACE_WITH_CLIENT_PRIVATE_KEY_GENERATED_ON_WINDOWS>
Address = $ip/32
DNS = 1.1.1.1

[Peer]
PublicKey = $server_pub
Endpoint = $endpoint:$server_port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$profile"
  echo "Client $name ($ip) added. Config template: $profile"
  echo 'Securely copy the template to Windows, replace the PrivateKey placeholder locally with the key from the empty tunnel, then import it. Never upload the client private key to the server.'
}

change_port() {
  [[ -f "$WG_CONF" ]] || { echo 'wg0 config not found. Install/initialize WireGuard first.'; return 1; }
  local current new_port line_count tmp backup runtime profile
  current=$(wg show "$WG_IF" listen-port 2>/dev/null || awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF")
  echo "Current UDP port: ${current:-unset}"
  read -r -p 'Enter a new UDP port (1-65535): ' new_port
  [[ "$new_port" =~ ^[0-9]{1,5}$ ]] || { echo 'Port must be an integer from 1 to 65535.'; return 1; }
  new_port=$((10#$new_port))
  (( new_port >= 1 && new_port <= 65535 )) || { echo 'Port must be between 1 and 65535.'; return 1; }
  [[ "$new_port" != "$current" ]] || { echo 'The new port matches the current port.'; return 0; }
  if command -v ss >/dev/null 2>&1 && ss -Hlun "sport = :$new_port" 2>/dev/null | grep -q .; then
    echo "UDP port $new_port is already in use; no changes made." >&2
    return 1
  fi
  line_count=$(grep -Ec '^[[:space:]]*ListenPort[[:space:]]*=' "$WG_CONF" || true)
  [[ "$line_count" == 1 ]] || { echo 'The config must contain exactly one ListenPort entry; no changes made.' >&2; return 1; }
  tmp=$(mktemp)
  sed -E "s/^([[:space:]]*ListenPort[[:space:]]*=[[:space:]]*)[0-9]+/\\1$new_port/" "$WG_CONF" > "$tmp"
  grep -Eq "^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*$new_port[[:space:]]*$" "$tmp" || { rm -f "$tmp"; echo 'Could not update the config port.' >&2; return 1; }
  backup="$WG_CONF.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$WG_CONF" "$backup"
  install -m 600 "$tmp" "$WG_CONF"; rm -f "$tmp"
  if ip link show "$WG_IF" >/dev/null 2>&1; then
    if ! wg set "$WG_IF" listen-port "$new_port"; then
      cp -p "$backup" "$WG_CONF"
      echo 'Runtime port update failed; restored the config backup.' >&2
      return 1
    fi
    echo "WireGuard runtime and config have been switched to UDP $new_port."
  else
    echo "Config updated to UDP $new_port; the change will take effect when the service starts."
  fi
  for profile in "$CLIENT_DIR"/*.conf; do
    [[ -f "$profile" ]] || continue
    sed -i -E "s/(Endpoint[[:space:]]*=[[:space:]]*[^:]+:)[0-9]+/\\1$new_port/" "$profile"
  done
  runtime=$(wg show "$WG_IF" listen-port 2>/dev/null || true)
  echo 'Update the UDP inbound port in your cloud security group/firewall and change the Endpoint port in imported Windows client tunnels.'
  echo "Server config backup: $backup"
  [[ -z "$runtime" || "$runtime" == "$new_port" ]] || echo "Warning: runtime port reports $runtime; check the service status." >&2
}

remove_client() {
  [[ -f "$WG_CONF" ]] || { echo 'WireGuard is not initialized.'; return 1; }
  local lines count choice selected name ip pub tmp backup
  lines=$(list_clients)
  [[ -n "$lines" ]] || { echo 'No clients registered by this script.'; return 1; }
  echo 'Select a client to remove:'
  count=0
  while IFS='|' read -r name ip; do count=$((count+1)); printf '  %d) %s (%s)\n' "$count" "$name" "$ip"; done <<< "$lines"
  read -r -p 'Enter a number (0 to cancel): ' choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { echo 'Invalid selection.'; return 1; }
  if (( choice == 0 )); then return 0; fi
  selected=$(printf '%s\n' "$lines" | sed -n "${choice}p")
  [[ -n "$selected" ]] || { echo 'Invalid selection.'; return 1; }
  IFS='|' read -r name ip <<< "$selected"
  read -r -p "Remove $name ($ip)? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo 'Cancelled.'; return 0; }
  pub=$(awk -v target="# client-name: $name" '$0 == target {f=1; next} f && /^PublicKey[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$WG_CONF")
  [[ -n "$pub" ]] || { echo 'Could not find this client public key in the config.'; return 1; }
  backup="$WG_CONF.bak.$(date +%Y%m%d%H%M%S)"; cp -p "$WG_CONF" "$backup"
  tmp=$(mktemp)
  awk -v target="# client-name: $name" '
    /^\[Peer\][[:space:]]*$/ { if (inside && !drop) printf "%s", block; inside=1; drop=0; block=$0 ORS; next }
    inside { if ($0 == target) drop=1; block=block $0 ORS; next }
    { print }
    END { if (inside && !drop) printf "%s", block }
  ' "$WG_CONF" > "$tmp"
  if cmp -s "$WG_CONF" "$tmp"; then rm -f "$tmp"; echo 'Client config entry not found.'; return 1; fi
  install -m 600 "$tmp" "$WG_CONF"; rm -f "$tmp"
  wg set "$WG_IF" peer "$pub" remove 2>/dev/null || true
  rm -f -- "$CLIENT_DIR/$name.conf"
  echo "Client $name removed from the server. Config backup: $backup"
  echo 'If the client config was imported, also remove that tunnel from the Windows WireGuard app.'
}

show_logs() { journalctl -u "wg-quick@$WG_IF" -n 80 --no-pager; }

need_root
if ! is_installed; then
  echo 'WireGuard is not installed on this VPS.'
  read -r -p 'Install and initialize wg0 now? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] && install_wireguard || true
elif [[ ! -f "$WG_CONF" ]]; then
  echo 'WireGuard is installed, but wg0.conf was not found.'
  read -r -p 'Initialize wg0 now? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] && install_wireguard || true
fi

while true; do
  show_status
  cat <<'EOF'
1) Refresh status
2) Install/initialize WireGuard
3) Add Windows client
4) Remove client
5) View service logs
6) Change WireGuard UDP port
0) Exit
EOF
  read -r -p 'Select an option: ' choice
  case "$choice" in
    1) ;;
    2) install_wireguard; pause ;;
    3) add_client; pause ;;
    4) remove_client; pause ;;
    5) show_logs; pause ;;
    6) change_port; pause ;;
    0) exit 0 ;;
    *) echo 'Invalid option.'; pause ;;
  esac
done

