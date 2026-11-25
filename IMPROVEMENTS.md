# Sherlock 本地部署 · 改进建议

> 复盘对象：会话 `session-e467d8c3-d69e-4db6-bd28-ddf48cb10774`（2026-11-25，共 6 轮：部署 → 桌面快捷方式 → 怎么搜索 → 怎么保存 → 保存到桌面）。
> 另外在 2026-11-25 12:50 之后对当前机器做了一轮复测，文中标「复测」的数字都来自那次实测。
> 这是**建议书 + 落地记录**：第 0.1 节是已完成的部分，其余按优先级排列。

---

## 0. 结论先行

现在这套部署**能用**，但它建立在三个隐形假设上：DSH 自带的 Python 一直在、`default-workspace` 目录不被清理、手工补丁不丢。这三个假设迟早会破，破了就是"昨天还能用，今天双击没反应"。

比"再加功能"更值钱的是三件事，按收益排序：

| 顺序 | 改什么 | 一句话理由 |
| --- | --- | --- |
| 1 | **把本机代理自动接管** | 复测：同一批站点直连 16/24 可达，走 `127.0.0.1:7890` 后 23/24；`github.com`、`x.com`、`instagram.com`、`reddit.com`、`tiktok.com` 从超时变 200。这是"能不能查到"的分水岭 |
| 2 | **运行底座与 DSH 解耦、搬出会话工作区** | `.venv` 的解释器路径写死在 `~/.dsh/dsh-runtimes/...`；项目又放在会被重建的 workspace 里 |
| 3 | **交互收成 1 步、结果变成报告** | 用户连问"输入用户名之后怎么搜索""如何保存结果""能否直接保存到桌面"——这不是用户不会用，是入口设计要求他先学会命令行 |

其余 9 项在下面分组展开，每项都带"现状证据 / 做法 / 验收 / 改动量"。

### 0.1 落地进度（2026-11-25 第二批）

| 项 | 状态 | 落地说明 |
| --- | --- | --- |
| **B1 代理自动接管** | ✅ 完成 | `lib\proxy_probe.py`：注册表（忽略 ProxyEnable）+ 环境变量 + 7 个常见端口，逐个做真实 HTTPS 验证；启动器与 `sherlock.cmd` 双入口都生效；同时设 `HTTPS_PROXY`，站点库/排除列表不再回退 |
| **D1 doctor / selftest** | ✅ 完成 | `doctor.ps1` 11 项体检、`selftest.ps1` 5 项真实查询断言，均支持 `-Json`，退出码可用于脚本判断 |
| **D2 运行日志** | ✅ 完成 | 每次运行写 `logs\run-<时间戳>.log`（UTF-8），含命令行、代理、输出、统计、保存路径 |
| **D3 编码统一** | ✅ 完成 | `chcp 65001` + 控制台 UTF-8 + `PYTHONUTF8/PYTHONIOENCODING`；`lib\run_sherlock.py` 把 stderr 并进 stdout，日志里不再出现 PowerShell 的 `所在位置 行:...` 噪声 |
| **C1 一问流** | 🟡 部分 | 已收为"输入用户名 + `?` 设置"，站点/超时/代理/保存位置记住上次选择（比原计划的 C1 多做了设置菜单） |
| 其余（A1/A2/A3/A4、B2/B3/B4、C2/C3/C4/C5、D4/D5） | ⬜ 未开始 | 建议下一批做 A1+A2（解释器解耦与迁出工作区），再往后 C3（HTML 报告/历史/diff）与 B2（可达性画像） |

### 0.2 国内化（2026-11-25 第三批）

起因：上游 `data.json` 的 481 个站点里**没有任何国内平台**（唯一沾边的是 Wikipedia 的 `uselang=qqx` 误匹配），
所以"只搜国内"不是改个站点列表，而是重新做一层适配。

本批把默认模式改成「国内」，并先把能力边界钉死（实测数据见 `LOCAL-DEPLOY.md` 第 3 节）：

| 平台 | 结论 | 判定依据 |
| --- | --- | --- |
| 抖音 | ✅ 自动 | 公开接口按**抖音号**查：`status_code` 0 / 5，附昵称、粉丝、sec_uid |
| B站 | ✅ 自动 | 取 buvid cookie 后调公开搜索接口，**昵称精确同名**才算命中 |
| 豆瓣 | ✅ 自动 | `/people/<ID>/`：404 / 200 |
| 博客园 | ✅ 自动 | `/<用户名>/`：404 / 200 |
| 微博 | ❌ 手动 | 匿名一律 302 到 Sina Visitor；ajax 接口 403 |
| 小红书 | ❌ 手动 | 302 到登录页；搜索需要登录态 + X-S 签名 |
| 微信 | ❌ 手动 | 个人号无公开主页、无公开检索接口（只能查公众号） |
| 知乎 / 贴吧 / 快手 | ❌ 手动 | 403 / 百度安全验证 / 无公开接口 |

落地内容：`lib\cn_search.py`（4 个自动通道 + 7 个手动入口 + `--selfcheck`）、
`run-sherlock.ps1` 增加模式开关与设置项、`sherlock-cn.cmd`、`doctor.ps1` 增加「国内通道」检查、
`selftest.ps1` 增加 `-Mode cn`（默认）与 `-Mode all`。

明确不做：登录态接口、签名参数破解（X-S / a_bogus）、验证码绕过。原因有两个——
技术上平台会持续对抗、维护成本无底；合规上越过风控边界就不再是"公开信息自查"。
需要更强能力时应走平台官方开放平台，而不是在本地逆向。

已知局限：抖音项只认抖音号（很多账号没设）；豆瓣项只认豆瓣 ID；B站同名不等于同一人。
这些都在结果里用 `identifier` 字段和 `candidate` 状态标出来了。

### 0.3 迁移与 Cookie 模式（2026-11-25 第四批）

* **A2 已落地**：项目从 `%USERPROFILE%\Documents\deepseek-harness\default-workspace\sherlock`
  迁到 `%USERPROFILE%\SherlockOSINT\sherlock`（139 MB / 7512 个文件），并做了三件收尾：
  重建 editable 安装、重建 venv 里仍指向旧路径的 `.exe` shim、按新路径重建桌面快捷方式；文档里的绝对路径全部同步。
  `doctor.ps1` 新增「安装位置」检查——以后再放回 `C:\Users` 下会直接 WARN。
* **Cookie 模式已落地（默认关闭）**：`cookieMode` 配置 + 设置菜单第 6 项 + `--cookie-mode`；
  支持微博 / 知乎 / 贴吧 三个平台的登录态页面判定，配置命令 `--set-cookie` / `--check-cookies` / `--clear-cookie`。
  只读公开主页 HTML，不碰 `X-S` / `a_bogus` 签名接口；小红书与微信仍不可自动判定（原因见 0.2）。
* **A1 已落地**：复制 CPython 3.12.14 到 `%USERPROFILE%\SherlockOSINT\runtime\python`（剔除 site-packages 与 test，51 MB），
  用它重建 `.venv` 并重装依赖；`.venv` 内对 `C:\Users` / `dsh-runtimes` 的引用为 0，`doctor` 从此 **13 项全绿、0 警告**。
* **至此 A1/A2 都完成**：项目数据、虚拟环境、Python 运行时全部位于 D 盘工作区，DSH 升级、清理会话目录都不再影响它。

落地过程中踩到并已规避的三个本机坑（对后续改动有约束力）：

1. **Python 子进程只能写项目目录**：`%TEMP%`、桌面都会 `PermissionError`；所有临时输出一律放 `state\` 或 `.last-run\`，由 PowerShell 负责搬运。
2. **PowerShell 5.1 会把子进程 stderr 包成 ErrorRecord**，直接写进日志会变成"所在位置 行:..."；解法是真的把两路输出在 Python 层合并，而不是在 PS 层重定向。
3. **`.cmd` 里不能有 UTF-8 中文**：936 代码页下会把后续行解析错（第一批的启动器就是这么坏的）；生成的 `.cmd` 现在强制 ASCII + CRLF。

---

## 1. 现状基线

### 1.1 这次部署交付了什么

| 项 | 值 |
| --- | --- |
| 位置 | `...\default-workspace\sherlock`（139 MB，其中 `.venv` 137.6 MB） |
| 版本 | Sherlock v0.16.2，master 源码包（`github.com` 不通，走 `codeload.github.com`） |
| 解释器 | Python 3.12.14，来自 DSH 运行时；`.venv\pyvenv.cfg` 的 `home` 指向 `%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python` |
| 站点库 | 包内 `resources\data.json`，481 站点 |
| 本地补丁 | `sites.py`：在线站点库拉取失败时回退到包内 `data.json` |
| 入口 | 桌面 `Sherlock.lnk` → `run-sherlock.ps1`（交互，3 问，结果自动存桌面）；`sherlock.cmd`（命令行透传） |
| 文档 | `LOCAL-DEPLOY.md`（10 节，含更新/卸载/验证记录） |

### 1.2 复测到的环境事实（与当时不同，很重要）

| 发现 | 数据 | 对改进的含义 |
| --- | --- | --- |
| 本机代理现在活着 | `127.0.0.1:7890` 在监听；系统代理 `ProxyEnable=0`，注册表里 `ProxyServer=http://127.0.0.1:7890` | 探测代理不能只看 `ProxyEnable`，要看端口是否真的能出网 |
| 走该代理，被墙站点全部能开 | `github.com`、`x.com`、`instagram.com`、`reddit.com`、`tiktok.com`、`data.sherlockproject.xyz`、`raw.githubusercontent.com` 全部 HTTP 200 | 现在这套部署等于"有钥匙但没插进锁里" |
| `--proxy` 覆盖不到启动阶段 | 加 `--proxy` 仍打印 `Could not load the online site list`；改成设 `HTTPS_PROXY` 环境变量后两条 warning 消失（在线站点库 + 排除列表都加载成功） | Sherlock 只把 `--proxy` 用在站点查询上，站点库/排除列表/更新检查走裸 `requests` |
| 站点可达率（抽样 24 个站点，HEAD 6s） | 直连 16/24，走代理 23/24（唯一失败是对方 SSL 握手） | 可达性抽样的意义：默认全站扫描里 1/3 是纯浪费 |
| 站点库新旧 | 包内 481 条与上游 master **逐条一致**（无新增/改动） | 现在没有"库过期"问题；缺的是以后怎么刷新的通道 |
| 可用镜像 | `ghproxy.net`、`gh-proxy.com` 直连可取上游 `data.json`（104 KB）；`cdn.jsdelivr.net`、`raw.githubusercontent.com` 直连被 reset | 刷新/升级有可用通道，不必依赖 `github.com` |
| 运行时能力 | 仅 Windows PowerShell 5.1；控制台代码页 936；venv 内 `tkinter 8.6`、`PySocks 1.7.1` 可用 | GUI 和 SOCKS 不需要新依赖；脚本必须兼容 5.1 |

---

## 2. 对话里暴露的 8 个问题

| # | 问题 | 证据 | 影响 |
| --- | --- | --- | --- |
| 1 | 入口不可自解释 | 用户直接问"输入用户名之后怎么搜索"；实际要按 3 次回车，其中两个问题可以直接回车 | 第一次使用的人会以为卡住或以为没搜 |
| 2 | 结果没有"归宿" | "如何保存结果" → "能否帮我直接保存到桌面" → 同一句话又问了一次 | 用户要的不是命令行参数，是"我不用管保存这件事" |
| 3 | 已有的网络能力没被用上 | 当时只能提示"有代理时加 `--proxy`"；快捷方式没有探测；而 12450 现在就在跑 | 查询结果里大量 `Unknown`/超时，被误读成"账号不存在" |
| 4 | 底座耦合 DSH | `pyvenv.cfg` 的 `home` 在 `.dsh\dsh-runtimes` 下 | DSH 升级/清理运行时 → 双击报"找不到虚拟环境" |
| 5 | 补丁靠人记 | 文档第 5、6 节要求升级后"按第 5 节重新打补丁" | 一次升级忘记重打，程序直接起不来 |
| 6 | 运行是黑盒 | 输出只在窗口里；中文 stderr 在 936 代码页下变成 `Զ������ǿ�ȹر�` | 出问题时无法复现、无法排查 |
| 7 | 结果是原料不是结论 | CSV/XLSX 是 481 行站点明细，没有"命中几个、哪些没验证成功、比上次多了什么" | 用户要自己会 Excel 才能读出结论 |
| 8 | 上游小毛病没人管 | `--xlsx` 忽略 `-fo` 永远写 cwd；更新检查每次启动都打 `api.github.com`，被限流时打印 `A problem occurred ... 'tag_name'`；`--proxy` 不覆盖启动请求 | 每次运行都多两条噪声、多一次不可控等待 |

---

## 3. 改进清单

改动量记号：**S** ≤ 2 小时 · **M** 半天 · **L** 1~2 天（以一次会话内完成为准）。

### A 组：让部署不再是易碎品

#### A1 解释器解耦（P0，M）

**现状**：`.venv` 的解释器来自 DSH 运行时。DSH 升级、清理 `dsh-runtimes`、换机器 → venv 直接失效。
**做法（二选一）**：

- 优选：装独立 Python（`winget install Python.Python.3.12`，或下载 python-build-standalone 解压到 `runtime\python`，约 40 MB），用它重建 venv，`pyvenv.cfg` 不再指向 `.dsh`；
- 兜底：保留 DSH Python，但写死一条自愈路径——`doctor.ps1 -Repair` 自动按候选列表（独立 Python → DSH 运行时 → `py -3`）重建 venv 并重装依赖。

**验收**：把 `.dsh\dsh-runtimes` 临时改名后，双击快捷方式仍能完成一次查询；或 `doctor.ps1 -Repair` 一条命令恢复。

#### A2 迁出会话工作区（P0，S）

**现状**：项目在 `default-workspace\sherlock`。这是会话目录，工作区里有 `dsh-purge` 这类清理/升级工具，随时可能被整目录重建。
**做法**：安装到 `%LOCALAPPDATA%\Programs\Sherlock`（无需管理员）；workspace 只保留 `install.ps1` + 文档；`install.ps1` 负责建目录、装依赖、重建 `.lnk`、写注册表项（可选：`HKCU\Software\Classes\Directory\shell` 右键菜单）。
**验收**：清空 `default-workspace` 后，桌面快捷方式仍可运行；`install.ps1` 从零到可查询 ≤ 3 分钟。

#### A3 补丁产品化（P1，M）

**现状**：`sites.py` 里 20 行改动，只在文档里用文字描述"补丁特征"。
**做法**：

1. 把改动抽成 `patches\0001-offline-sitelist.patch`（git 格式），配 `apply-patches.ps1`（幂等：已打则跳过）；
2. 记录 `patches\manifest.json`：目标文件 sha256 + 上游版本；
3. 启动时校验：`sites.py` 哈希对不上 → 提示"补丁丢失/上游已变"，并给出一键重打；
4. 顺带把 `--xlsx` 忽略 `-fo` 的一行 bug 也做成 patch（`DataFrame.to_excel(os.path.join(args.folderoutput or '', f"{username}.xlsx"))`）。

**验收**：升级到新版本源码后，一条命令重新打补丁；校验失败时启动给出明确提示而不是静默降级。

#### A4 版本化更新与回滚（P1，L）

**现状**：更新流程是文档里一段可复制的命令，删目录、解包、还原补丁、重装，全靠手稳。
**做法**：`versions\<tag>\` 存源码，`current` 用 junction 指向；`update.ps1` 下载（`codeload` 主通道 + `ghproxy.net` 备通道）→ 校验 tarball → 解包到新版本目录 → 打补丁 → 重装 editable → 切换 junction；保留最近 2 个版本，`update.ps1 -Rollback` 一键回退。
**验收**：升级失败时 `current` 仍指旧版本；回滚 ≤ 10 秒。

### B 组：让网络不再决定成败

#### B1 代理自动接管（P0，S）★ 最高性价比

**证据**（复测）：`127.0.0.1:7890` 在监听；直连 `data.sherlockproject.xyz` / `raw.githubusercontent.com` 被 reset，走该代理 200；`github.com`、`x.com`、`instagram.com`、`reddit.com`、`tiktok.com` 走代理全部 200；`--proxy` 不影响启动阶段的站点库/排除列表加载，只有 `HTTPS_PROXY`/`HTTP_PROXY` 能覆盖。
**做法**：

```powershell
function Get-UsableProxy {
    $cands = @()
    $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($k.ProxyServer) { $cands += ($k.ProxyServer -split ';' | ForEach-Object { ($_ -split '=')[-1] }) }
    $cands += '127.0.0.1:7890','127.0.0.1:7890','127.0.0.1:7897','127.0.0.1:10809','127.0.0.1:1080'
    foreach ($c in ($cands | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            $r = Invoke-WebRequest -Uri 'https://data.sherlockproject.xyz' -Proxy "http://$c" -TimeoutSec 5 -UseBasicParsing
            if ($r.StatusCode -eq 200) { return "http://$c" }
        } catch { }
    }
    return $null
}
```

拿到代理后：① 给 Sherlock 传 `--proxy`；② 同时设 `$env:HTTPS_PROXY/$env:HTTP_PROXY`（这步才是让站点库和排除列表加载成功的关键）；③ 没有可用代理时退回直连并提示"当前直连，未验证站点会记为 Unknown"。
配置位：`config.json` 里 `proxy = "auto" | "off" | "<url>"`，默认 `auto`，可显式关掉（隐私要求）。

**验收**：拔掉代理 → 自动直连不受影响；开着代理 → 启动无两条 warning，`GitHub` 查询从 `Timeout Error` 变 `[+]`；日志里记录实际使用的代理。

#### B2 站点可达性画像 + smart 默认（P0，L）

**现状**：默认全站 481 个站点，抽样里直连约 1/3 不可达，每次都要等超时；同一个墙外站点下次还会再等一遍。
**做法**：

- 每次扫描后解析 CSV，把 `exists=Unknown` 且无响应时间的站点记为 `fail`，`Claimed/Available` 记为 `ok`，写入 `state\reachability.json`（含时间戳、耗时、连续失败次数）；
- 默认 `smart` 模式：只扫"最近 7 天内 ok"或"从未测过"的站点；
- `--full` = 481 全量；`--sites-blocked` = 只看被判定不可达的站点（排查用）；
- 失败站点 7 天后自动重测一次，避免永久误杀。

**验收**：同一用户名第二次查询，耗时下降到首轮的 1/3 以内；`--full` 行为与现在完全一致。

#### B3 站点库刷新通道（P1，S）

**现状**：靠包内 `data.json`，现在恰好与上游一致，但没有任何刷新路径；每次启动还要先等一次 `data.sherlockproject.xyz` 失败（最长 30 秒）。
**做法**：`refresh-sites.ps1` 按优先级 `代理直连 data 域名 → ghproxy.net → gh-proxy.com` 拉官方 `data.json` 与 `false_positive_exclusions.txt`，校验 JSON、站点数（≥ 450）、记录抓取时间和来源；启动默认跳过远端探测（等价 `--local`），只有 `refresh-sites.ps1` 才联网。
**验收**：断网时启动 < 2 秒且无 warning；`refresh-sites.ps1` 能证明"从哪拉到、多少站点、和上次差几条"。

#### B4 失败分类写进结果（P2，S）

**现状**：`exists` 只有 `Claimed/Available/Unknown`，`Unknown` 里混着"被墙""超时""限流""服务器 5xx"，读表的人分不清"没有账号"和"没查成"。
**做法**：CSV 增加 `error_kind` 列（`blocked / timeout / dns / tls / rate_limited / http_5xx / ok`），由异常类型 + 代理是否启用推断；XLSX 里用条件格式把 `blocked` 涂灰。
**验收**：一眼能看出"这个用户名是真没注册，还是这 200 个站点压根没连上"。

### C 组：让体验配得上能力

#### C1 一问流 + 记忆上次选择（P1，S）

**现状**：3 个 `Read-Host`，用户第一次就卡住并专门来问。
**做法**：默认只问用户名（Enter 即扫），站点/超时/代理走 `config.json` 的上次值；输入框旁印一行 `[Enter] 开始 · [S] 设置 · [Q] 退出`；`S` 进二级菜单改站点组、超时、是否存桌面。
**验收**：新用户不问任何问题，双击 → 输用户名 → 出结果。

#### C2 tkinter 单窗口（P1，L）

**现状**：控制台窗口，信息密度低，超时站点刷屏（虽然 `--print-found` 压住了），结果只能在 Excel 里看。
**可行性**：venv 内 `tkinter 8.6` 可用，零新依赖。
**做法**：单窗口三区——上方用户名 + 站点组下拉 + 「开始」；中间进度（`已查 / 命中 / 超时` 实时计数，`--print-all` 的 stderr 解析或改用子进程逐行读）；下方结果表（`Treeview`：站点、状态、链接）。底部按钮：打开 CSV / 打开报告 / 复制全部链接 / 再来一次。
**验收**：双击 → 输入 → 进度条走完 → 双击一行直接用浏览器打开主页。

#### C3 结果产品化：HTML 报告 + 历史 + diff（P1，M）

**现状**：用户拿到的是 481 行原始明细。
**做法**：

- `state\history.sqlite`（stdlib，无需新依赖）存每次运行的 `run` 与 `site_result`；
- 生成单文件 `report.html`：运行元数据（时间/版本/站点库 sha1/代理/命令行）、命中卡片（按类别分组、可点）、未验证清单（按 `error_kind` 分组计数）、与上次同一用户名的 **diff**（新增命中高亮）；
- 桌面保存改为 `Desktop\Sherlock结果\<用户名>_<时间>\` 子目录，内含 `report.html + .csv + .xlsx`，只保留最近 20 份。

**验收**：给非技术用户一个 HTML 就能看懂"查到了什么、哪些没查成"；同一用户名第二次扫描能显示"新增 2 个"。

#### C4 批量查询（P2，L）

**做法**：`batch.ps1 -File users.txt`，逐个（或 2~4 并发进程）查询，断点续跑（`.done` 文件），最后汇总一个 XLSX（每用户名一个 sheet）+ 一张总表；并发上限可配，避免把目标站点打到限流。
**验收**：100 个用户名无人值守跑完，中途 Ctrl-C 后能从断点继续。

#### C5 监控（P2，S）

**做法**：`watch.ps1 -User john -Daily` 注册计划任务，命中集合变化时用 `NotifyIcon` 气泡提示（PS 5.1 无需装模块），并写一条到 `state\watch.log`。
**验收**：新增命中在 1 分钟内弹通知；无变化不打扰。

### D 组：让问题能被看见

#### D1 `doctor.ps1` + `selftest.ps1`（P1，M）

**做法**：`doctor` 打一张红绿灯表——独立 Python 存在？venv 可用？补丁哈希匹配？站点库条数？代理可用？桌面可写？快捷方式指向存在？日志目录可写？`selftest` 跑一次 `test @ GitLab` 并断言 CSV 里有 `Claimed` 行、断言 xlsx 能被 `openpyxl` 打开。
**验收**：任何"双击没反应"先用 `doctor` 一条命令定位，不用人工猜。

#### D2 运行日志（P1，S）

**做法**：每次运行 tee 到 `logs\run-<时间戳>.log`（UTF-8 无 BOM），头部记录命令行、代理、超时、版本；尾部记录统计。窗口关闭不丢。
**验收**：能凭日志复现任何一次异常，不再只有一张截图。

#### D3 编码统一（P1，S）

**现状**：代码页 936，Python 的 UTF-8 stderr 中文变 `Զ������ǿ�ȹر�`；`.cmd` 里写中文注释曾直接让 cmd 解析错乱（当时第一版启动器就是这么坏的）。
**做法**：启动器里统一 `chcp 65001` + `[Console]::OutputEncoding=[Text.Encoding]::UTF8` + `$env:PYTHONIOENCODING='utf-8'` + `$env:PYTHONUTF8='1'`；所有 `.cmd` 只用 ASCII；`.ps1` 保存为 UTF-8 **带 BOM**（5.1 才认中文）。
**验收**：中文错误信息正常显示；`.cmd` 在任何代码页下都能跑。

#### D4 启动噪声治理（P2，S）

**做法**：更新检查加 24h 缓存文件，捕获 `KeyError`（限流时 GitHub 返回的 JSON 没有 `tag_name`），提供 `SHERLOCK_NO_UPDATE=1` 彻底关闭；启动不再每次都打一次 `api.github.com`。
**验收**：连续双击 10 次，屏幕只有查询输出；被限流时也不出现 traceback 式提示。

#### D5 合规与速率（P2，S）

**做法**：首次运行一句确认（"仅限授权范围内公开信息核查"）写进 `state\accepted`；默认并发上限、单域 1 并发、`--threads` 可调；报告页脚带免责声明。
**验收**：误触大批量扫描时不会瞬间打出几百个并发连接。

---

## 4. 建议的落地顺序

| 批次 | 内容 | 目的 | 改动量 |
| --- | --- | --- | --- |
| 第一批（一次会话） | B1 代理接管 + D3 编码 + D2 日志 + D1 doctor | 先解决"能不能查到、出错能不能查" | S+S+S+M |
| 第二批 | A1 解耦 + A2 迁移 + C1 一问流 | 去掉定时炸弹，把入口降到 1 步 | M+S+S |
| 第三批 | B2 画像 + C3 报告 + B3 刷新 | 让结果可读、全站扫描不再靠等 | L+M+S |
| 第四批 | A3 补丁化 + A4 更新回滚 + C2 GUI + C4 批量 | 长期可维护 | M+L+L+L |
| 可选 | C5 监控 + B4 失败分类 + D4 噪声 + D5 合规 | 锦上添花 | S+S+S+S |

---

## 5. 明确不建议做的

| 想法 | 不做的理由 |
| --- | --- |
| 做 Web 版（FastAPI/Flask + 浏览器） | 要常驻端口、防火墙放行、简单鉴权；tkinter 单窗口已够，且零新依赖 |
| fork 上游长期维护 | 把本地改动压在 30 行内、能提 PR 就提，避免变成"自己的 Sherlock" |
| 上 Docker | Windows 上要 WSL2/Hyper-V，体积和网络两重成本，收益为负 |
| 默认全站扫描当卖点 | 481 站点里约 1/3 不可达，默认全量只会制造超时和误解；先画像再谈全量 |
| 把结果直接写进 OneDrive/同步盘 | 会触发同步冲突与延迟，桌面子目录 + 手动归档更稳 |

---

## 6. 风险与取舍

1. **代理自动接管的隐私面**：查询内容会经过本机代理进程。必须可一键关闭（`proxy: "off"`），并在日志/报告里写明"本次走了代理"。
2. **可达性画像会误判**：站点临时故障会被记成不可达。加 7 天 TTL、连续 3 次失败才降级、`--full` 强制全量。
3. **迁移目录会打散路径**：快捷方式、文档里的绝对路径、`LOCAL-DEPLOY.md` 的示例都要同步；迁移必须由一个脚本完成，不能让用户手动改。
4. **桌面文件会堆积**：改成 `Desktop\Sherlock结果\` 子目录 + 只留最近 20 份，避免用户几个月后桌面上百个 CSV。
5. **PowerShell 5.1 限制**：没有 `??`、三元、`-Parallel`；所有新脚本按 5.1 语法写并做 `Parser::ParseFile` 语法校验（这次就是靠它抓到初版脚本的引号 bug）。

---

## 7. 附录：本轮复测的命令与结果

```powershell
# 1) 本机代理与系统设置
Get-NetTCPConnection -LocalPort 12450 -State Listen          # 127.0.0.1:7890 LISTEN
(Get-ItemProperty 'HKCU:\...\Internet Settings').ProxyEnable  # 0（但 12450 可用）

# 2) 走代理取被墙域名（requests）
requests.get('https://github.com/', proxies={'https':'http://127.0.0.1:7890'})   # 200
requests.get('https://data.sherlockproject.xyz', proxies=...)                      # 200（直连 10054 reset）

# 3) --proxy 覆盖不到启动阶段；改用环境变量后 warning 消失
$env:HTTPS_PROXY='http://127.0.0.1:7890'
python -m sherlock_project test --site GitLab --print-all   # 无 Could not load the online site list

# 4) 站点可达率抽样（24 个随机站点，HEAD 6s）
直连 16/24 · 走代理 23/24

# 5) 站点库一致性
上游 master data.json 481 条 vs 包内 481 条：新增 0 / 删除 0 / 改动 0

# 6) 运行能力
python -c "import tkinter; print(tkinter.TkVersion)"   # 8.6
python -c "import socks; print(socks.__version__)"     # 1.7.1
$PSVersionTable.PSVersion                              # 5.1.22621.4391
chcp                                                   # 936
```

---

## 8. 可以顺手提给上游的 3 个 issue / PR

留在本地打补丁终究要人维护，这三处都是小改动、通用问题：

1. **`--proxy` 应覆盖站点库 / 排除列表 / 更新检查**：`sites.py` 与 `sherlock.py` 的启动请求没传 `proxies`，导致"代理能用但启动仍报错、站点库仍回退"。
2. **`--xlsx` 应尊重 `-fo`**：`DataFrame.to_excel(f"{username}.xlsx")` 永远是当前工作目录。
3. **更新检查应容错 + 可关闭**：限流时响应缺 `tag_name` 会抛出 `KeyError` 并打印成一句莫名提示；加 `--no-update-check` 或 24h 缓存。
