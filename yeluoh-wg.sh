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
pause() { read -r -p $'\n按回车键继续...' _; }

show_status() {
  clear 2>/dev/null || true
  echo '========== WireGuard VPS 状态 =========='
  if ! is_installed; then
    echo '未检测到 WireGuard。'
    return
  fi
  echo "程序：已安装 ($(wg --version 2>/dev/null | head -n1))"
  if [[ -f "$WG_CONF" ]]; then echo "配置：$WG_CONF"; else echo "配置：未初始化 ($WG_CONF 不存在)"; fi
  if systemctl is-active --quiet "wg-quick@$WG_IF" 2>/dev/null; then
    echo "服务：运行中 (wg-quick@$WG_IF)"
  else
    echo "服务：未运行 (wg-quick@$WG_IF)"
  fi
  if [[ -f "$WG_CONF" ]]; then
    echo "监听端口：$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF" || true)"
    echo "出口网卡：$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
    echo "IPv4 转发：$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
  fi
  echo
  echo '--- WireGuard 实时状态 ---'
  if ip link show "$WG_IF" >/dev/null 2>&1; then
    wg show "$WG_IF" 2>&1 || true
  else
    echo "接口 $WG_IF 当前未启动。"
  fi
  echo '--- 已登记客户端 ---'
  if [[ -f "$WG_CONF" ]]; then
    local peers
    peers=$(list_clients)
    if [[ -n "$peers" ]]; then printf '%s\n' "$peers" | while IFS='|' read -r name ip; do printf '  %-20s %s\n' "$name" "$ip"; done
    else echo '  暂无通过此脚本登记的客户端。'; fi
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
  echo '安装/初始化 WireGuard...'
  command -v apt-get >/dev/null 2>&1 || { echo '此脚本目前支持 Ubuntu/Debian (apt)。' >&2; return 1; }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables curl
  install -d -m 700 /etc/wireguard
  if [[ -e "$WG_CONF" ]]; then
    echo "检测到现有配置 $WG_CONF；不会覆盖。尝试启用现有服务。"
    systemctl enable --now "wg-quick@$WG_IF"
    return
  fi
  if [[ -e /etc/wireguard/server_private.key || -e /etc/wireguard/server_public.key ]]; then
    echo '检测到已有服务器密钥但没有 wg0.conf。为保护密钥，停止自动初始化；请先人工核对 /etc/wireguard。' >&2
    return 1
  fi
  local egress server_key
  egress=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [[ -n "$egress" ]] || { echo '无法识别 VPS 默认出口网卡。' >&2; return 1; }
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
  echo "初始化完成。服务器公钥：$(cat /etc/wireguard/server_public.key)"
  echo "请在 AWS 安全组/云厂商防火墙中允许 UDP $WG_PORT 入站。"
}

add_client() {
  [[ -f "$WG_CONF" ]] || { echo 'WireGuard 尚未初始化，请先选择安装/初始化。'; return 1; }
  systemctl is-active --quiet "wg-quick@$WG_IF" || { echo 'wg0 服务未运行，请先检查状态/日志。'; return 1; }
  local name pub ip n endpoint server_pub profile backup
  read -r -p '客户端名称 (字母、数字、_、-，最多32位): ' name
  [[ "$name" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { echo '名称不符合格式。'; return 1; }
  grep -Fq "# client-name: $name" "$WG_CONF" && { echo '此名称已存在。'; return 1; }
  echo '请在 Windows WireGuard 中选择 Add empty tunnel，复制它生成的 Public key。'
  read -r -p '粘贴客户端 Public key: ' pub
  [[ "$pub" =~ ^[A-Za-z0-9+/]{42,43}=?$ ]] || { echo '公钥格式不正确。'; return 1; }
  grep -Fq "PublicKey = $pub" "$WG_CONF" && { echo '此公钥已登记。'; return 1; }
  ip=''
  for n in $(seq 2 254); do
    if ! grep -qF "AllowedIPs = 10.8.0.$n/32" "$WG_CONF"; then ip="10.8.0.$n"; break; fi
  done
  [[ -n "$ip" ]] || { echo '客户端地址池已用完。'; return 1; }
  mkdir -p "$CLIENT_DIR"; chmod 700 "$CLIENT_DIR"
  backup="$WG_CONF.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$WG_CONF" "$backup"
  printf '\n[Peer]\n# client-name: %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$ip" >> "$WG_CONF"
  if ! wg set "$WG_IF" peer "$pub" allowed-ips "$ip/32"; then
    cp -p "$backup" "$WG_CONF"
    echo '运行时添加失败，已恢复配置备份。' >&2
    return 1
  fi
  server_pub=$(cat /etc/wireguard/server_public.key)
  endpoint=$(curl -4fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n' || true)
  if [[ -z "$endpoint" ]]; then read -r -p '无法自动检测公网 IPv4，请输入服务器公网 IPv4: ' endpoint; fi
  [[ "$endpoint" =~ ^[0-9.]+$ ]] || { echo '服务器公网 IPv4 无效；Peer 已添加。请稍后手工补齐客户端配置。' >&2; return 1; }
  profile="$CLIENT_DIR/$name.conf"
  umask 077
  cat > "$profile" <<EOF
[Interface]
PrivateKey = <替换为 Windows WireGuard 本机生成的客户端私钥>
Address = $ip/32
DNS = 1.1.1.1

[Peer]
PublicKey = $server_pub
Endpoint = $endpoint:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$profile"
  echo "客户端 $name ($ip) 已加入。配置模板：$profile"
  echo '将配置安全复制到 Windows，在本机将 PrivateKey 占位符替换为该空隧道的私钥后导入。客户端私钥不要上传到服务器。'
}

remove_client() {
  [[ -f "$WG_CONF" ]] || { echo 'WireGuard 尚未初始化。'; return 1; }
  local lines count choice selected name ip pub tmp backup
  lines=$(list_clients)
  [[ -n "$lines" ]] || { echo '没有通过此脚本登记的客户端。'; return 1; }
  echo '选择要删除的客户端：'
  count=0
  while IFS='|' read -r name ip; do count=$((count+1)); printf '  %d) %s (%s)\n' "$count" "$name" "$ip"; done <<< "$lines"
  read -r -p '输入序号 (0 取消): ' choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { echo '无效序号。'; return 1; }
  if (( choice == 0 )); then return 0; fi
  selected=$(printf '%s\n' "$lines" | sed -n "${choice}p")
  [[ -n "$selected" ]] || { echo '无效序号。'; return 1; }
  IFS='|' read -r name ip <<< "$selected"
  read -r -p "确认删除 $name ($ip)? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo '已取消。'; return 0; }
  pub=$(awk -v target="# client-name: $name" '$0 == target {f=1; next} f && /^PublicKey[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$WG_CONF")
  [[ -n "$pub" ]] || { echo '配置中找不到该客户端公钥。'; return 1; }
  backup="$WG_CONF.bak.$(date +%Y%m%d%H%M%S)"; cp -p "$WG_CONF" "$backup"
  tmp=$(mktemp)
  awk -v target="# client-name: $name" '
    /^\[Peer\][[:space:]]*$/ { if (inside && !drop) printf "%s", block; inside=1; drop=0; block=$0 ORS; next }
    inside { if ($0 == target) drop=1; block=block $0 ORS; next }
    { print }
    END { if (inside && !drop) printf "%s", block }
  ' "$WG_CONF" > "$tmp"
  if cmp -s "$WG_CONF" "$tmp"; then rm -f "$tmp"; echo '没有找到要删除的客户端配置。'; return 1; fi
  install -m 600 "$tmp" "$WG_CONF"; rm -f "$tmp"
  wg set "$WG_IF" peer "$pub" remove 2>/dev/null || true
  rm -f -- "$CLIENT_DIR/$name.conf"
  echo "客户端 $name 已从服务器移除；配置备份：$backup"
  echo '如客户端曾导入配置，也请在 Windows WireGuard 中删除该隧道。'
}

show_logs() { journalctl -u "wg-quick@$WG_IF" -n 80 --no-pager; }

need_root
if ! is_installed; then
  echo '当前 VPS 未安装 WireGuard。'
  read -r -p '现在安装并初始化 wg0？[y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] && install_wireguard || true
elif [[ ! -f "$WG_CONF" ]]; then
  echo '已安装 WireGuard，但未找到 wg0 配置。'
  read -r -p '现在初始化 wg0？[y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] && install_wireguard || true
fi

while true; do
  show_status
  cat <<'EOF'
1) 刷新状态
2) 安装/初始化 WireGuard
3) 添加 Windows 客户端
4) 删除客户端
5) 查看服务日志
0) 退出
EOF
  read -r -p '请选择: ' choice
  case "$choice" in
    1) ;;
    2) install_wireguard; pause ;;
    3) add_client; pause ;;
    4) remove_client; pause ;;
    5) show_logs; pause ;;
    0) exit 0 ;;
    *) echo '无效选项。'; pause ;;
  esac
done
