<#
.SYNOPSIS
    Installs the packages listed in a project's requirements files into the project's own .venv,
    after checking every direct dependency against the approved package list.

.DESCRIPTION
    Terminal use (the project is given explicitly):
        .\.tools\ApprovedPackages\Install-Packages.ps1 -ProjectPath ".\Projects\Project Name" -Target Runtime
    VS Code task use (the project is chosen from a list):
        .\.tools\ApprovedPackages\Install-Packages.ps1 -SelectProject -Target Runtime

    -Target is Runtime (requirements.txt), Development (requirements-dev.txt), or All (both files).
    Exactly one of -ProjectPath and -SelectProject is required. The tool never guesses the project from the
    current directory and never selects a project automatically.
    -ValidateOnly performs every check and shows the install plan, but never runs pip and never writes a file.

    Only direct dependencies are checked and passed to pip, in a single pip call. Transitive dependencies are
    left to pip and are never written to the requirements files. After a successful install, requirements lines
    that had no version are rewritten to the exact installed version (only those lines are changed).
    The tool never disables SSL verification, never adds --trusted-host or --upgrade, never edits pip or network
    settings, never rolls back, and never runs git or changes the PowerShell execution policy.
    Messages are read from ApprovedPackages.messages.json (UTF-8, no BOM).

    -TestMode and its related parameters are for automated tests only.
#>
[CmdletBinding()]
param(
    [string]$ProjectPath,
    [switch]$SelectProject,
    [string]$Target,
    [switch]$ValidateOnly,
    [switch]$TestMode,
    [string]$TestWorkspaceRoot,
    [switch]$SkipConfirmation,
    [string]$ConfirmAnswer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ApprovedPackages.Common.ps1')

$script:InstBoundNames = @($PSBoundParameters.Keys)
$script:InstMessages = $null
$script:InstSkipConfirm = $SkipConfirmation.IsPresent
$script:InstConfirmAnswer = $ConfirmAnswer
$script:InstTestMarkerName = '.install-packages-test-root'
$script:InstTestOnlyNames = @('TestWorkspaceRoot', 'SkipConfirmation', 'ConfirmAnswer')
$script:InstTargets = @('Runtime', 'Development', 'All')
$script:InstallRequiredKeys = @(
    'ErrorPrefix',
    'ErrReadFileNotFound', 'ErrReadInvalidUtf8', 'ErrReadInvalidJson',
    'ProblemRootNotObject', 'ProblemSchemaVersionMissing', 'ProblemSchemaVersionUnsupported', 'ProblemPackagesNotArray',
    'ProblemUnknownField', 'ProblemPackageNotObject', 'ProblemFieldMissing', 'ProblemFieldNotString',
    'ProblemNameInvalid', 'ProblemNameDuplicate', 'ProblemNameDuplicateNormalized',
    'ProblemAllowedVersionsNotArray', 'ProblemAllowedVersionInvalid', 'ProblemAllowedVersionDuplicate',
    'ProblemStatusInvalid', 'ProblemApprovedDateInvalid', 'ProblemApprovedDateMustBeEmpty',
    'InstUsage', 'InstErrTestModeOnly', 'InstErrTestRootRequired', 'InstErrTestRootInvalid', 'InstErrTargetInvalid',
    'InstErrProjectSpec', 'InstErrProjectNotUnderProjects', 'InstErrProjectPathInvalid', 'InstErrProjectLink',
    'InstErrNoProjects', 'InstListHeader', 'InstListItem', 'InstPromptSelect', 'InstSelectInvalid', 'InstErrProjectChanged',
    'InstErrVenvMissing', 'InstErrReqMissing', 'InstErrReqInvalidUtf8', 'InstReqProblemHeader', 'InstReqProblem',
    'InstReqProblemOption', 'InstReqProblemUrl', 'InstReqProblemLocalPath', 'InstReqProblemExtras', 'InstReqProblemMarker',
    'InstReqProblemInlineComment', 'InstReqProblemOperator', 'InstReqProblemFormat', 'InstReqProblemWildcard',
    'InstReqProblemUnsupportedVersion', 'InstReqProblemEmptyVersion', 'InstReqProblemDuplicate', 'InstReqProblemDuplicateAcrossFiles',
    'InstDecNotRegistered', 'InstDecStatusPending', 'InstDecStatusDeprecated', 'InstDecStatusDisabled', 'InstDecStatusInvalid',
    'InstDecVersionUnsupportedFormat', 'InstDecVersionNotAllowed', 'InstDecNeedsPin',
    'InstStopHeader', 'InstPlanHeader', 'InstPlanProject', 'InstPlanRow',
    'InstModePinned', 'InstModeFixedFromList', 'InstModeRangeFromList', 'InstModeAnyVersion', 'InstPlanFooter',
    'InstWarnAnyVersion', 'InstPromptAnyVersion', 'InstPromptConfirm', 'InstCancelled', 'InstValidateOnlyDone',
    'InstNothingToInstall', 'InstErrFreezeBefore', 'InstInstalling', 'InstPipFailed', 'InstPipFailedReview',
    'InstChangesHeader', 'InstChangeRow', 'InstKindAdded', 'InstKindChanged', 'InstKindRemoved', 'InstChangesNone', 'InstChangesUnknown',
    'InstErrFreezeAfter', 'InstVerifyHeader', 'InstVerifyMissing', 'InstVerifyMismatch', 'InstVerifyUnsupported',
    'InstPinsUpdated', 'InstPinRow', 'InstPinsNone', 'InstErrPinWrite', 'InstDone', 'InstFreezeHeader', 'InstFreezeRow'
)

function Get-InstMsg {
    param(
        [string]$Key,
        [object[]]$FormatArgs
    )

    return (Get-ToolMessage -Messages $script:InstMessages -Key $Key -FormatArgs $FormatArgs)
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

function Confirm-Action {
    param([string]$Prompt)

    if ($script:InstSkipConfirm) { return $true }
    if (-not [string]::IsNullOrEmpty($script:InstConfirmAnswer)) { return ($script:InstConfirmAnswer -eq 'Y') }
    return (Read-YesNo -Prompt $Prompt)
}

# ---------------------------------------------------------------------------
# Arguments and roots
# ---------------------------------------------------------------------------

function Assert-InstallArguments {
    $usage = Get-InstMsg 'InstUsage'
    $testOnly = @($script:InstTestOnlyNames | Where-Object { $script:InstBoundNames -contains $_ })
    if (-not $TestMode.IsPresent) {
        if ($testOnly.Count -gt 0) {
            $names = ($testOnly | ForEach-Object { '-' + $_ }) -join ', '
            throw ((Get-InstMsg 'InstErrTestModeOnly' @($names)) + [Environment]::NewLine + $usage)
        }
    } else {
        if ([string]::IsNullOrEmpty($TestWorkspaceRoot)) {
            throw ((Get-InstMsg 'InstErrTestRootRequired') + [Environment]::NewLine + $usage)
        }
        if (-not [string]::IsNullOrEmpty($script:InstConfirmAnswer) -and @('Y', 'N') -cnotcontains $script:InstConfirmAnswer) {
            throw $usage
        }
    }
    if ([string]::IsNullOrEmpty($Target) -or $script:InstTargets -cnotcontains $Target) {
        throw ((Get-InstMsg 'InstErrTargetInvalid') + [Environment]::NewLine + $usage)
    }
    $hasPath = -not [string]::IsNullOrEmpty($ProjectPath)
    if ($hasPath -eq $SelectProject.IsPresent) {
        throw ((Get-InstMsg 'InstErrProjectSpec') + [Environment]::NewLine + $usage)
    }
}

function Resolve-InstallRoots {
    $paths = Get-ApprovedPackagesPaths
    $root = $paths.WorkspaceRoot
    if ($TestMode.IsPresent) {
        $invalid = Get-InstMsg 'InstErrTestRootInvalid' @($TestWorkspaceRoot)
        $full = [System.IO.Path]::GetFullPath($TestWorkspaceRoot).TrimEnd('\')
        $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
        if (-not $full.StartsWith($temp + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw $invalid }
        if (-not (Test-Path -LiteralPath (Join-Path $full $script:InstTestMarkerName) -PathType Leaf)) { throw $invalid }
        if (-not (Test-Path -LiteralPath (Join-Path $full 'Projects') -PathType Container)) { throw $invalid }
        $root = $full
    }
    $projectsRoot = Join-Path $root 'Projects'
    if (-not (Test-Path -LiteralPath $projectsRoot -PathType Container)) {
        throw (Get-InstMsg 'InstErrNoProjects' @($projectsRoot))
    }
    return [pscustomobject]@{
        WorkspaceRoot = $root
        ProjectsRoot  = $projectsRoot
        DataDirectory = Join-Path $root 'ApprovedPackages'
    }
}

# ---------------------------------------------------------------------------
# Project selection
# ---------------------------------------------------------------------------

function Assert-ProjectFolder {
    param(
        [string]$FullPath,
        [string]$ProjectsRoot
    )

    $projectsFull = [System.IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\')
    $full = [System.IO.Path]::GetFullPath($FullPath).TrimEnd('\')
    $leaf = Split-Path -Leaf $full
    if ((Split-Path -Parent $full) -ine $projectsFull -or $leaf -notlike 'Project *' -or $leaf -like '_Template*') {
        throw (Get-InstMsg 'InstErrProjectNotUnderProjects' @($full))
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw (Get-InstMsg 'InstErrProjectPathInvalid' @($full))
    }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw (Get-InstMsg 'InstErrProjectLink' @($full))
    }
    return [pscustomobject]@{ FullPath = $item.FullName; Name = $item.Name; CreatedUtc = $item.CreationTimeUtc }
}

function Resolve-ProjectFromPath {
    param(
        [string]$InputPath,
        [string]$ProjectsRoot
    )

    $unresolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
    return (Assert-ProjectFolder -FullPath $unresolved -ProjectsRoot $ProjectsRoot)
}

function Get-SelectableProjects {
    param([string]$ProjectsRoot)

    $items = @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force | Where-Object {
            ($_.Name -like 'Project *') -and ($_.Name -notlike '_Template*') -and
            -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden) -and
            -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        })
    if ($items.Count -le 1) { return $items }
    $keys = [string[]]@($items | ForEach-Object { $_.Name })
    $sorted = [object[]]$items.Clone()
    [System.Array]::Sort($keys, $sorted, [System.StringComparer]::OrdinalIgnoreCase)
    return $sorted
}

function Select-ProjectFromList {
    param([string]$ProjectsRoot)

    $items = @(Get-SelectableProjects -ProjectsRoot $ProjectsRoot)
    if ($items.Count -eq 0) { throw (Get-InstMsg 'InstErrNoProjects' @($ProjectsRoot)) }
    $snapshot = @($items | ForEach-Object { [pscustomobject]@{ FullPath = $_.FullName; Name = $_.Name; CreatedUtc = $_.CreationTimeUtc } })
    Write-Host (Get-InstMsg 'InstListHeader')
    for ($i = 0; $i -lt $snapshot.Count; $i++) {
        Write-Host (Get-InstMsg 'InstListItem' @(($i + 1), $snapshot[$i].Name))
    }
    $chosen = $null
    while ($null -eq $chosen) {
        $answer = (Read-UserInput -Prompt (Get-InstMsg 'InstPromptSelect')).Trim()
        $number = 0
        if ($answer -cmatch '^[0-9]+$' -and [int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $snapshot.Count) {
            $chosen = $snapshot[$number - 1]
        } else {
            Write-Host (Get-InstMsg 'InstSelectInvalid' @($snapshot.Count))
        }
    }
    $verified = Assert-ProjectFolder -FullPath $chosen.FullPath -ProjectsRoot $ProjectsRoot
    if ($verified.CreatedUtc -ne $chosen.CreatedUtc) { throw (Get-InstMsg 'InstErrProjectChanged' @($chosen.FullPath)) }
    return $verified
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

function Get-TargetRequirementFiles {
    param(
        [string]$ProjectFullPath,
        [string]$TargetName
    )

    $names = @('requirements.txt')
    if ($TargetName -ceq 'Development') { $names = @('requirements-dev.txt') }
    if ($TargetName -ceq 'All') { $names = @('requirements.txt', 'requirements-dev.txt') }
    return @($names | ForEach-Object { [pscustomobject]@{ Name = $_; Path = Join-Path $ProjectFullPath $_ } })
}

function New-InstallPlan {
    param(
        [string]$ProjectFullPath,
        [string]$TargetName,
        [string]$DataDirectory
    )

    $stops = New-Object 'System.Collections.Generic.List[string]'
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $venvPython = Join-Path $ProjectFullPath '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        $stops.Add((Get-InstMsg 'InstErrVenvMissing' @($ProjectFullPath)))
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $requirementProblems = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    foreach ($file in @(Get-TargetRequirementFiles -ProjectFullPath $ProjectFullPath -TargetName $TargetName)) {
        if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) {
            $stops.Add((Get-InstMsg 'InstErrReqMissing' @($file.Path)))
            continue
        }
        $read = Read-RequirementsFile -Path $file.Path
        if ($read.ReadErrorCode -ceq 'InvalidUtf8') {
            $stops.Add((Get-InstMsg 'InstErrReqInvalidUtf8' @($file.Path)))
            continue
        }
        foreach ($problem in @($read.Problems)) {
            $reason = Get-InstMsg ('InstReqProblem' + $problem.Code)
            $requirementProblems.Add((Get-InstMsg 'InstReqProblem' @($file.Name, $problem.LineNumber, $problem.Text, $reason)))
        }
        foreach ($entry in @($read.Entries)) {
            $normalized = ConvertTo-NormalizedPackageName -Name $entry.Name
            if ($seen.ContainsKey($normalized)) {
                $reason = Get-InstMsg 'InstReqProblemDuplicateAcrossFiles'
                $requirementProblems.Add((Get-InstMsg 'InstReqProblem' @($file.Name, $entry.LineNumber, $entry.Raw, $reason)))
                continue
            }
            $seen[$normalized] = $file.Name
            $entries.Add([pscustomobject]@{ File = $file.Name; Path = $file.Path; Name = $entry.Name; Version = $entry.Version; LineNumber = $entry.LineNumber; Raw = $entry.Raw })
        }
    }
    if ($requirementProblems.Count -gt 0) {
        $stops.Add((Get-InstMsg 'InstReqProblemHeader'))
        foreach ($line in $requirementProblems) { $stops.Add($line) }
    }

    $paths = Get-ApprovedPackagesPaths -DataDirectory $DataDirectory
    $read = Read-ApprovedPackageList -Path $paths.JsonPath
    if (-not $read.Success) {
        $stops.Add((Get-InstMsg ('ErrRead' + $read.ErrorCode) @($read.ErrorDetail)))
    } else {
        $listProblems = @(Test-ApprovedPackageList -Data $read.Data)
        if ($listProblems.Count -gt 0) {
            foreach ($problem in $listProblems) { $stops.Add((Get-InstMsg ('Problem' + $problem.Code) @($problem.Package, $problem.Detail))) }
        } else {
            $packages = @($read.Data.packages)
            $decisions = Get-RequirementsDecisions -Packages $packages -Entries @($entries.ToArray())
            foreach ($result in @($decisions.Results)) {
                $entry = $result.Entry
                $decision = $result.Decision
                $allowedText = ''
                if ($null -ne $result.Package) { $allowedText = (@($result.Package.allowedVersions) -join ', ') }
                if (-not $decision.Allowed) {
                    $stops.Add((Get-InstMsg ('InstDec' + $decision.Code) @($entry.Name, $entry.Version, $allowedText)))
                    continue
                }
                $spec = Get-PipRequirementSpec -Name $entry.Name -Package $result.Package -RequestedVersion $entry.Version
                if ($spec.Mode -ceq 'NeedsPin') {
                    $stops.Add((Get-InstMsg 'InstDecNeedsPin' @($entry.Name, $allowedText)))
                    continue
                }
                $rows.Add([pscustomobject]@{ Entry = $entry; Package = $result.Package; Spec = $spec.Spec; Mode = $spec.Mode })
            }
        }
    }
    return [pscustomobject]@{ Stops = $stops.ToArray(); Rows = $rows.ToArray(); VenvPython = $venvPython }
}

function Show-InstallPlan {
    param(
        [object]$Plan,
        [string]$ProjectFullPath
    )

    Write-Host ''
    Write-Host (Get-InstMsg 'InstPlanHeader' @($Target))
    Write-Host (Get-InstMsg 'InstPlanProject' @($ProjectFullPath))
    foreach ($row in @($Plan.Rows)) {
        Write-Host (Get-InstMsg 'InstPlanRow' @($row.Entry.File, $row.Entry.Name, (Get-InstMsg ('InstMode' + $row.Mode)), $row.Spec))
    }
    Write-Host (Get-InstMsg 'InstPlanFooter')
    foreach ($row in @($Plan.Rows | Where-Object { $_.Mode -ceq 'AnyVersion' })) {
        Write-Host ''
        Write-Host (Get-InstMsg 'InstWarnAnyVersion' @($row.Entry.Name)) -ForegroundColor Yellow
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Running pip
# ---------------------------------------------------------------------------

function Invoke-PythonCommand {
    param(
        [string]$Python,
        [string[]]$Arguments,
        [switch]$Show
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $global:LASTEXITCODE = 0
    try {
        & $Python @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $text = $_.Exception.Message } else { $text = [string]$_ }
            $lines.Add($text)
            if ($Show.IsPresent) { Write-Host $text }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines.ToArray() }
}

function Write-SnapshotDifference {
    param(
        [hashtable]$Before,
        [object]$AfterResult
    )

    if ($AfterResult.ExitCode -ne 0) {
        Write-Host (Get-InstMsg 'InstChangesUnknown')
        return
    }
    $changes = @(Compare-FreezeSnapshots -Before $Before -After (ConvertFrom-PipFreezeText -Lines $AfterResult.Lines))
    if ($changes.Count -eq 0) {
        Write-Host (Get-InstMsg 'InstChangesNone')
        return
    }
    Write-Host (Get-InstMsg 'InstChangesHeader')
    foreach ($change in $changes) {
        Write-Host (Get-InstMsg 'InstChangeRow' @($change.Name, (Get-InstMsg ('InstKind' + $change.Kind)), $change.Before, $change.After))
    }
}

function Get-InstalledVersionProblems {
    param(
        [object[]]$Rows,
        [hashtable]$AfterMap
    )

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $pins = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $Rows) {
        $normalized = ConvertTo-NormalizedPackageName -Name $row.Entry.Name
        if (-not $AfterMap.ContainsKey($normalized)) {
            $problems.Add((Get-InstMsg 'InstVerifyMissing' @($row.Entry.Name)))
            continue
        }
        $actual = $AfterMap[$normalized]
        if ($null -ne $row.Entry.Version) {
            if ($null -ne (Get-ConcreteVersionProblem -Version $actual) -or -not (Test-VersionsEqual -Left $actual -Right $row.Entry.Version)) {
                $problems.Add((Get-InstMsg 'InstVerifyMismatch' @($row.Entry.Name, $actual, $row.Entry.Version)))
            }
            continue
        }
        if ($null -ne (Get-ConcreteVersionProblem -Version $actual)) {
            $problems.Add((Get-InstMsg 'InstVerifyUnsupported' @($row.Entry.Name, $actual)))
            continue
        }
        $allowed = @($row.Package.allowedVersions)
        if ($allowed.Count -gt 0 -and -not (Test-VersionAllowedByList -AllowedVersions $allowed -Version $actual)) {
            $problems.Add((Get-InstMsg 'InstVerifyMismatch' @($row.Entry.Name, $actual, ($allowed -join ', '))))
            continue
        }
        $pins.Add([pscustomobject]@{ File = $row.Entry.File; Path = $row.Entry.Path; LineNumber = $row.Entry.LineNumber; Name = $row.Entry.Name; Version = $actual })
    }
    return [pscustomobject]@{ Problems = $problems.ToArray(); Pins = $pins.ToArray() }
}

function Invoke-PackageInstall {
    param([object]$Plan)

    $python = $Plan.VenvPython
    $beforeResult = Invoke-PythonCommand -Python $python -Arguments @('-m', 'pip', 'freeze')
    if ($beforeResult.ExitCode -ne 0) {
        Write-Host (Get-InstMsg 'InstErrFreezeBefore' @($beforeResult.ExitCode)) -ForegroundColor Red
        return 1
    }
    $beforeMap = ConvertFrom-PipFreezeText -Lines $beforeResult.Lines

    Write-Host (Get-InstMsg 'InstInstalling')
    $pipArguments = @('-m', 'pip', 'install') + @($Plan.Rows | ForEach-Object { $_.Spec })
    $installResult = Invoke-PythonCommand -Python $python -Arguments $pipArguments -Show
    $afterResult = Invoke-PythonCommand -Python $python -Arguments @('-m', 'pip', 'freeze')

    if ($installResult.ExitCode -ne 0) {
        Write-Host (Get-InstMsg 'InstPipFailed' @($installResult.ExitCode)) -ForegroundColor Red
        Write-SnapshotDifference -Before $beforeMap -AfterResult $afterResult
        Write-Host (Get-InstMsg 'InstPipFailedReview') -ForegroundColor Yellow
        return 1
    }
    if ($afterResult.ExitCode -ne 0) {
        Write-Host (Get-InstMsg 'InstErrFreezeAfter' @($afterResult.ExitCode)) -ForegroundColor Red
        return 1
    }
    $afterMap = ConvertFrom-PipFreezeText -Lines $afterResult.Lines
    $verified = Get-InstalledVersionProblems -Rows @($Plan.Rows) -AfterMap $afterMap
    if (@($verified.Problems).Count -gt 0) {
        Write-Host (Get-InstMsg 'InstVerifyHeader') -ForegroundColor Red
        foreach ($line in @($verified.Problems)) { Write-Host $line -ForegroundColor Red }
        return 1
    }

    $pins = @($verified.Pins)
    if ($pins.Count -eq 0) {
        Write-Host (Get-InstMsg 'InstPinsNone')
    }
    foreach ($group in @($pins | Group-Object -Property Path)) {
        $updates = @($group.Group)
        try {
            Update-RequirementsPins -Path $group.Name -Updates $updates
        } catch {
            Write-Host (Get-InstMsg 'InstErrPinWrite' @($updates[0].File, $_.Exception.Message)) -ForegroundColor Red
            return 1
        }
        Write-Host (Get-InstMsg 'InstPinsUpdated' @($updates[0].File))
        foreach ($update in $updates) { Write-Host (Get-InstMsg 'InstPinRow' @($update.Name, $update.Version)) }
    }
    Write-Host ''
    Write-Host (Get-InstMsg 'InstFreezeHeader')
    foreach ($line in @($afterResult.Lines)) { Write-Host (Get-InstMsg 'InstFreezeRow' @($line)) }
    Write-Host (Get-InstMsg 'InstDone')
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-InstallMain {
    $paths = Get-ApprovedPackagesPaths
    $script:InstMessages = Import-ToolMessages -Path $paths.MessagesPath -RequiredKeys $script:InstallRequiredKeys
    Assert-InstallArguments
    $roots = Resolve-InstallRoots

    if ($SelectProject.IsPresent) {
        $project = Select-ProjectFromList -ProjectsRoot $roots.ProjectsRoot
    } else {
        $project = Resolve-ProjectFromPath -InputPath $ProjectPath -ProjectsRoot $roots.ProjectsRoot
    }

    $plan = New-InstallPlan -ProjectFullPath $project.FullPath -TargetName $Target -DataDirectory $roots.DataDirectory
    if (@($plan.Stops).Count -gt 0) {
        Write-Host (Get-InstMsg 'InstStopHeader') -ForegroundColor Red
        foreach ($line in @($plan.Stops)) { Write-Host $line -ForegroundColor Red }
        return 1
    }
    if (@($plan.Rows).Count -eq 0) {
        Write-Host (Get-InstMsg 'InstNothingToInstall')
        return 0
    }

    Show-InstallPlan -Plan $plan -ProjectFullPath $project.FullPath
    if ($ValidateOnly.IsPresent) {
        Write-Host (Get-InstMsg 'InstValidateOnlyDone')
        return 0
    }
    foreach ($row in @($plan.Rows | Where-Object { $_.Mode -ceq 'AnyVersion' })) {
        if (-not (Confirm-Action -Prompt (Get-InstMsg 'InstPromptAnyVersion'))) {
            Write-Host (Get-InstMsg 'InstCancelled')
            return 2
        }
    }
    if (-not (Confirm-Action -Prompt (Get-InstMsg 'InstPromptConfirm'))) {
        Write-Host (Get-InstMsg 'InstCancelled')
        return 2
    }
    return (Invoke-PackageInstall -Plan $plan)
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $results = @(Invoke-InstallMain)
    $exitCode = [int]$results[$results.Count - 1]
} catch {
    $errorText = $_.Exception.Message
    if ($null -ne $script:InstMessages) { $errorText = Get-InstMsg 'ErrorPrefix' @($errorText) }
    Write-Host $errorText -ForegroundColor Red
    $exitCode = 1
}
exit $exitCode
