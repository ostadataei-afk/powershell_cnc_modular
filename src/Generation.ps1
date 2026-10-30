function Apply-DxfPlan {
    param([object]$Document)
    [uint64]$nextHandle = Get-NextHandle $Document.Pairs
    $layer2Exists = Test-LayerExists -Pairs $Document.Pairs -Name '2'
    $layerHandle = $null
    if (-not $layer2Exists) { $layerHandle = $nextHandle.ToString('X'); $nextHandle++ }
    $sourceEntityCount = $Document.Entities.Count
    $sourceEntityHandles = @($Document.Entities | ForEach-Object { Get-FirstValue $_ 5 } | Where-Object { $null -ne $_ -and $_ -ne '' })
    $notchCount = 0; $slotCount = 0
    $slotEntities = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Document.FeatureRecords) {
        if ($record.HasZ) {
            $newPoints = Get-NotchedVertices -Shape $record.Shape -Corner $record.Corner -LongLength $record.NotchLongLength -ShortLength $record.NotchShortLength -Table $record.Table
            if ($newPoints.Count -ne 6) { throw "Handle notch for label '$($record.Label)' did not produce exactly six outline vertices." }
            Set-PolylineVertices -Entity $record.Shape.Entity -Points $newPoints
            $notchCount++
        }
        if ($record.HasSH) {
            $handle = $nextHandle.ToString('X'); $nextHandle++
            $slotEntity = New-SlotLineEntity -Handle $handle -Edge $record.GrooveEdge -Shape $record.Shape -Offset $record.GrooveOffset
            $Document.Entities.Add($slotEntity)
            $slotEntities.Add($slotEntity)
            $slotCount++
        }
    }
    $finalPairs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Document.EntityBodyStart; $i++) { $finalPairs.Add($Document.Pairs[$i]) }
    foreach ($entity in $Document.Entities) { foreach ($pair in $entity.Pairs) { $finalPairs.Add($pair) } }
    for ($i = $Document.EntityBodyEnd; $i -lt $Document.Pairs.Count; $i++) { $finalPairs.Add($Document.Pairs[$i]) }
    if (-not $layer2Exists) { Add-Layer2 -Pairs $finalPairs -Handle $layerHandle }
    Update-Handseed -Pairs $finalPairs -NextHandle $nextHandle
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in $finalPairs) { $lines.Add([string]$pair.CodeText); $lines.Add([string]$pair.Value) }
    return [pscustomobject]@{ Source = $Document.File; OutputName = $Document.File.Name; Lines = $lines.ToArray(); NotchCount = $notchCount; SlotCount = $slotCount; Stats = $Document.Stats; Document = $Document; SourceEntityCount = $sourceEntityCount; SourceEntityHandles = $sourceEntityHandles; SlotEntities = $slotEntities.ToArray() }
}

function Test-GeneratedDxf {
    param([System.IO.FileInfo]$File, [object]$Plan)
    $parsed = Read-DxfDocument $File
    $expectedCount = [int]$Plan.SourceEntityCount + [int]$Plan.SlotCount
    if ($parsed.Entities.Count -ne $expectedCount) { throw "Round-trip verification failed for '$($File.Name)': expected $expectedCount entities, found $($parsed.Entities.Count)." }
    if (-not (Test-LayerExists -Pairs $parsed.Pairs -Name '2')) { throw "Round-trip verification failed for '$($File.Name)': DXF layer 2 is missing." }
    foreach ($handle in $Plan.SourceEntityHandles) {
        $matches = @($parsed.Entities | Where-Object { (Get-FirstValue $_ 5) -eq $handle })
        if ($matches.Count -ne 1) { throw "Round-trip verification failed for '$($File.Name)': source handle '$handle' appears $($matches.Count) times." }
    }
    foreach ($record in $Plan.Document.FeatureRecords) {
        $handle = [string]$record.Shape.Handle
        $matches = @($parsed.Entities | Where-Object { (Get-FirstValue $_ 5) -eq $handle })
        if ($matches.Count -ne 1 -or $matches[0].Type -ne 'LWPOLYLINE') { throw "Round-trip verification failed for label '$($record.Label)': outline handle '$handle' is missing or duplicated." }
        $expectedPoints = Get-EntityVertices $record.Shape.Entity
        $actualPoints = Get-EntityVertices $matches[0]
        if ($expectedPoints.Count -ne $actualPoints.Count) { throw "Round-trip verification failed for label '$($record.Label)': outline vertex count changed." }
        for ($i = 0; $i -lt $expectedPoints.Count; $i++) {
            if ([math]::Abs([double]$expectedPoints[$i].X - [double]$actualPoints[$i].X) -gt 0.001 -or [math]::Abs([double]$expectedPoints[$i].Y - [double]$actualPoints[$i].Y) -gt 0.001) { throw "Round-trip verification failed for label '$($record.Label)' at outline vertex $($i + 1)." }
        }
        $actualBounds = Get-EntityBounds $actualPoints
        foreach ($field in @('MinX','MaxX','MinY','MaxY')) {
            if ([math]::Abs([double]$actualBounds.$field - [double]$record.Shape.$field) -gt 0.001) { throw "Round-trip verification failed for label '$($record.Label)': outline bounds changed ($field)." }
        }
        if ($record.HasZ -and $actualPoints.Count -ne 6) { throw "Round-trip verification failed for label '$($record.Label)': handle notch is not represented by six vertices." }
    }
    foreach ($expectedLine in $Plan.SlotEntities) {
        $handle = Get-FirstValue $expectedLine 5
        $matches = @($parsed.Entities | Where-Object { (Get-FirstValue $_ 5) -eq $handle })
        if ($matches.Count -ne 1 -or $matches[0].Type -ne 'LINE') { throw "Round-trip verification failed: groove line handle '$handle' is missing or duplicated." }
        if ((Get-FirstValue $matches[0] 8) -ne '2') { throw "Round-trip verification failed: groove line '$handle' is not on layer 2." }
        foreach ($code in @(10,20,30,11,21,31)) {
            $expectedValue = Get-FirstValue $expectedLine $code
            $actualValue = Get-FirstValue $matches[0] $code
            if ($null -eq $expectedValue -or $null -eq $actualValue) { throw "Round-trip verification failed: groove line '$handle' is missing coordinate code $code." }
            if ([math]::Abs((ConvertFrom-DxfNumber $expectedValue) - (ConvertFrom-DxfNumber $actualValue)) -gt 0.001) { throw "Round-trip verification failed: groove line '$handle' coordinate code $code changed." }
        }
    }
    return $true
}
