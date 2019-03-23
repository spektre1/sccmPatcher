# Danielle MacDonald
# Patcher Object Generator
function New-Patcher() {
    <#
    .SYNOPSIS
    Patcher Object Generator.
    
    .DESCRIPTION
    This is initialized on the CI, where it collects relevant data.
    
    .EXAMPLE
    $patcher = New-Patcher
    $patcher.Initialize()
    
    .NOTES
    General notes
    #>
    $TypeName = 'Patcher.SCCM'
    $Properties = @{
        'PSTypeName' = 'Patcher.SCCM'
        'DisplayName'= 'Patcher for Windows SCCM'
        'Hostname'   = $env:computername
        'Domain'     = $env:userdnsdomain
        'Username'   = $env:UserName
        'UserDomain' = $env:UserDomain
        'OSVersion'  = [String]([environment]::OSVersion.Version)
        'PSVersion'  = [String]$PSVersionTable.PSVersion
        'sysDrive'   = $null
        'freeSpace'  = 0
        'startTime'  = Get-Date
        'lastBoot'   = $null
        'lastPatchScan' = $null
        'patchList'  = $null
        'patchCount' = 0
        'remaining'  = 0
        'verifying'  = 0
        'rebootRequired' = $false
        'currentlyPatching' = $false
        'hotFixList' = $null
        'log'        = $null
        'lastLog'    = $null
        'MSCluster'  = $null
        'eState' = @{
            "0"  = "None"
            "1"  = "Available"
            "2"  = "Submitted"
            "3"  = "Detecting"
            "4"  = "PreDownload"
            "5"  = "Downloading"
            "6"  = "Wait-Install"
            "7"  = "Installing"
            "8"  = "Pending-Soft-Reboot"
            "9"  = "Pending-Hard-Reboot"
            "10" = "Wait-Reboot"
            "11" = "Verifying"
            "12" = "Install-Complete"
            "13" = "Error"
            "14" = "Wait-Service-Window"
            "15" = "Wait-User-Logon"
            "16" = "Wait-User-Logoff"
            "17" = "Wait-Job-User-Logon"
            "18" = "Wait-User-Reconnect"
            "19" = "Pending-User-Logoff"
            "20" = "Pending-Update"
            "21" = "Waiting-Retry"
            "22" = "Wait-Pres-ModeOff"
            "23" = "Wait-For-Orchestration"
        }
    }

    $Patcher = New-Object PSObject -Property $Properties

    # == .Initialize() ==
    $sb = {
        $this.WriteLog("Checking for CcmExec Service")
        #Make sure this is running first, can't do much without it...
        $service = Get-Service CcmExec -ErrorAction SilentlyContinue
        if ($service -eq $null) {
            $this.WriteLog("CcmExec Service not available. HALTING.")
        } ElseIf ( $service.Status -ne 'Running' ) {
            $this.WriteLog("CcmExec Service is stopped, trying wait...")
            Start-Sleep 60 #Try waiting first...
            if ((Get-Service CcmExec).status -ne 'Running') {
                $this.WriteLog("CcmExec Service is still stopped, starting...")
                Start-Service CcmExec
                Start-Sleep 10
            }
        }
        # TODO we should check again before continuing

        # Determine is this is a MS Cluster that needs to observe dependencies
        $this.WriteLog("Checking for Cluster")
        $service = Get-Service ClusSvc -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            $this.MSCluster = $false
        } Else {
            $this.MSCluster = $true
        }

        # $r = $this.CheckReboot()
        # $r = $this.CheckPolicy()
        $r = $this.CheckPatchScan()
        $r = $this.GetPatchList()
        $r = $this.CheckRunning()
        # Finish filling in metrics
        $this.SysDrive = (Get-WMIObject -Class Win32_OperatingSystem).SystemDrive
        $this.FreeSpace = [Math]::Round(((Get-WmiObject -Class Win32_LogicalDisk `
            -Filter "DeviceID='$($this.SysDrive)'").FreeSpace/1gb), 1)
        $this.LastBoot = [System.Management.ManagementDateTimeConverter]::ToDateTime((Get-WmiObject -Class Win32_OperatingSystem).LastBootUpTime)
        return
    }
    $Patcher | Add-Member -Name 'Initialize' -MemberType ScriptMethod -Value $sb -Force

    # == .WriteLog() ==
    $sb = {
        # Designed to store logs instead of writing directly to disk.
        Param (
            [parameter(Mandatory=$true, Position=0)]
            [String]$text
        )
        $ts = (Get-Date).ToUniversalTime().toString('yyyy-MM-dd HH:mm:ss.fff')
        $text = "$ts - " + $text + "`n"
        $this.log += $text
        $this.lastLog = Get-Date
        Write-Verbose $text
    }
    $Patcher | Add-Member -Name 'WriteLog' -MemberType ScriptMethod -Value $sb -Force


    # == .getLog() ==
    $sb = {
        $log = $this.log
        $this.log = $null
        return $log
    }
    $Patcher | Add-Member -Name 'getLog' -MemberType ScriptMethod -Value $sb -Force


    # == .CheckPolicy() ==
    $sb = {
        $s = '{00000000-0000-0000-0000-000000000021}'
        Invoke-WmiMethod -Namespace 'ROOT\ccm' -Class SMS_Client `
            -Name TriggerSchedule -ArgumentList $S
        return
    }
    $Patcher | Add-Member -Name 'CheckPolicy' -MemberType ScriptMethod -Value $sb -Force
    

    # == .CheckPatchScan() ==
    $sb = {
        # Get last Windows Update check time
        $this.WriteLog("Getting last patch scan time")
        $status = Get-WmiObject -query "SELECT * FROM CCM_UpdateStatus" -namespace `
        "root\ccm\SoftwareUpdates\UpdatesStore" -ErrorAction SilentlyContinue
        if ( $error.exception -like '*Access denied*' ) {
            $this.WriteLog($error.exception)
            $this.LastPatchScan = $null
        } else {
            $status | ForEach-Object {
                if($_.ScanTime -gt $ScanTime) { $ScanTime = $_.ScanTime  } 
            }
            $ScanTime = $ScanTime -as [DateTime]
            if ($ScanTime) { $this.LastPatchScan = $ScanTime }
        }
        return
    }
    $Patcher | Add-Member -Name 'CheckPatchScan' -MemberType ScriptMethod -Value $sb -Force


    # == .GetPatchList() ==
    $sb = {
        $this.WriteLog("Getting patch list")
        $this.PatchList = Get-WmiObject `
            -Query "SELECT * FROM CCM_SoftwareUpdate" `
            -Namespace "ROOT\ccm\ClientSDK"
        if ($this.PatchList -eq $null) {
            $this.WriteLog("Can't find any patches!")
            $this.PatchCount = 0
            return
        }
        if ($this.PatchList.count -lt 1) {
            $this.PatchCount = 0
        } else {
            $this.PatchCount = $this.PatchList.count
        }
        $this.remaining = @( $this.PatchList | Where-Object {$_.EvaluationState -lt 8}).count
        $this.verifying = @( $this.PatchList | Where-Object {$_.EvaluationState -eq 11}).count
        return
    }
    $Patcher | Add-Member -Name 'GetPatchList' -MemberType ScriptMethod -Value $sb -Force

    # == .CheckRunning() ==
    $sb = {
        if ( @( $this.PatchList |
            where {
                $_.EvaluationState -eq 2 -or
                $_.EvaluationState -eq 3 -or
                $_.EvaluationState -eq 4 -or
                $_.EvaluationState -eq 5 -or
                $_.EvaluationState -eq 6 -or
                $_.EvaluationState -eq 7 -or
                $_.EvaluationState -eq 11
            }
        ).length -ne 0) {
            $this.CurrentlyPatching = $true
        } else {
            $this.CurrentlyPatching = $false
        }
        $this.GetPatchList()
        return $this.CurrentlyPatching
    }
    $Patcher | Add-Member -Name 'CheckRunning' -MemberType ScriptMethod -Value $sb -Force


    # == .CheckReboot() ==
    $sb = {
        #Let's check for reboots while we're updating the patchlist
        $this.WriteLog("Checking for reboots")
        $r = Invoke-WmiMethod -Namespace ROOT\ccm\ClientSDK `
            -Class CCM_ClientUtilities -Name DetermineIfRebootPending
        $reboot = $this.rebootRequired
        $reboot = $reboot -or $r.RebootPending
        $reboot = $reboot -or $r.IsHardRebootPending
        if ( $reboot -eq $FALSE ) {
            if ( @($this.PatchList |
                Where-Object {
                    $_.EvaluationState -eq 8 -or
                    $_.EvaluationState -eq 9 -or
                    $_.EvaluationState -eq 10
                }).length -ne 0)
            { $reboot = $true }
        }
        $this.rebootRequired = $reboot
        return $reboot
    }
    $Patcher | Add-Member -Name 'CheckReboot' -MemberType ScriptMethod -Value $sb -Force


    # == .DownloadUpdates() ==
    $sb = {
        if( ((Get-Date) - $this.LastPatchScan).Hours -ge 2 )
        {
            $this.WriteLog("Forcing download of updates. Waiting 60 seconds...")
            $s = '{00000000-0000-0000-0000-000000000113}'
            Invoke-WmiMethod -Namespace 'ROOT\ccm' -Class SMS_Client `
                -Name TriggerSchedule -ArgumentList $S
            # ([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000113}') 
            Start-Sleep 60
        }
    }
    $Patcher | Add-Member -Name 'DownloadUpdates' -MemberType ScriptMethod -Value $sb -Force


    # == .StartPatching() ==
    $sb = {
        $this.startTime = Get-Date
        $PatchListFormatted = @($This.PatchList |
            ForEach-Object {
                if($_.ComplianceState -eq 0) { [WMI]$_.__PATH }
            }
        )
        # ++ START THE PATCH PROCESS! ++
        if ( $this.CurrentlyPatching -eq $false ) {
            $this.WriteLog("Starting Patching Process...")
            Invoke-WMIMethod -Namespace ROOT\ccm\ClientSDK -Class CCM_SoftwareUpdatesManager -Name InstallUpdates `
                -ArgumentList (,$PatchListFormatted) | Out-Null
            $this.CurrentlyPatching = $true
        } else {
            $this.WriteLog("Tried to start patching but it's already running?")
        }
    }
    $Patcher | Add-Member -Name 'StartPatching' -MemberType ScriptMethod -Value $sb -Force


    # == .getDebugLogs() ==
    $sb = {
        $CCMLogFilesRoot = "C:\\Windows\\CCM\\Logs\\"
        $CCMlogFiles = @(
            "WUAHandler.log",
            "UpdatesHandler.log",
            "UpdatesDeployment.log"
        )
        $LogTime = ($logsBack | Get-Date).toString('yyyy-MM-dd HH:mm:ss.fffK')
        $CCMLogs = "`n== Collecting Pre-Update CCMLogs for context. ==`n"
        $CCMLogs += "Collecting everything after $logTime to now.`n"
        $CCMLogs += Get-CCMLogs ..\temp\$this.CIName\
        $CCMLogFiles | ForEach-Object {
            Copy-Item ipsTmp:$CCMLogFilesRoot\$_ ..\temp\
        }

        $CCMLogs = "`n== Collecting Post-Update CCMLogs ==`n"
        $CCMLogs += "Collecting everything after Patch Start Time: $($this.StartTime).`n"
        $CCMLogs += Get-CCMLogs ..\temp\ ([math]::Round((New-Timespan -Start $this.StartTime).TotalHours, 1))
        $this.WriteLog( $CCMLogs )

        # Get-Hotfix and compare
        $hotFixes = Get-Hotfix
        $this.HotFixList = $hotFixes | Where-Object { $_.InstalledOn -gt $this.StartTime }
    }
    $Patcher | Add-Member -Name 'GetDebugLogs' -MemberType ScriptMethod -Value $sb -Force

    # == .CheckPatchFail() ==
    # Only look for failures of patches from this patch event
    # Old or other failures will not be returned
    $sb = {
        $rexPatchAttempt = ($this.Patchlist | ForEach-Object {$_.ArticleID}) -join "|"
        $notComply = Get-WmiObject -Query "SELECT * FROM CCM_SoftwareUpdate WHERE ComplianceState <> 1" -Namespace "ROOT\ccm\ClientSDK"
        $failed = @($notComply | Where-Object {$_.ArticleID -match $rexPatchAttempt} | ForEach-Object {$_.ArticleID})
        return $failed 
    }
    $Patcher | Add-Member -Name 'CheckPatchFail' -MemberType ScriptMethod -Value $sb -Force

    # == .ClusterPause() ==
    $sb = {
        $sleep     = 60 # seconds
        $drainMax  = 20 # minutes
        $drainLoop = 0
        $nodeCount = -1
    
        import-module failoverClusters
        
        # Remove the 3rd stanza of OSversion so we can use greater/less than
        $this.OSVersion -match "(\d+\.\d+)\.\d+" | out-null
    #    (gwmi win32_operatingsystem).version -match "(\d+\.\d+)\.\d+" | out-null
        $osVer = $matches[1]
        
        # Save current group state to do compare after drain
        $beforeDetails = get-clustergroup | where {$_.state -eq "Online"}
        $beforeCount = ($beforeDetails | measure-object).count
    
        # Less than 2012 R1 needs extra steps to drain before suspend
        if ($osVer -lt 6.2) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $out = Suspend-ClusterNode -Name $this.HostName | out-string
            $this.WriteLog($out)
            # Move the non Virtual resources
            $out = get-ClusterNode $this.HostName | get-ClusterGroup | where { $_ | Get-ClusterResource | where { $_.ResourceType -notmatch "Virtual" } } | Move-ClusterGroup -wait 0  | out-string
            $this.WriteLog($out)
            # Get-ClusterResource produces NULL against "Available storage"
            # get-clustergroup | where {$_.name -eq "Available Storage" -and $_.ownerNode.toString() -eq $this.HostName} | Move-ClusterGroup -wait 0
            $out = get-ClusterNode $this.HostName | get-ClusterGroup | where { $_.name -eq "Available Storage" } | Move-ClusterGroup -wait 0  | out-string
            $this.WriteLog($out)
    
            # With 2008 R2, Get-ClusterGroup does produce NOT GroupType property. Must also call Get-ClusterResources and look at ResourceType
            # get-ClusterNode $this.HostName | get-ClusterGroup | where { $_.GroupType -eq "VirtualMachine" } | Move-ClusterVirtualMachineRole -wait 0
            # get-ClusterNode $this.HostName | get-ClusterGroup | where { $_.GroupType -ne "VirtualMachine" } | Move-ClusterGroup -wait 0
            # Move-ClusterVirtualMachineRole requires you to specify the TARGET NODE
            # Move-ClusterGroup picks a TARGET NODE for you
            $xNode = 0 # migrate the vms to the nodes in a round robin
            $vm = 0
            $nodeList = get-ClusterNode | where { $_.state -eq "Up" -and $_.name -ne $this.HostName}
            $vmList = @() # Need to insure this is ALWAYS a collection. If host is running a single VM, get-ClusterGroup does not return collection
            $vmList += get-ClusterNode $this.HostName | get-ClusterGroup | where {$_.state -eq "Online"} | where { $_ | Get-ClusterResource | where { $_.ResourceType -match "Virtual" } }
            if ($vmList[0].name) {
                while ($timer.elapsed.totalminutes -lt $drainMax -AND $vm -lt $vmList.count) {
                    $this.WriteLog("Moving " + ($vmList[$vm]).name )
                    $out = $vmList[$vm] | Move-ClusterVirtualMachineRole -node $nodeList[$xNode].name
                    $this.WriteLog($out)
                    $xNode++
                    $vm++
                    if ($xNode -eq ($nodeList | measure-object).count ) { $xNode = 0 }
                }
            }
            if ($timer.elapsed.totalminutes -gt $drainMax -AND ($vm+1) -lt $vmList.count) {
                $moved = $vm+1
                $total = $vmList.count
                $this.WriteLog("Error - Drain timeout - Moved $moved of $total VMs")
                return $false
            }
        } else {
            $out = Suspend-ClusterNode -Name $this.HostName -Drain | out-string
            $this.WriteLog($out)
        }
        
        # Wait for resources to move
        while ($timer.elapsed.totalminutes -lt $drainMax -AND $nodeCount -ne 0) {
            $this.WriteLog("Waiting for drain, $nodeCount to go")
            $drainLoop++
            start-sleep -seconds $sleep
            $nodeCount = (get-ClusterNode $this.HostName | get-clustergroup | where { $_.state -ne "Offline" } | measure-object).count
        }
    
        # Verify drain completed
        if ($nodeCount -ne 0) {
            $this.WriteLog("Error - Drain did not complete in the allowed time")
            return $false
        }
        
        # Verify before/after counts
        $afterDetails = get-clustergroup | where {$_.state -eq "Online" -AND $_.ownerNode.toString() -ne $this.HostName } 
        $afterCount = ($afterDetails | measure-object).count
        if ($timer.elapsed.totalminutes -gt $drainMax) { $timeout = $true } else { $timeout = $false }
        if ($afterCount -ne $beforeCount) {
            $offline = (compare-object $beforeDetails.name $afterDetails.name).inputobject -join ", "
            $this.WriteLog("Error - Drain Timeout: $timeout - Offline or did not move: $offline")
            return $false
        } else {
            $nodeState = (get-clusterNode -name $this.HostName).state
            if ($nodeState -eq "Paused") {
                return $true
            } else {
                $this.WriteLog("Drain completed, but node is not paused, instead it is: $nodeState")
                return $false
            }
        }
    }
    $Patcher | Add-Member -Name 'ClusterPause' -MemberType ScriptMethod -Value $sb -Force


    # == .ClusterResume() ==
    $sb = {
        # Resume the node, and if it is NOT a HyperV cluster, move the resources back to the preferred node
        $sleep     = 60 # seconds
        $drainMax  = 20 # minutes
        $drainLoop = 0
        $afterCount = -1
    
        import-module failoverClusters
        $out = Resume-ClusterNode $this.HostName | out-string
        $this.WriteLog($out)
        if ( (get-clusternode $this.HostName).state -ne "Up" ) {
            $this.WriteLog("Error resuming the node: " + $error[0].exception.message)
            return $false
        }
    
        # If this is not Hyper cluster, and this is the preferred node, move resources back
        $prefer = (get-clusternode)[0].name
        # With 2008 R2, Get-ClusterGroup does NOT produce GroupType property. Must also call Get-ClusterResources and look at ResourceType
        # if ( (get-ClusterGroup).groupType -notcontains "VirtualMachine" -AND $this.HostName -eq $prefer ) {
        $vmList = Get-ClusterGroup | where { $_ | Get-ClusterResource | where { $_.ResourceType -match "Virtual" } }
        if ($vmList -eq $null -AND $this.HostName -eq $prefer) {
            $beforeDetails = get-clustergroup | where {$_.state -eq "Online"}
            $beforeCount = ($beforeDetails | measure-object).count
            $out = $beforeDetails | Move-ClusterGroup -node $this.HostName -wait 0 | out-string
            $this.WriteLog($out)
    
            # Wait for resources to move
            while (($drainLoop -lt $drainMax) -AND ($afterCount -ne $beforeCount)) {
                $this.WriteLog("Waiting...")
                start-sleep -sec $sleep
                $drainLoop++
                $afterDetails = get-clustergroup | where { $_.ownerNode.toString() -eq $this.HostName -AND $_.state -eq "Online"}
                $afterCount = ($afterDetails | measure-object).count
            }
    
            #  Verify online resources are the same as before the move
            if ($drainLoop -eq $drainMax) { $timeout = $true } else { $timeout = $false }
            if ($afterCount -ne $beforeCount ) {
                $offline = (compare-object $beforeDetails.name $afterDetails.name).inputobject -join ", "
                $this.WriteLog("Error - Online before/after not equal $beforeCount/$afterCount - Drain Timeout: $timeout - No longer online: $offline")
                return $false
            } else {
                $this.WriteLog("Good failback before/after $beforeCount/$afterCount")
                return $true
            }
        } else {
            $this.WriteLog("No Failback scenario -  HyperV cluster, or non preferred node of SQL cluster")
            return $true
        }
    }
    $Patcher | Add-Member -Name 'ClusterResume' -MemberType ScriptMethod -Value $sb -Force
    
    $patcher.Initialize()
    return $Patcher
}