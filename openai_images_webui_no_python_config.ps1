param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptDir "config.ini"
}

function Read-ConfigFile([string]$path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $path)) {
        return $map
    }

    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        $text = ($line + "").Trim()
        if ($text.Length -eq 0) { continue }
        if ($text.StartsWith("#") -or $text.StartsWith(";")) { continue }

        $idx = $text.IndexOf("=")
        if ($idx -le 0) { continue }

        $key = $text.Substring(0, $idx).Trim()
        $value = $text.Substring($idx + 1).Trim()

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        if ($key.Length -gt 0) {
            $map[$key] = $value
        }
    }

    return $map
}

$Config = Read-ConfigFile $ConfigPath

function ConfigValue([string]$key, [string]$default) {
    if ($Config.ContainsKey($key)) {
        $value = [string]$Config[$key]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    $envValue = [Environment]::GetEnvironmentVariable($key)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue
    }

    return $default
}

function ConfigInt([string]$key, [int]$default, [int]$min, [int]$max) {
    $raw = ConfigValue $key ([string]$default)
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed)) {
        return $default
    }
    if ($parsed -lt $min) { return $min }
    if ($parsed -gt $max) { return $max }
    return $parsed
}

function ConfigBool([string]$key, [bool]$default) {
    $raw = (ConfigValue $key ($(if ($default) { "1" } else { "0" })) + "").Trim().ToLowerInvariant()
    return ($raw -in @("1", "true", "yes", "on", "y"))
}

function Resolve-AppPath([string]$value, [string]$fallback) {
    $raw = ($value + "").Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = $fallback
    }
    if ([System.IO.Path]::IsPathRooted($raw)) {
        return [System.IO.Path]::GetFullPath($raw)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $ScriptDir $raw))
}

function Normalize-BaseUrl([string]$url) {
    $value = ($url + "").Trim()
    while ($value.EndsWith("/")) {
        $value = $value.Substring(0, $value.Length - 1)
    }
    if ($value.ToLowerInvariant().EndsWith("/v1")) {
        $value = $value.Substring(0, $value.Length - 3)
    }
    return $value
}

function Apply-RuntimeConfigFromFile {
    $script:Config = Read-ConfigFile $ConfigPath
    $script:BaseUrlRaw = ConfigValue "OPENAI_BASE_URL" "https://api.henng.cn/"
    $script:BaseUrl = Normalize-BaseUrl $script:BaseUrlRaw
    $script:ApiKey = ConfigValue "OPENAI_API_KEY" ""
    $script:DefaultModel = ConfigValue "OPENAI_IMAGE_MODEL" "gpt-image-2"
    $script:HostName = ConfigValue "IMAGE_WEBUI_HOST" "127.0.0.1"
    $script:Port = ConfigInt "IMAGE_WEBUI_PORT" 7861 1 65535
    $script:TimeoutSec = ConfigInt "IMAGE_WEBUI_TIMEOUT" 240 10 1800
    $script:NoBrowser = ConfigBool "IMAGE_WEBUI_NO_BROWSER" $false
    $script:SaveOutputs = ConfigBool "IMAGE_WEBUI_SAVE_OUTPUTS" $true
    $script:MockMode = ConfigBool "IMAGE_WEBUI_MOCK" $false
    $script:ForceResponseFormat = ConfigBool "IMAGE_WEBUI_FORCE_RESPONSE_FORMAT" $false
    $script:IncludeStreamFlag = ConfigBool "IMAGE_WEBUI_INCLUDE_STREAM_FLAG" $false
    $script:OutputDir = Resolve-AppPath (ConfigValue "IMAGE_WEBUI_OUTPUT_DIR" "outputs") "outputs"
    $script:LogDir = Resolve-AppPath (ConfigValue "IMAGE_WEBUI_LOG_DIR" "logs") "logs"
    $script:MaxUploadMB = ConfigInt "IMAGE_WEBUI_MAX_UPLOAD_MB" 50 1 200
    $script:MaxBodyMB = ConfigInt "IMAGE_WEBUI_MAX_BODY_MB" 80 1 500
    $script:MaxUploadBytes = [int64]$script:MaxUploadMB * 1MB
    $script:MaxBodyBytes = [int64]$script:MaxBodyMB * 1MB
    $script:HistoryFile = Join-Path $script:OutputDir "history.jsonl"
    $script:LogFile = Join-Path $script:LogDir ("webui-" + (Get-Date -Format "yyyyMMdd") + ".log")
    Ensure-Directory $script:LogDir
    if ($script:SaveOutputs) { Ensure-Directory $script:OutputDir }
}

function Save-ConfigValues($values) {
    $dir = Split-Path -Parent $ConfigPath
    if (-not [string]::IsNullOrWhiteSpace($dir)) { Ensure-Directory $dir }

    $lines = @()
    if (Test-Path -LiteralPath $ConfigPath) {
        $lines = @(Get-Content -LiteralPath $ConfigPath -Encoding UTF8)
    }

    $seen = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        $trim = $line.Trim()
        if ($trim.StartsWith("#") -or $trim.StartsWith(";") -or -not $trim.Contains("=")) { continue }
        $idx = $trim.IndexOf("=")
        if ($idx -le 0) { continue }
        $key = $trim.Substring(0, $idx).Trim()
        if ($values.Contains($key)) {
            $lines[$i] = "$key=$($values[$key])"
            $seen[$key] = $true
        }
    }

    foreach ($key in $values.Keys) {
        if (-not $seen.ContainsKey($key)) {
            $lines += "$key=$($values[$key])"
        }
    }

    Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8
    Apply-RuntimeConfigFromFile
    if (-not [string]::IsNullOrWhiteSpace($script:IndexHtmlTemplate)) {
        $script:IndexHtml = $script:IndexHtmlTemplate.
            Replace("%%BASE_URL%%", (HtmlAttr $script:BaseUrl)).
            Replace("%%MODEL%%", (HtmlAttr $script:DefaultModel))
    }
}

function Mask-Secret([string]$value) {
    $text = ($value + "").Trim()
    if ($text.Length -eq 0) { return "" }
    if ($text.Length -le 8) { return "****" }
    return $text.Substring(0, 4) + "..." + $text.Substring($text.Length - 4)
}

function HtmlAttr([string]$value) {
    if ($null -eq $value) { return "" }
    return $value.Replace("&", "&amp;").Replace('"', "&quot;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function To-JsonText($obj, [int]$depth = 30) {
    return ($obj | ConvertTo-Json -Depth $depth -Compress)
}

function Get-PayloadKeys($obj) {
    if ($null -eq $obj) { return "" }
    if ($obj -is [System.Collections.IDictionary]) {
        return (($obj.Keys | Sort-Object) -join ",")
    }
    return (($obj.PSObject.Properties.Name | Sort-Object) -join ",")
}

function Parse-JsonBody([string]$body) {
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw (New-HttpException 400 "请求体为空。")
    }
    try {
        return $body | ConvertFrom-Json
    } catch {
        throw (New-HttpException 400 "JSON 格式不正确：$($_.Exception.Message)")
    }
}

function Get-Prop($obj, [string]$name, $default = $null) {
    if ($null -eq $obj) { return $default }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) {
            if ($null -eq $obj[$name]) { return $default }
            return $obj[$name]
        }
        return $default
    }
    $prop = $obj.PSObject.Properties[$name]
    if ($null -eq $prop) { return $default }
    if ($null -eq $prop.Value) { return $default }
    return $prop.Value
}

function Required-String($obj, [string]$name, [string]$label) {
    $value = ([string](Get-Prop $obj $name "")).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw (New-HttpException 400 "$label 不能为空。")
    }
    return $value
}

function Get-RequestInt($obj, [string]$name, [int]$default, [int]$min, [int]$max, [string]$label) {
    $raw = Get-Prop $obj $name $null
    if ($null -eq $raw -or [string]::IsNullOrWhiteSpace([string]$raw)) {
        return $default
    }
    $parsed = 0
    if (-not [int]::TryParse([string]$raw, [ref]$parsed)) {
        throw (New-HttpException 400 "$label 必须是数字。")
    }
    if ($parsed -lt $min -or $parsed -gt $max) {
        throw (New-HttpException 400 "$label 必须在 $min 到 $max 之间。")
    }
    return $parsed
}

function New-CompactHashtable($pairs) {
    $hash = @{}
    foreach ($key in $pairs.Keys) {
        $value = $pairs[$key]
        if ($null -eq $value) { continue }
        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { continue }
        $hash[$key] = $value
    }
    return $hash
}

function Add-OptionalImageFields($apiPayload, $payload) {
    if ($ForceResponseFormat) {
        $apiPayload["response_format"] = (Get-Prop $payload "response_format" "b64_json")
    }
    if ($IncludeStreamFlag) {
        $apiPayload["stream"] = $false
    }
}

function New-HttpException([int]$status, [string]$message) {
    $exception = New-Object System.Exception($message)
    $exception.Data["Status"] = $status
    return $exception
}

function Get-HttpExceptionStatus($exception) {
    try {
        $value = $exception.Data["Status"]
        if ($null -ne $value) { return [int]$value }
    } catch {}
    return 500
}

function Image-MimeType([string]$format) {
    $value = ($format + "").Trim().ToLowerInvariant()
    if ($value.StartsWith("image/")) { return $value }
    if ($value -eq "jpg" -or $value -eq "jpeg") { return "image/jpeg" }
    if ($value -eq "webp") { return "image/webp" }
    if ($value -eq "svg" -or $value -eq "svg+xml") { return "image/svg+xml" }
    return "image/png"
}

function Image-Ext([string]$mime) {
    $value = ($mime + "").Trim().ToLowerInvariant()
    if ($value -eq "image/jpeg") { return "jpg" }
    if ($value -eq "image/webp") { return "webp" }
    if ($value -eq "image/svg+xml") { return "svg" }
    return "png"
}

function Guess-MimeFromFile([string]$path) {
    $ext = ([System.IO.Path]::GetExtension($path) + "").ToLowerInvariant()
    if ($ext -eq ".jpg" -or $ext -eq ".jpeg") { return "image/jpeg" }
    if ($ext -eq ".webp") { return "image/webp" }
    if ($ext -eq ".svg") { return "image/svg+xml" }
    if ($ext -eq ".json") { return "application/json; charset=utf-8" }
    return "image/png"
}

function Get-DataUrlBytes([string]$image) {
    $text = ($image + "").Trim()
    if ($text.StartsWith("data:")) {
        $comma = $text.IndexOf(",")
        if ($comma -gt 0) {
            $text = $text.Substring($comma + 1)
        }
    }
    $text = ($text -replace "\s", "")
    return [System.Convert]::FromBase64String($text)
}

function Assert-DataImageWithinLimit([string]$image, [string]$label) {
    $text = ($image + "").Trim()
    if ($text.StartsWith("http://") -or $text.StartsWith("https://")) {
        return
    }
    if (-not $text.StartsWith("data:image/")) {
        throw (New-HttpException 400 "$label 必须是图片 data URL 或 http(s) 图片地址。")
    }
    try {
        $bytes = Get-DataUrlBytes $text
        if ($bytes.Length -gt $MaxUploadBytes) {
            $mb = [Math]::Round($bytes.Length / 1MB, 2)
            throw (New-HttpException 413 "$label 大小为 $mb MB，超过配置限制 $MaxUploadMB MB。")
        }
    } catch {
        if ($_.Exception.Data["Status"]) { throw }
        throw (New-HttpException 400 "$label 不是有效的 base64 图片。")
    }
}

function Ensure-Directory([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        [void](New-Item -ItemType Directory -Path $path -Force)
    }
}

function New-OutputFileName([string]$prefix, [int]$index, [string]$mime) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $id = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $ext = Image-Ext $mime
    return "$stamp-$prefix-$index-$id.$ext"
}

function Save-ImageFromBase64([string]$base64, [string]$mime, [string]$prefix, [int]$index) {
    if (-not $SaveOutputs) { return $null }
    Ensure-Directory $OutputDir
    $fileName = New-OutputFileName $prefix $index $mime
    $path = Join-Path $OutputDir $fileName
    $bytes = Get-DataUrlBytes $base64
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return [ordered]@{
        filename = $fileName
        path = $path
        local_url = "/outputs/$fileName"
        bytes = $bytes.Length
    }
}

function Write-AppLog([string]$level, [string]$message) {
    try {
        Ensure-Directory $LogDir
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level.ToUpperInvariant(), $message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {}
}

function Redact-Raw($parsed) {
    try {
        $copy = $parsed | ConvertTo-Json -Depth 80 | ConvertFrom-Json
        $data = Get-Prop $copy "data" $null
        if ($null -ne $data) {
            foreach ($item in $data) {
                if ($null -ne $item.PSObject.Properties["b64_json"]) {
                    $item.b64_json = "<base64 omitted>"
                }
            }
        }
        return $copy
    } catch {
        return "<raw response omitted>"
    }
}

function Normalize-Images($parsed, $apiPayload, [string]$prefix) {
    $images = New-Object System.Collections.ArrayList
    $data = Get-Prop $parsed "data" $null
    if ($null -eq $data) { return @() }

    $preferredFormat = [string](Get-Prop $apiPayload "output_format" "png")
    $index = 1
    foreach ($item in $data) {
        $b64 = ([string](Get-Prop $item "b64_json" "")).Trim()
        $url = ([string](Get-Prop $item "url" "")).Trim()
        $fmt = [string](Get-Prop $item "output_format" $preferredFormat)
        $mime = Image-MimeType $fmt
        $src = ""
        $saved = $null

        if ($b64.Length -gt 0) {
            $src = "data:{0};base64,{1}" -f $mime, $b64
            try {
                $saved = Save-ImageFromBase64 $b64 $mime $prefix $index
            } catch {
                Write-AppLog "warn" "保存图片失败：$($_.Exception.Message)"
            }
        } elseif ($url.Length -gt 0) {
            $src = $url
        }

        if ($src.Length -gt 0) {
            $filename = "image-$index.$(Image-Ext $mime)"
            if ($null -ne $saved) { $filename = $saved.filename }
            [void]$images.Add([ordered]@{
                src = $src
                filename = $filename
                mime_type = $mime
                is_data_url = $src.StartsWith("data:")
                saved = ($null -ne $saved)
                local_url = $(if ($null -ne $saved) { $saved.local_url } else { "" })
                bytes = $(if ($null -ne $saved) { $saved.bytes } else { 0 })
            })
        }
        $index++
    }
    return @($images.ToArray())
}

function Compact-HistoryImages($images) {
    $result = New-Object System.Collections.ArrayList
    foreach ($image in $images) {
        [void]$result.Add([ordered]@{
            filename = [string](Get-Prop $image "filename" "")
            local_url = [string](Get-Prop $image "local_url" "")
            src = $(if (-not [string]::IsNullOrWhiteSpace([string](Get-Prop $image "local_url" ""))) { [string](Get-Prop $image "local_url" "") } elseif (-not [string]::IsNullOrWhiteSpace([string](Get-Prop $image "src" "")) -and -not ([string](Get-Prop $image "src" "")).StartsWith("data:")) { [string](Get-Prop $image "src" "") } else { "" })
            mime_type = [string](Get-Prop $image "mime_type" "")
            bytes = [int](Get-Prop $image "bytes" 0)
        })
    }
    return @($result.ToArray())
}

function Append-HistoryRecord([string]$action, [string]$status, $payload, $result) {
    try {
        Ensure-Directory $OutputDir
        $images = @()
        $errorMessage = ""
        $elapsedMs = 0
        if ($null -ne $result) {
            $images = Compact-HistoryImages (Get-Prop $result "images" @())
            $err = Get-Prop $result "error" $null
            if ($null -ne $err) { $errorMessage = [string](Get-Prop $err "message" "") }
            $elapsedMs = [int](Get-Prop $result "elapsed_ms" 0)
        }
        $record = [ordered]@{
            id = [Guid]::NewGuid().ToString("N")
            time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            action = $action
            status = $status
            prompt = [string](Get-Prop $payload "prompt" "")
            model = [string](Get-Prop $payload "model" $DefaultModel)
            size = [string](Get-Prop $payload "size" "")
            quality = [string](Get-Prop $payload "quality" "")
            output_format = [string](Get-Prop $payload "output_format" "")
            image_count = @($images).Count
            images = @($images)
            error = $errorMessage
            elapsed_ms = $elapsedMs
        }
        Add-Content -LiteralPath $HistoryFile -Value (To-JsonText $record 20) -Encoding UTF8
    } catch {
        Write-AppLog "warn" "写入历史失败：$($_.Exception.Message)"
    }
}

function Get-HistoryRecords([int]$limit) {
    if (-not (Test-Path -LiteralPath $HistoryFile)) {
        return @()
    }
    $lines = Get-Content -LiteralPath $HistoryFile -Encoding UTF8
    if ($lines.Count -gt $limit) {
        $lines = $lines[($lines.Count - $limit)..($lines.Count - 1)]
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            [void]$items.Add(($line | ConvertFrom-Json))
        } catch {}
    }
    $array = @($items.ToArray())
    [array]::Reverse($array)
    return @($array)
}

function Remove-HistoryRecord([string]$id) {
    $target = ($id + "").Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        throw (New-HttpException 400 "历史记录 id 不能为空。")
    }
    if (-not (Test-Path -LiteralPath $HistoryFile)) {
        return [ordered]@{ ok = $true; removed = $false; remaining = 0 }
    }

    $remaining = New-Object System.Collections.ArrayList
    $removed = $false
    foreach ($line in (Get-Content -LiteralPath $HistoryFile -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $item = $line | ConvertFrom-Json
            if ([string](Get-Prop $item "id" "") -eq $target) {
                $removed = $true
                continue
            }
        } catch {}
        [void]$remaining.Add($line)
    }

    Ensure-Directory $OutputDir
    Set-Content -LiteralPath $HistoryFile -Value @($remaining.ToArray()) -Encoding UTF8
    return [ordered]@{ ok = $true; removed = $removed; remaining = $remaining.Count }
}

function Clear-HistoryRecords {
    Ensure-Directory $OutputDir
    Set-Content -LiteralPath $HistoryFile -Value @() -Encoding UTF8
    return [ordered]@{ ok = $true; remaining = 0 }
}

function Get-RecentLogLines([int]$limit) {
    if (-not (Test-Path -LiteralPath $LogFile)) { return @() }
    $lines = @(Get-Content -LiteralPath $LogFile -Encoding UTF8 -Tail $limit)
    return @($lines)
}

function Handle-ConfigSave($payload) {
    $base = Normalize-BaseUrl ([string](Get-Prop $payload "base_url" $BaseUrl))
    $key = ([string](Get-Prop $payload "api_key" $ApiKey)).Trim()
    if ([string]::IsNullOrWhiteSpace($key) -and -not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $key = $ApiKey
    }
    $model = ([string](Get-Prop $payload "model" $DefaultModel)).Trim()
    $timeout = Get-RequestInt $payload "timeout_sec" $TimeoutSec 10 1800 "超时"
    $mock = Get-Prop $payload "mock" $MockMode

    if ([string]::IsNullOrWhiteSpace($base)) {
        throw (New-HttpException 400 "Base URL 不能为空。")
    }
    if (-not ($base.StartsWith("http://") -or $base.StartsWith("https://"))) {
        throw (New-HttpException 400 "Base URL 必须以 http:// 或 https:// 开头。")
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw (New-HttpException 400 "模型不能为空。")
    }

    $mockText = if (($mock -eq $true) -or ([string]$mock).Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")) { "1" } else { "0" }
    $values = [ordered]@{
        OPENAI_BASE_URL = $base
        OPENAI_API_KEY = $key
        OPENAI_IMAGE_MODEL = $model
        IMAGE_WEBUI_TIMEOUT = [string]$timeout
        IMAGE_WEBUI_MOCK = $mockText
    }
    Save-ConfigValues $values
    Write-AppLog "info" "config saved base=$BaseUrl model=$DefaultModel timeout=$TimeoutSec mock=$MockMode key_present=$(-not [string]::IsNullOrWhiteSpace($ApiKey))"
    return [ordered]@{ ok = $true; message = "配置已保存。"; config = (Get-ConfigSnapshot) }
}

function Handle-Diagnostics($payload) {
    $base = Normalize-BaseUrl ([string](Get-Prop $payload "base_url" $BaseUrl))
    $key = ([string](Get-Prop $payload "api_key" $ApiKey)).Trim()
    if ([string]::IsNullOrWhiteSpace($key) -and -not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $key = $ApiKey
    }
    $model = ([string](Get-Prop $payload "model" $DefaultModel)).Trim()
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $DefaultModel }

    $checks = New-Object System.Collections.ArrayList
    [void]$checks.Add([ordered]@{ name = "Base URL"; ok = (-not [string]::IsNullOrWhiteSpace($base)); value = $base })
    [void]$checks.Add([ordered]@{ name = "API Key"; ok = ((-not [string]::IsNullOrWhiteSpace($key)) -or $MockMode); value = $(if (-not [string]::IsNullOrWhiteSpace($key)) { Mask-Secret $key } elseif ($MockMode) { "Mock 模式" } else { "未配置" }) })
    [void]$checks.Add([ordered]@{ name = "模型"; ok = (-not [string]::IsNullOrWhiteSpace($model)); value = $model })
    [void]$checks.Add([ordered]@{ name = "服务端超时"; ok = ($TimeoutSec -ge 120); value = "$TimeoutSec 秒" })
    [void]$checks.Add([ordered]@{ name = "输出目录"; ok = (Test-Path -LiteralPath $OutputDir); value = $OutputDir })
    [void]$checks.Add([ordered]@{ name = "/v1/models"; ok = $true; value = "未执行网络连接测试；需要时点击测试连接。" })

    return [ordered]@{
        ok = $true
        generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        config = [ordered]@{
            base_url = $BaseUrl
            model = $DefaultModel
            timeout_sec = $TimeoutSec
            mock = $MockMode
            has_api_key = (-not [string]::IsNullOrWhiteSpace($ApiKey))
            output_dir = $OutputDir
            log_dir = $LogDir
        }
        effective_request = [ordered]@{
            base_url = $base
            api_key = (Mask-Secret $key)
            model = $model
        }
        checks = @($checks.ToArray())
        recent_logs = @()
    }
}

function Get-ConfigWarnings {
    $warnings = New-Object System.Collections.ArrayList
    if (($BaseUrlRaw + "").Trim().ToLowerInvariant().EndsWith("/v1")) {
        [void]$warnings.Add("OPENAI_BASE_URL 已自动去掉末尾 /v1。配置里建议填写根地址。")
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey) -and -not $MockMode) {
        [void]$warnings.Add("OPENAI_API_KEY 为空。真实请求会失败；可先设置 IMAGE_WEBUI_MOCK=1 测试界面。")
    }
    if ($SaveOutputs -and -not (Test-Path -LiteralPath $OutputDir)) {
        [void]$warnings.Add("输出目录将在首次保存时自动创建。")
    }
    if ($ForceResponseFormat -or $IncludeStreamFlag) {
        [void]$warnings.Add("已启用图片接口兼容字段开关；如果生成卡住，建议先关闭 IMAGE_WEBUI_FORCE_RESPONSE_FORMAT 和 IMAGE_WEBUI_INCLUDE_STREAM_FLAG。")
    }
    return @($warnings.ToArray())
}

function Get-ConfigSnapshot {
    return [ordered]@{
        app = "GPT Image Web UI"
        base_url = $BaseUrl
        base_url_raw = $BaseUrlRaw
        model = $DefaultModel
        host = $HostName
        port = $Port
        timeout_sec = $TimeoutSec
        no_browser = $NoBrowser
        has_api_key = (-not [string]::IsNullOrWhiteSpace($ApiKey))
        api_key_masked = (Mask-Secret $ApiKey)
        output_dir = $OutputDir
        save_outputs = $SaveOutputs
        log_dir = $LogDir
        max_upload_mb = $MaxUploadMB
        max_body_mb = $MaxBodyMB
        mock = $MockMode
        force_response_format = $ForceResponseFormat
        include_stream_flag = $IncludeStreamFlag
        warnings = @(Get-ConfigWarnings)
    }
}

function New-MockResult($uiPayload, [string]$endpoint, $apiPayload, [datetime]$started, [string]$requestId) {
    $count = 1
    if ($endpoint -eq "/v1/images/generations") {
        $count = [int](Get-Prop $apiPayload "n" 1)
    }
    if ($count -lt 1) { $count = 1 }
    if ($count -gt 10) { $count = 10 }

    $images = New-Object System.Collections.ArrayList
    $prompt = [string](Get-Prop $apiPayload "prompt" "Mock image")
    $size = [string](Get-Prop $apiPayload "size" "1024x1024")
    for ($index = 1; $index -le $count; $index++) {
        $safePrompt = HtmlAttr $prompt
        $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <radialGradient id="glow" cx="30%" cy="20%" r="80%">
      <stop offset="0%" stop-color="#f7f7f7"/>
      <stop offset="42%" stop-color="#565656"/>
      <stop offset="100%" stop-color="#020617"/>
    </radialGradient>
    <linearGradient id="card" x1="0" x2="1" y1="0" y2="1">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.32"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0.06"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  <circle cx="790" cy="190" r="230" fill="#cfcfcf" opacity="0.18"/>
  <circle cx="180" cy="820" r="260" fill="#2a2a2a" opacity="0.32"/>
  <rect x="96" y="130" width="832" height="764" rx="58" fill="url(#card)" stroke="#ffffff" stroke-opacity="0.35"/>
  <text x="128" y="230" fill="#fff7ed" font-family="Georgia, serif" font-size="58" font-weight="700">Mock Image $index</text>
  <text x="128" y="300" fill="#fde68a" font-family="Segoe UI, sans-serif" font-size="28">No API credits used · $size</text>
  <foreignObject x="128" y="365" width="768" height="330">
    <div xmlns="http://www.w3.org/1999/xhtml" style="font: 34px/1.35 'Segoe UI', sans-serif; color:#fff; word-wrap:break-word;">$safePrompt</div>
  </foreignObject>
  <text x="128" y="820" fill="#dbeafe" font-family="Consolas, monospace" font-size="22">IMAGE_WEBUI_MOCK=1</text>
</svg>
"@
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($svg))
        $saved = $null
        try { $saved = Save-ImageFromBase64 $b64 "image/svg+xml" "mock" $index } catch {}
        [void]$images.Add([ordered]@{
            src = "data:image/svg+xml;base64,$b64"
            filename = $(if ($null -ne $saved) { $saved.filename } else { "mock-$index.svg" })
            mime_type = "image/svg+xml"
            is_data_url = $true
            saved = ($null -ne $saved)
            local_url = $(if ($null -ne $saved) { $saved.local_url } else { "" })
            bytes = $(if ($null -ne $saved) { $saved.bytes } else { 0 })
        })
    }

    $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
    return [ordered]@{
        endpoint = $endpoint
        upstream_url = (Normalize-BaseUrl ([string](Get-Prop $uiPayload "base_url" $BaseUrl))) + $endpoint
        request_id = $requestId
        mock = $true
        elapsed_ms = $elapsed
        request = $apiPayload
        raw = [ordered]@{ mock = $true; message = "IMAGE_WEBUI_MOCK=1，本次未请求上游。" }
        images = @($images.ToArray())
    }
}

function Invoke-JsonPost($url, $headers, [string]$body, [int]$timeoutSec) {
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = "POST"
    $request.ContentType = "application/json; charset=utf-8"
    $request.Accept = "application/json"
    $request.Timeout = $timeoutSec * 1000
    $request.ReadWriteTimeout = $timeoutSec * 1000
    $request.KeepAlive = $false
    $request.ProtocolVersion = [Version]"1.1"

    foreach ($key in $headers.Keys) {
        if ($key -eq "Accept") { continue }
        if ($key -eq "Content-Type") { continue }
        $request.Headers[$key] = [string]$headers[$key]
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $request.ContentLength = $bytes.Length

    $requestStream = $null
    try {
        $requestStream = $request.GetRequestStream()
        $requestStream.Write($bytes, 0, $bytes.Length)
    } finally {
        if ($null -ne $requestStream) { $requestStream.Close() }
    }

    $response = $null
    $reader = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        return [ordered]@{
            StatusCode = [int]$response.StatusCode
            Content = $reader.ReadToEnd()
            Headers = $response.Headers
        }
    } finally {
        if ($null -ne $reader) { $reader.Close() }
        if ($null -ne $response) { $response.Close() }
    }
}

function Invoke-Upstream($uiPayload, [string]$endpoint, $apiPayload, [string]$historyPrefix) {
    $started = Get-Date
    $requestId = [Guid]::NewGuid().ToString()
    $base = Normalize-BaseUrl ([string](Get-Prop $uiPayload "base_url" $BaseUrl))
    $key = ([string](Get-Prop $uiPayload "api_key" $ApiKey)).Trim()

    if ([string]::IsNullOrWhiteSpace($base)) {
        throw (New-HttpException 400 "Base URL 不能为空。")
    }

    if ($MockMode) {
        return New-MockResult $uiPayload $endpoint $apiPayload $started $requestId
    }

    if ([string]::IsNullOrWhiteSpace($key)) {
        throw (New-HttpException 400 "API Key 为空：请在 config.ini 填写 OPENAI_API_KEY，或在页面右上角临时输入。")
    }

    $upstreamUrl = $base + $endpoint
    $body = To-JsonText $apiPayload 80
    $headers = @{
        "Authorization" = "Bearer $key"
        "Accept" = "application/json"
        "X-Client-Request-Id" = $requestId
    }

    $logModel = [string](Get-Prop $apiPayload "model" "")
    $payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount($body)
    Write-AppLog "info" "POST $endpoint request_id=$requestId model=$logModel base=$base timeout=$TimeoutSec payload_bytes=$payloadBytes keys=$(Get-PayloadKeys $apiPayload)"

    try {
        $response = Invoke-JsonPost $upstreamUrl $headers $body $TimeoutSec
        $text = [string]$response.Content
        try {
            $parsed = $text | ConvertFrom-Json
        } catch {
            throw (New-HttpException 502 "上游返回的不是 JSON：$($text.Substring(0, [Math]::Min(300, $text.Length)))")
        }

        $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
        $upstreamRequestId = ""
        try { $upstreamRequestId = [string]$response.Headers["x-request-id"] } catch {}
        $images = Normalize-Images $parsed $apiPayload $historyPrefix
        Write-AppLog "info" "POST $endpoint completed request_id=$requestId status=$([int]$response.StatusCode) elapsed_ms=$elapsed images=$(@($images).Count)"

        return [ordered]@{
            endpoint = $endpoint
            upstream_url = $upstreamUrl
            request_id = $requestId
            upstream_request_id = $upstreamRequestId
            elapsed_ms = $elapsed
            request = $apiPayload
            raw = (Redact-Raw $parsed)
            images = @($images)
        }
    } catch {
        $status = 504
        $rawText = ""
        $message = $_.Exception.Message
        $upstreamRequestId = ""
        $hasWebResponse = $false
        $statusDescription = ""

        try {
            $webResponse = $_.Exception.Response
            if ($null -ne $webResponse) {
                $hasWebResponse = $true
                try { $status = [int]$webResponse.StatusCode } catch {}
                try { $statusDescription = [string]$webResponse.StatusDescription } catch {}
                try { $upstreamRequestId = [string]$webResponse.Headers["x-request-id"] } catch {}
                $stream = $webResponse.GetResponseStream()
                if ($null -ne $stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $rawText = $reader.ReadToEnd()
                    $reader.Close()
                }
            }
        } catch {}

        if ($rawText.Length -gt 0) {
            try {
                $errJson = $rawText | ConvertFrom-Json
                $errObj = Get-Prop $errJson "error" $null
                $errMessage = [string](Get-Prop $errObj "message" "")
                if ([string]::IsNullOrWhiteSpace($errMessage)) {
                    $errMessage = [string](Get-Prop $errJson "message" "")
                }
                if (-not [string]::IsNullOrWhiteSpace($errMessage)) {
                    $message = $errMessage
                } else {
                    $message = $rawText
                }
            } catch {
                $message = $rawText
            }
        } elseif ($hasWebResponse -and -not [string]::IsNullOrWhiteSpace($statusDescription)) {
            $message = $statusDescription
        }

        $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
        $elapsedSec = [Math]::Round(($elapsed / 1000), 1)
        if ($status -eq 504 -and $elapsed -lt (($TimeoutSec * 1000) - 1000)) {
            $errorMessage = "上游网关返回 504 Gateway Timeout（约 $elapsedSec 秒）。本地超时为 $TimeoutSec 秒，但中转网关可能有更短的等待上限：$message"
        } elseif ($elapsed -ge (($TimeoutSec * 1000) - 1000)) {
            $errorMessage = "上游 API 请求超过 $TimeoutSec 秒未返回：$message"
        } else {
            $errorMessage = "上游 API 请求失败（HTTP $status，约 $elapsedSec 秒）：$message"
        }
        Write-AppLog "error" "POST $endpoint failed request_id=$requestId status=$status message=$message"

        return [ordered]@{
            error = [ordered]@{
                message = $errorMessage
                status = $status
                upstream_url = $upstreamUrl
                request_id = $requestId
                upstream_request_id = $upstreamRequestId
            }
            elapsed_ms = $elapsed
            images = @()
        }
    }
}

function Handle-ApiGenerate($payload) {
    $prompt = Required-String $payload "prompt" "Prompt"
    $model = ([string](Get-Prop $payload "model" $DefaultModel)).Trim()
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $DefaultModel }

    $pairs = @{
        model = $model
        prompt = $prompt
        size = (Get-Prop $payload "size" $null)
        n = (Get-RequestInt $payload "n" 1 1 10 "N")
        quality = (Get-Prop $payload "quality" $null)
        background = (Get-Prop $payload "background" $null)
        output_format = (Get-Prop $payload "output_format" $null)
        output_compression = $(if (-not [string]::IsNullOrWhiteSpace([string](Get-Prop $payload "output_compression" ""))) { Get-RequestInt $payload "output_compression" 100 0 100 "Output Compression" } else { $null })
    }
    $apiPayload = New-CompactHashtable $pairs
    Add-OptionalImageFields $apiPayload $payload
    $result = Invoke-Upstream $payload "/v1/images/generations" $apiPayload "generate"
    Append-HistoryRecord "generate" $(if ($null -ne $result.error) { "error" } else { "success" }) $payload $result
    return $result
}

function Handle-ApiEdit($payload) {
    $prompt = Required-String $payload "prompt" "Prompt"
    $model = ([string](Get-Prop $payload "model" $DefaultModel)).Trim()
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $DefaultModel }

    $inputImages = New-Object System.Collections.ArrayList
    $imagesValue = Get-Prop $payload "images" $null
    if ($null -ne $imagesValue) {
        foreach ($image in $imagesValue) {
            $text = ([string]$image).Trim()
            if ($text.Length -gt 0) { [void]$inputImages.Add($text) }
        }
    }
    $legacyImage = ([string](Get-Prop $payload "image" "")).Trim()
    if ($legacyImage.Length -gt 0) {
        [void]$inputImages.Add($legacyImage)
    }
    if ($inputImages.Count -eq 0) {
        throw (New-HttpException 400 "图生图至少需要上传 1 张参考图。")
    }
    if ($inputImages.Count -gt 16) {
        throw (New-HttpException 400 "图生图最多支持 16 张参考图。")
    }

    $apiImages = New-Object System.Collections.ArrayList
    $imageIndex = 1
    foreach ($image in $inputImages) {
        Assert-DataImageWithinLimit $image "参考图 $imageIndex"
        [void]$apiImages.Add(@{ image_url = $image })
        $imageIndex++
    }

    $pairs = @{
        model = $model
        prompt = $prompt
        images = @($apiImages)
        size = (Get-Prop $payload "size" $null)
        n = $(if (-not [string]::IsNullOrWhiteSpace([string](Get-Prop $payload "n" ""))) { Get-RequestInt $payload "n" 1 1 10 "N" } else { $null })
        quality = (Get-Prop $payload "quality" $null)
        background = (Get-Prop $payload "background" $null)
        output_format = (Get-Prop $payload "output_format" $null)
        output_compression = $(if (-not [string]::IsNullOrWhiteSpace([string](Get-Prop $payload "output_compression" ""))) { Get-RequestInt $payload "output_compression" 100 0 100 "Output Compression" } else { $null })
    }
    $apiPayload = New-CompactHashtable $pairs
    Add-OptionalImageFields $apiPayload $payload

    $mask = ([string](Get-Prop $payload "mask" "")).Trim()
    if ($mask.Length -gt 0) {
        Assert-DataImageWithinLimit $mask "Mask"
        $apiPayload["mask"] = @{ image_url = $mask }
    }

    $result = Invoke-Upstream $payload "/v1/images/edits" $apiPayload "edit"
    Append-HistoryRecord "edit" $(if ($null -ne $result.error) { "error" } else { "success" }) $payload $result
    return $result
}

function Handle-ApiTest($payload) {
    $base = Normalize-BaseUrl ([string](Get-Prop $payload "base_url" $BaseUrl))
    $key = ([string](Get-Prop $payload "api_key" $ApiKey)).Trim()
    if ([string]::IsNullOrWhiteSpace($key) -and -not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $key = $ApiKey
    }
    if ($MockMode) {
        return [ordered]@{ ok = $true; mock = $true; message = "Mock 模式已开启，跳过上游连接测试。"; config = (Get-ConfigSnapshot) }
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw (New-HttpException 400 "API Key 为空，无法测试真实中转。")
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw (New-HttpException 400 "Base URL 为空。")
    }
    $url = $base + "/v1/models"
    $requestId = [Guid]::NewGuid().ToString()
    try {
        $response = Invoke-WebRequest -Uri $url -Method Get -Headers @{
            "Authorization" = "Bearer $key"
            "Accept" = "application/json"
            "X-Client-Request-Id" = $requestId
        } -TimeoutSec ([Math]::Min(30, $TimeoutSec)) -UseBasicParsing
        return [ordered]@{
            ok = $true
            status = [int]$response.StatusCode
            message = "连接测试成功。"
            request_id = $requestId
            url = $url
        }
    } catch {
        $message = $_.Exception.Message
        $status = 502
        try {
            if ($null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        } catch {}
        return [ordered]@{
            ok = $false
            status = $status
            message = "连接测试失败：$message。注意：部分中转可能不开放 /v1/models，但图片接口仍可能可用。"
            request_id = $requestId
            url = $url
        }
    }
}

$BaseUrlRaw = ConfigValue "OPENAI_BASE_URL" "https://api.henng.cn/"
$BaseUrl = Normalize-BaseUrl $BaseUrlRaw
$ApiKey = ConfigValue "OPENAI_API_KEY" ""
$DefaultModel = ConfigValue "OPENAI_IMAGE_MODEL" "gpt-image-2"
$HostName = ConfigValue "IMAGE_WEBUI_HOST" "127.0.0.1"
$Port = ConfigInt "IMAGE_WEBUI_PORT" 7861 1 65535
$TimeoutSec = ConfigInt "IMAGE_WEBUI_TIMEOUT" 240 10 1800
$NoBrowser = ConfigBool "IMAGE_WEBUI_NO_BROWSER" $false
$SaveOutputs = ConfigBool "IMAGE_WEBUI_SAVE_OUTPUTS" $true
$MockMode = ConfigBool "IMAGE_WEBUI_MOCK" $false
$ForceResponseFormat = ConfigBool "IMAGE_WEBUI_FORCE_RESPONSE_FORMAT" $false
$IncludeStreamFlag = ConfigBool "IMAGE_WEBUI_INCLUDE_STREAM_FLAG" $false
$OutputDir = Resolve-AppPath (ConfigValue "IMAGE_WEBUI_OUTPUT_DIR" "outputs") "outputs"
$LogDir = Resolve-AppPath (ConfigValue "IMAGE_WEBUI_LOG_DIR" "logs") "logs"
$MaxUploadMB = ConfigInt "IMAGE_WEBUI_MAX_UPLOAD_MB" 50 1 200
$MaxBodyMB = ConfigInt "IMAGE_WEBUI_MAX_BODY_MB" 80 1 500
$MaxUploadBytes = [int64]$MaxUploadMB * 1MB
$MaxBodyBytes = [int64]$MaxBodyMB * 1MB
$HistoryFile = Join-Path $OutputDir "history.jsonl"
$LogFile = Join-Path $LogDir ("webui-" + (Get-Date -Format "yyyyMMdd") + ".log")

Ensure-Directory $LogDir
if ($SaveOutputs) { Ensure-Directory $OutputDir }

$IndexHtmlTemplate = @'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>ImageBot</title>
<style>
:root{--bg:#0b0b0c;--surface:#111113;--surface2:#18181b;--surface3:#202024;--text:#f4f4f5;--muted:#a1a1aa;--soft:#71717a;--line:#27272a;--field:#151518;--white:#fff;--black:#050505;--bad:#d4d4d8;--ok:#fafafa;--shadow:0 24px 70px rgba(0,0,0,.42);--font:"Segoe UI","Microsoft YaHei UI","Microsoft YaHei",Arial,sans-serif;--mono:"Cascadia Code",Consolas,monospace}*{box-sizing:border-box}html,body{height:100%}body{margin:0;background:var(--bg);color:var(--text);font-family:var(--font);overflow:hidden}button,input,textarea,select{font:inherit}.app{height:100vh;display:grid;grid-template-columns:300px minmax(0,1fr);background:radial-gradient(circle at 50% -10%,rgba(255,255,255,.08),transparent 34rem),var(--bg)}.sidebar{border-right:1px solid var(--line);background:#09090a;display:grid;grid-template-rows:auto auto 1fr auto;min-width:0}.brand{height:64px;display:flex;align-items:center;gap:11px;padding:0 16px}.logo{width:32px;height:32px;border-radius:10px;background:#f4f4f5;color:#050505;display:grid;place-items:center;font-weight:1000}.brand strong{display:block;font-size:15px}.brand span{display:block;color:var(--soft);font-size:12px;margin-top:2px}.new-chat{margin:8px 12px 12px;border:1px solid var(--line);background:var(--surface);color:var(--text);border-radius:13px;padding:12px;font-weight:900;cursor:pointer;text-align:left}.history-pane{overflow:auto;padding:0 8px 10px}.history-title{color:var(--soft);font-size:12px;font-weight:900;padding:10px 8px}.history-item{border:0;background:transparent;color:var(--muted);width:100%;text-align:left;border-radius:12px;padding:10px 9px;display:grid;grid-template-columns:42px minmax(0,1fr);gap:9px;cursor:pointer}.history-item:hover{background:var(--surface)}.thumbs{display:grid;grid-template-columns:repeat(2,19px);grid-auto-rows:19px;gap:3px}.thumbs img,.thumb-empty{width:19px;height:19px;border-radius:5px;object-fit:cover;background:var(--surface2);border:1px solid var(--line)}.history-copy{min-width:0}.history-copy strong{display:block;color:#e4e4e7;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.history-copy small{display:block;color:var(--soft);font-size:11px;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.side-foot{padding:12px;border-top:1px solid var(--line);display:grid;gap:8px}.status-chip{display:flex;align-items:center;gap:8px;color:var(--muted);font:12px/1.4 var(--mono);border:1px solid var(--line);background:var(--surface);border-radius:12px;padding:9px;min-width:0}.dot{width:8px;height:8px;border-radius:99px;background:var(--ok);box-shadow:0 0 14px rgba(255,255,255,.28);flex:0 0 auto}.dot.bad{background:#71717a}.main{height:100vh;display:grid;grid-template-rows:64px minmax(0,1fr) auto;background:linear-gradient(180deg,#0e0e10,#0b0b0c)}.topbar{height:64px;border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;padding:0 22px}.model-pill{display:flex;align-items:center;gap:10px;color:#e4e4e7;font-weight:900}.model-pill span{color:var(--soft);font:12px var(--mono)}.top-actions{display:flex;gap:8px}.icon-btn,.btn{border:1px solid var(--line);background:var(--surface);color:var(--text);border-radius:12px;padding:10px 12px;font-weight:900;cursor:pointer}.icon-btn:hover,.btn:hover{background:var(--surface2)}.btn.primary{background:#f4f4f5;color:#09090b;border-color:#f4f4f5}.workspace{overflow:auto}.conversation{width:min(900px,calc(100% - 36px));margin:0 auto;padding:34px 0 170px}.hero{min-height:calc(100vh - 300px);display:grid;place-items:center;text-align:center}.hero-inner{max-width:720px}.hero h1{font-size:42px;letter-spacing:-.04em;margin:0 0 10px}.hero p{color:var(--muted);font-size:16px;margin:0 auto 24px;line-height:1.7}.quick-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.quick{border:1px solid var(--line);background:rgba(255,255,255,.035);border-radius:16px;padding:14px;text-align:left;color:#e4e4e7;cursor:pointer}.quick:hover{background:var(--surface)}.quick b{display:block;margin-bottom:5px}.quick span{color:var(--soft);font-size:12px;line-height:1.5}.messages{display:grid;gap:24px}.message{display:grid;grid-template-columns:36px minmax(0,1fr);gap:13px}.avatar{width:36px;height:36px;border-radius:50%;display:grid;place-items:center;background:var(--surface2);border:1px solid var(--line);font-weight:1000;color:#f4f4f5}.message.user .avatar{background:#f4f4f5;color:#050505}.bubble{padding-top:6px;color:#e7e7ea;line-height:1.72;white-space:pre-wrap}.message.user .bubble{color:#fff}.meta{color:var(--soft);font:12px var(--mono);margin-top:6px}.image-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-top:14px}.image-card{border:1px solid var(--line);background:var(--surface);border-radius:18px;overflow:hidden}.image-card img{display:block;width:100%;aspect-ratio:1/1;object-fit:cover;background:#050505}.image-actions{display:flex;gap:8px;padding:10px}.image-actions button,.image-actions a{flex:1;border:1px solid var(--line);background:var(--surface2);color:#f4f4f5;text-decoration:none;text-align:center;border-radius:11px;padding:9px;font-weight:900;font-size:12px;cursor:pointer}.composer-wrap{position:fixed;left:300px;right:0;bottom:0;background:linear-gradient(180deg,rgba(11,11,12,0),rgba(11,11,12,.92) 22%,#0b0b0c 100%);padding:32px 18px 18px}.composer{width:min(900px,calc(100vw - 336px));margin:0 auto;border:1px solid var(--line);background:#131316;border-radius:24px;box-shadow:var(--shadow);padding:10px}.file-strip{display:flex;gap:8px;flex-wrap:wrap;padding:0 4px 8px}.file-pill{display:inline-flex;align-items:center;gap:8px;border:1px solid var(--line);background:var(--surface2);border-radius:999px;padding:6px 9px;color:#d4d4d8;font-size:12px}.file-pill button{border:0;background:transparent;color:#a1a1aa;cursor:pointer;font-weight:1000}.input-line{display:grid;grid-template-columns:auto 1fr auto;gap:8px;align-items:end}.upload{width:42px;height:42px;border:1px solid var(--line);background:var(--surface2);color:#f4f4f5;border-radius:14px;cursor:pointer;font-size:22px}.prompt{min-height:44px;max-height:170px;resize:none;border:0;background:transparent;color:var(--text);outline:none;padding:10px 6px;line-height:1.55}.send{height:42px;min-width:76px;border:0;border-radius:14px;background:#f4f4f5;color:#050505;font-weight:1000;cursor:pointer}.send:disabled,.upload:disabled{opacity:.5;cursor:wait}.composer-meta{display:flex;justify-content:space-between;gap:10px;color:var(--soft);font-size:12px;padding:8px 5px 0}.preset-row{display:flex;gap:8px;flex-wrap:wrap}.preset{border:1px solid var(--line);background:var(--surface);color:var(--muted);border-radius:999px;padding:6px 9px;font-size:12px;font-weight:900;cursor:pointer}.preset.active{background:#f4f4f5;color:#050505;border-color:#f4f4f5}.progress{height:4px;border-radius:99px;background:var(--surface3);overflow:hidden;margin:8px 5px 0}.progress span{display:block;width:0;height:100%;background:#f4f4f5;transition:.25s}.toast{position:fixed;right:20px;bottom:142px;max-width:520px;border:1px solid var(--line);background:#18181b;color:#e4e4e7;border-radius:16px;padding:12px 14px;font:13px/1.55 var(--mono);box-shadow:var(--shadow);white-space:pre-wrap}.hidden{display:none!important}.drawer{position:fixed;top:0;right:0;width:min(460px,100vw);height:100vh;background:#0f0f11;border-left:1px solid var(--line);box-shadow:-20px 0 70px rgba(0,0,0,.45);transform:translateX(105%);transition:.22s ease;z-index:20;display:grid;grid-template-rows:64px minmax(0,1fr)}.drawer.open{transform:translateX(0)}.drawer-head{display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--line);padding:0 16px}.drawer-body{overflow:auto;padding:16px;display:grid;gap:13px}.field{display:grid;gap:7px}.field span{color:#d4d4d8;font-size:13px;font-weight:900}input,select{width:100%;border:1px solid var(--line);background:var(--field);color:var(--text);border-radius:13px;padding:11px;outline:none}.admin-grid{display:grid;gap:10px}.admin-actions{display:flex;flex-wrap:wrap;gap:8px}.diagnostics{display:grid;gap:9px}.diag-card{border:1px solid var(--line);background:var(--surface);border-radius:14px;padding:10px}.diag-card b{display:block;font-size:12px;margin-bottom:4px}.diag-card span{display:block;color:var(--muted);font:12px/1.45 var(--mono);word-break:break-all}.raw{border-top:1px solid var(--line);padding-top:12px}.raw summary{cursor:pointer;color:#d4d4d8;font-weight:900}.raw pre{overflow:auto;max-height:260px;background:#050505;color:#e4e4e7;padding:12px;border-radius:12px;border:1px solid var(--line);font-size:12px}.mobile-menu{display:none}@media(max-width:860px){.app{grid-template-columns:1fr}.sidebar{position:fixed;inset:0 auto 0 0;width:300px;z-index:30;transform:translateX(-105%);transition:.2s}.sidebar.open{transform:translateX(0)}.mobile-menu{display:block}.composer-wrap{left:0}.composer{width:min(900px,calc(100vw - 24px))}.hero h1{font-size:32px}.quick-grid{grid-template-columns:1fr}.conversation{width:min(900px,calc(100% - 24px));padding-bottom:190px}.topbar{padding:0 12px}.composer-meta{display:grid}.model-pill span{display:none}}
</style>
</head>
<body>
<div class="app">
  <aside class="sidebar" id="sidebar">
    <div class="brand"><div class="logo">AI</div><div><strong>ImageBot</strong><span>图片生成助手</span></div></div>
    <button class="new-chat" id="newChatBtn">+ 新对话</button>
    <div class="history-pane"><div class="history-title">最近生成</div><div id="historyList"></div></div>
    <div class="side-foot"><div class="status-chip" id="keyStatus"><span class="dot bad"></span><span>配置读取中</span></div><div class="status-chip" id="baseStatus"><span class="dot"></span><span>%%BASE_URL%%</span></div></div>
  </aside>

  <main class="main">
    <header class="topbar">
      <button class="icon-btn mobile-menu" id="menuBtn">☰</button>
      <div class="model-pill">ImageBot <span id="modelLabel">%%MODEL%%</span></div>
      <div class="top-actions"><button class="icon-btn" id="adminBtn">设置</button></div>
    </header>
    <section class="workspace" id="workspace">
      <div class="conversation">
        <section class="hero" id="hero">
          <div class="hero-inner"><h1>想生成什么图片？</h1><p>输入一句话即可生成图片；如果要参考某张图，先上传图片再说想怎么改。</p><div class="quick-grid">
            <button class="quick" data-prompt="生成一张高级黑白风格的电商产品海报，干净背景，真实摄影质感"><b>电商产品海报</b><span>适合商品主图、详情页视觉</span></button>
            <button class="quick" data-prompt="生成一张专业头像写真，干净背景，真实摄影，柔和光线"><b>头像写真</b><span>适合个人形象照、社交头像</span></button>
            <button class="quick" data-prompt="生成一张电影感海报，强构图，高级黑白色调，视觉冲击力强"><b>电影感海报</b><span>适合活动、宣传和封面</span></button>
            <button class="quick" data-prompt="把参考图改成高级商业摄影风格，保持主体，背景更干净"><b>上传图片后改图</b><span>先上传参考图，再点击这个模板</span></button>
          </div></div>
        </section>
        <section class="messages" id="messages"></section>
      </div>
    </section>
  </main>
</div>

<div class="composer-wrap">
  <div class="composer">
    <div class="file-strip" id="fileStrip"></div>
    <div class="input-line"><button class="upload" id="uploadBtn" title="上传图片">+</button><textarea class="prompt" id="promptInput" placeholder="发消息给 ImageBot，描述你想生成的图片"></textarea><button class="send" id="sendBtn">生成</button></div>
    <input id="imageInput" class="hidden" type="file" accept="image/png,image/jpeg,image/webp" multiple />
    <div class="composer-meta"><div class="preset-row"><button class="preset active" data-size="1024x1024" data-quality="high" data-bg="" data-format="">通用高清</button><button class="preset" data-size="1536x1024" data-quality="high" data-bg="opaque" data-format="png">电商白底</button><button class="preset" data-size="1024x1024" data-quality="high" data-bg="transparent" data-format="png">透明背景</button><button class="preset" data-size="1536x1024" data-quality="high" data-bg="" data-format="png">海报图</button></div><span>Enter 换行，Ctrl+Enter 生成</span></div>
    <div class="progress"><span id="progressBar"></span></div>
  </div>
</div>

<div class="toast hidden" id="toast"></div>

<aside class="drawer" id="drawer">
  <div class="drawer-head"><strong>管理员设置</strong><button class="icon-btn" id="closeDrawerBtn">关闭</button></div>
  <div class="drawer-body">
    <div class="admin-grid">
      <label class="field"><span>Base URL</span><input id="baseUrl" value="%%BASE_URL%%" autocomplete="off" /></label>
      <label class="field"><span>API Key</span><input id="apiKey" type="password" placeholder="留空使用 config.ini" autocomplete="off" /></label>
      <label class="field"><span>模型</span><input id="model" value="%%MODEL%%" autocomplete="off" /></label>
      <label class="field"><span>服务端超时（秒）</span><input id="timeoutSecInput" type="number" min="10" max="1800" value="240" /></label>
      <label class="field"><span>Mock 测试</span><select id="mockMode"><option value="0">关闭</option><option value="1">开启</option></select></label>
      <label class="field"><span>尺寸</span><select id="sizeInput"><option>1024x1024</option><option>1536x1024</option><option>1024x1536</option><option>2048x2048</option><option>2048x1152</option><option>auto</option></select></label>
      <label class="field"><span>清晰度</span><select id="qualityInput"><option value="high">高</option><option value="medium">中</option><option value="low">低</option><option value="auto">自动</option><option value="">默认</option></select></label>
      <label class="field"><span>背景</span><select id="backgroundInput"><option value="">默认</option><option value="auto">自动</option><option value="opaque">不透明</option><option value="transparent">透明</option></select></label>
      <label class="field"><span>输出格式</span><select id="outputFormatInput"><option value="">默认</option><option>png</option><option>jpeg</option><option>webp</option></select></label>
      <label class="field"><span>生成数量</span><select id="countInput"><option value="1">1张</option><option value="2">2张</option><option value="4">4张</option></select></label>
    </div>
    <div class="admin-actions"><button class="btn" id="saveConfigBtn">保存配置</button><button class="btn" id="testBtn">测试连接</button><button class="btn" id="diagnoseBtn">诊断</button><button class="btn" id="copyDiagBtn">复制诊断</button><button class="btn" id="copyErrorBtn">复制错误</button><button class="btn" id="clearHistoryBtn">清空历史</button></div>
    <div class="status-chip" id="configText"><span class="dot"></span><span>加载中...</span></div>
    <div class="diagnostics hidden" id="diagnosticsPanel"></div>
    <details class="raw"><summary>原始响应</summary><pre id="raw">{}</pre></details>
  </div>
</aside>
<script>
const qs=id=>document.getElementById(id);
const state={config:null,files:[],currentImages:[],historyItems:[],lastError:"",lastDiagnostics:null,maxUploadMb:50,timeoutSec:240,busy:false};
const messages=qs("messages"),hero=qs("hero"),toast=qs("toast"),rawEl=qs("raw"),progressBar=qs("progressBar"),workspace=qs("workspace");
function esc(v){return String(v).replace(/[&<>"']/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch]));}function attr(v){return esc(v).replace(/`/g,"&#96;");}function arr(v){if(Array.isArray(v))return v;if(!v)return[];if(typeof v==="object"){if(Array.isArray(v.items))return v.items;if(Array.isArray(v.value))return v.value;return Object.values(v).filter(x=>x&&typeof x==="object");}return[];}function compact(o){for(const k of Object.keys(o)){if(o[k]===""||o[k]===null||o[k]===undefined)delete o[k];}return o;}function showToast(t){toast.textContent=t;toast.classList.remove("hidden");clearTimeout(showToast.t);showToast.t=setTimeout(()=>toast.classList.add("hidden"),5200);}function setProgress(v){progressBar.style.width=`${Math.max(0,Math.min(100,v))}%`;}function setBusy(v){state.busy=v;for(const el of document.querySelectorAll("button,textarea,input,select")){if(["adminBtn","closeDrawerBtn","copyErrorBtn","copyDiagBtn"].includes(el.id))continue;el.disabled=v;}}function humanError(m){const t=String(m||"");if(/504|Gateway Timeout/i.test(t))return t+"\n处理建议：网关或 CDN 等待时间不够，联系管理员检查回源超时。";if(/401|403|key|API Key/i.test(t))return t+"\n处理建议：检查 API Key 是否填写或有效。";if(/model|模型/i.test(t))return t+"\n处理建议：确认模型名称是否被中转支持。";return t;}function commonPayload(){const p={base_url:qs("baseUrl").value.trim(),api_key:qs("apiKey").value.trim(),model:qs("model").value.trim()};if(!p.model)p.model="%%MODEL%%";return p;}function configPayload(){return {...commonPayload(),timeout_sec:Number(qs("timeoutSecInput").value||state.timeoutSec||240),mock:qs("mockMode").value==="1"};}
function addMessage(role,html){hero.classList.add("hidden");const el=document.createElement("article");el.className=`message ${role}`;el.innerHTML=`<div class="avatar">${role==="user"?"你":"AI"}</div><div class="bubble">${html}</div>`;messages.appendChild(el);workspace.scrollTo({top:workspace.scrollHeight,behavior:"smooth"});return el;}function renderFiles(){qs("fileStrip").innerHTML=state.files.map((f,i)=>`<span class="file-pill">${esc(f.name)} <button type="button" onclick="removeFile(${i})">x</button></span>`).join("");}function validateFiles(files){const list=Array.from(files||[]);if(list.length>16)throw new Error("参考图最多 16 张。");for(const f of list){if(!/^image\/(png|jpeg|webp)$/.test(f.type))throw new Error(`${f.name} 不是支持的图片。`);if(f.size>state.maxUploadMb*1024*1024)throw new Error(`${f.name} 超过 ${state.maxUploadMb} MB。`);}return list;}function fileToDataURL(f){return new Promise((ok,fail)=>{const r=new FileReader();r.onload=()=>ok(String(r.result||""));r.onerror=()=>fail(r.error||new Error("读取图片失败"));r.readAsDataURL(f);});}async function filesToDataURLs(files){const out=[];for(const f of files)out.push(await fileToDataURL(f));return out;}
async function requestJSON(path,payload){rawEl.textContent="{}";setBusy(true);setProgress(12);const started=Date.now();const timer=setInterval(()=>{const s=Math.floor((Date.now()-started)/1000);if(s>8)showToast(`正在生成，已等待 ${s} 秒`);setProgress(Math.min(88,12+s/state.timeoutSec*70));},1000);const controller=new AbortController();const abortTimer=setTimeout(()=>controller.abort(),(state.timeoutSec+20)*1000);try{const res=await fetch(path,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload),signal:controller.signal});let body;try{body=await res.json();}catch{throw new Error(`服务端返回非 JSON：HTTP ${res.status}`);}rawEl.textContent=JSON.stringify(body,null,2);if(!res.ok||body.error)throw new Error((body.error&&body.error.message)||body.message||`HTTP ${res.status}`);setProgress(100);return body;}catch(e){const msg=humanError(e.name==="AbortError"?"浏览器等待超时，已断开。":(e.message||String(e)));state.lastError=msg+"\n\n"+rawEl.textContent;showToast(msg);throw e;}finally{clearInterval(timer);clearTimeout(abortTimer);setBusy(false);setTimeout(()=>setProgress(0),900);}}
function imageResult(images){images=arr(images);state.currentImages=images;if(!images.length)return"请求完成，但没有可显示图片。";return`生成完成，共 ${images.length} 张。<div class="image-grid">${images.map((it,i)=>{const src=it.local_url||it.src||"";return`<div class="image-card"><img src="${attr(src)}" alt="生成结果 ${i+1}"><div class="image-actions"><button onclick="downloadImage(${i})">下载</button><a href="${attr(src)}" target="_blank" rel="noreferrer">打开</a></div></div>`}).join("")}</div>`;}async function send(){const prompt=qs("promptInput").value.trim();if(!prompt){showToast("请先输入想生成什么图片。");return;}try{const hasFiles=state.files.length>0;addMessage("user",`${esc(prompt)}${hasFiles?`<div class="meta">已上传 ${state.files.length} 张参考图</div>`:""}`);const payload=compact({...commonPayload(),prompt,size:qs("sizeInput").value,n:Number(qs("countInput").value||1),quality:qs("qualityInput").value,background:qs("backgroundInput").value,output_format:qs("outputFormatInput").value});let path="/api/generate";if(hasFiles){path="/api/edit";payload.images=await filesToDataURLs(state.files);}const body=await requestJSON(path,payload);addMessage("assistant",imageResult(body.images));qs("promptInput").value="";state.files=[];renderFiles();await loadHistory();}catch(e){addMessage("assistant",`生成失败：${esc(humanError(e.message||String(e)))}`);}}
function renderConfig(){const cfg=state.config;if(!cfg)return;const tempKey=qs("apiKey").value.trim();const mock=qs("mockMode").value==="1"||cfg.mock;const hasKey=cfg.has_api_key||tempKey||mock;qs("keyStatus").innerHTML=`<span class="dot ${hasKey?"":"bad"}"></span><span>${mock?"Mock 模式":hasKey?"Key 已配置":"Key 缺失"}</span>`;qs("baseStatus").innerHTML=`<span class="dot"></span><span>${esc(qs("baseUrl").value||cfg.base_url||"")}</span>`;qs("modelLabel").textContent=qs("model").value||cfg.model||"";qs("configText").innerHTML=`<span class="dot ${hasKey?"":"bad"}"></span><span>${mock?"模拟模式":"真实请求"} · 超时 ${state.timeoutSec}s · ${hasKey?"Key 可用":"Key 缺失"}</span>`;}async function loadConfig(){try{const r=await fetch("/api/config");const cfg=await r.json();state.config=cfg;state.maxUploadMb=cfg.max_upload_mb||50;state.timeoutSec=cfg.timeout_sec||240;qs("baseUrl").value=cfg.base_url||qs("baseUrl").value;qs("model").value=cfg.model||qs("model").value;qs("timeoutSecInput").value=state.timeoutSec;qs("mockMode").value=cfg.mock?"1":"0";renderConfig();}catch{showToast("配置读取失败");}}
async function loadHistory(){try{const r=await fetch("/api/history?limit=50");const body=await r.json();const items=arr(body.items);state.historyItems=items;qs("historyList").innerHTML=items.length?items.map((item,i)=>{const imgs=arr(item.images).filter(x=>x&&(x.src||x.local_url)).slice(0,4);const thumbs=imgs.length?imgs.map(img=>`<img src="${attr(img.local_url||img.src)}" alt="">`).join(""):`<div class="thumb-empty"></div>`;return`<button class="history-item" onclick="reuseHistory(${i})"><div class="thumbs">${thumbs}</div><div class="history-copy"><strong>${esc(item.prompt||"无提示词")}</strong><small>${esc(item.time||"")} · ${item.status==="success"?"成功":"失败"}</small></div></button>`}).join(""):`<div class="history-copy" style="padding:10px;color:var(--soft)">暂无历史</div>`;}catch{}}
async function saveConfig(){try{const body=await requestJSON("/api/config/save",configPayload());state.config=body.config;state.timeoutSec=body.config.timeout_sec||state.timeoutSec;qs("apiKey").value="";renderConfig();showToast("配置已保存");}catch{}}async function diagnose(){try{const body=await requestJSON("/api/diagnostics",configPayload());state.lastDiagnostics=body;const checks=arr(body.checks);qs("diagnosticsPanel").classList.remove("hidden");qs("diagnosticsPanel").innerHTML=checks.map(c=>`<div class="diag-card"><b>${c.ok?"正常":"需处理"} · ${esc(c.name||"")}</b><span>${esc(c.value||"")}</span></div>`).join("");showToast("诊断完成");}catch{}}async function postSimple(path,payload={}){const r=await fetch(path,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)});const b=await r.json();if(!r.ok||b.error)throw new Error((b.error&&b.error.message)||b.message||`HTTP ${r.status}`);return b;}function reuseHistory(i){const item=state.historyItems[i];if(!item)return;qs("promptInput").value=item.prompt||"";qs("sidebar").classList.remove("open");qs("promptInput").focus();}async function clearHistory(){if(!confirm("确认清空历史记录？不会删除图片文件。"))return;await postSimple("/api/history/clear",{});await loadHistory();}
async function downloadImage(i){const it=state.currentImages[i];if(!it)return;const src=it.local_url||it.src;if(!src)return;const a=document.createElement("a");a.href=src;a.download=it.filename||`image-${i+1}.png`;document.body.appendChild(a);a.click();a.remove();}async function copyText(t){try{await navigator.clipboard.writeText(t);}catch{const ta=document.createElement("textarea");ta.value=t;document.body.appendChild(ta);ta.select();document.execCommand("copy");ta.remove();}}
for(const q of document.querySelectorAll(".quick")){q.addEventListener("click",()=>{qs("promptInput").value=q.dataset.prompt||"";qs("promptInput").focus();});}for(const p of document.querySelectorAll(".preset")){p.addEventListener("click",()=>{document.querySelectorAll(".preset").forEach(x=>x.classList.remove("active"));p.classList.add("active");qs("sizeInput").value=p.dataset.size||"1024x1024";qs("qualityInput").value=p.dataset.quality||"high";qs("backgroundInput").value=p.dataset.bg||"";qs("outputFormatInput").value=p.dataset.format||"";});}qs("sendBtn").addEventListener("click",send);qs("promptInput").addEventListener("keydown",e=>{if(e.key==="Enter"&&(e.ctrlKey||e.metaKey))send();});qs("uploadBtn").addEventListener("click",()=>qs("imageInput").click());qs("imageInput").addEventListener("change",e=>{state.files=validateFiles(e.target.files);renderFiles();});window.removeFile=i=>{state.files.splice(i,1);renderFiles();};qs("newChatBtn").addEventListener("click",()=>{messages.innerHTML="";hero.classList.remove("hidden");state.currentImages=[];qs("promptInput").value="";state.files=[];renderFiles();});qs("adminBtn").addEventListener("click",()=>qs("drawer").classList.add("open"));qs("closeDrawerBtn").addEventListener("click",()=>qs("drawer").classList.remove("open"));qs("menuBtn").addEventListener("click",()=>qs("sidebar").classList.toggle("open"));qs("saveConfigBtn").addEventListener("click",saveConfig);qs("diagnoseBtn").addEventListener("click",diagnose);qs("testBtn").addEventListener("click",async()=>{try{const b=await requestJSON("/api/test",commonPayload());showToast(b.message||"连接测试完成");}catch{}});qs("copyDiagBtn").addEventListener("click",async()=>{if(!state.lastDiagnostics){showToast("没有诊断信息");return;}await copyText(JSON.stringify(state.lastDiagnostics,null,2));showToast("诊断已复制");});qs("copyErrorBtn").addEventListener("click",async()=>{if(!state.lastError){showToast("没有错误信息");return;}await copyText(state.lastError);showToast("错误已复制");});qs("clearHistoryBtn").addEventListener("click",clearHistory);for(const id of ["baseUrl","apiKey","model","timeoutSecInput","mockMode"]){qs(id).addEventListener("input",()=>{state.timeoutSec=Number(qs("timeoutSecInput").value||state.timeoutSec||240);renderConfig();});}
window.downloadImage=downloadImage;window.reuseHistory=reuseHistory;loadConfig();loadHistory();
</script>
</body>
</html>
'@

$ExternalIndexPath = Join-Path $ScriptDir "webui_index.html"
if (Test-Path -LiteralPath $ExternalIndexPath) {
    $IndexHtmlTemplate = Get-Content -Raw -LiteralPath $ExternalIndexPath -Encoding UTF8
}

$IndexHtml = $IndexHtmlTemplate.
    Replace("%%BASE_URL%%", (HtmlAttr $BaseUrl)).
    Replace("%%MODEL%%", (HtmlAttr $DefaultModel))

function Send-HttpResponse($client, [int]$statusCode, [string]$contentType, [string]$body) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $reasonMap = @{
        200 = "OK"; 400 = "Bad Request"; 404 = "Not Found"; 405 = "Method Not Allowed"; 413 = "Payload Too Large"; 500 = "Internal Server Error"; 502 = "Bad Gateway"; 504 = "Gateway Timeout"
    }
    $reason = "OK"
    if ($reasonMap.ContainsKey($statusCode)) { $reason = $reasonMap[$statusCode] }
    $header = "HTTP/1.1 $statusCode $reason`r`nContent-Type: $contentType`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream = $client.GetStream()
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Send-Json($client, [int]$statusCode, $obj) {
    Send-HttpResponse $client $statusCode "application/json; charset=utf-8" (To-JsonText $obj 100)
}

function Send-BinaryResponse($client, [int]$statusCode, [string]$contentType, [byte[]]$bytes) {
    $reason = if ($statusCode -eq 200) { "OK" } else { "Not Found" }
    $header = "HTTP/1.1 $statusCode $reason`r`nContent-Type: $contentType`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream = $client.GetStream()
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Read-HttpRequest($client, [int64]$maxBodyBytes) {
    $stream = $client.GetStream()
    $buffer = New-Object byte[] 8192
    $memory = New-Object System.IO.MemoryStream
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $memory.Write($buffer, 0, $read)
        if ($memory.Length -gt 1048576) {
            throw (New-HttpException 413 "HTTP 请求头过大。")
        }
        $text = [System.Text.Encoding]::ASCII.GetString($memory.ToArray())
        $headerEnd = $text.IndexOf("`r`n`r`n")
    }

    $all = $memory.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($all)
    $headerEnd = $headerText.IndexOf("`r`n`r`n")
    if ($headerEnd -lt 0) {
        throw (New-HttpException 400 "不是有效的 HTTP 请求。")
    }

    $headersPart = $headerText.Substring(0, $headerEnd)
    $lines = $headersPart -split "`r`n"
    if ($lines.Count -eq 0) {
        throw (New-HttpException 400 "HTTP 请求行缺失。")
    }
    $requestLine = $lines[0] -split " "
    if ($requestLine.Count -lt 2) {
        throw (New-HttpException 400 "HTTP 请求行格式不正确。")
    }
    $method = $requestLine[0].ToUpperInvariant()
    $path = $requestLine[1]

    $headers = @{}
    for ($i = 1; $i -lt $lines.Length; $i++) {
        $idx = $lines[$i].IndexOf(":")
        if ($idx -gt 0) {
            $key = $lines[$i].Substring(0, $idx).Trim().ToLowerInvariant()
            $value = $lines[$i].Substring($idx + 1).Trim()
            $headers[$key] = $value
        }
    }

    if ($headers.ContainsKey("expect") -and ([string]$headers["expect"]).ToLowerInvariant().Contains("100-continue")) {
        $continueBytes = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
        $stream.Write($continueBytes, 0, $continueBytes.Length)
        $stream.Flush()
    }

    $contentLength = 0
    if ($headers.ContainsKey("content-length")) {
        if (-not [int]::TryParse($headers["content-length"], [ref]$contentLength)) {
            throw (New-HttpException 400 "Content-Length 不正确。")
        }
    }
    if ($contentLength -gt $maxBodyBytes) {
        throw (New-HttpException 413 "请求体超过 $MaxBodyMB MB，请调小上传图片或提高 IMAGE_WEBUI_MAX_BODY_MB。")
    }

    $bodyStart = $headerEnd + 4
    $bodyMemory = New-Object System.IO.MemoryStream
    if ($all.Length -gt $bodyStart) {
        $current = $all[$bodyStart..($all.Length - 1)]
        $bodyMemory.Write($current, 0, $current.Count)
    }
    while ($bodyMemory.Length -lt $contentLength) {
        $need = [Math]::Min($buffer.Length, $contentLength - [int]$bodyMemory.Length)
        $read = $stream.Read($buffer, 0, $need)
        if ($read -le 0) { break }
        $bodyMemory.Write($buffer, 0, $read)
    }

    return @{
        method = $method
        path = $path
        headers = $headers
        body = [System.Text.Encoding]::UTF8.GetString($bodyMemory.ToArray())
    }
}

function Get-ListenAddress([string]$hostName) {
    $hostText = ($hostName + "").Trim()
    if ([string]::IsNullOrWhiteSpace($hostText) -or $hostText -eq "localhost") {
        return [System.Net.IPAddress]::Loopback
    }
    if ($hostText -eq "0.0.0.0" -or $hostText -eq "*") {
        return [System.Net.IPAddress]::Any
    }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($hostText, [ref]$ip)) {
        return $ip
    }
    $addresses = [System.Net.Dns]::GetHostAddresses($hostText)
    foreach ($address in $addresses) {
        if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $address
        }
    }
    return [System.Net.IPAddress]::Loopback
}

function Handle-OutputFile($client, [string]$path) {
    $fileName = [System.IO.Path]::GetFileName([Uri]::UnescapeDataString($path.Substring("/outputs/".Length)))
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        Send-Json $client 404 @{ error = @{ message = "not found" } }
        return
    }
    $filePath = Join-Path $OutputDir $fileName
    if (-not (Test-Path -LiteralPath $filePath)) {
        Send-Json $client 404 @{ error = @{ message = "output file not found" } }
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    Send-BinaryResponse $client 200 (Guess-MimeFromFile $filePath) $bytes
}

function Route-Request($client, $req) {
    $method = $req.method
    $path = ([string]$req.path -split "\?")[0]
    Write-Host "$method $path"

    if ($method -eq "GET" -and ($path -eq "/" -or $path -eq "/index.html")) {
        Send-HttpResponse $client 200 "text/html; charset=utf-8" $IndexHtml
        return
    }
    if ($method -eq "GET" -and $path -eq "/api/health") {
        Send-Json $client 200 ([ordered]@{ ok = $true; time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); config = (Get-ConfigSnapshot) })
        return
    }
    if ($method -eq "GET" -and $path -eq "/api/config") {
        Send-Json $client 200 (Get-ConfigSnapshot)
        return
    }
    if ($method -eq "GET" -and $path -eq "/api/history") {
        Send-Json $client 200 ([ordered]@{ items = @(Get-HistoryRecords 50) })
        return
    }
    if ($method -eq "GET" -and $path.StartsWith("/outputs/")) {
        Handle-OutputFile $client $path
        return
    }
    if ($method -eq "POST" -and $path -eq "/api/test") {
        $payload = Parse-JsonBody $req.body
        $result = Handle-ApiTest $payload
        $status = if ($result.ok) { 200 } else { 502 }
        Send-Json $client $status $result
        return
    }
    if ($method -eq "POST" -and $path -eq "/api/config/save") {
        $payload = Parse-JsonBody $req.body
        Send-Json $client 200 (Handle-ConfigSave $payload)
        return
    }
    if ($method -eq "POST" -and $path -eq "/api/diagnostics") {
        $payload = Parse-JsonBody $req.body
        Send-Json $client 200 (Handle-Diagnostics $payload)
        return
    }
    if ($method -eq "POST" -and $path -eq "/api/history/delete") {
        $payload = Parse-JsonBody $req.body
        Send-Json $client 200 (Remove-HistoryRecord ([string](Get-Prop $payload "id" "")))
        return
    }
    if ($method -eq "POST" -and $path -eq "/api/history/clear") {
        [void](Parse-JsonBody $req.body)
        Send-Json $client 200 (Clear-HistoryRecords)
        return
    }
    if ($method -eq "POST" -and $path -eq "/api/generate") {
        $payload = Parse-JsonBody $req.body
        $result = Handle-ApiGenerate $payload
        $status = if ($null -ne $result.error) { [int]$result.error.status } else { 200 }
        if ($status -lt 100 -or $status -gt 599) { $status = 502 }
        Send-Json $client $status $result
        return
    }
    if ($method -eq "POST" -and $path -eq "/api/edit") {
        $payload = Parse-JsonBody $req.body
        $result = Handle-ApiEdit $payload
        $status = if ($null -ne $result.error) { [int]$result.error.status } else { 200 }
        if ($status -lt 100 -or $status -gt 599) { $status = 502 }
        Send-Json $client $status $result
        return
    }

    Send-Json $client 404 @{ error = @{ message = "not found" } }
}

$listenAddress = Get-ListenAddress $HostName
$listener = [System.Net.Sockets.TcpListener]::new($listenAddress, $Port)
$LocalUrl = "http://$HostName`:$Port"
$BrowserHost = if ($HostName -eq "0.0.0.0" -or $HostName -eq "*") { "127.0.0.1" } else { $HostName }
$BrowserUrl = "http://$BrowserHost`:$Port"

try {
    $listener.Start()
} catch {
    Write-Host ""
    Write-Host "[启动失败] 端口或监听地址不可用：$HostName`:$Port" -ForegroundColor Red
    Write-Host "可能原因：端口已被占用、Host 写错，或防火墙/权限拦截。"
    Write-Host "建议：修改 config.ini 的 IMAGE_WEBUI_PORT，例如 7862。"
    Write-Host "原始错误：$($_.Exception.Message)"
    Write-AppLog "error" "listener start failed: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "生图 Bat Studio 已启动：$LocalUrl" -ForegroundColor Green
Write-Host "配置文件：$ConfigPath"
Write-Host "上游地址：$BaseUrl"
Write-Host "模型：$DefaultModel"
Write-Host "超时：$TimeoutSec 秒"
Write-Host "输出目录：$OutputDir"
Write-Host "日志目录：$LogDir"
Write-Host "Mock 模式：$MockMode"
foreach ($warning in (Get-ConfigWarnings)) {
    Write-Host "[提示] $warning" -ForegroundColor Yellow
}
Write-Host "关闭此窗口或按 Ctrl+C 可停止服务。"
Write-AppLog "info" "server started url=$LocalUrl base=$BaseUrl model=$DefaultModel mock=$MockMode"

if (-not $NoBrowser) {
    try { Start-Process $BrowserUrl | Out-Null } catch {}
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $req = Read-HttpRequest $client $MaxBodyBytes
            Route-Request $client $req
        } catch {
            $status = Get-HttpExceptionStatus $_.Exception
            $message = $_.Exception.Message
            Write-AppLog "error" "request failed status=$status message=$message"
            try {
                Send-Json $client $status ([ordered]@{ error = [ordered]@{ message = $message; status = $status } })
            } catch {}
        } finally {
            try { $client.Close() } catch {}
        }
    }
} finally {
    Write-AppLog "info" "server stopped"
    $listener.Stop()
}


