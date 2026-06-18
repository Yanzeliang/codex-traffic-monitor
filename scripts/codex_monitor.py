#!/usr/bin/env python3
"""Privacy-preserving local Codex monitor for macOS."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import pathlib
import plistlib
import signal
import shutil
import subprocess
import sys
import time
import urllib.parse
from typing import Any

HOME = pathlib.Path.home()
CODEX_HOME = pathlib.Path(os.environ.get("CODEX_HOME", HOME / ".codex"))
DATA_DIR = HOME / ".codex-monitor"
LATEST = DATA_DIR / "latest.json"
HISTORY = DATA_DIR / "snapshots.jsonl"
REPORT = DATA_DIR / "report.html"
PLIST = HOME / "Library/LaunchAgents/com.local.codex-traffic-monitor.plist"
LABEL = "com.local.codex-traffic-monitor"


def run(cmd: list[str], timeout: int = 10) -> tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout, check=False)
        return p.returncode, p.stdout, p.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def collect_processes() -> tuple[list[dict[str, Any]], list[str]]:
    warnings: list[str] = []
    cmd = ["ps", "-axo", "pid=,ppid=,%cpu=,%mem=,rss=,etime=,comm="]
    code, out, err = run(cmd)
    if code:
        return [], [f"process collector: {err or 'ps failed'}"]
    rows: list[dict[str, Any]] = []
    for line in out.splitlines():
        parts = line.strip().split(None, 6)
        if len(parts) != 7:
            continue
        try:
            rows.append({
                "pid": int(parts[0]), "ppid": int(parts[1]), "cpu_percent": float(parts[2]),
                "memory_percent": float(parts[3]), "rss_bytes": int(parts[4]) * 1024,
                "elapsed": parts[5], "executable": pathlib.Path(parts[6]).name,
                "executable_path": parts[6],
            })
        except ValueError:
            continue
    codex_pids = {
        r["pid"] for r in rows
        if "codex" in r["executable"].lower()
        or "/Codex.app/" in r["executable_path"]
        or "codex" in r["executable_path"].lower()
    }
    changed = True
    while changed:
        changed = False
        for row in rows:
            if row["ppid"] in codex_pids and row["pid"] not in codex_pids:
                codex_pids.add(row["pid"])
                changed = True
    result = []
    for row in rows:
        if row["pid"] in codex_pids:
            row.pop("executable_path", None)
            row["is_codex_root"] = "codex" in row["executable"].lower()
            result.append(row)
    result.sort(key=lambda x: (x["ppid"], x["pid"]))
    return result, warnings


def collect_connections(pids: set[int]) -> tuple[list[dict[str, Any]], list[str]]:
    if not pids:
        return [], []
    warnings: list[str] = []
    code, out, err = run(["lsof", "-nP", "-a", "-p", ",".join(map(str, sorted(pids))), "-i"])
    if code not in (0, 1):
        return [], [f"network collector: {err or 'lsof failed'}"]
    items: list[dict[str, Any]] = []
    lines = out.splitlines()
    for line in lines[1:]:
        parts = line.split(None, 8)
        if len(parts) < 9:
            continue
        try:
            pid = int(parts[1])
        except ValueError:
            continue
        name = parts[8]
        state = None
        if name.endswith(")") and " (" in name:
            name, state = name.rsplit(" (", 1)
            state = state[:-1]
        local, remote = name, None
        if "->" in name:
            local, remote = name.split("->", 1)
        items.append({
            "pid": pid, "process": parts[0], "protocol": parts[7], "local": local,
            "remote": remote, "state": state,
        })
    unique = {(x["pid"], x["protocol"], x["local"], x["remote"], x["state"]): x for x in items}
    return list(unique.values()), warnings


def collect_traffic(pids: set[int]) -> tuple[dict[str, Any], list[str]]:
    """Read macOS per-process TCP counters without capturing packet payloads."""
    empty = {"bytes_in": 0, "bytes_out": 0, "by_process": []}
    if not pids:
        return empty, []
    code, out, err = run(["nettop", "-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out", "-m", "tcp"], timeout=15)
    if code:
        return empty, [f"traffic counter collector: {err or 'nettop failed'}"]
    rows: list[dict[str, Any]] = []
    for line in out.splitlines()[1:]:
        fields = line.rstrip(",").rsplit(",", 2)
        if len(fields) != 3 or "." not in fields[0]:
            continue
        process, pid_text = fields[0].rsplit(".", 1)
        try:
            pid, bytes_in, bytes_out = int(pid_text), int(fields[1]), int(fields[2])
        except ValueError:
            continue
        if pid in pids:
            rows.append({"pid": pid, "process": process, "bytes_in": bytes_in, "bytes_out": bytes_out})
    return {
        "bytes_in": sum(row["bytes_in"] for row in rows),
        "bytes_out": sum(row["bytes_out"] for row in rows),
        "by_process": sorted(rows, key=lambda row: row["bytes_in"] + row["bytes_out"], reverse=True),
    }, []


def skill_metadata(path: pathlib.Path, source: str) -> dict[str, str] | None:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")[:16384]
    except OSError:
        return None
    if not text.startswith("---"):
        return {"name": path.parent.name, "description": "", "source": source}
    header = text.split("---", 2)[1]
    fields: dict[str, str] = {}
    for line in header.splitlines():
        if ":" not in line or line[:1].isspace():
            continue
        key, value = line.split(":", 1)
        if key.strip() in ("name", "description"):
            fields[key.strip()] = value.strip().strip("'\"")
    return {
        "name": fields.get("name", path.parent.name),
        "description": fields.get("description", ""),
        "source": source,
    }


def collect_skills() -> tuple[list[dict[str, str]], list[str]]:
    items: list[dict[str, str]] = []
    roots: list[tuple[pathlib.Path, str]] = [(CODEX_HOME / "skills", "local")]
    cache = CODEX_HOME / "plugins" / "cache"
    if cache.exists():
        for marketplace in cache.iterdir():
            if not marketplace.is_dir():
                continue
            for plugin in marketplace.iterdir():
                if not plugin.is_dir():
                    continue
                versions = [p for p in plugin.iterdir() if p.is_dir()]
                if versions:
                    latest = max(versions, key=lambda p: p.stat().st_mtime)
                    roots.append((latest / "skills", f"plugin:{plugin.name}"))
    for root, source in roots:
        if not root.exists():
            continue
        for path in root.rglob("SKILL.md"):
            meta = skill_metadata(path, source)
            if meta:
                items.append(meta)
    unique = {(x["name"], x["source"]): x for x in items}
    return sorted(unique.values(), key=lambda x: (x["source"], x["name"].lower())), []


def codex_binary() -> str | None:
    candidates = [
        shutil.which("codex"),
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]
    return next((item for item in candidates if item and pathlib.Path(item).is_file()), None)


def collect_mcp_servers() -> tuple[list[dict[str, Any]], list[str]]:
    binary = codex_binary()
    if not binary:
        return [], ["MCP collector: codex executable not found"]
    code, out, err = run([binary, "mcp", "list", "--json"], timeout=15)
    if code:
        return [], [f"MCP collector: {err or 'codex mcp list failed'}"]
    try:
        raw = json.loads(out)
    except json.JSONDecodeError as exc:
        return [], [f"MCP collector: invalid JSON ({exc})"]
    items: list[dict[str, Any]] = []
    for entry in raw if isinstance(raw, list) else []:
        if not isinstance(entry, dict):
            continue
        transport = entry.get("transport") or {}
        kind = str(transport.get("type", "unknown"))
        endpoint = None
        if kind in ("streamable_http", "http", "sse"):
            url = str(transport.get("url", ""))
            parsed = urllib.parse.urlsplit(url)
            endpoint = f"{parsed.scheme}://{parsed.netloc}{parsed.path}" if parsed.scheme else None
        elif kind == "stdio":
            endpoint = pathlib.Path(str(transport.get("command", ""))).name or "stdio"
        items.append({
            "name": str(entry.get("name", "unnamed")),
            "enabled": bool(entry.get("enabled", False)),
            "transport": kind,
            "endpoint": endpoint,
            "auth_status": str(entry.get("auth_status", "unknown")),
        })
    return sorted(items, key=lambda x: x["name"].lower()), []


def collect_external_servers(connections: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], dict[str, Any]] = {}
    for connection in connections:
        remote = connection.get("remote")
        if not remote:
            continue
        host, port = remote, ""
        if remote.startswith("[") and "]:" in remote:
            host, port = remote[1:].rsplit("]:", 1)
        elif ":" in remote:
            host, port = remote.rsplit(":", 1)
        normalized = host.strip("[]").lower()
        if normalized in ("127.0.0.1", "::1", "localhost"):
            continue
        key = (host, port)
        item = grouped.setdefault(key, {
            "host": host,
            "port": port,
            "protocol": connection.get("protocol", ""),
            "processes": [],
            "connection_count": 0,
        })
        item["connection_count"] += 1
        process = str(connection.get("process", ""))
        if process and process not in item["processes"]:
            item["processes"].append(process)
    return sorted(grouped.values(), key=lambda x: (-x["connection_count"], x["host"], x["port"]))


def session_files() -> list[pathlib.Path]:
    roots = [CODEX_HOME / "sessions", CODEX_HOME / "archived_sessions"]
    files: list[pathlib.Path] = []
    for root in roots:
        if root.exists():
            files.extend(root.rglob("*.jsonl"))
    return files


def collect_tokens() -> tuple[dict[str, Any], list[str]]:
    warnings: list[str] = []
    sessions: dict[str, dict[str, Any]] = {}
    latest_telemetry: tuple[str, dict[str, Any]] | None = None
    for path in session_files():
        session_id = path.stem.rsplit("-", 1)[-1]
        last_usage: dict[str, Any] | None = None
        last_ts = ""
        try:
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    # Privacy boundary: parse only token_count event lines.
                    if '"token_count"' not in line:
                        continue
                    try:
                        event = json.loads(line)
                        payload = event.get("payload", {})
                        if payload.get("type") != "token_count":
                            continue
                        ts = str(event.get("timestamp", ""))
                        info = payload.get("info") or {}
                        usage = info.get("total_token_usage")
                        if isinstance(usage, dict):
                            last_usage, last_ts = usage, ts
                        telemetry = {
                            "timestamp": ts,
                            "rate_limits": payload.get("rate_limits"),
                        }
                        if latest_telemetry is None or ts > latest_telemetry[0]:
                            latest_telemetry = (ts, telemetry)
                    except (json.JSONDecodeError, AttributeError):
                        continue
        except OSError as exc:
            warnings.append(f"token collector skipped {path.name}: {exc}")
        if last_usage and (session_id not in sessions or last_ts > sessions[session_id]["timestamp"]):
            sessions[session_id] = {"timestamp": last_ts, "usage": last_usage}
    keys = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]
    totals = {key: 0 for key in keys}
    for entry in sessions.values():
        for key in keys:
            value = entry["usage"].get(key, 0)
            if isinstance(value, (int, float)):
                totals[key] += int(value)
    telemetry = latest_telemetry[1] if latest_telemetry else {"timestamp": None, "rate_limits": None}
    limits = telemetry.get("rate_limits") if isinstance(telemetry, dict) else None
    if isinstance(limits, dict):
        now_epoch = int(time.time())
        for key in ("primary", "secondary"):
            window = limits.get(key)
            if not isinstance(window, dict):
                continue
            raw_used = window.get("used_percent")
            resets_at = window.get("resets_at")
            if isinstance(raw_used, (int, float)):
                effective_used = float(raw_used)
                estimated = False
                # Codex only emits rate-limit telemetry during model activity. Once the
                # recorded reset time passes, the old usage value is stale even if no
                # new token_count event has been written yet.
                if isinstance(resets_at, (int, float)) and now_epoch >= int(resets_at):
                    effective_used = 0.0
                    estimated = True
                window["raw_used_percent"] = float(raw_used)
                window["effective_used_percent"] = effective_used
                window["remaining_percent"] = max(0.0, min(100.0, 100.0 - effective_used))
                window["estimated_after_reset"] = estimated
    return {
        "scope": "local_observed_sessions",
        "session_count": len(sessions),
        "totals": totals,
        "latest_telemetry": telemetry,
    }, warnings


def snapshot() -> dict[str, Any]:
    processes, p_warn = collect_processes()
    pids = {p["pid"] for p in processes}
    connections, n_warn = collect_connections(pids)
    traffic, b_warn = collect_traffic(pids)
    tokens, t_warn = collect_tokens()
    skills, s_warn = collect_skills()
    mcp_servers, m_warn = collect_mcp_servers()
    external_servers = collect_external_servers(connections)
    return {
        "schema_version": 1,
        "collected_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "host": {"hostname": os.uname().nodename, "platform": "macOS"},
        "privacy": {
            "payload_capture": False,
            "content_capture": False,
            "credential_access": False,
            "network_scope": "endpoint metadata only",
        },
        "processes": processes,
        "connections": connections,
        "traffic": traffic,
        "tokens": tokens,
        "skills": skills,
        "mcp_servers": mcp_servers,
        "external_servers": external_servers,
        "warnings": p_warn + n_warn + b_warn + t_warn + s_warn + m_warn,
    }


def human_size(value: int) -> str:
    size = float(value)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} GiB"


def render_text(data: dict[str, Any]) -> str:
    token = data["tokens"]
    totals = token["totals"]
    telemetry = token["latest_telemetry"]
    rate = telemetry.get("rate_limits") or {}
    credits = rate.get("credits") or {}
    balance = credits.get("balance")
    lines = [
        "Codex 本地监控快照",
        f"采集时间: {data['collected_at']}",
        f"Codex 进程: {len(data['processes'])}",
        f"活动网络端点: {len(data['connections'])}",
        f"Codex TCP 流量: 入站 {human_size(data['traffic']['bytes_in'])}, 出站 {human_size(data['traffic']['bytes_out'])}",
        f"本地 Skills: {len(data['skills'])}",
        f"MCP 服务: {len(data['mcp_servers'])}",
        f"外部服务器: {len(data['external_servers'])}",
        f"本地观测会话: {token['session_count']}",
        f"本地观测 Token: {totals['total_tokens']:,} (输入 {totals['input_tokens']:,}, 缓存输入 {totals['cached_input_tokens']:,}, 输出 {totals['output_tokens']:,}, 推理输出 {totals['reasoning_output_tokens']:,})",
        f"Codex 记录余额: {balance if balance is not None else '不可用/未返回'}",
    ]
    for key in ("primary", "secondary"):
        window = rate.get(key) or {}
        if window:
            remaining = window.get("remaining_percent")
            estimate = "（等待服务端刷新）" if window.get("estimated_after_reset") else ""
            lines.append(f"{key} 限额窗口: 剩余 {remaining if remaining is not None else '?'}%{estimate}, {window.get('window_minutes', '?')} 分钟")
    if data["processes"]:
        lines.append("\n进程:")
        for p in data["processes"]:
            lines.append(f"  PID {p['pid']} PPID {p['ppid']} {p['executable']} CPU {p['cpu_percent']:.1f}% RSS {human_size(p['rss_bytes'])} 运行 {p['elapsed']}")
    if data["connections"]:
        lines.append("\n连接（元数据，不含内容）:")
        for c in data["connections"]:
            arrow = f" -> {c['remote']}" if c["remote"] else ""
            state = f" [{c['state']}]" if c["state"] else ""
            lines.append(f"  PID {c['pid']} {c['protocol']} {c['local']}{arrow}{state}")
    if data["warnings"]:
        lines.append("\n采集警告:")
        lines.extend(f"  - {w}" for w in data["warnings"])
    return "\n".join(lines)


def write_snapshot(data: dict[str, Any], append: bool = True) -> None:
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = LATEST.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(LATEST)
    if append:
        with HISTORY.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n")
        os.chmod(HISTORY, 0o600)


def write_report(data: dict[str, Any]) -> pathlib.Path:
    write_snapshot(data, append=False)
    text = html.escape(render_text(data))
    doc = f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Codex Traffic Monitor</title>
<style>body{{margin:0;background:#0b1220;color:#dbe7e3;font:15px ui-monospace,SFMono-Regular,Menlo,monospace}}main{{max-width:1100px;margin:36px auto;padding:0 24px}}h1{{color:#48d7ad}}pre{{white-space:pre-wrap;background:#111c2e;border:1px solid #25334b;border-radius:12px;padding:22px;line-height:1.55}}.note{{color:#93a4b8}}</style></head><body><main><h1>Codex Traffic Monitor</h1><p class="note">本地只读统计；不捕获提示词、响应内容、凭据或 TLS 载荷。</p><pre>{text}</pre></main></body></html>"""
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    REPORT.write_text(doc, encoding="utf-8")
    os.chmod(REPORT, 0o600)
    return REPORT


def daemon_loop(interval: int) -> int:
    running = True
    def stop(_signum: int, _frame: Any) -> None:
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while running:
        try:
            write_snapshot(snapshot())
        except Exception as exc:  # daemon must survive partial collector failures
            DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
            with (DATA_DIR / "daemon-error.log").open("a", encoding="utf-8") as fh:
                fh.write(f"{dt.datetime.now(dt.timezone.utc).isoformat()} {type(exc).__name__}: {exc}\n")
        for _ in range(interval):
            if not running:
                break
            time.sleep(1)
    return 0


def install_daemon(interval: int) -> int:
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    script = pathlib.Path(__file__).resolve()
    payload = {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, str(script), "daemon", "--interval", str(interval)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "StandardOutPath": str(DATA_DIR / "daemon.stdout.log"),
        "StandardErrorPath": str(DATA_DIR / "daemon.stderr.log"),
    }
    with PLIST.open("wb") as fh:
        plistlib.dump(payload, fh)
    domain = f"gui/{os.getuid()}"
    run(["launchctl", "bootout", domain, str(PLIST)])
    code, _, err = run(["launchctl", "bootstrap", domain, str(PLIST)])
    if code:
        print(f"安装失败: {err}", file=sys.stderr)
        return code
    run(["launchctl", "kickstart", "-k", f"{domain}/{LABEL}"])
    print(f"监控已启动，每 {interval} 秒采集；数据目录: {DATA_DIR}")
    return 0


def uninstall_daemon() -> int:
    domain = f"gui/{os.getuid()}"
    run(["launchctl", "bootout", domain, str(PLIST)])
    try:
        PLIST.unlink()
    except FileNotFoundError:
        pass
    print("Codex 连续监控已停止。历史数据保留在", DATA_DIR)
    return 0


def daemon_status() -> int:
    domain = f"gui/{os.getuid()}"
    code, out, _ = run(["launchctl", "print", f"{domain}/{LABEL}"])
    if code:
        print("未运行")
        return 1
    state = next((line.strip() for line in out.splitlines() if "state =" in line), "已加载")
    print(f"{state}; latest={LATEST}; history={HISTORY}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Monitor local Codex processes, traffic metadata, tokens, quota, and recorded balance.")
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--json", action="store_true")
    sub.add_parser("report")
    install = sub.add_parser("install-daemon")
    install.add_argument("--interval", type=int, default=10)
    daemon = sub.add_parser("daemon")
    daemon.add_argument("--interval", type=int, default=10)
    sub.add_parser("uninstall-daemon")
    sub.add_parser("daemon-status")
    args = parser.parse_args()
    if args.command == "snapshot":
        data = snapshot()
        print(json.dumps(data, ensure_ascii=False, indent=2) if args.json else render_text(data))
        return 0
    if args.command == "report":
        path = write_report(snapshot())
        print(path)
        return 0
    if args.command == "install-daemon":
        return install_daemon(max(2, args.interval))
    if args.command == "daemon":
        return daemon_loop(max(2, args.interval))
    if args.command == "uninstall-daemon":
        return uninstall_daemon()
    return daemon_status()


if __name__ == "__main__":
    raise SystemExit(main())
