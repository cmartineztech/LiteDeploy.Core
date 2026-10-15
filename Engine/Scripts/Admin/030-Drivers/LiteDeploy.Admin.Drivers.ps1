<#
.SYNOPSIS
    LiteDeploy Admin.Drivers - find, download, verify, and optionally extract OEM driver packs
    (Dell, Lenovo, HP experimental, Custom) into the deployment share.

.DESCRIPTION
    Layout under the deployment share root (-DeploymentShare / -ShareRoot):

      Content\Drivers\                 driver packs, vendor catalogs, LocalCatalog.json, ComputerModels.csv
      Content\Temp\                    download / catalog build scratch
      Engine\Tools\                    bundled curl (if installed by Init)
      WorkLogs\Admin\DriverManagement.log

    Catalogs land in Content\Drivers\<Vendor>Catalog.json. Extracted packs go to
    Content\Drivers\<Manufacturer>\<Model>\Content\ for setup.exe /InstallDrivers.

    Download does not extract by default (-Extract $false). Pass -Extract $true to expand packs.
    Works on a full Windows OS and in WinPE. Exits 1 on failure.

.PARAMETER DeploymentShare
    Deployment share root (aliases: ShareRoot, Root). Example: C:\DeploymentShare or \\Server\DeploymentShare$.

.PARAMETER Extract
    When downloading: $false (default) keeps the verified archive only; $true extracts into Content.

.EXAMPLE
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Init
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action GetCatalog -All
    .\LiteDeploy.Admin.Drivers.ps1 -ShareRoot C:\DeploymentShare -Action GetCatalog -Manufacturer HP -CleanTemp
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Download
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Download -All
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Download -All -Extract $true
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Download -Manufacturer Lenovo -SystemSKU 21KC -OSCode Windows10
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Status -All
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action Search -SystemSKU 873E
    .\LiteDeploy.Admin.Drivers.ps1 -DeploymentShare C:\DeploymentShare -Action AddCustom -ComputerModel "Toughbook 55" -SystemSKU "FZ55" -CustomManufacturer Panasonic
#>

[CmdletBinding()]
param(
    [ValidateSet('Init', 'GetCatalog', 'CheckUpdate', 'Detect', 'Search', 'Status', 'Sync', 'Download', 'AddCustom')]
    [string]$Action = 'Detect',

    [Alias('ShareRoot', 'Root')]
    [string]$DeploymentShare = '',

    [string]$Manufacturer,            # Dell / Lenovo / HP / Custom / Custom_<Maker> / All
    [string]$SystemSKU,               # Override the detected SKU
    [string]$ComputerModel,           # Override the detected model
    [string]$CustomManufacturer,      # AddCustom: hardware maker (e.g. Panasonic), stored as Custom_Panasonic; optional
    [switch]$All,                     # Process every row in ComputerModels.csv
    [ValidateSet('Windows11', 'Windows10')]
    [string]$OSCode = 'Windows11',    # The newest build available for the model is used (e.g. 25H2)
    [switch]$AddSupport,              # Register the detected hardware in ComputerModels.csv
    [object]$Extract = $false,        # Download: default keeps archive only; pass $true to extract
    [string]$DriversPath = '',        # Optional override; default: <DeploymentShare>\Content\Drivers
    [switch]$CleanTemp,               # GetCatalog/CheckUpdate: delete raw vendor CAB/XML after conversion
    [switch]$Metadata
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = 'Admin.Drivers'
        Name                 = 'LiteDeploy Admin Driver Management'
        Version              = '2.0.0'
        Category             = 'Admin'
        TargetEnvironment    = 'Host'
        MinPowerShellVersion = '5.1'
        Author               = 'LiteDeploy Team'
        Dependencies         = @('Admin.Content')
        Description          = 'Download and manage OEM driver packs under Content\Drivers; logs to WorkLogs\Admin\DriverManagement.log.'
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# --- Paths (DeploymentShare-rooted) ---
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Resolve-LiteDeployDriverShareRoot {
    param([string]$ExplicitRoot)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot)) {
        return [IO.Path]::GetFullPath($ExplicitRoot.Trim().TrimEnd('\', '/'))
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LiteDeployShareRoot)) {
        return [IO.Path]::GetFullPath($env:LiteDeployShareRoot.Trim().TrimEnd('\', '/'))
    }

    # Walk up from this script looking for a share root (Content + Engine).
    $probe = $ScriptRoot
    for ($i = 0; $i -lt 8 -and $probe; $i++) {
        $content = Join-Path $probe 'Content'
        $engine  = Join-Path $probe 'Engine'
        if ((Test-Path -LiteralPath $content) -and (Test-Path -LiteralPath $engine)) {
            return [IO.Path]::GetFullPath($probe)
        }
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }

    return $null
}

$ShareRootResolved = Resolve-LiteDeployDriverShareRoot -ExplicitRoot $DeploymentShare
if (-not $ShareRootResolved) {
    throw "Pass -DeploymentShare <path> (deployment share root). Example: -DeploymentShare C:\DeploymentShare"
}
$DeploymentShare = $ShareRootResolved

if ([string]::IsNullOrWhiteSpace($DriversPath)) {
    $DriversPath = Join-Path $DeploymentShare 'Content\Drivers'
}
else {
    $DriversPath = [IO.Path]::GetFullPath($DriversPath.Trim().TrimEnd('\', '/'))
}

$TempPath         = Join-Path $DeploymentShare 'Content\Temp'
$ToolsPath        = Join-Path $DeploymentShare 'Engine\Tools'
$LocalCatalogPath = Join-Path $DriversPath 'LocalCatalog.json'
$LogPath          = Join-Path $DeploymentShare 'WorkLogs\Admin\DriverManagement.log'
$ModelsCsvPath    = Join-Path $DriversPath 'ComputerModels.csv'
$IsWinPE          = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'

# Name is used for folders and LocalCatalog.json; Short is used in the CSV and for the Temp\<Short>_Build folder.
$Vendors = [ordered]@{
    Dell   = [pscustomobject]@{ Name = 'Dell Inc.'; Short = 'Dell';   Catalog = Join-Path $DriversPath 'DellCatalog.json';   Converter = 'Convert-DellCatalog' }
    Lenovo = [pscustomobject]@{ Name = 'LENOVO';    Short = 'Lenovo'; Catalog = Join-Path $DriversPath 'LenovoCatalog.json'; Converter = 'Convert-LenovoCatalog' }
    HP     = [pscustomobject]@{ Name = 'HP';        Short = 'HP';     Catalog = Join-Path $DriversPath 'HPCatalog.json';     Converter = 'Convert-HPCatalog' }
    Custom = [pscustomobject]@{ Name = 'Custom';    Short = 'Custom'; Catalog = $null;                                       Converter = $null }
}
$CatalogCache = @{}

# --- Utilities ---
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host "[$Level] $Message" -ForegroundColor $color

    # Logging must never break a run (missing folder, read-only media, file in use).
    try {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 5MB) { Move-Item $LogPath "$LogPath.old" -Force }
        Add-Content -Path $LogPath -Value ('{0} [{1}] {2}' -f (Get-Date).ToString('s'), $Level, $Message) -Encoding UTF8
    }
    catch { }
}

function New-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item $Path -ItemType Directory -Force | Out-Null }
}

function Test-FolderHasContent {
    param([string]$Path)
    return (Test-Path $Path) -and [bool](Get-ChildItem $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SafeName {
    param([string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '-').Trim(' .')
}

function Get-CurlPath {
    # System curl (Windows 10 1803+) uses the Windows certificate store, so it works behind TLS inspection.
    $system = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($system) { return $system.Path }
    $bundled = Get-ChildItem (Join-Path $ToolsPath 'curl') -Filter curl.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bundled) { return $bundled.FullName }
    return $null
}

function Install-Curl {
    $zip = Join-Path $TempPath 'curl.zip'
    $stage = Join-Path $TempPath 'curl'
    Write-Log 'curl.exe not found. Downloading it to Engine\Tools\curl...'
    New-Directory $TempPath
    Remove-Item $zip, $stage -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri 'https://curl.se/windows/latest.cgi?p=win64-mingw.zip' -OutFile $zip -UseBasicParsing
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
    $exe = Get-ChildItem $stage -Filter curl.exe -Recurse | Select-Object -First 1
    New-Directory (Join-Path $ToolsPath 'curl')
    Copy-Item (Join-Path $exe.DirectoryName '*') (Join-Path $ToolsPath 'curl') -Recurse -Force
    Remove-Item $zip, $stage -Recurse -Force -ErrorAction SilentlyContinue
}

function Save-Url {
    param([string]$Url, [string]$Path, [switch]$Quiet)
    $partial = "$Path.part"
    $curl = Get-CurlPath
    try {
        if ($curl) {
            $progress = if ($Quiet) { '--silent', '--show-error' } else { @() }
            & $curl --location --fail --ssl-no-revoke --retry 5 --retry-delay 3 @progress --output $partial $Url
            if ($LASTEXITCODE -ne 0) { throw "curl exit code $LASTEXITCODE" }
        }
        else {
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
        }
        Move-Item $partial $Path -Force
    }
    catch {
        Remove-Item $partial -Force -ErrorAction SilentlyContinue
        throw "Download failed for ${Url}: $($_.Exception.Message)"
    }
}

function Test-PackHash {
    param([string]$Path, [pscustomobject]$Pack)
    if ($Pack.SHA256) { return (Get-FileHash $Path -Algorithm SHA256).Hash -eq $Pack.SHA256 }
    if ($Pack.MD5)    { return (Get-FileHash $Path -Algorithm MD5).Hash -eq $Pack.MD5 }
    Write-Log "The catalog has no hash for $($Pack.FileName); skipping verification." -Level WARN
    return $true
}

function Test-Is32BitExe {
    param([string]$Path)
    $bytes = New-Object byte[] 4096
    $stream = [IO.File]::OpenRead($Path)
    try { [void]$stream.Read($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    return ($peOffset -gt 0 -and $peOffset -lt 4090 -and [BitConverter]::ToUInt16($bytes, $peOffset + 4) -eq 0x14C)
}

function Reset-DirectoryAcl {
    param([string]$Path)
    # Grants Administrators full control and Users read/execute so setup.exe can read the drivers.
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    if (Test-Path $icacls) {
        & $icacls $Path /grant '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q | Out-Null
    }
}

# --- LocalCatalog.json ---
function Get-LocalCatalog {
    if (-not (Test-Path $LocalCatalogPath)) {
        return [pscustomobject]@{ Manufacturers = [pscustomobject]@{} }
    }
    try { return Get-Content $LocalCatalogPath -Raw | ConvertFrom-Json }
    catch { throw "LocalCatalog.json is not valid JSON ($LocalCatalogPath). Fix or restore it before running again." }
}

function Save-LocalCatalog {
    # Written to a temp file first so an interrupted run never leaves a half-written catalog.
    param([pscustomobject]$Catalog)
    New-Directory $DriversPath
    $Catalog | ConvertTo-Json -Depth 8 | Set-Content -Path "$LocalCatalogPath.tmp" -Encoding UTF8
    Move-Item "$LocalCatalogPath.tmp" $LocalCatalogPath -Force
}

function Get-VendorEntry {
    param([pscustomobject]$Catalog, [string]$VendorName)
    $entry = $Catalog.Manufacturers.$VendorName
    if (-not $entry) {
        $entry = [pscustomobject]@{ Catalog = $null; DrivePacks = @() }
        $Catalog.Manufacturers | Add-Member -NotePropertyName $VendorName -NotePropertyValue $entry
    }
    foreach ($property in 'Catalog', 'DrivePacks') {
        if (-not $entry.PSObject.Properties[$property]) { $entry | Add-Member -NotePropertyName $property -NotePropertyValue $null }
    }
    return $entry
}

# Windows drops trailing dots from folder names ("Dell Inc." is stored as "Dell Inc"), so compare full paths.
function Resolve-ContentPath {
    param([string]$ContentLocation)
    return [IO.Path]::GetFullPath((Join-Path $DriversPath $ContentLocation))
}

function Get-PackRecord {
    param([pscustomobject]$Vendor, [string]$ContentLocation)
    $entry = (Get-LocalCatalog).Manufacturers.($Vendor.Name)
    if (-not $entry) { return $null }
    $wanted = Resolve-ContentPath $ContentLocation
    return @($entry.DrivePacks) | Where-Object { $_ -and (Resolve-ContentPath $_.ContentLocation) -eq $wanted } | Select-Object -First 1
}

function Save-PackRecord {
    param([pscustomobject]$Vendor, [pscustomobject]$Record)
    $catalog = Get-LocalCatalog
    $entry = Get-VendorEntry $catalog $Vendor.Name
    $wanted = Resolve-ContentPath $Record.ContentLocation
    $others = @($entry.DrivePacks | Where-Object { $_ -and (Resolve-ContentPath $_.ContentLocation) -ne $wanted })
    $entry.DrivePacks = @($others) + $Record
    Save-LocalCatalog $catalog
}

# --- Vendor catalog converters ---
# Each converter downloads the vendor catalog into $WorkDir and writes a JSON file where every package has
# the same shape: ReleaseID, FileName, Url, Format (cab/exe), Type (win/winpe), Date (yyyy-MM-dd), Size,
# Version, SHA256, MD5, OS (e.g. Windows11, Windows11_24H2), SystemSKUs, Models.

function Expand-Cab {
    param([string]$CabPath, [string]$Destination)
    & expand.exe $CabPath $Destination | Out-Null
    if (-not (Test-Path $Destination)) { throw "Could not expand $CabPath" }
}

function Get-NodeText {
    param($Node)
    if ($null -eq $Node) { return '' }
    if ($Node -is [string]) { return $Node.Trim() }
    if ($Node.'#cdata-section') { return ([string]$Node.'#cdata-section').Trim() }
    if ($Node.'#text') { return ([string]$Node.'#text').Trim() }
    return ([string]$Node.InnerText).Trim()
}

function ConvertTo-IsoDate {
    param([string]$Value)
    $date = [datetime]::MinValue
    if ([datetime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
        return $date.ToString('yyyy-MM-dd')
    }
    return ''
}

# Lenovo and HP catalogs have no version field, so the HTTP Last-Modified date (or newest package) is used.
function Get-CatalogVersion {
    param([string]$Url, $Packages)
    try {
        $lastModified = @((Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 15).Headers['Last-Modified'])[0]
        if ($lastModified) { return ([datetime]$lastModified).ToString('yyyy.MM.dd') }
    }
    catch { }
    $newest = @($Packages.Date | Where-Object { $_ } | Sort-Object -Descending)[0]
    if ($newest) { return ([datetime]$newest).ToString('yyyy.MM.dd') }
    return (Get-Date).ToString('yyyy.MM.dd')
}

function Save-VendorCatalog {
    param([string]$Path, [string]$Vendor, [string]$Version, [string]$DateTime, $Packages)
    $catalog = [pscustomobject]@{
        Manifest       = [ordered]@{
            Manufacturer  = $Vendor
            Version       = $Version
            DateTime      = $DateTime
            TotalPackages = @($Packages).Count
            GeneratedAt   = (Get-Date).ToString('s')
        }
        DriverPackages = @($Packages)
    }
    $catalog | ConvertTo-Json -Depth 6 | Set-Content -Path "$Path.tmp" -Encoding UTF8
    Move-Item "$Path.tmp" $Path -Force
    return [pscustomobject]@{ Version = $Version; DateTime = $DateTime; TotalPackages = @($Packages).Count }
}

function Convert-DellCatalog {
    param([string]$TargetPath, [string]$WorkDir)
    $cab = Join-Path $WorkDir 'DriverPackCatalog.cab'
    $xmlPath = Join-Path $WorkDir 'DriverPackCatalog.xml'
    Save-Url -Url 'https://downloads.dell.com/catalog/DriverPackCatalog.cab' -Path $cab -Quiet
    Expand-Cab $cab $xmlPath

    [xml]$xml = Get-Content $xmlPath -Raw
    $manifest = $xml.DriverPackManifest
    $baseUrl = 'https://' + ([string]$manifest.baseLocation).TrimEnd('/')

    $packages = foreach ($pkg in $manifest.DriverPackage) {
        $sha256 = Get-NodeText ($pkg.Cryptography.Hash | Where-Object { $_.algorithm -eq 'SHA256' } | Select-Object -First 1)

        $skus = foreach ($id in $pkg.SupportedSystems.Brand.Model.systemID) {
            $id = ([string]$id).Trim().ToUpper()
            $id
            if ($id -match '^[0-9A-F]{1,3}$') { $id.PadLeft(4, '0') }
        }
        $models = foreach ($m in $pkg.SupportedSystems.Brand.Model) { Get-NodeText $m.name; Get-NodeText $m.Display }

        [pscustomobject]@{
            ReleaseID  = [string]$pkg.releaseID
            FileName   = Split-Path ([string]$pkg.path) -Leaf
            Url        = "$baseUrl/$($pkg.path)"
            Format     = ([string]$pkg.format).ToLower()
            Type       = [string]$pkg.type
            Date       = ConvertTo-IsoDate $pkg.dateTime
            Size       = [int64]$pkg.size
            Version    = [string]$pkg.dellVersion
            SHA256     = $sha256.ToUpper()
            MD5        = ([string]$pkg.hashMD5).ToUpper()
            OS         = @($pkg.SupportedOperatingSystems.OperatingSystem.osCode | Select-Object -Unique)
            SystemSKUs = @($skus | Where-Object { $_ } | Select-Object -Unique)
            Models     = @($models | Where-Object { $_ } | Select-Object -Unique)
        }
    }

    Save-VendorCatalog -Path $TargetPath -Vendor 'Dell Inc.' -Version $manifest.version -DateTime $manifest.dateTime -Packages $packages
}

function Convert-LenovoCatalog {
    param([string]$TargetPath, [string]$WorkDir)
    $url = 'https://download.lenovo.com/cdrt/td/catalogv2.xml'
    $xmlPath = Join-Path $WorkDir 'catalogv2.xml'
    Save-Url -Url $url -Path $xmlPath -Quiet

    [xml]$xml = Get-Content $xmlPath -Raw
    $packages = foreach ($model in $xml.ModelList.Model) {
        $modelName = Get-NodeText $model.name
        $skus = @($model.Types.Type | ForEach-Object { (Get-NodeText $_).ToUpper() } | Where-Object { $_ } | Select-Object -Unique)

        foreach ($sccm in $model.SCCM) {
            $packUrl = Get-NodeText $sccm
            if (-not $packUrl) { continue }

            $family = switch -Regex ([string]$sccm.os) { 'win11' { 'Windows11' } 'win10' { 'Windows10' } default { [string]$sccm.os } }
            $build = [string]$sccm.version
            $os = @($family)
            if ($build -and $build -ne '*') { $os += "${family}_$build" }

            $crc = [string]$sccm.crc
            $fileName = Split-Path $packUrl -Leaf
            [pscustomobject]@{
                ReleaseID  = $fileName -replace '\.[^.]+$', ''
                FileName   = $fileName
                Url        = $packUrl
                Format     = 'exe'
                Type       = 'win'
                Date       = ConvertTo-IsoDate $sccm.date
                Size       = 0
                Version    = $build
                SHA256     = if ($crc.Length -eq 64) { $crc.ToUpper() } else { '' }
                MD5        = ([string]$sccm.md5).ToUpper()
                OS         = $os
                SystemSKUs = $skus
                Models     = @($modelName)
            }
        }
    }

    $version = Get-CatalogVersion -Url $url -Packages $packages
    Save-VendorCatalog -Path $TargetPath -Vendor 'LENOVO' -Version $version -DateTime (Get-Date).ToString('s') -Packages $packages
}

function Convert-HPCatalog {
    param([string]$TargetPath, [string]$WorkDir)
    $url = 'https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab'
    $cab = Join-Path $WorkDir 'HPClientDriverPackCatalog.cab'
    $xmlPath = Join-Path $WorkDir 'HPClientDriverPackCatalog.xml'
    Save-Url -Url $url -Path $cab -Quiet
    Expand-Cab $cab $xmlPath

    [xml]$xml = Get-Content $xmlPath -Raw
    $root = $xml.NewDataSet.HPClientDriverPackCatalog
    $softPaqs = @{}
    foreach ($sp in $root.SoftPaqList.SoftPaq) { $softPaqs[[string]$sp.Id] = $sp }

    # Each SoftPaq is listed once per product and OS build; merge those rows into one package.
    $packages = foreach ($group in ($root.ProductOSDriverPackList.ProductOSDriverPack | Group-Object SoftPaqId)) {
        $sp = $softPaqs[$group.Name]
        if (-not $sp) { continue }

        $os = foreach ($p in $group.Group) {
            if ($p.OSName -match '^Windows (10|11) 64-bit, (\w+)$') { "Windows$($Matches[1])"; "Windows$($Matches[1])_$($Matches[2])" }
        }
        if (-not $os) { continue }   # IoT / LTSC-only packs

        $skus = foreach ($p in $group.Group) { ([string]$p.SystemId).Split(',') | ForEach-Object { $_.Trim().ToUpper() } }

        [pscustomobject]@{
            ReleaseID  = [string]$sp.Id
            FileName   = Split-Path ([string]$sp.Url) -Leaf
            Url        = [string]$sp.Url
            Format     = 'exe'
            Type       = 'win'
            Date       = ConvertTo-IsoDate $sp.DateReleased
            Size       = [int64]$sp.Size
            Version    = [string]$sp.Version
            SHA256     = ([string]$sp.SHA256).ToUpper()
            MD5        = ([string]$sp.MD5).ToUpper()
            OS         = @($os | Select-Object -Unique)
            SystemSKUs = @($skus | Where-Object { $_ } | Select-Object -Unique)
            Models     = @($group.Group.SystemName | Select-Object -Unique)
        }
    }

    $version = Get-CatalogVersion -Url $url -Packages $packages
    Save-VendorCatalog -Path $TargetPath -Vendor 'HP' -Version $version -DateTime (Get-Date).ToString('s') -Packages $packages
}

function Build-VendorCatalog {
    # The raw CAB/XML files are kept in Temp\<Vendor>_Build for inspection unless -CleanTemp is used.
    param([pscustomobject]$Vendor, [string]$TargetPath)
    $workDir = Join-Path $TempPath "$($Vendor.Short)_Build"
    New-Directory $workDir
    try { return & $Vendor.Converter -TargetPath $TargetPath -WorkDir $workDir }
    finally { if ($CleanTemp) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue } }
}

# --- Vendor catalogs ---
function Update-Catalog {
    param([pscustomobject]$Vendor)
    Write-Log "Downloading $($Vendor.Name) catalog..."
    $info = Build-VendorCatalog -Vendor $Vendor -TargetPath $Vendor.Catalog
    $CatalogCache.Remove($Vendor.Short)

    $catalog = Get-LocalCatalog
    $entry = Get-VendorEntry $catalog $Vendor.Name
    $oldVersion = if ($entry.Catalog) { $entry.Catalog.Version } else { 'none' }
    $entry.Catalog = [pscustomobject]@{ Version = $info.Version; DateTime = $info.DateTime; DownloadedOn = (Get-Date).ToString('s') }
    Save-LocalCatalog $catalog
    Write-Log "$($Vendor.Name) catalog: $oldVersion -> $($info.Version) ($($info.TotalPackages) packages)"
}

function Test-CatalogUpdate {
    param([pscustomobject]$Vendor)
    $current = if (Test-Path $Vendor.Catalog) { (Get-Content $Vendor.Catalog -Raw | ConvertFrom-Json).Manifest.Version }
    $probe = Join-Path $TempPath "$($Vendor.Short)CatalogCheck.json"
    try { $online = (Build-VendorCatalog -Vendor $Vendor -TargetPath $probe).Version }
    finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }

    if (-not $current)          { Write-Log "$($Vendor.Name): no local catalog. Online version is $online." -Level WARN }
    elseif ($current -ne $online) { Write-Log "$($Vendor.Name): update available $current -> $online. Run -Action GetCatalog." -Level WARN }
    else                        { Write-Log "$($Vendor.Name): catalog is up to date ($current)." }
}

function Get-VendorCatalog {
    param([pscustomobject]$Vendor)
    if (-not $CatalogCache[$Vendor.Short]) {
        if (-not (Test-Path $Vendor.Catalog)) { Update-Catalog $Vendor }
        $CatalogCache[$Vendor.Short] = Get-Content $Vendor.Catalog -Raw | ConvertFrom-Json
    }
    return $CatalogCache[$Vendor.Short]
}

# --- Hardware detection & ComputerModels.csv ---
function Resolve-Vendor {
    param([string]$Name)
    if (-not $Name) { return $null }
    switch -Regex ($Name.Trim()) {
        '^Dell'                    { return $Vendors.Dell }
        '^Lenovo'                  { return $Vendors.Lenovo }
        '^(HP|Hewlett[- ]?Packard)' { return $Vendors.HP }
        '^Custom(_.*)?$'           { return $Vendors.Custom }
    }
    return $null
}

function Get-CsvCustomManufacturer {
    # "Custom_Panasonic" -> "Panasonic". Older CSVs kept it in a separate CustomManufacturer column.
    param([pscustomobject]$Row)
    if ([string]$Row.Manufacturer -match '^\s*Custom_(.+)$') { return $Matches[1].Trim() }
    return ([string]$Row.CustomManufacturer).Trim()
}

function Get-LocalSystem {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $vendor = if ($Manufacturer) { Resolve-Vendor $Manufacturer } else { Resolve-Vendor $cs.Manufacturer }
    $model = [string]$cs.Model
    $sku = [string]$cs.SystemSKUNumber

    switch ($vendor.Short) {
        'Lenovo' {
            # SystemSKUNumber is LENOVO_MT_21KC_BU_...; Model is the machine type (21KC004AUS); the product name is in Version.
            $sku = if ($sku -match 'LENOVO_MT_(\w{4})') { $Matches[1] } elseif ($model -match '^(\w{4})') { $Matches[1] } else { $sku }
            $productName = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).Version
            if ($productName) { $model = $productName }
        }
        'HP' {
            # HP catalogs use the platform ID from the baseboard (e.g. 8870), not SystemSKUNumber.
            $sku = (Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue).Product
        }
    }
    if (-not $sku) { $sku = (Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue).Product }

    return [pscustomobject]@{
        Manufacturer       = if ($vendor) { $vendor.Name } else { [string]$cs.Manufacturer }
        SystemManufacturer = ([string]$cs.Manufacturer).Trim()
        Vendor             = $vendor
        Model              = if ($ComputerModel) { $ComputerModel } else { $model.Trim() }
        SystemSKU          = if ($SystemSKU) { $SystemSKU } else { ([string]$sku).Trim().ToUpper() }
    }
}

function Get-SupportRows {
    if (-not (Test-Path $ModelsCsvPath)) { throw "ComputerModels.csv not found: $ModelsCsvPath" }
    foreach ($row in Import-Csv $ModelsCsvPath) {
        $sku = ([string]$row.SystemSKUNumber).Trim()
        $model = ([string]$row.ComputerModel).Trim()
        if (-not $sku -and -not $model) { continue }

        $vendor = Resolve-Vendor $row.Manufacturer
        if (-not $vendor) {
            Write-Log "Skipping CSV row with unsupported manufacturer '$($row.Manufacturer)'." -Level WARN
            continue
        }
        [pscustomobject]@{
            Vendor             = $vendor
            SystemSKU          = $sku
            ComputerModel      = $model
            CustomManufacturer = if ($vendor -eq $Vendors.Custom) { Get-CsvCustomManufacturer $row } else { '' }
        }
    }
}

function Add-SupportRow {
    param([pscustomobject]$Vendor, [string]$Sku, [string]$Model, [string]$CustomManufacturer)
    $rows = @(if (Test-Path $ModelsCsvPath) { Import-Csv $ModelsCsvPath })
    $exists = $rows | Where-Object {
        (Resolve-Vendor $_.Manufacturer) -eq $Vendor -and
        ($Vendor -ne $Vendors.Custom -or (Get-CsvCustomManufacturer $_) -eq $CustomManufacturer) -and
        (($Sku -and $_.SystemSKUNumber -eq $Sku) -or ($Model -and $_.ComputerModel -eq $Model))
    }
    if ($exists) { return }

    # Rewrite every row in the three-column layout, converting the old CustomManufacturer column to Custom_<Maker>.
    $rows = @($rows | ForEach-Object {
        $manufacturer = if ((Resolve-Vendor $_.Manufacturer) -eq $Vendors.Custom) { Get-CustomLabel (Get-CsvCustomManufacturer $_) } else { $_.Manufacturer }
        [pscustomobject]@{ Manufacturer = $manufacturer; SystemSKUNumber = $_.SystemSKUNumber; ComputerModel = $_.ComputerModel }
    })
    $csvManufacturer = if ($Vendor -eq $Vendors.Custom) { Get-CustomLabel $CustomManufacturer } else { $Vendor.Short }
    $rows += [pscustomobject]@{ Manufacturer = $csvManufacturer; SystemSKUNumber = $Sku; ComputerModel = $Model }
    $rows | Export-Csv -Path $ModelsCsvPath -NoTypeInformation -Encoding UTF8
    Write-Log "Added to ComputerModels.csv: $csvManufacturer, $Sku, $Model"
}

function Find-CustomRow {
    # A Custom row matches on SKU or model; a Custom_<Maker> row also requires the machine's manufacturer
    # to start with <Maker> (e.g. Custom_Microsoft matches "Microsoft Corporation").
    # Custom_<Maker> rows are more specific, so they win over plain Custom rows.
    param([pscustomobject]$System, [switch]$AnyManufacturer)
    if (-not (Test-Path $ModelsCsvPath)) { return $null }
    return Get-SupportRows | Where-Object {
        $_.Vendor -eq $Vendors.Custom -and
        ($AnyManufacturer -or -not $_.CustomManufacturer -or $System.SystemManufacturer -like "$($_.CustomManufacturer)*") -and
        (($System.SystemSKU -and $_.SystemSKU -eq $System.SystemSKU) -or ($System.Model -and $_.ComputerModel -eq $System.Model))
    } | Sort-Object { -not $_.CustomManufacturer } | Select-Object -First 1
}

# --- Custom models ---
function Get-CustomContentLocation {
    param([string]$Model, [string]$Sku)
    $name = if ($Model) { $Model } else { $Sku }
    if (-not $name) { throw 'Custom models require -ComputerModel or -SystemSKU.' }
    return "Custom\$(Get-SafeName $name)\Content"
}

function Get-CustomLabel {
    # The value used in the CSV Manufacturer column and in the console: Custom or Custom_<Maker>.
    param([string]$CustomManufacturer)
    if ($CustomManufacturer) { return "Custom_$CustomManufacturer" }
    return 'Custom'
}

function Add-CustomModel {
    # Creates the Custom\<Model>\Content folder, CSV row, and LocalCatalog.json record if they are missing.
    param([string]$Model, [string]$Sku, [string]$CustomManufacturer)
    $location = Get-CustomContentLocation $Model $Sku
    $contentPath = Join-Path $DriversPath $location
    New-Directory $contentPath

    Add-SupportRow -Vendor $Vendors.Custom -Sku $Sku -Model $Model -CustomManufacturer $CustomManufacturer
    Save-PackRecord -Vendor $Vendors.Custom -Record ([pscustomobject]@{
        Manufacturer     = if ($CustomManufacturer) { $CustomManufacturer } else { $null }
        SystemSKU        = @($Sku | Where-Object { $_ })
        Model            = if ($Model) { $Model } else { $Sku }
        ContentLocation  = $location
        ContentExtracted = (Test-FolderHasContent $contentPath)
        MatchBy          = if ($Sku) { 'SKU' } else { 'Model' }
    })
    return $contentPath
}

# --- Driver pack lookup ---
function Get-PackBuild {
    # Highest build of $OSCode a pack lists (e.g. 25H2) plus a sortable number (25H2 -> 2512, 1809 -> 1809).
    # Dell publishes one pack per OS, so its packs have no build.
    param([pscustomobject]$Pack)
    $best = [pscustomobject]@{ Name = ''; Number = 0 }
    foreach ($tag in $Pack.OS) {
        if ($tag -notmatch "^${OSCode}_(\w{4})$") { continue }
        $build = $Matches[1]
        $number = if ($build -match '^(\d{2})H([12])$') { [int]($Matches[1] + $(if ($Matches[2] -eq '1') { '06' } else { '12' })) }
                  elseif ($build -match '^\d{4}$') { [int]$build }
                  else { 0 }
        if ($number -gt $best.Number) { $best = [pscustomobject]@{ Name = $build.ToUpper(); Number = $number } }
    }
    return $best
}

function Get-OsVersion {
    # Human-readable OS for a pack: "Windows 11 25H2", "Windows 11" (Dell), "WinPE 11".
    param([pscustomobject]$Pack)
    $release = $OSCode -replace '^Windows', ''
    if ($Pack.Type -eq 'winpe') { return "WinPE $release" }
    $build = (Get-PackBuild $Pack).Name
    return "Windows $release $build".Trim()
}

function Find-DriverPack {
    param([pscustomobject]$Vendor, [string]$Sku, [string]$Model)
    $packs = @((Get-VendorCatalog $Vendor).DriverPackages)

    if ("$Sku $Model" -match 'winpe') {
        $peTag = if ($OSCode -eq 'Windows10') { 'winpe10x' } else { 'winpe11x' }
        $best = $packs | Where-Object { $_.Type -eq 'winpe' -and $_.OS -contains $peTag } | Sort-Object Date -Descending | Select-Object -First 1
        if ($best) {
            $best | Add-Member -NotePropertyName MatchBy -NotePropertyValue 'WinPE' -Force
            $best | Add-Member -NotePropertyName OSVersion -NotePropertyValue (Get-OsVersion $best) -Force
        }
        return $best
    }

    $osPacks = @($packs | Where-Object { $_.Type -eq 'win' -and $_.OS -contains $OSCode })
    $candidates = @()
    $matchBy = 'SKU'
    if ($Sku) {
        $paddedSku = $Sku.PadLeft(4, '0')
        $candidates = @($osPacks | Where-Object { $_.SystemSKUs -contains $Sku -or $_.SystemSKUs -contains $paddedSku })
    }
    if (-not $candidates -and $Model) {
        $candidates = @($osPacks | Where-Object { $_.Models -contains $Model })
        $matchBy = 'Model'
    }

    # Newest package wins. When release dates tie (Lenovo publishes every build on the same date),
    # the highest Windows build wins (25H2 over 24H2).
    $best = $candidates | Sort-Object Date, { (Get-PackBuild $_).Number } -Descending | Select-Object -First 1
    if ($best) {
        $best | Add-Member -NotePropertyName MatchBy -NotePropertyValue $matchBy -Force
        $best | Add-Member -NotePropertyName OSVersion -NotePropertyValue (Get-OsVersion $best) -Force
    }
    return $best
}

function Get-PackTarget {
    param([pscustomobject]$Vendor, [pscustomobject]$Pack, [string]$Model, [string]$Sku)
    $name = if ($Pack.Models) { @($Pack.Models)[0] } elseif ($Model) { $Model } else { $Sku }
    return [pscustomobject]@{ Model = $name; ContentLocation = "$(Get-SafeName $Vendor.Name)\$(Get-SafeName $name)\Content" }
}

# --- Download & extraction ---
function Expand-Pack {
    param([string]$Archive, [string]$Destination, [pscustomobject]$Vendor, [string]$Format)
    New-Directory $Destination
    $fileName = Split-Path $Archive -Leaf

    if ($Format -eq 'cab') {
        & expand.exe $Archive -F:* $Destination | Out-Null
        $exitCode = $LASTEXITCODE
    }
    else {
        if ($IsWinPE -and [Environment]::Is64BitOperatingSystem -and (Test-Is32BitExe $Archive)) {
            throw "$fileName is a 32-bit extractor and can't run in WinPE x64. Extract it on a full OS and copy the Content folder."
        }
        $arguments = switch ($Vendor.Short) {
            'Lenovo' { "/VERYSILENT /SUPPRESSMSGBOXES /DIR=`"$Destination`" /EXTRACT=YES" }
            'HP'     { "/s /e /f `"$Destination`"" }
            default  { "/s /e=`"$Destination`"" }
        }
        $exitCode = (Start-Process -FilePath $Archive -ArgumentList $arguments -Wait -PassThru -NoNewWindow).ExitCode
    }

    # HP SoftPaqs return 1168 (Element not found) after a successful extract-only run.
    $successCodes = if ($Vendor.Short -eq 'HP') { 0, 1168 } else { 0 }
    $hasDrivers = [bool](Get-ChildItem $Destination -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($successCodes -notcontains $exitCode -or -not $hasDrivers) {
        $reason = if ($successCodes -notcontains $exitCode) { "exit code ${exitCode}: $([ComponentModel.Win32Exception]::new($exitCode).Message)" } else { 'no .inf files were extracted' }
        throw "Extraction failed for $fileName ($reason)."
    }
}

function Get-CustomContent {
    # With -AllowEmpty, an empty folder is a warning and returns $null instead of failing.
    param([string]$Sku, [string]$Model, [string]$CustomManufacturer, [switch]$AllowEmpty)
    $contentPath = Add-CustomModel -Model $Model -Sku $Sku -CustomManufacturer $CustomManufacturer
    $label = Get-CustomLabel $CustomManufacturer
    if (-not (Test-FolderHasContent $contentPath)) {
        $message = "No drivers staged for $label model '$(if ($Model) { $Model } else { $Sku })'. Copy them into $contentPath."
        if ($AllowEmpty) { Write-Log $message -Level WARN; return $null }
        throw $message
    }
    Reset-DirectoryAcl $contentPath
    Write-Log "$label drivers ready: $contentPath"
    return [pscustomobject]@{
        Manufacturer = $label; Model = $Model; SystemSKU = $Sku; FileName = $null
        ArchivePath  = $null; ContentPath = $contentPath; ContentExtracted = $true
    }
}

function Invoke-DownloadRow {
    param([pscustomobject]$Vendor, [string]$Sku, [string]$Model, [string]$CustomManufacturer)
    if ($Vendor -eq $Vendors.Custom) { return Get-CustomContent -Sku $Sku -Model $Model -CustomManufacturer $CustomManufacturer }

    $pack = Find-DriverPack -Vendor $Vendor -Sku $Sku -Model $Model
    if (-not $pack) { throw "No $($Vendor.Short) driver pack found for SKU '$Sku' / model '$Model' ($OSCode)." }

    $target      = Get-PackTarget -Vendor $Vendor -Pack $pack -Model $Model -Sku $Sku
    $contentPath = Join-Path $DriversPath $target.ContentLocation
    $modelPath   = Split-Path $contentPath -Parent
    $archive     = Join-Path $modelPath $pack.FileName
    $result      = [pscustomobject]@{
        Manufacturer = $Vendor.Name; Model = $target.Model; SystemSKU = $Sku; FileName = $pack.FileName
        OSVersion    = $pack.OSVersion; ReleaseDate = $pack.Date
        ArchivePath  = $archive; ContentPath = $contentPath; ContentExtracted = $false
    }

    Write-Log "=== $($Vendor.Name) / $($target.Model) | $($pack.OSVersion) | Released $($pack.Date) | $($pack.FileName) | SKU $Sku (matched by $($pack.MatchBy)) ==="

    $record    = Get-PackRecord -Vendor $Vendor -ContentLocation $target.ContentLocation
    $isCurrent = $record -and $record.FileName -eq $pack.FileName
    if ($isCurrent -and $record.ContentExtracted -and (Test-FolderHasContent $contentPath)) {
        Write-Log "Up to date: $contentPath"
        $result.ContentExtracted = $true
        return $result
    }
    if ($isCurrent -and -not $Extract -and (Test-Path $archive)) {
        Write-Log "Already downloaded (not extracted): $archive"
        return $result
    }

    # WinPE consumes pre-staged drivers: an update there usually can't be extracted (32-bit extractors)
    # and would discard drivers that already work, so keep what is extracted and update from a full OS.
    if ($IsWinPE -and $Extract -and $record -and $record.ContentExtracted -and (Test-FolderHasContent $contentPath)) {
        Write-Log "Newer pack $($pack.FileName) is available, but WinPE keeps the extracted $($record.FileName). Run Download from a full OS to update." -Level WARN
        $result.FileName = $record.FileName
        $result.OSVersion = $record.OSVersion
        $result.ReleaseDate = $record.ReleaseDate
        $result.ContentExtracted = $true
        return $result
    }

    New-Directory $modelPath
    if ((Test-Path $archive) -and (Test-PackHash $archive $pack)) {
        Write-Log "Using existing archive $archive"
        $downloadedOn = if ($isCurrent -and $record.DownloadedOn) { $record.DownloadedOn } else { (Get-Date).ToString('s') }
    }
    else {
        Write-Log "Downloading $($pack.Url)"
        Save-Url -Url $pack.Url -Path $archive
        if (-not (Test-PackHash $archive $pack)) {
            Remove-Item $archive -Force
            throw "Hash mismatch for $($pack.FileName). The archive was deleted."
        }
        $downloadedOn = (Get-Date).ToString('s')
    }
    Get-ChildItem $modelPath -File | Where-Object Name -ne $pack.FileName | Remove-Item -Force

    # Saved before extracting so LocalCatalog.json reflects the download even if extraction fails.
    $newRecord = [pscustomobject]@{
        SystemSKU        = @(@($Sku) + @($pack.SystemSKUs) | Where-Object { $_ } | Select-Object -Unique)
        Model            = $target.Model
        FileName         = $pack.FileName
        ContentLocation  = $target.ContentLocation
        OSVersion        = $pack.OSVersion
        ReleaseDate      = $pack.Date
        Format           = $pack.Format
        Size             = $pack.Size
        SHA256           = $pack.SHA256
        Url              = $pack.Url
        DownloadedOn     = $downloadedOn
        ContentExtracted = $false
        ExtractedOn      = $null
        MatchBy          = $pack.MatchBy
    }
    Save-PackRecord -Vendor $Vendor -Record $newRecord

    if (-not $Extract) {
        Write-Log "Downloaded (not extracted): $archive"
        return $result
    }

    # Extract into a staging folder, then swap it in. The old Content is only deleted once the new one is
    # in place, so a failed extraction or a locked file never leaves the model without working drivers.
    $staging = "$contentPath.new"
    $previous = "$contentPath.old"
    Remove-Item $staging, $previous -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Extracting to $contentPath..."
    try { Expand-Pack -Archive $archive -Destination $staging -Vendor $Vendor -Format $pack.Format }
    catch { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue; throw }

    try {
        if (Test-Path $contentPath) { Rename-Item $contentPath (Split-Path $previous -Leaf) }
        Rename-Item $staging 'Content'
    }
    catch {
        if (-not (Test-Path $contentPath) -and (Test-Path $previous)) { Rename-Item $previous 'Content' }
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw "Could not replace $contentPath; close any program using it and run Download again. $($_.Exception.Message)"
    }
    Remove-Item $previous -Recurse -Force -ErrorAction SilentlyContinue
    Reset-DirectoryAcl $contentPath

    $newRecord.ContentExtracted = $true
    $newRecord.ExtractedOn = (Get-Date).ToString('s')
    Save-PackRecord -Vendor $Vendor -Record $newRecord
    Write-Log "Ready: $contentPath"
    $result.ContentExtracted = $true
    return $result
}

function Invoke-LocalDownload {
    $system = Get-LocalSystem
    Write-Log "Detected: $($system.Manufacturer) / $($system.Model) / SKU $($system.SystemSKU)"

    # A matching Custom row in ComputerModels.csv takes priority, which also covers unsupported vendors.
    # With an explicit -Manufacturer Custom, the row's CustomManufacturer is not checked against the hardware.
    $custom = if (-not $Manufacturer) { Find-CustomRow $system }
              elseif ($system.Vendor -eq $Vendors.Custom) { Find-CustomRow $system -AnyManufacturer }
    if ($custom) {
        # An empty custom folder falls back to the vendor catalog, unless Custom was requested explicitly.
        $result = Get-CustomContent -Sku $custom.SystemSKU -Model $custom.ComputerModel -CustomManufacturer $custom.CustomManufacturer -AllowEmpty:(-not $Manufacturer)
        if ($result) { return $result }
    }
    if (-not $system.Vendor) {
        throw "Unsupported manufacturer '$($system.Manufacturer)'. Register this model with -Action AddCustom."
    }

    $result = Invoke-DownloadRow -Vendor $system.Vendor -Sku $system.SystemSKU -Model $system.Model
    if ($AddSupport) {
        try { Add-SupportRow -Vendor $system.Vendor -Sku $system.SystemSKU -Model $system.Model }
        catch { Write-Log "Could not update ComputerModels.csv: $($_.Exception.Message)" -Level WARN }
    }
    return $result
}

function Invoke-FleetDownload {
    param([pscustomobject[]]$TargetVendors)
    $rows = @(Get-SupportRows | Where-Object { $TargetVendors -contains $_.Vendor })
    Write-Log "Processing $($rows.Count) model(s)..."
    $failed = 0
    foreach ($row in $rows) {
        try {
            # Custom drivers are staged by hand: make sure the folder and record exist, and only warn when empty.
            if ($row.Vendor -eq $Vendors.Custom) { Get-CustomContent -Sku $row.SystemSKU -Model $row.ComputerModel -CustomManufacturer $row.CustomManufacturer -AllowEmpty }
            else { Invoke-DownloadRow -Vendor $row.Vendor -Sku $row.SystemSKU -Model $row.ComputerModel }
        }
        catch { $failed++; Write-Log $_.Exception.Message -Level ERROR }
    }
    if ($failed) { throw "$failed of $($rows.Count) model(s) failed." }
}

# --- Search ---
function Format-PackOS {
    # All OS versions a pack lists, e.g. "Windows 11 (22H2, 23H2, 24H2); Windows 10 (22H2)" or "WinPE 11".
    param([pscustomobject]$Pack)
    $families = foreach ($family in @($Pack.OS | Where-Object { $_ -notmatch '_' })) {
        $builds = @($Pack.OS | Where-Object { $_ -like "${family}_*" } | ForEach-Object { ($_ -split '_')[1] })
        $name = $family -replace '^Windows(\d)', 'Windows $1' -replace '^winpe(\d+)x$', 'WinPE $1'
        if ($builds) { "$name ($($builds -join ', '))" } else { $name }
    }
    return $families -join '; '
}

function Search-Catalogs {
    # SKU is an exact match; model is a case-insensitive partial match (wildcards allowed). Both must match when given.
    if (-not $SystemSKU -and -not $ComputerModel) { throw 'Search requires -SystemSKU and/or -ComputerModel.' }
    $targets = if ($Manufacturer -and $Manufacturer -ne 'All') { @(Resolve-Vendor $Manufacturer) } else { @($Vendors.Values) }
    $sku = $SystemSKU.Trim()
    $paddedSku = $sku.PadLeft(4, '0')

    foreach ($vendor in @($targets | Where-Object { $_.Catalog })) {
        foreach ($pack in (Get-VendorCatalog $vendor).DriverPackages) {
            if ($sku -and $pack.SystemSKUs -notcontains $sku -and $pack.SystemSKUs -notcontains $paddedSku) { continue }
            $models = @($pack.Models)
            if ($ComputerModel) {
                $models = @($models | Where-Object { $_ -like "*$ComputerModel*" })
                if (-not $models) { continue }
            }
            [pscustomobject]@{
                Manufacturer = $vendor.Short
                Model        = if ($models) { $models[0] } else { '' }
                SystemSKUs   = @($pack.SystemSKUs) -join ','
                OS           = Format-PackOS $pack
                ReleaseDate  = $pack.Date
                Version      = $pack.Version
                FileName     = $pack.FileName
            }
        }
    }
}

# --- Status & Sync ---
function Get-Status {
    param([pscustomobject[]]$TargetVendors)
    foreach ($row in @(Get-SupportRows | Where-Object { $TargetVendors -contains $_.Vendor })) {
        $status = [ordered]@{ Manufacturer = $row.Vendor.Short; Model = $row.ComputerModel; SystemSKU = $row.SystemSKU; Status = ''; MatchBy = ''; OSVersion = ''; ReleaseDate = ''; FileName = '' }

        if ($row.Vendor -eq $Vendors.Custom) {
            $status.Manufacturer = Get-CustomLabel $row.CustomManufacturer
            $contentPath = Join-Path $DriversPath (Get-CustomContentLocation $row.ComputerModel $row.SystemSKU)
            $status.Status = if (Test-FolderHasContent $contentPath) { 'Ready' } else { 'Empty' }
        }
        else {
            $pack = Find-DriverPack -Vendor $row.Vendor -Sku $row.SystemSKU -Model $row.ComputerModel
            if (-not $pack) {
                $status.Status = 'NotInCatalog'
            }
            else {
                $target = Get-PackTarget -Vendor $row.Vendor -Pack $pack -Model $row.ComputerModel -Sku $row.SystemSKU
                $record = Get-PackRecord -Vendor $row.Vendor -ContentLocation $target.ContentLocation
                $contentPath = Join-Path $DriversPath $target.ContentLocation
                $hasContent = Test-FolderHasContent $contentPath
                $hasArchive = Test-Path (Join-Path (Split-Path $contentPath -Parent) $pack.FileName)
                $isCurrent = $record -and $record.FileName -eq $pack.FileName

                $status.Model       = $target.Model
                $status.MatchBy     = $pack.MatchBy
                $status.FileName    = $pack.FileName
                $status.OSVersion   = $pack.OSVersion
                $status.ReleaseDate = $pack.Date
                $status.Status      = if ($isCurrent -and $record.ContentExtracted -and $hasContent) { 'Current' }
                                      elseif ($isCurrent -and $hasArchive) { 'Downloaded' }
                                      elseif ($hasContent) { 'UpdateAvailable' }
                                      else { 'NotDownloaded' }
            }
        }
        [pscustomobject]$status
    }
}

function Test-PackMatchesSupportRow {
    # ComputerModels.csv is the fleet list; LocalCatalog packs must still map to a CSV row.
    param([pscustomobject]$Vendor, [pscustomobject]$Record, [pscustomobject[]]$SupportRows)

    $rows = @($SupportRows | Where-Object { $_.Vendor -eq $Vendor })
    if (-not $rows) { return $false }

    $recModel = [string]$Record.Model
    $recSkus  = @($Record.SystemSKU | ForEach-Object { "$_".Trim().ToUpper() } | Where-Object { $_ })
    $recLoc   = [string]$Record.ContentLocation

    foreach ($row in $rows) {
        if ($Vendor -eq $Vendors.Custom) {
            $expected = Get-CustomContentLocation $row.ComputerModel $row.SystemSKU
            if ($recLoc -and ((Resolve-ContentPath $recLoc) -eq (Resolve-ContentPath $expected))) { return $true }
            if ($row.ComputerModel -and $recModel -and ($row.ComputerModel -eq $recModel)) { return $true }
            if ($row.SystemSKU -and ($recSkus -contains $row.SystemSKU.ToUpper())) { return $true }
            continue
        }

        if ($row.SystemSKU -and ($recSkus -contains $row.SystemSKU.ToUpper())) { return $true }
        if ($row.ComputerModel -and $recModel -and ($row.ComputerModel -eq $recModel)) { return $true }

        if ($recLoc -and $row.ComputerModel) {
            $expected = "$(Get-SafeName $Vendor.Name)\$(Get-SafeName $row.ComputerModel)\Content"
            if ((Resolve-ContentPath $recLoc) -eq (Resolve-ContentPath $expected)) { return $true }
        }
    }
    return $false
}

function Sync-LocalCatalog {
    # Reconcile LocalCatalog.json with ComputerModels.csv and on-disk packs:
    #  - drop packs with no archive/content (Custom: drop when model folder is gone)
    #  - drop packs that no longer appear in ComputerModels.csv
    param([pscustomobject[]]$TargetVendors)
    $catalog = Get-LocalCatalog
    $supportRows = @()
    try { $supportRows = @(Get-SupportRows) }
    catch { Write-Log "ComputerModels.csv missing during Sync; pruning by disk only. $($_.Exception.Message)" -Level WARN }

    foreach ($vendor in $TargetVendors) {
        $entry = $catalog.Manufacturers.($vendor.Name)
        if (-not $entry) { continue }
        $before = @($entry.DrivePacks).Count
        $kept = foreach ($record in @($entry.DrivePacks | Where-Object { $_ })) {
            $contentPath = Resolve-ContentPath $record.ContentLocation
            $modelPath = Split-Path $contentPath -Parent
            $hasContent = Test-FolderHasContent $contentPath

            if ($supportRows.Count -gt 0 -and -not (Test-PackMatchesSupportRow -Vendor $vendor -Record $record -SupportRows $supportRows)) {
                Write-Log "Sync drop (not in ComputerModels.csv): $($vendor.Name) / $($record.Model) / $($record.ContentLocation)"
                continue
            }

            if ($vendor -eq $Vendors.Custom) {
                # Custom records stay until their Custom\<Model> folder is deleted, even while it's empty.
                if (-not (Test-Path $modelPath)) { continue }
                $record.ContentExtracted = $hasContent
                $record
                continue
            }

            $hasArchive = $record.FileName -and (Test-Path (Join-Path $modelPath $record.FileName))
            if (-not $hasContent -and -not $hasArchive) { continue }
            $record.ContentExtracted = [bool]$record.ContentExtracted -and $hasContent
            $record
        }
        $kept = @($kept)
        $entry.DrivePacks = $kept
        Write-Log "$($vendor.Name): kept $($kept.Count) of $before record(s)."
    }
    Save-LocalCatalog $catalog
}

# --- Init ---
function Initialize-Engine {
    New-Directory $DriversPath
    New-Directory $TempPath
    New-Directory (Join-Path $DeploymentShare 'WorkLogs\Admin')
    New-Directory $ToolsPath
    if (-not (Test-Path $ModelsCsvPath)) {
        Set-Content -Path $ModelsCsvPath -Value "`"Manufacturer`",`"SystemSKUNumber`",`"ComputerModel`"`n`"Dell`",`"WinPE`",`"WinPE`"" -Encoding UTF8
    }
    if (-not (Test-Path $LocalCatalogPath)) { Save-LocalCatalog (Get-LocalCatalog) }
    if (-not (Get-CurlPath)) {
        try { Install-Curl }
        catch { Write-Log "Could not install curl; Invoke-WebRequest will be used. $($_.Exception.Message)" -Level WARN }
    }
    Write-Log "Ready. Share: $DeploymentShare | Drivers: $DriversPath | Temp: $TempPath | Log: $LogPath"
}

function Get-TargetVendors {
    if ($Manufacturer -eq 'All' -or ($All -and -not $Manufacturer)) { return @($Vendors.Values) }
    if ($Manufacturer) { return @(Resolve-Vendor $Manufacturer) }
    Write-Log "No vendor selected. Pass -Manufacturer <Dell|Lenovo|HP|Custom> or -All." -Level WARN
    return @()
}

# --- Main ---
try {
    # powershell.exe -File passes "$false" as text, so accept $true/$false, true/false, and 1/0.
    $Extract = switch -Regex ([string]$Extract) {
        '^\$?true$|^1$'  { $true }
        '^\$?false$|^0$' { $false }
        default          { throw "Invalid -Extract value '$Extract'. Use `$true or `$false." }
    }

    if ($Manufacturer -and $Manufacturer -ne 'All' -and -not (Resolve-Vendor $Manufacturer)) {
        throw "Unsupported manufacturer '$Manufacturer'. Use Dell, Lenovo, HP, Custom, Custom_<Maker>, or All."
    }

    switch ($Action) {
        'Init'        { Initialize-Engine }
        'GetCatalog'  { foreach ($v in @(Get-TargetVendors)) { if ($v.Catalog) { Update-Catalog $v } } }
        'CheckUpdate' { foreach ($v in @(Get-TargetVendors)) { if ($v.Catalog) { Test-CatalogUpdate $v } } }
        'Detect' {
            $system = Get-LocalSystem
            $system | Select-Object Manufacturer, Model, SystemSKU | Format-List
            if ($AddSupport) {
                if ($system.Vendor) { Add-SupportRow -Vendor $system.Vendor -Sku $system.SystemSKU -Model $system.Model }
                else { Write-Log "Unsupported manufacturer '$($system.Manufacturer)'. Use -Action AddCustom." -Level WARN }
            }
        }
        'Search' {
            $results = @(Search-Catalogs | Sort-Object Manufacturer, Model, @{ Expression = 'ReleaseDate'; Descending = $true }, @{ Expression = 'Version'; Descending = $true })
            if ($results) { Write-Log "$($results.Count) package(s) found."; $results | Format-Table -AutoSize }
            else { Write-Log 'No packages match.' -Level WARN }
        }
        'Status'      { Get-Status -TargetVendors @(Get-TargetVendors) | Format-Table -AutoSize }
        'Sync'        { Sync-LocalCatalog -TargetVendors @(Get-TargetVendors) }
        'Download' {
            if (-not (Test-IsAdmin)) { Write-Log 'Not running as administrator: HP packs will not extract and folder permissions are not reset.' -Level WARN }
            if ($All -or $Manufacturer -eq 'All') { Invoke-FleetDownload -TargetVendors @(Get-TargetVendors) }
            else { Invoke-LocalDownload }
        }
        'AddCustom' {
            $maker = if ($CustomManufacturer) { $CustomManufacturer.Trim() } elseif ($Manufacturer -match '^Custom_(.+)$') { $Matches[1].Trim() } else { '' }
            $contentPath = Add-CustomModel -Model $ComputerModel -Sku $SystemSKU -CustomManufacturer $maker
            Write-Log "Custom model registered. Copy its drivers into $contentPath"
        }
    }
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
exit 0
