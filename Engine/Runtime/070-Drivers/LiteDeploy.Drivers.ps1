<#
.SYNOPSIS
    LiteDeploy Drivers - LocalCatalog detection and shared driver helpers (WinPE-first, architecture v2).

.DESCRIPTION
    Importable module for driver pack resolution against Content\Drivers\LocalCatalog.json.
    WorkflowSelection uses these helpers for UI selection; staging extracts into W:\~LiteDeploy\Content\Drivers.
    Standalone execution is non-destructive: detection against -ShareRoot (default Z:\).

.NOTES
    Compatible with Set-StrictMode 2.0, PowerShell 5.1+, and WinPE 5.1/10/11.
    Flat Runtime layout: LogWriter + Hardware beside this script after SyncComponents.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Metadata,

    # Standalone only: deployment share root (default Z:\ when mapped). Detection is read-only.
    [Parameter(Mandatory = $false)]
    [string]$ShareRoot = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ==============================================================================
# COMPONENT METADATA
# ==============================================================================

function Get-LiteDeployComponentMetadata {
    return [PSCustomObject]@{
        ComponentId          = "Drivers"
        Name                 = "LiteDeploy Driver Staging"
        Version              = "2.0.0"
        Category             = "Runtime"
        TargetEnvironment    = "WinPE"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @("Logs", "Hardware")
        Description          = "LocalCatalog driver detection (Custom then OEM), folder/archive resolve, extraction, and staging helpers."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# ==============================================================================
# DEPENDENCIES (flat Runtime after SyncComponents)
# ==============================================================================

# Engine normally provides both helpers. Standalone callers load Environment once first.
# Never reload a dependency already available in this session.
if (-not (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command Get-LiteDeployComponentPath -ErrorAction SilentlyContinue)) { throw 'Load Environment before Drivers.' }
    . (Get-LiteDeployComponentPath -Name Logs)
}
if (-not (Get-Command Get-HardwareInventory -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command Get-LiteDeployComponentPath -ErrorAction SilentlyContinue)) { throw 'Load Environment before Drivers.' }
    . (Get-LiteDeployComponentPath -Name Hardware)
}

function Test-LiteDeployInternetConnection {
    param([int]$TimeoutMs = 200)

    # Fast outbound probe for WinPE/full OS (200 ms timeout to prevent offline UI freeze).
    $endpoints = @(
        @{ Host = "1.1.1.1"; Port = 443 }
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
                # Fast file size metadata check (< 1ms SMB attribute check, ensures file is non-empty)
                try {
                    $item = Get-Item -LiteralPath $archivePath -ErrorAction Stop
                    if ($item.Length -le 0) {
                        Write-LiteDeployLog " [WARNING] Driver archive '$archivePath' is empty (0 bytes). Skipping archive." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
                        return $null
                    }
                }
                catch {
                    return $null
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
        [string]$ShareRoot,
        [Parameter(Mandatory = $false)]
        [psobject]$HardwareInventory = $null
    )

    $root = $ShareRoot.TrimEnd('\')
    $driversRoot = Join-Path $root "Content\Drivers"

    $vendorNorm = $null
    $vendorRaw = $null
    $model = $null
    $serial = $null
    $sku = $null

    if ($HardwareInventory) {
        if ($HardwareInventory.PSObject.Properties['Vendor'] -and $HardwareInventory.Vendor) { $vendorNorm = [string]$HardwareInventory.Vendor }
        if ($HardwareInventory.PSObject.Properties['Model'] -and $HardwareInventory.Model) { $model = [string]$HardwareInventory.Model }
        if ($HardwareInventory.PSObject.Properties['SerialNumber'] -and $HardwareInventory.SerialNumber) { $serial = [string]$HardwareInventory.SerialNumber }
        if ($HardwareInventory.PSObject.Properties['Sku'] -and $HardwareInventory.Sku) { $sku = [string]$HardwareInventory.Sku }
        if (Get-Command Write-LiteDeployLog -ErrorAction SilentlyContinue) {
            Write-LiteDeployLog "Fast Transition: Reused in-memory hardware inventory for $vendorNorm $model (0 ms WMI overhead)." -Level "INFO" -Component "Drivers"
        }
    }

    if ([string]::IsNullOrWhiteSpace($vendorNorm)) { try { $vendorNorm = Get-HardwareVendor } catch {} }
    if ([string]::IsNullOrWhiteSpace($vendorRaw)) { try { $vendorRaw = Get-HardwareVendorRaw } catch {} }
    if ([string]::IsNullOrWhiteSpace($model)) { try { $model = Get-HardwareModel } catch {} }
    if ([string]::IsNullOrWhiteSpace($serial)) { try { $serial = Get-HardwareSerialNumber } catch {} }
    if ([string]::IsNullOrWhiteSpace($sku)) { try { $sku = Get-HardwareComputerSku } catch {} }

    if ([string]::IsNullOrWhiteSpace($vendorNorm)) { $vendorNorm = "Unknown" }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = "Unknown" }

    $catalog = Get-LiteDeployLocalDriverCatalog -ShareRoot $root
    if (-not $catalog) {
        return (New-InBoxDriverDetection -Manufacturer $vendorNorm -Model $model -SerialNumber $serial)
    }

    $customNode = $null
    $oemNodes = @()
    $manufacturers = $null
    if ($catalog -and $catalog.PSObject.Properties["Manufacturers"]) {
        $manufacturers = $catalog.Manufacturers
    }
    if ($null -eq $manufacturers) {
        return (New-InBoxDriverDetection -Manufacturer $vendorNorm -Model $model -SerialNumber $serial)
    }

    foreach ($prop in @($manufacturers.PSObject.Properties)) {
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

    # 3) Custom: manufacturer + model (only when pack has no SystemSKU list - same model can map to many SKUs)
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

# ==============================================================================
# v2 API ALIASES & DRIVER STAGING
# ==============================================================================

function Resolve-LiteDeployDriverShareRoot {
    param([string]$ShareRoot = "")

    if (-not [string]::IsNullOrWhiteSpace($ShareRoot)) {
        return $ShareRoot.TrimEnd('\')
    }
    if (Test-Path -LiteralPath "Z:\") { return "Z:" }
    throw "ShareRoot is required (no Z:\ share is mapped)."
}

function Get-LiteDeployDriverCatalog {
    <#
    .SYNOPSIS
        Loads Content\Drivers\LocalCatalog.json. Returns $null when missing/invalid.
    #>
    [CmdletBinding()]
    param([string]$ShareRoot = "")

    return Get-LiteDeployLocalDriverCatalog -ShareRoot (Resolve-LiteDeployDriverShareRoot -ShareRoot $ShareRoot)
}

function Find-LiteDeployDriverPackage {
    <#
    .SYNOPSIS
        Detects the driver pack for this machine (Custom, then OEM; else in-box). Read-only.
    #>
    [CmdletBinding()]
    param([string]$ShareRoot = "")

    return Get-SystemDriverDetection -ShareRoot (Resolve-LiteDeployDriverShareRoot -ShareRoot $ShareRoot)
}

function Expand-LiteDeployDriverPackage {
    <#
    .SYNOPSIS
        Extracts OEM / vendor driver archives (.exe / .cab) into a destination directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Detection,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [string]$ArchivePath = ""
    )

    $isDetected = [bool]($Detection.PSObject.Properties["IsDetected"] -and $Detection.IsDetected)
    $sourceKind = if ($Detection.PSObject.Properties["SourceKind"]) { [string]$Detection.SourceKind } else { "" }
    $fullPath = if ($Detection.PSObject.Properties["FullPath"]) { [string]$Detection.FullPath } else { "" }

    if (-not $isDetected) {
        return [PSCustomObject]@{ Success = $true; Expanded = $false; Status = "InBox"; SourcePath = $null; ExpandedPath = $null; Message = "No driver pack detected; Windows in-box drivers will be used." }
    }
    if ($sourceKind -ieq "Content") {
        if (Test-DriverFolderHasDriverFiles -RootPath $fullPath -MaxDepth 10) {
            Write-LiteDeployLog " [INFO]    Driver pack content is already extracted: '$fullPath'" -Level "INFO" -Component "DriverStaging"
            return [PSCustomObject]@{ Success = $true; Expanded = $false; Status = "AlreadyExtracted"; SourcePath = $fullPath; ExpandedPath = $fullPath; Message = "Pack content is already extracted." }
        }
        Write-LiteDeployLog " [WARNING] Content folder '$fullPath' has no .inf driver files." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
        return [PSCustomObject]@{ Success = $false; Expanded = $false; Status = "NoDriverFiles"; SourcePath = $fullPath; ExpandedPath = $null; Message = "No .inf driver files found in folder." }
    }

    $targetArchive = if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath } else { $fullPath }
    if (-not (Test-Path -LiteralPath $targetArchive -PathType Leaf)) {
        Write-LiteDeployLog " [ERROR]   Driver archive was not found at '$targetArchive'." -Level "ERROR" -ForegroundColor Red -Component "DriverStaging"
        return [PSCustomObject]@{ Success = $false; Expanded = $false; Status = "ArchiveNotFound"; SourcePath = $targetArchive; ExpandedPath = $null; Message = "Archive not found." }
    }

    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
        $null = New-Item -Path $DestinationPath -ItemType Directory -Force -ErrorAction Stop
    }

    $archiveName = Split-Path -Path $targetArchive -Leaf
    Write-LiteDeployLog " [INIT]    Extracting driver archive '$archiveName' to '$DestinationPath'..." -Level "INIT" -ForegroundColor Cyan -Component "DriverStaging"

    $mfrKey = if ($Detection.PSObject.Properties["ManufacturerKey"]) { [string]$Detection.ManufacturerKey } else { "" }
    $mfrNorm = if ($Detection.PSObject.Properties["Manufacturer"]) { [string]$Detection.Manufacturer } else { "" }
    $isHp = ($mfrKey -like "*HP*") -or ($mfrNorm -like "*HP*") -or ($mfrNorm -like "*Hewlett*")
    $isLenovo = ($mfrKey -like "*Lenovo*") -or ($mfrNorm -like "*Lenovo*")

    $exitCode = -1
    $ext = [System.IO.Path]::GetExtension($targetArchive).ToLowerInvariant()

    # Quote path only when needed — Dell prints CLI help + exit 10 if /e="path" is malformed.
    $destArg = if ($DestinationPath -match '[\s"]') { "`"$DestinationPath`"" } else { $DestinationPath }

    try {
        if ($ext -eq ".cab") {
            & expand.exe $targetArchive -F:* $DestinationPath | Out-Null
            $exitCode = $LASTEXITCODE
        }
        else {
            # Same switches Bun extractPack.ts / OSDCloud Dell path:
            #   Dell  : /s /e=<dir>
            #   HP    : /s /e /f <dir>
            #   Lenovo: /VERYSILENT /SUPPRESSMSGBOXES /DIR=<dir> /EXTRACT=YES
            $attemptArgs = if ($isLenovo) {
                @(
                    "/VERYSILENT /SUPPRESSMSGBOXES /DIR=$destArg /EXTRACT=YES"
                )
            } elseif ($isHp) {
                @(
                    "/s /e /f $destArg"
                )
            } else {
                @(
                    "/s /e=$destArg"
                )
            }

            $exitCode = -1
            foreach ($arguments in $attemptArgs) {
                Write-LiteDeployLog " [INIT]    Spawn: $archiveName $arguments" -Level "INIT" -ForegroundColor Cyan -Component "DriverStaging"
                $proc = Start-Process -FilePath $targetArchive -ArgumentList $arguments -Wait -PassThru -NoNewWindow
                $exitCode = $proc.ExitCode
                $successCodesTry = if ($isHp) { @(0, 1168) } else { @(0) }
                $hasTry = Test-DriverFolderHasDriverFiles -RootPath $DestinationPath -MaxDepth 10
                if (($successCodesTry -contains $exitCode) -and $hasTry) { break }
                Write-LiteDeployLog " [WARNING] Extract attempt failed (exit $exitCode, hasInf=$hasTry). Trying next switch if any..." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
            }
        }
    }
    catch {
        Write-LiteDeployLog " [ERROR]   Extraction process threw an exception: $($_.Exception.Message)" -Level "ERROR" -ForegroundColor Red -Component "DriverStaging"
        return [PSCustomObject]@{ Success = $false; Expanded = $false; Status = "ExecutionException"; SourcePath = $targetArchive; ExpandedPath = $null; Message = $_.Exception.Message }
    }

    $successCodes = if ($isHp) { @(0, 1168) } else { @(0) }
    $hasDrivers = Test-DriverFolderHasDriverFiles -RootPath $DestinationPath -MaxDepth 10

    if ($successCodes -contains $exitCode -and $hasDrivers) {
        Write-LiteDeployLog " [SUCCESS] Driver package extracted successfully (exit code $exitCode) to '$DestinationPath'." -Level "SUCCESS" -ForegroundColor Green -Component "DriverStaging"
        return [PSCustomObject]@{ Success = $true; Expanded = $true; Status = "Extracted"; SourcePath = $targetArchive; ExpandedPath = $DestinationPath; Message = "Extraction succeeded." }
    }

    $reason = if ($successCodes -notcontains $exitCode) { "Exit code $exitCode" } else { "No .inf driver files found after extraction" }
    Write-LiteDeployLog " [WARNING] Extraction validation failed: $reason. Falling back to Standard OS In-Box Drivers." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
    return [PSCustomObject]@{ Success = $false; Expanded = $false; Status = "ValidationFailed"; SourcePath = $targetArchive; ExpandedPath = $null; Message = $reason }
}

function Stage-LiteDeployDrivers {
    <#
    .SYNOPSIS
        Stages driver packages for installation directly to destination folder (W:\~LiteDeploy\Content\Drivers).
    #>
    [CmdletBinding()]
    param(
        [string]$ShareRoot = "",
        [psobject]$Detection = $null,
        [string]$DestinationPath = ""
    )

    if ($null -eq $Detection) {
        $Detection = Find-LiteDeployDriverPackage -ShareRoot $ShareRoot
    }

    $isDetected = [bool]($Detection.PSObject.Properties["IsDetected"] -and $Detection.IsDetected)
    if (-not $isDetected) {
        Write-LiteDeployLog " [INFO]    No OEM driver pack detected; Windows in-box drivers will be used." -Level "INFO" -Component "DriverStaging"
        return [PSCustomObject]@{
            Success         = $true
            Staged          = $false
            Status          = "InBox"
            DriverPath      = $null
            SourcePath      = $null
            DestinationPath = $null
            Detection       = $Detection
            Message         = "Standard OS In-Box Drivers (Windows Default)"
        }
    }

    $sourceKind = if ($Detection.PSObject.Properties["SourceKind"]) { [string]$Detection.SourceKind } else { "" }
    $fullPath = if ($Detection.PSObject.Properties["FullPath"] -and $Detection.FullPath) { [string]$Detection.FullPath } else { $null }

    # Destination directory: directly W:\~LiteDeploy\Content\Drivers without model subfolder
    $extractDir = if (-not [string]::IsNullOrWhiteSpace($DestinationPath)) {
        $DestinationPath
    } else {
        "W:\~LiteDeploy\Content\Drivers"
    }

    # 1. Content folder already extracted on the share / media
    if ($sourceKind -ieq "Content") {
        if ($fullPath -and (Test-Path -LiteralPath $fullPath -PathType Container) -and (Test-DriverFolderHasDriverFiles -RootPath $fullPath -MaxDepth 10)) {
            Write-LiteDeployLog " [SUCCESS] Driver staging ready (extracted folder): '$fullPath'" -Level "SUCCESS" -ForegroundColor Green -Component "DriverStaging"
            return [PSCustomObject]@{
                Success         = $true
                Staged          = $true
                Status          = "Ready"
                DriverPath      = $fullPath
                SourcePath      = $fullPath
                DestinationPath = $fullPath
                Detection       = $Detection
                Message         = "Extracted driver content validated."
            }
        }
        Write-LiteDeployLog " [WARNING] Extracted driver path '$fullPath' is missing or contains no drivers. Falling back to in-box." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
        return [PSCustomObject]@{
            Success         = $false
            Staged          = $false
            Status          = "InBox"
            DriverPath      = $null
            SourcePath      = $fullPath
            DestinationPath = $null
            Detection       = $Detection
            Message         = "Source folder has no valid .inf driver files."
        }
    }

    # 2. Archive (.exe / .cab) - copy to destination, extract, and remove archive
    if (-not (Test-Path -LiteralPath $extractDir -PathType Container)) {
        $null = New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction Stop
    }

    $archiveName = Split-Path -Path $fullPath -Leaf
    $stagedArchive = Join-Path $extractDir $archiveName

    Write-LiteDeployLog " [INIT]    Copying driver archive '$archiveName' to '$stagedArchive'..." -Level "INIT" -ForegroundColor Cyan -Component "DriverStaging"
    try {
        Copy-Item -LiteralPath $fullPath -Destination $stagedArchive -Force -ErrorAction Stop
    }
    catch {
        Write-LiteDeployLog " [WARNING] Failed to copy driver archive '$fullPath' to '$stagedArchive': $($_.Exception.Message). Falling back to in-box." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
        return [PSCustomObject]@{
            Success         = $false
            Staged          = $false
            Status          = "InBox"
            DriverPath      = $null
            SourcePath      = $fullPath
            DestinationPath = $null
            Detection       = $Detection
            Message         = "Failed to copy driver archive: $($_.Exception.Message)"
        }
    }

    # Verify complete transfer by comparing source and staged byte sizes
    try {
        $sourceSize = (Get-Item -LiteralPath $fullPath -ErrorAction Stop).Length
        $stagedSize = (Get-Item -LiteralPath $stagedArchive -ErrorAction Stop).Length
        if ($sourceSize -ne $stagedSize -or $stagedSize -le 0) {
            Write-LiteDeployLog " [WARNING] Staged driver archive size mismatch ($stagedSize bytes vs $sourceSize bytes). Copy was incomplete. Falling back to in-box." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
            if (Test-Path -LiteralPath $stagedArchive -PathType Leaf) {
                Remove-Item -LiteralPath $stagedArchive -Force -ErrorAction SilentlyContinue
            }
            return [PSCustomObject]@{
                Success         = $false
                Staged          = $false
                Status          = "InBox"
                DriverPath      = $null
                SourcePath      = $fullPath
                DestinationPath = $null
                Detection       = $Detection
                Message         = "Driver archive copy was incomplete (size mismatch)."
            }
        }
    }
    catch {
        Write-LiteDeployLog " [WARNING] Could not verify staged driver archive size: $($_.Exception.Message)" -Level "WARNING" -Component "DriverStaging"
    }

    # Verify file integrity of the copied archive locally before extracting
    $expectedSha = if ($Detection.PSObject.Properties["SHA256"] -and $Detection.SHA256) { [string]$Detection.SHA256 } else { $null }

    if (-not [string]::IsNullOrWhiteSpace($expectedSha)) {
        Write-LiteDeployLog " [CHECK]   Verifying SHA256 integrity of staged archive '$archiveName'..." -Level "INFO" -Component "DriverStaging"
        $stagedSha = $null
        try {
            $stagedSha = (Get-FileHash -LiteralPath $stagedArchive -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
            Write-LiteDeployLog " [WARNING] Failed to calculate hash for staged archive '$stagedArchive': $($_.Exception.Message). Falling back to in-box." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
            if (Test-Path -LiteralPath $stagedArchive -PathType Leaf) {
                Remove-Item -LiteralPath $stagedArchive -Force -ErrorAction SilentlyContinue
            }
            return [PSCustomObject]@{
                Success         = $false
                Staged          = $false
                Status          = "InBox"
                DriverPath      = $null
                SourcePath      = $fullPath
                DestinationPath = $null
                Detection       = $Detection
                Message         = "Could not calculate hash for staged driver archive."
            }
        }

        if ($stagedSha -ne $expectedSha) {
            Write-LiteDeployLog " [WARNING] Staged archive hash mismatch for '$archiveName'! Expected: $expectedSha, Got: $stagedSha. Integrity check failed; falling back to in-box drivers." -Level "WARNING" -ForegroundColor Yellow -Component "DriverStaging"
            if (Test-Path -LiteralPath $stagedArchive -PathType Leaf) {
                Remove-Item -LiteralPath $stagedArchive -Force -ErrorAction SilentlyContinue
            }
            return [PSCustomObject]@{
                Success         = $false
                Staged          = $false
                Status          = "InBox"
                DriverPath      = $null
                SourcePath      = $fullPath
                DestinationPath = $null
                Detection       = $Detection
                Message         = "Staged driver archive failed SHA256 integrity check."
            }
        }

        Write-LiteDeployLog " [SUCCESS] Archive integrity verified (SHA256 matched: $stagedSha)." -Level "SUCCESS" -ForegroundColor Green -Component "DriverStaging"
    }

    $expandResult = Expand-LiteDeployDriverPackage -Detection $Detection -ArchivePath $stagedArchive -DestinationPath $extractDir

    # Clean up the copied .exe archive after extraction to save disk space
    if (Test-Path -LiteralPath $stagedArchive -PathType Leaf) {
        Remove-Item -LiteralPath $stagedArchive -Force -ErrorAction SilentlyContinue
    }

    if ($expandResult.Success -and $expandResult.ExpandedPath) {
        Write-LiteDeployLog " [SUCCESS] Driver staging completed successfully: '$($expandResult.ExpandedPath)'" -Level "SUCCESS" -ForegroundColor Green -Component "DriverStaging"
        return [PSCustomObject]@{
            Success         = $true
            Staged          = $true
            Status          = "Ready"
            DriverPath      = $expandResult.ExpandedPath
            SourcePath      = $fullPath
            DestinationPath = $extractDir
            Detection       = $Detection
            Message         = "Driver package extracted and staged successfully."
        }
    }

    return [PSCustomObject]@{
        Success         = $false
        Staged          = $false
        Status          = "InBox"
        DriverPath      = $null
        SourcePath      = $fullPath
        DestinationPath = $null
        Detection       = $Detection
        Message         = $expandResult.Message
    }
}

function Test-LiteDeployDrivers {
    <#
    .SYNOPSIS
        Read-only validation of the driver catalog and detected pack for this machine.
    #>
    [CmdletBinding()]
    param([string]$ShareRoot = "")

    $root = Resolve-LiteDeployDriverShareRoot -ShareRoot $ShareRoot
    $catalog = Get-LiteDeployLocalDriverCatalog -ShareRoot $root
    $detection = Get-SystemDriverDetection -ShareRoot $root

    $fullPath = if ($detection.PSObject.Properties["FullPath"] -and $detection.FullPath) { [string]$detection.FullPath } else { $null }
    $pathExists = if ($fullPath) { [bool](Test-Path -LiteralPath $fullPath) } else { $false }

    return [PSCustomObject]@{
        ShareRoot     = $root
        CatalogFound  = ($null -ne $catalog)
        CatalogPath   = if ($catalog) { $catalog.CatalogPath } else { $null }
        IsDetected    = [bool]$detection.IsDetected
        MatchBy       = $detection.MatchBy
        SourceKind    = $detection.SourceKind
        RelativePath  = $detection.RelativePath
        FullPath      = $fullPath
        PathExists    = $pathExists
        Passed        = ((-not $detection.IsDetected) -or $pathExists)
        Detection     = $detection
    }
}

# ==============================================================================
# STANDALONE (non-destructive detection against -ShareRoot or Z:\)
# ==============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Test-LiteDeployDrivers -ShareRoot $ShareRoot
        Write-Host "LiteDeploy.Drivers - detection (read-only), ShareRoot: $($result.ShareRoot)" -ForegroundColor Cyan
        $result | Select-Object CatalogFound, CatalogPath, IsDetected, MatchBy, SourceKind, RelativePath, PathExists, Passed | Format-List | Out-Host
        return $result
    }
    catch {
        Write-Warning "Driver detection unavailable: $($_.Exception.Message)"
        return
    }
}
