# 2017 Danielle MacDonald
# CIHandler Object Generator
# Note: compatible with PSv3

function New-CIHandler {
    <#
    .SYNOPSIS
    CIHandler Object Generator.
    
    .DESCRIPTION
    This object is initialized on an controller, and acts as a communications
    handler with a Patcher Object, and reconnects to the CI as required,
    particularly after reboots.
    
    .EXAMPLE
    $CIHandler = New-CIHandler
    #>
    Param(
        [parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [String]$CIName,
        [parameter(Mandatory=$true, Position=1)]
        [ValidateNotNullOrEmpty()]
        [PSCredential]$Credential,
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        $startTime = (Get-Date),
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        $logdir,
        [parameter(Mandatory=$false)]
        $CMDB = $null,
        [Switch]$DisableLogging
    )

    # Set some timeouts on commands.
    $pssOpt = New-PSSessionOption
    $pssOptTimeout = (New-TimeSpan -Seconds 60)
    $pssOpt.OpenTimeout = $pssOptTimeout
    $pssOpt.IdleTimeout = $pssOptTimeout
    $pssOpt.OperationTimeout = $pssOptTimeout
    $pssOpt.CancelTimeout = $pssOptTimeout
    $pssOpt.NoMachineProfile = $true
    
    $Properties = @{
        'PSTypeName' = 'Patcher.CIHandler'
        'DisplayName'= 'CIHandler for Windows Patcher'
        'DisableLogging' = $DisableLogging
        'logsBack'   = $startTime.addHours(-2)
        'logPath'    = $null
        'startTime'  = (Get-Date)
        'elapsedTime'= $null
        'endTime'    = $null
        'CIName'     = $CIName
        'Hostname'   = $CIName
        'Credential' = $Credential
        'Session'    = $null
        'SessionOpts'= $pssOpt
        'Patcher'    = $null
        'RebootedAt' = $null
        'State'      = 'Initialized'
        'Error'      = $null
        'PatchesInstalled' = 0
        'CMDB'       = $CMDB
        'Platform'   = $null
    }

    $CIHandler = New-Object PSObject -Property $Properties

    # Assign methods...
    $typeData = @{
        TypeName = 'Patcher.CIHandler'
        MemberType = 'ScriptMethod'
        Force = $true
    }


    # == .Initialize()  ==
    $sb = {
        if (!$this.DisableLogging) {
            #Testing Logging is setup
            if (!$logDir) {
                $logDir = "..\patchlog\$($startTime.ToString('yyyyMMdd-HHmm'))"
            }
            if ( !( Test-Path $logDir) ) {
                New-Item -path . -name $logDir -itemtype directory | Out-Null
            }
            $this.logPath = ".\$logDir\$($this.CIName).log"
            $this.WriteLog('INFO', 'Starting CI Handler')
        }
        if ($psversiontable.platform) {
            $this.platform = $psversiontable.platform
        } else {
            $this.platform = 'NT'
        }
    }
    Update-TypeData @typeData -Value $sb -MemberName 'Initialize'


    # == .WriteLog() ==
    $sb = {
        Param (
            [parameter(Mandatory=$false, Position=0)]
            [ValidateNotNullOrEmpty()][alias("l")]
            [ValidateSet('ERROR','WARN','INFO','DEBUG')]
            [String]$level = 'INFO',
            [parameter(Mandatory=$true, Position=1)]
            [ValidateNotNullOrEmpty()][alias("m")]
            [String]$message
        )
        if (!$this.DisableLogging) {
            $ts = (Get-Date).ToUniversalTime().toString('yyyy-MM-dd HH:mm:ss.fff')
            $message = "$ts [$level] " + $message
            Add-Content $this.LogPath ($message -replace "\r\n|\n","`r`n")
        }
    }
    Update-TypeData @typeData -Value $sb -MemberName 'WriteLog'


    # == .TailLog() ==
    $sb = {
        Param ( [Int]$Count = 10 )
        Get-Content $this.LogPath | Select-Object -Last $count
    }
    Update-TypeData @typeData -Value $sb -MemberName 'TailLog'


    #  == .ConnectToCI() ==
    $sb = {
        Param (
            [Switch]$TestConnection
        )
        # if there's an existing session, try to disconnect it cleanly before
        # spinning up a fresh connection.
        if ($this.session -ne $null) {
            if ( $this.session.getType.name -like 'PSSession') {
                Remove-PSSession $this.session
            } else {
                $this.Session = $null
            }
        }
        # Start by testing DNS. Only test if it's not an IP.
        if (!(Test-IPAddress $this.hostname) -and $this.hostname -ne 'localhost') {
            try   { [Net.DNS]::GetHostEntry($this.HostName) | Out-Null }
            catch { $dnsErr = $error[0].Exception.Message
                    $msg = "DNS Error resolving $($this.Hostname)."
                    $this.State = 'Error'
                    $this.Error = $msg
                    $this.WriteLog('ERROR', $msg)
                    return
            }
        }

        # == Connection Testing ==
        if ($this.platform -eq 'Unix') {
            #TODO: Any unix stuff I wanna try instead?
        } else {
            $this.WriteLog('INFO', "Checking WinRM is available")
            if ( Test-WSMan $this.Hostname -ErrorVariable MyConnError -ErrorAction SilentlyContinue) {
                $this.WriteLog('INFO', "Opening new session")
                if ($this.credential) {
                    $this.Session = New-PSSession -ComputerName $this.HostName `
                        -ErrorAction SilentlyContinue -ErrorVariable MyConnError `
                        -SessionOption $this.SessionOpts -credential $this.Credential
                } else {
                    $this.Session = New-PSSession -ComputerName $this.HostName `
                        -ErrorAction SilentlyContinue -ErrorVariable MyConnError `
                        -SessionOption $this.SessionOpts
                }
                if ($MyConnError.count -ne 0) {
                    # Connection error handling
                    Switch -wildcard ($MyConnError.exception)
                    {
                        '*MI_RESULT_ACCESS_DENIED*' {
                            $errText = "Access denied. Actions: check user/pass is valid and WinRM is enabled."
                            Break
                        }
                        '*Access is denied*' {
                            $errText = "Access denied. Actions: check user/pass is valid and WinRM is enabled."
                            Break
                        }
                        '*Negotiate authentication: An unknown security error occurred.*' {
                            $errText = "Unknown Security Error: Check WinRM, Kerberos, or Domain"
                            Break
                        }
                        '*server name cannot be resolved*' {
                            $errText = "DNS cannot resolve name"
                            Break
                        }
                        '*concurrent shells*' {
                            $errText = "User tried to connect to CI too many times, or too many existing shells open"
                            Break
                        }
                        '*Verify that the specified computer name is valid, that the computer is accessible over the network, and that a firewall exception for the WinRM service is enabled*' {
                            $errText = "Verify that the specified computer name is valid, that the computer is accessible over the network, and that a firewall exception for the WinRM service is enabled"
                            Break
                        }
                        '*The WSMan service could not launch a host process to process the given request*' {
                            $errText = "The WSMan service could not launch a host process to process the given request"
                            Break
                        }
                        '*The client cannot connect to the destination specified in the request. Verify that the service on the destination is running and is accepting requests*' {
                            $errText = "WinRM is not responding"
                            Break
                        }
                        default {
                            $errText = "unknown exception! Including Exception text: `n" + $MyConnError.Exception
                        }
                    }
                    $this.error = $errText
                    $this.WriteLog('ERROR', $errText )
                    $this.state = 'Error'
                    return
                }
                Start-Sleep 1
                $text = "Connected $($this.CIName), session `"$($this.Session.Name)`" $($this.Session.State)"
                $this.WriteLog('INFO', $text)
            } else {
                $errText = "Host is unresponsive, possibly offline."
                $this.error = $errText
                $this.WriteLog('ERROR', $errText )
                $this.state = 'Error'
            }
        }
        if ($this.session -and ($this.session.state -ne 'Broken')) {
            # load the libraries on the CI while we're here...
            $this.WriteLog('INFO', "Loading libraries on the CI")
            $Path = 'C:\Data\Patching\lib\'
            $libFunctions = Get-ChildItem ($Path + '*.ps1') -exclude '*.tests.ps1'
            $libFunctions | ForEach-Object {
                $Filepath = $Path + $_.Name
                $this.WriteLog('INFO', "Loading: " + $Filepath)
                Invoke-Command -Session $this.session -FilePath $FilePath 
            }
            $this.WriteLog('INFO', "Instancing patching object")
            $this.Patcher = Invoke-Command -Session $this.Session -ScriptBlock {
                $Patcher = New-Patcher
                $Patcher
            }
            $this.WriteLog('INFO', "Loading complete")
            $this.State = 'Connected'
            # no need to go any further if we're just testing the connection
            if ($TestConnection) { return }

            # This next part is really important, lets Handler know we're done at the beginning.
            if ($this.Patcher.remaining -eq 0) {
                $this.State = 'Complete'
            } else {
                # Returns a plaintext list of the patches to be applied. Useful for status.
                $text = '== Available Patches ==' + "`n" +
                        'ArticleID | S | Def  | Description' + "`n"
                forEach ( $patch in $this.Patcher.PatchList ) {
                    $n = $patch.Name -replace ' \(KB\d+\)$',''
                    if ($n.length -gt 60) {
                        $n = ($n[0..60] -join '') + '...'
                    }
                    $eState = $patch.EvaluationState
                    $text += 'KB'+ $patch.ArticleID +
                        ' | '+ $eState +
                        ' | '+ $settings.defines.patchStateDef.$eState +
                        " | "+ $n + "`n"
                }
                $this.WriteLog('INFO', $text)
                if ( $this.PatchesInstalled -eq 0 ) {
                    $this.PatchesInstalled = $this.patcher.patchCount
                }
            }
            $log = $this.GetCILogs()
            if ($log) { $this.WriteLog('INFO', $log) }
        }
    }
    Update-TypeData @typeData -Value $sb -MemberName 'ConnectToCI'


    # == .getCILogs() ==
    $sb = {
        if ($this.session -and 
            $this.session.state -ne 'Broken') {
            $CILogs = Invoke-Command -Session $this.Session {
                return $patcher.getLog()
            }
            if ($CILogs) {
                $output = $CILogs -replace "\r\n|\n","`r`n"
                if (!$this.DisableLogging) {
                    Add-Content $this.LogPath $output
                }
            }
        } else {
            $this.Writelog('WARN', 'Cannot .getCILogs(), no session available connected to CI.')
        }
    }
    Update-TypeData @typeData -Value $sb -MemberName 'getCILogs'

    
    # == .startPatcher() ==
    $sb = {
        <# Most of this code handles how we asynchronously communicate with the
        CI that's being patched.
        #>
        # and $this.PatchesInstalled -gt 0 ?
        if ($this.state -eq 'Connected') {
            if ($this.PatchesInstalled -gt 0) {
                Invoke-command -Session $this.session -ScriptBlock  { $Patcher.StartPatching() }
                $this.state = 'Patching'
            } else {
                if ($this.Patcher.rebootRequired) {
                    $this.StartReboot()
                } else {
                    $this.state = 'Complete'
                }
            }
        }
    }
    Update-TypeData @typeData -Value $sb -MemberName 'startPatcher'


    # == .final() ==
    # This is for cleanup, and a summary of the patch.
    $sb = {
        # Check if any patches are left in error state:
        if ($this.Patcher.Patchlist) {
            $PatchErrors = $this.Patcher.Patchlist | Where {$_.EvaluationState -eq '13'}
            $PatchErrorCount = ($PatchErrors | Measure-Object).count
            if ($PatchErrorCount -gt 0) {
                $message = "$PatchErrorCount patches failed to install and may require manual remediation. Details in CILog."
                $this.error = $message
                $PatchInfo = $PatchErrors | Select-Object -Property ArticleID, Name, ErrorCode, URL |
                    ForEach-Object {
                        if ($_.name.length -gt 40) {$_.name = $_.name.subString(0,39) + "..."}
                        $_
                    } | Format-Table -AutoSize | Out-String
                $message += $PatchInfo
                $this.state = 'Error'
                $this.WriteLog('Error', $message)
            }
        }
        $log = $this.GetCILogs()
        if ($log) {
            $this.WriteLog('INFO', $log)
        }
        $this.WriteLog('INFO', 'Finished')
        $this.elapsedTime = New-Timespan -start $this.startTime -End (Get-Date)
        $this.endTime = Get-Date
        # == Cleanup Any Open Handles/connections ==
        if ($this.session) {
            Remove-PSSession $this.session
        }
    }
    Update-TypeData @typeData -Value $sb -MemberName 'final'


    # == .StartReboot() ==
    $sb = {
        Invoke-Command -Session $this.Session `
        -ErrorVariable ev -ErrorAction Continue -ScriptBlock {
            Restart-Computer -Force
        } | Out-Null
        if ($ev.exception) {
            $errText = "Reboot error: " + $ev.Exception.toString()
            $this.State = 'Error'
            $this.Writelog('ERROR', $errText)
            $this.Error = $errText
        } else {
            $this.State = 'Rebooting'
            $this.WriteLog('INFO', "Reboot started.")
            $this.RebootedAt = Get-Date
            Remove-PSSession $this.session
        }
    }
    Update-TypeData @typeData -Value $sb -MemberName 'StartReboot'


    # == .TicklSCCM() ==
    $sb = {
        if ($this.session -and 
            $this.session.state -ne 'Broken') {
            Invoke-Command -Session $this.Session `
            -ErrorVariable ev -ErrorAction Continue -ScriptBlock {
                $Baselines = Get-WmiObject -Namespace root\ccm\dcm -Class SMS_DesiredConfiguration
                $Baselines | Where-Object {
                    $_.displayName -match "Patching|Certification"
                } | ForEach-Object {
                    ([wmiclass]"root\ccm\dcm:SMS_DesiredConfiguration").TriggerEvaluation($_.Name, $_.Version)
                }
            } | Out-Null
            if ($ev.exception) {
                $errText = "tickleSCCM error: " + $ev.Exception.toString()
                $this.Writelog('ERROR', $errText)
            } else {
                $this.WriteLog('INFO', "tickleSCCM complete.")
            }
        }
        else {
            $this.WriteLog('WARN', "tickleSCCM No session available.")
        }
    }
    Update-TypeData @typeData -Value $sb -MemberName 'tickleSCCM'


    # == .CheckState() ==
    $sb = {
        $this.Patcher = Invoke-command -Session $this.session -ScriptBlock  {
            $Patcher.getPatchList()
            $Patcher.checkrunning()
            $Patcher.checkReboot()
            return $Patcher
        }
        $this.elapsedTime = New-Timespan -start $this.startTime -End (Get-Date)
    }
    Update-TypeData @typeData -Value $sb -MemberName 'CheckState'


    $CIHandler.initialize()
    return $CIHandler
}