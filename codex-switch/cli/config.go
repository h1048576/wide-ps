package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/pelletier/go-toml"
	"wesure.cn/msf/errors"
)

const (
	providerID    = "local_models"
	contextWindow = 1000000
)

func tomlString(value string) string {
	data, _ := json.Marshal(value)
	return string(data)
}

func makeConfig(original []byte, store *storage, settings *modelSettings, selected *model) ([]byte, error) {
	original = trimBOM(original)
	if _, err := toml.LoadBytes(original); err != nil {
		return nil, errors.New("原 config.toml 格式无效，请修正后重试；原配置未修改。")
	}
	rootValues := [][2]string{
		{"model", tomlString(selected.GetModel())},
		{"model_provider", tomlString(providerID)},
		{"model_catalog_json", tomlString(filepath.ToSlash(filepath.Join(store.directory, catalogName)))},
		{"model_reasoning_effort", tomlString(selected.GetDefaultEffect())},
		{"model_context_window", fmt.Sprint(contextWindow)},
		{"web_search", `"disabled"`},
	}
	removeRoot := map[string]bool{
		"profile": true, "preferred_auth_method": true, "forced_login_method": true,
		"openai_base_url": true, "plan_mode_reasoning_effort": true,
		"model_reasoning_summary": true, "model_supports_reasoning_summaries": true,
		"model_verbosity": true, "service_tier": true,
		"model_auto_compact_token_limit": true, "model_auto_compact_token_limit_scope": true,
	}
	var output strings.Builder
	for _, pair := range rootValues {
		fmt.Fprintf(&output, "%s = %s\n", pair[0], pair[1])
		removeRoot[pair[0]] = true
	}
	output.WriteByte('\n')
	effects, err := json.Marshal(settings.allEffects())
	if err != nil {
		return nil, err
	}
	desktopSetting := "enabled-reasoning-efforts = " + string(effects) + "\n"
	var section []string
	skipSection, desktopWritten := false, false
	for _, statement := range tomlStatements(string(original)) {
		trimmed := strings.TrimSpace(statement)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			if !skipSection {
				output.WriteString(statement)
			}
			continue
		}
		if strings.HasPrefix(trimmed, "[") {
			section, err = tomlExpressionPath(statement)
			if err != nil {
				return nil, err
			}
			skipSection = len(section) >= 2 && section[0] == "model_providers" && section[1] == providerID
			if skipSection {
				continue
			}
			output.WriteString(statement)
			if len(section) == 1 && section[0] == "desktop" {
				if desktopWritten || strings.HasPrefix(trimmed, "[[") {
					return nil, errors.New("[desktop] 必须是唯一的普通配置段；原配置未修改。")
				}
				if !strings.HasSuffix(statement, "\n") {
					output.WriteByte('\n')
				}
				output.WriteString(desktopSetting)
				desktopWritten = true
			}
			continue
		}
		if skipSection {
			continue
		}
		key, err := tomlExpressionPath(assignmentKey(trimmed) + " = true")
		if err != nil {
			return nil, err
		}
		skip := false
		if len(section) == 0 {
			if len(key) == 1 {
				if key[0] == "desktop" || key[0] == "model_providers" {
					return nil, failure("%s 使用了内联表，请改为独立的 TOML 配置段后重试；原配置未修改。", key[0])
				}
				skip = removeRoot[key[0]]
			} else if key[0] == "model_providers" && key[1] == providerID {
				skip = true
			} else if key[0] == "desktop" {
				if len(key) != 2 || key[1] != "enabled-reasoning-efforts" {
					return nil, errors.New("desktop 使用了点分键，请改为 [desktop] 配置段后重试；原配置未修改。")
				}
				skip = true
			}
		} else if len(section) == 1 {
			skip = (section[0] == "model_providers" && key[0] == providerID) ||
				(section[0] == "desktop" && len(key) == 1 && key[0] == "enabled-reasoning-efforts")
		}
		if !skip {
			output.WriteString(statement)
		}
	}
	output.WriteByte('\n')
	if !desktopWritten {
		output.WriteString("[desktop]\n" + desktopSetting + "\n")
	}
	fmt.Fprintf(&output, "[model_providers.%s]\n", providerID)
	fmt.Fprintf(&output, "name = %s\nbase_url = %s\n", tomlString("本地模型"), tomlString(settings.GetBaseURL()))
	fmt.Fprintf(&output, "wire_api = \"responses\"\nexperimental_bearer_token = %s\n", tomlString(settings.GetAPIKey()))
	output.WriteString("requires_openai_auth = false\nsupports_websockets = false\n")
	result := []byte(output.String())
	if _, err := toml.LoadBytes(result); err != nil {
		return nil, errors.New("生成的 config.toml 无效，请检查原配置中的模型提供方及 desktop 配置段；原配置未修改。")
	}
	return result, nil
}

// 按完整 TOML 语句切分，仅替换托管字段，保留其他语句、注释和换行。
// 完整文档由 TOML 库先验证，扫描器只负责定位跨行数组、内联表及字符串边界。
func tomlStatements(input string) []string {
	var result []string
	start, depth := 0, 0
	var quote byte
	multiline, comment := false, false
	for i := 0; i < len(input); i++ {
		ch := input[i]
		if comment {
			if ch != '\n' {
				continue
			}
			comment = false
		} else if quote != 0 {
			if quote == '"' && ch == '\\' {
				i++
				continue
			}
			if ch == quote {
				if multiline {
					end := i
					for end < len(input) && input[end] == quote {
						end++
					}
					if end-i >= 3 {
						quote, multiline = 0, false
					}
					i = end - 1
				} else {
					quote = 0
				}
			}
			continue
		} else {
			switch ch {
			case '#':
				comment = true
			case '\'', '"':
				quote = ch
				if i+2 < len(input) && input[i+1] == ch && input[i+2] == ch {
					multiline = true
					i += 2
				}
			case '[', '{':
				depth++
			case ']', '}':
				depth--
			}
		}
		if ch == '\n' && depth == 0 && quote == 0 {
			result = append(result, input[start:i+1])
			start = i + 1
		}
	}
	if start < len(input) {
		result = append(result, input[start:])
	}
	return result
}

func assignmentKey(input string) string {
	var quote byte
	for i := 0; i < len(input); i++ {
		ch := input[i]
		if quote != 0 {
			if quote == '"' && ch == '\\' {
				i++
			} else if ch == quote {
				quote = 0
			}
		} else if ch == '\'' || ch == '"' {
			quote = ch
		} else if ch == '=' {
			return strings.TrimSpace(input[:i])
		}
	}
	return ""
}

// 交给 TOML 库解码带引号、转义或点分的键，避免将字符串内的点误当分隔符。
func tomlExpressionPath(expression string) ([]string, error) {
	tree, err := toml.Load(expression)
	if err != nil {
		return nil, errors.New("无法解析 TOML 配置键；原配置未修改。")
	}
	var path []string
	for {
		keys := tree.Keys()
		if len(keys) == 0 && len(path) > 0 {
			return path, nil
		}
		if len(keys) != 1 {
			return nil, errors.New("TOML 配置键路径无效；原配置未修改。")
		}
		path = append(path, keys[0])
		switch value := tree.GetPath(keys).(type) {
		case *toml.Tree:
			tree = value
		case []*toml.Tree:
			if len(value) != 1 {
				return nil, errors.New("TOML 数组配置段无效；原配置未修改。")
			}
			tree = value[0]
		default:
			return path, nil
		}
	}
}

func (app *application) showStatus(store *storage) error {
	path := filepath.Join(store.directory, configName)
	fmt.Fprintf(app.output, "配置文件：%s\n", path)
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		fmt.Fprintln(app.output, "尚未创建 config.toml。")
		return nil
	}
	if err != nil {
		return failure("读取 config.toml 失败：%+v", err)
	}
	tree, err := toml.LoadBytes(trimBOM(data))
	if err != nil {
		return errors.New("config.toml 格式无效，无法读取状态。")
	}
	for _, entry := range [][2]string{
		{"模型", "model"}, {"提供方", "model_provider"}, {"思考等级", "model_reasoning_effort"},
		{"上下文", "model_context_window"}, {"模型目录", "model_catalog_json"},
		{"桌面端可选档位", "desktop.enabled-reasoning-efforts"},
	} {
		value := tree.Get(entry[1])
		if value == nil {
			value = "未设置"
		}
		fmt.Fprintf(app.output, "%s：%v\n", entry[0], value)
	}
	if _, err := os.Stat(filepath.Join(store.initialPath(), "manifest.json")); err == nil {
		fmt.Fprintf(app.output, "首次备份：%s\n", store.initialPath())
	}
	return nil
}
