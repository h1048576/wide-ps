#!/usr/bin/env sh

# 只需要改这里，例如 72rem / 80rem / 90rem / 1200px / 1400px。
WIDTH='80rem'

# 界面字体、字号和字重（100–1000）
FONT_FAMILY='Cascadia Mono, LXGW WenKai Mono'
FONT_SIZE=17
FONT_WEIGHT=300

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
script_path="$script_dir/codexhost-wide.ps1"

if [ ! -f "$script_path" ]; then
  printf '找不到 CodexHost Wide 启动脚本：%s\n' "$script_path" >&2
  exit 1
fi

# Git Bash/MSYS 使用 cygpath 把 Unix 风格路径转换成 Windows 路径。
if command -v cygpath >/dev/null 2>&1; then
  script_path=$(cygpath -w "$script_path") || exit 1
elif command -v wslpath >/dev/null 2>&1; then
  script_path=$(wslpath -w "$script_path") || exit 1
fi

if command -v pwsh.exe >/dev/null 2>&1; then
  powershell_command='pwsh.exe'
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell_command='powershell.exe'
else
  printf '找不到 PowerShell，请安装 PowerShell 7 或检查 PATH。\n' >&2
  exit 1
fi

"$powershell_command" \
  -NoProfile \
  -ExecutionPolicy Bypass \
  -File "$script_path" \
  -Width "$WIDTH" \
  -FontFamily "$FONT_FAMILY" \
  -FontSize "$FONT_SIZE" \
  -FontWeight "$FONT_WEIGHT" \
  -Detach \
  -Restart \
  "$@"
status=$?

if [ "$status" -ne 0 ]; then
  printf '\nCodexHost Wide 启动失败，见上面的错误信息。\n'
  printf '按 Enter 键退出...'
  read -r _
fi

exit "$status"
