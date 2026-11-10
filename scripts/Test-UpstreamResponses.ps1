param(
    [string]$Root = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$appScript = Join-Path $Root "openai_images_webui_no_python_config.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($appScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Application script has PowerShell syntax errors." }
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Invoke-Expression $definition.Extent.Text
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Upstream response test failed: $Message" }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch { return }
    throw "Upstream response test failed: $Message"
}

Assert-True (Test-GptImageModel "gpt-image-2.5-flare") "Flare model was not recognized"
Assert-True (Test-GptImageModel "gpt-image-2.5-sunburst-2026-09-08") "dated Sunburst model was not recognized"
Assert-True (Test-RetrySafeUpstreamError 400 "Unsupported parameter: quality") "unsupported optional parameter was not marked retry-safe"
Assert-True (-not (Test-RetrySafeUpstreamError 429 "rate limit")) "rate-limit response was incorrectly marked retry-safe"
Assert-Throws { Assert-ImageSize "gpt-image-2.5-flare" "1024x512" } "undersized custom resolution was accepted"
Assert-ImageSize "gpt-image-2.5-flare" "1536x864"
Assert-ImageSize "gpt-image-2.5-sunburst" "1536x1024"
Assert-ImageQuality "gpt-image-2.5-flare" "max"
Assert-Throws { Assert-ImageQuality "gpt-image-2" "max" } "xhigh quality was accepted for an older image model"

foreach ($model in @("gpt-image-2.6-flare", "gpt-image-2.6-sunburst")) {
    $capabilities = Get-ImageModelCapabilities $model
    Assert-True ($capabilities.known -and $capabilities.supports_complexity) "$model capabilities were not recognized"
    Assert-True ($capabilities.default_complexity -eq "high") "$model default complexity is incorrect"
    Assert-True (($capabilities.output_formats -join ',') -eq 'png,jpeg,webp') "$model exposed unsupported output formats"
    foreach ($quality in @("", "auto", "low", "medium", "high", "xhigh", "max")) { Assert-ImageQuality $model $quality }
    foreach ($complexity in @("", "low", "medium", "high")) { Assert-ImageComplexity $model $complexity }
    Assert-Throws { Assert-ImageQuality $model "ultra" } "$model accepted an invalid quality"
    Assert-Throws { Assert-ImageComplexity $model "auto" } "$model accepted an invalid complexity"
    Assert-ImageSize $model "1280x512"
    Assert-ImageSize $model "3840x2160"
    foreach ($size in @("1024x512", "1025x1024", "4096x2048", "3840x3840", "3840x512", "00x1024")) {
        Assert-Throws { Assert-ImageSize $model $size } "$model accepted invalid size $size"
    }
}
foreach ($oldModel in @("gpt-image-2.5-flare", "gpt-image-2.5-sunburst-2026-09-08", "gpt-image-2", "gpt-image-2-2026-04-21", "gpt-image-1.5")) {
    Assert-True (-not (Get-ImageModelCapabilities $oldModel).supports_complexity) "$oldModel advertised complexity"
    Assert-Throws { Assert-ImageComplexity $oldModel "high" } "$oldModel accepted complexity"
    Assert-ImageComplexity $oldModel ""
}
Assert-Throws { Assert-ImageQuality "gpt-image-2-2026-04-21" "max" } "dated Image 2 accepted max quality"
Assert-Throws { Assert-ImageSize "gpt-image-2-2026-04-21" "1024x512" } "dated Image 2 bypassed size validation"
Assert-True (-not (Get-ImageModelCapabilities "customer-image-model").known) "custom model was treated as a known OpenAI model"
Assert-ImageQuality "customer-image-model" "max"
Assert-ImageComplexity "customer-image-model" "low"
Assert-ImageSize "customer-image-model" "512x512"
Assert-True (Test-RetrySafeUpstreamError 422 "complexity is not supported") "complexity rejection was not marked retry-safe"
foreach ($message in @("Invalid parameter: model", "Unknown field: prompt", "Invalid size", "Invalid parameter", "account rejected")) {
    Assert-True (-not (Test-RetrySafeUpstreamError 400 $message)) "nonoptional error was marked retry-safe: $message"
}
foreach ($status in @(408, 429, 500, 502, 504)) {
    Assert-True (-not (Test-RetrySafeUpstreamError $status "Unsupported parameter: complexity")) "uncertain/rate-limited response was marked retry-safe: $status"
}
$basicPayload = [ordered]@{ model = "gpt-image-2.6-flare"; prompt = "test"; quality = "max"; complexity = "low"; background = "opaque"; output_format = "png"; output_compression = 90 }
$compatibilityOutput = @(Apply-RequestCompatibility $basicPayload "basic")
Assert-True ($compatibilityOutput.Count -eq 0 -and $basicPayload.Count -eq 2) "basic mode polluted the response or retained optional fields"
Assert-True ((To-JsonText @()) -eq '[]') "empty array was not serialized as an array"
Assert-True ((To-JsonText @('one')) -eq '["one"]') "single-item array was not serialized as an array"
$oldCapabilities = To-JsonText (Get-ImageModelCapabilities "gpt-image-2")
Assert-True ($oldCapabilities -match '"complexities":\[\]') "unsupported complexities must serialize as an empty array"

$script:SaveOutputs = $false
$script:OutputDir = Join-Path $env:TEMP "imagebot-response-tests"
$script:MaxUploadBytes = 10MB
$script:MaxUploadMB = 10
$script:LogDir = $script:OutputDir
$script:LogFile = Join-Path $script:OutputDir "test.log"
$started = Get-Date
$payload = @{ output_format = "png" }
$urlResponse = '{"data":[{"url":"https://cdn.example.test/image.png"}]}' | ConvertFrom-Json
$urlImages = @(Normalize-Images $urlResponse $payload "generate")
Assert-True ($urlImages.Count -eq 1) "URL response was not normalized"
Assert-True ($urlImages[0].src -eq "https://cdn.example.test/image.png") "URL response changed source"
Assert-True (-not $urlImages[0].saved) "remote URL was incorrectly marked saved"

$base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("image bytes"))
$base64Response = ('{"data":[{"b64_json":"' + $base64 + '"}]}' | ConvertFrom-Json)
$base64Images = @(Normalize-Images $base64Response $payload "generate")
Assert-True ($base64Images.Count -eq 1) "Base64 response was not normalized"
Assert-True ($base64Images[0].is_data_url) "Base64 response was not exposed as a data URL"
Assert-True ($base64Images[0].mime_type -eq "image/png") "Base64 response got the wrong MIME type"

$raw = Redact-Raw $base64Response
Assert-True ([string](Get-Prop $raw.data[0] "b64_json" "") -eq "<base64 omitted>") "raw response did not redact base64"

$recoveryRoot = Join-Path ([IO.Path]::GetTempPath()) ("ImageBot-RecoveryTest-" + [Guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null
    $script:OutputDir = $recoveryRoot
    $script:HistoryFile = Join-Path $recoveryRoot "history.jsonl"
    $script:LogDir = $recoveryRoot
    $script:LogFile = Join-Path $recoveryRoot "test.log"
    $interrupted = [ordered]@{ request_id = "interrupted-request-123"; status = "processing"; revision = 1; images = @(); input_images = @() }
    [IO.File]::WriteAllText($script:HistoryFile, (To-JsonText $interrupted 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $probe = Get-Content -Raw -LiteralPath $script:HistoryFile -Encoding UTF8 | ConvertFrom-Json
    Assert-True (([string](Get-Prop $probe "status" "")) -eq "processing") "test history probe could not read processing status"
    $script:HistoryFile = [IO.Path]::GetFullPath($script:HistoryFile)
    $recoveredChanged = Recover-InterruptedHistoryRecords $script:HistoryFile
    Assert-True $recoveredChanged "recovery did not report changing the test history"
    $recovered = Get-Content -Raw -LiteralPath $script:HistoryFile -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($recovered.status -eq "unknown" -and -not $recovered.retry_safe) "interrupted history did not become unknown (status=$($recovered.status); file=$([IO.File]::ReadAllText($script:HistoryFile)))"

    $singlePage = Get-HistoryPage "/api/history?limit=1"
    Assert-True ($singlePage.total -eq 1 -and $singlePage.items.Count -eq 1 -and -not $singlePage.has_more) "single-line history pagination is incorrect"
    $historyLines = @(1..1005 | ForEach-Object { To-JsonText ([ordered]@{ request_id = "history-request-$_"; status = "success"; images = @() }) })
    [IO.File]::WriteAllLines($script:HistoryFile, $historyLines, [Text.UTF8Encoding]::new($false))
    $historyHash = (Get-FileHash -LiteralPath $script:HistoryFile -Algorithm SHA256).Hash
    $defaultPage = Get-HistoryPage "/api/history"
    Assert-True ($defaultPage.total -eq 1005 -and $defaultPage.items.Count -eq 50 -and $defaultPage.has_more) "default history page is incorrect"
    $largerPage = Get-HistoryPage "/api/history?limit=75"
    Assert-True ($largerPage.items.Count -eq 75 -and $largerPage.items[0].request_id -eq 'history-request-1005') "history limit or newest-first order is incorrect"
    $boundedPage = Get-HistoryPage "/api/history?limit=1001"
    Assert-True ($boundedPage.items.Count -eq 1000 -and $boundedPage.has_more) "history limit was not bounded"
    foreach ($limit in @('0', '-1', 'abc', '1.5', '', '1&limit=2')) {
        Assert-Throws { Get-HistoryPage "/api/history?limit=$limit" } "invalid history limit was accepted: $limit"
    }
    Assert-True ((Get-FileHash -LiteralPath $script:HistoryFile -Algorithm SHA256).Hash -eq $historyHash) "history reads mutated local records"

    $script:ScriptDir = $recoveryRoot
    $script:ConfigPath = Join-Path $recoveryRoot "config.ini"
    $configText = "OPENAI_BASE_URL=https://www.chichiapi.cn/`nOPENAI_API_KEY=`nIMAGE_WEBUI_TIMEOUT=240`nIMAGE_WEBUI_MOCK=1`n"
    [IO.File]::WriteAllText($script:ConfigPath, $configText, [Text.UTF8Encoding]::new($false))
    $savedModelEnvironment = [Environment]::GetEnvironmentVariable("OPENAI_IMAGE_MODEL")
    try {
        [Environment]::SetEnvironmentVariable("OPENAI_IMAGE_MODEL", $null)
        Apply-RuntimeConfigFromFile
        Assert-True ($script:DefaultModel -eq 'gpt-image-2.6-flare') "new configuration did not default to Image 2.6 Flare"
    } finally {
        [Environment]::SetEnvironmentVariable("OPENAI_IMAGE_MODEL", $savedModelEnvironment)
    }
    foreach ($configuredModel in @('gpt-image-2.5-sunburst', 'customer-image-model')) {
        [IO.File]::WriteAllText($script:ConfigPath, ($configText + "OPENAI_IMAGE_MODEL=$configuredModel`nIMAGEBOT_MODEL_PRESETS=customer-image-model`n"), [Text.UTF8Encoding]::new($false))
        $configHash = (Get-FileHash -LiteralPath $script:ConfigPath -Algorithm SHA256).Hash
        Apply-RuntimeConfigFromFile
        $snapshot = Get-ConfigSnapshot
        Assert-True ($snapshot.model -eq $configuredModel) "existing configured model was overwritten"
        Assert-True ($snapshot.model_presets[0] -eq 'gpt-image-2.6-flare' -and $snapshot.model_presets[1] -eq 'gpt-image-2.6-sunburst') "Image 2.6 presets were not first"
        Assert-True ($snapshot.model_presets -contains 'customer-image-model') "custom model preset was removed"
        Assert-True ($null -ne $snapshot.model_capabilities[$configuredModel]) "configured model capabilities were omitted"
        Assert-True ((Get-FileHash -LiteralPath $script:ConfigPath -Algorithm SHA256).Hash -eq $configHash) "loading configuration changed its file"
    }

    $mockRequest = @{ prompt = 'PNG demonstration'; model = 'gpt-image-2.6-flare'; size = '1536x864'; quality = ' XHIGH '; complexity = ' LOW '; mock = $true; request_id = 'test-png-generation' }
    $mockGeneration = Handle-ApiGenerate $mockRequest
    Assert-True ($mockGeneration.request.quality -eq 'xhigh' -and $mockGeneration.request.complexity -eq 'low') "normalized image parameters were not forwarded"
    Assert-True ($mockGeneration.images[0].mime_type -eq 'image/png') "mock generation MIME type is not PNG"
    $pngStream = [IO.MemoryStream]::new((Get-DataUrlBytes $mockGeneration.images[0].src))
    $png = $null
    try {
        $png = [Drawing.Image]::FromStream($pngStream)
        Assert-True ($png.Width -eq 1536 -and $png.Height -eq 864) "mock PNG dimensions do not match the requested size"
        Assert-True ($png.RawFormat.Guid -eq [Drawing.Imaging.ImageFormat]::Png.Guid) "mock result is not an actual PNG"
    } finally {
        if ($null -ne $png) { $png.Dispose() }
        $pngStream.Dispose()
    }
    $mockEdit = Handle-ApiEdit @{ prompt = 'Continue edit'; model = 'gpt-image-2.6-sunburst'; size = '1024x1024'; complexity = 'medium'; quality = 'max'; images = @($mockGeneration.images[0].src); mock = $true; request_id = 'test-png-edit'; parent_request_id = 'test-png-generation' }
    Assert-True ($mockEdit.request.complexity -eq 'medium' -and $mockEdit.request.quality -eq 'max' -and $mockEdit.revision -eq 2) "mock PNG cannot continue through an Image 2.6 edit"
    Assert-True ((Get-HistoryRecordByRequestId 'test-png-edit').complexity -eq 'medium') "edit complexity was not persisted"

    $script:UpstreamCalls = 0
    function Invoke-JsonPost($url, $headers, [string]$body, [int]$timeoutSec) {
        $script:UpstreamCalls++
        throw [Net.WebException]::new('Test request timed out', [Net.WebExceptionStatus]::Timeout)
    }
    $script:ApiKey = 'test-only-key'
    $timeoutRequest = @{ prompt = 'timeout test'; model = 'gpt-image-2.6-flare'; size = '1024x1024'; complexity = 'high'; mock = $false; request_id = 'test-timeout-request' }
    $timeoutResult = Handle-ApiGenerate $timeoutRequest
    Assert-True ($timeoutResult.outcome_unknown -and -not $timeoutResult.retry_safe) "timeout outcome was not marked unknown"
    Assert-True ((Get-HistoryRecordByRequestId 'test-timeout-request').status -eq 'unknown') "timeout did not persist unknown state"
    $timeoutRequest.request_mode = 'basic'
    $timeoutReplay = Handle-ApiGenerate $timeoutRequest
    Assert-True ($timeoutReplay.pending -and $script:UpstreamCalls -eq 1) "timeout was repeated when requesting a basic retry"
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolved = [IO.Path]::GetFullPath($recoveryRoot)
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Upstream response tests passed."
