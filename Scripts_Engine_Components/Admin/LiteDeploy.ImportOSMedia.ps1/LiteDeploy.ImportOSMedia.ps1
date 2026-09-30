#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'Import')]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the root LiteDeploy deployment share directory.")]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$DeploymentShare,

    [Parameter(Mandatory = $true, ParameterSetName = 'Import', HelpMessage = "Path to an ISO file, Drive Letter (e.g., E: or E:\), or unpacked directory.")]
    [string]$SourcePath,

    [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Use 7-Zip registry parsing for automated OS name/version extraction.")]
    [switch]$Use7Zip,

    [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Path to 7z.exe binary.")]
    [string]$SevenZipPath = "C:\Program Files\7-Zip\7z.exe",

    [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Optional path to a custom .wim or .esd file to replace default install.wim.")]
    [string]$CustomWimPath,

    [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Specific WIM image indices to enable (e.g. 1, 6). Bypasses Out-GridView prompt if specified.")]
    [int[]]$SelectedIndices,

    [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Select all editions automatically without interactive Out-GridView prompt.")]
    [switch]$SelectAllEditions,

    [Parameter(Mandatory = $false, ParameterSetName = 'Import', HelpMessage = "Override or supply OS Name directly (bypasses Read-Host prompt in DISM mode).")]
    [string]$OSName,

    [Parameter(Mandatory = $false, HelpMessage = "Return the generated local OS object output to pipeline.")]
    [switch]$PassThru,

    [Parameter(Mandatory = $false, ParameterSetName = 'Rebuild', HelpMessage = "Rebuild central catalog.json from local os.json files.")]
    [switch]$RebuildCatalog
)

# ===========================================================================
# Helper Function 0: Safe Property Accessor for StrictMode v2
# ===========================================================================
function Get-SafeProp {
    param([psobject]$Obj, [string[]]$PropNames, [object]$DefaultValue = $null)
    if (-not $Obj) { return $DefaultValue }
    foreach ($pName in $PropNames) {
        $prop = $Obj.PSObject.Properties | Where-Object { $_.Name -eq $pName }
        if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    }
    return $DefaultValue
}

# ===========================================================================
# Helper Function 0b: Normalize Architecture Strings & Codes
# ===========================================================================
function Get-NormalizedArchitecture {
    param([string]$RawArch)
    if ([string]::IsNullOrWhiteSpace($RawArch)) { return 'x64' }
    switch -Regex ($RawArch.Trim()) {
        '^(9|x64|amd64|x86_64)$' { return 'x64' }
        '^(12|arm64|aarch64)$'  { return 'arm64' }
        '^(0|x86|i386|i686)$'    { return 'x86' }
        '^(11|5|arm|arm32)$'     { return 'arm' }
        '^(6|ia64)$'             { return 'ia64' }
        default                  { return $RawArch.ToLower() }
    }
}

# ===========================================================================
# Helper Function 0c: Extract Exact CreatedTime & ModifiedTime per WIM Index
# ===========================================================================
function Get-WimIndexTimestamps {
    param([string]$WimPath, [int]$ImageIndex, [object]$WimObject)

    $cVal = Get-SafeProp -Obj $WimObject -PropNames "CreatedTime", "CreationTime"
    $mVal = Get-SafeProp -Obj $WimObject -PropNames "ModifiedTime", "LastWriteTime"

    $cStr = if ($cVal -is [datetime]) { $cVal.ToString("M/d/yyyy h:mm:ss tt") } elseif ($cVal) { try { ([datetime]$cVal).ToString("M/d/yyyy h:mm:ss tt") } catch { $cVal.ToString() } } else { "" }
    $mStr = if ($mVal -is [datetime]) { $mVal.ToString("M/d/yyyy h:mm:ss tt") } elseif ($mVal) { try { ([datetime]$mVal).ToString("M/d/yyyy h:mm:ss tt") } catch { $mVal.ToString() } } else { "" }

    if ($cStr -and $mStr) {
        return @{ CreatedTime = $cStr; ModifiedTime = $mStr }
    }

    if ($WimPath -and (Test-Path $WimPath -PathType Leaf)) {
        try {
            $rawDism = dism.exe /English /Get-WimInfo /WimFile:"$WimPath" /Index:$ImageIndex 2>$null
            foreach ($line in $rawDism) {
                if (-not $cStr -and $line -match '^Created\s*:\s*(.+)') {
                    $cleanStr = $Matches[1].Trim() -replace '\s*-\s*', ' '
                    try { $cStr = ([datetime]$cleanStr).ToString("M/d/yyyy h:mm:ss tt") } catch { $cStr = $cleanStr }
                }
                elseif (-not $mStr -and $line -match '^Modified\s*:\s*(.+)') {
                    $cleanStr = $Matches[1].Trim() -replace '\s*-\s*', ' '
                    try { $mStr = ([datetime]$cleanStr).ToString("M/d/yyyy h:mm:ss tt") } catch { $mStr = $cleanStr }
                }
            }
        } catch {}

        if (-not $cStr -or -not $mStr) {
            try {
                $fileItem = Get-Item $WimPath
                if (-not $cStr) { $cStr = $fileItem.CreationTime.ToString("M/d/yyyy h:mm:ss tt") }
                if (-not $mStr) { $mStr = $fileItem.LastWriteTime.ToString("M/d/yyyy h:mm:ss tt") }
            } catch {}
        }
    }

    return @{ CreatedTime = $cStr; ModifiedTime = $mStr }
}

# ===========================================================================
# Helper Function 0d: Clean JSON Formatter
# ===========================================================================
function Format-CleanJson {
    param([object]$InputObject)
    $json = $InputObject | ConvertTo-Json -Depth 10
    return ($json -replace '(?m)^(\s*"[^"]+":)\s{2,}', '$1 ')
}

# ===========================================================================
# Helper Function 0.1: Normalize Edition SKU Codes (Standard & European N)
# ===========================================================================
function Get-NormalizedSkuCode {
    param(
        [string]$EditionName,
        [string]$RawSkuCode
    )

    $isN = ($EditionName -match '\bN\b')

    # Ignore RawSkuCode if it contains spaces or "Windows" (which indicates EditionName was passed instead of DISM SKU)
    $validRawSku = if ($RawSkuCode -and $RawSkuCode -notlike "* *" -and $RawSkuCode -notlike "*Windows*") { $RawSkuCode } else { $null }

    $sku = if ($validRawSku) {
        $validRawSku
    } elseif ($EditionName -like "*Pro*Workstation*" -or $EditionName -like "*Pro*for Workstations*") {
        "ProfessionalWorkstation"
    } elseif ($EditionName -like "*Pro*Education*") {
        "ProfessionalEducation"
    } elseif ($EditionName -like "*Pro*") {
        "Professional"
    } elseif ($EditionName -like "*Home*Single*") {
        "CoreSingleLanguage"
    } elseif ($EditionName -like "*Home*") {
        "Core"
    } elseif ($EditionName -like "*Education*") {
        "Education"
    } elseif ($EditionName -like "*Enterprise*") {
        "Enterprise"
    } else {
        ($EditionName -replace "Windows 11 ", "" -replace "Windows 10 ", "" -replace '\bN\b', '').Trim()
    }

    if ($isN -and -not $sku.EndsWith("N")) {
        return "${sku}N"
    }

    return $sku
}

# ===========================================================================
# Helper Function 1: Extract Media Languages
# ===========================================================================
function Get-MediaLanguages {
    param(
        [Parameter(Mandatory = $true)][string]$MediaDrive,
        [Parameter(Mandatory = $false)][object]$WimImageObject = $null
    )

    $defaultLang    = $null
    $availableLangs = [System.Collections.Generic.List[string]]::new()

    if ($WimImageObject) {
        $wimLangs = Get-SafeProp -Obj $WimImageObject -PropNames "Languages", "SupportedLanguages"
        if ($wimLangs) {
            if ($wimLangs -is [array]) { foreach ($l in $wimLangs) { if (-not $availableLangs.Contains($l.ToString())) { $availableLangs.Add($l.ToString()) } } }
            else { if (-not $availableLangs.Contains($wimLangs.ToString())) { $availableLangs.Add($wimLangs.ToString()) } }
        }
        $defIdx = Get-SafeProp -Obj $WimImageObject -PropNames "DefaultLanguageIndex" -DefaultValue 0
        if ($availableLangs.Count -gt 0) {
            if ([int]$defIdx -lt $availableLangs.Count) { $defaultLang = $availableLangs[[int]$defIdx] }
            else { $defaultLang = $availableLangs[0] }
        }
        $wimDefLang = Get-SafeProp -Obj $WimImageObject -PropNames "DefaultLanguage", "Language"
        if ($wimDefLang) { $defaultLang = $wimDefLang }
    }

    $langIniPath = Join-Path $MediaDrive "sources\lang.ini"
    if (Test-Path $langIniPath) {
        $iniContent = [System.IO.File]::ReadAllText($langIniPath)
        
        if ($iniContent -match '(?i)Default\s*=\s*([a-z]{2}-[a-z]{2,4})') {
            if (-not $defaultLang) { $defaultLang = $Matches[1] }
        }
        
        if ($iniContent -match '(?i)\[Available UI Languages\]\s*[\r\n\s]+([a-z]{2}-[a-z]{2,4})\s*=') {
            if (-not $defaultLang) { $defaultLang = $Matches[1] }
        }

        [regex]::Matches($iniContent, '(?m)^([a-z]{2}-[a-z]{2,4})\s*=') | ForEach-Object {
            $val = $_.Groups[1].Value
            if (-not $availableLangs.Contains($val)) { $availableLangs.Add($val) }
        }
    }

    if (-not $defaultLang -and $availableLangs.Count -gt 0) { $defaultLang = $availableLangs[0] }
    if (-not $defaultLang) { $defaultLang = "en-US" }
    if ($availableLangs.Count -eq 0) { $availableLangs.Add($defaultLang) }

    return [pscustomobject]@{
        DefaultLanguage    = $defaultLang
        SupportedLanguages = ($availableLangs | Select-Object -Unique)
    }
}

# ===========================================================================
# Helper Function 2: Validate Media Integrity
# ===========================================================================
function Test-ValidWindowsMedia {
    param([Parameter(Mandatory = $true)][string]$MediaDrive)

    Write-Host "[+] Validating Windows Media structure on '$MediaDrive'..." -ForegroundColor Cyan

    $missing = @()
    if (-not (Test-Path (Join-Path $MediaDrive "setup.exe"))) { $missing += "setup.exe" }
    if (-not ((Test-Path (Join-Path $MediaDrive "bootmgr")) -or (Test-Path (Join-Path $MediaDrive "boot\bootmgr")))) { $missing += "bootmgr" }
    if (-not (Test-Path (Join-Path $MediaDrive "sources\boot.wim"))) { $missing += "sources\boot.wim" }

    if ($missing.Count -gt 0) {
        Write-Warning "[-] Missing required Windows setup files: $($missing -join ', ')"
        return $false
    }

    $installWim = Join-Path $MediaDrive "sources\install.wim"
    $installEsd = Join-Path $MediaDrive "sources\install.esd"
    $targetImage = if (Test-Path $installWim) { $installWim } elseif (Test-Path $installEsd) { $installEsd } else { $null }

    if (-not $targetImage) {
        Write-Warning "[-] Missing sources\install.wim or sources\install.esd."
        return $false
    }

    try { $null = Get-WindowsImage -ImagePath $targetImage -ErrorAction Stop }
    catch {
        Write-Warning "[-] Image '$targetImage' unreadable by DISM: $_"
        return $false
    }

    Write-Host "[+] Media validation passed!" -ForegroundColor Green
    return $true
}

# ===========================================================================
# Helper Function 3: Parse Native DISM Header
# ===========================================================================
function Get-WimIndexMetadataNative {
    param([string]$WimPath, [int]$ImageIndex)

    $dismRaw = dism.exe /English /Get-WimInfo /WimFile:"$WimPath" /Index:$ImageIndex 2>$null
    $meta    = [pscustomobject]@{
        Name = $null; Architecture = "x64"; Version = $null; ServicePackBuild = $null
        FullBuildVersion = $null; Edition = $null; ModifiedDate = $null
    }

    foreach ($line in $dismRaw) {
        if ($line -match '^Name\s*:\s*(.+)')                 { $meta.Name = $Matches[1].Trim() }
        elseif ($line -match '^Architecture\s*:\s*(.+)')     { $meta.Architecture = Get-NormalizedArchitecture $Matches[1] }
        elseif ($line -match '^Version\s*:\s*(.+)')          { $meta.Version = $Matches[1].Trim() }
        elseif ($line -match '^ServicePack\s*Build\s*:\s*(.+)') { $meta.ServicePackBuild = $Matches[1].Trim() }
        elseif ($line -match '^Edition\s*:\s*(.+)')          { $meta.Edition = $Matches[1].Trim() }
        elseif ($line -match '^(Modified|Created)\s*:\s*(.+)') {
            try {
                $rawStr = $Matches[2].Trim()
                $cleanDateStr = ($rawStr -replace '\s*-\s*.*$', '').Trim()
                $meta.ModifiedDate = ([datetime]$cleanDateStr).ToString("yyyy-MM-dd")
            } catch {}
        }
    }

    $meta.FullBuildVersion = if ($meta.Version -and $meta.ServicePackBuild) { "$($meta.Version).$($meta.ServicePackBuild)" } else { $meta.Version }
    return $meta
}

# ===========================================================================
# Helper Function 4: Fast 7-Zip Registry Extractor
# ===========================================================================
function Get-WimRegistryVia7Zip {
    param([string]$DeploymentShare, [string]$WimPath, [int]$ImageIndex, [string]$SevenZipExe)

    $tempDir  = Join-Path $DeploymentShare "Content\Temp"
    $hiveFile = Join-Path $tempDir "SOFTWARE"
    if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }

    # Resolve 7-Zip executable path if default path is not found
    $resolved7z = if (Test-Path $SevenZipExe) {
        $SevenZipExe
    } elseif ((Get-Command 7z.exe -ErrorAction SilentlyContinue)) {
        (Get-Command 7z.exe).Path
    } elseif (Test-Path "C:\Program Files\7-Zip\7z.exe") {
        "C:\Program Files\7-Zip\7z.exe"
    } elseif (Test-Path "C:\Program Files (x86)\7-Zip\7z.exe") {
        "C:\Program Files (x86)\7-Zip\7z.exe"
    } else {
        $null
    }

    $extracted  = $false
    $resultData = [pscustomobject]@{ ProductName = $null; DisplayVersion = $null; CurrentBuild = $null; UBR = $null }

    try {
        if ($resolved7z -and (Test-Path $resolved7z) -and ($WimPath -like "*.wim")) {
            Write-Host "[+] Extracting 'SOFTWARE' hive via 7-Zip CLI (Index $ImageIndex)..." -ForegroundColor Cyan
            & $resolved7z e "$WimPath" "$ImageIndex\Windows\System32\config\SOFTWARE" -o"$tempDir" -y 2>&1 | Out-Null
            $extracted = Test-Path $hiveFile
        }

        if (-not $extracted) {
            Write-Host "[!] 7-Zip unavailable or ESD file. Falling back to DISM mount..." -ForegroundColor Yellow
            $mountDir = Join-Path $tempDir "WimMount"
            if (-not (Test-Path $mountDir)) { New-Item -Path $mountDir -ItemType Directory -Force | Out-Null }
            try {
                Mount-WindowsImage -ImagePath $WimPath -Index $ImageIndex -Path $mountDir -ReadOnly -ErrorAction Stop | Out-Null
                $sourceHive = Join-Path $mountDir "Windows\System32\config\SOFTWARE"
                if (Test-Path $sourceHive) { Copy-Item $sourceHive $hiveFile -Force }
            }
            finally {
                Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
                if (Test-Path $mountDir) { Remove-Item $mountDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        if (Test-Path $hiveFile) {
            reg.exe load "HKLM\OFFLINE_SOFTWARE" "$hiveFile" 2>&1 | Out-Null
            $regPath = "HKLM:\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion"
            if (Test-Path $regPath) {
                $regProps = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                $rawProductName = $regProps.ProductName
                $buildNum       = [int]$regProps.CurrentBuild

                if ($rawProductName -like "*Windows 10*" -and $buildNum -ge 22000) {
                    $rawProductName = $rawProductName -replace "Windows 10", "Windows 11"
                }

                $resultData.ProductName    = $rawProductName
                $resultData.DisplayVersion = $regProps.DisplayVersion
                $resultData.CurrentBuild   = $regProps.CurrentBuild
                $resultData.UBR            = $regProps.UBR
            }
        }
    }
    finally {
        $regProps = $null
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            reg.exe unload "HKLM\OFFLINE_SOFTWARE" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Milliseconds 200
        }

        if (Test-Path $tempDir) {
            Get-ChildItem $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $resultData
}

# ===========================================================================
# Helper Function 5: Central Catalog Rebuilder
# ===========================================================================
function Invoke-CatalogRebuild {
    param([string]$DeploymentShare)

    $osRootDir   = Join-Path $DeploymentShare "Content\OperatingSystems"
    $catalogPath = Join-Path $osRootDir "catalog.json"

    Write-Host "`n[+] Rebuilding central catalog.json..." -ForegroundColor Cyan
    if (-not (Test-Path $osRootDir)) { throw "OperatingSystems directory not found at '$osRootDir'." }

    $newCatalog = [pscustomobject]@{
        '$schema'          = "./schemas/os-catalog.schema.json"
        'operatingSystems' = [System.Collections.Generic.List[object]]::new()
    }

    $localOsFiles = Get-ChildItem -Path $osRootDir -Recurse -Filter "os.json" -ErrorAction SilentlyContinue
    if (-not $localOsFiles) {
        Write-Host "[!] No local os.json files found. Generating empty central catalog.json..." -ForegroundColor Yellow
        Format-CleanJson $newCatalog | Set-Content -Path $catalogPath -Encoding UTF8
        Write-Host "[+] Empty central catalog written: $catalogPath" -ForegroundColor Green
        return
    }

    foreach ($file in $localOsFiles) {
        try {
            $localOsData = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            $enabledEditions = [System.Collections.Generic.List[object]]::new()
            if ($localOsData.editions) {
                $localOsData.editions | Where-Object { $_.enabled -eq $true -or $_.enabled -eq "true" } | ForEach-Object { $enabledEditions.Add($_) }
            }

            $catalogOsEntry = [pscustomobject]@{
                osId               = $localOsData.osId
                fullName           = $localOsData.fullName
                osName             = $localOsData.osName
                version            = $localOsData.version
                buildVersion       = $localOsData.buildVersion
                defaultLanguage    = $localOsData.defaultLanguage
                supportedLanguages = $localOsData.supportedLanguages
                importedDate       = $localOsData.importedDate
                arch               = $localOsData.arch
                isCustomImage      = [bool]$localOsData.isCustomImage
                enabled            = [bool]($enabledEditions.Count -gt 0)
                mediaRoot          = $localOsData.mediaRoot
                setupPath          = $localOsData.setupPath
                imagePath          = $localOsData.imagePath
                editions           = $enabledEditions
            }
            $newCatalog.operatingSystems.Add($catalogOsEntry)
            Write-Host "    [+] Merged OS '$($localOsData.osId)' ($($enabledEditions.Count) enabled editions)." -ForegroundColor Green
        }
        catch { Write-Warning "[-] Failed to parse '$($file.FullName)': $_" }
    }

    Format-CleanJson $newCatalog | Set-Content -Path $catalogPath -Encoding UTF8
    Write-Host "[+] Central catalog rebuilt: $catalogPath" -ForegroundColor Green
}

# ===========================================================================
# Main Execution Pipeline
# ===========================================================================
if ($RebuildCatalog) {
    Invoke-CatalogRebuild -DeploymentShare $DeploymentShare
    return
}

$mountedIso  = $null
$sourceDrive = $null

try {
    # 1. Resolve & Mount Source Media (Drive Letter, ISO, or Directory)
    if ($SourcePath -match '^[a-zA-Z]:?\\?$') {
        $sourceDrive = "$($SourcePath.TrimEnd('\').TrimEnd(':')):\"
        Write-Host "[+] Using media from drive: $sourceDrive" -ForegroundColor Green
    }
    elseif ((Test-Path $SourcePath -PathType Leaf) -and ((Get-Item $SourcePath).Extension -eq '.iso')) {
        Write-Host "[+] Mounting ISO image: $SourcePath..." -ForegroundColor Cyan
        $null        = Mount-DiskImage -ImagePath (Resolve-Path $SourcePath).Path -ErrorAction Stop
        $mountedIso  = Get-DiskImage -ImagePath (Resolve-Path $SourcePath).Path
        $sourceDrive = "$((Get-Volume -DiskImage $mountedIso).DriveLetter):\"
        Write-Host "[+] ISO mounted to drive $sourceDrive" -ForegroundColor Green
    }
    elseif (Test-Path $SourcePath -PathType Container) {
        $sourceDrive = (Resolve-Path $SourcePath).Path
        if (-not $sourceDrive.EndsWith('\')) { $sourceDrive += '\' }
        Write-Host "[+] Using media from unpacked folder: $sourceDrive" -ForegroundColor Green
    }
    else {
        throw "Source path '$SourcePath' is not a valid drive, folder, or .iso file."
    }

    # 2. Validate Media & Resolve Custom WIM
    if (-not (Test-ValidWindowsMedia -MediaDrive $sourceDrive)) {
        throw "Source media at '$sourceDrive' failed integrity validation."
    }

    $imageFile = Join-Path $sourceDrive "sources\install.wim"
    if (-not (Test-Path $imageFile)) { $imageFile = Join-Path $sourceDrive "sources\install.esd" }

    if ($CustomWimPath) {
        if (-not (Test-Path $CustomWimPath -PathType Leaf)) { throw "Custom WIM '$CustomWimPath' not found." }
        $customExt = (Get-Item $CustomWimPath).Extension.ToLower()
        if ($customExt -ne '.wim' -and $customExt -ne '.esd') { throw "Custom image must be .wim or .esd." }
        try { $null = Get-WindowsImage -ImagePath $CustomWimPath -ErrorAction Stop }
        catch { throw "Custom image '$CustomWimPath' unreadable by DISM: $_" }
        $imageFile = (Resolve-Path $CustomWimPath).Path
        Write-Host "[+] Using custom WIM image: $imageFile" -ForegroundColor Cyan
    }

    # 3. Inspect Image Editions & Resolve Selection
    Write-Host "[+] Inspecting OS editions inside $imageFile..." -ForegroundColor Cyan
    $wimImages = Get-WindowsImage -ImagePath $imageFile

    if ($SelectAllEditions) {
        $selectedEditions = $wimImages
    }
    elseif ($SelectedIndices -and $SelectedIndices.Count -gt 0) {
        $selectedEditions = $wimImages | Where-Object { $SelectedIndices -contains $_.ImageIndex }
    }
    else {
        $selectedEditions = $wimImages | Out-GridView -Title "LiteDeploy: Select Edition(s) to Import" -OutputMode Multiple
    }

    if (-not $selectedEditions) {
        Write-Warning "[-] No editions selected. Import canceled."
        return
    }
    $selectedIndices = $selectedEditions | Select-Object -ExpandProperty ImageIndex

    # 4. Extract OS Metadata
    $firstEdition  = $selectedEditions[0]
    $selectedIndex = $firstEdition.ImageIndex

    Write-Host "[+] Reading DISM image metadata..." -ForegroundColor Cyan
    $indexMeta        = Get-WimIndexMetadataNative -WimPath $imageFile -ImageIndex $selectedIndex
    $buildNumber      = if ($indexMeta.Version) { ($indexMeta.Version -split '\.')[-1] } else { "26200" }
    $spBuild          = $indexMeta.ServicePackBuild
    $fullBuildVersion = $indexMeta.FullBuildVersion
    $rawArchVal       = Get-SafeProp -Obj $indexMeta -PropNames "Architecture", "Arch" -DefaultValue "x64"
    $arch             = Get-NormalizedArchitecture -RawArch $rawArchVal

    $displayVersion = $null
    if ($Use7Zip) {
        Write-Host "[+] Extracting DisplayVersion via 7-Zip registry hive..." -ForegroundColor Cyan
        $regData = Get-WimRegistryVia7Zip -DeploymentShare $DeploymentShare -WimPath $imageFile -ImageIndex $selectedIndex -SevenZipExe $SevenZipPath
        if ($regData -and $regData.DisplayVersion) {
            $displayVersion = $regData.DisplayVersion
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($OSName)) {
        $userFullName = $OSName.Trim()
    }
    elseif ($displayVersion) {
        $dismImageName  = Get-SafeProp -Obj $firstEdition -PropNames "ImageName", "Name" -DefaultValue "Windows"
        $cleanOsName    = ($dismImageName -replace '\s*(Pro|Enterprise|Home|Education|Standard|Datacenter).*', '').Trim()
        $userFullName   = "$cleanOsName $displayVersion"
    }
    else {
        Write-Host "`n[?] Full OS Name Entry Required (e.g. 'Windows 11 25H2')" -ForegroundColor Yellow
        $rawInput = Read-Host -Prompt "--> Enter Full OS Name"
        $userFullName = if (-not [string]::IsNullOrWhiteSpace($rawInput)) { $rawInput.Trim() } else { $null }
    }
    if (-not $userFullName) { Write-Warning "[-] Import canceled: No OS name supplied."; return }

    if ($displayVersion) {
        $versionCode = $displayVersion
        $cleanOsName = ($userFullName -replace '\b(2[0-9]H[1-2]|[0-9]{4})\b', '').Trim()
    }
    elseif ($userFullName -match '\b(2[0-9]H[1-2]|[0-9]{4})\b') {
        $versionCode = $Matches[1].ToUpper()
        $cleanOsName = ($userFullName -replace '\b(2[0-9]H[1-2]|[0-9]{4})\b', '').Trim()
    }
    else {
        $versionCode = "$buildNumber"
        $cleanOsName = $userFullName
    }

    # Derive Family Key, OS ID, and Target Folder
    $langData    = Get-MediaLanguages -MediaDrive $sourceDrive -WimImageObject $firstEdition
    $defLang     = $langData.DefaultLanguage
    $osFamilyKey = if ($cleanOsName -like "*Server*") { "winserver" } elseif ($cleanOsName -like "*11*") { "win11" } elseif ($cleanOsName -like "*10*") { "win10" } else { "winos" }
    $customTag   = if ($CustomWimPath) { "-custom" } else { "" }
    $customDir   = if ($CustomWimPath) { "_custom" } else { "" }
    $langTag     = if ($defLang -and $defLang -notlike "en-US*") { "-$($defLang.ToLower())" } else { "" }
    $langDir     = if ($defLang -and $defLang -notlike "en-US*") { "_$($defLang.ToLower() -replace '-', '')" } else { "" }

    $osId             = "$osFamilyKey-$($versionCode.ToLower())$customTag$langTag-$buildNumber.$spBuild-$arch"
    $targetFolderName = "$($osFamilyKey)_$($versionCode)_$($buildNumber)_$($spBuild)$customDir$langDir"

    Write-Host "`n[+] Extracted OS Details:" -ForegroundColor Yellow
    Write-Host "    - Full Name:        $userFullName"
    Write-Host "    - Version Code:     $versionCode"
    Write-Host "    - Build Version:    $fullBuildVersion"
    Write-Host "    - Default Language: $($langData.DefaultLanguage)"
    Write-Host "    - Architecture:     $arch"
    Write-Host "    - Custom Image:     $([bool]$CustomWimPath)"
    Write-Host "    - OS ID:            $osId"

    # 5. Target Directory Setup & Parallel Robocopy Transfer (/MT:16)
    $osRootDir       = Join-Path $DeploymentShare "Content\OperatingSystems"
    $targetMediaDir  = Join-Path $osRootDir $targetFolderName
    $localOsJsonPath = Join-Path $targetMediaDir "os.json"

    if (-not (Test-Path $osRootDir)) { New-Item -Path $osRootDir -ItemType Directory -Force | Out-Null }

    if (-not (Test-Path $targetMediaDir)) {
        Write-Host "`n[+] Copying ISO contents (Multi-Threaded /MT:16) to '$targetMediaDir'..." -ForegroundColor Cyan
        robocopy.exe $sourceDrive $targetMediaDir /E /MT:16 /NDL /NFL /NJH /NJS /nc /ns /np
        if ($LASTEXITCODE -ge 8) { throw "Robocopy failed with exit code $LASTEXITCODE." }
        Write-Host "[+] ISO content copied successfully." -ForegroundColor Green
    } else {
        Write-Host "[!] Directory '$targetFolderName' already exists. Skipping base media copy." -ForegroundColor Yellow
    }

    if ($CustomWimPath) {
        $customExt   = (Get-Item $imageFile).Extension.ToLower()
        $destWimPath = Join-Path $targetMediaDir "sources\install.wim"
        $destEsdPath = Join-Path $targetMediaDir "sources\install.esd"
        $targetPayloadPath = if ($customExt -eq '.esd') { $destEsdPath } else { $destWimPath }

        if ($customExt -eq '.esd' -and (Test-Path $destWimPath)) { Remove-Item $destWimPath -Force -ErrorAction SilentlyContinue }
        if ($customExt -ne '.esd' -and (Test-Path $destEsdPath)) { Remove-Item $destEsdPath -Force -ErrorAction SilentlyContinue }

        Write-Host "[+] Copying custom image payload to '$targetPayloadPath'..." -ForegroundColor Cyan
        Copy-Item -Path $imageFile -Destination $targetPayloadPath -Force
        Write-Host "[+] Custom image payload placed successfully." -ForegroundColor Green
    }

    # 6. Generate Local os.json with All WIM Editions
    Write-Host "[+] Cataloging WIM editions into local os.json..." -ForegroundColor Cyan
    $relFolder       = "Content/OperatingSystems/$targetFolderName"
    $wimFileName     = if ($CustomWimPath) { Split-Path -Leaf $targetPayloadPath } else { Split-Path -Leaf $imageFile }
    $allEditionsList = [System.Collections.Generic.List[object]]::new()

    foreach ($edition in $wimImages) {
        $iIndex   = Get-SafeProp -Obj $edition -PropNames "ImageIndex", "Index" -DefaultValue 1
        $dismName = Get-SafeProp -Obj $edition -PropNames "ImageName", "Name" -DefaultValue "Windows"
        $dismSku  = Get-SafeProp -Obj $edition -PropNames "EditionId", "Edition", "Sku"
        $skuCode  = if (-not [string]::IsNullOrWhiteSpace($dismSku)) { $dismSku } else { Get-NormalizedSkuCode -EditionName $dismName -RawSkuCode "" }

        $edVersion  = Get-SafeProp -Obj $edition -PropNames "Version"
        $edBuild    = Get-SafeProp -Obj $edition -PropNames "Build"
        $edSPBuild  = Get-SafeProp -Obj $edition -PropNames "SPBuild", "ServicePackBuild"
        $edFullBuild = if ($edVersion -and $edSPBuild) { "$edVersion.$edSPBuild" } elseif ($edVersion) { $edVersion } else { $fullBuildVersion }

        $edArchRaw  = Get-SafeProp -Obj $edition -PropNames "Architecture", "Arch"
        $edArch     = if ($edArchRaw) { Get-NormalizedArchitecture -RawArch $edArchRaw } else { $arch }

        $edLangs  = Get-SafeProp -Obj $edition -PropNames "Languages"
        $edDefLang = Get-SafeProp -Obj $edition -PropNames "DefaultLanguage"
        if (-not $edDefLang -and $edLangs) {
            if ($edLangs -is [array] -and $edLangs.Count -gt 0) { $edDefLang = $edLangs[0] }
            elseif ($edLangs -is [string]) { $edDefLang = $edLangs }
        }
        if (-not $edDefLang) { $edDefLang = $langData.DefaultLanguage }

        $edSuppLangs = if ($edLangs) {
            if ($edLangs -is [array]) { ($edLangs | ForEach-Object { $_.ToString().ToLower() }) }
            else { @($edLangs.ToString().ToLower()) }
        } else { $langData.SupportedLanguages }

        $ts = Get-WimIndexTimestamps -WimPath $imageFile -ImageIndex $iIndex -WimObject $edition

        $kebabEditionName = ($dismName.ToLower() -replace '\s+', '-').Trim('-')
        $editionId        = "$osFamilyKey-$($versionCode.ToLower())$customTag-$kebabEditionName-$buildNumber.$spBuild-$arch"
        $isEnabled        = $selectedIndices -contains $iIndex

        $allEditionsList.Add([pscustomobject]@{
            editionId          = $editionId
            editionName        = $dismName
            skuCode            = $skuCode
            imageIndex         = [int]$iIndex
            enabled            = [bool]$isEnabled
            buildVersion       = $edFullBuild
            arch               = $edArch
            defaultLanguage    = $edDefLang
            supportedLanguages = $edSuppLangs
            createdTime        = $ts.CreatedTime
            modifiedTime       = $ts.ModifiedTime
        })
    }

    $localOsObject = [pscustomobject]@{
        osId               = $osId
        fullName           = $userFullName
        osName             = "$cleanOsName $versionCode ($buildNumber.$spBuild)"
        version            = $versionCode
        buildVersion       = $fullBuildVersion
        defaultLanguage    = $langData.DefaultLanguage
        supportedLanguages = $langData.SupportedLanguages
        importedDate       = (Get-Date -Format "yyyy-MM-dd")
        arch               = $arch
        isCustomImage      = [bool]$CustomWimPath
        enabled            = $true
        mediaRoot          = "$relFolder"
        setupPath          = "$relFolder/setup.exe"
        imagePath          = "$relFolder/sources/$wimFileName"
        editions           = $allEditionsList
    }

    Format-CleanJson $localOsObject | Set-Content -Path $localOsJsonPath -Encoding UTF8
    Write-Host "[+] Local '$localOsJsonPath' created successfully." -ForegroundColor Green

    # 7. Rebuild Central Catalog
    Invoke-CatalogRebuild -DeploymentShare $DeploymentShare

    if ($PassThru) {
        return $localOsObject
    }
}
finally {
    if ($mountedIso) {
        Write-Host "[+] Unmounting source ISO..." -ForegroundColor Cyan
        Dismount-DiskImage -ImagePath (Resolve-Path $SourcePath).Path | Out-Null
        Write-Host "[+] ISO dismounted successfully." -ForegroundColor Green
    }
}