$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$original = Join-Path $root 'Build-Cnc-Dxf-OptiCut-Dual-Format-v4.ps1'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($original,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Original source syntax errors' }
$legacy = New-Module -ScriptBlock {
    param($Ast)
    $culture=[System.Globalization.CultureInfo]::InvariantCulture
    $epsilon=0.05; $sizeTolerance=0.1
    foreach ($node in $Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
        . ([scriptblock]::Create($node.Extent.Text))
    }
    Export-ModuleMember -Function *
} -ArgumentList $ast
Import-Module (Join-Path $PSScriptRoot '../Cnc.psm1') -Force -DisableNameChecking
$batches = @(
    @{ Path = 'Sample_A_Valid'; Names = @('*.dxf') },
    @{ Path = 'TestFixtures'; Names = @('Legacy-One-Part.dxf') },
    @{ Path = 'TestFixtures'; Names = @('Legacy-Fifteen-Parts.dxf') },
    @{ Path = 'TestFixtures'; Names = @('Layered-Original.dxf') },
    @{ Path = 'TestFixtures'; Names = @('Layered-Pair.dxf') },
    @{ Path = 'TestFixtures'; Names = @('Layered-Standalone.dxf') },
    @{ Path = 'TestFixtures'; Names = @('Mix-R-Legacy.dxf','Mix-L-Layered.dxf') }
)
$count=0
foreach ($batch in $batches) {
    $files=@(@(foreach ($name in $batch.Names) { Get-ChildItem (Join-Path $PSScriptRoot "$($batch.Path)/$name") -File }) | Sort-Object Name)
    $expected = & $legacy {
        param($Files)
        $docs=@($Files | ForEach-Object { Build-DxfPlan (Read-DxfDocument $_) })
        Resolve-GlobalPairs -Documents $docs
        Assert-CncGeometry -Documents $docs
        @($docs | ForEach-Object { Apply-DxfPlan $_ })
    } $files
    $docs=@($files | ForEach-Object { Read-DxfDocument $_ })
    $plans=New-CncBatchPlan -Documents $docs
    $contract=ConvertTo-CncPlanContract $plans | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    if ($contract.files.Count -ne $files.Count -or $contract.schemaVersion -ne 1) { throw 'Contract round-trip failed' }
    $actual=ConvertTo-CncOutput -Documents $plans
    for ($i=0; $i -lt $expected.Count; $i++) {
        if ($expected[$i].OutputName -cne $actual[$i].OutputName -or
            ($expected[$i].Lines -join "`r`n") -cne ($actual[$i].Lines -join "`r`n")) {
            throw "DXF parity failed: $($files[$i].Name)"
        }
        $count++
    }
}
Write-Host "Parity: $count DXF outputs identical to original; 7 contract JSON round-trips passed."
