# =====================================================================
#  Sherlock 本地部署 —— 公共函数
#  由 run-sherlock.ps1 / doctor.ps1 / selftest.ps1 点源加载
#  兼容 Windows PowerShell 5.1（本机未装 pwsh 7）
# =====================================================================

$script:SherlockLibDir  = $PSScriptRoot
$script:SherlockRoot    = Split-Path -Parent $PSScriptRoot
$script:SherlockLogPath = $null

$script:Paths = [pscustomobject]@{
    Root      = $script:SherlockRoot
    Lib       = $script:SherlockLibDir
    Python    = Join-Path $script:SherlockRoot '.venv\Scripts\python.exe'
    Exe       = Join-Path $script:SherlockRoot '.venv\Scripts\sherlock.exe'
    Sites     = Join-Path $script:SherlockRoot 'sherlock_project\resources\data.json'
    SitesPy   = Join-Path $script:SherlockRoot 'sherlock_project\sites.py'
    PyProject = Join-Path $script:SherlockRoot 'pyproject.toml'
    State     = Join-Path $script:SherlockRoot 'state'
    Logs      = Join-Path $script:SherlockRoot 'logs'
    RunDir    = Join-Path $script:SherlockRoot '.last-run'
    Config    = Join-Path $script:SherlockRoot 'state\config.json'
    Probe     = Join-Path $script:SherlockLibDir 'proxy_probe.py'
    Runner    = Join-Path $script:SherlockLibDir 'run_sherlock.py'
}

# ---------------------------------------------------------------------
# 控制台编码：把代码页、.NET 控制台、Python 三处统一成 UTF-8
# （不做这步，936 代码页下中文 stderr 会变成 Զ������ǿ�ȹر� 这种乱码）
# ---------------------------------------------------------------------
function Initialize-SherlockConsole {
    [CmdletBinding()]
    param()

    try { & chcp.com 65001 > $null 2>&1 } catch { }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try { [Console]::InputEncoding  = [System.Text.Encoding]::UTF8 } catch { }
    try { $global:OutputEncoding    = [System.Text.Encoding]::UTF8 } catch { }

    $env:PYTHONUTF8       = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    # 输出走管道时 Python 会改成块缓冲，进度就会拖到最后才出现
    $env:PYTHONUNBUFFERED = '1'
}

# ---------------------------------------------------------------------
# 配置：state\config.json
# ---------------------------------------------------------------------
function Read-SherlockConfig {
    [CmdletBinding()]
    param()

    $defaults = [ordered]@{
        mode          = 'cn'
        cookieMode    = $false
        proxy         = 'auto'
        timeout       = 15
        sites         = ''
        saveToDesktop = $true
        keepResults   = 20
    }

    if (-not (Test-Path -LiteralPath $script:Paths.Config)) {
        return [pscustomobject]$defaults
    }
    try {
        $raw = Get-Content -LiteralPath $script:Paths.Config -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        foreach ($key in @($defaults.Keys)) {
            if ($null -eq $obj.PSObject.Properties[$key]) {
                $obj | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
            }
        }
        return $obj
    } catch {
        return [pscustomobject]$defaults
    }
}

function Save-SherlockConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    try {
        if (-not (Test-Path -LiteralPath $script:Paths.State)) {
            New-Item -ItemType Directory -Path $script:Paths.State -Force | Out-Null
        }
        $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Paths.Config -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------
# 代理探测：交给 lib\proxy_probe.py，脚本只负责调用与展示
# ---------------------------------------------------------------------
function Get-SherlockProxyInfo {
    [CmdletBinding()]
    param([switch]$Refresh)

    $python = $script:Paths.Python
    if (-not (Test-Path -LiteralPath $python)) { return $null }
    if (-not (Test-Path -LiteralPath $script:Paths.Probe)) { return $null }

    $probeArgs = @($script:Paths.Probe, '--json')
    if ($Refresh) { $probeArgs += '--refresh' }

    try {
        $json = (& $python $probeArgs 2>$null | Out-String).Trim()
    } catch {
        return $null
    }
    if (-not $json) { return $null }
    try {
        return ($json | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Format-SherlockProxy {
    [CmdletBinding()]
    param($ProxyInfo)

    if ($null -eq $ProxyInfo) { return '未探测（探测脚本未运行）' }
    if (-not $ProxyInfo.url) {
        if ($ProxyInfo.mode -eq 'off' -or $ProxyInfo.source -eq 'disabled') {
            return '已关闭（直连）'
        }
        if ($ProxyInfo.mode -ne 'auto' -and $ProxyInfo.mode -ne 'unknown') {
            return '指定的代理不可用，已退回直连'
        }
        return '未启用（直连，未验证站点会记为 Unknown）'
    }

    $sourceMap = @{
        config    = '配置指定'
        parameter = '参数指定'
        env       = '环境变量'
        registry  = '系统注册表'
        port      = '端口探测'
        cache     = '缓存'
    }
    $source = $sourceMap[[string]$ProxyInfo.source]
    if (-not $source) { $source = [string]$ProxyInfo.source }

    if ($ProxyInfo.verified -eq 'strong') {
        $tail = '已验证可访问被阻断站点'
    } elseif ($ProxyInfo.verified -eq 'weak') {
        $tail = '可出网，但目标站点仍受限'
    } elseif ($ProxyInfo.verified -eq 'unknown') {
        $tail = '手动指定，未做连通验证'
    } else {
        $tail = '未通过验证'
    }
    $latency = ''
    if ($ProxyInfo.latency_ms) { $latency = "，$($ProxyInfo.latency_ms) ms" }
    return ('{0}（{1}，{2}{3}）' -f $ProxyInfo.url, $source, $tail, $latency)
}

# ---------------------------------------------------------------------
# 版本 / 站点数
# ---------------------------------------------------------------------
function Get-SherlockVersion {
    [CmdletBinding()]
    param()

    try {
        $text = Get-Content -LiteralPath $script:Paths.PyProject -Raw -Encoding UTF8
        if ($text -match '(?m)^\s*version\s*=\s*"([^"]+)"') { return $Matches[1] }
    } catch { }
    return 'unknown'
}

function Get-SherlockSiteCount {
    [CmdletBinding()]
    param()

    try {
        $json = Get-Content -LiteralPath $script:Paths.Sites -Raw -Encoding UTF8 | ConvertFrom-Json
        $count = @($json.PSObject.Properties | Where-Object { $_.Name -notlike '$*' }).Count
        if ($count -gt 0) { return $count }
    } catch { }
    return 0
}

# ---------------------------------------------------------------------
# 运行日志
# ---------------------------------------------------------------------
function New-SherlockRunLog {
    [CmdletBinding()]
    param([string]$Tag = 'run')

    if (-not (Test-Path -LiteralPath $script:Paths.Logs)) {
        New-Item -ItemType Directory -Path $script:Paths.Logs -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:SherlockLogPath = Join-Path $script:Paths.Logs ("{0}-{1}.log" -f $Tag, $stamp)
    Add-Content -LiteralPath $script:SherlockLogPath -Value '=== Sherlock 本地运行日志 ===' -Encoding UTF8
    Add-Content -LiteralPath $script:SherlockLogPath -Value ("时间: {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)) -Encoding UTF8
    return $script:SherlockLogPath
}

function Write-SherlockLog {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Lines)

    if (-not $script:SherlockLogPath) { return }
    foreach ($line in $Lines) {
        Add-Content -LiteralPath $script:SherlockLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------
# 执行 Sherlock
#   输出经 lib\run_sherlock.py（把 stderr 并进 stdout），
#   所以这里面对的是一条干净的文本流：实时显示 + 落日志
# ---------------------------------------------------------------------
function Invoke-SherlockProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Python,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $script:SherlockRoot,
        [string]$LogPath = $null,
        [switch]$Quiet
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = -1

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $Python @Arguments | ForEach-Object {
            $text = [string]$_
            if (-not $Quiet) { Write-Host $text }
            if ($LogPath) {
                Add-Content -LiteralPath $LogPath -Value $text -Encoding UTF8 -ErrorAction SilentlyContinue
            }
        }
        if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
    } catch {
        $message = "[启动失败] $($_.Exception.Message)"
        Write-Host $message -ForegroundColor Red
        if ($LogPath) {
            Add-Content -LiteralPath $LogPath -Value $message -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } finally {
        $stopwatch.Stop()
        Pop-Location
    }

    return [pscustomobject]@{
        ExitCode       = $exitCode
        ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    }
}

# ---------------------------------------------------------------------
# CSV 统计：把明细读成"命中 / 未注册 / 未验证"
# ---------------------------------------------------------------------
function Get-CsvSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $summary = [pscustomobject]@{
        Total     = 0
        Claimed   = 0
        Available = 0
        Unknown   = 0
        Other     = 0
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $summary }

    try {
        $rows = @(Import-Csv -LiteralPath $Path)
    } catch {
        return $summary
    }

    $summary.Total = $rows.Count
    foreach ($row in $rows) {
        $value = [string]$row.exists
        if ($value -eq 'Claimed') { $summary.Claimed++ }
        elseif ($value -eq 'Available') { $summary.Available++ }
        elseif ($value -eq 'Unknown') { $summary.Unknown++ }
        else { $summary.Other++ }
    }
    return $summary
}

# ---------------------------------------------------------------------
# 站点参数解析：支持逗号 / 中文逗号 / 顿号 / 分号 / 空格分隔
# ---------------------------------------------------------------------
function Split-SherlockSites {
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @(
        $Text -split '[,，、;；\s]+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

# ---------------------------------------------------------------------
# 中文对齐：中文字符占两个显示格，PadRight 按字符数算会对不齐
# ---------------------------------------------------------------------
function Get-SherlockDisplayWidth {
    [CmdletBinding()]
    param([string]$Text)

    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

function Format-SherlockLabel {
    [CmdletBinding()]
    param([string]$Text, [int]$Width = 12)

    $pad = $Width - (Get-SherlockDisplayWidth -Text $Text)
    if ($pad -lt 1) { $pad = 1 }
    return ($Text + (' ' * $pad))
}
