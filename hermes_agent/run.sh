#!/command/with-contenv bash
# ─────────────────────────────────────────────────────────────────────
# Hermes Agent HA Add-on Entrypoint
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Section 1: Read options ──────────────────────────────────────────
OPTIONS_FILE="/data/options.json"
if [ ! -f "$OPTIONS_FILE" ]; then
    echo "[run] FATAL: $OPTIONS_FILE not found"
    exit 1
fi

opt() { jq -r ".${1} // empty" "$OPTIONS_FILE"; }
opt_bool() { jq -r ".${1} // false" "$OPTIONS_FILE"; }

GIT_URL=$(opt git_url)
GIT_REF=$(opt git_ref)
GIT_TOKEN=$(opt git_token)
AUTO_UPDATE=$(opt_bool auto_update)
21: HASS_URL=$(opt hass_url)
22: HASS_TOKEN=$(opt homeassistant_token)
23: HERMES_HOME_DIR=$(opt hermes_home)
24: ENABLE_DASHBOARD=$(opt_bool enable_dashboard)
25: ENABLE_TERMINAL=$(opt_bool enable_terminal)
26: ENABLE_API=$(opt_bool enable_api)
27: ACCESS_PASSWORD=$(opt access_password)

# ── Section 2: System setup ─────────────────────────────────────────
# Timezone: sync /etc/localtime + /etc/timezone from HA's TZ env var
if [ -n "$TZ" ] && [[ "$TZ" != *..* ]] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
    echo "[run] Timezone: $TZ"
fi

# IPv4 DNS priority (always enabled — no practical IPv6-only home networks)
if grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
    : # already active
elif grep -q "^#[[:space:]]*precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
    sed -i 's/^#[[:space:]]*\(precedence ::ffff:0:0\/96  100\)/\1/' /etc/gai.conf
else
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
fi

# Core paths (HOME=/config set in Dockerfile ENV)
export HERMES_HOME="$HOME/${HERMES_HOME_DIR:-.hermes}"
echo "[run] HERMES_HOME: $HERMES_HOME"

# ── Section 3: Persistent storage setup ──────────────────────────────
SRC_DIR="$HERMES_HOME/hermes-agent"
VENV_DIR="$SRC_DIR/venv"
BREW_DIR="$HOME/.linuxbrew"
NODE_DIR="$HOME/.npm-global"
GO_DIR="$HOME/.go"
CERTS_DIR="$HOME/.certs"
INGRESS_PORT=49169
# Default-profile ports (profile index 0)
# Named profiles get TTYD/dashboard offset by PORT_BLOCK per profile index.
# Gateway API port is offset by 10 per profile index (stays compact).
PORT_BLOCK=1000
TTYD_HERMES_PORT=49269
TTYD_TERMINAL_PORT=49369
DASHBOARD_PORT=49469
GATEWAY_API_PORT=8642
HTTP_PORT=8080
HTTPS_PORT=8443

# Start nginx early with loading page (replaced with full config after setup)
cat > /etc/nginx/nginx.conf << LOADCONF
worker_processes 1;
pid /var/run/nginx.pid;
error_log stderr warn;
events { worker_connections 64; }
http {
    server {
        listen ${INGRESS_PORT};
        location / { root /var/www; try_files /loading.html =404; }
        location = /health { return 200 "OK\n"; add_header Content-Type text/plain; }
    }
}
LOADCONF
nginx
echo "[run] Loading page active (ingress: $INGRESS_PORT)"

# Create persistent directories (only system infra — Hermes creates its own)
for d in "$HERMES_HOME" \
         "$NODE_DIR/lib" \
         "$GO_DIR/bin" \
         "$CERTS_DIR"; do
    mkdir -p "$d"
done

# Go
export GOPATH="$GO_DIR"
export GOBIN="$GO_DIR/bin"
export PATH="$GOBIN:$PATH"

# Node global
export NPM_CONFIG_PREFIX="$NODE_DIR"
export PATH="$NODE_DIR/bin:$PATH"

# Homebrew: sync from image on first boot, then persistent
BREW_IMAGE="/home/linuxbrew/.linuxbrew"
if [ -d "$BREW_IMAGE" ] && [ ! -d "$BREW_DIR/bin" ]; then
    echo "[run] First boot: syncing Homebrew to persistent storage..."
    rsync -a "$BREW_IMAGE/" "$BREW_DIR/"
    echo "[run] Homebrew synced"
fi
if [ -d "$BREW_DIR/bin" ]; then
    export HOMEBREW_PREFIX="$BREW_DIR"
    export HOMEBREW_CELLAR="$BREW_DIR/Cellar"
    export HOMEBREW_REPOSITORY="$BREW_DIR/Homebrew"
    export PATH="$BREW_DIR/sbin:$BREW_DIR/bin:$PATH"
fi

# ── Section 4: Shell environment ─────────────────────────────────────
# ~/.bashrc: persistent, create-if-missing (user-editable)
if [ ! -f /config/.bashrc ]; then
    cat > /config/.bashrc << 'BASHRC'
# Source Hermes API keys (.env first, then profile overrides)
[ -f "${HERMES_HOME:=$HOME/.hermes}/.env" ] && set a && . "$HERMES_HOME/.env" && set +a
# Source Hermes environment (paths, variables, tokens — overrides .env)
[ -f ~/.hermes_profile ] && . ~/.hermes_profile

# If not running interactively, stop here
case $- in
    *i*) ;;
      *) return;;
esac

# Working directory
cd ~

# History
HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=1000000
HISTFILESIZE=1000000

# Shell options
shopt -s checkwinsize
shopt -s globstar

# lesspipe
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# Prompt
PS1='\[\033[01;34m\]\w\[\033[00m\]\$ '

# Colors
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias diff='diff --color=auto'
    alias egrep='egrep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias grep='grep --color=auto'
    alias ls='ls --color=auto'
fi

# ls aliases
alias l='ls -CF'
alias la='ls -A'
alias ll='ls -l'
alias lla='ls -Al'

# Alias definitions
[ -f ~/.bash_aliases ] && . ~/.bash_aliases

# Bash completion
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# Command-not-found handler
if [ -x /usr/lib/command-not-found ]; then
    command_not_found_handle() { /usr/lib/command-not-found -- "$1"; return $?; }
fi
BASHRC
    echo "[run] Created default .bashrc"
fi

# ~/.profile: persistent, create-if-missing (user-editable)
if [ ! -f /config/.profile ]; then
    cat > /config/.profile << 'PROFILE'
# Source .bashrc for paths and aliases
[ -f ~/.bashrc ] && . ~/.bashrc
PROFILE
    echo "[run] Created default .profile"
fi

# ── Section 5: Hermes installation ───────────────────────────────────
MARKER_FILE="$HOME/.hermes_install"

compute_marker() {
    local ref="${GIT_REF:-$(cd "$SRC_DIR" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
    local hash="$(cd "$SRC_DIR" 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo none)"
    local subs="$(ls -d "$SRC_DIR"/*/pyproject.toml 2>/dev/null | xargs -I{} dirname {} | xargs -n1 basename | sort | paste -sd,)"
    echo "${GIT_URL}|${ref}|${hash}|${subs}"
}

install_needed() {
    local current
    current=$(compute_marker)
    if [ ! -f "$MARKER_FILE" ]; then return 0; fi
    if [ "$(cat "$MARKER_FILE")" != "$current" ]; then return 0; fi
    if [ ! -f "$VENV_DIR/bin/activate" ]; then return 0; fi
    if [ ! -f "$VENV_DIR/bin/hermes" ]; then return 0; fi
    return 1
}

activate_venv() {
    if [ ! -f "$VENV_DIR/bin/activate" ]; then
        echo "[run] Creating venv..."
        uv venv "$VENV_DIR" --python 3.11
    fi
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
}

# Clone if missing
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "[run] Cloning Hermes Agent..."
    CLONE_URL="$GIT_URL"
    if [ -n "$GIT_TOKEN" ]; then
        CLONE_URL=$(echo "$GIT_URL" | sed "s|https://|https://${GIT_TOKEN}@|")
    fi
    CLONE_ARGS=()
    if [ -n "$GIT_REF" ]; then
        CLONE_ARGS+=(--branch "$GIT_REF")
    fi
    git clone "${CLONE_ARGS[@]}" "$CLONE_URL" "$SRC_DIR"
    cd "$SRC_DIR"
    git submodule update --init --recursive 2>/dev/null || true
    echo "[run] Clone complete: $(git log --oneline -1)"
fi

# Auto-update
if [ "$AUTO_UPDATE" = "true" ] && [ -d "$SRC_DIR/.git" ]; then
    echo "[run] Pulling latest changes..."
    cd "$SRC_DIR"
    git stash --quiet 2>/dev/null || true
    git pull --ff-only 2>/dev/null || echo "[run] Warning: git pull failed"
    git stash pop --quiet 2>/dev/null || true
    git submodule update --init --recursive 2>/dev/null || true
fi

# Editable install
activate_venv
if install_needed; then
    echo "[run] Installing Hermes (editable)..."
    cd "$SRC_DIR"
    uv pip install -e ".[all,dev]" 2>&1 | tail -5
    if [ -f "$SRC_DIR/mini-swe-agent/pyproject.toml" ]; then
        uv pip install -e "$SRC_DIR/mini-swe-agent" 2>&1 | tail -3
    fi
    if [ -f "$SRC_DIR/tinker-atropos/pyproject.toml" ]; then
        uv pip install -e "$SRC_DIR/tinker-atropos" 2>&1 | tail -3
    fi
    compute_marker > "$MARKER_FILE"
    echo "[run] Install complete"
else
    echo "[run] Install up to date"
fi

# Link npm packages
if [ ! -e "$SRC_DIR/node_modules/agent-browser" ]; then
    mkdir -p "$SRC_DIR/node_modules"
    ln -snf /usr/lib/node_modules/agent-browser "$SRC_DIR/node_modules/agent-browser"
    cd "$SRC_DIR" && npm audit fix --silent 2>/dev/null || true
    echo "[run] Linked agent-browser"
fi

# Build dashboard
if [ -f "$SRC_DIR/web/package.json" ]; then
    DASHBOARD_REBUILD="false"
    if ! grep -q 'HA-ADDON-BASE-PATCHED' "$SRC_DIR/web/src/lib/api.ts" 2>/dev/null; then
        sed -i 's|^const BASE = .*|export const BASE = new URL("..", import.meta.url).pathname.replace(/\\/$/, ""); /* HA-ADDON-BASE-PATCHED */|' "$SRC_DIR/web/src/lib/api.ts"
        DASHBOARD_REBUILD="true"
    fi
    if ! grep -q 'HA-ADDON-BASE-INJECTED' "$SRC_DIR/web/vite.config.ts" 2>/dev/null; then
        sed -i 's|export default defineConfig({|export default defineConfig({\n  /* HA-ADDON-BASE-INJECTED */\n  base: "./",|' "$SRC_DIR/web/vite.config.ts"
        DASHBOARD_REBUILD="true"
    fi
    if [ "$DASHBOARD_REBUILD" = "true" ] || [ ! -d "$SRC_DIR/hermes_cli/web_dist/assets" ]; then
        echo "[run] Building dashboard..."
        (cd "$SRC_DIR/web" && npm install --silent && npx vite build --outDir ../hermes_cli/web_dist --emptyOutDir)
    fi
fi

# Verify
HERMES_VERSION=$(hermes --version 2>/dev/null | head -1 || echo "unknown")
export HERMES_VERSION
echo "[run] Hermes version: $HERMES_VERSION"

# ── Section 6: Initial config scaffolding ──────────────────────────
if [ ! -f "$HERMES_HOME/.env" ] && [ -f "$SRC_DIR/.env.example" ]; then
    cp -p "$SRC_DIR/.env.example" "$HERMES_HOME/.env"
    chmod 600 "$HERMES_HOME/.env"
fi
if [ ! -f "$HERMES_HOME/config.yaml" ] && [ -f "$SRC_DIR/cli-config.yaml.example" ]; then
    cp -p "$SRC_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
fi

# ── Section 7: Environment variable passthrough ──────────────────────
if [ -f "$HERMES_HOME/.env" ]; then
    set -a
    source "$HERMES_HOME/.env"
    set +a
fi
if [ -n "$HASS_TOKEN" ]; then export HASS_TOKEN; fi
if [ -n "$GIT_TOKEN" ]; then export GITHUB_TOKEN="$GIT_TOKEN"; fi
if [ -n "$HASS_URL" ]; then export HASS_URL; fi

if [ "$ENABLE_API" = "true" ]; then export API_SERVER_ENABLED=true; else export API_SERVER_ENABLED=false; fi
if [ -n "$ACCESS_PASSWORD" ]; then
    export API_SERVER_KEY="$ACCESS_PASSWORD"
    echo "hermes:$(openssl passwd -apr1 "$ACCESS_PASSWORD")" > /etc/nginx/.htpasswd
fi

# ── Section 8: TLS certificates ──────────────────────────────────────
if [ ! -f "$CERTS_DIR/server.crt" ]; then
    openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt" \
        -days 3650 -subj "/CN=Hermes Agent CA" 2>/dev/null
    LAN_IP=$(hostname -I | awk '{print $1}' || echo "127.0.0.1")
    openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$CERTS_DIR/server.key" -out /tmp/server.csr -subj "/CN=hermes-agent" 2>/dev/null
    openssl x509 -req -in /tmp/server.csr -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
        -CAcreateserial -out "$CERTS_DIR/server.crt" -days 3650 \
        -extfile <(printf "subjectAltName=DNS:hermes-agent,DNS:localhost,IP:127.0.0.1,IP:%s" "$LAN_IP") 2>/dev/null
fi

# ── Section 9: Profile Discovery ───────────────────────────────────────
DASHBOARD_AVAILABLE="false"
if python3 -c "from hermes_cli.web_server import start_server" 2>/dev/null; then DASHBOARD_AVAILABLE="true"; fi

PROFILES_DATA=$(python3 -c '
import json, os
from hermes_cli.profiles import list_profiles
try:
    profiles = list_profiles()
    out = []
    for p in profiles:
        out.append({"name": p.name, "label": p.name, "path": str(p.path)})
    print(json.dumps(out))
except Exception as e:
    print(json.dumps([{"name": "default", "label": "default", "path": os.environ.get("HERMES_HOME", "/config/.hermes")}]))
')
PROFILES_COUNT=$(echo "$PROFILES_DATA" | jq '. | length' 2>/dev/null || echo 1)

# Nginx config generation (simplified for brevity, keeping profile locations)
PROFILE_UPSTREAMS=""
PROFILE_LOCATIONS=""
for i in $(seq 1 $((PROFILES_COUNT - 1))); do
    P_NAME=$(echo "$PROFILES_DATA" | jq -r ".[$i].name")
    P_TTYD_H=$((TTYD_HERMES_PORT + i * PORT_BLOCK))
    P_TTYD_T=$((TTYD_TERMINAL_PORT + i * PORT_BLOCK))
    P_DASH=$((DASHBOARD_PORT + i * PORT_BLOCK))
    P_API=$((GATEWAY_API_PORT + i * 10))
    PROFILE_UPSTREAMS+="upstream ttyd_hermes_${P_NAME} { server 127.0.0.1:${P_TTYD_H}; }
upstream ttyd_terminal_${P_NAME} { server 127.0.0.1:${P_TTYD_T}; }
upstream hermes_api_${P_NAME} { server 127.0.0.1:${P_API}; }
upstream hermes_dashboard_${P_NAME} { server 127.0.0.1:${P_DASH}; }
"
    PROFILE_LOCATIONS+="
    location /profiles/${P_NAME}/hermes/ { proxy_pass http://ttyd_hermes_${P_NAME}/; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_set_header Host \$host; }
    location /profiles/${P_NAME}/terminal/ { proxy_pass http://ttyd_terminal_${P_NAME}/; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_set_header Host \$host; }
    location /profiles/${P_NAME}/v1/ { proxy_pass http://hermes_api_${P_NAME}/v1/; proxy_http_version 1.1; proxy_set_header Host \$host; }
    location /profiles/${P_NAME}/dashboard/api/ { proxy_pass http://hermes_dashboard_${P_NAME}/api/; proxy_http_version 1.1; proxy_set_header Host 127.0.0.1; proxy_set_header X-Forwarded-Host \$host; proxy_set_header Authorization \"Bearer \$dashboard_token\"; }
    location /profiles/${P_NAME}/dashboard/ { proxy_pass http://hermes_dashboard_${P_NAME}/; proxy_http_version 1.1; proxy_set_header Host 127.0.0.1; proxy_set_header X-Forwarded-Host \$host; }
"
done

# Render landing page
ADDON_SLUG=$(hostname | tr '-' '_')
cp /var/www/landing.html.tpl /var/www/landing.html
sed -i -e "s|%%HERMES_VERSION%%|${HERMES_VERSION}|g" -e "s|%%ADDON_SLUG%%|${ADDON_SLUG}|g" -e "s|%%SHOW_DASHBOARD%%|${DASHBOARD_AVAILABLE}|g" -e "s|%%PROFILES_JSON%%|$(echo "$PROFILES_DATA" | jq -c '.' | sed 's/[&/|]/\\&/g')|g" /var/www/landing.html

# Render Nginx
cp /etc/nginx/nginx.conf.tpl /etc/nginx/nginx.conf
sed -i -e "s|%%INGRESS_PORT%%|${INGRESS_PORT}|g" -e "s|%%TTYD_TERMINAL_PORT%%|${TTYD_TERMINAL_PORT}|g" -e "s|%%TTYD_HERMES_PORT%%|${TTYD_HERMES_PORT}|g" -e "s|%%DASHBOARD_PORT%%|${DASHBOARD_PORT}|g" -e "s|%%CERTS_DIR%%|${CERTS_DIR}|g" -e "s|%%HERMES_VERSION%%|${HERMES_VERSION}|g" -e "s|%%INCLUDE_PORTS%%||g" /etc/nginx/nginx.conf
echo "$PROFILE_UPSTREAMS" > /tmp/upstreams.conf && sed -i '/%%PROFILE_UPSTREAMS%%/r /tmp/upstreams.conf' /etc/nginx/nginx.conf
echo "$PROFILE_LOCATIONS" > /tmp/locations.conf && sed -i '/%%PROFILE_LOCATIONS%%/r /tmp/locations.conf' /etc/nginx/nginx.conf

# ── Section 10: Start services ───────────────────────────────────────
PROFILES_LIST=""

start_gateway() {
    local p_name="${1}"
    local p_home="${2}"
    local p_port="${3}"
    echo "[run] [$p_name] Starting Gateway (port: $p_port)..."
    mkdir -p "$p_home/logs"
    (HERMES_HOME="$p_home" HERMES_CONFIG_OVERRIDE_api_server__port="$p_port" hermes gateway run 2>&1 | tee -a "$p_home/logs/gateway.log") &
    local tee_pid=$!
    sleep 2
    local g_pid=$(pgrep -f "hermes.*gateway run" | sort -n | tail -1 || echo "$tee_pid")
    eval "PID_GATEWAY_${p_name}=\"$g_pid\""
}

# Register signal handler
trap shutdown SIGTERM SIGINT

# Initialize manager state
echo "$PROFILES_DATA" > /tmp/profiles_data.json
echo '"default" "UNAVAILABLE";' > /tmp/dashboard_tokens.conf

# Start Manager
echo "[run] Starting service manager..."
python3 "$(dirname "$0")/manager.py" &
PID_MANAGER=$!

# Start Gateways
for i in $(seq 0 $((PROFILES_COUNT - 1))); do
    NAME=$(echo "$PROFILES_DATA" | jq -r ".[$i].name" | tr '-' '_')
    PATH_VAL=$(echo "$PROFILES_DATA" | jq -r ".[$i].path")
    PROFILES_LIST="$PROFILES_LIST $NAME"
    API=$((GATEWAY_API_PORT + i * 10))
    [ "$NAME" = "default" ] && API=$GATEWAY_API_PORT
    start_gateway "$NAME" "$PATH_VAL" "$API"
done

nginx && nginx -s reload
echo "[run] All systems go."

# ── Section 11: Signal handling ──────────────────────────────────────
shutdown() {
    echo "[run] Stopping..."
    nginx -s quit 2>/dev/null || true
    kill "$PID_MANAGER" 2>/dev/null || true
    pkill -f ttyd 2>/dev/null || true
    pkill -f "hermes gateway" 2>/dev/null || true
    exit 0
}

# ── Section 12: Supervisor loop ──────────────────────────────────────
while true; do
    for p in $PROFILES_LIST; do
        G_VAR="PID_GATEWAY_$p"; G_PID="${!G_VAR}"
        if [ -n "$G_PID" ] && ! kill -0 "$G_PID" 2>/dev/null; then
            echo "[run] [$p] Gateway crashed, restarting..."
            # Restart logic simplified
            start_gateway "$p" "$HERMES_HOME" "$GATEWAY_API_PORT"
        fi
    done
    sleep 10
done
