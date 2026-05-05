import http.server
import socketserver
import subprocess
import os
import json
import time
import signal
import re
import urllib.parse

PORT = 49999
TOKEN_FILE = "/tmp/dashboard_tokens.conf"
PROFILES_DATA_FILE = "/tmp/profiles_data.json"

# State: { profile_name: { "dashboard": <popen_obj>, "ttyd_h": <popen_obj>, "ttyd_t": <popen_obj>, "token": <str> } }
services = {}
active_profile = None

def get_profiles():
    if os.path.exists(PROFILES_DATA_FILE):
        with open(PROFILES_DATA_FILE, 'r') as f:
            try:
                return json.load(f)
            except:
                return []
    return []

def update_nginx_tokens():
    with open(TOKEN_FILE, 'w') as f:
        # Default entry to prevent nginx error if empty
        f.write('"default" "UNAVAILABLE";\n')
        for name, data in services.items():
            if name != "default":
                token = data.get("token", "UNAVAILABLE")
                f.write(f'"{name}" "{token}";\n')
    # Reload nginx
    subprocess.run(["nginx", "-s", "reload"])

def kill_others(keep_profile):
    global active_profile
    if active_profile and active_profile != keep_profile:
        print(f"[manager] Switching from {active_profile} to {keep_profile}. Killing old services.")
        if active_profile in services:
            for s_type in ["dashboard", "ttyd_h", "ttyd_t"]:
                proc = services[active_profile].get(s_type)
                if proc:
                    print(f"[manager] Killing {s_type} for {active_profile}")
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except:
                        proc.kill()
                    services[active_profile][s_type] = None
    active_profile = keep_profile

def start_service(profile_name, service_type):
    profiles = get_profiles()
    profile = next((p for p in profiles if p['name'] == profile_name), None)
    if not profile:
        print(f"[manager] Profile {profile_name} not found")
        return False

    if profile_name not in services:
        services[profile_name] = {"dashboard": None, "ttyd_h": None, "ttyd_t": None, "token": "UNAVAILABLE"}

    if services[profile_name].get(service_type):
        # Check if still running
        if services[profile_name][service_type].poll() is None:
            return True
        else:
            services[profile_name][service_type] = None

    kill_others(profile_name)

    # Resolve ports and paths
    idx = 0
    for i, p in enumerate(profiles):
        if p['name'] == profile_name:
            idx = i
            break
    
    PORT_BLOCK=1000
    TTYD_HERMES_PORT=49269
    TTYD_TERMINAL_PORT=49369
    DASHBOARD_PORT=49469

    if profile_name == "default":
        h_port = TTYD_HERMES_PORT
        t_port = TTYD_TERMINAL_PORT
        d_port = DASHBOARD_PORT
    else:
        h_port = TTYD_HERMES_PORT + idx * PORT_BLOCK
        t_port = TTYD_TERMINAL_PORT + idx * PORT_BLOCK
        d_port = DASHBOARD_PORT + idx * PORT_BLOCK

    p_home = profile['path']
    env = os.environ.copy()
    env["HERMES_HOME"] = p_home

    if service_type == "dashboard":
        print(f"[manager] Starting dashboard for {profile_name} on port {d_port}")
        cmd = f"cd {p_home} && HERMES_HOME={p_home} python3 -c \"from hermes_cli.web_server import start_server; start_server(host='127.0.0.1', port={d_port}, open_browser=False)\""
        proc = subprocess.Popen(cmd, shell=True, env=env)
        services[profile_name]["dashboard"] = proc
        
        # Scrape token
        token = "UNAVAILABLE"
        for _ in range(15):
            time.sleep(2)
            try:
                res = subprocess.check_output(f"curl -s http://127.0.0.1:{d_port}/", shell=True).decode()
                match = re.search(r'__HERMES_SESSION_TOKEN__="([^"]*)"', res)
                if match:
                    token = match.group(1)
                    print(f"[manager] Found token for {profile_name}")
                    break
            except:
                continue
        services[profile_name]["token"] = token
        update_nginx_tokens()

    elif service_type == "ttyd_h":
        print(f"[manager] Starting ttyd_h for {profile_name} on port {h_port}")
        p_base = "/hermes/" if profile_name == "default" else f"/profiles/{profile_name}/hermes/"
        cmd = [
            "ttyd", "--port", str(h_port), "--interface", "127.0.0.1", "--base-path", p_base, "--writable", "-d", "3",
            "tmux", "-u", "new", "-A", "-s", f"hermes_{profile_name}", "/usr/local/bin/start-hermes"
        ]
        if profile_name != "default":
            cmd.append(profile_name)
        proc = subprocess.Popen(cmd, env=env)
        services[profile_name]["ttyd_h"] = proc

    elif service_type == "ttyd_t":
        print(f"[manager] Starting ttyd_t for {profile_name} on port {t_port}")
        t_base = "/terminal/" if profile_name == "default" else f"/profiles/{profile_name}/terminal/"
        cmd = [
            "ttyd", "--port", str(t_port), "--interface", "127.0.0.1", "--base-path", t_base, "--writable", "-d", "3",
            "tmux", "-u", "new", "-A", "-s", f"terminal_{profile_name}", "/usr/bin/bash"
        ]
        proc = subprocess.Popen(cmd, env=env)
        services[profile_name]["ttyd_t"] = proc

    return True

class ManagerHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/manage":
            params = urllib.parse.parse_qs(parsed.query)
            profile = params.get("profile", ["default"])[0]
            service = params.get("service", [""])[0]
            
            success = start_service(profile, service)
            self.send_response(200 if success else 400)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": success}).encode())
        else:
            self.send_response(404)
            self.end_headers()

def signal_handler(sig, frame):
    print("[manager] Shutting down, killing all services...")
    for name, data in services.items():
        for s_type in ["dashboard", "ttyd_h", "ttyd_t"]:
            proc = data.get(s_type)
            if proc:
                proc.terminate()
    os._exit(0)

def run_manager():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    if not os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, 'w') as f:
            f.write('"default" "UNAVAILABLE";\n')
    
    with socketserver.TCPServer(("", PORT), ManagerHandler) as httpd:
        print(f"[manager] Serving on port {PORT}")
        httpd.serve_forever()

if __name__ == "__main__":
    run_manager()
