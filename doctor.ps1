# =====================================================================
#  Sherlock 本地部署 —— 体检（doctor）
#  一条命令回答："这台机器上它还跑得起来吗？"
#  用法：powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 [-Refresh] [-Json]
# =====================================================================
[CmdletBinding()]
param(
    [switch]$Refresh,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib\common.ps1')
Initialize-SherlockConsole

$paths = $script:Paths
$checks = New-Object System.Collections.ArrayList

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )
    [void]$checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

function Invoke-PythonQuiet {
    param([string]$Code)
    try {
        $out = & $paths.Python -c $Code 2>$null
        if ($null -eq $out) { return '' }
        return ([string]($out | Select-Object -First 1)).Trim()
    } catch {
        return ''
    }
}

# 1) 项目文件 -----------------------------------------------------------
$missing = @()
foreach ($item in @($paths.PyProject, (Join-Path $paths.Root 'sherlock_project\sherlock.py'), $paths.Sites)) {
    if (-not (Test-Path -LiteralPath $item)) { $missing += (Split-Path -Leaf $item) }
}
if ($missing.Count -eq 0) {
    Add-Check -Name '项目文件' -Status 'OK' -Detail 'pyproject.toml / sherlock.py / data.json 齐全'
} else {
    Add-Check -Name '项目文件' -Status 'FAIL' -Detail ('缺少: ' + ($missing -join ', '))
}

# 1b) 安装位置 ---------------------------------------------------------
if ($paths.Root -like 'C:\Users\*') {
    Add-Check -Name '安装位置' -Status 'WARN' -Detail ($paths.Root + '（在系统盘用户目录，建议迁到其他盘）')
} else {
    Add-Check -Name '安装位置' -Status 'OK' -Detail $paths.Root
}

# 2) 解释器 -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $paths.Python)) {
    Add-Check -Name 'Python 解释器' -Status 'FAIL' -Detail ('找不到 ' + $paths.Python)
    $pythonOk = $false
} else {
    $pythonOk = $true
    $pyVersion = Invoke-PythonQuiet -Code 'import sys; print(sys.version.split()[0])'
    if ($pyVersion) {
        $pythonHome = ''
        try {
            $cfg = Get-Content -LiteralPath (Join-Path $paths.Root '.venv\pyvenv.cfg') -Raw
            if ($cfg -match '(?m)^home\s*=\s*(.+)$') { $pythonHome = $Matches[1].Trim() }
        } catch { }
        $detail = "Python $pyVersion"
        if ($pythonHome) { $detail += " · 解释器来源 $pythonHome" }
        if ($pythonHome -match '\\\.dsh\\') {
            Add-Check -Name 'Python 解释器' -Status 'WARN' -Detail ($detail + '（依赖 DSH 运行时，DSH 升级后可能失效）')
        } else {
            Add-Check -Name 'Python 解释器' -Status 'OK' -Detail $detail
        }
    } else {
        Add-Check -Name 'Python 解释器' -Status 'FAIL' -Detail '虚拟环境无法启动'
    }
}

# 3) sherlock 包 --------------------------------------------------------
if ($pythonOk) {
    $pkgVersion = Invoke-PythonQuiet -Code 'import sherlock_project as s; print(s.get_version())'
    if ($pkgVersion) {
        Add-Check -Name 'Sherlock 包' -Status 'OK' -Detail ("v$pkgVersion 已安装（可编辑模式）")
    } else {
        Add-Check -Name 'Sherlock 包' -Status 'FAIL' -Detail '无法 import sherlock_project，请重装依赖'
    }
} else {
    Add-Check -Name 'Sherlock 包' -Status 'FAIL' -Detail '解释器不可用，跳过'
}

# 4) 本地补丁 -----------------------------------------------------------
if (Test-Path -LiteralPath $paths.SitesPy) {
    $sitePy = Get-Content -LiteralPath $paths.SitesPy -Raw -Encoding UTF8
    $hasMarker = ($sitePy -match 'BUNDLED_DATA_FILE') -and ($sitePy -match 'bundled site list')
    $hash = ''
    try { $hash = (Get-FileHash -LiteralPath $paths.SitesPy -Algorithm SHA256).Hash.Substring(0, 12) } catch { }
    if ($hasMarker) {
        Add-Check -Name '本地补丁' -Status 'OK' -Detail ("离线站点库回退已生效（sites.py sha256:$hash）")
    } else {
        Add-Check -Name '本地补丁' -Status 'FAIL' -Detail 'sites.py 里找不到回退逻辑，启动会因在线站点库失败而退出'
    }
} else {
    Add-Check -Name '本地补丁' -Status 'FAIL' -Detail 'sites.py 不存在'
}

# 5) 站点库 -------------------------------------------------------------
$siteCount = Get-SherlockSiteCount
if ($siteCount -ge 450) {
    Add-Check -Name '站点库' -Status 'OK' -Detail ("$siteCount 个站点")
} elseif ($siteCount -gt 0) {
    Add-Check -Name '站点库' -Status 'WARN' -Detail ("只有 $siteCount 个站点，可能被截断")
} else {
    Add-Check -Name '站点库' -Status 'FAIL' -Detail 'data.json 解析失败'
}

# 6) 代理 ---------------------------------------------------------------
$proxyInfo = Get-SherlockProxyInfo -Refresh:$Refresh
$proxyText = Format-SherlockProxy $proxyInfo
if ($null -eq $proxyInfo) {
    Add-Check -Name '代理探测' -Status 'WARN' -Detail '探测脚本未返回结果，将直连'
} elseif ($proxyInfo.url -and $proxyInfo.verified -eq 'strong') {
    Add-Check -Name '代理探测' -Status 'OK' -Detail $proxyText
} elseif ($proxyInfo.url) {
    Add-Check -Name '代理探测' -Status 'WARN' -Detail $proxyText
} else {
    Add-Check -Name '代理探测' -Status 'WARN' -Detail ($proxyText + '；被阻断站点会记为 Unknown')
}

# 6b) 国内通道 ----------------------------------------------------------
$cnScript = Join-Path $paths.Lib 'cn_search.py'
if (Test-Path -LiteralPath $cnScript) {
    $cnOut = ''
    $cnCode = 1
    try {
        $cnOut = (& $paths.Python $cnScript --selfcheck 2>&1 | Out-String)
        $cnCode = $LASTEXITCODE
    } catch { }
    $cnLine = ($cnOut.Trim() -split "`r?`n" | Where-Object { $_ -match '个通道可用' } | Select-Object -Last 1)
    if (-not $cnLine) { $cnLine = ($cnOut.Trim() -split "`r?`n" | Select-Object -Last 1) }
    if ($cnCode -eq 0) {
        Add-Check -Name '国内通道' -Status 'OK' -Detail $cnLine.Trim()
    } else {
        Add-Check -Name '国内通道' -Status 'WARN' -Detail ($cnLine.Trim() + '（平台可能改版或触发风控）')
    }
} else {
    Add-Check -Name '国内通道' -Status 'FAIL' -Detail 'lib\cn_search.py 不存在'
}

# 7) 结果目录可写 -------------------------------------------------------
$desktop = [Environment]::GetFolderPath('Desktop')
try {
    $probeFile = Join-Path $desktop ('.sherlock-write-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    Set-Content -LiteralPath $probeFile -Value 'ok' -Encoding ASCII -ErrorAction Stop
    Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    Add-Check -Name '桌面可写' -Status 'OK' -Detail $desktop
} catch {
    Add-Check -Name '桌面可写' -Status 'FAIL' -Detail ("无法写入 $desktop，结果会保存失败")
}

# 8) 快捷方式 -----------------------------------------------------------
$lnkPath = Join-Path $desktop 'Sherlock.lnk'
if (Test-Path -LiteralPath $lnkPath) {
    $lnkOk = $false
    $lnkDetail = ''
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $target = [string]$shortcut.TargetPath
        $arguments = [string]$shortcut.Arguments
        $scriptPath = ''
        if ($arguments -match '-File\s+"?([^"]+\.ps1)"?') { $scriptPath = $Matches[1] }
        $scriptOk = $scriptPath -and (Test-Path -LiteralPath $scriptPath)
        $lnkOk = (Test-Path -LiteralPath $target) -and $scriptOk
        $lnkDetail = ('目标 {0} · 脚本 {1}' -f $target, $(if ($scriptPath) { $scriptPath } else { '(未解析到)' }))
        if (-not $scriptOk) { $lnkDetail += '（脚本不存在，快捷方式需要重建）' }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    } catch {
        $lnkDetail = '读取快捷方式失败: ' + $_.Exception.Message
    }
    if ($lnkOk) {
        Add-Check -Name '桌面快捷方式' -Status 'OK' -Detail ('Sherlock.lnk → ' + $scriptPath)
    } else {
        Add-Check -Name '桌面快捷方式' -Status 'FAIL' -Detail $lnkDetail
    }
} else {
    Add-Check -Name '桌面快捷方式' -Status 'WARN' -Detail '未找到 Sherlock.lnk（命令行仍可用）'
}

# 9) 日志目录 -----------------------------------------------------------
try {
    if (-not (Test-Path -LiteralPath $paths.Logs)) {
        New-Item -ItemType Directory -Path $paths.Logs -Force | Out-Null
    }
    $probeLog = Join-Path $paths.Logs ('.write-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    Set-Content -LiteralPath $probeLog -Value 'ok' -Encoding ASCII -ErrorAction Stop
    Remove-Item -LiteralPath $probeLog -Force -ErrorAction SilentlyContinue
    Add-Check -Name '日志目录' -Status 'OK' -Detail $paths.Logs
} catch {
    Add-Check -Name '日志目录' -Status 'FAIL' -Detail ('无法写入 ' + $paths.Logs)
}

# 10) 运行环境 ----------------------------------------------------------
$psVersion = $PSVersionTable.PSVersion.ToString()
$policy = 'Unknown'
try { $policy = (Get-ExecutionPolicy -Scope CurrentUser).ToString() } catch { }
$encoding = 'unknown'
try { $encoding = [Console]::OutputEncoding.WebName } catch { }
Add-Check -Name '运行环境' -Status 'OK' -Detail ("PowerShell $psVersion · ExecutionPolicy $policy · 控制台编码 $encoding · PYTHONIOENCODING=$env:PYTHONIOENCODING")

$freeGb = 0
$driveName = 'C'
try {
    $driveName = (Split-Path -Qualifier $paths.Root).TrimEnd(':')
    $freeGb = [math]::Round((Get-PSDrive -Name $driveName).Free / 1GB, 1)
} catch { }
if ($freeGb -ge 1) {
    Add-Check -Name '磁盘空间' -Status 'OK' -Detail ("{0}: 剩余 {1} GB" -f $driveName, $freeGb)
} else {
    Add-Check -Name '磁盘空间' -Status 'WARN' -Detail ("{0}: 只剩 {1} GB" -f $driveName, $freeGb)
}

# ---------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------
$okCount = @($checks | Where-Object { $_.Status -eq 'OK' }).Count
$warnCount = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
$failCount = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count

if ($Json) {
    [pscustomobject]@{
        checkedAt = (Get-Date).ToString('s')
        summary   = [pscustomobject]@{ ok = $okCount; warn = $warnCount; fail = $failCount }
        checks    = $checks
    } | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host '  Sherlock 本地部署体检' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    foreach ($check in $checks) {
        $color = 'Green'
        $tag = 'OK  '
        if ($check.Status -eq 'WARN') { $color = 'Yellow'; $tag = 'WARN' }
        if ($check.Status -eq 'FAIL') { $color = 'Red';    $tag = 'FAIL' }
        Write-Host ("  [{0}] " -f $tag) -ForegroundColor $color -NoNewline
        Write-Host (Format-SherlockLabel -Text $check.Name -Width 12) -NoNewline
        Write-Host (" {0}" -f $check.Detail) -ForegroundColor DarkGray
    }
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    $summaryColor = 'Green'
    if ($failCount -gt 0) { $summaryColor = 'Red' } elseif ($warnCount -gt 0) { $summaryColor = 'Yellow' }
    Write-Host ("  结果：{0} 项通过 · {1} 项警告 · {2} 项失败" -f $okCount, $warnCount, $failCount) -ForegroundColor $summaryColor
    if ($failCount -gt 0) {
        Write-Host '  先修失败项；需要重建依赖时见 LOCAL-DEPLOY.md 第 7 节。' -ForegroundColor DarkGray
    }
    Write-Host ''
}

if ($failCount -gt 0) { exit 1 }
exit 0
