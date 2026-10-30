function Get-FilenamePairRole {
    param([string]$FileName)
    # Only standalone tokens count: R, L, Right, Left (case-insensitive).
    # Hyphens, underscores, spaces and parentheses are supported separators.
    # Words containing these letters (e.g. Drawer, Rail) must not set a role.
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $r = [regex]::IsMatch($stem, '(?i)(?:^|[^a-z0-9])(?:R|RIGHT)(?=$|[^a-z0-9])')
    $l = [regex]::IsMatch($stem, '(?i)(?:^|[^a-z0-9])(?:L|LEFT)(?=$|[^a-z0-9])')
    if ($r -and $l) { throw "File '$FileName' contains both R and L role markers; rename it unambiguously." }
    if ($r) { return 'R' }
    if ($l) { return 'L' }
    return $null
}

function Resolve-GlobalPairs {
    param([object[]]$Documents)
    # Documents arrive in the source-file name order (Sort-Object Name).
    # Within each file, preserve the original DXF TEXT entity order.
    $candidates = [System.Collections.Generic.List[object]]::new()
    for ($fileOrder = 0; $fileOrder -lt $Documents.Count; $fileOrder++) {
        $document = $Documents[$fileOrder]
        foreach ($record in $document.FeatureRecords) {
            if (-not ($record.HasSH -and $record.HasZ)) { continue }
            $candidates.Add([pscustomobject]@{
                Label = $record.Label
                Document = $document
                Record = $record
                FileOrder = $fileOrder
                EntityIndex = [int]$record.Text.EntityIndex
            })
        }
    }
    $pairGroups = @($candidates | Group-Object -Property Label)
    foreach ($group in $pairGroups) {
        if ($group.Count -ne 2) {
            $sources = (@($group.Group | ForEach-Object { $_.Document.File.Name }) -join ', ')
            throw "Label '$($group.Name)' contains SH and Z and must occur exactly twice across folder A; found $($group.Count) in file(s): $sources."
        }
        $members = @($group.Group | Sort-Object FileOrder, EntityIndex)
        # Original behavior is preserved when both TEXT labels are in one DXF:
        # smaller EntityIndex is R and larger EntityIndex is L.
        # For different files, explicit filename roles take precedence over name order.
        if (-not [object]::ReferenceEquals($members[0].Document, $members[1].Document)) {
            $role0 = Get-FilenamePairRole -FileName $members[0].Document.File.Name
            $role1 = Get-FilenamePairRole -FileName $members[1].Document.File.Name
            if ($null -ne $role0 -and $null -ne $role1 -and $role0 -eq $role1) {
                throw "Pair '$($group.Name)': both files claim role '$role0' ('$($members[0].Document.File.Name)' and '$($members[1].Document.File.Name)')."
            }
            # A single explicit marker determines the counterpart's opposite role.
            # With no explicit markers, use the existing alphabetical filename order.
            $swap = ($role0 -eq 'L') -or ($role1 -eq 'R')
            if ($swap) { $members = @($members[1], $members[0]) }
        }
        $first = $members[0].Record; $second = $members[1].Record
        if ([object]::ReferenceEquals($first.Shape, $second.Shape)) { throw "Pair label '$($group.Name)' resolves twice to the same part outline." }
        if ($first.Table -ne $second.Table) {
            throw "Pair '$($group.Name)' selects inconsistent tables in '$($members[0].Document.File.Name)' and '$($members[1].Document.File.Name)'."
        }
        $state = Get-SymmetryState -FirstOrientation $first.Shape.Orientation -SecondOrientation $second.Shape.Orientation
        Write-Host "  Pair '$($group.Name)': R $($members[0].Document.File.Name) [TEXT $($members[0].EntityIndex)] -> L $($members[1].Document.File.Name) [TEXT $($members[1].EntityIndex)] | $state" -ForegroundColor DarkCyan
        foreach ($index in 0,1) {
            $role = if ($index -eq 0) { 'R' } else { 'L' }
            $record = $members[$index].Record
            $rule = Get-TableRule -Table $record.Table -State $state -Role $role
            $record.Role = $role; $record.State = $state; $record.GrooveEdge = $rule.Groove; $record.HandleEdges = @($rule.Handles); $record.Corner = $rule.Corner; $record.IsPair = $true
        }
    }
    foreach ($document in $Documents) {
        $document.Stats.PairCount = @($document.FeatureRecords | Where-Object { $_.IsPair } | Group-Object -Property Label).Count
    }
}
