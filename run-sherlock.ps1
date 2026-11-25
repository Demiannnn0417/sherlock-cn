# =====================================================================
#  Sherlock 桌面快捷方式入口（Windows PowerShell 5.1）
#  双击后：输入用户名 -> 国内模式或全站模式 -> 结果存桌面 -> 运行日志留档
#  国内模式：抖音号 / B站昵称 / 豆瓣ID / 博客园用户名 自动判定，
#            微博、小红书、微信、知乎、贴吧、快手给检索入口（不假装查到）
# =====================================================================
[CmdletBinding()]
param(
    [string]$Username = '',
    [string]$Sites = '',
    [int]$Timeout = 0,
    [string]$Proxy = '',
    [ValidateSet('cn', 'all', '')][string]$Mode = '',
    [switch]$NonInteractive,
    [switch]$NoPause,
    [switch]$KeepRunDir
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib\common.ps1')
Initialize-SherlockConsole

$paths     = $script:Paths
$version   = Get-SherlockVersion
$siteCount = Get-SherlockSiteCount
$config    = Read-SherlockConfig
if (-not (Test-Path -LiteralPath $paths.Config)) {
    Save-SherlockConfig -Config $config | Out-Null
}

if ($NonInteractive -and [string]::IsNullOrWhiteSpace($Username)) {
    Write-Host '[错误] -NonInteractive 模式必须提供 -Username' -ForegroundColor Red
    exit 2
}

# 模式：参数 > 配置（默认 cn）
$effectiveMode = 'cn'
if (-not [string]::IsNullOrWhiteSpace($Mode)) {
    $effectiveMode = $Mode
} elseif ($config.mode -in @('cn', 'all')) {
    $effectiveMode = [string]$config.mode
}

# ---------------------------------------------------------------------
# 代理：仅全站模式需要（国内平台直连更快、也不会被代理的规则影响）
# ---------------------------------------------------------------------
function Resolve-ProxyChoice {
    param([string]$Override, [switch]$Refresh)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $lower = $Override.Trim().ToLowerInvariant()
        if ($lower -in @('off', 'none', 'direct', '0', 'false')) {
            return [pscustomobject]@{ url = $null; mode = 'off'; source = 'parameter'; verified = 'none'; latency_ms = $null }
        }
        $url = $Override.Trim()
        if ($url -notmatch '^[a-z]+://') { $url = 'http://' + $url }
        return [pscustomobject]@{ url = $url; mode = 'manual'; source = 'parameter'; verified = 'unknown'; latency_ms = $null }
    }

    $info = Get-SherlockProxyInfo -Refresh:$Refresh
    if ($null -eq $info) {
        return [pscustomobject]@{ url = $null; mode = 'unknown'; source = 'none'; verified = 'none'; latency_ms = $null }
    }
    return $info
}

$proxyInfo = $null
$proxyUrl  = $null
$proxyText = '国内模式直连（不使用代理）'
if ($effectiveMode -eq 'all') {
    $proxyInfo = Resolve-ProxyChoice -Override $Proxy
    $proxyUrl = $proxyInfo.url
    $proxyText = Format-SherlockProxy $proxyInfo
}

# ---------------------------------------------------------------------
# 界面
# ---------------------------------------------------------------------
function Show-Banner {
    param([string]$ModeName, [string]$ProxyText, [string]$SaveText)

    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ("     Sherlock  v{0}   ·   {1}用户名账号检索" -f $version, $ModeName) -ForegroundColor Cyan
    if ($ModeName -eq '国内') {
        Write-Host '     抖音 / B站 / 豆瓣 / 博客园 自动 · 微博 / 小红书 / 微信 给入口' -ForegroundColor DarkGray
        Write-Host ('     ' + (Get-CookieStatusText)) -ForegroundColor DarkGray
    } else {
        Write-Host ("     {0} 个站点 · 可配合 --site 定向查询" -f $siteCount) -ForegroundColor DarkGray
    }
    Write-Host ("     结果保存到{0} · 仅限合法授权用途" -f $SaveText) -ForegroundColor DarkGray
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ("     代理：{0}" -f $ProxyText) -ForegroundColor DarkGray
    Write-Host ''
}

function Get-ModeName {
    if ($effectiveMode -eq 'cn') { return '国内' }
    return '全部'
}

function Get-SaveTargetText {
    if ($config.saveToDesktop) { return '桌面' }
    return ' results 目录'
}

function Get-CookieCount {
    $file = Join-Path $paths.State 'cookies.json'
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    try {
        $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($data.PSObject.Properties | Where-Object { $_.Value }).Count
    } catch {
        return 0
    }
}

function Get-CookieStatusText {
    $count = Get-CookieCount
    if ($config.cookieMode) { return ("Cookie 模式：开（已配置 {0}/3 个平台）" -f $count) }
    return 'Cookie 模式：关（微博/知乎/贴吧 可选）'
}

function Show-Settings {
    param($Config, [string]$CurrentProxy)

    while ($true) {
        $modeLabel = '国内（抖音/B站/豆瓣/博客园 + 手动入口）'
        if ($effectiveMode -eq 'all') { $modeLabel = '全部（Sherlock 481 站点）' }

        $siteLabel = '全部'
        if ($Config.sites) { $siteLabel = $Config.sites }
        if ($effectiveMode -eq 'cn') { $siteLabel = '全部可用平台' }
        if ($effectiveMode -eq 'cn' -and $Config.sites) { $siteLabel = $Config.sites }

        $saveLabel = '桌面'
        if (-not $Config.saveToDesktop) { $saveLabel = '项目目录 results\' }

        Write-Host ''
        Write-Host '  ── 设置 ──────────────────────────────────────' -ForegroundColor DarkCyan
        Write-Host ("   0) 查询模式：{0}" -f $modeLabel)
        if ($effectiveMode -eq 'cn') {
            Write-Host ("   1) 平台过滤：{0}（如 douyin,bilibili）" -f $siteLabel)
        } else {
            Write-Host ("   1) 查询站点：{0}" -f $siteLabel)
        }
        Write-Host ("   2) 超时秒数：{0}" -f $Config.timeout)
        Write-Host ("   3) 代理：{0}" -f $CurrentProxy)
        Write-Host ("   4) 结果保存：{0}" -f $saveLabel)
        Write-Host '   5) 重新探测代理（仅全站模式）'
        Write-Host ("   6) Cookie 模式：{0}" -f $(if ($Config.cookieMode) { '开' } else { '关' }))
        Write-Host '   回车）返回'
        $choice = Read-Host '  选择'

        if ([string]::IsNullOrWhiteSpace($choice)) { return }
        switch ($choice.Trim()) {
            '0' {
                if ($effectiveMode -eq 'cn') {
                    $effectiveMode = 'all'
                    $Config.mode = 'all'
                } else {
                    $effectiveMode = 'cn'
                    $Config.mode = 'cn'
                }
                if ($effectiveMode -eq 'all') {
                    $script:proxyInfo = Resolve-ProxyChoice -Override $Proxy
                    $script:proxyUrl = $script:proxyInfo.url
                    $CurrentProxy = Format-SherlockProxy $script:proxyInfo
                } else {
                    $script:proxyUrl = $null
                    $CurrentProxy = '国内模式直连（不使用代理）'
                }
                Write-Host ("  已切换为：{0}" -f (Get-ModeName)) -ForegroundColor DarkGray
            }
            '1' {
                if ($effectiveMode -eq 'cn') {
                    $answer = Read-Host '  平台（逗号分隔：douyin,bilibili,douban,cnblogs；输入 all 表示全部）'
                    if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim().ToLowerInvariant() -eq 'all') {
                        $Config.sites = ''
                    } else {
                        $Config.sites = $answer.Trim()
                    }
                } else {
                    $answer = Read-Host '  站点（逗号分隔，如 GitLab,GitHub；输入 all 表示全部）'
                    if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim().ToLowerInvariant() -eq 'all') {
                        $Config.sites = ''
                    } else {
                        $Config.sites = $answer.Trim()
                    }
                }
            }
            '2' {
                $answer = Read-Host '  超时秒数（5~60）'
                if ($answer -match '^\d+$') {
                    $value = [int]$answer
                    if ($value -ge 5 -and $value -le 60) { $Config.timeout = $value }
                }
            }
            '3' {
                if ($effectiveMode -eq 'cn') {
                    Write-Host '  国内模式固定直连，代理设置仅对全站模式生效。' -ForegroundColor DarkYellow
                } else {
                    $answer = Read-Host '  代理：auto / off / http://127.0.0.1:7890'
                    if (-not [string]::IsNullOrWhiteSpace($answer)) {
                        $Config.proxy = $answer.Trim()
                        Save-SherlockConfig -Config $Config | Out-Null
                        $script:proxyInfo = Resolve-ProxyChoice -Override ''
                        $script:proxyUrl = $script:proxyInfo.url
                        $CurrentProxy = Format-SherlockProxy $script:proxyInfo
                    }
                }
            }
            '4' {
                $Config.saveToDesktop = -not [bool]$Config.saveToDesktop
            }
            '5' {
                if ($effectiveMode -eq 'cn') {
                    Write-Host '  国内模式直连，无需探测代理。' -ForegroundColor DarkYellow
                } else {
                    Save-SherlockConfig -Config $Config | Out-Null
                    $script:proxyInfo = Resolve-ProxyChoice -Refresh
                    $script:proxyUrl = $script:proxyInfo.url
                    $CurrentProxy = Format-SherlockProxy $script:proxyInfo
                    Write-Host ("  当前代理：{0}" -f $CurrentProxy) -ForegroundColor DarkGray
                }
            }
            '6' {
                $Config.cookieMode = -not [bool]$Config.cookieMode
                if ($Config.cookieMode) {
                    if ((Get-CookieCount) -eq 0) {
                        Write-Host '  已开启，但还没有配置 Cookie。配置方法：' -ForegroundColor DarkYellow
                        Write-Host '    sherlock-cn.cmd --set-cookie weibo' -ForegroundColor DarkYellow
                    } else {
                        Write-Host '  Cookie 模式已开启（仅本机登录态，请勿外发 cookies.json）。' -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host '  Cookie 模式已关闭，微博/知乎/贴吧 只给检索入口。' -ForegroundColor DarkGray
                }
            }
            default { }
        }
        Save-SherlockConfig -Config $Config | Out-Null
    }
}

Show-Banner -ModeName (Get-ModeName) -ProxyText $proxyText -SaveText (Get-SaveTargetText)

# ---------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------
$queryNames = @()
if (-not [string]::IsNullOrWhiteSpace($Username)) {
    $queryNames = @($Username.Trim() -split '\s+' | Where-Object { $_ })
}

if (-not $NonInteractive -and $queryNames.Count -eq 0) {
    while ($true) {
        $reply = Read-Host '  请输入用户名 / 抖音号 / 豆瓣ID（多个用空格分隔；? = 设置；直接回车退出）'
        if ([string]::IsNullOrWhiteSpace($reply)) { exit 0 }
        if ($reply.Trim() -eq '?') {
            Show-Settings -Config $config -CurrentProxy $proxyText
            $proxyText = if ($effectiveMode -eq 'cn') { '国内模式直连（不使用代理）' } else { Format-SherlockProxy $proxyInfo }
            continue
        }
        $queryNames = @($reply.Trim() -split '\s+' | Where-Object { $_ })
        if ($queryNames.Count -gt 0) { break }
    }
}

$siteList = @()
if (-not [string]::IsNullOrWhiteSpace($Sites)) {
    $siteList = Split-SherlockSites -Text $Sites
} elseif (-not [string]::IsNullOrWhiteSpace([string]$config.sites)) {
    $siteList = Split-SherlockSites -Text ([string]$config.sites)
}

$effectiveTimeout = 0
if ($Timeout -gt 0) {
    $effectiveTimeout = $Timeout
} else {
    $effectiveTimeout = [int]$config.timeout
}
if ($effectiveTimeout -le 0) { $effectiveTimeout = 15 }

# ---------------------------------------------------------------------
# 准备运行目录与参数
# ---------------------------------------------------------------------
if (Test-Path -LiteralPath $paths.RunDir) {
    Remove-Item -LiteralPath $paths.RunDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $paths.RunDir -Force | Out-Null

$cnJsonPath = Join-Path $paths.RunDir 'cn-result.json'
$cnCsvPath  = Join-Path $paths.RunDir 'cn-result.csv'
$cnXlsxPath = Join-Path $paths.RunDir 'cn-result.xlsx'

if ($effectiveMode -eq 'cn') {
    $cnScript = Join-Path $paths.Lib 'cn_search.py'
    $arguments = @($cnScript) + $queryNames
    $arguments += @('--timeout', [string]$effectiveTimeout, '--json', $cnJsonPath, '--csv', $cnCsvPath, '--xlsx', $cnXlsxPath)
    if ($siteList.Count -gt 0) { $arguments += @('--only', ($siteList -join ',')) }
    if ($config.cookieMode) { $arguments += '--cookie-mode' }
} else {
    $runner = Join-Path $paths.Lib 'run_sherlock.py'
    $arguments = @($runner) + $queryNames
    foreach ($site in $siteList) { $arguments += @('--site', $site) }
    $arguments += @('--timeout', [string]$effectiveTimeout, '--no-color', '--csv', '--xlsx')
    if ($proxyUrl) { $arguments += @('--proxy', $proxyUrl) }
    $arguments += @('-fo', $paths.RunDir)
}

# ---------------------------------------------------------------------
# 日志与运行
# ---------------------------------------------------------------------
$logPath = New-SherlockRunLog -Tag $(if ($effectiveMode -eq 'cn') { 'cn' } else { 'run' })
Write-SherlockLog `
    ("版本: {0}" -f $version) `
    ("模式: {0}" -f (Get-ModeName)) `
    ("代理: {0}" -f $proxyText) `
    ("Cookie: {0}" -f (Get-CookieStatusText)) `
    ("用户名: {0}" -f ($queryNames -join ' ')) `
    ("过滤: {0}" -f $(if ($siteList.Count -gt 0) { $siteList -join ',' } else { '全部' })) `
    ("超时: {0} 秒" -f $effectiveTimeout) `
    ("命令: {0} {1}" -f $paths.Python, ($arguments -join ' '))

Write-Host ''
Write-Host ('  > ' + ($arguments -join ' ')) -ForegroundColor DarkGray
Write-Host ''

$savedEnv = @{
    HTTPS_PROXY = $env:HTTPS_PROXY
    HTTP_PROXY  = $env:HTTP_PROXY
}
if ($effectiveMode -eq 'all' -and $proxyUrl) {
    $env:HTTPS_PROXY = $proxyUrl
    $env:HTTP_PROXY  = $proxyUrl
}

try {
    $result = Invoke-SherlockProcess -Python $paths.Python -Arguments $arguments -WorkingDirectory $paths.RunDir -LogPath $logPath
} finally {
    foreach ($key in @('HTTPS_PROXY', 'HTTP_PROXY')) {
        $previous = $savedEnv[$key]
        if ([string]::IsNullOrEmpty($previous)) {
            Remove-Item -Path ("Env:" + $key) -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path ("Env:" + $key) -Value $previous
        }
    }
}

Write-SherlockLog ("退出码: {0}  用时: {1} 秒" -f $result.ExitCode, $result.ElapsedSeconds)
Write-Host ''
if ($result.ExitCode -eq 0) {
    Write-Host ("  检索结束：用时 {0:N1} 秒" -f $result.ElapsedSeconds) -ForegroundColor DarkGray
} else {
    Write-Host ("  检索异常结束：退出码 {0}，用时 {1:N1} 秒" -f $result.ExitCode, $result.ElapsedSeconds) -ForegroundColor Yellow
}

# ---------------------------------------------------------------------
# 收集结果并保存
# ---------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$saved = @()

if ($effectiveMode -eq 'cn') {
    $csvFiles  = @(Get-ChildItem -LiteralPath $paths.RunDir -File -Filter '*.csv' -ErrorAction SilentlyContinue)
    $xlsxFiles = @(Get-ChildItem -LiteralPath $paths.RunDir -File -Filter '*.xlsx' -ErrorAction SilentlyContinue)
    $prefix = 'SherlockCN'
    $namePart = (($queryNames | Select-Object -First 3) -join '_')
    if ($queryNames.Count -gt 3) { $namePart += ('_等' + $queryNames.Count + '个') }
    $namePart = $namePart -replace '[\\/:*?"<>|\s]', '_'
    if ([string]::IsNullOrWhiteSpace($namePart)) { $namePart = 'cn' }
} else {
    $csvFiles  = @(Get-ChildItem -LiteralPath $paths.RunDir -File -Filter '*.csv' -ErrorAction SilentlyContinue)
    $xlsxFiles = @(Get-ChildItem -LiteralPath $paths.RunDir -File -Filter '*.xlsx' -ErrorAction SilentlyContinue)
    $prefix = 'Sherlock'
    $baseName = $null
}

$saveDir = [Environment]::GetFolderPath('Desktop')
if (-not $config.saveToDesktop) {
    $saveDir = Join-Path $paths.Root ('results\' + $stamp)
    New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
}

foreach ($file in $csvFiles) {
    $base = [IO.Path]::GetFileNameWithoutExtension($file.Name) -replace '[\\/:*?"<>|]', '_'
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'result' }
    if ($effectiveMode -eq 'cn') { $base = $namePart }
    $dest = Join-Path $saveDir ('{0}_{1}_{2}.csv' -f $prefix, $base, $stamp)
    Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dest) { $saved += $dest }
}
foreach ($file in $xlsxFiles) {
    $base = [IO.Path]::GetFileNameWithoutExtension($file.Name) -replace '[\\/:*?"<>|]', '_'
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'result' }
    if ($effectiveMode -eq 'cn') { $base = $namePart }
    $dest = Join-Path $saveDir ('{0}_{1}_{2}.xlsx' -f $prefix, $base, $stamp)
    Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dest) { $saved += $dest }
}

# ---------------------------------------------------------------------
# 统计
# ---------------------------------------------------------------------
$totals = [pscustomobject]@{ Total = 0; Claimed = 0; Available = 0; Unknown = 0; Manual = 0; Candidate = 0; Cookie = 0 }

if ($effectiveMode -eq 'cn') {
    if (Test-Path -LiteralPath $cnJsonPath) {
        try {
            $payload = Get-Content -LiteralPath $cnJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary = $payload.summary
            $totals.Claimed   = [int]$summary.claimed
            $totals.Candidate = [int]$summary.candidate
            $totals.Available = [int]$summary.available
            $totals.Unknown   = [int]$summary.unknown
$totals.Manual    = [int]$summary.unsupported
            $totals.Cookie    = [int]$summary.needs_cookie
            $totals.Total     = $totals.Claimed + $totals.Candidate + $totals.Available + $totals.Unknown + $totals.Cookie
        } catch { }
    }
} else {
    foreach ($file in $csvFiles) {
        $one = Get-CsvSummary -Path $file.FullName
        $totals.Total     += $one.Total
        $totals.Claimed   += $one.Claimed
        $totals.Available += $one.Available
        $totals.Unknown   += $one.Unknown
    }
}

if (-not $KeepRunDir) {
    Remove-Item -LiteralPath $paths.RunDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($saved.Count -gt 0) {
    Write-Host ''
    Write-Host ("  已保存 {0} 个文件到{1}：" -f $saved.Count, (Get-SaveTargetText)) -ForegroundColor Green
    foreach ($path in $saved) { Write-Host ('    ' + $path) -ForegroundColor Green }
    Write-Host ''
    if ($effectiveMode -eq 'cn') {
        Write-Host ("  统计：自动判定 {0} 项 · 命中 {1} · 有候选 {2} · 未注册 {3} · 未验证 {4} · 需Cookie {5} · 需手动 {6}" -f `
            $totals.Total, $totals.Claimed, $totals.Candidate, $totals.Available, $totals.Unknown, $totals.Cookie, $totals.Manual) -ForegroundColor Cyan
        if ($config.cookieMode) {
            Write-Host '        已启用 Cookie 模式：需Cookie 行表示该平台未配置或登录态失效，可用 sherlock-cn.cmd --check-cookies 检查。' -ForegroundColor DarkGray
        } else {
            Write-Host '        微博 / 知乎 / 贴吧 可配置 Cookie 自动判定；小红书 / 微信 / 快手 只能人工确认。' -ForegroundColor DarkGray
        }
        Write-SherlockLog ("统计: 判定={0} 命中={1} 候选={2} 未注册={3} 未验证={4} 需手动={5}" -f `
            $totals.Total, $totals.Claimed, $totals.Candidate, $totals.Available, $totals.Unknown, $totals.Manual)
    } else {
        Write-Host ("  统计：检查 {0} 个站点 · 命中 {1} · 未注册 {2} · 未验证 {3}" -f $totals.Total, $totals.Claimed, $totals.Available, $totals.Unknown) -ForegroundColor Cyan
        if ($totals.Unknown -gt 0) {
            Write-Host ("        未验证多为超时或被阻断；本次代理：{0}" -f $(if ($proxyUrl) { $proxyUrl } else { '未使用' })) -ForegroundColor DarkGray
        }
        Write-SherlockLog ("统计: 总计={0} 命中={1} 未注册={2} 未验证={3}" -f $totals.Total, $totals.Claimed, $totals.Available, $totals.Unknown)
    }
    Write-SherlockLog ("保存: {0}" -f ($saved -join ' | '))
} else {
    Write-Host ''
    Write-Host '  [警告] 没有生成结果文件，请检查上面的输出或日志。' -ForegroundColor Yellow
    Write-SherlockLog '警告: 未生成任何 CSV/XLSX'
}

Write-Host ''
Write-Host ("  运行日志：{0}" -f $logPath) -ForegroundColor DarkGray
if ($KeepRunDir) {
    Write-Host ("  临时目录：{0}" -f $paths.RunDir) -ForegroundColor DarkGray
}
Write-Host ''

if (-not $NonInteractive -and -not $NoPause) {
    $answer = Read-Host '  按 O 回车打开结果目录，直接回车关闭窗口'
    if ($answer -and $answer.Trim().ToLowerInvariant() -eq 'o' -and $saved.Count -gt 0) {
        & explorer.exe /select,"$($saved[0])"
    }
}

exit $result.ExitCode
