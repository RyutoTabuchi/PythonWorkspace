<#
.SYNOPSIS
    Manages ApprovedPackages\approved-packages.json (the approved package list).

.DESCRIPTION
    Interactive menu: add a package, show entries, update purpose or notes, add or remove an allowed
    version, change the status, and regenerate the Markdown document.
    Packages are never deleted. Use status 'disabled' to stop using a package.
    The tool never runs git add/commit/push, never installs packages, and keeps no backup files.
    The change history is kept by the workspace Git repository.
    Messages are read from ApprovedPackages.messages.json (UTF-8, no BOM).

    All parameters are for automated tests only and require -TestMode. -DataDirectory must be inside
    the temporary folder and contain the test marker file.
#>
[CmdletBinding()]
param(
    [switch]$TestMode,
    [string]$DataDirectory,
    [ValidateSet('Add', 'Show', 'SetPurpose', 'SetNotes', 'AddVersion', 'RemoveVersion', 'SetStatus', 'RegenerateDocument')]
    [string]$Action,
    [string]$Name,
    [string]$Value,
    [string]$VersionList,
    [string]$Status,
    [string]$Purpose,
    [string]$Notes,
    [switch]$SkipConfirmation,
    [ValidateSet('Y', 'N')]
    [string]$ConfirmAnswer,
    [string]$Today
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ApprovedPackages.Common.ps1')

$script:MgrBoundNames = @($PSBoundParameters.Keys)
$script:MgrIsTestMode = $TestMode.IsPresent
$script:MgrSkipConfirm = $SkipConfirmation.IsPresent
$script:MgrConfirmAnswer = $ConfirmAnswer
$script:MgrTodayOverride = $Today
$script:MgrMessages = $null
$script:MgrPaths = $null
$script:ManageRequiredKeys = @(
    'ErrorPrefix',
    'ErrReadFileNotFound', 'ErrReadInvalidUtf8', 'ErrReadInvalidJson',
    'ProblemRootNotObject', 'ProblemSchemaVersionMissing', 'ProblemSchemaVersionUnsupported', 'ProblemPackagesNotArray',
    'ProblemUnknownField', 'ProblemPackageNotObject', 'ProblemFieldMissing', 'ProblemFieldNotString',
    'ProblemNameInvalid', 'ProblemNameDuplicate', 'ProblemNameDuplicateNormalized',
    'ProblemAllowedVersionsNotArray', 'ProblemAllowedVersionInvalid', 'ProblemAllowedVersionDuplicate',
    'ProblemStatusInvalid', 'ProblemApprovedDateInvalid', 'ProblemApprovedDateMustBeEmpty',
    'MgrUsage', 'MgrErrTestModeOnly', 'MgrErrTestRootRequired', 'MgrErrTestRootInvalid', 'MgrErrActionRequired', 'MgrErrTodayInvalid',
    'MgrMenuItems', 'MgrPromptMenu', 'MgrMenuInvalid',
    'MgrPromptName', 'MgrPromptNameOptional', 'MgrPromptVersions', 'MgrPromptPurpose', 'MgrPromptNotes', 'MgrPromptStatus',
    'MgrPromptVersion', 'MgrPromptRemoveVersion', 'MgrPromptValue',
    'MgrErrNameRequired', 'MgrErrNameFormat', 'MgrErrNameDuplicate', 'MgrErrNameNotFound', 'MgrErrStatusInvalid',
    'MgrErrVersionInvalid', 'MgrErrVersionDuplicate', 'MgrErrVersionNotFound', 'MgrErrControlChar',
    'MgrWarnAnyVersion',
    'MgrPlanHeader', 'MgrPlanNew', 'MgrPlanChange', 'MgrFieldName', 'MgrFieldVersions', 'MgrFieldPurpose',
    'MgrFieldStatus', 'MgrFieldApprovedDate', 'MgrFieldNotes', 'MgrEmptyValue', 'MgrNoVersions',
    'MgrPromptConfirm', 'MgrCancelled', 'MgrNothingToChange', 'MgrSaved', 'MgrDocFailed',
    'MgrShowHeader', 'MgrShowRow', 'MgrNoPackages', 'MgrDetailTitle', 'MgrCurrentVersions'
)

function Get-MgrMsg {
    param(
        [string]$Key,
        [object[]]$FormatArgs
    )

    return (Get-ToolMessage -Messages $script:MgrMessages -Key $Key -FormatArgs $FormatArgs)
}

function Read-UserInput {
    param([string]$Prompt)

    $value = Read-Host -Prompt $Prompt
    if ($null -eq $value) { throw 'Input stream ended.' }
    return $value
}

function Read-YesNo {
    param([string]$Prompt)

    while ($true) {
        $answer = (Read-UserInput -Prompt $Prompt).Trim()
        if ($answer -eq '') { return $false }
        if ($answer -ieq 'Y') { return $true }
        if ($answer -ieq 'N') { return $false }
    }
}

function Confirm-Change {
    if ($script:MgrSkipConfirm) { return $true }
    if (-not [string]::IsNullOrEmpty($script:MgrConfirmAnswer)) { return ($script:MgrConfirmAnswer -eq 'Y') }
    return (Read-YesNo -Prompt (Get-MgrMsg 'MgrPromptConfirm'))
}

function Get-MgrToday {
    if (-not [string]::IsNullOrEmpty($script:MgrTodayOverride)) { return $script:MgrTodayOverride }
    return (Get-LocalDateText)
}

# ---------------------------------------------------------------------------
# Value helpers
# ---------------------------------------------------------------------------

function Test-SingleLineText {
    param([string]$Text)

    if ($null -eq $Text) { return $true }
    return ($Text -cnotmatch '[\x00-\x1F\x7F]')
}

function Assert-SingleLineText {
    param([string]$Text)

    if (-not (Test-SingleLineText -Text $Text)) { throw (Get-MgrMsg 'MgrErrControlChar') }
}

function Assert-StatusName {
    param([string]$StatusName)

    if ($script:ApprovedStatuses -cnotcontains $StatusName) {
        throw (Get-MgrMsg 'MgrErrStatusInvalid' @($StatusName, ($script:ApprovedStatuses -join ', ')))
    }
}

function Assert-VersionPattern {
    param([string]$Pattern)

    if (-not (Test-AllowedVersionPattern -Pattern $Pattern)) { throw (Get-MgrMsg 'MgrErrVersionInvalid' @($Pattern)) }
}

function ConvertFrom-VersionListText {
    param([string]$Text)

    $versions = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($Text)) { return $versions.ToArray() }
    foreach ($part in $Text.Split(',')) {
        $item = $part.Trim()
        Assert-VersionPattern -Pattern $item
        if ($versions.Contains($item)) { throw (Get-MgrMsg 'MgrErrVersionDuplicate' @($item)) }
        $versions.Add($item)
    }
    return $versions.ToArray()
}

function Copy-ApprovedPackage {
    param([object]$Package)

    return (New-ApprovedPackage -Name $Package.name -AllowedVersions @($Package.allowedVersions) -Purpose $Package.purpose -Status $Package.status -ApprovedDate $Package.approvedDate -Notes $Package.notes)
}

function Get-ExistingPackageOrThrow {
    param(
        [object[]]$Packages,
        [string]$PackageName
    )

    $found = Find-ApprovedPackage -Packages $Packages -Name $PackageName
    if ($null -eq $found) { throw (Get-MgrMsg 'MgrErrNameNotFound' @($PackageName)) }
    return $found
}

function New-ChangeRecord {
    param(
        [object[]]$Packages,
        [object]$Old,
        [object]$New
    )

    $target = ConvertTo-NormalizedPackageName -Name $New.name
    $others = @($Packages | Where-Object { (ConvertTo-NormalizedPackageName -Name $_.name) -cne $target })
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    if (@($New.allowedVersions).Count -eq 0 -and ($null -eq $Old -or @($Old.allowedVersions).Count -gt 0)) {
        $warnings.Add('AnyVersion')
    }
    return [pscustomobject]@{
        Old      = $Old
        New      = $New
        Packages = @($others + @($New))
        Warnings = $warnings.ToArray()
    }
}

function Test-PackagesEqual {
    param(
        [object]$Left,
        [object]$Right
    )

    if ($null -eq $Left -or $null -eq $Right) { return $false }
    foreach ($field in @('name', 'purpose', 'status', 'approvedDate', 'notes')) {
        if ($Left.$field -cne $Right.$field) { return $false }
    }
    return ((@($Left.allowedVersions) -join "`n") -ceq (@($Right.allowedVersions) -join "`n"))
}

# ---------------------------------------------------------------------------
# Change builders (pure: they return a change record and never write files)
# ---------------------------------------------------------------------------

function New-AddChange {
    param(
        [object[]]$Packages,
        [string]$PackageName,
        [string]$VersionListText,
        [string]$PurposeText,
        [string]$StatusName,
        [string]$NotesText
    )

    $nameText = ''
    if ($null -ne $PackageName) { $nameText = $PackageName.Trim() }
    if ($nameText -eq '') { throw (Get-MgrMsg 'MgrErrNameRequired') }
    if (-not (Test-PackageNameFormat -Name $nameText)) { throw (Get-MgrMsg 'MgrErrNameFormat' @($nameText)) }
    $duplicate = Find-ApprovedPackage -Packages $Packages -Name $nameText
    if ($null -ne $duplicate) { throw (Get-MgrMsg 'MgrErrNameDuplicate' @($nameText, $duplicate.name)) }
    $versions = @(ConvertFrom-VersionListText -Text $VersionListText)
    $purposeValue = ''
    if ($null -ne $PurposeText) { $purposeValue = $PurposeText.Trim() }
    $notesValue = ''
    if ($null -ne $NotesText) { $notesValue = $NotesText.Trim() }
    Assert-SingleLineText -Text $purposeValue
    Assert-SingleLineText -Text $notesValue
    Assert-StatusName -StatusName $StatusName
    $date = Get-NextApprovedDate -OldStatus '' -NewStatus $StatusName -OldDate '' -Today (Get-MgrToday)
    $new = New-ApprovedPackage -Name $nameText -AllowedVersions $versions -Purpose $purposeValue -Status $StatusName -ApprovedDate $date -Notes $notesValue
    return (New-ChangeRecord -Packages $Packages -Old $null -New $new)
}

function New-TextFieldChange {
    param(
        [object[]]$Packages,
        [string]$PackageName,
        [string]$FieldName,
        [string]$NewText
    )

    $old = Get-ExistingPackageOrThrow -Packages $Packages -PackageName $PackageName
    $text = ''
    if ($null -ne $NewText) { $text = $NewText.Trim() }
    Assert-SingleLineText -Text $text
    $new = Copy-ApprovedPackage -Package $old
    $new.$FieldName = $text
    return (New-ChangeRecord -Packages $Packages -Old $old -New $new)
}

function New-AddVersionChange {
    param(
        [object[]]$Packages,
        [string]$PackageName,
        [string]$Pattern
    )

    $old = Get-ExistingPackageOrThrow -Packages $Packages -PackageName $PackageName
    $item = ''
    if ($null -ne $Pattern) { $item = $Pattern.Trim() }
    Assert-VersionPattern -Pattern $item
    if (@($old.allowedVersions) -ccontains $item) { throw (Get-MgrMsg 'MgrErrVersionDuplicate' @($item)) }
    $new = Copy-ApprovedPackage -Package $old
    $new.allowedVersions = @(@($old.allowedVersions) + @($item))
    return (New-ChangeRecord -Packages $Packages -Old $old -New $new)
}

function New-RemoveVersionChange {
    param(
        [object[]]$Packages,
        [string]$PackageName,
        [string]$Pattern
    )

    $old = Get-ExistingPackageOrThrow -Packages $Packages -PackageName $PackageName
    $item = ''
    if ($null -ne $Pattern) { $item = $Pattern.Trim() }
    if (@($old.allowedVersions) -cnotcontains $item) { throw (Get-MgrMsg 'MgrErrVersionNotFound' @($item, $old.name)) }
    $new = Copy-ApprovedPackage -Package $old
    $new.allowedVersions = @(@($old.allowedVersions) | Where-Object { $_ -cne $item })
    return (New-ChangeRecord -Packages $Packages -Old $old -New $new)
}

function New-StatusChange {
    param(
        [object[]]$Packages,
        [string]$PackageName,
        [string]$StatusName
    )

    $old = Get-ExistingPackageOrThrow -Packages $Packages -PackageName $PackageName
    Assert-StatusName -StatusName $StatusName
    $new = Copy-ApprovedPackage -Package $old
    $new.status = $StatusName
    $new.approvedDate = Get-NextApprovedDate -OldStatus $old.status -NewStatus $StatusName -OldDate $old.approvedDate -Today (Get-MgrToday)
    return (New-ChangeRecord -Packages $Packages -Old $old -New $new)
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

function Format-VersionsText {
    param([object[]]$Versions)

    if (@($Versions).Count -eq 0) { return (Get-MgrMsg 'MgrNoVersions') }
    return (@($Versions) -join ', ')
}

function Format-FieldValue {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return (Get-MgrMsg 'MgrEmptyValue') }
    return $Text
}

function Show-ChangePlan {
    param([object]$Change)

    Write-Host (Get-MgrMsg 'MgrPlanHeader')
    $fields = @(
        @{ Label = 'MgrFieldName'; Value = { param($p) $p.name } },
        @{ Label = 'MgrFieldVersions'; Value = { param($p) Format-VersionsText -Versions @($p.allowedVersions) } },
        @{ Label = 'MgrFieldPurpose'; Value = { param($p) Format-FieldValue -Text $p.purpose } },
        @{ Label = 'MgrFieldStatus'; Value = { param($p) $p.status } },
        @{ Label = 'MgrFieldApprovedDate'; Value = { param($p) Format-FieldValue -Text $p.approvedDate } },
        @{ Label = 'MgrFieldNotes'; Value = { param($p) Format-FieldValue -Text $p.notes } }
    )
    if ($null -eq $Change.Old) {
        Write-Host (Get-MgrMsg 'MgrPlanNew' @($Change.New.name))
        foreach ($field in $fields) {
            Write-Host ('  ' + (Get-MgrMsg $field.Label) + ': ' + (& $field.Value $Change.New))
        }
    } else {
        Write-Host (Get-MgrMsg 'MgrPlanChange' @($Change.New.name))
        foreach ($field in $fields) {
            $before = & $field.Value $Change.Old
            $after = & $field.Value $Change.New
            if ($before -cne $after) {
                Write-Host ('  ' + (Get-MgrMsg $field.Label) + ': ' + $before + ' -> ' + $after)
            }
        }
    }
    foreach ($warning in @($Change.Warnings)) {
        Write-Host (Get-MgrMsg ('MgrWarn' + $warning)) -ForegroundColor Yellow
    }
}

function Show-Packages {
    param(
        [object[]]$Packages,
        [string]$PackageName
    )

    if (-not [string]::IsNullOrWhiteSpace($PackageName)) {
        $package = Get-ExistingPackageOrThrow -Packages $Packages -PackageName $PackageName.Trim()
        Write-Host (Get-MgrMsg 'MgrDetailTitle' @($package.name))
        Write-Host ('  ' + (Get-MgrMsg 'MgrFieldVersions') + ': ' + (Format-VersionsText -Versions @($package.allowedVersions)))
        Write-Host ('  ' + (Get-MgrMsg 'MgrFieldStatus') + ': ' + $package.status)
        Write-Host ('  ' + (Get-MgrMsg 'MgrFieldApprovedDate') + ': ' + (Format-FieldValue -Text $package.approvedDate))
        Write-Host ('  ' + (Get-MgrMsg 'MgrFieldPurpose') + ': ' + (Format-FieldValue -Text $package.purpose))
        Write-Host ('  ' + (Get-MgrMsg 'MgrFieldNotes') + ': ' + (Format-FieldValue -Text $package.notes))
        return
    }
    $sorted = @(Get-SortedPackages -Packages $Packages)
    if ($sorted.Count -eq 0) {
        Write-Host (Get-MgrMsg 'MgrNoPackages')
        return
    }
    Write-Host (Get-MgrMsg 'MgrShowHeader' @($sorted.Count))
    foreach ($package in $sorted) {
        Write-Host (Get-MgrMsg 'MgrShowRow' @($package.name, $package.status, (Format-VersionsText -Versions @($package.allowedVersions)), (Format-FieldValue -Text $package.approvedDate)))
    }
}

# ---------------------------------------------------------------------------
# Loading, saving, and the document
# ---------------------------------------------------------------------------

function Read-ValidatedPackages {
    $read = Read-ApprovedPackageList -Path $script:MgrPaths.JsonPath
    if (-not $read.Success) { throw (Get-MgrMsg ('ErrRead' + $read.ErrorCode) @($read.ErrorDetail)) }
    $problems = @(Test-ApprovedPackageList -Data $read.Data)
    if ($problems.Count -gt 0) {
        $lines = @($problems | ForEach-Object { Get-MgrMsg ('Problem' + $_.Code) @($_.Package, $_.Detail) })
        throw ($lines -join [Environment]::NewLine)
    }
    return @(@($read.Data.packages) | ForEach-Object { Copy-ApprovedPackage -Package $_ })
}

function Invoke-DocumentRegeneration {
    $updateScript = Join-Path $PSScriptRoot 'Update-ApprovedPackagesDocument.ps1'
    $global:LASTEXITCODE = 0
    if ($script:MgrIsTestMode) {
        & $updateScript -TestMode -DataDirectory $script:MgrPaths.DataDirectory
    } else {
        & $updateScript
    }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-ManageOperation {
    param(
        [string]$ActionName,
        [hashtable]$Arguments
    )

    $packages = @(Read-ValidatedPackages)
    if ($ActionName -ceq 'Show') {
        Show-Packages -Packages $packages -PackageName $Arguments['Name']
        return 0
    }
    if ($ActionName -ceq 'RegenerateDocument') {
        if (Invoke-DocumentRegeneration) { return 0 }
        return 1
    }

    $change = $null
    switch ($ActionName) {
        'Add' { $change = New-AddChange -Packages $packages -PackageName $Arguments['Name'] -VersionListText $Arguments['VersionList'] -PurposeText $Arguments['Purpose'] -StatusName $Arguments['Status'] -NotesText $Arguments['Notes'] }
        'SetPurpose' { $change = New-TextFieldChange -Packages $packages -PackageName $Arguments['Name'] -FieldName 'purpose' -NewText $Arguments['Value'] }
        'SetNotes' { $change = New-TextFieldChange -Packages $packages -PackageName $Arguments['Name'] -FieldName 'notes' -NewText $Arguments['Value'] }
        'AddVersion' { $change = New-AddVersionChange -Packages $packages -PackageName $Arguments['Name'] -Pattern $Arguments['Value'] }
        'RemoveVersion' { $change = New-RemoveVersionChange -Packages $packages -PackageName $Arguments['Name'] -Pattern $Arguments['Value'] }
        'SetStatus' { $change = New-StatusChange -Packages $packages -PackageName $Arguments['Name'] -StatusName $Arguments['Status'] }
    }
    if (Test-PackagesEqual -Left $change.Old -Right $change.New) {
        Write-Host (Get-MgrMsg 'MgrNothingToChange')
        return 0
    }
    Show-ChangePlan -Change $change
    if (-not (Confirm-Change)) {
        Write-Host (Get-MgrMsg 'MgrCancelled')
        return 2
    }
    Write-ApprovedPackageList -Path $script:MgrPaths.JsonPath -Packages $change.Packages
    Write-Host (Get-MgrMsg 'MgrSaved' @($script:MgrPaths.JsonPath))
    if (-not (Invoke-DocumentRegeneration)) {
        Write-Host (Get-MgrMsg 'MgrDocFailed')
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------

function Read-ActionArguments {
    param([string]$ActionName)

    $arguments = @{}
    if ($ActionName -ceq 'RegenerateDocument') { return $arguments }
    if ($ActionName -ceq 'Show') {
        $arguments['Name'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptNameOptional')
        return $arguments
    }
    $arguments['Name'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptName')
    switch ($ActionName) {
        'Add' {
            $arguments['VersionList'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptVersions')
            $arguments['Purpose'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptPurpose')
            $arguments['Status'] = (Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptStatus')).Trim()
            $arguments['Notes'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptNotes')
        }
        'SetPurpose' { $arguments['Value'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptPurpose') }
        'SetNotes' { $arguments['Value'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptNotes') }
        'AddVersion' { $arguments['Value'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptVersion') }
        'RemoveVersion' {
            $current = Find-ApprovedPackage -Packages @(Read-ValidatedPackages) -Name $arguments['Name'].Trim()
            if ($null -ne $current) { Write-Host (Get-MgrMsg 'MgrCurrentVersions' @((Format-VersionsText -Versions @($current.allowedVersions)))) }
            $arguments['Value'] = Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptRemoveVersion')
        }
        'SetStatus' { $arguments['Status'] = (Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptStatus')).Trim() }
    }
    return $arguments
}

function Invoke-ManageMenu {
    $map = @{ '1' = 'Add'; '2' = 'Show'; '3' = 'SetPurpose'; '4' = 'SetNotes'; '5' = 'AddVersion'; '6' = 'RemoveVersion'; '7' = 'SetStatus'; '8' = 'RegenerateDocument' }
    while ($true) {
        Write-Host ''
        Write-Host (Get-MgrMsg 'MgrMenuItems')
        $choice = (Read-UserInput -Prompt (Get-MgrMsg 'MgrPromptMenu')).Trim()
        if ($choice -eq '0') { return 0 }
        if (-not $map.ContainsKey($choice)) {
            Write-Host (Get-MgrMsg 'MgrMenuInvalid')
            continue
        }
        try {
            $arguments = Read-ActionArguments -ActionName $map[$choice]
            [void](Invoke-ManageOperation -ActionName $map[$choice] -Arguments $arguments)
        } catch {
            Write-Host (Get-MgrMsg 'ErrorPrefix' @($_.Exception.Message)) -ForegroundColor Red
        }
    }
}

function Invoke-ManageMain {
    $paths = Get-ApprovedPackagesPaths
    $script:MgrMessages = Import-ToolMessages -Path $paths.MessagesPath -RequiredKeys $script:ManageRequiredKeys

    if (-not $script:MgrIsTestMode) {
        if ($script:MgrBoundNames.Count -gt 0) {
            $names = ($script:MgrBoundNames | ForEach-Object { '-' + $_ }) -join ', '
            throw ((Get-MgrMsg 'MgrErrTestModeOnly' @($names)) + [Environment]::NewLine + (Get-MgrMsg 'MgrUsage'))
        }
        $script:MgrPaths = $paths
        return (Invoke-ManageMenu)
    }

    if ([string]::IsNullOrEmpty($DataDirectory)) {
        throw ((Get-MgrMsg 'MgrErrTestRootRequired') + [Environment]::NewLine + (Get-MgrMsg 'MgrUsage'))
    }
    $resolved = Resolve-TestDataDirectory -Directory $DataDirectory
    if ($null -eq $resolved) { throw (Get-MgrMsg 'MgrErrTestRootInvalid' @($DataDirectory)) }
    if ([string]::IsNullOrEmpty($Action)) {
        throw ((Get-MgrMsg 'MgrErrActionRequired') + [Environment]::NewLine + (Get-MgrMsg 'MgrUsage'))
    }
    if (-not [string]::IsNullOrEmpty($script:MgrTodayOverride) -and -not (Test-ApprovedDateText -Text $script:MgrTodayOverride)) {
        throw (Get-MgrMsg 'MgrErrTodayInvalid' @($script:MgrTodayOverride))
    }
    $script:MgrPaths = Get-ApprovedPackagesPaths -DataDirectory $resolved
    $arguments = @{ Name = $Name; Value = $Value; VersionList = $VersionList; Status = $Status; Purpose = $Purpose; Notes = $Notes }
    return (Invoke-ManageOperation -ActionName $Action -Arguments $arguments)
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $results = @(Invoke-ManageMain)
    $exitCode = [int]$results[$results.Count - 1]
} catch {
    $errorText = $_.Exception.Message
    if ($null -ne $script:MgrMessages) { $errorText = Get-MgrMsg 'ErrorPrefix' @($errorText) }
    Write-Host $errorText -ForegroundColor Red
    $exitCode = 1
}
exit $exitCode
