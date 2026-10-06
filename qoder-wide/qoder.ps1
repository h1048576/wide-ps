param(
    [ValidatePattern('^(?:auto|fit-content|(?:0|[1-9][0-9]{0,3})(?:\.[0-9]+)?(?:px|rem|em|vw|vh|%))$')]
    [string]$Width = '100%',

    [ValidatePattern('^(?:none|(?:0|[1-9][0-9]{0,3})(?:\.[0-9]+)?(?:px|rem|em|vw|vh|%))$')]
    [string]$MaxWidth = '90rem',

    [ValidateRange(8, 72)]
    [int]$FontSize = 18,

    [ValidateRange(100, 1000)]
    [int]$FontWeight = 300,

    [ValidateScript({ $_ -and $_ -notmatch '[;{}<>\r\n]' })]
    [string]$FontFamily = 'Cascadia Mono, LXGW WenKai Mono',

    [ValidateRange(1024, 65535)]
    [int]$Port = 9335,

    [switch]$Normal,

    [switch]$Background,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

if (-not ('QoderWide.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace QoderWide
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
        $logRoot = Join-Path $env:LOCALAPPDATA 'QoderWide'
        [void][IO.Directory]::CreateDirectory($logRoot)
        $outputLog = Join-Path $logRoot 'qoder-wide.log'
        $powerShellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
        $quotedScriptPath = '"' + $PSCommandPath + '"'
        $quotedLogPath = '"' + $outputLog + '"'
        $quotedWidth = '"' + $Width + '"'
        $quotedMaxWidth = '"' + $MaxWidth + '"'
        $quotedFontFamily = '"' + $FontFamily.Replace('"', '\"') + '"'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -Width $quotedWidth -MaxWidth $quotedMaxWidth -FontSize $FontSize -FontWeight $FontWeight -FontFamily $quotedFontFamily -Port $Port -LogPath $quotedLogPath"
        if ($Normal) { $arguments += ' -Normal' }

        Start-Process `
            -FilePath $powerShellExecutable `
            -ArgumentList $arguments `
            -WorkingDirectory $scriptRoot `
            -WindowStyle Hidden `
            -ErrorAction Stop | Out-Null

        Write-Host '[Qoder Wide] 已在后台启动。' -ForegroundColor Cyan
        Write-Host "[Qoder Wide] 运行日志：$outputLog" -ForegroundColor Cyan
        exit 0
    } catch {
        Write-Host "[Qoder Wide] 后台启动失败：$($_.Exception.Message)" -ForegroundColor Red
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
    Write-Host "[Qoder Wide] $Message" -ForegroundColor Cyan
}

function Get-QoderApplication {
    $executableCandidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($process in @(Get-Process -Name 'Qoder CN', 'Qoder' -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path) { $executableCandidates.Add($process.Path) }
        } catch {}
    }

    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $uninstallEntries = @(Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue | Where-Object {
        "$($_.DisplayName)" -match '(?i)^Qoder(?:\s|$)'
    })
    foreach ($entry in $uninstallEntries) {
        $displayIcon = "$($entry.DisplayIcon)".Trim()
        if ($displayIcon -match '^"([^"]+\.exe)"(?:,\d+)?$') {
            $executableCandidates.Add($matches[1])
        } elseif ($displayIcon -match '^(.+?\.exe)(?:,\d+)?$') {
            $executableCandidates.Add($matches[1])
        }

        $installRoots = @("$($entry.InstallLocation)".Trim().Trim('"'))
        if ($displayIcon -match '^"?(.+?\.(?:ico|exe))"?(?:,\d+)?$') {
            $installRoots += Split-Path -Parent $matches[1]
        }
        foreach ($installRoot in $installRoots | Where-Object { $_ }) {
            @('Qoder CN.exe', 'Qoder.exe') | ForEach-Object {
                $executableCandidates.Add((Join-Path $installRoot $_))
            }
        }
    }

    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Qoder CN\Qoder CN.exe'))
    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Qoder\Qoder.exe'))
    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Qoder CN\Qoder CN.exe'))
    $executableCandidates.Add((Join-Path $env:LOCALAPPDATA 'Qoder\Qoder.exe'))
    $executableCandidates.Add((Join-Path $env:ProgramFiles 'Qoder CN\Qoder CN.exe'))
    $executableCandidates.Add((Join-Path $env:ProgramFiles 'Qoder\Qoder.exe'))
    if (${env:ProgramFiles(x86)}) {
        $executableCandidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Qoder CN\Qoder CN.exe'))
        $executableCandidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Qoder\Qoder.exe'))
    }

    $executable = $executableCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Select-Object -Unique -First 1

    if (-not $executable) {
        throw '没有找到 Windows 版 Qoder，请先安装 Qoder 桌面应用。'
    }

    $file = Get-Item -LiteralPath $executable -ErrorAction Stop
    $version = "$($file.VersionInfo.ProductVersion)".Trim()
    if (-not $version) { $version = "$($file.VersionInfo.FileVersion)".Trim() }
    if (-not $version) { $version = '未知版本' }
    $applicationName = "$($file.VersionInfo.ProductName)".Trim()
    if (-not $applicationName) { $applicationName = 'Qoder' }

    [pscustomobject]@{
        ApplicationName = $applicationName
        Executable      = $file.FullName
        InstallRoot     = $file.DirectoryName
        ProcessName     = $file.Name
        Version         = $version
    }
}

function Start-Qoder([object]$Qoder, [string[]]$Arguments = @()) {
    $logRoot = Join-Path $env:LOCALAPPDATA 'QoderWide'
    [void][IO.Directory]::CreateDirectory($logRoot)
    $startProcessArguments = @{
        FilePath               = $Qoder.Executable
        WorkingDirectory       = $Qoder.InstallRoot
        WindowStyle            = 'Maximized'
        RedirectStandardOutput = Join-Path $logRoot 'qoder-app.stdout.log'
        RedirectStandardError  = Join-Path $logRoot 'qoder-app.stderr.log'
        ErrorAction            = 'Stop'
    }
    if ($Arguments.Count -gt 0) {
        $startProcessArguments.ArgumentList = $Arguments
    }
    Start-Process @startProcessArguments | Out-Null
}

function Get-QoderProcesses([object]$Qoder) {
    $root = $Qoder.InstallRoot.TrimEnd('\') + '\'
    $processName = $Qoder.ProcessName.Replace("'", "''")
    @(Get-CimInstance Win32_Process -Filter "Name = '$processName'" -ErrorAction SilentlyContinue | Where-Object {
        $path = "$($_.ExecutablePath)"
        $path -and $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Set-QoderWindowMaximized([object]$Qoder, [int]$Seconds = 12) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        foreach ($processInfo in @(Get-QoderProcesses $Qoder)) {
            try {
                $process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue
                if (-not $process) { continue }
                $process.Refresh()
                $windowHandle = $process.MainWindowHandle
                if ($windowHandle -eq [IntPtr]::Zero) { continue }

                if (-not [QoderWide.NativeMethods]::IsZoomed($windowHandle)) {
                    [void][QoderWide.NativeMethods]::ShowWindowAsync($windowHandle, 3)
                    Start-Sleep -Milliseconds 150
                    $process.Refresh()
                    $windowHandle = $process.MainWindowHandle
                }

                if ($windowHandle -ne [IntPtr]::Zero -and [QoderWide.NativeMethods]::IsZoomed($windowHandle)) {
                    return
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    throw "未能在 $Seconds 秒内最大化 $($Qoder.ApplicationName) 主窗口。"
}

function Stop-Qoder([object]$Qoder) {
    $procs = @(Get-QoderProcesses $Qoder)
    if ($procs.Count -eq 0) { return }

    Write-Step "正在关闭已运行的 $($Qoder.ApplicationName)…"
    foreach ($p in $procs) {
        $process = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($process) { try { [void]$process.CloseMainWindow() } catch {} }
    }

    $deadline = (Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 250
        $left = @(Get-QoderProcesses $Qoder)
    } while ($left.Count -gt 0 -and (Get-Date) -lt $deadline)

    foreach ($p in @(Get-QoderProcesses $Qoder)) {
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
        $targets = ConvertFrom-Json -InputObject $reader.ReadToEnd()
        foreach ($target in $targets) {
            if ($target.type -eq 'page' -and
                $target.url -match '^qoder(?:-cn)?-app://renderer/' -and
                $target.webSocketDebuggerUrl) {
                $target
            }
        }
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
        $commandId = Get-Random -Minimum 1000 -Maximum 999999
        $payload = @{
            id     = $commandId
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

        $buffer = New-Object byte[] 65536
        $receiveSegment = [ArraySegment[byte]]::new($buffer)
        $message = [IO.MemoryStream]::new()
        try {
            while ($true) {
                $received = $ws.ReceiveAsync($receiveSegment, $cts.Token).GetAwaiter().GetResult()
                if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                    throw "CDP 连接在 $Method 返回前关闭。"
                }
                $message.Write($buffer, 0, $received.Count)
                if (-not $received.EndOfMessage) { continue }

                $response = [Text.Encoding]::UTF8.GetString($message.ToArray()) | ConvertFrom-Json
                $message.SetLength(0)
                if ($response.id -ne $commandId) { continue }
                if ($response.error) { throw "CDP $Method 失败：$($response.error.message)" }
                if ($response.result.exceptionDetails) {
                    throw "CDP $Method 执行异常：$($response.result.exceptionDetails.text)"
                }
                if ($Method -eq 'Runtime.evaluate' -and $response.result.result.value -ne $true) {
                    throw 'Qoder 界面样式注入未返回成功。'
                }
                break
            }
        } finally {
            $message.Dispose()
        }
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

function Inject-QoderUi(
    [object[]]$Targets,
    [string]$ContentWidth,
    [string]$ContentMaxWidth,
    [string]$ContentFontFamily,
    [int]$ContentFontSize,
    [int]$ContentFontWeight
) {
    $safeWidth = if ($ContentWidth -in @('auto', 'fit-content')) {
        $ContentWidth
    } else {
        "min(100%, $ContentWidth)"
    }
    $safeMaxWidth = if ($ContentMaxWidth -eq 'none') {
        '100%'
    } else {
        "min(100%, $ContentMaxWidth)"
    }
    $safeFontFamily = $ContentFontFamily.Trim()
    $css = @"
:root {
    --q5e9e46: $safeMaxWidth !important;
}

:root,
body,
body * {
    font-family: $safeFontFamily !important;
    font-size: ${ContentFontSize}px !important;
    font-weight: $ContentFontWeight !important;
}

[data-chat-session-main] [class*="max-w-[var(--qe5d022)]"],
[data-chat-session-main] [data-conversation-composer] > div,
[class*="max-w-[768px]"]:has(> [data-new-chat-context-strip]) {
    box-sizing: border-box !important;
    width: $safeWidth !important;
    max-width: $safeMaxWidth !important;
    min-width: 0 !important;
}

[data-chat-session-main] .markdown-body,
[data-chat-session-main] .markdown-body :is(p, li, blockquote, a),
[data-chat-session-main] [data-message-id] {
    min-width: 0 !important;
    overflow-wrap: anywhere !important;
}
"@

    # JavaScript string is JSON-encoded to avoid quote/escape problems.
    $cssJson = $css | ConvertTo-Json -Compress
    $script = @"
(() => {
  const apply = () => {
    const id = 'qoder-wide-ui-override';
    let style = document.getElementById(id);
    if (!style) {
      style = document.createElement('style');
      style.id = id;
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = $cssJson;
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
    $qoder = Get-QoderApplication
    Write-Step "检测到 $($qoder.ApplicationName) $($qoder.Version)"

    if ($Normal) {
        Stop-Qoder $qoder
        Write-Step "正在正常启动 $($qoder.ApplicationName)（恢复默认界面，不开放 CDP）…"
        Start-Qoder $qoder
        Write-Step '正在最大化主窗口…'
        Set-QoderWindowMaximized $qoder
        Write-Step '完成。'
        Stop-RunTranscript
        exit 0
    }

    $Port = Select-Port $Port
    Write-Step "对话区宽度：$Width"
    Write-Step "对话区最大宽度：$MaxWidth"
    Write-Step "字体：$FontFamily"
    Write-Step "字号：${FontSize}px"
    Write-Step "字重：$FontWeight"
    Write-Host "[Qoder Wide] 注意：本次 $($qoder.ApplicationName) 运行期间会开放仅限 127.0.0.1 的 Chromium CDP 调试端口。" -ForegroundColor Yellow

    $debugArgs = @(
        '--remote-debugging-address=127.0.0.1',
        "--remote-debugging-port=$Port"
    )

    Stop-Qoder $qoder
    Write-Step "正在启动 $($qoder.ApplicationName)（CDP 端口 $Port）…"
    Start-Qoder $qoder $debugArgs
    $targets = @(Wait-Cdp $Port 20)

    if ($targets.Count -eq 0) {
        throw "$($qoder.ApplicationName) 未在 http://127.0.0.1:$Port 提供可用的 CDP page target。请确认 Qoder 已完全退出后重试。"
    }

    Inject-QoderUi $targets $Width $MaxWidth $FontFamily $FontSize $FontWeight
    Write-Step '正在最大化主窗口…'
    Set-QoderWindowMaximized $qoder
    Write-Step "注入成功：对话区宽度 $Width、最大宽度 $MaxWidth，字体 $FontFamily，字号 ${FontSize}px，字重 $FontWeight。"
    Write-Step '以后用 wide.sh 启动即可；要恢复默认界面，运行 normal.sh。'
    Start-Sleep -Seconds 1
    Stop-RunTranscript
    exit 0
} catch {
    Write-Host "[Qoder Wide] 失败：$($_.Exception.Message)" -ForegroundColor Red
    Stop-RunTranscript
    exit 1
}
