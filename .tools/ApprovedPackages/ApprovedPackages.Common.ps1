# ApprovedPackages.Common.ps1
# Shared logic for the approved-package tools.
# ASCII only. No user-facing text lives here; messages are loaded from ApprovedPackages.messages.json.
# Dot-source this file from a tool: . (Join-Path $PSScriptRoot 'ApprovedPackages.Common.ps1')

$script:ApprovedPackagesToolsDirectory = $PSScriptRoot
$script:ApprovedStatuses = @('approved', 'pending', 'deprecated', 'disabled')
$script:ApprovedPackageFieldNames = @('name', 'allowedVersions', 'purpose', 'status', 'approvedDate', 'notes')
$script:ApprovedPackagesSchemaVersion = 1
$script:ApprovedPackagesTestMarkerName = '.approved-packages-test-root'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

function Get-ApprovedPackagesPaths {
    param([string]$DataDirectory)

    $toolsDirectory = $script:ApprovedPackagesToolsDirectory
    $workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $toolsDirectory '..\..'))
    if ([string]::IsNullOrEmpty($DataDirectory)) {
        $dataDirectoryFull = Join-Path $workspaceRoot 'ApprovedPackages'
    } else {
        $dataDirectoryFull = [System.IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
    }
    return [pscustomobject]@{
        ToolsDirectory = $toolsDirectory
        WorkspaceRoot  = $workspaceRoot
        DataDirectory  = $dataDirectoryFull
        JsonPath       = Join-Path $dataDirectoryFull 'approved-packages.json'
        MarkdownPath   = Join-Path $dataDirectoryFull 'approved-packages.md'
        MessagesPath   = Join-Path $toolsDirectory 'ApprovedPackages.messages.json'
    }
}

function Resolve-TestDataDirectory {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) { return $null }
    $full = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not $full.StartsWith($temp + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $full $script:ApprovedPackagesTestMarkerName) -PathType Leaf)) { return $null }
    return $full
}

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

function Import-ToolMessages {
    param(
        [string]$Path,
        [string[]]$RequiredKeys
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Message file not found: $Path"
    }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = [System.IO.File]::ReadAllText($Path, $strictUtf8)
    } catch {
        throw "Message file is not valid UTF-8: $Path"
    }
    try {
        $loaded = $text | ConvertFrom-Json
    } catch {
        throw "Message file is not valid JSON: $Path"
    }
    $missing = @($RequiredKeys | Where-Object { $null -eq $loaded.PSObject.Properties[$_] })
    if ($missing.Count -gt 0) {
        throw ('Message file is missing required keys: ' + ($missing -join ', '))
    }
    return $loaded
}

function Get-ToolMessage {
    param(
        [object]$Messages,
        [string]$Key,
        [object[]]$FormatArgs
    )

    $property = $Messages.PSObject.Properties[$Key]
    if ($null -eq $property) { return ('[message not found: ' + $Key + ']') }
    $value = $property.Value
    if ($value -is [System.Array]) { $value = ($value -join [Environment]::NewLine) }
    $text = [string]$value
    if ($null -ne $FormatArgs -and $FormatArgs.Count -gt 0) {
        return [string]::Format($text, $FormatArgs)
    }
    return $text
}

# ---------------------------------------------------------------------------
# Package names
# ---------------------------------------------------------------------------

function ConvertTo-NormalizedPackageName {
    param([string]$Name)

    if ($null -eq $Name) { return '' }
    return ([regex]::Replace($Name, '[-_.]+', '-')).ToLowerInvariant()
}

function Test-PackageNameFormat {
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return $false }
    return ($Name -cmatch '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?\z')
}

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

function Test-AllowedVersionPattern {
    param([string]$Pattern)

    if ([string]::IsNullOrEmpty($Pattern)) { return $false }
    return ($Pattern -cmatch '^[0-9]+(\.[0-9]+)*(\.\*)*\z')
}

function Get-ConcreteVersionProblem {
    param([string]$Version)

    if ([string]::IsNullOrEmpty($Version)) { return 'Empty' }
    if ($Version -cmatch '^[0-9]+(\.[0-9]+)*\z') { return $null }
    if ($Version.Contains('*')) { return 'Wildcard' }
    if ($Version -cmatch '[A-Za-z+!_-]') { return 'Unsupported' }
    return 'Format'
}

function ConvertTo-VersionElements {
    param(
        [string]$Version,
        [switch]$TrimTrailingZeros
    )

    $elements = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in $Version.Split('.')) {
        $trimmed = $part.TrimStart('0')
        if ($trimmed.Length -eq 0) { $trimmed = '0' }
        $elements.Add($trimmed)
    }
    if ($TrimTrailingZeros.IsPresent) {
        while ($elements.Count -gt 1 -and $elements[$elements.Count - 1] -ceq '0') {
            $elements.RemoveAt($elements.Count - 1)
        }
    }
    return $elements.ToArray()
}

function Test-VersionsEqual {
    param(
        [string]$Left,
        [string]$Right
    )

    $a = @(ConvertTo-VersionElements -Version $Left -TrimTrailingZeros)
    $b = @(ConvertTo-VersionElements -Version $Right -TrimTrailingZeros)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -cne $b[$i]) { return $false }
    }
    return $true
}

function Test-VersionMatchesPattern {
    param(
        [string]$Version,
        [string]$Pattern
    )

    if ($null -ne (Get-ConcreteVersionProblem -Version $Version)) { return $false }
    if (-not (Test-AllowedVersionPattern -Pattern $Pattern)) { return $false }
    if (-not $Pattern.Contains('*')) {
        return (Test-VersionsEqual -Left $Version -Right $Pattern)
    }
    $numericPart = $Pattern.Substring(0, $Pattern.IndexOf('.*'))
    $patternElements = @(ConvertTo-VersionElements -Version $numericPart)
    $versionElements = @(ConvertTo-VersionElements -Version $Version)
    for ($i = 0; $i -lt $patternElements.Count; $i++) {
        $actual = '0'
        if ($i -lt $versionElements.Count) { $actual = $versionElements[$i] }
        if ($actual -cne $patternElements[$i]) { return $false }
    }
    return $true
}

function Test-VersionAllowedByList {
    param(
        [string[]]$AllowedVersions,
        [string]$Version
    )

    foreach ($pattern in @($AllowedVersions)) {
        if (Test-VersionMatchesPattern -Version $Version -Pattern $pattern) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Approved package list: objects, validation, lookup
# ---------------------------------------------------------------------------

function New-ApprovedPackage {
    param(
        [string]$Name,
        [string[]]$AllowedVersions,
        [string]$Purpose,
        [string]$Status,
        [string]$ApprovedDate,
        [string]$Notes
    )

    return [pscustomobject][ordered]@{
        name            = $Name
        allowedVersions = @($AllowedVersions | Where-Object { $null -ne $_ })
        purpose         = [string]$Purpose
        status          = $Status
        approvedDate    = [string]$ApprovedDate
        notes           = [string]$Notes
    }
}

function New-ProblemRecord {
    param(
        [string]$Code,
        [string]$Package,
        [string]$Detail
    )

    return [pscustomobject]@{ Code = $Code; Package = $Package; Detail = $Detail }
}

function Test-ApprovedDateText {
    param([string]$Text)

    if ($Text -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}\z') { return $false }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact($Text, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
}

function Test-ApprovedPackageList {
    param([object]$Data)

    $problems = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq $Data -or $Data -isnot [pscustomobject]) {
        $problems.Add((New-ProblemRecord -Code 'RootNotObject' -Package '' -Detail ''))
        return $problems.ToArray()
    }
    $topLevelNames = @($Data.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $topLevelNames) {
        if (@('schemaVersion', 'packages') -cnotcontains $name) {
            $problems.Add((New-ProblemRecord -Code 'UnknownField' -Package '' -Detail $name))
        }
    }
    $versionProperty = $Data.PSObject.Properties['schemaVersion']
    if ($null -eq $versionProperty) {
        $problems.Add((New-ProblemRecord -Code 'SchemaVersionMissing' -Package '' -Detail ''))
    } elseif (($versionProperty.Value -isnot [int]) -or $versionProperty.Value -ne $script:ApprovedPackagesSchemaVersion) {
        $problems.Add((New-ProblemRecord -Code 'SchemaVersionUnsupported' -Package '' -Detail ([string]$versionProperty.Value)))
    }
    $packagesProperty = $Data.PSObject.Properties['packages']
    if ($null -eq $packagesProperty -or $packagesProperty.Value -isnot [System.Array]) {
        $problems.Add((New-ProblemRecord -Code 'PackagesNotArray' -Package '' -Detail ''))
        return $problems.ToArray()
    }

    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $seenNormalized = @{}
    $index = 0
    foreach ($package in @($packagesProperty.Value)) {
        $index++
        $label = '#' + $index
        if ($package -isnot [pscustomobject]) {
            $problems.Add((New-ProblemRecord -Code 'PackageNotObject' -Package $label -Detail ''))
            continue
        }
        $present = @($package.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($field in $present) {
            if ($script:ApprovedPackageFieldNames -cnotcontains $field) {
                $problems.Add((New-ProblemRecord -Code 'UnknownField' -Package $label -Detail $field))
            }
        }
        $missing = @($script:ApprovedPackageFieldNames | Where-Object { $present -cnotcontains $_ })
        foreach ($field in $missing) {
            $problems.Add((New-ProblemRecord -Code 'FieldMissing' -Package $label -Detail $field))
        }
        if ($missing.Count -gt 0) { continue }

        foreach ($field in @('name', 'purpose', 'status', 'approvedDate', 'notes')) {
            if ($package.$field -isnot [string]) {
                $problems.Add((New-ProblemRecord -Code 'FieldNotString' -Package $label -Detail $field))
            }
        }
        if ($package.name -isnot [string]) { continue }
        $name = $package.name
        $label = $name
        if (-not (Test-PackageNameFormat -Name $name)) {
            $problems.Add((New-ProblemRecord -Code 'NameInvalid' -Package $name -Detail $name))
        } else {
            $normalized = ConvertTo-NormalizedPackageName -Name $name
            if (-not $seenNames.Add($name)) {
                $problems.Add((New-ProblemRecord -Code 'NameDuplicate' -Package $name -Detail $name))
            } elseif ($seenNormalized.ContainsKey($normalized)) {
                $problems.Add((New-ProblemRecord -Code 'NameDuplicateNormalized' -Package $name -Detail $seenNormalized[$normalized]))
            }
            if (-not $seenNormalized.ContainsKey($normalized)) { $seenNormalized[$normalized] = $name }
        }

        $versionsValue = $package.allowedVersions
        if ($versionsValue -isnot [System.Array]) {
            $problems.Add((New-ProblemRecord -Code 'AllowedVersionsNotArray' -Package $label -Detail ''))
        } else {
            $seenVersions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($version in @($versionsValue)) {
                if ($version -isnot [string] -or -not (Test-AllowedVersionPattern -Pattern $version)) {
                    $problems.Add((New-ProblemRecord -Code 'AllowedVersionInvalid' -Package $label -Detail ([string]$version)))
                } elseif (-not $seenVersions.Add($version)) {
                    $problems.Add((New-ProblemRecord -Code 'AllowedVersionDuplicate' -Package $label -Detail $version))
                }
            }
        }

        if ($package.status -is [string]) {
            if ($script:ApprovedStatuses -cnotcontains $package.status) {
                $problems.Add((New-ProblemRecord -Code 'StatusInvalid' -Package $label -Detail $package.status))
            } elseif ($package.approvedDate -is [string]) {
                if ($package.status -ceq 'approved') {
                    if (-not (Test-ApprovedDateText -Text $package.approvedDate)) {
                        $problems.Add((New-ProblemRecord -Code 'ApprovedDateInvalid' -Package $label -Detail $package.approvedDate))
                    }
                } elseif ($package.approvedDate -cne '') {
                    $problems.Add((New-ProblemRecord -Code 'ApprovedDateMustBeEmpty' -Package $label -Detail $package.approvedDate))
                }
            }
        }
    }
    return $problems.ToArray()
}

function Test-ApprovedPackageOrder {
    param([object[]]$Packages)

    $names = @($Packages | ForEach-Object { ConvertTo-NormalizedPackageName -Name $_.name })
    for ($i = 1; $i -lt $names.Count; $i++) {
        if ([string]::CompareOrdinal($names[$i - 1], $names[$i]) -ge 0) { return $false }
    }
    return $true
}

function Get-SortedPackages {
    param([object[]]$Packages)

    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($package in @($Packages)) { $list.Add($package) }
    $comparison = [System.Comparison[object]]{
        param($left, $right)
        [string]::CompareOrdinal((ConvertTo-NormalizedPackageName -Name $left.name), (ConvertTo-NormalizedPackageName -Name $right.name))
    }
    $list.Sort($comparison)
    return $list.ToArray()
}

function Find-ApprovedPackage {
    param(
        [object[]]$Packages,
        [string]$Name
    )

    $target = ConvertTo-NormalizedPackageName -Name $Name
    foreach ($package in @($Packages)) {
        if ((ConvertTo-NormalizedPackageName -Name $package.name) -ceq $target) { return $package }
    }
    return $null
}

function Get-LocalDateText {
    return (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-NextApprovedDate {
    param(
        [string]$OldStatus,
        [string]$NewStatus,
        [string]$OldDate,
        [string]$Today
    )

    if ($NewStatus -cne 'approved') { return '' }
    if ($OldStatus -ceq 'approved' -and -not [string]::IsNullOrEmpty($OldDate)) { return $OldDate }
    return $Today
}

# ---------------------------------------------------------------------------
# Install decisions (also used by the install tool)
# ---------------------------------------------------------------------------

function Get-PackageInstallDecision {
    param(
        [object]$Package,
        [string]$RequestedVersion
    )

    $decision = [pscustomobject]@{
        Allowed               = $false
        Code                  = ''
        Detail                = ''
        Warning               = ''
        RequiresVersionChoice = $false
        FixedVersion          = ''
    }
    if ($null -eq $Package) {
        $decision.Code = 'NotRegistered'
        return $decision
    }
    switch ($Package.status) {
        'approved' { }
        'pending' { $decision.Code = 'StatusPending'; return $decision }
        'deprecated' { $decision.Code = 'StatusDeprecated'; return $decision }
        'disabled' { $decision.Code = 'StatusDisabled'; return $decision }
        default { $decision.Code = 'StatusInvalid'; return $decision }
    }
    $hasRequested = -not [string]::IsNullOrEmpty($RequestedVersion)
    if ($hasRequested) {
        $problem = Get-ConcreteVersionProblem -Version $RequestedVersion
        if ($null -ne $problem) {
            $decision.Code = 'VersionUnsupportedFormat'
            $decision.Detail = $problem
            return $decision
        }
    }
    $allowed = @($Package.allowedVersions)
    if ($allowed.Count -eq 0) {
        $decision.Allowed = $true
        $decision.Code = 'AllowedAnyVersion'
        $decision.Warning = 'AnyVersion'
        return $decision
    }
    if ($hasRequested) {
        if (Test-VersionAllowedByList -AllowedVersions $allowed -Version $RequestedVersion) {
            $decision.Allowed = $true
            $decision.Code = 'AllowedVersionMatches'
        } else {
            $decision.Code = 'VersionNotAllowed'
        }
        return $decision
    }
    $decision.Allowed = $true
    $decision.Code = 'AllowedVersionUnspecified'
    $decision.RequiresVersionChoice = $true
    if ($allowed.Count -eq 1 -and -not $allowed[0].Contains('*')) { $decision.FixedVersion = $allowed[0] }
    return $decision
}

function Get-RequirementsDecisions {
    param(
        [object[]]$Packages,
        [object[]]$Entries
    )

    $results = New-Object 'System.Collections.Generic.List[object]'
    $allAllowed = $true
    foreach ($entry in @($Entries)) {
        $package = Find-ApprovedPackage -Packages $Packages -Name $entry.Name
        $decision = Get-PackageInstallDecision -Package $package -RequestedVersion $entry.Version
        if (-not $decision.Allowed) { $allAllowed = $false }
        $results.Add([pscustomobject]@{ Entry = $entry; Package = $package; Decision = $decision })
    }
    return [pscustomobject]@{ Results = $results.ToArray(); AllAllowed = $allAllowed }
}

# ---------------------------------------------------------------------------
# requirements parsing
# ---------------------------------------------------------------------------

function Get-RequirementLineProblem {
    param([string]$Line)

    if ($Line.StartsWith('-')) { return 'Option' }
    if ($Line.Contains('://') -or $Line -cmatch '^(?i:git|hg|svn|bzr)\+') { return 'Url' }
    if ($Line.Contains('@')) { return 'Url' }
    if ($Line -cmatch '^[A-Za-z]:' -or $Line.Contains('\') -or $Line.Contains('/') -or $Line.StartsWith('.') -or $Line.StartsWith('~')) { return 'LocalPath' }
    if ($Line.Contains('[')) { return 'Extras' }
    if ($Line.Contains(';')) { return 'Marker' }
    if ($Line.Contains('#')) { return 'InlineComment' }
    if ($Line -cmatch '===|~=|!=|<=|>=|<|>') { return 'Operator' }
    $match = [regex]::Match($Line, '^(?<name>[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?)(==(?<ver>.*))?\z')
    if (-not $match.Success) { return 'Format' }
    if ($match.Groups['ver'].Success) {
        switch (Get-ConcreteVersionProblem -Version $match.Groups['ver'].Value) {
            'Empty' { return 'EmptyVersion' }
            'Wildcard' { return 'Wildcard' }
            'Unsupported' { return 'UnsupportedVersion' }
            'Format' { return 'Format' }
        }
    }
    return $null
}

function ConvertFrom-RequirementsText {
    param([string]$Text)

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $problems = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $lines = [regex]::Split($Text, "\r\n|\n|\r")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $lineNumber = $i + 1
        $line = $lines[$i].Trim()
        if ($line -eq '') { continue }
        if ($line.StartsWith('#')) { continue }
        $code = Get-RequirementLineProblem -Line $line
        if ($null -ne $code) {
            $problems.Add([pscustomobject]@{ LineNumber = $lineNumber; Code = $code; Text = $line })
            continue
        }
        $parts = $line -split '==', 2
        $name = $parts[0]
        $version = $null
        if ($parts.Count -eq 2) { $version = $parts[1] }
        $normalized = ConvertTo-NormalizedPackageName -Name $name
        if ($seen.ContainsKey($normalized)) {
            $problems.Add([pscustomobject]@{ LineNumber = $lineNumber; Code = 'Duplicate'; Text = $line })
            continue
        }
        $seen[$normalized] = $true
        $entries.Add([pscustomobject]@{ Name = $name; Version = $version; LineNumber = $lineNumber; Raw = $line })
    }
    return [pscustomobject]@{ Entries = $entries.ToArray(); Problems = $problems.ToArray(); ReadErrorCode = $null }
}

function Read-RequirementsFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Entries = @(); Problems = @(); ReadErrorCode = 'FileNotFound' }
    }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = [System.IO.File]::ReadAllText($Path, $strictUtf8)
    } catch {
        return [pscustomobject]@{ Entries = @(); Problems = @(); ReadErrorCode = 'InvalidUtf8' }
    }
    return (ConvertFrom-RequirementsText -Text $text)
}

# ---------------------------------------------------------------------------
# Reading and writing the approved list
# ---------------------------------------------------------------------------

function Read-ApprovedPackageList {
    param([string]$Path)

    $result = [pscustomobject]@{ Success = $false; ErrorCode = ''; ErrorDetail = ''; Data = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.ErrorCode = 'FileNotFound'
        $result.ErrorDetail = $Path
        return $result
    }
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = [System.IO.File]::ReadAllText($Path, $strictUtf8)
    } catch {
        $result.ErrorCode = 'InvalidUtf8'
        $result.ErrorDetail = $Path
        return $result
    }
    try {
        $result.Data = $text | ConvertFrom-Json
    } catch {
        $result.ErrorCode = 'InvalidJson'
        $result.ErrorDetail = $Path
        return $result
    }
    $result.Success = $true
    return $result
}

function Test-ApprovedPackageFileFormat {
    param([string]$Path)

    $codes = New-Object 'System.Collections.Generic.List[string]'
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $codes.Add('FileBom') }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    } catch {
        $codes.Add('InvalidUtf8')
        return $codes.ToArray()
    }
    if ($text.Contains([string][char]0xFFFD)) { $codes.Add('FileReplacementChar') }
    if ([regex]::IsMatch($text, "(?<!`r)`n")) { $codes.Add('FileBareLf') }
    if ([regex]::IsMatch($text, "`r(?!`n)")) { $codes.Add('FileBareCr') }
    return $codes.ToArray()
}

function ConvertTo-JsonStringLiteral {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        if ($ch -ceq '"') { [void]$builder.Append('\"') }
        elseif ($ch -ceq '\') { [void]$builder.Append('\\') }
        elseif ($code -eq 8) { [void]$builder.Append('\b') }
        elseif ($code -eq 9) { [void]$builder.Append('\t') }
        elseif ($code -eq 10) { [void]$builder.Append('\n') }
        elseif ($code -eq 12) { [void]$builder.Append('\f') }
        elseif ($code -eq 13) { [void]$builder.Append('\r') }
        elseif ($code -lt 32) { [void]$builder.Append(('\u{0:x4}' -f $code)) }
        else { [void]$builder.Append($ch) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-ApprovedPackagesJsonText {
    param([object[]]$Packages)

    $nl = "`r`n"
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('{' + $nl)
    [void]$builder.Append('  "schemaVersion": ' + $script:ApprovedPackagesSchemaVersion + ',' + $nl)
    $sorted = @(Get-SortedPackages -Packages $Packages)
    if ($sorted.Count -eq 0) {
        [void]$builder.Append('  "packages": []' + $nl)
    } else {
        [void]$builder.Append('  "packages": [' + $nl)
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $package = $sorted[$i]
            [void]$builder.Append('    {' + $nl)
            [void]$builder.Append('      "name": ' + (ConvertTo-JsonStringLiteral -Text $package.name) + ',' + $nl)
            $versions = @($package.allowedVersions)
            if ($versions.Count -eq 0) {
                [void]$builder.Append('      "allowedVersions": [],' + $nl)
            } else {
                [void]$builder.Append('      "allowedVersions": [' + $nl)
                for ($j = 0; $j -lt $versions.Count; $j++) {
                    $comma = ''
                    if ($j -lt $versions.Count - 1) { $comma = ',' }
                    [void]$builder.Append('        ' + (ConvertTo-JsonStringLiteral -Text $versions[$j]) + $comma + $nl)
                }
                [void]$builder.Append('      ],' + $nl)
            }
            [void]$builder.Append('      "purpose": ' + (ConvertTo-JsonStringLiteral -Text $package.purpose) + ',' + $nl)
            [void]$builder.Append('      "status": ' + (ConvertTo-JsonStringLiteral -Text $package.status) + ',' + $nl)
            [void]$builder.Append('      "approvedDate": ' + (ConvertTo-JsonStringLiteral -Text $package.approvedDate) + ',' + $nl)
            [void]$builder.Append('      "notes": ' + (ConvertTo-JsonStringLiteral -Text $package.notes) + $nl)
            $closing = '    }'
            if ($i -lt $sorted.Count - 1) { $closing = '    },' }
            [void]$builder.Append($closing + $nl)
        }
        [void]$builder.Append('  ]' + $nl)
    }
    [void]$builder.Append('}' + $nl)
    return $builder.ToString()
}

function Write-TextFileSafely {
    param(
        [string]$Path,
        [string]$Text,
        [scriptblock]$Validator,
        [switch]$WithBom
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bodyBytes = $utf8.GetBytes($Text)
    $bytes = $bodyBytes
    if ($WithBom.IsPresent) { $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + @($bodyBytes)) }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop)
    }
    $temp = Join-Path $directory ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllBytes($temp, $bytes)
        $back = [System.IO.File]::ReadAllBytes($temp)
        if ([System.Convert]::ToBase64String($back) -cne [System.Convert]::ToBase64String($bytes)) {
            throw 'Write verification failed: the written bytes differ from the expected bytes.'
        }
        if ($null -ne $Validator) { & $Validator $temp }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temp, $Path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($temp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Write-ApprovedPackageList {
    param(
        [string]$Path,
        [object[]]$Packages
    )

    $sorted = @(Get-SortedPackages -Packages $Packages)
    $candidate = [pscustomobject]@{ schemaVersion = $script:ApprovedPackagesSchemaVersion; packages = $sorted }
    $before = @(Test-ApprovedPackageList -Data $candidate)
    if ($before.Count -gt 0) { throw ('The list is invalid and was not written: ' + $before[0].Code) }
    $text = ConvertTo-ApprovedPackagesJsonText -Packages $sorted
    $validator = {
        param($tempPath)
        $formatProblems = @(Test-ApprovedPackageFileFormat -Path $tempPath)
        if ($formatProblems.Count -gt 0) { throw ('Written JSON failed the format check: ' + ($formatProblems -join ', ')) }
        $read = Read-ApprovedPackageList -Path $tempPath
        if (-not $read.Success) { throw ('Written JSON could not be read back: ' + $read.ErrorCode) }
        $problems = @(Test-ApprovedPackageList -Data $read.Data)
        if ($problems.Count -gt 0) { throw ('Written JSON failed validation: ' + $problems[0].Code) }
        $again = ConvertTo-ApprovedPackagesJsonText -Packages @($read.Data.packages)
        if ($again -cne $text) { throw 'Written JSON did not round-trip.' }
    }.GetNewClosure()
    Write-TextFileSafely -Path $Path -Text $text -Validator $validator
}

# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------

function ConvertTo-MarkdownCell {
    param([string]$Text)

    if ($null -eq $Text) { return '' }
    $escaped = $Text.Replace('|', '\|')
    return [regex]::Replace($escaped, "\r\n|\n|\r", '<br>')
}

function ConvertTo-ApprovedPackagesMarkdown {
    param(
        [object[]]$Packages,
        [object]$Labels
    )

    $nl = "`r`n"
    $builder = New-Object System.Text.StringBuilder
    foreach ($line in @($Labels.NoticeLines)) { [void]$builder.Append('> ' + $line + $nl) }
    [void]$builder.Append($nl)
    [void]$builder.Append('# ' + $Labels.Title + $nl)
    [void]$builder.Append($nl)
    $headers = @($Labels.HeaderName, $Labels.HeaderVersions, $Labels.HeaderStatus, $Labels.HeaderApprovedDate, $Labels.HeaderPurpose, $Labels.HeaderNotes)
    [void]$builder.Append('| ' + ($headers -join ' | ') + ' |' + $nl)
    [void]$builder.Append('| ' + ((@('---') * $headers.Count) -join ' | ') + ' |' + $nl)
    foreach ($package in @(Get-SortedPackages -Packages $Packages)) {
        $versions = @($package.allowedVersions)
        if ($versions.Count -eq 0) {
            $versionCell = $Labels.NoVersions
        } else {
            $versionCell = (@($versions | ForEach-Object { '`' + $_ + '`' }) -join ', ')
        }
        $cells = @(
            (ConvertTo-MarkdownCell -Text $package.name),
            $versionCell,
            (ConvertTo-MarkdownCell -Text $package.status),
            (ConvertTo-MarkdownCell -Text $package.approvedDate),
            (ConvertTo-MarkdownCell -Text $package.purpose),
            (ConvertTo-MarkdownCell -Text $package.notes)
        )
        [void]$builder.Append('| ' + ($cells -join ' | ') + ' |' + $nl)
    }
    return $builder.ToString()
}

# ---------------------------------------------------------------------------
# pip specifications, requirements updates, and pip freeze parsing (install tool)
# ---------------------------------------------------------------------------

function Add-OneToDecimalString {
    param([string]$Digits)

    $chars = $Digits.ToCharArray()
    for ($i = $chars.Length - 1; $i -ge 0; $i--) {
        if ($chars[$i] -ceq '9') {
            $chars[$i] = '0'
        } else {
            $chars[$i] = [char]([int]$chars[$i] + 1)
            return (-join $chars)
        }
    }
    return ('1' + (-join $chars))
}

function Get-PipRequirementSpec {
    param(
        [string]$Name,
        [object]$Package,
        [string]$RequestedVersion
    )

    $result = [pscustomobject]@{ Spec = ''; Mode = '' }
    if (-not [string]::IsNullOrEmpty($RequestedVersion)) {
        $result.Spec = $Name + '==' + $RequestedVersion
        $result.Mode = 'Pinned'
        return $result
    }
    $allowed = @($Package.allowedVersions)
    if ($allowed.Count -eq 0) {
        $result.Spec = $Name
        $result.Mode = 'AnyVersion'
    } elseif ($allowed.Count -gt 1) {
        $result.Mode = 'NeedsPin'
    } elseif (-not $allowed[0].Contains('*')) {
        $result.Spec = $Name + '==' + $allowed[0]
        $result.Mode = 'FixedFromList'
    } else {
        $numeric = $allowed[0].Substring(0, $allowed[0].IndexOf('.*'))
        $lower = [string[]]@(ConvertTo-VersionElements -Version $numeric)
        $upper = [string[]]$lower.Clone()
        $upper[$upper.Length - 1] = Add-OneToDecimalString -Digits $upper[$upper.Length - 1]
        $result.Spec = $Name + '>=' + ($lower -join '.') + ',<' + ($upper -join '.')
        $result.Mode = 'RangeFromList'
    }
    return $result
}

function ConvertTo-UpdatedRequirementsText {
    param(
        [string]$Text,
        [object[]]$Updates
    )

    $parts = [regex]::Split($Text, '(\r\n|\n|\r)')
    foreach ($update in @($Updates)) {
        $index = ($update.LineNumber - 1) * 2
        if ($index -lt 0 -or $index -ge $parts.Length) { throw 'The requirements line number is out of range.' }
        $match = [regex]::Match($parts[$index], '^(?<lead>\s*)(?<body>\S+)(?<trail>\s*)\z')
        if (-not $match.Success -or $match.Groups['body'].Value -cne $update.Name) {
            throw 'The requirements line does not contain the expected package name.'
        }
        $parts[$index] = $match.Groups['lead'].Value + $update.Name + '==' + $update.Version + $match.Groups['trail'].Value
    }
    return ($parts -join '')
}

function Update-RequirementsPins {
    param(
        [string]$Path,
        [object[]]$Updates
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $offset = 0
    if ($hasBom) { $offset = 3 }
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset)
    $newText = ConvertTo-UpdatedRequirementsText -Text $text -Updates $Updates
    $expectedUpdates = @($Updates)
    $validator = {
        param($tempPath)
        $read = Read-RequirementsFile -Path $tempPath
        if ($null -ne $read.ReadErrorCode -or @($read.Problems).Count -gt 0) { throw 'The updated requirements file could not be parsed.' }
        foreach ($update in $expectedUpdates) {
            $entry = @($read.Entries | Where-Object { $_.LineNumber -eq $update.LineNumber })
            if ($entry.Count -ne 1 -or $entry[0].Name -cne $update.Name -or $entry[0].Version -cne $update.Version) {
                throw 'The updated line does not have the expected content.'
            }
        }
    }.GetNewClosure()
    Write-TextFileSafely -Path $Path -Text $newText -Validator $validator -WithBom:$hasBom
}

function ConvertFrom-PipFreezeText {
    param([string[]]$Lines)

    $map = @{}
    foreach ($line in @($Lines)) {
        $match = [regex]::Match(([string]$line).Trim(), '^(?<name>[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?)==(?<ver>\S+)\z')
        if ($match.Success) {
            $map[(ConvertTo-NormalizedPackageName -Name $match.Groups['name'].Value)] = $match.Groups['ver'].Value
        }
    }
    return $map
}

function Compare-FreezeSnapshots {
    param(
        [hashtable]$Before,
        [hashtable]$After
    )

    $changes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) {
            $changes.Add([pscustomobject]@{ Name = $key; Kind = 'Added'; Before = ''; After = $After[$key] })
        } elseif ($Before[$key] -cne $After[$key]) {
            $changes.Add([pscustomobject]@{ Name = $key; Kind = 'Changed'; Before = $Before[$key]; After = $After[$key] })
        }
    }
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) {
            $changes.Add([pscustomobject]@{ Name = $key; Kind = 'Removed'; Before = $Before[$key]; After = '' })
        }
    }
    return @($changes.ToArray() | Sort-Object -Property Name)
}
