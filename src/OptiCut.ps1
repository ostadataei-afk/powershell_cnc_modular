function Test-TextInsidePart {
    param([object]$Text, [object]$Shape)
    $epsilon = 0.05 # millimetres; original v4.1 tolerance
    return ([math]::Abs([double]$Shape.MinX - [double]$Text.X) -lt $epsilon -and [double]$Text.Y -gt ([double]$Shape.MinY + 1) -and [double]$Text.Y -lt ([double]$Shape.MaxY - 1))
}

function Get-OptiCutFormat {
    param([object]$Document)
    $panel = @($Document.Entities | Where-Object { $_.Type -eq 'LWPOLYLINE' -and (Get-FirstValue $_ 8) -ieq 'Panel' })
    $pieces = @($Document.Entities | Where-Object { $_.Type -eq 'LWPOLYLINE' -and (Get-FirstValue $_ 8) -ieq 'Parts' })
    if (($panel.Count -gt 0) -xor ($pieces.Count -gt 0)) {
        throw "Incomplete layered OptiCut format in '$($Document.File.Name)': both Panel and Parts outline layers must be present."
    }
    if ($panel.Count -gt 0) { return 'Layered' }
    # If it has layered-only geometry but no valid Panel/Parts pair, reject it
    # rather than mistaking an off-cut for a legacy stock sheet.
    $foreignOutlines = @($Document.Entities | Where-Object {
        $_.Type -eq 'LWPOLYLINE' -and (Get-FirstValue $_ 8) -in @('Off-Cuts','Panel','Parts')
    })
    if ($foreignOutlines.Count -gt 0) {
        throw "Incomplete OptiCut layer layout in '$($Document.File.Name)'."
    }
    return 'Legacy'
}

function Test-TextAtPartCenter {
    param([object]$Text,[object]$Shape)
    $epsilon = 0.05 # millimetres; original v4.1 tolerance
    if ($null -eq $Text.X -or $null -eq $Text.Y) { return $false }
    # First require an unambiguous containment, then a central insertion point.
    $x = [double]$Text.X; $y = [double]$Text.Y
    if ($x -le ($Shape.MinX + $epsilon) -or $x -ge ($Shape.MaxX - $epsilon) -or
        $y -le ($Shape.MinY + $epsilon) -or $y -ge ($Shape.MaxY - $epsilon)) { return $false }
    $centerX = ([double]$Shape.MinX + [double]$Shape.MaxX) / 2.0
    $centerY = ([double]$Shape.MinY + [double]$Shape.MaxY) / 2.0
    # OptiCut centers its TEXT insertion exactly; permit a small 5% region
    # for minor exporter drift, without using a fixed sheet/part dimension.
    $marginX = [math]::Max($epsilon, [double]$Shape.Width * 0.05)
    $marginY = [math]::Max($epsilon, [double]$Shape.Height * 0.05)
    return ([math]::Abs($x - $centerX) -le $marginX -and
            [math]::Abs($y - $centerY) -le $marginY)
}

function Build-DxfPlan {
    param([object]$Document)
    $sizeTolerance = 0.1 # millimetres; original v4.1 tolerance
    $format = Get-OptiCutFormat -Document $Document
    $Document | Add-Member -NotePropertyName OptiCutFormat -NotePropertyValue $format -Force
    $texts = Get-TextRecords $Document
    $rectangles = [System.Collections.Generic.List[object]]::new()
    foreach ($entity in $Document.Entities) {
        if ($entity.Type -ne 'LWPOLYLINE') { continue }
        $layer = Get-FirstValue $entity 8
        if ($format -eq 'Layered' -and $layer -notin @('Panel','Parts')) { continue }
        $points = Get-EntityVertices $entity
        if ($points.Count -lt 2) { continue }
        $bounds = Get-EntityBounds $points
        if ($format -eq 'Legacy') {
            # Preserve the stage-2 threshold and legacy sheet order behavior.
            if ($bounds.Width -lt 100 -or $bounds.Height -lt 100) { continue }
        } elseif ($bounds.Width -le 0 -or $bounds.Height -le 0) {
            throw "Layered OptiCut outline '$((Get-FirstValue $entity 5))' has a zero-sized bounding box."
        }
        $closed = Get-FirstValue $entity 70
        if ($null -eq $closed -or (([int]$closed -band 1) -eq 0)) {
            throw "Candidate outline handle '$((Get-FirstValue $entity 5))' is not a closed polyline."
        }
        if (-not (Test-RectangleVertices -Points $points -Bounds $bounds)) {
            throw "Candidate outline handle '$((Get-FirstValue $entity 5))' is not a plain axis-aligned four-corner rectangle."
        }
        $rectangles.Add([pscustomobject]@{
            Entity = $entity; Handle = (Get-FirstValue $entity 5)
            Points = $points; Layer = $layer
            MinX = $bounds.MinX; MaxX = $bounds.MaxX
            MinY = $bounds.MinY; MaxY = $bounds.MaxY
            Width = [double]$bounds.Width; Height = [double]$bounds.Height
        })
    }
    $stockHandles = [System.Collections.Generic.HashSet[string]]::new()
    if ($format -eq 'Layered') {
        $sheets = @($rectangles | Where-Object { $_.Layer -ieq 'Panel' })
        if ($sheets.Count -ne 1) {
            throw "Layered OptiCut file must contain exactly one rectangular Panel outline; found $($sheets.Count)."
        }
        $sheet = $sheets[0]
        $partRects = @($rectangles | Where-Object { $_.Layer -ieq 'Parts' })
        if ($partRects.Count -eq 0) { throw 'Layered OptiCut file has no rectangular Parts outlines.' }
        # Do not infer a sheet from overall bounds or from entity order.
        [void]$stockHandles.Add([string]$sheet.Handle)
        Write-Host "  OptiCut layered: Panel handle $($sheet.Handle), $($partRects.Count) Parts outlines (off-cuts ignored)." -ForegroundColor DarkCyan
    } else {
        # Stage-2 legacy rule is intentionally unchanged.
        if ($rectangles.Count -lt 2) {
            throw 'Expected stock sheet followed by at least one part rectangle; fewer than two rectangular outlines found.'
        }
        $sheet = $rectangles[0]
        [void]$stockHandles.Add([string]$sheet.Handle)
        Write-Host "  OptiCut legacy: first rectangle is sheet handle $($sheet.Handle), $($sheet.Width)x$($sheet.Height) mm." -ForegroundColor DarkCyan
    }
    $Document | Add-Member -NotePropertyName StockSheet -NotePropertyValue $sheet -Force
    $parts = [System.Collections.Generic.List[object]]::new()
    foreach ($rect in $rectangles) {
        if ($stockHandles.Contains([string]$rect.Handle)) { continue }
        if ($format -eq 'Layered' -and $rect.Layer -ine 'Parts') { continue }
        $parts.Add([pscustomobject]@{
            Id = $parts.Count; Entity = $rect.Entity; Handle = $rect.Handle
            Points = $rect.Points; MinX = $rect.MinX; MaxX = $rect.MaxX
            MinY = $rect.MinY; MaxY = $rect.MaxY
            Width = $rect.Width; Height = $rect.Height
            DimensionText = $null; FeatureLabel = $null; Orientation = $null
        })
    }
    if ($parts.Count -eq 0) { throw "No part outlines were detected for OptiCut format '$format'." }
    $dimensionTexts = @($texts | Where-Object { $null -ne $_.Dimension })
    if ($format -eq 'Legacy') {
        # Exact stage-2 left-edge dimension matching: both position AND size.
        foreach ($part in $parts) {
            $positionMatches = @($dimensionTexts | Where-Object { Test-TextInsidePart -Text $_ -Shape $part })
            $matches = @($positionMatches | Where-Object {
                $dim = $_.Dimension
                ([math]::Abs($dim.Width - $part.Width) -lt $sizeTolerance -and [math]::Abs($dim.Height - $part.Height) -lt $sizeTolerance) -or
                ([math]::Abs($dim.Width - $part.Height) -lt $sizeTolerance -and [math]::Abs($dim.Height - $part.Width) -lt $sizeTolerance)
            })
            if ($matches.Count -ne 1) { throw "Part handle '$($part.Handle)' ($($part.Width)x$($part.Height) mm) has $($matches.Count) dimension TEXT entities matching BOTH its location and actual dimensions; exactly one is required (nearby dimension labels: $($positionMatches.Count))." }
            $part.DimensionText = $matches[0]
        }
        $reusedDimensions = @($parts | Group-Object -Property { $_.DimensionText.EntityIndex } | Where-Object { $_.Count -gt 1 })
        if ($reusedDimensions.Count -gt 0) { throw 'A dimension TEXT was assigned to multiple part outlines; geometry is ambiguous.' }
    }
    # Layered format derives width/height from rectangular outlines, because
    # these OptiCut exports have NO corresponding dimension TEXT entities.
    $featureTexts = @($texts | Where-Object { $_.IsFeature })
    foreach ($text in $featureTexts) {
        $matches = if ($format -eq 'Layered') {
            @($parts | Where-Object { Test-TextAtPartCenter -Text $text -Shape $_ })
        } else {
            @($parts | Where-Object { Test-TextInsidePart -Text $text -Shape $_ })
        }
        if ($matches.Count -ne 1) {
            throw "Feature label '$($text.Value)' at ($($text.X),$($text.Y)) matches $($matches.Count) parts in OptiCut $format format; exactly one is required."
        }
        $text.Shape = $matches[0]
        if ($null -eq $text.Shape.Orientation) { $text.Shape.Orientation = Get-Orientation $text.Shape }
        if ($null -ne $text.Shape.FeatureLabel) {
            throw "Part handle '$($text.Shape.Handle)' has more than one feature label ('$($text.Shape.FeatureLabel)' and '$($text.Value)')."
        }
        $text.Shape.FeatureLabel = $text.Value
    }
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($text in $featureTexts) {
        $parameters = $text.Parameters
        $zParameters = $text.Parameters
        $hasSH = [bool]$text.HasSH; $hasZ = [bool]$text.HasZ
        if ($hasSH -and $parameters.GrooveOffset -le 0) { throw "Label '$($text.Value)' has invalid groove offset $($parameters.GrooveOffset) mm; offset must be positive." }
        if ($hasSH -and $parameters.GrooveOffset -ge [math]::Min($text.Shape.Width, $text.Shape.Height)) { throw "Label '$($text.Value)': groove offset $($parameters.GrooveOffset) mm must be smaller than the part's short dimension $([math]::Min($text.Shape.Width,$text.Shape.Height)) mm (part $($text.Shape.Width)x$($text.Shape.Height))." }
        $table = Get-TableNumber -Prefix $parameters.Prefix -Shape $text.Shape -Label $text.Value
        if ($hasZ) { Assert-ZNotchFitsPart -Shape $text.Shape -Label $text.Value -ZParameters $zParameters -Table $table }
        $records.Add([pscustomobject]@{ Label = $text.Value; Text = $text; Shape = $text.Shape; HasSH = $hasSH; HasZ = $hasZ; GrooveOffset = [double]$parameters.GrooveOffset; Prefix = $parameters.Prefix; NotchLongLength = [double]$zParameters.LongLength; NotchShortLength = [double]$zParameters.ShortLength; Table = $table; Role = $null; State = $null; GrooveEdge = $null; HandleEdges = @(); Corner = $null; IsPair = $false })
    }
    # SH+Z pairs are resolved across all source DXF files after every file is parsed.
    # SH-only and Z-only parts remain independent, using the original standalone rule.
    foreach ($record in $records) {
        if ($record.HasSH -and $record.HasZ) { continue }
        # Standalone SH-only or Z-only parts use the R row and their own orientation on both sides.
        $record.Role = 'R'; $record.State = Get-SymmetryState -FirstOrientation $record.Shape.Orientation -SecondOrientation $record.Shape.Orientation
        $rule = Get-TableRule -Table $record.Table -State $record.State -Role $record.Role
        $record.GrooveEdge = $rule.Groove; $record.HandleEdges = @($rule.Handles); $record.Corner = $rule.Corner
    }
    $Document.Parts = $parts.ToArray(); $Document.FeatureRecords = $records.ToArray()
    $Document.Stats = [pscustomobject]@{ PartCount = $parts.Count; DimensionCount = $(if ($format -eq 'Legacy') { $parts.Count } else { 0 }); FeatureCount = $records.Count; PairCount = 0; GrooveCount = @($records | Where-Object { $_.HasSH }).Count; HandleCount = @($records | Where-Object { $_.HasZ }).Count }
    return $Document
}
