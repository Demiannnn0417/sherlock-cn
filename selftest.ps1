# =====================================================================
#  Sherlock 本地部署 —— 自检（selftest）
#  默认自检「国内模式」：4 个自动通道 + 一次真实检索 + CSV/XLSX/日志落盘
#  全部模式：-Mode all，跑一次 test @ GitLab
#  用法：powershell -NoProfile -ExecutionPolicy Bypass -File selftest.ps1 [-Mode cn|all] [-Json]
# =====================================================================
[CmdletBinding()]
param(
    [ValidateSet('cn', 'all')][string]$Mode = 'cn',
    [switch]$Refresh,
    [switch]$Json,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib\common.ps1')
Initialize-SherlockConsole

$paths = $script:Paths
$checks = New-Object System.Collections.ArrayList

function Write-Ui {
    param([string]$Text, [string]$Color = 'Gray')
    if ($Json) { return }
    Write-Host $Text -ForegroundColor $Color
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )
    [void]$checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

function Test-XlsxReadable {
    param([string]$Path)
    try {
        $sheet = (& $paths.Python -c "import sys, openpyxl; wb = openpyxl.load_workbook(sys.argv[1]); print(','.join(wb.sheetnames))" $Path 2>$null | Out-String).Trim()
        return $sheet
    } catch {
        return ''
    }
}

if (-not (Test-Path -LiteralPath $paths.Python)) {
    $payload = [pscustomobject]@{
        checkedAt = (Get-Date).ToString('s')
        summary   = [pscustomobject]@{ ok = 0; warn = 0; fail = 1 }
        checks    = @([pscustomobject]@{ Name = '虚拟环境'; Status = 'FAIL'; Detail = '找不到 .venv\Scripts\python.exe' })
    }
    if ($Json) { $payload | ConvertTo-Json -Depth 5 }
    else { Write-Host '[FAIL] 找不到虚拟环境解释器，请先运行 doctor.ps1 查看原因' -ForegroundColor Red }
    exit 1
}

# 不用 %TEMP%：本机 Python 子进程被限制只能写项目目录（PowerShell 不受限）
$tempDir = Join-Path $paths.State ('selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$logPath = New-SherlockRunLog -Tag 'selftest'
Write-SherlockLog ("模式: {0}" -f $Mode) ("自检目录: {0}" -f $tempDir)

$savedEnv = @{ HTTPS_PROXY = $env:HTTPS_PROXY; HTTP_PROXY = $env:HTTP_PROXY }

if ($Mode -eq 'cn') {
    $cn = Join-Path $paths.Lib 'cn_search.py'
    Write-Ui ''
    Write-Ui '  国内模式自检：4 个自动通道 + 一次真实检索' 'Cyan'

    # 1) 通道自检
    $selfOut = ''
    $selfCode = 1
    try {
        $selfOut = (& $paths.Python $cn --selfcheck 2>&1 | Out-String)
        $selfCode = $LASTEXITCODE
    } catch { }
    $selfLine = ($selfOut.Trim() -split "`r?`n" | Where-Object { $_ -match '个通道可用' } | Select-Object -Last 1)
    if (-not $selfLine) { $selfLine = ($selfOut.Trim() -split "`r?`n" | Select-Object -Last 1) }
    if ($selfCode -eq 0) {
        Add-Check -Name '国内通道' -Status 'OK' -Detail ($selfLine.Trim())
    } else {
        Add-Check -Name '国内通道' -Status 'WARN' -Detail (($selfLine.Trim()) + '（个别平台可能改版或触发风控）')
    }

    # 2) 真实检索：抖音号 douyin 应命中
    $jsonPath = Join-Path $tempDir 'cn.json'
    $csvPath = Join-Path $tempDir 'cn.csv'
    $xlsxPath = Join-Path $tempDir 'cn.xlsx'
    $arguments = @($cn, 'douyin', '--timeout', '15',
        '--json', $jsonPath, '--csv', $csvPath, '--xlsx', $xlsxPath)
    Write-Ui ('  > {0} {1}' -f $paths.Python, ($arguments -join ' ')) 'DarkGray'
    Write-Ui ''
    $result = Invoke-SherlockProcess -Python $paths.Python -Arguments $arguments `
        -WorkingDirectory $tempDir -LogPath $logPath -Quiet:$Json

    if ($result.ExitCode -eq 0) {
        Add-Check -Name '进程退出' -Status 'OK' -Detail ('退出码 0，用时 {0} 秒' -f $result.ElapsedSeconds)
    } else {
        Add-Check -Name '进程退出' -Status 'FAIL' -Detail ('退出码 {0}，详见 {1}' -f $result.ExitCode, $logPath)
    }

    # 3) JSON 结果
    $claimed = 0
    if (Test-Path -LiteralPath $jsonPath) {
        try {
            $payload = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $claimed = [int]$payload.summary.claimed
            Add-Check -Name 'JSON 结果' -Status 'OK' -Detail ('命中 {0} · 未注册 {1} · 待确认 {2}' -f $payload.summary.claimed, $payload.summary.available, $payload.summary.unsupported)
        } catch {
            Add-Check -Name 'JSON 结果' -Status 'FAIL' -Detail '结果 JSON 解析失败'
        }
    } else {
        Add-Check -Name 'JSON 结果' -Status 'FAIL' -Detail '没有生成结果 JSON'
    }

    # 4) 命中判定
    if ($claimed -ge 1) {
        Add-Check -Name '命中判定' -Status 'OK' -Detail '抖音号 douyin 命中'
    } elseif ($claimed -eq 0) {
        Add-Check -Name '命中判定' -Status 'WARN' -Detail '未命中（可能接口变更或该抖音号不存在）'
    }

    # 5) CSV
    if ((Test-Path -LiteralPath $csvPath) -and ((Get-Content -LiteralPath $csvPath -TotalCount 1) -match '^username,platform,identifier,status')) {
        Add-Check -Name 'CSV 导出' -Status 'OK' -Detail ((Split-Path -Leaf $csvPath) + ' 表头正确')
    } else {
        Add-Check -Name 'CSV 导出' -Status 'FAIL' -Detail 'CSV 缺失或表头异常'
    }

    # 6) XLSX
    if (Test-Path -LiteralPath $xlsxPath) {
        $sheets = Test-XlsxReadable -Path $xlsxPath
        if ($sheets) {
            Add-Check -Name 'XLSX 导出' -Status 'OK' -Detail ('工作表 ' + $sheets)
        } else {
            Add-Check -Name 'XLSX 导出' -Status 'FAIL' -Detail 'openpyxl 无法读取'
        }
    } else {
        Add-Check -Name 'XLSX 导出' -Status 'FAIL' -Detail '没有生成 XLSX'
    }
} else {
    # ---- 全部模式：Sherlock + 代理 + GitLab ----
    $proxyInfo = Get-SherlockProxyInfo -Refresh:$Refresh
    $proxyUrl = $null
    if ($proxyInfo) { $proxyUrl = $proxyInfo.url }

    Write-SherlockLog ("代理: {0}" -f (Format-SherlockProxy $proxyInfo))
    Write-Ui ''
    Write-Ui '  全部模式自检：test @ GitLab' 'Cyan'

    $runner = Join-Path $paths.Lib 'run_sherlock.py'
    $arguments = @(
        $runner, 'test',
        '--site', 'GitLab',
        '--print-all',
        '--no-color',
        '--timeout', '20',
        '--csv', '--xlsx',
        '-fo', $tempDir
    )
    if ($proxyUrl) { $arguments += @('--proxy', $proxyUrl) }
    Write-Ui ('  > {0} {1}' -f $paths.Python, ($arguments -join ' ')) 'DarkGray'
    Write-Ui ''

    if ($proxyUrl) {
        $env:HTTPS_PROXY = $proxyUrl
        $env:HTTP_PROXY = $proxyUrl
    }
    try {
        $result = Invoke-SherlockProcess -Python $paths.Python -Arguments $arguments `
            -WorkingDirectory $tempDir -LogPath $logPath -Quiet:$Json
    } finally {
        foreach ($key in @('HTTPS_PROXY', 'HTTP_PROXY')) {
            $previous = $savedEnv[$key]
            if ([string]::IsNullOrEmpty($previous)) {
                Remove-Item -Path ('Env:' + $key) -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path ('Env:' + $key) -Value $previous
            }
        }
    }

    if ($result.ExitCode -eq 0) {
        Add-Check -Name '进程退出' -Status 'OK' -Detail ('退出码 0，用时 {0} 秒' -f $result.ElapsedSeconds)
    } else {
        Add-Check -Name '进程退出' -Status 'FAIL' -Detail ('退出码 {0}，详见 {1}' -f $result.ExitCode, $logPath)
    }

    $csv = @(Get-ChildItem -LiteralPath $tempDir -Filter '*.csv' -File -ErrorAction SilentlyContinue)
    $gitlabRow = $null
    if ($csv.Count -gt 0) {
        $rows = @(Import-Csv -LiteralPath $csv[0].FullName -ErrorAction SilentlyContinue)
        $header = ''
        try { $header = (Get-Content -LiteralPath $csv[0].FullName -TotalCount 1) } catch { }
        if ($header -match '^username,name,url_main,url_user,exists,http_status,response_time_s') {
            Add-Check -Name 'CSV 结构' -Status 'OK' -Detail ('{0} 行 · 表头正确' -f $rows.Count)
        } else {
            Add-Check -Name 'CSV 结构' -Status 'FAIL' -Detail ('表头异常: {0}' -f $header)
        }
        $gitlabRow = $rows | Where-Object { $_.name -eq 'GitLab' } | Select-Object -First 1
    } else {
        Add-Check -Name 'CSV 结构' -Status 'FAIL' -Detail '没有生成 CSV'
    }

    if ($null -ne $gitlabRow) {
        switch ([string]$gitlabRow.exists) {
            'Claimed' { Add-Check -Name '查询结果' -Status 'OK' -Detail ('GitLab 命中：{0}（HTTP {1}）' -f $gitlabRow.url_user, $gitlabRow.http_status) }
            'Available' { Add-Check -Name '查询结果' -Status 'FAIL' -Detail 'GitLab 返回 Available，与预期不符' }
            default { Add-Check -Name '查询结果' -Status 'WARN' -Detail ('GitLab 未验证（{0}）：网络或代理不可用' -f $gitlabRow.http_status) }
        }
    }

    $xlsx = @(Get-ChildItem -LiteralPath $tempDir -Filter '*.xlsx' -File -ErrorAction SilentlyContinue)
    if ($xlsx.Count -gt 0) {
        $sheets = Test-XlsxReadable -Path $xlsx[0].FullName
        if ($sheets) {
            Add-Check -Name 'XLSX 可打开' -Status 'OK' -Detail ('工作表 ' + $sheets)
        } else {
            Add-Check -Name 'XLSX 可打开' -Status 'FAIL' -Detail 'openpyxl 无法读取生成的文件'
        }
    } else {
        Add-Check -Name 'XLSX 可打开' -Status 'FAIL' -Detail '没有生成 XLSX'
    }
}

if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -gt 64)) {
    Add-Check -Name '运行日志' -Status 'OK' -Detail $logPath
} else {
    Add-Check -Name '运行日志' -Status 'FAIL' -Detail '日志为空或未写入'
}

if (-not $KeepTemp) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
} elseif (-not $Json) {
    Write-Ui ('  临时目录保留：{0}' -f $tempDir) 'DarkGray'
}

# ---------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------
$okCount = @($checks | Where-Object { $_.Status -eq 'OK' }).Count
$warnCount = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count
$failCount = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count

if ($Json) {
    [pscustomobject]@{
        checkedAt = (Get-Date).ToString('s')
        mode      = $Mode
        log       = $logPath
        summary   = [pscustomobject]@{ ok = $okCount; warn = $warnCount; fail = $failCount }
        checks    = $checks
    } | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host ('  Sherlock 自检结果（{0}模式）' -f $(if ($Mode -eq 'cn') { '国内' } else { '全部' })) -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    foreach ($check in $checks) {
        $color = 'Green'
        $tag = 'OK  '
        if ($check.Status -eq 'WARN') { $color = 'Yellow'; $tag = 'WARN' }
        if ($check.Status -eq 'FAIL') { $color = 'Red';    $tag = 'FAIL' }
        Write-Host ('  [{0}] ' -f $tag) -ForegroundColor $color -NoNewline
        Write-Host (Format-SherlockLabel -Text $check.Name -Width 12) -NoNewline
        Write-Host (' {0}' -f $check.Detail) -ForegroundColor DarkGray
    }
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    $summaryColor = 'Green'
    if ($failCount -gt 0) { $summaryColor = 'Red' } elseif ($warnCount -gt 0) { $summaryColor = 'Yellow' }
    Write-Host ('  结果：{0} 项通过 · {1} 项警告 · {2} 项失败' -f $okCount, $warnCount, $failCount) -ForegroundColor $summaryColor
    Write-Host ('  日志：{0}' -f $logPath) -ForegroundColor DarkGray
    Write-Host ''
}

if ($failCount -gt 0) { exit 1 }
exit 0
