#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$distribution = 'BMCShell/packages'
$allowedPackages = [ordered]@{
    'bmcshell-tool-ipmi' = 'c7998528-c9db-4b22-8c8f-a16e0affd94d'
    'bmcshell-tool-redfish' = '15b746d7-7b0d-4556-89c8-d88078a3117a'
    'bmcshell-tool-snmp' = '6ad7023f-7be5-4c61-8c92-57af9e256dbf'
}

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
        throw "$Repository has no uploaded asset for '$([IO.Path]::GetFileName($Path))'."
    }
    $binaryHeaders = $Headers.Clone()
    $binaryHeaders.Accept = 'application/octet-stream'
    Invoke-WebRequest -Uri "https://api.github.com/repos/$Repository/releases/assets/$($Asset.id)" `
        -Headers $binaryHeaders -OutFile $Path -TimeoutSec 120
}

function Save-PublicGitHubAsset([string] $Repository, [string] $Tag, $Asset, [string] $Path, [string] $Name = [IO.Path]::GetFileName($Path)) {
    if ($Asset.name -cne $name -or $Asset.state -cne 'uploaded') {
        throw "$Repository has no uploaded asset for '$name'."
    }
    $url = [uri] $Asset.browser_download_url
    if (!$url -or !$url.IsAbsoluteUri -or $url.Scheme -cne 'https' -or $url.Host -cne 'github.com' -or
        !$url.IsDefaultPort -or $url.UserInfo -or $url.Query -or $url.Fragment -or
        [uri]::UnescapeDataString($url.AbsolutePath) -cne "/$Repository/releases/download/$Tag/$name") {
        throw "Unexpected public download URL for '$name'."
    }
    Invoke-WebRequest -Uri $url -OutFile $Path -TimeoutSec 120 -MaximumRetryCount 3 -RetryIntervalSec 2
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PackageRelease([string] $Name, [string] $Version, [string] $Zip, [string] $Manifest) {
    $id = $allowedPackages[$Name]
    $checksum = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $zipHash = Get-Sha256 $Zip
    if ($checksum.schema -ne 1 -or $checksum.id -cne $id -or $checksum.name -cne $Name -or
        $checksum.version -cne $Version -or $checksum.type -cne 'toolplugin' -or
        $checksum.artifact -cne [IO.Path]::GetFileName($Zip) -or $checksum.sha256 -ine $zipHash) {
        throw "Invalid release manifest for $Name $Version."
    }

    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($archive.Entries | Where-Object FullName -CEQ 'bmc-package.json')
        if ($entries.Count -ne 1 -or $entries[0].Length -gt 1MB) {
            throw "Invalid package manifest in $Name $Version."
        }
        $reader = [IO.StreamReader]::new($entries[0].Open())
        try { $package = $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
    }

    if ($package.schema -ne 1 -or $package.id -cne $id -or $package.name -cne $Name -or
        $package.publisher -cne 'bmcshell' -or $package.version -cne $Version -or
        $package.type -cne 'toolplugin' -or $package.coreApi -ne $checksum.coreApi) {
        throw "Unexpected package identity in $Name $Version."
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
    if ($Release.prerelease -ne $Prerelease) { throw "Existing release $Tag has a different prerelease state." }

    $assets = @{}
    foreach ($path in $Paths) {
        $name = [IO.Path]::GetFileName($path)
        $asset = Get-ReleaseAsset $Release $name
        if (!$Release.draft -and $asset.state -cne 'uploaded') {
            throw "Published release $Tag is missing '$name'."
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
                    throw "Unexpected upload URL for $Tag."
                }
                $asset = Invoke-RestMethod -Method Post -Uri "$upload`?name=$([uri]::EscapeDataString($name))" `
                    -Headers $writeHeaders -ContentType 'application/octet-stream' -InFile $path -TimeoutSec 120
            }
            if ($asset.name -cne $name -or $asset.state -cne 'uploaded') {
                throw "Unexpected release asset for $Tag."
            }
            $expected = Get-Sha256 $path
            if ($asset.digest) {
                if ($asset.digest -ine "sha256:$expected") { throw "Draft asset '$name' has different bytes." }
            } else {
                Save-GitHubAsset $distribution $asset $writeHeaders $Temporary
                if ((Get-Sha256 $Temporary) -cne $expected) { throw "Draft asset '$name' has different bytes." }
            }
        }
        $assets[$name] = $asset
    }
    if ($Release.draft) {
        $Release = Invoke-RestMethod -Method Patch -Uri "$endpoint/$($Release.id)" -Headers $writeHeaders `
            -ContentType 'application/json' -Body '{"draft":false,"make_latest":"false"}' -TimeoutSec 60
        if ($Release.draft -or $Release.tag_name -cne $Tag) { throw "Release $Tag did not publish." }
    }
    $assets
}

if ($env:GITHUB_REPOSITORY -ine $distribution -or !$env:GITHUB_TOKEN) {
    throw "Run the synchronization in $distribution with its repository token."
}
$readHeaders = @{
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$writeHeaders = $readHeaders.Clone()
$writeHeaders.Authorization = "Bearer $env:GITHUB_TOKEN"
$index = Join-Path (Split-Path -Parent $PSScriptRoot) 'index.json'
$indexed = Get-Content -LiteralPath $index -Raw | ConvertFrom-Json
if ($indexed.schema -ne 1 -or $indexed.packages -isnot [array]) { throw 'Invalid public source index.' }
foreach ($entry in $indexed.packages) {
    if ($entry.name -cnotin $allowedPackages.Keys -or $entry.id -cne $allowedPackages[$entry.name]) {
        throw "Public index contains an unexpected package '$($entry.name)'."
    }
}

$publicReleases = @{}
$upstreamReleases = @{}
foreach ($name in $allowedPackages.Keys) {
    $upstreamReleases[$name] = @(Get-GitHubReleases "BMCShell/$name" $readHeaders)
}
foreach ($release in (Get-GitHubReleases $distribution $writeHeaders)) {
    $publicReleases[$release.tag_name] = $release
}

$work = [IO.Directory]::CreateTempSubdirectory('bmcshell-sync-').FullName
try {
    $artifacts = [Collections.Generic.List[object]]::new()
    $temporary = Join-Path $work 'verify-download'
    foreach ($name in $allowedPackages.Keys) {
        $upstream = "BMCShell/$name"
        foreach ($release in $upstreamReleases[$name]) {
            if ($release.draft -or $release.tag_name -cnotmatch '^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)$') {
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
                if ($previous.id -ceq $allowedPackages[$name] -and $previous.version -ceq $version -and $previous.sha256 -ine $hash) {
                    throw "Indexed version $name $version has different bytes. Publish a new version."
                }
            }

            $assets = Publish-ReleaseAssets $tag $release.prerelease $publicReleases[$tag] @($zip, $manifest) $temporary
            foreach ($path in @($zip, $manifest)) {
                $nameInRelease = [IO.Path]::GetFileName($path)
                $asset = $assets[$nameInRelease]
                Save-PublicGitHubAsset $distribution $tag $asset $temporary -Name $nameInRelease
                if ((Get-Sha256 $temporary) -cne (Get-Sha256 $path)) {
                    throw "Public asset '$($asset.name)' has different bytes."
                }
            }
            $artifacts.Add(@{ path = $zip; url = $assets[$zipName].browser_download_url })
            Write-Output "Verified $name $version."
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
