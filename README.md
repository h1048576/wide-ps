# AI 编程工具界面加宽脚本集合

一套用于调整各类 AI 编程工具（Codex、Droid、Paseo、Qoder、WorkBuddy、ZCode）界面布局与字体的脚本集合，支持 PowerShell（Windows）与 Shell（Git Bash / WSL / macOS / Linux）两种运行方式。

## 目录结构

| 目录 | 说明 |
| --- | --- |
| `codex-wide/` | OpenAI Codex 界面加宽脚本 |
| `codex-switch/` | Codex 本地模型切换脚本 |
| `droid-wide/` | Droid 界面加宽脚本 |
| `paseo-wide/` | Paseo 界面加宽脚本 |
| `qoder-wide/` | Qoder 界面加宽脚本 |
| `workbuddy-wide/` | WorkBuddy 界面加宽脚本 |
| `zcode-wide/` | ZCode 界面加宽脚本 |

## 使用方法

### PowerShell（Windows）

```powershell
# Codex 界面加宽（默认 80rem，字号 18，字重 300）
.\codex-wide\codex.ps1

# 自定义宽度与字体
.\codex-wide\codex.ps1 -Width 90rem -FontSize 16 -FontWeight 100 -FontFamily 'Cascadia Mono, LXGW WenKai Mono'

# 恢复默认布局
.\codex-wide\codex.ps1 -Normal
```

常用参数（不同工具的脚本参数略有差异，可用 `Get-Help` 查看）：

- `-Width`：对话区目标宽度，如 `80rem`、`1200px`
- `-MaxWidth`：最大宽度限制
- `-FontSize` / `-FontWeight` / `-FontFamily`：字体样式
- `-Normal`：恢复默认布局

### Shell（Git Bash / WSL / macOS / Linux）

```sh
./codex-wide/wide.sh
```

脚本顶部的 `WIDTH`、`FONT_FAMILY`、`FONT_SIZE`、`FONT_WEIGHT` 变量可直接修改。

### Codex 本地模型切换

```powershell
# 配置本地模型（默认 glm-5.3-flashx，思考等级 xhigh）
.\codex-switch\codex-local-models-setup.ps1

# 指定模型
.\codex-switch\codex-local-models-setup.ps1 -Model deepseek-v4.1-flash

# 菜单模式 / 恢复默认
.\codex-switch\codex-local-models-setup.ps1 -Action Menu
.\codex-switch\codex-local-models-setup.ps1 -Action Restore
```

Git Bash 下也可以用封装好的 Shell 脚本：

```sh
./codex-switch/codex-local-models-switch.sh
```

## 注意事项

- 脚本会修改对应工具的本地配置文件或注入自定义样式，请先关闭正在运行的对应工具再执行。
- 执行前建议备份工具的原始配置文件。
- 各工具升级后内部样式可能变化，脚本如失效请更新适配。

## License

MIT
