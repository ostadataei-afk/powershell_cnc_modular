$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$originalPath = Join-Path $root 'Build-Cnc-Dxf-OptiCut-Dual-Format-v4.ps1'
$original = Get-Content -Raw $originalPath
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($original,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Original syntax error' }
$functions=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false))
$moduleFunctions=@{}
foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot '../src') -Filter '*.ps1') {
    $tree=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "Syntax errors: $($file.Name)" }
    foreach ($node in $tree.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
        if ($moduleFunctions.ContainsKey($node.Name)) { throw "Duplicate function: $($node.Name)" }
        $moduleFunctions[$node.Name]=$node
    }
}
foreach ($fn in $functions) {
    $expected=$fn.Extent.Text.Replace('$culture','[System.Globalization.CultureInfo]::InvariantCulture')
    $actual=$moduleFunctions[$fn.Name].Extent.Text
    $actual=[regex]::Replace($actual,'\r?\n    \$(epsilon|sizeTolerance) = (0\.05|0\.1) # millimetres; original v4\.1 tolerance','')
    if ($expected.Replace("`r`n","`n") -cne $actual.Replace("`r`n","`n")) { throw "Logic changed: $($fn.Name)" }
}
Write-Host "PASS All $($functions.Count) original functions preserved (only invariant culture and local constants substituted)."
$mainStart=$original.IndexOf("`ntry {",$functions[-1].Extent.EndOffset)
$main=$original.Substring($mainStart).Trim()
$appBody=$moduleFunctions['Invoke-CncBatch'].Extent.Text
$actualMain=$appBody.Substring($appBody.IndexOf("`ntry {")).Trim()
$actualMain=$actualMain.Substring(0,$actualMain.LastIndexOf('}')).Trim()
if ($main.Replace("`r`n","`n") -cne $actualMain.Replace("`r`n","`n")) { throw 'Application workflow changed' }
Write-Host 'PASS Entire original application workflow preserved after added path preflight.'

# Execute the original workflow with isolated paths; never run its Desktop defaults.
$legacy=New-Module -ScriptBlock {
    param($Functions,$Main)
    $culture=[Globalization.CultureInfo]::InvariantCulture; $epsilon=0.05; $sizeTolerance=0.1
    foreach ($fn in $Functions) { . ([scriptblock]::Create($fn.Extent.Text)) }
    $script:workflow=[scriptblock]::Create($Main)
    function Invoke-ReferenceBatch {
        param($SourceFolder,$OutputFolder,[switch]$ValidateOnly)
        $desktop=[Environment]::GetFolderPath('Desktop')
        . $script:workflow
    }
    Export-ModuleMember Invoke-ReferenceBatch
} -ArgumentList $functions,$main
Import-Module (Join-Path $PSScriptRoot '../Cnc.psm1') -Force -DisableNameChecking
$work=Join-Path $root ('tmp/preservation-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$source=Join-Path $PSScriptRoot 'Sample_A_Valid'
$before=@(Get-ChildItem $source -File | Get-FileHash | Select-Object Path,Hash) | ConvertTo-Json
foreach ($mode in @('reference','modular')) {
    $out=Join-Path $work $mode
    [void](New-Item -ItemType Directory -Path "$out/old-subfolder")
    Set-Content "$out/old-subfolder/sentinel.txt" 'preserve on validate; remove on normal generation'
    if ($mode -eq 'reference') { & $legacy { param($s,$o) Invoke-ReferenceBatch $s $o -ValidateOnly } $source $out 6>$null }
    else { Invoke-CncBatch $source $out -ValidateOnly 6>$null }
    if (!(Test-Path "$out/old-subfolder/sentinel.txt")) { throw "$mode ValidateOnly changed output" }
    if ($mode -eq 'reference') { & $legacy { param($s,$o) Invoke-ReferenceBatch $s $o } $source $out 6>$null }
    else { Invoke-CncBatch $source $out 6>$null }
    if (Test-Path "$out/old-subfolder") { throw "$mode did not clear old output" }
    if (@(Get-ChildItem $out -File -Filter '*.dxf').Count -ne 10) { throw "$mode missing outputs" }
}
foreach ($file in Get-ChildItem "$work/reference" -File) {
    if ((Get-FileHash $file.FullName).Hash -cne (Get-FileHash "$work/modular/$($file.Name)").Hash) { throw "Byte mismatch: $($file.Name)" }
}
$after=@(Get-ChildItem $source -File | Get-FileHash | Select-Object Path,Hash) | ConvertTo-Json
if ($before -cne $after) { throw 'Source files changed' }
Write-Host 'PASS Full original/modular workflows: ValidateOnly preserves old output; normal run clears old subfolders; 10 output files byte-identical; inputs unchanged.'
foreach ($badName in @('Layered-Missing-Panel.dxf','Layered-Offcenter.dxf','Layered-MultiPanel.dxf')) {
    $inputDir=Join-Path $work $badName.Replace('.dxf','')
    [void](New-Item -ItemType Directory -Path $inputDir)
    Copy-Item (Join-Path $PSScriptRoot "TestFixtures/$badName") $inputDir
    $messages=@()
    foreach ($mode in @('reference','modular')) {
        $out=Join-Path $work "negative-$mode"
        [void](New-Item -ItemType Directory -Path $out -Force)
        Set-Content "$out/sentinel.txt" 'must survive'
        $caught=$null
        try {
            if ($mode -eq 'reference') { & $legacy { param($s,$o) Invoke-ReferenceBatch $s $o } $inputDir $out 6>$null }
            else { Invoke-CncBatch $inputDir $out 6>$null }
        } catch { $caught=$_.Exception.Message }
        if (!$caught -or !(Test-Path "$out/sentinel.txt")) { throw "Failure preservation failed: $badName / $mode" }
        $messages += $caught
    }
    if ($messages[0] -cne $messages[1]) { throw "Error mismatch: $badName" }
}
Write-Host 'PASS Three invalid input batches rejected equally; existing outputs preserved.'
Write-Host "Review output retained at $work"
