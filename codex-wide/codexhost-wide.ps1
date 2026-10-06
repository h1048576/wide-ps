param(
    [ValidatePattern('^[0-9]{2,4}(?:\.[0-9]+)?(?:rem|px|vw)$')]
    [string]$Width = '80rem',

    [ValidateRange(8, 72)]
    [int]$FontSize = 18,

    [ValidateRange(100, 1000)]
    [int]$FontWeight = 300,

    [ValidateScript({ $_ -and $_ -notmatch '[;{}<>\r\n]' })]
    [string]$FontFamily = 'Cascadia Mono, LXGW WenKai Mono',

    [switch]$Detach,

    [switch]$Restart,

    [switch]$PrepareOnly,

    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$CodexHostArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CodexHostCommand {
    $command = Get-Command codexhost.ps1 -CommandType ExternalScript -ErrorAction Stop |
        Select-Object -First 1

    if (-not $command -or -not $command.Path) {
        throw '没有找到 npm 安装的 codexhost.ps1。'
    }

    $command
}

function Invoke-OriginalCodexHost([string[]]$Arguments) {
    $command = Get-CodexHostCommand
    & $command.Path @Arguments
    exit $LASTEXITCODE
}

function Get-CodexDesktopPackage {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $package) {
        throw '没有找到 Microsoft Store 版 Codex（包名 OpenAI.Codex）。'
    }

    [pscustomobject]@{
        InstallRoot = [IO.Path]::GetFullPath($package.InstallLocation).TrimEnd('\')
        Version     = "$($package.Version)"
    }
}

function Get-CodexDesktopProcesses([object]$CodexPackage) {
    $installRoot = $CodexPackage.InstallRoot + '\'

    @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $executablePath = "$($_.ExecutablePath)"
            $executablePath -and $executablePath.StartsWith(
                $installRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
        })
}

function Stop-CodexDesktop {
    $codexPackage = Get-CodexDesktopPackage
    $processes = @(Get-CodexDesktopProcesses $codexPackage)

    if ($processes.Count -eq 0) {
        return
    }

    Write-Host '[Codex Wide] 正在关闭旧的 Codex Desktop 实例…' -ForegroundColor Cyan

    foreach ($process in $processes) {
        try {
            [void](Get-Process -Id $process.ProcessId -ErrorAction Stop).CloseMainWindow()
        } catch {}
    }

    $deadline = (Get-Date).AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-CodexDesktopProcesses $codexPackage)
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

    foreach ($process in @(Get-CodexDesktopProcesses $codexPackage)) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        } catch {}
    }

    # 给旧 CodexHost 监管器一点时间释放启动锁和运行描述符。
    Start-Sleep -Milliseconds 750
}

function ConvertTo-ProcessArgument([string]$Argument) {
    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = [Regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [Regex]::Replace($escaped, '(\\+)$', '$1$1')
    '"' + $escaped + '"'
}

function Start-DetachedCodexHost(
    [object]$Command,
    [string]$RendererPath,
    [string[]]$Arguments,
    [string]$LogDirectory
) {
    $powerShellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
    if (-not $powerShellExecutable) {
        throw '无法确定当前 PowerShell 可执行文件路径。'
    }

    $runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $standardOutputPath = Join-Path $LogDirectory "codexhost.$runId.stdout.log"
    $standardErrorPath = Join-Path $LogDirectory "codexhost.$runId.stderr.log"
    $forwardArguments = @($Arguments | Where-Object { $null -ne $_ })
    $childArguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $Command.Path,
        'launch',
        '--renderer',
        $RendererPath
    ) + $forwardArguments

    $argumentLine = ($childArguments |
        ForEach-Object { ConvertTo-ProcessArgument "$_" }) -join ' '

    $process = Start-Process `
        -FilePath $powerShellExecutable `
        -ArgumentList $argumentLine `
        -WindowStyle Hidden `
        -RedirectStandardOutput $standardOutputPath `
        -RedirectStandardError $standardErrorPath `
        -PassThru

    # 捕获参数错误、启动锁错误等立即失败；正常监管进程会持续运行。
    Start-Sleep -Milliseconds 1200
    $process.Refresh()

    if ($process.HasExited) {
        $errorOutput = ''
        if (Test-Path -LiteralPath $standardErrorPath -PathType Leaf) {
            $errorOutput = [IO.File]::ReadAllText($standardErrorPath).Trim()
        }

        if ($errorOutput) {
            throw "CodexHost 后台启动失败：$errorOutput"
        }

        throw "CodexHost 后台启动失败，退出码：$($process.ExitCode)"
    }

    Write-Host "[Codex Wide] CodexHost 已转入后台监管，PID：$($process.Id)" -ForegroundColor Cyan
    Write-Host "[Codex Wide] 错误日志：$standardErrorPath" -ForegroundColor Cyan
}

$arguments = @($CodexHostArguments | Where-Object { $null -ne $_ })

# --version、--help、inspect、remote 等命令保持原有行为。
# 只有直接运行 codexhost 或 codexhost launch 时才启用 Wide。
if ($arguments.Count -gt 0 -and $arguments[0] -ne 'launch') {
    Invoke-OriginalCodexHost $arguments
}

$launchArguments = @()
if ($arguments.Count -gt 1) {
    $launchArguments = @($arguments[1..($arguments.Count - 1)])
}

if ($launchArguments -contains '--renderer') {
    throw 'Wide 模式会自动提供 --renderer，请不要重复传入该参数。'
}

$codexHostCommand = Get-CodexHostCommand
$nodeGlobalRoot = Split-Path -Parent $codexHostCommand.Path
$codexHostPackageRoot = Join-Path $nodeGlobalRoot 'node_modules\@codexhost\cli'

$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
switch ($architecture) {
    'X64' {
        $platformPackageName = '@codexhost\cli-win32-x64'
    }
    'Arm64' {
        $platformPackageName = '@codexhost\cli-win32-arm64'
    }
    default {
        throw "当前脚本不支持该系统架构：$architecture"
    }
}

$stockRendererPath = Join-Path $codexHostPackageRoot (
    "node_modules\$platformPackageName\app\renderer-extension.js"
)

if (-not (Test-Path -LiteralPath $stockRendererPath -PathType Leaf)) {
    throw "找不到 CodexHost Renderer：$stockRendererPath"
}

$wideRendererSource = @'
"use strict";

(() => {
  const contentWidth = "__CODEX_WIDE_WIDTH__";
  const contentFontFamily = __CODEX_WIDE_FONT_FAMILY__;
  const contentFontSize = __CODEX_WIDE_FONT_SIZE__;
  const contentFontWeight = __CODEX_WIDE_FONT_WEIGHT__;

  const applyWidth = () => {
    const id = "codex-wide-width-override";
    let style = document.getElementById(id);

    if (!style) {
      style = document.createElement("style");
      style.id = id;
      (document.head || document.documentElement).appendChild(style);
    }

    style.textContent = [
      ':root, body, body * {',
      `  font-family: ${contentFontFamily} !important;`,
      `  font-size: ${contentFontSize}px !important;`,
      `  font-weight: ${contentFontWeight} !important;`,
      '}',
      '',
      'body,',
      '[class*="--thread-content-max-width"] {',
      `  --thread-content-max-width: ${contentWidth} !important;`,
      "}",
      "",
      'header[data-pip-obstacle="app-shell-header"] [data-codexhost-settings-trigger],',
      'header[data-pip-obstacle="app-shell-header"] button[aria-label="分享"],',
      'header[data-pip-obstacle="app-shell-header"] button[aria-label="Share"] {',
      "  display: none !important;",
      "}",
    ].join("\n");

    window.__codexWideV2 = {
      width: contentWidth,
      fontFamily: contentFontFamily,
      fontSize: contentFontSize,
      fontWeight: contentFontWeight,
      appliedAt: Date.now(),
    };
  };

  const installSummaryAutoOpenGuard = () => {
    const guardKey = "__codexWideSummaryAutoOpenGuard";

    if (window[guardKey]) {
      window[guardKey].scan();
      return;
    }

    const openStates = new WeakMap();
    const manualIntents = new WeakMap();
    let scanScheduled = false;

    const isSummaryToggle = (element) => {
      if (!(element instanceof HTMLButtonElement)) return false;
      if (!element.hasAttribute("aria-pressed")) return false;

      const label = [
        element.getAttribute("aria-label"),
        element.getAttribute("title"),
      ]
        .filter(Boolean)
        .join(" ");

      return /摘要|summary/i.test(label);
    };

    const scan = () => {
      scanScheduled = false;

      document
        .querySelectorAll("button[aria-pressed]")
        .forEach((button) => {
          if (!isSummaryToggle(button)) return;

          const isOpen = button.getAttribute("aria-pressed") === "true";
          const wasOpen = openStates.get(button) === true;

          if (isOpen && !wasOpen) {
            const intentTime = manualIntents.get(button);
            const openedManually =
              typeof intentTime === "number" &&
              performance.now() - intentTime < 1500;

            openStates.set(button, true);
            manualIntents.delete(button);

            if (!openedManually) {
              button.click();
            }

            return;
          }

          openStates.set(button, isOpen);

          if (!isOpen) {
            manualIntents.delete(button);
          }
        });
    };

    const scheduleScan = () => {
      if (scanScheduled) return;
      scanScheduled = true;
      window.queueMicrotask(scan);
    };

    document.addEventListener(
      "click",
      (event) => {
        if (!event.isTrusted || !(event.target instanceof Element)) return;

        const button = event.target.closest("button[aria-pressed]");
        if (!isSummaryToggle(button)) return;

        if (button.getAttribute("aria-pressed") !== "true") {
          manualIntents.set(button, performance.now());
        }
      },
      true
    );

    const observer = new MutationObserver(scheduleScan);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["aria-label", "aria-pressed", "title"],
      childList: true,
      subtree: true,
    });

    window[guardKey] = {
      observer,
      scan: scheduleScan,
    };

    scheduleScan();
  };

  const apply = () => {
    applyWidth();
    installSummaryAutoOpenGuard();
  };

  if (document.head || document.documentElement) {
    apply();
  } else {
    document.addEventListener("DOMContentLoaded", apply, {
      once: true,
    });
  }
})();
'@

$wideRendererSource = $wideRendererSource.Replace(
    '__CODEX_WIDE_WIDTH__',
    $Width
)
$wideRendererSource = $wideRendererSource.Replace(
    '__CODEX_WIDE_FONT_FAMILY__',
    ($FontFamily.Trim() | ConvertTo-Json -Compress)
)
$wideRendererSource = $wideRendererSource.Replace(
    '__CODEX_WIDE_FONT_SIZE__',
    "$FontSize"
)
$wideRendererSource = $wideRendererSource.Replace(
    '__CODEX_WIDE_FONT_WEIGHT__',
    "$FontWeight"
)

# 每次运行都从当前安装版本的 CodexHost Renderer 生成组合文件，
# 避免升级 CodexHost 后继续使用旧版 Renderer。
$generatedDirectory = Join-Path $env:LOCALAPPDATA 'CodexWide'
$generatedRendererPath = Join-Path $generatedDirectory 'codexhost-renderer.js'

[IO.Directory]::CreateDirectory($generatedDirectory) | Out-Null

$stockRendererSource = [IO.File]::ReadAllText($stockRendererPath)
$combinedRendererSource = (
    $stockRendererSource +
    [Environment]::NewLine +
    [Environment]::NewLine +
    $wideRendererSource +
    [Environment]::NewLine
)

$shouldWrite = $true
if (Test-Path -LiteralPath $generatedRendererPath -PathType Leaf) {
    $existingSource = [IO.File]::ReadAllText($generatedRendererPath)
    $shouldWrite = $existingSource -ne $combinedRendererSource
}

if ($shouldWrite) {
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText(
        $generatedRendererPath,
        $combinedRendererSource,
        $utf8WithoutBom
    )
}

if ($PrepareOnly) {
    Write-Host "[Codex Wide] 已生成组合 Renderer：$generatedRendererPath" -ForegroundColor Cyan
    Write-Host "[Codex Wide] 对话区目标宽度：$Width" -ForegroundColor Cyan
    Write-Host "[Codex Wide] 字体：$FontFamily" -ForegroundColor Cyan
    Write-Host "[Codex Wide] 字号：${FontSize}px" -ForegroundColor Cyan
    Write-Host "[Codex Wide] 字重：$FontWeight" -ForegroundColor Cyan
    exit 0
}

if ($Restart) {
    Stop-CodexDesktop
}

Write-Host "[Codex Wide] CodexHost Renderer：$stockRendererPath" -ForegroundColor Cyan
Write-Host "[Codex Wide] 对话区目标宽度：$Width" -ForegroundColor Cyan
Write-Host "[Codex Wide] 字体：$FontFamily" -ForegroundColor Cyan
Write-Host "[Codex Wide] 字号：${FontSize}px" -ForegroundColor Cyan
Write-Host "[Codex Wide] 字重：$FontWeight" -ForegroundColor Cyan

if ($Detach) {
    Write-Host '[Codex Wide] 正在后台启动 CodexHost 和 Codex Desktop…' -ForegroundColor Cyan
    Start-DetachedCodexHost `
        -Command $codexHostCommand `
        -RendererPath $generatedRendererPath `
        -Arguments $launchArguments `
        -LogDirectory $generatedDirectory
    exit 0
}

Write-Host '[Codex Wide] 正在通过 CodexHost 启动 Codex Desktop…' -ForegroundColor Cyan

& $codexHostCommand.Path launch `
    --renderer $generatedRendererPath `
    @launchArguments

exit $LASTEXITCODE
