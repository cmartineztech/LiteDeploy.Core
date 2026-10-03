<#
.SYNOPSIS
    LiteDeploy.SetDeploymentShareAcl.ps1
    Configures a deployment share, SMB share permissions, and granular NTFS log ACLs.

.DESCRIPTION
    - Creates the base deployment share directory structure (Engine, WorkLogs\Deployments).
    - Creates local deployment user account if specified and doesn't exist.
    - Configures SMB Share with Full Control.
    - Applies Read & Execute permissions across the entire share for Admins, Users, and AD Groups.
    - Applies granular CREATOR OWNER permissions on WorkLogs\Deployments so callers can write logs isolated to their own subfolders.

.EXAMPLE
    .\LiteDeploy.SetDeploymentShareAcl.ps1 -SharePath "C:\DeploymentShare" -ShareName "DeploymentShare$" -LocalUser "deployer" -ADGroups "CORP\DeployAdmins", "CORP\FieldTechs"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SharePath = "C:\DeploymentShare",

    [Parameter(Mandatory = $false)]
    [string]$ShareName = "DeploymentShare$",

    [Parameter(Mandatory = $false)]
    [string]$LocalUser = "deployer",

    [Parameter(Mandatory = $false)]
    [string[]]$AdditionalUsers = @(),

    [Parameter(Mandatory = $false)]
    [string[]]$ADGroups = @(),

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
        ComponentId          = "SetDeploymentShareAcl"
        Name                 = "LiteDeploy Share ACL Hardener"
        Version              = "1.0.0"
        Category             = "Admin"
        TargetEnvironment    = "Host"
        MinPowerShellVersion = "5.1"
        Author               = "LiteDeploy Team"
        Dependencies         = @()
        Description          = "Provisions share directory layout, SMB permissions, and isolated NTFS log ACLs."
    }
}

if ($Metadata) {
    Get-LiteDeployComponentMetadata
    return
}

# --- Internal Helper Functions ---

function New-LiteDeployFolderStructure {
    param([string]$Path)
    
    $directories = @(
        "Config",
        "Content\BootMedia\ISO",
        "Content\BootMedia\WIM",
        "Content\Drivers",
        "Content\OperatingSystems",
        "Content\Packages",
        "Content\Temp",
        "Content\Unattend",
        "Engine\Scripts\Admin",
        "Engine\Scripts\Runtime",
        "Engine\Tools",
        "WorkFlows",
        "WorkLogs\Admin",
        "WorkLogs\Deployments"
    )

    Write-Host "[+] Creating complete DeploymentShare folder structure under '$Path'..." -ForegroundColor Cyan
    foreach ($dir in $directories) {
        $targetDir = Join-Path $Path $dir
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }
    }
    
    return @{
        EnginePath         = (Join-Path $Path "Engine")
        AdminLogsPath      = (Join-Path $Path "WorkLogs\Admin")
        DeploymentLogsPath = (Join-Path $Path "WorkLogs\Deployments")
    }
}

function New-LiteDeployLocalAccount {
    param([string]$UserName)
    
    if (-not $UserName) { return }

    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        Write-Host "[+] Local user '$UserName' not found. Creating..." -ForegroundColor Cyan
        $Password = Read-Host -AsSecureString -Prompt "Enter password for local user '$UserName'"
        New-LocalUser -Name $UserName -Password $Password -FullName "LiteDeploy Service Account" -Description "Deployment & Logging Account" | Out-Null
        Set-LocalUser -Name $UserName -PasswordNeverExpires $true
        Write-Host "[+] Local user '$UserName' created successfully." -ForegroundColor Green
    } else {
        Write-Host "[!] Local user '$UserName' already exists. Skipping creation." -ForegroundColor Yellow
    }
}

function Set-LiteDeploySmbShare {
    param(
        [string]$Name,
        [string]$Path,
        [string[]]$FullAccessIdentities
    )

    Write-Host "[+] Configuring SMB Share '$Name'..." -ForegroundColor Cyan
    if (Get-SmbShare -Name $Name -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $Name -Force
    }

    # Grant Administrators + all specified users/groups FullAccess at the SMB share level
    $shareAccess = @("Administrators", "SYSTEM") + $FullAccessIdentities | Where-Object { $_ } | Select-Object -Unique
    New-SmbShare -Name $Name -Path $Path -FullAccess $shareAccess -ReadAccess "Everyone" | Out-Null
    Write-Host "[+] SMB Share '$Name' configured." -ForegroundColor Green
}

function Set-LiteDeployNtfSAcl {
    param(
        [string]$RootPath,
        [string]$AdminLogsPath,
        [string]$DeploymentLogsPath,
        [string[]]$ReadIdentities
    )

    # 1. Root Share Permissions
    Write-Host "[+] Applying Root Share Read & Execute Permissions on '$RootPath'..." -ForegroundColor Cyan
    $rootAcl = Get-Acl $RootPath
    $rootAcl.SetAccessRuleProtection($true, $false) # Protect ACL, retain explicit rights

    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow"
    )
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow"
    )
    $rootAcl.SetAccessRule($adminRule)
    $rootAcl.SetAccessRule($systemRule)

    # Apply Read & Execute to all specified Users/AD Groups across general share payloads
    foreach ($identity in $ReadIdentities) {
        if (-not [string]::IsNullOrWhiteSpace($identity)) {
            Write-Host "    -> Granting ReadAndExecute to '$identity'" -ForegroundColor Gray
            $readRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity, "ReadAndExecute, Synchronize", "ContainerInherit, ObjectInherit", "None", "Allow"
            )
            $rootAcl.SetAccessRule($readRule)
        }
    }
    Set-Acl -Path $RootPath -AclObject $rootAcl

    # 2. Lock Down WorkLogs\Admin (Strictly Administrators & SYSTEM - Deployers have ZERO access)
    Write-Host "[+] Locking Down Admin Logs on '$AdminLogsPath' (Admins & SYSTEM only)..." -ForegroundColor Cyan
    $adminLogsAcl = Get-Acl $AdminLogsPath
    $adminLogsAcl.SetAccessRuleProtection($true, $false)
    $adminLogsAcl.SetAccessRule($adminRule)
    $adminLogsAcl.SetAccessRule($systemRule)
    Set-Acl -Path $AdminLogsPath -AclObject $adminLogsAcl
    Write-Host "    -> WorkLogs\Admin restricted strictly to Administrators." -ForegroundColor Green

    # 3. Configure WorkLogs\Deployments (Cross-Read & CREATOR OWNER Full Control)
    Write-Host "[+] Configuring Deployment Logs on '$DeploymentLogsPath'..." -ForegroundColor Cyan
    $depLogsAcl = Get-Acl $DeploymentLogsPath
    $depLogsAcl.SetAccessRuleProtection($true, $false)
    $depLogsAcl.SetAccessRule($adminRule)
    $depLogsAcl.SetAccessRule($systemRule)

    foreach ($identity in $ReadIdentities) {
        if (-not [string]::IsNullOrWhiteSpace($identity)) {
            # Rule A: Allow listing and reading existing deployment logs for peer diagnostics
            $readLogsRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity, "ReadAndExecute, Synchronize", "ContainerInherit, ObjectInherit", "None", "Allow"
            )
            $depLogsAcl.SetAccessRule($readLogsRule)

            # Rule B: Allow creating new deployment folders and log files under WorkLogs\Deployments
            $createFolderRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity, "CreateFiles, CreateDirectories, AppendData", "None", "None", "Allow"
            )
            $depLogsAcl.SetAccessRule($createFolderRule)
        }
    }

    # Rule C: Grant CREATOR OWNER Full Control over their own created deployment session folders
    $creatorOwnerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "CREATOR OWNER", "FullControl", "ContainerInherit, ObjectInherit", "InheritOnly", "Allow"
    )
    $depLogsAcl.SetAccessRule($creatorOwnerRule)

    Set-Acl -Path $DeploymentLogsPath -AclObject $depLogsAcl
    Write-Host "[+] NTFS ACLs successfully configured." -ForegroundColor Green
}

# --- Main Execution Flow ---

function Invoke-LiteDeployAclSetup {
    [CmdletBinding()]
    param()

    # Consolidate all users and groups into a clean array
    $allReadIdentities = @()
    if ($LocalUser) { $allReadIdentities += $LocalUser }
    if ($AdditionalUsers) { $allReadIdentities += $AdditionalUsers }
    if ($ADGroups) { $allReadIdentities += $ADGroups }
    $allReadIdentities = $allReadIdentities | Select-Object -Unique

    # 1. Create Folders
    $paths = New-LiteDeployFolderStructure -Path $SharePath

    # 2. Create Local User (if specified)
    if ($LocalUser) {
        New-LiteDeployLocalAccount -UserName $LocalUser
    }

    # 3. Create SMB Share
    Set-LiteDeploySmbShare -Name $ShareName -Path $SharePath -FullAccessIdentities $allReadIdentities

    # 4. Set NTFS ACLs
    Set-LiteDeployNtfSAcl -RootPath $SharePath -AdminLogsPath $paths.AdminLogsPath -DeploymentLogsPath $paths.DeploymentLogsPath -ReadIdentities $allReadIdentities

    Write-Host "`n====================================================" -ForegroundColor Green
    Write-Host " LiteDeploy Share & ACL Setup Completed!" -ForegroundColor Green
    Write-Host " Share UNC       : \\localhost\$ShareName" -ForegroundColor Yellow
    Write-Host " Engine Path     : \\localhost\$ShareName\Engine" -ForegroundColor Yellow
    Write-Host " Admin Logs      : \\localhost\$ShareName\WorkLogs\Admin (Locked)" -ForegroundColor Yellow
    Write-Host " Deployment Logs : \\localhost\$ShareName\WorkLogs\Deployments (Read/Own)" -ForegroundColor Yellow
    Write-Host "====================================================`n" -ForegroundColor Green
}

# Run setup
Invoke-LiteDeployAclSetup