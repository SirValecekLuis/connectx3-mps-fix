# Shared helpers for the ConnectX-3 MPS fix scripts. Dot-sourced by the other scripts - do not run directly.
Set-StrictMode -Version 2

$script:EfiGlobalGuid    = '{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}'
$script:ShellUrl         = 'https://github.com/pbatard/UEFI-Shell/releases/download/26H2/shellx64.efi'
$script:ShellSha256      = '4922D9885AC92D8AB58E5DA4EB8AD6CBFBE651EA9CDC03A1BA67355E5EDE83B1'
$script:EntryDescription = 'PCIe MPS fix (UEFI Shell)'
$script:EspFolderName    = 'mpsfix'                       # -> \EFI\mpsfix on the EFI system partition
$script:EspShellPath     = '\EFI\mpsfix\shellx64.efi'
$script:LogFile          = $null

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    if ($script:LogFile) { $Message | Out-File -FilePath $script:LogFile -Append -Encoding utf8 }
    Write-Host $Message -ForegroundColor $Color
}

function Start-Log([string]$Path) {
    $script:LogFile = $Path
    "==== $(Split-Path $Path -Leaf)  $(Get-Date -Format s) ====" | Out-File -FilePath $Path -Encoding utf8
}

function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated PowerShell (Run as administrator).' }
}

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE
    Write-Log "> $Exe $($Arguments -join ' ')  (exit $rc)" 'DarkGray'
    $out | ForEach-Object { Write-Log "  $_" 'DarkGray' }
    if ($rc -ne 0) { throw "$Exe failed with exit code $rc" }
    return ($out -join "`n")
}

# ---------- UEFI variables (BootOrder / Boot####) ----------
if (-not ('MpsFixFirmware' -as [type])) {
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class MpsFixFirmware {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern uint GetFirmwareEnvironmentVariableExW(string name, string guid, byte[] buf, uint size, out uint attr);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool SetFirmwareEnvironmentVariableExW(string name, string guid, byte[] buf, uint size, uint attr);
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
  [StructLayout(LayoutKind.Sequential, Pack=4)] struct TP { public uint Count; public long Luid; public uint Attr; }
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP ns, uint len, IntPtr prev, IntPtr rl);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  public static bool EnablePrivilege() {
    IntPtr tok; if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
    TP tp = new TP(); tp.Count = 1; tp.Attr = 2;
    if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out tp.Luid)) return false;
    return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero) && Marshal.GetLastWin32Error() == 0;
  }
  public static byte[] Get(string name, string guid, out uint attr) {
    byte[] b = new byte[8192]; uint n = GetFirmwareEnvironmentVariableExW(name, guid, b, (uint)b.Length, out attr);
    if (n == 0) return null; byte[] r = new byte[n]; Array.Copy(b, r, n); return r;
  }
  public static bool Set(string name, string guid, byte[] data, uint attr) { return SetFirmwareEnvironmentVariableExW(name, guid, data, (uint)data.Length, attr); }
}
"@
}

function Enable-FirmwareAccess { if (-not [MpsFixFirmware]::EnablePrivilege()) { throw 'Could not enable SeSystemEnvironmentPrivilege (run as administrator).' } }

function Get-FwVar([string]$Name) {
    $a = [uint32]0; $d = [MpsFixFirmware]::Get($Name, $script:EfiGlobalGuid, [ref]$a)
    if ($null -eq $d) { return $null }
    return [pscustomobject]@{ Name = $Name; Data = $d; VarAttributes = $a }
}

function Get-BootOrder {
    $v = Get-FwVar 'BootOrder'; if (-not $v) { return @() }
    $ids = @(); for ($i = 0; $i + 1 -lt $v.Data.Length; $i += 2) { $ids += [BitConverter]::ToUInt16($v.Data, $i) }
    return $ids
}

function Get-BootCurrent {
    $v = Get-FwVar 'BootCurrent'; if (-not $v) { return $null }
    return [BitConverter]::ToUInt16($v.Data, 0)
}

function ConvertFrom-LoadOption([string]$Name, [byte[]]$d) {
    $attr = [BitConverter]::ToUInt32($d, 0); $fpl = [BitConverter]::ToUInt16($d, 4)
    $p = 6; $sb = New-Object Text.StringBuilder
    while ($p + 1 -lt $d.Length) { $c = [BitConverter]::ToUInt16($d, $p); $p += 2; if ($c -eq 0) { break }; [void]$sb.Append([char]$c) }
    $dp = $p; $end = [Math]::Min($p + $fpl, $d.Length); $files = @()
    while ($dp + 4 -le $end) {
        $t = $d[$dp]; $st = $d[$dp + 1]; $nl = [BitConverter]::ToUInt16($d, $dp + 2); if ($nl -lt 4) { break }
        if ($t -eq 4 -and $st -eq 4) { $files += [Text.Encoding]::Unicode.GetString($d, $dp + 4, $nl - 4).TrimEnd([char]0) }
        if ($t -eq 0x7F) { break }
        $dp += $nl
    }
    return [pscustomobject]@{ Name = $Name; Id = [Convert]::ToUInt16($Name.Substring(4), 16); Attributes = $attr
        Hidden = (($attr -band 0x8) -ne 0); Active = (($attr -band 0x1) -ne 0); Description = $sb.ToString(); FilePath = ($files -join '\') }
}

function Get-BootEntries {
    $list = @()
    foreach ($i in 0..0x7F) {
        $n = 'Boot{0:X4}' -f $i; $v = Get-FwVar $n
        if ($v) { $list += ConvertFrom-LoadOption $n $v.Data }
    }
    return $list
}

function Find-FixBootEntries {
    @(Get-BootEntries | Where-Object { $_.Description -eq $script:EntryDescription -or $_.FilePath -like '*\EFI\mpsfix\shellx64.efi' })
}

# Clears LOAD_OPTION_HIDDEN on our own entry (Windows creates it as active+hidden; AMI/ASRock firmware then skips it).
function Show-FixBootEntry([string]$BackupDir) {
    $entries = @(Get-BootEntries | Where-Object { $_.Description -eq $script:EntryDescription -and $_.FilePath -like '*\EFI\mpsfix\shellx64.efi' })
    if ($entries.Count -ne 1) { throw "Expected exactly one boot entry '$($script:EntryDescription)', found $($entries.Count)" }
    $e = $entries[0]; $v = Get-FwVar $e.Name
    if (-not $e.Hidden) { Write-Log "$($e.Name) is already visible (attributes 0x$('{0:x}' -f $e.Attributes))"; return $e.Name }
    if ($BackupDir) { $bak = Join-Path $BackupDir ("{0}-before-unhide-{1}.bin" -f $e.Name, (Get-Date -Format 'yyyyMMdd-HHmmss')); [IO.File]::WriteAllBytes($bak, $v.Data); Write-Log "backup of $($e.Name): $bak" }
    $data = [byte[]]$v.Data.Clone()
    $new = [uint32]((([uint64]$e.Attributes) -band 0xFFFFFFF7L) -bor 1)     # clear LOAD_OPTION_HIDDEN (0x8), keep ACTIVE (0x1)
    [BitConverter]::GetBytes($new).CopyTo($data, 0)
    $va = $v.VarAttributes; if ($va -eq 0) { $va = 7 }
    if (-not [MpsFixFirmware]::Set($e.Name, $script:EfiGlobalGuid, $data, [uint32]$va)) { throw "Writing $($e.Name) failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
    $chk = Get-FwVar $e.Name
    if ([Convert]::ToBase64String($chk.Data) -ne [Convert]::ToBase64String($data)) { throw "Verification of $($e.Name) failed" }
    Write-Log ("{0}: attributes 0x{1:x} -> 0x{2:x} (visible in BIOS now)" -f $e.Name, $e.Attributes, $new)
    return $e.Name
}

# ---------- EFI system partition ----------
function Get-EspPartition {
    $p = @(Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -and $_.IsSystem })
    if ($p.Count -ne 1) { $p = @(Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }) }
    if ($p.Count -ne 1) { throw "Could not identify a single EFI system partition (found $($p.Count))" }
    return $p[0]
}

function Get-EspVolumePath {
    $vp = @((Get-EspPartition).AccessPaths | Where-Object { $_ -like '\\?\Volume*' })
    if (-not $vp) { throw 'EFI system partition has no volume path' }
    return $vp[0]
}

function Get-FreeDriveLetter {
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() }) +
            @(Get-CimInstance Win32_LogicalDisk | ForEach-Object { $_.DeviceID.Substring(0, 1).ToUpper() })
    $l = [char[]](90..68) | Where-Object { $used -notcontains [string]$_ } | Select-Object -First 1
    if (-not $l) { throw 'No free drive letter' }
    return [string]$l
}

# ---------- PCI location of devices ----------
function Get-PnpProp([string]$InstanceId, [string]$Key) {
    $p = @(Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction SilentlyContinue)
    if ($p.Count -eq 0 -or $null -eq $p[0] -or -not $p[0].PSObject.Properties['Data']) { return $null }
    return $p[0].Data
}

function Get-PciLocation([string]$InstanceId) {
    $bus = Get-PnpProp $InstanceId 'DEVPKEY_Device_BusNumber'; $adr = Get-PnpProp $InstanceId 'DEVPKEY_Device_Address'
    if ($null -eq $bus -or $null -eq $adr) { throw "No PCI location for $InstanceId" }
    $o = [pscustomobject]@{ Bus = [int]$bus; Device = [int](($adr -shr 16) -band 0x1F); Function = [int]($adr -band 0x7) }
    $o | Add-Member -NotePropertyName Text -NotePropertyValue ('{0:X2}:{1:X2}.{2:X}' -f $o.Bus, $o.Device, $o.Function)
    return $o
}

# Address format of the UEFI Shell 'mm -pci' command: bbddffrr (hex), see EDK2 ShellPkg Mm.c
function Format-MmPci([object]$Loc, [int]$Register) { '{0:X2}{1:X2}{2:X2}{3:X2}' -f $Loc.Bus, $Loc.Device, $Loc.Function, $Register }

function Get-MellanoxCards {
    @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like 'PCI\VEN_15B3&*' -and (Get-PnpProp $_.InstanceId 'DEVPKEY_PciDevice_BaseClass') -in 2, 0x0C })
}

function Get-RootPortOf([string]$CardInstanceId) {
    $parent = Get-PnpProp $CardInstanceId 'DEVPKEY_Device_Parent'
    if (-not $parent -or $parent -notlike 'PCI\*') { throw "Parent of the card is not a PCI device ($parent)" }
    $bc = Get-PnpProp $parent 'DEVPKEY_PciDevice_BaseClass'; $sc = Get-PnpProp $parent 'DEVPKEY_PciDevice_SubClass'
    if ($bc -ne 6 -or $sc -ne 4) { throw "Parent of the card is not a PCI-to-PCI bridge ($parent)" }
    $gp = Get-PnpProp $parent 'DEVPKEY_Device_Parent'
    if ($gp -notlike 'ACPI\PNP0A08*' -and $gp -notlike 'ACPI\PNP0A03*') { throw "The card is behind a PCIe switch (bridge parent: $gp). This tool only handles cards directly on a root port." }
    return $parent
}

function Get-UsbVolumes {
    @(Get-Disk -ErrorAction SilentlyContinue | Where-Object BusType -eq 'USB' | ForEach-Object { Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue } |
      Where-Object { $_.DriveLetter } | ForEach-Object { Get-Volume -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue } | Where-Object { $_ })
}

function Test-SecureBootOn { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled -eq 1 }

function Get-BitLockerState([string]$Drive = $env:SystemDrive) {
    try { $v = Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop; return [string]$v.ProtectionStatus } catch { }
    try { $s = (New-Object -ComObject Shell.Application).NameSpace("$Drive\").Self.ExtendedProperty('System.Volume.BitLockerProtection'); if ($s -in 1, 3, 6) { return 'On' } elseif ($s -eq 5) { return 'Off' } else { return 'Off' } } catch { }
    return 'Unknown'
}
