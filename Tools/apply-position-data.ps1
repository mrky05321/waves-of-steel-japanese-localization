[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DataRoot,
    [Parameter(Mandatory=$true)][System.Collections.IDictionary]$Catalog,
    [string[]]$DataFiles = @(),
    [string[]]$DataFields = @()
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$useWindowsPowerShellJson = $PSVersionTable.PSVersion.Major -lt 6
$legacyJsonDeserializer = $null
if ($useWindowsPowerShellJson) {
    Add-Type -AssemblyName System.Web.Extensions
    $legacyJsonDeserializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $legacyJsonDeserializer.MaxJsonLength = [int]::MaxValue
    $legacyJsonDeserializer.RecursionLimit = 512
}

function ConvertFrom-JsonCompat([string]$Json) {
    if ($useWindowsPowerShellJson) {
        $parsed = $legacyJsonDeserializer.DeserializeObject($Json)
    }
    else {
        $parsed = ConvertFrom-Json -InputObject $Json -AsHashtable
    }
    return $parsed
}
function Get-PositionHash([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    if ($PSVersionTable.PSVersion.Major -ge 6) { return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Write-PositionFile([string]$Path, [string]$Text) {
    $tempPath = "$Path.jp-tmp"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Text, $utf8NoBom)
        if ($PSVersionTable.PSVersion.Major -ge 6) { [System.IO.File]::Move($tempPath, $Path, $true) }
        elseif ([System.IO.File]::Exists($Path)) {
            $oldPath = "$Path.jp-backup-$([Guid]::NewGuid().ToString('N'))"
            try { [System.IO.File]::Replace($tempPath, $Path, $oldPath) }
            finally { if ([System.IO.File]::Exists($oldPath)) { [System.IO.File]::Delete($oldPath) } }
        }
        else { [System.IO.File]::Move($tempPath, $Path) }
    }
    finally { if ([System.IO.File]::Exists($tempPath)) { [System.IO.File]::Delete($tempPath) } }
}
function Get-PositionedValue([string]$Current, $Locator, [string]$Description) {
    $currentHash = Get-PositionHash $Current
    if ($currentHash -ceq [string]$Locator.targetSha256) { return [pscustomobject]@{ Value=$Current; Changed=$false } }
    if ($currentHash -cne [string]$Locator.sourceSha256) {
        throw "Position guard failed at $Description. The supported game data or this field has changed; no file was written."
    }
    $target = [string]$Locator.translation
    if ((Get-PositionHash $target) -cne [string]$Locator.targetSha256) { throw "Translation catalog hash is invalid at $Description." }
    return [pscustomobject]@{ Value=$target; Changed=($target -cne $Current) }
}
function Test-SelectedPositionField([string]$File, [string]$Field) {
    $qualifiedName = '{0}:{1}' -f $File, $Field
    if ($DataFields.Count -gt 0) { return $DataFields -contains $qualifiedName }
    if ($qualifiedName -eq 'CSV/ships.json:shipCategoryName') { return $false }
    return $true
}
function ConvertTo-JsonToken([string]$Text) {
    # Keep the token bytes stable across Windows PowerShell 5.1 and PowerShell 7.
    # The catalog hashes compact UTF-8 JSON tokens with non-ASCII characters left literal.
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        $codePoint = [int]$character
        if ($codePoint -eq 8) {
            [void]$builder.Append('\b')
        }
        elseif ($codePoint -eq 9) {
            [void]$builder.Append('\t')
        }
        elseif ($codePoint -eq 10) {
            [void]$builder.Append('\n')
        }
        elseif ($codePoint -eq 12) {
            [void]$builder.Append('\f')
        }
        elseif ($codePoint -eq 13) {
            [void]$builder.Append('\r')
        }
        elseif ($codePoint -eq 34) {
            [void]$builder.Append('\"')
        }
        elseif ($codePoint -eq 92) {
            [void]$builder.Append('\\')
        }
        elseif ($codePoint -lt 32) {
            [void]$builder.Append(('\u{0:x4}' -f $codePoint))
        }
        else {
            [void]$builder.Append($character)
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}
function Apply-MissionLineLocator([string[]]$Parts, $Locator, [string]$Description) {
    $lineIndex = [int]$Locator.lineIndex
    $partIndex = $lineIndex * 2
    if ($partIndex -lt 0 -or $partIndex -ge $Parts.Length) { throw "Mission position is outside the supported file at $Description." }
    $line = [string]$Parts[$partIndex]
    $property = [regex]::Escape([string]$Locator.field)
    $pattern = [regex]::new('(?<prefix>"' + $property + '"\s*:\s*)(?<token>"(?:\\.|[^"\\])*")')
    $matches = @($pattern.Matches($line))
    if ($matches.Count -ne 1) { throw "Mission field position is ambiguous at $Description." }
    $match = $matches[0]
    $token = [string]$match.Groups['token'].Value
    $tokenHash = Get-PositionHash $token
    if ($tokenHash -ceq [string]$Locator.targetTokenSha256) { return $false }
    if ($tokenHash -cne [string]$Locator.sourceTokenSha256) { throw "Mission position guard failed at $Description." }
    $targetToken = ConvertTo-JsonToken ([string]$Locator.translation)
    if ((Get-PositionHash $targetToken) -cne [string]$Locator.targetTokenSha256) { throw "Mission translation locator hash is invalid at $Description." }
    $Parts[$partIndex] = $line.Substring(0, $match.Groups['token'].Index) + $targetToken + $line.Substring($match.Groups['token'].Index + $match.Groups['token'].Length)
    return $true
}

$changedFiles = [System.Collections.Generic.List[string]]::new()
$jsonChanged = 0
foreach ($relativePath in $Catalog.dataFields.Keys) {
    if ($DataFiles.Count -gt 0 -and $relativePath -notin $DataFiles) { continue }
    $locators = @($Catalog.dataFields[$relativePath] | Where-Object { Test-SelectedPositionField $relativePath ([string]$_.field) })
    if ($locators.Count -eq 0) { continue }
    $targetPath = Join-Path $DataRoot ('StreamingAssets\' + $relativePath.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw "Positioned JSON target is missing: $targetPath" }
    $document = ConvertFrom-JsonCompat ([System.IO.File]::ReadAllText($targetPath, [System.Text.Encoding]::UTF8))
    $changedHere = 0
    foreach ($locator in $locators) {
        $rowIndex = [int]$locator.rowIndex
        if ($rowIndex -lt 0 -or $rowIndex -ge $document.Count) { throw "JSON row position is outside the supported file: $relativePath row $rowIndex" }
        $row = $document[$rowIndex]
        $field = [string]$locator.field
        if (-not $row.ContainsKey($field) -or $row[$field] -isnot [string]) { throw "JSON field position is missing or not text: $relativePath row $rowIndex field $field" }
        $result = Get-PositionedValue ([string]$row[$field]) $locator "$relativePath row $rowIndex field $field"
        if ($result.Changed) { $row[$field] = $result.Value; $changedHere++ }
    }
    if ($changedHere -gt 0) {
        $serialized = ConvertTo-Json -InputObject @($document) -Depth 100
        $verified = ConvertFrom-JsonCompat $serialized
        foreach ($locator in $locators) {
            if ((Get-PositionHash ([string]$verified[[int]$locator.rowIndex][[string]$locator.field])) -cne [string]$locator.targetSha256) {
                throw "Positioned JSON verification failed: $relativePath row $($locator.rowIndex) field $($locator.field)"
            }
        }
        Write-PositionFile $targetPath $serialized
        $jsonChanged += $changedHere
        $changedFiles.Add($relativePath)
    }
}

if ($DataFields.Count -eq 0) {
    foreach ($relativePath in $Catalog.singleColumnCsv.Keys) {
        if ($DataFiles.Count -gt 0 -and $relativePath -notin $DataFiles) { continue }
        $targetPath = Join-Path $DataRoot ('StreamingAssets\' + $relativePath.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw "Positioned CSV target is missing: $targetPath" }
        $records = @(Import-Csv -LiteralPath $targetPath -Header Value -Encoding UTF8)
        $locatorByRow = @{}
        foreach ($locator in $Catalog.singleColumnCsv[$relativePath]) { $locatorByRow[[string]$locator.rowIndex] = $locator }
        $lines = [System.Collections.Generic.List[string]]::new()
        $changedHere = 0
        for ($rowIndex = 0; $rowIndex -lt $records.Count; $rowIndex++) {
            $value = [string]$records[$rowIndex].Value
            if ($locatorByRow.ContainsKey([string]$rowIndex)) {
                $result = Get-PositionedValue $value $locatorByRow[[string]$rowIndex] "$relativePath row $rowIndex"
                if ($result.Changed) { $value = $result.Value; $changedHere++ }
            }
            if ($value.Contains('"') -or $value.Contains(',') -or $value.Contains("`r") -or $value.Contains("`n")) { $value = '"' + $value.Replace('"', '""') + '"' }
            $lines.Add($value)
        }
        if ($changedHere -gt 0) { Write-PositionFile $targetPath ([string]::Join("`r`n", $lines) + "`r`n"); $changedFiles.Add($relativePath) }
    }
}

$creditsPath = Join-Path $DataRoot 'StreamingAssets\CSV\credits.csv'
if ($DataFields.Count -eq 0 -and $Catalog.creditsFields.Count -gt 0 -and ($DataFiles.Count -eq 0 -or $DataFiles -contains 'CSV/credits.csv')) {
    if (-not (Test-Path -LiteralPath $creditsPath -PathType Leaf)) { throw "Positioned credits CSV is missing: $creditsPath" }
    $credits = @(Import-Csv -LiteralPath $creditsPath -Encoding UTF8)
    $changedHere = 0
    foreach ($locator in $Catalog.creditsFields) {
        $rowIndex = [int]$locator.rowIndex; $field = [string]$locator.field
        if ($rowIndex -lt 0 -or $rowIndex -ge $credits.Count -or $field -notin @('header','subheader')) { throw "Credits cell position is invalid: row $rowIndex field $field" }
        $result = Get-PositionedValue ([string]$credits[$rowIndex].$field) $locator "CSV/credits.csv row $rowIndex field $field"
        if ($result.Changed) { $credits[$rowIndex].$field = $result.Value; $changedHere++ }
    }
    if ($changedHere -gt 0) { Write-PositionFile $creditsPath ((@($credits | ConvertTo-Csv -NoTypeInformation) -join "`r`n") + "`r`n"); $changedFiles.Add('CSV/credits.csv') }
}

$missionFileSelected = $DataFiles.Count -eq 0 -or $DataFiles -contains 'Missions/missions.json'
$missionTitleSelected = $DataFields.Count -eq 0 -or $DataFields -contains 'Missions/missions.json:title'
$missionObjectivesSelected = $DataFields.Count -eq 0 -or $DataFields -contains 'Missions/missions.json:objDesc'
$missionTitleChanges = 0; $missionObjectiveChanges = 0
if ($missionFileSelected -and ($missionTitleSelected -or $missionObjectivesSelected)) {
    foreach ($missionDocument in $Catalog.missionDocuments) {
        $targetPath = Join-Path (Join-Path $DataRoot 'StreamingAssets') ([string]$missionDocument.file.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw "Positioned mission file is missing: $targetPath" }
        $parts = [regex]::Split([System.IO.File]::ReadAllText($targetPath, [System.Text.Encoding]::UTF8), '(\r\n|\n|\r)')
        $changedHere = $false
        if ($missionTitleSelected -and $null -ne $missionDocument.title) {
            if (Apply-MissionLineLocator $parts $missionDocument.title "$($missionDocument.file) title") { $missionTitleChanges++; $changedHere = $true }
        }
        if ($missionObjectivesSelected) {
            foreach ($locator in $missionDocument.objectives) {
                if (Apply-MissionLineLocator $parts $locator "$($missionDocument.file) objective index $($locator.objectiveIndex)") { $missionObjectiveChanges++; $changedHere = $true }
            }
        }
        if ($changedHere) {
            $updatedJson = [string]::Join('', $parts)
            $null = ConvertFrom-JsonCompat $updatedJson
            Write-PositionFile $targetPath $updatedJson
            $changedFiles.Add(([string]$missionDocument.file).Replace('\', '/'))
        }
    }
}

[pscustomobject]@{
    JsonChanged = $jsonChanged
    MissionTitleChanges = $missionTitleChanges
    MissionObjectiveChanges = $missionObjectiveChanges
    ChangedFiles = $changedFiles.ToArray()
}
