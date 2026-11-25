# Sherlock 本地部署说明

> 上游项目：<https://github.com/sherlock-project/sherlock>（MIT License）
> 本机部署版本：**v0.16.2**（master 源码，2026-11-25 获取）
> 部署位置：`%USERPROFILE%\SherlockOSINT\sherlock`
> 最近更新：2026-11-25 第五批 —— 自带独立 Python 运行时（`runtime\python`），虚拟环境不再依赖 DSH / C 盘；`doctor` 13 项全绿

---

## 1. 部署结果一览

| 项目 | 内容 |
| --- | --- |
| 安装位置 | `%USERPROFILE%\SherlockOSINT\sherlock`（系统盘只留一个快捷方式） |
| 运行模式 | **国内（默认）** / 全部（Sherlock 481 站点），设置菜单第 0 项切换 |
| Cookie 模式 | **默认关闭**；开启后微博 / 知乎 / 贴吧 用本机登录态判定，配置见 3.5 |
| 国内模式 | `lib\cn_search.py`：抖音号、B站昵称、豆瓣ID、博客园用户名 自动判定；其余平台给检索入口 |
| 全部模式 | 上游 Sherlock，481 站点，代理自动探测 |
| 源码 | 从 `codeload.github.com` 下载（本机无法直连 `github.com:443`） |
| Python | 3.12.14，来自 `%USERPROFILE%\SherlockOSINT\runtime\python`（独立运行时，不依赖 DSH） |
| 虚拟环境 | `sherlock\.venv`（由 runtime Python 创建，隔离，Sherlock 以可编辑模式装入） |
| 启动入口 | 桌面 `Sherlock` 快捷方式、`sherlock-cn.cmd`（国内）、`sherlock.cmd`（全部）、`run-sherlock.ps1` |
| 日志 | 每次运行写 `logs\<mode>-<时间戳>.log`（UTF-8） |

目录结构（只列关键项）：

```
sherlock\
├─ run-sherlock.ps1              ← 桌面快捷方式入口（国内/全部两种模式 + 设置菜单）
├─ sherlock-cn.cmd               ← 国内模式命令行入口（ASCII only）
├─ sherlock.cmd                  ← 全部模式命令行入口（ASCII only）
├─ doctor.ps1                    ← 体检：解释器/补丁/站点库/代理/国内通道/桌面/快捷方式
├─ selftest.ps1                  ← 自检：国内 4 通道 + 真实检索（-Mode all 走 GitLab）
├─ sherlock.ico                  ← 快捷方式图标
├─ LOCAL-DEPLOY.md               ← 本文件
├─ IMPROVEMENTS.md               ← 改进建议与落地进度
├─ lib\
│  ├─ cn_search.py               ← 国内平台检索器（本批新增，核心）
│  ├─ common.ps1                 ← 公共函数（编码、代理、日志、进程封装、统计）
│  ├─ proxy_probe.py             ← 代理探测（仅全站模式使用）
│  └─ run_sherlock.py            ← 运行壳：stderr 并入 stdout
├─ logs\                         ← 运行日志
├─ state\                        ← config.json / 代理缓存 / 代理环境脚本
├─ .venv\                        ← 虚拟环境
├─ sherlock_project\             ← 上游源码（含离线站点库补丁）
└─ tests\ devel\ docs\ ...       ← 上游测试与文档
```

### 1.1 工作区与备份

项目不再放在 DSH 会话目录里（那个目录随时可能被清理），而是迁到了独立工作区：

```
%USERPROFILE%\SherlockOSINT\
├─ sherlock\        ← 项目本体（本文件所在位置）
├─ runtime\python\  ← 独立 CPython 3.12.14（51 MB，项目专用）
├─ backups\         ← 快照：源码、脚本、配置、运行时（不含 .venv、日志、Cookie）
└─ WORKSPACE.md     ← 工作区说明：备份/恢复/迁移记录
```

* 整个项目（含 137 MB 虚拟环境）都在 D 盘，C 盘只保留桌面快捷方式；
* 备份与恢复见第 16 节；`state\cookies.json` 属于登录凭据，**不进备份**、不随意外发。

---

## 2. 快速开始

**双击桌面 `Sherlock`** → 输入用户名 / 抖音号 / 豆瓣ID → 回车，结果自动存桌面。

```
   ============================================================
      Sherlock  v0.16.2   ·   国内用户名账号检索
      抖音 / B站 / 豆瓣 / 博客园 自动 · 微博 / 小红书 / 微信 给入口
      结果保存到桌面 · 仅限合法授权用途
   ============================================================
      代理：国内模式直连（不使用代理）
```

输入 `?` 进设置：`0` 切国内/全部、`1` 平台或站点过滤、`2` 超时、`3` 代理、`4` 保存位置。
命令行：

```bat
:: 国内模式（默认 4 个自动平台 + 手动入口）
sherlock-cn.cmd douyin
sherlock-cn.cmd douyin ahbei --csv out.csv --xlsx out.xlsx
sherlock-cn.cmd ahbei --only douyin,douban      :: 只查指定平台
sherlock-cn.cmd --selfcheck                     :: 自检 4 个通道
sherlock-cn.cmd --list                          :: 看平台覆盖

:: 全部模式（Sherlock 481 站点）
sherlock.cmd john --site GitLab --print-found
```

结果文件：

```
%USERPROFILE%\Desktop\SherlockCN_<用户名>_<yyyyMMdd_HHmmss>.csv
%USERPROFILE%\Desktop\SherlockCN_<用户名>_<yyyyMMdd_HHmmss>.xlsx
```

CSV 字段：`username,platform,identifier,status,status_cn,url,detail,method`；
`status` 为 `claimed`（命中）/ `candidate`（有同名候选）/ `available`（未注册）/
`unknown`（未验证）/ `unsupported`（需手动）。XLSX 第二张表是平台说明。

---

## 3. 国内模式：能查什么、查不了什么

这一节是这次改造的核心，也是**必须先看清的部分**——国内平台能匿名判定的很少，
工具只对能判定的给结论，判不了的一律给检索入口，不会假装查到。

### 3.1 覆盖矩阵（2026-11-25 实测）

| 平台 | 自动判定 | 匹配依据 | 方法 / 证据 |
| --- | --- | --- | --- |
| **抖音** | ✅ | 抖音号（不是昵称） | 公开接口 `iesdouyin/user/info`：存在返回 `status_code=0` + 昵称/粉丝/`sec_uid`，不存在返回 `status_code=5` |
| **B站** | ✅ | 昵称（精确同名） | 先取 `buvid` cookie（`/x/frontend/finger/spi`），再调公开搜索接口；返回 `uname/mid/fans/认证`，无结果时 `numResults=0` |
| **豆瓣** | ✅ | 豆瓣ID | `/people/<ID>/`：404=未注册，200=存在（实测 `ahbei`→阿北，随机串→404） |
| **博客园** | ✅ | 用户名 | `/<用户名>/`：404=未注册，200=存在 |
| 微博 | ❌ 需手动 | 昵称 | 匿名请求一律 302 到 `passport.weibo.com/visitor`（Sina Visitor System），`m.weibo.cn` 同样；`ajax/profile/info` 直接 403 |
| 小红书 | ❌ 需手动 | 昵称 | 匿名访问 302 到 `rednote.com/login`；搜索接口要求登录态 + `X-S` 签名 |
| 微信 | ❌ 需手动 | 微信号 | 个人微信**没有**公开主页或公开检索接口；只能查公众号（搜狗入口，且常要验证码） |
| 知乎 | ❌ 需手动 | 昵称 | `/people/` 与 `api/v4/members` 均 403，搜索页 403 |
| 贴吧 | ❌ 需手动 | 用户名 | 触发「百度安全验证」403 |
| 快手 | ❌ 需手动 | 昵称 | 无公开用户检索接口，页面为前端渲染 |
| 抖音（昵称） | ❌ 需手动 | 昵称 | 昵称不能拼成 URL，只能人工看搜索结果 |

**没进自动列表的还有**：V2EX（Cloudflare 403）、CSDN（521）、SegmentFault（468）、
开源中国（SPA 同页）、少数派（SPA 同页）、什么值得买（主页 404 恒定）、简书（用户主页改版）——
都是实测过、判定不可靠，所以不放进来自欺欺人。

### 3.2 三个必须知道的前提

1. **匹配依据不同**：抖音要**抖音号**（很多账号没设，只有昵称）、豆瓣要**豆瓣ID**（不是昵称）、
   B站按**昵称精确匹配**、博客园按用户名。用同一个字符串去查，各平台含义并不相同。
2. **同名 ≠ 同一个人**：工具只回答"这个标识在该平台是否存在"。B站会给粉丝数和认证信息做参考，
   需要人工判断；`candidate` 状态表示"没有精确同名，但有相近结果"。
3. **接口会变**：抖音、B站用的是公开 Web 接口（不是官方开放平台 API），平台改版就可能失效。
   所以每次运行后如果发现某平台总是"未验证"，先跑 `sherlock-cn.cmd --selfcheck` 看通道是否还通。

### 3.3 手动入口怎么用

对微博、小红书、微信、知乎、贴吧、快手，结果表里会给一条带关键词的检索链接
（`state` 里的 CSV/XLSX 都可点击），点开就是平台的搜索页，人工确认即可。
微信一栏给的是搜狗公众号入口——个人微信号无从检索，这是客观限制，不是工具偷懒。

### 3.4 为什么不做「自动登录 + 签名接口」

- 微博/小红书/知乎要登录 Cookie 或签名参数（`X-S`、`a_bogus`），这类接口属于平台的风控边界，
  自动化调用既不稳定也可能违反用户协议；
- 微信没有任何公开接口，技术上做不到；
- 本工具的定位是"授权范围内的公开信息自查"，不是爬虫。需要更强能力时，
  应走平台官方开放平台（需要企业资质与授权），而不是在本地破解签名。

---

### 3.5 登录态（Cookie）模式：默认关闭的可选开关

匿名查不了的微博、知乎、贴吧，在**你自己已登录**的前提下，可以用本机 Cookie 读取公开主页。
这个能力默认关闭，三层开关：`config.json` 的 `cookieMode`、设置菜单第 6 项、命令行 `--cookie-mode`。

```bat
:: 1) 配置（交互粘贴 Cookie 请求头，会先验证登录态）
sherlock-cn.cmd --set-cookie weibo
sherlock-cn.cmd --set-cookie zhihu
sherlock-cn.cmd --set-cookie tieba

:: 2) 检查是否还有效
sherlock-cn.cmd --check-cookies

:: 3) 开启后查询（也可只开一次）
sherlock-cn.cmd <用户名> --cookie-mode

:: 4) 不用了
sherlock-cn.cmd --clear-cookie weibo
```

实现边界（重要）：

* 只请求**公开个人主页 HTML**（`weibo.com/n/<昵称>`、`zhihu.com/people/<slug>`、`tieba.baidu.com/home/main?un=`），
  **不调用**需要 `X-S` / `a_bogus` 签名的接口，不做验证码绕过；
* 结果状态：`需Cookie`（未配置）、`未验证`（Cookie 失效/被风控）、`命中`/`未注册`（页面判定）；
* Cookie 保存在 `state\cookies.json`（已在 `.gitignore` 中），等同账号登录态，**不要外发、不要进备份**；
* 小红书仍不支持：即使有 Cookie，搜索接口还要签名、网页端是登录墙；微信个人号没有任何公开入口；
* 默认关闭的原因：登录态查询依赖你的账号、受平台风控影响，失败还会白跑一次请求——需要时手动开即可。

---

## 4. 全部模式（上游 Sherlock）

设置菜单第 0 项切到「全部」，或命令行：

```bat
sherlock.cmd john
sherlock.cmd john --site GitLab --site GitHub --print-found
sherlock.cmd john --csv --xlsx -fo output
```

全部模式仍会自动探测本机代理（见第 6 节），481 个站点里相当一部分在境内不可达，
未验证会记成 `Unknown`，不代表"没注册"。

---

## 5. 常用参数

**国内模式 `cn_search.py` / `sherlock-cn.cmd`**

| 参数 | 作用 |
| --- | --- |
| `--only douyin,douban` | 只查指定平台（键名见 `--list`） |
| `--csv` / `--json` / `--xlsx` | 导出结果 |
| `--timeout N` | 单请求超时秒数（默认 10） |
| `--selfcheck` | 自检 4 个自动通道 |
| `--list` | 列出平台覆盖情况 |
| `--verbose` | 逐个列出只能手动检索的平台 |
| `--cookie-mode` | 本次查询启用登录态模式（默认关闭） |
| `--set-cookie weibo` | 交互配置平台 Cookie（写入 `state\cookies.json`） |
| `--check-cookies` | 检查已保存 Cookie 是否仍有效 |
| `--clear-cookie weibo` | 删除平台 Cookie |

**全部模式（Sherlock 原生参数）**

| 参数 | 作用 |
| --- | --- |
| `--site NAME` | 只查指定站点，可重复 |
| `--print-found` / `--print-all` | 只显示命中 / 显示全部 |
| `--timeout N` | 单站点超时 |
| `--csv` / `--xlsx` / `-fo DIR` / `-o FILE` | 导出 |
| `--proxy URL` | 手动代理（一般不用，自动探测） |
| `--local` | 强制用内置站点库 |

---

## 6. 代理：自动探测（仅全站模式）

国内模式固定直连（国内平台走代理反而更慢）；全站模式按「配置 → 环境变量 → 注册表 →
常见端口」探测，并用真实请求验证，分 strong / weak / none 三档。拿到代理后同时设置
`--proxy` 与 `HTTPS_PROXY`（后者让站点库、排除列表也能加载）。

```jsonc
// state\config.json
"proxy": "auto"        // 自动
"proxy": "off"         // 直连
"proxy": "http://127.0.0.1:7890"
```

---

## 7. 本机网络现状（2026-11-25）

* 国内平台（抖音、B站、豆瓣、博客园、微博、小红书…）**直连可达**，但风控各有不同（见第 3 节）
* 直连 `github.com`、`data.sherlockproject.xyz`、`raw.githubusercontent.com` 时通时断
* 本机 `127.0.0.1:7890` 代理可访问被阻断站点（`github.com`、`x.com`、`instagram.com` 等）
* 站点可达率抽样（24 个随机站点）：直连 16/24，走代理 23/24

---

## 8. 运行日志与自检

**日志**：`logs\cn-*.log`（国内）/ `logs\run-*.log`（全部）/ `logs\selftest-*.log`，
含模式、代理、用户名、完整命令、输出、退出码、耗时、统计、保存路径。

**体检**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1
```

12 项：项目文件、解释器、Sherlock 包、本地补丁、站点库、代理探测、**国内通道**、桌面可写、
快捷方式、日志目录、运行环境、磁盘空间。支持 `-Json`、`-Refresh`，有 FAIL 时退出码 1。

**自检**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\selftest.ps1            # 国内模式（默认）
powershell -NoProfile -ExecutionPolicy Bypass -File .\selftest.ps1 -Mode all  # 全部模式
```

国内模式跑：4 通道自检 + 抖音号 `douyin` 真实检索 + JSON/CSV/XLSX/日志校验；
网络原因查不到只报 `WARN`，不误报 `FAIL`。

---

## 9. 配置文件 `state\config.json`

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `mode` | `"cn"` | `cn` 国内 / `all` 全部 |
| `proxy` | `"auto"` | 仅全站模式：`auto` / `off` / URL |
| `timeout` | `15` | 单请求超时秒数 |
| `sites` | `""` | 国内模式=平台过滤（如 `douyin,douban`）；全部模式=站点过滤；空=全部 |
| `saveToDesktop` | `true` | `true` 桌面；`false` `results\<时间戳>\` |
| `cookieMode` | `false` | **默认关闭**；开启后微博/知乎/贴吧 用本机 Cookie 判定 |
| `keepResults` | `20` | 预留：结果保留份数（当前未启用自动清理） |

Cookie 单独存在 `state\cookies.json`（键为 `weibo` / `zhihu` / `tieba`，值为 Cookie 请求头原文），
不写进 `config.json`，也不进备份；`--set-cookie` 会先做一次登录态验证再保存。

---

## 10. 对上游源码的本地补丁（全部模式必须保留）

**文件**：`sherlock_project\sites.py`。上游启动时先请求 `https://data.sherlockproject.xyz`
拉在线站点库，本机连不上会直接退出；补丁把它包在 try 里，失败时回退到包内
`resources\data.json`（481 站点），与 `--local` 行为一致。`doctor.ps1` 会显示
`sites.py sha256:...` 以确认补丁还在。

> 运行时的独立性（2026-11-25 已完成）：`.venv` 由 `%USERPROFILE%\SherlockOSINT\runtime\python\python.exe` 创建，
> `pyvenv.cfg` 的 `home` 指向该目录，**不再引用 DSH 或 C 盘**；`doctor.ps1` 的「Python 解释器」项显示
> 解释器来源，只要不在 `C:\Users\...` 下即为独立运行。

---

## 11. 更新到最新版

```powershell
$ws = "%USERPROFILE%\SherlockOSINT"
$tmp = "$env:TEMP\sherlock-latest.tar.gz"
Invoke-WebRequest "https://codeload.github.com/sherlock-project/sherlock/tar.gz/refs/heads/master" -OutFile $tmp

Copy-Item "$ws\sherlock\sherlock_project\sites.py" "$env:TEMP\sites.py.bak"   # 备份补丁
Remove-Item "$ws\sherlock\sherlock_project" -Recurse -Force
tar -xzf $tmp -C $env:TEMP
Copy-Item "$env:TEMP\sherlock-master\sherlock_project" "$ws\sherlock\" -Recurse -Force
Copy-Item "$env:TEMP\sherlock-master\pyproject.toml" "$ws\sherlock\" -Force
Copy-Item "$env:TEMP\sites.py.bak" "$ws\sherlock\sherlock_project\sites.py" -Force

& "$ws\sherlock\.venv\Scripts\python.exe" -m pip install -e "$ws\sherlock"
powershell -NoProfile -ExecutionPolicy Bypass -File "$ws\sherlock\doctor.ps1"
```

`lib\`、`doctor.ps1`、`selftest.ps1`、`run-sherlock.ps1`、`sherlock*.cmd` 不在上游源码包内，
更新不会被覆盖。

---

## 12. 卸载 / 重装

* **卸载**：删除 `sherlock` 目录与桌面 `Sherlock.lnk`（虚拟环境、日志、配置都在目录内，不写注册表）。
* **重装**：

```powershell
$ws = "%USERPROFILE%\SherlockOSINT\sherlock"
$py = "%USERPROFILE%\SherlockOSINT\runtime\python\python.exe"
& $py -m venv "$ws\.venv"
$env:PIP_CACHE_DIR = "$ws\.pip-cache"; $env:TEMP = "$ws\.tmp"
& "$ws\.venv\Scripts\python.exe" -m pip install -e "$ws"
```

> 依赖安装若报 `[WinError 5] 拒绝访问: ...appdata\local\pip`，按上面把 `PIP_CACHE_DIR` / `TEMP`
> 指到工作目录即可。

---

## 13. 验证记录（模板）

部署、迁移或升级后，跑下面两组检查并把结果填进「本次结果」列。`doctor.ps1` / `selftest.ps1`
会自动给出大部分结论，不需要手工逐站点试。

### 13.1 基础检查

| 检查项 | 方法 | 期望 | 本次结果 |
| --- | --- | --- | --- |
| 项目文件 | `doctor.ps1` 第 1 项 | `pyproject.toml` / `sherlock.py` / `data.json` 齐全 | ☐ |
| 安装位置 | `doctor.ps1` 第 2 项 | 不在 `C:\Users` 下（避免会话目录被清理） | ☐ |
| Python 解释器 | `doctor.ps1` 第 3 项 | 版本 ≥ 3.9，且来源不在 `C:\Users` | ☐ |
| Sherlock 包 | `doctor.ps1` 第 4 项 | 可 import，版本与 `pyproject.toml` 一致 | ☐ |
| 本地补丁 | `doctor.ps1` 第 5 项 | 显示 `sites.py sha256:...` | ☐ |
| 站点库 | `doctor.ps1` 第 6 项 | ≥ 450 个站点 | ☐ |
| 代理（全站模式） | `doctor.ps1` 第 7 项 | 有可用代理或明确直连 | ☐ |
| 国内通道 | `doctor.ps1` 第 8 项 | `sherlock-cn.cmd --selfcheck` 返回 4/4 | ☐ |
| 桌面可写 | `doctor.ps1` 第 9 项 | 能创建/删除临时文件 | ☐ |
| 快捷方式 | `doctor.ps1` 第 10 项 | 指向当前 `run-sherlock.ps1` | ☐ |
| 日志目录 | `doctor.ps1` 第 11 项 | 可写 | ☐ |

### 13.2 功能抽查

| 场景 | 命令 | 期望 | 本次结果 |
| --- | --- | --- | --- |
| 国内模式自检 | `selftest.ps1` | 4 个通道 + 真实检索全部通过 | ☐ |
| 全站模式自检 | `selftest.ps1 -Mode all` | GitLab 命中，CSV/XLSX 正常 | ☐ |
| 桌面入口 | 双击 `Sherlock` 快捷方式 → 输入用户名 | 出结果并保存 CSV/XLSX 到桌面 | ☐ |
| 国内模式（自动） | `sherlock-cn.cmd <抖音号>` | 抖音命中，豆瓣/博客园按 ID 判定 | ☐ |
| 国内模式（手动入口） | 同上，看 `unsupported` 行 | 微博/小红书/微信等给出可点链接 | ☐ |
| Cookie 模式（可选） | `--set-cookie weibo` → `--check-cookies` | 有效时显示"通过"，失效时给出提示 | ☐ |
| 全部模式 | `sherlock.cmd <用户名> --site GitLab` | 命中或明确 `Timeout`，不崩溃 | ☐ |

> 说明：`selftest.ps1` 在网络原因查不到时给 `WARN` 而不是 `FAIL`，以它的汇总结果为准；
> 任何 `FAIL` 都应对照 `logs\` 里的日志先定位，再重跑。

---

## 14. 桌面快捷方式

| 项目 | 内容 |
| --- | --- |
| 位置 | `%USERPROFILE%\Desktop\Sherlock.lnk` |
| 目标 | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` |
| 参数 | `-NoProfile -ExecutionPolicy Bypass -File "...\sherlock\run-sherlock.ps1"` |
| 起始位置 | `%USERPROFILE%\SherlockOSINT\sherlock` |
| 图标 | `...\sherlock\sherlock.ico` |

说明：

* 快捷方式调用的脚本按 `state\config.json` 的 `mode` 决定国内/全部；默认国内。
* 结果先落在 `.last-run`，再复制到桌面，最后清理临时目录；`-KeepRunDir` 可保留临时目录排查。
* 双击后窗口一闪而过，先跑 `doctor.ps1`；仍失败就在 `sherlock` 目录执行
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\run-sherlock.ps1` 看报错。

---

## 15. 合规提醒

国内模式只做两类事：读取**公开可访问**的个人主页 / 公开搜索接口，或给出**公开检索入口**。
请仅用于授权范围内的自查、品牌保护、公开信息研究：

* 遵守《个人信息保护法》《网络安全法》与各平台用户协议，不要用于人肉搜索、跟踪、骚扰或大规模画像；
* 不要高频批量查询（工具本身是串行 + 0.2 秒间隔，请不要改成并发轰炸）；
* 命中结果只代表"该标识存在"，同名同号不等于同一个人；
* `logs\` 与桌面结果包含查询过的账号标识，属于个人信息，按需清理、不要外发；
* `state\cookies.json` 等同账号登录态，泄露即等于账号被登录；不要截图、不要提交、不要放进备份或云盘，不用时 `--clear-cookie` 删除；
* 微信个人号无公开检索途径；微博/小红书等请通过页面人工确认，不要尝试绕过登录或风控。

---

## 16. 备份与恢复

工作区 `backups\` 里保存两份快照：

* `sherlock-src-*.zip`：源码 + 脚本 + 配置（**不含** `.venv`、`logs`、`.last-run`、`state\cookies.json`）；
* `python-runtime-3.12.14-win64.zip`：运行时 Python（约 19 MB），用于完全离线重建。

生成源码快照：

```powershell
$root = "%USERPROFILE%\SherlockOSINT"
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$zip = "$root\backups\sherlock-$stamp.zip"
$items = @('run-sherlock.ps1','doctor.ps1','selftest.ps1','sherlock.cmd','sherlock-cn.cmd',
           'sherlock.ico','LOCAL-DEPLOY.md','IMPROVEMENTS.md','pyproject.toml','lib',
           'sherlock_project','state\config.json')
$tmp = Join-Path $env:TEMP "sherlock-backup-$stamp"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
foreach ($item in $items) { Copy-Item (Join-Path "$root\sherlock" $item) $tmp -Recurse -Force }
Compress-Archive -Path "$tmp\*" -DestinationPath $zip -Force
Remove-Item $tmp -Recurse -Force
"备份完成：$zip"
```

恢复：解压到 `%USERPROFILE%\SherlockOSINT\sherlock`，重建虚拟环境（第 12 节），
再跑 `sherlock-cn.cmd --selfcheck` 与 `doctor.ps1`。不含 `.venv` 是刻意的——虚拟环境跨机器/跨路径不可靠，重建更干净。

---
