<#  Common Functions used across this project.
#   Danielle MacDonald, 2018.
#>

# <--== SYSTEM UTILITY FUNCTIONS ==-->
function Get-ShellMemoryUsage {
    # This forces a garbage collection event to get some information on how
    # much memory is actually in use currently by this script/shell.
    # http://community.idera.com/powershell/powertips/b/tips/posts/get-memory-consumption
    $memusagebyte = [System.GC]::GetTotalMemory('forcefullcollection')
    $memusageMB = $memusagebyte / 1MB
    $script:last_memory_usage_byte = $memusagebyte
    Return $memusageMB
}

Function Test-MemoryUsage {
    # This gets the OS's global utilization information.
    $os = Get-WMIobject Win32_OperatingSystem
    $pctFree = [math]::Round(($os.FreePhysicalMemory/$os.TotalVisibleMemorySize)*100,2)
    $os | Select-Object `
    @{Name = "PctFree"; Expression = {$pctFree}},
    @{Name = "FreeGB";Expression = {[math]::Round($_.FreePhysicalMemory/1mb,2)}},
    @{Name = "TotalGB";Expression = {[int]($_.TotalVisibleMemorySize/1mb)}}
}

function Get-Credential {
    # Take string versions of user/pass and construct a credential object.
    # Bypasses a lot of the shenanigans MS put in the way to make this hard to
    # do so you don't mess up the security model.
    Param (
        [parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$username,
        [parameter(Mandatory=$true, Position=1)]
        [ValidateNotNullOrEmpty()]
        [string]$password
    )
    $hashedPass = ConvertTo-SecureString -AsPlainText $password -Force
    New-Object System.Management.Automation.PSCredential -ArgumentList $username, $hashedPass
}

# <--== DATA HANDLING FUNCTIONS ==-->
Function Split-Array {
    <# This function splits a single array into multiple sub-arrays along
    the ChunkSize. This is useful for processing multiple requests in batches.
    #>
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [Array]$InArray,
        [Alias('Size','Chunk')]
        [Parameter(Mandatory=$false, Position=1)]
        [Int]$ChunkSize=40
    )
    $ListOfArrays = @()
    for($i=0; $i -lt $InArray.length; $i+=$ChunkSize){
        $ListOfArrays += ,( $InArray[$i..($i+($ChunkSize-1))] )
    }
    Return $ListOfArrays
}

# Need a manual array handler for the synchronized arrays...
function Remove-ArrayItem {
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [Array]$InputArray,
        [Parameter(Mandatory=$true, Position=1)]
        [ValidateNotNullOrEmpty()]
        $elementsToRemove
    )
    $newArray = @()
    ForEach ($item in $InputArray) {
        $i = 0
        ForEach ($element in $elementsToRemove) {
            if ($item -ne $element) { $i++ }
        }
        if ($i -eq $elementsToRemove.count) {
            $newArray += $item
        }
    }
    Return $newArray
}

function Sum-Array {
    <#
    .SYNOPSIS
    Sums all Ints found in an array.
    
    .DESCRIPTION
    Iterate over objects in an array. If it's an int, add to a running sum.
    Return the sum as an int.
    
    .PARAMETER array
    Expects an array containing at least one Int. Otherwise returns 0.
    #>
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]    
        [Array]$array
    )
    $sum = 0
    $array | ForEach-Object {
        if ($_ -is [int]) { $sum += $_ }
    }
    return $sum
}

# These two are just here in case I need to encode for CLI params...
function ConvertTo-Base64 ($string) {
    [System.Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes($string))    
}
function ConvertFrom-Base64 ($string) {
    [System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String($string))
}

function Format-Escs ($str) {
     $str -replace '\\','\\'
}


function Test-IPAddress {
    # Returns $true for IPs, $false for anything else.
    Param([string]$test)
    if ($test -match '(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})') {
        $test -split '\.' | ForEach-Object {
            [int]$octet = $_
            if (($octet -ge 0) -and ($octet -le 255)) { $c++
            } else {
                Write-Verbose "$octet Num is out of range to be a true IP"
                return $false
            }
        }
        if ($c -eq 4) { return $true }
    } else { return $false }    
}
# <---x DATA HANDLING FUNCTIONS x--->


# <--== LOGGING/PARSING FUNCTIONS ==-->
function Read-WUpdateLog {
    <#
    .SYNOPSIS
    Read Windows Update/WSUS/SCCM logs into a human readable format, useful
    for visual scan analysis.
    .DESCRIPTION
    Long description
    .PARAMETER logFile
    Path to log file to read.
    .PARAMETER logsBack
    Hours before start time of the script to collect logs from.
    .EXAMPLE
    This example grabs the WUAHandler log, and any lines from the last 72 hours.
    Read-WUpdateLog C:\Windows\CCM\Logs\WUAHandler.log 72
    .NOTES
    General notes
    #>
    Param (
        [parameter(Mandatory=$true, Position=0)]
        [String] $logFile,
        [parameter(Mandatory=$false, Position=1)]
        [Int] $logsBack = 2
    )
    $dtLogsBack = (Get-Date).AddHours(-($logsBack))
    $newLog = "DateTime          | MsgType | Message `n"
    $log = Get-Content $logFile
    $regex = '(?s)^<!\[LOG\[(.*)\]LOG\]!><time="(.*)" date="(.*)" component="(.*)" context="(.*)" type="(.*)" thread="(.*)" file="(.*)">'
    # Doing a ForEach since some log messages are multiline, and I have to add them together to try and regex match them
    ForEach ($Index in (1..($log.Count - 1))) {
        $lineIndex = 0  #Keep count of how many lines we've added together
        $line = $log[$Index].Trim()
        while ($true) {
            $re = [regex]::Match($line, $regex)
            if ($re.success -eq $true) {
                break
            } else {
                $line += $log[$lineIndex].Trim()
                $lineIndex++
            }
            if ($lineIndex -gt 5) {
                # Here to keep it from reading the whole file.
                # This shouldn't happen, as there shouldn't be messages this long.
                break
            }
        }
        if ( $re.success ) {
            $groups = $re.captures.groups
            $time = ([regex]::Match($groups[2].value, '(.+)\+')).captures.groups[1].value
            $date = $groups[3].value
            $dt = [DateTime]($date + ' ' + $time)
            $dts = ($dt | Get-Date).toString('yyyy-MM-dd HH:mm:ss.fffK').PadRight(23)
            $log_message = $groups[1].value
            if ($dt -gt $dtLogsBack) {
                $newLog += $dts + ' | ' + $groups[6].value + ' | ' + $log_message + "`n"
            }
        }
    }
}

#TODO: What did I have this for again?
function Get-CCMLogs {
    Param (
        [parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [String]$logPath = 'C:\Windows\CCM\Logs\',
        [parameter(Mandatory=$false, Position=1)]
        [Int]$logsBack = 24
    )
    $logs = ''
    'WUAUpdate.log' | ForEach-Object {
        $logName = $logPath + $_
        $logs += "`n    == $logName == `n"
        $log = Read-WUpdateLog $logName $logsBack
        if (($log | Measure-Object -line).lines -le 1) {
            $logs += "Unable to find any entries within last $logsBack hours.`n"
        } else {
            $logs += $log
        }
    }
    return $logs
}


# There's a much better way to do this, I'm sure.
# Not sure if still useful.
function Set-Log {
    Param (
        [parameter(Mandatory=$false, Position=0)]
        [ValidateNotNullOrEmpty()]
        [String]$logdir = "..\patchlog\$((Get-Date).ToString('yyyyMMdd-HHmm'))",
        [String]$logName = 'PatchMaster'
    )
    #Test Whether the path is valid first.
    Try { $a = [System.IO.Path]::GetFullPath($LogDir) }
    Catch {
        Write-Error 'The path is not valid. Using default.'
        $logdir = "..\patchlog\$((Get-Date).ToString('yyyyMMdd-HHmm'))"
    }

    # If the Logfile path already exists, rename with the datestamp appended
    if (Test-Path $logDir) {
        # If the path already exists, rename with the datestamp appended
        $now = $((Get-Date).ToString('yyyyMMdd-HHmmss'))
        if ((Get-Item $logDir) -isnot [System.IO.DirectoryInfo]) {
            $f = Split-Path -Path $logDir -Leaf -Resolve
            Rename-Item -Path $logDir -NewName "$f-$now"
            Write-Error 'Logpath already exists - renaming $f to $f-$now'
        }
        else {
            $basename = $(Split-Path -Path $logDir -Leaf)
            Rename-Item -Path $logdir -NewName "$basename.$now"
        }
    }

    # Create the Logfile path
    # Different methods required depending on a rel/abs path.
    If ([System.IO.Path]::IsPathRooted($LogDir)) {
        New-Item -path (Split-Path $logDir) -Name (Split-Path -Leaf $logDir) -itemtype Directory | Out-Null
    } else {
        New-Item -path . -name $logDir -itemtype Directory | Out-Null
    }

    # Convert the log file 
    $logName = $logdir + '\' + $logName + '.log'
    #Initalize the log file
    Set-Content $logName ''
    $logName = (Resolve-Path $logName).path
    Set-Variable -Name SCCMMasterLogFile -Value "$logName" -Scope Global
}


function Write-Log {
    <#
    Writes to std-out, and also logs if this is called from a script where
    the log path is defined.
    #>
    Param (
        [parameter(Mandatory=$false, Position=0)]
        [ValidateNotNullOrEmpty()][alias("l")]
        [ValidateSet('ERROR','WARN','INFO','DEBUG')]
        [String]$level = 'INFO',
        [parameter(Mandatory=$true, Position=1)]
        [ValidateNotNullOrEmpty()][alias("m")]
        [String]$message,
        [Switch]$noWriteScreen
    )
    $LevelColors = @{
        'ERROR' = 'Red'
        'WARN'  = 'Yellow'
        'INFO'  = 'White'
        'DEBUG' = 'Cyan'
    }
    if ($SCCMMasterLogFile) {
        $ts = (Get-Date).toString('yyyy-MM-dd HH:mm:ss.fffK')
        $message = "$ts [$level] " + $message
        Add-Content $SCCMMasterLogFile $message
        if ( (!($level -eq 'DEBUG') -or $VerbosePreference -eq 'continue') -and !$noWriteScreen) {
            Write-Host ($message -replace "`n", "`n`r") -ForegroundColor  $LevelColors[$level]
        }
    } else {
        Write-Error 'You must Set-Log before trying to write to it.'
    }
}
# <---x LOGGING/PARSING FUNCTIONS x--->


# <=== DATETIME FUNCTIONS ===>
function Get-EpochTime {
    <#
    .SYNOPSIS
    Returns [int]seconds since the unix epoch.
    #>
    Param (
        [parameter(Mandatory=$false, Position=0)]
        $timeTo
    )
    if ($timeTo) {
        $Seconds = (New-TimeSpan `
        -Start (Get-Date -Date "01/01/1970") `
        -End (Get-Date $timeTo)).TotalSeconds
    } else {
        $Seconds = (New-TimeSpan `
        -Start (Get-Date -Date "01/01/1970") `
        -End (Get-Date)).TotalSeconds
    }
    $r = [Math]::Floor($seconds)
    return [Int]$r
}

function Get-DateFromEpoch ($t) {
    # Get a datetime obj from a unix epoch timestamp
    (Get-Date -Date "1970-01-01").AddSeconds($t)
}

function Convert-JavaDateTime ($objs) {
    # This helps parse Java timestamps into PowerShell DateTime objects.
    $objs | ForEach-Object {
        $obj = $_
        $PropNames = ($obj | Get-Member | Where-Object {
            $_.MemberType -eq 'NoteProperty' -and
            $_.Definition -like 'long*'
        }).Name
        $PropNames | ForEach-Object {
            if ($obj.$_ -gt 1000000000000) {
                #Might be a date. Try it:
                $t = [Math]::Floor(($obj.$_ / 1000))
                $obj.$_ = Get-DateFromEpoch $t
            }
        }
    }
}
# Example is from an API call for HostStatus:
# Get-DateFromEpoch ($content.lastHardStateChange /1000)

function Convert-Time {
    <#
    .SYNOPSIS
    Convert a given time from one zone to another
    This observes Daylight Savings Time

    .DESCRIPTION
    The -fromZone, -toZone arguments need to be the zone "ID"
    ([TimeZoneInfo]::Local).Id shows the current time zone ID, and -FromZone defaults to this
    Powershell sessions obseve the time zone setting of the time they were launched, they
    do not update when you change the time zone.
    Get-WmiObject Win32_TimeZone does NOT show the time zone ID

    The following .NET method to lists all time zones and their properties:
    ID, 3 different Names, Offset, DST Support
    [System.TimeZoneInfo]::GetSystemTimeZones() | Out-Gridview
    Use GridView, Output is too wide for most console windows

    .NOTES
    This requires .NET Framework 3.5
    In the US, DST changes the 2nd Sunday of March, and the 1st Sunday of November

    For most zones, the ID and the "Standard Zone" name are the same
    However, for 16 zones they are different
    UTC is one of the non matching zones (ID = UTC, Display = Coordinated Universal Time)

    .EXAMPLE
    ConvertTime "03/11/2018 22:00" -fromZone UTC -toZone "Central Standard Time"

    .EXAMPLE
    ConvertTime "03/11/2018 22:00" -fromZone "Central Standard Time" -toZone UTC

    .EXAMPLE
    ConvertTime "03/11/2018 22:00" -toZone UTC

    .LINK
    https://www.worldtimebuddy.com/
    https://www.timeanddate.com/time/zone/usa/chicago

     #>
    [CmdletBinding()]    
    param ( [Parameter(Mandatory=$true)]
            [string]$time,
            [Parameter(Mandatory=$false)]
            [string]$fromZone = ([TimeZoneInfo]::Local).Id,
            [Parameter(Mandatory=$true)]
            [string]$toZone
          )
    # $Time as [string] avoids: conversion could not be completed because the supplied DateTime did not have the Kind property set correctly
    $tziFrom = [System.TimeZoneInfo]::FindSystemTimeZoneById($fromZone)
    $tziTo   = [System.TimeZoneInfo]::FindSystemTimeZoneById($toZone)
    $utc     = [System.TimeZoneInfo]::ConvertTimeToUtc($time, $tziFrom)
    $newTime = [System.TimeZoneInfo]::ConvertTime($utc, $tziTo)
    return $newTime
}

# <---x DATETIME FUNCTIONS x--->