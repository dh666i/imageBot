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
    return Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json; charset=utf-8" -Body ($body | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec 15
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
    }

    $appDir = Join-Path $testRoot "app"
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root "openai_images_webui_no_python_config.ps1") -Destination $appDir
    Copy-Item -LiteralPath (Join-Path $Root "webui_index.html") -Destination $appDir
    $port = Get-FreeTcpPort
    $configPath = Join-Path $appDir "config.ini"
    @"
OPENAI_BASE_URL=https://api.henng.cn
OPENAI_API_KEY=
OPENAI_IMAGE_MODEL=gpt-image-2
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

    $config = Invoke-RestMethod -Uri "$baseUrl/api/config" -Method Get -TimeoutSec 5
    Assert-True $config.mock "mock mode is not active"
    $page = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing -TimeoutSec 5
    Assert-True ($page.Content -match [regex]::Escape("v" + $appVersionMatch.Groups[1].Value)) "rendered page does not contain the current version"

    $generation = Invoke-TestPost "$baseUrl/api/generate" ([ordered]@{
        prompt = "自动化测试图片"
        model = "gpt-image-2"
        size = "1024x1024"
        n = 2
        mock = $true
    })
    Assert-True $generation.mock "generation did not use mock mode"
    Assert-True (@($generation.images).Count -eq 2) "generation did not return two images"

    $history = Invoke-RestMethod -Uri "$baseUrl/api/history" -Method Get -TimeoutSec 5
    Assert-True (@($history.items).Count -eq 1) "history endpoint did not return the generated request"
    Assert-True ($history.items[0].prompt -eq "自动化测试图片") "history prompt is incorrect"

    $storage = Invoke-RestMethod -Uri "$baseUrl/api/storage" -Method Get -TimeoutSec 5
    Assert-True ([int]$storage.images.files -eq 2) "storage endpoint did not count generated images"
    Assert-True ([int]$storage.history_records -eq 1) "storage endpoint did not count history"

    $updateStatus = Invoke-RestMethod -Uri "$baseUrl/api/update/status" -Method Get -TimeoutSec 5
    Assert-True (-not $updateStatus.rollback_available) "fresh installation unexpectedly offers rollback"

    $cleared = Invoke-TestPost "$baseUrl/api/storage/clear" ([ordered]@{ target = "images" })
    Assert-True ([int]$cleared.storage.images.files -eq 0) "image cleanup did not remove generated images"
    Assert-True ([int]$cleared.storage.history_records -eq 0) "image cleanup did not clear related history"

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
