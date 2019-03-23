
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path) -replace '\.Tests\.', '.'
. "$here\$sut"

Describe 'Get-ShellMemoryUsage' {
    It 'Returns an int' {
        Get-ShellMemoryUsage | Should BeOfType [Double]
    }
}

Describe 'Test-MemoryUsage' {
    It 'Returns a PSCustomObject containing memory values' {
        $Actual = Test-MemoryUsage
        $Actual | Should BeOfType [PSCustomObject]
        $Actual.PctFree | Should BeOfType [Double]
        $Actual.FreeGB | Should BeOfType [Double]
    }
}

Describe 'Get-Credential' {
    # Generate some fake data to setup with.
    It 'creates a PSCredential Object' {
        $credential = Get-Credential -Username 'FakeUser' -Password 'FakePassword'
        $credential | Should BeOfType [PSCredential]
        $credential.UserName | Should Be 'FakeUser'
    }
}

Describe 'Split-Array' {
    It 'Returns an Array' {
        (Split-Array @(0..9) 4) | Should BeOfType [Array]
    }
    It 'Splits an Array of 0..99 into 10 subarrays' {
        $Actual = Split-Array @(0..99) 10
        $Expected = 10
        $Actual.count | Should be $Expected
    }
}

Describe 'Remove-ArrayItem' {
    $testData = ('Apple', 'Orange', 'Grapes')
    It 'Returns an array without the item for removal' {
        $Actual = Remove-ArrayItem $testData 'Grapes'
        $Expected = @('Apple', 'Orange')
        $Actual | Should Be $Expected
    }
}

Describe 'Sum-Array' {
    It 'Returns 10 for input @(0..4)' {
        $Actual = Sum-Array @(0..4)
        $Expected = 10
        $Actual | Should Be $Expected
    }

}

Describe 'ConvertTo-Base64' {
    it 'returns a base64 encoded string' {
        ConvertTo-Base64 'Stuff' | Should be 'U3R1ZmY='
    }
}

Describe 'ConvertFrom-Base64' {
    it 'returns a plaintext string' {
        ConvertFrom-Base64 'U3R1ZmY=' | Should be 'Stuff'
    }
}

Describe 'Get-EpochTime' {
    It 'Returns an int32 representing seconds since unix epoch'  {
        Get-EpochTime | Should BeOfType [Int]
    }
}


Describe 'Set- and Write- Log' {
    $TestLogPath = "$TestDrive\logs"
    $TestLogName = '\PatchMaster.log'
    $TestLogFile = ($TestLogPath + $TestLogName)
    $TestLogEntry = 'This is a bunch of text'
    It 'Sets a logfile with a valid path' {
        Set-Log $TestLogPath
        $SCCMMasterLogFile | Should be $TestLogFile
        Test-Path $TestLogPath | Should Be $true
    }
    It 'is capable of writing to that log' {
        Write-Log $TestLogEntry -noWriteScreen
        $actual = Get-Content $TestLogFile
        "$actual" | Should Match $TestLogEntry
    }
}

Describe 'Test-IPAddress' {
    It 'Returns True for an actual ip address' {
        Test-IPaddress '127.0.0.1' | Should be $true
    }
    It 'Returns Flase for out-of-range ip address' {
        Test-IPaddress '192.168.0.256' | Should be $false
    }
    It 'Returns flase for a hostname' {
        Test-IPaddress 'example.com' | Should be $false
    }
}