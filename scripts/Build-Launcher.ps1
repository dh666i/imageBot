param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $Root ".tmp-launcher\ImageBot.exe"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$OutputDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$source = Join-Path $Root "launcher\ImageBotLauncher.cs"
$appScript = Join-Path $Root "openai_images_webui_no_python_config.ps1"
if (-not (Test-Path -LiteralPath $source)) { throw "Launcher source was not found: $source" }
$versionLine = Select-String -LiteralPath $appScript -Pattern '^\$AppVersion\s*=\s*"v(\d+)\.(\d+)\.(\d+)"$' | Select-Object -First 1
if ($null -eq $versionLine) { throw "Cannot read AppVersion from $appScript" }
$major = $versionLine.Matches[0].Groups[1].Value
$minor = $versionLine.Matches[0].Groups[2].Value
$patch = $versionLine.Matches[0].Groups[3].Value

$assemblyInfo = Join-Path $OutputDir "ImageBotLauncher.AssemblyInfo.cs"
@"
using System.Reflection;
[assembly: AssemblyTitle("ImageBot")]
[assembly: AssemblyDescription("ImageBot Windows Launcher")]
[assembly: AssemblyCompany("ImageBot")]
[assembly: AssemblyProduct("ImageBot")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("$major.$minor.$patch.0")]
[assembly: AssemblyFileVersion("$major.$minor.$patch.0")]
"@ | Set-Content -LiteralPath $assemblyInfo -Encoding UTF8

$candidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($csc)) { throw "Windows .NET Framework C# compiler was not found." }

try {
    & $csc /nologo /target:winexe /optimize+ /platform:anycpu /out:"$OutputPath" `
        /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll `
        "$source" "$assemblyInfo"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        throw "Launcher compilation failed."
    }
} finally {
    Remove-Item -LiteralPath $assemblyInfo -Force -ErrorAction SilentlyContinue
}

$expectedVersion = "$major.$minor.$patch.0"
$actualVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($OutputPath).FileVersion
if ($actualVersion -ne $expectedVersion) {
    throw "Launcher version mismatch. Expected $expectedVersion, got $actualVersion."
}
Write-Host "Launcher built: $OutputPath"
