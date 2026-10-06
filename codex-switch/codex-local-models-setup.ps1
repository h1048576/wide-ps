#requires -Version 5.1
<#
.SYNOPSIS
为 Codex 配置本地模型，默认使用 glm-5.3-flashx，思考等级为 xhigh。
.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\codex-local-models-setup.ps1
.EXAMPLE
.\codex-local-models-setup.ps1 -Model deepseek-v4.1-flash
.EXAMPLE
.\codex-local-models-setup.ps1 -Action Menu
.EXAMPLE
.\codex-local-models-setup.ps1 -Action Restore
.NOTES
参考：https://cdn.deepseek.com/api-docs/codex-deepseek-setup.ps1
配置：https://developers.openai.com/codex/config-reference/
只写入 config.toml、models-local.json 和备份目录，不修改 auth.json。
首次安装前的配置永久保留；每次修改另存一份快照；失败时回滚。
支持 Windows PowerShell 5.1 / PowerShell 7，也支持读取脚本文本后执行 iex。
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Menu', 'Restore')]
    [string]$Action = 'Install',

    [ValidateSet('glm-5.3-flashx', 'deepseek-v4.1-flash')]
    [string]$Model = 'glm-5.3-flashx',

    [string]$BaseUrl = 'http://localhost:20128/v1',
    [string]$ApiKey = 'sk-8a3316bd1cf5f6cf-7703e9-99ea6cb2',

    [string]$CodexHomeDir = $(
        if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
        } else {
            $env:CODEX_HOME
        }
    ),

    # 服务未启动时，可跳过检查，先生成配置；实际使用仍需要 Responses API。
    [switch]$SkipConnectionCheck
)

# 子作用域避免 irm | iex 改变调用方的严格模式、错误处理或函数定义。
& {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 2.0

    $providerId = 'local_models'
    $reasoningEffort = 'xhigh'
    $modelSlugs = @('cbcn/glm-5.3-flashx', 'cbcn/deepseek-v4.1-flash')
    $selectedAction = $Action
    $selectedModel = $Model
    $configDirectory = [IO.Path]::GetFullPath($CodexHomeDir)
    $configPath = Join-Path $configDirectory 'config.toml'
    $catalogPath = Join-Path $configDirectory 'models-local.json'
    $backupDirectory = Join-Path $configDirectory 'backup-local-models'
    $initialBackup = Join-Path $backupDirectory 'initial'
    $managedFiles = @('config.toml', 'models-local.json')
    $utf8NoBom = New-Object Text.UTF8Encoding($false)

    function Write-Status {
        param([string]$Message)
        Write-Host ('[OK] ' + $Message) -ForegroundColor Green
    }

    function ConvertTo-TomlString {
        param([string]$Value)
        # JSON 的基本字符串转义也适用于此处的 TOML 字符串。
        return (ConvertTo-Json -InputObject $Value -Compress)
    }

    function Update-TomlState {
        param([string]$Line, [hashtable]$State)
        $quote = ''
        for ($i = 0; $i -lt $Line.Length; $i++) {
            $character = $Line[$i]
            $triple = if ($i + 3 -le $Line.Length) { $Line.Substring($i, 3) } else { '' }
            if ($State.Multiline) {
                if (($State.Multiline -eq 'basic' -and $triple -eq '"""') -or
                    ($State.Multiline -eq 'literal' -and $triple -eq "'''")) {
                    $State.Multiline = ''; $i += 2
                } elseif ($State.Multiline -eq 'basic' -and $character -eq '\') {
                    $i++
                }
                continue
            }
            if ($quote) {
                if ($quote -eq 'basic' -and $character -eq '\') { $i++; continue }
                if (($quote -eq 'basic' -and $character -eq '"') -or
                    ($quote -eq 'literal' -and $character -eq "'")) { $quote = '' }
                continue
            }
            if ($triple -eq '"""') { $State.Multiline = 'basic'; $i += 2; continue }
            if ($triple -eq "'''") { $State.Multiline = 'literal'; $i += 2; continue }
            switch ($character) {
                '#' { return }
                '"' { $quote = 'basic' }
                "'" { $quote = 'literal' }
                '[' { $State.Depth++ }
                ']' { $State.Depth-- }
                '{' { $State.Depth++ }
                '}' { $State.Depth-- }
            }
        }
    }

    function Get-TomlPath {
        param([string]$Text)
        $parts = New-Object 'Collections.Generic.List[string]'
        $keyPattern = '\G\s*(?:"(?<basic>(?:\\.|[^"\\])*)"|''(?<literal>[^'']*)''|(?<bare>[A-Za-z0-9_-]+))\s*(?:\.|$)'
        $position = 0
        while ($position -lt $Text.Length) {
            $match = [regex]::Match($Text.Substring($position), $keyPattern)
            if (-not $match.Success) { throw '无法解析 TOML 配置键，请检查配置格式。' }
            if ($match.Groups['basic'].Success) {
                $parts.Add(('"' + $match.Groups['basic'].Value + '"' | ConvertFrom-Json))
            } elseif ($match.Groups['literal'].Success) {
                $parts.Add($match.Groups['literal'].Value)
            } else {
                $parts.Add($match.Groups['bare'].Value)
            }
            $position += $match.Length
        }
        return $parts.ToArray()
    }

    function New-ConfigText {
        param([string]$Original, [string]$Slug, [string]$Endpoint)
        $settings = [ordered]@{
            model = (ConvertTo-TomlString $Slug)
            model_provider = (ConvertTo-TomlString $providerId)
            model_catalog_json = (ConvertTo-TomlString ($catalogPath.Replace('\', '/')))
            model_reasoning_effort = (ConvertTo-TomlString $reasoningEffort)
            web_search = '"disabled"'
        }
        # 清理上一模型专属的覆盖值，避免发送网关未声明支持的参数。
        $removeKeys = @(
            'profile', 'preferred_auth_method', 'forced_login_method', 'openai_base_url',
            'plan_mode_reasoning_effort',
            'model_reasoning_summary', 'model_supports_reasoning_summaries', 'model_verbosity', 'service_tier',
            'model_context_window', 'model_auto_compact_token_limit',
            'model_auto_compact_token_limit_scope'
        )
        $output = New-Object 'Collections.Generic.List[string]'
        foreach ($key in $settings.Keys) { $output.Add($key + ' = ' + $settings[$key]) }
        $output.Add('')
        $state = @{ Multiline = ''; Depth = 0 }
        $section = @()
        $skipSection = $false
        $skipAssignment = $false
        foreach ($line in ($Original -split '\r?\n')) {
            $atBoundary = -not $state.Multiline -and $state.Depth -eq 0
            if ($atBoundary) {
                $skipAssignment = $false
                $header = [regex]::Match($line, '^\s*\[\[?(?<name>.*?)\]\]?\s*(?:#.*)?$')
                if ($header.Success) {
                    $section = @(Get-TomlPath $header.Groups['name'].Value)
                    $skipSection = $section.Count -ge 2 -and $section[0] -ceq 'model_providers' -and $section[1] -ceq $providerId
                    if (-not $skipSection) { $output.Add($line) }
                    continue
                }
                $assignment = [regex]::Match($line, '^\s*(?<key>(?:"(?:\\.|[^"\\])*"|''[^'']*''|[A-Za-z0-9_.-]+|\s)+?)\s*=')
                if ($assignment.Success) {
                    $keyParts = @(Get-TomlPath $assignment.Groups['key'].Value.Trim())
                    if ($section.Count -eq 0) {
                        if ($keyParts.Count -eq 1) {
                            $key = $keyParts[0]
                            if ($key -ceq 'model_providers') {
                                throw 'model_providers 使用了内联表；请改为 [model_providers.<名称>] 格式后重试。原配置未修改。'
                            }
                            $skipAssignment = $settings.Keys -ccontains $key -or $removeKeys -ccontains $key
                        } elseif ($keyParts[0] -ceq 'model_providers' -and $keyParts[1] -ceq $providerId) {
                            $skipAssignment = $true
                        }
                    } elseif ($section.Count -eq 1 -and $section[0] -ceq 'model_providers' -and $keyParts[0] -ceq $providerId) {
                        $skipAssignment = $true
                    }
                }
            }
            Update-TomlState $line $state
            if (-not $skipSection -and -not $skipAssignment) { $output.Add($line) }
        }
        if ($state.Multiline -or $state.Depth -ne 0) { throw '原 TOML 配置存在未闭合字符串或数组。原配置未修改。' }
        $output.Add('')
        $output.Add('[model_providers.' + $providerId + ']')
        $output.Add('name = "本地模型"')
        $output.Add('base_url = ' + (ConvertTo-TomlString $Endpoint))
        $output.Add('wire_api = "responses"')
        $output.Add('experimental_bearer_token = ' + (ConvertTo-TomlString $ApiKey))
        $output.Add('requires_openai_auth = false')
        $output.Add('supports_websockets = false')
        return ($output -join "`n").TrimEnd() + "`n"
    }

    function New-CatalogText {
        $instructions = '你是 Codex 编程助手。遵守用户和工作目录中的指令，先检查现有代码，再完成用户要求的修改。使用可用工具处理文件和命令；尽量保留无关配置和用户已有修改。根据证据说明结果，不声称执行过尚未执行的操作。默认使用中文回复。'
        $entries = @()
        for ($i = 0; $i -lt $modelSlugs.Count; $i++) {
            $entries += [ordered]@{
                slug = $modelSlugs[$i]
                display_name = $modelSlugs[$i].Substring(5)
                description = '通过 localhost:20128 的 Responses API 使用本地网关模型'
                visibility = 'list'
                supported_in_api = $true
                priority = $i + 1
                # 与 config.toml 保持一致，使 Codex 可使用 xhigh 档位。
                default_reasoning_level = $reasoningEffort
                supported_reasoning_levels = @(
                    @{ effort = $reasoningEffort; description = '超高思考等级' }
                )
                supports_reasoning_summaries = $false
                default_reasoning_summary = 'none'
                support_verbosity = $false
                default_verbosity = $null
                shell_type = 'shell_command'
                apply_patch_tool_type = 'freeform'
                web_search_tool_type = 'text'
                supports_search_tool = $false
                prefer_websockets = $false
                use_responses_lite = $false
                supports_parallel_tool_calls = $false
                experimental_supported_tools = @()
                default_service_tier = $null
                input_modalities = @('text', 'image')
                supports_image_detail_original = $false
                # 两个模型的 /v1/models 均声明 context_length = 1000000。
                context_window = 1000000
                max_context_window = 1000000
                effective_context_window_percent = 95
                truncation_policy = @{ mode = 'tokens'; limit = 10000 }
                availability_nux = $null
                upgrade = $null
                base_instructions = $instructions
                model_messages = @{ instructions_template = $instructions }
            }
        }
        return (ConvertTo-Json -InputObject @{ models = $entries } -Depth 10) + "`n"
    }

    function Confirm-LocalEndpoint {
        param([string]$Endpoint, [string]$Slug)
        $headers = @{ Authorization = 'Bearer ' + $ApiKey }
        Write-Host '检查模型列表和 Responses 流式接口……'
        try {
            $models = Invoke-RestMethod -Uri ($Endpoint + '/models') -Headers $headers -TimeoutSec 15
            $ids = @($models.data | ForEach-Object { $_.id })
            foreach ($requiredSlug in $modelSlugs) {
                if ($ids -cnotcontains $requiredSlug) { throw ('模型列表中没有 ' + $requiredSlug) }
            }
            $body = @{ model = $Slug; input = '仅回复 OK，不要解释。'; reasoning = @{ effort = $reasoningEffort }; stream = $true; store = $false; max_output_tokens = 256 } | ConvertTo-Json -Depth 5 -Compress
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($Endpoint + '/responses') -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30
            $content = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
            $completed = $false
            foreach ($line in ($content -split '\r?\n')) {
                if (-not $line.StartsWith('data:')) { continue }
                $data = $line.Substring(5).Trim()
                if (-not $data -or $data -eq '[DONE]') { continue }
                $event = ConvertFrom-Json -InputObject $data
                if ($event.type -eq 'response.completed') { $completed = $true }
                if ($event.type -in @('response.failed', 'error')) { throw 'Responses 接口返回了失败事件。' }
            }
            if (-not $completed) { throw '未收到 response.completed 流式事件。' }
            Write-Status ('模型列表和 ' + $Slug + ' 的 Responses 流式接口可用')
        } catch {
            $message = $_.Exception.Message.Replace($ApiKey, '[已隐藏密钥]')
            throw ('连接检查失败：' + $message + "`n原配置未修改。确认本地服务已启动并支持 /v1/responses；仅准备配置时可使用 -SkipConnectionCheck。")
        }
    }

    function New-Snapshot {
        param([string]$Directory)
        if (Test-Path -LiteralPath $Directory) { throw ('备份目录已经存在：' + $Directory) }
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $manifest = [ordered]@{ version = 1; files = [ordered]@{} }
        foreach ($name in $managedFiles) {
            $path = Join-Path $configDirectory $name
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            $manifest.files[$name] = $exists
            if ($exists) { Copy-Item -LiteralPath $path -Destination (Join-Path $Directory $name) }
        }
        [IO.File]::WriteAllText((Join-Path $Directory 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)
    }

    function Set-AtomicFile {
        param([string]$Path, [string]$Content)
        $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllText($temporary, $Content, $utf8NoBom)
            if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $Path) }
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }

    function Restore-Snapshot {
        param([string]$Directory)
        $manifest = Get-Content -LiteralPath (Join-Path $Directory 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.version -ne 1) { throw '不支持此备份格式。' }
        # 先完整检查备份，再修改文件；不使用 manifest 提供的任意文件路径。
        foreach ($name in $managedFiles) {
            $property = $manifest.files.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -isnot [bool]) { throw '备份清单无效。' }
            if ($property.Value -and -not (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf)) { throw ('备份文件缺失：' + $name) }
        }
        foreach ($name in $managedFiles) {
            $path = Join-Path $configDirectory $name
            if ($manifest.files.PSObject.Properties[$name].Value) {
                # 复制原始字节，恢复时保留原配置的编码及换行。
                $temporary = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
                try {
                    Copy-Item -LiteralPath (Join-Path $Directory $name) -Destination $temporary
                    if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
                    else { [IO.File]::Move($temporary, $path) }
                } finally {
                    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
                }
            } elseif ([IO.File]::Exists($path)) {
                [IO.File]::Delete($path)
            }
        }
    }

    if ($selectedAction -eq 'Menu') {
        Write-Host ''
        Write-Host '1. 使用 glm-5.3-flashx（默认）'
        Write-Host '2. 使用 deepseek-v4.1-flash'
        Write-Host '9. 恢复首次安装前的配置'
        Write-Host '0. 退出'
        $choice = (Read-Host '请选择，直接回车使用 GLM').Trim()
        switch ($choice) {
            { $_ -in @('', '1') } { $selectedModel = 'glm-5.3-flashx'; $selectedAction = 'Install' }
            '2' { $selectedModel = 'deepseek-v4.1-flash'; $selectedAction = 'Install' }
            '9' { $selectedAction = 'Restore' }
            '0' { return }
            default { throw '无效的菜单选项。' }
        }
    }

    if ($selectedAction -eq 'Restore' -and -not (Test-Path -LiteralPath (Join-Path $initialBackup 'manifest.json') -PathType Leaf)) {
        throw '没有找到首次安装前的备份，无法恢复。'
    }

    $newConfig = ''
    $newCatalog = ''
    if ($selectedAction -eq 'Install') {
        if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'ApiKey 不能为空。' }
        $endpoint = $BaseUrl.Trim().TrimEnd('/')
        $endpointUri = $null
        if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$endpointUri) -or
            $endpointUri.Scheme -notin @('http', 'https') -or -not $endpointUri.IsLoopback -or
            $endpointUri.AbsolutePath -cne '/v1' -or $endpointUri.Query -or $endpointUri.Fragment -or $endpointUri.UserInfo) {
            throw 'BaseUrl 必须是本机地址，且以 /v1 结尾，例如 http://localhost:20128/v1。'
        }
        $slug = 'cbcn/' + $selectedModel
        if (-not $SkipConnectionCheck) { Confirm-LocalEndpoint $endpoint $slug }
        $original = if (Test-Path -LiteralPath $configPath -PathType Leaf) { [IO.File]::ReadAllText($configPath) } else { '' }
        $newConfig = New-ConfigText $original $slug $endpoint
        $newCatalog = New-CatalogText
        $catalog = ConvertFrom-Json -InputObject $newCatalog
        if (@($catalog.models).Count -ne 2) { throw '生成的模型目录无效。' }
    }

    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $snapshotName = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $snapshotPath = Join-Path $backupDirectory $snapshotName
    New-Snapshot $snapshotPath
    if ($selectedAction -eq 'Install' -and -not (Test-Path -LiteralPath $initialBackup)) { New-Snapshot $initialBackup }
    try {
        if ($selectedAction -eq 'Restore') {
            Restore-Snapshot $initialBackup
            Write-Status '已恢复首次安装前的配置'
        } else {
            Set-AtomicFile $catalogPath $newCatalog
            Set-AtomicFile $configPath $newConfig
            Write-Status ('已登记两个模型，默认使用 ' + $selectedModel)
            Write-Status ('模型思考等级：' + $reasoningEffort)
            Write-Status ('配置文件：' + $configPath)
            Write-Status ('模型目录：' + $catalogPath)
        }
    } catch {
        $failure = $_
        try { Restore-Snapshot $snapshotPath }
        catch {
            $rollbackMessage = $_.Exception.Message
            $failureMessage = $failure.Exception.Message
            if ($ApiKey) {
                $rollbackMessage = $rollbackMessage.Replace($ApiKey, '[已隐藏密钥]')
                $failureMessage = $failureMessage.Replace($ApiKey, '[已隐藏密钥]')
            }
            throw ("修改失败：$failureMessage`n自动回滚失败：$rollbackMessage`n请从此备份手动恢复：$snapshotPath")
        }
        throw ('修改失败，已回滚到本次操作前：' + $failure.Exception.Message.Replace($ApiKey, '[已隐藏密钥]'))
    }
    Write-Status ('本次操作前的备份：' + $snapshotPath)
    Write-Host '请完全退出并重新打开 Codex 桌面端 / IDE 插件，CLI 请重新启动。'
    Write-Host '新建对话使用默认模型；已有对话可能保留原模型。'
    if ($selectedAction -eq 'Install') {
        Write-Host 'CLI 临时切换：codex -m cbcn/deepseek-v4.1-flash'
        if ($SkipConnectionCheck) { Write-Warning '已跳过连接检查；实际使用时需要启动本地服务。' }
    }
}
