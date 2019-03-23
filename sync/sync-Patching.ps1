<#
#requires -version 5.0

.Synopsis
    Update script on the first controller from workstation.
.Description
    Script distributes the project to primary controller in an environment.
    Relies on a PS v5 command, "Compress-Archive". 
    This assumes I've set up ssh keys for the necessary machines already.
.Parameter  <SettingsFile>
.Example
    > .\syncProject.ps1
.Outputs
    None
.Notes
    Author: Danielle.MacDonald.a@gmail.com
    Created: 2017-11-27
controller
#>
Param (
    [parameter(Mandatory=$false, Position=0)]
    [String] $SettingsFile = 'settings.json'
)

# == Imports ==
if ( (Get-Module IPpatch-functions) -ne $null ) {
    Remove-Module IPpatch-functions
}
Import-Module .\IPpatch-functions
$settings = Import-Settings $settingsFile

# == Local Setup ==
$localWorkingDir = $pwd.path
$localProjDir = Split-Path $localWorkingDir -leaf

$Path = ($settings.controllerScriptPath).TrimEnd('\')
$Parent = (Split-Path $Path) + '\'
$projName = Split-Path $Path -leaf


$ScriptPath = $settings.controllerScriptPath
$ScriptPath = $ScriptPath.TrimEnd('\')
$ScriptPathParent = (Split-Path $ScriptPath) + '\'
$projDir = Split-Path $ScriptPath -leaf
$Archive = $projDir + '.zip'

Set-Location '.\..'
Compress-Archive -Path .\${localProjDir}\* -DestinationPath $Archive -Force

# == Stage 2 Params ==
# This also strips the first controller out of the list.
$controllersJSON = ConvertTo-Json ($settings.controllers -ne $settings.controllerSharing)

$stage2 = 'sync-Patching-stage2.ps1'
$stage2_params = @"
{
"controllerScriptPath":"$(Format-Escs $settings.controllerScriptPath)",
"username":"$(Format-Escs $settings.username)",
"password":"$(Format-Escs $settings.password)",
"controllerSharing":"$((Get-Item Env:ComputerName).value)",
"controllers":$controllersJSON
}
"@
# get rid of spaces so I can oneline this in the SSH command
$stage2_params = $stage2_params -replace "`n","" -replace "`r","" -replace "    ",""
$encodedParams = ConvertTo-Base64 $stage2_params

# == Copy to Share Server ==
$remServer = $settings.username+'@'+$settings.controllerSharing
$remServerSCP = $remServer +':'+$ScriptPathParent
scp $Archive $remServerSCP
scp ($localWorkingDir+'\'+$stage2) $remServerSCP
# Execute Stage2
ssh $remServer ($ScriptPathParent+'\'+$stage2+' '+$encodedParams)

Set-Location $localWorkingDir