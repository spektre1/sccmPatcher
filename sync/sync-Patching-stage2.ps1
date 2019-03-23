<#
#requires -version 3.0

.Synopsis
    Update scripts on all controllers.
.Description
    Script distributes the project to controllers in an environment.
    Assumes controllers can all reach each other. This is a standalone
    script that is not reliant on any of the other project files.
.Parameter  <SettingsJson>
.Example
    > .\syncProject.ps1
.Outputs
    None
.Notes
    Author: Danielle.MacDonald.a@gmail.com
    Created: 2017-11-27
#>
Param (
    [parameter(Mandatory=$true, Position=0)]
    [String] $SettingsJson = ''
)

if ($SettingsJson -eq '') {
    Write-Error "This requires a settings string to function."
    Exit
}

$JsonString = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($SettingsJson))
$settings = ConvertFrom-Json $JsonString

$hashedPass = ConvertTo-SecureString -AsPlainText $settings.password -Force
$Cred = New-Object System.Management.Automation.PSCredential -ArgumentList $settings.username, $hashedPass

# == BUILD PATHS ==
$Path = ($settings.controllerScriptPath).TrimEnd('\')
$Parent = (Split-Path $Path) + '\'
$projName = Split-Path $Path -leaf
Set-Location (Split-Path $Path)

$functions_block = {
    function Get-Project ($Path, $controllerSharing, $Cred ) {
        # DOWNLOAD VIA SMB
        $projName = Split-Path $Path -leaf
        New-PSDrive -Name $projName -PSProvider FileSystem -Root "\\$controllerSharing\$projName" -Credential $Cred
        Copy-Item ($projName+':\'+$projName+'.zip') .
        Remove-PSDrive $projName
    }
    # == DECOMPRESS ==
    function Update-Project ($Path) {
        # DECOMPRESS
        $Parent = (Split-Path $Path) + '\'
        $projName = Split-Path $Path -leaf
        if (!(Test-Path $Path)) {New-Item $Path -ItemType Directory -Path $Parent}
        Remove-Item -path $Path\* -recurse -force
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory(($Parent + $projName+'.zip'), ($Path+'\'))
    }
}

. Invoke-Expression "$functions_block"
Update-Project $path

$sb_remotes = {
    Param (
        $functions_block,
        $path,
        $controllerSharing,
        $user,
        $pass
    )
    . Invoke-Expression "$functions_block"
    $hashedPass = ConvertTo-SecureString -AsPlainText $pass -Force
    $Cred = New-Object System.Management.Automation.PSCredential -ArgumentList $user, $hashedPass
    
    Set-Location (Split-Path $Path)
    Get-Project $path $controllerSharing $cred
    Update-Project $path
}

# == Setup share ==
New-SMBShare -Name $projName -Path $Parent -ReadAccess $settings.username
# == Invoke Remote controllers ==
$scontrollers = New-PSSession -ComputerName $settings.controllers -credential $Cred
Invoke-Command -Session $scontrollers -ScriptBlock $sb_remotes -ArgumentList "$functions_block", $path, $settings.controllerSharing, $settings.username, $settings.password
# == Cleanup ==
Remove-SmbShare -Name $projName -Force
