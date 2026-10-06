#!/usr/bin/env sh

# 对话区宽度和最大宽度，例如 100% / 90rem / 1200px / 80vw
WIDTH='80rem'
MAX_WIDTH='90rem'

# 界面字体、字号和字重（100–1000）
FONT_FAMILY='Cascadia Mono, LXGW WenKai Mono'
FONT_SIZE=18
FONT_WEIGHT=300

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
script_path="$script_dir/qoder.ps1"

if command -v cygpath >/dev/null 2>&1; then
  script_path=$(cygpath -w "$script_path") || exit 1
elif command -v wslpath >/dev/null 2>&1; then
  script_path=$(wslpath -w "$script_path") || exit 1
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script_path" \
  -Width "$WIDTH" \
  -MaxWidth "$MAX_WIDTH" \
  -FontFamily "$FONT_FAMILY" \
  -FontSize "$FONT_SIZE" \
  -FontWeight "$FONT_WEIGHT"
status=$?

if [ "$status" -ne 0 ]; then
  printf '\nQoder Wide 启动失败，见上面的错误信息。\n'
fi

exit "$status"
