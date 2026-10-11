<#
.SYNOPSIS
  Removes the fix: deletes the firmware boot entry "PCIe MPS fix (UEFI Shell)" and the folder \EFI\mpsfix on the
  EFI system partition. Nothing else is touched. Run as administrator.

.PARAMETER KeepFiles  Only delete the boot entry, keep \EFI\mpsfix
#>
param([switch]$KeepFiles)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MpsFix.Common.ps1')
try {
    Assert-Admin
    $fw = Invoke-Native 'bcdedit.exe' @('/enum', 'firmware')
    $ids = @(foreach ($block in ($fw -split "`n\s*`n")) {
        if ($block -match [regex]::Escape($script:EntryDescription) -or $block -match [regex]::Escape($script:EspShellPath)) { [regex]::Match($block, '\{[0-9a-fA-F-]{36}\}').Value }
    }) | Where-Object { $_ }
    if (-not $ids) { Write-Log 'No boot entry of the fix found.' }
    foreach ($id in $ids) { Invoke-Native 'bcdedit.exe' @('/delete', $id) | Out-Null; Write-Log "Deleted boot entry $id" 'Green' }

    if (-not $KeepFiles) {
        $letter = Get-FreeDriveLetter; $mounted = $false
        try {
            Invoke-Native 'mountvol.exe' @("$($letter):", '/S') | Out-Null; $mounted = $true
            if (-not (Test-Path "$($letter):\EFI\Microsoft\Boot\bootmgfw.efi")) { throw "$($letter): is not the Windows EFI partition" }
            if (Test-Path "$($letter):\EFI\mpsfix") { Remove-Item -LiteralPath "$($letter):\EFI\mpsfix" -Recurse -Force; Write-Log 'Removed \EFI\mpsfix' 'Green' }
            else { Write-Log '\EFI\mpsfix not present' }
        } finally { if ($mounted) { & mountvol.exe "$($letter):" /D | Out-Null } }
    }
    Write-Log 'Done. Windows Boot Manager boots directly again (the card goes back to the BIOS default MPS).' 'Green'
    exit 0
} catch { Write-Log "ERROR: $_" 'Red'; exit 1 }
