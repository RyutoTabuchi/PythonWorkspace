<#
.SYNOPSIS
    Creates a new Python project under Projects\ from Projects\_Template_Python.

.DESCRIPTION
    Interactive by default. Requires Windows PowerShell 5.1 or later.
    All user-facing messages are read from New-Project.messages.json (UTF-8, no BOM).
    The tool never installs packages, never runs git add/commit/push, and never
    changes the PowerShell execution policy.

    Test-only parameters (TestWorkspaceRoot, SkipConfirmation, SkipGitInit,
    SkipVenv, VenvFailureAnswer) are accepted only together with -TestMode.
#>
[CmdletBinding()]
param(
    [string]$ProjectDisplayName,
    [string]$PythonIdentifier,
    [string]$PythonPath,
    [string]$MinimumPythonVersion,
    [switch]$TestMode,
    [string]$TestWorkspaceRoot,
    [switch]$SkipConfirmation,
    [switch]$SkipGitInit,
    [switch]$SkipVenv,
    [ValidateSet('Y', 'N')]
    [string]$VenvFailureAnswer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:BoundNames = @($PSBoundParameters.Keys)
$script:Messages = $null
$script:CreatedPath = $null
$script:CreatedByThisRun = $false
$script:TestRootMarkerName = '.new-project-test-root'
$script:TestOnlyParameters = @('TestWorkspaceRoot', 'SkipConfirmation', 'SkipGitInit', 'SkipVenv', 'VenvFailureAnswer')
$script:TemplateFolderName = '_Template_Python'
$script:PlaceholderFolderName = '__PYTHON_IDENTIFIER__'
$script:ExcludedCopyNames = @('.git', '.venv', 'venv', '__pycache__')
$script:RequiredTemplateFiles = @(
    '.gitignore',
    'README.md',
    'requirements.txt',
    'requirements-dev.txt',
    'source\main.py',
    'source\__PYTHON_IDENTIFIER__\__init__.py',
    'tests\README.md',
    'config\.gitkeep',
    'input\.gitkeep',
    'output\.gitkeep',
    'logs\.gitkeep'
)
$script:RequiredMessageKeys = @(
    'Usage', 'ErrorPrefix', 'ErrProjectsMissing', 'ErrTemplateMissing', 'ErrTemplateFiles', 'ErrTemplateLink',
    'ErrTestModeOnly', 'ErrTestRootRequired', 'ErrTestRootInvalid',
    'PromptDisplayName', 'NormalizedPrefix', 'NameEmpty', 'NameEdgeSpace', 'NameTrailingDot',
    'NameInvalidChars', 'NameReserved', 'NameExists',
    'PythonScanning', 'PythonNoneFound', 'PythonListHeader', 'PythonListItem', 'PromptPythonNumber',
    'PythonNumberInvalid', 'PythonPathInvalid',
    'PromptIdentifier', 'IdEmpty', 'IdMain', 'IdSpace', 'IdHyphen', 'IdNonAscii', 'IdLeadingDigit',
    'IdChars', 'IdKeyword', 'IdStdlibWarning', 'PromptStdlibConfirm', 'IdStdlibDeclined', 'IdStdlibUnknown',
    'PromptMinVersion', 'MinVerFormat', 'MinVerTooLow', 'MinVerTooHigh',
    'PlanHeader', 'PlanDisplayName', 'PlanFolder', 'PlanPath', 'PlanIdentifier', 'PlanPython',
    'PlanMinVersion', 'PlanVenv', 'PlanVenvSkipped', 'PlanGit', 'PlanGitSkipped', 'PlanNoPackages',
    'PathWarnHeader', 'PathWarnLength', 'PathWarnLongDisabled', 'PathWarnLongEnabled', 'PathWarnLongUnknown',
    'PathWarnVenv', 'PathWarnPackages', 'PathWarnShorten',
    'PromptConfirm', 'Cancelled', 'CreatingFolder', 'CopyingTemplate', 'ReplacingTokens', 'TokenLeftovers',
    'CreatingVenv', 'VenvCreated', 'VenvFailed', 'PromptDeleteOnVenvFail', 'DeletedProject', 'KeptProject',
    'DeleteRefused', 'PartialKept', 'GitInitialized', 'GitInitFailed', 'GitSkipped',
    'DoneHeader', 'DoneNoPackages', 'DoneRun', 'GitViewGuidance'
)

# ---------------------------------------------------------------------------
# Messages and input helpers
# ---------------------------------------------------------------------------

function Import-Messages {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Message file not found: $Path"
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $text = [System.IO.File]::ReadAllText($Path, $utf8)
    try {
        $loaded = $text | ConvertFrom-Json
    } catch {
        throw "Message file is not valid JSON: $Path"
    }
    $missing = @($script:RequiredMessageKeys | Where-Object { $null -eq $loaded.PSObject.Properties[$_] })
    if ($missing.Count -gt 0) {
        throw ('Message file is missing required keys: ' + ($missing -join ', '))
    }
    $script:Messages = $loaded
}

function Get-Msg {
    param(
        [string]$Key,
        [object[]]$FormatArgs
    )

    $value = $script:Messages.PSObject.Properties[$Key].Value
    if ($value -is [System.Array]) {
        $value = ($value -join [Environment]::NewLine)
    }
    $text = [string]$value
    if ($null -ne $FormatArgs -and $FormatArgs.Count -gt 0) {
        return [string]::Format($text, $FormatArgs)
    }
    return $text
}

function Read-UserInput {
    param([string]$Prompt)

    $value = Read-Host -Prompt $Prompt
    if ($null -eq $value) {
        throw 'Input stream ended.'
    }
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

# ---------------------------------------------------------------------------
# Test mode
# ---------------------------------------------------------------------------

function Assert-TestModeArguments {
    param(
        [string[]]$BoundNames,
        [bool]$TestModeEnabled,
        [string]$Root
    )

    $used = @($script:TestOnlyParameters | Where-Object { $BoundNames -contains $_ })
    if (-not $TestModeEnabled) {
        if ($used.Count -gt 0) {
            $names = ($used | ForEach-Object { '-' + $_ }) -join ', '
            throw ((Get-Msg 'ErrTestModeOnly' @($names)) + [Environment]::NewLine + (Get-Msg 'Usage'))
        }
        return
    }
    if ([string]::IsNullOrEmpty($Root)) {
        throw ((Get-Msg 'ErrTestRootRequired') + [Environment]::NewLine + (Get-Msg 'Usage'))
    }
}

function Resolve-TestProjectsRoot {
    param([string]$Root)

    $invalid = Get-Msg 'ErrTestRootInvalid' @($Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { throw $invalid }
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not $fullRoot.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw $invalid }
    if (-not (Test-Path -LiteralPath (Join-Path $fullRoot $script:TestRootMarkerName) -PathType Leaf)) { throw $invalid }
    $projects = Join-Path $fullRoot 'Projects'
    if (-not (Test-Path -LiteralPath $projects -PathType Container)) { throw $invalid }
    return $projects
}

# ---------------------------------------------------------------------------
# Display name
# ---------------------------------------------------------------------------

function ConvertTo-ProjectDisplayName {
    param([string]$InputName)

    if ($null -eq $InputName) { return '' }
    return [regex]::Replace($InputName, '^(?i:project)[ \t]+', '')
}

function Get-DisplayNameProblem {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return 'NameEmpty' }
    if ($Name -match '^\s' -or $Name -match '\s$') { return 'NameEdgeSpace' }
    if ($Name.EndsWith('.')) { return 'NameTrailingDot' }
    if ($Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return 'NameInvalidChars' }
    $baseName = $Name.Split('.')[0].TrimEnd()
    if ($baseName -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') { return 'NameReserved' }
    return $null
}

function Get-ProjectFolderName {
    param([string]$DisplayName)

    return ('Project ' + $DisplayName)
}

function Get-ValidDisplayName {
    param(
        [string]$Initial,
        [string]$ProjectsRoot
    )

    $fromParameter = -not [string]::IsNullOrEmpty($Initial)
    $candidate = $Initial
    while ($true) {
        if (-not $fromParameter) {
            $candidate = Read-UserInput -Prompt (Get-Msg 'PromptDisplayName')
        }
        $name = ConvertTo-ProjectDisplayName -InputName $candidate
        if ($name -ne $candidate) {
            Write-Host (Get-Msg 'NormalizedPrefix' @($name))
        }
        $problem = Get-DisplayNameProblem -Name $name
        if ($null -eq $problem) {
            $destination = Join-Path $ProjectsRoot (Get-ProjectFolderName -DisplayName $name)
            if (Test-Path -LiteralPath $destination) { $problem = 'NameExists' }
        }
        if ($null -eq $problem) { return $name }
        $message = Get-Msg $problem @($name)
        if ($fromParameter) { throw $message }
        Write-Host $message
    }
}

# ---------------------------------------------------------------------------
# Python detection and selection
# ---------------------------------------------------------------------------

function Invoke-PythonProbe {
    param(
        [string]$Path,
        [string]$Code,
        [int]$TimeoutMilliseconds = 20000
    )

    $result = [pscustomobject]@{ Started = $false; TimedOut = $false; ExitCode = -1; Output = '' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.Arguments = '-c "' + $Code + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return $result
    }
    $result.Started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        try { $process.Kill() } catch { }
        $result.TimedOut = $true
        return $result
    }
    $process.WaitForExit()
    $result.ExitCode = $process.ExitCode
    $result.Output = [string]$stdoutTask.Result
    return $result
}

function Get-PythonInfo {
    param(
        [string]$Path,
        [int]$TimeoutMilliseconds = 20000
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $code = 'import sys,venv,ensurepip;print(sys.version_info[0],sys.version_info[1],sys.version_info[2])'
    $probe = Invoke-PythonProbe -Path $Path -Code $code -TimeoutMilliseconds $TimeoutMilliseconds
    if (-not $probe.Started -or $probe.TimedOut -or $probe.ExitCode -ne 0) { return $null }
    $match = [regex]::Match($probe.Output, '(?m)^(\d+) (\d+) (\d+)\s*$')
    if (-not $match.Success) { return $null }
    $major = [int]$match.Groups[1].Value
    $minor = [int]$match.Groups[2].Value
    $patch = [int]$match.Groups[3].Value
    if ($major -lt 3) { return $null }
    return [pscustomobject]@{
        Path         = [System.IO.Path]::GetFullPath($Path)
        Major        = $major
        Minor        = $minor
        Version      = New-Object System.Version($major, $minor, $patch)
        MinorVersion = ('{0}.{1}' -f $major, $minor)
    }
}

function ConvertFrom-PyLauncherList {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        $match = [regex]::Match([string]$line, '(?<p>[A-Za-z]:\\.+?\.exe)\s*$')
        if ($match.Success) { $match.Groups['p'].Value }
    }
}

function Merge-PythonPaths {
    param([string[]]$Paths)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($path.Trim())
        } catch {
            continue
        }
        if ($seen.Add($full)) { $result.Add($full) }
    }
    return $result.ToArray()
}

function Get-PythonPathCandidates {
    $paths = @()
    if ($null -ne (Get-Command py -ErrorAction SilentlyContinue)) {
        try { $paths += @(ConvertFrom-PyLauncherList -Lines @(& py -0p 2>$null)) } catch { }
    }
    foreach ($name in @('python', 'python3')) {
        try { $paths += @(& where.exe $name 2>$null | Where-Object { $_ -match '\.exe\s*$' }) } catch { }
    }
    $patterns = @()
    if ($env:LOCALAPPDATA) { $patterns += (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe') }
    if ($env:ProgramFiles) { $patterns += (Join-Path $env:ProgramFiles 'Python3*\python.exe') }
    if ($env:SystemDrive) { $patterns += (Join-Path ($env:SystemDrive + '\') 'Python3*\python.exe') }
    foreach ($pattern in $patterns) {
        $paths += @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    return @(Merge-PythonPaths -Paths $paths)
}

function Get-PythonCandidates {
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in @(Get-PythonPathCandidates)) {
        $info = Get-PythonInfo -Path $path
        if ($null -ne $info) { $list.Add($info) }
    }
    return @($list | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true }, Path)
}

function Resolve-PythonSelection {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrEmpty($ExplicitPath)) {
        $info = Get-PythonInfo -Path $ExplicitPath
        if ($null -eq $info) { throw (Get-Msg 'PythonPathInvalid' @($ExplicitPath)) }
        return $info
    }
    Write-Host (Get-Msg 'PythonScanning')
    $candidates = @(Get-PythonCandidates)
    if ($candidates.Count -eq 0) { throw (Get-Msg 'PythonNoneFound') }
    Write-Host (Get-Msg 'PythonListHeader')
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host (Get-Msg 'PythonListItem' @(($i + 1), $candidates[$i].Version.ToString(), $candidates[$i].Path))
    }
    while ($true) {
        $answer = (Read-UserInput -Prompt (Get-Msg 'PromptPythonNumber')).Trim()
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
            return $candidates[$number - 1]
        }
        Write-Host (Get-Msg 'PythonNumberInvalid' @($candidates.Count))
    }
}

function Get-PythonNameInfo {
    param([string]$PythonExecutable)

    $code = "import json,keyword,sys;s=getattr(sys,'stdlib_module_names',None);print(json.dumps({'kw':keyword.kwlist,'std':None if s is None else sorted(s)}))"
    $probe = Invoke-PythonProbe -Path $PythonExecutable -Code $code
    $keywords = @()
    $stdlib = $null
    if ($probe.Started -and -not $probe.TimedOut -and $probe.ExitCode -eq 0) {
        try {
            $data = $probe.Output.Trim() | ConvertFrom-Json
            $keywords = @($data.kw)
            if ($null -ne $data.std) { $stdlib = @($data.std) }
        } catch {
            $keywords = @()
            $stdlib = $null
        }
    }
    return [pscustomobject]@{ Keywords = $keywords; StdlibNames = $stdlib }
}

# ---------------------------------------------------------------------------
# Python identifier and minimum version
# ---------------------------------------------------------------------------

function Get-IdentifierProblem {
    param(
        [string]$Name,
        [string[]]$Keywords = @()
    )

    if ([string]::IsNullOrEmpty($Name)) { return 'IdEmpty' }
    if ($Name.ToLowerInvariant() -eq 'main') { return 'IdMain' }
    if ($Name -match '\s') { return 'IdSpace' }
    if ($Name.Contains('-')) { return 'IdHyphen' }
    if ($Name -match '[^\x00-\x7F]') { return 'IdNonAscii' }
    if ($Name -match '^[0-9]') { return 'IdLeadingDigit' }
    if ($Name -cnotmatch '^[a-z_][a-z0-9_]*$') { return 'IdChars' }
    if ($Keywords -ccontains $Name) { return 'IdKeyword' }
    return $null
}

function Test-StdlibName {
    param(
        [string]$Name,
        [string[]]$StdlibNames
    )

    if ($null -eq $StdlibNames) { return $false }
    return ($StdlibNames -ccontains $Name)
}

function Get-ValidIdentifier {
    param(
        [string]$Initial,
        [object]$NameInfo
    )

    $fromParameter = -not [string]::IsNullOrEmpty($Initial)
    $candidate = $Initial
    $unknownNoticeShown = $false
    while ($true) {
        if (-not $fromParameter) {
            $candidate = Read-UserInput -Prompt (Get-Msg 'PromptIdentifier')
        }
        $problem = Get-IdentifierProblem -Name $candidate -Keywords $NameInfo.Keywords
        if ($null -ne $problem) {
            $message = Get-Msg $problem @($candidate)
            if ($fromParameter) { throw $message }
            Write-Host $message
            continue
        }
        if ($null -eq $NameInfo.StdlibNames) {
            if (-not $unknownNoticeShown) {
                Write-Host (Get-Msg 'IdStdlibUnknown')
                $unknownNoticeShown = $true
            }
            return $candidate
        }
        if (-not (Test-StdlibName -Name $candidate -StdlibNames $NameInfo.StdlibNames)) { return $candidate }
        Write-Host (Get-Msg 'IdStdlibWarning' @($candidate))
        if (Read-YesNo -Prompt (Get-Msg 'PromptStdlibConfirm')) { return $candidate }
        if ($fromParameter) { throw (Get-Msg 'IdStdlibDeclined' @($candidate)) }
    }
}

function Get-MinimumVersionProblem {
    param(
        [string]$Text,
        [object]$Python
    )

    if ($Text -notmatch '^\d{1,3}\.\d{1,3}$') { return 'MinVerFormat' }
    $minimum = [version]$Text
    if ($minimum -lt [version]'3.0') { return 'MinVerTooLow' }
    if ($minimum -gt [version]$Python.MinorVersion) { return 'MinVerTooHigh' }
    return $null
}

function Get-ValidMinimumVersion {
    param(
        [string]$Initial,
        [object]$Python
    )

    $fromParameter = -not [string]::IsNullOrEmpty($Initial)
    $candidate = $Initial
    while ($true) {
        if (-not $fromParameter) {
            $answer = (Read-UserInput -Prompt (Get-Msg 'PromptMinVersion' @($Python.MinorVersion))).Trim()
            if ($answer -eq '') { $answer = $Python.MinorVersion }
            $candidate = $answer
        }
        $problem = Get-MinimumVersionProblem -Text $candidate -Python $Python
        if ($null -eq $problem) { return $candidate }
        $message = Get-Msg $problem @($Python.Version.ToString(), $candidate)
        if ($fromParameter) { throw $message }
        Write-Host $message
    }
}

# ---------------------------------------------------------------------------
# Template, placeholders, and file operations
# ---------------------------------------------------------------------------

function Get-MissingTemplateFiles {
    param([string]$TemplateRoot)

    return @($script:RequiredTemplateFiles | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $TemplateRoot $_) -PathType Leaf)
        })
}

function Copy-TemplateTree {
    param(
        [string]$Source,
        [string]$Destination
    )

    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($script:ExcludedCopyNames -contains $item.Name) { continue }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw (Get-Msg 'ErrTemplateLink' @($item.FullName))
        }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            [void](New-Item -ItemType Directory -Path $target -ErrorAction Stop)
            Copy-TemplateTree -Source $item.FullName -Destination $target
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $target
        }
    }
}

function Expand-TemplateTokens {
    param(
        [string]$Text,
        [hashtable]$Values
    )

    $pattern = '\{\{(PROJECT_DISPLAY_NAME|PYTHON_IDENTIFIER|MIN_PYTHON_VERSION)\}\}'
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]({
            param($match)
            [string]$Values[$match.Groups[1].Value]
        }.GetNewClosure())
    return [regex]::Replace($Text, $pattern, $evaluator)
}

function Update-TemplateTokensInFile {
    param(
        [string]$Path,
        [hashtable]$Values
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $original = [System.IO.File]::ReadAllText($Path, $utf8)
    $updated = Expand-TemplateTokens -Text $original -Values $Values
    [System.IO.File]::WriteAllText($Path, $updated, $utf8)
}

function Find-TemplateLeftovers {
    param([string]$ProjectPath)

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $root = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        $relative = $item.FullName.Substring($root.Length + 1)
        if ($relative -match '^(\.venv|\.git)(\\|$)') { continue }
        if ($item.PSIsContainer) {
            if ($item.Name -ceq $script:PlaceholderFolderName) { $problems.Add('folder: ' + $relative) }
            continue
        }
        $text = [System.IO.File]::ReadAllText($item.FullName, $utf8)
        if ($text -match '\{\{[A-Z_]+\}\}' -or $text.Contains($script:PlaceholderFolderName)) {
            $problems.Add('text: ' + $relative)
        }
    }
    return $problems.ToArray()
}

function Test-SafeToRemove {
    param(
        [string]$Path,
        [string]$ProjectsRoot,
        [bool]$CreatedByThisRun
    )

    if (-not $CreatedByThisRun) { return $false }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetFullPath($ProjectsRoot).TrimEnd('\')
    if ((Split-Path -Parent $full) -ine $root) { return $false }
    if ((Split-Path -Leaf $full) -notlike 'Project *') { return $false }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $false }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
    return $true
}

function Remove-ProjectDirectory {
    param([string]$Path)

    [System.IO.Directory]::Delete([System.IO.Path]::GetFullPath($Path), $true)
}

# ---------------------------------------------------------------------------
# Virtual environment and Git
# ---------------------------------------------------------------------------

function New-ProjectVenv {
    param(
        [string]$PythonExecutable,
        [string]$VenvPath,
        [string]$MinimumVersion
    )

    try {
        & $PythonExecutable -m venv $VenvPath | Out-Host
        if ($LASTEXITCODE -ne 0) { return $false }
    } catch {
        return $false
    }
    $venvPython = Join-Path $VenvPath 'Scripts\python.exe'
    $info = Get-PythonInfo -Path $venvPython
    if ($null -eq $info) { return $false }
    return ($info.Version -ge [version]($MinimumVersion + '.0'))
}

function Initialize-ProjectGit {
    param([string]$ProjectPath)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    try {
        & git -C $ProjectPath init -b main | Out-Host
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

function Get-LongPathSetting {
    try {
        $value = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction Stop).LongPathsEnabled
        return [int]$value
    } catch {
        return $null
    }
}

function Write-PathLengthWarning {
    param([string]$Destination)

    Write-Host (Get-Msg 'PathWarnHeader')
    Write-Host (Get-Msg 'PathWarnLength' @($Destination.Length, $Destination))
    $setting = Get-LongPathSetting
    if ($null -eq $setting) {
        Write-Host (Get-Msg 'PathWarnLongUnknown')
    } elseif ($setting -eq 0) {
        Write-Host (Get-Msg 'PathWarnLongDisabled')
    } else {
        Write-Host (Get-Msg 'PathWarnLongEnabled')
    }
    Write-Host (Get-Msg 'PathWarnVenv')
    Write-Host (Get-Msg 'PathWarnPackages')
    Write-Host (Get-Msg 'PathWarnShorten')
}

function Show-CreationPlan {
    param(
        [string]$DisplayName,
        [string]$Destination,
        [string]$Identifier,
        [object]$Python,
        [string]$MinimumVersion
    )

    Write-Host ''
    Write-Host (Get-Msg 'PlanHeader')
    Write-Host (Get-Msg 'PlanDisplayName' @($DisplayName))
    Write-Host (Get-Msg 'PlanFolder' @((Split-Path -Leaf $Destination)))
    Write-Host (Get-Msg 'PlanPath' @($Destination))
    Write-Host (Get-Msg 'PlanIdentifier' @($Identifier))
    Write-Host (Get-Msg 'PlanPython' @($Python.Version.ToString(), $Python.Path))
    Write-Host (Get-Msg 'PlanMinVersion' @($MinimumVersion))
    if ($SkipVenv.IsPresent) { Write-Host (Get-Msg 'PlanVenvSkipped') } else { Write-Host (Get-Msg 'PlanVenv') }
    if ($SkipGitInit.IsPresent) { Write-Host (Get-Msg 'PlanGitSkipped') } else { Write-Host (Get-Msg 'PlanGit') }
    Write-Host (Get-Msg 'PlanNoPackages')
    Write-Host ''
    Write-PathLengthWarning -Destination $Destination
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

function Invoke-NewProject {
    Import-Messages -Path (Join-Path $PSScriptRoot 'New-Project.messages.json')
    Assert-TestModeArguments -BoundNames $script:BoundNames -TestModeEnabled $TestMode.IsPresent -Root $TestWorkspaceRoot

    $workspaceRoot = Split-Path -Parent $PSScriptRoot
    $templateRoot = Join-Path $workspaceRoot ('Projects\' + $script:TemplateFolderName)
    if ($TestMode.IsPresent) {
        $projectsRoot = Resolve-TestProjectsRoot -Root $TestWorkspaceRoot
    } else {
        $projectsRoot = Join-Path $workspaceRoot 'Projects'
    }
    if (-not (Test-Path -LiteralPath $projectsRoot -PathType Container)) {
        throw (Get-Msg 'ErrProjectsMissing' @($projectsRoot))
    }
    if (-not (Test-Path -LiteralPath $templateRoot -PathType Container)) {
        throw (Get-Msg 'ErrTemplateMissing' @($templateRoot))
    }
    $missing = @(Get-MissingTemplateFiles -TemplateRoot $templateRoot)
    if ($missing.Count -gt 0) {
        throw (Get-Msg 'ErrTemplateFiles' @(($missing -join ', ')))
    }

    $displayName = Get-ValidDisplayName -Initial $ProjectDisplayName -ProjectsRoot $projectsRoot
    $python = Resolve-PythonSelection -ExplicitPath $PythonPath
    $nameInfo = Get-PythonNameInfo -PythonExecutable $python.Path
    $identifier = Get-ValidIdentifier -Initial $PythonIdentifier -NameInfo $nameInfo
    $minimumVersion = Get-ValidMinimumVersion -Initial $MinimumPythonVersion -Python $python

    while ($true) {
        $destination = Join-Path $projectsRoot (Get-ProjectFolderName -DisplayName $displayName)
        Show-CreationPlan -DisplayName $displayName -Destination $destination -Identifier $identifier -Python $python -MinimumVersion $minimumVersion
        if ($SkipConfirmation.IsPresent) { break }
        $answer = (Read-UserInput -Prompt (Get-Msg 'PromptConfirm')).Trim()
        if ($answer -ieq 'Y') { break }
        if ($answer -ieq 'R') {
            $displayName = Get-ValidDisplayName -Initial '' -ProjectsRoot $projectsRoot
            continue
        }
        if ($answer -ieq 'N' -or $answer -eq '') {
            Write-Host (Get-Msg 'Cancelled')
            return 2
        }
    }

    if (Test-Path -LiteralPath $destination) {
        throw (Get-Msg 'NameExists' @($displayName))
    }
    Write-Host (Get-Msg 'CreatingFolder' @($destination))
    [void](New-Item -ItemType Directory -Path $destination -ErrorAction Stop)
    $script:CreatedPath = $destination
    $script:CreatedByThisRun = $true

    try {
        Write-Host (Get-Msg 'CopyingTemplate')
        Copy-TemplateTree -Source $templateRoot -Destination $destination
        Write-Host (Get-Msg 'ReplacingTokens')
        Rename-Item -LiteralPath (Join-Path $destination ('source\' + $script:PlaceholderFolderName)) -NewName $identifier
        $values = @{
            PROJECT_DISPLAY_NAME = $displayName
            PYTHON_IDENTIFIER    = $identifier
            MIN_PYTHON_VERSION   = $minimumVersion
        }
        Update-TemplateTokensInFile -Path (Join-Path $destination 'README.md') -Values $values
        $leftovers = @(Find-TemplateLeftovers -ProjectPath $destination)
        if ($leftovers.Count -gt 0) {
            throw (Get-Msg 'TokenLeftovers' @(($leftovers -join ', ')))
        }
    } catch {
        Write-Host (Get-Msg 'PartialKept' @($destination))
        throw
    }

    if (-not $SkipVenv.IsPresent) {
        Write-Host (Get-Msg 'CreatingVenv')
        $venvCreated = New-ProjectVenv -PythonExecutable $python.Path -VenvPath (Join-Path $destination '.venv') -MinimumVersion $minimumVersion
        if (-not $venvCreated) {
            Write-Host (Get-Msg 'VenvFailed')
            if (-not [string]::IsNullOrEmpty($VenvFailureAnswer)) {
                $delete = ($VenvFailureAnswer -eq 'Y')
            } else {
                $delete = Read-YesNo -Prompt (Get-Msg 'PromptDeleteOnVenvFail')
            }
            if ($delete) {
                if (Test-SafeToRemove -Path $destination -ProjectsRoot $projectsRoot -CreatedByThisRun $script:CreatedByThisRun) {
                    Remove-ProjectDirectory -Path $destination
                    Write-Host (Get-Msg 'DeletedProject' @($destination))
                } else {
                    Write-Host (Get-Msg 'DeleteRefused' @($destination))
                }
            } else {
                Write-Host (Get-Msg 'KeptProject' @($destination))
            }
            return 1
        }
        Write-Host (Get-Msg 'VenvCreated')
    }

    if ($SkipGitInit.IsPresent) {
        Write-Host (Get-Msg 'GitSkipped')
    } elseif (Initialize-ProjectGit -ProjectPath $destination) {
        Write-Host (Get-Msg 'GitInitialized')
    } else {
        Write-Warning (Get-Msg 'GitInitFailed' @($destination))
    }

    Write-Host ''
    Write-Host (Get-Msg 'DoneHeader' @($destination))
    Write-Host (Get-Msg 'DoneNoPackages')
    Write-Host (Get-Msg 'DoneRun' @((Split-Path -Leaf $destination)))
    $guidance = (Get-Msg 'GitViewGuidance').Replace('{projectPath}', $destination)
    Write-Host $guidance
    return 0
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $results = @(Invoke-NewProject)
    $exitCode = [int]$results[$results.Count - 1]
} catch {
    $errorText = $_.Exception.Message
    if ($null -ne $script:Messages) { $errorText = Get-Msg 'ErrorPrefix' @($errorText) }
    Write-Host $errorText -ForegroundColor Red
    $exitCode = 1
}
exit $exitCode
