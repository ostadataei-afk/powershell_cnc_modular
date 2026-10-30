function Invoke-CncBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$OutputFolder,
        [switch]$ValidateOnly
    )
    $ErrorActionPreference = 'Stop'
    $desktop = [Environment]::GetFolderPath('Desktop')
    $inputPath = [IO.Path]::GetFullPath($SourceFolder).TrimEnd('\','/')
    $outputPath = [IO.Path]::GetFullPath($OutputFolder).TrimEnd('\','/')
    $rootPath = [IO.Path]::GetPathRoot($outputPath).TrimEnd('\','/')
    if ($outputPath -ieq $rootPath -or $outputPath -ieq $inputPath -or
        $inputPath.StartsWith($outputPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe output path: output must not be a drive root, the input folder, or its ancestor.'
    }
    if ((Test-Path -LiteralPath $OutputFolder) -and
        ((Get-Item -LiteralPath $OutputFolder).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unsafe output path: output must not be a symbolic link or junction.'
    }
try {
    Write-Host ''
    Write-Host '=== Independent DXF Generator for CNC Parts ===' -ForegroundColor Cyan
    Write-Host "Input: $sourceFolder"
    Write-Host "Output: $outputFolder"
    if (-not (Test-Path -LiteralPath $sourceFolder -PathType Container)) { throw "Input folder not found: $sourceFolder" }
    $files = @(Get-ChildItem -LiteralPath $sourceFolder -File | Where-Object { $_.Extension -match '^\.dxf$' } | Sort-Object Name)
    if ($files.Count -eq 0) { throw "No DXF files found in folder $sourceFolder." }
    Write-Host "Number of input files: $($files.Count)" -ForegroundColor Cyan

    $documents = [System.Collections.Generic.List[object]]::new(); $validationErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        Write-Host "`n[Validating] $($file.Name)" -ForegroundColor Yellow
        try {
            $doc = Read-DxfDocument $file
            $doc = Build-DxfPlan $doc
            $documents.Add($doc)
        } catch {
            $message = "$($file.Name): $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
        }
    }
    if ($validationErrors.Count -eq 0) {
        try { Resolve-GlobalPairs -Documents $documents.ToArray() }
        catch {
            $message = "Global SH+Z pairing: $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
        }
    }
    if ($validationErrors.Count -gt 0) {
        Write-Host "`nGeneration stopped; no new output files were written and existing files in folder B were preserved." -ForegroundColor Red
        foreach ($message in $validationErrors) { Write-Host " - $message" -ForegroundColor Red }
        throw 'Validation failed for one or more input files.'
    }
    if ($validationErrors.Count -eq 0) {
        try { Assert-CncGeometry -Documents $documents.ToArray() }
        catch {
            $message = "Geometry validation: $($_.Exception.Message)"
            $validationErrors.Add($message)
            Write-Host "  Error: $message" -ForegroundColor Red
            Write-Host "`nGeneration stopped; geometry check failed; folder B was not changed." -ForegroundColor Red
            throw 'Geometry safety validation failed.'
        }
    }
    foreach ($doc in $documents) {
        Write-Host "  Detected OptiCut format: $($doc.OptiCutFormat) ($($doc.File.Name))" -ForegroundColor DarkCyan
        Write-Host "  Verified $($doc.File.Name): parts $($doc.Stats.PartCount), dimension TEXT checked $($doc.Stats.DimensionCount), feature labels $($doc.Stats.FeatureCount), pairs $($doc.Stats.PairCount), grooves $($doc.Stats.GrooveCount), handle notches $($doc.Stats.HandleCount)" -ForegroundColor Green
        foreach ($mark in $doc.FeatureRecords) {
            $actionParts = [System.Collections.Generic.List[string]]::new()
            if ($mark.HasSH) { $actionParts.Add("Groove $($mark.GrooveEdge), offset $($mark.GrooveOffset) mm") }
            if ($mark.HasZ) { $actionParts.Add("Notch $($mark.Corner); edges $($mark.HandleEdges -join '+')") }
            $mapping = if ($mark.IsPair) { "$($mark.State)/$($mark.Role)" } else { "Standalone/$($mark.Shape.Orientation)" }
            Write-Host "    $($mark.Label) | Handle $($mark.Shape.Handle) | $($mark.Shape.Width)x$($mark.Shape.Height) | Table $($mark.Table) | $mapping | $($actionParts -join '; ')" -ForegroundColor DarkCyan
        }
    }
    Write-Host "`nAll input files validated successfully; starting in-memory generation." -ForegroundColor Green

    $generated = [System.Collections.Generic.List[object]]::new()
    foreach ($doc in $documents) {
        try { $generated.Add((Apply-DxfPlan $doc)) }
        catch { throw "Error preparing output for '$($doc.File.Name)'; no output files have been written yet. Details: $($_.Exception.Message)" }
    }
    if ($ValidateOnly) {
        $verifyFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('.dxf-verify-' + [guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path $verifyFolder)
            foreach ($item in $generated) {
                $verifyPath = Join-Path $verifyFolder $item.OutputName
                [System.IO.File]::WriteAllLines($verifyPath, $item.Lines, [System.Text.UTF8Encoding]::new($false))
                [void](Test-GeneratedDxf -File (Get-Item -LiteralPath $verifyPath) -Plan $item)
            }
        } finally {
            if (Test-Path -LiteralPath $verifyFolder) { Remove-Item -LiteralPath $verifyFolder -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Write-Host "`nValidation, in-memory generation, and DXF round-trip verification succeeded; no files were written to B because ValidateOnly was specified." -ForegroundColor Green
        foreach ($item in $generated) { Write-Host "  $($item.Source.Name): handle notches $($item.NotchCount), groove lines $($item.SlotCount), DXF round-trip verification: passed" -ForegroundColor Green }
        return
    }

    # Before writing a new batch, clear ALL previous contents of B (including subfolders).
    # This intentionally runs only in normal mode, never with -ValidateOnly.
    $inputAbsolute = [System.IO.Path]::GetFullPath($sourceFolder).TrimEnd([char[]]@('\','/'))
    $outputAbsolute = [System.IO.Path]::GetFullPath($outputFolder).TrimEnd([char[]]@('\','/'))
    $desktopAbsolute = [System.IO.Path]::GetFullPath($desktop).TrimEnd([char[]]@('\','/'))
    if ($outputAbsolute -ieq $inputAbsolute -or $outputAbsolute -ieq $desktopAbsolute) {
        throw 'Unsafe output path: refusing to clear the input folder or Desktop.'
    }
    if (-not (Test-Path -LiteralPath $outputFolder -PathType Container)) { [void](New-Item -ItemType Directory -Path $outputFolder) }
    $previousItems = @(Get-ChildItem -LiteralPath $outputFolder -Force)
    if ($previousItems.Count -gt 0) {
        Write-Host "`nClearing folder B: $($previousItems.Count) old item(s)..." -ForegroundColor Yellow
        foreach ($previousItem in $previousItems) {
            Remove-Item -LiteralPath $previousItem.FullName -Recurse -Force -ErrorAction Stop
        }
    }

    # Stage every output before replacing anything. If commit fails, backups are restored.
    $token = [guid]::NewGuid().ToString('N')
    $stageFolder = Join-Path $outputFolder ".dxf-stage-$token"
    $backupFolder = Join-Path $outputFolder ".dxf-backup-$token"
    [void](New-Item -ItemType Directory -Path $stageFolder)
    [void](New-Item -ItemType Directory -Path $backupFolder)
    $backedUp = [System.Collections.Generic.List[string]]::new(); $installed = [System.Collections.Generic.List[string]]::new(); $preserveBackup = $false
    try {
        foreach ($item in $generated) {
            $stagePath = Join-Path $stageFolder $item.OutputName
            [System.IO.File]::WriteAllLines($stagePath, $item.Lines, [System.Text.UTF8Encoding]::new($false))
        }
        foreach ($item in $generated) {
            $stagePath = Join-Path $stageFolder $item.OutputName
            [void](Test-GeneratedDxf -File (Get-Item -LiteralPath $stagePath) -Plan $item)
        }
        foreach ($item in $generated) {
            $target = Join-Path $outputFolder $item.OutputName
            $backup = Join-Path $backupFolder $item.OutputName
            if (Test-Path -LiteralPath $target -PathType Leaf) { [System.IO.File]::Move($target, $backup); $backedUp.Add($target) }
            [System.IO.File]::Move((Join-Path $stageFolder $item.OutputName), $target)
            $installed.Add($target)
        }
    } catch {
        $commitError = $_.Exception.Message
        foreach ($target in $installed) { if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue } }
        foreach ($target in $backedUp) {
            $backup = Join-Path $backupFolder ([System.IO.Path]::GetFileName($target))
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                try { [System.IO.File]::Move($backup, $target) }
                catch { $preserveBackup = $true; Write-Host "Automatic restore failed; backup preserved at: $backupFolder" -ForegroundColor Red }
            }
        }
        throw "Failed to write output files; previous outputs were restored or backups were preserved for manual recovery. Details: $commitError"
    } finally {
        if (Test-Path -LiteralPath $stageFolder) { Remove-Item -LiteralPath $stageFolder -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $preserveBackup -and (Test-Path -LiteralPath $backupFolder)) { Remove-Item -LiteralPath $backupFolder -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "`n=== Generation Successful ===" -ForegroundColor Green
    foreach ($item in $generated) {
        Write-Host "  $($item.Source.Name) -> $(Join-Path $outputFolder $item.OutputName) | Parts: $($item.Stats.PartCount) | Handle notches: $($item.NotchCount) | Groove lines: $($item.SlotCount)" -ForegroundColor Green
    }
    Write-Host 'Input files in A were not modified. The OptiCut TXT output is also unchanged.' -ForegroundColor Green
    Write-Host ''
} catch {
    Write-Host "`nStopped: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

}
