param(
    [ValidatePattern('^[0-9]{2,4}(?:\.[0-9]+)?(?:rem|px|vw)$')]
    [string]$Width = '80rem',

    [ValidateNotNullOrEmpty()]
    [string]$FontFamily = 'Cascadia Mono, LXGW WenKai Mono',

    [ValidateRange(100, 1000)]
    [int]$FontWeight = 300,

    [ValidateRange(1024, 65535)]
    [int]$Port = 9335,

    [string]$ZCodePath,

    [switch]$Normal
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host "[ZCode Wide] $Message" -ForegroundColor Cyan
}

function Add-ZCodeCandidate([Collections.Generic.List[string]]$Candidates, [string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return }

    $expanded = [Environment]::ExpandEnvironmentVariables($Candidate.Trim().Trim('"'))
    if ([IO.Path]::GetExtension($expanded) -ne '.exe') {
        $expanded = Join-Path $expanded 'ZCode.exe'
    }

    if (-not $Candidates.Contains($expanded)) {
        $Candidates.Add($expanded)
    }
}

function Get-CommandExecutable([string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }

    if ($Command -match '^\s*"([^"]+\.exe)"') {
        return $Matches[1]
    }
    if ($Command -match '^\s*(.+?\.exe)(?:\s|$)') {
        return $Matches[1]
    }
    $null
}

function Resolve-ZCode {
    $candidates = [Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($ZCodePath)) {
        Add-ZCodeCandidate $candidates $ZCodePath
    }

    $runningPaths = @(Get-CimInstance Win32_Process -Filter "Name = 'ZCode.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ExecutablePath } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique)
    foreach ($path in $runningPaths) {
        Add-ZCodeCandidate $candidates $path
    }

    $appPathKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\ZCode.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\ZCode.exe'
    )
    foreach ($keyPath in $appPathKeys) {
        if (-not (Test-Path -LiteralPath $keyPath)) { continue }
        $key = Get-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue
        if ($key) {
            Add-ZCodeCandidate $candidates "$($key.GetValue(''))"
        }
    }

    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installEntries = @(Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { "$($_.DisplayName)" -match '(?i)^ZCode(?:\s|$)' })
    foreach ($entry in $installEntries) {
        Add-ZCodeCandidate $candidates "$($entry.InstallLocation)"

        $displayIcon = "$($entry.DisplayIcon)".Trim().Trim('"') -replace ',\d+$', ''
        if (-not [string]::IsNullOrWhiteSpace($displayIcon)) {
            if ([IO.Path]::GetFileName($displayIcon) -ieq 'ZCode.exe') {
                Add-ZCodeCandidate $candidates $displayIcon
            } else {
                Add-ZCodeCandidate $candidates (Split-Path -Parent $displayIcon)
            }
        }

        $uninstaller = Get-CommandExecutable "$($entry.UninstallString)"
        if ($uninstaller) {
            Add-ZCodeCandidate $candidates (Split-Path -Parent $uninstaller)
        }
    }

    $standardRoots = @(
        $env:ProgramW6432,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' })
    )
    foreach ($root in $standardRoots) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            Add-ZCodeCandidate $candidates (Join-Path $root 'ZCode')
        }
    }

    $executable = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if (-not $executable) {
        $searched = ($candidates | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "没有找到 ZCode.exe。已检查以下位置：$([Environment]::NewLine)$searched$([Environment]::NewLine)也可以通过 -ZCodePath 手动指定。"
    }

    $executable = [IO.Path]::GetFullPath($executable)
    $versionInfo = (Get-Item -LiteralPath $executable).VersionInfo
    $version = "$($versionInfo.ProductVersion)".Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = "$($versionInfo.FileVersion)".Trim()
    }

    [pscustomobject]@{
        Executable  = $executable
        InstallRoot = [IO.Path]::GetDirectoryName($executable).TrimEnd('\')
        Version     = $version
    }
}

function Get-ZCodeProcesses([object]$ZCode) {
    @(Get-CimInstance Win32_Process -Filter "Name = 'ZCode.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $path = "$($_.ExecutablePath)"
        $path -and $path.Equals($ZCode.Executable, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-ZCode([object]$ZCode) {
    $processes = @(Get-ZCodeProcesses $ZCode)
    if ($processes.Count -eq 0) { return }

    Write-Step '正在关闭已运行的 ZCode…'
    foreach ($process in $processes) {
        try {
            [void](Get-Process -Id $process.ProcessId -ErrorAction Stop).CloseMainWindow()
        } catch {}
    }

    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-ZCodeProcesses $ZCode)
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

    foreach ($process in @(Get-ZCodeProcesses $ZCode)) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        } catch {}
    }
    Start-Sleep -Milliseconds 500
}

function Initialize-DetachedLauncher {
    if ('ZCodeWide.DetachedLauncher' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ZCodeWide {
    public static class DetachedLauncher {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const uint STARTF_USESTDHANDLES = 0x00000100;
        private const uint DETACHED_PROCESS = 0x00000008;
        private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
        private const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SECURITY_ATTRIBUTES securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref STARTUPINFO startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public static uint Launch(string executable, string arguments, string workingDirectory) {
            var securityAttributes = new SECURITY_ATTRIBUTES {
                nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)),
                lpSecurityDescriptor = IntPtr.Zero,
                bInheritHandle = true
            };
            var nullHandle = CreateFile(
                "NUL",
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                ref securityAttributes,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                IntPtr.Zero);
            if (nullHandle == INVALID_HANDLE_VALUE) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法打开 NUL 设备");
            }

            try {
                var startupInfo = new STARTUPINFO {
                    cb = Marshal.SizeOf(typeof(STARTUPINFO)),
                    dwFlags = STARTF_USESTDHANDLES,
                    hStdInput = nullHandle,
                    hStdOutput = nullHandle,
                    hStdError = nullHandle
                };
                PROCESS_INFORMATION processInformation;
                var commandLineText = "\"" + executable + "\"";
                if (!String.IsNullOrWhiteSpace(arguments)) {
                    commandLineText += " " + arguments;
                }

                var creationFlags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB;
                var created = CreateProcess(
                    executable,
                    new StringBuilder(commandLineText),
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    creationFlags,
                    IntPtr.Zero,
                    workingDirectory,
                    ref startupInfo,
                    out processInformation);
                var error = created ? 0 : Marshal.GetLastWin32Error();

                // 某些终端作业不允许显式 breakaway；DETACHED_PROCESS 本身仍能隔离控制台。
                if (!created && error == 5) {
                    creationFlags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;
                    created = CreateProcess(
                        executable,
                        new StringBuilder(commandLineText),
                        IntPtr.Zero,
                        IntPtr.Zero,
                        true,
                        creationFlags,
                        IntPtr.Zero,
                        workingDirectory,
                        ref startupInfo,
                        out processInformation);
                    error = created ? 0 : Marshal.GetLastWin32Error();
                }

                if (!created) {
                    throw new Win32Exception(error, "无法以独立进程方式启动 ZCode");
                }

                try {
                    return processInformation.dwProcessId;
                } finally {
                    CloseHandle(processInformation.hThread);
                    CloseHandle(processInformation.hProcess);
                }
            } finally {
                CloseHandle(nullHandle);
            }
        }
    }
}
'@
}

function Start-ZCode([object]$ZCode, [string[]]$Arguments = @()) {
    $argumentLine = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + $_.Replace('"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' '

    Initialize-DetachedLauncher
    [void][ZCodeWide.DetachedLauncher]::Launch(
        $ZCode.Executable,
        $argumentLine,
        $ZCode.InstallRoot
    )
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
        if ($listener) {
            try { $listener.Stop() } catch {}
        }
    }
}

function Select-Port([int]$Preferred) {
    for ($candidate = $Preferred; $candidate -le [Math]::Min(65535, $Preferred + 50); $candidate++) {
        if (Test-PortFree $candidate) { return $candidate }
    }
    throw "从 $Preferred 开始的 51 个本地端口都不可用。"
}

function Get-CdpTargets([int]$CdpPort) {
    try {
        @((Invoke-RestMethod -Uri "http://127.0.0.1:$CdpPort/json/list" -TimeoutSec 1) |
            Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl })
    } catch {
        @()
    }
}

function Wait-Cdp([int]$CdpPort, [int]$Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $targets = @(Get-CdpTargets $CdpPort)
        if ($targets.Count -gt 0) { return $targets }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    @()
}

function Invoke-CdpCommand([string]$WebSocketUrl, [string]$Method, [hashtable]$Params) {
    $webSocket = [Net.WebSockets.ClientWebSocket]::new()
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(3))
    try {
        [void]$webSocket.ConnectAsync([Uri]$WebSocketUrl, $cancellation.Token).GetAwaiter().GetResult()
        $commandId = Get-Random -Minimum 1000 -Maximum 999999
        $payload = @{
            id     = $commandId
            method = $Method
            params = $Params
        } | ConvertTo-Json -Compress -Depth 8

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [ArraySegment[byte]]::new($bytes)
        [void]$webSocket.SendAsync(
            $segment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cancellation.Token
        ).GetAwaiter().GetResult()

        $buffer = New-Object byte[] 65536
        $receiveSegment = [ArraySegment[byte]]::new($buffer)
        while ($true) {
            $message = [IO.MemoryStream]::new()
            try {
                do {
                    $received = $webSocket.ReceiveAsync($receiveSegment, $cancellation.Token).GetAwaiter().GetResult()
                    if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                        throw 'CDP 连接在返回命令结果前关闭。'
                    }
                    $message.Write($buffer, 0, $received.Count)
                } while (-not $received.EndOfMessage)
                $response = [Text.Encoding]::UTF8.GetString($message.ToArray()) | ConvertFrom-Json
            } finally {
                $message.Dispose()
            }

            # 忽略异步事件，只接受当前命令的完整响应。
            if ($response.id -ne $commandId) { continue }
            if ($response.error) {
                throw "CDP $Method 失败：$($response.error.message)"
            }
            if ($response.result.exceptionDetails) {
                throw "页面脚本执行失败：$($response.result.exceptionDetails | ConvertTo-Json -Compress -Depth 8)"
            }
            return $response.result
        }
    } finally {
        try {
            if ($webSocket.State -eq [Net.WebSockets.WebSocketState]::Open) {
                [void]$webSocket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'done',
                    $cancellation.Token
                ).GetAwaiter().GetResult()
            }
        } catch {}
        $webSocket.Dispose()
        $cancellation.Dispose()
    }
}

function ConvertTo-CssFontFamily([string]$FontList) {
    $families = @($FontList -split ',' | ForEach-Object {
        $_.Trim().Trim('"').Trim("'")
    } | Where-Object { $_ })

    if ($families.Count -eq 0) {
        throw '字体列表不能为空。'
    }

    $unsafeFamily = $families | Where-Object { $_ -match '[\r\n;{}]' } | Select-Object -First 1
    if ($unsafeFamily) {
        throw "字体名称包含不支持的字符：$unsafeFamily"
    }

    $genericFamilies = @('serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui', 'ui-serif', 'ui-sans-serif', 'ui-monospace')
    $cssFamilies = @($families | ForEach-Object {
        if ($genericFamilies -contains $_.ToLowerInvariant()) {
            $_.ToLowerInvariant()
        } else {
            '"' + $_.Replace('\', '\\').Replace('"', '\"') + '"'
        }
    })

    if (-not ($families | Where-Object { $_.ToLowerInvariant() -eq 'monospace' })) {
        $cssFamilies += 'monospace'
    }
    $cssFamilies -join ', '
}

function Inject-ZCodeUi([object[]]$Targets, [string]$ContentWidth, [string]$RequestedFontFamily, [int]$ContentFontWeight) {
    $safeWidth = $ContentWidth.Replace("'", '')
    $cssFontFamily = ConvertTo-CssFontFamily $RequestedFontFamily
    $css = @"
:root,
body,
body * {
    font-weight: $ContentFontWeight !important;
}

:root,
:host {
    --font-sans: $cssFontFamily !important;
    --font-mono: $cssFontFamily !important;
    --default-font-family: $cssFontFamily !important;
    --default-mono-font-family: $cssFontFamily !important;
}

html,
body,
button,
input,
select,
textarea {
    font-family: $cssFontFamily !important;
}

code,
kbd,
pre,
samp,
.font-mono,
.font-sans {
    font-family: $cssFontFamily !important;
}

/* 新建和已有会话统一使用配置宽度。 */
[data-v4-timeline-content-column="true"],
[data-v4-composer-dock-content="true"] {
    width: min(100%, $safeWidth) !important;
    max-width: $safeWidth !important;
    /* 取消为右侧状态面板预留空间的水平偏移。 */
    translate: none !important;
    transform: none !important;
}

/* 新建会话的输入组件也需解除内部宽度限制，与外层同步。 */
[data-v4-composer-dock-content="true"] [data-testid="v4-composer"] {
    width: 100% !important;
    max-width: 100% !important;
}

/* 左侧栏与右侧主区域使用相同的主题背景色。 */
[data-workspace-sidebar-panel="true"],
[data-testid="sidebar"] {
    background: var(--color-background) !important;
}

/* 隐藏右上角的“更改”浮动控件。 */
[data-testid="chat-summary-panel"] {
    display: none !important;
}
"@

    $cssJson = $css | ConvertTo-Json -Compress
    $script = @"
(() => {
  const apply = () => {
    const id = 'zcode-wide-ui-override';
    let style = document.getElementById(id);
    if (!style) {
      style = document.createElement('style');
      style.id = id;
      (document.head || document.documentElement).appendChild(style);
    }
    const css = $cssJson;
    if (style.textContent !== css) style.textContent = css;
    return style.isConnected && style.textContent === css;
  };

  if (!document.documentElement || document.readyState === 'loading') return false;
  if (!location.href || location.href === 'about:blank') return false;
  return apply();
})();
"@

    foreach ($target in $Targets) {
        try {
            $result = Invoke-CdpCommand $target.webSocketDebuggerUrl 'Runtime.evaluate' @{
                expression    = $script
                returnByValue = $true
            }
            if ($result.result.value -eq $true) {
                [pscustomobject]@{ TargetId = $target.id; Success = $true; Error = '' }
            } else {
                [pscustomobject]@{ TargetId = $target.id; Success = $false; Error = '页面仍在加载' }
            }
        } catch {
            # 页面导航、关闭和渲染进程切换都可能暂时断开连接，下一轮重新发现页面。
            [pscustomobject]@{ TargetId = $target.id; Success = $false; Error = $_.Exception.Message }
        }
    }
}

try {
    $zcode = Resolve-ZCode
    if ([string]::IsNullOrWhiteSpace($zcode.Version)) {
        Write-Step "检测到 ZCode：$($zcode.Executable)"
    } else {
        Write-Step "检测到 ZCode $($zcode.Version)：$($zcode.Executable)"
    }

    Stop-ZCode $zcode

    if ($Normal) {
        Write-Step '正在正常启动 ZCode（恢复默认宽度、字体和字重，不开放 CDP）…'
        Start-ZCode $zcode
        Write-Step '完成。'
        exit 0
    }

    $Port = Select-Port $Port
    Write-Step "对话区目标宽度：$Width"
    Write-Step "中英文字体：$FontFamily"
    Write-Step "字重：$FontWeight"
    Write-Host '[ZCode Wide] 注意：本次 ZCode 运行期间会开放仅限 127.0.0.1 的 Chromium CDP 调试端口。' -ForegroundColor Yellow

    $debugArguments = @(
        '--remote-debugging-address=127.0.0.1',
        "--remote-debugging-port=$Port"
    )

    Write-Step "正在启动 ZCode（CDP 端口 $Port）…"
    Start-ZCode $zcode $debugArguments
    $targets = @(Wait-Cdp $Port)
    if ($targets.Count -eq 0) {
        throw "ZCode 已启动，但 http://127.0.0.1:$Port 没有可用的 CDP page target。"
    }

    # 绑定本次启动的进程，避免再次运行 wide.sh / normal.sh 后旧任务继续注入。
    $sessionProcesses = @(Get-ZCodeProcesses $zcode | ForEach-Object {
        Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    })
    $injected = $false
    $deadline = (Get-Date).AddSeconds(60)
    $lastError = '没有可用的页面'
    $lastStatus = ''
    Write-Step '正在等待页面加载并确认样式；后台任务会持续处理重载和新窗口。'
    while (@($sessionProcesses | Where-Object { -not $_.HasExited }).Count -gt 0) {
        $results = @(Inject-ZCodeUi $targets $Width $FontFamily $FontWeight)
        $successful = @($results | Where-Object { $_.Success })
        $failed = @($results | Where-Object { -not $_.Success })
        if ($failed.Count -gt 0) { $lastError = $failed[0].Error }

        if ($successful.Count -gt 0 -and -not $injected) {
            $injected = $true
            Write-Step "注入成功并已校验：对话区宽度 $Width，字体 $FontFamily，字重 $FontWeight，右上角更改控件已隐藏。"
            Write-Step '后台持续维护样式；要恢复 ZCode 默认样式，运行 normal.sh。'
        }
        if (-not $injected -and (Get-Date) -ge $deadline) {
            throw "等待样式注入超时：$lastError"
        }

        $status = if ($targets.Count -eq 0) { '暂未发现页面，正在重试。' }
            elseif ($failed.Count -gt 0) { "部分页面尚未完成注入，将自动重试：$lastError" }
            else { '' }
        if ($status -and $status -ne $lastStatus) { Write-Step $status }
        $lastStatus = $status
        Start-Sleep -Seconds 1
        $targets = @(Get-CdpTargets $Port)
    }
    if (-not $injected) { throw 'ZCode 在样式注入成功前已退出。' }
    Write-Step '本次 ZCode 已退出，样式维护任务结束。'
    exit 0
} catch {
    Write-Host "[ZCode Wide] 失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
