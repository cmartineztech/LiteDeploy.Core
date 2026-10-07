# LiteDeploy Hardware

**ComponentId**: `Hardware`  
**Version**: `1.0.0`  
**Script File**: `Engine\Scripts\Runtime\000-Hardware\LiteDeploy.Hardware.ps1`  
**Target Environment**: WinPE-first (also usable where the same WMI/CIM APIs exist)

Importable `Get-Hardware*` helpers for identity, firmware, TPM, memory, CPU, NICs, disks, and network addressing. Used by HardwarePreCheck for quiet inventory, DeploymentEngine for MDT-style computer information logs, and WorkflowSelection for wipe-target disk rows (`Get-HardwarePhysicalDisks` / `Test-HardwareDiskSelectionHasCapacity`).

## Import

```powershell
# Production (flat Runtime after SyncComponents)
Import-Module "Z:\Engine\Scripts\Runtime\LiteDeploy.Hardware.ps1" -Force

# Dev layout
Import-Module ".\Engine\Scripts\Runtime\000-Hardware\LiteDeploy.Hardware.ps1" -Force

Get-HardwareVendor
Get-HardwareModel
Get-HardwareSerialNumber
Get-HardwareUUID
Get-HardwareIsUEFI
Get-HardwareTpmIsReady
Get-HardwareDnsServers
Get-HardwareDriverFolderHint
Get-HardwarePhysicalDisks
$inv = Get-HardwareInventory
```

## WinPE-safe functions

| Function | Returns |
|---|---|
| `Get-HardwareVendor` / `VendorRaw` | Normalized / raw manufacturer |
| `Get-HardwareModel` | Model (Lenovo: marketing name from `Win32_ComputerSystemProduct.Version` when present) |
| `Get-HardwareComputerSku` | Catalog SKU: Lenovo MT (`LENOVO_MT_XXXX` / first 4 of CS model); HP baseboard `Product`; else `SystemSKUNumber` / BIOS / baseboard |
| `Get-HardwareBaseBoardProduct` | `Win32_BaseBoard.Product` |
| `Get-HardwareSerialNumber` | Serial |
| `Get-HardwareUUID` / `AssetTag` | UUID / asset tag |
| `Get-HardwareComputerName` | Hostname |
| `Get-HardwareArchitecture` | AMD64 / ARM64 / … |
| `Get-HardwareChassis` / `IsLaptop` / `IsDesktop` / `IsVM` | Form factor |
| `Get-HardwareIsWinPE` / `SystemDrive` | Environment |
| `Get-HardwareDriverFolderHint` | `Vendor\Model` |
| `Get-HardwareFirmwareType` / `IsUEFI` / BIOS fields | Firmware |
| `Get-HardwareSecureBoot*` | Secure Boot status / display / CA note |
| `Get-HardwareTpm*` | TPM present / version / state / ready |
| `Get-HardwareMemory*` / `Get-HardwareProcessor*` | Sizing |
| `Get-HardwareNICs` / `Get-HardwarePrimaryNicName` / MAC | Adapters |
| `Get-HardwareIPAddresses` / `Get-HardwareIPAddress` / `Get-HardwareIPv6Address` | IPv4, `IPv4PrefixLength`, `IPv4Cidr` (`x.x.x.x/24`), IPv6 |
| `Get-HardwareDnsServers` | DNS server list (up adapters; skips loopback / link-local) |
| `Get-HardwareHardDrives` / DiskCount / TotalDiskGB | Storage inventory (Number / Model / SizeGB) |
| `Get-HardwarePhysicalDisks` | Wipe-target selection rows (Index, Model, Capacity, UsedSpace, FreeSpace, DiskNumber); includes 0 GB disks; free = unallocated + readable volume free; Storage then WMI; unknown free → 0 |
| `Test-HardwareDiskSelectionHasCapacity` | True when a selection row has ≥ 1 GB (WorkflowSelection Continue gate) |
| `Get-HardwareTimezoneId` / `UtcOffsetMinutes` | Logging |
| `Get-HardwareInventory` | Full object; optional `-Assessment`, `-Results`, `-Passed` |
| `Clear-HardwareCache` | Clear script-scoped WMI/network cache |

## Inventory object (high-signal fields)

`Get-HardwareInventory` returns (among others):

| Area | Properties |
|---|---|
| Identity | `Vendor`, `Model`, `Sku` (vendor-aware), `SerialNumber`, `UUID`, `AssetTag`, `ComputerName` |
| Form factor | `Chassis`, `Architecture`, `IsLaptop`, `IsDesktop`, `IsVM`, `DriverFolderHint` |
| Firmware | `FirmwareType`, `IsUEFI`, `BiosVersion`, `SecureBootDisplay`, TPM fields |
| Compute | `MemoryGB`, `ProcessorName`, cores / logical count |
| Network | `PrimaryNicName`, `PrimaryMacAddress`, `IPAddress`, `IPv4PrefixLength`, `IPv4Cidr`, `IPv6Address`, `DnsServers`, `NICs` |
| Storage | `HardDrives` (Number / Model / SizeGB), `DiskCount`, `TotalDiskGB`. Selection grid: `Get-HardwarePhysicalDisks` (0 GB listed; Continue uses `Test-HardwareDiskSelectionHasCapacity`) |
| Assessment merge | Optional Precheck fields: mode, share, disks summary, `Results`, `Passed`, `SkippedByPolicy` |

### IPv4 prefix notes

- Prefer `IPv4Cidr` (e.g. `172.17.127.54/24`) when `PrefixLength` or IPv4 mask is available.
- If prefix is missing, consumers should log plain `IPAddress`.
- If Precheck assessment IPv4 does not match the gathered CIDR host, CIDR is cleared so a wrong `/prefix` is not kept.

## Sync layout

After SyncComponents:

```text
Engine\Scripts\Runtime\LiteDeploy.Hardware.ps1
```
