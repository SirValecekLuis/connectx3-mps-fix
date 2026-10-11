<#
.SYNOPSIS
  Step 4: analyses the probe result and installs the pre-boot fix:
  UEFI Shell + startup.nsh + ref.txt in \EFI\mpsfix on the EFI system partition and a firmware boot entry
  "PCIe MPS fix (UEFI Shell)" placed FIRST. At every boot the shell sets the card's Max Payload Size to the value
  of its root port (exactly what Linux does) and then starts Windows Boot Manager.

.DESCRIPTION
  -GenerateOnly : only analyses the probe and writes the generated files to -OutputDir. Nothing is changed.
  Without it   : (admin) BCD backup -> copy files to \EFI\mpsfix -> bcdedit /copy {bootmgr} -> set path ->
                 put first -> clear the 'hidden' flag of the new entry (Windows creates it hidden and ASRock/AMI
                 firmware then skips it). If anything fails, the half-created boot entry is deleted again.
  Windows Boot Manager, its files and its own boot entry are not modified.

  Safety interlock in the generated startup.nsh: the card register is written ONLY if, at that boot,
    - the device at the card address is still the same card (vendor/device dword),
    - the root port above it still leads to the card's bus (bus-number register), and
    - the root port's Device Control is still exactly what the probe saw (so a BIOS update that changes
      the root port MPS can never produce the opposite, more dangerous mismatch).
  Otherwise nothing is written and Windows starts normally.

.PARAMETER ProbeFile     \mpsfix\probe.txt from the probe stick (e.g. E:\mpsfix\probe.txt)
.PARAMETER GenerateOnly  Analyse + generate only, change nothing
.PARAMETER OutputDir     Where generated files and backups go (default: ..\generated next to this folder)
.PARAMETER ShellPath     Local shellx64.efi (default: \shellx64.efi on the probe stick, else download); SHA256 verified

.EXAMPLE
  .\Install-MpsFix.ps1 -ProbeFile E:\mpsfix\probe.txt -GenerateOnly
  .\Install-MpsFix.ps1 -ProbeFile E:\mpsfix\probe.txt
#>
param(
    [Parameter(Mandatory = $true)][string]$ProbeFile,
    [switch]$GenerateOnly,
    [string]$OutputDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'generated'),
    [string]$ShellPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MpsFix.Common.ps1')

$MpsNames = @{ 0 = 128; 1 = 256; 2 = 512; 3 = 1024; 4 = 2048; 5 = 4096 }

function Read-Probe([string]$Path) {
    $lines = @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $res = @{}; $cur = $null
    foreach ($l in $lines) {
        if ($l -match '^(CARD|ROOTPORT)\s+([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})\.([0-7])$') {
            $cur = $matches[1]
            $res[$cur] = [pscustomobject]@{ Loc = [pscustomobject]@{ Bus = [Convert]::ToInt32($matches[2], 16); Device = [Convert]::ToInt32($matches[3], 16); Function = [int]$matches[4]; Text = ('{0}:{1}.{2}' -f $matches[2], $matches[3], $matches[4]).ToUpper() }; Dwords = New-Object Collections.Generic.List[uint32] }
        } elseif ($l -eq 'END') { $cur = $null }
        elseif ($cur -and $l -match '^0x([0-9A-Fa-f]{8})$') { $res[$cur].Dwords.Add([Convert]::ToUInt32($matches[1], 16)) }
        elseif ($cur) { throw "Unexpected line in probe file: '$l' (the probe may have failed - check the stick)" }
    }
    foreach ($k in 'CARD', 'ROOTPORT') {
        if (-not $res.ContainsKey($k)) { throw "Probe file has no $k section" }
        if ($res[$k].Dwords.Count -ne 64) { throw "Probe $k section has $($res[$k].Dwords.Count) values, expected 64" }
        $b = New-Object byte[] 256; for ($i = 0; $i -lt 64; $i++) { [BitConverter]::GetBytes([uint32]$res[$k].Dwords[$i]).CopyTo($b, $i * 4) }
        $res[$k] | Add-Member -NotePropertyName Cfg -NotePropertyValue $b
    }
    return $res
}

function U16([byte[]]$c, [int]$o) { [BitConverter]::ToUInt16($c, $o) }
function U32([byte[]]$c, [int]$o) { [BitConverter]::ToUInt32($c, $o) }

function Find-PcieCap([byte[]]$c, [string]$Who) {
    if (((U16 $c 0x06) -band 0x10) -eq 0) { throw "$Who has no capability list" }
    $p = $c[0x34] -band 0xFC; $n = 0
    while ($p -ge 0x40 -and $p -le 0xFC -and $n -lt 48) {
        if ($c[$p] -eq 0x10) { return $p }
        $p = $c[$p + 1] -band 0xFC; $n++
    }
    throw "$Who has no PCI Express capability in the first 256 bytes"
}

try {
    $logDir = $OutputDir; New-Item -ItemType Directory -Force $logDir | Out-Null
    Start-Log (Join-Path $logDir ('install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log'))

    # ================= analysis =================
    $pr = Read-Probe $ProbeFile
    $c = $pr.CARD.Cfg; $r = $pr.ROOTPORT.Cfg; $cl = $pr.CARD.Loc; $rl = $pr.ROOTPORT.Loc
    $cardId = U32 $c 0; $rpId = U32 $r 0
    if ($cardId -eq 0xFFFFFFFF) { throw "No device answered at $($cl.Text) during the probe" }
    if ((U16 $c 0) -ne 0x15B3) { throw ("Device at {0} is not Mellanox (ID 0x{1:X8})" -f $cl.Text, $cardId) }
    if (($c[0x0E] -band 0x7F) -ne 0) { throw 'Card config space is not a type-0 header' }
    if (($r[0x0E] -band 0x7F) -ne 1 -or $r[0x0B] -ne 6 -or $r[0x0A] -ne 4) { throw "Device at $($rl.Text) is not a PCI-to-PCI bridge" }
    $sec = $r[0x19]; $sub = $r[0x1A]
    if ($sec -ne $cl.Bus -or $sub -lt $cl.Bus) { throw ("Root port {0} leads to bus {1:X2}-{2:X2}, the card is on bus {3:X2}" -f $rl.Text, $sec, $sub, $cl.Bus) }
    $ccap = Find-PcieCap $c 'Card'; $rcap = Find-PcieCap $r 'Root port'
    $portType = ((U16 $r ($rcap + 2)) -shr 4) -band 0xF
    if ($portType -ne 4) { throw "The bridge at $($rl.Text) is not a PCIe root port (port type $portType)" }
    $cDevCap = U32 $c ($ccap + 4); $cDevCtl = U16 $c ($ccap + 8); $cDevSta = U16 $c ($ccap + 10)
    $rDevCap = U32 $r ($rcap + 4); $rDevCtl = U16 $r ($rcap + 8)
    $cMpss = $cDevCap -band 7; $cMps = ($cDevCtl -shr 5) -band 7; $rMps = ($rDevCtl -shr 5) -band 7; $rMpss = $rDevCap -band 7
    $busReg = U32 $r 0x18
    Write-Log ("Card      {0}  ID 0x{1:X8}  PCIe cap 0x{2:X2}  DevCap MPS supported {3} B  DevCtl 0x{4:X4} -> MPS {5} B  DevSta 0x{6:X4}" -f $cl.Text, $cardId, $ccap, $MpsNames[[int]$cMpss], $cDevCtl, $MpsNames[[int]$cMps], $cDevSta)
    Write-Log ("Root port {0}  ID 0x{1:X8}  PCIe cap 0x{2:X2}  DevCap MPS supported {3} B  DevCtl 0x{4:X4} -> MPS {5} B  buses 0x{6:X8}" -f $rl.Text, $rpId, $rcap, $MpsNames[[int]$rMpss], $rDevCtl, $MpsNames[[int]$rMps], $busReg)
    if ($cDevSta -band 0x4) { Write-Log 'Note: the card already reports a FATAL error at this point (usually its option ROM hit the same mismatch during POST). See README: CSM / option ROM.' 'Yellow' }

    if ($cMps -eq $rMps) { Write-Log "No Max Payload Size mismatch: card and root port both use $($MpsNames[[int]$cMps]) B. This fix does NOT apply to your system - see README troubleshooting." 'Yellow'; exit 2 }
    if ($cMps -gt $rMps) { throw "Card MPS ($($MpsNames[[int]$cMps]) B) is larger than the root port's ($($MpsNames[[int]$rMps]) B) - a different problem, this fix does not apply." }
    if ($cMpss -lt $rMps) { throw "The card cannot use the root port's MPS ($($MpsNames[[int]$rMps]) B) - this fix does not apply." }
    $newCtl = [uint16]((($cDevCtl -band 0xFF1F) -bor ($rMps -shl 5)) -band 0x7FFF)
    Write-Log ("MISMATCH CONFIRMED: card {0} B < root port {1} B. Fix: write card DevCtl 0x{2:X4} at offset 0x{3:X2} before Windows starts." -f $MpsNames[[int]$cMps], $MpsNames[[int]$rMps], $newCtl, ($ccap + 8)) 'Green'

    # ================= generate =================
    $aId  = Format-MmPci $cl 0
    $aBus = Format-MmPci $rl 0x18
    $aRpc = Format-MmPci $rl ($rcap + 8)
    $aCtl = Format-MmPci $cl ($ccap + 8)
    $ref  = ("0x{0:X8}`r`n0x{1:X8}`r`n0x{2:X4}`r`n" -f $cardId, $busReg, $rDevCtl)
    $nsh = @"
@echo -off
# PCIe Max Payload Size fix - runs before Windows at every boot (connectx3-mps-fix, generated by Install-MpsFix.ps1).
# The BIOS leaves the card $($cl.Text) at MPS $($MpsNames[[int]$cMps]) B while root port $($rl.Text) uses $($MpsNames[[int]$rMps]) B -> Code 43 in Windows.
# Like Linux does, set the card to the root port's MPS. The write happens ONLY if all three reads match ref.txt:
#   card $($cl.Text) reg 0x00 = card ID, root port $($rl.Text) reg 0x18 = bus numbers, root port DevCtl = value seen by the probe.
# Volatile (lost at power-off). Then starts Windows Boot Manager.

set -v fix none
set -v win none
for %i run (0 15)
  if exist fs%i:\EFI\mpsfix\ref.txt then
    set -v fix fs%i:
  endif
  if exist fs%i:\EFI\Microsoft\Boot\bootmgfw.efi then
    set -v win fs%i:
  endif
endfor
if exist %fix%\EFI\Microsoft\Boot\bootmgfw.efi then
  set -v win %fix%
endif

if not "%fix%" == "none" then
  mm $aId -pci -w 4 -n >a %fix%\EFI\mpsfix\now.txt
  mm $aBus -pci -w 4 -n >>a %fix%\EFI\mpsfix\now.txt
  mm $aRpc -pci -w 2 -n >>a %fix%\EFI\mpsfix\now.txt
  comp %fix%\EFI\mpsfix\ref.txt %fix%\EFI\mpsfix\now.txt
  if %lasterror% == 0 then
    mm $aCtl $('{0:X4}' -f $newCtl) -pci -w 2 -n
    echo "mpsfix: card $($cl.Text) MPS set to $($MpsNames[[int]$rMps]) B"
  else
    echo "mpsfix: check failed - nothing written"
  endif
endif

if not "%win%" == "none" then
  %win%\EFI\Microsoft\Boot\bootmgfw.efi
endif
exit
"@
    $nsh = ($nsh -replace "`r?`n", "`r`n")
    $gen = Join-Path $OutputDir 'EFI\mpsfix'; New-Item -ItemType Directory -Force $gen | Out-Null
    [IO.File]::WriteAllText((Join-Path $gen 'startup.nsh'), $nsh, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $gen 'ref.txt'), $ref, [Text.Encoding]::ASCII)
    Write-Log "Generated: $gen\startup.nsh and ref.txt"
    if ($GenerateOnly) { Write-Log 'GenerateOnly: nothing was installed.' 'Green'; exit 0 }

    # ================= install =================
    Assert-Admin
    if (Test-SecureBootOn) { throw 'Secure Boot is ON. The UEFI Shell is not signed and would not start - see README "Requirements".' }
    $bl = Get-BitLockerState
    if ($bl -eq 'On') { throw "BitLocker is ON for $env:SystemDrive. Changing the boot path would ask for the recovery key. Run 'Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 3' first (see README), then run this again." }
    Enable-FirmwareAccess
    if (@(Find-FixBootEntries).Count -gt 0) { throw "A boot entry '$($script:EntryDescription)' already exists - run Uninstall-MpsFix.ps1 first." }

    $shell = Join-Path $env:TEMP ('mpsfix-shell-' + [guid]::NewGuid().ToString('N') + '.efi')
    $stickShell = Join-Path (Split-Path (Split-Path $ProbeFile -Parent) -Parent) 'shellx64.efi'
    if ($ShellPath) { Copy-Item $ShellPath $shell }
    elseif (Test-Path $stickShell) { Copy-Item $stickShell $shell }
    else { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $script:ShellUrl -OutFile $shell -UseBasicParsing }
    if ((Get-FileHash $shell).Hash -ne $script:ShellSha256) { throw 'UEFI Shell SHA256 mismatch' }

    $bak = Join-Path $OutputDir ('bcd-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Invoke-Native 'bcdedit.exe' @('/export', $bak) | Out-Null
    Write-Log "BCD backup: $bak"

    $letter = $null; $mounted = $false; $guid = $null; $done = $false
    try {
        $letter = Get-FreeDriveLetter
        Invoke-Native 'mountvol.exe' @("$($letter):", '/S') | Out-Null; $mounted = $true
        $esp = "$($letter):"
        if (-not ((Test-Path "$esp\EFI\Microsoft\Boot\bootmgfw.efi") -and (Test-Path "$esp\EFI\Microsoft\Boot\BCD"))) { throw "$esp is not the Windows EFI system partition" }
        $free = (New-Object IO.DriveInfo $esp).AvailableFreeSpace
        if ($free -lt 5MB) { throw "Not enough free space on the EFI partition ($([int]($free/1MB)) MB)" }
        New-Item -ItemType Directory -Force "$esp\EFI\mpsfix" | Out-Null
        $files = @{ 'shellx64.efi' = $shell; 'startup.nsh' = (Join-Path $gen 'startup.nsh'); 'ref.txt' = (Join-Path $gen 'ref.txt') }
        foreach ($f in $files.Keys) {
            Copy-Item $files[$f] "$esp\EFI\mpsfix\$f" -Force
            if ((Get-FileHash $files[$f]).Hash -ne (Get-FileHash "$esp\EFI\mpsfix\$f").Hash) { throw "Copy verification failed: $f" }
            Write-Log "copied \EFI\mpsfix\$f (verified)"
        }

        $out = Invoke-Native 'bcdedit.exe' @('/copy', '{bootmgr}', '/d', $script:EntryDescription)
        $guid = [regex]::Match($out, '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}').Value
        if (-not $guid) { throw 'Could not read the id of the new boot entry' }
        Invoke-Native 'bcdedit.exe' @('/set', $guid, 'path', $script:EspShellPath) | Out-Null
        Invoke-Native 'bcdedit.exe' @('/set', '{fwbootmgr}', 'displayorder', $guid, '/addfirst') | Out-Null
        $name = Show-FixBootEntry -BackupDir $OutputDir
        $done = $true
        Write-Log ("BootOrder now: " + ((Get-BootOrder | ForEach-Object { 'Boot{0:X4}' -f $_ }) -join ', '))
        Write-Log "INSTALLED: $name '$($script:EntryDescription)'  BCD id $guid" 'Green'
    } catch {
        if ($guid -and -not $done) { try { Invoke-Native 'bcdedit.exe' @('/delete', $guid) | Out-Null; Write-Log "rolled back boot entry $guid" 'Yellow' } catch { Write-Log "rollback failed: $_" 'Red' } }
        throw
    } finally {
        if ($mounted) { & mountvol.exe "$($letter):" /D | Out-Null; Write-Log "EFI partition unmounted ($($letter):)" 'DarkGray' }
        if (Test-Path $shell) { Remove-Item $shell -Force }
    }

    Write-Log ''
    Write-Log 'Next:' 'Green'
    Write-Log '  1. Restart, enter BIOS setup. ASRock: Advanced mode (F6) -> Boot -> Boot Option #1 = "PCIe MPS fix (UEFI Shell)".'
    Write-Log '     If there is a "UEFI Hard Disk Drive BBS Priorities" list, put it above Windows Boot Manager there too. Save (F10).'
    Write-Log '  2. Watch for the black UEFI Shell screen (5 s countdown) and "mpsfix: card ... MPS set to ..." - do not press keys.'
    Write-Log '  3. In Windows run 3-TEST.cmd (or .\Test-MpsFix.ps1 as administrator).'
    exit 0
} catch {
    Write-Log "ERROR: $_" 'Red'
    exit 1
}
