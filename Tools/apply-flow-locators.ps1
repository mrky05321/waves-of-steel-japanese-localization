[CmdletBinding()]
param(
    [string]$DataRoot,
    [string[]]$FlowFileNames = @()
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$toolsRoot = $PSScriptRoot
$localizationRoot = Split-Path -Parent $toolsRoot
$gameRoot = Split-Path -Parent $localizationRoot
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Join-Path $gameRoot 'Waves of Steel_Data' }
$dataRoot = [System.IO.Path]::GetFullPath($DataRoot)
$flowDirectory = Join-Path $dataRoot 'StreamingAssets\Missions\flow'
$backupDirectory = Join-Path $localizationRoot 'backup\Waves of Steel_Data\StreamingAssets\Missions\flow'
$locatorPath = Join-Path $toolsRoot 'mission-flow-locators.json'
$excludedNames = @('000_test.txt', '003_stresstest.txt', '059_ship_test.txt', 'README.txt')

if (-not (Test-Path -LiteralPath $flowDirectory -PathType Container)) { throw "Mission-flow directory not found: $flowDirectory" }
if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) { throw "Verified original backup is required. Run the main localization script once first: $backupDirectory" }
if (-not (Test-Path -LiteralPath $locatorPath -PathType Leaf)) { throw "Locator catalog not found: $locatorPath" }
if ($FlowFileNames | Where-Object { $_ -notmatch '^[A-Za-z0-9_]+\.txt$' -or $_ -in $excludedNames }) { throw 'Invalid or excluded mission-flow filename.' }

function Get-TextSha256([string]$Text) {
    $bytes = $utf8NoBom.GetBytes($Text)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-FileSha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Move-FileOverwriting([string]$Source, [string]$Destination) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { [System.IO.File]::Move($Source, $Destination, $true) }
    elseif ([System.IO.File]::Exists($Destination)) {
        $backupPath = "$Destination.locator-backup-$([Guid]::NewGuid().ToString('N'))"
        try { [System.IO.File]::Replace($Source, $Destination, $backupPath) }
        finally { if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) } }
    }
    else { [System.IO.File]::Move($Source, $Destination) }
}

function New-LocatorMap($Items, [string]$FileName, [string]$Category) {
    $map = @{}
    foreach ($item in @($Items)) {
        $key = [string]$item.lineIndex
        if ($map.ContainsKey($key)) { throw "Duplicate locator: $FileName $Category line $key" }
        $map[$key] = $item
    }
    return ,$map
}

function Test-AndConsumeLocator($Locator, [string]$Value, [string]$Description, [hashtable]$Consumed) {
    if ($null -eq $Locator) { return $null }
    $sourceHash = Get-TextSha256 $Value
    if ($sourceHash -cne [string]$Locator.sourceSha256) {
        throw "Position guard failed at $Description; the supported game text or layout may have changed. No files have been written."
    }
    $Consumed[$Description] = $true
    return [string]$Locator.translation
}

function Split-FlowLines([string]$Text) {
    $lines = [System.Collections.Generic.List[object]]::new()
    $start = 0
    $index = 0
    while ($index -lt $Text.Length) {
        if ($Text[$index] -eq "`r" -or $Text[$index] -eq "`n") {
            $ending = if ($Text[$index] -eq "`r" -and $index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "`n") { "`r`n" } else { [string]$Text[$index] }
            $lines.Add([pscustomobject]@{ Content = $Text.Substring($start, $index - $start); Ending = $ending })
            $index += $ending.Length
            $start = $index
        }
        else { $index++ }
    }
    if ($start -lt $Text.Length -or $lines.Count -eq 0) { $lines.Add([pscustomobject]@{ Content = $Text.Substring($start); Ending = '' }) }
    return ,$lines.ToArray()
}

function Join-FlowLines($Lines) {
    $builder = [System.Text.StringBuilder]::new()
    foreach ($line in $Lines) { [void]$builder.Append($line.Content); [void]$builder.Append($line.Ending) }
    return $builder.ToString()
}

function Update-LineText([string]$Text, [int]$LineIndex, [hashtable]$Map, [string]$Category, [hashtable]$Consumed, [hashtable]$ChangedCounts, [string]$FileName) {
    $key = [string]$LineIndex
    if (-not $Map.ContainsKey($key)) { return $Text }
    $locator = $Map[$key]
    $start = [int]$locator.startIndex
    $length = [int]$locator.sourceLength
    if ($start -lt 0 -or $length -lt 0 -or $start + $length -gt $Text.Length) { throw "Range guard failed at $FileName $Category line $LineIndex; no files have been written." }
    $currentValue = $Text.Substring($start, $length)
    $replacement = Test-AndConsumeLocator $locator $currentValue "$FileName $Category line $LineIndex offset $start" $Consumed
    $ChangedCounts[$Category]++
    return $Text.Substring(0, $start) + $replacement + $Text.Substring($start + $length)
}

function New-MultiRangeMap($Items, [string]$FileName, [string]$Category) {
    $map = @{}
    foreach ($item in @($Items)) {
        $key = [string]$item.lineIndex
        if (-not $map.ContainsKey($key)) { $map[$key] = [System.Collections.Generic.List[object]]::new() }
        foreach ($existing in $map[$key]) { if ([int]$existing.startIndex -eq [int]$item.startIndex) { throw "Duplicate locator: $FileName $Category line $key offset $($item.startIndex)" } }
        $map[$key].Add($item)
    }
    return ,$map
}

function Update-LocatedRanges([string]$Text, [int]$LineIndex, [hashtable]$Map, [string]$Category, [hashtable]$Consumed, [hashtable]$ChangedCounts, [string]$FileName) {
    $key = [string]$LineIndex
    if (-not $Map.ContainsKey($key)) { return $Text }
    $locators = @($Map[$key] | Sort-Object { [int]$_.startIndex } -Descending)
    foreach ($locator in $locators) {
        $start = [int]$locator.startIndex
        $length = [int]$locator.sourceLength
        if ($start -lt 0 -or $length -lt 0 -or $start + $length -gt $Text.Length) { throw "Range guard failed at $FileName $Category line $LineIndex; no files have been written." }
        $currentValue = $Text.Substring($start, $length)
        $replacement = Test-AndConsumeLocator $locator $currentValue "$FileName $Category line $LineIndex offset $start" $Consumed
        $Text = $Text.Substring(0, $start) + $replacement + $Text.Substring($start + $length)
        $ChangedCounts[$Category]++
    }
    return $Text
}

function Assert-FlowLayout([string]$Before, [string]$After, [regex]$ScrollPattern, [regex]$MarkerPattern, [string]$FileName) {
    $beforeStructure = $ScrollPattern.Replace($Before, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return $m.Groups['prefix'].Value })
    $afterStructure = $ScrollPattern.Replace($After, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return $m.Groups['prefix'].Value })
    if ([regex]::Matches($Before, '\[').Count -ne [regex]::Matches($After, '\[').Count -or
        [regex]::Matches($Before, '\]').Count -ne [regex]::Matches($After, '\]').Count -or
        [regex]::Matches($beforeStructure, '\n').Count -ne [regex]::Matches($afterStructure, '\n').Count) {
        throw "Structure check failed for $FileName; no files have been written."
    }
    $beforeMarkers = @($MarkerPattern.Matches($Before) | ForEach-Object { $_.Value })
    $afterMarkers = @($MarkerPattern.Matches($After) | ForEach-Object { $_.Value })
    if ([string]::Join("`n", $beforeMarkers) -cne [string]::Join("`n", $afterMarkers)) {
        throw "Markup or input-glyph check failed for $FileName; no files have been written."
    }
}

$document = Get-Content -LiteralPath $locatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$document.schemaVersion -ne 1) { throw 'Unsupported locator catalog schema.' }
$allNames = @($document.files.PSObject.Properties | ForEach-Object Name | Sort-Object)
foreach ($name in $allNames) { if ($name -notmatch '^[A-Za-z0-9_]+\.txt$' -or $name -in $excludedNames) { throw "Unsafe or excluded locator filename: $name" } }
$actualNames = @(Get-ChildItem -LiteralPath $flowDirectory -File -Filter '*.txt' | Where-Object Name -notin $excludedNames | ForEach-Object Name | Sort-Object)
if ([string]::Join("`n", $allNames) -cne [string]::Join("`n", $actualNames)) { throw 'Mission-flow file list differs from the supported version; no files have been written.' }
if ($FlowFileNames.Count -gt 0) {
    foreach ($name in $FlowFileNames) { if ($allNames -cnotcontains $name) { throw "Requested flow file is not in this version: $name" } }
    $allNames = @($allNames | Where-Object { $_ -in $FlowFileNames })
}

$scrollPattern = [regex]::new('(?ms)^(?<prefix>\[MISSION scroll\][ \t]*\r?\n)(?<body>.*?)(?=^\[|\z)')
$markerPattern = [regex]::new('\[\[[^\]\r\n]*\]\]|</?[A-Za-z][^>\r\n]*>')
$candidates = [System.Collections.Generic.List[object]]::new()
$totalChanged = 0

foreach ($name in $allNames) {
    $path = Join-Path $flowDirectory $name
    $backupPath = Join-Path $backupDirectory $name
    $fileEntry = $document.files.PSObject.Properties[$name].Value
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Required flow or backup file is missing: $name" }
    $actualHash = Get-FileSha256 $path
    if ($fileEntry.targetFileSha256 -and $actualHash -ceq [string]$fileEntry.targetFileSha256) { continue }
    if ($actualHash -cne [string]$fileEntry.sourceFileSha256) { throw "File-version guard failed for $name; no files have been written." }
    if ((Get-FileSha256 $backupPath) -cne [string]$fileEntry.sourceFileSha256) { throw "Original backup guard failed for $name; no files have been written." }

    $source = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $tempPath = "$path.locator-tmp"
    if (Test-Path -LiteralPath $tempPath) { throw "Temporary output already exists; no files have been written: $tempPath" }
    $consumed = @{}
    $changed = @{ messageText = 0; dialogueText = 0; promptText = 0; bannerText = 0; metaText = 0; scrollText = 0 }
    $messageMap = New-LocatorMap -Items @($fileEntry.messageText) -FileName $name -Category 'messageText'
    $dialogueMap = New-LocatorMap -Items @($fileEntry.dialogueText) -FileName $name -Category 'dialogueText'
    $promptMap = New-MultiRangeMap -Items @($fileEntry.promptText) -FileName $name -Category 'promptText'
    $bannerMap = New-MultiRangeMap -Items @($fileEntry.bannerText) -FileName $name -Category 'bannerText'
    $metaMap = New-MultiRangeMap -Items @($fileEntry.metaText) -FileName $name -Category 'metaText'

    $lines = Split-FlowLines $source
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $lines[$lineIndex].Content = Update-LineText $lines[$lineIndex].Content $lineIndex $messageMap 'messageText' $consumed $changed $name
    }
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $lines[$lineIndex].Content = Update-LineText $lines[$lineIndex].Content $lineIndex $dialogueMap 'dialogueText' $consumed $changed $name
    }
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex].Content
        $line = Update-LocatedRanges $line $lineIndex $promptMap 'promptText' $consumed $changed $name
        $line = Update-LocatedRanges $line $lineIndex $bannerMap 'bannerText' $consumed $changed $name
        $lines[$lineIndex].Content = $line
    }
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $lines[$lineIndex].Content = Update-LocatedRanges $lines[$lineIndex].Content $lineIndex $metaMap 'metaText' $consumed $changed $name
    }
    $updated = Join-FlowLines $lines

    if ($fileEntry.scrollText) {
        $scrollMatches = @($scrollPattern.Matches($updated))
        if ($scrollMatches.Count -ne 1) { throw "Expected one scroll block in $name; no files have been written." }
        $scrollBody = $scrollMatches[0].Groups['body'].Value
        $normalizedBody = $scrollBody.Replace("`r`n", "`n").TrimEnd([char[]]"`r`n")
        $normalizedTranslation = ([string]$fileEntry.scrollText.translation).Replace("`r`n", "`n").TrimEnd([char[]]"`r`n")
        $scrollHash = Get-TextSha256 $normalizedBody
        if ($scrollHash -ceq [string]$fileEntry.scrollText.targetSha256) { }
        elseif ($scrollHash -ceq [string]$fileEntry.scrollText.sourceSha256 -or $scrollHash -ceq [string]$fileEntry.scrollText.previousTranslationSha256) {
            $ending = [regex]::Match($scrollBody, '(?:\r\n|\n)*\z').Value
            $lineEnding = if ($scrollBody.Contains("`r`n")) { "`r`n" } else { "`n" }
            $formatted = $normalizedTranslation.Replace("`n", $lineEnding) + $ending
            $updated = $scrollPattern.Replace($updated, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) return $m.Groups['prefix'].Value + $formatted }, 1)
            $changed.scrollText++
        }
        else { throw "Story-scroll guard failed for $name; no files have been written." }
    }

    foreach ($category in @('messageText','dialogueText','promptText','bannerText','metaText')) {
        $categoryMap = switch ($category) { 'messageText' { $messageMap } 'dialogueText' { $dialogueMap } 'promptText' { $promptMap } 'bannerText' { $bannerMap } 'metaText' { $metaMap } }
        foreach ($key in $categoryMap.Keys) {
            foreach ($locator in @($categoryMap[$key])) {
                $consumeKey = "$name $category line $key offset $($locator.startIndex)"
                if (-not $consumed.ContainsKey($consumeKey)) { throw "Locator was not consumed at $consumeKey; no files have been written." }
            }
        }
    }
    Assert-FlowLayout $source $updated $scrollPattern $markerPattern $name
    if (-not $fileEntry.targetFileSha256) { throw "Target file hash is missing for $name; refusing to write." }
    if ((Get-TextSha256 $updated) -cne [string]$fileEntry.targetFileSha256) { throw "Output hash guard failed for $name; no files have been written." }
    if ($updated -cne $source) {
        $totalChanged += ($changed.Values | Measure-Object -Sum).Sum
        $candidates.Add([pscustomobject]@{ Path = $path; Name = $name; Text = $updated; Counts = $changed })
    }
}

foreach ($candidate in $candidates) {
    $tempPath = "$($candidate.Path).locator-tmp"
    [System.IO.File]::WriteAllText($tempPath, $candidate.Text, $utf8NoBom)
    if (Test-Path -LiteralPath $tempPath) { Move-FileOverwriting $tempPath $candidate.Path }
    Write-Output ("{0}: translated {1} message/tutorial lines, {2} dialogue lines, {3} action prompts, {4} banners, {5} mission labels, {6} scroll blocks." -f $candidate.Name, $candidate.Counts.messageText, $candidate.Counts.dialogueText, $candidate.Counts.promptText, $candidate.Counts.bannerText, $candidate.Counts.metaText, $candidate.Counts.scrollText)
}
Write-Output "Locator files written: $($candidates.Count); translated strings: $totalChanged. Files already matching the target hash were left untouched."
