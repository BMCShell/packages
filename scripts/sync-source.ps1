<#
.SYNOPSIS
    同步已发布的 BMCShell 工具包并更新公共软件源索引。
.DESCRIPTION
    在 BMCShell/packages 的发布流程中运行。脚本会校验上游 ZIP 和清单，发布匹配的文件，然后更新索引。需要配置仓库令牌。
#>

#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$distribution = 'BMCShell/packages'
$mirroredPackages = [ordered]@{
    'bmcshell-tool-ipmi' = 'c7998528-c9db-4b22-8c8f-a16e0affd94d'
    'bmcshell-tool-redfish' = '15b746d7-7b0d-4556-89c8-d88078a3117a'
    'bmcshell-tool-snmp' = '6ad7023f-7be5-4c61-8c92-57af9e256dbf'
}
$directThemes = [ordered]@{
    'bmcshell-theme-care' = '0cf9329d-c9de-43ca-9ec7-224b74b05a44'
    'bmcshell-theme-sharp-tongue' = 'a19086e4-7f76-437b-aa41-2ffe8f4e38f9'
    'bmcshell-theme-signal' = '374e74c7-914a-4cd0-ab70-7dfc2670dbe7'
}
$allowedPackages = @{}
foreach ($name in $mirroredPackages.Keys) {
    $allowedPackages[$name] = @{ Id = $mirroredPackages[$name]; Type = 'toolplugin' }
}
foreach ($name in $directThemes.Keys) {
    $allowedPackages[$name] = @{ Id = $directThemes[$name]; Type = 'theme' }
}
$versionPattern = '((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)'

function Get-GitHubReleases([string] $Repository, [hashtable] $Headers) {
    for ($page = 1; ; $page++) {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page" `
            -Headers $Headers -TimeoutSec 60
        $releases
        if ($releases.Count -lt 100) { break }
    }
}

function Get-ReleaseAsset($Release, [string] $Name) {
    $Release.assets | Where-Object { $_.name -ceq $Name } | Select-Object -First 1
}

function Save-GitHubAsset([string] $Repository, $Asset, [hashtable] $Headers, [string] $Path) {
    if ($Asset.state -cne 'uploaded' -or $Asset.id -le 0) {
        throw "仓库 $Repository 中没有已上传的发布文件 '$([IO.Path]::GetFileName($Path))'。"
    }
    $binaryHeaders = $Headers.Clone()
    $binaryHeaders.Accept = 'application/octet-stream'
    Invoke-WebRequest -Uri "https://api.github.com/repos/$Repository/releases/assets/$($Asset.id)" `
        -Headers $binaryHeaders -OutFile $Path -TimeoutSec 120
}

function Save-PublicGitHubAsset([string] $Repository, [string] $Tag, $Asset, [string] $Path, [string] $Name = [IO.Path]::GetFileName($Path)) {
    if ($Asset.name -cne $name -or $Asset.state -cne 'uploaded') {
        throw "仓库 $Repository 中没有已上传的发布文件 '$name'。"
    }
    $url = [uri] $Asset.browser_download_url
    if (!$url -or !$url.IsAbsoluteUri -or $url.Scheme -cne 'https' -or $url.Host -cne 'github.com' -or
        !$url.IsDefaultPort -or $url.UserInfo -or $url.Query -or $url.Fragment -or
        [uri]::UnescapeDataString($url.AbsolutePath) -cne "/$Repository/releases/download/$Tag/$name") {
        throw "发布文件 '$name' 的公共下载 URL 与预期不符。"
    }
    Invoke-WebRequest -Uri $url -OutFile $Path -TimeoutSec 120 -MaximumRetryCount 3 -RetryIntervalSec 2
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PackageRelease([string] $Name, [string] $Version, [string] $Zip, [string] $Manifest) {
    $expected = $allowedPackages[$Name]
    $checksum = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $zipHash = Get-Sha256 $Zip
    if ($checksum.schema -ne 1 -or $checksum.id -cne $expected.Id -or $checksum.name -cne $Name -or
        $checksum.version -cne $Version -or $checksum.type -cne $expected.Type -or
        $checksum.artifact -cne [IO.Path]::GetFileName($Zip) -or $checksum.sha256 -ine $zipHash) {
        throw "扩展包 $Name $Version 的发行清单无效。"
    }

    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($archive.Entries | Where-Object FullName -CEQ 'bmc-package.json')
        if ($entries.Count -ne 1 -or $entries[0].Length -gt 1MB) {
            throw "扩展包 $Name $Version 的包清单无效。"
        }
        $reader = [IO.StreamReader]::new($entries[0].Open())
        try { $package = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
    }

    if ($package.schema -ne 1 -or $package.id -cne $expected.Id -or $package.name -cne $Name -or
        $package.publisher -cne 'bmcshell' -or $package.version -cne $Version -or
        $package.type -cne $expected.Type -or $package.coreApi -ne $checksum.coreApi) {
        throw "扩展包 $Name $Version 的标识与预期不符。"
    }
    $zipHash
}

function Publish-ReleaseAssets([string] $Tag, [bool] $Prerelease, $Release, [string[]] $Paths, [string] $Temporary) {
    $endpoint = "https://api.github.com/repos/$distribution/releases"
    if (!$Release) {
        $body = @{
            tag_name = $Tag
            name = $Tag
            target_commitish = 'main'
            draft = $true
            prerelease = $Prerelease
        } | ConvertTo-Json -Compress
        $Release = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $writeHeaders `
            -ContentType 'application/json' -Body $body -TimeoutSec 60
    }
    if ($Release.prerelease -ne $Prerelease) { throw "现有发布记录 $Tag 的预发行状态不一致。" }

    foreach ($path in $Paths) {
        $name = [IO.Path]::GetFileName($path)
        $asset = Get-ReleaseAsset $Release $name
        if (!$Release.draft -and $asset.state -cne 'uploaded') {
            throw "已发布版本 $Tag 缺少文件 '$name'。"
        }
        if ($Release.draft) {
            if ($asset.state -ceq 'starter') {
                $null = Invoke-RestMethod -Method Delete -Headers $writeHeaders -TimeoutSec 60 `
                    -Uri "https://api.github.com/repos/$distribution/releases/assets/$($asset.id)"
                $asset = $null
            }
            if (!$asset) {
                $upload = $Release.upload_url -replace '\{.*\}$', ''
                if ($upload -cne "https://uploads.github.com/repos/$distribution/releases/$($Release.id)/assets") {
                    throw "标签 $Tag 的上传 URL 与预期不符。"
                }
                $asset = Invoke-RestMethod -Method Post -Uri "$upload`?name=$([uri]::EscapeDataString($name))" `
                    -Headers $writeHeaders -ContentType 'application/octet-stream' -InFile $path -TimeoutSec 120
            }
            if ($asset.name -cne $name -or $asset.state -cne 'uploaded') {
                throw "标签 $Tag 的发布文件与预期不符。"
            }
            $expected = Get-Sha256 $path
            if ($asset.digest) {
                if ($asset.digest -ine "sha256:$expected") { throw "草稿发布文件 '$name' 的内容不一致。" }
            } else {
                Save-GitHubAsset $distribution $asset $writeHeaders $Temporary
                if ((Get-Sha256 $Temporary) -cne $expected) { throw "草稿发布文件 '$name' 的内容不一致。" }
            }
        }
    }
    if ($Release.draft) {
        $Release = Invoke-RestMethod -Method Patch -Uri "$endpoint/$($Release.id)" -Headers $writeHeaders `
            -ContentType 'application/json' -Body '{"draft":false,"make_latest":"false"}' -TimeoutSec 60
        if ($Release.draft -or $Release.tag_name -cne $Tag) { throw "版本 $Tag 发布失败。" }
        # Asset URLs obtained while a release is a draft contain a temporary tag.
        $publishedTag = [uri]::EscapeDataString($Tag)
        $Release = Invoke-RestMethod -Uri "$endpoint/tags/$publishedTag" -Headers $writeHeaders -TimeoutSec 60
    }
    $assets = @{}
    foreach ($path in $Paths) {
        $name = [IO.Path]::GetFileName($path)
        $assets[$name] = Get-ReleaseAsset $Release $name
    }
    $assets
}

if ($env:GITHUB_REPOSITORY -ine $distribution -or !$env:GITHUB_TOKEN) {
    throw "请在 $distribution 仓库中配置其令牌后运行同步。"
}
$readHeaders = @{
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$writeHeaders = $readHeaders.Clone()
$writeHeaders.Authorization = "Bearer $env:GITHUB_TOKEN"
$index = Join-Path (Split-Path -Parent $PSScriptRoot) 'index.json'
$indexed = Get-Content -LiteralPath $index -Raw | ConvertFrom-Json
if ($indexed.schema -ne 1 -or $indexed.packages -isnot [array]) { throw '公共软件源索引格式无效。' }
foreach ($entry in $indexed.packages) {
    if ($entry.name -cnotin $allowedPackages.Keys -or $entry.id -cne $allowedPackages[$entry.name].Id -or
        $entry.type -cne $allowedPackages[$entry.name].Type) {
        throw "公共索引中包含未预期的扩展包 '$($entry.name)'。"
    }
}

$publicReleases = @{}
$upstreamReleases = @{}
foreach ($name in $mirroredPackages.Keys) {
    $upstreamReleases[$name] = @(Get-GitHubReleases "BMCShell/$name" $readHeaders)
}
foreach ($release in (Get-GitHubReleases $distribution $writeHeaders)) {
    $publicReleases[$release.tag_name] = $release
}

$work = [IO.Directory]::CreateTempSubdirectory('bmcshell-sync-').FullName
try {
    $artifacts = [Collections.Generic.List[object]]::new()
    $temporary = Join-Path $work 'verify-download'
    foreach ($name in $mirroredPackages.Keys) {
        $upstream = "BMCShell/$name"
        foreach ($release in $upstreamReleases[$name]) {
            if ($release.draft -or $release.tag_name -cnotmatch "^v${versionPattern}$") {
                continue
            }
            $version = $Matches[1]
            $tag = "$name-v$version"
            $zipName = "$name@$version.zip"
            $manifestName = "$name@$version.manifest.json"
            $zip = Join-Path $work $zipName
            $manifest = Join-Path $work $manifestName
            Save-PublicGitHubAsset $upstream $release.tag_name (Get-ReleaseAsset $release $zipName) $zip
            Save-PublicGitHubAsset $upstream $release.tag_name (Get-ReleaseAsset $release $manifestName) $manifest
            $hash = Test-PackageRelease $name $version $zip $manifest
            foreach ($previous in $indexed.packages) {
                if ($previous.id -ceq $allowedPackages[$name].Id -and $previous.version -ceq $version -and $previous.sha256 -ine $hash) {
                    throw "索引中已存在内容不同的 $name $version。请使用新版本号发布。"
                }
            }

            $assets = Publish-ReleaseAssets $tag $release.prerelease $publicReleases[$tag] @($zip, $manifest) $temporary
            foreach ($path in @($zip, $manifest)) {
                $nameInRelease = [IO.Path]::GetFileName($path)
                $asset = $assets[$nameInRelease]
                Save-PublicGitHubAsset $distribution $tag $asset $temporary -Name $nameInRelease
                if ((Get-Sha256 $temporary) -cne (Get-Sha256 $path)) {
                    throw "公共发布文件 '$($asset.name)' 的内容不一致。"
                }
            }
            $artifacts.Add(@{ path = $zip; url = $assets[$zipName].browser_download_url })
            Write-Output "已校验 $name $version。"
        }
    }
    foreach ($name in $directThemes.Keys) {
        $tagPattern = '^' + [regex]::Escape($name) + "-v${versionPattern}$"
        foreach ($release in $publicReleases.Values) {
            if ($release.draft -or $release.tag_name -cnotmatch $tagPattern) { continue }
            $version = $Matches[1]
            $zipName = "$name@$version.zip"
            $manifestName = "$name@$version.manifest.json"
            $zip = Join-Path $work $zipName
            $manifest = Join-Path $work $manifestName
            $zipAsset = Get-ReleaseAsset $release $zipName
            Save-PublicGitHubAsset $distribution $release.tag_name $zipAsset $zip
            Save-PublicGitHubAsset $distribution $release.tag_name (Get-ReleaseAsset $release $manifestName) $manifest
            $hash = Test-PackageRelease $name $version $zip $manifest
            foreach ($previous in $indexed.packages) {
                if ($previous.id -ceq $allowedPackages[$name].Id -and $previous.version -ceq $version -and $previous.sha256 -ine $hash) {
                    throw "索引中已存在内容不同的 $name $version。请使用新版本号发布。"
                }
            }
            $artifacts.Add(@{ path = $zip; url = $zipAsset.browser_download_url })
            Write-Output "已校验 $name $version。"
        }
    }
    if ($artifacts.Count -gt 0) {
        $artifactList = Join-Path $work 'artifacts.json'
        ConvertTo-Json -InputObject $artifacts.ToArray() | Set-Content -LiteralPath $artifactList
        & (Join-Path $PSScriptRoot 'build-source-index.ps1') -ArtifactsFile $artifactList -Output $index -Merge | Out-Null
    }
} finally {
    foreach ($file in [IO.Directory]::EnumerateFiles($work)) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($work)
}
