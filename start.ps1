<#
.Synopsis
    Update controller.
.Description
    This script starts the windows SCCM patching process.
.Parameter  <Parameter-Name>
.Example
.Inputs
    $CIs = CI Hostname or IP address
    $SettingsFile
.Notes
    Author: Danielle.MacDonald.a@gmail.com
    Created: 2017-09-19
    Patcher can be in states: Initialized WaitForDependency Connected Patching Rebooting Complete
#>

# Parameter sets: http://codepyre.com/2012/08/ad-hoc-polymorphism-in-powershell/
Param(
    [Parameter(Mandatory=$True, ParameterSetName='CI')]
    [ValidateNotNullOrEmpty()]     [Array]$CIs,
    [Parameter(Mandatory=$True, ParameterSetName='RFC')]
    [ValidateNotNullOrEmpty()]     [String]$RFC,
    [Parameter(Mandatory=$false)]  [Int] $MaxThreads = 40,
    [Parameter(Mandatory=$false)]  [PSCredential]$Credential,
    [Switch] $TestConnection,
    [Switch] $DisableLogging,
    [Switch] $InstallUpdates
)

#       --== Dev Options ==--
#$MaxMemoryPerShell = 20     # In MB, system-wide limit override per shell
#$maxProcesses = 50   #This is the WinRM system-wide limit override
#This is how many threads this app will use
$StartTime = Get-Date
$ConnTestTimeout = 15 #Minutes
$PatchTimeout = 100 #Minutes
$logDir = $null

#Check to see what system functions already exist, need this to difference loaded funcs
$sysFunctions = Get-ChildItem function:
$host.ui.RawUI.WindowTitle = "SCCM Patcher - CI Controller - " + (hostname)

#       --==  Import Functions, Objects ==--
#
# === Platform specifics for paths ===
If ($PSVersionTable.platform -like 'Unix' ) {
    $unixPlatform = $true
    Set-Location '/mnt/data/home/sync/projects/powershell/winpatching'
} ElseIf (!$PSVersionTable.platform) {
    $unixPlatform = $false
    Set-Location 'C:\Data\patching'
} else {
    Write-Debug "Not sure what platform this is."
}
# === load functions and libs ===
. .\dev.ps1
$libDir = 'lib'
$libFiles = Get-ChildItem -exclude '*.tests.ps1' ($libDir + '\*.ps1')
$libFiles | ForEach-Object {
    If ($unixPlatform) {
        $libFile = './' + $libDir + '/' + $_.Name
    } else {
        $libFile = '.\' + $libDir + '\' + $_.Name
    }
    Write-Debug "Importing $libFile"
    . $libFile
}

#       --==  Arguments/Settings Handling ==--
#
$settings = Import-Settings
if ($RFC) {
    if ($TestConnection) { $suffix = ".ctest" }
    elseif ($InstallUpdates) { $suffix = ".patch" }
    else { $suffix = "" }
    $logDir = "..\patchlog\${RFC}${suffix}"
    Set-Log $logDir
} else {
    Set-Log
}

Write-Log 'INFO' "Starting SCCM Master Patch Controller."
# Set Mem/Process Limits
# If (!$unixPlatform) { Set-ThreadingConfig $MaxMemoryPerShell $maxProcesses }


#       --== Parameter Testing ==--
# Most of this is about deciding what mode we're running in, and what set of CIs
# and credentials to use.
If ($TestConnection -and $InstallUpdates) {
    Write-Log 'ERROR' 'Cannot do both -TestConnection and -InstallUpdates. Use only one.'
    return 1
} 
if (!($TestConnection -or $InstallUpdates)) {
    Write-Log 'ERROR' 'This script must be invoked with either -TestConnection and -InstallUpdates.'
    return 1
}

switch ($PSCmdlet.ParameterSetName) { 
    'CI'  {
        Write-Log 'DEBUG' "Using CI array from CLI."
        # --== CI Testing ==--
        $domains = @()
        $cis | ForEach-Object {
            #Test that CIs look like CINames/FQDN
            if ($ci -match '^(\w*)\.([\w\.]*)') {
                if ($Domains -notcontains $matches[2]) {
                    $Domains += $matches[2]
                }
            } else { Write-Log 'ERROR' "'$ci' is not a valid FQDN."; return 1 }
        }
        #TODO: Don't think I actually need these.
        # ! $Domains and $DomainUsernames can be used to decide which credentials to construct
        break
    }
    'RFC' {
        # TODO validate the RFC's all match and throw an error (make it easier to debug issues)
        # Test file exists, etc
        # why does this not work - $controllerCIPath is defined ins settings.json
        #$RFCFilename = $controllerCIPath + '\' + $RFC + ".txt"
        $RFCFilename = 'C:\Data\CIs\' + $RFC + ".txt"
        Write-Log 'DEBUG' "Loading RFC file: $RFCFilename."
        if (test-path $RFCFilename) {
            $file = Get-Content (Resolve-Path $RFCFilename).Path
            $CIsByCreds = ("$file" | ConvertFrom-Json).$RFC
            $CIs = $CIsByCreds.ci
            $CredCounts = ($CIsByCreds.cred | Group-Object -NoElement)
            #$DomainUsernames = $CredCounts.Name
        } else {
            Write-Log 'ERROR' "Can't find specified RFC file - aborting!"
            exit
        }
        break
    }
    default {
        Write-Log 'DEBUG' "Problem detecting parameter set! Shouldn't default..."
    }
}
$ciCount = $CIs.count



#       --==  CI Control (Downtime, Updates) ==--

$text =  @"
Logging to $SCCMMasterLogFile
Process ID: $pid
Cur Working Dir: $pwd
Credentials in use: $($credCounts | Out-String)

"@

if ($TestConnection) {$text += "Connection Test on the following CIs.`n"}
if ($InstallUpdates) {$text += "Patching the following CIs.`n"}
<#
$text += @"

== CIList ==

"@
$text += $cis -join "`n"
#>
Write-Log 'INFO' $text


# List all my custom functions we just loaded
$myFunctions = Get-ChildItem function: | Where-Object {$sysfunctions -notcontains $_}

# Let's pass these just to make the API updates at the end easy.
$myVariables = @( $settings, '' )
$RunspacePool = New-RunspacePool -maxThreads $maxThreads `
    -functions $myFunctions -variables $myVariables

    Write-Log 'INFO' "Starting threads..."


#       --== Thread Scripts ==--
#
# Scriptblocks we're passing to the threads.
# Note that the $myFunctions and $myVariables array contents
# are loaded into these blocks.
$PatchJobSB = {
    Param( 
        $CI,
        $CMDB,
        [PSCredential]$Credential,
        $Status,
        $logDir,
        $startTime
    )
    Set-Location 'C:\Data\Patching'
    if ($logDir) {
        $CIHandler = New-CIHandler -CIName $CI `
            -Credential $Credential `
            -StartTime $startTime `
            -CMDB $CMDB `
            -logDir $logDir
    } else {
        $CIHandler = New-CIHandler -CIName $CI `
            -Credential $Credential `
            -StartTime $startTime `
            -CMDB $CMDB
    }
    Manage-Patching $CIHandler $Status
    $CIHandler | Select-Object CIName, State, Error, StartTime, ElapsedTime, EndTime, PatchesInstalled
}

# Connection Test
$ConnTestJobSB = {
    Param(
        $CI,
        $CMDB,
        [PSCredential]$Credential,
        $Status,
        $logDir
    )
    Set-Location 'C:\Data\Patching'
    $CIStatus = New-Object -TypeName PSObject -Prop (@{
        'CIName' = $CI
        'State' ='Unknown'
        'Details' = ''
        'Timestamp' = (Get-Date)
        'PatchesAvail' = $null
        'Username' = $Credential.username
        'Uptime' = $null
    })
    $CIStatus.PSObject.TypeNames.Insert(0,'Patcher.SCCM.Status')

    if ($logDir) {
        $CIHandler = New-CIHandler -CIName $CI `
            -Credential $Credential `
            -CMDB $CMDB `
            -logDir "$logDir\"
    } else {
        $CIHandler = New-CIHandler -CIName $CI `
            -Credential $Credential `
            -CMDB $CMDB
    }
    $CIHandler.ConnectToCI($true)
    $CIHandler.final()
    $CIStatus.State = $CIHandler.state
    if ($CIHandler.Patcher.patchCount -is [int]) {
        $CIStatus.PatchesAvail = $CIHandler.Patcher.patchCount
        $CIStatus.Uptime = $CIHandler.Patcher.LastBoot.ToUniversalTime().toString('yyyy-MM-dd HH:mm:ss.fff')
    }
    If ($CIhandler.error -ne '' -or $CIHandler.error -ne $null) {
        $CIStatus.Details = $CIHandler.error
    }
    Return $CIStatus
}

# Which job are we doing?
If ($TestConnection) { $JobScriptBlock = $ConnTestJobSB }
if ($InstallUpdates) { $JobScriptBlock = $PatchJobSB }



#       --==  Init Threads  ==--
#   Pass CIname and details to the threads, start them.
$Status = [hashtable]::Synchronized(@{})
$Jobs = @()
$CMDB | ForEach-Object {
    $entry = $_
    $name = ($_.name)
    $Params = @{
        CI = $name
        CMDB = $_
        Credential = $credential
        Status = $Status
        StartTime = $startTime
        LogDir = $logdir
    }
    $jobs += New-Thread -ScriptBlock $JobScriptBlock `
            -Params $Params -RunspacePool $RunspacePool `
            -Name $name
}
$JobCount = $jobs.count
$JobComplete = 0
$JobError = 0

#       --==  Thread Monitor/Handling  ==--
#
# All threads are running. Monitor them until they're done. Collect returns.
$JobReturns = @()
# This is for the while loop. 
$isJobRunning = {
    $a = $Jobs.Handle.IsCompleted[0]
    $Jobs.Handle.IsCompleted | ForEach-Object{$a=$a -and $_}
    Return !$a
}
While ( $isJobRunning ) {
    # This block cleans up any Finished Jobs
    $jobsToRemove = @()
    ForEach ($job in $jobs) {
        If ($Job.Handle.IsCompleted) {
            $Job.Thread.EndInvoke($Job.Handle)
            If ($job.thread.HadErrors -and 
                ($job.thread.Streams.Error | Measure-Object).count ) {
                Write-Log 'ERROR' ("{0}:" -f $job.Name)
                $job.thread.Streams.Error | forEach-Object {
                    $text = @"
ScriptName: $($_.InvocationInfo.ScriptName)
Line      : $($_.InvocationInfo.ScriptLineNumber) (Col $($_.InvocationInfo.OffsetInLine))
Invocation: $($_.InvocationInfo.Line)
Exception :`n$($_.exception)
"@
                    Write-Log 'ERROR' $text
                }
            }
            $Job.Thread.dispose()
            # Update Counters
            $jout = $job.output
            if ($jout.State -eq 'Error') { $JobError++ } else { $JobComplete++ }
            $JobReturns += $jout
            $jobsToRemove += $job
        }
    }
    If ($jobsToRemove) {
        $jobs = Remove-ArrayItem $jobs $jobsToRemove
        $jobsToRemove = @()
        if (!$jobs) { Break }
        #Timeout if conn test has been running too long.
        if ($TestConnection) {
            if ((get-date) -gt $startTime + (New-TimeSpan -Minutes $ConnTestTimeout)) { Break }
        }
        if ($InstallUpdates) {
            if ((get-date) -gt $startTime + (New-TimeSpan -Minutes $PatchTimeout)) { Break }
        }
    } # END Finished Job BLOCK
    if (Test-Path '.\killswitch') { Remove-Item '.\killswitch'; Break }
    Write-ScriptStatus (Get-JobProgress $Jobs) -JobTotal $JobCount -JobsComplete $JobComplete -JobsError $JobError
    Start-Sleep 2
}
#  End of loop here: Forcibly shut down any jobs that are somehow still going.
ForEach ($job in $jobs) {
    $Job.Thread.EndInvoke($job.Handle)
    $Job.Thread.dispose()
    $JobReturns += $job.output
}
$RunspacePool.Close()
$RunspacePool.Dispose()


#       --== Cleanup and Summary ==--
#
If ($JobCount -eq $ciCount) {$t = "`nAll $JobCount"} else {
    $t = "`nAttempted to patch: $($ciCount) CIs.`n`r$JobCount"
}
$text = $t + " jobs returned data.`n`rSummary:"
Write-Log 'INFO' $text -noWriteScreen
Write-Output $text

if ($TestConnection) {
    # This block reports totals for connection testing
    # First, failed patches don't mean a failed connection.
    $jobReturns = $jobReturns | ForEach-Object {
        if ($_.State -eq 'Error' -and $_.Details -like '*patches failed to install*') {
            $_.State = 'Connected'
        }
        $_
    }
    # Note the missing CMDB entries in output:
    if ($CMDBdiff) {
        $missingCIs = @()
        $CMDBdiff.InputObject | ForEach-Object {
            $CIStatus = New-Object -TypeName PSObject -Prop (@{
                'CIName' = $_
                'State' ='Error'
                'Details' = 'CMDB entry missing'
                'Timestamp' = ''
                'PatchesAvail' = $null
            })
            $missingCIs += $CIStatus
        }
        $jobReturns += $missingCIs
    }
    $tComplete = ($JobReturns | Where-Object {$_.State -eq 'Connected'} | Measure-Object).count
    $tError = ($JobReturns | Where-Object {$_.State -ne 'Connected'} | Measure-Object).count
    if ($ciCount -ne 0) {
        $successrate = [Math]::Round((($tComplete / $ciCount)*100),1)
    } else {
        $successrate = 0
    }
    

    $JRComplete = $JobReturns | Where-Object {$_.State -eq 'Connected'} |
        Select-Object -Property CIName, Uptime, PatchesAvail, Details |
        Sort-Object -Property CIName
    
    if ($JRComplete) {
        Write-Log 'INFO' "--== Completed Connection ==--"
        Write-Log 'INFO' -noWriteScreen ($JRComplete | Format-Table -AutoSize | Out-String)
        #$JRComplete | Format-Table -AutoSize | Write-Output
    } 
    $JRErrors = $JobReturns | Where-Object {$_.State -ne 'Connected'} |
        Select-Object -Property CIName, Uptime, Details, Username |
        Sort-Object -Property CIName
    if ($JRErrors) {
        Write-Log 'ERROR' "--== Connection Errors ==--"
        Write-Log 'ERROR' -noWriteScreen ($JRErrors | Format-Table -AutoSize | Out-String)
        $JRErrors | Format-Table -AutoSize | Write-Output
    }
    if ($tComplete -eq $ciCount) {
        $finalStatus = "100% of $ciCount CIs completed the connection test."
    } else {
        $finalStatus = @"
$tComplete/$ciCount completed the connection test for a
$successrate% success rate.
"@
    }
    $OutputText =  @"
    
    --== Totals ==--
$finalStatus

"@
    if ($tComplete -ne 0){$OutputText += "$tComplete CIs Completed connection test.`n"}
    if ($tError -ne 0)   {$OutputText += "$tError CIs with errors.`n"}
    # Output details to csv and json
    $ConnTest = $JobReturns | Select-Object -Property CIName, State, PatchesAvail, Details | Sort-Object -Property CIName
    # For clarity of communication to the client...
    $ConnTest | ForEach-Object {
        if ($_.state -eq 'Connected') {$_.state = 'Success'}
        # Hack to remove extraneous quotes from the error details
        if ($_.details -like "*`"*") {
            $_.details = $_.details -replace '"',''
        }
    }
    if ($logDir) {
        $ConnTest | Export-Csv -NoTypeInformation -Path "$logDir\ConnTest.csv"
        $ConnTest | ConvertTo-JSON -Depth 5 > "$logDir\ConnTest.json"
    } else {
        $ConnTest | Export-Csv -NoTypeInformation -Path "C:\Data\Patchlog\ConnTest.csv"
        $ConnTest | ConvertTo-JSON -Depth 5 > "C:\Data\Patchlog\ConnTest.json"
    }
} else {
    # This block reports totals for patching.
    # Figure out totals
    $tComplete = ($JobReturns | Where-Object {$_.State -eq 'Complete'} | Measure-Object).count
    $tNoPatch  = ($JobReturns | Where-Object {$_.State -eq 'Complete' -and $_.PatchesInstalled -eq 0} | Measure-Object).count
    $tError    = ($JobReturns | Where-Object {$_.State -eq 'Error'} | Measure-Object).count
    # And some quick math
    $successrate = [Math]::Round((($tComplete / $ciCount)*100),1)
    $PatchesInstalled = Sum-Array $JobReturns.PatchesInstalled
    $AveragePatches = [Math]::Round(($PatchesInstalled / $ciCount),1)
    
    $JRComplete = $JobReturns | Where-Object {$_.State -eq 'Complete'} | Select-Object -Property CIName, elapsedTime, PatchesInstalled | Sort-Object -Property CIName
    if ($JRComplete) {
        $JRComplete | ForEach-Object {if ($_.PatchesInstalled -eq 0) {$_.PatchesInstalled = 'n/a'}}
        Write-Log 'INFO' "--== Completed CIs ==--"
        Write-Log 'INFO' -noWriteScreen ($JRComplete | Format-Table -AutoSize | Out-String)
        $JRComplete | Format-Table -AutoSize | Write-Output
    }
    $JRErrors = $JobReturns | Where-Object {$_.State -ne 'Complete'} | Select-Object -Property CIName, elapsedTime, PatchesInstalled | Sort-Object -Property CIName
    if ($JRErrors) {
        Write-Log 'ERROR' "--== CIs with Errors ==--"
        Write-Log 'ERROR' -noWriteScreen ($JRErrors | Format-Table -AutoSize | Out-String)
        $JRErrors | Format-Table -AutoSize | Write-Output
    }
    $jrFormatted = $JobReturns | Select-Object -Property CIName, @{Name="ThreadState"; Expr={$_.State}}, `
        @{Name="Status"; Expr={$_.Error}}, `
        PatchesInstalled, `
        @{Name = "StartTime"; Expr = {(Convert-Time -time $_.startTime -toZone "Central Standard Time").toString("MM/dd/yyyy HH:mm:ss")}}, `
        @{Name="EndTime"; Expr={(Convert-Time -time $_.endTime -toZone "Central Standard Time").toString("MM/dd/yyyy HH:mm:ss")}}
    if ($logdir) {
        $jrFormatted | Export-Csv -NoTypeInformation -Path "$logDir\JobReturns.csv"
        $jrFormatted | ConvertTo-JSON -Depth 5 > "$logDir\JobReturns.json"
    } else {
        $ymd = get-date($startTime) -f "yyyyMMdd-HHmm"
        $jrFormatted | Export-Csv -NoTypeInformation -Path "C:\Data\Patchlog\$ymd\JobReturns.csv"
        $jrFormatted | ConvertTo-JSON -Depth 5 > "C:\Data\Patchlog\$ymd\JobReturns.json"
    }
    
    if ($tComplete -eq $ciCount) {
        $finalStatus = '100% of CIs completed patching and completed reboot if required successfully.'
    } else {
        $finalStatus = @"
$tComplete/$ciCount Completed patching for a
$successrate% success rate.
"@
    }
    $Elapsed = ((Get-Date) - $StartTime).toString('hh\:mm\:ss\.fff')
    
    # Assemble the textblock
    $OutputText =  @"

    --== Totals ==--
$finalStatus
$Elapsed Elapsed time to finish this patch cycle.`n
"@
    if ($tComplete -ne 0){$OutputText += "$tComplete CIs Completed Patching.`n"}
    if ($tNoPatch -ne 0) {$OutputText += "$tNoPatch CIs required no patch.`n"}
    if ($tError -ne 0)   {$OutputText += "$tError CIs with errors.`n"}
    $OutputText += "$PatchesInstalled Patches installed (Averaging $AveragePatches per CI)"

}

# And output it.
Write-Log 'INFO' -noWriteScreen $OutputText
Write-Output $OutputText