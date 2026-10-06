#!/usr/bin/env sh

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
script_path="$script_dir/zcode.ps1"

if command -v cygpath >/dev/null 2>&1; then
  script_path=$(cygpath -w "$script_path") || exit 1
elif command -v wslpath >/dev/null 2>&1; then
  script_path=$(wslpath -w "$script_path") || exit 1
fi

ZCODE_WIDE_SCRIPT_PATH="$script_path" \
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
  '& ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 -LiteralPath $env:ZCODE_WIDE_SCRIPT_PATH))) -Normal'
status=$?

if [ "$status" -ne 0 ]; then
  printf '\nZCode 正常启动失败，见上面的错误信息。\n'
  printf '按 Enter 键退出...'
  read -r _
fi

exit "$status"
