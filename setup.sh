#!/bin/bash
#
# Personal provisioning script
# Installs: Docker, Tailscale
# Configures: Docker registry mirror, apt-cacher-ng proxy
#
# Usage:
#   Interactive: prompts for each component and asks for cache host when needed
#     curl -sSL <url> | sudo bash
#
#   Unattended: opt-in via flags
#     curl -sSL <url> | sudo bash -s -- --yes --host=192.168.0.123 --all
#     curl -sSL <url> | sudo bash -s -- --yes --apt-proxy --host=cache.local
#
# Component flags:
#   --docker                 Install Docker
#   --docker-mirror          Configure Docker registry mirror (needs --host or --docker-mirror-url)
#   --tailscale              Install Tailscale
#   --apt-proxy              Configure apt-cacher-ng proxy (needs --host or --apt-proxy-url)
#   --all                    Enable all components
#
# Cache host / URL flags:
#   --host=HOST              Cache host for BOTH Docker mirror (:5000) and apt proxy (:3142)
#   --docker-mirror-url=URL  Full URL override for Docker registry mirror
#   --apt-proxy-url=URL      Full URL override for apt proxy
#
# Modifiers:
#   --yes, -y                Unattended mode (no prompts, respects component flags)
#   --tailscale-authkey=K    Auto-connect Tailscale with this auth key
#   --tailscale-hostname=H   Set the Tailscale hostname for this machine
#   --help, -h               Show this help
#
# Default ports if only --host is given:
#   Docker registry mirror: 5000
#   apt-cacher-ng proxy:    3142
#

set -e

# ---- Defaults ----
DEFAULT_DOCKER_PORT=5000
DEFAULT_APT_PORT=3142

CACHE_HOST=""
DOCKER_MIRROR_URL=""
APT_PROXY_URL=""

ASSUME_YES=0
DO_DOCKER=0
DO_DOCKER_MIRROR=0
DO_TAILSCALE=0
DO_APT_PROXY=0
TAILSCALE_AUTHKEY=""
TAILSCALE_HOSTNAME=""

# ---- Helpers ----
log() { echo -e "\n\033[1;34m[*]\033[0m $1"; }
ok()  { echo -e "\033[1;32m[✓]\033[0m $1"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $1"; }
err() { echo -e "\033[1;31m[✗]\033[0m $1" >&2; }

show_help() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# Y/n prompt (defaults to Yes). Reads /dev/tty so it works under curl|bash.
confirm() {
  local prompt="$1"
  local reply
  if [ -t 0 ]; then
    read -r -p "$prompt [Y/n] " reply
  else
    read -r -p "$prompt [Y/n] " reply < /dev/tty
  fi
  case "$reply" in
    ""|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Read a value from user (reads from /dev/tty for curl|bash compatibility)
ask() {
  local prompt="$1"
  local reply
  if [ -t 0 ]; then
    read -r -p "$prompt " reply
  else
    read -r -p "$prompt " reply < /dev/tty
  fi
  echo "$reply"
}

# ---- Parse args ----
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --all)
      DO_DOCKER=1
      DO_DOCKER_MIRROR=1
      DO_TAILSCALE=1
      DO_APT_PROXY=1
      ;;
    --docker) DO_DOCKER=1 ;;
    --docker-mirror) DO_DOCKER_MIRROR=1 ;;
    --tailscale) DO_TAILSCALE=1 ;;
    --apt-proxy) DO_APT_PROXY=1 ;;
    --host=*) CACHE_HOST="${arg#*=}" ;;
    --tailscale-authkey=*) TAILSCALE_AUTHKEY="${arg#*=}" ;;
    --tailscale-hostname=*) TAILSCALE_HOSTNAME="${arg#*=}" ;;
    --docker-mirror-url=*) DOCKER_MIRROR_URL="${arg#*=}" ;;
    --apt-proxy-url=*) APT_PROXY_URL="${arg#*=}" ;;
    --help|-h) show_help ;;
    *) err "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ---- Must be root ----
if [ "$EUID" -ne 0 ]; then
  err "Run as root (use sudo)."
  exit 1
fi

# ---- Detect distro ----
. /etc/os-release
DISTRO_ID="$ID"
CODENAME="$VERSION_CODENAME"

if [[ "$DISTRO_ID" != "ubuntu" && "$DISTRO_ID" != "debian" ]]; then
  err "Unsupported distro: $DISTRO_ID"
  exit 1
fi

# ---- Interactive: ask for each component ----
if [ "$ASSUME_YES" -eq 0 ]; then
  echo ""
  echo "Interactive setup — answer each prompt:"
  echo ""
  confirm "Configure apt-cacher-ng proxy?" && DO_APT_PROXY=1
  confirm "Install Docker?"                && DO_DOCKER=1
  if [ "$DO_DOCKER" -eq 1 ]; then
    confirm "Configure Docker registry mirror?" && DO_DOCKER_MIRROR=1
  fi
  confirm "Install Tailscale?"             && DO_TAILSCALE=1
fi

# ---- Nothing to do? ----
if [ "$DO_DOCKER" -eq 0 ] && [ "$DO_DOCKER_MIRROR" -eq 0 ] && \
   [ "$DO_TAILSCALE" -eq 0 ] && [ "$DO_APT_PROXY" -eq 0 ]; then
  warn "Nothing selected. Exiting."
  [ "$ASSUME_YES" -eq 1 ] && echo "Hint: pass component flags like --docker, --apt-proxy, or --all"
  exit 0
fi

# ---- Resolve cache URLs ----
# Priority: explicit *-url flag > --host + default port > interactive prompt > error
needs_cache_host() {
  [ "$DO_APT_PROXY" -eq 1 ] && [ -z "$APT_PROXY_URL" ] && return 0
  [ "$DO_DOCKER_MIRROR" -eq 1 ] && [ -z "$DOCKER_MIRROR_URL" ] && return 0
  return 1
}

if needs_cache_host && [ -z "$CACHE_HOST" ]; then
  if [ "$ASSUME_YES" -eq 0 ]; then
    echo ""
    CACHE_HOST=$(ask "Cache host (IP or hostname, e.g. 192.168.0.123):")
    if [ -z "$CACHE_HOST" ]; then
      err "No cache host provided."
      exit 1
    fi
  else
    err "--apt-proxy or --docker-mirror requires --host=HOST (or a *-url override)."
    exit 1
  fi
fi

# Fill in URLs from host if not explicitly set
if [ "$DO_APT_PROXY" -eq 1 ] && [ -z "$APT_PROXY_URL" ]; then
  APT_PROXY_URL="http://${CACHE_HOST}:${DEFAULT_APT_PORT}"
fi
if [ "$DO_DOCKER_MIRROR" -eq 1 ] && [ -z "$DOCKER_MIRROR_URL" ]; then
  DOCKER_MIRROR_URL="http://${CACHE_HOST}:${DEFAULT_DOCKER_PORT}"
fi

# ---- Plan summary ----
echo ""
echo "Setup plan:"
[ "$DO_APT_PROXY" -eq 1 ]     && echo "  • Configure apt proxy:       $APT_PROXY_URL"
[ "$DO_DOCKER" -eq 1 ]        && echo "  • Install Docker"
[ "$DO_DOCKER_MIRROR" -eq 1 ] && echo "  • Configure Docker mirror:   $DOCKER_MIRROR_URL"
[ "$DO_TAILSCALE" -eq 1 ]     && echo "  • Install Tailscale$( [ -n "$TAILSCALE_AUTHKEY" ] && echo ' (auto-connect)' )"
echo ""

# ---- 1. apt proxy (first, so subsequent apt installs go through it) ----
if [ "$DO_APT_PROXY" -eq 1 ]; then
  log "Configuring apt proxy → ${APT_PROXY_URL}"
  cat > /etc/apt/apt.conf.d/01proxy << EOF
Acquire::http::Proxy "${APT_PROXY_URL}";
Acquire::https::Proxy "DIRECT";
EOF
  ok "apt proxy configured (HTTPS bypasses proxy, as apt-cacher-ng can't cache it)"
fi

# ---- 2. Docker ----
if [ "$DO_DOCKER" -eq 1 ]; then
  if command -v docker &>/dev/null; then
    ok "Docker already installed ($(docker --version))"
  else
    log "Installing Docker..."
    apt update
    apt install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    ok "Docker installed"
  fi
fi

# ---- 3. Docker registry mirror ----
if [ "$DO_DOCKER_MIRROR" -eq 1 ]; then
  if ! command -v docker &>/dev/null; then
    warn "Docker not installed, skipping mirror config."
  else
    log "Configuring Docker registry mirror → ${DOCKER_MIRROR_URL}"
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": ["${DOCKER_MIRROR_URL}"]
}
EOF
    systemctl restart docker
    ok "Docker registry mirror configured"
  fi
fi

# ---- 4. Tailscale ----
if [ "$DO_TAILSCALE" -eq 1 ]; then
  if command -v tailscale &>/dev/null; then
    ok "Tailscale already installed ($(tailscale version | head -n1))"
  else
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed"
  fi

  if [ -n "$TAILSCALE_AUTHKEY" ]; then
    log "Connecting to tailnet..."
    if [ -n "$TAILSCALE_HOSTNAME" ]; then
      tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME"
    else
      tailscale up --authkey="$TAILSCALE_AUTHKEY"
    fi
    ok "Connected: $(tailscale ip -4 2>/dev/null || echo 'check status')"
  elif [ "$ASSUME_YES" -eq 0 ]; then
    if confirm "Connect Tailscale now? (will open browser auth URL)"; then
      if [ -z "$TAILSCALE_HOSTNAME" ]; then
        TAILSCALE_HOSTNAME=$(ask "Tailscale hostname (leave blank to use default):")
      fi
      if [ -n "$TAILSCALE_HOSTNAME" ]; then
        tailscale up --hostname="$TAILSCALE_HOSTNAME"
      else
        tailscale up
      fi
    else
      echo "Skipped. Run 'sudo tailscale up' later."
    fi
  else
    echo "No auth key provided — run 'sudo tailscale up' manually to connect."
  fi
fi

# ---- Summary ----
echo ""
ok "Setup complete."
echo ""
[ "$DO_APT_PROXY" -eq 1 ]     && echo "apt proxy:       $APT_PROXY_URL"
command -v docker    &>/dev/null && echo "Docker:          $(docker --version)"
[ "$DO_DOCKER_MIRROR" -eq 1 ] && command -v docker &>/dev/null && \
  echo "Docker mirror:   $(docker info 2>/dev/null | grep -A1 'Registry Mirrors' | tail -n1 | xargs)"
command -v tailscale &>/dev/null && echo "Tailscale:       $(tailscale version | head -n1)"
