param(
    [switch]$SkipUpdaterTests
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ImageBot-Tests-" + [Guid]::NewGuid().ToString("N"))
$server = $null
$launcher = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ImageBot test failed: $Message" }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Invoke-TestPost([string]$url, $body) {
    try {
        return Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json; charset=utf-8" -Body ($body | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec 15
    } catch {
        $text = [string]$_.ErrorDetails.Message
        if ([string]::IsNullOrWhiteSpace($text)) {
            try {
                $response = $_.Exception.Response
                if ($null -ne $response) {
                    $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
            } catch {}
        }
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            try { return ($text | ConvertFrom-Json) } catch {}
        }
        throw
    }
}

function Start-TestLauncher([string]$path, [string]$arguments = "") {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $path
    $start.Arguments = $arguments
    $start.WorkingDirectory = Split-Path -Parent $path
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.EnvironmentVariables["IMAGEBOT_LAUNCHER_NO_BROWSER"] = "1"
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "Launcher process could not be started." }
    return $process
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $powerShellFiles = @(
        "openai_images_webui_no_python_config.ps1",
        "scripts\Build-Launcher.ps1",
        "scripts\Sign-Launcher.ps1",
        "scripts\New-ReleasePackage.ps1",
        "scripts\Test-Updater.ps1",
        "scripts\Test-UpstreamResponses.ps1",
        "scripts\Test-ImageBot.ps1"
    )
    foreach ($relativePath in $powerShellFiles) {
        $path = Join-Path $Root $relativePath
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            $details = ($errors | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" }) -join "; "
            throw "PowerShell syntax check failed for $relativePath`: $details"
        }
    }
    Write-Host "PowerShell syntax checks passed."

    $node = Get-Command node -ErrorAction Stop
    $html = Get-Content -Raw -LiteralPath (Join-Path $Root "webui_index.html") -Encoding UTF8
    $scriptMatch = [regex]::Match($html, '(?s)<script>(.*)</script>')
    if (-not $scriptMatch.Success) { throw "JavaScript block was not found in webui_index.html." }
    $javascriptPath = Join-Path $testRoot "webui.js"
    [IO.File]::WriteAllText($javascriptPath, $scriptMatch.Groups[1].Value, [Text.UTF8Encoding]::new($false))
    & $node.Source --check $javascriptPath
    if ($LASTEXITCODE -ne 0) { throw "JavaScript syntax check failed." }
    Write-Host "JavaScript syntax check passed."

    $launcherPath = Join-Path $testRoot "ImageBot.exe"
    & (Join-Path $PSScriptRoot "Build-Launcher.ps1") -OutputPath $launcherPath
    $appVersionMatch = [regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $Root "openai_images_webui_no_python_config.ps1")), '\$AppVersion\s*=\s*"v(\d+\.\d+\.\d+)"')
    Assert-True $appVersionMatch.Success "application version was not found"
    $launcherVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($launcherPath).FileVersion
    Assert-True ($launcherVersion -eq ($appVersionMatch.Groups[1].Value + ".0")) "launcher version does not match application version"

    if (-not $SkipUpdaterTests) {
        & (Join-Path $PSScriptRoot "Test-Updater.ps1") -Root $Root
        & (Join-Path $PSScriptRoot "Test-UpstreamResponses.ps1") -Root $Root
    }

    $appDir = Join-Path $testRoot "app"
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    [IO.File]::Copy((Join-Path $Root "openai_images_webui_no_python_config.ps1"), (Join-Path $appDir "openai_images_webui_no_python_config.ps1"), $true)
    [IO.File]::Copy((Join-Path $Root "webui_index.html"), (Join-Path $appDir "webui_index.html"), $true)
    Assert-True (Test-Path -LiteralPath (Join-Path $appDir "openai_images_webui_no_python_config.ps1")) "test server script was not copied"
    $port = Get-FreeTcpPort
    $configPath = Join-Path $appDir "config.ini"
    @"
OPENAI_BASE_URL=https://www.chichiapi.cn/
OPENAI_API_KEY=customer-local-secret
OPENAI_IMAGE_MODEL=gpt-image-2.5-flare
IMAGE_WEBUI_HOST=127.0.0.1
IMAGE_WEBUI_PORT=$port
IMAGE_WEBUI_TIMEOUT=240
IMAGE_WEBUI_NO_BROWSER=1
IMAGE_WEBUI_SAVE_OUTPUTS=1
IMAGE_WEBUI_OUTPUT_DIR=outputs
IMAGE_WEBUI_LOG_DIR=logs
IMAGE_WEBUI_MAX_UPLOAD_MB=10
IMAGE_WEBUI_MAX_BODY_MB=20
IMAGE_WEBUI_MOCK=1
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

    $stdoutPath = Join-Path $testRoot "server.stdout.log"
    $stderrPath = Join-Path $testRoot "server.stderr.log"
    $server = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $appDir "openai_images_webui_no_python_config.ps1"), "-ConfigPath", $configPath) `
        -WorkingDirectory $appDir -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

    $baseUrl = "http://127.0.0.1:$port"
    $health = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Uri "$baseUrl/api/health" -Method Get -TimeoutSec 2
            if ($health.ok) { break }
        } catch {
            if ($server.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    if ($null -eq $health -or -not $health.ok) {
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
        throw "Mock server did not become ready. $stderr"
    }

    Assert-True ($health.config.version -eq ("v" + $appVersionMatch.Groups[1].Value)) "health endpoint returned the wrong version"
    Assert-True ([int]$health.config.timeout_sec -eq 240) "configured timeout is not 240 seconds"
    Assert-True ([int]$health.config.pid -eq $server.Id) "health endpoint returned the wrong process id"
    Assert-True ($health.config.base_url -eq "https://www.chichiapi.cn") "default base URL was not normalized to chichiapi.cn"
    Assert-True ($health.config.model -eq "gpt-image-2.5-flare") "fresh configuration did not default to GPT Image 2.5 Flare"

    $config = Invoke-RestMethod -Uri "$baseUrl/api/config" -Method Get -TimeoutSec 5
    Assert-True $config.mock "mock mode is not active"
    Assert-True $config.has_api_key "test customer key was not loaded"
    Assert-True (@($config.model_presets) -contains "gpt-image-2.5-flare") "GPT Image 2.5 Flare model preset is missing"
    Assert-True (@($config.model_presets) -contains "gpt-image-2.5-sunburst") "GPT Image 2.5 Sunburst model preset is missing"
    Assert-True ($config.request_mode -eq "auto") "default request mode is incorrect"
    $savedConfig = Invoke-TestPost "$baseUrl/api/config/save" ([ordered]@{
        base_url = "https://www.chichiapi.cn/"
        api_key = ""
        model = "gpt-image-2.5-flare"
        timeout_sec = 240
        mock = $true
        request_mode = "basic"
    })
    Assert-True ($savedConfig.config.request_mode -eq "basic") "saved request mode was not applied immediately"
    Assert-True $savedConfig.config.has_api_key "blank key field overwrote the saved customer key"
    [void](Invoke-TestPost "$baseUrl/api/config/save" ([ordered]@{
        base_url = "https://www.chichiapi.cn/"
        api_key = ""
        model = "gpt-image-2"
        timeout_sec = 240
        mock = $true
        request_mode = "auto"
    }))
    $page = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing -TimeoutSec 5
    Assert-True ($page.Content -match [regex]::Escape("v" + $appVersionMatch.Groups[1].Value)) "rendered page does not contain the current version"
    Assert-True ($page.Content -match 'id="modelPreset"' -and $page.Content -match 'id="requestMode"') "model compatibility controls are missing"

    $generation = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "自动化测试图片"
        model = "gpt-image-2"
        size = "1024x1024"
        n = 2
        mock = $true
        request_id = "test-request-id-001"
    })
    Assert-True $generation.mock "generation did not use mock mode"
    Assert-True (@($generation.images).Count -eq 2) "generation did not return two images"

    $replayed = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "自动化测试图片"
        model = "gpt-image-2"
        size = "1024x1024"
        n = 2
        mock = $true
        request_id = "test-request-id-001"
    })
    Assert-True $replayed.replayed "duplicate request was not replayed from history"
    Assert-True (@($replayed.images).Count -eq 2) "replayed request did not return saved images"

    $basic = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "基础兼容模式测试"
        model = "gpt-image-2.5-flare"
        size = "1024x1024"
        n = 1
        quality = "high"
        background = "transparent"
        output_format = "webp"
        request_mode = "basic"
        mock = $true
        request_id = "test-request-id-basic"
    })
    Assert-True ($basic.request.model -eq "gpt-image-2.5-flare") "GPT Image 2.5 model was not forwarded"
    Assert-True ($null -eq $basic.request.quality -and $null -eq $basic.request.background -and $null -eq $basic.request.output_format) "basic mode kept optional image fields"

    $safeFailure = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "安全降级重试测试"
        model = "gpt-image-2.5-flare"
        size = "1024x1024"
        quality = "max"
        mock_error = "Unsupported parameter: quality"
        mock = $true
        request_id = "test-request-safe-001"
    })
    Assert-True ($null -ne $safeFailure.error) "mock unsupported-parameter response was not returned"
    Assert-True $safeFailure.retry_safe "unsupported image parameter was not marked safe to retry"
    $safeHistory = Invoke-RestMethod -Uri "$baseUrl/api/requests/test-request-safe-001" -Method Get -TimeoutSec 5
    Assert-True ($safeHistory.request.status -eq "error") "safe retry failure was not finalized in history"

    $unsafeFailure = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "不可安全重发测试"
        model = "gpt-image-2.5-flare"
        size = "1024x1024"
        mock_error = "account rejected"
        mock = $true
        request_id = "test-request-unsafe-001"
    })
    Assert-True ($null -ne $unsafeFailure.error) "mock unsafe failure was not returned"
    Assert-True (-not $unsafeFailure.retry_safe) "ordinary API error was incorrectly marked retry-safe"
    $unsafeDuplicate = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "不可安全重发测试"
        model = "gpt-image-2.5-flare"
        size = "1024x1024"
        mock = $true
        request_id = "test-request-unsafe-001"
    })
    Assert-True $unsafeDuplicate.replayed "unsafe duplicate request was not blocked"
    Assert-True ($null -ne $unsafeDuplicate.error) "unsafe duplicate lost the original error"
    $safeRetry = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "安全降级重试测试"
        model = "gpt-image-2.5-flare"
        size = "1024x1024"
        request_mode = "basic"
        mock = $true
        request_id = "test-request-safe-001"
    })
    Assert-True $safeRetry.mock "safe parameter retry did not complete"
    $safeRetryHistory = Invoke-RestMethod -Uri "$baseUrl/api/requests/test-request-safe-001" -Method Get -TimeoutSec 5
    Assert-True ($safeRetryHistory.request.status -eq "success") "safe retry did not finalize its history row"

    $referenceData = "data:image/png;base64,$([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('reference image bytes')))"
    $edit = Invoke-TestPost "$baseUrl/api/edit" ([ordered]@{
        prompt = "把背景换成白色，主体保持不变"
        model = "gpt-image-2.5-sunburst"
        size = "1024x1024"
        images = @($referenceData)
        parent_request_id = "test-request-id-001"
        request_id = "test-request-edit-001"
        mock = $true
    })
    Assert-True $edit.mock "reference edit did not complete"
    $editHistory = Invoke-RestMethod -Uri "$baseUrl/api/requests/test-request-edit-001" -Method Get -TimeoutSec 5
    Assert-True ($editHistory.request.revision -eq 2) "edit history revision is incorrect"
    Assert-True ($editHistory.request.root_request_id -eq "test-request-id-001") "edit history root request was not linked"
    Assert-True (@($editHistory.request.input_images).Count -eq 1) "reference image was not saved with the history"

    $history = Invoke-RestMethod -Uri "$baseUrl/api/history" -Method Get -TimeoutSec 5
    Assert-True (@($history.items).Count -eq 5) "history endpoint did not keep one row per request and revision"
    $historyItem = @($history.items | Where-Object { $_.prompt -eq "自动化测试图片" } | Select-Object -First 1)
    Assert-True ($historyItem.Count -eq 1) "history prompt is incorrect"

    $storage = Invoke-RestMethod -Uri "$baseUrl/api/storage" -Method Get -TimeoutSec 5
    Assert-True ([int]$storage.images.files -eq 6) "storage endpoint did not count generated and input images"
    Assert-True ([int]$storage.history_records -eq 5) "storage endpoint did not count history"

    $export = Invoke-RestMethod -Uri "$baseUrl/api/history/export" -Method Get -TimeoutSec 5
    Assert-True (@($export.records).Count -eq 5) "history export omitted records"
    Assert-True (-not ($export | ConvertTo-Json -Depth 50 -Compress).Contains("customer-secret")) "history export exposed a secret"

    [void](Invoke-TestPost "$baseUrl/api/config/save" ([ordered]@{ base_url = "https://www.chichiapi.cn/"; api_key = ""; model = "gpt-image-2.5-flare"; timeout_sec = 240; mock = $false; request_mode = "auto" }))
    $unsavedDemo = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{ prompt = "未保存演示模式测试"; model = "gpt-image-2.5-flare"; size = "1024x1024"; mock = $true; request_id = "test-request-unsaved-mock" })
    Assert-True $unsavedDemo.mock "per-request demo mode did not override the saved setting"
    [void](Invoke-TestPost "$baseUrl/api/config/save" ([ordered]@{ base_url = "https://www.chichiapi.cn/"; api_key = ""; model = "gpt-image-2.5-flare"; timeout_sec = 240; mock = $true; request_mode = "auto" }))

    $emptyResult = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "空结果状态测试"
        model = "gpt-image-2.5-flare"
        size = "1024x1024"
        mock_empty_images = $true
        mock = $true
        request_id = "test-request-empty-001"
    })
    Assert-True $emptyResult.outcome_unknown "empty image response was not marked as unknown"
    $emptyHistory = Invoke-RestMethod -Uri "$baseUrl/api/requests/test-request-empty-001" -Method Get -TimeoutSec 5
    Assert-True ($emptyHistory.request.status -eq "unknown") "empty image response was not recorded as unknown"
    $emptyReplay = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{ prompt = "空结果状态测试"; model = "gpt-image-2.5-flare"; size = "1024x1024"; mock = $true; request_id = "test-request-empty-001" })
    Assert-True $emptyReplay.pending "empty/unknown request was automatically repeated"

    $allDataClear = Invoke-TestPost "$baseUrl/api/storage/clear" ([ordered]@{ target = "all" })
    Assert-True ([int]$allDataClear.storage.images.files -eq 0) "clear-all did not remove output and reference images"
    Assert-True ([int]$allDataClear.storage.history_records -eq 0) "clear-all did not remove history"
    Assert-True ([int]$allDataClear.storage.logs.files -eq 0) "clear-all did not remove logs"
    $afterClearConfig = Invoke-RestMethod -Uri "$baseUrl/api/config" -Method Get -TimeoutSec 5
    Assert-True $afterClearConfig.has_api_key "clear-all deleted the customer's API key"

    $updateStatus = Invoke-RestMethod -Uri "$baseUrl/api/update/status" -Method Get -TimeoutSec 5
    Assert-True (-not $updateStatus.rollback_available) "fresh installation unexpectedly offers rollback"

    $shutdown = Invoke-TestPost "$baseUrl/api/shutdown" ([ordered]@{})
    Assert-True $shutdown.ok "shutdown endpoint did not confirm exit"
    Assert-True ($server.WaitForExit(10000)) "server did not exit after shutdown request"
    Write-Host "API smoke tests passed."

    $packagedLauncher = Join-Path $appDir "ImageBot.exe"
    Copy-Item -LiteralPath $launcherPath -Destination $packagedLauncher -Force
    $launcher = Start-TestLauncher $packagedLauncher
    $launcherHealth = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try {
            $launcherHealth = Invoke-RestMethod -Uri "$baseUrl/api/health" -Method Get -TimeoutSec 2
            if ($launcherHealth.ok) { break }
        } catch {
            if ($launcher.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    Assert-True ($null -ne $launcherHealth -and $launcherHealth.ok) "launcher did not start the local service"

    $duplicate = Start-TestLauncher $packagedLauncher
    Assert-True ($duplicate.WaitForExit(5000)) "duplicate launcher instance did not exit"
    Assert-True (-not $launcher.HasExited) "duplicate launch stopped the primary launcher"

    $exitCommand = Start-TestLauncher $packagedLauncher "--exit"
    Assert-True ($exitCommand.WaitForExit(5000)) "launcher exit command did not finish"
    Assert-True ($launcher.WaitForExit(10000)) "primary launcher did not exit after control command"
    $serviceStopped = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        try {
            [void](Invoke-RestMethod -Uri "$baseUrl/api/health" -Method Get -TimeoutSec 1)
            Start-Sleep -Milliseconds 200
        } catch {
            $serviceStopped = $true
            break
        }
    }
    Assert-True $serviceStopped "launcher exit did not stop the local service"
    Write-Host "Launcher process tests passed."
} finally {
    if ($null -ne $launcher -and -not $launcher.HasExited) {
        try {
            $exitCommand = Start-TestLauncher (Join-Path $appDir "ImageBot.exe") "--exit"
            [void]$exitCommand.WaitForExit(2000)
            [void]$launcher.WaitForExit(3000)
        } catch {
            try { $launcher.Kill() } catch {}
        }
    }
    if ($null -ne $server -and -not $server.HasExited) {
        try { [void](Invoke-TestPost "http://127.0.0.1:$port/api/shutdown" ([ordered]@{})) } catch {}
        try { if (-not $server.WaitForExit(2500)) { $server.Kill() } } catch {}
    }
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction SilentlyContinue
    }
}
