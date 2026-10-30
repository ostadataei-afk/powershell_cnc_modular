function Get-EntityBounds {
    param([object[]]$Points)
    if ($Points.Count -lt 2) { throw 'A polyline has fewer than two readable vertices.' }
    $xs = @($Points | ForEach-Object { [double]$_.X })
    $ys = @($Points | ForEach-Object { [double]$_.Y })
    $minX = [double](($xs | Measure-Object -Minimum).Minimum)
    $maxX = [double](($xs | Measure-Object -Maximum).Maximum)
    $minY = [double](($ys | Measure-Object -Minimum).Minimum)
    $maxY = [double](($ys | Measure-Object -Maximum).Maximum)
    [pscustomobject]@{ MinX = $minX; MaxX = $maxX; MinY = $minY; MaxY = $maxY; Width = ($maxX - $minX); Height = ($maxY - $minY) }
}

function Test-RectangleVertices {
    param([object[]]$Points, [object]$Bounds)
    if ($Points.Count -ne 4) { return $false }
    $corners = @{}
    foreach ($point in $Points) {
        $atLeft = [math]::Abs([double]$point.X - $Bounds.MinX) -lt 0.001
        $atRight = [math]::Abs([double]$point.X - $Bounds.MaxX) -lt 0.001
        $atBottom = [math]::Abs([double]$point.Y - $Bounds.MinY) -lt 0.001
        $atTop = [math]::Abs([double]$point.Y - $Bounds.MaxY) -lt 0.001
        if (-not ($atLeft -or $atRight) -or -not ($atBottom -or $atTop)) { return $false }
        $key = ('{0}|{1}' -f $(if ($atLeft) {'L'} else {'R'}), $(if ($atBottom) {'B'} else {'T'}))
        if ($corners.ContainsKey($key)) { return $false }
        $corners[$key] = $true
    }
    for ($i = 0; $i -lt 4; $i++) {
        $a = $Points[$i]
        $b = $Points[($i + 1) % 4]
        $dx = [math]::Abs([double]$a.X - [double]$b.X)
        $dy = [math]::Abs([double]$a.Y - [double]$b.Y)
        if (($dx -lt 0.001 -and $dy -lt 0.001) -or ($dx -ge 0.001 -and $dy -ge 0.001)) { return $false }
    }
    return ($corners.Count -eq 4)
}

function Get-NotchedVertices {
    param([object]$Shape, [string]$Corner, [double]$LongLength, [double]$ShortLength, [int]$Table = 2)
    # Corner convention: A=upper-left, B=upper-right, C=lower-right, D=lower-left.
    # Table 2: long notch length follows the longer dimension; short notch length follows the shorter dimension.
    # Table 1: long notch length follows the shorter dimension; short notch length follows the longer dimension.
    if ($Table -notin @(1,2)) { throw "Unsupported handle-notch table '$Table'." }
    $horizontalGetsLong = if ($Table -eq 1) { [double]$Shape.Width -lt [double]$Shape.Height } else { [double]$Shape.Width -gt [double]$Shape.Height }
    $verticalGetsLong = if ($Table -eq 1) { [double]$Shape.Height -lt [double]$Shape.Width } else { [double]$Shape.Height -gt [double]$Shape.Width }
    $a = [pscustomobject]@{ Name = 'A'; X = [double]$Shape.MinX; Y = [double]$Shape.MaxY }
    $b = [pscustomobject]@{ Name = 'B'; X = [double]$Shape.MaxX; Y = [double]$Shape.MaxY }
    $c = [pscustomobject]@{ Name = 'C'; X = [double]$Shape.MaxX; Y = [double]$Shape.MinY }
    $d = [pscustomobject]@{ Name = 'D'; X = [double]$Shape.MinX; Y = [double]$Shape.MinY }
    $base = @($a,$b,$c,$d); $result = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt 4; $i++) {
        $v = $base[$i]
        if ($v.Name -ne $Corner) { $result.Add([pscustomobject]@{ X = $v.X; Y = $v.Y }); continue }
        $prev = $base[($i + 3) % 4]; $next = $base[($i + 1) % 4]
        $prevDx = [double]$prev.X - [double]$v.X; $prevDy = [double]$prev.Y - [double]$v.Y
        $nextDx = [double]$next.X - [double]$v.X; $nextDy = [double]$next.Y - [double]$v.Y
        $prevOffset = if ([math]::Abs($prevDx) -gt 0) { if ($horizontalGetsLong) { $LongLength } else { $ShortLength } } else { if ($verticalGetsLong) { $LongLength } else { $ShortLength } }
        $nextOffset = if ([math]::Abs($nextDx) -gt 0) { if ($horizontalGetsLong) { $LongLength } else { $ShortLength } } else { if ($verticalGetsLong) { $LongLength } else { $ShortLength } }
        $prevScale = if ([math]::Abs($prevDx) -gt 0) { [math]::Sign($prevDx) } else { [math]::Sign($prevDy) }
        $nextScale = if ([math]::Abs($nextDx) -gt 0) { [math]::Sign($nextDx) } else { [math]::Sign($nextDy) }
        if ([math]::Abs($prevDx) -gt 0) { $p1x = $v.X + $prevScale * $prevOffset; $p1y = $v.Y } else { $p1x = $v.X; $p1y = $v.Y + $prevScale * $prevOffset }
        if ([math]::Abs($nextDx) -gt 0) { $p3x = $v.X + $nextScale * $nextOffset; $p3y = $v.Y } else { $p3x = $v.X; $p3y = $v.Y + $nextScale * $nextOffset }
        $result.Add([pscustomobject]@{ X = [double]$p1x; Y = [double]$p1y })
        $result.Add([pscustomobject]@{ X = [double]($p1x + $p3x - $v.X); Y = [double]($p1y + $p3y - $v.Y) })
        $result.Add([pscustomobject]@{ X = [double]$p3x; Y = [double]$p3y })
    }
    return ,$result.ToArray()
}

function ConvertTo-DxfGridNumber {
    param([double]$Value)
    # Output coordinates are serialized to three decimals by ConvertTo-DxfNumber.
    return (ConvertFrom-DxfNumber (ConvertTo-DxfNumber $Value))
}

function Assert-CncGeometry {
    param([object[]]$Documents)
    $epsilon = 0.05 # millimetres; original v4.1 tolerance
    $gridTolerance = 0.0005
    foreach ($document in $Documents) {
        $sheet = $document.StockSheet
        if ($null -eq $sheet) { throw "File '$($document.File.Name)': stock sheet is missing." }
        $parts = @($document.Parts)
        # First-rectangle convention stays unchanged. Reject wrong ordering
        # when the presumed sheet does not enclose all part outlines.
        foreach ($part in $parts) {
            if ($part.MinX -lt ($sheet.MinX - $epsilon) -or
                $part.MaxX -gt ($sheet.MaxX + $epsilon) -or
                $part.MinY -lt ($sheet.MinY - $epsilon) -or
                $part.MaxY -gt ($sheet.MaxY + $epsilon)) {
                throw "File '$($document.File.Name)': first rectangle (handle $($sheet.Handle)) does not contain part handle $($part.Handle). Check DXF entity ordering; the first rectangle must be the stock sheet."
            }
        }
        # Adjacent pieces may share a border; overlapping interiors cannot
        # safely represent separate CNC pieces.
        for ($i = 0; $i -lt $parts.Count; $i++) {
            for ($j = $i + 1; $j -lt $parts.Count; $j++) {
                $first = $parts[$i]; $second = $parts[$j]
                $overlapX = [math]::Min($first.MaxX, $second.MaxX) - [math]::Max($first.MinX, $second.MinX)
                $overlapY = [math]::Min($first.MaxY, $second.MaxY) - [math]::Max($first.MinY, $second.MinY)
                if ($overlapX -gt $epsilon -and $overlapY -gt $epsilon) {
                    throw "File '$($document.File.Name)': overlapping part interiors (handles $($first.Handle) and $($second.Handle)); $overlapX x $overlapY mm overlap."
                }
            }
        }
        foreach ($record in $document.FeatureRecords) {
            $shape = $record.Shape
            $notchBox = $null
            if ($record.HasZ) {
                # Z size-to-part checks are already performed by stage 1.
                # Check the resulting SIX serialized outline vertices, including
                # very small decimal values that would round to zero.
                $notchPoints = Get-NotchedVertices -Shape $shape -Corner $record.Corner -LongLength $record.NotchLongLength -ShortLength $record.NotchShortLength -Table $record.Table
                if ($notchPoints.Count -ne 6) { throw "Label '$($record.Label)': expected six vertices after Z notch." }
                $rounded = @($notchPoints | ForEach-Object {
                    [pscustomobject]@{ X = (ConvertTo-DxfGridNumber ([double]$_.X)); Y = (ConvertTo-DxfGridNumber ([double]$_.Y)) }
                })
                for ($i = 0; $i -lt $rounded.Count; $i++) {
                    $a = $rounded[$i]; $b = $rounded[($i + 1) % $rounded.Count]
                    $dx = [math]::Abs([double]$a.X - [double]$b.X)
                    $dy = [math]::Abs([double]$a.Y - [double]$b.Y)
                    if (($dx -le $gridTolerance -and $dy -le $gridTolerance) -or
                        ($dx -gt $gridTolerance -and $dy -gt $gridTolerance)) {
                        throw "Label '$($record.Label)': Z notch produces a degenerate or diagonal edge after DXF 0.001 mm coordinate rounding (part $($shape.Handle))."
                    }
                    if ($a.X -lt ($shape.MinX - $gridTolerance) -or $a.X -gt ($shape.MaxX + $gridTolerance) -or
                        $a.Y -lt ($shape.MinY - $gridTolerance) -or $a.Y -gt ($shape.MaxY + $gridTolerance)) {
                        throw "Label '$($record.Label)': Z notch vertex outside part $($shape.Handle)."
                    }
                }
                # The new interior (concave) vertex is the only point strictly
                # inside the original rectangle. It defines the removed corner box.
                $innerPoints = @($rounded | Where-Object {
                    $_.X -gt ($shape.MinX + $gridTolerance) -and $_.X -lt ($shape.MaxX - $gridTolerance) -and
                    $_.Y -gt ($shape.MinY + $gridTolerance) -and $_.Y -lt ($shape.MaxY - $gridTolerance)
                })
                if ($innerPoints.Count -ne 1) {
                    throw "Label '$($record.Label)': Z corner is ambiguous after coordinate rounding (part $($shape.Handle))."
                }
                $cornerX = if ($record.Corner -in @('A','D')) { [double]$shape.MinX } else { [double]$shape.MaxX }
                $cornerY = if ($record.Corner -in @('A','B')) { [double]$shape.MaxY } else { [double]$shape.MinY }
                $notchBox = [pscustomobject]@{
                    MinX = [math]::Min($cornerX,[double]$innerPoints[0].X)
                    MaxX = [math]::Max($cornerX,[double]$innerPoints[0].X)
                    MinY = [math]::Min($cornerY,[double]$innerPoints[0].Y)
                    MaxY = [math]::Max($cornerY,[double]$innerPoints[0].Y)
                }
            }
            if ($record.HasSH) {
                # Use the original slot-line creator so this safety check
                # follows the unchanged table/edge calculations exactly.
                $line = New-SlotLineEntity -Handle '0' -Edge $record.GrooveEdge -Shape $shape -Offset $record.GrooveOffset
                $x1 = ConvertFrom-DxfNumber (Get-FirstValue $line 10)
                $y1 = ConvertFrom-DxfNumber (Get-FirstValue $line 20)
                $x2 = ConvertFrom-DxfNumber (Get-FirstValue $line 11)
                $y2 = ConvertFrom-DxfNumber (Get-FirstValue $line 21)
                $horizontal = ([math]::Abs($y1 - $y2) -le $gridTolerance)
                $vertical = ([math]::Abs($x1 - $x2) -le $gridTolerance)
                if ($horizontal -eq $vertical) {
                    throw "Label '$($record.Label)': SH slot is diagonal or zero length after serialization."
                }
                if ($horizontal) {
                    if ($y1 -le ($shape.MinY + $gridTolerance) -or $y1 -ge ($shape.MaxY - $gridTolerance) -or
                        [math]::Abs($x1 - $x2) -le $gridTolerance) {
                        throw "Label '$($record.Label)': SH slot lies on/outside the original part border after rounding."
                    }
                } else {
                    if ($x1 -le ($shape.MinX + $gridTolerance) -or $x1 -ge ($shape.MaxX - $gridTolerance) -or
                        [math]::Abs($y1 - $y2) -le $gridTolerance) {
                        throw "Label '$($record.Label)': SH slot lies on/outside the original part border after rounding."
                    }
                }
                if ($null -ne $notchBox) {
                    # The groove spans the full part; if its inset coordinate
                    # crosses the removed Z-corner box, part of it is in void.
                    # Boundary contact is conservatively rejected as ambiguous.
                    $touchesRemovedCorner = if ($horizontal) {
                        ($y1 -ge ($notchBox.MinY - $gridTolerance) -and $y1 -le ($notchBox.MaxY + $gridTolerance))
                    } else {
                        ($x1 -ge ($notchBox.MinX - $gridTolerance) -and $x1 -le ($notchBox.MaxX + $gridTolerance))
                    }
                    if ($touchesRemovedCorner) {
                        throw "Label '$($record.Label)': SH groove ($($record.GrooveEdge), offset $($record.GrooveOffset)) crosses or touches the material removed by Z notch at corner $($record.Corner) on part $($shape.Handle)."
                    }
                }
            }
        }
        Write-Host "  Geometry safe: sheet containment, part overlap, SH/Z bounds and groove/notch conflicts checked ($($document.File.Name))." -ForegroundColor DarkGreen
    }
}
