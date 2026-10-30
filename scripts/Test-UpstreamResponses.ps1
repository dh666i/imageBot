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
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolved = [IO.Path]::GetFullPath($recoveryRoot)
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Upstream response tests passed."
