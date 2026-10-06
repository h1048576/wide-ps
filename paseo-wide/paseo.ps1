param(
    [ValidatePattern('^[0-9]{2,4}(?:\.[0-9]+)?(?:rem|px|vw)$')]
    [string]$Width = '80rem',

    [ValidateRange(100, 1000)]
    [int]$FontWeight = 300,

    [ValidateRange(1024, 65535)]
    [int]$Port = 9335,

    [ValidateSet(0, 1)]
    [int]$HideLocalMerge = 1,

    [ValidateSet(0, 1)]
    [int]$HideGitDiff = 1,

    [switch]$Normal,

    [switch]$Background,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

if ($Background) {
    try {
        $scriptRoot = Split-Path -Parent $PSCommandPath
        $logRoot = Join-Path $env:LOCALAPPDATA 'PaseoWide'
        [void][IO.Directory]::CreateDirectory($logRoot)
        $outputLog = Join-Path $logRoot 'paseo-wide.log'
        $powerShellExecutable = Join-Path $PSHOME 'powershell.exe'
        $quotedScriptPath = '"' + $PSCommandPath + '"'
        $quotedLogPath = '"' + $outputLog + '"'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -Width $Width -FontWeight $FontWeight -Port $Port -HideLocalMerge $HideLocalMerge -HideGitDiff $HideGitDiff -LogPath $quotedLogPath"
        if ($Normal) { $arguments += ' -Normal' }

        Start-Process `
            -FilePath $powerShellExecutable `
            -ArgumentList $arguments `
            -WorkingDirectory $scriptRoot `
            -WindowStyle Hidden `
            -ErrorAction Stop | Out-Null

        Write-Host '[Paseo Wide] 已在后台启动。' -ForegroundColor Cyan
        Write-Host "[Paseo Wide] 运行日志：$outputLog" -ForegroundColor Cyan
        exit 0
    } catch {
        Write-Host "[Paseo Wide] 后台启动失败：$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$script:transcriptStarted = $false
if ($LogPath) {
    $resolvedLogPath = [IO.Path]::GetFullPath($LogPath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedLogPath))
    Start-Transcript -LiteralPath $resolvedLogPath -Force | Out-Null
    $script:transcriptStarted = $true
}

function Stop-RunTranscript {
    if (-not $script:transcriptStarted) { return }
    try { Stop-Transcript | Out-Null } catch {}
    $script:transcriptStarted = $false
}

function Write-Step([string]$Message) {
    Write-Host "[Paseo Wide] $Message" -ForegroundColor Cyan
}

function Get-PaseoApplication {
    $executableCandidates = New-Object 'System.Collections.Generic.List[string]'
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $uninstallEntries = @(Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue | Where-Object {
        "$($_.DisplayName)" -match '(?i)^Paseo(?:\s|$)'
    })
    foreach ($entry in $uninstallEntries) {
        $displayIcon = "$($entry.DisplayIcon)".Trim()
        if ($displayIcon -match '^"([^"]+\.exe)"') {
            $executableCandidates.Add($matches[1])
        } elseif ($displayIcon -match '^(.+?\.exe)(?:,\d+)?$') {
            $executableCandidates.Add($matches[1])
        }

        $installLocation = "$($entry.InstallLocation)".Trim().Trim('"')
        if ($installLocation) {
            $executableCandidates.Add((Join-Path $installLocation 'Paseo.exe'))
        }
    }

    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Paseo\Paseo.exe'))
    $executableCandidates.Add((Join-Path $env:ProgramFiles 'Paseo\Paseo.exe'))
    if (${env:ProgramFiles(x86)}) {
        $executableCandidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Paseo\Paseo.exe'))
    }

    $executable = $executableCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Select-Object -Unique -First 1

    if (-not $executable) {
        throw '没有找到 Windows 版 Paseo，请先安装 Paseo 桌面应用。'
    }

    $file = Get-Item -LiteralPath $executable -ErrorAction Stop
    $version = "$($file.VersionInfo.ProductVersion)".Trim()
    if (-not $version) { $version = "$($file.VersionInfo.FileVersion)".Trim() }
    if (-not $version) { $version = '未知版本' }

    [pscustomobject]@{
        Executable  = $file.FullName
        InstallRoot = $file.DirectoryName
        ProcessName = $file.Name
        Version     = $version
    }
}

function Start-Paseo([object]$Paseo, [string[]]$Arguments = @()) {
    $hadOriginalFlags = Test-Path Env:\PASEO_ELECTRON_FLAGS
    $originalFlags = $env:PASEO_ELECTRON_FLAGS
    $launchFlags = @(
        @("$originalFlags" -split '\s+' | Where-Object {
            $_ -and $_ -notmatch '(?i)^--remote-debugging-(?:address|port)='
        })
        $Arguments
    )

    try {
        if ($launchFlags.Count -gt 0) {
            $env:PASEO_ELECTRON_FLAGS = $launchFlags -join ' '
        } else {
            Remove-Item Env:\PASEO_ELECTRON_FLAGS -ErrorAction SilentlyContinue
        }
        Start-Process -FilePath $Paseo.Executable -WorkingDirectory $Paseo.InstallRoot -ErrorAction Stop | Out-Null
    } finally {
        if ($hadOriginalFlags) {
            $env:PASEO_ELECTRON_FLAGS = $originalFlags
        } else {
            Remove-Item Env:\PASEO_ELECTRON_FLAGS -ErrorAction SilentlyContinue
        }
    }
}

function Get-PaseoProcesses([object]$Paseo) {
    $root = $Paseo.InstallRoot.TrimEnd('\') + '\'
    $processName = $Paseo.ProcessName.Replace("'", "''")
    @(Get-CimInstance Win32_Process -Filter "Name = '$processName'" -ErrorAction SilentlyContinue | Where-Object {
        $path = "$($_.ExecutablePath)"
        $path -and $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-Paseo([object]$Paseo) {
    $procs = @(Get-PaseoProcesses $Paseo)
    if ($procs.Count -eq 0) { return }

    Write-Step '正在关闭已运行的 Paseo…'
    foreach ($p in $procs) {
        try { [void](Get-Process -Id $p.ProcessId -ErrorAction Stop).CloseMainWindow() } catch {}
    }

    $deadline = (Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 250
        $left = @(Get-PaseoProcesses $Paseo)
    } while ($left.Count -gt 0 -and (Get-Date) -lt $deadline)

    foreach ($p in @(Get-PaseoProcesses $Paseo)) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Milliseconds 500
}

function Test-PortFree([int]$Candidate) {
    $listener = $null
    try {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Candidate)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch {} }
    }
}

function Select-Port([int]$Preferred) {
    for ($p = $Preferred; $p -le [Math]::Min(65535, $Preferred + 50); $p++) {
        if (Test-PortFree $p) { return $p }
    }
    throw "从 $Preferred 开始的 51 个本地端口都不可用。"
}

function Get-CdpTargets([int]$CdpPort) {
    $response = $null
    $reader = $null
    try {
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$CdpPort/json/list")
        $request.Proxy = $null
        $request.Timeout = 1000
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        $targets = @($reader.ReadToEnd() | ConvertFrom-Json)
        @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl })
    } catch {
        @()
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Wait-Cdp([int]$CdpPort, [int]$Seconds = 10) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $targets = @(Get-CdpTargets $CdpPort)
        if ($targets.Count -gt 0) { return $targets }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    @()
}

function Invoke-CdpCommand([string]$WebSocketUrl, [string]$Method, [hashtable]$Params) {
    $ws = [Net.WebSockets.ClientWebSocket]::new()
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(3))
    try {
        try { $ws.Options.Proxy = [Net.WebProxy]::new() } catch {}
        [void]$ws.ConnectAsync([Uri]$WebSocketUrl, $cts.Token).GetAwaiter().GetResult()
        $payload = @{
            id     = Get-Random -Minimum 1000 -Maximum 999999
            method = $Method
            params = $Params
        } | ConvertTo-Json -Compress -Depth 8

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [ArraySegment[byte]]::new($bytes)
        [void]$ws.SendAsync(
            $segment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cts.Token
        ).GetAwaiter().GetResult()

        # Read one response so Chromium has processed the command before we disconnect.
        $buffer = New-Object byte[] 65536
        $receiveSegment = [ArraySegment[byte]]::new($buffer)
        [void]$ws.ReceiveAsync($receiveSegment, $cts.Token).GetAwaiter().GetResult()
    } finally {
        try {
            if ($ws.State -eq [Net.WebSockets.WebSocketState]::Open) {
                [void]$ws.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'done',
                    [Threading.CancellationToken]::None
                ).GetAwaiter().GetResult()
            }
        } catch {}
        $ws.Dispose()
        $cts.Dispose()
    }
}

function Inject-WideUi(
    [object[]]$Targets,
    [string]$ContentWidth,
    [int]$ContentFontWeight,
    [int]$ShouldHideLocalMerge,
    [int]$ShouldHideGitDiff
) {
    $safeWidth = $ContentWidth.Replace("'", "")
    $hiddenUiRules = @()
    if ($ShouldHideLocalMerge) {
        $hiddenUiRules += @"
[data-testid="changes-primary-cta"],
[data-testid="changes-primary-cta-caret"] {
    display: none !important;
}
"@
    }
    if ($ShouldHideGitDiff) {
        $hiddenUiRules += @"
[data-testid="composer-diff-stat-pill"] {
    display: none !important;
}
"@
    }

    $hiddenUiCss = $hiddenUiRules -join [Environment]::NewLine
    $css = @"
:root,
body,
body * {
    font-weight: $ContentFontWeight !important;
}

[data-paseo-wide-content] {
    max-width: $safeWidth !important;
}
$hiddenUiCss
"@

    # JavaScript string is JSON-encoded to avoid quote/escape problems.
    $cssJson = $css | ConvertTo-Json -Compress
    $script = @"
(() => {
  const installContentWidthGuard = () => {
    const guardKey = '__paseoWideContentGuard';
    const marker = 'data-paseo-wide-content';
    const defaultMaxWidth = '820px';
    if (window[guardKey]) {
      window[guardKey].scan();
      return;
    }

    const queuedRoots = new Set();
    let scanScheduled = false;

    const markContentNodes = (root) => {
      if (!(root instanceof Element)) return;
      const candidates = [root, ...root.querySelectorAll('*')];
      candidates.forEach((element) => {
        if (element.hasAttribute(marker)) return;
        if (getComputedStyle(element).maxWidth === defaultMaxWidth) {
          element.setAttribute(marker, '');
        }
      });
    };

    const flushScan = () => {
      scanScheduled = false;
      const roots = Array.from(queuedRoots);
      queuedRoots.clear();
      roots.forEach((root) => {
        if (root.isConnected) markContentNodes(root);
      });
    };

    const scheduleScan = (root = document.documentElement) => {
      if (!(root instanceof Element)) return;
      queuedRoots.add(root);
      if (scanScheduled) return;
      scanScheduled = true;
      window.requestAnimationFrame(flushScan);
    };

    const observer = new MutationObserver((records) => {
      records.forEach((record) => {
        if (record.type === 'attributes') scheduleScan(record.target);
        record.addedNodes.forEach((node) => scheduleScan(node));
      });
    });
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class', 'style'],
      childList: true,
      subtree: true,
    });

    window[guardKey] = { observer, scan: scheduleScan };
    scheduleScan();
    [250, 1000, 3000].forEach((delay) => {
      window.setTimeout(() => scheduleScan(document.documentElement), delay);
    });
  };

  const apply = () => {
    const id = 'paseo-wide-width-override';
    let style = document.getElementById(id);
    if (!style) {
      style = document.createElement('style');
      style.id = id;
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = $cssJson;
    installContentWidthGuard();
    return true;
  };
  if (document.head || document.documentElement) return apply();
  document.addEventListener('DOMContentLoaded', apply, { once: true });
  return true;
})();
"@

    foreach ($target in $Targets) {
        # Apply now.
        Invoke-CdpCommand $target.webSocketDebuggerUrl 'Runtime.evaluate' @{
            expression    = $script
            returnByValue = $true
        }

        # Re-apply automatically when this renderer reloads/navigates.
        Invoke-CdpCommand $target.webSocketDebuggerUrl 'Page.addScriptToEvaluateOnNewDocument' @{
            source = $script
        }
    }
}

try {
    $paseo = Get-PaseoApplication
    Write-Step "检测到 Paseo $($paseo.Version)"

    Stop-Paseo $paseo

    if ($Normal) {
        Write-Step '正在正常启动 Paseo（恢复默认宽度和字重，不开放 CDP）…'
        Start-Paseo $paseo
        Write-Step '完成。'
        Stop-RunTranscript
        exit 0
    }

    $Port = Select-Port $Port
    Write-Step "对话区目标宽度：$Width"
    Write-Step "字重：$FontWeight"
    Write-Step "本地 merge：$(if ($HideLocalMerge) { '隐藏' } else { '显示' })"
    Write-Step "git diff 统计：$(if ($HideGitDiff) { '隐藏' } else { '显示' })"
    Write-Host '[Paseo Wide] 注意：本次 Paseo 运行期间会开放仅限 127.0.0.1 的 Chromium CDP 调试端口。' -ForegroundColor Yellow

    $debugArgs = @(
        '--remote-debugging-address=127.0.0.1',
        "--remote-debugging-port=$Port"
    )

    Write-Step "正在启动 Paseo（CDP 端口 $Port）…"
    Start-Paseo $paseo $debugArgs
    $targets = @(Wait-Cdp $Port 12)

    if ($targets.Count -eq 0) {
        throw "Paseo 未在 http://127.0.0.1:$Port 提供可用的 CDP page target。请关闭由其他安装目录或开发环境启动的 Paseo 后重试。"
    }

    Inject-WideUi $targets $Width $FontWeight $HideLocalMerge $HideGitDiff
    Write-Step "注入成功：Paseo 内容区宽度已设为 $Width，字重已设为 $FontWeight。"
    Write-Step '以后用 wide.sh 启动即可；要恢复默认宽度和字重，运行 normal.sh。'
    Start-Sleep -Seconds 1
    Stop-RunTranscript
    exit 0
} catch {
    Write-Host "[Paseo Wide] 失败：$($_.Exception.Message)" -ForegroundColor Red
    Stop-RunTranscript
    exit 1
}
