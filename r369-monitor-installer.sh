#!/usr/bin/env bash
# =============================================================================
#  R369 System Monitor — turn-key installer
#  Target:    Ubuntu 24.04 LTS (also works on 22.04+)
#  Installs:  /opt/r369/  (app, venv, logs, systemd unit, logrotate)
#  Port:      10369 primary, falls back to 20369 if in use
#  Auth:      Local PAM users (for terminal + power actions)
#  Logs:      /opt/r369/logs   (rotating, 2 GB max, 30-day retention)
#
#  Usage:
#    sudo ./r369-monitor-installer.sh                # quiet install
#    sudo ./r369-monitor-installer.sh --verbose      # stream all step output
#    sudo ./r369-monitor-installer.sh --uninstall
# =============================================================================
set -euo pipefail

# --- config ------------------------------------------------------------------
R369_DIR="/opt/r369"
R369_LOGS="${R369_DIR}/logs"
R369_VENV="${R369_DIR}/venv"
R369_APP="${R369_DIR}/app.py"
R369_SVC="r369-monitor"
PORTS=(10369 20369)
XTERM_VERSION="5.3.0"
XTERM_FIT_VERSION="0.8.0"

# --- output helpers ----------------------------------------------------------
C_BLU=$'\033[1;34m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
C_RED=$'\033[1;31m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'
VERBOSE=0
say()  { printf "%s[r369]%s %s\n" "$C_BLU" "$C_OFF" "$*"; }
warn() { printf "%s[warn]%s %s\n" "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf "%s[fail]%s %s\n" "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# Run a labeled step. In quiet mode (default) we capture stdout+stderr and
# only show the captured output if the step fails. In --verbose mode we just
# stream everything to the terminal as it runs.
quietly() {
    local label="$1"; shift
    if (( VERBOSE )); then
        printf "%s── %s%s\n" "$C_BLU" "$label" "$C_OFF"
        if "$@"; then
            printf "  %-50s%s[ ok ]%s\n" "$label" "$C_GRN" "$C_OFF"
            return 0
        fi
        local rc=$?
        printf "  %-50s%s[fail]%s\n" "$label" "$C_RED" "$C_OFF"
        exit "$rc"
    fi
    local tmp; tmp=$(mktemp)
    printf "  %-50s" "$label"
    if "$@" >"$tmp" 2>&1; then
        printf "%s[ ok ]%s\n" "$C_GRN" "$C_OFF"
        rm -f "$tmp"
        return 0
    fi
    local rc=$?
    printf "%s[fail]%s\n" "$C_RED" "$C_OFF"
    printf "\n%s──── captured output ────────────────────────────────%s\n" "$C_YEL" "$C_OFF" >&2
    sed 's/^/    /' "$tmp" >&2
    printf "%s─────────────────────────────────────────────────────%s\n\n" "$C_YEL" "$C_OFF" >&2
    printf "%sStep failed:%s %s  (rc=%d)\n" "$C_RED" "$C_OFF" "$label" "$rc" >&2
    printf "Re-run with --verbose for full streaming output.\n" >&2
    rm -f "$tmp"
    exit "$rc"
}

# --- argument parsing --------------------------------------------------------
MODE=install
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall)  MODE=uninstall ;;
        --verbose|-v) VERBOSE=1 ;;
        -h|--help)
            cat <<H
Usage: $0 [--verbose|-v] [--uninstall]
  --verbose   stream every step's output (default: quiet, dump on error only)
  --uninstall remove the service, files, and firewall rules
H
            exit 0 ;;
        *) die "Unknown argument: $1  (try --help)" ;;
    esac
    shift
done

# --- uninstall ---------------------------------------------------------------
if [[ "$MODE" == "uninstall" ]]; then
    [[ $EUID -eq 0 ]] || die "Run as root (sudo)."
    say "Stopping and removing R369 monitor…"
    systemctl stop    "${R369_SVC}.service" 2>/dev/null || true
    systemctl disable "${R369_SVC}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${R369_SVC}.service"
    rm -f "/etc/logrotate.d/r369"
    rm -f "/etc/pam.d/r369"
    systemctl daemon-reload || true
    if command -v ufw >/dev/null 2>&1; then
        for p in "${PORTS[@]}"; do ufw delete allow "$p"/tcp 2>/dev/null || true; done
    fi
    rm -rf "${R369_DIR}"
    printf "  %s[ ok ]%s Uninstalled.\n" "$C_GRN" "$C_OFF"
    exit 0
fi

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

# =============================================================================
# Step functions — each is invoked through `quietly LABEL stepfn`. Anything
# they print is captured; on non-zero exit the captured tail is surfaced.
# =============================================================================

step_preflight() {
    if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        echo "warning: OS not detected as Ubuntu/Debian — proceeding anyway."
    fi
    command -v apt-get >/dev/null 2>&1 \
        || { echo "apt-get not found — Debian/Ubuntu required."; return 1; }
}

step_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -yqq \
        htop python3 python3-venv python3-pip python3-dev \
        libpam0g-dev build-essential logrotate \
        iproute2 procps util-linux curl ca-certificates
}

step_dirs() {
    install -d -m 0755 "${R369_DIR}"
    install -d -m 0755 "${R369_DIR}/static"
    install -d -m 0750 "${R369_LOGS}"
}

# Extract one path from a tarball to a destination, idempotent.
_extract() {                               # tarball  inside-path  dest-path
    local tar="$1" inside="$2" dest="$3"
    [[ -s "$dest" ]] && return 0
    tar -xzf "$tar" -O "$inside" > "$dest" 2>/dev/null && [[ -s "$dest" ]]
}

step_xterm() {
    local TMP rc=0
    TMP=$(mktemp -d -t r369-xterm.XXXXXX)
    {
        curl -sSLf --retry 3 --connect-timeout 10 \
            -o "$TMP/xterm.tgz" \
            "https://registry.npmjs.org/xterm/-/xterm-${XTERM_VERSION}.tgz" \
        && curl -sSLf --retry 3 --connect-timeout 10 \
            -o "$TMP/fit.tgz" \
            "https://registry.npmjs.org/xterm-addon-fit/-/xterm-addon-fit-${XTERM_FIT_VERSION}.tgz" \
        && _extract "$TMP/xterm.tgz" "package/css/xterm.css"           "${R369_DIR}/static/xterm.css" \
        && _extract "$TMP/xterm.tgz" "package/lib/xterm.js"            "${R369_DIR}/static/xterm.js" \
        && _extract "$TMP/fit.tgz"   "package/lib/xterm-addon-fit.js"  "${R369_DIR}/static/xterm-addon-fit.js" \
        && grep -q 'Terminal' "${R369_DIR}/static/xterm.js" \
        && grep -q 'FitAddon' "${R369_DIR}/static/xterm-addon-fit.js"
    } || rc=$?
    rm -rf "$TMP"
    if (( rc != 0 )); then
        echo "Failed to fetch/extract xterm assets from npm registry." >&2
        echo "Check that this host can reach https://registry.npmjs.org/" >&2
    fi
    return $rc
}

step_python() {
    [[ -d "${R369_VENV}" ]] || python3 -m venv "${R369_VENV}"
    "${R369_VENV}/bin/pip" install --quiet --disable-pip-version-check --upgrade pip wheel setuptools
    "${R369_VENV}/bin/pip" install --quiet --disable-pip-version-check \
        "aiohttp>=3.9" "psutil>=5.9" "pamela>=1.1.0"
    if ! "${R369_VENV}/bin/python" -c "import pamela; pamela.PAMError" 2>&1; then
        echo "pamela failed to import after install."
        ldconfig -p 2>/dev/null | grep -q 'libpam\.so\.0' \
            || echo "  + libpam.so.0 missing — install libpam0g."
        return 1
    fi
}

step_appfiles() {
    cat > "${R369_APP}" <<'R369_PY_EOF'
#!/usr/bin/env python3
"""
R369 System Monitor — single-file aiohttp service.
Provides:
  GET  /                    dark-themed htop-style dashboard
  GET  /api/metrics         JSON metrics snapshot
  POST /api/auth            PAM auth, returns bearer token
  POST /api/power/<action>  shutdown | reboot   (token required)
  GET  /ws/terminal         WebSocket PTY → bash login shell (token required)
"""
from __future__ import annotations

import asyncio
import fcntl
import json
import logging
import os
import pty
import pwd
import secrets
import signal
import socket
import struct
import sys
import termios
import time
from datetime import datetime, timedelta, timezone
from logging.handlers import RotatingFileHandler

import psutil
from aiohttp import WSMsgType, web

# Prefer `pamela` (pure-Python ctypes; used by JupyterHub). Fall back to
# `python-pam` only if pamela isn't present, so older installs keep working.
PAM_LIB = None
try:
    import pamela                                   # type: ignore
    PAM_LIB = "pamela"
except ImportError:
    try:
        import pam as _pam                          # type: ignore
        PAM_LIB = "python-pam"
    except ImportError:
        PAM_LIB = None

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
APP_NAME = "R369 System Monitor"
LOG_DIR = "/opt/r369/logs"
LOG_FILE = os.path.join(LOG_DIR, "r369.log")
LOG_MAX_BYTES = 2 * 1024 * 1024 * 1024  # 2 GB
LOG_BACKUPS = 30
PRIMARY_PORT = 10369
FALLBACK_PORT = 20369
STATIC_DIR = "/opt/r369/static"          # locally-cached xterm assets
SESSION_TTL = timedelta(minutes=30)

os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(STATIC_DIR, exist_ok=True)

# -----------------------------------------------------------------------------
# Logging — rotating handler keeps individual log <= 2 GB, 30 backups
# -----------------------------------------------------------------------------
fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
file_handler = RotatingFileHandler(
    LOG_FILE, maxBytes=LOG_MAX_BYTES, backupCount=LOG_BACKUPS, encoding="utf-8"
)
file_handler.setFormatter(fmt)
stream_handler = logging.StreamHandler(sys.stdout)
stream_handler.setFormatter(fmt)
logging.basicConfig(level=logging.INFO, handlers=[file_handler, stream_handler])
log = logging.getLogger("r369")

# -----------------------------------------------------------------------------
# Session store (in-memory bearer tokens)
# -----------------------------------------------------------------------------
SESSIONS: dict[str, dict] = {}   # token -> {"user": str, "expires": datetime}


def _expire_sessions() -> None:
    now = datetime.now(timezone.utc)
    for tok in [t for t, s in SESSIONS.items() if s["expires"] < now]:
        SESSIONS.pop(tok, None)


def _token_user(request: web.Request) -> str | None:
    _expire_sessions()
    tok = ""
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        tok = auth[7:]
    if not tok:
        tok = request.query.get("token", "")
    if not tok:
        tok = request.cookies.get("r369_token", "")
    sess = SESSIONS.get(tok)
    return sess["user"] if sess else None


PAM_SERVICE = "r369"   # custom PAM stack — see /etc/pam.d/r369


def _authenticate(user: str, password: str) -> tuple[bool, str]:
    """
    Returns (ok, reason). `reason` is the PAM library's textual error so we
    can log exactly why an attempt failed. We never return it to the client,
    only "Authentication failed".
    """
    if PAM_LIB is None:
        return False, "no PAM library installed (need pamela or python-pam)"
    try:
        if PAM_LIB == "pamela":
            # Raises pamela.PAMError on failure; returns None on success.
            pamela.authenticate(user, password, service=PAM_SERVICE)
            return True, ""
        # python-pam fallback
        p = _pam.pam()
        ok = bool(p.authenticate(user, password, service=PAM_SERVICE))
        if ok:
            return True, ""
        return False, f"{getattr(p, 'reason', '?')} (code={getattr(p, 'code', '?')})"
    except Exception as exc:    # pamela.PAMError lands here too
        # don't dump full traceback for a wrong password
        return False, f"{type(exc).__name__}: {exc}"


# -----------------------------------------------------------------------------
# Metrics collection (htop-equivalent)
# -----------------------------------------------------------------------------
_BOOT_TIME = psutil.boot_time()
_LAST_NET = {"t": time.time(), "tx": 0, "rx": 0}


def _collect_metrics() -> dict:
    cpu_percpu = psutil.cpu_percent(interval=None, percpu=True)
    cpu_times_pct = psutil.cpu_times_percent(interval=None, percpu=False)
    try:
        freq = psutil.cpu_freq(percpu=False)
        freq_mhz = float(freq.current) if freq else 0.0
    except Exception:
        freq_mhz = 0.0

    vmem = psutil.virtual_memory()
    swap = psutil.swap_memory()
    load1, load5, load15 = os.getloadavg()
    nproc = psutil.cpu_count(logical=True) or 1

    procs = []
    n_total = n_run = n_sleep = n_thread = 0
    for proc in psutil.process_iter(
        ["pid", "ppid", "name", "username", "status",
         "cpu_percent", "memory_percent", "memory_info",
         "nice", "num_threads", "create_time", "cmdline"]
    ):
        try:
            info = proc.info
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
        n_total += 1
        if info.get("status") == psutil.STATUS_RUNNING:
            n_run += 1
        elif info.get("status") == psutil.STATUS_SLEEPING:
            n_sleep += 1
        n_thread += info.get("num_threads") or 0
        mi = info.get("memory_info")
        rss = getattr(mi, "rss", 0) if mi else 0
        vms = getattr(mi, "vms", 0) if mi else 0
        cmd = info.get("cmdline") or []
        procs.append({
            "pid": info["pid"],
            "user": info.get("username") or "?",
            "pri": 20 + (info.get("nice") or 0),
            "ni":  info.get("nice") or 0,
            "virt": vms,
            "res":  rss,
            "s":    (info.get("status") or "?")[:1].upper(),
            "cpu":  round(info.get("cpu_percent") or 0.0, 1),
            "mem":  round(info.get("memory_percent") or 0.0, 1),
            "time": int(time.time() - (info.get("create_time") or time.time())),
            "name": info.get("name") or "?",
            "cmd":  " ".join(cmd) if cmd else (info.get("name") or ""),
        })
    procs.sort(key=lambda p: p["cpu"], reverse=True)
    procs = procs[:80]

    net = psutil.net_io_counters()
    now = time.time()
    dt = max(now - _LAST_NET["t"], 1e-3)
    tx_rate = max(net.bytes_sent - _LAST_NET["tx"], 0) / dt
    rx_rate = max(net.bytes_recv - _LAST_NET["rx"], 0) / dt
    _LAST_NET.update(t=now, tx=net.bytes_sent, rx=net.bytes_recv)

    disks = []
    for part in psutil.disk_partitions(all=False):
        if "loop" in part.device or part.fstype in ("squashfs", "tmpfs", ""):
            continue
        try:
            u = psutil.disk_usage(part.mountpoint)
            disks.append({
                "device": part.device,
                "mount":  part.mountpoint,
                "fs":     part.fstype,
                "total":  u.total,
                "used":   u.used,
                "percent": u.percent,
            })
        except PermissionError:
            continue

    try:
        users = [{"name": u.name, "host": u.host, "started": u.started}
                 for u in psutil.users()]
    except Exception:
        users = []

    return {
        "hostname": socket.gethostname(),
        "kernel": os.uname().release if hasattr(os, "uname") else "",
        "time":   now,
        "uptime": int(now - _BOOT_TIME),
        "boot_time": _BOOT_TIME,
        "load":   [load1, load5, load15],
        "cpu": {
            "count": nproc,
            "freq_mhz": freq_mhz,
            "avg": sum(cpu_percpu) / max(len(cpu_percpu), 1),
            "per_core": cpu_percpu,
            "user":   getattr(cpu_times_pct, "user", 0.0),
            "system": getattr(cpu_times_pct, "system", 0.0),
            "idle":   getattr(cpu_times_pct, "idle", 0.0),
            "iowait": getattr(cpu_times_pct, "iowait", 0.0),
        },
        "memory": {
            "total": vmem.total, "used": vmem.used,
            "available": vmem.available,
            "buffers": getattr(vmem, "buffers", 0),
            "cached":  getattr(vmem, "cached", 0),
            "percent": vmem.percent,
        },
        "swap": {
            "total": swap.total, "used": swap.used, "percent": swap.percent,
        },
        "tasks": {
            "total": n_total, "running": n_run,
            "sleeping": n_sleep, "threads": n_thread,
        },
        "network": {
            "tx_total": net.bytes_sent, "rx_total": net.bytes_recv,
            "tx_rate":  tx_rate,        "rx_rate":  rx_rate,
            "packets_sent": net.packets_sent,
            "packets_recv": net.packets_recv,
        },
        "disks":  disks,
        "users":  users,
        "processes": procs,
    }


# -----------------------------------------------------------------------------
# HTTP handlers
# -----------------------------------------------------------------------------
async def index(_request: web.Request) -> web.Response:
    return web.Response(text=INDEX_HTML, content_type="text/html")


async def metrics_handler(_request: web.Request) -> web.Response:
    loop = asyncio.get_running_loop()
    data = await loop.run_in_executor(None, _collect_metrics)
    return web.json_response(data)


async def auth_handler(request: web.Request) -> web.Response:
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "Invalid JSON"}, status=400)
    user = (body.get("username") or "").strip()
    pwd_ = body.get("password") or ""
    if not user or not pwd_:
        return web.json_response({"ok": False, "error": "Missing credentials"}, status=400)
    loop = asyncio.get_running_loop()
    ok, reason = await loop.run_in_executor(None, _authenticate, user, pwd_)
    if not ok:
        log.warning("auth failed user=%s peer=%s reason=%s",
                    user, request.remote, reason)
        return web.json_response({"ok": False, "error": "Authentication failed"}, status=401)
    token = secrets.token_urlsafe(32)
    SESSIONS[token] = {"user": user,
                       "expires": datetime.now(timezone.utc) + SESSION_TTL}
    log.info("auth ok user=%s peer=%s", user, request.remote)
    return web.json_response({"ok": True, "token": token, "user": user,
                              "expires_in": int(SESSION_TTL.total_seconds())})


async def power_handler(request: web.Request) -> web.Response:
    user = _token_user(request)
    if not user:
        return web.json_response({"ok": False, "error": "Unauthorized"}, status=401)
    action = request.match_info["action"]
    if action == "shutdown":
        cmd = ["systemctl", "poweroff"]
    elif action == "reboot":
        cmd = ["systemctl", "reboot"]
    else:
        return web.json_response({"ok": False, "error": "invalid action"}, status=400)
    log.warning("POWER %s requested by user=%s peer=%s", action, user, request.remote)

    async def _later() -> None:
        await asyncio.sleep(1.5)
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await proc.communicate()
        except Exception:
            log.exception("power action failed: %s", cmd)

    asyncio.create_task(_later())
    return web.json_response({"ok": True, "action": action,
                              "msg": f"{action} scheduled"})


# -----------------------------------------------------------------------------
# WebSocket terminal — PTY → user shell
# -----------------------------------------------------------------------------
async def terminal_ws(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse(heartbeat=30)
    await ws.prepare(request)

    user = _token_user(request)
    if not user:
        await ws.send_json({"type": "error", "msg": "Unauthorized — login first"})
        await ws.close()
        return ws

    try:
        pw_record = pwd.getpwnam(user)
    except KeyError:
        await ws.send_json({"type": "error", "msg": f"unknown user {user}"})
        await ws.close()
        return ws

    log.info("terminal open user=%s peer=%s", user, request.remote)
    pid, fd = pty.fork()
    if pid == 0:                                     # child
        try:
            os.setgid(pw_record.pw_gid)
            os.initgroups(user, pw_record.pw_gid)
            os.setuid(pw_record.pw_uid)
            os.chdir(pw_record.pw_dir)
            env = {
                "HOME":    pw_record.pw_dir,
                "USER":    user,
                "LOGNAME": user,
                "SHELL":   pw_record.pw_shell or "/bin/bash",
                "PATH":    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM":    "xterm-256color",
                "LANG":    os.environ.get("LANG", "C.UTF-8"),
            }
            shell = pw_record.pw_shell or "/bin/bash"
            os.execvpe(shell, [shell, "-l"], env)
        except Exception as exc:                     # pragma: no cover
            os.write(2, f"R369: failed to start shell: {exc}\n".encode())
            os._exit(1)

    # ------ parent ------
    loop = asyncio.get_running_loop()
    closed = asyncio.Event()

    def _read_pty() -> None:
        try:
            data = os.read(fd, 4096)
        except OSError:
            data = b""
        if not data:
            loop.remove_reader(fd)
            closed.set()
            return
        asyncio.create_task(
            ws.send_str(json.dumps({"type": "data",
                                    "data": data.decode("utf-8", "replace")}))
        )

    loop.add_reader(fd, _read_pty)
    await ws.send_json({"type": "ready", "user": user})

    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    payload = json.loads(msg.data)
                except json.JSONDecodeError:
                    continue
                t = payload.get("type")
                if t == "data":
                    os.write(fd, payload.get("data", "").encode())
                elif t == "resize":
                    cols = int(payload.get("cols") or 80)
                    rows = int(payload.get("rows") or 24)
                    fcntl.ioctl(fd, termios.TIOCSWINSZ,
                                struct.pack("HHHH", rows, cols, 0, 0))
            elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR):
                break
    finally:
        try:
            loop.remove_reader(fd)
        except Exception:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.kill(pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            pass
        log.info("terminal closed user=%s", user)
    return ws


# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
def _pick_port() -> int:
    for p in (PRIMARY_PORT, FALLBACK_PORT):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", p))
            s.close()
            return p
        except OSError:
            log.warning("port %s busy, trying next", p)
            continue
        finally:
            try:
                s.close()
            except Exception:
                pass
    raise RuntimeError("No available port among %s" % (PRIMARY_PORT, FALLBACK_PORT))


def build_app() -> web.Application:
    app = web.Application(client_max_size=4 * 1024 * 1024)
    app.router.add_get("/",            index)
    app.router.add_get("/api/metrics", metrics_handler)
    app.router.add_post("/api/auth",   auth_handler)
    app.router.add_post("/api/power/{action}", power_handler)
    app.router.add_get("/ws/terminal", terminal_ws)
    # Locally-cached xterm.js assets — avoids cdnjs dependency at runtime
    app.router.add_static("/static/", path=STATIC_DIR, show_index=False,
                          append_version=False)
    return app


def main() -> None:
    port = _pick_port()
    # prime the per-cpu sample so the first read returns sane values
    psutil.cpu_percent(interval=None, percpu=True)
    log.info("%s starting on 0.0.0.0:%s (PAM lib: %s, service: %s)",
             APP_NAME, port, PAM_LIB or "NONE", PAM_SERVICE)
    if PAM_LIB is None:
        log.error("No PAM library importable — terminal and power actions will reject all auth.")
    print(f"R369 Monitor listening on http://0.0.0.0:{port}  [PAM: {PAM_LIB or 'NONE'}]",
          flush=True)
    web.run_app(build_app(),
                host="0.0.0.0", port=port,
                access_log=log, print=lambda *_a, **_kw: None)


# =============================================================================
# Embedded UI — single HTML/CSS/JS document, no external assets except CDN xterm
# =============================================================================
INDEX_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>R369 · System Monitor</title>
<link rel="stylesheet" href="/static/xterm.css">
<style>
:root {
  --bg-0: #05060d;
  --bg-1: #0b0e1a;
  --bg-2: #131829;
  --bg-3: #1c2238;
  --line: #232b48;
  --text: #d8e1ff;
  --muted: #7c87b3;
  --cyan: #4cf2ff;
  --magenta: #ff5cd6;
  --violet: #a880ff;
  --green: #5dffae;
  --yellow: #ffd166;
  --red: #ff5d6c;
  --grad: linear-gradient(135deg, #4cf2ff 0%, #a880ff 50%, #ff5cd6 100%);
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; height: 100%; background: var(--bg-0); color: var(--text);
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            font-size: 13px; line-height: 1.45; overflow: hidden; }
body::before {
  content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 0;
  background:
    radial-gradient(ellipse 80% 50% at 20% 0%, rgba(168,128,255,0.18), transparent 60%),
    radial-gradient(ellipse 60% 40% at 100% 100%, rgba(76,242,255,0.12), transparent 60%),
    linear-gradient(180deg, #07080f 0%, #05060d 100%);
}
body::after {
  content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 0; opacity: 0.04;
  background-image:
    linear-gradient(rgba(255,255,255,0.6) 1px, transparent 1px),
    linear-gradient(90deg, rgba(255,255,255,0.6) 1px, transparent 1px);
  background-size: 40px 40px;
}

#app { position: relative; z-index: 1; height: 100vh; display: flex; flex-direction: column; }

header {
  display: flex; align-items: center; gap: 18px; padding: 12px 22px;
  border-bottom: 1px solid var(--line);
  background: linear-gradient(180deg, rgba(19,24,41,0.85), rgba(11,14,26,0.85));
  backdrop-filter: blur(8px);
}
.logo {
  font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace;
  font-weight: 800; font-size: 18px; letter-spacing: 1px;
  background: var(--grad); -webkit-background-clip: text; background-clip: text;
  -webkit-text-fill-color: transparent;
  filter: drop-shadow(0 0 10px rgba(168,128,255,0.35));
}
header h1 { margin: 0; font-size: 14px; font-weight: 500; color: var(--muted); letter-spacing: 1px; text-transform: uppercase; }
.host-info { margin-left: auto; display: flex; align-items: center; gap: 18px; color: var(--muted); font-size: 12px; }
.host-info b { color: var(--text); font-weight: 600; }
.dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
       background: var(--green); box-shadow: 0 0 8px var(--green); margin-right: 6px;
       animation: pulse 2s ease-in-out infinite; }
@keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: 0.4 } }

select, button, input { font-family: inherit; }
.refresh {
  display: flex; align-items: center; gap: 8px;
  background: var(--bg-2); border: 1px solid var(--line); padding: 6px 10px; border-radius: 8px;
}
.refresh select {
  background: transparent; color: var(--text); border: none; outline: none;
  font-size: 12px; font-weight: 600; cursor: pointer;
}
.refresh select option { background: var(--bg-2); }

main {
  flex: 1; overflow: auto; padding: 18px 22px;
  display: grid; gap: 18px;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  grid-template-areas:
    "cpu  mem"
    "load net"
    "proc proc"
    "disk power";
}
@media (max-width: 1100px) {
  main { grid-template-columns: 1fr; grid-template-areas: "cpu" "mem" "load" "net" "disk" "proc" "power"; }
}

.card {
  position: relative; padding: 16px 18px;
  background: linear-gradient(180deg, rgba(28,34,56,0.65), rgba(19,24,41,0.65));
  border: 1px solid var(--line); border-radius: 14px;
  box-shadow: 0 1px 0 rgba(255,255,255,0.04) inset, 0 10px 30px rgba(0,0,0,0.35);
  overflow: hidden;
}
.card::before {
  content: ""; position: absolute; inset: 0; padding: 1px; border-radius: 14px;
  background: var(--grad); -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  -webkit-mask-composite: xor; mask-composite: exclude; opacity: 0.18; pointer-events: none;
}
.card h2 {
  margin: 0 0 12px; font-size: 11px; letter-spacing: 2px; text-transform: uppercase;
  color: var(--muted); font-weight: 600;
  display: flex; align-items: center; gap: 8px;
}
.card h2 .swatch { width: 8px; height: 8px; border-radius: 50%; background: var(--cyan); box-shadow: 0 0 8px var(--cyan); }

.cpu  { grid-area: cpu; }
.mem  { grid-area: mem; }
.load { grid-area: load; }
.net  { grid-area: net; }
.proc { grid-area: proc; }
.disk { grid-area: disk; }
.power { grid-area: power; }

.cpu-stats { display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 12px; color: var(--muted); font-size: 12px; }
.cpu-stats b { color: var(--text); font-variant-numeric: tabular-nums; }
.cpu-grid { display: grid; gap: 6px; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); }
.core {
  display: grid; grid-template-columns: 30px 1fr 44px; align-items: center; gap: 8px;
  font-family: 'JetBrains Mono', ui-monospace, monospace; font-size: 11px;
}
.core-label { color: var(--muted); }
.core-bar { height: 8px; background: var(--bg-3); border-radius: 4px; overflow: hidden; position: relative; }
.core-bar > span {
  display: block; height: 100%; width: 0%;
  background: linear-gradient(90deg, #4cf2ff, #a880ff 70%, #ff5cd6);
  box-shadow: 0 0 10px rgba(168,128,255,0.5);
  transition: width .45s ease;
}
.core-pct { text-align: right; color: var(--text); font-variant-numeric: tabular-nums; }

.bar-row { margin: 10px 0; }
.bar-row label { display: flex; justify-content: space-between; font-size: 11px; color: var(--muted); margin-bottom: 4px; font-family: 'JetBrains Mono', monospace; }
.bar-row label b { color: var(--text); font-weight: 600; }
.bar { height: 14px; background: var(--bg-3); border-radius: 6px; position: relative; overflow: hidden; border: 1px solid rgba(255,255,255,0.04); }
.bar > span { display: block; height: 100%; transition: width .5s ease; }
.bar-mem  > .seg-used  { background: linear-gradient(90deg, #4cf2ff, #a880ff); }
.bar-mem  > .seg-buff  { background: rgba(255,209,102,0.45); }
.bar-mem  > .seg-cache { background: rgba(93,255,174,0.35); }
.bar-swap > span       { background: linear-gradient(90deg, #ff5cd6, #ff5d6c); }
.bar-multi { display: flex; }
.bar-multi > span { display: block; height: 100%; transition: width .5s ease; }

.load-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 12px; }
.load-cell { background: var(--bg-2); border: 1px solid var(--line); border-radius: 10px; padding: 12px; text-align: center; }
.load-cell small { display: block; color: var(--muted); font-size: 10px; text-transform: uppercase; letter-spacing: 1px; }
.load-cell b { display: block; font-size: 22px; margin-top: 4px; font-family: 'JetBrains Mono', monospace; color: var(--cyan); text-shadow: 0 0 12px rgba(76,242,255,0.4); }
.tasks-line { font-size: 12px; color: var(--muted); display: flex; gap: 14px; flex-wrap: wrap; }
.tasks-line span b { color: var(--text); }

.net-stats { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 8px; font-size: 12px; }
.net-stat { background: var(--bg-2); border: 1px solid var(--line); border-radius: 10px; padding: 10px; }
.net-stat small { color: var(--muted); text-transform: uppercase; font-size: 10px; letter-spacing: 1px; }
.net-stat b { display: block; font-size: 16px; margin-top: 2px; font-family: 'JetBrains Mono', monospace; }
.net-stat.tx b { color: var(--magenta); }
.net-stat.rx b { color: var(--cyan); }
#net-chart { width: 100%; height: 100px; display: block; }

.disk-list { display: flex; flex-direction: column; gap: 10px; }
.disk-row { display: grid; grid-template-columns: 1fr auto; gap: 6px; }
.disk-row .meta { font-size: 11px; color: var(--muted); font-family: 'JetBrains Mono', monospace; }
.disk-row .meta b { color: var(--text); }
.disk-row .pct { color: var(--text); font-variant-numeric: tabular-nums; font-family: 'JetBrains Mono', monospace; font-size: 11px; }

.proc-tools { display: flex; gap: 10px; align-items: center; margin-bottom: 8px; }
.proc-tools input {
  flex: 1; background: var(--bg-2); border: 1px solid var(--line); border-radius: 8px;
  color: var(--text); padding: 6px 10px; font-size: 12px; outline: none;
}
.proc-tools input:focus { border-color: var(--cyan); box-shadow: 0 0 0 2px rgba(76,242,255,0.15); }
.proc-wrap { max-height: 360px; overflow: auto; border: 1px solid var(--line); border-radius: 10px; }
.proc-wrap::-webkit-scrollbar { width: 8px; height: 8px; }
.proc-wrap::-webkit-scrollbar-thumb { background: var(--bg-3); border-radius: 4px; }
table.procs { width: 100%; border-collapse: collapse; font-family: 'JetBrains Mono', monospace; font-size: 11.5px; }
table.procs th { position: sticky; top: 0; background: var(--bg-2); color: var(--muted);
                 text-align: left; padding: 8px 10px; font-weight: 600; font-size: 10.5px;
                 letter-spacing: 1px; border-bottom: 1px solid var(--line); cursor: pointer; user-select: none; }
table.procs th:hover { color: var(--cyan); }
table.procs th .arrow { font-size: 9px; opacity: 0.6; }
table.procs td { padding: 5px 10px; border-bottom: 1px solid rgba(35,43,72,0.5); white-space: nowrap; }
table.procs tr:hover td { background: rgba(76,242,255,0.04); }
table.procs td.right { text-align: right; }
.cpu-hot { color: var(--magenta); }
.cpu-warm { color: var(--yellow); }
.cpu-cool { color: var(--green); }

.power-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px; }
.btn {
  padding: 12px 14px; border-radius: 10px; border: 1px solid var(--line);
  background: var(--bg-2); color: var(--text); font-weight: 600; cursor: pointer;
  font-size: 12px; letter-spacing: 1px; text-transform: uppercase;
  transition: transform .12s ease, box-shadow .25s ease, border-color .25s ease;
  display: flex; align-items: center; justify-content: center; gap: 8px;
}
.btn:hover  { transform: translateY(-1px); }
.btn-cyan   { border-color: rgba(76,242,255,0.4); color: var(--cyan); }
.btn-cyan:hover { box-shadow: 0 0 24px rgba(76,242,255,0.25); border-color: var(--cyan); }
.btn-warn   { border-color: rgba(255,209,102,0.4); color: var(--yellow); }
.btn-warn:hover { box-shadow: 0 0 24px rgba(255,209,102,0.25); border-color: var(--yellow); }
.btn-danger { border-color: rgba(255,93,108,0.4); color: var(--red); }
.btn-danger:hover { box-shadow: 0 0 24px rgba(255,93,108,0.3); border-color: var(--red); }
.btn-primary{ background: var(--grad); color: #06091a; border: none; font-weight: 700; }
.btn-primary:hover { box-shadow: 0 0 24px rgba(168,128,255,0.4); }

.terminal-fab {
  position: fixed; right: 22px; bottom: 22px; z-index: 30;
  padding: 14px 18px; border-radius: 999px; border: none;
  background: var(--grad); color: #06091a; font-weight: 700; cursor: pointer;
  letter-spacing: 1px; text-transform: uppercase; font-size: 12px;
  box-shadow: 0 10px 40px rgba(168,128,255,0.45);
  display: flex; align-items: center; gap: 8px;
}

/* Floating terminal window */
.term-window {
  position: fixed; left: 80px; top: 80px; width: 760px; height: 460px;
  background: rgba(5,6,13,0.95); border: 1px solid var(--line);
  border-radius: 12px; box-shadow: 0 30px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(76,242,255,0.15);
  display: none; flex-direction: column; overflow: hidden; z-index: 50; backdrop-filter: blur(8px);
  min-width: 380px; min-height: 220px;
}
.term-window.show { display: flex; }
.term-header {
  display: flex; align-items: center; gap: 10px; padding: 8px 12px;
  background: linear-gradient(180deg, rgba(28,34,56,0.95), rgba(19,24,41,0.95));
  border-bottom: 1px solid var(--line); cursor: move; user-select: none;
}
.term-dots { display: flex; gap: 6px; }
.term-dots span { width: 11px; height: 11px; border-radius: 50%; }
.term-dots span:nth-child(1) { background: #ff5d6c; }
.term-dots span:nth-child(2) { background: #ffd166; }
.term-dots span:nth-child(3) { background: #5dffae; }
.term-title {
  font-family: 'JetBrains Mono', monospace; font-size: 11px; color: var(--muted);
  flex: 1; text-align: center; letter-spacing: 1px;
}
.term-title b { color: var(--cyan); }
.term-controls button {
  background: transparent; border: 1px solid var(--line); color: var(--muted);
  border-radius: 6px; padding: 2px 8px; cursor: pointer; font-size: 12px;
}
.term-controls button:hover { color: var(--text); border-color: var(--cyan); }
.term-body { flex: 1; padding: 8px; min-height: 0; min-width: 0; overflow: hidden; }
.term-body #term { width: 100%; height: 100%; }
.term-body .xterm { width: 100%; height: 100%; }
.term-body .xterm-viewport { width: 100% !important; }
.term-resize {
  position: absolute; right: 0; bottom: 0; width: 16px; height: 16px;
  cursor: nwse-resize; background:
    linear-gradient(135deg, transparent 50%, var(--muted) 50% 56%, transparent 56% 70%, var(--muted) 70% 76%, transparent 76%);
}

/* Modal */
.modal {
  position: fixed; inset: 0; background: rgba(0,0,0,0.65); backdrop-filter: blur(6px);
  z-index: 100; display: none; align-items: center; justify-content: center;
}
.modal.show { display: flex; }
.modal-box {
  width: 380px; padding: 22px; border-radius: 14px;
  background: linear-gradient(180deg, rgba(28,34,56,0.98), rgba(19,24,41,0.98));
  border: 1px solid var(--line); box-shadow: 0 30px 80px rgba(0,0,0,0.7);
}
.modal-box h3 {
  margin: 0 0 14px; font-size: 14px; letter-spacing: 2px; text-transform: uppercase; color: var(--muted);
  display: flex; align-items: center; gap: 8px;
}
.modal-box h3 .swatch { width: 10px; height: 10px; border-radius: 50%; background: var(--cyan); box-shadow: 0 0 10px var(--cyan); }
.modal-box label { display: block; font-size: 11px; color: var(--muted); margin: 10px 0 4px; }
.modal-box input {
  width: 100%; padding: 10px 12px; background: var(--bg-1); border: 1px solid var(--line);
  border-radius: 8px; color: var(--text); font-size: 13px; outline: none;
}
.modal-box input:focus { border-color: var(--cyan); box-shadow: 0 0 0 2px rgba(76,242,255,0.15); }
.modal-actions { display: flex; gap: 10px; margin-top: 16px; justify-content: flex-end; }
.modal-error { color: var(--red); font-size: 12px; margin-top: 8px; min-height: 14px; }
.modal-info  { color: var(--muted); font-size: 12px; margin-top: 8px; }

/* Toast */
.toast-wrap { position: fixed; right: 22px; bottom: 90px; display: flex; flex-direction: column; gap: 8px; z-index: 200; }
.toast {
  background: rgba(28,34,56,0.95); border: 1px solid var(--line);
  border-left: 3px solid var(--cyan);
  padding: 10px 14px; border-radius: 8px; font-size: 12px;
  box-shadow: 0 10px 30px rgba(0,0,0,0.4); max-width: 320px;
  animation: slidein .25s ease;
}
.toast.warn  { border-left-color: var(--yellow); }
.toast.error { border-left-color: var(--red); }
.toast.ok    { border-left-color: var(--green); }
@keyframes slidein { from { transform: translateY(8px); opacity: 0 } to { transform: none; opacity: 1 } }

/* scrollbar */
main::-webkit-scrollbar { width: 10px; }
main::-webkit-scrollbar-thumb { background: var(--bg-3); border-radius: 5px; }
</style>
</head>
<body>
<div id="app">
  <header>
    <div class="logo">R369</div>
    <h1>· System Monitor</h1>
    <div class="host-info">
      <span><span class="dot"></span><b id="hostname">—</b></span>
      <span>kernel <b id="kernel">—</b></span>
      <span>up <b id="uptime">—</b></span>
      <span>local <b id="localtime">—</b></span>
      <div class="refresh">
        <span style="color:var(--muted);font-size:11px;letter-spacing:1px;">REFRESH</span>
        <select id="refresh-rate">
          <option value="5000">5s</option>
          <option value="10000" selected>10s</option>
          <option value="15000">15s</option>
          <option value="30000">30s</option>
          <option value="60000">60s</option>
          <option value="0">off</option>
        </select>
        <button id="refresh-now" title="Refresh once"
                style="background:transparent;border:1px solid var(--line);color:var(--muted);
                       border-radius:6px;padding:2px 8px;cursor:pointer;font-size:11px;">⟳</button>
      </div>
    </div>
  </header>

  <main>
    <section class="card cpu">
      <h2><span class="swatch"></span>CPU · <span id="cpu-meta" style="color:var(--text);text-transform:none;letter-spacing:0;">—</span></h2>
      <div class="cpu-stats">
        <span>avg <b id="cpu-avg">0%</b></span>
        <span>user <b id="cpu-user">0%</b></span>
        <span>sys <b id="cpu-sys">0%</b></span>
        <span>iowait <b id="cpu-io">0%</b></span>
        <span>idle <b id="cpu-idle">0%</b></span>
      </div>
      <div class="cpu-grid" id="cpu-grid"></div>
    </section>

    <section class="card mem">
      <h2><span class="swatch" style="background:var(--magenta);box-shadow:0 0 8px var(--magenta)"></span>Memory</h2>
      <div class="bar-row">
        <label><span>RAM</span><span><b id="mem-used">0</b> / <b id="mem-total">0</b> · <b id="mem-pct">0%</b></span></label>
        <div class="bar bar-multi" id="mem-bar">
          <span class="seg-used"  style="width:0%; background:linear-gradient(90deg,#4cf2ff,#a880ff)"></span>
          <span class="seg-buff"  style="width:0%; background:rgba(255,209,102,0.45)"></span>
          <span class="seg-cache" style="width:0%; background:rgba(93,255,174,0.35)"></span>
        </div>
      </div>
      <div class="bar-row">
        <label><span>SWAP</span><span><b id="swap-used">0</b> / <b id="swap-total">0</b> · <b id="swap-pct">0%</b></span></label>
        <div class="bar bar-swap"><span id="swap-bar" style="width:0%"></span></div>
      </div>
      <div style="display:flex;gap:14px;margin-top:10px;font-size:11px;color:var(--muted);font-family:'JetBrains Mono',monospace;">
        <span>used <b style="color:var(--text)" id="mem-used-2">0</b></span>
        <span>buff <b style="color:var(--yellow)" id="mem-buff">0</b></span>
        <span>cache <b style="color:var(--green)" id="mem-cache">0</b></span>
        <span>avail <b style="color:var(--cyan)" id="mem-avail">0</b></span>
      </div>
    </section>

    <section class="card load">
      <h2><span class="swatch" style="background:var(--violet);box-shadow:0 0 8px var(--violet)"></span>Load · Tasks</h2>
      <div class="load-grid">
        <div class="load-cell"><small>1 min</small><b id="load1">0.00</b></div>
        <div class="load-cell"><small>5 min</small><b id="load5">0.00</b></div>
        <div class="load-cell"><small>15 min</small><b id="load15">0.00</b></div>
      </div>
      <div class="tasks-line">
        <span>tasks <b id="t-total">0</b></span>
        <span>running <b id="t-run">0</b></span>
        <span>sleeping <b id="t-sleep">0</b></span>
        <span>threads <b id="t-thr">0</b></span>
        <span>users <b id="t-users">0</b></span>
      </div>
    </section>

    <section class="card net">
      <h2><span class="swatch" style="background:var(--green);box-shadow:0 0 8px var(--green)"></span>Network</h2>
      <div class="net-stats">
        <div class="net-stat rx"><small>↓ rx</small><b id="net-rx">0 B/s</b></div>
        <div class="net-stat tx"><small>↑ tx</small><b id="net-tx">0 B/s</b></div>
      </div>
      <canvas id="net-chart" width="600" height="100"></canvas>
      <div style="font-size:11px;color:var(--muted);margin-top:6px;font-family:'JetBrains Mono',monospace;">
        total rx <b style="color:var(--cyan)" id="net-rx-tot">0</b> · total tx <b style="color:var(--magenta)" id="net-tx-tot">0</b>
      </div>
    </section>

    <section class="card disk">
      <h2><span class="swatch" style="background:var(--yellow);box-shadow:0 0 8px var(--yellow)"></span>Disks</h2>
      <div class="disk-list" id="disk-list"></div>
    </section>

    <section class="card power">
      <h2><span class="swatch" style="background:var(--red);box-shadow:0 0 8px var(--red)"></span>System Control</h2>
      <p style="color:var(--muted);margin:0 0 12px;font-size:12px;">Authenticated PAM users only. Actions execute after a 1.5 s grace period.</p>
      <div class="power-grid">
        <button class="btn btn-cyan"   id="btn-login">Login (PAM)</button>
        <button class="btn btn-warn"   id="btn-reboot">⟳ Reboot</button>
        <button class="btn btn-danger" id="btn-shutdown">⏻ Shutdown</button>
      </div>
      <p id="auth-status" style="color:var(--muted);font-size:11px;margin-top:10px;">not logged in</p>
    </section>

    <section class="card proc" style="grid-column: 1/-1;">
      <h2><span class="swatch" style="background:var(--cyan);box-shadow:0 0 8px var(--cyan)"></span>Processes</h2>
      <div class="proc-tools">
        <input id="proc-filter" placeholder="filter by name, user, or command…" />
        <span style="color:var(--muted);font-size:11px;">showing top 80 by CPU</span>
      </div>
      <div class="proc-wrap">
        <table class="procs">
          <thead>
            <tr>
              <th data-sort="pid">PID<span class="arrow"></span></th>
              <th data-sort="user">USER</th>
              <th data-sort="pri" class="right">PRI</th>
              <th data-sort="ni" class="right">NI</th>
              <th data-sort="virt" class="right">VIRT</th>
              <th data-sort="res" class="right">RES</th>
              <th data-sort="s">S</th>
              <th data-sort="cpu" class="right">CPU%<span class="arrow">▼</span></th>
              <th data-sort="mem" class="right">MEM%</th>
              <th data-sort="time" class="right">TIME+</th>
              <th data-sort="cmd">COMMAND</th>
            </tr>
          </thead>
          <tbody id="proc-tbody"></tbody>
        </table>
      </div>
    </section>
  </main>

  <button class="terminal-fab" id="btn-terminal">▶ Terminal</button>

  <!-- Floating terminal window -->
  <div class="term-window" id="termwin">
    <div class="term-header" id="term-header">
      <div class="term-dots"><span></span><span></span><span></span></div>
      <div class="term-title">r369 · shell · <b id="term-user">guest</b>@<span id="term-host">host</span></div>
      <div class="term-controls">
        <button id="term-close" title="close">×</button>
      </div>
    </div>
    <div class="term-body"><div id="term"></div></div>
    <div class="term-resize" id="term-resize"></div>
  </div>

  <!-- Login modal -->
  <div class="modal" id="login-modal">
    <div class="modal-box">
      <h3><span class="swatch"></span>PAM Authentication</h3>
      <p class="modal-info">Local user credentials are required before opening the terminal or invoking power actions.</p>
      <label>Username</label>
      <input type="text" id="lm-user" autocomplete="username">
      <label>Password</label>
      <input type="password" id="lm-pass" autocomplete="current-password">
      <div class="modal-error" id="lm-error"></div>
      <div class="modal-actions">
        <button class="btn"            id="lm-cancel">Cancel</button>
        <button class="btn btn-primary" id="lm-ok">Authenticate</button>
      </div>
    </div>
  </div>

  <!-- Confirm modal -->
  <div class="modal" id="confirm-modal">
    <div class="modal-box">
      <h3><span class="swatch" style="background:var(--red);box-shadow:0 0 10px var(--red)"></span><span id="cm-title">Confirm</span></h3>
      <p class="modal-info" id="cm-msg">Are you sure?</p>
      <div class="modal-actions">
        <button class="btn"            id="cm-cancel">Cancel</button>
        <button class="btn btn-danger" id="cm-ok">Confirm</button>
      </div>
    </div>
  </div>

  <div class="toast-wrap" id="toasts"></div>
</div>

<script src="/static/xterm.js"></script>
<script src="/static/xterm-addon-fit.js"></script>
<script>
(() => {
  // ------------------------------ helpers
  const $ = (id) => document.getElementById(id);
  const fmtBytes = (n) => {
    if (n === null || n === undefined || isNaN(n)) return "0 B";
    const u = ["B","KiB","MiB","GiB","TiB","PiB"]; let i = 0; n = Number(n);
    while (n >= 1024 && i < u.length-1) { n /= 1024; i++; }
    return n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2) + " " + u[i];
  };
  const fmtRate = (n) => fmtBytes(n) + "/s";
  const fmtUptime = (s) => {
    s = Math.max(0, Math.floor(s));
    const d = Math.floor(s/86400), h = Math.floor((s%86400)/3600);
    const m = Math.floor((s%3600)/60), ss = s%60;
    return (d?d+"d ":"") + String(h).padStart(2,"0") + ":" + String(m).padStart(2,"0") + ":" + String(ss).padStart(2,"0");
  };
  const fmtTimeProc = (s) => {
    const m = Math.floor(s/60), sec = s%60;
    return String(m).padStart(2,"0") + ":" + String(sec).padStart(2,"0");
  };

  // ------------------------------ session
  let token = null, username = null;
  const setAuth = (t, u) => {
    token = t; username = u;
    $("auth-status").textContent = t ? `authenticated as ${u}` : "not logged in";
    $("auth-status").style.color = t ? "var(--green)" : "var(--muted)";
    $("term-user").textContent = u || "guest";
  };

  // ------------------------------ toasts
  const toast = (msg, kind = "ok", ttl = 3500) => {
    const el = document.createElement("div");
    el.className = "toast " + kind;
    el.textContent = msg;
    $("toasts").appendChild(el);
    setTimeout(() => el.remove(), ttl);
  };

  // ------------------------------ metrics
  let intervalId = null, currentInterval = 10000;
  let netHistory = [];
  const NET_HISTORY = 60;

  async function poll() {
    try {
      const r = await fetch("/api/metrics", { cache: "no-store" });
      if (!r.ok) throw new Error("metrics " + r.status);
      const m = await r.json();
      render(m);
    } catch (e) {
      console.warn("metrics error", e);
    }
  }

  function render(m) {
    $("hostname").textContent  = m.hostname || "—";
    $("kernel").textContent    = m.kernel   || "—";
    $("uptime").textContent    = fmtUptime(m.uptime);
    $("localtime").textContent = new Date(m.time*1000).toLocaleTimeString();

    // CPU
    $("cpu-meta").textContent =
      `${m.cpu.count} cores · ${m.cpu.freq_mhz ? m.cpu.freq_mhz.toFixed(0)+" MHz" : "freq n/a"}`;
    $("cpu-avg").textContent  = m.cpu.avg.toFixed(1) + "%";
    $("cpu-user").textContent = m.cpu.user.toFixed(1) + "%";
    $("cpu-sys").textContent  = m.cpu.system.toFixed(1) + "%";
    $("cpu-io").textContent   = m.cpu.iowait.toFixed(1) + "%";
    $("cpu-idle").textContent = m.cpu.idle.toFixed(1) + "%";

    const grid = $("cpu-grid");
    if (grid.children.length !== m.cpu.per_core.length) {
      grid.innerHTML = "";
      m.cpu.per_core.forEach((_,i) => {
        const row = document.createElement("div");
        row.className = "core";
        row.innerHTML =
          `<div class="core-label">CPU${i}</div>` +
          `<div class="core-bar"><span></span></div>` +
          `<div class="core-pct">0.0%</div>`;
        grid.appendChild(row);
      });
    }
    [...grid.children].forEach((row,i) => {
      const v = m.cpu.per_core[i] || 0;
      row.querySelector("span").style.width = v.toFixed(1) + "%";
      row.querySelector(".core-pct").textContent = v.toFixed(1) + "%";
    });

    // Memory
    const usedAlone = Math.max(0, m.memory.used - (m.memory.buffers||0) - (m.memory.cached||0));
    const total = m.memory.total || 1;
    const pUsed  = (usedAlone / total) * 100;
    const pBuff  = ((m.memory.buffers||0) / total) * 100;
    const pCache = ((m.memory.cached ||0) / total) * 100;
    const segs = $("mem-bar").children;
    segs[0].style.width = pUsed.toFixed(2)  + "%";
    segs[1].style.width = pBuff.toFixed(2)  + "%";
    segs[2].style.width = pCache.toFixed(2) + "%";

    $("mem-used").textContent  = fmtBytes(m.memory.used);
    $("mem-total").textContent = fmtBytes(m.memory.total);
    $("mem-pct").textContent   = m.memory.percent.toFixed(1) + "%";
    $("mem-used-2").textContent = fmtBytes(usedAlone);
    $("mem-buff").textContent   = fmtBytes(m.memory.buffers||0);
    $("mem-cache").textContent  = fmtBytes(m.memory.cached||0);
    $("mem-avail").textContent  = fmtBytes(m.memory.available||0);

    $("swap-bar").style.width  = m.swap.percent.toFixed(2) + "%";
    $("swap-used").textContent = fmtBytes(m.swap.used);
    $("swap-total").textContent= fmtBytes(m.swap.total);
    $("swap-pct").textContent  = m.swap.percent.toFixed(1) + "%";

    // Load + tasks
    $("load1").textContent  = m.load[0].toFixed(2);
    $("load5").textContent  = m.load[1].toFixed(2);
    $("load15").textContent = m.load[2].toFixed(2);
    $("t-total").textContent = m.tasks.total;
    $("t-run").textContent   = m.tasks.running;
    $("t-sleep").textContent = m.tasks.sleeping;
    $("t-thr").textContent   = m.tasks.threads;
    $("t-users").textContent = (m.users||[]).length;

    // Network
    $("net-rx").textContent     = fmtRate(m.network.rx_rate);
    $("net-tx").textContent     = fmtRate(m.network.tx_rate);
    $("net-rx-tot").textContent = fmtBytes(m.network.rx_total);
    $("net-tx-tot").textContent = fmtBytes(m.network.tx_total);
    netHistory.push({ rx: m.network.rx_rate, tx: m.network.tx_rate });
    if (netHistory.length > NET_HISTORY) netHistory.shift();
    drawNet();

    // Disks
    const dl = $("disk-list");
    dl.innerHTML = "";
    (m.disks||[]).forEach(d => {
      const wrap = document.createElement("div");
      wrap.className = "disk-row";
      wrap.innerHTML =
        `<div>` +
          `<div class="meta"><b>${d.mount}</b> <span style="color:var(--muted)">(${d.fs})</span></div>` +
          `<div class="bar" style="margin-top:4px;"><span style="width:${d.percent}%;background:linear-gradient(90deg,#5dffae,#ffd166 60%,#ff5d6c)"></span></div>` +
        `</div>` +
        `<div class="pct">${fmtBytes(d.used)} / ${fmtBytes(d.total)} · ${d.percent.toFixed(1)}%</div>`;
      dl.appendChild(wrap);
    });

    // Processes
    procData = m.processes || [];
    renderProcs();
  }

  // network sparkline
  function drawNet() {
    const c = $("net-chart"); const ctx = c.getContext("2d");
    const dpr = window.devicePixelRatio || 1;
    const w = c.clientWidth, h = c.clientHeight;
    if (c.width !== w*dpr || c.height !== h*dpr) { c.width = w*dpr; c.height = h*dpr; ctx.scale(dpr,dpr); }
    ctx.clearRect(0,0,w,h);
    if (netHistory.length === 0) return;
    const peak = Math.max(1, ...netHistory.map(p => Math.max(p.rx, p.tx)));
    const stepX = w / Math.max(1, NET_HISTORY-1);
    // baseline
    ctx.strokeStyle = "rgba(255,255,255,0.05)";
    for (let i = 0; i < 4; i++) {
      const y = (h / 4) * i + 0.5;
      ctx.beginPath(); ctx.moveTo(0,y); ctx.lineTo(w,y); ctx.stroke();
    }
    const drawSeries = (k, color, fill) => {
      ctx.beginPath();
      netHistory.forEach((p,i) => {
        const x = i*stepX;
        const y = h - (p[k]/peak)*h*0.95 - 2;
        if (i === 0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
      });
      ctx.lineTo(w, h); ctx.lineTo(0, h); ctx.closePath();
      const grad = ctx.createLinearGradient(0,0,0,h);
      grad.addColorStop(0, fill); grad.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = grad; ctx.fill();
      ctx.beginPath();
      netHistory.forEach((p,i) => {
        const x = i*stepX;
        const y = h - (p[k]/peak)*h*0.95 - 2;
        if (i === 0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
      });
      ctx.strokeStyle = color; ctx.lineWidth = 1.6; ctx.stroke();
    };
    drawSeries("rx", "#4cf2ff", "rgba(76,242,255,0.25)");
    drawSeries("tx", "#ff5cd6", "rgba(255,92,214,0.25)");
  }

  // ------------------------------ processes
  let procData = [];
  let procSort = { key: "cpu", dir: -1 };
  $("proc-filter").addEventListener("input", renderProcs);
  document.querySelectorAll("table.procs th").forEach(th => {
    th.addEventListener("click", () => {
      const k = th.dataset.sort;
      if (procSort.key === k) procSort.dir = -procSort.dir;
      else { procSort.key = k; procSort.dir = (k === "cpu" || k === "mem" || k === "res" || k === "virt" || k === "time") ? -1 : 1; }
      document.querySelectorAll("table.procs th .arrow").forEach(a => a.textContent = "");
      th.querySelector(".arrow").textContent = procSort.dir === -1 ? "▼" : "▲";
      renderProcs();
    });
  });
  function renderProcs() {
    const q = $("proc-filter").value.trim().toLowerCase();
    const tbody = $("proc-tbody"); tbody.innerHTML = "";
    let rows = procData.slice();
    if (q) rows = rows.filter(p =>
      String(p.pid).includes(q) || (p.name||"").toLowerCase().includes(q)
      || (p.user||"").toLowerCase().includes(q) || (p.cmd||"").toLowerCase().includes(q));
    rows.sort((a,b) => {
      let av = a[procSort.key], bv = b[procSort.key];
      if (typeof av === "string") return procSort.dir * av.localeCompare(bv);
      return procSort.dir * ((av||0) - (bv||0));
    });
    rows.slice(0, 200).forEach(p => {
      const tr = document.createElement("tr");
      const cpuClass = p.cpu > 50 ? "cpu-hot" : p.cpu > 10 ? "cpu-warm" : "cpu-cool";
      tr.innerHTML =
        `<td>${p.pid}</td>` +
        `<td>${p.user}</td>` +
        `<td class="right">${p.pri}</td>` +
        `<td class="right">${p.ni}</td>` +
        `<td class="right">${fmtBytes(p.virt)}</td>` +
        `<td class="right">${fmtBytes(p.res)}</td>` +
        `<td>${p.s}</td>` +
        `<td class="right ${cpuClass}">${p.cpu.toFixed(1)}</td>` +
        `<td class="right">${p.mem.toFixed(1)}</td>` +
        `<td class="right">${fmtTimeProc(p.time)}</td>` +
        `<td title="${(p.cmd||"").replace(/"/g,'&quot;')}">${p.name || ""}</td>`;
      tbody.appendChild(tr);
    });
  }

  // ------------------------------ refresh interval
  function startPolling(ms) {
    currentInterval = ms;
    if (intervalId) { clearInterval(intervalId); intervalId = null; }
    if (ms > 0) {
      intervalId = setInterval(poll, ms);
    }
  }
  $("refresh-rate").addEventListener("change", e => {
    const ms = parseInt(e.target.value, 10) || 0;
    startPolling(ms);
    toast(ms > 0 ? `auto-refresh every ${ms/1000}s` : "auto-refresh paused", ms > 0 ? "ok" : "warn", 1800);
  });
  $("refresh-now").addEventListener("click", () => { poll(); toast("refreshed", "ok", 1200); });
  poll();                       // always do an initial fetch
  startPolling(currentInterval);

  // ------------------------------ login
  const loginModal = $("login-modal");
  const showLogin = (next) => {
    $("lm-error").textContent = "";
    $("lm-user").value = ""; $("lm-pass").value = "";
    loginModal.classList.add("show");
    setTimeout(() => $("lm-user").focus(), 50);
    loginModal.dataset.next = next || "";
  };
  $("btn-login").addEventListener("click", () => showLogin(""));
  $("lm-cancel").addEventListener("click", () => loginModal.classList.remove("show"));
  $("lm-ok").addEventListener("click", doLogin);
  $("lm-pass").addEventListener("keypress", e => { if (e.key === "Enter") doLogin(); });

  async function doLogin() {
    const u = $("lm-user").value.trim();
    const p = $("lm-pass").value;
    if (!u || !p) { $("lm-error").textContent = "Username and password required."; return; }
    $("lm-ok").disabled = true; $("lm-ok").textContent = "…";
    try {
      const r = await fetch("/api/auth", {
        method: "POST", headers: {"Content-Type":"application/json"},
        body: JSON.stringify({ username: u, password: p })
      });
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || "auth failed");
      setAuth(d.token, d.user);
      loginModal.classList.remove("show");
      toast(`Authenticated as ${d.user}`, "ok");
      const next = loginModal.dataset.next;
      if (next === "terminal") openTerminal();
      else if (next === "shutdown") confirmPower("shutdown");
      else if (next === "reboot")   confirmPower("reboot");
    } catch (e) {
      $("lm-error").textContent = e.message;
    } finally {
      $("lm-ok").disabled = false; $("lm-ok").textContent = "Authenticate";
    }
  }

  // ------------------------------ confirm modal
  const cm = $("confirm-modal");
  let cmAction = null;
  function confirmPower(action) {
    cmAction = action;
    $("cm-title").textContent = action === "shutdown" ? "Shutdown system" : "Reboot system";
    $("cm-msg").textContent =
      `Confirm ${action} of ${$("hostname").textContent}? The action will execute after a 1.5 s grace period.`;
    cm.classList.add("show");
  }
  $("cm-cancel").addEventListener("click", () => cm.classList.remove("show"));
  $("cm-ok").addEventListener("click", async () => {
    cm.classList.remove("show");
    if (!token) { showLogin(cmAction); return; }
    try {
      const r = await fetch("/api/power/" + cmAction, {
        method: "POST",
        headers: {"Authorization": "Bearer " + token}
      });
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || "power failed");
      toast(`${cmAction} scheduled — host going down`, "warn", 6000);
    } catch (e) { toast("Power action failed: " + e.message, "error"); }
  });
  $("btn-shutdown").addEventListener("click", () => token ? confirmPower("shutdown") : showLogin("shutdown"));
  $("btn-reboot")  .addEventListener("click", () => token ? confirmPower("reboot")   : showLogin("reboot"));

  // ------------------------------ terminal
  let term = null, fitAddon = null, ws = null;
  let termResizeObserver = null, termHandlersBound = false;
  const termWin = $("termwin");
  $("btn-terminal").addEventListener("click", () => token ? openTerminal() : showLogin("terminal"));
  $("term-close").addEventListener("click", closeTerminal);

  function termFatal(msg) {
    const el = $("term");
    if (el) el.innerHTML =
      '<div style="color:#ff5d6c;font-family:JetBrains Mono,monospace;padding:18px;line-height:1.6;">'
      + '[r369] ' + msg + '<br><br>'
      + '<span style="color:#7c87b3">Open the browser dev tools (F12) → Console tab for details.</span>'
      + '</div>';
    console.error("[r369]", msg);
  }

  function openTerminal() {
    if (!token) return showLogin("terminal");
    $("term-host").textContent = $("hostname").textContent;
    termWin.classList.add("show");

    // (1) Sanity-check that xterm.js actually loaded. If not, surface it
    //     instead of silently failing.
    if (typeof Terminal === "undefined" || typeof FitAddon === "undefined") {
      termFatal("xterm.js failed to load. Check that /static/xterm.js is reachable.");
      return;
    }

    // (2) Construct the Terminal object once. DOM-independent, so safe to do
    //     synchronously here.
    if (!term) {
      try {
        term = new Terminal({
          fontFamily: "JetBrains Mono, Menlo, Consolas, monospace",
          fontSize: 13, cursorBlink: true, scrollback: 5000,
          theme: { background: "#05060d", foreground: "#d8e1ff",
                   cursor: "#4cf2ff", black: "#05060d", red: "#ff5d6c",
                   green: "#5dffae", yellow: "#ffd166", blue: "#6196ff",
                   magenta: "#ff5cd6", cyan: "#4cf2ff", white: "#d8e1ff" }
        });
        fitAddon = new FitAddon.FitAddon();
        term.loadAddon(fitAddon);
      } catch (e) {
        termFatal("Terminal constructor failed: " + e.message);
        return;
      }
    }

    // (3) Open the WS *before* poking the DOM, so even if xterm.open() throws
    //     the connection still hits the server (and shows up in /opt/r369/logs).
    connectTerminalWS();

    // (4) DOM-dependent: open xterm into its container on the next paint so
    //     dimensions are real.
    requestAnimationFrame(() => {
      if (!term._opened) {
        try {
          term.open($("term"));
          term._opened = true;
          if (termResizeObserver) { try { termResizeObserver.disconnect(); } catch(e){} }
          termResizeObserver = new ResizeObserver(() => { try { fitAddon.fit(); } catch (e) {} });
          termResizeObserver.observe($("term"));
        } catch (e) {
          termFatal("term.open() failed: " + e.message);
          return;
        }
      }
      try { fitAddon.fit(); } catch (e) {}
      requestAnimationFrame(() => { try { fitAddon.fit(); } catch (e) {} });
      try { term.focus(); } catch (e) {}
    });
  }

  function connectTerminalWS() {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
      console.log("[r369] WS already open/connecting");
      return;
    }
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url   = proto + "//" + location.host + "/ws/terminal?token=" + encodeURIComponent(token);
    console.log("[r369] WS connecting:", url);

    try {
      ws = new WebSocket(url);
    } catch (e) {
      termFatal("WebSocket constructor threw: " + e.message);
      return;
    }

    ws.onopen = () => {
      console.log("[r369] WS open");
      let cols = 100, rows = 28;
      try {
        const dim = fitAddon ? fitAddon.proposeDimensions() : null;
        if (dim && dim.cols > 0 && dim.rows > 0) { cols = dim.cols; rows = dim.rows; }
      } catch (e) {}
      try { ws.send(JSON.stringify({ type: "resize", cols, rows })); } catch (e) {}
      if (term) try { term.focus(); } catch (e) {}
    };
    ws.onerror = (e) => {
      console.error("[r369] WS error", e);
      if (term) try { term.writeln("\r\n\x1b[31m[r369] websocket error — see browser console\x1b[0m"); } catch (er) {}
    };
    ws.onmessage = (ev) => {
      try {
        const d = JSON.parse(ev.data);
        if (d.type === "data" && term)        term.write(d.data);
        else if (d.type === "ready" && term)  term.writeln("\x1b[36m[r369] connected as " + d.user + "\x1b[0m");
        else if (d.type === "error" && term)  term.writeln("\x1b[31m[r369] " + d.msg + "\x1b[0m");
      } catch (e) { console.warn("[r369] bad ws frame", e); }
    };
    ws.onclose = (ev) => {
      console.log("[r369] WS closed", ev.code, ev.reason || "");
      if (term) try { term.writeln("\r\n\x1b[33m[r369] session closed (code " + ev.code + ")\x1b[0m"); } catch (er) {}
    };

    // Bind input handlers exactly once per term instance.
    if (term && !termHandlersBound) {
      termHandlersBound = true;
      term.onData(d => {
        if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type:"data", data:d}));
      });
      term.onResize(({cols, rows}) => {
        if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({type:"resize", cols, rows}));
      });
    }
  }
  function closeTerminal() {
    termWin.classList.remove("show");
    if (ws) { try { ws.close(); } catch (e) {} ws = null; }
  }

  // ------------------------------ drag + resize the terminal window
  (() => {
    const head = $("term-header"), win = termWin, rh = $("term-resize");
    let drag = null;
    head.addEventListener("mousedown", (e) => {
      if (e.target.closest("button")) return;
      const r = win.getBoundingClientRect();
      drag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
      e.preventDefault();
    });
    let resize = null;
    rh.addEventListener("mousedown", (e) => {
      const r = win.getBoundingClientRect();
      resize = { x: e.clientX, y: e.clientY, w: r.width, h: r.height };
      e.preventDefault();
    });
    document.addEventListener("mousemove", (e) => {
      if (drag) {
        const x = Math.max(0, Math.min(window.innerWidth  - win.offsetWidth,  e.clientX - drag.dx));
        const y = Math.max(0, Math.min(window.innerHeight - win.offsetHeight, e.clientY - drag.dy));
        win.style.left = x + "px"; win.style.top = y + "px";
      } else if (resize) {
        const w = Math.max(380, Math.min(window.innerWidth  - win.offsetLeft, resize.w + (e.clientX - resize.x)));
        const h = Math.max(220, Math.min(window.innerHeight - win.offsetTop,  resize.h + (e.clientY - resize.y)));
        win.style.width = w + "px"; win.style.height = h + "px";
        if (fitAddon) try { fitAddon.fit(); } catch (e) {}
      }
    });
    document.addEventListener("mouseup", () => { drag = null; resize = null; });
    window.addEventListener("resize", () => { if (fitAddon && termWin.classList.contains("show")) try { fitAddon.fit(); } catch (e) {} });
  })();
})();
</script>
</body>
</html>
"""


if __name__ == "__main__":
    main()
R369_PY_EOF
    chmod 0750 "${R369_APP}"

    # PAM service stack — minimal: chains common-auth + common-account so it
    # works for both root and non-root local users and avoids /etc/pam.d/login
    # side effects (pam_securetty/pam_faildelay/pam_nologin) that don't apply
    # to a daemon-driven HTTP auth flow.
    cat > "/etc/pam.d/r369" <<'PAMEOF'
# R369 System Monitor — PAM service
# Used by the web UI for terminal + power-action authentication.
auth      include   common-auth
account   include   common-account
PAMEOF
    chmod 0644 "/etc/pam.d/r369"

    cat > "/etc/systemd/system/${R369_SVC}.service" <<EOF
[Unit]
Description=R369 System Monitor (htop-style web dashboard on :10369)
Documentation=file://${R369_DIR}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${R369_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${R369_VENV}/bin/python ${R369_APP}
Restart=on-failure
RestartSec=5
KillMode=mixed
TimeoutStopSec=10
# Logs are managed by Python's RotatingFileHandler in ${R369_LOGS}; also mirror to journal.
StandardOutput=journal
StandardError=journal
# Allow systemctl reboot/poweroff
NoNewPrivileges=false
ProtectSystem=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    # logrotate policy (belt-and-braces; the app self-rotates too)
    cat > "/etc/logrotate.d/r369" <<EOF
${R369_LOGS}/*.log {
    size 2G
    rotate 60
    maxage 30
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
    create 0640 root root
}
EOF
}

step_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo "ufw not installed — nothing to do."
        return 0
    fi
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw present but inactive — nothing to do."
        return 0
    fi
    for p in "${PORTS[@]}"; do
        ufw allow "$p"/tcp comment "R369 Monitor" >/dev/null 2>&1 || true
    done
    echo "ufw rules added for ${PORTS[*]}/tcp."
}

step_systemd() {
    systemctl daemon-reload
    systemctl enable "${R369_SVC}.service" >/dev/null 2>&1 || true
    # restart picks up app.py / unit / PAM changes on re-runs
    systemctl restart "${R369_SVC}.service"
    sleep 1.5
    if ! systemctl is-active --quiet "${R369_SVC}.service"; then
        echo "Service failed to start. Last 30 journal lines:"
        echo
        journalctl -u "${R369_SVC}.service" --no-pager -n 30 || true
        return 1
    fi
}

# Detect which of our two candidate ports the service is actually listening on.
detect_port() {
    local p
    for p in "${PORTS[@]}"; do
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(:|^)${p}$"; then
            echo "$p"; return 0
        fi
    done
    echo "${PORTS[0]}"
}

# =============================================================================
# Main flow
# =============================================================================
printf "\n%sR369 System Monitor%s — installing…\n\n" "$C_BLU" "$C_OFF"

quietly "Pre-flight checks"                    step_preflight
quietly "Installing OS packages"               step_apt
quietly "Creating ${R369_DIR}"                 step_dirs
quietly "Caching xterm.js assets (npm)"        step_xterm
quietly "Setting up Python environment"        step_python
quietly "Writing application + service files"  step_appfiles
quietly "Configuring firewall (UFW)"           step_firewall
quietly "Starting ${R369_SVC}.service"         step_systemd

# --- summary -----------------------------------------------------------------
ip_primary=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$ip_primary" ]] && ip_primary="<host-ip>"
chosen_port=$(detect_port)

cat <<SUMMARY

  ${C_GRN}✓${C_OFF} R369 System Monitor installed.

    URL          ${C_BLU}http://${ip_primary}:${chosen_port}/${C_OFF}
    Install dir  ${R369_DIR}
    Logs         ${R369_LOGS}/r369.log  (2 GB rotation × 60, 30-day max-age)
    Service      systemctl {status|restart|stop} ${R369_SVC}
    Uninstall    sudo $0 --uninstall

  Login uses local Linux PAM users.
  Power buttons require auth and execute via systemctl.
  Floating terminal opens a real PTY shell as the authenticated user.

SUMMARY
