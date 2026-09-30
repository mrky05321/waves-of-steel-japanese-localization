[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$DataOnly,
    [switch]$MenusOnly,
    [switch]$FlowOnly,
    [string[]]$DataFiles = @(),
    [string[]]$DataFields = @(),
    [Alias('FlowFiles')]
    [string[]]$FlowFileNames = @()
)

$ErrorActionPreference = 'Stop'
$localizationRoot = $PSScriptRoot
$gameRoot = Split-Path -Parent $localizationRoot
$dataRoot = Join-Path $gameRoot 'Waves of Steel_Data'
$backupRoot = Join-Path $localizationRoot 'backup'
$catalogPath = Join-Path $localizationRoot 'position-translations.json'
$manifestPath = Join-Path $backupRoot 'SHA256SUMS.txt'
$pristineManifestPath = Join-Path $localizationRoot 'pristine-files.sha256'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$useWindowsPowerShellJson = $PSVersionTable.PSVersion.Major -lt 6
$legacyJsonDeserializer = $null

if ($useWindowsPowerShellJson) {
    Add-Type -AssemblyName System.Web.Extensions
    $legacyJsonDeserializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $legacyJsonDeserializer.MaxJsonLength = [int]::MaxValue
    $legacyJsonDeserializer.RecursionLimit = 512
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;

public static class WosLocalizationAssemblyResolver
{
    private static string _toolsPath;

    public static void Register(string toolsPath)
    {
        _toolsPath = toolsPath;
        AppDomain.CurrentDomain.AssemblyResolve -= Resolve;
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
    }

    private static Assembly Resolve(object sender, ResolveEventArgs args)
    {
        var requested = new AssemblyName(args.Name);
        var candidate = Path.Combine(_toolsPath, requested.Name + ".dll");
        return File.Exists(candidate) ? Assembly.LoadFrom(candidate) : null;
    }
}
'@
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

function Move-FileOverwriting([string]$Source, [string]$Destination) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        [System.IO.File]::Move($Source, $Destination, $true)
    }
    elseif ([System.IO.File]::Exists($Destination)) {
        $backupPath = "$Destination.jp-backup-$([Guid]::NewGuid().ToString('N'))"
        try {
            [System.IO.File]::Replace($Source, $Destination, $backupPath)
        }
        finally {
            if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
        }
    }
    else {
        [System.IO.File]::Move($Source, $Destination)
    }
}

function Get-Sha256Hex([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-ScenePositionKey([string]$Asset, [long]$PathId, [int[]]$ChildPath) {
    $indices = [string]::Join(',', [string[]]@($ChildPath | ForEach-Object { [string][int]$_ }))
    return '{0}|{1}|{2}' -f $Asset, $PathId, $indices
}

function Get-ScenePositionedText([string]$Current, $Locator, [string]$Description) {
    $currentHash = Get-Sha256Hex $Current
    if ($currentHash -ceq [string]$Locator.targetSha256) { return [pscustomobject]@{ Value=$Current; Changed=$false } }
    $edits = @($Locator.edits)
    if ($edits.Count -eq 1 -and [bool]$edits[0].whole) {
        $edit = $edits[0]
        $sourceMatches = @($edit.sourceOptions | Where-Object { [int]$_.length -eq $Current.Length -and [string]$_.sha256 -ceq $currentHash })
        if ($sourceMatches.Count -eq 0) { throw "Scene text position guard failed at $Description." }
        $target = [string]$edit.translation
        if ((Get-Sha256Hex $target) -cne [string]$Locator.targetSha256 -or [string]$edit.targetSha256 -cne [string]$Locator.targetSha256) {
            throw "Scene text locator hash is invalid at $Description."
        }
        return [pscustomobject]@{ Value=$target; Changed=($target -cne $Current) }
    }

    $parts = [System.Text.RegularExpressions.Regex]::Split($Current, '(\r\n|\n|\r)')
    foreach ($edit in $edits) {
        $partIndex = ([int]$edit.lineIndex) * 2
        if ($partIndex -lt 0 -or $partIndex -ge $parts.Length) { throw "Scene text line position is outside the supported value at $Description." }
        $line = [string]$parts[$partIndex]
        $lineHash = Get-Sha256Hex $line
        if ($lineHash -ceq [string]$edit.targetSha256) { continue }
        $sourceMatches = @($edit.sourceOptions | Where-Object { [int]$_.length -eq $line.Length -and [string]$_.sha256 -ceq $lineHash })
        if ($sourceMatches.Count -eq 0) { throw "Scene text line position guard failed at $Description line $($edit.lineIndex)." }
        $parts[$partIndex] = [string]$edit.translation
    }
    $target = [string]::Join('', $parts)
    if ((Get-Sha256Hex $target) -cne [string]$Locator.targetSha256) { throw "Scene text output verification failed at $Description." }
    return [pscustomobject]@{ Value=$target; Changed=($target -cne $Current) }
}

if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    throw "Unity data directory was not found: $dataRoot"
}
function Read-HashManifest([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Hash manifest was not found: $Path"
    }
    $entries = @()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([A-Fa-f0-9]{64})\s{2}(.+)$') {
            throw "Invalid line in backup manifest: $line"
        }
        $hash = $Matches[1].ToUpperInvariant()
        $relativePath = $Matches[2].Replace('/', '\')
        $pathParts = $relativePath.Split([char[]]@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($relativePath -notmatch '^Waves of Steel_Data\\' -or
            $relativePath.Contains(':') -or
            $pathParts -contains '.' -or
            $pathParts -contains '..' -or
            -not $seenPaths.Add($relativePath)) {
            throw "Unsafe or duplicate path in hash manifest: $relativePath"
        }
        $entries += [pscustomobject]@{ Hash = $hash; RelativePath = $relativePath }
    }
    if ($entries.Count -eq 0) { throw 'The backup hash manifest is empty.' }
    return $entries
}

function Initialize-BackupFromGameFiles {
    $expectedEntries = @(Read-HashManifest -Path $pristineManifestPath)
    $optionalPaths = @('Waves of Steel_Data\level1.before-japanese-settings.bak')
    $level1Path = 'Waves of Steel_Data\level1'
    $level1BeforeSettingsPath = 'Waves of Steel_Data\level1.before-japanese-settings.bak'
    $level1BeforeSettingsEntry = $expectedEntries | Where-Object { $_.RelativePath -eq $level1BeforeSettingsPath } | Select-Object -First 1
    $verifiedEntries = [System.Collections.Generic.List[object]]::new()
    $gameRootFullPath = [System.IO.Path]::GetFullPath($gameRoot).TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar

    # Validate every source before creating any backup files. This prevents a partially
    # modified or different game build from being mistaken for a pristine source.
    foreach ($entry in $expectedEntries) {
        $sourcePath = Join-Path $gameRoot $entry.RelativePath
        $sourceFullPath = [System.IO.Path]::GetFullPath($sourcePath)
        if (-not $sourceFullPath.StartsWith($gameRootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Game source path is outside the game folder: $($entry.RelativePath)"
        }
        if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) {
            if ($entry.RelativePath -in $optionalPaths) { continue }
            throw "Required original game file is missing: $sourceFullPath"
        }
        $sourceHash = (Get-FileHash -LiteralPath $sourceFullPath -Algorithm SHA256).Hash.ToUpperInvariant()
        $knownVersionHash = $sourceHash -eq $entry.Hash
        if (-not $knownVersionHash -and
            $entry.RelativePath -eq $level1Path -and
            $null -ne $level1BeforeSettingsEntry -and
            $sourceHash -eq $level1BeforeSettingsEntry.Hash) {
            # A clean install may have the known pre-settings level1 scene directly
            # at level1, without the companion .bak file. Preserve its actual hash.
            $knownVersionHash = $true
            Write-Output 'Recognized the supported pre-settings level1 scene.'
        }
        if (-not $knownVersionHash) {
            if ($entry.RelativePath -in $optionalPaths) { continue }
            throw "Game file does not match the supported pristine version; no backup or game files were changed: $sourceFullPath"
        }
        $verifiedEntries.Add([pscustomobject]@{ Hash = $sourceHash; RelativePath = $entry.RelativePath })
    }
    $expectedEntries = @($verifiedEntries.ToArray())

    if (Test-Path -LiteralPath $backupRoot) {
        $existingBackupContent = Get-ChildItem -LiteralPath $backupRoot -Force -Recurse | Select-Object -First 1
        if ($null -ne $existingBackupContent) {
            throw "Backup folder exists but has no valid manifest; refusing to overwrite it: $backupRoot"
        }
        Remove-Item -LiteralPath $backupRoot -Force
    }

    $stagingRoot = Join-Path $localizationRoot ('.backup-initializing-' + [Guid]::NewGuid().ToString('N'))
    try {
        $null = [System.IO.Directory]::CreateDirectory($stagingRoot)
        foreach ($entry in $expectedEntries) {
            $sourcePath = Join-Path $gameRoot $entry.RelativePath
            $destinationPath = Join-Path $stagingRoot $entry.RelativePath
            $destinationDirectory = Split-Path -Parent $destinationPath
            $null = [System.IO.Directory]::CreateDirectory($destinationDirectory)
            [System.IO.File]::Copy($sourcePath, $destinationPath)

            $copiedHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($copiedHash -ne $entry.Hash) {
                throw "Backup copy did not match the verified original; no game files were changed: $($entry.RelativePath)"
            }
        }

        $backupManifestLines = @($expectedEntries | ForEach-Object { '{0}  {1}' -f $_.Hash, $_.RelativePath })
        [System.IO.File]::WriteAllLines((Join-Path $stagingRoot 'SHA256SUMS.txt'), [string[]]$backupManifestLines, $utf8NoBom)
        [System.IO.Directory]::Move($stagingRoot, $backupRoot)
        Write-Output "Created a local backup from the verified game installation ($($expectedEntries.Count) files)."
    }
    finally {
        if ([System.IO.Directory]::Exists($stagingRoot)) {
            [System.IO.Directory]::Delete($stagingRoot, $true)
        }
    }
}

function Get-BackupEntries {
    return Read-HashManifest -Path $manifestPath
}

function Assert-BackupIntegrity($entries) {
    foreach ($entry in $entries) {
        $backupPath = Join-Path $backupRoot $entry.RelativePath
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            throw "Required backup is missing: $backupPath"
        }
        $actualHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
        if ($actualHash -ne $entry.Hash) {
            throw "Backup hash mismatch; no files were changed: $backupPath"
        }
    }
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    if ($Restore) {
        throw "No localization backup exists to restore: $manifestPath"
    }
    Initialize-BackupFromGameFiles
}

$backupEntries = Get-BackupEntries
Assert-BackupIntegrity $backupEntries
$backupPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $backupEntries) { [void]$backupPaths.Add([string]$entry.RelativePath) }

if ($Restore) {
    foreach ($entry in $backupEntries) {
        $source = Join-Path $backupRoot $entry.RelativePath
        $destination = Join-Path $gameRoot $entry.RelativePath
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "Restore destination directory is missing: $parent"
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    $settingsOriginalRelativePath = 'Waves of Steel_Data\level1.before-japanese-settings.bak'
    $settingsOriginal = Join-Path $dataRoot 'level1.before-japanese-settings.bak'
    if ($backupPaths.Contains($settingsOriginalRelativePath) -and (Test-Path -LiteralPath $settingsOriginal -PathType Leaf)) {
        Copy-Item -LiteralPath $settingsOriginal -Destination (Join-Path $dataRoot 'level1') -Force
        Write-Output 'Restored the pristine pre-settings level1 scene as well.'
    }
    Write-Output "Restored $($backupEntries.Count) backed-up files. Backup hashes were verified before restore."
    exit 0
}

if ($MenusOnly -and $DataOnly) {
    throw 'Use either -MenusOnly or -DataOnly, not both.'
}
if ($FlowOnly -and ($DataOnly -or $MenusOnly)) {
    throw 'Use -FlowOnly by itself; it cannot be combined with -DataOnly or -MenusOnly.'
}
if ($FlowFileNames.Count -gt 0 -and -not $FlowOnly) {
    throw 'Use -FlowFiles only together with -FlowOnly.'
}
if ($DataFiles.Count -gt 0 -and -not $DataOnly) {
    throw 'Use -DataFiles only together with -DataOnly.'
}
if ($DataFields.Count -gt 0 -and (-not $DataOnly -or $DataFiles.Count -eq 0)) {
    throw 'Use -DataFields together with -DataOnly and -DataFiles.'
}

$catalog = ConvertFrom-JsonCompat -Json (Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8)
if ([int]$catalog.schemaVersion -ne 1) { throw 'Unsupported position-translation catalog version.' }
$knownDataFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$knownDataFields = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($relativePath in $catalog.dataFields.Keys) {
    [void]$knownDataFiles.Add([string]$relativePath)
    foreach ($locator in $catalog.dataFields[$relativePath]) {
        [void]$knownDataFields.Add(('{0}:{1}' -f $relativePath, [string]$locator.field))
    }
}
foreach ($relativePath in $catalog.singleColumnCsv.Keys) { [void]$knownDataFiles.Add([string]$relativePath) }
if ($catalog.creditsFields.Count -gt 0) { [void]$knownDataFiles.Add('CSV/credits.csv') }
if ($catalog.missionDocuments.Count -gt 0) { [void]$knownDataFiles.Add('Missions/missions.json') }
foreach ($missionDocument in $catalog.missionDocuments) {
    if ($null -ne $missionDocument.title) { [void]$knownDataFields.Add('Missions/missions.json:title') }
    if ($missionDocument.objectives.Count -gt 0) { [void]$knownDataFields.Add('Missions/missions.json:objDesc') }
}
foreach ($relativePath in $DataFiles) {
    if (-not $knownDataFiles.Contains($relativePath)) {
        throw "Unknown localization data file: $relativePath"
    }
}
foreach ($fieldEntry in $DataFields) {
    if (-not $knownDataFields.Contains($fieldEntry)) {
        throw "Unknown localization data field: $fieldEntry"
    }
    $separator = $fieldEntry.LastIndexOf(':')
    $fieldFile = $fieldEntry.Substring(0, $separator)
    if ($DataFiles -notcontains $fieldFile) {
        throw "Data field is not included in -DataFiles: $fieldEntry"
    }
}

$changedFiles = [System.Collections.Generic.List[string]]::new()
$jsonChanged = 0

function Write-AtomicUtf8([string]$Path, [string]$Text) {
    $tempPath = "$Path.jp-tmp"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Text, $utf8NoBom)
        Move-FileOverwriting $tempPath $Path
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

if (-not $MenusOnly -and -not $FlowOnly) {
    $positionDataScript = Join-Path $localizationRoot 'Tools\apply-position-data.ps1'
    if (-not (Test-Path -LiteralPath $positionDataScript -PathType Leaf)) { throw 'Position-based data translator is missing.' }
    $dataResult = & $positionDataScript -DataRoot $dataRoot -Catalog $catalog -DataFiles $DataFiles -DataFields $DataFields
    $jsonChanged = [int]$dataResult.JsonChanged
    foreach ($relativePath in $dataResult.ChangedFiles) { $changedFiles.Add([string]$relativePath) }
    Write-Output ("Mission definitions translated: {0} campaign/freeplay titles and {1} objective descriptions; positioned data fields were verified." -f ([int]$dataResult.MissionTitleChanges), ([int]$dataResult.MissionObjectiveChanges))
}
if (-not $DataOnly -and -not $FlowOnly) {
    $toolsRoot = Join-Path $localizationRoot 'Tools'
    foreach ($required in @('AssetsTools.NET.dll', 'AssetsTools.NET.MonoCecil.dll', 'Mono.Cecil.dll', 'Mono.Cecil.Rocks.dll', 'classdata.tpk')) {
        if (-not (Test-Path -LiteralPath (Join-Path $toolsRoot $required) -PathType Leaf)) {
            throw "Unity serialized-file helper is missing: $required"
        }
    }
    if ($useWindowsPowerShellJson) {
        [WosLocalizationAssemblyResolver]::Register($toolsRoot)
    }
    Add-Type -Path (Join-Path $toolsRoot 'Mono.Cecil.dll')

    $assemblyPath = Join-Path $dataRoot 'Managed\clock.dll'
    $assemblyTempPath = "$assemblyPath.jp-tmp"
    $assemblyChanges = @{}
    $assemblyChangedLocatorsByMethod = @{}
    $assemblyFloatChanges = @{}
    $assemblyLocatorsByPosition = @{}
    $seenAssemblyPositions = @{}
    foreach ($locator in $catalog.assemblyText) {
        $positionKey = '{0}:{1}' -f [int]$locator.methodToken, [int]$locator.instructionIndex
        if ($assemblyLocatorsByPosition.ContainsKey($positionKey)) { throw "Duplicate managed-string position: $positionKey" }
        $assemblyLocatorsByPosition[$positionKey] = $locator
    }
    $assembly = $null
    $resolver = [Mono.Cecil.DefaultAssemblyResolver]::new()
    $resolver.AddSearchDirectory((Join-Path $dataRoot 'Managed'))
    $readerParameters = [Mono.Cecil.ReaderParameters]::new()
    $readerParameters.AssemblyResolver = $resolver
    $readerParameters.InMemory = $true
    try {
        $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($assemblyPath, $readerParameters)
        $typeQueue = [System.Collections.Generic.Queue[Mono.Cecil.TypeDefinition]]::new()
        foreach ($type in $assembly.MainModule.Types) { $typeQueue.Enqueue($type) }
        while ($typeQueue.Count -gt 0) {
            $type = $typeQueue.Dequeue()
            foreach ($nestedType in $type.NestedTypes) { $typeQueue.Enqueue($nestedType) }
            foreach ($method in $type.Methods) {
                if (-not $method.HasBody) { continue }
                for ($instructionIndex = 0; $instructionIndex -lt $method.Body.Instructions.Count; $instructionIndex++) {
                    $instruction = $method.Body.Instructions[$instructionIndex]
                    $floatTargetKey = "$($type.Name)::$($method.Name)"
                    if (-not $MenusOnly -and $catalog.ContainsKey("assemblyFloatTargets") -and $catalog.assemblyFloatTargets.ContainsKey($floatTargetKey) -and [string]$instruction.OpCode.Code -eq "Ldc_R4") {
                        $scaleTarget = $catalog.assemblyFloatTargets[$floatTargetKey]
                        $currentScale = [double]$instruction.Operand
                        $sourceScale = [double]$scaleTarget.source
                        $targetScale = [double]$scaleTarget.target
                        if ([Math]::Abs($currentScale - $sourceScale) -lt 0.00001) {
                            $instruction.Operand = [single]$targetScale
                            $assemblyFloatChanges[$floatTargetKey] = $targetScale
                        }
                        elseif ([Math]::Abs($currentScale - $targetScale) -ge 0.00001) {
                            throw "Unexpected managed UI scale constant; refusing to overwrite: $floatTargetKey = $currentScale"
                        }
                    }
                    if ($instruction.OpCode.Code -ne [Mono.Cecil.Cil.Code]::Ldstr -or $instruction.Operand -isnot [string]) { continue }
                    $sourceText = [string]$instruction.Operand
                    $positionKey = '{0}:{1}' -f $method.MetadataToken.ToInt32(), $instructionIndex
                    if ($assemblyLocatorsByPosition.ContainsKey($positionKey)) {
                        $seenAssemblyPositions[$positionKey] = $true
                        $locator = $assemblyLocatorsByPosition[$positionKey]
                        $currentHash = Get-Sha256Hex $sourceText
                        if ($currentHash -ceq [string]$locator.targetSha256) { continue }
                        if ($currentHash -cne [string]$locator.sourceSha256) {
                            throw "Managed string position guard failed at method $($method.MetadataToken.ToInt32()) instruction $instructionIndex."
                        }
                        $translatedText = [string]$locator.translation
                        if ((Get-Sha256Hex $translatedText) -cne [string]$locator.targetSha256) { throw "Managed string locator hash is invalid at $positionKey." }
                        $instruction.Operand = $translatedText
                        $assemblyChanges[$positionKey] = $translatedText
                        $methodFullName = [string]$method.FullName
                        if (-not $assemblyChangedLocatorsByMethod.ContainsKey($methodFullName)) { $assemblyChangedLocatorsByMethod[$methodFullName] = @{} }
                        $assemblyChangedLocatorsByMethod[$methodFullName][[string]$instructionIndex] = $positionKey
                    }
                }
            }
        }
        foreach ($positionKey in $assemblyLocatorsByPosition.Keys) {
            if (-not $seenAssemblyPositions.ContainsKey([string]$positionKey)) { throw "Managed string position was not found: $positionKey" }
        }

        if (($assemblyChanges.Count -gt 0) -or ($assemblyFloatChanges.Count -gt 0)) {
            $assembly.Write($assemblyTempPath)
        }
    }
    finally {
        if ($null -ne $assembly) { $assembly.Dispose() }
        $resolver.Dispose()
    }

    if (($assemblyChanges.Count -gt 0) -or ($assemblyFloatChanges.Count -gt 0)) {
        $verifiedAssembly = $null
        $verifyResolver = [Mono.Cecil.DefaultAssemblyResolver]::new()
        $verifyResolver.AddSearchDirectory((Join-Path $dataRoot 'Managed'))
        $verifyParameters = [Mono.Cecil.ReaderParameters]::new()
        $verifyParameters.AssemblyResolver = $verifyResolver
        $verifyParameters.InMemory = $true
        try {
            $verifiedAssembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($assemblyTempPath, $verifyParameters)
            $verifiedValues = @{}
            $verifiedFloatTargets = @{}
            $typeQueue = [System.Collections.Generic.Queue[Mono.Cecil.TypeDefinition]]::new()
            foreach ($type in $verifiedAssembly.MainModule.Types) { $typeQueue.Enqueue($type) }
            while ($typeQueue.Count -gt 0) {
                $type = $typeQueue.Dequeue()
                foreach ($nestedType in $type.NestedTypes) { $typeQueue.Enqueue($nestedType) }
                foreach ($method in $type.Methods) {
                    if (-not $method.HasBody) { continue }
                    for ($instructionIndex = 0; $instructionIndex -lt $method.Body.Instructions.Count; $instructionIndex++) {
                        $instruction = $method.Body.Instructions[$instructionIndex]
                        if (-not $MenusOnly -and [string]$instruction.OpCode.Code -eq "Ldc_R4") {
                            $floatTargetKey = "$($type.Name)::$($method.Name)"
                            if ($catalog.assemblyFloatTargets.ContainsKey($floatTargetKey) -and [Math]::Abs([double]$instruction.Operand - [double]$catalog.assemblyFloatTargets[$floatTargetKey].target) -lt 0.00001) {
                                $verifiedFloatTargets[$floatTargetKey] = $true
                            }
                        }
                        $methodFullName = [string]$method.FullName
                        if ($assemblyChangedLocatorsByMethod.ContainsKey($methodFullName) -and
                            $assemblyChangedLocatorsByMethod[$methodFullName].ContainsKey([string]$instructionIndex)) {
                            $positionKey = [string]$assemblyChangedLocatorsByMethod[$methodFullName][[string]$instructionIndex]
                            $locator = $assemblyLocatorsByPosition[$positionKey]
                            if ($instruction.OpCode.Code -ne [Mono.Cecil.Cil.Code]::Ldstr -or $instruction.Operand -isnot [string] -or
                                (Get-Sha256Hex ([string]$instruction.Operand)) -cne [string]$locator.targetSha256) {
                                throw "Managed string position verification failed at $positionKey."
                            }
                            $verifiedValues[$positionKey] = $true
                        }
                    }
                }
            }
            if (-not $MenusOnly) {
                foreach ($floatTargetKey in $catalog.assemblyFloatTargets.Keys) {
                    if (-not $verifiedFloatTargets.ContainsKey([string]$floatTargetKey)) { throw "Managed assembly scale verification failed for $floatTargetKey" }
                }
            }
            foreach ($expectedKey in $assemblyChanges.Keys) {
                if (-not $verifiedValues.ContainsKey($expectedKey)) { throw "Managed assembly verification failed for $expectedKey" }
            }
        }
        finally {
            if ($null -ne $verifiedAssembly) { $verifiedAssembly.Dispose() }
            $verifyResolver.Dispose()
        }
        Move-FileOverwriting $assemblyTempPath $assemblyPath
        $changedFiles.Add('Managed/clock.dll')
        Write-Output "Managed UI assembly updated: $($assemblyChanges.Count) strings, $($assemblyFloatChanges.Count) layout constants; rewritten assembly re-opened and verified."
    }
    else {
        Write-Output 'Managed UI assembly: no catalogued English strings remain.'
    }
    if (Test-Path -LiteralPath $assemblyTempPath) { Remove-Item -LiteralPath $assemblyTempPath -Force }

    Add-Type -Path (Join-Path $toolsRoot 'AssetsTools.NET.dll')
    Add-Type -Path (Join-Path $toolsRoot 'AssetsTools.NET.MonoCecil.dll')

    $fontAssetPath = Join-Path $dataRoot 'sharedassets0.assets'
    $fontTempPath = "$fontAssetPath.jp-tmp"
    if (Test-Path -LiteralPath $fontTempPath) {
        throw "Temporary font output already exists; no files were changed: $fontTempPath"
    }
    $fontManager = [AssetsTools.NET.Extra.AssetsManager]::new()
    try {
        $fontManager.LoadClassPackage((Join-Path $toolsRoot 'classdata.tpk')) | Out-Null
        $fontClassDatabase = $fontManager.LoadClassDatabaseFromPackage('2019.4.40f1')
        $fontManager.MonoTempGenerator = [AssetsTools.NET.Extra.MonoCecilTempGenerator]::new((Join-Path $dataRoot 'Managed'))
        $null = $fontManager.LoadAssetsFile((Join-Path $dataRoot 'globalgamemanagers.assets'), $true)
        $fontInstance = $fontManager.LoadAssetsFile($fontAssetPath, $true)
        $codaInfo = $null
        $codaOutlineInfo = $null
        $robotoInfo = $null
        $liberationInfo = $null
        $notoInfo = $null
        foreach ($assetInfo in $fontInstance.file.GetAssetsOfType([int]114)) {
            $fontBase = $fontManager.GetBaseField($fontInstance, $assetInfo)
            switch ([string]$fontBase['m_Name'].AsString) {
                'Coda-Regular Outline' { $codaOutlineInfo = $assetInfo }
                'Coda-Regular SDF' { $codaInfo = $assetInfo }
                'LiberationSans SDF' { $liberationInfo = $assetInfo }
                'Roboto-Regular Outline' { $robotoInfo = $assetInfo }
                'NotoJPOutline' { $notoInfo = $assetInfo }
            }
        }
        if ($null -eq $codaInfo -or $null -eq $codaOutlineInfo -or $null -eq $robotoInfo -or $null -eq $notoInfo) {
            throw 'Expected Coda SDF, Coda Outline, Roboto Outline, and NotoJPOutline TMP font assets were not all found.'
        }
        if (-not $MenusOnly -and $null -eq $liberationInfo) {
            throw 'Expected generic LiberationSans SDF TMP font asset was not found.'
        }

        $robotoBase = $fontManager.GetBaseField($fontInstance, $robotoInfo)
        $notoBase = $fontManager.GetBaseField($fontInstance, $notoInfo)
        $notoPathId = [long]$notoInfo.PathId
        $notoSourceFontInfo = $fontInstance.file.GetAssetsOfType([int]128) | Where-Object { $_.PathId -eq 241 } | Select-Object -First 1
        if ($null -eq $notoSourceFontInfo) {
            throw 'Expected NotoSansJP-Regular source Font asset was not found.'
        }
        $notoSourceFontBase = $fontManager.GetBaseField($fontInstance, $notoSourceFontInfo)
        $notoSourceFontName = [string]$notoSourceFontBase['m_Name'].AsString
        $expectedNotoSourceFontName = 'NotoSansJP-Regular'
        $needsNotoSourceFontNameRestore = $notoSourceFontName -ceq 'Noto Sans JP'
        if (-not $needsNotoSourceFontNameRestore -and $notoSourceFontName -cne $expectedNotoSourceFontName) {
            throw "Unexpected Japanese source-font family name: $notoSourceFontName"
        }
        $multiAtlasField = $notoBase['m_IsMultiAtlasTexturesEnabled']
        if ($null -eq $multiAtlasField -or $null -eq $multiAtlasField.Value -or $multiAtlasField.Value.ValueType -ne [AssetsTools.NET.AssetValueType]::UInt8) {
            throw 'NotoJPOutline no longer has the expected multi-atlas TMP setting.'
        }
        $needsMultiAtlasEnable = -not [bool]$multiAtlasField.AsBool
        $fontTargets = @($codaInfo, $codaOutlineInfo)
        if (-not $MenusOnly) { $fontTargets += $liberationInfo }
        $missingFontTargets = [System.Collections.Generic.List[object]]::new()
        foreach ($fontTarget in $fontTargets) {
            $fontBase = $fontManager.GetBaseField($fontInstance, $fontTarget)
            $fallbackArray = $fontBase['m_FallbackFontAssetTable'].Children[0]
            $fontHasNoto = $false
            foreach ($reference in $fallbackArray.Children) {
                if ([int]$reference.Children[0].AsInt -eq 0 -and [long]$reference.Children[1].AsLong -eq $notoPathId) {
                    $fontHasNoto = $true
                    break
                }
            }
            if (-not $fontHasNoto) { $missingFontTargets.Add($fontTarget) }
        }

        if ($missingFontTargets.Count -gt 0 -or $needsNotoSourceFontNameRestore -or $needsMultiAtlasEnable) {
            $robotoArray = $robotoBase['m_FallbackFontAssetTable'].Children[0]
            $notoReference = $null
            foreach ($reference in $robotoArray.Children) {
                if ([int]$reference.Children[0].AsInt -eq 0 -and [long]$reference.Children[1].AsLong -eq $notoPathId) {
                    $notoReference = $reference
                    break
                }
            }
            if ($null -eq $notoReference) {
                throw 'Roboto font no longer contains the expected NotoJPOutline fallback reference.'
            }

            $fontReplacers = [System.Collections.Generic.List[AssetsTools.NET.AssetsReplacer]]::new()
            foreach ($fontTarget in $missingFontTargets) {
                $fontBase = $fontManager.GetBaseField($fontInstance, $fontTarget)
                $fallbackArray = $fontBase['m_FallbackFontAssetTable'].Children[0]
                $fallbackArray.Children.Add($notoReference)
                $fallbackArray.Value.AsArray.size = $fallbackArray.Children.Count
                $fontReplacers.Add([AssetsTools.NET.AssetsReplacerFromMemory]::new($fontInstance.file, $fontTarget, $fontBase))
            }
            if ($needsNotoSourceFontNameRestore) {
                $notoSourceFontBase['m_Name'].AsString = $expectedNotoSourceFontName
                $fontReplacers.Add([AssetsTools.NET.AssetsReplacerFromMemory]::new($fontInstance.file, $notoSourceFontInfo, $notoSourceFontBase))
            }
            if ($needsMultiAtlasEnable) {
                $multiAtlasField.AsByte = [byte]1
                $fontReplacers.Add([AssetsTools.NET.AssetsReplacerFromMemory]::new($fontInstance.file, $notoInfo, $notoBase))
            }
            $fontWriter = [System.IO.File]::Create($fontTempPath)
            try { $fontInstance.file.Write($fontWriter, 0, $fontReplacers, $fontClassDatabase) }
            finally { $fontWriter.Dispose() }

            $fontVerifyManager = [AssetsTools.NET.Extra.AssetsManager]::new()
            try {
                $fontVerifyManager.LoadClassPackage((Join-Path $toolsRoot 'classdata.tpk')) | Out-Null
                $null = $fontVerifyManager.LoadClassDatabaseFromPackage('2019.4.40f1')
                $fontVerifyManager.MonoTempGenerator = [AssetsTools.NET.Extra.MonoCecilTempGenerator]::new((Join-Path $dataRoot 'Managed'))
                $null = $fontVerifyManager.LoadAssetsFile((Join-Path $dataRoot 'globalgamemanagers.assets'), $true)
                $verifiedFontFile = $fontVerifyManager.LoadAssetsFile($fontTempPath, $true)
                foreach ($fontTarget in $fontTargets) {
                    $verifiedTarget = $verifiedFontFile.file.GetAssetsOfType([int]114) | Where-Object { $_.PathId -eq $fontTarget.PathId } | Select-Object -First 1
                    if ($null -eq $verifiedTarget) { throw "TMP font is missing from the serialized-file candidate: pathID $($fontTarget.PathId)." }
                    $verifiedBase = $fontVerifyManager.GetBaseField($verifiedFontFile, $verifiedTarget)
                    $verifiedFallbacks = $verifiedBase['m_FallbackFontAssetTable'].Children[0].Children
                    $verifiedNoto = $false
                    foreach ($reference in $verifiedFallbacks) {
                        if ([int]$reference.Children[0].AsInt -eq 0 -and [long]$reference.Children[1].AsLong -eq $notoPathId) {
                            $verifiedNoto = $true
                            break
                        }
                    }
                    if (-not $verifiedNoto) { throw "Serialized-file verification failed: TMP font pathID $($fontTarget.PathId) does not resolve to NotoJPOutline." }
                }
                $verifiedSourceFont = $verifiedFontFile.file.GetAssetsOfType([int]128) | Where-Object { $_.PathId -eq 241 } | Select-Object -First 1
                if ($null -eq $verifiedSourceFont) { throw 'Serialized-file verification failed: Noto Sans JP source Font asset is missing.' }
                $verifiedSourceFontBase = $fontVerifyManager.GetBaseField($verifiedFontFile, $verifiedSourceFont)
                if ([string]$verifiedSourceFontBase['m_Name'].AsString -cne $expectedNotoSourceFontName) {
                    throw 'Serialized-file verification failed: Noto Sans JP source Font family name was not preserved.'
                }
                $verifiedNotoFont = $verifiedFontFile.file.GetAssetsOfType([int]114) | Where-Object { $_.PathId -eq $notoInfo.PathId } | Select-Object -First 1
                if ($null -eq $verifiedNotoFont) { throw 'Serialized-file verification failed: NotoJPOutline TMP asset is missing.' }
                $verifiedNotoBase = $fontVerifyManager.GetBaseField($verifiedFontFile, $verifiedNotoFont)
                if ([byte]$verifiedNotoBase['m_IsMultiAtlasTexturesEnabled'].AsByte -ne [byte]1) {
                    throw 'Serialized-file verification failed: NotoJPOutline multi-atlas mode is disabled.'
                }
            }
            finally { $fontVerifyManager.UnloadAll() }

            $fontManager.UnloadAll()
            Move-FileOverwriting $fontTempPath $fontAssetPath
            $fontManager = $null
            $changedFiles.Add('sharedassets0.assets')
            Write-Output 'NotoJPOutline: verified multi-atlas dynamic glyph expansion; source font family name preserved.'
            if ($MenusOnly) {
                Write-Output 'Main-menu TMP fonts: verified NotoJPOutline fallback for Coda-Regular SDF and Coda-Regular Outline.'
            }
            else {
                Write-Output 'Main-menu and generic TMP fonts: verified NotoJPOutline fallback for Coda-Regular SDF, Coda-Regular Outline, and LiberationSans SDF.'
            }
        }
        else {
            Write-Output 'Main-menu and generic TMP fonts: NotoJPOutline fallback is already present on all selected fonts.'
        }
    }
    finally {
        if ($null -ne $fontManager) { $fontManager.UnloadAll() }
        if (Test-Path -LiteralPath $fontTempPath) { Remove-Item -LiteralPath $fontTempPath -Force }
    }

    if (-not $MenusOnly) {
        # Many ship-designer, mission, debrief, and typewriter screens use different
        # TMP font assets than the title menu. Add the game's dynamic Japanese font
        # as a fallback only; preserve each original primary font and existing fallbacks.
        $additionalFontPlans = @(
            [pscustomobject]@{
                RelativePath = 'sharedassets1.assets'; TargetNames = @('RobotoSlab-Regular')
                TemplatePath = 'sharedassets1.assets'; TemplateFontName = 'Roboto-Regular Shadow'
                NotoFileId = 3; NotoPathId = 341
            },
            [pscustomobject]@{
                RelativePath = 'sharedassets2.assets'; TargetNames = @(
                    'B612Mono-Regular SDF', 'FrancoisOne-Regular SDF', 'LifeSavers-Bold SDF',
                    'RobotoSlab-Bold SDF', 'RobotoSlab-Regular Outline', 'SS Soapy Hands Regular SDF',
                    'TT2020StyleG-Regular-ASCII SDF'
                )
                TemplatePath = 'sharedassets2.assets'; TemplateFontName = 'Roboto-Bold Outline'
                NotoFileId = 0; NotoPathId = 230
                RemoveFallbackFileId = 5; RemoveFallbackPathId = 341
            },
            [pscustomobject]@{
                RelativePath = 'sharedassets3.assets'; TargetNames = @('Anton Form Text', 'TT2020StyleG-Regular SDF')
                TemplatePath = 'sharedassets1.assets'; TemplateFontName = 'Roboto-Regular Shadow'
                NotoFileId = 3; NotoPathId = 341
            },
            [pscustomobject]@{
                RelativePath = 'sharedassets5.assets'; TargetNames = @(
                    'ArvoRegular', 'ArvoRegularOutlined', 'FrancoisOne-Outline', 'RobotoSlab-Typewriter'
                )
                TemplatePath = 'sharedassets5.assets'; TemplateFontName = 'Roboto-BoldOutlineThick'
                NotoFileId = 7; NotoPathId = 230
                RemoveFallbackFileId = 5; RemoveFallbackPathId = 341
            }
        )

        foreach ($plan in $additionalFontPlans) {
            $targetAssetPath = Join-Path $dataRoot $plan.RelativePath
            $targetTempPath = "$targetAssetPath.jp-tmp"
            if (Test-Path -LiteralPath $targetTempPath) {
                throw "Temporary font output already exists; no additional font assets were changed: $targetTempPath"
            }

            $planManager = [AssetsTools.NET.Extra.AssetsManager]::new()
            try {
                $planManager.LoadClassPackage((Join-Path $toolsRoot 'classdata.tpk')) | Out-Null
                $planClassDatabase = $planManager.LoadClassDatabaseFromPackage('2019.4.40f1')
                $planManager.MonoTempGenerator = [AssetsTools.NET.Extra.MonoCecilTempGenerator]::new((Join-Path $dataRoot 'Managed'))
                $null = $planManager.LoadAssetsFile((Join-Path $dataRoot 'globalgamemanagers.assets'), $true)
                $targetInstance = $planManager.LoadAssetsFile($targetAssetPath, $true)
                $templatePath = Join-Path $dataRoot $plan.TemplatePath
                if ($plan.TemplatePath -ceq $plan.RelativePath) {
                    $templateInstance = $targetInstance
                }
                else {
                    $templateInstance = $planManager.LoadAssetsFile($templatePath, $true)
                }

                $templateAsset = $null
                foreach ($assetInfo in $templateInstance.file.GetAssetsOfType([int]114)) {
                    $base = $planManager.GetBaseField($templateInstance, $assetInfo)
                    if ([string]$base['m_Name'].AsString -ceq [string]$plan.TemplateFontName) {
                        $templateAsset = $assetInfo
                        break
                    }
                }
                if ($null -eq $templateAsset) {
                    throw "TMP fallback template font was not found: $($plan.TemplatePath) / $($plan.TemplateFontName)"
                }
                $templateBase = $planManager.GetBaseField($templateInstance, $templateAsset)
                $templateFallbacks = $templateBase['m_FallbackFontAssetTable'].Children[0].Children
                $notoReference = $null
                foreach ($reference in $templateFallbacks) {
                    if ([int]$reference.Children[0].AsInt -eq [int]$plan.NotoFileId -and [long]$reference.Children[1].AsLong -eq [long]$plan.NotoPathId) {
                        $notoReference = $reference
                        break
                    }
                }
                if ($null -eq $notoReference) {
                    throw "TMP fallback template no longer points to the expected Japanese font: $($plan.TemplatePath) / $($plan.TemplateFontName)"
                }

                $targetByName = @{}
                foreach ($assetInfo in $targetInstance.file.GetAssetsOfType([int]114)) {
                    $base = $planManager.GetBaseField($targetInstance, $assetInfo)
                    $name = [string]$base['m_Name'].AsString
                    if ($plan.TargetNames -ccontains $name) { $targetByName[$name] = $assetInfo }
                }
                foreach ($fontName in $plan.TargetNames) {
                    if (-not $targetByName.ContainsKey([string]$fontName)) {
                        throw "Expected TMP font was not found: $($plan.RelativePath) / $fontName"
                    }
                }

                $replacers = [System.Collections.Generic.List[AssetsTools.NET.AssetsReplacer]]::new()
                $expectedFallbackReferences = [System.Collections.Generic.List[object]]::new()
                $expectedFallbackReferences.Add([pscustomobject]@{ FileId = [int]$plan.NotoFileId; PathId = [long]$plan.NotoPathId })
                foreach ($fontName in $plan.TargetNames) {
                    $fontInfo = $targetByName[[string]$fontName]
                    $fontBase = $planManager.GetBaseField($targetInstance, $fontInfo)
                    $fallbackArray = $fontBase['m_FallbackFontAssetTable'].Children[0]
                    $fontChanged = $false

                    if ($null -ne $plan.RemoveFallbackPathId) {
                        for ($fallbackIndex = $fallbackArray.Children.Count - 1; $fallbackIndex -ge 0; $fallbackIndex--) {
                            $reference = $fallbackArray.Children[$fallbackIndex]
                            if ([int]$reference.Children[0].AsInt -eq [int]$plan.RemoveFallbackFileId -and [long]$reference.Children[1].AsLong -eq [long]$plan.RemoveFallbackPathId) {
                                $fallbackArray.Children.RemoveAt($fallbackIndex)
                                $fontChanged = $true
                            }
                        }
                    }

                    foreach ($expectedReference in $expectedFallbackReferences) {
                        $hasExpectedFallback = $false
                        foreach ($reference in $fallbackArray.Children) {
                            if ([int]$reference.Children[0].AsInt -eq [int]$expectedReference.FileId -and [long]$reference.Children[1].AsLong -eq [long]$expectedReference.PathId) {
                                $hasExpectedFallback = $true
                                break
                            }
                        }
                        if (-not $hasExpectedFallback) {
                            $fallbackArray.Children.Add($notoReference)
                            $fontChanged = $true
                        }
                    }
                    if ($fontChanged) {
                        $fallbackArray.Value.AsArray.size = $fallbackArray.Children.Count
                        $replacers.Add([AssetsTools.NET.AssetsReplacerFromMemory]::new($targetInstance.file, $fontInfo, $fontBase))
                    }
                }

                if ($plan.RelativePath -ceq 'sharedassets2.assets') {
                    # This bold Japanese font is dynamic, but its single 1024px atlas was
                    # capped. Multi-atlas prevents overflow glyphs from switching to the
                    # regular Noto fallback removed from the selected UI font assets.
                    $boldJapaneseFont = $null
                    foreach ($assetInfo in $targetInstance.file.GetAssetsOfType([int]114)) {
                        $base = $planManager.GetBaseField($targetInstance, $assetInfo)
                        if ([string]$base['m_Name'].AsString -ceq 'NotoJPBoldOutline') {
                            $boldJapaneseFont = $assetInfo
                            break
                        }
                    }
                    if ($null -eq $boldJapaneseFont) { throw 'NotoJPBoldOutline was not found in sharedassets2.assets.' }
                    $boldJapaneseBase = $planManager.GetBaseField($targetInstance, $boldJapaneseFont)
                    $boldSourcePointer = $boldJapaneseBase['m_SourceFontFile']
                    if ([int]$boldSourcePointer.Children[0].AsInt -ne 5 -or [long]$boldSourcePointer.Children[1].AsLong -ne 234) {
                        throw 'NotoJPBoldOutline no longer uses the expected NotoSansJP-Bold source font.'
                    }
                    if ([int]$boldJapaneseBase['m_AtlasPopulationMode'].AsInt -ne 1) {
                        throw 'NotoJPBoldOutline is not a dynamic TMP font; refusing to enable multi-atlas mode.'
                    }
                    $boldMultiAtlas = $boldJapaneseBase['m_IsMultiAtlasTexturesEnabled']
                    if ($null -eq $boldMultiAtlas -or $null -eq $boldMultiAtlas.Value -or $boldMultiAtlas.Value.ValueType -ne [AssetsTools.NET.AssetValueType]::UInt8) {
                        throw 'NotoJPBoldOutline has an unexpected multi-atlas setting.'
                    }
                    if (-not [bool]$boldMultiAtlas.AsBool) {
                        $boldMultiAtlas.AsByte = [byte]1
                        $replacers.Add([AssetsTools.NET.AssetsReplacerFromMemory]::new($targetInstance.file, $boldJapaneseFont, $boldJapaneseBase))
                    }
                }

                if ($replacers.Count -eq 0) {
                    Write-Output "$($plan.RelativePath): Japanese TMP fallbacks are already present on all selected fonts."
                    continue
                }

                $writer = [System.IO.File]::Create($targetTempPath)
                try { $targetInstance.file.Write($writer, 0, $replacers, $planClassDatabase) }
                finally { $writer.Dispose() }

                $verifyManager = [AssetsTools.NET.Extra.AssetsManager]::new()
                try {
                    $verifyManager.LoadClassPackage((Join-Path $toolsRoot 'classdata.tpk')) | Out-Null
                    $null = $verifyManager.LoadClassDatabaseFromPackage('2019.4.40f1')
                    $verifyManager.MonoTempGenerator = [AssetsTools.NET.Extra.MonoCecilTempGenerator]::new((Join-Path $dataRoot 'Managed'))
                    $null = $verifyManager.LoadAssetsFile((Join-Path $dataRoot 'globalgamemanagers.assets'), $true)
                    $verifiedFile = $verifyManager.LoadAssetsFile($targetTempPath, $true)
                    foreach ($fontName in $plan.TargetNames) {
                        $verifiedAsset = $null
                        foreach ($assetInfo in $verifiedFile.file.GetAssetsOfType([int]114)) {
                            $base = $verifyManager.GetBaseField($verifiedFile, $assetInfo)
                            if ([string]$base['m_Name'].AsString -ceq [string]$fontName) { $verifiedAsset = $assetInfo; break }
                        }
                        if ($null -eq $verifiedAsset) { throw "TMP font verification failed: $($plan.RelativePath) / $fontName" }
                        $verifiedBase = $verifyManager.GetBaseField($verifiedFile, $verifiedAsset)
                        $verifiedFallbacks = $verifiedBase['m_FallbackFontAssetTable'].Children[0].Children
                        foreach ($expectedReference in $expectedFallbackReferences) {
                            $verifiedNoto = $false
                            foreach ($reference in $verifiedFallbacks) {
                                if ([int]$reference.Children[0].AsInt -eq [int]$expectedReference.FileId -and [long]$reference.Children[1].AsLong -eq [long]$expectedReference.PathId) {
                                    $verifiedNoto = $true
                                    break
                                }
                            }
                            if (-not $verifiedNoto) { throw "Serialized-file verification failed: $($plan.RelativePath) / $fontName lacks fallback $($expectedReference.FileId):$($expectedReference.PathId)." }
                        }
                        if ($null -ne $plan.RemoveFallbackPathId) {
                            foreach ($reference in $verifiedFallbacks) {
                                if ([int]$reference.Children[0].AsInt -eq [int]$plan.RemoveFallbackFileId -and [long]$reference.Children[1].AsLong -eq [long]$plan.RemoveFallbackPathId) {
                                    throw "Serialized-file verification failed: $($plan.RelativePath) / $fontName still points to the inconsistent regular Japanese fallback."
                                }
                            }
                        }
                    }
                    if ($plan.RelativePath -ceq 'sharedassets2.assets') {
                        $verifiedBoldJapaneseFont = $null
                        foreach ($assetInfo in $verifiedFile.file.GetAssetsOfType([int]114)) {
                            $base = $verifyManager.GetBaseField($verifiedFile, $assetInfo)
                            if ([string]$base['m_Name'].AsString -ceq 'NotoJPBoldOutline') { $verifiedBoldJapaneseFont = $assetInfo; break }
                        }
                        if ($null -eq $verifiedBoldJapaneseFont) { throw 'Serialized-file verification failed: NotoJPBoldOutline is missing.' }
                        $verifiedBoldBase = $verifyManager.GetBaseField($verifiedFile, $verifiedBoldJapaneseFont)
                        if ([byte]$verifiedBoldBase['m_IsMultiAtlasTexturesEnabled'].AsByte -ne [byte]1) {
                            throw 'Serialized-file verification failed: NotoJPBoldOutline multi-atlas mode is disabled.'
                        }
                        $verifiedSourcePointer = $verifiedBoldBase['m_SourceFontFile']
                        if ([int]$verifiedSourcePointer.Children[0].AsInt -ne 5 -or [long]$verifiedSourcePointer.Children[1].AsLong -ne 234) {
                            throw 'Serialized-file verification failed: NotoJPBoldOutline source font reference changed.'
                        }
                    }
                }
                finally { $verifyManager.UnloadAll() }

                $planManager.UnloadAll()
                $planManager = $null
                Move-FileOverwriting $targetTempPath $targetAssetPath
                $changedFiles.Add($plan.RelativePath)
                if ($plan.RelativePath -ceq 'sharedassets2.assets') {
                    Write-Output ("{0}: verified consistent bold Japanese multi-atlas fallback on {1} TMP font assets." -f $plan.RelativePath, $plan.TargetNames.Count)
                }
                else {
                    Write-Output ("{0}: verified consistent bold Japanese fallback on {1} TMP font assets." -f $plan.RelativePath, $plan.TargetNames.Count)
                }
            }
            finally {
                if ($null -ne $planManager) { $planManager.UnloadAll() }
                if (Test-Path -LiteralPath $targetTempPath) { Remove-Item -LiteralPath $targetTempPath -Force }
            }
        }
    }

    $sceneLocatorsByKey = @{}
    $sceneLocatorKeysByAsset = @{}
    $seenSceneLocatorKeys = @{}
    foreach ($locator in $catalog.sceneText) {
        $childPath = [int[]]@($locator.childPath | ForEach-Object { [int]$_ })
        $positionKey = Get-ScenePositionKey ([string]$locator.asset) ([long]$locator.pathId) $childPath
        if ($sceneLocatorsByKey.ContainsKey($positionKey)) { throw "Duplicate scene text position: $positionKey" }
        $sceneLocatorsByKey[$positionKey] = $locator
        $assetName = [string]$locator.asset
        if (-not $sceneLocatorKeysByAsset.ContainsKey($assetName)) { $sceneLocatorKeysByAsset[$assetName] = [System.Collections.Generic.List[string]]::new() }
        $sceneLocatorKeysByAsset[$assetName].Add($positionKey)
    }
    # Keep the Japanese glyphs within the fixed designer panels. The path IDs
    # below are checked against their known source sizes before any edit.
    $designerTextLayoutTargets = @{
        'level2:2850' = [pscustomobject]@{ SourceSize = 64.0; FontSize = 40.0; Min = 32.0; Max = 40.0 }
        'level2:2810' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2814' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2923' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2829' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2917' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2851' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2889' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2888' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2792' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2924' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2898' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2826' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'level2:2928' = [pscustomobject]@{ SourceSize = 48.0; FontSize = 40.0; Min = 28.0; Max = 40.0 }
        'level2:2891' = [pscustomobject]@{ SourceSize = 36.0; FontSize = 32.0; Min = 24.0; Max = 32.0 }
        'sharedassets2.assets:256' = [pscustomobject]@{ SourceSize = 40.0; FontSize = 30.0; Min = 22.0; Max = 30.0 }
    }
    # PartStatsPanel creates ship and part performance rows from this shared
    # TextOptions asset. A small size reduction prevents Japanese rows colliding.
    $partStatsTextOptionSizeTargets = @{
        'sharedassets2.assets:249' = [pscustomobject]@{ SourceSize = 36; Size = 32 }
    }
    # The post-mission report title uses a fixed TMP box inside the folder tab.
    # Nudge only this title down slightly to compensate for the Japanese glyph baseline.
    $missionTitleRectTransformTargets = @{
        'level3:420' = [pscustomobject]@{ SourceY = 5.0; Y = 0.0 }
    }
    # The story dialogue component's bold outlined font has a tiny pre-baked
    # Japanese atlas, and adding more TMP fallbacks did not render all glyphs.
    # Assign the game's dynamic Japanese TMP font directly to this text only.
    $storyDialogueComponentPathId = [long]2461
    $storyDialogueOriginalFontFileId = 7
    $storyDialogueOriginalFontPathId = [long]231
    $storyDialoguePreviousFontFileId = 5
    $storyDialoguePreviousFontPathId = [long]342
    $storyDialogueJapaneseFontFileId = 5
    $storyDialogueJapaneseFontPathId = [long]341
    if ($MenusOnly) {
        $serializedFileNames = @()
        Write-Output 'Menu-only mode: Unity scene and StreamingAssets text were not changed.'
    }
    else {
        # Restrict level1 edits to known mission-report labels, settings-panel
        # text, and selected input hints; unrelated scene fields stay intact.
        $serializedFileNames = @(0..8 | ForEach-Object { "level$_" }) + @('sharedassets0.assets', 'sharedassets2.assets', 'sharedassets5.assets')
        Write-Output 'Unity text is selected by serialized asset position; font and layout targets remain separately restricted.'
    }
    foreach ($sceneName in $serializedFileNames) {
        $scenePath = Join-Path $dataRoot $sceneName
        if (-not (Test-Path -LiteralPath $scenePath -PathType Leaf)) {
            throw "Unity scene asset is missing: $scenePath"
        }

        $manager = [AssetsTools.NET.Extra.AssetsManager]::new()
        $tempPath = "$scenePath.jp-tmp"
        try {
            $manager.LoadClassPackage((Join-Path $toolsRoot 'classdata.tpk')) | Out-Null
            $classDatabase = $manager.LoadClassDatabaseFromPackage('2019.4.40f1')
            $manager.MonoTempGenerator = [AssetsTools.NET.Extra.MonoCecilTempGenerator]::new((Join-Path $dataRoot 'Managed'))
            $null = $manager.LoadAssetsFile((Join-Path $dataRoot 'globalgamemanagers.assets'), $true)
            $sceneInstance = $manager.LoadAssetsFile($scenePath, $true)
            $replacers = [System.Collections.Generic.List[AssetsTools.NET.AssetsReplacer]]::new()
            $expectedByLocator = @{}
            $expectedFontByPathId = @{}
            $expectedLayoutByPathId = @{}
            $expectedTextOptionsSizeByPathId = @{}
            $expectedPositionYByPathId = @{}
            $sceneCandidatePathIds = [System.Collections.Generic.HashSet[long]]::new()
            if ($sceneLocatorKeysByAsset.ContainsKey($sceneName)) {
                foreach ($positionKey in $sceneLocatorKeysByAsset[$sceneName]) {
                    [void]$sceneCandidatePathIds.Add([long]$sceneLocatorsByKey[$positionKey].pathId)
                }
            }
            foreach ($layoutKey in (@($designerTextLayoutTargets.Keys) + @($partStatsTextOptionSizeTargets.Keys))) {
                $assetPrefix = $sceneName + ':'
                if ($layoutKey.StartsWith($assetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$sceneCandidatePathIds.Add([long]$layoutKey.Substring($assetPrefix.Length))
                }
            }
            if ($sceneName -eq 'level5') { [void]$sceneCandidatePathIds.Add($storyDialogueComponentPathId) }

            foreach ($assetInfo in $sceneInstance.file.GetAssetsOfType([int]114)) {
                if (-not $sceneCandidatePathIds.Contains([long]$assetInfo.PathId)) { continue }
                $baseField = $manager.GetBaseField($sceneInstance, $assetInfo)
                $changedHere = $false
                $layoutKey = '{0}:{1}' -f $sceneName, [long]$assetInfo.PathId
                if ($partStatsTextOptionSizeTargets.ContainsKey($layoutKey)) {
                    $sizeTarget = $partStatsTextOptionSizeTargets[$layoutKey]
                    $sizeField = $baseField['size']
                    if ($null -eq $sizeField -or $null -eq $sizeField.Value) {
                        throw "Part stats TextOptions size field is missing: $sceneName / $($assetInfo.PathId)"
                    }
                    $currentTextOptionsSize = [int]$sizeField.AsInt
                    if ($currentTextOptionsSize -eq [int]$sizeTarget.SourceSize) {
                        $sizeField.AsInt = [int]$sizeTarget.Size
                        $changedHere = $true
                    }
                    elseif ($currentTextOptionsSize -ne [int]$sizeTarget.Size) {
                        throw "Unexpected part stats TextOptions size; refusing to overwrite: $sceneName / $($assetInfo.PathId)"
                    }
                    if ($currentTextOptionsSize -ne [int]$sizeTarget.Size) {
                        $expectedTextOptionsSizeByPathId[[string]$assetInfo.PathId] = $sizeTarget
                    }
                }
                if ($designerTextLayoutTargets.ContainsKey($layoutKey)) {
                    $layout = $designerTextLayoutTargets[$layoutKey]
                    $fontSizeField = $baseField['m_fontSize']
                    $autoSizeField = $baseField['m_enableAutoSizing']
                    $fontSizeMinField = $baseField['m_fontSizeMin']
                    $fontSizeMaxField = $baseField['m_fontSizeMax']
                    if ($null -eq $fontSizeField -or $null -eq $fontSizeField.Value -or
                        $null -eq $autoSizeField -or $null -eq $autoSizeField.Value -or
                        $null -eq $fontSizeMinField -or $null -eq $fontSizeMinField.Value -or
                        $null -eq $fontSizeMaxField -or $null -eq $fontSizeMaxField.Value) {
                        throw "Designer TMP layout fields are missing or have an unexpected serialized layout: $sceneName / $($assetInfo.PathId)"
                    }
                    $currentSize = [double]$fontSizeField.AsFloat
                    $currentAutoSize = [bool]$autoSizeField.AsBool
                    $currentMin = [double]$fontSizeMinField.AsFloat
                    $currentMax = [double]$fontSizeMaxField.AsFloat
                    $isTargetLayout = [Math]::Abs($currentSize - [double]$layout.FontSize) -lt 0.01 -and
                        $currentAutoSize -and
                        [Math]::Abs($currentMin - [double]$layout.Min) -lt 0.01 -and
                        [Math]::Abs($currentMax - [double]$layout.Max) -lt 0.01
                    $isSourceLayout = [Math]::Abs($currentSize - [double]$layout.SourceSize) -lt 0.01 -and
                        -not $currentAutoSize -and
                        [Math]::Abs($currentMin - 18.0) -lt 0.01 -and
                        [Math]::Abs($currentMax - 72.0) -lt 0.01
                    if ($isSourceLayout) {
                        $fontSizeField.AsFloat = [single]$layout.FontSize
                        $autoSizeField.AsByte = [byte]1
                        $fontSizeMinField.AsFloat = [single]$layout.Min
                        $fontSizeMaxField.AsFloat = [single]$layout.Max
                        $changedHere = $true
                    }
                    elseif (-not $isTargetLayout) {
                        throw "Unexpected designer TMP layout; refusing to overwrite: $sceneName / $($assetInfo.PathId)"
                    }
                    if (-not $isTargetLayout) {
                        $expectedLayoutByPathId[[string]$assetInfo.PathId] = $layout
                    }
                }
                if ($sceneName -eq 'level5' -and [long]$assetInfo.PathId -eq $storyDialogueComponentPathId) {
                    $fontPointer = $baseField['m_fontAsset']
                    if ($null -eq $fontPointer -or $fontPointer.Children.Count -lt 2) {
                        throw 'Story dialogue TMP font pointer is missing or has an unexpected serialized layout.'
                    }
                    $currentFontFileId = [int]$fontPointer.Children[0].AsInt
                    $currentFontPathId = [long]$fontPointer.Children[1].AsLong
                    $isOriginalFont = $currentFontFileId -eq $storyDialogueOriginalFontFileId -and $currentFontPathId -eq $storyDialogueOriginalFontPathId
                    $isPreviousJapaneseFont = $currentFontFileId -eq $storyDialoguePreviousFontFileId -and $currentFontPathId -eq $storyDialoguePreviousFontPathId
                    if ($isOriginalFont -or $isPreviousJapaneseFont) {
                        $fontPointer.Children[0].AsInt = $storyDialogueJapaneseFontFileId
                        $fontPointer.Children[1].AsLong = $storyDialogueJapaneseFontPathId
                        $changedHere = $true
                    }
                    elseif ($currentFontFileId -ne $storyDialogueJapaneseFontFileId -or $currentFontPathId -ne $storyDialogueJapaneseFontPathId) {
                        throw "Unexpected story dialogue font reference: $currentFontFileId`:$currentFontPathId"
                    }
                    $expectedFontByPathId[[string]$assetInfo.PathId] = [pscustomobject]@{
                        FileId = $storyDialogueJapaneseFontFileId
                        PathId = $storyDialogueJapaneseFontPathId
                    }
                }
                $stack = [System.Collections.Generic.Stack[object]]::new()
                $stack.Push([pscustomobject]@{ Field = $baseField; ChildPath = [int[]]@() })
                while ($stack.Count -gt 0) {
                    $node = $stack.Pop()
                    $field = $node.Field
                    $childPath = [int[]]$node.ChildPath
                    $positionKey = Get-ScenePositionKey $sceneName ([long]$assetInfo.PathId) $childPath
                    if ($null -ne $field.Value -and $field.Value.ValueType -eq [AssetsTools.NET.AssetValueType]::String -and $sceneLocatorsByKey.ContainsKey($positionKey)) {
                        $seenSceneLocatorKeys[$positionKey] = $true
                        $originalText = [string]$field.Value.AsString
                        $locatedText = Get-ScenePositionedText $originalText $sceneLocatorsByKey[$positionKey] "$sceneName path $($assetInfo.PathId) field $([string]::Join(',', [string[]]$childPath))"
                        $expectedByLocator[$positionKey] = [string]$sceneLocatorsByKey[$positionKey].targetSha256
                        if ($locatedText.Changed) {
                            $field.Value.AsString = [string]$locatedText.Value
                            $changedHere = $true
                        }
                    }
                    for ($childIndex = 0; $childIndex -lt $field.Children.Count; $childIndex++) {
                        $nextPath = [int[]]@($childPath + $childIndex)
                        $stack.Push([pscustomobject]@{ Field = $field.Children[$childIndex]; ChildPath = $nextPath })
                    }
                }
                if ($changedHere) {
                    $replacers.Add([AssetsTools.NET.AssetsReplacerFromMemory]::new($sceneInstance.file, $assetInfo, $baseField))
                }
            }

            if ($sceneLocatorKeysByAsset.ContainsKey($sceneName)) {
                foreach ($positionKey in $sceneLocatorKeysByAsset[$sceneName]) {
                    if (-not $seenSceneLocatorKeys.ContainsKey([string]$positionKey)) { throw "Scene text position was not found: $positionKey" }
                }
            }

            foreach ($assetInfo in $sceneInstance.file.GetAssetsOfType([int]224)) {
                $layoutKey = '{0}:{1}' -f $sceneName, [long]$assetInfo.PathId
                if (-not $missionTitleRectTransformTargets.ContainsKey($layoutKey)) { continue }
                $positionTarget = $missionTitleRectTransformTargets[$layoutKey]
                $baseField = $manager.GetBaseField($sceneInstance, $assetInfo)
                $positionY = $baseField['m_AnchoredPosition']['y']
                if ($null -eq $positionY) {
                    throw "Report title RectTransform position is missing: $sceneName / $($assetInfo.PathId)"
                }
                $currentPositionY = [double]$positionY.AsFloat
                if ([Math]::Abs($currentPositionY - [double]$positionTarget.SourceY) -lt 0.01) {
                    $positionY.AsFloat = [single]$positionTarget.Y
                    $replacers.Add([AssetsTools.NET.AssetsReplacerFromMemory]::new($sceneInstance.file, $assetInfo, $baseField))
                    $expectedPositionYByPathId[[string]$assetInfo.PathId] = $positionTarget
                }
                elseif ([Math]::Abs($currentPositionY - [double]$positionTarget.Y) -ge 0.01) {
                    throw "Unexpected report title position; refusing to overwrite: $sceneName / $($assetInfo.PathId)"
                }
            }

            if ($replacers.Count -gt 0) {
                $writer = [System.IO.File]::Create($tempPath)
                try { $sceneInstance.file.Write($writer, 0, $replacers, $classDatabase) }
                finally { $writer.Dispose() }
                if (-not (Test-Path -LiteralPath $tempPath -PathType Leaf)) { throw "Serialized scene writer produced no output: $sceneName" }

                # Verify using a second manager while the candidate is beside its dependencies.
                $verifyManager = [AssetsTools.NET.Extra.AssetsManager]::new()
                try {
                    $verifyManager.LoadClassPackage((Join-Path $toolsRoot 'classdata.tpk')) | Out-Null
                    $null = $verifyManager.LoadClassDatabaseFromPackage('2019.4.40f1')
                    $verifyManager.MonoTempGenerator = [AssetsTools.NET.Extra.MonoCecilTempGenerator]::new((Join-Path $dataRoot 'Managed'))
                    $null = $verifyManager.LoadAssetsFile((Join-Path $dataRoot 'globalgamemanagers.assets'), $true)
                    $verifiedScene = $verifyManager.LoadAssetsFile($tempPath, $true)
                    foreach ($positionKey in $expectedByLocator.Keys) {
                        $locator = $sceneLocatorsByKey[$positionKey]
                        $verifiedAsset = $null
                        foreach ($candidateAsset in $verifiedScene.file.GetAssetsOfType([int]114)) {
                            if ([long]$candidateAsset.PathId -eq [long]$locator.pathId) { $verifiedAsset = $candidateAsset; break }
                        }
                        if ($null -eq $verifiedAsset) { throw "Serialized scene position verification failed: $positionKey" }
                        $verifiedField = $verifyManager.GetBaseField($verifiedScene, $verifiedAsset)
                        foreach ($childIndex in $locator.childPath) {
                            if ([int]$childIndex -lt 0 -or [int]$childIndex -ge $verifiedField.Children.Count) { throw "Serialized scene field path verification failed: $positionKey" }
                            $verifiedField = $verifiedField.Children[[int]$childIndex]
                        }
                        if ($null -eq $verifiedField.Value -or $verifiedField.Value.ValueType -ne [AssetsTools.NET.AssetValueType]::String -or
                            (Get-Sha256Hex ([string]$verifiedField.Value.AsString)) -cne [string]$expectedByLocator[$positionKey]) {
                            throw "Serialized scene text locator verification failed: $positionKey"
                        }
                    }
                    foreach ($pathId in $expectedFontByPathId.Keys) {
                        $verifiedComponent = $verifiedScene.file.GetAssetsOfType([int]114) | Where-Object { [string]$_.PathId -eq $pathId } | Select-Object -First 1
                        if ($null -eq $verifiedComponent) { throw "Serialized scene font verification failed: $sceneName pathID $pathId" }
                        $verifiedComponentBase = $verifyManager.GetBaseField($verifiedScene, $verifiedComponent)
                        $verifiedFontPointer = $verifiedComponentBase['m_fontAsset']
                        $expectedFont = $expectedFontByPathId[$pathId]
                        if ([int]$verifiedFontPointer.Children[0].AsInt -ne [int]$expectedFont.FileId -or [long]$verifiedFontPointer.Children[1].AsLong -ne [long]$expectedFont.PathId) {
                            throw "Serialized scene font reference verification failed: $sceneName pathID $pathId"
                        }
                    }
                    foreach ($pathId in $expectedLayoutByPathId.Keys) {
                        $verifiedComponent = $verifiedScene.file.GetAssetsOfType([int]114) | Where-Object { [string]$_.PathId -eq $pathId } | Select-Object -First 1
                        if ($null -eq $verifiedComponent) { throw "Serialized TMP layout verification failed: $sceneName pathID $pathId" }
                        $verifiedBase = $verifyManager.GetBaseField($verifiedScene, $verifiedComponent)
                        $layout = $expectedLayoutByPathId[$pathId]
                        $verifiedAutoSize = $verifiedBase['m_enableAutoSizing']
                        $verifiedMin = $verifiedBase['m_fontSizeMin']
                        $verifiedMax = $verifiedBase['m_fontSizeMax']
                        if ([Math]::Abs([double]$verifiedBase['m_fontSize'].AsFloat - [double]$layout.FontSize) -ge 0.01 -or
                            -not [bool]$verifiedAutoSize.AsBool -or
                            [Math]::Abs([double]$verifiedMin.AsFloat - [double]$layout.Min) -ge 0.01 -or
                            [Math]::Abs([double]$verifiedMax.AsFloat - [double]$layout.Max) -ge 0.01) {
                            throw "Serialized TMP layout verification failed: $sceneName pathID $pathId"
                        }
                    }
                    foreach ($pathId in $expectedTextOptionsSizeByPathId.Keys) {
                        $verifiedAsset = $verifiedScene.file.GetAssetsOfType([int]114) | Where-Object { [string]$_.PathId -eq $pathId } | Select-Object -First 1
                        if ($null -eq $verifiedAsset) { throw "Part stats TextOptions verification failed: $sceneName pathID $pathId" }
                        $verifiedBase = $verifyManager.GetBaseField($verifiedScene, $verifiedAsset)
                        $sizeTarget = $expectedTextOptionsSizeByPathId[$pathId]
                        if ([int]$verifiedBase['size'].AsInt -ne [int]$sizeTarget.Size) {
                            throw "Part stats TextOptions size verification failed: $sceneName pathID $pathId"
                        }
                        Write-Output ("{0} path {1}: performance text size set to {2} and verified." -f $sceneName, $pathId, $sizeTarget.Size)
                    }
                    foreach ($pathId in $expectedPositionYByPathId.Keys) {
                        $verifiedAsset = $verifiedScene.file.GetAssetsOfType([int]224) | Where-Object { [string]$_.PathId -eq $pathId } | Select-Object -First 1
                        if ($null -eq $verifiedAsset) { throw "Report title RectTransform verification failed: $sceneName pathID $pathId" }
                        $verifiedBase = $verifyManager.GetBaseField($verifiedScene, $verifiedAsset)
                        $positionTarget = $expectedPositionYByPathId[$pathId]
                        if ([Math]::Abs([double]$verifiedBase['m_AnchoredPosition']['y'].AsFloat - [double]$positionTarget.Y) -ge 0.01) {
                            throw "Report title vertical position verification failed: $sceneName pathID $pathId"
                        }
                        Write-Output ("{0} path {1}: report title moved down and verified." -f $sceneName, $pathId)
                    }
                }
                finally { $verifyManager.UnloadAll() }

                $manager.UnloadAll()
                $manager = $null
                Move-FileOverwriting $tempPath $scenePath
                $changedFiles.Add($sceneName)
                Write-Output ("{0}: updated {1} serialized objects; text and layout verified after re-reading." -f $sceneName, $replacers.Count)
            }
            else {
                Write-Output ("{0}: no matching English scene strings (already applied or not in catalog)." -f $sceneName)
            }
        }
        finally {
            if ($null -ne $manager) { $manager.UnloadAll() }
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
        }
    }
}

if ($FlowOnly -or (-not $MenusOnly -and -not $DataOnly)) {
    $flowLocatorScript = Join-Path $localizationRoot 'Tools\apply-flow-locators.ps1'
    if (-not (Test-Path -LiteralPath $flowLocatorScript -PathType Leaf)) {
        throw "Mission-flow locator script was not found: $flowLocatorScript"
    }
    if ($FlowFileNames.Count -gt 0) {
        $flowLocatorOutput = @(& $flowLocatorScript -DataRoot $dataRoot -FlowFileNames $FlowFileNames)
    }
    else {
        $flowLocatorOutput = @(& $flowLocatorScript -DataRoot $dataRoot)
    }
    foreach ($outputLine in $flowLocatorOutput) {
        Write-Output $outputLine
        if ([string]$outputLine -match '^([A-Za-z0-9_]+\.txt): translated ') {
            $changedFiles.Add(('Waves of Steel_Data/StreamingAssets/Missions/flow/' + $Matches[1]))
        }
    }
}
Write-Output "JSON text fields translated: $jsonChanged"
Write-Output "Changed files: $($changedFiles.Count)"
$changedFiles | ForEach-Object { Write-Output "  $_" }
if ($DataOnly) { Write-Output 'Scene translation skipped by -DataOnly.' }
