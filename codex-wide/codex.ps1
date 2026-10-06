param(
    [ValidatePattern('^[0-9]{2,4}(?:\.[0-9]+)?(?:rem|px|vw)$')]
    [string]$Width = '80rem',

    [ValidateRange(8, 72)]
    [int]$FontSize = 18,

    [ValidateRange(100, 1000)]
    [int]$FontWeight = 300,

    [ValidateScript({ $_ -and $_ -notmatch '[;{}<>\r\n]' })]
    [string]$FontFamily = 'Cascadia Mono, LXGW WenKai Mono',

    [ValidateRange(1024, 65535)]
    [int]$Port = 9335,

    [switch]$Normal
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host "[Codex Wide] $Message" -ForegroundColor Cyan
}

function Get-CodexPackage {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $pkg) {
        throw '没有找到 Microsoft Store 版 Codex（包名 OpenAI.Codex）。'
    }

    $manifest = Get-AppxPackageManifest -Package $pkg.PackageFullName -ErrorAction Stop
    $apps = @($manifest.Package.Applications.Application)
    $app = $apps | Where-Object { "$($_.Executable)" -match '(?i)ChatGPT\.exe$' } | Select-Object -First 1
    if (-not $app) { $app = $apps | Select-Object -First 1 }
    if (-not $app -or -not $app.Id) {
        throw '无法从 Codex 包清单中解析 Application Id。'
    }

    [pscustomobject]@{
        Package        = $pkg
        InstallRoot    = [IO.Path]::GetFullPath($pkg.InstallLocation).TrimEnd('\')
        Executable     = Join-Path $pkg.InstallLocation "$($app.Executable)"
        AppUserModelId = "$($pkg.PackageFamilyName)!$($app.Id)"
        Version        = "$($pkg.Version)"
    }
}

function Initialize-PackageLauncher {
    if ('CodexWide.PackageLauncher' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexWide {
    [Flags]
    internal enum ActivateOptions : uint { None = 0 }

    [ComImport]
    [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            ActivateOptions options,
            out uint processId);
    }

    [ComImport]
    [Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
    internal class ApplicationActivationManager {}

    public static class PackageLauncher {
        public static uint Launch(string appUserModelId, string arguments) {
            var manager = (IApplicationActivationManager)new ApplicationActivationManager();
            try {
                uint processId;
                int hr = manager.ActivateApplication(
                    appUserModelId,
                    arguments ?? string.Empty,
                    ActivateOptions.None,
                    out processId);
                Marshal.ThrowExceptionForHR(hr);
                return processId;
            } finally {
                if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
            }
        }
    }
}
'@
}

function Start-CodexPackage([object]$Codex, [string[]]$Arguments = @()) {
    Initialize-PackageLauncher
    $argLine = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"','\\"') + '"' } else { $_ }
    }) -join ' '
    [void][CodexWide.PackageLauncher]::Launch($Codex.AppUserModelId, $argLine)
}

function Get-CodexProcesses([object]$Codex) {
    $root = $Codex.InstallRoot + '\'
    @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $path = "$($_.ExecutablePath)"
        $path -and $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-Codex([object]$Codex) {
    $procs = @(Get-CodexProcesses $Codex)
    if ($procs.Count -eq 0) { return }

    Write-Step '正在关闭已运行的 Codex…'
    foreach ($p in $procs) {
        try { [void](Get-Process -Id $p.ProcessId -ErrorAction Stop).CloseMainWindow() } catch {}
    }

    $deadline = (Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 250
        $left = @(Get-CodexProcesses $Codex)
    } while ($left.Count -gt 0 -and (Get-Date) -lt $deadline)

    foreach ($p in @(Get-CodexProcesses $Codex)) {
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
    try {
        @((Invoke-RestMethod -Uri "http://127.0.0.1:$CdpPort/json/list" -TimeoutSec 1) |
            Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl })
    } catch {
        @()
    }
}

function Wait-Cdp([int]$CdpPort, [int]$Seconds = 10) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $targets = @(Get-CdpTargets $CdpPort)
        # 等主页面出现再注入，避免只命中先启动的头像浮层或独立窗口。
        $mainTargets = @($targets | Where-Object {
            $_.url -match '^app://-/index\.html(?:$|[?#])' -and
            $_.url -notmatch '[?&]initialRoute='
        })
        if ($mainTargets.Count -gt 0) { return $targets }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    @()
}

function Invoke-CdpCommand([string]$WebSocketUrl, [string]$Method, [hashtable]$Params) {
    $ws = [Net.WebSockets.ClientWebSocket]::new()
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(3))
    try {
        $ws.ConnectAsync([Uri]$WebSocketUrl, $cts.Token).GetAwaiter().GetResult()
        $payload = @{
            id     = Get-Random -Minimum 1000 -Maximum 999999
            method = $Method
            params = $Params
        } | ConvertTo-Json -Compress -Depth 8

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [ArraySegment[byte]]::new($bytes)
        $ws.SendAsync(
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
                $ws.CloseAsync(
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
    [string]$ContentFontFamily,
    [int]$ContentFontSize,
    [int]$ContentFontWeight
) {
    $safeWidth = $ContentWidth.Replace("'", "")
    $safeFontFamily = $ContentFontFamily.Trim()
    $css = @"
:root,
body,
body * {
    font-family: $safeFontFamily !important;
    font-size: ${ContentFontSize}px !important;
    font-weight: $ContentFontWeight !important;
}

[class*="--thread-content-max-width"] {
    --thread-content-max-width: $safeWidth !important;
}
"@

    # JavaScript string is JSON-encoded to avoid quote/escape problems.
    $cssJson = $css | ConvertTo-Json -Compress
    $script = @"
(() => {
  const installSummaryAutoOpenGuard = () => {
    const guardKey = '__codexWideSummaryAutoOpenGuard';
    if (window[guardKey]) {
      window[guardKey].scan();
      return;
    }

    const openStates = new WeakMap();
    const manualIntents = new WeakMap();
    let scanScheduled = false;

    const isSummaryToggle = (element) => {
      if (!(element instanceof HTMLButtonElement)) return false;
      if (!element.hasAttribute('aria-pressed')) return false;
      const label = [
        element.getAttribute('aria-label'),
        element.getAttribute('title'),
      ].filter(Boolean).join(' ');
      return /摘要|summary/i.test(label);
    };

    const scan = () => {
      scanScheduled = false;
      document.querySelectorAll('button[aria-pressed]').forEach((button) => {
        if (!isSummaryToggle(button)) return;

        const isOpen = button.getAttribute('aria-pressed') === 'true';
        const wasOpen = openStates.get(button) === true;
        if (isOpen && !wasOpen) {
          const intentTime = manualIntents.get(button);
          const openedManually = typeof intentTime === 'number' &&
            performance.now() - intentTime < 1500;

          openStates.set(button, true);
          manualIntents.delete(button);
          if (!openedManually) button.click();
          return;
        }

        openStates.set(button, isOpen);
        if (!isOpen) manualIntents.delete(button);
      });
    };

    const scheduleScan = () => {
      if (scanScheduled) return;
      scanScheduled = true;
      window.queueMicrotask(scan);
    };

    document.addEventListener('click', (event) => {
      if (!event.isTrusted || !(event.target instanceof Element)) return;
      const button = event.target.closest('button[aria-pressed]');
      if (!isSummaryToggle(button)) return;
      if (button.getAttribute('aria-pressed') !== 'true') {
        manualIntents.set(button, performance.now());
      }
    }, true);

    const observer = new MutationObserver(scheduleScan);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['aria-label', 'aria-pressed', 'title'],
      childList: true,
      subtree: true,
    });

    window[guardKey] = { observer, scan: scheduleScan };
    scheduleScan();
  };

  const apply = () => {
    const id = 'codex-wide-width-override';
    let style = document.getElementById(id);
    if (!style) {
      style = document.createElement('style');
      style.id = id;
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = $cssJson;
    installSummaryAutoOpenGuard();
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
    $codex = Get-CodexPackage
    Write-Step "检测到 Codex $($codex.Version)"

    Stop-Codex $codex

    if ($Normal) {
        Write-Step '正在正常启动 Codex（恢复默认宽度和字体，不开放 CDP）…'
        Start-CodexPackage $codex
        Write-Step '完成。'
        exit 0
    }

    $Port = Select-Port $Port
    Write-Step "对话区目标宽度：$Width"
    Write-Step "字体：$FontFamily"
    Write-Step "字号：${FontSize}px"
    Write-Step "字重：$FontWeight"
    Write-Host '[Codex Wide] 注意：本次 Codex 运行期间会开放仅限 127.0.0.1 的 Chromium CDP 调试端口。' -ForegroundColor Yellow

    $debugArgs = @(
        '--remote-debugging-address=127.0.0.1',
        "--remote-debugging-port=$Port"
    )

    Write-Step "正在启动 Codex（CDP 端口 $Port）…"
    Start-CodexPackage $codex $debugArgs
    $targets = @(Wait-Cdp $Port 8)

    # Some Codex/Windows combinations redirect package activation arguments through codex://.
    # In that case, retry the validated Store executable directly without modifying WindowsApps.
    if ($targets.Count -eq 0) {
        Write-Step '包激活没有暴露 CDP，尝试直接启动 Store 包内的官方可执行文件…'
        Stop-Codex $codex
        if (-not (Test-Path -LiteralPath $codex.Executable -PathType Leaf)) {
            throw "找不到 Codex 可执行文件：$($codex.Executable)"
        }
        try {
            Start-Process -FilePath $codex.Executable -ArgumentList ($debugArgs -join ' ') -ErrorAction Stop | Out-Null
        } catch {
            throw "Windows 阻止了直接启动 Store 包内 Codex，无法开启 CDP。原始错误：$($_.Exception.Message)"
        }
        $targets = @(Wait-Cdp $Port 8)
    }

    if ($targets.Count -eq 0) {
        throw "Codex 已启动，但 http://127.0.0.1:$Port 没有可用的 CDP page target。"
    }

    Inject-WideUi $targets $Width $FontFamily $FontSize $FontWeight
    Write-Step "注入成功：对话区宽度已设为 $Width，字体 $FontFamily，字号 ${FontSize}px，字重 $FontWeight，并已阻止摘要面板自动弹出。"
    Write-Step '以后用 wide.sh 启动即可；要恢复默认宽度和字体，运行 normal.sh。'
    Start-Sleep -Seconds 1
    exit 0
} catch {
    Write-Host "[Codex Wide] 失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
