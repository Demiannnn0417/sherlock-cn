#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sherlock 本地部署 —— 代理探测

本机网络里有一件容易被忽略的事：系统代理注册表可能写着 ProxyEnable=0，
但代理客户端其实在跑（TUN / 规则模式）。所以判断"有没有可用代理"不能只看开关，
必须真的发一个请求出去。

探测顺序（auto）：
  1. 环境变量 HTTPS_PROXY / HTTP_PROXY（尊重用户已有设置）
  2. 注册表 ProxyServer（哪怕 ProxyEnable=0）
  3. 常见本地端口（12450 / 7890 / 7897 / 10809 / 1080 / 8080）
每个候选先做 TCP 连通，再做一次 HTTPS 验证：
  - strong：能取到 data.sherlockproject.xyz（本机直连会被 reset，能打开说明代理确实做了转发）
  - weak  ：能取到 api.github.com（代理能出网，但拿不到被阻断的域名）

用法：
  python lib/proxy_probe.py                 # 输出代理 URL（没有则空）
  python lib/proxy_probe.py --json          # 输出完整探测结果
  python lib/proxy_probe.py --refresh       # 忽略缓存重新探测
  python lib/proxy_probe.py --emit-cmd FILE # 生成可 call 的 set 环境变量脚本
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = ROOT / "state"
CONFIG_FILE = STATE_DIR / "config.json"
CACHE_FILE = STATE_DIR / "proxy.json"
ENV_FILE = STATE_DIR / "proxy_env.cmd"

# 本机直连会被 reset，走代理通常能打开 —— 用它判断"代理是否真的绕过了阻断"
BLOCKED_CANARY = "https://data.sherlockproject.xyz"
# 直连一般可达 —— 用它判断"代理本身能不能出网"
CONTROL_CANARY = "https://api.github.com"

DEFAULT_PORTS = (12450, 7890, 7897, 10809, 1080, 8080, 8888)
CACHE_TTL_SECONDS = 300
HTTP_TIMEOUT = 5.0
TCP_TIMEOUT = 0.35

try:
    import requests
except Exception:  # pragma: no cover - venv 未装依赖时保持静默
    requests = None


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _read_json(path: Path, default):
    # utf-8-sig：PowerShell 5.1 的 Set-Content -Encoding UTF8 会写 BOM，
    # 用 utf-8 读到 "\ufeff{...}" 会让 json 解析直接失败
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        return default


def _write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_config() -> dict:
    cfg = _read_json(CONFIG_FILE, {})
    if not isinstance(cfg, dict):
        cfg = {}
    cfg.setdefault("proxy", "auto")
    cfg.setdefault("timeout", 15)
    cfg.setdefault("sites", "")
    cfg.setdefault("saveToDesktop", True)
    return cfg


def normalize_proxy(value: str | None) -> str | None:
    """把 127.0.0.1:12450 / http://... / https://... 统一成 http://host:port。"""
    if not value:
        return None
    value = value.strip().strip('"').strip("'")
    if not value:
        return None
    if value.lower() in ("off", "none", "direct", "false", "0"):
        return None
    if "://" not in value:
        value = "http://" + value
    value = value.rstrip("/")
    return value


def registry_proxy() -> str | None:
    """读 HKCU 的 ProxyServer，即使 ProxyEnable=0 也读（TUN 模式下常是这种情况）。"""
    try:
        import winreg

        key = winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Internet Settings",
        )
        try:
            server, _ = winreg.QueryValueEx(key, "ProxyServer")
        finally:
            winreg.CloseKey(key)
    except Exception:
        return None
    if not server:
        return None
    parts = [p.strip() for p in str(server).split(";") if p.strip()]
    parsed = {}
    for part in parts:
        if "=" in part:
            scheme, _, addr = part.partition("=")
            parsed[scheme.strip().lower()] = addr.strip()
        else:
            parsed.setdefault("http", part)
    addr = parsed.get("https") or parsed.get("http")
    return normalize_proxy(addr)


def _host_port(url: str) -> tuple[str, int] | None:
    try:
        body = url.split("://", 1)[1]
        body = body.split("/", 1)[0]
        host, _, port = body.rpartition(":")
        if not host:
            host, port = body, "80"
        return host, int(port)
    except Exception:
        return None


def port_open(url: str, timeout: float = TCP_TIMEOUT) -> bool:
    hp = _host_port(url)
    if not hp:
        return False
    try:
        with socket.create_connection(hp, timeout=timeout):
            return True
    except OSError:
        return False


def http_probe(target: str, proxy_url: str) -> dict:
    if requests is None:
        return {"ok": False, "error": "requests 未安装", "status": None, "latency_ms": None}
    started = time.perf_counter()
    try:
        response = requests.get(
            target,
            proxies={"http": proxy_url, "https": proxy_url},
            timeout=HTTP_TIMEOUT,
            allow_redirects=False,
            headers={"User-Agent": "sherlock-local-probe/1.0"},
        )
        latency = int((time.perf_counter() - started) * 1000)
        return {
            "ok": response.status_code < 500,
            "status": response.status_code,
            "latency_ms": latency,
            "error": None,
        }
    except Exception as exc:  # 连接失败 / 超时 / TLS 重置
        latency = int((time.perf_counter() - started) * 1000)
        return {
            "ok": False,
            "status": None,
            "latency_ms": latency,
            "error": f"{type(exc).__name__}: {str(exc)[:120]}",
        }


def verify(proxy_url: str) -> dict:
    """strong = 能打开被阻断域名；weak = 只能出网；none = 代理不可用。"""
    if not port_open(proxy_url):
        return {"verified": "none", "blocked_ok": False, "control_ok": False, "latency_ms": None, "error": "TCP 端口未监听"}
    blocked = http_probe(BLOCKED_CANARY, proxy_url)
    control = http_probe(CONTROL_CANARY, proxy_url)
    if blocked["ok"]:
        level = "strong"
    elif control["ok"]:
        level = "weak"
    else:
        level = "none"
    return {
        "verified": level,
        "blocked_ok": bool(blocked["ok"]),
        "control_ok": bool(control["ok"]),
        "latency_ms": blocked["latency_ms"] if blocked["ok"] else control["latency_ms"],
        "error": None if level != "none" else (blocked["error"] or control["error"]),
    }


def collect_candidates(mode: str) -> list[dict]:
    """返回 [(url, source)]，按优先级排序并去重。"""
    candidates: list[dict] = []
    seen: set[str] = set()

    def add(url: str | None, source: str) -> None:
        norm = normalize_proxy(url)
        if not norm or norm in seen:
            return
        seen.add(norm)
        candidates.append({"url": norm, "source": source})

    if mode not in ("auto", ""):
        add(mode, "config")
        return candidates

    add(os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy"), "env")
    add(os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy"), "env")
    add(registry_proxy(), "registry")
    for port in DEFAULT_PORTS:
        add(f"127.0.0.1:{port}", "port")
    return candidates


def _cache_is_fresh(cache: dict) -> bool:
    try:
        age = time.time() - float(cache.get("checked_ts", 0))
    except Exception:
        return False
    return 0 <= age < CACHE_TTL_SECONDS


def detect(refresh: bool = False) -> dict:
    config = load_config()
    mode = str(config.get("proxy", "auto") or "auto").strip().lower()
    result = {
        "url": None,
        "source": "none",
        "verified": "none",
        "blocked_ok": False,
        "control_ok": False,
        "latency_ms": None,
        "error": None,
        "cached": False,
        "mode": mode,
        "checked_at": _now_iso(),
        "candidates": [],
    }

    if mode in ("off", "none", "direct", "false", "0"):
        result.update({"mode": "off", "source": "disabled"})
        return result

    cache = _read_json(CACHE_FILE, {})
    if not refresh and isinstance(cache, dict) and cache.get("mode") == mode and _cache_is_fresh(cache):
        if not cache.get("url"):
            result.update({"cached": True, "source": "cache", "verified": "none"})
            return result
        if port_open(cache["url"]):
            result.update(
                {
                    "cached": True,
                    "url": cache["url"],
                    "source": cache.get("source", "cache"),
                    "verified": cache.get("verified", "none"),
                    "blocked_ok": bool(cache.get("blocked_ok")),
                    "control_ok": bool(cache.get("control_ok")),
                }
            )
            return result

    candidates = collect_candidates(mode)
    result["candidates"] = candidates
    chosen = None
    for candidate in candidates:
        outcome = verify(candidate["url"])
        candidate.update(outcome)
        if outcome["verified"] == "strong":
            chosen = candidate
            break
        if outcome["verified"] == "weak" and chosen is None:
            chosen = candidate

    if chosen is not None:
        result.update(
            {
                "url": chosen["url"],
                "source": chosen["source"],
                "verified": chosen["verified"],
                "blocked_ok": chosen.get("blocked_ok", False),
                "control_ok": chosen.get("control_ok", False),
                "latency_ms": chosen.get("latency_ms"),
                "error": None,
            }
        )
    else:
        errors = [c["error"] for c in candidates if c.get("error")]
        result["error"] = errors[0] if errors else None

    _write_json(
        CACHE_FILE,
        {
            "checked_ts": time.time(),
            "checked_at": result["checked_at"],
            "mode": mode,
            "url": result["url"],
            "source": result["source"],
            "verified": result["verified"],
            "blocked_ok": result["blocked_ok"],
            "control_ok": result["control_ok"],
        },
    )
    return result


def emit_env_cmd(path: Path, url: str | None) -> None:
    """生成可被 call 的 .cmd。

    内容必须是纯 ASCII 且用 CRLF：cmd.exe 的代码页可能是 936，
    任何 UTF-8 中文注释都可能让后面几行被解析错（本项目踩过一次）。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if url:
        lines = [
            "@echo off",
            "rem generated by lib/proxy_probe.py -- do not edit",
            'set "HTTPS_PROXY=%s"' % url,
            'set "HTTP_PROXY=%s"' % url,
        ]
    else:
        lines = [
            "@echo off",
            "rem no usable proxy detected; keep existing environment",
        ]
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sherlock 本地部署代理探测")
    parser.add_argument("--json", action="store_true", help="输出完整探测结果 JSON")
    parser.add_argument("--refresh", action="store_true", help="忽略缓存重新探测")
    parser.add_argument("--quiet", action="store_true", help="不输出代理 URL")
    parser.add_argument("--emit-cmd", metavar="FILE", help="把代理写成 set 环境变量脚本")
    args = parser.parse_args(argv)

    try:
        result = detect(refresh=args.refresh)
    except Exception as exc:  # 探测失败不应该拦住 Sherlock 本身
        print(f"proxy_probe: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    if args.emit_cmd:
        emit_env_cmd(Path(args.emit_cmd), result["url"])

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif not args.quiet:
        if result["url"]:
            print(result["url"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
