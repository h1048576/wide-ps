param(
    [ValidatePattern('^(?:auto|fit-content|(?:0|[1-9][0-9]{0,3})(?:\.[0-9]+)?(?:px|rem|em|vw|vh|%))$')]
    [string]$Width = '100%',

    [ValidatePattern('^(?:none|(?:0|[1-9][0-9]{0,3})(?:\.[0-9]+)?(?:px|rem|em|vw|vh|%))$')]
    [string]$MaxWidth = '90rem',

    [ValidatePattern('^(?:auto|(?:0|[1-9][0-9]{0,3})(?:\.[0-9]+)?(?:px|rem|em|vh|%))$')]
    [string]$ChatHeight = '120px',

    [ValidateRange(8, 72)]
    [int]$FontSize = 18,

    [ValidateRange(100, 1000)]
    [int]$FontWeight = 300,

    [ValidateScript({ $_ -and $_ -notmatch '[;{}<>\r\n]' })]
    [string]$FontFamily = 'Cascadia Mono, LXGW WenKai Mono',

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

if (-not ('DroidWide.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DroidWide
{
    public static class NativeMethods
    {
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsZoomed(IntPtr hWnd);
    }
}
'@
}

if ($Background) {
    try {
        $scriptRoot = Split-Path -Parent $PSCommandPath
        $logRoot = Join-Path $env:LOCALAPPDATA 'DroidWide'
        [void][IO.Directory]::CreateDirectory($logRoot)
        $outputLog = Join-Path $logRoot 'droid-wide.log'
        $powerShellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
        $quotedScriptPath = '"' + $PSCommandPath + '"'
        $quotedLogPath = '"' + $outputLog + '"'
        $quotedWidth = '"' + $Width + '"'
        $quotedMaxWidth = '"' + $MaxWidth + '"'
        $quotedChatHeight = '"' + $ChatHeight + '"'
        $quotedFontFamily = '"' + $FontFamily.Replace('"', '\"') + '"'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -Width $quotedWidth -MaxWidth $quotedMaxWidth -ChatHeight $quotedChatHeight -FontSize $FontSize -FontWeight $FontWeight -FontFamily $quotedFontFamily -Port $Port -HideLocalMerge $HideLocalMerge -HideGitDiff $HideGitDiff -LogPath $quotedLogPath"
        if ($Normal) { $arguments += ' -Normal' }

        Start-Process `
            -FilePath $powerShellExecutable `
            -ArgumentList $arguments `
            -WorkingDirectory $scriptRoot `
            -WindowStyle Hidden `
            -ErrorAction Stop | Out-Null

        Write-Host '[Droid Wide] 已在后台启动。' -ForegroundColor Cyan
        Write-Host "[Droid Wide] 运行日志：$outputLog" -ForegroundColor Cyan
        exit 0
    } catch {
        Write-Host "[Droid Wide] 后台启动失败：$($_.Exception.Message)" -ForegroundColor Red
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
    Write-Host "[Droid Wide] $Message" -ForegroundColor Cyan
}

function Get-DroidApplication {
    $executableCandidates = New-Object 'System.Collections.Generic.List[string]'
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $uninstallEntries = @(Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue | Where-Object {
        "$($_.DisplayName)" -match '(?i)^(?:Droid|Factory)(?:\s|$)'
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
            @('factory-desktop.exe', 'droid-desktop.exe', 'Droid.exe', 'Factory.exe') | ForEach-Object {
                $executableCandidates.Add((Join-Path $installLocation $_))
            }
        }
    }

    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Factory\factory-desktop.exe'))
    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Droid\droid-desktop.exe'))
    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Droid\Droid.exe'))
    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Droid\Droid.exe'))
    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Factory\factory-desktop.exe'))
    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Factory\Factory.exe'))
    $executableCandidates.Add((Join-Path $env:ProgramFiles 'Droid\droid-desktop.exe'))
    $executableCandidates.Add((Join-Path $env:ProgramFiles 'Droid\Droid.exe'))
    $executableCandidates.Add((Join-Path $env:ProgramFiles 'Factory\factory-desktop.exe'))
    $executableCandidates.Add((Join-Path $env:ProgramFiles 'Factory\Factory.exe'))
    if (${env:ProgramFiles(x86)}) {
        $executableCandidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Droid\droid-desktop.exe'))
        $executableCandidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Droid\Droid.exe'))
        $executableCandidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Factory\factory-desktop.exe'))
        $executableCandidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Factory\Factory.exe'))
    }

    $executable = $executableCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Select-Object -Unique -First 1

    if (-not $executable) {
        throw '没有找到 Windows 版 Droid/Factory，请先安装 Factory 桌面应用。'
    }

    $file = Get-Item -LiteralPath $executable -ErrorAction Stop
    $version = "$($file.VersionInfo.ProductVersion)".Trim()
    if (-not $version) { $version = "$($file.VersionInfo.FileVersion)".Trim() }
    if (-not $version) { $version = '未知版本' }
    $applicationName = "$($file.VersionInfo.ProductName)".Trim()
    if (-not $applicationName) { $applicationName = 'Droid/Factory' }

    [pscustomobject]@{
        ApplicationName = $applicationName
        Executable      = $file.FullName
        InstallRoot     = $file.DirectoryName
        ProcessName     = $file.Name
        Version         = $version
    }
}

function Start-Droid([object]$Droid, [string[]]$Arguments = @()) {
    $startProcessArguments = @{
        FilePath         = $Droid.Executable
        WorkingDirectory = $Droid.InstallRoot
        WindowStyle      = 'Maximized'
        ErrorAction      = 'Stop'
    }
    if ($Arguments.Count -gt 0) {
        $startProcessArguments.ArgumentList = $Arguments
    }
    Start-Process @startProcessArguments | Out-Null
}

function Get-DroidProcesses([object]$Droid) {
    $root = $Droid.InstallRoot.TrimEnd('\') + '\'
    $processName = $Droid.ProcessName.Replace("'", "''")
    @(Get-CimInstance Win32_Process -Filter "Name = '$processName'" -ErrorAction SilentlyContinue | Where-Object {
        $path = "$($_.ExecutablePath)"
        $path -and $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Set-DroidWindowMaximized([object]$Droid, [int]$Seconds = 12) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        foreach ($processInfo in @(Get-DroidProcesses $Droid)) {
            try {
                $process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue
                if (-not $process) { continue }
                $process.Refresh()
                $windowHandle = $process.MainWindowHandle
                if ($windowHandle -eq [IntPtr]::Zero) { continue }

                if (-not [DroidWide.NativeMethods]::IsZoomed($windowHandle)) {
                    [void][DroidWide.NativeMethods]::ShowWindowAsync($windowHandle, 3)
                    Start-Sleep -Milliseconds 150
                    $process.Refresh()
                    $windowHandle = $process.MainWindowHandle
                }

                if ($windowHandle -ne [IntPtr]::Zero -and [DroidWide.NativeMethods]::IsZoomed($windowHandle)) {
                    return
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    throw "未能在 $Seconds 秒内最大化 $($Droid.ApplicationName) 主窗口。"
}

function Stop-Droid([object]$Droid) {
    $procs = @(Get-DroidProcesses $Droid)
    if ($procs.Count -eq 0) { return }

    Write-Step "正在关闭已运行的 $($Droid.ApplicationName)…"
    foreach ($p in $procs) {
        $process = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($process) { try { [void]$process.CloseMainWindow() } catch {} }
    }

    $deadline = (Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 250
        $left = @(Get-DroidProcesses $Droid)
    } while ($left.Count -gt 0 -and (Get-Date) -lt $deadline)

    foreach ($p in @(Get-DroidProcesses $Droid)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
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
    $stream = $null
    $reader = $null
    try {
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$CdpPort/json/list")
        $request.Proxy = $null
        $request.Timeout = 1000
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        if (-not $stream -or -not $stream.CanRead) { return @() }
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
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

function Inject-DroidUi(
    [object[]]$Targets,
    [string]$ContentWidth,
    [string]$ContentMaxWidth,
    [string]$ContentChatHeight,
    [string]$ContentFontFamily,
    [int]$ContentFontSize,
    [int]$ContentFontWeight,
    [int]$ShouldHideLocalMerge,
    [int]$ShouldHideGitDiff
) {
    $safeWidth = $ContentWidth.Replace("'", "")
    $safeMaxWidth = $ContentMaxWidth.Replace("'", "")
    $safeChatHeight = $ContentChatHeight.Replace("'", "")
    $safeFontFamily = $ContentFontFamily.Trim()
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
    font-family: $safeFontFamily !important;
    font-size: ${ContentFontSize}px !important;
    font-weight: $ContentFontWeight !important;
}

[data-droid-wide-content],
[data-new-session-composer-v2="true"] {
    width: $safeWidth !important;
    max-width: $safeMaxWidth !important;
}

[data-testid="chat-composer-wrapper"] > [data-direction="row"][data-flex-row="true"]:first-child,
[data-testid="chat-composer-wrapper"] [contenteditable="true"][role="textbox"] {
    box-sizing: border-box !important;
    height: $safeChatHeight !important;
    min-height: $safeChatHeight !important;
    max-height: $safeChatHeight !important;
}
$hiddenUiCss
"@

    # JavaScript string is JSON-encoded to avoid quote/escape problems.
    $cssJson = $css | ConvertTo-Json -Compress
    $script = @"
(() => {
  const installContentWidthGuard = () => {
    const guardKey = '__droidWideContentGuard';
    const marker = 'data-droid-wide-content';
    const defaultMaxWidths = new Set(['768px']);
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
        if (defaultMaxWidths.has(getComputedStyle(element).maxWidth)) {
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
    const id = 'droid-wide-ui-override';
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
    $droid = Get-DroidApplication
    Write-Step "检测到 $($droid.ApplicationName) $($droid.Version)"

    Stop-Droid $droid

    if ($Normal) {
        Write-Step "正在正常启动 $($droid.ApplicationName)（恢复默认界面，不开放 CDP）…"
        Start-Droid $droid
        Write-Step '正在最大化主窗口…'
        Set-DroidWindowMaximized $droid
        Write-Step '完成。'
        Stop-RunTranscript
        exit 0
    }

    $Port = Select-Port $Port
    Write-Step "内容区宽度：$Width"
    Write-Step "内容区最大宽度：$MaxWidth"
    Write-Step "聊天框高度：$ChatHeight"
    Write-Step "字体：$FontFamily"
    Write-Step "字号：${FontSize}px"
    Write-Step "字重：$FontWeight"
    Write-Step "本地 merge：$(if ($HideLocalMerge) { '隐藏' } else { '显示' })"
    Write-Step "git diff 统计：$(if ($HideGitDiff) { '隐藏' } else { '显示' })"
    Write-Host "[Droid Wide] 注意：本次 $($droid.ApplicationName) 运行期间会开放仅限 127.0.0.1 的 Chromium CDP 调试端口。" -ForegroundColor Yellow

    $debugArgs = @(
        '--remote-debugging-address=127.0.0.1',
        "--remote-debugging-port=$Port"
    )

    Write-Step "正在启动 $($droid.ApplicationName)（CDP 端口 $Port）…"
    Start-Droid $droid $debugArgs
    $targets = @(Wait-Cdp $Port 12)

    if ($targets.Count -eq 0) {
        throw "$($droid.ApplicationName) 未在 http://127.0.0.1:$Port 提供可用的 CDP page target。请关闭由其他安装目录或开发环境启动的 Droid/Factory 后重试。"
    }

    Inject-DroidUi $targets $Width $MaxWidth $ChatHeight $FontFamily $FontSize $FontWeight $HideLocalMerge $HideGitDiff
    Write-Step '正在最大化主窗口…'
    Set-DroidWindowMaximized $droid
    Write-Step "注入成功：内容区宽度 $Width、最大宽度 $MaxWidth，聊天框高度 $ChatHeight，字体 $FontFamily，字号 ${FontSize}px，字重 $FontWeight。"
    Write-Step '以后用 wide.sh 启动即可；要恢复默认界面，运行 normal.sh。'
    Start-Sleep -Seconds 1
    Stop-RunTranscript
    exit 0
} catch {
    Write-Host "[Droid Wide] 失败：$($_.Exception.Message)" -ForegroundColor Red
    Stop-RunTranscript
    exit 1
}
