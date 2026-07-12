param(
    [string]$Root = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$appScript = Join-Path $Root "openai_images_webui_no_python_config.ps1"

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Updater test failed: $Message" }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($appScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Application script has PowerShell syntax errors." }
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Invoke-Expression $definition.Extent.Text
}

$script:RealAtomicImpl = (Get-Item Function:\Set-ProgramFileAtomically).ScriptBlock
$realExpectedHashImpl = (Get-Item Function:\Get-ExpectedUpdateHash).ScriptBlock
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ImageBot-UpdaterTests-" + [Guid]::NewGuid().ToString("N"))
$packagePath = Join-Path $testRoot "ImageBot-v1.4.0.zip"

function New-TestPackage {
    $source = Join-Path $testRoot "package-source"
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    foreach ($name in (Get-RequiredUpdateFileNames)) {
        $content = "new::$name"
        if ($name -eq "openai_images_webui_no_python_config.ps1") { $content = '$AppVersion = "v1.4.0"' }
        if ($name -eq "webui_index.html") { $content = '<html>%%BASE_URL%% %%MODEL%% %%APP_VERSION%%</html>' }
        Set-Content -LiteralPath (Join-Path $source $name) -Value $content -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $source "config.ini") -Value "OPENAI_API_KEY=" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $source "ImageBot.exe") -Value "new launcher" -Encoding ASCII
    Compress-Archive -Path (Join-Path $source "*") -DestinationPath $packagePath -Force
}

function Initialize-TestCase([string]$name) {
    $caseRoot = Join-Path $testRoot $name
    New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
    $originals = @{}
    foreach ($fileName in (Get-RequiredUpdateFileNames)) {
        $content = "old::$fileName"
        $originals[$fileName] = $content
        Set-Content -LiteralPath (Join-Path $caseRoot $fileName) -Value $content -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $caseRoot "config.ini") -Value "OPENAI_API_KEY=customer-local-value" -Encoding UTF8

    $script:ScriptDir = $caseRoot
    $script:AppVersion = "v1.3.0"
    $script:UpdateRepo = "dh666i/imageBot"
    $script:BaseUrl = "https://api.henng.cn"
    $script:DefaultModel = "gpt-image-2"
    $script:LogDir = Join-Path $caseRoot "logs"
    $script:LogFile = Join-Path $script:LogDir "webui-test.log"
    $script:IndexHtmlTemplate = ""
    $script:IndexHtml = ""
    $script:FakePackagePath = $packagePath
    $script:FakePackageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:FakeUpdateInfo = [pscustomobject]@{
        ok = $true
        current_version = "v1.3.0"
        latest_version = "v1.4.0"
        update_available = $true
        asset_url = "https://github.com/dh666i/imageBot/releases/download/v1.4.0/ImageBot-v1.4.0.zip"
        asset_digest = ""
        checksum_url = "https://github.com/dh666i/imageBot/releases/download/v1.4.0/ImageBot-v1.4.0.zip.sha256"
    }
    return [pscustomobject]@{ Root = $caseRoot; Originals = $originals }
}

function Get-UpdateInfo { return $script:FakeUpdateInfo }
function Invoke-HttpDownloadFile([string]$url, [string]$destination, [int]$timeoutSec = 180) {
    Copy-Item -LiteralPath $script:FakePackagePath -Destination $destination -Force
}
function Get-ExpectedUpdateHash($info) { return $script:FakePackageHash }

function Assert-OriginalFiles($case) {
    foreach ($name in (Get-RequiredUpdateFileNames)) {
        $actual = (Get-Content -Raw -LiteralPath (Join-Path $case.Root $name) -Encoding UTF8).Trim()
        Assert-True ($actual -eq $case.Originals[$name]) "$name was not restored"
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    New-TestPackage

    $packageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $digestResult = & $realExpectedHashImpl ([pscustomobject]@{ asset_digest = "sha256:$packageHash"; checksum_url = "" })
    Assert-True ($digestResult -eq $packageHash) "GitHub digest was not parsed"

    $success = Initialize-TestCase "success"
    $applyResult = Handle-UpdateApply ([pscustomobject]@{})
    Assert-True $applyResult.updated "successful update did not report updated=true"
    Assert-True ((Test-Path -LiteralPath (Join-Path $success.Root "ImageBot.exe"))) "new launcher was not installed"
    Assert-True (((Get-Content -Raw -LiteralPath (Join-Path $success.Root "config.ini") -Encoding UTF8).Trim()) -eq "OPENAI_API_KEY=customer-local-value") "local config was changed"
    $status = Handle-UpdateStatus
    Assert-True $status.rollback_available "rollback was not offered after update"
    Assert-True ($status.previous_version -eq "v1.3.0") "rollback version is incorrect"
    $rollbackResult = Handle-UpdateRollback ([pscustomobject]@{})
    Assert-True $rollbackResult.rolled_back "manual rollback did not complete"
    Assert-OriginalFiles $success
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $success.Root "ImageBot.exe"))) "rollback did not remove a newly created launcher"
    Assert-True (-not (Handle-UpdateStatus).rollback_available) "completed rollback is still offered"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $success.Root ".updates") -Filter "ImageBot-update-*.zip" -ErrorAction SilentlyContinue).Count -eq 0) "downloaded update package was not cleaned"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $success.Root ".updates") -Directory -Filter "stage-*" -ErrorAction SilentlyContinue).Count -eq 0) "successful update stage was not cleaned"

    $failure = Initialize-TestCase "replacement-failure"
    $script:AtomicCallCount = 0
    function Set-ProgramFileAtomically([string]$source, [string]$target) {
        $script:AtomicCallCount++
        if ($script:AtomicCallCount -eq 3) { throw "simulated replacement failure" }
        & $script:RealAtomicImpl $source $target
    }
    $failedAsExpected = $false
    try {
        [void](Handle-UpdateApply ([pscustomobject]@{}))
    } catch {
        $failedAsExpected = $_.Exception.Message -match "已自动恢复原版本"
    }
    Assert-True $failedAsExpected "replacement failure did not report automatic recovery"
    Assert-OriginalFiles $failure
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $failure.Root ".updates") -Force -ErrorAction SilentlyContinue).Count -eq 0) "failed update artifacts were not cleaned"
    Set-Item -Path Function:\Set-ProgramFileAtomically -Value $script:RealAtomicImpl

    $hashFailure = Initialize-TestCase "hash-failure"
    $script:FakePackageHash = ("0" * 64)
    $hashRejected = $false
    try {
        [void](Handle-UpdateApply ([pscustomobject]@{}))
    } catch {
        $hashRejected = $_.Exception.Message -match "完整性校验失败"
    }
    Assert-True $hashRejected "invalid package hash was accepted"
    Assert-OriginalFiles $hashFailure
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $hashFailure.Root ".updates") -Force -ErrorAction SilentlyContinue).Count -eq 0) "rejected update artifacts were not cleaned"

    Write-Host "Updater tests passed."
} finally {
    Set-Item -Path Function:\Set-ProgramFileAtomically -Value $script:RealAtomicImpl -ErrorAction SilentlyContinue
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction SilentlyContinue
    }
}
