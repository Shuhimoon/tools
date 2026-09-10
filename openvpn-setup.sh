#!/usr/bin/env bash
# OpenVPN 伺服器／用戶端安裝腳本
# 支援 Linux 與 macOS；伺服器用帳號密碼管理連線者
set -euo pipefail

VERSION="2.1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVPN_BASE="/etc/openvpn"
OVPN_SERVER_DIR="${OVPN_BASE}/server"
EASYRSA_DIR="${OVPN_BASE}/easy-rsa"
STATE_FILE="${OVPN_BASE}/openvpn-setup.env"
CLIENT_DIR="${CLIENT_DIR:-${OVPN_BASE}/clients}"
SYSCTL_FILE="/etc/sysctl.d/99-openvpn.conf"
IPTABLES_UNIT="/etc/systemd/system/openvpn-nat.service"
LAUNCHD_PLIST="/Library/LaunchDaemons/com.openvpn.server.plist"
MARKER="${OVPN_SERVER_DIR}/.managed-by-openvpn-setup"
USER_DB="${OVPN_SERVER_DIR}/users.db"
AUTH_SH="${OVPN_SERVER_DIR}/auth-user.sh"
SHARED_CLIENT="vpn-client"
TEMPLATE_OVPN="${CLIENT_DIR}/client.ovpn"

UNATTENDED=0
PURGE_PACKAGES=0
REDIRECT_GATEWAY=1
CLIENT_TO_CLIENT=0
CLIENT_DIR_SET=0

OVPN_PORT="${OVPN_PORT:-1194}"
OVPN_PROTO="${OVPN_PROTO:-udp}"
OVPN_NETWORK="${OVPN_NETWORK:-10.8.0.0}"
OVPN_NETMASK="${OVPN_NETMASK:-255.255.255.0}"
OVPN_CIDR="${OVPN_CIDR:-24}"
OVPN_DNS1="${OVPN_DNS1:-1.1.1.1}"
OVPN_DNS2="${OVPN_DNS2:-1.0.0.1}"
OVPN_PUBLIC_IP="${OVPN_PUBLIC_IP:-}"
OVPN_NIC="${OVPN_NIC:-}"
OVPN_DNS_PRESET="${OVPN_DNS_PRESET:-cloudflare}"
OVPN_DNS2_SET=0
OVPN_SERVICE=""
OVPN_BIN=""
OPENSSL_BIN=""
BREW_USER="${SUDO_USER:-}"
CLIENT_OVPN_PATH=""
CLIENT_USERNAME=""
CLIENT_AUTH_FILE=""
CLIENT_SERVER_HOST=""
PASSWD_BIN=""
UNPRIV_USER="nobody"
UNPRIV_GROUP="nobody"

HAS_SYSTEMD=0
OS_ID=""
OS_FAMILY=""
PKG_MGR=""

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN="" C_YELLOW="" C_RED="" C_CYAN="" C_BOLD="" C_RESET=""
fi

info() { printf '%s[*]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[錯誤]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
OpenVPN 安裝腳本（Linux / macOS）

啟動後可選「伺服器」、「用戶端」或「帳號管理」。
帳號、密碼由你自行輸入；密碼用 Go 做 PBKDF2 雜湊，並為每位使用者設定 OTP。

用法:
  ./openvpn-setup.sh                     互動選單
  ./openvpn-setup.sh server [選項]       建置伺服器
  ./openvpn-setup.sh client [選項]       安裝用戶端
  ./openvpn-setup.sh users               帳號管理（新增／刪除／改密碼／OTP）
  ./openvpn-setup.sh add-user [帳號]     新增使用者（會問帳號密碼並設定 OTP）
  ./openvpn-setup.sh del-user [帳號]     刪除使用者
  ./openvpn-setup.sh passwd [帳號]       修改密碼
  ./openvpn-setup.sh otp [帳號]          重設 OTP 並顯示 QR
  ./openvpn-setup.sh otp-show [帳號]     再顯示 OTP 綁定資訊
  ./openvpn-setup.sh list-users          列出使用者
  ./openvpn-setup.sh status
  ./openvpn-setup.sh uninstall
  ./openvpn-setup.sh help

伺服器選項:
  --unattended            不詢問（建置後仍可再 add-user）
  --port <埠>             監聽埠 (預設 1194)
  --proto <udp|tcp>       協定 (預設 udp)
  --dns <名稱或 IP>       cloudflare / google / quad9 / adguard 或 IP
  --dns2 <IP>
  --network <CIDR>        例如 10.8.0.0/24
  --public-ip <IP或網域>  寫進用戶端設定的伺服器位址
  --nic <介面>            NAT 出口網卡
  --client-to-client      允許 VPN 用戶互連
  --no-redirect           分割隧道（不把全部流量導進 VPN）

用戶端選項:
  --ovpn <路徑>           從伺服器拷來的 client.ovpn
  --server-host <位址>    覆寫 ovpn 裡的 remote 位址
  --username <帳號>
  --auth-file <路徑>      帳號密碼檔（兩行：帳號、密碼）

範例:
  sudo ./openvpn-setup.sh
  sudo ./openvpn-setup.sh server
  sudo ./openvpn-setup.sh users
  sudo ./openvpn-setup.sh add-user
  sudo ./openvpn-setup.sh client --ovpn ./client.ovpn
EOF
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "請以 root 執行（sudo $0 $*）"
}

is_installed() {
  [[ -f "$MARKER" && -f "${OVPN_SERVER_DIR}/server.conf" ]]
}

is_darwin() { [[ "$OS_FAMILY" == "darwin" ]]; }

load_state() {
  [[ -f "$STATE_FILE" ]] || die "尚未安裝伺服器，找不到 $STATE_FILE。"
  local saved_client_dir="$CLIENT_DIR"
  local client_dir_was_set="${CLIENT_DIR_SET:-0}"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  if [[ "$client_dir_was_set" -eq 1 ]]; then
    CLIENT_DIR="$saved_client_dir"
  fi
  USER_DB="${OVPN_SERVER_DIR}/users.db"
  AUTH_SH="${OVPN_SERVER_DIR}/auth-user.sh"
  TEMPLATE_OVPN="${CLIENT_DIR}/client.ovpn"
}

save_state() {
  umask 077
  cat > "$STATE_FILE" <<EOF
# 由 openvpn-setup.sh 產生，請勿手動亂改
OVPN_PORT='${OVPN_PORT}'
OVPN_PROTO='${OVPN_PROTO}'
OVPN_NETWORK='${OVPN_NETWORK}'
OVPN_NETMASK='${OVPN_NETMASK}'
OVPN_CIDR='${OVPN_CIDR}'
OVPN_DNS1='${OVPN_DNS1}'
OVPN_DNS2='${OVPN_DNS2}'
OVPN_PUBLIC_IP='${OVPN_PUBLIC_IP}'
OVPN_NIC='${OVPN_NIC}'
OVPN_SERVICE='${OVPN_SERVICE}'
REDIRECT_GATEWAY='${REDIRECT_GATEWAY}'
CLIENT_TO_CLIENT='${CLIENT_TO_CLIENT}'
CLIENT_DIR='${CLIENT_DIR}'
OVPN_BIN='${OVPN_BIN}'
OPENSSL_BIN='${OPENSSL_BIN}'
UNPRIV_USER='${UNPRIV_USER}'
UNPRIV_GROUP='${UNPRIV_GROUP}'
PASSWD_BIN='${PASSWD_BIN}'
EOF
  chmod 600 "$STATE_FILE"
}

detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin)
      OS_ID="macos"
      OS_FAMILY="darwin"
      PKG_MGR="brew"
      UNPRIV_USER="nobody"
      UNPRIV_GROUP="nobody"
      ;;
    Linux)
      [[ -f /etc/os-release ]] || die "無法判斷 Linux 發行版（缺少 /etc/os-release）"
      # os-release 會覆寫 VERSION，必須先存起來
      local _keep_version="$VERSION"
      # shellcheck disable=SC1091
      source /etc/os-release
      VERSION="$_keep_version"
      OS_ID="${ID:-unknown}"
      UNPRIV_USER="nobody"
      UNPRIV_GROUP="nogroup"
      getent group nogroup >/dev/null 2>&1 || UNPRIV_GROUP="nobody"
      case "$OS_ID" in
        debian|ubuntu) OS_FAMILY="debian"; PKG_MGR="apt-get" ;;
        rhel|centos|rocky|almalinux|ol)
          OS_FAMILY="rhel"; PKG_MGR="yum"
          command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
          ;;
        fedora) OS_FAMILY="fedora"; PKG_MGR="dnf" ;;
        *) die "不支援的發行版：${ID:-unknown}。請使用 Debian / Ubuntu / RHEL 系列 / Fedora / macOS。" ;;
      esac
      ;;
    *)
      die "不支援的系統：${uname_s}。請使用 Linux 或 macOS。"
      ;;
  esac
}

detect_systemd() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    HAS_SYSTEMD=1
  else
    HAS_SYSTEMD=0
  fi
}

ovpn_version_line() {
  local text=""
  text="$("$OVPN_BIN" --version 2>/dev/null || true)"
  printf '%s\n' "$text" | awk 'NR==1{print; exit}'
}

openvpn_is_legacy_24() {
  local line
  line="$(ovpn_version_line)"
  case "$line" in
    *"OpenVPN 2.3"*|*"OpenVPN 2.4"*) return 0 ;;
    *) return 1 ;;
  esac
}

timestamp_now() {
  date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date
}

resolve_bins() {
  if command -v openvpn >/dev/null 2>&1; then
    OVPN_BIN="$(command -v openvpn)"
  fi
  if [[ -z "$OVPN_BIN" ]]; then
    local brew_bin prefix=""
    brew_bin="$(find_brew 2>/dev/null || true)"
    if [[ -n "$brew_bin" ]]; then
      if [[ -n "$BREW_USER" && "$BREW_USER" != "root" ]]; then
        prefix="$(sudo -u "$BREW_USER" -H "$brew_bin" --prefix 2>/dev/null || true)"
      else
        prefix="$("$brew_bin" --prefix 2>/dev/null || true)"
      fi
      if [[ -x "${prefix}/sbin/openvpn" ]]; then
        OVPN_BIN="${prefix}/sbin/openvpn"
      fi
    fi
  fi
  if command -v openssl >/dev/null 2>&1; then
    OPENSSL_BIN="$(command -v openssl)"
  elif [[ -x /usr/bin/openssl ]]; then
    OPENSSL_BIN="/usr/bin/openssl"
  fi
}

check_tun() {
  if is_darwin; then
    return 0
  fi
  if [[ ! -e /dev/net/tun ]]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
  fi
  if [[ ! -c /dev/net/tun ]]; then
    modprobe tun 2>/dev/null || true
  fi
  [[ -c /dev/net/tun ]] || die "此系統沒有 /dev/net/tun。容器／VPS 需在宿主機開啟 TUN 裝置。"
}

iface_exists() {
  local nic="$1"
  if command -v ip >/dev/null 2>&1; then
    ip link show "$nic" >/dev/null 2>&1
  else
    ifconfig "$nic" >/dev/null 2>&1
  fi
}

detect_nic() {
  if [[ -n "$OVPN_NIC" ]]; then
    iface_exists "$OVPN_NIC" || die "網卡不存在：$OVPN_NIC"
    return
  fi
  if is_darwin; then
    OVPN_NIC="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  else
    OVPN_NIC="$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi
  [[ -n "$OVPN_NIC" ]] || die "找不到預設路由網卡，請用 --nic 指定。"
}

fetch_url() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fsS --max-time 5 "$url" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=5 "$url" 2>/dev/null || true
  fi
}

nic_ipv4() {
  local nic="$1"
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show "$nic" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1
  elif is_darwin && command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr "$nic" 2>/dev/null || true
  else
    ifconfig "$nic" 2>/dev/null | awk '/inet /{print $2; exit}'
  fi
}

detect_public_ip() {
  if [[ -n "$OVPN_PUBLIC_IP" ]]; then
    return
  fi
  local ip="" url
  for url in \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com" \
    "https://api.ipify.org"; do
    ip="$(fetch_url "$url" | tr -d '[:space:]')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      OVPN_PUBLIC_IP="$ip"
      return
    fi
  done
  ip="$(nic_ipv4 "$OVPN_NIC")"
  [[ -n "$ip" ]] || die "無法偵測公網 IP，請用 --public-ip 指定。"
  OVPN_PUBLIC_IP="$ip"
  warn "改用網卡位址 ${OVPN_PUBLIC_IP}。若伺服器在 NAT 後，請改指定對外 IP。"
}

parse_network() {
  local cidr="$1"
  if [[ "$cidr" == */* ]]; then
    OVPN_NETWORK="${cidr%/*}"
    OVPN_CIDR="${cidr#*/}"
  else
    OVPN_NETWORK="$cidr"
    OVPN_CIDR="${OVPN_CIDR:-24}"
  fi
  [[ "$OVPN_NETWORK" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VPN 網段無效：$cidr"
  [[ "$OVPN_CIDR" =~ ^[0-9]+$ && "$OVPN_CIDR" -ge 8 && "$OVPN_CIDR" -le 30 ]] || die "VPN 前置長度無效：$OVPN_CIDR"
  local mask
  mask=$(( 0xffffffff ^ ((1 << (32 - OVPN_CIDR)) - 1) ))
  OVPN_NETMASK="$(printf '%d.%d.%d.%d' \
    $(( (mask >> 24) & 255 )) \
    $(( (mask >> 16) & 255 )) \
    $(( (mask >> 8) & 255 )) \
    $(( mask & 255 )))"
}

set_dns_preset() {
  local name="$1"
  case "$name" in
    cloudflare) OVPN_DNS1="1.1.1.1"; OVPN_DNS2="1.0.0.1" ;;
    google)     OVPN_DNS1="8.8.8.8"; OVPN_DNS2="8.8.4.4" ;;
    quad9)      OVPN_DNS1="9.9.9.9"; OVPN_DNS2="149.112.112.112" ;;
    adguard)    OVPN_DNS1="94.140.14.14"; OVPN_DNS2="94.140.15.15" ;;
    current)
      OVPN_DNS1="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
      OVPN_DNS2="$(awk '/^nameserver/{x=$2} END{print x}' /etc/resolv.conf 2>/dev/null || true)"
      [[ -n "$OVPN_DNS1" ]] || OVPN_DNS1="1.1.1.1"
      [[ -n "$OVPN_DNS2" && "$OVPN_DNS2" != "$OVPN_DNS1" ]] || OVPN_DNS2="1.0.0.1"
      ;;
    *)
      [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "未知 DNS 預設或無效 IP：$name"
      OVPN_DNS1="$name"
      ;;
  esac
}

prompt() {
  local message="$1" default="${2:-}" value=""
  if [[ "$UNATTENDED" -eq 1 ]]; then
    printf '%s\n' "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${message} [${default}]: " value || true
  else
    read -r -p "${message}: " value || true
  fi
  printf '%s\n' "${value:-$default}"
}

prompt_secret() {
  local message="$1" value=""
  if [[ ! -t 0 ]]; then
    die "需要從終端機輸入密碼。"
  fi
  read -r -s -p "${message}: " value || true
  printf '\n' >&2
  printf '%s\n' "$value"
}

confirm() {
  local message="$1" default="${2:-n}" answer
  if [[ "$UNATTENDED" -eq 1 ]]; then
    return 0
  fi
  if [[ "$default" == "y" ]]; then
    read -r -p "${message} [Y/n]: " answer || true
    [[ ! "${answer:-y}" =~ ^[Nn]$ ]]
  else
    read -r -p "${message} [y/N]: " answer || true
    [[ "${answer:-n}" =~ ^[Yy]$ ]]
  fi
}

username_error() {
  local name="$1"
  if [[ -z "$name" ]]; then
    printf '%s\n' "請提供帳號。"
    return 0
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; then
    printf '%s\n' "帳號僅能使用英數、點、底線、連字號（1–32 字）：$name"
    return 0
  fi
  if [[ "$name" == "server" || "$name" == "ca" || "$name" == "$SHARED_CLIENT" ]]; then
    printf '%s\n' "名稱保留：$name"
    return 0
  fi
  return 1
}

validate_username() {
  local err
  err="$(username_error "$1" || true)"
  [[ -z "$err" ]] || die "$err"
}

run_easyrsa() {
  (
    cd "$EASYRSA_DIR"
    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="${EASYRSA_REQ_CN:-OpenVPN-CA}"
    "./easyrsa" --batch "$@"
  )
}

find_brew() {
  local b
  for b in \
    "$(command -v brew 2>/dev/null || true)" \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew; do
    if [[ -n "$b" && -x "$b" ]]; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  if [[ -n "$BREW_USER" && "$BREW_USER" != "root" ]]; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if sudo -u "$BREW_USER" test -x "$b" 2>/dev/null; then
        printf '%s\n' "$b"
        return 0
      fi
    done
  fi
  return 1
}

brew_as_user() {
  local brew_bin
  brew_bin="$(find_brew)" || die "找不到 Homebrew。請先以一般帳號安裝：https://brew.sh"
  [[ -n "$BREW_USER" && "$BREW_USER" != "root" ]] || die "macOS 請用「一般帳號 + sudo」執行，不要直接用 root 登入再裝 Homebrew。"
  sudo -u "$BREW_USER" -H "$brew_bin" "$@"
}

install_packages_server() {
  info "安裝 OpenVPN 與 Easy-RSA…"
  case "$OS_FAMILY" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends \
        openvpn easy-rsa ca-certificates curl iptables iproute2 openssl
      ;;
    rhel)
      if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf install -y epel-release || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm"
        dnf install -y openvpn easy-rsa ca-certificates curl iptables iproute openssl
      else
        yum install -y epel-release
        yum install -y openvpn easy-rsa ca-certificates curl iptables iproute openssl
      fi
      ;;
    fedora)
      dnf install -y openvpn easy-rsa ca-certificates curl iptables iproute openssl
      ;;
    darwin)
      find_brew >/dev/null || die "找不到 Homebrew。請先以一般帳號安裝：https://brew.sh"
      brew_as_user install openvpn easy-rsa
      ;;
  esac
  resolve_bins
  [[ -n "$OVPN_BIN" ]] || die "OpenVPN 安裝失敗。"
  [[ -n "$OPENSSL_BIN" ]] || die "找不到 openssl（用來存放密碼雜湊）。"
  ok "套件已安裝（$(ovpn_version_line)）"
}

install_packages_client() {
  info "安裝 OpenVPN 用戶端…"
  case "$OS_FAMILY" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends openvpn ca-certificates
      ;;
    rhel)
      if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf install -y epel-release || true
        dnf install -y openvpn ca-certificates
      else
        yum install -y epel-release || true
        yum install -y openvpn ca-certificates
      fi
      ;;
    fedora)
      dnf install -y openvpn ca-certificates
      ;;
    darwin)
      if command -v brew >/dev/null 2>&1 || [[ -n "$BREW_USER" ]]; then
        if [[ ${EUID} -eq 0 && -n "$BREW_USER" && "$BREW_USER" != "root" ]]; then
          brew_as_user install openvpn || true
        else
          brew install openvpn || true
        fi
      else
        warn "沒有 Homebrew，將只產生／匯入 .ovpn，請用 Tunnelblick 或 OpenVPN Connect 連線。"
      fi
      ;;
  esac
  resolve_bins
}

seed_easyrsa() {
  mkdir -p "$EASYRSA_DIR"
  local src="" candidate
  local -a candidates=(
    /usr/share/easy-rsa
    /usr/share/easy-rsa/3
    /usr/share/easyrsa
  )
  if is_darwin; then
    local bp brew_bin
    brew_bin="$(find_brew 2>/dev/null || true)"
    if [[ -n "$brew_bin" ]]; then
      if [[ -n "$BREW_USER" && "$BREW_USER" != "root" ]]; then
        bp="$(sudo -u "$BREW_USER" -H "$brew_bin" --prefix easy-rsa 2>/dev/null || true)"
      else
        bp="$("$brew_bin" --prefix easy-rsa 2>/dev/null || true)"
      fi
      [[ -n "$bp" ]] && candidates+=("${bp}/share/easy-rsa" "${bp}/share/easy-rsa/easy-rsa")
    fi
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}/easyrsa" ]]; then
      src="$candidate"
      break
    fi
  done
  if [[ -z "$src" ]] && command -v easyrsa >/dev/null 2>&1; then
    cp -a "$(command -v easyrsa)" "${EASYRSA_DIR}/easyrsa"
    chmod +x "${EASYRSA_DIR}/easyrsa"
    return
  fi
  [[ -n "$src" && -f "${src}/easyrsa" ]] || die "找不到 easyrsa 執行檔。"
  cp -a "${src}/." "$EASYRSA_DIR/"
  chmod +x "${EASYRSA_DIR}/easyrsa"
}

setup_pki() {
  info "建立伺服器憑證（ECDSA / prime256v1）…"
  seed_easyrsa
  umask 077
  cat > "${EASYRSA_DIR}/vars" <<'EOF'
set_var EASYRSA_ALGO "ec"
set_var EASYRSA_CURVE "prime256v1"
set_var EASYRSA_DIGEST "sha256"
set_var EASYRSA_CA_EXPIRE 3650
set_var EASYRSA_CERT_EXPIRE 3650
set_var EASYRSA_CRL_DAYS 3650
set_var EASYRSA_BATCH "1"
set_var EASYRSA_REQ_COUNTRY "TW"
set_var EASYRSA_REQ_PROVINCE "Taiwan"
set_var EASYRSA_REQ_CITY "Taipei"
set_var EASYRSA_REQ_ORG "OpenVPN"
set_var EASYRSA_REQ_EMAIL "vpn@localhost"
set_var EASYRSA_REQ_OU "VPN"
EOF

  if [[ -d "${EASYRSA_DIR}/pki" ]]; then
    warn "發現既有 PKI，將備份後重建。"
    mv "${EASYRSA_DIR}/pki" "${EASYRSA_DIR}/pki.bak.$(date +%Y%m%d%H%M%S)"
  fi

  EASYRSA_REQ_CN="OpenVPN-CA" run_easyrsa init-pki
  EASYRSA_REQ_CN="OpenVPN-CA" run_easyrsa build-ca nopass
  EASYRSA_REQ_CN="server" run_easyrsa gen-req server nopass
  run_easyrsa sign-req server server
  EASYRSA_REQ_CN="$SHARED_CLIENT" run_easyrsa gen-req "$SHARED_CLIENT" nopass
  run_easyrsa sign-req client "$SHARED_CLIENT"
  run_easyrsa gen-crl

  mkdir -p "$OVPN_SERVER_DIR" "${OVPN_SERVER_DIR}/ccd" "${OVPN_SERVER_DIR}/tmp"
  chmod 755 "$OVPN_SERVER_DIR" "${OVPN_SERVER_DIR}/ccd"
  chmod 700 "${OVPN_SERVER_DIR}/tmp"
  cp -f "${EASYRSA_DIR}/pki/ca.crt" "${OVPN_SERVER_DIR}/ca.crt"
  cp -f "${EASYRSA_DIR}/pki/issued/server.crt" "${OVPN_SERVER_DIR}/server.crt"
  cp -f "${EASYRSA_DIR}/pki/private/server.key" "${OVPN_SERVER_DIR}/server.key"
  cp -f "${EASYRSA_DIR}/pki/crl.pem" "${OVPN_SERVER_DIR}/crl.pem"
  if ! "$OVPN_BIN" --genkey secret "${OVPN_SERVER_DIR}/tc.key" 2>/dev/null; then
    "$OVPN_BIN" --genkey --secret "${OVPN_SERVER_DIR}/tc.key"
  fi
  chmod 600 "${OVPN_SERVER_DIR}/server.key" "${OVPN_SERVER_DIR}/tc.key"
  chmod 644 "${OVPN_SERVER_DIR}/ca.crt" "${OVPN_SERVER_DIR}/server.crt" "${OVPN_SERVER_DIR}/crl.pem"
  umask 022
  ok "伺服器憑證與 tls-crypt 金鑰已就緒"
}

passwd_prebuilt_name() {
  local goos goarch
  goos="$(uname -s | tr '[:upper:]' '[:lower:]')"
  goarch="$(uname -m)"
  case "$goarch" in
    x86_64|amd64) goarch=amd64 ;;
    aarch64|arm64) goarch=arm64 ;;
  esac
  printf 'ovpn-passwd-%s-%s\n' "$goos" "$goarch"
}

ensure_passwd_tool() {
  local dest="${OVPN_SERVER_DIR}/ovpn-passwd"
  mkdir -p "$OVPN_SERVER_DIR"
  if [[ -x "$dest" ]]; then
    PASSWD_BIN="$dest"
    return
  fi
  local srcbin="${SCRIPT_DIR}/ovpn-passwd/bin/$(passwd_prebuilt_name)"
  if [[ -f "$srcbin" ]]; then
    cp -f "$srcbin" "$dest"
    chmod 755 "$dest"
    PASSWD_BIN="$dest"
    return
  fi
  if command -v go >/dev/null 2>&1 && [[ -f "${SCRIPT_DIR}/ovpn-passwd/main.go" ]]; then
    info "編譯帳號密碼工具（Go）…"
    ( cd "${SCRIPT_DIR}/ovpn-passwd" && go build -ldflags='-s -w' -o "$dest" . )
    chmod 755 "$dest"
    PASSWD_BIN="$dest"
    return
  fi
  die "找不到 ovpn-passwd。請把 ${srcbin} 放進專案，或在本機安裝 Go 後重試。"
}

fix_user_db_perm() {
  [[ -f "$USER_DB" ]] || return 0
  chmod 640 "$USER_DB" 2>/dev/null || true
  chown "${UNPRIV_USER}:${UNPRIV_GROUP}" "$USER_DB" 2>/dev/null || chmod 644 "$USER_DB"
}

write_auth_script() {
  info "寫入帳號密碼驗證程式（Go）…"
  ensure_passwd_tool
  cat > "$AUTH_SH" <<EOF
#!/bin/bash
# OpenVPN via-file → ovpn-passwd（Go / PBKDF2-SHA256）
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
exec "${PASSWD_BIN}" auth "${USER_DB}" "\$1"
EOF
  chmod 755 "$AUTH_SH"
  if [[ ! -f "$USER_DB" ]]; then
    : > "$USER_DB"
  fi
  fix_user_db_perm
  ok "驗證程式：${AUTH_SH}"
}

user_in_db() {
  local name="$1"
  ensure_passwd_tool
  "$PASSWD_BIN" exists "$USER_DB" "$name"
}

set_user_record() {
  local name="$1" passwd="$2"
  validate_username "$name"
  [[ ${#passwd} -ge 6 ]] || die "密碼至少 6 個字。"
  ensure_passwd_tool
  mkdir -p "$OVPN_SERVER_DIR"
  printf '%s\n' "$passwd" | "$PASSWD_BIN" set "$USER_DB" "$name"
  fix_user_db_perm
}

add_user_interactive() {
  local name="${1:-}" pass1 pass2 err
  local fatal="${2:-1}"
  if [[ -z "$name" ]]; then
    name="$(prompt "帳號" "")"
  fi
  if [[ -z "$name" ]]; then
    return 1
  fi
  err="$(username_error "$name" || true)"
  if [[ -n "$err" ]]; then
    if [[ "$fatal" -eq 1 ]]; then die "$err"; else warn "$err"; return 1; fi
  fi
  if user_in_db "$name"; then
    if [[ "$fatal" -eq 1 ]]; then
      die "使用者已存在：$name（若要改密碼請用 passwd）"
    fi
    warn "使用者已存在：$name"
    return 1
  fi
  if [[ -n "${OVPN_PASS:-}" ]]; then
    pass1="$OVPN_PASS"
  else
    pass1="$(prompt_secret "密碼")"
    pass2="$(prompt_secret "再輸入一次密碼")"
    if [[ "$pass1" != "$pass2" ]]; then
      if [[ "$fatal" -eq 1 ]]; then die "兩次密碼不一致。"; else warn "兩次密碼不一致。"; return 1; fi
    fi
  fi
  if [[ ${#pass1} -lt 6 ]]; then
    if [[ "$fatal" -eq 1 ]]; then die "密碼至少 6 個字。"; else warn "密碼至少 6 個字。"; return 1; fi
  fi
  set_user_record "$name" "$pass1"
  ok "已新增使用者：$name（請立刻用驗證器 App 掃描上方 OTP QR）"
}

cmd_add_user() {
  require_root
  detect_os
  is_installed || die "請先建置伺服器。"
  load_state
  ensure_passwd_tool
  add_user_interactive "${1:-}"
}

cmd_del_user() {
  local name="${1:-}" err
  require_root
  detect_os
  is_installed || die "請先建置伺服器。"
  load_state
  ensure_passwd_tool
  [[ -n "$name" ]] || name="$(prompt "要刪除的帳號" "")"
  [[ -n "$name" ]] || return 1
  err="$(username_error "$name" || true)"
  [[ -z "$err" ]] || { warn "$err"; return 1; }
  user_in_db "$name" || { warn "沒有這個使用者：$name"; return 1; }
  "$PASSWD_BIN" del "$USER_DB" "$name"
  fix_user_db_perm
  ok "已刪除使用者：$name（已連線的工作階段不會立刻中斷）"
}

cmd_passwd() {
  local name="${1:-}" pass1 pass2 err
  require_root
  detect_os
  is_installed || die "請先建置伺服器。"
  load_state
  ensure_passwd_tool
  [[ -n "$name" ]] || name="$(prompt "要改密碼的帳號" "")"
  [[ -n "$name" ]] || return 1
  err="$(username_error "$name" || true)"
  [[ -z "$err" ]] || { warn "$err"; return 1; }
  user_in_db "$name" || { warn "沒有這個使用者：$name"; return 1; }
  if [[ -n "${OVPN_PASS:-}" ]]; then
    pass1="$OVPN_PASS"
  else
    pass1="$(prompt_secret "新密碼")"
    pass2="$(prompt_secret "再輸入一次新密碼")"
    if [[ "$pass1" != "$pass2" ]]; then
      warn "兩次密碼不一致。"
      return 1
    fi
  fi
  set_user_record "$name" "$pass1"
  ok "已更新 $name 的密碼（OTP 金鑰不變）"
}

cmd_otp_new() {
  local name="${1:-}" err
  require_root
  detect_os
  is_installed || die "請先建置伺服器。"
  load_state
  ensure_passwd_tool
  [[ -n "$name" ]] || name="$(prompt "要重設 OTP 的帳號" "")"
  [[ -n "$name" ]] || return 1
  err="$(username_error "$name" || true)"
  [[ -z "$err" ]] || { warn "$err"; return 1; }
  user_in_db "$name" || { warn "沒有這個使用者：$name"; return 1; }
  "$PASSWD_BIN" otp-new "$USER_DB" "$name"
  fix_user_db_perm
  ok "已為 $name 重設 OTP，請用驗證器 App 重新掃描。"
}

cmd_otp_show() {
  local name="${1:-}" err
  require_root
  detect_os
  is_installed || die "請先建置伺服器。"
  load_state
  ensure_passwd_tool
  [[ -n "$name" ]] || name="$(prompt "要顯示 OTP 的帳號" "")"
  [[ -n "$name" ]] || return 1
  err="$(username_error "$name" || true)"
  [[ -z "$err" ]] || { warn "$err"; return 1; }
  user_in_db "$name" || { warn "沒有這個使用者：$name"; return 1; }
  "$PASSWD_BIN" otp-show "$USER_DB" "$name"
}

cmd_list_users() {
  is_installed || die "請先建置伺服器。"
  load_state
  ensure_passwd_tool
  echo "VPN 使用者"
  echo "----------"
  local names
  names="$("$PASSWD_BIN" list "$USER_DB" 2>/dev/null || true)"
  if [[ -z "$names" ]]; then
    echo "（尚無使用者）"
    return
  fi
  printf '%s\n' "$names" | sed 's/^/  /'
}

user_admin_menu() {
  require_root
  detect_os
  is_installed || die "請先建置伺服器。"
  load_state
  ensure_passwd_tool
  echo
  echo "${C_BOLD}VPN 帳號管理${C_RESET}"
  echo "帳號、密碼自行輸入。密碼由 Go 雜湊；每個帳號會產生 OTP（驗證器 App）。"
  echo "連線時密碼欄請輸入：登入密碼 + 6 碼 OTP。"
  while true; do
    echo
    echo "  1) 新增帳號（含設定 OTP）"
    echo "  2) 刪除帳號"
    echo "  3) 修改密碼"
    echo "  4) 重設 OTP（新 QR）"
    echo "  5) 再顯示 OTP"
    echo "  6) 列出帳號"
    echo "  0) 結束"
    echo
    local choice
    choice="$(prompt "請選擇" "1")"
    case "$choice" in
      1) add_user_interactive "" 0 || true ;;
      2) cmd_del_user "" || true ;;
      3) cmd_passwd "" || true ;;
      4) cmd_otp_new "" || true ;;
      5) cmd_otp_show "" || true ;;
      6) cmd_list_users ;;
      0) break ;;
      *) warn "無效的選項：$choice" ;;
    esac
  done
}

write_server_conf() {
  info "寫入伺服器設定（帳號密碼驗證）…"
  local drop_priv="" cipher_lines
  if ! is_darwin; then
    drop_priv=$(printf 'user %s\ngroup %s\n' "$UNPRIV_USER" "$UNPRIV_GROUP")
  fi
  if openvpn_is_legacy_24; then
    cipher_lines=$(printf '%s\n' 'ncp-ciphers AES-256-GCM:AES-128-GCM' 'cipher AES-256-GCM')
  else
    cipher_lines=$(printf '%s\n' \
      'data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305' \
      'data-ciphers-fallback AES-256-GCM')
  fi

  cat > "${OVPN_SERVER_DIR}/server.conf" <<EOF
# 由 openvpn-setup.sh v${VERSION} 產生（server + 帳號密碼）
port ${OVPN_PORT}
proto ${OVPN_PROTO}
dev tun
topology subnet
server ${OVPN_NETWORK} ${OVPN_NETMASK}
ifconfig-pool-persist ${OVPN_SERVER_DIR}/ipp.txt
client-config-dir ${OVPN_SERVER_DIR}/ccd
tmp-dir ${OVPN_SERVER_DIR}/tmp
max-clients 100

ca ${OVPN_SERVER_DIR}/ca.crt
cert ${OVPN_SERVER_DIR}/server.crt
key ${OVPN_SERVER_DIR}/server.key
dh none
ecdh-curve prime256v1
tls-crypt ${OVPN_SERVER_DIR}/tc.key
crl-verify ${OVPN_SERVER_DIR}/crl.pem
remote-cert-tls client

script-security 3
auth-user-pass-verify ${AUTH_SH} via-file
username-as-common-name
auth-gen-token 0
reneg-sec 86400

auth SHA256
${cipher_lines}
tls-version-min 1.2

keepalive 10 120
persist-key
persist-tun
${drop_priv}

push "dhcp-option DNS ${OVPN_DNS1}"
push "dhcp-option DNS ${OVPN_DNS2}"
status-version 2
verb 3
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/openvpn.log
mute 10
EOF

  if [[ "$REDIRECT_GATEWAY" -eq 1 ]]; then
    printf '%s\n' 'push "redirect-gateway def1 bypass-dhcp"' >> "${OVPN_SERVER_DIR}/server.conf"
  fi
  if [[ "$CLIENT_TO_CLIENT" -eq 1 ]]; then
    printf '%s\n' 'client-to-client' >> "${OVPN_SERVER_DIR}/server.conf"
  fi
  if [[ "$OVPN_PROTO" == "udp" ]]; then
    printf '%s\n' 'explicit-exit-notify 1' >> "${OVPN_SERVER_DIR}/server.conf"
  fi

  mkdir -p /var/log/openvpn "${OVPN_SERVER_DIR}/ccd" "${OVPN_SERVER_DIR}/tmp"
  chmod 755 /var/log/openvpn "${OVPN_SERVER_DIR}/ccd"
  chmod 1777 "${OVPN_SERVER_DIR}/tmp"
  chown "${UNPRIV_USER}:${UNPRIV_GROUP}" /var/log/openvpn "${OVPN_SERVER_DIR}/tmp" 2>/dev/null || true
  : > "${OVPN_SERVER_DIR}/ipp.txt"
  chmod 644 "${OVPN_SERVER_DIR}/ipp.txt"
  chown "${UNPRIV_USER}:${UNPRIV_GROUP}" "${OVPN_SERVER_DIR}/ipp.txt" 2>/dev/null || true
  ok "已寫入 ${OVPN_SERVER_DIR}/server.conf"
}

extract_pem() {
  local file="$1"
  awk 'BEGIN{p=0} /-----BEGIN /{p=1} p{print} /-----END /{p=0}' "$file"
}

write_client_template() {
  info "產生共用用戶端設定（Mac / Linux 皆可用）…"
  mkdir -p "$CLIENT_DIR"
  chmod 755 "$CLIENT_DIR"
  local crt="${EASYRSA_DIR}/pki/issued/${SHARED_CLIENT}.crt"
  local key="${EASYRSA_DIR}/pki/private/${SHARED_CLIENT}.key"
  cat > "$TEMPLATE_OVPN" <<EOF
# OpenVPN 用戶端（Linux / macOS）
# 帳號：伺服器上建立的使用者名稱
# 密碼欄：登入密碼立刻接 6 碼 OTP（或中間加空格）
#   例：密碼 hello12、OTP 123456 → hello12123456
client
dev tun
proto ${OVPN_PROTO}
remote ${OVPN_PUBLIC_IP} ${OVPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
auth-user-pass
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
tls-version-min 1.2
verb 3
ignore-unknown-option block-outside-dns
block-outside-dns
<ca>
$(extract_pem "${OVPN_SERVER_DIR}/ca.crt")
</ca>
<cert>
$(extract_pem "$crt")
</cert>
<key>
$(extract_pem "$key")
</key>
<tls-crypt>
$(extract_pem "${OVPN_SERVER_DIR}/tc.key")
</tls-crypt>
EOF
  chmod 644 "$TEMPLATE_OVPN"
  ok "用戶端設定：${TEMPLATE_OVPN}"
}

setup_forwarding_linux() {
  info "開啟 IPv4 轉送…"
  cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null
  ok "ip_forward=1"
}

firewalld_active() {
  command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

ufw_active() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"
}

write_nat_unit_linux() {
  command -v iptables >/dev/null 2>&1 || die "找不到 iptables，無法設定 NAT。"
  local nat_sh="${OVPN_SERVER_DIR}/nat.sh"
  local ipt_bin
  ipt_bin="$(command -v iptables)"
  cat > "$nat_sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IPTABLES="${ipt_bin}"
NIC="${OVPN_NIC}"
SRC="${OVPN_NETWORK}/${OVPN_CIDR}"
PROTO="${OVPN_PROTO}"
PORT="${OVPN_PORT}"

up() {
  "\$IPTABLES" -t nat -C POSTROUTING -s "\$SRC" -o "\$NIC" -j MASQUERADE 2>/dev/null \\
    || "\$IPTABLES" -t nat -A POSTROUTING -s "\$SRC" -o "\$NIC" -j MASQUERADE
  "\$IPTABLES" -C INPUT -p "\$PROTO" --dport "\$PORT" -j ACCEPT 2>/dev/null \\
    || "\$IPTABLES" -I INPUT -p "\$PROTO" --dport "\$PORT" -j ACCEPT
  "\$IPTABLES" -C FORWARD -s "\$SRC" -j ACCEPT 2>/dev/null \\
    || "\$IPTABLES" -I FORWARD -s "\$SRC" -j ACCEPT
  "\$IPTABLES" -C FORWARD -d "\$SRC" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \\
    || "\$IPTABLES" -I FORWARD -d "\$SRC" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

down() {
  "\$IPTABLES" -t nat -D POSTROUTING -s "\$SRC" -o "\$NIC" -j MASQUERADE 2>/dev/null || true
  "\$IPTABLES" -D INPUT -p "\$PROTO" --dport "\$PORT" -j ACCEPT 2>/dev/null || true
  "\$IPTABLES" -D FORWARD -s "\$SRC" -j ACCEPT 2>/dev/null || true
  "\$IPTABLES" -D FORWARD -d "\$SRC" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
}

case "\${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: \$0 up|down" >&2; exit 1 ;;
esac
EOF
  chmod 700 "$nat_sh"

  cat > "$IPTABLES_UNIT" <<EOF
[Unit]
Description=OpenVPN NAT / forwarding rules
After=network-online.target
Wants=network-online.target
Before=openvpn-server@server.service openvpn@server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nat_sh} up
ExecStop=${nat_sh} down

[Install]
WantedBy=multi-user.target
EOF

  if [[ "$HAS_SYSTEMD" -eq 1 ]]; then
    systemctl daemon-reload
    systemctl enable --now openvpn-nat.service
    ok "已啟用 openvpn-nat.service"
  else
    bash "$nat_sh" up
    warn "無 systemd，NAT 規則不會自動在開機後恢復。"
  fi
}

setup_firewall_linux() {
  info "設定防火牆與 NAT（出口網卡：${OVPN_NIC}）…"
  if firewalld_active; then
    local zone
    zone="$(firewall-cmd --get-zone-of-interface="$OVPN_NIC" 2>/dev/null || true)"
    [[ -n "$zone" ]] || zone="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
    firewall-cmd --permanent --zone="$zone" --add-port="${OVPN_PORT}/${OVPN_PROTO}" || true
    firewall-cmd --permanent --zone="$zone" --add-masquerade || true
    firewall-cmd --permanent --zone=trusted --add-source="${OVPN_NETWORK}/${OVPN_CIDR}" || true
    firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 \
      -s "${OVPN_NETWORK}/${OVPN_CIDR}" -o "$OVPN_NIC" -j MASQUERADE 2>/dev/null || true
    firewall-cmd --reload
    ok "已用 firewalld 放行 ${OVPN_PORT}/${OVPN_PROTO} 並設定 NAT"
    return
  fi
  if ufw_active; then
    ufw allow "${OVPN_PORT}/${OVPN_PROTO}" comment "OpenVPN"
    ok "已用 ufw 放行 ${OVPN_PORT}/${OVPN_PROTO}"
  fi
  write_nat_unit_linux
}

setup_networking_darwin() {
  info "設定 macOS 轉送與 pf NAT…"
  sysctl -w net.inet.ip.forwarding=1 >/dev/null
  local pf_rules="${OVPN_SERVER_DIR}/pf.rules"
  cat > "$pf_rules" <<EOF
nat on ${OVPN_NIC} from ${OVPN_NETWORK}/${OVPN_CIDR} to any -> (${OVPN_NIC})
pass in quick proto ${OVPN_PROTO} from any to any port ${OVPN_PORT}
pass from ${OVPN_NETWORK}/${OVPN_CIDR} to any keep state
EOF
  local pf_conf="/etc/pf.conf"
  if [[ -f "$pf_conf" ]] && ! grep -q 'BEGIN openvpn-setup' "$pf_conf"; then
    cp -a "$pf_conf" "${pf_conf}.bak.openvpn"
    cat >> "$pf_conf" <<EOF

# BEGIN openvpn-setup
nat-anchor "org.openvpn"
anchor "org.openvpn"
load anchor "org.openvpn" from "${pf_rules}"
# END openvpn-setup
EOF
  fi
  pfctl -ef /etc/pf.conf 2>/dev/null || pfctl -e 2>/dev/null || true
  pfctl -a org.openvpn -f "$pf_rules" 2>/dev/null || true
  ok "已開啟 IP forwarding 與 pf 規則"
}

pick_service_linux() {
  if [[ "$HAS_SYSTEMD" -ne 1 ]]; then
    OVPN_SERVICE=""
    return
  fi
  if [[ -f /lib/systemd/system/openvpn-server@.service || -f /usr/lib/systemd/system/openvpn-server@.service ]]; then
    OVPN_SERVICE="openvpn-server@server"
  elif [[ -f /lib/systemd/system/openvpn@.service || -f /usr/lib/systemd/system/openvpn@.service ]]; then
    OVPN_SERVICE="openvpn@server"
  else
    warn "找不到 OpenVPN systemd unit，請手動啟動。"
    OVPN_SERVICE=""
  fi
}

enable_service_linux() {
  pick_service_linux
  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P openvpn_can_network_connect 1 2>/dev/null || true
  fi
  if [[ "$OVPN_SERVICE" == "openvpn@server" ]]; then
    ln -sfn "${OVPN_SERVER_DIR}/server.conf" "${OVPN_BASE}/server.conf"
  else
    rm -f "${OVPN_BASE}/server.conf"
    if [[ "$HAS_SYSTEMD" -eq 1 ]]; then
      systemctl disable --now openvpn.service 2>/dev/null || true
    fi
  fi
  [[ -n "$OVPN_SERVICE" ]] || return 0
  info "啟動 ${OVPN_SERVICE}…"
  systemctl enable --now "$OVPN_SERVICE"
  sleep 1
  if systemctl is-active --quiet "$OVPN_SERVICE"; then
    ok "OpenVPN 伺服器運作中"
  else
    warn "服務未能順利啟動： journalctl -u ${OVPN_SERVICE} -xe"
    systemctl --no-pager --full status "$OVPN_SERVICE" || true
  fi
}

enable_service_darwin() {
  info "寫入 launchd 並啟動伺服器…"
  [[ -n "$OVPN_BIN" ]] || resolve_bins
  local start_sh="${OVPN_SERVER_DIR}/start.sh"
  cat > "$start_sh" <<EOF
#!/bin/bash
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1 || true
pfctl -a org.openvpn -f ${OVPN_SERVER_DIR}/pf.rules >/dev/null 2>&1 || true
exec "${OVPN_BIN}" --config "${OVPN_SERVER_DIR}/server.conf"
EOF
  chmod 700 "$start_sh"
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.openvpn.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>${start_sh}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/openvpn/openvpn.out</string>
  <key>StandardErrorPath</key>
  <string>/var/log/openvpn/openvpn.err</string>
</dict>
</plist>
EOF
  chmod 644 "$LAUNCHD_PLIST"
  launchctl bootout system "$LAUNCHD_PLIST" 2>/dev/null || launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  launchctl bootstrap system "$LAUNCHD_PLIST" 2>/dev/null || launchctl load -w "$LAUNCHD_PLIST"
  launchctl enable system/com.openvpn.server 2>/dev/null || true
  launchctl kickstart -k system/com.openvpn.server 2>/dev/null || true
  OVPN_SERVICE="com.openvpn.server"
  sleep 1
  if pgrep -f "${OVPN_SERVER_DIR}/server.conf" >/dev/null 2>&1; then
    ok "OpenVPN 伺服器運作中（launchd）"
  else
    warn "launchd 已載入，但行程可能尚未起來。請看 /var/log/openvpn/"
  fi
}

collect_install_settings() {
  local net_in proto_in port_in dns_in nic_in pub_in
  if [[ "$UNATTENDED" -eq 0 ]]; then
    echo
    echo "${C_BOLD}OpenVPN 伺服器建置（${OS_ID}）${C_RESET}"
    echo
    proto_in="$(prompt "伺服器協定 udp/tcp" "$OVPN_PROTO")"
    OVPN_PROTO="$(printf '%s' "$proto_in" | tr '[:upper:]' '[:lower:]')"
    port_in="$(prompt "伺服器監聽埠" "$OVPN_PORT")"
    OVPN_PORT="$port_in"
    dns_in="$(prompt "推送給連入用戶的 DNS (cloudflare/google/quad9/adguard/IP)" "$OVPN_DNS_PRESET")"
    set_dns_preset "$dns_in"
    net_in="$(prompt "VPN 網段" "${OVPN_NETWORK}/${OVPN_CIDR}")"
    parse_network "$net_in"
    detect_nic
    nic_in="$(prompt "NAT 出口網卡" "$OVPN_NIC")"
    OVPN_NIC="$nic_in"
    detect_public_ip
    pub_in="$(prompt "這台伺服器的對外 IP / 網域" "$OVPN_PUBLIC_IP")"
    OVPN_PUBLIC_IP="$pub_in"
    if confirm "要把連入用戶的全部流量導向 VPN 嗎？" y; then
      REDIRECT_GATEWAY=1
    else
      REDIRECT_GATEWAY=0
    fi
    if confirm "允許 VPN 用戶之間互連（client-to-client）嗎？" n; then
      CLIENT_TO_CLIENT=1
    else
      CLIENT_TO_CLIENT=0
    fi
  else
    parse_network "${OVPN_NETWORK}/${OVPN_CIDR}"
    local saved_dns2="$OVPN_DNS2"
    set_dns_preset "$OVPN_DNS_PRESET"
    if [[ "$OVPN_DNS2_SET" -eq 1 ]]; then
      OVPN_DNS2="$saved_dns2"
    fi
    detect_nic
    detect_public_ip
  fi
  [[ "$OVPN_PROTO" == "udp" || "$OVPN_PROTO" == "tcp" ]] || die "協定只能是 udp 或 tcp。"
  [[ "$OVPN_PORT" =~ ^[0-9]+$ && "$OVPN_PORT" -ge 1 && "$OVPN_PORT" -le 65535 ]] || die "埠號無效：$OVPN_PORT"
  iface_exists "$OVPN_NIC" || die "網卡不存在：$OVPN_NIC"
}

cmd_install_server() {
  require_root
  detect_os
  detect_systemd
  resolve_bins
  check_tun
  if is_installed; then
    die "這台機器已經有 OpenVPN 伺服器。看狀態用 status；若要重裝請先 uninstall。"
  fi
  collect_install_settings

  info "即將建置 OpenVPN 伺服器："
  info "  OS        ${OS_ID}"
  info "  監聽      ${OVPN_PROTO}/${OVPN_PORT}"
  info "  網段      ${OVPN_NETWORK}/${OVPN_CIDR}"
  info "  對外      ${OVPN_PUBLIC_IP}"
  info "  網卡      ${OVPN_NIC}"
  info "  驗證      帳號 + 密碼"
  if [[ "$UNATTENDED" -eq 0 ]]; then
    confirm "開始安裝伺服器？" y || die "已取消。"
  fi

  install_packages_server
  setup_pki
  write_auth_script
  write_server_conf
  if is_darwin; then
    setup_networking_darwin
    enable_service_darwin
  else
    setup_forwarding_linux
    setup_firewall_linux
    enable_service_linux
  fi
  write_client_template
  printf 'v%s %s\n' "$VERSION" "$(timestamp_now)" > "$MARKER"
  save_state

  echo
  ok "OpenVPN 伺服器建置完成"
  echo "  設定檔    : ${OVPN_SERVER_DIR}/server.conf"
  echo "  監聽      : ${OVPN_PROTO}/${OVPN_PORT}"
  echo "  VPN 網段  : ${OVPN_NETWORK}/${OVPN_CIDR}"
  echo "  用戶端檔  : ${TEMPLATE_OVPN}"
  echo "             （拷到 Mac / Linux，用本腳本的 client 模式或 Tunnelblick / OpenVPN Connect 匯入）"

  if [[ "$UNATTENDED" -eq 0 ]]; then
    user_admin_menu
  elif [[ -n "${OVPN_USER:-}" && -n "${OVPN_PASS:-}" ]]; then
    set_user_record "$OVPN_USER" "$OVPN_PASS"
    ok "已新增使用者：${OVPN_USER}"
  else
    warn "無人值守模式未建立使用者。請執行： sudo $0 users"
  fi
}

cmd_install_client() {
  detect_os
  if ! is_darwin; then
    require_root
  fi
  resolve_bins
  echo
  echo "${C_BOLD}OpenVPN 用戶端安裝（${OS_ID}）${C_RESET}"
  echo "請使用從伺服器拷貝的 client.ovpn。"
  echo "連線時輸入帳號；密碼欄填「登入密碼 + 6 碼 OTP」。"
  echo

  local ovpn="$CLIENT_OVPN_PATH"
  if [[ -z "$ovpn" && -f "$TEMPLATE_OVPN" ]]; then
    ovpn="$TEMPLATE_OVPN"
    info "偵測到本機伺服器範本：$ovpn"
  fi
  if [[ -z "$ovpn" ]]; then
    ovpn="$(prompt "client.ovpn 路徑" "")"
  fi
  [[ -n "$ovpn" && -f "$ovpn" ]] || die "找不到 client.ovpn。請先從伺服器複製 ${OVPN_BASE}/clients/client.ovpn"

  local dest_dir dest_ovpn
  if is_darwin && [[ ${EUID} -ne 0 ]]; then
    dest_dir="${HOME}/OpenVPN"
  else
    dest_dir="${OVPN_BASE}/client"
  fi
  mkdir -p "$dest_dir"
  dest_ovpn="${dest_dir}/client.ovpn"
  cp -f "$ovpn" "$dest_ovpn"
  chmod 600 "$dest_ovpn"
  if [[ -n "$CLIENT_SERVER_HOST" ]]; then
    local tmp_remote
    tmp_remote="$(mktemp)"
    awk -v h="$CLIENT_SERVER_HOST" '
      $1=="remote" { $2=h; print; next }
      { print }
    ' "$dest_ovpn" > "$tmp_remote"
    mv "$tmp_remote" "$dest_ovpn"
    chmod 600 "$dest_ovpn"
  fi

  install_packages_client

  echo
  ok "用戶端設定已寫入 ${dest_ovpn}"
  echo "連線時輸入帳號；密碼欄填「登入密碼 + 6 碼 OTP」。"
  echo "  例：密碼 hello12、OTP 123456 → hello12123456"
  if is_darwin; then
    echo
    echo "macOS："
    echo "  1. Tunnelblick：https://tunnelblick.net/  匯入 ${dest_ovpn}"
    echo "  2. OpenVPN Connect：https://openvpn.net/client/"
    echo "  3. 指令： sudo ${OVPN_BIN:-openvpn} --config ${dest_ovpn}"
  else
    echo "連線： sudo openvpn --config ${dest_ovpn}"
  fi
}

cmd_status() {
  detect_os
  detect_systemd
  if ! is_installed; then
    die "尚未安裝伺服器。"
  fi
  load_state
  echo "OpenVPN 伺服器狀態"
  echo "----------------"
  echo "系統         : ${OS_ID}"
  echo "版本標記     : $(tr -d '\n' < "$MARKER" || true)"
  echo "監聽         : ${OVPN_PROTO}/${OVPN_PORT}"
  echo "VPN 網段     : ${OVPN_NETWORK}/${OVPN_CIDR}"
  echo "對外位址     : ${OVPN_PUBLIC_IP}"
  echo "NAT 網卡     : ${OVPN_NIC}"
  echo "驗證方式     : 帳號 + 密碼 + OTP"
  echo "使用者檔     : ${USER_DB}"
  echo "用戶端 ovpn  : ${TEMPLATE_OVPN}"
  echo "服務         : ${OVPN_SERVICE:-（未記錄）}"
  if [[ "$HAS_SYSTEMD" -eq 1 && -n "${OVPN_SERVICE:-}" ]]; then
    echo "服務狀態     : $(systemctl is-active "$OVPN_SERVICE" 2>/dev/null || echo unknown)"
  elif is_darwin; then
    if pgrep -f "${OVPN_SERVER_DIR}/server.conf" >/dev/null 2>&1; then
      echo "服務狀態     : running"
    else
      echo "服務狀態     : stopped"
    fi
    echo "IPv4 轉送    : $(sysctl -n net.inet.ip.forwarding 2>/dev/null || echo '?')"
  fi
  if ! is_darwin; then
    echo "IPv4 轉送    : $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
  fi
  echo
  cmd_list_users
  if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
    echo
    echo "目前連線："
    awk -F, '
      $1=="CLIENT_LIST" && $2!="Common Name" {
        printf "  %-16s %-22s virt=%s rx=%s tx=%s\n", $2, $3, $4, $6, $7
      }
    ' /var/log/openvpn/openvpn-status.log || true
  fi
}

remove_firewall_linux() {
  if firewalld_active; then
    firewall-cmd --permanent --remove-port="${OVPN_PORT}/${OVPN_PROTO}" 2>/dev/null || true
    firewall-cmd --permanent --zone=trusted --remove-source="${OVPN_NETWORK}/${OVPN_CIDR}" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  fi
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${OVPN_PORT}/${OVPN_PROTO}" 2>/dev/null || true
  fi
  if [[ "$HAS_SYSTEMD" -eq 1 ]]; then
    systemctl disable --now openvpn-nat.service 2>/dev/null || true
  fi
  rm -f "$IPTABLES_UNIT"
  [[ "$HAS_SYSTEMD" -eq 1 ]] && systemctl daemon-reload || true
}

remove_networking_darwin() {
  if [[ -f /etc/pf.conf ]]; then
    awk '
      /# BEGIN openvpn-setup/ {skip=1; next}
      /# END openvpn-setup/ {skip=0; next}
      !skip {print}
    ' /etc/pf.conf > /etc/pf.conf.openvpn-new
    mv /etc/pf.conf.openvpn-new /etc/pf.conf
    pfctl -f /etc/pf.conf 2>/dev/null || true
  fi
}

cmd_uninstall() {
  require_root
  detect_os
  detect_systemd
  if [[ ! -f "$STATE_FILE" && ! -f "$MARKER" ]]; then
    die "找不到本腳本的安裝紀錄，拒絕盲目刪除 ${OVPN_BASE}。"
  fi
  [[ -f "$STATE_FILE" ]] && load_state
  if [[ "$UNATTENDED" -eq 0 ]]; then
    confirm "確定要移除 OpenVPN 伺服器設定、憑證與使用者帳號？" || die "已取消。"
  fi

  if is_darwin; then
    launchctl bootout system "$LAUNCHD_PLIST" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST"
    remove_networking_darwin
  else
    pick_service_linux
    if [[ "$HAS_SYSTEMD" -eq 1 ]]; then
      [[ -n "${OVPN_SERVICE:-}" ]] && systemctl disable --now "$OVPN_SERVICE" 2>/dev/null || true
      systemctl disable --now openvpn-server@server 2>/dev/null || true
      systemctl disable --now openvpn@server 2>/dev/null || true
    fi
    remove_firewall_linux
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true
  fi

  rm -rf "$OVPN_SERVER_DIR" "$EASYRSA_DIR" "$CLIENT_DIR"
  rm -f "$STATE_FILE" "${OVPN_BASE}/server.conf" "$MARKER"
  if [[ "$PURGE_PACKAGES" -eq 1 ]]; then
    info "移除套件…"
    case "$OS_FAMILY" in
      debian) apt-get remove --purge -y openvpn easy-rsa || true ;;
      rhel|fedora) "$PKG_MGR" remove -y openvpn easy-rsa || true ;;
      darwin) warn "macOS 請自行 brew uninstall openvpn easy-rsa（用原本的使用者帳號）" ;;
    esac
  fi
  ok "已解除安裝。"
}

interactive_menu() {
  detect_os
  echo
  echo "${C_BOLD}OpenVPN 安裝（Linux / macOS）${C_RESET}"
  echo "目前系統：${OS_ID}"
  echo
  echo "  1) 伺服器（Server）— 讓別人連進來"
  echo "  2) 用戶端（Client）— 連到既有伺服器"
  echo "  3) 帳號管理 — 新增／刪除／改密碼／OTP"
  echo "  4) 伺服器狀態"
  echo "  5) 解除安裝"
  echo "  0) 離開"
  echo
  local choice
  choice="$(prompt "請選擇" "1")"
  case "$choice" in
    1) cmd_install_server ;;
    2) cmd_install_client ;;
    3) user_admin_menu ;;
    4) cmd_status ;;
    5) cmd_uninstall ;;
    0) exit 0 ;;
    *) die "無效的選項：$choice" ;;
  esac
}

need_value() {
  [[ $# -ge 2 && -n "${2}" && "${2}" != -* ]] || die "選項 $1 需要參數"
}

parse_global_args() {
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --unattended) UNATTENDED=1; shift ;;
      --purge-packages) PURGE_PACKAGES=1; shift ;;
      --no-redirect) REDIRECT_GATEWAY=0; shift ;;
      --port) need_value "$@"; OVPN_PORT="$2"; shift 2 ;;
      --proto) need_value "$@"; OVPN_PROTO="$2"; shift 2 ;;
      --dns) need_value "$@"; OVPN_DNS_PRESET="$2"; set_dns_preset "$OVPN_DNS_PRESET"; shift 2 ;;
      --dns2) need_value "$@"; OVPN_DNS2="$2"; OVPN_DNS2_SET=1; shift 2 ;;
      --network) need_value "$@"; parse_network "$2"; shift 2 ;;
      --public-ip) need_value "$@"; OVPN_PUBLIC_IP="$2"; shift 2 ;;
      --nic) need_value "$@"; OVPN_NIC="$2"; shift 2 ;;
      --client-to-client) CLIENT_TO_CLIENT=1; shift ;;
      --client-dir) need_value "$@"; CLIENT_DIR="$2"; CLIENT_DIR_SET=1; shift 2 ;;
      --ovpn) need_value "$@"; CLIENT_OVPN_PATH="$2"; shift 2 ;;
      --server-host) need_value "$@"; CLIENT_SERVER_HOST="$2"; shift 2 ;;
      --username) need_value "$@"; CLIENT_USERNAME="$2"; shift 2 ;;
      --auth-file) need_value "$@"; CLIENT_AUTH_FILE="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      --) shift; rest+=("$@"); break ;;
      -*) die "未知選項：$1" ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  if [[ ${#rest[@]} -gt 0 ]]; then
    set -- "${rest[@]}"
  else
    set --
  fi
  COMMAND="${1:-}"
  shift || true
  COMMAND_ARGS=("$@")
}

main() {
  local COMMAND=""
  local -a COMMAND_ARGS=()
  parse_global_args "$@"

  case "$COMMAND" in
    server|install)
      cmd_install_server
      ;;
    client)
      cmd_install_client
      ;;
    add-user|user-add)
      cmd_add_user "${COMMAND_ARGS[0]:-}"
      ;;
    del-user|user-del|rm-user)
      cmd_del_user "${COMMAND_ARGS[0]:-}"
      ;;
    passwd|passwd-user|mod-user)
      cmd_passwd "${COMMAND_ARGS[0]:-}"
      ;;
    otp|otp-new)
      cmd_otp_new "${COMMAND_ARGS[0]:-}"
      ;;
    otp-show)
      cmd_otp_show "${COMMAND_ARGS[0]:-}"
      ;;
    list-users)
      cmd_list_users
      ;;
    users|account)
      user_admin_menu
      ;;
    status)
      cmd_status
      ;;
    uninstall|remove)
      cmd_uninstall
      ;;
    help)
      usage
      ;;
    "")
      if [[ -t 0 ]]; then
        interactive_menu
      else
        usage
        exit 1
      fi
      ;;
    *)
      die "未知指令：$COMMAND（執行 $0 help）"
      ;;
  esac
}

main "$@"
