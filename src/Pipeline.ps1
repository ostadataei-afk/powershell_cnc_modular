# File-system independent orchestration: callers supply parsed documents.
function New-CncBatchPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Documents)
    $planned = @($Documents | ForEach-Object { Build-DxfPlan -Document $_ })
    Resolve-GlobalPairs -Documents $planned
    Assert-CncGeometry -Documents $planned
    return ,$planned
}

function ConvertTo-CncOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Documents)
    # Apply-DxfPlan mutates the supplied plans. Use fresh plans for each run.
    return ,@($Documents | ForEach-Object { Apply-DxfPlan -Document $_ })
}

function ConvertTo-CncPlanContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Documents)
    # A detached, JSON-safe projection; no FileInfo, DXF entities or shared references.
    [pscustomobject]@{
        schemaVersion = 1
        units = 'mm'
        files = @($Documents | ForEach-Object {
            $doc = $_
            [pscustomobject]@{
                name = $doc.File.Name
                format = $doc.OptiCutFormat
                operations = @($doc.FeatureRecords | ForEach-Object {
                    [pscustomobject]@{
                        handle = [string]$_.Shape.Handle
                        label = [string]$_.Label
                        bounds = [pscustomobject]@{ minX = [double]$_.Shape.MinX; minY = [double]$_.Shape.MinY; maxX = [double]$_.Shape.MaxX; maxY = [double]$_.Shape.MaxY }
                        table = [int]$_.Table
                        role = $_.Role
                        state = $_.State
                        groove = $(if ($_.HasSH) { [pscustomobject]@{ edge = $_.GrooveEdge; offset = [double]$_.GrooveOffset } } else { $null })
                        notch = $(if ($_.HasZ) { [pscustomobject]@{ corner = $_.Corner; longLength = [double]$_.NotchLongLength; shortLength = [double]$_.NotchShortLength } } else { $null })
                    }
                })
            }
        })
    }
}
