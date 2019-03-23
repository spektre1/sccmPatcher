<#
    This script is to reset the CIList CIs.
#>
Param (
    [switch]$revert
)

# Load settings
Set-Location 'C:\Data\Patching'
$VerbosePreference = 'Continue'
. .\Dev.ps1
. Reset-DevEnv
$SnapshotName = 'SCCMPatcherTesting'

$VMs = @()
$Settings.CIList | ForEach {
    $VMs += [regex]::match($_,'^[0-9\-a-z]+').Value
}
$Hostnames = @()
$Settings.CIList | ForEach {
    $Hostnames += $_
}

# VM Snapshot refresh
if ($status) {
    $s = New-PSSession -ComputerName $hostnames -Credential $Credential
    $r = Invoke-Command -Session $s { $SCCM = Get-WMIobject -Query "SELECT * FROM CCM_SoftwareUpdate" -Namespace "ROOT\ccm\ClientSDK"; $SCCM.count }
    Remove-PSSession $s
    $r | Group-Object
    Exit 0
}

if ( (Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ) {
    Add-PsSnapin VMware.VimAutomation.Core
    Write-Verbose 'Loading VMware modules...'
}
# Ignore bad SSL certs.
Set-PowerCLIConfiguration -InvalidCertificateAction ignore -confirm:$false | Out-Null
Connect-VIServer -Server 10.164.192.232 -Credential $credential | Out-Null

# Confirm they're all shutdown before continuing.
$timerDuration = 5
$Waited = 0

Write-Verbose "Shutting down VMs."
Stop-VM $VMs -confirm:$false
Write-Verbose "Waiting 30 seconds for shutdown..."
Start-Sleep 30
While ( ((Get-VM -Name $VMs | Where-Object { $_.PowerState -eq 'PoweredOn' }) | Measure-Object).count -gt 0 ) {
    Write-Output "Still $StillOn VMs. Waited ${Waited}s for VMs to power down..."
    $timerDuration = Get-Random -Minimum 6 -Maximum 12
    $Waited += $timerDuration
    if ($waited -gt 120) {Break}
    Start-Sleep $timerDuration
}
Write-Verbose "All shut down."

# Check snapshots
$snapshots = Get-VM -Name $VMs | Get-Snapshot -name $SnapshotName -ErrorAction SilentlyContinue
# Remove old snapshosts if exist
if (($snapshots | Measure-Object).count -gt 0) {
    if ($revert) {
        Write-Verbose "Snapshots exist. Reverting VMs to snapshot."
        forEach ($snapshot in $snapshots) {
            Set-VM -runAsync -VM ($snapshot.vm) -Snapshot $snapshot -confirm:$false | Out-Null
        }
        Write-Verbose "Waiting 30 secs to ensure revert..."
        Start-Sleep 30
    }
    Write-Verbose "Removing snapshots."
    $snapshots | Remove-Snapshot -RunAsync -Confirm:$false | Out-Null
}

Write-Verbose "Generating new Snapshots."
Get-VM -Name $VMs | New-Snapshot -Name $SnapshotName -Memory:$false -Quiesce:$true -RunAsync | Out-Null

Write-Verbose "Starting VMs."
Get-VM -Name $VMs | Start-VM | Out-Null
