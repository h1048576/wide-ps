#!/usr/bin/env sh

# 对话区宽度，例如 72rem / 80rem / 90rem / 1200px / 1400px
WIDTH='90rem'

# 中英文字体按顺序回退：Cascadia Mono 显示英文，LXGW WenKai Mono 补充中文字符。
FONT_FAMILY='Cascadia Mono, LXGW WenKai Mono'
# 界面字重（100–1000）
FONT_WEIGHT=300

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
script_path="$script_dir/zcode.ps1"
log_path="$script_dir/zcode.log"

if command -v cygpath >/dev/null 2>&1; then
  script_path=$(cygpath -w "$script_path") || exit 1
elif command -v wslpath >/dev/null 2>&1; then
  script_path=$(wslpath -w "$script_path") || exit 1
fi

if command -v nohup >/dev/null 2>&1; then
  ZCODE_WIDE_SCRIPT_PATH="$script_path" \
  ZCODE_WIDE_WIDTH="$WIDTH" \
  ZCODE_WIDE_FONT_FAMILY="$FONT_FAMILY" \
  ZCODE_WIDE_FONT_WEIGHT="$FONT_WEIGHT" \
  nohup powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    '& ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 -LiteralPath $env:ZCODE_WIDE_SCRIPT_PATH))) -Width $env:ZCODE_WIDE_WIDTH -FontFamily $env:ZCODE_WIDE_FONT_FAMILY -FontWeight $env:ZCODE_WIDE_FONT_WEIGHT' \
    >"$log_path" 2>&1 </dev/null &
else
  ZCODE_WIDE_SCRIPT_PATH="$script_path" \
  ZCODE_WIDE_WIDTH="$WIDTH" \
  ZCODE_WIDE_FONT_FAMILY="$FONT_FAMILY" \
  ZCODE_WIDE_FONT_WEIGHT="$FONT_WEIGHT" \
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    '& ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 -LiteralPath $env:ZCODE_WIDE_SCRIPT_PATH))) -Width $env:ZCODE_WIDE_WIDTH -FontFamily $env:ZCODE_WIDE_FONT_FAMILY -FontWeight $env:ZCODE_WIDE_FONT_WEIGHT' \
    >"$log_path" 2>&1 </dev/null &
fi

worker_pid=$!
printf 'ZCode Wide 已转入后台运行（后台任务 PID：%s）。\n' "$worker_pid"
printf '启动与注入日志：%s\n' "$log_path"
exit 0
