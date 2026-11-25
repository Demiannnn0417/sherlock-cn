# Sherlock-CN：本地化部署 + 国内平台模式

基于 [sherlock-project/sherlock](https://github.com/sherlock-project/sherlock) v0.16.2 的本地部署版本，
默认面向国内平台：**抖音 / B站 / 豆瓣 / 博客园**可自动判定，**微博 / 知乎 / 贴吧**支持可选的 Cookie 模式，
**微信 / 小红书 / 快手**只给检索入口（不做假装能查）。

> ⚠️ 仅用于授权范围内的公开信息自查、品牌保护与公开研究。
> 请遵守各平台用户协议与当地法律法规，不要用于人肉搜索、跟踪、骚扰或大规模自动化查询。

## 特性

- **国内模式（默认）**：抖音号、B站昵称、豆瓣ID、博客园用户名 自动判定；
  微博/知乎/贴吧 可按需启用登录态（Cookie）页面判定；其余平台给带关键词的检索入口。
- **全站模式**：上游 Sherlock 的 481 个站点，支持代理自动探测。
- **Cookie 模式始终默认关闭**：只读取公开个人主页 HTML，不调用需要 `X-S` / `a_bogus` 签名的接口，
  不做验证码绕过；Cookie 存在本机 `state\cookies.json`，不随仓库分发。
- **可观测**：每次运行写 `logs\*.log`；`doctor.ps1` 体检 13 项；`selftest.ps1` 真跑一次查询做断言。
- **Windows 友好**：纯 PowerShell 5.1 兼容，桌面快捷方式入口，结果自动保存 CSV/XLSX 到桌面。

## 平台覆盖

| 平台 | 自动判定 | 匹配依据 | 判定方式 |
| --- | --- | --- | --- |
| 抖音 | ✅ | 抖音号 | 公开接口，存在 `status_code=0`，不存在 `=5` |
| B站 | ✅ | 昵称（精确同名） | `buvid` cookie + 公开搜索接口 |
| 豆瓣 | ✅ | 豆瓣ID | `/people/<ID>/` 404 / 200 |
| 博客园 | ✅ | 用户名 | `/<用户名>/` 404 / 200 |
| 微博 | 🔐 Cookie 模式 | 昵称 | 登录态下读 `/n/<昵称>` 页面 |
| 知乎 | 🔐 Cookie 模式 | 昵称 | 登录态下读 `/people/<slug>` |
| 贴吧 | 🔐 Cookie 模式 | 用户名 | 登录态下读 `home/main?un=` |
| 小红书 | ❌ | 昵称 | 搜索接口需登录态 + `X-S` 签名，网页端登录墙 |
| 微信 | ❌ | 微信号 | 个人号无公开主页、无公开检索接口 |
| 快手 | ❌ | 昵称 | 无公开用户检索接口 |

命中只代表"该标识在该平台存在"，**同名不等于同一个人**。

## 快速开始（Windows）

要求：Windows 10/11、Windows PowerShell 5.1、Python 3.12（用于创建虚拟环境）。

```powershell
git clone https://github.com/<你的账号>/<仓库名>.git
cd <仓库名>

# 1) 建虚拟环境（用你本机的 Python 3.12）
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .

# 2) 体检 + 自检
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\selftest.ps1        # 国内模式
powershell -NoProfile -ExecutionPolicy Bypass -File .\selftest.ps1 -Mode all

# 3) 用起来
.\sherlock-cn.cmd douyin                 # 国内模式
.\sherlock.cmd test --site GitLab        # 全站模式
```

桌面快捷方式与「双击输入用户名」的入口见 `LOCAL-DEPLOY.md` 第 14 节。

## 常用命令

```bat
sherlock-cn.cmd <用户名>                  :: 国内模式：4 个自动平台 + 手动入口
sherlock-cn.cmd <用户名> --only douyin,douban
sherlock-cn.cmd --selfcheck               :: 4 个通道是否还通
sherlock-cn.cmd --list                    :: 平台覆盖

sherlock-cn.cmd --set-cookie weibo        :: 配置登录态（默认关闭）
sherlock-cn.cmd --check-cookies
sherlock-cn.cmd <用户名> --cookie-mode

sherlock.cmd <用户名> --site GitLab --print-found   :: 全站模式
```

## 目录

```
.
├─ run-sherlock.ps1     桌面快捷方式入口（国内/全部模式 + 设置菜单）
├─ sherlock-cn.cmd      国内模式命令行入口
├─ sherlock.cmd         全站模式命令行入口
├─ doctor.ps1           体检（13 项）
├─ selftest.ps1         自检（国内 / 全站两种模式）
├─ lib/
│  ├─ cn_search.py      国内平台检索器
│  ├─ proxy_probe.py    代理探测（全站模式）
│  ├─ run_sherlock.py   stderr 合并的运行壳
│  └─ common.ps1        公共函数
├─ sherlock_project/    上游源码（sites.py 含离线站点库回退补丁）
├─ LOCAL-DEPLOY.md      部署说明（含原理、限制、迁移记录）
├─ IMPROVEMENTS.md      改进建议与落地进度
└─ state/ logs/         本机运行时目录（已 gitignore）
```

## 说明

- 本项目是个人本地部署，`LOCAL-DEPLOY.md` / `IMPROVEMENTS.md` 里记录的是作者本机的路径与验证数据，
  换机器时按文档替换路径即可。
- 国内平台接口会随平台改版失效，用 `sherlock-cn.cmd --selfcheck` 可快速确认通道是否还通。
- 上游版权归 [sherlock-project](https://github.com/sherlock-project/sherlock)，本仓库同样以 MIT 协议发布。

## License

MIT，见 [LICENSE](LICENSE)。
