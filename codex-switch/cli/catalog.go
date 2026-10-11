package main

import "encoding/json"

func makeCatalog(settings *modelSettings) ([]byte, error) {
	const instructions = "你是 Codex 编程助手。遵守用户和工作目录中的指令，先检查现有代码，再完成用户要求的修改。使用可用工具处理文件和命令；尽量保留无关配置和用户已有修改。根据证据说明结果，不声称执行过尚未执行的操作。默认使用中文回复。"
	entries := make([]map[string]interface{}, 0, len(settings.GetModels()))
	for i, entry := range settings.GetModels() {
		levels := make([]map[string]string, 0, len(entry.GetEffect()))
		for _, effect := range entry.GetEffect() {
			levels = append(levels, map[string]string{"effort": effect, "description": reasoningDescriptions[effect]})
		}
		entries = append(entries, map[string]interface{}{
			"slug": entry.GetModel(), "display_name": entry.GetDisplayName(),
			"description": "通过本地模型网关使用 Responses API", "visibility": "list",
			"supported_in_api": true, "priority": i + 1,
			"default_reasoning_level": entry.GetDefaultEffect(), "supported_reasoning_levels": levels,
			"supports_reasoning_summaries": false, "default_reasoning_summary": "none",
			"support_verbosity": false, "default_verbosity": nil,
			"shell_type": "shell_command", "apply_patch_tool_type": "freeform",
			"web_search_tool_type": "text", "supports_search_tool": false,
			"prefer_websockets": false, "use_responses_lite": false,
			"supports_parallel_tool_calls": false, "experimental_supported_tools": []string{},
			"default_service_tier": nil, "input_modalities": []string{"text", "image"},
			"supports_image_detail_original": false,
			"context_window":                 contextWindow, "max_context_window": contextWindow,
			"effective_context_window_percent": 95,
			"truncation_policy":                map[string]interface{}{"mode": "tokens", "limit": 10000},
			"availability_nux":                 nil, "upgrade": nil, "base_instructions": instructions,
			"model_messages": map[string]string{"instructions_template": instructions},
		})
	}
	data, err := json.MarshalIndent(map[string]interface{}{"models": entries}, "", "  ")
	if err != nil {
		return nil, failure("生成模型目录失败：%+v", err)
	}
	return append(data, '\n'), nil
}
