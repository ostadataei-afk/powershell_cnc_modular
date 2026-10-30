[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceFolder)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cnc.psm1') -Force -DisableNameChecking
# Keep stdout valid JSON; diagnostic Write-Host messages use stream 6.
$documents = @(Get-ChildItem -LiteralPath $SourceFolder -File -Filter '*.dxf' | Sort-Object Name | ForEach-Object { Read-DxfDocument $_ })
if ($documents.Count -eq 0) { throw 'No DXF input files found.' }
$plans = New-CncBatchPlan -Documents $documents 6>$null
ConvertTo-CncPlanContract -Documents $plans | ConvertTo-Json -Depth 20
