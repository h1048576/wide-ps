#!/usr/bin/env sh
# 以 Menu 模式调用 codex-local-models-setup.ps1 切换本地模型。
# 额外参数原样传给 PowerShell 脚本，例如：./codex-local-models-switch.sh -SkipConnectionCheck
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ps1_path="$script_dir/codex-local-models-setup.ps1"

if [ ! -f "$ps1_path" ]; then
    echo "找不到脚本：$ps1_path" >&2
    exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
    ps_exe=pwsh
elif command -v powershell.exe >/dev/null 2>&1; then
    ps_exe=powershell.exe
else
    echo "未找到 PowerShell（pwsh 或 powershell.exe）。" >&2
    exit 1
fi

# Windows 上的 PowerShell 只认 Windows 路径（Git Bash / Cygwin 用 cygpath，WSL 用 wslpath）。
if command -v cygpath >/dev/null 2>&1; then
    ps1_path=$(cygpath -w "$ps1_path")
elif [ "$ps_exe" = powershell.exe ] && command -v wslpath >/dev/null 2>&1; then
    ps1_path=$(wslpath -w "$ps1_path")
fi

exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$ps1_path" -Action Menu "$@"
