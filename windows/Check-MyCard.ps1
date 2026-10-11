<#
.SYNOPSIS
  "Is my Mellanox ConnectX-3 affected?"  READ-ONLY - changes nothing. Works without Linux and without extra tools.

.DESCRIPTION
  Uses what Windows itself knows:
    - the PCIe Max Payload Size (MPS) Windows recorded for the card and for every other PCIe device,
    - the card's status (Code 43?) and the mlx4_bus events (MAP_FA -5 failures vs. successful starts),
    - whether the fix from this repository is installed and ran at this boot (needs administrator).
  Windows does not show the root port's own MPS, but all other devices behind the same BIOS reveal what the BIOS
  uses. A card at 128 B while the rest of the system is at 256 B is exactly this bug.
#>
param([int]$Days = 90, [int]$TestCardMps = -1)   # -TestCardMps: only for testing the verdict texts
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MpsFix.Common.ps1')
$MpsB = @{ 0 = 128; 1 = 256; 2 = 512; 3 = 1024; 4 = 2048; 5 = 4096 }
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }

Say ''
Say '=== Is my Mellanox ConnectX-3 affected by the PCIe Max Payload Size bug?  (read-only) ===' 'Cyan'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$cards = @(Get-MellanoxCards)
if ($cards.Count -eq 0) { Say 'No Mellanox (vendor 15B3) PCIe network card found in this PC.' 'Yellow'; exit 3 }

# MPS of all other PCIe devices = what this BIOS normally uses
$others = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\*' -and $_.InstanceId -notlike 'PCI\VEN_15B3*' } | ForEach-Object {
    $v = Get-PnpProp $_.InstanceId 'DEVPKEY_PciDevice_CurrentPayloadSize'
    if ($null -ne $v) { [pscustomobject]@{ Name = $_.FriendlyName; Mps = [int]$v } } })
$sys = if ($others.Count) { ($others | Group-Object Mps | Sort-Object Count -Descending | Select-Object -First 1).Name -as [int] } else { $null }

$exit = 0
foreach ($card in $cards) {
    $id = $card.InstanceId
    $loc = Get-PciLocation $id
    $cur = Get-PnpProp $id 'DEVPKEY_PciDevice_CurrentPayloadSize'; $max = Get-PnpProp $id 'DEVPKEY_PciDevice_MaxPayloadSize'
    if ($TestCardMps -ge 0) { $cur = $TestCardMps; Say "(TEST MODE: pretending the card MPS is $($MpsB[$TestCardMps]) B)" 'Magenta' }
    $prob = Get-PnpProp $id 'DEVPKEY_Device_ProblemCode'; $drv = Get-PnpProp $id 'DEVPKEY_Device_DriverVersion'
    Say ''
    Say "Card        : $($card.FriendlyName)  (PCI $($loc.Text))" 'White'
    Say ("Status      : {0}{1}   driver {2}" -f $card.Status, $(if ($prob) { "  - Code $prob" } else { '' }), $drv)
    try { $rp = Get-RootPortOf $id; Say "Root port   : $((Get-PnpDevice -InstanceId $rp).FriendlyName)  (PCI $((Get-PciLocation $rp).Text))" }
    catch { Say "Root port   : $_" 'Yellow' }

    if ($null -ne $cur) { Say ("Card MPS    : {0} B   (card supports up to {1} B)" -f $MpsB[[int]$cur], $MpsB[[int]$max]) }
    else { Say 'Card MPS    : not reported by Windows' 'Yellow' }
    if ($null -ne $sys) {
        Say ("Other PCIe devices: {0} B  ({1})" -f $MpsB[$sys], ((@($others | Where-Object Mps -eq $sys | Select-Object -ExpandProperty Name -First 4) -join ', ')))
    }

    $since = (Get-Date).AddDays(-$Days)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'mlx4_bus'; Id = 6, 7, 73; StartTime = $since } -ErrorAction SilentlyContinue)
    $nOk = @($ev | Where-Object Id -eq 6).Count; $nMapFa = @($ev | Where-Object Id -eq 7).Count; $nFail = @($ev | Where-Object Id -eq 73).Count
    Say ("Driver log  : last {0} days: {1}x started OK, {2}x failed ({3}x 'MAP_FA ... error -5')" -f $Days, $nOk, $nFail, $nMapFa)
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $ifm = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'mlx4eth63'; Id = 34; StartTime = $bootTime } -ErrorAction SilentlyContinue).Count
    if ($ifm) { Say 'Note        : Ethernet ports report "interface mismatch between ETH driver and bus driver" - bus and ETH driver come from different packages (README 7.1).' 'Yellow' }

    $fixRan = $false; $fixInstalled = $false
    if ($isAdmin) {
        try {
            Enable-FirmwareAccess
            $fe = @(@(Find-FixBootEntries) + @(Get-BootEntries | Where-Object { $_.FilePath -like '*\shellx64.efi' -and $_.Description -like '*MPS fix*' }) | Sort-Object Name -Unique)
            if ($fe.Count) { $fixInstalled = $true; $fixRan = ($fe | Where-Object { $_.Id -eq (Get-BootCurrent) }) -ne $null
                Say ("Fix         : installed ({0}){1}" -f (($fe | ForEach-Object { "$($_.Name) '$($_.Description)'" }) -join ', '), $(if ($fixRan) { ' - and THIS boot went through it' } else { ' - but this boot did NOT go through it' })) }
            else { Say 'Fix         : not installed' }
        } catch { Say "Fix         : could not check ($_)" 'Yellow' }
    } else { Say 'Fix         : (run as administrator to check whether the fix is installed)' 'DarkGray' }

    # ---------------- verdict ----------------
    $working = ($card.Status -eq 'OK') -and -not $prob
    $mismatch = ($null -ne $cur) -and ($null -ne $sys) -and ([int]$cur -lt $sys)
    Say ''
    if ($fixRan -and $working) {
        Say 'VERDICT: FIX ACTIVE AND WORKING - the card was set to the right MPS before Windows started and it initialized.' 'Green'
        Say '         Detailed check: 3-TEST.cmd'
    } elseif ($mismatch -and ($nMapFa -gt 0 -or -not $working)) {
        Say ("VERDICT: AFFECTED (very likely). The card runs with MPS {0} B while the rest of your PCIe devices use {1} B," -f $MpsB[[int]$cur], $MpsB[$sys]) 'Red'
        Say '         and the driver fails with MAP_FA error -5. That is exactly this BIOS bug. -> Use 2-FIX.cmd' 'Red'
        $exit = 1
    } elseif ($mismatch) {
        Say ("VERDICT: LIKELY AFFECTED. The card runs with MPS {0} B while the rest of your PCIe devices use {1} B." -f $MpsB[[int]$cur], $MpsB[$sys]) 'Yellow'
        Say '         The driver has not failed yet (not installed / not started?). Install the driver and check again.' 'Yellow'
        $exit = 1
    } elseif ($working -and $nMapFa -gt 0) {
        Say 'VERDICT: WORKS ON THIS BOOT, BUT FAILED BEFORE. MAP_FA -5 failures were logged, while on this boot the MPS is fine.' 'Yellow'
        Say '         That is typical for this bug ("lucky" boots). Run this check again on a boot where the card fails (Code 43).' 'Yellow'
        if (-not $isAdmin) { Say '         (If the fix is already installed, run this as administrator - then it can confirm the fix.)' 'Yellow' }
        $exit = 1
    } elseif (-not $working -and $nMapFa -gt 0) {
        Say 'VERDICT: DRIVER FAILS, BUT NO MPS MISMATCH VISIBLE. Probably a different problem - see README section 3 (Linux check).' 'Yellow'
        $exit = 2
    } elseif ($working) {
        Say 'VERDICT: NOT AFFECTED - the card works and its MPS matches the rest of the system.' 'Green'
    } else {
        Say 'VERDICT: UNCLEAR - the card does not work, but there are no MAP_FA errors. Not this bug (check the driver installation).' 'Yellow'
        $exit = 2
    }
}
Say ''
Say 'Optional 100% confirmation: boot an Ubuntu live USB and run   sudo dmesg | grep -i "max payload"   (README section 3C).' 'DarkGray'
exit $exit
