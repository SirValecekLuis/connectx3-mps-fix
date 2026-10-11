<#
.SYNOPSIS
  Guided installation (started by 2-FIX.cmd). Run it twice:
    1st run: check the card -> prepare the read-only probe USB stick -> you restart and boot the stick once
    2nd run: it finds the probe result on the stick -> shows the analysis -> asks -> installs the fix
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MpsFix.Common.ps1')
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Ask([string]$q) { $a = Read-Host "$q [Y/N]"; return ($a -match '^\s*[yYaAjJ]') }
function Pause-End { Say ''; Read-Host 'Press Enter to close' | Out-Null }

try {
    Assert-Admin
    Say ''
    Say '================  ConnectX-3 MPS fix - guided installation  ================' 'Cyan'

    # Is there already a probe result on a USB stick?
    $probe = @(Get-UsbVolumes | ForEach-Object { "$($_.DriveLetter):\mpsfix\probe.txt" } |
               Where-Object { Test-Path $_ } | Sort-Object { (Get-Item $_).LastWriteTime } -Descending)

    if ($probe.Count -eq 0) {
        # ---------------- first run ----------------
        Say 'STEP 1 of 3 - checking your card' 'Cyan'
        & (Join-Path $PSScriptRoot 'Check-MyCard.ps1')
        $rc = $LASTEXITCODE
        if ($rc -eq 3) { Pause-End; exit }
        if ($rc -eq 0) { Say ''; Say 'Your card does not look affected (or the fix already works). Nothing to do.' 'Green'; if (-not (Ask 'Continue anyway?')) { Pause-End; exit } }
        if ($rc -eq 2) { Say ''; Say 'This does not look like the MPS bug. The fix will most likely not help.' 'Yellow'; if (-not (Ask 'Continue anyway?')) { Pause-End; exit } }

        Say ''
        Say 'STEP 2 of 3 - read-only probe USB stick' 'Cyan'
        Say 'The fix must know the exact register values the BIOS leaves BEFORE Windows starts. A small USB stick boots once,'
        Say 'READS them (writes nothing to your PC), saves them on the stick and starts Windows again.'
        Say 'You need a USB stick formatted FAT32 (files on it can stay; for > 32 GB use Rufus "Large FAT32" - see README).'
        Say ''
        $vols = @(Get-UsbVolumes)
        if ($vols.Count -eq 0) { Say 'No USB stick found. Plug one in and start 2-FIX.cmd again.' 'Yellow'; Pause-End; exit }
        $vols | ForEach-Object { Say ("   {0}:  {1,-12} {2,-6} {3,6:N1} GB{4}" -f $_.DriveLetter, $_.FileSystemLabel, $_.FileSystem, ($_.Size / 1GB), $(if ($_.FileSystem -ne 'FAT32') { '   <- not FAT32, cannot be used' } else { '' })) }
        $l = (Read-Host 'Drive letter of the USB stick to use (e.g. E)').Trim().TrimEnd(':')
        & (Join-Path $PSScriptRoot 'New-ProbeUsb.ps1') -UsbDrive "$($l):"
        if ($LASTEXITCODE -ne 0) { Say 'Probe stick could not be prepared (see the message above).' 'Red'; Pause-End; exit 1 }
        Say ''
        Say 'NOW:' 'Green'
        Say '  1. Leave the stick plugged in and restart the PC.'
        Say '  2. During start-up open the boot menu (ASRock: F11, ASUS: F8, MSI: F11, Gigabyte: F12) and choose "UEFI: <your stick>".'
        Say '  3. Do not press anything during the 5 s countdown. When it asks for a key, press Enter - Windows starts.'
        Say '  4. Back in Windows, double-click 2-FIX.cmd again (stick still plugged in) - it continues with step 3.'
        if (Ask 'Restart now?') { Restart-Computer -Force }
        exit
    }

    # ---------------- second run ----------------
    $p = $probe[0]
    Say "STEP 3 of 3 - probe result found: $p  ($((Get-Item $p).LastWriteTime))" 'Cyan'
    & (Join-Path $PSScriptRoot 'Install-MpsFix.ps1') -ProbeFile $p -GenerateOnly
    $rc = $LASTEXITCODE
    if ($rc -eq 2) { Say ''; Say 'The probe found NO mismatch on that boot. If the card still fails, probe once more (delete \mpsfix\probe.txt on the stick and run 2-FIX.cmd again).' 'Yellow'; Pause-End; exit }
    if ($rc -ne 0) { Say 'Analysis failed - see the message above.' 'Red'; Pause-End; exit 1 }
    Say ''
    Say 'Installing will: back up your boot configuration, copy 3 small files to \EFI\mpsfix on the EFI partition,'
    Say 'add the boot entry "PCIe MPS fix (UEFI Shell)" in front of Windows Boot Manager. Windows itself is not modified.'
    if (-not (Ask 'Install the fix now?')) { Pause-End; exit }
    & (Join-Path $PSScriptRoot 'Install-MpsFix.ps1') -ProbeFile $p
    if ($LASTEXITCODE -ne 0) { Say 'Installation did not complete - nothing is left half-done. See the message above.' 'Red'; Pause-End; exit 1 }
    Rename-Item $p ('probe-used-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    Say ''
    Say 'DONE. Last two things:' 'Green'
    Say '  1. Restart, enter BIOS setup (usually Del), Advanced mode -> Boot -> Boot Option #1 = "PCIe MPS fix (UEFI Shell)". Save (F10).'
    Say '     (Some BIOSes also have a "UEFI Hard Disk Drive BBS Priorities" list - put it first there too.)'
    Say '  2. After Windows has started, double-click 3-TEST.cmd. It must end with "RESULT: everything OK".'
    Say '  The USB stick is not needed any more (keep it for a possible re-install after a BIOS update).'
    Pause-End
} catch {
    Say "ERROR: $_" 'Red'; Pause-End; exit 1
}
