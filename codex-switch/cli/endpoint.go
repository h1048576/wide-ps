package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"golang.org/x/net/context"
	"wesure.cn/msf/errors"
)

func checkEndpoint(ctx context.Context, settings *modelSettings, selected *model) error {
	client := &http.Client{
		Timeout: 15 * time.Second,
		// 不跟随网关重定向，确保探测请求和密钥始终留在配置的本机地址。
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := endpointRequest(ctx, client, settings, http.MethodGet, "/models", nil)
	if err != nil {
		return err
	}
	var catalog struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	err = json.NewDecoder(io.LimitReader(response.Body, 16<<20)).Decode(&catalog)
	response.Body.Close()
	if err != nil {
		return errors.New("/models 未返回有效的模型列表 JSON。")
	}
	available := make(map[string]bool)
	for _, entry := range catalog.Data {
		available[entry.ID] = true
	}
	for _, entry := range settings.GetModels() {
		if !available[entry.GetModel()] {
			return failure("网关模型列表中没有 %s。", entry.GetModel())
		}
	}
	body, err := json.Marshal(map[string]interface{}{
		"model": selected.GetModel(), "input": "仅回复 OK，不要解释。",
		"reasoning": map[string]string{"effort": selected.GetDefaultEffect()},
		"stream":    true, "store": false, "max_output_tokens": 256,
	})
	if err != nil {
		return err
	}
	client.Timeout = 30 * time.Second
	response, err = endpointRequest(ctx, client, settings, http.MethodPost, "/responses", body)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	return consumeResponse(response.Body)
}

func endpointRequest(ctx context.Context, client *http.Client, settings *modelSettings, method, path string, body []byte) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, method, settings.GetBaseURL()+path, bytes.NewReader(body))
	if err != nil {
		return nil, failure("创建 %s 请求失败：%+v", path, err)
	}
	request.Header.Set("Authorization", "Bearer "+settings.GetAPIKey())
	if method == http.MethodPost {
		request.Header.Set("Content-Type", "application/json; charset=utf-8")
		request.Header.Set("Accept", "text/event-stream")
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, failure("请求 %s 失败：%+v", path, err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		response.Body.Close()
		return nil, failure("%s 返回 HTTP %d。", path, response.StatusCode)
	}
	return response, nil
}

func consumeResponse(reader io.Reader) error {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	var lines []string
	eventType := ""
	flush := func() (bool, error) {
		if len(lines) == 0 {
			return false, nil
		}
		data := strings.Join(lines, "\n")
		if strings.TrimSpace(data) == "[DONE]" {
			return false, nil
		}
		var event struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal([]byte(data), &event); err != nil {
			return false, errors.New("Responses 流式事件不是有效 JSON。")
		}
		kind := event.Type
		if kind == "" {
			kind = eventType
		}
		switch kind {
		case "response.completed":
			return true, nil
		case "response.failed", "response.incomplete", "error":
			return false, failure("Responses 接口返回 %s 事件。", kind)
		}
		return false, nil
	}
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			completed, err := flush()
			if err != nil || completed {
				return err
			}
			lines, eventType = nil, ""
			continue
		}
		if value, ok := strings.CutPrefix(line, "data:"); ok {
			lines = append(lines, strings.TrimPrefix(value, " "))
		} else if value, ok := strings.CutPrefix(line, "event:"); ok {
			eventType = strings.TrimSpace(value)
		}
	}
	if err := scanner.Err(); err != nil {
		return failure("读取 Responses 流失败：%+v", err)
	}
	if completed, err := flush(); err != nil || completed {
		return err
	}
	return errors.New("未收到 response.completed 流式事件。")
}
