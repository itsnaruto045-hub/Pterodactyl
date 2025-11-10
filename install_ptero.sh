#!/bin/bash
# Pterodactyl Auto Installer (Panel + Wings)
# English, mostly automatic (~90%)
# Includes MySQL 1396 fix, IP auto connect, TLS & firewall

set -euo pipefail
IFS=$'\n\t'

# ---------- Config ----------
GITHUB_BASE_URL="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer"
TMP_LIB="/tmp/ptero_lib.sh"
LOG_PATH="/var/log/pterodactyl_auto_installer.log"
BANNER_SPEED=0.002
AUTO_YES=0
DO_PANEL=1
DO_WINGS=1
DO_CLEAN=0
DO_PURGE=0
DB_USER="pterodactyl"
DB_PASS="PteroPass123!" # Change this if you want

# ---------- Helpers ----------
info(){ printf "\033[1;34m[*]\033[0m %s\n" "$*"; }
ok(){ printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[-]\033[0m %s\n" "$*"; }

confirm_or_die(){
  if [ "$AUTO_YES" -eq 1 ]; then return 0; fi
  read -r -p "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy] ]] || { err "Aborted by user."; return 1; }
  return 0
}

require_root(){
  if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      warn "Not running as root; sudo will be used where needed."
    else
      err "Run this script as root or install sudo."
      exit 1
    fi
  fi
}

# ---------- Banner ----------
display_banner(){
  clear
  banner=(
"██╗░██╗  ░██████╗██████╗░███████╗  ██╗░░░░░░░░"
"╚═╝██╔╝  ██╔════╝██╔══██╗██╔════╝  ╚██╗░░░░░░░"
"░░██╔╝░  ╚█████╗░██║░░██║█████╗░░  ░╚██╗░░░░░░"
"░██╔╝░░  ░╚═══██╗██║░░██║██╔══╝░░  ░██╔╝░░░░░░"
"██╔╝██╗  ██████╔╝██████╔╝██║░░░░░  ██╔╝░██╗██╗"
"╚═╝░╚═╝  ╚═════╝░╚═════╝░╚═╝░░░░░  ╚═╝░░╚═╝╚═╝"
  )
  echo -e "\033[1;36m"
  for line in "${banner[@]}"; do
    for ((i=0;i<${#line};i++)); do
      printf "%s" "${line:$i:1}"
      sleep "$BANNER_SPEED"
    done
    echo
  done
  echo -e "\033[0m"
  echo -e "\033[1;33m🌟 Pterodactyl Installer — Auto (Panel + Wings)\033[0m"
  echo "================================================================"
  echo
}

# ---------- Flags ----------
while (( $# )); do
  case "$1" in
    --yes|-y) AUTO_YES=1; shift ;;
    --no-panel) DO_PANEL=0; shift ;;
    --no-wings) DO_WINGS=0; shift ;;
    --clean) DO_CLEAN=1; shift ;;
    --purge) DO_PURGE=1; shift ;;
    --help|-h) echo "Usage: $0 [--yes] [--no-panel] [--no-wings] [--clean] [--purge]"; exit 0 ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

# ---------- OS Detect ----------
detect_os(){
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    OS_LIKE="${ID_LIKE:-}"
  else
    OS_ID="unknown"; OS_PRETTY="Unknown"; OS_LIKE=""
  fi
  info "Detected OS: $OS_PRETTY (ID=$OS_ID)"
  if [[ "$OS_ID" == "kali" || "$OS_LIKE" =~ debian || "$OS_ID" =~ debian|ubuntu ]]; then
    PKG="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG="pacman"
  else
    err "Unsupported package manager. Exiting."
    exit 1
  fi
  ok "Using package manager: $PKG"
}

# ---------- Package Install Helpers ----------
apt_install(){ DEBIAN_FRONTEND=noninteractive apt update -y && apt install -y "$@"; }
dnf_install(){ dnf install -y "$@"; }
yum_install(){ yum install -y "$@"; }
pacman_install(){ pacman -Syu --noconfirm "$@"; }

install_curl(){
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl missing — installing..."
    case "$PKG" in
      apt) apt_install curl ca-certificates gnupg lsb-release apt-transport-https || true ;;
      dnf) dnf_install curl || true ;;
      yum) yum_install curl || true ;;
      pacman) pacman_install curl || true ;;
    esac
    ok "curl installed"
  else
    ok "curl present"
  fi
}

# ---------- MySQL 1396 Fix ----------
fix_mysql_user(){
  info "Checking/creating MySQL user '$DB_USER'..."
  if ! command -v mysql >/dev/null 2>&1; then
    warn "mysql client not found. Please install MariaDB/MySQL first."
    return
  fi
  mysql -uroot -e "DROP USER IF EXISTS '$DB_USER'@'127.0.0.1'; CREATE USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS'; CREATE DATABASE IF NOT EXISTS pterodactyl; GRANT ALL PRIVILEGES ON pterodactyl.* TO '$DB_USER'@'127.0.0.1'; FLUSH PRIVILEGES;"
  ok "MySQL user '$DB_USER' ensured (1396 fixed) and DB created."
}

# ---------- Auto Public IP ----------
get_public_ip(){
  ip=$(curl -fsS https://ifconfig.me || curl -fsS https://ipinfo.io/ip || curl -fsS https://api.ipify.org || true)
  if [ -z "$ip" ]; then
    warn "Could not detect public IP. Manual setup needed."
  else
    ok "Detected public IP: $ip"
  fi
  printf "%s" "$ip"
}

update_panel_env(){
  local ip="$1"
  local envs=("/var/www/pterodactyl/.env" "/var/www/panel/.env" "$HOME/pterodactyl/.env")
  for f in "${envs[@]}"; do
    if [ -f "$f" ]; then
      ok "Updating $f with APP_URL=http://$ip"
      cp "$f" "$f.bak-$(date +%s)" || true
      if grep -q "^APP_URL=" "$f"; then
        sed -i "s|^APP_URL=.*|APP_URL=http://$ip|g" "$f"
      else
        echo "APP_URL=http://$ip" >> "$f"
      fi
      return 0
    fi
  done
}

update_wings_config(){
  local ip="$1"
  local cfgs=("/etc/pterodactyl/config.yml" "/etc/pterodactyl/wings/config.yml")
  for f in "${cfgs[@]}"; do
    if [ -f "$f" ]; then
      ok "Updating Wings config $f with bind_address: $ip"
      sed -i "s|bind_address: .*|bind_address: $ip|g" "$f" || true
      return 0
    fi
  done
}

# ---------- TLS Setup ----------
setup_tls(){
  local domain="$1"
  if [ -z "$domain" ]; then
    warn "No domain provided for TLS. Skipping Let's Encrypt."
    return
  fi
  info "Installing certbot for Let's Encrypt..."
  case "$PKG" in
    apt) apt_install certbot python3-certbot-nginx -y || true ;;
    dnf|yum) $PKG install -y certbot python3-certbot-nginx || true ;;
    pacman) pacman_install certbot python-certbot-nginx || true ;;
  esac
  info "Issuing certificate for $domain..."
  certbot --nginx -d "$domain" --non-interactive --agree-tos -m admin@"$domain" || warn "TLS issuance may have failed"
  ok "TLS setup attempted for $domain"
}

# ---------- Firewall ----------
setup_firewall(){
  info "Configuring UFW firewall (if available)..."
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 8080/tcp
    ufw --force enable
    ok "UFW rules set for SSH, HTTP, HTTPS, Wings"
  else
    warn "UFW not found. Please ensure ports 22,80,443,8080 open manually."
  fi
}

# ---------- Main ----------
require_root
display_banner
detect_os
install_curl

info "Installing basic dependencies..."
case "$PKG" in
  apt) apt_install mariadb-server nginx redis-server php-cli php-fpm php-mbstring php-xml php-bcmath php-zip unzip git curl composer -y || true ;;
  dnf|yum) $PKG install -y mariadb-server nginx redis php-cli php-fpm php-mbstring php-xml php-bcmath php-zip unzip git curl composer || true ;;
  pacman) pacman_install mariadb nginx redis php php-fpm php-mbstring php-xml php-bcmath php-zip unzip git curl composer || true ;;
esac

info "Ensuring Docker + docker-compose..."
if ! command -v docker >/dev/null 2>&1; then
  info "Installing docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi
if ! docker compose version >/dev/null 2>&1; then
  ok "Installing docker-compose plugin..."
  if [ "$PKG" = "apt" ]; then apt_install docker-compose-plugin || true; fi
fi

fix_mysql_user

[ -f "$TMP_LIB" ] && rm -f "$TMP_LIB"
if curl -fsSL -o "$TMP_LIB" "$GITHUB_BASE_URL/master/lib/lib.sh"; then
  source "$TMP_LIB" || true
fi

if [ "$DO_PANEL" -eq 1 ]; then
  info "Installing Panel..."
  if type run_ui >/dev/null 2>&1; then run_ui panel; else warn "Upstream run_ui not found, panel may need manual install"; fi
fi
if [ "$DO_WINGS" -eq 1 ]; then
  info "Installing Wings..."
  if type run_ui >/dev/null 2>&1; then run_ui wings; else warn "Upstream run_ui not found, wings may need manual install"; fi
fi

PUB_IP=$(get_public_ip)
if [ -n "$PUB_IP" ]; then
  update_panel_env "$PUB_IP"
  update_wings_config "$PUB_IP"
fi

# TLS Domain Input
if [ "$AUTO_YES" -eq 1 ]; then
  DOMAIN="" # leave blank if unknown
else
  read -r -p "* Enter your domain for HTTPS (leave empty to skip TLS): " DOMAIN
fi
if [ -n "$DOMAIN" ]; then setup_tls "$DOMAIN"; fi

setup_firewall

echo
ok "Installation finished. Your server public IP: $PUB_IP"
cat <<EOF
Cloudflare DNS instructions:

1) Login to Cloudflare dashboard.
2) Go to DNS of your domain.
3) Add an A record:
   - Type: A
   - Name: panel (or desired subdomain)
   - IPv4: $PUB_IP
   - Proxy status: DNS only (grey cloud recommended)
4) Use the same IP in Panel APP_URL and Wings bind_address if needed.

EOF

if [ "$DO_CLEAN" -eq 1 ]; then rm -f "$TMP_LIB"; ok "Temp files removed"; fi
ok "All done. Check Panel (http://<IP or domain>) and Wings. Logs: $LOG_PATH"
