<#
.SYNOPSIS
    雁书 Gaggle · 一键推送到 GitHub。

.DESCRIPTION
    按顺序做六件事，任何一步失败就停下并给出人话提示：

      1. 环境检查：git 是否安装、提交身份是否配置
      2. 安全闸门：确认 .gitignore 生效（不会把模型、音频、数据库、API Key 传上去）
                   单文件 > MaxFileMB 直接中止（GitHub 单文件上限 100MB）
      3. 本地提交：git init -b main（若尚未初始化）→ git add -A → git commit
      4. 创建远程仓库并推送
           装了 gh 且已登录 → gh repo create --push（顺手写 Description + Topics）
           否则            → 打印网页建仓地址，等你建好后重跑本脚本
      5. 替换占位符：把 README/CHANGELOG/SECURITY 等文件里的 OWNER/REPO
                     换成真实的 用户名/仓库名，并补一次提交（否则徽章是坏图）
      6. 打 tag（可选）：-Tag v0.1.0 时自动创建并推送 tag

.PARAMETER RepoName
    远程仓库名，默认 gaggle-voice-notes。
    GitHub 上叫 gaggle 的仓库已有多个，加 voice-notes 更利于被搜到。
    想要短名就传 -RepoName gaggle。

.PARAMETER Visibility
    public / private，默认 public。

.PARAMETER Owner
    GitHub 用户名或组织名。留空 = 当前 gh 登录账号 / 从 origin 推断。

.PARAMETER RemoteUrl
    已在网页手动建好仓库时，直接给地址，脚本只负责 add remote + push。

.PARAMETER GitUserName
    本机没配 git 身份时，用这个值写入**当前仓库**（不是全局）。

.PARAMETER GitEmail
    同上，配合 -GitUserName 使用。

.PARAMETER Tag
    推送完成后打一个 tag 并推送，例如 v0.1.0。留空则不打。

.PARAMETER DryRun
    只打印将要执行的命令，不真的执行（第一次用建议先跑一遍）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\push-to-github.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\push-to-github.ps1

.EXAMPLE
    # 仓库已在网页建好，只想推 + 打 tag
    powershell -ExecutionPolicy Bypass -File scripts\push-to-github.ps1 `
        -RemoteUrl https://github.com/me/gaggle-voice-notes.git -Tag v0.1.0

.NOTES
    必须在仓库根目录的 scripts\ 下执行；脚本会自动定位仓库根。
#>
[CmdletBinding()]
param(
    [string]$RepoName = 'gaggle-voice-notes',
    [ValidateSet('public', 'private')][string]$Visibility = 'public',
    [string]$Owner = '',
    [string]$RemoteUrl = '',
    [string]$Description = 'Local-first voice & note vault: record, transcribe offline, search any sentence, ask your own AI agent. No account, no cloud.',
    [string]$CommitMessage = 'chore: initial commit',
    [string[]]$Topics = @(
        'local-first', 'privacy', 'speech-to-text', 'whisper', 'voice-notes',
        'meeting-notes', 'offline', 'self-hosted', 'a2a', 'flutter',
        'desktop', 'android', 'sqlite', 'ollama'
    ),
    [int]$MaxFileMB = 95,
    [string]$GitUserName = '',
    [string]$GitEmail = '',
    [string]$Tag = '',
    [switch]$SkipSizeCheck,
    [switch]$SkipPlaceholderFix,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:StepNo = 0

# ---------------------------------------------------------------- 输出小工具
function Write-Step([string]$msg) {
    $script:StepNo++
    Write-Host ''
    Write-Host ("[{0}] {1}" -f $script:StepNo, $msg) -ForegroundColor Cyan
}
function Write-Ok([string]$msg) { Write-Host "     OK  $msg" -ForegroundColor Green }
function Write-Note([string]$msg) { Write-Host "     ..  $msg" -ForegroundColor DarkGray }
function Write-Warn2([string]$msg) { Write-Host "     !!  $msg" -ForegroundColor Yellow }
function Write-Bad([string]$msg) { Write-Host "     XX  $msg" -ForegroundColor Red }

function Format-Args([string[]]$items) {
    ($items | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [switch]$AllowFail,
        [switch]$Quiet
    )
    $shown = "$Exe $(Format-Args $Arguments)"
    if ($DryRun) {
        Write-Host "     DRY $shown" -ForegroundColor DarkGray
        return [pscustomobject]@{ ExitCode = 0; Output = ''; Shown = $shown }
    }
    # 注意：git 会把进度/提示写到 stderr，PS 5.1 在 Stop 策略下会把重定向后的
    # stderr 当成终止错误（例如 "Everything up-to-date"），所以这里临时降级。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($null -eq $code) { $code = 0 }
    if ($out -and -not $Quiet) {
        $out | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "命令执行失败（exit $code）：$shown"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (($out | Out-String).Trim()); Shown = $shown }
}

function Fail([string]$msg, [string]$hint) {
    Write-Bad $msg
    if ($hint) { Write-Host ''; Write-Host $hint -ForegroundColor Yellow }
    Write-Host ''
    exit 1
}

# ---------------------------------------------------------------- 定位仓库根
$Root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $Root 'app\pubspec.yaml'))) {
    Fail '没找到 app\pubspec.yaml，脚本似乎不在 《computer ASR》 项目里。' `
        '请把本脚本放在仓库根的 scripts\ 目录下再运行。'
}
if (-not (Test-Path (Join-Path $Root 'README.md'))) {
    Fail '仓库根缺少 README.md。' 'GitHub 首页没有 README 等于没有门面，先补上再推。'
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  雁书 Gaggle · 上传到 GitHub' -ForegroundColor Cyan
Write-Host ("  仓库根：{0}" -f $Root) -ForegroundColor Cyan
Write-Host ("  目标仓库：{0}" -f $RepoName) -ForegroundColor Cyan
if ($DryRun) { Write-Host '  模式：DryRun（只打印，不执行）' -ForegroundColor Yellow }
Write-Host '============================================================' -ForegroundColor Cyan

Set-Location $Root

# ---------------------------------------------------------------- 1. 环境检查
Write-Step '检查 git 与提交身份'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail '没有找到 git。' '先安装 Git for Windows：https://git-scm.com/download/win ，装完重开终端。'
}
Write-Ok ("git {0}" -f (Invoke-Tool git @('--version') -Quiet).Output)

if ($GitUserName) {
    Invoke-Tool git @('config', 'user.name', $GitUserName) | Out-Null
    Write-Note ("已为当前仓库设置 user.name = {0}" -f $GitUserName)
}
if ($GitEmail) {
    Invoke-Tool git @('config', 'user.email', $GitEmail) | Out-Null
    Write-Note ("已为当前仓库设置 user.email = {0}" -f $GitEmail)
}

$userName = (Invoke-Tool git @('config', 'user.name') -AllowFail -Quiet).Output
$userMail = (Invoke-Tool git @('config', 'user.email') -AllowFail -Quiet).Output
if (-not $userName -or -not $userMail) {
    if ($DryRun) {
        Write-Warn2 'DryRun 模式读不到 git 身份（真实运行时会在这里中止）'
        $userName = '<未设置>'
        $userMail = '<未设置>'
    }
    else {
        Fail 'git 还没配置提交身份（user.name / user.email）。' @"
两种做法，任选其一后重跑本脚本：

  A. 只给这个仓库配（推荐）
     powershell -ExecutionPolicy Bypass -File scripts\push-to-github.ps1 -GitUserName "Your Name" -GitEmail "you@example.com"

  B. 全局配置
     git config --global user.name  "Your Name"
     git config --global user.email "you@example.com"
"@
    }
}
Write-Ok ("commit 身份：{0} <{1}>" -f $userName, $userMail)

# ---------------------------------------------------------------- 2. 安全闸门
Write-Step '安全检查（.gitignore / 密钥 / 大文件）'

$ignore = Join-Path $Root '.gitignore'
if (-not (Test-Path $ignore)) {
    Fail '仓库根缺少 .gitignore。' '没有它会把 models（1GB+）、build（5GB+）、workspace 里的音频和数据库一起传上去。'
}
Write-Ok '.gitignore 存在'

# 没有 .git 时先 init，这样下面的 git check-ignore 才有意义
if (-not (Test-Path (Join-Path $Root '.git'))) {
    Write-Note '尚未初始化 git 仓库，先 git init -b main'
    Invoke-Tool git @('init', '-b', 'main') | Out-Null
}
else {
    Write-Ok '已有 .git 仓库'
}

# 绝不能入库的路径
$mustIgnore = @(
    'workspace',
    'dist',
    'spikes',
    '_src',
    'app/build',
    'app/.dart_tool',
    'app/windows/engine',
    'tools/agent_config.json'
)
foreach ($rel in $mustIgnore) {
    if (-not (Test-Path (Join-Path $Root $rel))) { continue }
    $r = Invoke-Tool git @('check-ignore', '-q', '--', $rel) -AllowFail -Quiet
    if ($r.ExitCode -ne 0) {
        if ($rel -eq 'tools/agent_config.json') {
            Fail 'tools/agent_config.json 没有被忽略，里面可能有你的 API Key。' `
                '请在 .gitignore 里确认有这一行：tools/agent_config.json'
        }
        Write-Warn2 ("{0} 没有被 .gitignore 忽略，可能会被上传" -f $rel)
    }
    else {
        Write-Ok ("已忽略 {0}" -f $rel)
    }
}

if (-not $SkipSizeCheck) {
    Write-Note '扫描将要提交的文件体积（已按 .gitignore 过滤）'
    $list = (Invoke-Tool git @('ls-files', '-o', '--exclude-standard', '-z') -Quiet).Output
    $files = @($list -split "`0" | Where-Object { $_ })
    if ($files.Count -eq 0) {
        Write-Note '没有未跟踪的新文件（可能已全部提交过）'
    }
    else {
        $sizes = foreach ($f in $files) {
            $full = Join-Path $Root $f
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                [pscustomobject]@{
                    Path = $f
                    MB   = [math]::Round((Get-Item -LiteralPath $full).Length / 1MB, 2)
                }
            }
        }
        $sizes = @($sizes)

        $tooBig = @($sizes | Where-Object { $_.MB -ge $MaxFileMB } | Sort-Object MB -Descending)
        if ($tooBig.Count -gt 0) {
            Write-Bad ("有 {0} 个文件超过 {1} MB，GitHub 会直接拒绝（单文件上限 100MB）：" -f $tooBig.Count, $MaxFileMB)
            $tooBig | Select-Object -First 15 | ForEach-Object { Write-Host ("         {0,8} MB  {1}" -f $_.MB, $_.Path) -ForegroundColor Red }
            Fail '中止上传。' @"
把这些路径补进 .gitignore（或改用 Git LFS / GitHub Release 发布二进制），再重跑本脚本。
确认要强行继续（不推荐）可加 -SkipSizeCheck。
"@
        }

        $totalMB = [math]::Round((($sizes | Measure-Object MB -Sum).Sum), 1)
        Write-Ok ("待提交 {0} 个文件，合计 {1} MB" -f $sizes.Count, $totalMB)
        if ($totalMB -gt 300) {
            Write-Warn2 '仓库偏大，clone 会很慢。模型/引擎/安装包应该放 GitHub Release，而不是仓库里。'
        }
    }
}

# ---------------------------------------------------------------- 3. 本地提交
Write-Step '本地提交'

Invoke-Tool git @('add', '-A') | Out-Null

$staged = (Invoke-Tool git @('diff', '--cached', '--name-only') -Quiet).Output
$hasCommit = ((Invoke-Tool git @('rev-parse', '--verify', 'HEAD') -AllowFail -Quiet).ExitCode -eq 0)

if (-not $staged) {
    if ($hasCommit) {
        Write-Ok '没有新改动，跳过 commit'
    }
    else {
        Fail '没有任何文件被加入暂存区。' '检查 .gitignore 是否把源码也一起忽略了（比如写了 * 或 app/）。'
    }
}
else {
    Invoke-Tool git @('commit', '-m', $CommitMessage) | Out-Null
    Write-Ok 'commit 完成'
}

$branch = 'main'
$b = Invoke-Tool git @('rev-parse', '--abbrev-ref', 'HEAD') -AllowFail -Quiet
if ($b.ExitCode -eq 0 -and $b.Output -and $b.Output -ne 'HEAD') { $branch = $b.Output }
Write-Note ("当前分支：{0}" -f $branch)

# ---------------------------------------------------------------- 4. 远程与推送
Write-Step '创建远程仓库并推送'

$originOut = Invoke-Tool git @('remote', 'get-url', 'origin') -AllowFail -Quiet
$hasOrigin = ($originOut.ExitCode -eq 0 -and $originOut.Output)
if ($hasOrigin) { Write-Note ("已有 origin：{0}" -f $originOut.Output) }

$pushed = $false

if ($hasOrigin) {
    Invoke-Tool git @('push', '-u', 'origin', $branch) | Out-Null
    Write-Ok '推送完成'
    $pushed = $true
}
elseif ($RemoteUrl) {
    Invoke-Tool git @('remote', 'add', 'origin', $RemoteUrl) | Out-Null
    Invoke-Tool git @('push', '-u', 'origin', $branch) | Out-Null
    Write-Ok '推送完成'
    $pushed = $true
}
else {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    $ghReady = $false
    if ($gh) {
        $auth = Invoke-Tool gh @('auth', 'status') -AllowFail -Quiet
        $ghReady = ($auth.ExitCode -eq 0)
        if ($ghReady) { Write-Ok 'gh 已安装并登录' }
        else { Write-Warn2 'gh 已安装但未登录（先执行 gh auth login）' }
    }
    else {
        Write-Warn2 '没有安装 GitHub CLI（gh），走「网页建仓 + 手动推」流程'
    }

    if ($ghReady) {
        $target = if ($Owner) { "$Owner/$RepoName" } else { $RepoName }
        $ghArgs = @(
            'repo', 'create', $target, "--$Visibility",
            '--source', '.', '--remote', 'origin', '--push',
            '--description', $Description
        )
        $r = Invoke-Tool gh $ghArgs -AllowFail
        if ($r.ExitCode -ne 0) {
            Write-Warn2 'gh repo create 没成功（仓库可能已存在）。尝试直接推送…'
            Invoke-Tool git @('push', '-u', 'origin', $branch) -AllowFail | Out-Null
            $pushed = $true
        }
        else {
            Write-Ok '远程仓库已创建并推送'
            $pushed = $true
            if ($Topics.Count -gt 0) {
                $topicArg = ($Topics -join ',')
                Invoke-Tool gh @('repo', 'edit', $target, '--add-topic', $topicArg) -AllowFail | Out-Null
                Write-Ok ("已设置 {0} 个 Topics" -f $Topics.Count)
            }
        }
    }
    else {
        $ownerPart = if ($Owner) { $Owner } else { '<你的用户名>' }
        Write-Host ''
        Write-Host '  需要你手动做两步：' -ForegroundColor Yellow
        Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host "  1) 打开 https://github.com/new 建一个空仓库，名字填 $RepoName" -ForegroundColor Yellow
        Write-Host '     不要勾选 README / .gitignore / license（本地已经有了，勾了会冲突）' -ForegroundColor DarkGray
        Write-Host '  2) 回到这个终端执行（把用户名换成你的）：' -ForegroundColor Yellow
        Write-Host "     git remote add origin https://github.com/$ownerPart/$RepoName.git" -ForegroundColor White
        Write-Host "     git push -u origin $branch" -ForegroundColor White
        Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  或者装一个 GitHub CLI 让脚本全自动：winget install --id GitHub.cli' -ForegroundColor DarkGray
        Write-Host '  装完执行 gh auth login，然后重跑本脚本。' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  不想装 gh 也行：建好仓库后重跑本脚本并带上 -RemoteUrl' -ForegroundColor DarkGray
        Write-Host "      powershell -ExecutionPolicy Bypass -File scripts\push-to-github.ps1 -RemoteUrl <仓库地址>" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------- 5. 占位符替换
function Resolve-RepoTarget {
    $repo = $RepoName
    $own = $Owner

    $urlOut = Invoke-Tool git @('remote', 'get-url', 'origin') -AllowFail -Quiet
    if ($urlOut.ExitCode -eq 0 -and $urlOut.Output -match 'github\.com[:/](?<o>[^/]+)/(?<r>[^/]+?)(\.git)?$') {
        if (-not $own) { $own = $Matches['o'] }
        $repo = $Matches['r']
    }
    if (-not $own -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        $r = Invoke-Tool gh @('api', 'user', '--jq', '.login') -AllowFail -Quiet
        if ($r.ExitCode -eq 0 -and $r.Output) { $own = $r.Output.Trim() }
    }
    return [pscustomobject]@{ Owner = $own; Repo = $repo }
}

if ($SkipPlaceholderFix) {
    Write-Step '跳过占位符替换（-SkipPlaceholderFix）'
}
else {
    Write-Step '替换 OWNER/REPO 占位符'

    $target2 = Resolve-RepoTarget
    if (-not $target2.Owner) {
        Write-Warn2 '不知道你的 GitHub 用户名，跳过占位符替换。'
        Write-Note '稍后手动把 README.md 等文件里的 OWNER/REPO 换成 用户名/仓库名，或用 -Owner 参数重跑。'
    }
    else {
        $real = '{0}/{1}' -f $target2.Owner, $target2.Repo
        Write-Note ("目标：{0}" -f $real)

        $placeholderFiles = @(
            'README.md',
            'CHANGELOG.md',
            'SECURITY.md',
            'CONTRIBUTING.md',
            '.github/ISSUE_TEMPLATE/config.yml'
        )
        $changedFiles = @()

        foreach ($rel in $placeholderFiles) {
            $path = Join-Path $Root $rel
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $text = [System.IO.File]::ReadAllText($path)
            if ($text -notmatch 'OWNER/REPO') { continue }

            if ($DryRun) {
                Write-Host ("     DRY 替换 {0} 中的 OWNER/REPO" -f $rel) -ForegroundColor DarkGray
                $changedFiles += $rel
                continue
            }
            $newText = $text.Replace('OWNER/REPO', $real)
            [System.IO.File]::WriteAllText($path, $newText, (New-Object System.Text.UTF8Encoding($false)))
            $changedFiles += $rel
            Write-Ok ("已替换 {0}" -f $rel)
        }

        if ($changedFiles.Count -gt 0) {
            if (-not $DryRun) {
                Invoke-Tool git (@('add') + $changedFiles) | Out-Null
                Invoke-Tool git @('commit', '-m', 'docs: 替换仓库占位符') | Out-Null
                if ($pushed -or $hasOrigin -or $RemoteUrl) {
                    Invoke-Tool git @('push') -AllowFail | Out-Null
                    Write-Ok '占位符提交已推送'
                }
                else {
                    Write-Note '尚未建立远程，占位符提交等推送时一起上传'
                }
            }
        }
        else {
            Write-Ok '没有残留的 OWNER/REPO'
        }

        # 其余占位符脚本不猜，只提醒
        $leftover = @()
        foreach ($rel in @('CODE_OF_CONDUCT.md', 'SECURITY.md')) {
            $path = Join-Path $Root $rel
            if ((Test-Path -LiteralPath $path) -and ([System.IO.File]::ReadAllText($path) -match 'MAINTAINER_EMAIL')) {
                $leftover += $rel
            }
        }
        if ($leftover.Count -gt 0) {
            Write-Warn2 ("{0} 里还有 MAINTAINER_EMAIL 占位符，记得改成你的邮箱" -f ($leftover -join '、'))
        }
    }
}

# ---------------------------------------------------------------- 6. 打 tag
if ($Tag) {
    Write-Step ("创建并推送 tag：{0}" -f $Tag)
    $exists = (Invoke-Tool git @('tag', '--list', $Tag) -Quiet).Output
    if ($exists) {
        Write-Warn2 ("tag {0} 已存在，跳过创建" -f $Tag)
    }
    else {
        Invoke-Tool git @('tag', '-a', $Tag, '-m', $Tag) | Out-Null
        Write-Ok 'tag 已创建'
    }
    if ($pushed -or $hasOrigin -or $RemoteUrl) {
        Invoke-Tool git @('push', 'origin', $Tag) -AllowFail | Out-Null
        Write-Ok 'tag 已推送'
    }
    else {
        Write-Note '还没建立远程，建好后执行：git push origin ' + $Tag
    }
}

# ---------------------------------------------------------------- 收尾
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  完成。剩下这几件事脚本做不了，去网页上补：' -ForegroundColor Cyan
Write-Host '  1. Settings → Social preview 上传一张 1280x640 封面图' -ForegroundColor Gray
Write-Host '  2. Releases → Draft a new release，把 dist\ 里的安装包/APK 作为附件上传' -ForegroundColor Gray
Write-Host '  3. Settings → Code security 打开 Private vulnerability reporting' -ForegroundColor Gray
Write-Host '  4. Settings → Features 打开 Discussions' -ForegroundColor Gray
Write-Host '  5. 截图放 docs/images/，并把 README 顶部的 demo.gif 注释打开' -ForegroundColor Gray
Write-Host '  完整清单见 docs\RELEASE_CHECKLIST.md' -ForegroundColor Gray
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
