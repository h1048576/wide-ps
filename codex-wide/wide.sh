#!/usr/bin/env sh

# 只需要改这里，例如 72rem / 80rem / 90rem / 1200px / 1400px
# 加宽模式同时阻止摘要面板自动弹出，但仍可从右上角手动打开。
WIDTH='80rem'

# 界面字体、字号和字重（100–1000）
FONT_FAMILY='Cascadia Mono, LXGW WenKai Mono'
FONT_SIZE=16
FONT_WEIGHT=100

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
script_path="$script_dir/codex.ps1"

if command -v cygpath >/dev/null 2>&1; then
  script_path=$(cygpath -w "$script_path") || exit 1
elif command -v wslpath >/dev/null 2>&1; then
  script_path=$(wslpath -w "$script_path") || exit 1
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script_path" \
  -Width "$WIDTH" \
  -FontFamily "$FONT_FAMILY" \
  -FontSize "$FONT_SIZE" \
  -FontWeight "$FONT_WEIGHT"
status=$?

if [ "$status" -ne 0 ]; then
  printf '\nCodex Wide 启动失败，见上面的错误信息。\n'
  printf '按 Enter 键退出...'
  read -r _
fi

exit "$status"
