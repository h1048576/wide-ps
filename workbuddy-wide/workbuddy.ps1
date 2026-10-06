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

if ($Background) {
    try {
        $scriptRoot = Split-Path -Parent $PSCommandPath
        $logRoot = Join-Path $env:LOCALAPPDATA 'WorkBuddyWide'
        [void][IO.Directory]::CreateDirectory($logRoot)
        $outputLog = Join-Path $logRoot 'workbuddy-wide.log'
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

        Write-Host '[WorkBuddy Wide] 已在后台启动。' -ForegroundColor Cyan
        Write-Host "[WorkBuddy Wide] 运行日志：$outputLog" -ForegroundColor Cyan
        exit 0
    } catch {
        Write-Host "[WorkBuddy Wide] 后台启动失败：$($_.Exception.Message)" -ForegroundColor Red
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
    Write-Host "[WorkBuddy Wide] $Message" -ForegroundColor Cyan
}

function Get-WorkBuddyApplication {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'WorkBuddy.exe'" -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        if ($process.ExecutablePath) { $candidates.Add($process.ExecutablePath) }
    }

    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = @(Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue | Where-Object {
        "$($_.DisplayName)" -match '(?i)^WorkBuddy(?:\s|$)'
    })
    foreach ($entry in $entries) {
        $displayIcon = "$($entry.DisplayIcon)".Trim()
        if ($displayIcon -match '^"([^"]+\.exe)"') {
            $candidates.Add($matches[1])
        } elseif ($displayIcon -match '^(.+?\.exe)(?:,\d+)?$') {
            $candidates.Add($matches[1])
        }
        if ($entry.InstallLocation) {
            $candidates.Add((Join-Path "$($entry.InstallLocation)".Trim().Trim('"') 'WorkBuddy.exe'))
        }
    }

    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\WorkBuddy\WorkBuddy.exe'))
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'WorkBuddy\WorkBuddy.exe'))
    $candidates.Add((Join-Path $env:ProgramFiles 'WorkBuddy\WorkBuddy.exe'))
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'WorkBuddy\WorkBuddy.exe'))
    }

    $executable = $candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Where-Object { [IO.Path]::GetFileName($_) -eq 'WorkBuddy.exe' } |
        Select-Object -Unique -First 1
    if (-not $executable) {
        throw '没有找到 Windows 版 WorkBuddy，请先安装桌面应用。'
    }

    $file = Get-Item -LiteralPath $executable -ErrorAction Stop
    $version = "$($file.VersionInfo.ProductVersion)".Trim()
    if (-not $version) { $version = "$($file.VersionInfo.FileVersion)".Trim() }
    if (-not $version) { $version = '未知版本' }
    [pscustomobject]@{
        Executable = $file.FullName
        InstallRoot = $file.DirectoryName
        Version = $version
    }
}

function Get-WorkBuddyProcesses([object]$Application) {
    @(Get-CimInstance Win32_Process -Filter "Name = 'WorkBuddy.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.Equals(
            $Application.Executable, [StringComparison]::OrdinalIgnoreCase
        )
    })
}

function Stop-WorkBuddy([object]$Application) {
    $processes = @(Get-WorkBuddyProcesses $Application)
    if ($processes.Count -eq 0) { return }

    Write-Step '正在关闭已运行的 WorkBuddy…'
    foreach ($processInfo in $processes) {
        $process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue
        if ($process) { try { [void]$process.CloseMainWindow() } catch {} }
    }

    $deadline = (Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-WorkBuddyProcesses $Application)
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

    foreach ($processInfo in @(Get-WorkBuddyProcesses $Application)) {
        Stop-Process -Id $processInfo.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
}

function Start-WorkBuddy([object]$Application, [string[]]$Arguments = @()) {
    $options = @{
        FilePath = $Application.Executable
        WorkingDirectory = $Application.InstallRoot
        ErrorAction = 'Stop'
    }
    if ($Arguments.Count -gt 0) { $options.ArgumentList = $Arguments }
    Start-Process @options | Out-Null
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
    for ($candidate = $Preferred; $candidate -le [Math]::Min(65535, $Preferred + 50); $candidate++) {
        if (Test-PortFree $candidate) { return $candidate }
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

function Wait-Cdp([int]$CdpPort, [int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $targets = @(Get-CdpTargets $CdpPort)
        $main = @($targets | Where-Object { $_.url -match '(?i)/renderer/index\.html(?:$|[?#])' })
        if ($main.Count -gt 0) { return $main }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    @()
}

function Invoke-CdpCommand([string]$WebSocketUrl, [string]$Method, [hashtable]$Params) {
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(4))
    try {
        try { $socket.Options.Proxy = [Net.WebProxy]::new() } catch {}
        [void]$socket.ConnectAsync([Uri]$WebSocketUrl, $timeout.Token).GetAwaiter().GetResult()
        $commandId = Get-Random -Minimum 1000 -Maximum 999999
        $payload = @{
            id = $commandId
            method = $Method
            params = $Params
        } | ConvertTo-Json -Compress -Depth 8
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        [void]$socket.SendAsync(
            [ArraySegment[byte]]::new($bytes),
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $timeout.Token
        ).GetAwaiter().GetResult()

        $buffer = New-Object byte[] 65536
        $message = New-Object IO.MemoryStream
        try {
            do {
                $received = $socket.ReceiveAsync(
                    [ArraySegment[byte]]::new($buffer), $timeout.Token
                ).GetAwaiter().GetResult()
                $message.Write($buffer, 0, $received.Count)
            } while (-not $received.EndOfMessage)
            $result = [Text.Encoding]::UTF8.GetString($message.ToArray()) | ConvertFrom-Json
            if ($result.error) { throw "$Method 失败：$($result.error.message)" }
            if ($result.result.exceptionDetails) {
                throw "$Method 执行异常：$($result.result.exceptionDetails.text)"
            }
        } finally {
            $message.Dispose()
        }
    } finally {
        try {
            if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
                [void]$socket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'done',
                    [Threading.CancellationToken]::None
                ).GetAwaiter().GetResult()
            }
        } catch {}
        $socket.Dispose()
        $timeout.Dispose()
    }
}

function Inject-WorkBuddyUi(
    [object[]]$Targets,
    [string]$ContentWidth,
    [string]$ContentMaxWidth,
    [string]$ContentFontFamily,
    [int]$ContentFontSize,
    [int]$ContentFontWeight
) {
    $safeWidth = $ContentWidth.Replace("'", '')
    $safeMaxWidth = $ContentMaxWidth.Replace("'", '')
    $safeFontFamily = $ContentFontFamily.Trim()
    $css = @"
:root {
    --cb-font-size-offset-global: 0 !important;
    --cb-font-size-offset: 0 !important;
    --wb-font-size-offset: 0 !important;
}

:is(#workbuddy-wide-ui-override, :root, body, body *) {
    font-family: $safeFontFamily !important;
    font-size: ${ContentFontSize}px !important;
    font-weight: $ContentFontWeight !important;
}

:root,
.chat-container,
.claw-agent-chat-pane,
.colleague-chat-cb-chat,
.project-detail-view__main,
[style*="--cb-chat-max-content-width"] {
    --cb-chat-max-content-width: $safeMaxWidth !important;
}

.claw-agent-chat-pane {
    --claw-agent-chat-content-max-width: $safeMaxWidth !important;
}

.chat-container--welcome,
.chat-container__message-skeleton-content,
[class*="chatMessageBox"],
[class*="input-area-container"],
.cr-message-list__content,
.conversation-input-area,
.project-detail-view__input-area--task,
.wb-home-route__input-wrap {
    box-sizing: border-box !important;
    width: $safeWidth !important;
    max-width: $safeMaxWidth !important;
    margin-left: auto !important;
    margin-right: auto !important;
}
"@

    $cssJson = $css | ConvertTo-Json -Compress
    $script = @"
(() => {
  const apply = () => {
    const id = 'workbuddy-wide-ui-override';
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
        Invoke-CdpCommand $target.webSocketDebuggerUrl 'Runtime.evaluate' @{
            expression = $script
            returnByValue = $true
        }
        Invoke-CdpCommand $target.webSocketDebuggerUrl 'Page.addScriptToEvaluateOnNewDocument' @{
            source = $script
        }
    }
}

try {
    $application = Get-WorkBuddyApplication
    Write-Step "检测到 WorkBuddy $($application.Version)"
    Stop-WorkBuddy $application

    if ($Normal) {
        Write-Step '正在正常启动 WorkBuddy（恢复默认界面，不开放 CDP）…'
        Start-WorkBuddy $application
        Write-Step '完成。'
        Stop-RunTranscript
        exit 0
    }

    $Port = Select-Port $Port
    Write-Step "聊天对话区宽度：$Width"
    Write-Step "聊天对话区最大宽度：$MaxWidth"
    Write-Step "字体：$FontFamily"
    Write-Step "字号：${FontSize}px"
    Write-Step "字重：$FontWeight"
    Write-Host '[WorkBuddy Wide] 注意：本次运行期间会开放仅限 127.0.0.1 的 Chromium CDP 调试端口。' -ForegroundColor Yellow

    $debugArguments = @(
        '--remote-debugging-address=127.0.0.1',
        "--remote-debugging-port=$Port"
    )
    Write-Step "正在启动 WorkBuddy（CDP 端口 $Port）…"
    Start-WorkBuddy $application $debugArguments
    $targets = @(Wait-Cdp $Port 20)
    if ($targets.Count -eq 0) {
        throw "WorkBuddy 未在 http://127.0.0.1:$Port 提供主页面 CDP target。请确认旧实例已退出后重试。"
    }

    Inject-WorkBuddyUi $targets $Width $MaxWidth $FontFamily $FontSize $FontWeight
    Write-Step "注入成功：聊天对话区宽度 $Width、最大宽度 $MaxWidth，字体 $FontFamily，字号 ${FontSize}px，字重 $FontWeight。"
    Stop-RunTranscript
    exit 0
} catch {
    Write-Host "[WorkBuddy Wide] 失败：$($_.Exception.Message)" -ForegroundColor Red
    Stop-RunTranscript
    exit 1
}
