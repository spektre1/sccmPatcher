<#  Threading Functions.
#   Danielle MacDonald, 2018.
#>

function Set-ThreadingConfig {
    <# Configure memory and max process settings. This is key because we're
    kicking a lot of low-cost threads at the same time.
    #>
    Param (
        [parameter(Mandatory=$true, Position=0)]
        [Int]$maxMem = 1024,
        [parameter(Mandatory=$true, Position=1)]
        [Int]$maxProcs = 40
    )
    $RestartWinRM = $false
    $maxMemPath =    'WSMan:\localhost\Shell\MaxMemoryPerShellMB'
    $maxMemPath2 =   'WSMan:\localhost\Plugin\Microsoft.PowerShell\Quotas\MaxMemoryPerShellMB'
    $maxProcsPath =  'WSMan:\localhost\Shell\MaxProcessesPerShell'
    $maxProcsPath2 = 'WSMan:\localhost\Plugin\Microsoft.PowerShell\Quotas\MaxProcessesPerShell'
    #Test whether we can set this.
    $CurMaxMem = (Get-Item $maxMemPath).Value
    Set-Item $maxMemPath $CurMaxMem -ErrorVariable SetWinRMError -ErrorAction SilentlyContinue
    if ($SetWinRMError -like '*Access is denied.*') {
        Write-Verbose 'No write access to WinRM Memory Settings.'
        Write-Output $SetWinRMError
        Return
    } else {
        if ($CurMaxMem -ne $maxMem)
        { Set-Item $maxMemPath $maxMem; $RestartWinRM = $true }
        $CurMaxMem2 = (Get-Item $maxMemPath2).Value
        if ($CurMaxMem2 -ne $maxMem)
        { Set-Item $maxMemPath2 $maxMem; $RestartWinRM = $true }
        $CurMaxProcs = (Get-Item $maxProcsPath).Value
        if ($CurMaxProcs -ne $maxProcs)
        { Set-Item $maxProcsPath $maxProcs; $RestartWinRM = $true }
        $CurMaxProcs2 = (Get-Item $maxProcsPath2).Value
        if ($CurMaxProcs2 -ne $maxProcs)
        { Set-Item $maxProcsPath2 $maxProcs; $RestartWinRM = $true }
        if ($RestartWinRM) { Restart-Service WinRM; Start-Sleep 5 }
    }
}


Function New-RunspacePool {
    <#  This accepts functions and variables you want to load into a runspace,
        and processes them into a new runspacePool.
    #>
    Param (
        [Parameter(Mandatory=$false, Position=0)]
        [ValidateNotNullOrEmpty()]
        [Int]$maxThreads = 10,
        [Parameter(Mandatory=$false, Position=1)]
        $functions,
        [Parameter(Mandatory=$false, Position=2)]
        $variables
    )
    $SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    if ($variables) {
        $variables | ForEach-Object {
            $Variable = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'settings',$Settings,$Null
            $SessionState.Variables.Add($Variable)
        }
    }
    if ($functions) {
        $functions | ForEach-Object {
            $FunctionName = $_.Name
            $functionDefinition = Get-Content function:\$FunctionName
            $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry `
                -ArgumentList $FunctionName, $functionDefinition 
            $SessionState.Commands.Add($functionEntry)
        }
    }
    $RunspacePool = [runspacefactory]::CreateRunspacePool($SessionState)
    [void]$RunspacePool.SetMinRunspaces(1)
    [void]$RunspacePool.SetMaxRunspaces($MaxThreads)
    $RunspacePool.Open()
    Return $RunspacePool
}
# Example
# $RunspacePool = New-RunspacePool -maxThreads $maxThreads -functions $myFunctions


Function New-Thread {
    <# Constructs a runspace thread, returns Job object.
    #>
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [ScriptBlock]$ScriptBlock,
        [Parameter(Mandatory=$false, Position=1)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]$Params,
        [Parameter(Mandatory=$false, Position=2)]
        [ValidateNotNullOrEmpty()]
        $RunspacePool,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [String]$Name
    )
    $PSThread = [powershell]::Create()
    $PSThread.RunspacePool = $RunspacePool
    #IMPORTANT: The $true in AddScript() enabled Local scoping for vars in a thread
    [void]$PSThread.AddScript($ScriptBlock, $true)
    if ($Params) {
        [void]$PSThread.AddParameters($Params)
    }
    $ReturnObj = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $Handle = $PSThread.BeginInvoke($ReturnObj,$ReturnObj)
    #Return object:
    $Thread = "" | Select-Object Handle, Thread, Output, Name
    if ($name) {$Thread.Name = $Name}
    else {$Thread.Name = 'DefaultThreadName'}
    $Thread.Handle = $Handle
    $Thread.Thread = $PSThread
    $Thread.Output = $ReturnObj
    Return $Thread
}


Function Get-JobProgress {
    <# This assembles all the status data from an array of threads. #>
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        $Jobs
    )
    #Construction objects.
    $PercentsComplete = @()
    $Activities = @()
    # Get an array of completion and activity types
    ForEach ($job in $jobs) {
        if ($job.Thread.Streams.Progress) {
            $PercentsComplete += $job.Thread.Streams.Progress[-1].PercentComplete
            $Activities += $job.Thread.Streams.Progress[-1].Activity
        }
    }
    # Group and count the activities, assemble a string
    $ActivitiesStringified = ""
    $Activities | Group-Object | ForEach-Object {
        if ($_.name -like "*Preparing modules*") { $n = 'Preparing'}
        else { $n = $_.name }
        $ActivitiesStringified += $n + ": " + $_.count + "   "
    }
    # Add all the percents together, and round them as required for reporting.
    if ($PercentsComplete.count -ne 0 ) {
        $TotalCompletion = [math]::round((($PercentsComplete | Measure-Object -Sum).sum / $PercentsComplete.count),2)
    } 
    $Progress = "" | Select-Object Completion, Activities, JobCount, ActString
    $Progress.Completion = $TotalCompletion
    $Progress.Activities = $Activities | Group-Object | Select Count,Name
    $Progress.ActString  = $ActivitiesStringified
    $Progress.JobCount   = ($jobs | Measure-Object).count
    Return $Progress
}


Function Write-ScriptStatus {
    <# Write the output from Get-JobProgress to host. #>
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        $Progress,
        $JobTotal,
        $JobsComplete,
        $JobsError
    )
    $Elapsed = ((Get-Date) - $StartTime).ToString('hh\:mm\:ss\.ff')
    $PC = $Progress.Completion
    $s  = $Progress.ActString
    $jcount = $Progress.JobCount
    # Get Memory Data
    if (!$unixPlatform) { 
        $mem = Test-MemoryUsage
        $MemPercentFree = [math]::Round($mem.PctFree,0)
    } else {
        $MemPercentFree = 'na'
    }
    $MemUsed = Get-ShellMemoryUsage
    $MemUsed = ([Math]::Round($MemUsed, 2)).toString() + "MB"
    $cpuLoad = Get-WmiObject win32_processor | Select-Object -exp LoadPercentage

    $StatusString = "$Elapsed $PC% J#$jcount/$JobTotal  C#$JobsComplete E#$JobsError  Free$MemPercentFree%  Mem$MemUsed CPU$cpuLoad% $s`r"
    $Status = New-Object -TypeName PSObject -Prop (@{
        'JobsTotal'  = $JobTotal
        'JobsActive' = $jcount
        'JobsComplete' = $JobsComplete
        'JobsError'  = $JobsError
        'ElapsedTime' = $Elapsed
        'MemoryFree' = $MemPercentFree
        'MemUsed'    = $MemUsed
        'CPULoad'    = $cpuLoad
        'Progress'   = $PC
        'Activities' = $Progress.Activities
    })
    $Status | ConvertTo-Json -Depth 5 > 'C:\Data\Patching\status.json'

    # The first write-host will reset the line before drawing new text over it.
    $ShellWidth = (get-host).ui.rawui.windowsize.width
    Write-Host -NoNewLine -BackgroundColor Black (''.PadRight($ShellWidth - 1) + "`r")
    Write-Host -NoNewLine -ForegroundColor Green $StatusString
}
