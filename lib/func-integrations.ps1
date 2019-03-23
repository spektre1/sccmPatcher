

<#
# TODO: Make SCOM portable.
https://stholo.blogspot.com/2013/08/make-scom-2012-ps-module-portable.html


SCOM Server Names
#>
function SCOM-MaintMode-Start {
    param ( [Parameter(Mandatory=$True)][string]$ciFQDN,
            [Parameter(Mandatory=$False)][single]$duration = 120
    )
    $result = $false
    import-module OperationsManager
    $endTime = ((Get-Date).AddMinutes($duration))
    $class = Get-SCOMClass -Name Microsoft.Windows.Computer
    $instance = Get-SCOMClassInstance -Class $class | Where-Object {$_.DisplayName -eq $ciFQDN}
    if ($instance) {
        Start-SCOMMaintenanceMode -Instance $Instance -EndTime $endTime -Reason "SecurityIssue" -Comment "MS Security Patches"
        if ($?) {
            $msg = "SCOM Maintenance Mode has started"
            $result = $true
        } else {
            $msg = "SCOM Error: other"
        }
    } else {
        $msg = "SCOM Warning: agent not found $ciFQDN"
        $result = $true
    }
    $CIHandler.writelog('INFO', $msg)
    return $result
}

function SCOM-MaintMode-Stop {
    param ( [Parameter(Mandatory=$True)][string]$ciFQDN )
    $result = $false
    import-module OperationsManager
    $class = Get-SCOMClass -Name Microsoft.Windows.Computer
    $instance = Get-SCOMClassInstance -Class $class | Where-Object {$_.DisplayName -eq $ciFQDN}
    if ($instance) {
        $instance | Get-SCOMMaintenanceMode | Set-SCOMMaintenanceMode -EndTime $(get-date) -Comment "Patching has been completed"
        if ($?) {
            $msg = "SCOM Maintenance Mode has ended"
            $result = $true
        } else {
            $msg = "SCOM Error: other"
        }
    } else {
        $msg = "SCOM Warning: agent not found $ciFQDN"
        $result = $true
    }
    $CIHandler.writelog('INFO', $msg)
    return $result
}


function Start-HPOMSuppress {
    <# This accepts a single CI or a list, batches the queries, 
        and returns all the available CMDB data.
    #>
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [String[]]$CIList
    )
    # This chunk does multiple queries to make sure we get all the CI data in one go.
    $SplitThreshhold = 40
    $HPOM_URI = 'EXAMPLE'
    $Data = @()
    If ($CIList.count -gt $SplitThreshhold) {
        $Chunks = Split-Array $CIList $SplitThreshhold
        $Chunks | ForEach {
            $uri = $HPOM_URI + ($_ -join '%7C')
            $Data += Invoke-WebRequest -UseBasicParsing -Method GET -uri $uri
        }
    } else {
        $uri = $HPOM_URI + ($CIList -join '%7C')
        $Data += Invoke-WebRequest -UseBasicParsing -Method GET -uri $uri
    }
    return $Data
}

function Stop-HPOMSuppress {
    <# This accepts a single CI or a list, batches the queries, 
        and returns all the available CMDB data.
    #>
    Param (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [String[]]$CIList
    )
    # This chunk does multiple queries to make sure we get all the CI data in one go.
    $SplitThreshhold = 40
    $HPOM_URI = 'EXAMPLE'
    $Data = @()
    If ($CIList.count -gt $SplitThreshhold) {
        $Chunks = Split-Array $CIList $SplitThreshhold
        $Chunks | ForEach {
            $uri = $HPOM_URI + ($_ -join '%7C')
            $Data += Invoke-WebRequest -UseBasicParsing -Method GET -uri $uri
        }
    } else {
        $uri = $HPOM_URI + ($CIList -join '%7C')
        $Data += Invoke-WebRequest -UseBasicParsing -Method GET -uri $uri
    }
    return $Data
}





