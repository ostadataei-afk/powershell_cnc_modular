$ErrorActionPreference = 'Stop'
foreach ($name in @('Test-Cnc-Safe-Labels-v2.ps1','Test-Cnc-Geometry-Stage2-v3.1.ps1','Test-Cnc-OptiCut-Stage3.ps1','Test-Parity.ps1','Test-Preservation.ps1')) {
    & (Join-Path $PSScriptRoot $name)
}
