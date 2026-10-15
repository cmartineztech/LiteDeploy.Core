#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    LiteDeploy path conventions and helpers for WinPECT credential handoff.

.DESCRIPTION
    Dot-source this script from WinPE (export) or full Windows (import). It wraps
    the upstream WinPECT engine (https://github.com/cmartinezone/WinPECT) with
    LiteDeploy defaults:

      Package : <OsDrive>\<LocalRootName>\Content\Credentials\CredentialTransfer.bin
      Output  : <OsDrive>\<LocalRootName>\Content\Credentials\ (SYSTEM DPAPI CLIXML)
      Registry: LiteDeploy\CredentialTransfer  (offline SOFTWARE hive / HKLM:\SOFTWARE)

    Secrets are accepted only as in-memory PSCredential objects (SecretMap or
    Secrets). Plaintext passwords are never written to disk by this wrapper.

.NOTES
    Keep this file next to WinPECredentialTransfer.ps1 under Engine\Tools\WinPECT (published to the share by Admin.Build).
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:LiteDeployWinPECTDefaults = [pscustomobject]@{
    RegistrySubKey      = 'LiteDeploy\CredentialTransfer'
    PackageFileName     = 'CredentialTransfer.bin'
    CredentialsLeaf     = 'Content\Credentials'
    DeploymentShareId   = 'DeploymentShare'
    StagedToolsLeaf     = 'Engine\Tools\WinPECT'
}

# Dot-source the core WinPECT engine into the caller session
$script:WinPECTEnginePath = Join-Path $PSScriptRoot 'WinPECredentialTransfer.ps1'
if (Test-Path -LiteralPath $script:WinPECTEnginePath -PathType Leaf) {
    . $script:WinPECTEnginePath
}

function Get-LiteDeployWinPECTEnginePath {
    $enginePath = Join-Path $PSScriptRoot 'WinPECredentialTransfer.ps1'
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        throw "WinPECT engine not found: $enginePath"
    }
    return $enginePath
}

function Import-LiteDeployWinPECTEngine {
    if (-not (Get-Command Mount-WPCTOfflineSoftwareHive -ErrorAction SilentlyContinue)) {
        $enginePath = Get-LiteDeployWinPECTEnginePath
        . $enginePath
        Get-ChildItem function:*WPCT* | ForEach-Object {
            Set-Item -Path "function:global:$($_.Name)" -Value $_.ScriptBlock -Force
        }
    }
}

function Resolve-LiteDeployWinPECTOsRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OsDriveLetter,

        [string]$LocalRootName = '~LiteDeploy'
    )

    $drive = ($OsDriveLetter -replace '[\\/]+$', '').Trim()
    if ($drive -notmatch '^[A-Za-z]:?$') {
        throw "Invalid OS drive letter '$OsDriveLetter'."
    }
    if ($drive.Length -eq 1) { $drive += ':' }
    if ([string]::IsNullOrWhiteSpace($LocalRootName) -or $LocalRootName -match '[\\/:]' -or $LocalRootName -in @('.', '..')) {
        throw 'LocalRootName must be one directory name.'
    }

    return [pscustomobject]@{
        DriveRoot     = "$drive\"
        LocalRootName = $LocalRootName
        LocalRoot     = Join-Path "$drive\" $LocalRootName
        WindowsPath   = Join-Path "$drive\" 'Windows'
    }
}

function Get-LiteDeployWinPECTPaths {
    <#
    .SYNOPSIS
        Resolves LiteDeploy-standard WinPECT package, output, and staging paths.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OsDriveLetter,

        [string]$LocalRootName = '~LiteDeploy'
    )

    $roots = Resolve-LiteDeployWinPECTOsRoot -OsDriveLetter $OsDriveLetter -LocalRootName $LocalRootName
    $credentialsDir = Join-Path $roots.LocalRoot $script:LiteDeployWinPECTDefaults.CredentialsLeaf

    return [pscustomobject]@{
        DriveRoot         = $roots.DriveRoot
        LocalRoot         = $roots.LocalRoot
        WindowsPath       = $roots.WindowsPath
        CredentialsDir    = $credentialsDir
        SecretFilePath    = Join-Path $credentialsDir $script:LiteDeployWinPECTDefaults.PackageFileName
        OutputDirectory   = $credentialsDir
        RegistrySubKey    = $script:LiteDeployWinPECTDefaults.RegistrySubKey
        StagedToolsDir    = Join-Path $roots.LocalRoot $script:LiteDeployWinPECTDefaults.StagedToolsLeaf
    }
}

function ConvertTo-LiteDeployWinPECTSecrets {
    <#
    .SYNOPSIS
        Normalizes SecretMap / Secrets / a single share PSCredential into WPCT secret objects.
    #>
    param(
        [hashtable]$SecretMap = $null,
        [object[]]$Secrets = $null,
        [System.Management.Automation.PSCredential]$ShareCredential = $null,
        [string]$ShareSecretId = 'DeploymentShare'
    )

    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    if ($Secrets) {
        foreach ($item in @($Secrets)) {
            if ($null -eq $item) { continue }
            $id = $null
            $cred = $null
            if ($item -is [hashtable]) {
                $id = [string]$item['Id']
                $cred = $item['Credential']
            }
            else {
                if ($item.PSObject.Properties['Id']) { $id = [string]$item.Id }
                if ($item.PSObject.Properties['Credential']) { $cred = $item.Credential }
            }
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'Each Secrets entry requires Id.' }
            if ($cred -isnot [System.Management.Automation.PSCredential]) {
                throw "Secrets entry '$id' must be a PSCredential."
            }
            if (-not $seen.Add($id)) { throw "Duplicate secret Id '$id'." }
            $list.Add([pscustomobject]@{ Id = $id; Credential = $cred })
        }
    }

    if ($SecretMap) {
        foreach ($key in @($SecretMap.Keys)) {
            $id = [string]$key
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'SecretMap keys must be non-empty secret Ids.' }
            $cred = $SecretMap[$key]
            if ($cred -isnot [System.Management.Automation.PSCredential]) {
                throw "SecretMap entry '$id' must be a PSCredential."
            }
            if (-not $seen.Add($id)) { throw "Duplicate secret Id '$id'." }
            $list.Add([pscustomobject]@{ Id = $id; Credential = $cred })
        }
    }

    if ($null -ne $ShareCredential) {
        if ($ShareCredential -isnot [System.Management.Automation.PSCredential]) {
            throw 'ShareCredential must be a PSCredential.'
        }
        if (-not $seen.Contains($ShareSecretId)) {
            $null = $seen.Add($ShareSecretId)
            $list.Add([pscustomobject]@{ Id = $ShareSecretId; Credential = $ShareCredential })
        }
    }

    return @($list.ToArray())
}

function Copy-LiteDeployWinPECTToolsToOsVolume {
    <#
    .SYNOPSIS
        Stages WinPECT scripts onto the OS volume so FullOS import can run offline.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    $null = New-Item -Path $DestinationDirectory -ItemType Directory -Force -ErrorAction Stop
    $required = @(
        'WinPECredentialTransfer.ps1'
        'LiteDeploy.WinPECT.ps1'
    )
    foreach ($name in $required) {
        $source = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required WinPECT file missing: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $DestinationDirectory $name) -Force -ErrorAction Stop
    }

    return $DestinationDirectory
}

function Export-LiteDeployWinPECTCredentials {
    <#
    .SYNOPSIS
        Creates a WinPECT transfer on the installed OS volume (WinPE phase).

    .DESCRIPTION
        Mounts the offline SOFTWARE hive, writes CredentialTransfer.bin under
        LocalRoot\Credentials, stores the bootstrap secret under
        LiteDeploy\CredentialTransfer, and stages import scripts under
        LocalRoot\Tools\WinPECT.

    .PARAMETER OsDriveLetter
        Installed OS volume as seen from WinPE (for example W:).
    .PARAMETER LocalRootName
        Local root folder name (default ~LiteDeploy).
    .PARAMETER SecretMap
        Hashtable of secret Id -> PSCredential (preferred for DeployVault IDs).
    .PARAMETER Secrets
        Array of @{ Id; Credential } or equivalent objects.
    .PARAMETER ShareCredential
        Optional BootObject.Credential (network share) stored as DeploymentShare.
    .PARAMETER RequiredSecretIds
        IDs that must exist in the package.
    .PARAMETER AllowOverwrite
        Replace an existing LiteDeploy-owned transfer.
    .PARAMETER SkipToolStaging
        Do not copy WinPECT scripts onto the OS volume.
    .PARAMETER Metadata
        Optional serializable metadata stored with the transfer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OsDriveLetter,

        [string]$LocalRootName = '~LiteDeploy',

        [hashtable]$SecretMap = $null,

        [object[]]$Secrets = $null,

        [System.Management.Automation.PSCredential]$ShareCredential = $null,

        [string[]]$RequiredSecretIds = @(),

        [object]$Metadata = $null,

        [switch]$AllowOverwrite,

        [switch]$SkipToolStaging,

        [switch]$SkipEnvironmentCheck
    )

    $isWinPE = Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
    if (-not $isWinPE -and -not $SkipEnvironmentCheck) {
        throw 'Export-LiteDeployWinPECTCredentials must run in Windows PE.'
    }

    Import-LiteDeployWinPECTEngine

    $normalized = @(ConvertTo-LiteDeployWinPECTSecrets `
            -SecretMap $SecretMap `
            -Secrets $Secrets `
            -ShareCredential $ShareCredential `
            -ShareSecretId $script:LiteDeployWinPECTDefaults.DeploymentShareId)

    if ($normalized.Count -lt 1) {
        return [pscustomobject]@{
            Success   = $true
            Skipped   = $true
            Message   = 'No in-memory credentials to hand off.'
            SecretIds = @()
        }
    }

    $paths = Get-LiteDeployWinPECTPaths -OsDriveLetter $OsDriveLetter -LocalRootName $LocalRootName
    if (-not (Test-Path -LiteralPath $paths.WindowsPath -PathType Container)) {
        throw "Target Windows directory is missing: $($paths.WindowsPath)"
    }

    $null = New-Item -Path $paths.CredentialsDir -ItemType Directory -Force -ErrorAction Stop

    if (-not $SkipToolStaging) {
        $null = Copy-LiteDeployWinPECTToolsToOsVolume -DestinationDirectory $paths.StagedToolsDir
    }

    $required = @($RequiredSecretIds)
    if ($required.Count -lt 1) {
        $required = @($normalized | ForEach-Object { $_.Id })
    }

    $mountName = 'LDWPCT_{0}' -f [guid]::NewGuid().ToString('N')
    $mount = $null
    $result = $null

    try {
        $mount = Mount-WPCTOfflineSoftwareHive `
            -WindowsPath $paths.WindowsPath `
            -MountName $mountName

        if (-not $mount.Success) {
            throw $mount.Error
        }

        $transferMeta = if ($null -ne $Metadata) { $Metadata } else {
            [pscustomobject]@{
                Product       = 'LiteDeploy'
                LocalRootName = $LocalRootName
                SecretIds     = @($normalized | ForEach-Object { $_.Id })
            }
        }

        $result = New-WPCTCredentialTransfer `
            -Secrets $normalized `
            -SecretFilePath $paths.SecretFilePath `
            -OfflineRegistryRoot $mount.Payload.RegistryRoot `
            -RegistrySubKey $paths.RegistrySubKey `
            -RequiredSecretIds $required `
            -Metadata $transferMeta `
            -AllowOverwrite:$AllowOverwrite

        if (-not $result.Success) {
            throw $result.Error
        }

        return [pscustomobject]@{
            Success         = $true
            Skipped         = $false
            Message         = 'WinPECT credential transfer staged on the OS volume.'
            SecretIds       = @($normalized | ForEach-Object { $_.Id })
            SecretFilePath  = $paths.SecretFilePath
            OutputDirectory = $paths.OutputDirectory
            RegistrySubKey  = $paths.RegistrySubKey
            StagedToolsDir  = $(if ($SkipToolStaging) { $null } else { $paths.StagedToolsDir })
            TransferId      = $(if ($result.Payload -and $result.Payload.PSObject.Properties['TransferId']) { $result.Payload.TransferId } else { $null })
            Payload         = $result.Payload
        }
    }
    finally {
        foreach ($secret in $normalized) {
            $secret.Credential = $null
        }
        if ($null -ne $mount -and $mount.Success) {
            $unmount = Dismount-WPCTOfflineSoftwareHive -MountName $mountName
            if (-not $unmount.Success) {
                Write-Warning "Offline hive cleanup failed: $($unmount.Error)"
            }
        }
    }
}

function Import-LiteDeployWinPECTCredentials {
    <#
    .SYNOPSIS
        Imports a LiteDeploy WinPECT transfer in full Windows (SYSTEM DPAPI).

    .PARAMETER OsDriveLetter
        Installed OS volume (usually C:). Defaults to SystemDrive.
    .PARAMETER LocalRootName
        Local root folder name (default ~LiteDeploy).
    .PARAMETER RequiredSecretIds
        Credential IDs that must exist.
    .PARAMETER KeepTransfer
        Retain package/registry after import (diagnostics only).
    .PARAMETER AllowClixmlOverwrite
        Replace existing CLIXML files.
    #>
    [CmdletBinding()]
    param(
        [string]$OsDriveLetter = $env:SystemDrive,

        [string]$LocalRootName = '~LiteDeploy',

        [string[]]$RequiredSecretIds = @(),

        [switch]$KeepTransfer,

        [switch]$AllowClixmlOverwrite,

        [switch]$SkipEnvironmentCheck
    )

    $isWinPE = Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
    if ($isWinPE -and -not $SkipEnvironmentCheck) {
        throw 'Import-LiteDeployWinPECTCredentials must run in the installed Windows environment.'
    }

    Import-LiteDeployWinPECTEngine

    $paths = Get-LiteDeployWinPECTPaths -OsDriveLetter $OsDriveLetter -LocalRootName $LocalRootName
    if (-not (Test-Path -LiteralPath $paths.SecretFilePath -PathType Leaf)) {
        return [pscustomobject]@{
            Success   = $true
            Skipped   = $true
            Message   = "No WinPECT package at $($paths.SecretFilePath)."
            ClixmlFiles = @()
        }
    }

    $result = Invoke-WPCTCredentialImport `
        -SecretFilePath $paths.SecretFilePath `
        -OutputDirectory $paths.OutputDirectory `
        -RegistrySubKey $paths.RegistrySubKey `
        -RequiredSecretIds $RequiredSecretIds `
        -KeepTransfer:$KeepTransfer `
        -AllowClixmlOverwrite:$AllowClixmlOverwrite

    if (-not $result.Success) {
        throw $result.Error
    }

    return [pscustomobject]@{
        Success         = $true
        Skipped         = $false
        Message         = 'WinPECT credentials imported as DPAPI CLIXML.'
        OutputDirectory = $paths.OutputDirectory
        RegistrySubKey  = $paths.RegistrySubKey
        CreatedFor      = $(if ($result.Payload) { $result.Payload.CreatedFor } else { $null })
        TransferId      = $(if ($result.Payload) { $result.Payload.TransferId } else { $null })
        CleanedUp       = $(if ($result.Payload) { $result.Payload.CleanedUp } else { $null })
        ClixmlFiles     = @(if ($result.Payload) { $result.Payload.ClixmlFiles } else { @() })
        Payload         = $result.Payload
    }
}
