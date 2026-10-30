[CmdletBinding()]
param(
    [string]$SourceFolder = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'A'),
    [string]$OutputFolder = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'B'),
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cnc.psm1') -Force -DisableNameChecking
Invoke-CncBatch -SourceFolder $SourceFolder -OutputFolder $OutputFolder -ValidateOnly:$ValidateOnly
