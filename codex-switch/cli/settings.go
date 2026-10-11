package main

import (
	"bytes"
	"encoding/json"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"unicode"

	"wesure.cn/msf/errors"
)

const settingsName = "codex-local-models.json"

var reasoningDescriptions = map[string]string{
	"none": "不启用思考", "minimal": "最低思考等级", "low": "低思考等级",
	"medium": "中等思考等级", "high": "高思考等级", "xhigh": "超高思考等级",
	"ultra": "极高思考等级", "max": "最高思考等级",
}

type model struct {
	Model       string   `json:"model"`
	DisplayName string   `json:"displayName"`
	Effect      []string `json:"effect"`
}

func (m *model) GetModel() string         { return m.Model }
func (m *model) GetDisplayName() string   { return m.DisplayName }
func (m *model) GetEffect() []string      { return m.Effect }
func (m *model) GetDefaultEffect() string { return m.GetEffect()[len(m.GetEffect())-1] }

type modelSettings struct {
	BaseURL string   `json:"baseUrl"`
	APIKey  string   `json:"apiKey"`
	Models  []*model `json:"models"`
}

func (s *modelSettings) GetBaseURL() string  { return s.BaseURL }
func (s *modelSettings) GetAPIKey() string   { return s.APIKey }
func (s *modelSettings) GetModels() []*model { return s.Models }

func trimBOM(data []byte) []byte {
	return bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
}

func findSettings(requested string) (string, error) {
	if requested != "" {
		return filepath.Abs(requested)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", failure("无法获取当前目录：%+v", err)
	}
	directories := []string{cwd, filepath.Dir(cwd)}
	if executable, err := os.Executable(); err == nil {
		directory := filepath.Dir(executable)
		directories = append(directories, directory, filepath.Dir(directory), filepath.Dir(filepath.Dir(directory)))
	}
	for _, directory := range directories {
		path := filepath.Join(directory, settingsName)
		info, err := os.Stat(path)
		if err == nil && info.Mode().IsRegular() {
			return path, nil
		}
		if err != nil && !os.IsNotExist(err) {
			return "", failure("无法访问配置文件 %s：%+v", path, err)
		}
	}
	return "", errors.New("找不到 codex-local-models.json，请使用 --config 指定路径。")
}

func readSettings(path string) (*modelSettings, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, failure("读取模型配置 %s 失败：%+v", path, err)
	}
	var raw struct {
		BaseURL string            `json:"baseUrl"`
		APIKey  string            `json:"apiKey"`
		Models  []json.RawMessage `json:"models"`
	}
	if err := json.Unmarshal(trimBOM(data), &raw); err != nil {
		return nil, errors.New("模型配置不是有效的 JSON 对象，请检查字段类型。")
	}
	if len(raw.Models) == 0 {
		return nil, errors.New("models 必须是非空数组，请至少保留一个模型。")
	}
	settings := &modelSettings{BaseURL: raw.BaseURL, APIKey: raw.APIKey}
	seen := make(map[string]bool)
	for i, rawModel := range raw.Models {
		var entry model
		if err := json.Unmarshal(rawModel, &entry); err != nil {
			return nil, failure("models[%d] 的 model、displayName 必须是字符串，effect 必须是字符串数组。", i)
		}
		for field, value := range map[string]string{"model": entry.GetModel(), "displayName": entry.GetDisplayName()} {
			if strings.TrimSpace(value) == "" || strings.IndexFunc(value, unicode.IsControl) >= 0 {
				return nil, failure("models[%d].%s 必须是非空字符串，且不能包含控制字符。", i, field)
			}
		}
		entry.Model = strings.TrimSpace(entry.GetModel())
		entry.DisplayName = strings.TrimSpace(entry.GetDisplayName())
		if seen[entry.GetModel()] {
			return nil, failure("models[%d] 的模型 ID 重复。", i)
		}
		seen[entry.GetModel()] = true
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(rawModel, &fields); err != nil {
			return nil, failure("models[%d] 必须是对象。", i)
		}
		if _, provided := fields["effect"]; !provided {
			entry.Effect = []string{"xhigh"}
		}
		if len(entry.GetEffect()) == 0 {
			return nil, failure("models[%d].effect 必须是非空字符串数组。", i)
		}
		levels := make(map[string]bool)
		for _, level := range entry.GetEffect() {
			if _, ok := reasoningDescriptions[level]; !ok {
				return nil, failure("models[%d].effect 仅支持 none、minimal、low、medium、high、xhigh、ultra、max。", i)
			}
			if levels[level] {
				return nil, failure("models[%d].effect 存在重复档位。", i)
			}
			levels[level] = true
		}
		settings.Models = append(settings.Models, &entry)
	}
	return settings, nil
}

func (s *modelSettings) selectModel(requested string) (*model, error) {
	if strings.TrimSpace(requested) == "" {
		return s.GetModels()[0], nil
	}
	for _, entry := range s.GetModels() {
		if entry.GetModel() == requested {
			return entry, nil
		}
	}
	for _, match := range []func(*model) string{
		func(entry *model) string { return entry.GetDisplayName() },
		func(entry *model) string { return entry.GetModel()[strings.LastIndex(entry.GetModel(), "/")+1:] },
	} {
		var selected *model
		for _, entry := range s.GetModels() {
			if match(entry) == requested {
				if selected != nil {
					return nil, errors.New("模型名称匹配多个条目，请使用完整模型 ID。")
				}
				selected = entry
			}
		}
		if selected != nil {
			return selected, nil
		}
	}
	return nil, failure("找不到模型 %q，请使用 list 查看配置中的模型。", requested)
}

func (s *modelSettings) validateConnection() error {
	if strings.TrimSpace(s.GetAPIKey()) == "" {
		return errors.New("apiKey 不能为空，请填写 JSON 或设置 CODEX_SWITCH_API_KEY。")
	}
	s.BaseURL = strings.TrimRight(strings.TrimSpace(s.GetBaseURL()), "/")
	endpoint, err := url.Parse(s.GetBaseURL())
	if err != nil {
		return errors.New("baseUrl 不是有效的 URL。")
	}
	ip := net.ParseIP(endpoint.Hostname())
	loopback := strings.EqualFold(endpoint.Hostname(), "localhost") || (ip != nil && ip.IsLoopback())
	if (endpoint.Scheme != "http" && endpoint.Scheme != "https") || !loopback || endpoint.Path != "/v1" || endpoint.RawQuery != "" || endpoint.ForceQuery || endpoint.Fragment != "" || endpoint.User != nil {
		return errors.New("baseUrl 必须是本机 HTTP(S) 地址，且以 /v1 结尾，例如 http://localhost:20128/v1。")
	}
	return nil
}

func (s *modelSettings) allEffects() []string {
	var result []string
	seen := make(map[string]bool)
	for _, entry := range s.GetModels() {
		for _, effect := range entry.GetEffect() {
			if !seen[effect] {
				seen[effect] = true
				result = append(result, effect)
			}
		}
	}
	return result
}
