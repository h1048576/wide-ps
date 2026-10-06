#!/usr/bin/env sh

# 只需要改这里，例如 72rem / 80rem / 90rem / 1200px / 1400px
WIDTH='100rem'

# 界面字重（100–1000）
FONT_WEIGHT=300

# 界面隐藏开关：1 = 隐藏，0 = 显示
HIDE_LOCAL_MERGE=1
HIDE_GIT_DIFF=1

case "$HIDE_LOCAL_MERGE" in
  0|1) ;;
  *)
    printf '\nHIDE_LOCAL_MERGE 只能设为 0 或 1。\n'
    exit 2
    ;;
esac

case "$HIDE_GIT_DIFF" in
  0|1) ;;
  *)
    printf '\nHIDE_GIT_DIFF 只能设为 0 或 1。\n'
    exit 2
    ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
script_path="$script_dir/paseo.ps1"

if command -v cygpath >/dev/null 2>&1; then
  script_path=$(cygpath -w "$script_path") || exit 1
elif command -v wslpath >/dev/null 2>&1; then
  script_path=$(wslpath -w "$script_path") || exit 1
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script_path" \
  -Width "$WIDTH" \
  -FontWeight "$FONT_WEIGHT" \
  -HideLocalMerge "$HIDE_LOCAL_MERGE" \
  -HideGitDiff "$HIDE_GIT_DIFF" \
  -Background
status=$?

if [ "$status" -ne 0 ]; then
  printf '\nPaseo Wide 后台启动失败，见上面的错误信息。\n'
  printf '按 Enter 键退出...'
  read -r _
fi

exit "$status"
