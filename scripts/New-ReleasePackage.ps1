param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $Root "dist"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

if ($Tag -notmatch '^v\d+\.\d+\.\d+$') {
    throw "Release tag must look like v1.2.3. Current: $Tag"
}
$versionLine = Select-String -LiteralPath (Join-Path $Root "openai_images_webui_no_python_config.ps1") -Pattern '^\$AppVersion\s*=\s*"(v\d+\.\d+\.\d+)"$' | Select-Object -First 1
if ($null -eq $versionLine) { throw "Cannot read AppVersion from the application script." }
$appVersion = $versionLine.Matches[0].Groups[1].Value
if ($appVersion -ne $Tag) {
    throw "Application version $appVersion does not match release tag $Tag."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stage = Join-Path $OutputDirectory (".stage-" + [Guid]::NewGuid().ToString("N"))
$zipName = "ImageBot-$Tag.zip"
$zipPath = Join-Path $OutputDirectory $zipName
$checksumPath = "$zipPath.sha256"

try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $files = @(
        "openai_images_webui_no_python_config.ps1",
        "webui_index.html",
        "README.md",
        "LICENSE",
        "config.example.ini",
        "启动图片WebUI-独立Config版.bat"
    )
    foreach ($file in $files) {
        $source = Join-Path $Root $file
        if (-not (Test-Path -LiteralPath $source)) { throw "Required release file is missing: $file" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $file) -Force
    }

    Copy-Item -LiteralPath (Join-Path $Root "config.example.ini") -Destination (Join-Path $stage "config.ini") -Force
    & (Join-Path $PSScriptRoot "Build-Launcher.ps1") -OutputPath (Join-Path $stage "ImageBot.exe")
    & (Join-Path $PSScriptRoot "Sign-Launcher.ps1") -Path (Join-Path $stage "ImageBot.exe")

    @"
ImageBot $Tag 使用说明

1. 完整解压压缩包。
2. 双击 ImageBot.exe。
3. 第一次打开时填写接口密钥并保存。
4. 输入想生成的画面，也可以先上传参考图片，然后点击“生成”。

程序运行后会显示在 Windows 右下角托盘。双击托盘图标可重新打开页面，右键可重新启动或退出。
如果 ImageBot.exe 无法运行，可使用“启动图片WebUI-独立Config版.bat”备用启动。

本发布包不包含接口密钥、历史记录、日志或已生成图片。
"@ | Set-Content -LiteralPath (Join-Path $stage "发布说明.txt") -Encoding UTF8

    $configKey = Get-Content -LiteralPath (Join-Path $stage "config.ini") -Encoding UTF8 |
        Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } |
        Select-Object -First 1
    if ($configKey -notmatch '^\s*OPENAI_API_KEY\s*=\s*$') {
        throw "Release config.ini must contain a blank OPENAI_API_KEY."
    }

    $textExtensions = @(".ps1", ".html", ".md", ".ini", ".bat", ".txt")
    $keyHits = New-Object System.Collections.ArrayList
    foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
        if ($textExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
            $lineNumber++
            if ($line -match 'sk-[A-Za-z0-9_-]{12,}') {
                [void]$keyHits.Add("$($file.Name):$lineNumber")
            }
        }
    }
    if ($keyHits.Count -gt 0) {
        throw "Possible API key found in release files: $($keyHits -join ', ')"
    }

    $launcherVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $stage "ImageBot.exe")).FileVersion
    $expectedLauncherVersion = $Tag.TrimStart("v") + ".0"
    if ($launcherVersion -ne $expectedLauncherVersion) {
        throw "Launcher version mismatch. Expected $expectedLauncherVersion, got $launcherVersion."
    }

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force

    $verify = Join-Path $OutputDirectory (".verify-" + [Guid]::NewGuid().ToString("N"))
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $verify -Force
        foreach ($required in @($files + @("config.ini", "ImageBot.exe", "发布说明.txt"))) {
            if (-not (Test-Path -LiteralPath (Join-Path $verify $required))) {
                throw "Release archive is missing: $required"
            }
        }
    } finally {
        Remove-Item -LiteralPath $verify -Recurse -Force -ErrorAction SilentlyContinue
    }

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $zipName" | Set-Content -LiteralPath $checksumPath -Encoding ASCII
    Write-Host "Release archive: $zipPath"
    Write-Host "SHA-256: $hash"
    [pscustomobject]@{ ZipPath = $zipPath; ChecksumPath = $checksumPath; Sha256 = $hash; Version = $Tag }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
