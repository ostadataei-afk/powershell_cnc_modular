$ErrorActionPreference = 'Stop'
foreach ($component in @('Dxf','Geometry','Rules','OptiCut','Planning','Generation','Pipeline','Application')) {
    . (Join-Path $PSScriptRoot "src/$component.ps1")
}
Export-ModuleMember -Function @('New-DxfPair','Add-DxfPair','Get-FirstValue','ConvertFrom-DxfNumber','ConvertTo-DxfNumber','Get-EntityVertices','Read-DxfDocument','Get-TextRecords','Get-LayerTableInfo','Test-LayerExists','Add-Layer2','Get-NextHandle','Update-Handseed','Set-PolylineVertices','New-SlotLineEntity','Get-EntityBounds','Test-RectangleVertices','Get-NotchedVertices','ConvertTo-DxfGridNumber','Assert-CncGeometry','Get-DimensionText','Parse-FeatureLabel','Get-Orientation','Get-SymmetryState','Get-TableNumber','Assert-ZNotchFitsPart','Get-TableRule','Test-TextInsidePart','Get-OptiCutFormat','Test-TextAtPartCenter','Build-DxfPlan','Get-FilenamePairRole','Resolve-GlobalPairs','Apply-DxfPlan','Test-GeneratedDxf','Invoke-CncBatch','New-CncBatchPlan','ConvertTo-CncOutput')

Export-ModuleMember -Function ConvertTo-CncPlanContract
