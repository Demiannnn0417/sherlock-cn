#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""国内社交平台检索（Sherlock 本地部署 · CN 模式）

设计原则：
  1. 只做匿名可访问的公开页面 / 公开接口，不破解签名、不绕验证码、不模拟登录；
  2. 能自动判定的平台直接给结论；不能判定的平台只给「带关键词的检索入口」，
     并明确标注"需手动确认"，绝不假装查到了；
  3. 每个平台都记录它是按什么标识匹配的（抖音号 / 昵称 / 豆瓣ID / 用户名），
     避免把"昵称同名"误读成"同一个人"。

用法：
  python lib/cn_search.py <用户名> [更多用户名...] [--csv out.csv] [--json out.json]
  python lib/cn_search.py --selfcheck          # 自检各通道是否还能用
  python lib/cn_search.py --list               # 列出平台覆盖情况
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

try:
    import requests
except Exception:  # pragma: no cover
    requests = None

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
DEFAULT_TIMEOUT = 10.0

ROOT = Path(__file__).resolve().parent.parent
CONFIG_FILE = ROOT / "state" / "config.json"
COOKIE_FILE = ROOT / "state" / "cookies.json"

STATUS_LABEL = {
    "claimed": "命中",
    "available": "未注册",
    "unknown": "未验证",
    "unsupported": "需手动",
    "candidate": "有候选",
    "needs_cookie": "需Cookie",
}

# 每个平台：key / 中文名 / 匹配标识 / 自动检索方式
PLATFORMS = [
    {
        "key": "douyin",
        "name": "抖音",
        "identifier": "抖音号",
        "auto": True,
        "note": "只认抖音号；没设过抖音号的账号查不到",
    },
    {
        "key": "bilibili",
        "name": "B站",
        "identifier": "昵称",
        "auto": True,
        "note": "按昵称搜索，精确同名才算命中",
    },
    {
        "key": "douban",
        "name": "豆瓣",
        "identifier": "豆瓣ID",
        "auto": True,
        "note": "个人主页 /people/<ID>/，不是昵称",
    },
    {
        "key": "cnblogs",
        "name": "博客园",
        "identifier": "用户名",
        "auto": True,
        "note": "博客地址 /<用户名>/",
    },
]

# 不能自动判定的平台：给检索入口 + 原因，状态固定为 unsupported
MANUAL_PLATFORMS = [
    {
        "key": "weibo",
        "name": "微博",
        "identifier": "昵称",
        "reason": "匿名请求一律跳 Sina Visitor 登录页（实测 302→passport）",
        "url": "https://s.weibo.com/user?q={q}",
        "alt": "https://weibo.com/n/{q}",
    },
    {
        "key": "xiaohongshu",
        "name": "小红书",
        "identifier": "昵称",
        "reason": "搜索接口需要登录态与 X-S 签名，网页端为登录墙",
        "url": "https://www.xiaohongshu.com/search_result?keyword={q}",
        "alt": "",
    },
    {
        "key": "wechat",
        "name": "微信",
        "identifier": "微信号",
        "reason": "个人微信没有公开主页或公开检索接口；只能查公众号",
        "url": "https://weixin.sogou.com/weixin?type=1&query={q}",
        "alt": "",
    },
    {
        "key": "zhihu",
        "name": "知乎",
        "identifier": "昵称",
        "reason": "无 Cookie 访问 /people/ 与搜索接口均返回 403",
        "url": "https://www.zhihu.com/search?type=people&q={q}",
        "alt": "",
    },
    {
        "key": "tieba",
        "name": "贴吧",
        "identifier": "用户名",
        "reason": "触发百度安全验证（403），需人工过验证",
        "url": "https://tieba.baidu.com/f/search/res?qw={q}",
        "alt": "",
    },
    {
        "key": "kuaishou",
        "name": "快手",
        "identifier": "昵称",
        "reason": "无公开的用户检索接口，页面为前端渲染",
        "url": "https://www.kuaishou.com/search/user?searchKey={q}",
        "alt": "",
    },
    {
        "key": "douyin_nick",
        "name": "抖音昵称",
        "identifier": "",
        "reason": "抖音昵称不支持按 URL 判定，只能人工看搜索结果",
        "url": "https://www.douyin.com/search/{q}",
        "alt": "",
    },
]

# ---------------------------------------------------------------------
# 登录态（Cookie）模式：默认关闭，需要用户自己提供 Cookie
#   只访问公开的个人主页 HTML，不调用任何需要签名的接口
# ---------------------------------------------------------------------
COOKIE_PLATFORMS = [
    {
        "key": "weibo",
        "name": "微博",
        "identifier": "昵称",
        "url": "https://weibo.com/n/{q}",
        "home": "https://weibo.com/",
        "login_markers": ["Sina Visitor System", "passport.weibo.com", "登录/注册"],
        "notfound_markers": ["用户不存在", "抱歉，此用户不存在"],
        "hint": "浏览器登录微博后，从开发者工具复制 Cookie 请求头（含 SUB）",
    },
    {
        "key": "zhihu",
        "name": "知乎",
        "identifier": "昵称",
        "url": "https://www.zhihu.com/people/{q}",
        "home": "https://www.zhihu.com/",
        "login_markers": ["安全验证", "请登录", "signin"],
        "notfound_markers": ["用户不存在", "页面不存在"],
        "hint": "浏览器登录知乎后复制 Cookie 请求头（需含 z_c0）",
    },
    {
        "key": "tieba",
        "name": "贴吧",
        "identifier": "用户名",
        "url": "https://tieba.baidu.com/home/main?un={q}",
        "home": "https://tieba.baidu.com/",
        "login_markers": ["百度安全验证", "passport.baidu.com"],
        "notfound_markers": ["该用户不存在", "用户不存在"],
        "hint": "浏览器登录百度后复制 Cookie 请求头（需含 BDUSS）",
    },
]

COOKIE_KEYS = {platform["key"] for platform in COOKIE_PLATFORMS}


# ---------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------
def new_session() -> "requests.Session":
    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": UA,
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
        }
    )
    return session


def make_result(platform: dict, status: str, url: str = "", detail: str = "", method: str = "") -> dict:
    return {
        "platform": platform["name"],
        "key": platform["key"],
        "identifier": platform.get("identifier", ""),
        "status": status,
        "status_cn": STATUS_LABEL.get(status, status),
        "url": url,
        "detail": detail,
        "method": method,
    }


def html_text(resp) -> str:
    """按页面真实编码解码。

    requests 对没有 charset 的 text/html 会按 ISO-8859-1 处理，
    直接把 r.text 拿去匹配标题就会得到 ç¨æ·ä¸å¿ 这种乱码。
    """
    try:
        encoding = resp.encoding
        if not encoding or encoding.lower() in ("iso-8859-1", "latin-1"):
            encoding = resp.apparent_encoding or "utf-8"
        return resp.content.decode(encoding, errors="replace")
    except Exception:
        return resp.text or ""


def title_of(html: str) -> str:
    start = html.find("<title>")
    if start == -1:
        return ""
    end = html.find("</title>", start)
    if end == -1:
        return ""
    return " ".join(html[start + 7: end].split())[:60]


# ---------------------------------------------------------------------
# 配置与 Cookie 存取
# ---------------------------------------------------------------------
def load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        return default


def load_config() -> dict:
    config = load_json(CONFIG_FILE, {})
    return config if isinstance(config, dict) else {}


def load_cookies(path: Path = COOKIE_FILE) -> dict:
    data = load_json(path, {})
    if not isinstance(data, dict):
        return {}
    return {str(k): str(v).strip() for k, v in data.items() if isinstance(v, str) and v.strip()}


def save_cookies(cookies: dict, path: Path = COOKIE_FILE) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cookies, ensure_ascii=False, indent=2), encoding="utf-8")
    try:
        import os

        os.chmod(path, 0o600)
    except Exception:
        pass


def mask_cookie(cookie: str) -> str:
    if not cookie:
        return "(空)"
    if len(cookie) <= 12:
        return "***"
    return f"{cookie[:6]}…{cookie[-4:]}（{len(cookie)} 字符）"


def validate_cookie(session, platform: dict, cookie: str, timeout: float) -> tuple[bool, str]:
    """用平台首页判断 Cookie 是否还能用（不保证一定有权限，只排除明显的未登录）"""
    try:
        resp = session.get(platform["home"], headers={"Cookie": cookie}, timeout=timeout, allow_redirects=True)
    except Exception as exc:
        return False, f"请求失败：{type(exc).__name__}"
    body = html_text(resp)
    final_url = (resp.url or "").lower()
    if "passport." in final_url or "visitor" in final_url:
        return False, "被重定向到登录页"
    for marker in platform["login_markers"]:
        if marker in body:
            return False, "页面仍显示登录/验证"
    return True, "已通过登录态验证"


def check_with_cookie(session, platform: dict, username: str, cookies: dict, timeout: float) -> dict:
    url = platform["url"].format(q=quote(username))
    cookie = cookies.get(platform["key"], "")
    if not cookie:
        return make_result(
            platform, "needs_cookie", url,
            f"未配置 Cookie（{platform['hint']}）", "登录态页面",
        )
    try:
        resp = session.get(url, headers={"Cookie": cookie}, timeout=timeout, allow_redirects=True)
    except Exception as exc:
        return make_result(platform, "unknown", url, f"请求失败：{type(exc).__name__}", "登录态页面")

    body = html_text(resp)
    final_url = (resp.url or "").lower()
    if "passport." in final_url or "visitor" in final_url or "login" in final_url:
        return make_result(platform, "unknown", url, "登录态无效或已过期（被重定向到登录页）", "登录态页面")
    for marker in platform["login_markers"]:
        if marker in body:
            return make_result(platform, "unknown", url, "登录态无效或触发风控，请重新获取 Cookie", "登录态页面")
    if resp.status_code == 404:
        return make_result(platform, "available", url, "主页不存在（404）", "登录态页面")
    for marker in platform["notfound_markers"]:
        if marker in body:
            return make_result(platform, "available", url, f"页面提示「{marker}」", "登录态页面")
    if 200 <= resp.status_code < 300:
        page_title = title_of(body)
        detail = "主页可访问（已用本机 Cookie）"
        if page_title:
            detail += f" · {page_title}"
        return make_result(platform, "claimed", url, detail, "登录态页面")
    return make_result(platform, "unknown", url, f"HTTP {resp.status_code}", "登录态页面")


# ---------------------------------------------------------------------
# 抖音：抖音号 -> 公开接口（无需签名）
# ---------------------------------------------------------------------
def check_douyin(session, username: str, timeout: float) -> dict:
    platform = next(p for p in PLATFORMS if p["key"] == "douyin")
    api = "https://www.iesdouyin.com/web/api/v2/user/info/"
    try:
        resp = session.get(api, params={"unique_id": username}, timeout=timeout)
        payload = resp.json()
    except Exception as exc:
        return make_result(platform, "unknown", f"https://www.douyin.com/search/{quote(username)}",
                           f"接口异常：{type(exc).__name__}", "公开接口")

    code = payload.get("status_code")
    if code == 0:
        info = payload.get("user_info") or {}
        nickname = info.get("nickname", "")
        sec_uid = info.get("sec_uid", "")
        followers = info.get("mplatform_followers_count") or info.get("follower_count") or ""
        profile = f"https://www.douyin.com/user/{sec_uid}" if sec_uid else f"https://www.douyin.com/search/{quote(username)}"
        detail = f"昵称 {nickname}"
        if followers != "":
            detail += f" · 粉丝 {followers}"
        return make_result(platform, "claimed", profile, detail, "公开接口")
    if code == 5:
        return make_result(platform, "available", f"https://www.douyin.com/search/{quote(username)}",
                           "该抖音号不存在（或未设置抖音号）", "公开接口")
    return make_result(platform, "unknown", f"https://www.douyin.com/search/{quote(username)}",
                       f"接口返回 status_code={code}", "公开接口")


# ---------------------------------------------------------------------
# B站：昵称 -> 公开搜索接口（需先取 buvid cookie，不是签名）
# ---------------------------------------------------------------------
_BILI_READY = {"ok": False}


def bilibili_session(session, timeout: float) -> bool:
    if _BILI_READY["ok"]:
        return True
    try:
        spi = session.get("https://api.bilibili.com/x/frontend/finger/spi", timeout=timeout).json()
        data = spi.get("data") or {}
        if data.get("b_3"):
            session.cookies.set("buvid3", data["b_3"], domain=".bilibili.com")
        if data.get("b_4"):
            session.cookies.set("buvid4", data["b_4"], domain=".bilibili.com")
        _BILI_READY["ok"] = True
        return True
    except Exception:
        return False


def check_bilibili(session, username: str, timeout: float) -> dict:
    platform = next(p for p in PLATFORMS if p["key"] == "bilibili")
    search_url = f"https://search.bilibili.com/all?keyword={quote(username)}"
    if not bilibili_session(session, timeout):
        return make_result(platform, "unknown", search_url, "获取 buvid cookie 失败", "公开搜索接口")
    try:
        resp = session.get(
            "https://api.bilibili.com/x/web-interface/search/type",
            params={"search_type": "bili_user", "keyword": username},
            headers={"Referer": "https://search.bilibili.com/"},
            timeout=timeout,
        )
        if resp.status_code == 412:
            return make_result(platform, "unknown", search_url, "触发风控（412），建议稍后重试", "公开搜索接口")
        payload = resp.json()
    except Exception as exc:
        return make_result(platform, "unknown", search_url, f"接口异常：{type(exc).__name__}", "公开搜索接口")

    if payload.get("code") != 0:
        return make_result(platform, "unknown", search_url, f"接口返回 code={payload.get('code')}", "公开搜索接口")

    data = payload.get("data") or {}
    results = data.get("result") or []
    exact = [r for r in results if str(r.get("uname", "")).strip() == username.strip()]
    if exact:
        best = max(exact, key=lambda r: int(r.get("fans") or 0))
        mid = best.get("mid")
        detail = f"昵称 {best.get('uname')} · 粉丝 {best.get('fans', '?')}"
        verify = (best.get("official_verify") or {}).get("desc")
        if verify:
            detail += f" · {verify}"
        return make_result(platform, "claimed", f"https://space.bilibili.com/{mid}", detail, "公开搜索接口")

    if results:
        names = "、".join(str(r.get("uname")) for r in results[:3])
        return make_result(platform, "candidate", search_url,
                           f"无精确同名，相近结果：{names}", "公开搜索接口")
    return make_result(platform, "available", search_url, "搜索无结果", "公开搜索接口")


# ---------------------------------------------------------------------
# 豆瓣 / 博客园：按主页 URL 的状态码判定
# ---------------------------------------------------------------------
def check_by_status(session, platform_key: str, username: str, url_template: str, timeout: float) -> dict:
    platform = next(p for p in PLATFORMS if p["key"] == platform_key)
    url = url_template.format(quote(username))
    try:
        resp = session.get(url, timeout=timeout, allow_redirects=True)
    except Exception as exc:
        return make_result(platform, "unknown", url, f"请求失败：{type(exc).__name__}", "主页状态码")

    if resp.status_code == 404:
        return make_result(platform, "available", url, "主页不存在（404）", "主页状态码")
    if resp.status_code in (403, 418, 429, 468):
        return make_result(platform, "unknown", url, f"被风控（{resp.status_code}），需人工确认", "主页状态码")
    if 200 <= resp.status_code < 300:
        page_title = title_of(html_text(resp))
        detail = f"主页可访问（{resp.status_code}）"
        if page_title:
            detail += f" · {page_title}"
        return make_result(platform, "claimed", url, detail, "主页状态码")
    return make_result(platform, "unknown", url, f"HTTP {resp.status_code}", "主页状态码")


# ---------------------------------------------------------------------
# 手动平台：只生成检索入口
# ---------------------------------------------------------------------
def manual_result(platform: dict, username: str) -> dict:
    detail = platform["reason"]
    if platform["key"] in COOKIE_KEYS:
        detail += "；配置 Cookie 后可自动判定"
    return make_result(
        platform,
        "unsupported",
        platform["url"].format(q=quote(username)),
        detail,
        "检索入口",
    )


# ---------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------
def search_one(
    session,
    username: str,
    timeout: float,
    only: list[str] | None = None,
    cookie_mode: bool = False,
    cookies: dict | None = None,
) -> list[dict]:
    results: list[dict] = []
    cookies = cookies or {}

    def want(key: str) -> bool:
        return not only or key in only

    if want("douyin"):
        results.append(check_douyin(session, username, timeout))
        time.sleep(0.2)
    if want("bilibili"):
        results.append(check_bilibili(session, username, timeout))
        time.sleep(0.2)
    if want("douban"):
        results.append(check_by_status(session, "douban", username,
                                       "https://www.douban.com/people/{}/", timeout))
        time.sleep(0.2)
    if want("cnblogs"):
        results.append(check_by_status(session, "cnblogs", username,
                                       "https://www.cnblogs.com/{}/", timeout))
        time.sleep(0.2)

    handled_by_cookie: set[str] = set()
    if cookie_mode:
        for platform in COOKIE_PLATFORMS:
            if not want(platform["key"]):
                continue
            results.append(check_with_cookie(session, platform, username, cookies, timeout))
            handled_by_cookie.add(platform["key"])
            time.sleep(0.2)

    for platform in MANUAL_PLATFORMS:
        if platform["key"] in handled_by_cookie:
            continue
        if want(platform["key"]):
            results.append(manual_result(platform, username))
    return results


def summarize(all_results: list[dict]) -> dict:
    summary = {"usernames": 0, "claimed": 0, "available": 0, "unknown": 0,
               "unsupported": 0, "candidate": 0, "needs_cookie": 0}
    usernames = []
    for entry in all_results:
        usernames.append(entry["username"])
        for item in entry["results"]:
            status = item["status"]
            summary[status] = summary.get(status, 0) + 1
    summary["usernames"] = len(usernames)
    return summary


def render_console(all_results: list[dict], verbose: bool = False) -> None:
    for entry in all_results:
        print(f"\n用户：{entry['username']}")
        print("-" * 78)
        auto = [i for i in entry["results"] if i["status"] != "unsupported"]
        manual = [i for i in entry["results"] if i["status"] == "unsupported"]
        for item in auto:
            print(f"  [{item['status_cn']:<4}] {item['platform']:<8} {item['detail']}")
            if item["url"]:
                print(f"           {item['url']}")
        if manual:
            if verbose:
                for item in manual:
                    print(f"  [{item['status_cn']:<4}] {item['platform']:<8} {item['detail']}")
                    print(f"           {item['url']}")
            else:
                names = "、".join(item["platform"] for item in manual)
                print(f"  [需手动] {names}：未配置登录态，检索入口见下方说明/CSV")


def write_csv(path: Path, all_results: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["username", "platform", "identifier", "status", "status_cn", "url", "detail", "method"])
        for entry in all_results:
            for item in entry["results"]:
                writer.writerow([
                    entry["username"], item["platform"], item["identifier"],
                    item["status"], item["status_cn"], item["url"], item["detail"], item["method"],
                ])


def write_xlsx(path: Path, all_results: list[dict]) -> bool:
    try:
        from openpyxl import Workbook
        from openpyxl.styles import Alignment, Font, PatternFill
    except Exception:
        return False

    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "检索结果"
    headers = ["用户名", "平台", "匹配标识", "结果", "链接", "说明"]
    sheet.append(headers)
    for cell in sheet[1]:
        cell.font = Font(bold=True)
        cell.fill = PatternFill("solid", fgColor="DDEBF7")

    colors = {"claimed": "C6EFCE", "available": "F2F2F2", "unknown": "FFF2CC",
              "candidate": "DDEBF7", "unsupported": "EDEDED", "needs_cookie": "FCE4D6"}
    for entry in all_results:
        for item in entry["results"]:
            sheet.append([
                entry["username"], item["platform"], item["identifier"],
                item["status_cn"], item["url"], item["detail"],
            ])
            row = sheet.max_row
            fill = colors.get(item["status"])
            if fill:
                for cell in sheet[row]:
                    cell.fill = PatternFill("solid", fgColor=fill)
            link_cell = sheet.cell(row=row, column=5)
            if item["url"]:
                link_cell.hyperlink = item["url"]
                link_cell.style = "Hyperlink"
            for cell in sheet[row]:
                cell.alignment = Alignment(vertical="center", wrap_text=True)

    sheet.column_dimensions["A"].width = 16
    sheet.column_dimensions["B"].width = 14
    sheet.column_dimensions["C"].width = 12
    sheet.column_dimensions["D"].width = 10
    sheet.column_dimensions["E"].width = 52
    sheet.column_dimensions["F"].width = 46

    summary_sheet = workbook.create_sheet("说明")
    summary_sheet.append(["平台", "匹配标识", "能否自动检索", "说明"])
    for platform in PLATFORMS:
        summary_sheet.append([platform["name"], platform["identifier"], "是", platform["note"]])
    for platform in COOKIE_PLATFORMS:
        summary_sheet.append([platform["name"], platform["identifier"], "需 Cookie（默认关闭）", platform["hint"]])
    for platform in MANUAL_PLATFORMS:
        if platform["key"] in COOKIE_KEYS:
            continue
        summary_sheet.append([platform["name"], platform["identifier"], "否", platform["reason"]])
    for cell in summary_sheet[1]:
        cell.font = Font(bold=True)
    summary_sheet.column_dimensions["A"].width = 16
    summary_sheet.column_dimensions["B"].width = 12
    summary_sheet.column_dimensions["C"].width = 16
    summary_sheet.column_dimensions["D"].width = 70

    path.parent.mkdir(parents=True, exist_ok=True)
    workbook.save(path)
    return True


def selfcheck(timeout: float) -> int:
    session = new_session()
    cases = [
        ("douyin", "douyin", "claimed"),
        ("bilibili", "碧诗", "claimed"),
        ("douban", "ahbei", "claimed"),
        ("cnblogs", "zhangyong", "claimed"),
    ]
    failures = 0
    print("CN 通道自检")
    print("-" * 60)
    for key, handle, expected in cases:
        if key == "douyin":
            item = check_douyin(session, handle, timeout)
        elif key == "bilibili":
            item = check_bilibili(session, handle, timeout)
        elif key == "douban":
            item = check_by_status(session, "douban", handle, "https://www.douban.com/people/{}/", timeout)
        else:
            item = check_by_status(session, "cnblogs", handle, "https://www.cnblogs.com/{}/", timeout)
        ok = item["status"] == expected
        if not ok:
            failures += 1
        print(f"  [{'OK  ' if ok else 'FAIL'}] {item['platform']:<8} {item['status_cn']:<4} {item['detail']}")
        time.sleep(0.2)
    print("-" * 60)
    print(f"  {len(cases) - failures}/{len(cases)} 个通道可用")
    return 1 if failures else 0


def cmd_set_cookie(args, cookies: dict, path: Path) -> int:
    key = args.set_cookie
    platform = next((p for p in COOKIE_PLATFORMS if p["key"] == key), None)
    if platform is None:
        print(f"未知平台：{key}", file=sys.stderr)
        print("可选：" + ", ".join(p["key"] for p in COOKIE_PLATFORMS), file=sys.stderr)
        return 2
    print(f"粘贴 {platform['name']} 的 Cookie 请求头（{platform['hint']}），回车结束：")
    line = sys.stdin.readline()
    cookie = (line or "").strip()
    if not cookie:
        print("未输入，已取消", file=sys.stderr)
        return 2
    ok, message = validate_cookie(new_session(), platform, cookie, args.timeout)
    print(f"验证：{'通过' if ok else '未通过'} · {message}")
    if not ok and not args.force:
        print("未保存；确认可用可加 --force", file=sys.stderr)
        return 1
    cookies[key] = cookie
    save_cookies(cookies, path)
    print(f"已保存：{path} · {mask_cookie(cookie)}")
    print("提示：Cookie 等同账号登录态，请勿外发；state\\ 已在 .gitignore 中。")
    return 0


def cmd_clear_cookie(args, cookies: dict, path: Path) -> int:
    key = args.clear_cookie
    if key not in cookies:
        print(f"没有保存过 {key} 的 Cookie", file=sys.stderr)
        return 1
    cookies.pop(key, None)
    if cookies:
        save_cookies(cookies, path)
    elif path.exists():
        try:
            path.unlink()
        except Exception:
            pass
    print(f"已删除 {key} 的 Cookie")
    return 0


def cmd_check_cookies(args, cookies: dict) -> int:
    if not cookies:
        print("未配置任何 Cookie；用 --set-cookie weibo 配置")
        return 0
    session = new_session()
    failed = 0
    for platform in COOKIE_PLATFORMS:
        cookie = cookies.get(platform["key"])
        if not cookie:
            print(f"  [--] {platform['name']}：未配置")
            continue
        ok, message = validate_cookie(session, platform, cookie, args.timeout)
        if not ok:
            failed += 1
        print(f"  [{'OK' if ok else 'FAIL'}] {platform['name']}：{message} · {mask_cookie(cookie)}")
        time.sleep(0.2)
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="国内社交平台检索（Sherlock 本地部署）")
    parser.add_argument("usernames", nargs="*", help="要检索的用户名/标识")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument("--csv", help="导出 CSV 路径")
    parser.add_argument("--json", help="导出 JSON 路径")
    parser.add_argument("--xlsx", help="导出 XLSX 路径")
    parser.add_argument("--only", help="只查指定平台，逗号分隔（douyin,bilibili,douban,cnblogs,weibo,...）")
    parser.add_argument("--selfcheck", action="store_true", help="自检各通道是否还能用")
    parser.add_argument("--list", action="store_true", help="列出平台覆盖情况")
    parser.add_argument("--verbose", action="store_true", help="逐个列出只能手动检索的平台")
    parser.add_argument("--cookie-mode", action="store_true", help="启用登录态模式（默认关闭）")
    parser.add_argument("--cookie-file", help="Cookie 文件路径（默认 state\\cookies.json）")
    parser.add_argument("--set-cookie", metavar="PLATFORM", help="配置平台 Cookie（交互粘贴）")
    parser.add_argument("--check-cookies", action="store_true", help="检查已保存 Cookie 是否有效")
    parser.add_argument("--clear-cookie", metavar="PLATFORM", help="删除平台 Cookie")
    parser.add_argument("--force", action="store_true", help="Cookie 验证失败也保存")
    args = parser.parse_args(argv)

    if requests is None:
        print("缺少 requests，请先激活 .venv", file=sys.stderr)
        return 2

    if args.list:
        print("可自动检索（无需登录）：")
        for platform in PLATFORMS:
            print(f"  - {platform['name']}（{platform['identifier']}）：{platform['note']}")
        print("需 Cookie 模式（默认关闭）：")
        for platform in COOKIE_PLATFORMS:
            print(f"  - {platform['name']}（{platform['identifier']}）：{platform['hint']}")
        print("只能手动检索：")
        for platform in MANUAL_PLATFORMS:
            if platform["key"] in COOKIE_KEYS:
                continue
            suffix = f"（{platform['identifier']}）" if platform['identifier'] else ""
            print(f"  - {platform['name']}{suffix}：{platform['reason']}")
        return 0

    if args.selfcheck:
        return selfcheck(args.timeout)

    cookie_path = Path(args.cookie_file) if args.cookie_file else COOKIE_FILE
    cookies = load_cookies(cookie_path)

    if args.set_cookie:
        return cmd_set_cookie(args, cookies, cookie_path)
    if args.clear_cookie:
        return cmd_clear_cookie(args, cookies, cookie_path)
    if args.check_cookies:
        return cmd_check_cookies(args, cookies)

    if not args.usernames:
        parser.print_help()
        return 2

    only = None
    if args.only:
        only = [part.strip() for part in args.only.split(",") if part.strip()]

    cookie_mode = bool(args.cookie_mode or load_config().get("cookieMode"))
    if cookie_mode and not cookies:
        print("提示：已启用 Cookie 模式，但还没有配置任何 Cookie（--set-cookie weibo）。")

    session = new_session()
    all_results = []
    for username in args.usernames:
        username = username.strip()
        if not username:
            continue
        all_results.append({
            "username": username,
            "results": search_one(session, username, args.timeout, only, cookie_mode, cookies),
        })

    render_console(all_results, args.verbose)

    summary = summarize(all_results)
    print()
    print("统计：" + " · ".join(
        f"{STATUS_LABEL[k]} {summary.get(k, 0)}"
        for k in ("claimed", "candidate", "available", "unknown", "needs_cookie", "unsupported")
    ))
    if cookie_mode:
        print("说明：已启用 Cookie 模式（本机登录态）；结果仍只代表该标识在该主页存在。")
    else:
        print("说明：命中只代表该标识在该平台存在；微博/知乎/贴吧 可配置 Cookie 自动判定，其余请点检索入口人工确认。")

    payload = {
        "generatedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "summary": summary,
        "results": all_results,
    }
    if args.json:
        path = Path(args.json)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"JSON: {path}")
    if args.csv:
        path = Path(args.csv)
        write_csv(path, all_results)
        print(f"CSV : {path}")
    if args.xlsx:
        path = Path(args.xlsx)
        if write_xlsx(path, all_results):
            print(f"XLSX: {path}")
        else:
            print("XLSX: 生成失败（openpyxl 不可用）", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
