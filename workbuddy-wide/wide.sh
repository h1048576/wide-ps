#!/usr/bin/env sh

# 聊天对话区宽度和最大宽度，例如 100% / 90rem / 1200px / 80vw
WIDTH='100%'
MAX_WIDTH='90rem'

# 界面字体、字号和字重（100–1000）
FONT_FAMILY='Cascadia Mono, LXGW WenKai Mono'
FONT_SIZE=17
FONT_WEIGHT=200

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
script_path="$script_dir/workbuddy.ps1"

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
  -FontWeight "$FONT_WEIGHT" \
  -Background
status=$?

if [ "$status" -ne 0 ]; then
  printf '\nWorkBuddy Wide 后台启动失败，见上面的错误信息。\n'
  printf '按 Enter 键退出...'
  read -r _
fi

exit "$status"
