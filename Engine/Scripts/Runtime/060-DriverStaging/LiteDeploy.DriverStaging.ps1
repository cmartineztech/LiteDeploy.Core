<#
.SYNOPSIS
    LiteDeploy DriverStaging — LocalCatalog detection and shared driver helpers (WinPE-first).

.DESCRIPTION
    Importable module for driver pack resolution against Content\Drivers\LocalCatalog.json.
    WorkflowSelection uses these helpers for UI selection; future staging apply will reuse them.

.NOTES
    Compatible with Set-StrictMode 2.0, PowerShell 5.1+, and WinPE 5.1/10/11.
    Flat Runtime layout: LogWriter + Hardware beside this script after SyncComponents.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Metadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "DriverStaging"
        Name                 = "LiteDeploy Driver Staging"
        Version              = "1.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("LogWriter", "Hardware")
        Description          = "LocalCatalog driver detection (Custom then OEM), folder/archive resolve, and media online reachability helpers. Pack extract/inject reserved for later."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# DEPENDENCIES (flat Runtime after SyncComponents)
# ==============================================================================

$logWriterModule = Join-Path $PSScriptRoot "LiteDeploy.LogWriter.ps1"
if (-not (Test-Path -LiteralPath $logWriterModule -PathType Leaf)) {
    $logWriterModule = Join-Path $PSScriptRoot "..\000-LogWriter\LiteDeploy.LogWriter.ps1"
}
if (-not (Test-Path -LiteralPath $logWriterModule -PathType Leaf)) {
    throw "LiteDeploy.LogWriter.ps1 was not found beside DriverStaging (flat Runtime) or under 000-LogWriter."
}
Import-Module -Name $logWriterModule -Force

$hardwareModule = Join-Path $PSScriptRoot "LiteDeploy.Hardware.ps1"
if (-not (Test-Path -LiteralPath $hardwareModule -PathType Leaf)) {
    $hardwareModule = Join-Path $PSScriptRoot "..\000-Hardware\LiteDeploy.Hardware.ps1"
}
if (-not (Test-Path -LiteralPath $hardwareModule -PathType Leaf)) {
    throw "LiteDeploy.Hardware.ps1 was not found beside DriverStaging (flat Runtime) or under 000-Hardware."
}
Import-Module -Name $hardwareModule -Force

# ==============================================================================
# INTERNET / ONLINE OFFER
# ==============================================================================

function Test-LiteDeployInternetConnection {
    param([int]$TimeoutMs = 2000)

    # Fast outbound probe for WinPE/full OS. Any success means offer online download.
    $endpoints = @(
        @{ Host = "1.1.1.1"; Port = 443 },
        @{ Host = "8.8.8.8"; Port = 53 }
    )

    foreach ($endpoint in $endpoints) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($endpoint.Host, [int]$endpoint.Port, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { continue }
            $client.EndConnect($async)
            return $true
        }
        catch { }
        finally {
            if ($null -ne $client) { try { $client.Close() } catch {} }
        }
    }

    return $false
}

function Test-OfferOnlineDriverDownload {
    param(
        [string]$DeploymentType,
        [bool]$AutoOnlineDownload
    )

    if ($DeploymentType -ne "Media" -or -not $AutoOnlineDownload) { return $false }
    return (Test-LiteDeployInternetConnection)
}

# ==============================================================================
# LOCALCATALOG DETECTION
# ==============================================================================

function Get-DriverPackPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Pack,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Pack) { return "" }
    foreach ($name in $Names) {
        if (-not $Pack.PSObject.Properties[$name]) { continue }
        $value = $Pack.$name
        if ($null -eq $value) { continue }
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text)) { return $text.Trim() }
    }
    return ""
}

function Get-DriverPackCatalogDetails {
    param(
        [Parameter(Mandatory = $true)]$Pack
    )

    $extracted = $true
    if ($Pack -and $Pack.PSObject.Properties["ContentExtracted"]) {
        $extracted = [bool]$Pack.ContentExtracted
    }

    return [PSCustomObject]@{
        PackModel        = (Get-DriverPackPropertyValue -Pack $Pack -Names @("Model"))
        FileName         = (Get-DriverPackPropertyValue -Pack $Pack -Names @("FileName", "Filename"))
        SHA256           = (Get-DriverPackPropertyValue -Pack $Pack -Names @("SHA256", "Hash", "FileHash"))
        ReleaseDate      = (Get-DriverPackPropertyValue -Pack $Pack -Names @("ReleaseDate", "ReleaseDateUTC", "Date", "PublishedDate"))
        DownloadedOn     = (Get-DriverPackPropertyValue -Pack $Pack -Names @("DownloadedOn", "DateDownloaded", "DownloadDate", "LastUpdate", "Downloaded"))
        ContentExtracted = $extracted
    }
}

function New-InBoxDriverDetection {
    param(
        [string]$Manufacturer = "",
        [string]$Model = "",
        [string]$SerialNumber = ""
    )

    return [PSCustomObject]@{
        Manufacturer     = $Manufacturer
        Model            = $Model
        SerialNumber     = $SerialNumber
        RelativePath     = "Standard OS In-Box Drivers (Windows Default)"
        FullPath         = $null
        IsDetected       = $false
        IsOem            = $false
        MatchBy          = $null
        CatalogPath      = $null
        ManufacturerKey  = $null
        PackModel        = $null
        FileName         = $null
        SHA256           = $null
        ReleaseDate      = $null
        DownloadedOn     = $null
        ContentExtracted = $null
        SourceKind       = $null
        HardwareSku      = $null
    }
}

function New-DriverPackHit {
    param(
        [Parameter(Mandatory = $true)]$Pack,
        [Parameter(Mandatory = $true)][string]$ManufacturerKey,
        [Parameter(Mandatory = $true)][string]$MatchReason,
        [Parameter(Mandatory = $true)][string]$ContentLocation,
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][ValidateSet("Content", "Archive")][string]$SourceKind
    )

    $details = Get-DriverPackCatalogDetails -Pack $Pack
    return [PSCustomObject]@{
        ManufacturerKey  = $ManufacturerKey
        Model            = $details.PackModel
        MatchBy          = $MatchReason
        ContentLocation  = $ContentLocation
        FullPath         = $FullPath
        RelativePath     = $RelativePath
        SourceKind       = $SourceKind
        IsOem            = ($ManufacturerKey -ne "Custom")
        PackModel        = $details.PackModel
        FileName         = $details.FileName
        SHA256           = $details.SHA256
        ReleaseDate      = $details.ReleaseDate
        DownloadedOn     = $details.DownloadedOn
        ContentExtracted = $details.ContentExtracted
    }
}

function Test-DriverManufacturerKeyMatch {
    param(
        [string]$ManufacturerKey,
        [string]$VendorRaw,
        [string]$VendorNormalized
    )

    if ([string]::IsNullOrWhiteSpace($ManufacturerKey)) { return $false }
    if ($ManufacturerKey -ieq "Custom") { return $false }

    $key = $ManufacturerKey.Trim()
    $candidates = @($VendorRaw, $VendorNormalized) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() }
    foreach ($vendor in $candidates) {
        if ($key -ieq $vendor) { return $true }
        if ($key -like "*$vendor*" -or $vendor -like "*$key*") { return $true }
    }
    return $false
}

function Test-DriverSystemSkuMatch {
    param(
        [string]$HardwareSku,
        [object]$CatalogSkus
    )

    if ([string]::IsNullOrWhiteSpace($HardwareSku) -or $null -eq $CatalogSkus) { return $false }
    $hw = $HardwareSku.Trim()
    $hwPadded = $hw.PadLeft(4, '0')
    foreach ($sku in @($CatalogSkus)) {
        if ($null -eq $sku -or [string]::IsNullOrWhiteSpace([string]$sku)) { continue }
        $catalogSku = ([string]$sku).Trim()
        $catalogPadded = $catalogSku.PadLeft(4, '0')
        if ($hw -ieq $catalogSku -or $hwPadded -ieq $catalogSku -or $hw -ieq $catalogPadded -or $hwPadded -ieq $catalogPadded) { return $true }
        if ($hw.Length -ge $catalogSku.Length -and $hw.StartsWith($catalogSku, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($hw -match ("(?i)(?:^|[^A-Za-z0-9]){0}(?:$|[^A-Za-z0-9])" -f [regex]::Escape($catalogSku))) { return $true }
    }
    return $false
}

function Test-DriverModelMatch {
    param(
        [string]$HardwareModel,
        [string]$CatalogModel
    )

    if ([string]::IsNullOrWhiteSpace($HardwareModel) -or [string]::IsNullOrWhiteSpace($CatalogModel)) { return $false }
    $hw = $HardwareModel.Trim()
    $cm = $CatalogModel.Trim()
    if ($hw -ieq $cm) { return $true }
    if ($hw -like "*$cm*" -or $cm -like "*$hw*") { return $true }
    return $false
}

function Test-DriverPackHasSystemSkus {
    param([object]$CatalogSkus)

    if ($null -eq $CatalogSkus) { return $false }
    foreach ($sku in @($CatalogSkus)) {
        if ($null -ne $sku -and -not [string]::IsNullOrWhiteSpace([string]$sku)) { return $true }
    }
    return $false
}

function Get-LiteDeployLocalDriverCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareRoot
    )

    $catalogPath = Join-Path $ShareRoot.TrimEnd('\') "Content\Drivers\LocalCatalog.json"
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        Write-LiteDeployLog " [WARNING] LocalCatalog.json was not found at '$catalogPath'. Using Standard OS In-Box Drivers." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
        return $null
    }

    try {
        $catalogData = Get-Content -LiteralPath $catalogPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-LiteDeployLog " [WARNING] LocalCatalog.json could not be parsed at '$catalogPath': $($_.Exception.Message). Using Standard OS In-Box Drivers." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
        return $null
    }

    if (-not $catalogData -or -not $catalogData.PSObject.Properties["Manufacturers"] -or $null -eq $catalogData.Manufacturers) {
        Write-LiteDeployLog " [WARNING] LocalCatalog.json is missing required 'Manufacturers' at '$catalogPath'. Using Standard OS In-Box Drivers." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
        return $null
    }

    Write-LiteDeployLog " [INFO]    Driver catalog loaded." -Level "INFO" -Component "DriverStaging"
    return [PSCustomObject]@{
        CatalogPath   = $catalogPath
        Manufacturers = $catalogData.Manufacturers
    }
}

function Test-DriverManufacturerValueMatch {
    param(
        [string]$CatalogManufacturer,
        [string]$VendorRaw,
        [string]$VendorNormalized
    )

    if ([string]::IsNullOrWhiteSpace($CatalogManufacturer)) { return $false }
    return (Test-DriverManufacturerKeyMatch -ManufacturerKey $CatalogManufacturer -VendorRaw $VendorRaw -VendorNormalized $VendorNormalized)
}

function Test-DriverFolderHasDriverFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [int]$MaxDepth = 10,
        [int]$MaxDirectories = 2500
    )

    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return $false
    }

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Path = $RootPath; Depth = 0 })
    $visited = 0

    while ($queue.Count -gt 0 -and $visited -lt $MaxDirectories) {
        $current = $queue.Dequeue()
        $visited++

        try {
            $directory = New-Object System.IO.DirectoryInfo($current.Path)
            foreach ($pattern in @("*.inf", "*.sys", "*.cat")) {
                foreach ($file in $directory.EnumerateFiles($pattern)) {
                    return $true
                }
            }

            if ($current.Depth -ge $MaxDepth) { continue }

            foreach ($subDirectory in $directory.EnumerateDirectories()) {
                if (($subDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $name = $subDirectory.Name
                if ($name -match '^(?i)(Windows|\$Recycle\.Bin|System Volume Information)$') { continue }
                $queue.Enqueue([pscustomobject]@{
                    Path  = $subDirectory.FullName
                    Depth = $current.Depth + 1
                })
            }
        }
        catch {
            # Access-denied / transient IO: keep scanning siblings.
        }
    }

    return $false
}

function Resolve-DriverPackHit {
    param(
        [Parameter(Mandatory = $true)]$Pack,
        [Parameter(Mandatory = $true)][string]$ManufacturerKey,
        [Parameter(Mandatory = $true)][string]$DriversRoot,
        [Parameter(Mandatory = $true)][string]$MatchReason
    )

    if ($null -eq $Pack) { return $null }

    $matchBy = if ($Pack.PSObject.Properties["MatchBy"] -and $Pack.MatchBy) { [string]$Pack.MatchBy } else { "" }
    if ($matchBy -ieq "WinPE") { return $null }

    $contentLocation = if ($Pack.PSObject.Properties["ContentLocation"] -and $Pack.ContentLocation) {
        ([string]$Pack.ContentLocation).Trim().TrimStart('\')
    } else { "" }
    if ([string]::IsNullOrWhiteSpace($contentLocation)) { return $null }

    $contentPath = Join-Path $DriversRoot $contentLocation
    $modelPath = Split-Path -Parent $contentPath
    $details = Get-DriverPackCatalogDetails -Pack $Pack
    $isDellOrLenovo = ($ManufacturerKey -like "*Dell*") -or ($ManufacturerKey -ieq "LENOVO") -or ($ManufacturerKey -like "*Lenovo*")

    # Dell / Lenovo: prefer extracted Content with driver files (depth 10); else use downloaded .exe beside Content.
    if ($isDellOrLenovo) {
        $contentOk = $details.ContentExtracted -and
            (Test-Path -LiteralPath $contentPath -PathType Container) -and
            (Test-DriverFolderHasDriverFiles -RootPath $contentPath -MaxDepth 10)

        if ($contentOk) {
            return (New-DriverPackHit -Pack $Pack -ManufacturerKey $ManufacturerKey -MatchReason $MatchReason `
                    -ContentLocation $contentLocation -FullPath $contentPath `
                    -RelativePath "Content\Drivers\$contentLocation" -SourceKind "Content")
        }

        # Archive path is derived only from LocalCatalog: parent(ContentLocation) + FileName.
        $fileName = $details.FileName
        if (-not [string]::IsNullOrWhiteSpace($fileName) -and -not [string]::IsNullOrWhiteSpace($modelPath)) {
            $archivePath = Join-Path $modelPath $fileName
            if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
                $expectedSha = $details.SHA256
                if (-not [string]::IsNullOrWhiteSpace($expectedSha)) {
                    try {
                        $actualSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash
                        if ($actualSha -ne $expectedSha) {
                            Write-LiteDeployLog " [WARNING] Driver archive SHA256 mismatch for '$archivePath'. Expected $expectedSha, got $actualSha. Skipping archive." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
                            return $null
                        }
                    }
                    catch {
                        Write-LiteDeployLog " [WARNING] Could not verify SHA256 for '$archivePath': $($_.Exception.Message). Skipping archive." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
                        return $null
                    }
                }

                $relArchive = Join-Path (Split-Path $contentLocation -Parent) $fileName
                return (New-DriverPackHit -Pack $Pack -ManufacturerKey $ManufacturerKey -MatchReason $MatchReason `
                        -ContentLocation $contentLocation -FullPath $archivePath `
                        -RelativePath "Content\Drivers\$relArchive" -SourceKind "Archive")
            }
        }

        return $null
    }

    # Custom: scan the model root (parent of ContentLocation) depth 5 for at least one driver file.
    if ($ManufacturerKey -ieq "Custom") {
        $customRoot = if (-not [string]::IsNullOrWhiteSpace($modelPath)) { $modelPath } else { $contentPath }
        if (-not (Test-Path -LiteralPath $customRoot -PathType Container)) { return $null }
        if (-not (Test-DriverFolderHasDriverFiles -RootPath $customRoot -MaxDepth 5)) { return $null }

        # Prefer ContentLocation when it exists; otherwise the model root that passed the scan.
        $selectedPath = if (Test-Path -LiteralPath $contentPath -PathType Container) { $contentPath } else { $customRoot }
        $relPath = if ($selectedPath -eq $contentPath) {
            "Content\Drivers\$contentLocation"
        } else {
            "Content\Drivers\$(Split-Path $contentLocation -Parent)"
        }

        return (New-DriverPackHit -Pack $Pack -ManufacturerKey $ManufacturerKey -MatchReason $MatchReason `
                -ContentLocation $contentLocation -FullPath $selectedPath `
                -RelativePath $relPath -SourceKind "Content")
    }

    # HP / others: extracted Content folder only.
    if (-not $details.ContentExtracted) { return $null }
    if (-not (Test-Path -LiteralPath $contentPath -PathType Container)) { return $null }

    return (New-DriverPackHit -Pack $Pack -ManufacturerKey $ManufacturerKey -MatchReason $MatchReason `
            -ContentLocation $contentLocation -FullPath $contentPath `
            -RelativePath "Content\Drivers\$contentLocation" -SourceKind "Content")
}

function Get-SystemDriverDetection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareRoot
    )

    $root = $ShareRoot.TrimEnd('\')
    $driversRoot = Join-Path $root "Content\Drivers"

    $vendorNorm = $null
    $vendorRaw = $null
    $model = $null
    $serial = $null
    $sku = $null
    try { $vendorNorm = Get-HardwareVendor } catch {}
    try { $vendorRaw = Get-HardwareVendorRaw } catch {}
    try { $model = Get-HardwareModel } catch {}
    try { $serial = Get-HardwareSerialNumber } catch {}
    try { $sku = Get-HardwareComputerSku } catch {}

    if ([string]::IsNullOrWhiteSpace($vendorNorm)) { $vendorNorm = "Unknown" }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = "Unknown" }

    $catalog = Get-LiteDeployLocalDriverCatalog -ShareRoot $root
    if (-not $catalog) {
        return (New-InBoxDriverDetection -Manufacturer $vendorNorm -Model $model -SerialNumber $serial)
    }

    $customNode = $null
    $oemNodes = @()
    foreach ($prop in @($catalog.Manufacturers.PSObject.Properties)) {
        if ($null -eq $prop) { continue }
        $key = [string]$prop.Name
        $node = $prop.Value
        if ($null -eq $node) { continue }

        $packs = @()
        if ($node.PSObject.Properties["DrivePacks"] -and $node.DrivePacks) {
            $packs = @($node.DrivePacks)
        }

        $entry = [PSCustomObject]@{
            Key   = $key
            Packs = $packs
        }

        if ($key -ieq "Custom") {
            $customNode = $entry
        }
        else {
            $oemNodes += $entry
        }
    }

    $winner = $null

    # 1) Custom: same object must match manufacturer + model + SKU
    if ($customNode) {
        foreach ($pack in @($customNode.Packs)) {
            $packMfr = if ($pack -and $pack.PSObject.Properties["Manufacturer"] -and $pack.Manufacturer) {
                [string]$pack.Manufacturer
            } else { "" }
            $packModel = if ($pack -and $pack.PSObject.Properties["Model"] -and $pack.Model) { [string]$pack.Model } else { "" }
            $packSkus = if ($pack -and $pack.PSObject.Properties["SystemSKU"]) { $pack.SystemSKU } else { @() }

            $mfrOk = Test-DriverManufacturerValueMatch -CatalogManufacturer $packMfr -VendorRaw $vendorRaw -VendorNormalized $vendorNorm
            $modelOk = Test-DriverModelMatch -HardwareModel $model -CatalogModel $packModel
            $skuOk = Test-DriverSystemSkuMatch -HardwareSku $sku -CatalogSkus $packSkus
            if (-not ($mfrOk -and $modelOk -and $skuOk)) { continue }

            $winner = Resolve-DriverPackHit -Pack $pack -ManufacturerKey "Custom" -DriversRoot $driversRoot -MatchReason "Custom:Manufacturer+Model+SKU"
            if ($winner) { break }
        }
    }

    # 2) Custom: manufacturer + SKU
    if (-not $winner -and $customNode) {
        foreach ($pack in @($customNode.Packs)) {
            $packMfr = if ($pack -and $pack.PSObject.Properties["Manufacturer"] -and $pack.Manufacturer) {
                [string]$pack.Manufacturer
            } else { "" }
            $packSkus = if ($pack -and $pack.PSObject.Properties["SystemSKU"]) { $pack.SystemSKU } else { @() }

            $mfrOk = Test-DriverManufacturerValueMatch -CatalogManufacturer $packMfr -VendorRaw $vendorRaw -VendorNormalized $vendorNorm
            $skuOk = Test-DriverSystemSkuMatch -HardwareSku $sku -CatalogSkus $packSkus
            if (-not ($mfrOk -and $skuOk)) { continue }

            $winner = Resolve-DriverPackHit -Pack $pack -ManufacturerKey "Custom" -DriversRoot $driversRoot -MatchReason "Custom:Manufacturer+SKU"
            if ($winner) { break }
        }
    }

    # 3) Custom: manufacturer + model (only when pack has no SystemSKU list — same model can map to many SKUs)
    if (-not $winner -and $customNode) {
        foreach ($pack in @($customNode.Packs)) {
            $packMfr = if ($pack -and $pack.PSObject.Properties["Manufacturer"] -and $pack.Manufacturer) {
                [string]$pack.Manufacturer
            } else { "" }
            $packModel = if ($pack -and $pack.PSObject.Properties["Model"] -and $pack.Model) { [string]$pack.Model } else { "" }
            $packSkus = if ($pack -and $pack.PSObject.Properties["SystemSKU"]) { $pack.SystemSKU } else { @() }
            if (Test-DriverPackHasSystemSkus -CatalogSkus $packSkus) { continue }

            $mfrOk = Test-DriverManufacturerValueMatch -CatalogManufacturer $packMfr -VendorRaw $vendorRaw -VendorNormalized $vendorNorm
            $modelOk = Test-DriverModelMatch -HardwareModel $model -CatalogModel $packModel
            if (-not ($mfrOk -and $modelOk)) { continue }

            $winner = Resolve-DriverPackHit -Pack $pack -ManufacturerKey "Custom" -DriversRoot $driversRoot -MatchReason "Custom:Manufacturer+Model"
            if ($winner) { break }
        }
    }

    # 4) OEM manufacturer objects: manufacturer key match, then SKU, then model-without-SKU-list
    if (-not $winner) {
        foreach ($mfr in $oemNodes) {
            if (-not (Test-DriverManufacturerKeyMatch -ManufacturerKey $mfr.Key -VendorRaw $vendorRaw -VendorNormalized $vendorNorm)) {
                continue
            }

            foreach ($pack in @($mfr.Packs)) {
                $packSkus = if ($pack -and $pack.PSObject.Properties["SystemSKU"]) { $pack.SystemSKU } else { @() }
                if (-not (Test-DriverSystemSkuMatch -HardwareSku $sku -CatalogSkus $packSkus)) { continue }

                $winner = Resolve-DriverPackHit -Pack $pack -ManufacturerKey $mfr.Key -DriversRoot $driversRoot -MatchReason "OEM:SKU"
                if ($winner) { break }
            }
            if ($winner) { break }

            foreach ($pack in @($mfr.Packs)) {
                $packModel = if ($pack -and $pack.PSObject.Properties["Model"] -and $pack.Model) { [string]$pack.Model } else { "" }
                $packSkus = if ($pack -and $pack.PSObject.Properties["SystemSKU"]) { $pack.SystemSKU } else { @() }
                # Packs that declare SystemSKU must match by SKU only (same model, different SKUs).
                if (Test-DriverPackHasSystemSkus -CatalogSkus $packSkus) { continue }
                if (-not (Test-DriverModelMatch -HardwareModel $model -CatalogModel $packModel)) { continue }

                $winner = Resolve-DriverPackHit -Pack $pack -ManufacturerKey $mfr.Key -DriversRoot $driversRoot -MatchReason "OEM:Model"
                if ($winner) { break }
            }
            if ($winner) { break }
        }
    }

    if (-not $winner) {
        return (New-InBoxDriverDetection -Manufacturer $vendorNorm -Model $model -SerialNumber $serial)
    }

    $sourceLabel = if ($winner.SourceKind -ieq "Archive") { "Archive" } elseif ($winner.SourceKind -ieq "Content") { "Content" } else { "Pack" }
    $packLabel = if (-not [string]::IsNullOrWhiteSpace([string]$winner.PackModel)) {
        [string]$winner.PackModel
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$winner.FileName)) {
        [string]$winner.FileName
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$winner.RelativePath)) {
        Split-Path -Path $winner.RelativePath -Leaf
    } else {
        "matched"
    }
    Write-LiteDeployLog (" [SUCCESS] Driver pack: {0} | {1} | {2}" -f $winner.MatchBy, $sourceLabel, $packLabel) -Level "SUCCESS" -ForegroundColor Green -Component "DriverStaging"

    return [PSCustomObject]@{
        Manufacturer     = $vendorNorm
        Model            = $model
        SerialNumber     = $serial
        RelativePath     = $winner.RelativePath
        FullPath         = $winner.FullPath
        IsDetected       = $true
        IsOem            = [bool]$winner.IsOem
        MatchBy          = $winner.MatchBy
        CatalogPath      = $catalog.CatalogPath
        ManufacturerKey  = $winner.ManufacturerKey
        PackModel        = $winner.PackModel
        FileName         = $winner.FileName
        SHA256           = $winner.SHA256
        ReleaseDate      = $winner.ReleaseDate
        DownloadedOn     = $winner.DownloadedOn
        ContentExtracted = $winner.ContentExtracted
        SourceKind       = $winner.SourceKind
        HardwareSku      = $sku
    }
}
