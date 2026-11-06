# 在 Windows 上打包 EarPair（需要 .NET 10 SDK，不需要 Visual Studio）。
# 产物都自带 .NET 运行时和 Windows App SDK，复制到别的电脑解压就能用：
#   dist\EarPair-<版本>-win-x64.zip          WinUI 界面版（解压后运行 EarPair\EarPair.exe）
#   dist\EarPair.Sender-<版本>-win-x64.exe   命令行版（单个文件）
# 用法：powershell -ExecutionPolicy Bypass -File windows\build.ps1 [-Runtimes win-x64,win-arm64] [-Out 目录]
param(
    [string[]]$Runtimes = @('win-x64', 'win-arm64'),
    [string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

# 找一个装了 .NET 10 SDK 的 dotnet：先看 PATH 里的，没有 10.x 再看用户目录里的
function Test-Sdk10([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return $false }
    return [bool](& $path --list-sdks 2>$null | Where-Object { $_ -match '^10\.' })
}
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not (Test-Sdk10 $dotnet)) { $dotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe' }
if (-not (Test-Sdk10 $dotnet)) { throw '找不到 .NET 10 SDK，请先安装：https://dotnet.microsoft.com/download/dotnet/10.0' }

# 打进 zip 之前检查发布目录：少了 pri 会启动就崩；必须自带运行时；不能混进 AI / ML 组件；
# 中文界面的卫星程序集不能在清理语言目录时被删掉
function Test-Publish([string]$dir) {
    $problems = @()
    if (-not (Get-ChildItem $dir -Filter *.pri)) { $problems += '没有 .pri（缺 EnableMsixTooling，启动会崩）' }
    foreach ($name in 'EarPair.exe', 'hostfxr.dll', 'coreclr.dll', 'Microsoft.UI.Xaml.dll',
                      'zh-Hans\EarPair.resources.dll', 'zh-Hans\EarPair.Sender.Core.resources.dll') {
        if (-not (Test-Path (Join-Path $dir $name))) { $problems += "缺 $name" }
    }
    if (Get-ChildItem $dir -Recurse -Include onnxruntime.dll, 'Microsoft.Windows.AI*.dll') { $problems += '混进了 AI / ML 组件' }
    $config = Join-Path $dir 'EarPair.runtimeconfig.json'
    if (-not (Test-Path $config) -or -not (Select-String -Path $config -Pattern 'includedFrameworks' -Quiet)) {
        $problems += '不是自包含（runtimeconfig 里没有 includedFrameworks）'
    }
    if ($problems) { throw ("发布目录有问题：$dir`n  " + ($problems -join "`n  ")) }
}

[xml]$project = Get-Content (Join-Path $PSScriptRoot 'EarPair.App\EarPair.App.csproj')
$version = ($project.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1).Version
$work = Join-Path $env:TEMP 'earpair-publish'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# 把目录连同目录名一起打成 zip。条目路径一律用“/”：Windows PowerShell 5.1 的 Compress-Archive 和 ZipFile
# 都会写反斜杠（不合 zip 规范，别的解压工具会把它当成文件名的一部分）
function New-Zip([string]$dir, [string]$zip) {
    $base = Split-Path -Parent $dir
    $stream = [IO.File]::Open($zip, [IO.FileMode]::Create)
    $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem $dir -Recurse -File) {
            $name = $file.FullName.Substring($base.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $name,
                [IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}
New-Item -ItemType Directory -Force $Out | Out-Null

foreach ($rid in $Runtimes) {
    $platform = if ($rid -eq 'win-arm64') { 'ARM64' } else { 'x64' }
    # zip 里带一层 EarPair\ 目录，解压时文件不会散一地
    $appDir = Join-Path $work "$rid\EarPair"
    $cliDir = Join-Path $work "cli-$rid"
    Remove-Item -Recurse -Force (Join-Path $work $rid), $cliDir -ErrorAction SilentlyContinue

    Write-Host "== $rid：界面版"
    & $dotnet publish (Join-Path $PSScriptRoot 'EarPair.App\EarPair.App.csproj') -c Release -r $rid "-p:Platform=$platform" -o $appDir
    if ($LASTEXITCODE -ne 0) { throw "界面版打包失败（$rid）" }
    Test-Publish $appDir

    Write-Host "== $rid：命令行版"
    & $dotnet publish (Join-Path $PSScriptRoot 'EarPair.Sender\EarPair.Sender.csproj') -c Release -r $rid -o $cliDir
    if ($LASTEXITCODE -ne 0) { throw "命令行版打包失败（$rid）" }

    $zip = Join-Path $Out "EarPair-$version-$rid.zip"
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    New-Zip $appDir $zip
    Copy-Item (Join-Path $cliDir 'EarPair.Sender.exe') (Join-Path $Out "EarPair.Sender-$version-$rid.exe") -Force

    $appSize = (Get-ChildItem $appDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ('   {0}：{1:N0} MB（解压后 {2:N0} MB）' -f (Split-Path -Leaf $zip), ((Get-Item $zip).Length / 1MB), $appSize)
}
Write-Host "完成：$Out"
