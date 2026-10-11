<#
.SYNOPSIS
  Step 6: READ-ONLY check that the fix ran at this boot and the card works. Run as administrator after a restart.

.DESCRIPTION
  Checks: Secure Boot state, our firmware boot entry (exists, visible, first, used for THIS boot), the files in
  \EFI\mpsfix, that now.txt (written by the shell at this boot) matches ref.txt, and the Mellanox driver result
  (mlx4_bus event 6 = initialized, 73 = failed / Code 43) plus the network adapters' link state.
  Nothing is written anywhere.

.PARAMETER EspFolder    Folder under \EFI on the EFI partition (default mpsfix)
.PARAMETER Description  Boot entry description (default "PCIe MPS fix (UEFI Shell)")
#>
param([string]$EspFolder = 'mpsfix', [string]$Description = 'PCIe MPS fix (UEFI Shell)')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MpsFix.Common.ps1')
$fail = 0
function Pass([string]$m) { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Info([string]$m) { Write-Host "[info] $m" -ForegroundColor Gray }

try {
    Assert-Admin; Enable-FirmwareAccess
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Info "Last boot: $boot"
    if (Test-SecureBootOn) { Fail 'Secure Boot is ON - the UEFI Shell cannot run' } else { Pass 'Secure Boot is off' }

    $entries = @(Get-BootEntries | Where-Object { $_.Description -eq $Description -or $_.FilePath -like "*\EFI\$EspFolder\shellx64.efi" })
    $order = @(Get-BootOrder); $cur = Get-BootCurrent
    Info ("BootOrder: " + (($order | ForEach-Object { 'Boot{0:X4}' -f $_ }) -join ', ') + ("   BootCurrent: Boot{0:X4}" -f $cur))
    if ($entries.Count -ne 1) { Fail "Expected one boot entry '$Description', found $($entries.Count)" }
    else {
        $e = $entries[0]
        Pass ("Boot entry {0} '{1}' -> {2}" -f $e.Name, $e.Description, $e.FilePath)
        if ($e.Hidden) { Fail "$($e.Name) is HIDDEN - firmware may skip it (re-run Install or see README)" } else { Pass "$($e.Name) is visible" }
        if ($order.Count -gt 0 -and $order[0] -eq $e.Id) { Pass "$($e.Name) is first in BootOrder" } else { Fail "$($e.Name) is not first in BootOrder - set it as Boot Option #1 in BIOS" }
        if ($cur -eq $e.Id) { Pass "This boot was started through $($e.Name)" } else { Fail ("This boot was started through Boot{0:X4}, not through the fix" -f $cur) }
    }

    $vp = Get-EspVolumePath
    $dir = "$($vp)EFI\$EspFolder"
    $listing = (& cmd.exe /c "dir /a `"$dir`"" 2>&1) -join "`n"
    foreach ($f in 'shellx64.efi', 'startup.nsh', 'ref.txt') { if ($listing -match [regex]::Escape($f)) { Pass "\EFI\$EspFolder\$f present" } else { Fail "\EFI\$EspFolder\$f missing" } }
    $ref = (& cmd.exe /c "type `"$dir\ref.txt`"" 2>&1) -join "`n"
    $now = (& cmd.exe /c "type `"$dir\now.txt`"" 2>&1) -join "`n"
    $nowLine = ($listing -split "`n" | Where-Object { $_ -match 'now\.txt' } | Select-Object -First 1)
    if ($now -match 'cannot find') { Fail 'now.txt not found - the shell script has not run yet' }
    elseif ($now.Trim() -eq $ref.Trim()) { Pass "now.txt matches ref.txt (all three safety checks passed at the last shell run)  [$($nowLine.Trim())]" }
    else { Fail "now.txt differs from ref.txt - the shell did NOT write the card.`n       ref: $($ref -replace "`n", ' ')`n       now: $($now -replace "`n", ' ')" }

    $ev = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'mlx4_bus'; Id = 6, 73; StartTime = $boot.AddMinutes(-1) } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
    if ($ev.Count -eq 0) { Info 'No mlx4_bus start/fail event since boot (driver not installed or not started yet)' }
    elseif ($ev[-1].Id -eq 6) { Pass ("mlx4_bus initialized the card ({0:HH:mm:ss}, event 6)" -f $ev[-1].TimeCreated) }
    else { Fail ("mlx4_bus failed ({0:HH:mm:ss}, event 73 - Code 43)" -f $ev[-1].TimeCreated) }
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VEN_15B3|^MLX4' } | ForEach-Object {
        $v = Get-PnpProp $_.InstanceId 'DEVPKEY_Device_DriverVersion'
        if ($_.Status -eq 'OK') { Pass "$($_.FriendlyName) - OK (driver $v)" } else { Fail "$($_.FriendlyName) - $($_.Status) $($_.Problem) (driver $v)" }
    }
    Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object InterfaceDescription -match 'Mellanox' | ForEach-Object { Info ("{0}: {1} {2}" -f $_.InterfaceDescription, $_.Status, $_.LinkSpeed) }
    $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($hb -eq 1) { Info 'Fast Startup is ON: if the card ever fails after a cold power-on, use Restart (see README).' }
} catch { Write-Host "ERROR: $_" -ForegroundColor Red; $fail++ }
Write-Host ''
if ($fail -eq 0) { Write-Host 'RESULT: everything OK' -ForegroundColor Green; exit 0 } else { Write-Host "RESULT: $fail check(s) failed - see README troubleshooting" -ForegroundColor Red; exit 1 }
