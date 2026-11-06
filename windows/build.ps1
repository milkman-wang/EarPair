# 在 Windows 上打包 EarPair（需要 .NET 10 SDK，不需要 Visual Studio）。
# 产物自带 .NET 运行时和 Windows App SDK，别的电脑不用另装：
#   dist\EarPair-<版本>-win-x64-setup.exe    安装程序（装了 Inno Setup 6 时；只装给当前用户，不需要管理员）
#   dist\EarPair-<版本>-win-x64.zip          没有 Inno Setup 时打 zip（解压后运行 EarPair\EarPair.exe）
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

# 打包之前检查发布目录：少了 pri 会启动就崩；必须自带运行时；不能混进 AI / ML 组件；
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

# Inno Setup 的编译器：PATH 里的，或者装在默认位置的（GitHub 的 Windows 构建机上有）
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
              "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { Write-Warning '没有找到 Inno Setup 6（ISCC.exe），只打 zip：https://jrsoftware.org/isdl.php' }

foreach ($rid in $Runtimes) {
    $platform = if ($rid -eq 'win-arm64') { 'ARM64' } else { 'x64' }
    # zip 里带一层 EarPair\ 目录，解压时文件不会散一地
    $appDir = Join-Path $work "$rid\EarPair"
    Remove-Item -Recurse -Force (Join-Path $work $rid) -ErrorAction SilentlyContinue

    Write-Host "== $rid：界面版"
    & $dotnet publish (Join-Path $PSScriptRoot 'EarPair.App\EarPair.App.csproj') -c Release -r $rid "-p:Platform=$platform" -o $appDir
    if ($LASTEXITCODE -ne 0) { throw "界面版打包失败（$rid）" }
    Test-Publish $appDir

    if ($iscc) {
        Write-Host "== $rid：安装程序"
        $package = Join-Path $Out "EarPair-$version-$rid-setup.exe"
        Remove-Item -Force $package -ErrorAction SilentlyContinue
        & $iscc "/DAppVersion=$version" "/DArch=$rid" "/DSourceDir=$appDir" "/DOutputDir=$Out" (Join-Path $PSScriptRoot 'installer\EarPair.iss')
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $package)) { throw "安装程序打包失败（$rid）" }
    }
    else {
        $package = Join-Path $Out "EarPair-$version-$rid.zip"
        Remove-Item -Force $package -ErrorAction SilentlyContinue
        New-Zip $appDir $package
    }

    $appSize = (Get-ChildItem $appDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ('   {0}：{1:N0} MB（装好后 {2:N0} MB）' -f (Split-Path -Leaf $package), ((Get-Item $package).Length / 1MB), $appSize)
}
Write-Host "完成：$Out"
