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
Write-Host "Upstream response tests passed."
