# 打包 Windows 安装程序（Inno Setup）。
# 用法：pwsh app/tool/package_windows.ps1 -Version 2.0.2
# 需要先运行 `flutter build windows --release`，并安装 Inno Setup 6.3 或更高版本。
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$SourceDir = (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\..\dist')
)
$ErrorActionPreference = 'Stop'
$Version = $Version.TrimStart('v', 'V')

$iscc = @(
    if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
    if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe' }
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    throw '找不到 Inno Setup 6 的 ISCC.exe，请先安装 Inno Setup 6。'
}
if (-not (Test-Path $SourceDir)) {
    throw "找不到构建目录：$SourceDir。请先运行 flutter build windows --release。"
}
$SourceDir = (Resolve-Path $SourceDir).Path
if (-not (Test-Path (Join-Path $SourceDir 'CTerminal.exe'))) {
    throw "找不到已构建的 Windows 程序：$SourceDir。请先运行 flutter build windows --release。"
}
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path
$script = Join-Path $PSScriptRoot '..\windows\installer\CTerminal.iss'

& $iscc "/DAppVersion=$Version" "/DBuildDir=$SourceDir" "/DDistDir=$OutputDir" $script
if ($LASTEXITCODE -ne 0) {
    throw "ISCC 失败，退出码 $LASTEXITCODE"
}
Get-ChildItem -Path $OutputDir -Filter "*-$Version-windows-x64-setup.exe" | ForEach-Object { $_.FullName }
