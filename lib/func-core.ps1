# <--== CORE FUNCTIONS ==-->
<#
    These are core functions, that may be tied to the particular patching
    implementation here. I've done my best to abstract the logic, but these
    should be checked carefully if the project is ported for other uses.

    The Manage-Patching function handles state transitions on the CIHandler
    object. The object should only contain state, and this tells it how to
    change during the patching process. The secondary point of this is to report
    back status to the controlling script about the current state.
    It only takes as input the CIHandler it's controlling, and the $Settings.

    The Join-CIbySubnet function distributes CIs across controllers, and is specific
    to CLIENT's subnet mappings. This should be rewritten generally for other
    instances.
#>
function Manage-Patching {
    Param(
        [parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [PSTypeName('Patcher.CIHandler')]$CIHandler,
        [parameter(Mandatory=$false, Position=1)]
        [hashtable]$Status,
        [parameter(Mandatory=$false)]
        [int]$timer = 30,
        [parameter(Mandatory=$false)]
        [int]$timeout = 70
    )
    $CI = $CIHandler.CIName
    $ConnectAttempts = 0
    $MaxConnectAttempts = 3
    $CIStatus = @{
        'State' ='Starting'
        'Progress' = 0
        'LastLog' = ''
        'Timestamp' = (Get-Date)
    }
    if (!$status.ContainsKey($CI)) {$status.add($CI, $CIStatus)}
    $rebootCount = 0
    while ($CIHandler.state -ne 'Complete') {
        #TODO: Move this timeout logic *outside* the thread
        $PatchElapsed = New-Timespan -start $CIHandler.StartTime -End (get-date)
        if ($CIHandler.state -ne 'Rebooting' -and $rebootCount -eq 0) {
            if ($patchElapsed -gt (New-Timespan -minutes $Timeout)) {
                #This CI has been patching for $Timeout minutes, and hasn't rebooted yet.
                $CIHandler.State = 'Complete'
                $text = "Patching Timeout: $Timeout minutes exceeded."
                $CIHandler.Error = $text
                Write-Progress -Activity 'ERROR' -Status $text -PercentComplete 100
                $CIStatus = @{
                    'State' ='ERROR'
                    'Progress' = 100
                    'LastLog' = $text
                    'Timestamp' = (Get-Date)
                }
                $Status[$CI] = $CIStatus
            }
        }

        Switch ($CIHandler.state) {
            # First possible state. Immediately try to connect.
            # Also here as a placeholder for any required setup.
            'Initialized' {
                if ($ConnectAttempts -lt $MaxConnectAttempts) {
                    $ConnectAttempts++
                    $CIHandler.writelog('Info', "Connection attempt $ConnectAttempts to $($CIHandler.hostname)")
                    if ($rebootCount -gt 0) { $pc = 100 } else { $pc = 5 }
                    Write-Progress -Activity 'Initialized' -Status 'Connecting...' -PercentComplete $pc
                    $CIHandler.ConnectToCI()
                    if ($CIHandler.State -eq 'Initialized') {
                        $CIHandler.writelog('Info', "Failed connection.")
                    }
                    if ($CIHandler.State -eq 'Connected') {
                        $CIHandler.writelog('Info', "Connection success!")
                    }
                } else {
                    #Error handling for too many failed conn attempts:
                    $CIHandler.state = 'ERROR'
                    $t = "ERROR: Attempted to connect $MaxConnectAttempts times and failed."
                    $CIHandler.Error = $t
                    $CIHandler.writelog('ERROR', $t)
                }
                Break
            }
            'Connected' {
                # Reboot if required, then start the patching process.
                # Note that this state and Initialized don't provide very good
                # feedback yet.
                $ConnectAttempts = 0
                $PatchCount = $CIHandler.Patcher.patchCount
                $logText = "Starting process with $PatchCount updates to install."
                $CIHandler.writelog('INFO', $logText)
                if ($CIHandler.Patcher.rebootRequired) {
                    $CIHandler.state = 'Rebooting'
                    $CIHandler.StartReboot()
                } else {
                    $CIHandler.StartPatcher()
                    Start-Sleep -seconds $timer #Extra time to wait to let it fire up.
                }
                Write-Progress -Activity 'Connected' -Status 'Preparing to patch' -PercentComplete 10
                $CIStatus = @{
                    'State' ='Starting Patching'
                    'Progress' = 10
                    'LastLog' = $logText
                    'Timestamp' = (Get-Date)
                }
                $Status[$CI] = $CIStatus
                Break
            }
            'Patching' {
                #This state simply loops, collects status data, and provides it.
                # Once done patching, reboot if required.
                $CIHandler.CheckState()
                $c = $CIHandler.Patcher.patchCount
                $r = $c - $CIHandler.Patcher.remaining
                $text = "Elapsed Time: $PatchElapsed "
                if ($c -ne 0) {
                    $pComplete = [math]::Round((($r / $c) * 80) + 10 )
                    if ($pComplete -lt 1) {$pComplete = 1} elseif ($pComplete -gt 100) {$pComplete = 100}
                } else {
                    $pComplete = 100
                }
                if ($CIHandler.Patcher.remaining -eq 0) {
                    $text += "Left to verify: $($CIHandler.Patcher.verifying)"
                    $pstatus = 'Verifying installed patches'
                    $pComplete = 90
                    $Activity = 'Verifying'
                } else {
                    $text += "Installed/Total: $r/$c"
                    $pstatus = 'Installing patches'
                    $Activity = "Patching"
                }
                Write-Verbose $text
                Write-Progress -Activity $Activity -Status $pstatus -PercentComplete $pComplete
                $CIStatus = @{
                    'State' = $pstatus
                    'Progress' = $pComplete
                    'LastLog' = $text
                    'Timestamp' = (Get-Date)
                }
                $Status[$CI] = $CIStatus
                if (!$CIHandler.Patcher.currentlyPatching -and $CIHandler.Patcher.rebootRequired) {
                    Write-Verbose "Rebooting..."
                    $CIHandler.state = 'Rebooting'
                    $rebootCount++
                    $CIStatus = @{
                        'State' = 'Rebooting'
                        'Progress' = $pComplete
                        'LastLog' = "Reboot number $rebootCount"
                        'Timestamp' = (Get-Date)
                    }
                    $Status[$CI] = $CIStatus
                    $CIHandler.StartReboot()
                }
                Break
            }
            'Rebooting' {
                # Keep a reboot timer. Check back with the CI every so often.
                # There's a bunch of extra sleeps in here to contend with
                # various services on the CIs not being available immediately
                # upon boot.
                $RebootElapsed = New-Timespan -start $CIHandler.RebootedAt -End (get-date)
                if ($rebootElapsed -gt (New-Timespan -seconds 90) ) {
                    if (Test-WSMan -ComputerName $CIHandler.CIName -ErrorAction SilentlyContinue) {
                        Write-Verbose "Response to WSMan test. $($CIHandler.CIName) Online. Waiting 60s for services."
                        # Restart connection here by making it think we're starting from the beginning again... 
                        $CIHandler.state = 'Initialized'
                        $CIStatus = @{
                            'State' = 'Finished Reboot'
                            'Progress' = 100
                            'LastLog' = "Reboot took $RebootElapsed"
                            'Timestamp' = (Get-Date)
                        }
                        $Status[$CI] = $CIStatus
                        Start-Sleep ($timer * 4) #Wait an extra minute before connecting once we detect it's online.
                        $CIHandler.writelog('INFO', "Finished reboot.")
                        Break
                    }
                }
                if ($rebootElapsed -gt (New-Timespan -minutes 20)) {
                    #We've waited too long for it to reboot
                    $CIHandler.state = 'Error'
                    $t = 'ERROR: Exceeded 20m Timeout waiting for reboot.'
                    $CIHandler.Error = $t
                    $CIHandler.writelog('ERROR', $t)
                    Break
                }
                #Wait 15 seconds while waiting for the system to finish rebooting.
                $text = "Waited on reboot $RebootElapsed..."
                Write-Verbose $text
                $pComplete = [math]::Round((($RebootElapsed.TotalSeconds / 120) + 90), 1)
                Write-Progress -Activity ("Rebooting") -Status 'Waiting up to 20m for reboot to finish' -PercentComplete $pComplete
                $CIStatus = @{
                    'State' = 'Rebooting'
                    'Progress' = $pComplete
                    'LastLog' = $text
                    'Timestamp' = (Get-Date)
                }
                $Status[$CI] = $CIStatus
            }
            'Error' {
                # Error handling state if required. Not doing much here rn.
                $PatchError = $true
                $CIhandler.Writelog('ERROR', 'This CI failed to patch, log details follow.')
                $CIHandler.state = 'Complete'
                $CIStatus = @{
                    'State' = 'ERROR'
                    'Progress' = 0
                    'LastLog' = $CIHandler.Error
                    'Timestamp' = (Get-Date)
                }
                $Status[$CI] = $CIStatus
                Break
            }
        }
        Start-Sleep -seconds $timer #How often to poll state
    }
    # Should be in Complete state now. Tickle the SCCM evaluation
    $CIHandler.tickleSCCM()
    # Close up shop and log it.
    $CIHandler.final()
    $tp = $CIHandler.PatchesInstalled
    $rp = $CIHandler.Patcher.Remaining
    if ($PatchError) {
        # Setting back as final state for reporting
        $CIHandler.state = 'Error'
        $t = "$rp of $tp have not installed."
        $CIStatus = @{
            'State' = 'ERROR'
            'LastLog' = $t
            'Timestamp' = (Get-Date)
        }
        if ($rebootCount -gt 0) {
            $t += "`n`rRebooted $rebootCount times."
        }
    } else {
        if ($tp -eq 0) {
            $t = "No patches to install."
        } else {
            $t = "Success! Installed $tp patches."
        }
        if ($rebootCount -gt 0) {
            $t += "`n`rRebooted $rebootCount times."
        }
        $CIStatus = @{
            'State' = 'Complete'
            'Progress' = 100
            'LastLog' = $t
            'Timestamp' = (Get-Date)
        }
    }
    $Status[$CI] = $CIStatus
    $text = @"
$t 
Patch Complete.

== Totals ==
Elapsed Time: $($CIHandler.ElapsedTime)
Patches Installed: $($CIHandler.PatchesInstalled)
"@
    $CIHandler.WriteLog('INFO', $text)
}


function Join-CIbySubnet {
    # This sorts CMDB entries into Arrays of CIs in a Dict of controllers; providing
    # a CI assignment to each controller. Right now this is deterministic, but could
    # randomize the assignment easily here.
    Param (
        [Parameter(Mandatory=$True, Position=0)]
        $CMDB,
        [Parameter(Mandatory=$True, Position=1)]
        $controllerList
    ) 
    $ProxyList = @{}
    forEach ($controller in $controllerList) {
        $proxy = $controller.Proxy
        $data = @{
            'Hostname' = $controller.Hostname
            'IP' = $controller.IP
        }
        if ($ProxyList.ContainsKey( $proxy ) ) {
            $ProxyList[$proxy] += $data
        } else {
            $ProxyList.add($proxy, @( $Data ) )
        }
    }
    # Assign CIs to controllers.
    $CountProd = 0
    $CIsByController = @{}
    $IndexSubnets = @{} #Keep track of each controller 
    $CMDB | ForEach {
        # Figure out which subnet this CI is in
        # If Tier is anything other than Dev, count it as Prod for connecting to it.
        $controller = $null
        $CIName = $_.name
        $tier = ($_.Attributes | Where-Object{$_.name -eq 'Tier'}).content
        if ($tier -like '*dev*') {
            $tier = 'Dev'
        } else {
            $tier = 'Prod'
        }
        # Site is NDC, unless it's associated to a CSMC site
        $Site = $_.OutgoingAssociations.CI.name
        if ($Site -like '*CSMC*') {
            $Site = 'CSMC'
        } else {
            $Site = 'NDC'
        }
        $Subnet = "$Tier-$Site"
        # Index tracks which controller in a subnet we've last assigned to
        # This is a round-robin assignment
        if (-not $IndexSubnets.ContainsKey($Subnet)) {
            $IndexSubnets.Add($Subnet, 0)
        }
        #Now that we have an index and a subnet, assign the CI to the controller
        if ($ProxyList.ContainsKey($subnet)) {
            $controller = $ProxyList[$subnet][$IndexSubnets[$Subnet]].hostname
        } else {
            $controller = 'NotInProxy'
        }
        If (-not $CIsByController.ContainsKey($controller) ) {
            $CIsByController.add($controller, @($CIName))
        } else {
            $CIsByController[$controller] += $CIName
        } 
        if ($IndexSubnets[$Subnet] -ge ($ProxyList[$Subnet].count - 1)) {
            $IndexSubnets[$Subnet] = 0
        } else {
            $IndexSubnets[$Subnet]++
        }
    }
    return $CIsByController
}

Function Copy-ProjectAcrossEnv {
    <#  Distributes project files across controller environment.  #>
    Param (
        [parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [Array]$controllersList,
        [parameter(Mandatory=$true, Position=1)]
        [ValidateNotNullOrEmpty()]
        [PSCredential]$Credential,
        [parameter(Mandatory=$true, Position=2)]
        [ValidateNotNullOrEmpty()]
        [String]$ScriptRootPath # $settings.controllerScriptPath
    )
    # Get my hostname
    if ($PSVersionTable.Platform -eq 'Unix') {
        $MyHostname = hostname
    } else {
        $MyHostname = (Get-WmiObject win32_computersystem).DNSHostName+"."+(Get-WmiObject win32_computersystem).Domain
    } 
    # Work out Pathing
    $WorkPath = $ScriptRootPath.TrimEnd('\')
    $ProjectName = Split-Path $WorkPath -leaf
    $ParentPath = (Split-Path $WorkPath) + '\'
    New-SMBShare -Name $ProjectName -Path $ParentPath -FullAccess "$($Credential.UserName)"
    #=== START REMOTE SCRIPTBLOCK ===
    $sb = {
        Param (
            $Credential,
            $masterController,
            $WorkPath
        )
    $ProjectName = Split-Path $WorkPath -leaf
    $ParentPath = (Split-Path $WorkPath) + '\'
    if (!(Test-Path 'Patching:\') ) {
            New-PSDrive -Name $ProjectName -PSProvider FileSystem `
                -Root "\\$masterController\$ProjectName" `
                -Credential $Credential | Out-Null
        }
        Remove-Item -recurse $WorkPath -confirm:$false
        $SourcePath = ($ProjectName+':\'+$ProjectName+'\*')
        New-Item -ItemType Directory -Path $WorkPath | Out-Null
        Copy-Item -Recurse $SourcePath $WorkPath
        Remove-PSDrive $ProjectName
    }
    #<-- END REMOTE SCRIPTBLOCK -->
    # Establish sessions
    $s = New-PSSession -ComputerName $controllersList -Credential $Credential
    # Run commands against them
    $ArgList = @(
        $Credential
        $MyHostname
        $WorkPath
    )
    Invoke-Command -Session $s -ScriptBlock $sb -ArgumentList $ArgList

    Remove-SmbShare -Name $ProjectName -Force
}



# <---x CORE FUNCTIONS x--->