param(
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($env:WINDOWS_CERTIFICATE_BASE64)) {
    Write-Host "Code-signing certificate is not configured; launcher remains unsigned."
    exit 0
}
if ([string]::IsNullOrWhiteSpace($env:WINDOWS_CERTIFICATE_PASSWORD)) {
    throw "WINDOWS_CERTIFICATE_PASSWORD is required when a signing certificate is configured."
}

$tempRoot = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { [IO.Path]::GetTempPath() } else { $env:RUNNER_TEMP }
$certificatePath = Join-Path $tempRoot ("imagebot-signing-{0}.pfx" -f [Guid]::NewGuid().ToString("N"))
[IO.File]::WriteAllBytes($certificatePath, [Convert]::FromBase64String($env:WINDOWS_CERTIFICATE_BASE64))
try {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter signtool.exe -File -Recurse |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($null -eq $signtool) { throw "signtool.exe was not found." }
    & $signtool.FullName sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /f $certificatePath /p $env:WINDOWS_CERTIFICATE_PASSWORD $Path
    if ($LASTEXITCODE -ne 0) { throw "Launcher signing failed." }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne "Valid") { throw "Launcher signature verification failed: $($signature.Status)" }
} finally {
    Remove-Item -LiteralPath $certificatePath -Force -ErrorAction SilentlyContinue
}
