#!/usr/bin/env python3
"""cpu-orphan-watch: detect VS Code extension-host busy-loops (dangling-pipe /
orphaned agent sessions) and alert via Telegram.

Symptom this catches: an `extensionHost` node process burning sustained CPU
(mostly kernel/system time) because a dead agent session left a pipe that epoll
reports readable-on-EOF forever. See homelab docs for the 2026-07-01 incident.

Trigger  = any extensionHost process with sustained CPU >= CPU_THRESHOLD %.
Enriched = long-lived claude/codex sessions (candidate orphans) + tmux clients.
Config   : reuses ~/.config/homelab/notify-telegram.env
Log      : ~/.local/state/homelab-notify/cpu-orphan-watch.log
State    : cooldown so an ongoing issue pings once per COOLDOWN, but always logs.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

# ---- tunables (override via env) ---------------------------------------------
CPU_THRESHOLD = float(os.environ.get("COW_CPU_THRESHOLD", "40"))   # percent
SAMPLE_SECS   = float(os.environ.get("COW_SAMPLE_SECS", "4"))      # measure window
STALE_MINUTES = int(os.environ.get("COW_STALE_MINUTES", "360"))    # 6h => "old agent"
COOLDOWN_SECS = int(os.environ.get("COW_COOLDOWN_SECS", "7200"))   # 2h between pings

HOME     = os.path.expanduser("~")
ENV_FILE = os.path.join(HOME, ".config/homelab/notify-telegram.env")
STATE_D  = os.path.join(HOME, ".local/state/homelab-notify")
LOG_FILE = os.path.join(STATE_D, "cpu-orphan-watch.log")
STATE_F  = os.path.join(STATE_D, "cpu-orphan-watch.state.json")
CLK_TCK  = os.sysconf("SC_CLK_TCK")


def log(msg):
    os.makedirs(STATE_D, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    with open(LOG_FILE, "a") as f:
        f.write(f"{ts} {msg}\n")


def load_cfg():
    cfg = {}
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def tg_send(cfg, text):
    token = cfg["TELEGRAM_BOT_TOKEN"]
    chat = cfg["TELEGRAM_CHAT_ID"]
    data = json.dumps({"chat_id": chat, "text": text,
                       "disable_web_page_preview": True}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        resp = json.load(r)
    if not resp.get("ok"):
        raise RuntimeError(f"telegram error: {resp}")


def read_state():
    try:
        with open(STATE_F) as f:
            return json.load(f)
    except Exception:
        return {}


def write_state(st):
    with open(STATE_F, "w") as f:
        json.dump(st, f)


def proc_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read().replace(b"\0", b" ").decode(errors="replace").strip()
    except Exception:
        return ""


def proc_cpu_ticks(pid):
    """utime+stime and (utime,stime) in clock ticks."""
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().split()
    # fields 14,15 (1-indexed) = utime,stime; account for comm containing spaces
    rparen = " ".join(parts).rfind(")")
    tail = " ".join(parts)[rparen + 2:].split()
    utime, stime = int(tail[11]), int(tail[12])
    return utime, stime


def find_ext_hosts():
    pids = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        cmd = proc_cmdline(name)
        if "type=extensionHost" in cmd:
            pids.append(int(name))
    return pids


def measure_cpu(pids):
    t0 = {}
    for p in pids:
        try:
            u, s = proc_cpu_ticks(p)
            t0[p] = (u, s)
        except Exception:
            pass
    time.sleep(SAMPLE_SECS)
    out = {}
    for p, (u0, s0) in t0.items():
        try:
            u1, s1 = proc_cpu_ticks(p)
        except Exception:
            continue
        du, ds = (u1 - u0), (s1 - s0)
        pct = (du + ds) / (SAMPLE_SECS * CLK_TCK) * 100.0
        sys_share = (ds / (du + ds) * 100.0) if (du + ds) else 0.0
        out[p] = (pct, sys_share)
    return out


def list_agents():
    """long-lived claude/codex procs -> list of dicts."""
    try:
        raw = subprocess.check_output(
            ["ps", "-eo", "pid,ppid,etimes,tty,comm"], text=True)
    except Exception:
        return []
    agents = []
    for line in raw.splitlines()[1:]:
        f = line.split(None, 4)
        if len(f) < 5:
            continue
        pid, ppid, etimes, tty, comm = f
        if comm not in ("claude", "codex"):
            continue
        try:
            secs = int(etimes)
        except ValueError:
            continue
        if secs >= STALE_MINUTES * 60:
            agents.append({"pid": pid, "ppid": ppid, "hrs": secs / 3600.0,
                           "tty": tty, "comm": comm})
    return agents


def tmux_summary():
    try:
        out = subprocess.check_output(
            ["pgrep", "-a", "tmux"], text=True).strip()
        return len([l for l in out.splitlines() if l]) if out else 0
    except Exception:
        return 0


def main():
    hosts = find_ext_hosts()
    if not hosts:
        return
    cpu = measure_cpu(hosts)
    offenders = {p: v for p, v in cpu.items() if v[0] >= CPU_THRESHOLD}

    st = read_state()
    now = int(time.time())

    if not offenders:
        # recovery note if we were previously in an alerting state
        if st.get("active"):
            st["active"] = False
            write_state(st)
            log("RECOVERED: no extension host over threshold")
            try:
                tg_send(load_cfg(),
                        "✅ CPU 恢復正常\nextension host 已無空轉（<%.0f%%）。"
                        % CPU_THRESHOLD)
            except Exception as e:
                log(f"tg send failed (recovery): {e}")
        return

    # build report
    agents = list_agents()
    ntmux = tmux_summary()
    lines = []
    for p, (pct, sysh) in sorted(offenders.items(), key=lambda x: -x[1][0]):
        lines.append(f"  host PID {p}: {pct:.0f}% CPU (kernel {sysh:.0f}%)")
    detail = "\n".join(lines)
    agent_lines = "\n".join(
        f"  {a['comm']} PID {a['pid']} ppid={a['ppid']} "
        f"{a['hrs']:.1f}h tty={a['tty']}" for a in agents) or "  (none)"

    log(f"TRIGGER hosts={list(offenders)} "
        f"cpu={{ {', '.join(f'{p}:{v[0]:.0f}%' for p,v in offenders.items())} }} "
        f"stale_agents={[a['pid'] for a in agents]} tmux_procs={ntmux}")

    # cooldown: log always, ping at most once per COOLDOWN
    last = st.get("last_notify", 0)
    if now - last < COOLDOWN_SECS:
        return

    msg = (
        "⚠️ VS Code extension host 空轉\n"
        f"CPU 門檻 {CPU_THRESHOLD:.0f}%，取樣 {SAMPLE_SECS:.0f}s\n\n"
        f"高佔用 host：\n{detail}\n\n"
        f"可疑殘留 session（存活 ≥{STALE_MINUTES//60}h，優先考慮 kill）：\n"
        f"{agent_lines}\n\n"
        f"tmux 相關進程：{ntmux}\n"
        "處置：kill 上面殘留 session 的 PID，或\n"
        "VS Code → Developer: Restart Extension Host。"
    )
    try:
        tg_send(load_cfg(), msg)
        st["last_notify"] = now
        st["active"] = True
        write_state(st)
        log("notified via telegram")
    except Exception as e:
        log(f"tg send failed: {e}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"FATAL: {e}")
        sys.exit(1)
