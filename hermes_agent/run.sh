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
HASS_URL=$(opt hass_url)
HASS_TOKEN=$(opt homeassistant_token)
HERMES_HOME_DIR=$(opt hermes_home)
ENABLE_DASHBOARD=$(opt_bool enable_dashboard)
ENABLE_TERMINAL=$(opt_bool enable_terminal)
ENABLE_API=$(opt_bool enable_api)
ACCESS_PASSWORD=$(opt access_password)

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
[ -f "${HERMES_HOME:=$HOME/.hermes}/.env" ] && set -a && . "$HERMES_HOME/.env" && set +a
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
# Hermes autostart is handled by /usr/local/bin/start-hermes (via ttyd),
# not .profile, to avoid recursion when Hermes spawns login subshells.
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

# Auto-update (stash local changes, pull, restore)
if [ "$AUTO_UPDATE" = "true" ] && [ -d "$SRC_DIR/.git" ]; then
    echo "[run] Pulling latest changes..."
    cd "$SRC_DIR"
    git stash --quiet 2>/dev/null || true
    git pull --ff-only 2>/dev/null || echo "[run] Warning: git pull failed (branch may have diverged)"
    git stash pop --quiet 2>/dev/null || true
    git submodule update --init --recursive 2>/dev/null || true
fi

# Editable install
activate_venv
if install_needed; then
    echo "[run] Installing Hermes (editable)..."
    cd "$SRC_DIR"
    uv pip install -e ".[all,dev]" 2>&1 | tail -5
    # Submodules
    if [ -f "$SRC_DIR/mini-swe-agent/pyproject.toml" ]; then
        uv pip install -e "$SRC_DIR/mini-swe-agent" 2>&1 | tail -3
    fi
    if [ -f "$SRC_DIR/tinker-atropos/pyproject.toml" ]; then
        uv pip install -e "$SRC_DIR/tinker-atropos" 2>&1 | tail -3
    fi
    compute_marker > "$MARKER_FILE"
    echo "[run] Install complete"
else
    echo "[run] Install up to date (marker match)"
fi

# Link image-installed npm packages into project node_modules (where Hermes expects them)
if [ ! -e "$SRC_DIR/node_modules/agent-browser" ]; then
    mkdir -p "$SRC_DIR/node_modules"
    ln -snf /usr/lib/node_modules/agent-browser "$SRC_DIR/node_modules/agent-browser"
    cd "$SRC_DIR" && npm audit fix --silent 2>/dev/null || true
    echo "[run] Linked agent-browser into project"
fi

# Build dashboard web frontend
if [ -f "$SRC_DIR/web/package.json" ]; then
    # ── Patches for reverse-proxy compatibility (idempotent) ──
    # The upstream dashboard assumes it's served at the URL root, using
    # absolute paths (/api/*, /dashboard-plugins/*) that break behind a
    # reverse proxy. We patch three files so ALL API and plugin requests
    # are prefixed with the SPA's actual mount point — stable across HA
    # Ingress, direct ports, custom reverse proxies, and React Router
    # client-side navigation.
    DASHBOARD_REBUILD="false"

    # 1. api.ts: compute BASE from import.meta.url (the JS chunk's runtime URL).
    #    Stripping the trailing slash off `{SPA_ROOT}/assets/../` gives the
    #    stable mount path. Also exported so usePlugins.ts can reuse it.
    if ! grep -q 'HA-ADDON-BASE-PATCHED' "$SRC_DIR/web/src/lib/api.ts" 2>/dev/null; then
        if grep -qE '^const BASE = ' "$SRC_DIR/web/src/lib/api.ts" 2>/dev/null; then
            sed -i 's|^const BASE = .*|export const BASE = new URL("..", import.meta.url).pathname.replace(/\\/$/, ""); /* HA-ADDON-BASE-PATCHED */|' "$SRC_DIR/web/src/lib/api.ts"
            DASHBOARD_REBUILD="true"
        fi
    fi

    # 2. usePlugins.ts: prefix hardcoded /dashboard-plugins/* URLs with BASE so
    #    plugin JS/CSS loads via the same reverse-proxy route as /api/. Depends
    #    on patch 1 having exported BASE — skip if api.ts wasn't patched.
    #    Sanity-check surfaces a warning if upstream changes the URL syntax
    #    (e.g. switches from template literals to string concatenation).
    if grep -q 'HA-ADDON-BASE-PATCHED' "$SRC_DIR/web/src/lib/api.ts" 2>/dev/null && \
       [ -f "$SRC_DIR/web/src/plugins/usePlugins.ts" ] && \
       ! grep -q 'HA-ADDON-PLUGINS-PATCHED' "$SRC_DIR/web/src/plugins/usePlugins.ts" 2>/dev/null; then
        sed -i \
            -e 's|import { api } from "@/lib/api";|import { api, BASE } from "@/lib/api"; /* HA-ADDON-PLUGINS-PATCHED */|' \
            -e 's|`/dashboard-plugins/|`${BASE}/dashboard-plugins/|g' \
            "$SRC_DIR/web/src/plugins/usePlugins.ts"
        if ! grep -q '${BASE}/dashboard-plugins/' "$SRC_DIR/web/src/plugins/usePlugins.ts" 2>/dev/null; then
            echo "[run] WARNING: usePlugins.ts URL pattern changed upstream — dashboard plugins may 404"
        fi
        DASHBOARD_REBUILD="true"
    fi

    # 3. vite.config.ts: inject base:"./" into defineConfig (HTML asset paths).
    #    Ensures npm run build (called by `hermes update` / `hermes web`) also
    #    produces relative script/link hrefs, not just our explicit vite build.
    if ! grep -q 'HA-ADDON-BASE-INJECTED' "$SRC_DIR/web/vite.config.ts" 2>/dev/null; then
        # Clean up bare base: "./" lines from pre-marker versions (e.g. 1.0.3-dev)
        sed -i '/^\s*base:\s*"\.\/",\s*$/d' "$SRC_DIR/web/vite.config.ts" 2>/dev/null || true
        sed -i 's|export default defineConfig({|export default defineConfig({\n  /* HA-ADDON-BASE-INJECTED */\n  base: "./",|' "$SRC_DIR/web/vite.config.ts"
        DASHBOARD_REBUILD="true"
    fi

    # 4. Detect stale build (absolute paths in output → needs rebuild)
    if grep -q 'src="/assets/' "$SRC_DIR/hermes_cli/web_dist/index.html" 2>/dev/null; then
        DASHBOARD_REBUILD="true"
    fi

    if [ "$DASHBOARD_REBUILD" = "true" ] || [ ! -d "$SRC_DIR/hermes_cli/web_dist/assets" ]; then
        echo "[run] Building dashboard frontend..."
        if (cd "$SRC_DIR/web" && npm install --silent 2>&1 | tail -3 && npx vite build --outDir ../hermes_cli/web_dist --emptyOutDir 2>&1 | tail -3); then
            echo "[run] Dashboard frontend built"
        else
            echo "[run] Warning: dashboard frontend build failed (dashboard will not be available)"
        fi
    fi
fi

# Verify
HERMES_VERSION=$(hermes --version 2>/dev/null | head -1 || echo "unknown")
export HERMES_VERSION
echo "[run] Hermes version: $HERMES_VERSION"

# ── Section 6: Initial config scaffolding (mirrors official installer) ─
if [ ! -f "$HERMES_HOME/.env" ] && [ -f "$SRC_DIR/.env.example" ]; then
    cp -p "$SRC_DIR/.env.example" "$HERMES_HOME/.env"
    chmod 600 "$HERMES_HOME/.env"
    echo "[run] Created .env from source example (chmod 600)"
fi
if [ ! -f "$HERMES_HOME/config.yaml" ] && [ -f "$SRC_DIR/cli-config.yaml.example" ]; then
    cp -p "$SRC_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
    echo "[run] Created config.yaml from source example"
fi
if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
    cat > "$HERMES_HOME/SOUL.md" << 'SOUL_EOF'
# Hermes Agent Persona

<!--
This file defines the agent's personality and tone.
The agent will embody whatever you write here.
Edit this to customize how Hermes communicates with you.

Examples:
  - "You are a warm, playful assistant who uses kaomoji occasionally."
  - "You are a concise technical expert. No fluff, just facts."
  - "You speak like a friendly coworker who happens to know everything."

This file is loaded fresh each message -- no restart needed.
Delete the contents (or this file) to use the default personality.
-->
SOUL_EOF
    echo "[run] Created SOUL.md template"
fi

# tmux config (persistent, user-editable)
if [ ! -f /config/.tmux.conf ]; then
    cat > /config/.tmux.conf << 'TMUX'
set -g default-terminal "tmux-256color"
set -g history-limit 100000
set -g mouse on
TMUX
    echo "[run] Created default .tmux.conf"
fi

# ── Section 7: Environment variable passthrough ──────────────────────
# Source .env first (base config from hermes setup)
if [ -f "$HERMES_HOME/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$HERMES_HOME/.env"
    set +a
fi

# Write HA addon config env_vars to .env (non-empty values only)
# Hermes reads .env via dotenv (override=True), so this is the canonical path
RESERVED_VARS="HERMES_HOME|HASS_TOKEN|HASS_URL|GITHUB_TOKEN"

if [ -f "$HERMES_HOME/.env" ]; then
    ENV_COUNT=$(jq '.env_vars | length' "$OPTIONS_FILE" 2>/dev/null || echo 0)
    for i in $(seq 0 $((ENV_COUNT - 1))); do
        VAR_NAME=$(jq -r ".env_vars[$i].name" "$OPTIONS_FILE")
        VAR_VALUE=$(jq -r ".env_vars[$i].value" "$OPTIONS_FILE")
        if echo "$VAR_NAME" | grep -qE "^($RESERVED_VARS)$"; then
            echo "[run] Warning: Skipping '$VAR_NAME' (use the dedicated config option instead)"
            continue
        fi
        if [ -n "$VAR_VALUE" ]; then
            if grep -q "^${VAR_NAME}=" "$HERMES_HOME/.env"; then
                sed -i "s|^${VAR_NAME}=.*|${VAR_NAME}=${VAR_VALUE}|" "$HERMES_HOME/.env"
            else
                echo "${VAR_NAME}=${VAR_VALUE}" >> "$HERMES_HOME/.env"
            fi
            echo "[run] .env: ${VAR_NAME} set from addon config"
        fi
    done
fi

# HA integration: pass through if set
if [ -n "$HASS_TOKEN" ]; then
    export HASS_TOKEN
    echo "[run] HASS_TOKEN injected"
fi
# Git token also serves as GITHUB_TOKEN (for gh CLI + Hermes skills)
if [ -n "$GIT_TOKEN" ]; then
    export GITHUB_TOKEN="$GIT_TOKEN"
    echo "[run] GITHUB_TOKEN injected"
fi
if [ -n "$HASS_URL" ]; then
    export HASS_URL
    echo "[run] HASS_URL: $HASS_URL"
fi

# OpenAI-compatible API server on the Gateway (port 8642, host 127.0.0.1 = Hermes defaults)
if [ "$ENABLE_API" = "true" ]; then
    export API_SERVER_ENABLED=true
    echo "[run] API server enabled"
else
    export API_SERVER_ENABLED=false
    echo "[run] API server disabled"
fi
# Write API_SERVER_ENABLED to .env (Hermes dotenv override=True)
# PORT and HOST are fixed (nginx upstream hardcoded to 127.0.0.1:8642)
if [ -f "$HERMES_HOME/.env" ]; then
    if grep -q "^API_SERVER_ENABLED=" "$HERMES_HOME/.env"; then
        sed -i "s|^API_SERVER_ENABLED=.*|API_SERVER_ENABLED=${API_SERVER_ENABLED}|" "$HERMES_HOME/.env"
    else
        echo "API_SERVER_ENABLED=${API_SERVER_ENABLED}" >> "$HERMES_HOME/.env"
    fi
fi
if [ -n "$ACCESS_PASSWORD" ]; then
    export API_SERVER_KEY="$ACCESS_PASSWORD"
    # Write to .env so Hermes' dotenv loader picks it up (override=True)
    if [ -f "$HERMES_HOME/.env" ]; then
        if grep -q "^API_SERVER_KEY=" "$HERMES_HOME/.env"; then
            sed -i "s|^API_SERVER_KEY=.*|API_SERVER_KEY=${ACCESS_PASSWORD}|" "$HERMES_HOME/.env"
        else
            echo "API_SERVER_KEY=${ACCESS_PASSWORD}" >> "$HERMES_HOME/.env"
        fi
    fi
    echo "hermes:$(openssl passwd -apr1 "$ACCESS_PASSWORD")" > /etc/nginx/.htpasswd
    echo "[run] Access password set (API key + nginx basic auth)"
else
    rm -f /etc/nginx/.htpasswd
    # Clear API_SERVER_KEY in .env if password was removed
    if [ -f "$HERMES_HOME/.env" ] && grep -q "^API_SERVER_KEY=" "$HERMES_HOME/.env"; then
        sed -i "s|^API_SERVER_KEY=.*|API_SERVER_KEY=|" "$HERMES_HOME/.env"
    fi
fi

# ~/.hermes_profile: regenerated every start with all env vars (for SSH/docker-exec sessions)
cat > /config/.hermes_profile << ENVSH
export HERMES_HOME="$HERMES_HOME"
export HERMES_VERSION="$HERMES_VERSION"
$([ -n "$GIT_TOKEN" ] && echo "export GITHUB_TOKEN=\"$GIT_TOKEN\"")
export GOBIN="$GO_DIR/bin"
export GOPATH="$GO_DIR"
$([ -n "$HASS_TOKEN" ] && echo "export HASS_TOKEN=\"$HASS_TOKEN\"")
$([ -n "$HASS_URL" ] && echo "export HASS_URL=\"$HASS_URL\"")
export HOMEBREW_CELLAR="$BREW_DIR/Cellar"
export HOMEBREW_PREFIX="$BREW_DIR"
export HOMEBREW_REPOSITORY="$BREW_DIR/Homebrew"
export NPM_CONFIG_PREFIX="$NODE_DIR"
export PATH="$VENV_DIR/bin:$BREW_DIR/sbin:$BREW_DIR/bin:$GO_DIR/bin:/usr/local/go/bin:$NODE_DIR/bin:\$PATH"
ENVSH

# ── Section 8: TLS certificates ──────────────────────────────────────
if [ ! -f "$CERTS_DIR/server.crt" ]; then
    echo "[run] Generating self-signed TLS certificates..."
    # CA
    openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt" \
        -days 3650 -subj "/CN=Hermes Agent CA" 2>/dev/null
    # Server cert signed by CA
    openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$CERTS_DIR/server.key" -out /tmp/server.csr \
        -subj "/CN=hermes-agent" 2>/dev/null
    # SAN: localhost + common LAN hostnames
    LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    openssl x509 -req -in /tmp/server.csr \
        -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
        -CAcreateserial -out "$CERTS_DIR/server.crt" \
        -days 3650 -extfile <(printf "subjectAltName=DNS:hermes-agent,DNS:localhost,IP:127.0.0.1,IP:%s" "$LAN_IP") 2>/dev/null
    rm -f /tmp/server.csr "$CERTS_DIR/ca.srl"
    chmod 600 "$CERTS_DIR/server.key" "$CERTS_DIR/ca.key"
    echo "[run] TLS certificates generated (CA + server)"
    echo "[run] Install $CERTS_DIR/ca.crt on clients to avoid browser warnings"
else
    echo "[run] TLS certificates: using existing"
fi

# ── Section 9: Profile Discovery & Nginx Render ───────────────────────
# Check dashboard availability
DASHBOARD_AVAILABLE="false"
if python -c "from hermes_cli.web_server import start_server" 2>/dev/null; then
    DASHBOARD_AVAILABLE="true"
fi
echo "[run] Dashboard module: $( [ "$DASHBOARD_AVAILABLE" = "true" ] && echo "available" || echo "missing" )"

# Discover all profiles (including default)
PROFILES_DATA=$(python -c '
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
echo "[run] Discovered $PROFILES_COUNT profiles"

# Prepare dynamic nginx config snippets
PROFILE_UPSTREAMS=""
PROFILE_LOCATIONS=""

# Define auth basic vars
if [ -n "$ACCESS_PASSWORD" ]; then
    AUTH_BASIC_ON='auth_basic "Hermes Agent"; auth_basic_user_file /etc/nginx/.htpasswd;'
    AUTH_BASIC_OFF='auth_basic off;'
else
    AUTH_BASIC_ON='# no authentication'
    AUTH_BASIC_OFF=''
fi

# Generate nginx config for named profiles
# Profile index 0 is always "default"
if [ "$PROFILES_COUNT" -gt 1 ]; then
    for i in $(seq 1 $((PROFILES_COUNT - 1))); do
        P_NAME=$(echo "$PROFILES_DATA" | jq -r ".[$i].name")
        
        # Port allocation
        P_TTYD_H=$((TTYD_HERMES_PORT + i * PORT_BLOCK))
        P_TTYD_T=$((TTYD_TERMINAL_PORT + i * PORT_BLOCK))
        P_DASH=$((DASHBOARD_PORT + i * PORT_BLOCK))
        P_API=$((GATEWAY_API_PORT + i * 10))

        # Upstreams
        PROFILE_UPSTREAMS+="
upstream ttyd_hermes_${P_NAME} { server 127.0.0.1:${P_TTYD_H}; }
upstream ttyd_terminal_${P_NAME} { server 127.0.0.1:${P_TTYD_T}; }
upstream hermes_api_${P_NAME} { server 127.0.0.1:${P_API}; }
upstream hermes_dashboard_${P_NAME} { server 127.0.0.1:${P_DASH}; }
"

        # Locations
        PROFILE_LOCATIONS+="
    location = /profiles/${P_NAME}/hermes { return 302 /profiles/${P_NAME}/hermes/; }
    location /profiles/${P_NAME}/hermes/ {
        proxy_pass http://ttyd_hermes_${P_NAME}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
    }
    location = /profiles/${P_NAME}/terminal { return 302 /profiles/${P_NAME}/terminal/; }
    location /profiles/${P_NAME}/terminal/ {
        proxy_pass http://ttyd_terminal_${P_NAME}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
    }
    location /profiles/${P_NAME}/v1/ {
        proxy_pass http://hermes_api_${P_NAME}/v1/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
    }
    location = /profiles/${P_NAME}/dashboard { return 302 /profiles/${P_NAME}/dashboard/; }
    location /profiles/${P_NAME}/dashboard/api/ {
        proxy_pass http://hermes_dashboard_${P_NAME}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Authorization \"Bearer %%DASHBOARD_TOKEN_${P_NAME}%%\";
        proxy_buffering off;
    }
    location /profiles/${P_NAME}/dashboard/ {
        proxy_pass http://hermes_dashboard_${P_NAME}/;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
    }
"
    done
fi

# Render ports config
if [ "$ENABLE_DASHBOARD" = "true" ] || [ "$ENABLE_TERMINAL" = "true" ] || [ "$ENABLE_API" = "true" ]; then
    cp /etc/nginx/nginx-ports.conf.tpl /etc/nginx/ports.conf
    sed -i \
        -e "s|%%HTTP_PORT%%|${HTTP_PORT}|g" \
        -e "s|%%HTTPS_PORT%%|${HTTPS_PORT}|g" \
        -e "s|%%TTYD_TERMINAL_PORT%%|${TTYD_TERMINAL_PORT}|g" \
        -e "s|%%TTYD_HERMES_PORT%%|${TTYD_HERMES_PORT}|g" \
        -e "s|%%DASHBOARD_PORT%%|${DASHBOARD_PORT}|g" \
        -e "s|%%CERTS_DIR%%|${CERTS_DIR}|g" \
        -e "s|%%AUTH_BASIC_ON%%|${AUTH_BASIC_ON}|g" \
        -e "s|%%AUTH_BASIC_OFF%%|${AUTH_BASIC_OFF}|g" \
        /etc/nginx/ports.conf
    
    # Inject upstreams and locations into ports.conf
    [ -n "$PROFILE_UPSTREAMS" ] && sed -i "s|%%PROFILE_UPSTREAMS%%|$(echo "$PROFILE_UPSTREAMS" | sed 's/[&/|]/\\&/g')|g" /etc/nginx/ports.conf || sed -i "s|%%PROFILE_UPSTREAMS%%||g" /etc/nginx/ports.conf
    [ -n "$PROFILE_LOCATIONS" ] && sed -i "s|%%PROFILE_LOCATIONS%%|$(echo "$PROFILE_LOCATIONS" | sed 's/[&/|]/\\&/g')|g" /etc/nginx/ports.conf || sed -i "s|%%PROFILE_LOCATIONS%%||g" /etc/nginx/ports.conf

    # Strip blocks
    [ "$ENABLE_TERMINAL" != "true" ] && sed -i '/# TERMINAL_START/,/# TERMINAL_END/d' /etc/nginx/ports.conf
    [ "$ENABLE_API" != "true" ] && sed -i '/# API_START/,/# API_END/d' /etc/nginx/ports.conf
    [ "$ENABLE_DASHBOARD" != "true" ] || [ "$DASHBOARD_AVAILABLE" != "true" ] && sed -i '/# DASHBOARD_START/,/# DASHBOARD_END/d' /etc/nginx/ports.conf
    
    INCLUDE_PORTS="include /etc/nginx/ports.conf;"
else
    INCLUDE_PORTS="# direct ports disabled"
fi

# Render main nginx config
cp /etc/nginx/nginx.conf.tpl /etc/nginx/nginx.conf
sed -i \
    -e "s|%%INGRESS_PORT%%|${INGRESS_PORT}|g" \
    -e "s|%%TTYD_TERMINAL_PORT%%|${TTYD_TERMINAL_PORT}|g" \
    -e "s|%%TTYD_HERMES_PORT%%|${TTYD_HERMES_PORT}|g" \
    -e "s|%%DASHBOARD_PORT%%|${DASHBOARD_PORT}|g" \
    -e "s|%%CERTS_DIR%%|${CERTS_DIR}|g" \
    -e "s|%%HERMES_VERSION%%|${HERMES_VERSION}|g" \
    -e "s|%%INCLUDE_PORTS%%|${INCLUDE_PORTS}|g" \
    /etc/nginx/nginx.conf

# Inject profile markers into main nginx config
[ -n "$PROFILE_UPSTREAMS" ] && sed -i "s|%%PROFILE_UPSTREAMS%%|$(echo "$PROFILE_UPSTREAMS" | sed 's/[&/|]/\\&/g')|g" /etc/nginx/nginx.conf || sed -i "s|%%PROFILE_UPSTREAMS%%||g" /etc/nginx/nginx.conf
[ -n "$PROFILE_LOCATIONS" ] && sed -i "s|%%PROFILE_LOCATIONS%%|$(echo "$PROFILE_LOCATIONS" | sed 's/[&/|]/\\&/g')|g" /etc/nginx/nginx.conf || sed -i "s|%%PROFILE_LOCATIONS%%||g" /etc/nginx/nginx.conf

# Strip dashboard from ingress if module not available
if [ "$DASHBOARD_AVAILABLE" != "true" ]; then
    sed -i '/# DASHBOARD_START/,/# DASHBOARD_END/d' /etc/nginx/nginx.conf
fi

# Render landing page
ADDON_SLUG=$(hostname | tr '-' '_')
SHOW_TERMINAL="false"
if [ "$ENABLE_TERMINAL" = "true" ]; then SHOW_TERMINAL="true"; fi
SHOW_DASHBOARD="$DASHBOARD_AVAILABLE"
SHOW_DASHBOARD_PORTS="false"
if [ "$ENABLE_DASHBOARD" = "true" ] && [ "$DASHBOARD_AVAILABLE" = "true" ]; then SHOW_DASHBOARD_PORTS="true"; fi

cp /var/www/landing.html.tpl /var/www/landing.html
sed -i \
    -e "s|%%HERMES_VERSION%%|${HERMES_VERSION}|g" \
    -e "s|%%ADDON_SLUG%%|${ADDON_SLUG}|g" \
    -e "s|%%SHOW_TERMINAL%%|${SHOW_TERMINAL}|g" \
    -e "s|%%SHOW_DASHBOARD%%|${SHOW_DASHBOARD}|g" \
    -e "s|%%SHOW_DASHBOARD_PORTS%%|${SHOW_DASHBOARD_PORTS}|g" \
    -e "s|%%PROFILES_JSON%%|$(echo "$PROFILES_DATA" | jq -c '.' | sed 's/[&/|]/\\&/g')|g" \
    /var/www/landing.html

echo "[run] Nginx config rendered"

# ── Section 10: Start services ───────────────────────────────────────
declare -A GATEWAY_PIDS
declare -A TTYD_HERMES_PIDS
declare -A TTYD_TERMINAL_PIDS
declare -A DASHBOARD_PIDS

start_gateway() {
    local p_name="${1}"
    local p_home="${2}"
    local p_port="${3}"
    echo "[run] [$p_name] Starting Gateway (port: $p_port)..."
    mkdir -p "$p_home/logs"
    (HERMES_HOME="$p_home" HERMES_CONFIG_OVERRIDE_api_server__port="$p_port" hermes gateway run 2>&1 | tee -a "$p_home/logs/gateway.log") &
    local tee_pid=$!
    sleep 1.5
    local g_pid=$(pgrep -f "hermes.*gateway run" | sort -n | tail -1 || echo "$tee_pid")
    GATEWAY_PIDS["$p_name"]="$g_pid"
}

start_ttyd() {
    local p_name="${1}"
    local p_h_port="${2}"
    local p_t_port="${3}"
    local p_base="/hermes/"
    [ "$p_name" != "default" ] && p_base="/profiles/${p_name}/hermes/"
    local t_base="/terminal/"
    [ "$p_name" != "default" ] && t_base="/profiles/${p_name}/terminal/"

    echo "[run] [$p_name] Starting ttyd..."
    ttyd --port "${p_h_port}" --interface 127.0.0.1 --base-path "$p_base" --writable -d 3 \
        tmux -u new -A -s "hermes_${p_name}" /usr/local/bin/start-hermes "$([ "$p_name" != "default" ] && echo "$p_name")" &
    TTYD_HERMES_PIDS["$p_name"]=$!
    
    ttyd --port "${p_t_port}" --interface 127.0.0.1 --base-path "$t_base" --writable -d 3 \
        tmux -u new -A -s "terminal_${p_name}" /usr/bin/bash &
    TTYD_TERMINAL_PIDS["$p_name"]=$!
}

start_dashboard() {
    local p_name="${1}"
    local p_home="${2}"
    local p_port="${3}"
    if [ "$DASHBOARD_AVAILABLE" != "true" ]; then return; fi
    echo "[run] [$p_name] Starting Dashboard (port: $p_port)..."
    (cd "$p_home" && HERMES_HOME="$p_home" python -c "from hermes_cli.web_server import start_server; start_server(host='127.0.0.1', port=$p_port, open_browser=False)") &
    DASHBOARD_PIDS["$p_name"]=$!
}

inject_dashboard_token() {
    local p_name="${1}"
    local p_port="${2}"
    if [ "$DASHBOARD_AVAILABLE" != "true" ]; then return; fi
    
    echo "[run] [$p_name] Fetching dashboard token..."
    local token=""
    for i in $(seq 1 15); do
        token=$(curl -s "http://127.0.0.1:${p_port}/" 2>/dev/null | grep "__HERMES_SESSION_TOKEN__=" | sed 's/.*__HERMES_SESSION_TOKEN__="\([^"]*\)".*/\1/' || true)
        [ -n "$token" ] && break
        sleep 2
    done
    [ -z "$token" ] && echo "[run] [$p_name] Warning: token not found" && token="UNAVAILABLE"
    
    if [ "$p_name" = "default" ]; then
        sed -i "s|%%DASHBOARD_TOKEN%%|${token}|g" /etc/nginx/nginx.conf
        [ -f /etc/nginx/ports.conf ] && sed -i "s|%%DASHBOARD_TOKEN%%|${token}|g" /etc/nginx/ports.conf
    else
        sed -i "s|%%DASHBOARD_TOKEN_${p_name}%%|${token}|g" /etc/nginx/nginx.conf
        [ -f /etc/nginx/ports.conf ] && sed -i "s|%%DASHBOARD_TOKEN_${p_name}%%|${token}|g" /etc/nginx/ports.conf
    fi
}

# Register signal handler
trap shutdown SIGTERM SIGINT

# Start all profiles
echo "[run] Launching services for all profiles..."
for i in $(seq 0 $((PROFILES_COUNT - 1))); do
    NAME=$(echo "$PROFILES_DATA" | jq -r ".[$i].name")
    P_PATH=$(echo "$PROFILES_DATA" | jq -r ".[$i].path")
    
    if [ "$NAME" = "default" ]; then
        API=$GATEWAY_API_PORT; H_P=$TTYD_HERMES_PORT; T_P=$TTYD_TERMINAL_PORT; D_P=$DASHBOARD_PORT
    else
        API=$((GATEWAY_API_PORT + i * 10)); H_P=$((TTYD_HERMES_PORT + i * PORT_BLOCK)); T_P=$((TTYD_TERMINAL_PORT + i * PORT_BLOCK)); D_P=$((DASHBOARD_PORT + i * PORT_BLOCK))
    fi
    
    start_gateway "$NAME" "$P_PATH" "$API"
    start_ttyd "$NAME" "$H_P" "$T_P"
    start_dashboard "$NAME" "$P_PATH" "$D_P"
    inject_dashboard_token "$NAME" "$D_P"
done

# Final Nginx reload
echo "[run] Reloading Nginx..."
if nginx -t; then
    nginx -s reload
else
    echo "[run] FATAL: Nginx config check failed"
    exit 1
fi

echo "[run] All services started successfully"

# ── Section 11: Signal handling ──────────────────────────────────────
shutdown() {
    echo "[run] Stopping services..."
    nginx -s quit 2>/dev/null || true
    for p in "${!GATEWAY_PIDS[@]}"; do
        [ -n "${GATEWAY_PIDS[$p]}" ] && kill "${GATEWAY_PIDS[$p]}" 2>/dev/null || true
        [ -n "${TTYD_HERMES_PIDS[$p]}" ] && kill "${TTYD_HERMES_PIDS[$p]}" 2>/dev/null || true
        [ -n "${TTYD_TERMINAL_PIDS[$p]}" ] && kill "${TTYD_TERMINAL_PIDS[$p]}" 2>/dev/null || true
        [ -n "${DASHBOARD_PIDS[$p]}" ] && kill "${DASHBOARD_PIDS[$p]}" 2>/dev/null || true
    done
    echo "[run] Exiting."
    exit 0
}

# ── Section 12: Supervisor loop ──────────────────────────────────────
while true; do
    for p in "${!GATEWAY_PIDS[@]}"; do
        if ! kill -0 "${GATEWAY_PIDS[$p]}" 2>/dev/null; then
            echo "[run] [$p] Gateway crashed, restarting..."
            P_IDX=0
            for i in $(seq 0 $((PROFILES_COUNT - 1))); do
                [ "$(echo "$PROFILES_DATA" | jq -r ".[$i].name")" = "$p" ] && P_IDX=$i && break
            done
            P_PATH=$(echo "$PROFILES_DATA" | jq -r ".[$P_IDX].path")
            P_API=$((GATEWAY_API_PORT + P_IDX * 10))
            [ "$p" = "default" ] && P_API=$GATEWAY_API_PORT
            start_gateway "$p" "$P_PATH" "$P_API"
        fi
    done
    sleep 10
done


