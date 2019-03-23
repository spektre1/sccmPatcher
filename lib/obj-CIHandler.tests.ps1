$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path) -replace '\.Tests\.', '.'
. "$here\$sut"

Describe "New-CIHandler" {
    # Generate some fake data to setup with.
    $hashedPass = ConvertTo-SecureString -AsPlainText 'fakepass' -Force
    $credential = New-Object System.Management.Automation.PSCredential -ArgumentList 'fakeUsername', $hashedPass
    $CIHandler = New-CIHandler -Credential $credential 'localhost'
    It "creates the object" {
        $CIHandler.ciname | Should Be 'localhost'
    }
    It "is of the correct type" {
        $CIHandler.DisplayName | Should Be 'CIHandler for Windows Patcher'
        $CIHandler.pstypenames[0] | Should Be 'Patcher.CIHandler'
    }
    It "is in the intialized state" {
        $CIHandler.state | Should be 'Initialized'
    }
    It "has a startTime that reflects actual time" {
        (New-Timespan -start $cihandler.starttime -end (get-date)).totalseconds | Should BeLessThan 60
    }
    It "generates a logfile" {
        Test-Path $cihandler.logpath | Should Be $true
    }
    It "Fails to connect to a bad DNS and errors" {
        $testHostname = 'imcertainthisdoesntexist.com'
        $CIHandler.hostname = $testHostname
        $CIHandler.ConnectToCI()
        $CIHandler.state | Should Be 'Error'
        "$($CIHandler.taillog())" | Should Match ('DNS Error resolving '+$testHostname)
    }
    It "Fails to connect without credentials and errors" {
        $CIHandler.hostname = 'localhost'
        $CIHandler.state = 'Initialized'
        $CIHandler.ConnectToCI()
        "$($CIHandler.taillog())" | Should Match 'Access denied'
    }
    It "Connects Successfully to localhost" {
        $cihandler.credential = $null
        $CIHandler.hostname = 'localhost'
        $CIHandler.ConnectToCI()
        "$($CIHandler.taillog())" | Should Match ("Connected $($CIHandler.hostname)")
    }
    # Clean up after tests:
    Write-Verbose ((Get-Content $cihandler.logpath) -join "`n`r")
    Write-Verbose "Removing logs generated during tests..."
    Remove-Item -Force -Recurse (Split-Path $cihandler.logpath)
}

