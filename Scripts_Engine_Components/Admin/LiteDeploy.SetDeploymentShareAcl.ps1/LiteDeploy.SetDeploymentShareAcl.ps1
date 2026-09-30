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
    [string[]]$ADGroups = @()
)

# --- Internal Helper Functions ---

function New-LiteDeployFolderStructure {
    param([string]$Path)
    
    $enginePath = Join-Path $Path "Engine"
    $logsPath   = Join-Path $Path "WorkLogs\Deployments"

    Write-Host "[+] Creating folder structure under '$Path'..." -ForegroundColor Cyan
    New-Item -Path $enginePath -ItemType Directory -Force | Out-Null
    New-Item -Path $logsPath -ItemType Directory -Force | Out-Null
    
    return @{
        EnginePath = $enginePath
        LogsPath   = $logsPath
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
    $shareAccess = @("Administrators") + $FullAccessIdentities | Where-Object { $_ } | Select-Object -Unique
    New-SmbShare -Name $Name -Path $Path -FullAccess $shareAccess -ReadAccess "Everyone" | Out-Null
    Write-Host "[+] SMB Share '$Name' configured." -ForegroundColor Green
}

function Set-LiteDeployNtfSAcl {
    param(
        [string]$RootPath,
        [string]$LogsPath,
        [string[]]$ReadIdentities
    )

    Write-Host "[+] Applying Root Share Read & Execute Permissions on '$RootPath'..." -ForegroundColor Cyan
    $rootAcl = Get-Acl $RootPath
    $rootAcl.SetAccessRuleProtection($true, $false) # Protect ACL, retain system rights

    # Admin Rule
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow"
    )
    $rootAcl.SetAccessRule($adminRule)

    # Apply Read & Execute to all specified Users/AD Groups
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

    Write-Host "[+] Applying Granular Write & CREATOR OWNER Permissions on '$LogsPath'..." -ForegroundColor Cyan
    $logsAcl = Get-Acl $LogsPath
    $logsAcl.SetAccessRuleProtection($true, $false)

    # Rule A: Grant specified Users/Groups ability to create files/folders inside WorkLogs\Deployments ONLY
    foreach ($identity in $ReadIdentities) {
        if (-not [string]::IsNullOrWhiteSpace($identity)) {
            $createRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity, "CreateFiles, CreateDirectories, Traverse, ReadAttributes", "None", "None", "Allow"
            )
            $logsAcl.SetAccessRule($createRule)
        }
    }

    # Rule B: Grant CREATOR OWNER Full Control over whatever subfolder/file they create
    $creatorOwnerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "CREATOR OWNER", "FullControl", "ContainerInherit, ObjectInherit", "InheritOnly", "Allow"
    )

    # Rule C: Grant Administrators Full Access over logs
    $logsAcl.SetAccessRule($adminRule)
    $logsAcl.SetAccessRule($creatorOwnerRule)

    Set-Acl -Path $LogsPath -AclObject $logsAcl
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
    Set-LiteDeployNtfSAcl -RootPath $SharePath -LogsPath $paths.LogsPath -ReadIdentities $allReadIdentities

    Write-Host "`n====================================================" -ForegroundColor Green
    Write-Host " LiteDeploy Share & ACL Setup Completed!" -ForegroundColor Green
    Write-Host " Share UNC   : \\localhost\$ShareName" -ForegroundColor Yellow
    Write-Host " Engine Path : \\localhost\$ShareName\Engine" -ForegroundColor Yellow
    Write-Host " Log Path    : \\localhost\$ShareName\WorkLogs\Deployments" -ForegroundColor Yellow
    Write-Host "====================================================`n" -ForegroundColor Green
}

# Run setup
Invoke-LiteDeployAclSetup