# 雁书 Gaggle · 拉取随包分发的运行时依赖到 app\windows\engine\
#
# 用法（在仓库根目录执行）：
#     powershell -ExecutionPolicy Bypass -File tools\fetch_engine.ps1
#
# 拉到 app\windows\engine\ 后，CMakeLists.txt 会在构建时把它整体装到 <exe>\engine\，
# 安装包（installer.iss）再随包分发。App 端的查找顺序见 app\lib\audio_convert.dart
# 与 app\lib\transcriber.dart：
#     <exe>\engine\ffmpeg.exe  ->  <数据目录>\engine\ffmpeg.exe  ->  系统兜底路径
#
# 需要的文件：
#   ffmpeg.exe + 依赖 dll   音频解码/转码（AAC 归档、导入格式、转写前转 16k）
#   whisper-cli.exe + ggml* 桌面转写引擎
#   diarizer\               声纹分离（PyInstaller 产物）

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $repo 'app\windows\engine'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Write-Host "[1/3] 检查 whisper-cli / ggml / diarizer ..."
$whisper = Join-Path $dest 'whisper-cli.exe'
if (Test-Path $whisper) {
    Write-Host "      已存在，跳过"
} else {
    # 从开发机的 spike 目录搬（仅本地开发便捷，正式分发请自行编译 whisper.cpp）
    $spike = Join-Path $repo 'spikes\s2-whisper\bin\Release'
    if (Test-Path (Join-Path $spike 'whisper-cli.exe')) {
        Copy-Item (Join-Path $spike '*') $dest -Recurse -Force
        Write-Host "      已从 spikes\s2-whisper 复制"
    } else {
        Write-Warn "      未找到 whisper-cli.exe，请手动放入 $dest"
    }
}

$diarizer = Join-Path $dest 'diarizer'
if (-not (Test-Path $diarizer)) {
    $src = Join-Path $repo 'tools\dist\diarizer'
    if (Test-Path $src) {
        Copy-Item $src $dest -Recurse -Force
        Write-Host "      已从 tools\dist 复制 diarizer"
    } else {
        Write-Warn "      未找到 diarizer，请手动放入 $dest\diarizer"
    }
}

Write-Host "[2/3] 检查 ffmpeg ..."
$ff = Join-Path $dest 'ffmpeg.exe'
if (Test-Path $ff) {
    Write-Host "      已存在，跳过"
} else {
    # 必须用 LGPL 构建（不含 x264 等 GPL 组件），否则与项目的 MIT 协议冲突。
    # 这里取 LGPL 共享版：ffmpeg.exe + avcodec/avformat/... dll 一起放到 engine\
    $url = 'https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl-shared.zip'
    $zip = Join-Path $env:TEMP 'ffmpeg-lgpl-shared.zip'
    $tmp = Join-Path $env:TEMP 'ffmpeg-lgpl-extract'

    if (-not (Test-Path $zip)) {
        Write-Host "      下载 $url"
        curl.exe -L --fail --retry 3 -o $zip $url
    } else {
        Write-Host "      使用已下载的缓存 $zip"
    }

    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    # 解压后结构：ffmpeg-master-latest-win64-lgpl-shared\bin\*
    $bin = Get-ChildItem $tmp -Directory -Recurse |
           Where-Object { $_.Name -eq 'bin' } |
           Select-Object -First 1
    if (-not $bin) { throw "压缩包里没找到 bin 目录" }

    Copy-Item (Join-Path $bin.FullName 'ffmpeg.exe') $dest -Force
    # 共享版需要同一目录下的 dll
    Copy-Item (Join-Path $bin.FullName '*.dll') $dest -Force
    Write-Host "      已解压到 $dest"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[3/3] 结果"
Get-ChildItem $dest | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } | Format-Table -AutoSize

$total = (Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("engine 目录合计 {0} MB" -f [math]::Round($total / 1MB, 1))
Write-Host "完成。之后执行 flutter build windows --release 即会自动装进 <exe>\engine\"
