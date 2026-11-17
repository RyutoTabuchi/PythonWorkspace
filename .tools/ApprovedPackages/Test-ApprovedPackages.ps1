<#
.SYNOPSIS
    Tests the approved-package tools and the initial approved package list.

.DESCRIPTION
    Uses only temporary files under %TEMP% (created and removed by this test), never installs packages,
    never uses the network, never runs git, and never changes the real ApprovedPackages folder.
    Results are Pass, Fail, or NotReady. The exit code is 1 only when a check Fails.
    Checks that depend on Install-Packages.ps1 use a fake python.exe (compiled in %TEMP%); no real pip runs.
    Requires Windows PowerShell 5.1 or later.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolsDirectory = $PSScriptRoot
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

. (Join-Path $toolsDirectory 'ApprovedPackages.Common.ps1')
. (Join-Path $toolsDirectory 'Manage-ApprovedPackage.ps1')
. (Join-Path $toolsDirectory 'Install-Packages.ps1')

$script:TestRequiredKeys = @('ErrorPrefix', 'TestStart', 'TestSummary', 'TestFatal')
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:CreatedRoots = @()
$script:FakePythonPath = $null
$realPaths = Get-ApprovedPackagesPaths
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$jaAnyVersionNote = [regex]::Unescape('\u8a31\u53ef\u30d0\u30fc\u30b8\u30e7\u30f3\u306e\u6307\u5b9a\u306a\u3057')
$expectedOrder = @('pdfplumber', 'playwright', 'pyinstaller', 'pypdf', 'pyperclip', 'pytest', 'python-pptx', 'pywin32')
$script:OriginalMessageKeys = @(
    'ErrorPrefix', 'ErrReadFileNotFound', 'ErrReadInvalidUtf8', 'ErrReadInvalidJson', 'ProblemRootNotObject',
    'ProblemSchemaVersionMissing', 'ProblemSchemaVersionUnsupported', 'ProblemPackagesNotArray', 'ProblemUnknownField',
    'ProblemPackageNotObject', 'ProblemFieldMissing', 'ProblemFieldNotString', 'ProblemNameInvalid', 'ProblemNameDuplicate',
    'ProblemNameDuplicateNormalized', 'ProblemAllowedVersionsNotArray', 'ProblemAllowedVersionInvalid',
    'ProblemAllowedVersionDuplicate', 'ProblemStatusInvalid', 'ProblemApprovedDateInvalid', 'ProblemApprovedDateMustBeEmpty',
    'UpdUsage', 'UpdErrTestModeOnly', 'UpdErrTestRootRequired', 'UpdErrTestRootInvalid', 'UpdGenerated', 'UpdUnchanged',
    'MdNotice', 'MdTitle', 'MdHeaderName', 'MdHeaderVersions', 'MdHeaderStatus', 'MdHeaderApprovedDate', 'MdHeaderPurpose',
    'MdHeaderNotes', 'MdNoVersions', 'MgrUsage', 'MgrErrTestModeOnly', 'MgrErrTestRootRequired', 'MgrErrTestRootInvalid',
    'MgrErrActionRequired', 'MgrErrTodayInvalid', 'MgrMenuItems', 'MgrPromptMenu', 'MgrMenuInvalid', 'MgrPromptName',
    'MgrPromptNameOptional', 'MgrPromptVersions', 'MgrPromptPurpose', 'MgrPromptNotes', 'MgrPromptStatus', 'MgrPromptVersion',
    'MgrPromptRemoveVersion', 'MgrPromptValue', 'MgrErrNameRequired', 'MgrErrNameFormat', 'MgrErrNameDuplicate',
    'MgrErrNameNotFound', 'MgrErrStatusInvalid', 'MgrErrVersionInvalid', 'MgrErrVersionDuplicate', 'MgrErrVersionNotFound',
    'MgrErrControlChar', 'MgrWarnAnyVersion', 'MgrPlanHeader', 'MgrPlanNew', 'MgrPlanChange', 'MgrFieldName',
    'MgrFieldVersions', 'MgrFieldPurpose', 'MgrFieldStatus', 'MgrFieldApprovedDate', 'MgrFieldNotes', 'MgrEmptyValue',
    'MgrNoVersions', 'MgrPromptConfirm', 'MgrCancelled', 'MgrNothingToChange', 'MgrSaved', 'MgrDocFailed', 'MgrShowHeader',
    'MgrShowRow', 'MgrNoPackages', 'MgrDetailTitle', 'MgrCurrentVersions', 'TestStart', 'TestSummary', 'TestFatal'
)
$expectedVersions = [ordered]@{
    'pdfplumber'  = @('0.10.3')
    'playwright'  = @()
    'pyinstaller' = @('6.*.*')
    'pypdf'       = @('6.8.0')
    'pyperclip'   = @('1.*')
    'pytest'      = @('8.*.*')
    'python-pptx' = @('1.*.*')
    'pywin32'     = @('312')
}

# ---------------------------------------------------------------------------
# Framework
# ---------------------------------------------------------------------------

function Write-ResultLine {
    param([string]$Status, [string]$GroupName, [string]$CheckName, [string]$Detail)

    $line = '[{0}] {1}: {2}' -f $Status, $GroupName, $CheckName
    if ($Detail -ne '') { $line += '  -- ' + $Detail }
    $color = 'Green'
    if ($Status -eq 'Fail') { $color = 'Red' } elseif ($Status -eq 'NotReady') { $color = 'Yellow' }
    Write-Host $line -ForegroundColor $color
}

function Invoke-Check {
    param([string]$GroupName, [string]$CheckName, [scriptblock]$Body)

    $status = 'Pass'
    $detail = ''
    try {
        & $Body | Out-Null
    } catch {
        $status = 'Fail'
        $detail = $_.Exception.Message
    }
    $script:Results.Add([pscustomobject]@{ Group = $GroupName; Name = $CheckName; Status = $status; Detail = $detail })
    Write-ResultLine -Status $status -GroupName $GroupName -CheckName $CheckName -Detail $detail
}

function Add-NotReady {
    param([string]$GroupName, [string]$CheckName, [string]$Reason)

    $script:Results.Add([pscustomobject]@{ Group = $GroupName; Name = $CheckName; Status = 'NotReady'; Detail = $Reason })
    Write-ResultLine -Status 'NotReady' -GroupName $GroupName -CheckName $CheckName -Detail $Reason
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Message)

    $threw = $false
    try { & $Body | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

function Get-Sha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'MISSING' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-FileFacts {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    return [pscustomobject]@{
        Length   = $bytes.Length
        HasBom   = $hasBom
        Text     = $text
        Crlf     = [regex]::Matches($text, "`r`n").Count
        BareLf   = [regex]::Matches($text, "(?<!`r)`n").Count
        BareCr   = [regex]::Matches($text, "`r(?!`n)").Count
        NonAscii = @($bytes | Where-Object { $_ -ge 0x80 }).Count
    }
}

# ---------------------------------------------------------------------------
# Temporary data roots and child processes
# ---------------------------------------------------------------------------

function New-DataRoot {
    param([switch]$CopyRealData)

    $guid = [guid]::NewGuid().ToString('N')
    $root = Join-Path $tempBase ('approved-packages-test-' + $guid)
    if (Test-Path -LiteralPath $root) { throw "Test folder already exists: $root" }
    [void](New-Item -ItemType Directory -Path $root -ErrorAction Stop)
    [System.IO.File]::WriteAllText((Join-Path $root $script:ApprovedPackagesTestMarkerName), $guid, (New-Object System.Text.ASCIIEncoding))
    if ($CopyRealData.IsPresent) {
        Copy-Item -LiteralPath $realPaths.JsonPath -Destination (Join-Path $root 'approved-packages.json')
    }
    $entry = [pscustomobject]@{ Path = $root; Guid = $guid }
    $script:CreatedRoots += $entry
    return $entry
}

function Remove-DataRoot {
    param([object]$Entry)

    $root = [System.IO.Path]::GetFullPath($Entry.Path).TrimEnd('\')
    if ((Split-Path -Parent $root) -ine $tempBase) { throw "Refusing to delete (not directly under TEMP): $root" }
    if ((Split-Path -Leaf $root) -cnotmatch '^approved-packages-test-[0-9a-f]{32}$') { throw "Refusing to delete (unexpected name): $root" }
    $marker = Join-Path $root $script:ApprovedPackagesTestMarkerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Refusing to delete (marker missing): $root" }
    if ([System.IO.File]::ReadAllText($marker).Trim() -ne $Entry.Guid) { throw "Refusing to delete (marker mismatch): $root" }
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Refusing to delete (reparse point): $root" }
    foreach ($link in @(Get-ChildItem -LiteralPath (Join-Path $root 'Projects') -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })) {
        & cmd.exe /c ('rmdir "' + $link.FullName + '"') | Out-Null
    }
    [System.IO.Directory]::Delete($root, $true)
    $script:CreatedRoots = @($script:CreatedRoots | Where-Object { $_.Path -ne $Entry.Path })
}

function Invoke-ToolProcess {
    param(
        [string]$ScriptName,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$InputText,
        [hashtable]$Environment
    )

    $quoted = @($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powerShellExe
    $psi.Arguments = '-NoProfile -File "' + (Join-Path $toolsDirectory $ScriptName) + '" ' + $quoted
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
    }
    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not [string]::IsNullOrEmpty($InputText)) { $process.StandardInput.Write($InputText) }
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill() } catch { }
        throw ($ScriptName + ' timed out.')
    }
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ([string]$stdoutTask.Result + [string]$stderrTask.Result) }
}

function Invoke-Manage {
    param([object]$Root, [string[]]$Arguments)

    return (Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments (@('-TestMode', '-DataDirectory', $Root.Path) + $Arguments))
}

function Read-DataRootPackages {
    param([object]$Root)

    $read = Read-ApprovedPackageList -Path (Join-Path $Root.Path 'approved-packages.json')
    if (-not $read.Success) { throw 'The test data could not be read.' }
    return @($read.Data.packages)
}

function New-TestList {
    param([object[]]$Specs)

    return @($Specs | ForEach-Object {
            New-ApprovedPackage -Name $_.Name -AllowedVersions @($_.Versions) -Purpose '' -Status $_.Status -ApprovedDate $_.Date -Notes ''
        })
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

$realBefore = @{
    Json = Get-Sha256 -Path $realPaths.JsonPath
    Md   = Get-Sha256 -Path $realPaths.MarkdownPath
}
$toolMessages = $null
try {
    $toolMessages = Import-ToolMessages -Path $realPaths.MessagesPath -RequiredKeys $script:TestRequiredKeys
    $script:MgrMessages = Import-ToolMessages -Path $realPaths.MessagesPath -RequiredKeys $script:ManageRequiredKeys
    $script:InstMessages = Import-ToolMessages -Path $realPaths.MessagesPath -RequiredKeys $script:InstallRequiredKeys
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
Write-Host (Get-ToolMessage -Messages $toolMessages -Key 'TestStart')
$realRead = Read-ApprovedPackageList -Path $realPaths.JsonPath

# ---------------------------------------------------------------------------
# Group: Data (initial approved list)
# ---------------------------------------------------------------------------

function Invoke-DataGroup {
    $g = 'Data'
    Invoke-Check $g 'approved-packages.json loads; schemaVersion is 1; packages is an array' {
        Assert-True $realRead.Success 'The real list could not be read.'
        Assert-True ($realRead.Data.schemaVersion -eq 1) 'schemaVersion must be 1.'
        Assert-True ($realRead.Data.packages -is [System.Array]) 'packages must be an array.'
    }
    Invoke-Check $g 'List passes full validation (fields, statuses, arrays, names, dates)' {
        $problems = @(Test-ApprovedPackageList -Data $realRead.Data)
        Assert-True ($problems.Count -eq 0) ('Problems: ' + (($problems | ForEach-Object { $_.Code + ':' + $_.Package }) -join ', '))
    }
    Invoke-Check $g 'Exactly the eight initial packages are registered, with no normalized duplicates' {
        $names = @($realRead.Data.packages | ForEach-Object { $_.name })
        Assert-True ($names.Count -eq 8) ('Expected 8 packages but found ' + $names.Count)
        foreach ($expected in $expectedOrder) { Assert-True ($names -ccontains $expected) ('Missing: ' + $expected) }
        $normalized = @($names | ForEach-Object { ConvertTo-NormalizedPackageName -Name $_ })
        Assert-True (@($normalized | Select-Object -Unique).Count -eq 8) 'Normalized names are not unique.'
    }
    Invoke-Check $g 'Allowed versions match the approved initial data exactly' {
        foreach ($name in $expectedVersions.Keys) {
            $package = Find-ApprovedPackage -Packages @($realRead.Data.packages) -Name $name
            $actual = @($package.allowedVersions)
            $expected = @($expectedVersions[$name])
            Assert-True ((($actual -join '|') -ceq ($expected -join '|')) -and $actual.Count -eq $expected.Count) ($name + ' has unexpected allowed versions: ' + ($actual -join ','))
        }
    }
    Invoke-Check $g 'All packages are approved with the same valid approvedDate; purpose is empty' {
        $dates = @($realRead.Data.packages | ForEach-Object { $_.approvedDate } | Select-Object -Unique)
        Assert-True ($dates.Count -eq 1 -and (Test-ApprovedDateText -Text $dates[0])) 'approvedDate must be one valid date.'
        foreach ($package in @($realRead.Data.packages)) {
            Assert-True ($package.status -ceq 'approved') ($package.name + ' is not approved.')
            Assert-True ($package.purpose -ceq '') ($package.name + ' purpose must be empty.')
        }
    }
    Invoke-Check $g 'notes: only playwright has a note; all others are empty' {
        foreach ($package in @($realRead.Data.packages)) {
            if ($package.name -ceq 'playwright') {
                Assert-True ($package.notes -ceq $jaAnyVersionNote) 'The playwright note is wrong or its Japanese text was corrupted.'
            } else {
                Assert-True ($package.notes -ceq '') ($package.name + ' notes must be empty.')
            }
        }
    }
    Invoke-Check $g 'Stored order is ascending by normalized name and matches the expected order' {
        $actual = @($realRead.Data.packages | ForEach-Object { $_.name })
        Assert-True (($actual -join '|') -ceq ($expectedOrder -join '|')) ('Order: ' + ($actual -join ', '))
        Assert-True (Test-ApprovedPackageOrder -Packages @($realRead.Data.packages)) 'Test-ApprovedPackageOrder returned false.'
    }
    Invoke-Check $g 'approved-packages.json: UTF-8 without BOM, CRLF only, Japanese intact, canonical form' {
        $facts = Get-FileFacts -Path $realPaths.JsonPath
        Assert-True (-not $facts.HasBom) 'BOM found.'
        Assert-True ($facts.BareLf -eq 0 -and $facts.BareCr -eq 0 -and $facts.Crlf -gt 0) 'CRLF only is required.'
        Assert-True (@(Test-ApprovedPackageFileFormat -Path $realPaths.JsonPath).Count -eq 0) 'File format problems found.'
        Assert-True ($facts.Text.Contains($jaAnyVersionNote)) 'The Japanese note is missing from the file text.'
        Assert-True ((ConvertTo-ApprovedPackagesJsonText -Packages @($realRead.Data.packages)) -ceq $facts.Text) 'The file is not in canonical serializer form.'
    }
    Invoke-Check $g 'Wildcard expressions are stored as entered (8.*.* is not shortened)' {
        Assert-True ((@((Find-ApprovedPackage -Packages @($realRead.Data.packages) -Name 'pytest').allowedVersions) -join '') -ceq '8.*.*') 'pytest'
        Assert-True ((@((Find-ApprovedPackage -Packages @($realRead.Data.packages) -Name 'pyperclip').allowedVersions) -join '') -ceq '1.*') 'pyperclip'
        Assert-True ((@((Find-ApprovedPackage -Packages @($realRead.Data.packages) -Name 'python-pptx').allowedVersions) -join '') -ceq '1.*.*') 'python-pptx'
    }
}

# ---------------------------------------------------------------------------
# Group: Names
# ---------------------------------------------------------------------------

function Invoke-NamesGroup {
    $g = 'Names'
    Invoke-Check $g 'types-openpyxl, types_openpyxl, Types-OpenPyXL, and types.openpyxl normalize to the same name' {
        $values = @('types-openpyxl', 'types_openpyxl', 'Types-OpenPyXL', 'types.openpyxl')
        $normalized = @($values | ForEach-Object { ConvertTo-NormalizedPackageName -Name $_ } | Select-Object -Unique)
        Assert-True ($normalized.Count -eq 1 -and $normalized[0] -ceq 'types-openpyxl') ('Normalized: ' + ($normalized -join ','))
    }
    Invoke-Check $g 'Runs of separators collapse and the original spelling is never changed' {
        Assert-True ((ConvertTo-NormalizedPackageName -Name 'A__b-.c') -ceq 'a-b-c') 'Separator runs.'
        $package = New-ApprovedPackage -Name 'Types_OpenPyXL' -AllowedVersions @() -Purpose '' -Status 'pending' -ApprovedDate '' -Notes ''
        Assert-True ($package.name -ceq 'Types_OpenPyXL') 'The stored name changed.'
    }
    Invoke-Check $g 'Name format validation' {
        foreach ($good in @('a', 'ab', 'a1', 'a-b', 'a_b', 'a.b', 'python-pptx', 'Types-OpenPyXL')) { Assert-True (Test-PackageNameFormat -Name $good) ('Rejected: ' + $good) }
        foreach ($bad in @('', '-a', 'a-', '_a', 'a_', '.a', 'a b', 'a/b', 'a[b]', 'a=b')) { Assert-True (-not (Test-PackageNameFormat -Name $bad)) ('Accepted: [' + $bad + ']') }
    }
    Invoke-Check $g 'Lookup is by normalized name; unregistered is distinct' {
        $list = @($realRead.Data.packages)
        Assert-True ($null -ne (Find-ApprovedPackage -Packages $list -Name 'Python_PPTX')) 'python-pptx must be found by a normalized name.'
        Assert-True ($null -eq (Find-ApprovedPackage -Packages $list -Name 'not-registered')) 'An unregistered package must return null.'
    }
}

# ---------------------------------------------------------------------------
# Group: Versions
# ---------------------------------------------------------------------------

function Invoke-VersionsGroup {
    $g = 'Versions'
    $listVersions = @{}
    foreach ($package in @($realRead.Data.packages)) { $listVersions[$package.name] = @($package.allowedVersions) }
    $matrix = @(
        @('pytest', '8.0.0', $true), @('pytest', '8.3.5', $true), @('pytest', '9.0.0', $false),
        @('python-pptx', '1.0.0', $true), @('python-pptx', '2.0.0', $false),
        @('pyinstaller', '6.0.0', $true), @('pyinstaller', '7.0.0', $false),
        @('pyperclip', '1.9', $true), @('pyperclip', '2.0', $false),
        @('pdfplumber', '0.10.3', $true), @('pdfplumber', '0.10.4', $false),
        @('pywin32', '312', $true), @('pywin32', '313', $false)
    )
    foreach ($row in $matrix) {
        $expectedText = 'match'
        if (-not $row[2]) { $expectedText = 'no match' }
        $rowName = $row[0]
        $rowVersion = $row[1]
        $rowExpected = $row[2]
        Invoke-Check $g ("{0} {1}: {2}" -f $rowName, $rowVersion, $expectedText) {
            $actual = Test-VersionAllowedByList -AllowedVersions $listVersions[$rowName] -Version $rowVersion
            Assert-True ($actual -eq $rowExpected) ('Expected ' + $rowExpected + ' but got ' + $actual)
        }
    }
    Invoke-Check $g '8.* and 8.*.* are the same major-version constraint; 8 matches both' {
        foreach ($version in @('8', '8.0', '8.3.5', '9.0', '7.9.9', '80.1')) {
            $a = Test-VersionMatchesPattern -Version $version -Pattern '8.*'
            $b = Test-VersionMatchesPattern -Version $version -Pattern '8.*.*'
            Assert-True ($a -eq $b) ('Different results for ' + $version)
        }
        Assert-True (Test-VersionMatchesPattern -Version '8' -Pattern '8.*.*') '8 must match 8.*.*'
        Assert-True (-not (Test-VersionMatchesPattern -Version '80.1' -Pattern '8.*')) '80.1 must not match 8.*'
    }
    Invoke-Check $g 'A multi-element prefix is honored (1.2.*)' {
        Assert-True (Test-VersionMatchesPattern -Version '1.2.5' -Pattern '1.2.*') '1.2.5'
        Assert-True (Test-VersionMatchesPattern -Version '1.2' -Pattern '1.2.*') '1.2'
        Assert-True (-not (Test-VersionMatchesPattern -Version '1.3.0' -Pattern '1.2.*')) '1.3.0'
        Assert-True (-not (Test-VersionMatchesPattern -Version '1' -Pattern '1.2.*')) '1'
    }
    Invoke-Check $g 'Trailing zeros are equivalent for comparison only (312 = 312.0 = 312.0.0; 1 = 1.0 = 1.0.0)' {
        foreach ($pair in @(@('312', '312.0'), @('312', '312.0.0'), @('312.0', '312.0.0'), @('1', '1.0'), @('1', '1.0.0'), @('1.0', '1.0.0'))) {
            Assert-True (Test-VersionsEqual -Left $pair[0] -Right $pair[1]) ($pair[0] + ' vs ' + $pair[1])
            Assert-True (Test-VersionMatchesPattern -Version $pair[0] -Pattern $pair[1]) ('pattern ' + $pair[0] + ' vs ' + $pair[1])
        }
        Assert-True (-not (Test-VersionsEqual -Left '312' -Right '312.1')) '312 vs 312.1'
        Assert-True (-not (Test-VersionsEqual -Left '1.0.1' -Right '1')) '1.0.1 vs 1'
        Assert-True (Test-VersionsEqual -Left '01.0' -Right '1') 'Leading zeros of elements are ignored.'
    }
    Invoke-Check $g 'A stored allowed version keeps its text (312 is not written back as 312.0)' {
        $root = New-DataRoot
        try {
            $package = New-ApprovedPackage -Name 'sample' -AllowedVersions @('312', '8.*.*') -Purpose '' -Status 'approved' -ApprovedDate '2026-01-02' -Notes ''
            $path = Join-Path $root.Path 'approved-packages.json'
            Write-ApprovedPackageList -Path $path -Packages @($package)
            $read = Read-ApprovedPackageList -Path $path
            Assert-True ((@($read.Data.packages[0].allowedVersions) -join '|') -ceq '312|8.*.*') 'The stored text changed.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Unsupported version text (rc, dev, post, +local, wildcard) is never converted; it stops' {
        foreach ($bad in @('1.0rc1', '1.0.dev1', '1.0.post1', '1.0+local', '1.0a1', '1.0b2', '2!1.0', '1.0-1', '1.*', '*')) {
            Assert-True ($null -ne (Get-ConcreteVersionProblem -Version $bad)) ('Accepted: ' + $bad)
            Assert-True (-not (Test-VersionMatchesPattern -Version $bad -Pattern '1.*')) ('Matched: ' + $bad)
        }
        Assert-True ((Get-ConcreteVersionProblem -Version '1.0rc1') -ceq 'Unsupported') 'rc must be Unsupported.'
        Assert-True ((Get-ConcreteVersionProblem -Version '1.*') -ceq 'Wildcard') 'A wildcard version is a Wildcard problem.'
        foreach ($good in @('312', '0.10.3', '6.8.0', '8.3.5', '1.9')) { Assert-True ($null -eq (Get-ConcreteVersionProblem -Version $good)) ('Rejected: ' + $good) }
    }
    Invoke-Check $g 'Allowed-version expressions: invalid patterns are rejected' {
        foreach ($bad in @('*', '8*', '8.*.x', '8..*', '.*.*', '1.*.2', 'abc', '>=8', '', ' 8.*', '8.* ', '8.*.*.', '8.', '.8', '8.*x')) {
            Assert-True (-not (Test-AllowedVersionPattern -Pattern $bad)) ('Accepted: [' + $bad + ']')
        }
    }
    Invoke-Check $g 'Allowed-version expressions: 312, 0.10.3, 8.*, 8.*.*, 1.2.* are accepted' {
        foreach ($good in @('312', '0.10.3', '8.*', '8.*.*', '1.2.*', '6.8.0')) {
            Assert-True (Test-AllowedVersionPattern -Pattern $good) ('Rejected: ' + $good)
        }
    }
}

# ---------------------------------------------------------------------------
# Group: Decisions (any-version, statuses, whole-stop)
# ---------------------------------------------------------------------------

function Invoke-DecisionsGroup {
    $g = 'Decisions'
    $list = @($realRead.Data.packages)
    Invoke-Check $g 'allowedVersions [] (playwright): recognized, any version allowed, warning, distinct from unregistered' {
        $package = Find-ApprovedPackage -Packages $list -Name 'playwright'
        $decision = Get-PackageInstallDecision -Package $package -RequestedVersion $null
        Assert-True ($decision.Allowed -and $decision.Code -ceq 'AllowedAnyVersion' -and $decision.Warning -ceq 'AnyVersion') 'Any-version decision.'
        $withVersion = Get-PackageInstallDecision -Package $package -RequestedVersion '1.58.0'
        Assert-True ($withVersion.Allowed -and $withVersion.Warning -ceq 'AnyVersion') 'Any-version with a requested version.'
        $unregistered = Get-PackageInstallDecision -Package $null -RequestedVersion $null
        Assert-True ((-not $unregistered.Allowed) -and $unregistered.Code -ceq 'NotRegistered') 'Unregistered must stop.'
        Assert-True ($decision.Code -cne $unregistered.Code) 'Registered and unregistered must differ.'
    }
    Invoke-Check $g 'Version-less requirement with a fixed or wildcard list reports a required choice (decided in the install step)' {
        $fixed = Get-PackageInstallDecision -Package (Find-ApprovedPackage -Packages $list -Name 'pypdf') -RequestedVersion $null
        Assert-True ($fixed.Allowed -and $fixed.RequiresVersionChoice -and $fixed.FixedVersion -ceq '6.8.0') 'pypdf'
        $wild = Get-PackageInstallDecision -Package (Find-ApprovedPackage -Packages $list -Name 'pytest') -RequestedVersion $null
        Assert-True ($wild.Allowed -and $wild.RequiresVersionChoice -and $wild.FixedVersion -ceq '') 'pytest'
    }
    Invoke-Check $g 'Requested versions: match, mismatch, and unsupported format' {
        $pytest = Find-ApprovedPackage -Packages $list -Name 'pytest'
        Assert-True ((Get-PackageInstallDecision -Package $pytest -RequestedVersion '8.3.5').Code -ceq 'AllowedVersionMatches') '8.3.5'
        $no = Get-PackageInstallDecision -Package $pytest -RequestedVersion '9.0.0'
        Assert-True ((-not $no.Allowed) -and $no.Code -ceq 'VersionNotAllowed') '9.0.0'
        $bad = Get-PackageInstallDecision -Package $pytest -RequestedVersion '8.3.5rc1'
        Assert-True ((-not $bad.Allowed) -and $bad.Code -ceq 'VersionUnsupportedFormat') '8.3.5rc1'
    }
    Invoke-Check $g 'Only approved is installable; pending, deprecated, and disabled stop' {
        $statuses = @{ approved = $true; pending = $false; deprecated = $false; disabled = $false }
        foreach ($status in $statuses.Keys) {
            $date = ''
            if ($status -ceq 'approved') { $date = '2026-01-02' }
            $package = New-ApprovedPackage -Name 'x' -AllowedVersions @('1.*') -Purpose '' -Status $status -ApprovedDate $date -Notes ''
            $decision = Get-PackageInstallDecision -Package $package -RequestedVersion '1.0'
            Assert-True ($decision.Allowed -eq $statuses[$status]) ($status + ' returned ' + $decision.Allowed)
        }
        $codes = @{ pending = 'StatusPending'; deprecated = 'StatusDeprecated'; disabled = 'StatusDisabled' }
        foreach ($status in $codes.Keys) {
            $package = New-ApprovedPackage -Name 'x' -AllowedVersions @('1.*') -Purpose '' -Status $status -ApprovedDate '' -Notes ''
            Assert-True ((Get-PackageInstallDecision -Package $package -RequestedVersion '1.0').Code -ceq $codes[$status]) ($status + ' code')
        }
    }
    Invoke-Check $g 'One blocked package stops the whole set (no partial installation)' {
        $specs = @(
            @{ Name = 'good'; Versions = @('1.*'); Status = 'approved'; Date = '2026-01-02' },
            @{ Name = 'wait'; Versions = @('1.*'); Status = 'pending'; Date = '' },
            @{ Name = 'old'; Versions = @('1.*'); Status = 'deprecated'; Date = '' },
            @{ Name = 'off'; Versions = @('1.*'); Status = 'disabled'; Date = '' }
        )
        $packages = New-TestList -Specs $specs
        $ok = ConvertFrom-RequirementsText -Text "good==1.2`r`n"
        Assert-True ((Get-RequirementsDecisions -Packages $packages -Entries $ok.Entries).AllAllowed) 'A fully approved set must pass.'
        foreach ($blockedName in @('wait', 'old', 'off', 'unknown')) {
            $text = "good==1.2`r`n" + $blockedName + "`r`n"
            $parsed = ConvertFrom-RequirementsText -Text $text
            $result = Get-RequirementsDecisions -Packages $packages -Entries $parsed.Entries
            Assert-True (-not $result.AllAllowed) ($blockedName + ' must stop the whole set.')
        }
        $mismatch = ConvertFrom-RequirementsText -Text "good==2.0`r`n"
        Assert-True (-not (Get-RequirementsDecisions -Packages $packages -Entries $mismatch.Entries).AllAllowed) 'A version mismatch must stop the set.'
    }
}

# ---------------------------------------------------------------------------
# Group: Requirements
# ---------------------------------------------------------------------------

function Invoke-RequirementsGroup {
    $g = 'Requirements'
    Invoke-Check $g 'package and package==1.2.3 are parsed; comments and blank lines are ignored; line numbers are kept' {
        $text = "# comment`r`n`r`nopenpyxl`r`n  pytest==8.3.5  `r`n   # indented comment`r`n`r`nTypes_X==1.0`r`n"
        $result = ConvertFrom-RequirementsText -Text $text
        Assert-True (@($result.Problems).Count -eq 0) 'Unexpected problems.'
        $entries = @($result.Entries)
        Assert-True ($entries.Count -eq 3) ('Expected 3 entries but got ' + $entries.Count)
        Assert-True ($entries[0].Name -ceq 'openpyxl' -and $null -eq $entries[0].Version -and $entries[0].LineNumber -eq 3) 'Entry 1'
        Assert-True ($entries[1].Name -ceq 'pytest' -and $entries[1].Version -ceq '8.3.5' -and $entries[1].LineNumber -eq 4) 'Entry 2'
        Assert-True ($entries[2].Name -ceq 'Types_X' -and $entries[2].Version -ceq '1.0' -and $entries[2].LineNumber -eq 7) 'Entry 3 (original spelling kept)'
    }
    Invoke-Check $g 'An empty or comment-only file is valid' {
        foreach ($text in @('', "`r`n", "# only a comment`r`n", "`n`n# x`n")) {
            $result = ConvertFrom-RequirementsText -Text $text
            Assert-True (@($result.Entries).Count -eq 0 -and @($result.Problems).Count -eq 0) ('Not empty for: [' + $text + ']')
        }
    }
    $unsupported = @(
        @('pytest>=8', 'Operator'), @('pytest<9', 'Operator'), @('pytest>=8,<9', 'Operator'), @('pytest~=8.0', 'Operator'),
        @('pytest!=8.0', 'Operator'), @('pytest===8.0', 'Operator'), @('pytest<=8.0', 'Operator'), @('pytest>8', 'Operator'),
        @('requests[security]', 'Extras'), @('-e .', 'Option'), @('-r other.txt', 'Option'), @('--index-url https://x', 'Option'),
        @('git+https://github.com/a/b.git', 'Url'), @('https://example.com/p.whl', 'Url'), @('pkg @ https://example.com/p.whl', 'Url'),
        @('./local', 'LocalPath'), @('..\pkg', 'LocalPath'), @('C:\x\y', 'LocalPath'), @('sub/pkg', 'LocalPath'), @('~/pkg', 'LocalPath'),
        @('pytest==8.*.*', 'Wildcard'), @('pytest==8.*', 'Wildcard'), @('pytest==1.0rc1', 'UnsupportedVersion'),
        @('pytest==1.0.post1', 'UnsupportedVersion'), @('pytest==1.0+local', 'UnsupportedVersion'), @('pytest==', 'EmptyVersion'),
        @('pytest == 1.0', 'Format'), @('pytest==1.0 # c', 'InlineComment'), @('pkg;python_version<"3.9"', 'Marker'),
        @('pytest=8', 'Format'), @('pytest==1..0', 'Format')
    )
    foreach ($case in $unsupported) {
        $line = $case[0]
        $code = $case[1]
        Invoke-Check $g ("Unsupported syntax stops: [{0}] -> {1}" -f $line, $code) {
            $result = ConvertFrom-RequirementsText -Text ($line + "`r`n")
            Assert-True (@($result.Entries).Count -eq 0) 'It must not produce an entry.'
            Assert-True (@($result.Problems).Count -eq 1 -and $result.Problems[0].Code -ceq $code) ('Got: ' + (@($result.Problems | ForEach-Object { $_.Code }) -join ','))
            Assert-True ($result.Problems[0].LineNumber -eq 1) 'The line number is wrong.'
        }
    }
    Invoke-Check $g 'Duplicate packages (after normalization) are reported once, with the later line' {
        $result = ConvertFrom-RequirementsText -Text "Types_X`r`ntypes-x==1.0`r`n"
        Assert-True (@($result.Entries).Count -eq 1) 'One entry expected.'
        Assert-True (@($result.Problems).Count -eq 1 -and $result.Problems[0].Code -ceq 'Duplicate' -and $result.Problems[0].LineNumber -eq 2) 'Duplicate problem.'
    }
    Invoke-Check $g 'A problem in one line does not hide others' {
        $result = ConvertFrom-RequirementsText -Text "pytest>=8`r`nopenpyxl`r`n-e .`r`n"
        Assert-True (@($result.Problems).Count -eq 2 -and @($result.Entries).Count -eq 1) 'Problems and entries.'
    }
    Invoke-Check $g 'Read-RequirementsFile: missing file, invalid UTF-8, and a normal file' {
        $root = New-DataRoot
        try {
            $missing = Read-RequirementsFile -Path (Join-Path $root.Path 'none.txt')
            Assert-True ($missing.ReadErrorCode -ceq 'FileNotFound') 'FileNotFound'
            $bad = Join-Path $root.Path 'bad.txt'
            [System.IO.File]::WriteAllBytes($bad, [byte[]](0x70, 0xFF, 0xFE, 0x0D, 0x0A))
            Assert-True ((Read-RequirementsFile -Path $bad).ReadErrorCode -ceq 'InvalidUtf8') 'InvalidUtf8'
            $good = Join-Path $root.Path 'good.txt'
            [System.IO.File]::WriteAllText($good, "pytest==8.3.5`r`n", (New-Object System.Text.UTF8Encoding($false)))
            $read = Read-RequirementsFile -Path $good
            Assert-True ($null -eq $read.ReadErrorCode -and @($read.Entries).Count -eq 1) 'Normal file'
        } finally { Remove-DataRoot -Entry $root }
    }
}

# ---------------------------------------------------------------------------
# Group: Validation (list schema) and Write/Markdown
# ---------------------------------------------------------------------------

function Invoke-ValidationGroup {
    $g = 'Validation'
    function New-DataObject { param([object[]]$Packages) return [pscustomobject]@{ schemaVersion = 1; packages = @($Packages) } }
    function New-RawPackage {
        param([hashtable]$Overrides)
        $base = [ordered]@{ name = 'a'; allowedVersions = @('1.*'); purpose = ''; status = 'approved'; approvedDate = '2026-01-02'; notes = '' }
        foreach ($key in $Overrides.Keys) { $base[$key] = $Overrides[$key] }
        return [pscustomobject]$base
    }
    function Get-Codes { param([object]$Data) return @(@(Test-ApprovedPackageList -Data $Data) | ForEach-Object { $_.Code }) }

    Invoke-Check $g 'A valid minimal list passes; an empty packages array passes' {
        Assert-True (@(Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{})))).Count -eq 0) 'valid'
        Assert-True (@(Get-Codes -Data (New-DataObject -Packages @())).Count -eq 0) 'empty'
    }
    Invoke-Check $g 'Schema errors: root, schemaVersion, packages' {
        Assert-True ((Get-Codes -Data $null) -contains 'RootNotObject') 'null root'
        Assert-True ((Get-Codes -Data ([pscustomobject]@{ packages = @() })) -contains 'SchemaVersionMissing') 'missing schemaVersion'
        Assert-True ((Get-Codes -Data ([pscustomobject]@{ schemaVersion = 2; packages = @() })) -contains 'SchemaVersionUnsupported') 'schemaVersion 2'
        Assert-True ((Get-Codes -Data ([pscustomobject]@{ schemaVersion = '1'; packages = @() })) -contains 'SchemaVersionUnsupported') 'schemaVersion as text'
        Assert-True ((Get-Codes -Data ([pscustomobject]@{ schemaVersion = 1 })) -contains 'PackagesNotArray') 'missing packages'
        Assert-True ((Get-Codes -Data ([pscustomobject]@{ schemaVersion = 1; packages = 'x' })) -contains 'PackagesNotArray') 'packages as text'
        Assert-True ((Get-Codes -Data ([pscustomobject]@{ schemaVersion = 1; packages = @(); extra = 1 })) -contains 'UnknownField') 'unknown top-level field'
    }
    Invoke-Check $g 'Package errors: missing and unknown fields, types, names, statuses, dates, versions' {
        $missing = [pscustomobject][ordered]@{ name = 'a'; allowedVersions = @(); purpose = ''; status = 'approved'; approvedDate = '2026-01-02' }
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @($missing))) -contains 'FieldMissing') 'missing notes'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ category = 'x' })))) -contains 'UnknownField') 'unknown field'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ purpose = 5 })))) -contains 'FieldNotString') 'purpose as number'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ name = 'a b' })))) -contains 'NameInvalid') 'bad name'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ status = 'Approved' })))) -contains 'StatusInvalid') 'status case'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ status = 'live' })))) -contains 'StatusInvalid') 'unknown status'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ allowedVersions = '1.*' })))) -contains 'AllowedVersionsNotArray') 'versions as text'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ allowedVersions = @('8*') })))) -contains 'AllowedVersionInvalid') 'bad pattern'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ allowedVersions = @('8.*', '8.*') })))) -contains 'AllowedVersionDuplicate') 'duplicate pattern'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @('text'))) -contains 'PackageNotObject') 'package as text'
    }
    Invoke-Check $g 'approvedDate rules: approved needs a real date; other statuses need an empty date' {
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ approvedDate = '' })))) -contains 'ApprovedDateInvalid') 'empty for approved'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ approvedDate = '2026-13-01' })))) -contains 'ApprovedDateInvalid') 'month 13'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ approvedDate = '2026/01/02' })))) -contains 'ApprovedDateInvalid') 'slashes'
        Assert-True ((Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ status = 'pending' })))) -contains 'ApprovedDateMustBeEmpty') 'pending with date'
        Assert-True (@(Get-Codes -Data (New-DataObject -Packages @((New-RawPackage -Overrides @{ status = 'disabled'; approvedDate = '' })))).Count -eq 0) 'disabled without date'
    }
    Invoke-Check $g 'Duplicate names are rejected, including names that are equal only after normalization' {
        $same = New-DataObject -Packages @((New-RawPackage -Overrides @{ name = 'abc' }), (New-RawPackage -Overrides @{ name = 'abc' }))
        Assert-True ((Get-Codes -Data $same) -contains 'NameDuplicate') 'same spelling'
        $normalized = New-DataObject -Packages @((New-RawPackage -Overrides @{ name = 'Types_X' }), (New-RawPackage -Overrides @{ name = 'types-x' }))
        Assert-True ((Get-Codes -Data $normalized) -contains 'NameDuplicateNormalized') 'normalized'
    }
    Invoke-Check $g 'Read-ApprovedPackageList reports missing, invalid UTF-8, and invalid JSON without repairing' {
        $root = New-DataRoot
        try {
            Assert-True ((Read-ApprovedPackageList -Path (Join-Path $root.Path 'none.json')).ErrorCode -ceq 'FileNotFound') 'FileNotFound'
            $badUtf8 = Join-Path $root.Path 'u.json'
            [System.IO.File]::WriteAllBytes($badUtf8, [byte[]](0x7B, 0xFF, 0xFE, 0x7D))
            Assert-True ((Read-ApprovedPackageList -Path $badUtf8).ErrorCode -ceq 'InvalidUtf8') 'InvalidUtf8'
            $badJson = Join-Path $root.Path 'j.json'
            [System.IO.File]::WriteAllText($badJson, '{ "schemaVersion": 1, ', (New-Object System.Text.UTF8Encoding($false)))
            $before = Get-Sha256 -Path $badJson
            Assert-True ((Read-ApprovedPackageList -Path $badJson).ErrorCode -ceq 'InvalidJson') 'InvalidJson'
            Assert-True ((Get-Sha256 -Path $badJson) -ceq $before) 'The file must not be modified.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Hand-edited disorder is detected by Test-ApprovedPackageOrder (not by validation)' {
        $a = New-RawPackage -Overrides @{ name = 'b' }
        $b = New-RawPackage -Overrides @{ name = 'a' }
        Assert-True (-not (Test-ApprovedPackageOrder -Packages @($a, $b))) 'Disorder must be detected.'
        Assert-True (Test-ApprovedPackageOrder -Packages @($b, $a)) 'Order must pass.'
        Assert-True (@(Get-Codes -Data (New-DataObject -Packages @($a, $b))).Count -eq 0) 'Validation must not depend on order.'
    }
}

function Invoke-WriteGroup {
    $g = 'Write'
    Invoke-Check $g 'Write-ApprovedPackageList: sorted, BOM-less, CRLF, Japanese intact, read back, no temp files' {
        $root = New-DataRoot
        try {
            $path = Join-Path $root.Path 'approved-packages.json'
            $packages = @(
                (New-ApprovedPackage -Name 'zeta' -AllowedVersions @() -Purpose ('a' + [char]0x3042 + '"q"\n') -Status 'approved' -ApprovedDate '2026-01-02' -Notes $jaAnyVersionNote),
                (New-ApprovedPackage -Name 'Alpha_pkg' -AllowedVersions @('1.*', '2.0') -Purpose '' -Status 'pending' -ApprovedDate '' -Notes '')
            )
            Write-ApprovedPackageList -Path $path -Packages $packages
            Assert-True (@(Test-ApprovedPackageFileFormat -Path $path).Count -eq 0) 'Format problems.'
            $read = Read-ApprovedPackageList -Path $path
            Assert-True ((@($read.Data.packages | ForEach-Object { $_.name }) -join ',') -ceq 'Alpha_pkg,zeta') 'The list must be sorted by normalized name.'
            Assert-True ($read.Data.packages[1].notes -ceq $jaAnyVersionNote) 'Japanese text was corrupted.'
            Assert-True ($read.Data.packages[1].purpose -ceq ('a' + [char]0x3042 + '"q"\n')) 'Quotes or backslashes were corrupted.'
            $leftovers = @(Get-ChildItem -LiteralPath $root.Path -Force | Where-Object { $_.Name -like '*.tmp' })
            Assert-True ($leftovers.Count -eq 0) 'A temporary file remains.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'An invalid list is not written and the existing file is kept unchanged' {
        $root = New-DataRoot -CopyRealData
        try {
            $path = Join-Path $root.Path 'approved-packages.json'
            $before = Get-Sha256 -Path $path
            $bad = New-ApprovedPackage -Name 'x' -AllowedVersions @('8*') -Purpose '' -Status 'approved' -ApprovedDate '2026-01-02' -Notes ''
            Assert-Throws { Write-ApprovedPackageList -Path $path -Packages @($bad) } 'An invalid list must throw.'
            $badStatus = New-ApprovedPackage -Name 'x' -AllowedVersions @() -Purpose '' -Status 'approved' -ApprovedDate '' -Notes ''
            Assert-Throws { Write-ApprovedPackageList -Path $path -Packages @($badStatus) } 'An invalid date must throw.'
            Assert-True ((Get-Sha256 -Path $path) -ceq $before) 'The existing file changed.'
            Assert-True (@(Get-ChildItem -LiteralPath $root.Path -Force | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) 'A temporary file remains.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'A failing validator keeps the original file and removes the temporary file' {
        $root = New-DataRoot
        try {
            $path = Join-Path $root.Path 'target.txt'
            [System.IO.File]::WriteAllText($path, 'original', (New-Object System.Text.UTF8Encoding($false)))
            Assert-Throws { Write-TextFileSafely -Path $path -Text 'new' -Validator { param($p) throw 'rejected' } } 'The validator failure must propagate.'
            Assert-True ([System.IO.File]::ReadAllText($path) -ceq 'original') 'The original file changed.'
            Assert-True (@(Get-ChildItem -LiteralPath $root.Path -Force | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) 'A temporary file remains.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'JSON text escaping covers quotes, backslashes, control characters, and non-ASCII' {
        $text = 'a"b\c' + [char]9 + [char]10 + [char]13 + [char]8 + [char]12 + [char]1 + [char]0x3042
        $literal = ConvertTo-JsonStringLiteral -Text $text
        Assert-True ($literal -ceq ('"a\"b\\c\t\n\r\b\f\u0001' + [char]0x3042 + '"')) ('Literal: ' + $literal)
        $roundTrip = ('{"v":' + $literal + '}') | ConvertFrom-Json
        Assert-True ($roundTrip.v -ceq $text) 'The literal did not round-trip.'
    }
}

function Invoke-MarkdownGroup {
    $g = 'Markdown'
    $labels = [pscustomobject]@{
        NoticeLines = @($toolMessages.MdNotice); Title = $toolMessages.MdTitle; HeaderName = $toolMessages.MdHeaderName
        HeaderVersions = $toolMessages.MdHeaderVersions; HeaderStatus = $toolMessages.MdHeaderStatus
        HeaderApprovedDate = $toolMessages.MdHeaderApprovedDate; HeaderPurpose = $toolMessages.MdHeaderPurpose
        HeaderNotes = $toolMessages.MdHeaderNotes; NoVersions = $toolMessages.MdNoVersions
    }
    Invoke-Check $g 'The real approved-packages.md equals the Markdown regenerated from the JSON' {
        $expected = ConvertTo-ApprovedPackagesMarkdown -Packages @($realRead.Data.packages) -Labels $labels
        $facts = Get-FileFacts -Path $realPaths.MarkdownPath
        Assert-True ($facts.Text -ceq $expected) 'The Markdown differs from the JSON-derived text.'
        Assert-True (-not $facts.HasBom -and $facts.BareLf -eq 0 -and $facts.BareCr -eq 0 -and $facts.Crlf -gt 0) 'Encoding or line endings.'
    }
    Invoke-Check $g 'Notice, no timestamp, ascending order, and version display rules' {
        $text = (Get-FileFacts -Path $realPaths.MarkdownPath).Text
        $lines = @($text -split "`r`n")
        Assert-True ($lines[0] -ceq ('> ' + @($toolMessages.MdNotice)[0]) -and $lines[1] -ceq ('> ' + @($toolMessages.MdNotice)[1])) 'The direct-edit notice is missing.'
        Assert-True ($text -notmatch '[0-9]{1,2}:[0-9]{2}') 'A time of day was found.'
        $rows = @($lines | Where-Object { $_ -match '^\| [a-z]' -and $_ -notmatch '^\| ---' })
        $rowNames = @($rows | ForEach-Object { ($_ -split ' \| ')[0].Substring(2) })
        Assert-True (($rowNames -join '|') -ceq ($expectedOrder -join '|')) ('Row order: ' + ($rowNames -join ','))
        $playwright = @($rows | Where-Object { $_.StartsWith('| playwright ') })[0]
        Assert-True ($playwright.Contains('| ' + $toolMessages.MdNoVersions + ' |')) 'Empty versions must show the no-version label.'
        Assert-True (@($rows | Where-Object { $_.Contains('`8.*.*`') }).Count -eq 1) 'The wildcard text must be shown as written (in a code span).'
    }
    Invoke-Check $g 'Generation is deterministic and independent of the input order' {
        $packages = @($realRead.Data.packages)
        $reversed = @($packages[($packages.Count - 1)..0])
        $a = ConvertTo-ApprovedPackagesMarkdown -Packages $packages -Labels $labels
        $b = ConvertTo-ApprovedPackagesMarkdown -Packages $reversed -Labels $labels
        $c = ConvertTo-ApprovedPackagesMarkdown -Packages $packages -Labels $labels
        Assert-True ($a -ceq $b -and $a -ceq $c) 'The output differs.'
    }
    Invoke-Check $g 'Cell escaping: pipes and line breaks; multiple versions are comma-separated' {
        $package = New-ApprovedPackage -Name 'x' -AllowedVersions @('1.0', '2.*') -Purpose 'a|b' -Status 'approved' -ApprovedDate '2026-01-02' -Notes ('l1' + [char]10 + 'l2')
        $text = ConvertTo-ApprovedPackagesMarkdown -Packages @($package) -Labels $labels
        Assert-True ($text.Contains('a\|b')) 'The pipe was not escaped.'
        Assert-True ($text.Contains('l1<br>l2')) 'The line break was not converted.'
        Assert-True ($text.Contains('`1.0`, `2.*`')) 'The versions are not comma-separated.'
    }
    Invoke-Check $g 'An empty list produces only the header and table head' {
        $text = ConvertTo-ApprovedPackagesMarkdown -Packages @() -Labels $labels
        $rows = @(($text -split "`r`n") | Where-Object { $_.StartsWith('|') })
        Assert-True ($rows.Count -eq 2) 'Expected the header and separator rows only.'
    }
    Invoke-Check $g 'Update tool (child process): regenerates a missing file, then reports no change (bytes identical)' {
        $root = New-DataRoot -CopyRealData
        try {
            $mdPath = Join-Path $root.Path 'approved-packages.md'
            $first = Invoke-ToolProcess -ScriptName 'Update-ApprovedPackagesDocument.ps1' -Arguments @('-TestMode', '-DataDirectory', $root.Path)
            Assert-True ($first.ExitCode -eq 0) ('Exit code ' + $first.ExitCode + ': ' + $first.Output)
            Assert-True ((Get-Sha256 -Path $mdPath) -ceq (Get-Sha256 -Path $realPaths.MarkdownPath)) 'The generated file differs from the real one.'
            $stamp = (Get-Item -LiteralPath $mdPath).LastWriteTimeUtc
            Start-Sleep -Milliseconds 1100
            $second = Invoke-ToolProcess -ScriptName 'Update-ApprovedPackagesDocument.ps1' -Arguments @('-TestMode', '-DataDirectory', $root.Path)
            Assert-True ($second.ExitCode -eq 0) 'The second run failed.'
            Assert-True ((Get-Item -LiteralPath $mdPath).LastWriteTimeUtc -eq $stamp) 'An unchanged document was rewritten.'
            Assert-True (@(Get-ChildItem -LiteralPath $root.Path -Force | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) 'A temporary file remains.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Update tool: invalid JSON stops with exit code 1 and writes nothing' {
        $root = New-DataRoot
        try {
            [System.IO.File]::WriteAllText((Join-Path $root.Path 'approved-packages.json'), '{ broken', (New-Object System.Text.UTF8Encoding($false)))
            $run = Invoke-ToolProcess -ScriptName 'Update-ApprovedPackagesDocument.ps1' -Arguments @('-TestMode', '-DataDirectory', $root.Path)
            Assert-True ($run.ExitCode -eq 1) ('Exit code ' + $run.ExitCode)
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root.Path 'approved-packages.md'))) 'A document was written.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Update tool: runs from another working directory and rejects test-only arguments without -TestMode' {
        $root = New-DataRoot -CopyRealData
        try {
            $other = Invoke-ToolProcess -ScriptName 'Update-ApprovedPackagesDocument.ps1' -Arguments @('-TestMode', '-DataDirectory', $root.Path) -WorkingDirectory $tempBase
            Assert-True ($other.ExitCode -eq 0) 'It must not depend on the current directory.'
            $json = Get-Sha256 -Path $realPaths.JsonPath
            $md = Get-Sha256 -Path $realPaths.MarkdownPath
            $rejected = Invoke-ToolProcess -ScriptName 'Update-ApprovedPackagesDocument.ps1' -Arguments @('-DataDirectory', $root.Path)
            Assert-True ($rejected.ExitCode -eq 1) 'Test-only arguments without -TestMode must fail.'
            $realFolder = Invoke-ToolProcess -ScriptName 'Update-ApprovedPackagesDocument.ps1' -Arguments @('-TestMode', '-DataDirectory', $realPaths.DataDirectory)
            Assert-True ($realFolder.ExitCode -eq 1) 'The real data folder must be rejected in test mode.'
            Assert-True ((Get-Sha256 -Path $realPaths.JsonPath) -ceq $json -and (Get-Sha256 -Path $realPaths.MarkdownPath) -ceq $md) 'The real files changed.'
        } finally { Remove-DataRoot -Entry $root }
    }
}

# ---------------------------------------------------------------------------
# Group: Manage (function level and child-process level)
# ---------------------------------------------------------------------------

function Invoke-ManageGroup {
    $g = 'Manage'
    $baseList = @($realRead.Data.packages | ForEach-Object { Copy-ApprovedPackage -Package $_ })
    $script:MgrTodayOverride = '2026-03-04'

    Invoke-Check $g 'Menu offers no deletion; the Action parameter has no delete operation' {
        $valid = @((Get-Command (Join-Path $toolsDirectory 'Manage-ApprovedPackage.ps1')).Parameters['Action'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues })
        Assert-True ($valid.Count -eq 8) ('Unexpected action count: ' + $valid.Count)
        Assert-True (@($valid | Where-Object { $_ -match '(?i)delete|remove(?!version)|purge' }).Count -eq 0) 'A delete-like action exists.'
        $menu = [string]$script:MgrMessages.MgrMenuItems -join "`n"
        $menuItems = @($script:MgrMessages.MgrMenuItems)
        Assert-True ($menuItems.Count -eq 10) ('Expected 10 menu lines (title, 8 operations, exit) but found ' + $menuItems.Count)
        Assert-True ($menuItems[0] -ne '' -and ($menuItems -join '') -notmatch 'delete') 'Menu text.'
    }
    Invoke-Check $g 'Add: new package gets the date when approved, empty otherwise; duplicates (also normalized) are rejected' {
        $change = New-AddChange -Packages $baseList -PackageName 'New_Pkg' -VersionListText '1.*, 2.0' -PurposeText 'p' -StatusName 'approved' -NotesText 'n'
        Assert-True ($change.New.approvedDate -ceq '2026-03-04' -and $null -eq $change.Old) 'approved date'
        Assert-True ((@($change.New.allowedVersions) -join '|') -ceq '1.*|2.0') 'versions'
        Assert-True (@($change.Warnings).Count -eq 0) 'no warning with versions'
        $pending = New-AddChange -Packages $baseList -PackageName 'x1' -VersionListText '' -PurposeText '' -StatusName 'pending' -NotesText ''
        Assert-True ($pending.New.approvedDate -ceq '' -and (@($pending.Warnings) -contains 'AnyVersion')) 'pending: empty date and any-version warning'
        Assert-Throws { New-AddChange -Packages $baseList -PackageName 'Python_PPTX' -VersionListText '' -PurposeText '' -StatusName 'approved' -NotesText '' } 'A normalized duplicate must be rejected.'
        Assert-Throws { New-AddChange -Packages $baseList -PackageName 'bad name' -VersionListText '' -PurposeText '' -StatusName 'approved' -NotesText '' } 'A bad name must be rejected.'
        Assert-Throws { New-AddChange -Packages $baseList -PackageName 'y' -VersionListText '8*' -PurposeText '' -StatusName 'approved' -NotesText '' } 'A bad version must be rejected.'
        Assert-Throws { New-AddChange -Packages $baseList -PackageName 'y' -VersionListText '8.*, 8.*' -PurposeText '' -StatusName 'approved' -NotesText '' } 'Duplicate versions must be rejected.'
        Assert-Throws { New-AddChange -Packages $baseList -PackageName 'y' -VersionListText '' -PurposeText '' -StatusName 'live' -NotesText '' } 'A bad status must be rejected.'
        Assert-Throws { New-AddChange -Packages $baseList -PackageName 'y' -VersionListText '' -PurposeText ('a' + [char]10 + 'b') -StatusName 'approved' -NotesText '' } 'A line break in text must be rejected.'
    }
    Invoke-Check $g 'approvedDate transitions: set on entering approved, cleared on leaving, kept when staying' {
        Assert-True ((Get-NextApprovedDate -OldStatus '' -NewStatus 'approved' -OldDate '' -Today '2026-03-04') -ceq '2026-03-04') 'new approved'
        Assert-True ((Get-NextApprovedDate -OldStatus '' -NewStatus 'pending' -OldDate '' -Today '2026-03-04') -ceq '') 'new pending'
        Assert-True ((Get-NextApprovedDate -OldStatus 'pending' -NewStatus 'approved' -OldDate '' -Today '2026-03-04') -ceq '2026-03-04') 'pending to approved'
        Assert-True ((Get-NextApprovedDate -OldStatus 'approved' -NewStatus 'disabled' -OldDate '2026-01-02' -Today '2026-03-04') -ceq '') 'approved to disabled'
        Assert-True ((Get-NextApprovedDate -OldStatus 'approved' -NewStatus 'approved' -OldDate '2026-01-02' -Today '2026-03-04') -ceq '2026-01-02') 'approved to approved'
        $off = New-StatusChange -Packages $baseList -PackageName 'pytest' -StatusName 'disabled'
        Assert-True ($off.New.approvedDate -ceq '') 'status change clears the date'
        $on = New-StatusChange -Packages @($off.Packages) -PackageName 'pytest' -StatusName 'approved'
        Assert-True ($on.New.approvedDate -ceq '2026-03-04') 'back to approved sets the new date'
        $same = New-StatusChange -Packages $baseList -PackageName 'pytest' -StatusName 'approved'
        Assert-True (Test-PackagesEqual -Left $same.Old -Right $same.New) 'The same status is no change.'
    }
    Invoke-Check $g 'Purpose, notes, and version edits never change approvedDate' {
        $purpose = New-TextFieldChange -Packages $baseList -PackageName 'pytest' -FieldName 'purpose' -NewText 'testing'
        $notes = New-TextFieldChange -Packages $baseList -PackageName 'pytest' -FieldName 'notes' -NewText 'memo'
        $added = New-AddVersionChange -Packages $baseList -PackageName 'pytest' -Pattern '7.*'
        $removed = New-RemoveVersionChange -Packages $baseList -PackageName 'pdfplumber' -Pattern '0.10.3'
        foreach ($change in @($purpose, $notes, $added, $removed)) {
            Assert-True ($change.New.approvedDate -ceq $change.Old.approvedDate) 'The date changed.'
        }
        Assert-True ($purpose.New.purpose -ceq 'testing' -and $notes.New.notes -ceq 'memo') 'Text edits.'
    }
    Invoke-Check $g 'Version add/remove: validation, duplicates, unknown names, and untouched other packages' {
        $added = New-AddVersionChange -Packages $baseList -PackageName 'Pytest' -Pattern '7.*'
        Assert-True ((@($added.New.allowedVersions) -join '|') -ceq '8.*.*|7.*') 'Added version.'
        Assert-True (@($added.Packages).Count -eq 8) 'The package count changed.'
        Assert-Throws { New-AddVersionChange -Packages $baseList -PackageName 'pytest' -Pattern '8.*.*' } 'A duplicate version must be rejected.'
        Assert-Throws { New-AddVersionChange -Packages $baseList -PackageName 'pytest' -Pattern '>=8' } 'An invalid version must be rejected.'
        Assert-Throws { New-AddVersionChange -Packages $baseList -PackageName 'nope' -Pattern '1.*' } 'An unknown package must be rejected.'
        Assert-Throws { New-RemoveVersionChange -Packages $baseList -PackageName 'pytest' -Pattern '9.*' } 'An unknown version must be rejected.'
    }
    Invoke-Check $g 'Removing the last allowed version raises the any-version warning (not a prohibition)' {
        $removed = New-RemoveVersionChange -Packages $baseList -PackageName 'pdfplumber' -Pattern '0.10.3'
        Assert-True (@($removed.New.allowedVersions).Count -eq 0) 'Versions must be empty.'
        Assert-True (@($removed.Warnings) -contains 'AnyVersion') 'The warning is missing.'
        Assert-True ($removed.New.status -ceq 'approved') 'The status must stay approved.'
        $text = Get-MgrMsg 'MgrWarnAnyVersion'
        Assert-True ($text.Contains('allowedVersions') -and $text.Contains('disabled')) 'The warning text must explain the meaning and the disabled alternative.'
        $again = New-RemoveVersionChange -Packages $baseList -PackageName 'pytest' -Pattern '8.*.*'
        Assert-True (@($again.Warnings) -contains 'AnyVersion') 'The warning must appear for any package.'
        $noWarn = New-AddVersionChange -Packages $baseList -PackageName 'playwright' -Pattern '1.*'
        Assert-True (@($noWarn.Warnings).Count -eq 0) 'Adding a version must not warn.'
    }
    Invoke-Check $g 'Child process: add, then confirm N keeps the file; SkipConfirmation saves and regenerates the document' {
        $root = New-DataRoot -CopyRealData
        try {
            $jsonPath = Join-Path $root.Path 'approved-packages.json'
            $before = Get-Sha256 -Path $jsonPath
            $declined = Invoke-Manage -Root $root -Arguments @('-Action', 'Add', '-Name', 'brandnew', '-VersionList', '1.*', '-Status', 'approved', '-Today', '2026-05-06', '-ConfirmAnswer', 'N')
            Assert-True ($declined.ExitCode -eq 2) ('Declined exit code was ' + $declined.ExitCode)
            Assert-True ((Get-Sha256 -Path $jsonPath) -ceq $before) 'The file changed after declining.'
            Assert-True ((Get-Sha256 -Path (Join-Path $root.Path 'approved-packages.md')) -ceq (Get-Sha256 -Path $realPaths.MarkdownPath)) 'The startup-generated document differs from the unchanged list.'
            $saved = Invoke-Manage -Root $root -Arguments @('-Action', 'Add', '-Name', 'brandnew', '-VersionList', '1.*', '-Status', 'approved', '-Today', '2026-05-06', '-SkipConfirmation')
            Assert-True ($saved.ExitCode -eq 0) ('Exit code ' + $saved.ExitCode + ': ' + $saved.Output)
            $packages = Read-DataRootPackages -Root $root
            Assert-True ($packages.Count -eq 9) 'The package count must be 9.'
            $new = Find-ApprovedPackage -Packages $packages -Name 'brandnew'
            Assert-True ($new.approvedDate -ceq '2026-05-06' -and $new.status -ceq 'approved') 'The new entry is wrong.'
            Assert-True (Test-ApprovedPackageOrder -Packages $packages) 'The list is not sorted.'
            Assert-True (@(Test-ApprovedPackageFileFormat -Path $jsonPath).Count -eq 0) 'File format problems.'
            Assert-True (@(Test-ApprovedPackageList -Data (Read-ApprovedPackageList -Path $jsonPath).Data).Count -eq 0) 'The saved list is invalid.'
            Assert-True ((Get-Sha256 -Path (Join-Path $root.Path 'approved-packages.md')) -match '^[0-9A-F]{64}$') 'The document was not regenerated.'
            $mdText = (Get-FileFacts -Path (Join-Path $root.Path 'approved-packages.md')).Text
            Assert-True ($mdText.Contains('| brandnew |')) 'The document does not list the new package.'
            Assert-True (@(Get-ChildItem -LiteralPath $root.Path -Force | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) 'A temporary file remains.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Child process: duplicate (normalized) add, unknown package, and bad values fail with exit code 1 and change nothing' {
        $root = New-DataRoot -CopyRealData
        try {
            $jsonPath = Join-Path $root.Path 'approved-packages.json'
            $before = Get-Sha256 -Path $jsonPath
            $cases = @(
                @('-Action', 'Add', '-Name', 'Python_PPTX', '-Status', 'approved', '-SkipConfirmation'),
                @('-Action', 'Add', '-Name', 'x', '-VersionList', '8*', '-Status', 'approved', '-SkipConfirmation'),
                @('-Action', 'SetStatus', '-Name', 'nope', '-Status', 'disabled', '-SkipConfirmation'),
                @('-Action', 'SetStatus', '-Name', 'pytest', '-Status', 'live', '-SkipConfirmation'),
                @('-Action', 'AddVersion', '-Name', 'pytest', '-Value', '8.*.*', '-SkipConfirmation'),
                @('-Action', 'RemoveVersion', '-Name', 'pytest', '-Value', '9.*', '-SkipConfirmation')
            )
            foreach ($case in $cases) {
                $run = Invoke-Manage -Root $root -Arguments $case
                Assert-True ($run.ExitCode -eq 1) ('Expected exit code 1 for [' + ($case -join ' ') + '] but got ' + $run.ExitCode)
            }
            Assert-True ((Get-Sha256 -Path $jsonPath) -ceq $before) 'The file changed.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Child process: status changes update approvedDate (approved -> disabled -> approved)' {
        $root = New-DataRoot -CopyRealData
        try {
            $off = Invoke-Manage -Root $root -Arguments @('-Action', 'SetStatus', '-Name', 'pytest', '-Status', 'disabled', '-Today', '2026-07-08', '-SkipConfirmation')
            Assert-True ($off.ExitCode -eq 0) ('disable exit ' + $off.ExitCode)
            $pytest = Find-ApprovedPackage -Packages (Read-DataRootPackages -Root $root) -Name 'pytest'
            Assert-True ($pytest.status -ceq 'disabled' -and $pytest.approvedDate -ceq '') 'disabled must clear the date'
            $on = Invoke-Manage -Root $root -Arguments @('-Action', 'SetStatus', '-Name', 'pytest', '-Status', 'approved', '-Today', '2026-07-09', '-SkipConfirmation')
            Assert-True ($on.ExitCode -eq 0) ('approve exit ' + $on.ExitCode)
            $pytest = Find-ApprovedPackage -Packages (Read-DataRootPackages -Root $root) -Name 'pytest'
            Assert-True ($pytest.status -ceq 'approved' -and $pytest.approvedDate -ceq '2026-07-09') 'approved must set the new date'
            $same = Invoke-Manage -Root $root -Arguments @('-Action', 'SetStatus', '-Name', 'pytest', '-Status', 'approved', '-Today', '2026-12-31', '-SkipConfirmation')
            Assert-True ($same.ExitCode -eq 0) 'The same status must be a no-op.'
            $pytest = Find-ApprovedPackage -Packages (Read-DataRootPackages -Root $root) -Name 'pytest'
            Assert-True ($pytest.approvedDate -ceq '2026-07-09') 'A no-op must not change the date.'
            $note = Invoke-Manage -Root $root -Arguments @('-Action', 'SetNotes', '-Name', 'pytest', '-Value', 'memo text', '-Today', '2026-12-31', '-SkipConfirmation')
            Assert-True ($note.ExitCode -eq 0) 'SetNotes'
            $pytest = Find-ApprovedPackage -Packages (Read-DataRootPackages -Root $root) -Name 'pytest'
            Assert-True ($pytest.notes -ceq 'memo text' -and $pytest.approvedDate -ceq '2026-07-09') 'Notes must not change the date.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Child process: removing every allowed version needs confirmation; N keeps them, Y leaves allowedVersions []' {
        $root = New-DataRoot -CopyRealData
        try {
            $jsonPath = Join-Path $root.Path 'approved-packages.json'
            $before = Get-Sha256 -Path $jsonPath
            $declined = Invoke-Manage -Root $root -Arguments @('-Action', 'RemoveVersion', '-Name', 'pdfplumber', '-Value', '0.10.3', '-ConfirmAnswer', 'N')
            Assert-True ($declined.ExitCode -eq 2) ('Declined exit code ' + $declined.ExitCode)
            Assert-True ((Get-Sha256 -Path $jsonPath) -ceq $before) 'The file changed after declining.'
            $accepted = Invoke-Manage -Root $root -Arguments @('-Action', 'RemoveVersion', '-Name', 'pdfplumber', '-Value', '0.10.3', '-SkipConfirmation')
            Assert-True ($accepted.ExitCode -eq 0) 'Accepted removal failed.'
            $pdf = Find-ApprovedPackage -Packages (Read-DataRootPackages -Root $root) -Name 'pdfplumber'
            Assert-True (@($pdf.allowedVersions).Count -eq 0 -and $pdf.status -ceq 'approved') 'Versions must be empty and the status must stay approved.'
            Assert-True ((Get-FileFacts -Path $jsonPath).Text.Contains('"allowedVersions": [],')) 'The empty array must be written as [].'
            $add = Invoke-Manage -Root $root -Arguments @('-Action', 'AddVersion', '-Name', 'pdfplumber', '-Value', '0.10.*', '-SkipConfirmation')
            Assert-True ($add.ExitCode -eq 0) 'AddVersion'
            $pdf = Find-ApprovedPackage -Packages (Read-DataRootPackages -Root $root) -Name 'pdfplumber'
            Assert-True ((@($pdf.allowedVersions) -join '|') -ceq '0.10.*') 'The added version is wrong.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Child process: Show and RegenerateDocument succeed without changing the list' {
        $root = New-DataRoot -CopyRealData
        try {
            $jsonPath = Join-Path $root.Path 'approved-packages.json'
            $before = Get-Sha256 -Path $jsonPath
            Assert-True ((Invoke-Manage -Root $root -Arguments @('-Action', 'Show')).ExitCode -eq 0) 'Show (list)'
            Assert-True ((Invoke-Manage -Root $root -Arguments @('-Action', 'Show', '-Name', 'pytest')).ExitCode -eq 0) 'Show (detail)'
            Assert-True ((Invoke-Manage -Root $root -Arguments @('-Action', 'Show', '-Name', 'nope')).ExitCode -eq 1) 'Show (unknown)'
            Assert-True ((Invoke-Manage -Root $root -Arguments @('-Action', 'RegenerateDocument')).ExitCode -eq 0) 'RegenerateDocument'
            Assert-True ((Get-Sha256 -Path $jsonPath) -ceq $before) 'The list changed.'
            Assert-True ((Get-Sha256 -Path (Join-Path $root.Path 'approved-packages.md')) -ceq (Get-Sha256 -Path $realPaths.MarkdownPath)) 'The document differs from the real one.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Child process: missing JSON and Markdown are initialized; a missing Markdown is regenerated' {
        $root = New-DataRoot
        try {
            $run = Invoke-Manage -Root $root -Arguments @('-Action', 'Show')
            Assert-True ($run.ExitCode -eq 0) ('Initialization failed: ' + $run.Output)
            $jsonPath = Join-Path $root.Path 'approved-packages.json'
            $mdPath = Join-Path $root.Path 'approved-packages.md'
            Assert-True ((Test-Path -LiteralPath $jsonPath -PathType Leaf) -and (Test-Path -LiteralPath $mdPath -PathType Leaf)) 'The missing files were not created.'
            $read = Read-ApprovedPackageList -Path $jsonPath
            Assert-True ($read.Success -and $read.Data.schemaVersion -eq 1 -and @($read.Data.packages).Count -eq 0) 'The initial JSON is not an empty schema-version-1 list.'
            Assert-True (@(Test-ApprovedPackageList -Data $read.Data).Count -eq 0) 'The initial JSON is invalid.'
            $labels = [pscustomobject]@{
                NoticeLines = @($toolMessages.MdNotice); Title = $toolMessages.MdTitle; HeaderName = $toolMessages.MdHeaderName
                HeaderVersions = $toolMessages.MdHeaderVersions; HeaderStatus = $toolMessages.MdHeaderStatus
                HeaderApprovedDate = $toolMessages.MdHeaderApprovedDate; HeaderPurpose = $toolMessages.MdHeaderPurpose
                HeaderNotes = $toolMessages.MdHeaderNotes; NoVersions = $toolMessages.MdNoVersions
            }
            $expected = ConvertTo-ApprovedPackagesMarkdown -Packages @() -Labels $labels
            $actual = [System.IO.File]::ReadAllText($mdPath, (New-Object System.Text.UTF8Encoding($false, $true)))
            Assert-True ($actual -ceq $expected) 'The initial Markdown does not match the empty list.'
        } finally { Remove-DataRoot -Entry $root }

        $root = New-DataRoot -CopyRealData
        try {
            $jsonPath = Join-Path $root.Path 'approved-packages.json'
            $before = Get-Sha256 -Path $jsonPath
            $run = Invoke-Manage -Root $root -Arguments @('-Action', 'Show')
            Assert-True ($run.ExitCode -eq 0) ('Markdown regeneration failed: ' + $run.Output)
            Assert-True ((Get-Sha256 -Path $jsonPath) -ceq $before) 'Regenerating Markdown changed the JSON.'
            Assert-True ((Get-Sha256 -Path (Join-Path $root.Path 'approved-packages.md')) -ceq (Get-Sha256 -Path $realPaths.MarkdownPath)) 'The regenerated Markdown differs from the source JSON.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Child process: invalid list stops every operation (exit 1, no write)' {
        $root = New-DataRoot
        try {
            $jsonPath = Join-Path $root.Path 'approved-packages.json'
            [System.IO.File]::WriteAllText($jsonPath, '{ "schemaVersion": 1, "packages": [ { "name": "a" } ] }', (New-Object System.Text.UTF8Encoding($false)))
            $before = Get-Sha256 -Path $jsonPath
            foreach ($action in @('Show', 'RegenerateDocument')) {
                Assert-True ((Invoke-Manage -Root $root -Arguments @('-Action', $action)).ExitCode -eq 1) ($action + ' must stop.')
            }
            Assert-True ((Invoke-Manage -Root $root -Arguments @('-Action', 'Add', '-Name', 'b', '-Status', 'pending', '-SkipConfirmation')).ExitCode -eq 1) 'Add must stop.'
            Assert-True ((Get-Sha256 -Path $jsonPath) -ceq $before) 'The invalid file was modified.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root.Path 'approved-packages.md'))) 'A document was written.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Interactive menu (scripted stdin, normal mode): show, invalid choice, add then answer N, end of input' {
        $json = Get-Sha256 -Path $realPaths.JsonPath
        $md = Get-Sha256 -Path $realPaths.MarkdownPath
        $nl = "`r`n"
        $show = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @() -InputText ('2' + $nl + $nl + '2' + $nl + 'pytest' + $nl + '9' + $nl + '0' + $nl)
        Assert-True ($show.ExitCode -eq 0) ('Show flow exit code ' + $show.ExitCode)
        $declined = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @() -InputText ('1' + $nl + 'zz_interactive_test' + $nl + '1.*' + $nl + $nl + 'approved' + $nl + $nl + 'N' + $nl + '0' + $nl)
        Assert-True ($declined.ExitCode -eq 0) ('Add-then-N flow exit code ' + $declined.ExitCode)
        $enter = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @() -InputText ('7' + $nl + 'pytest' + $nl + 'disabled' + $nl + $nl + '0' + $nl)
        Assert-True ($enter.ExitCode -eq 0) ('Enter-as-No flow exit code ' + $enter.ExitCode)
        $badInput = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @() -InputText ('1' + $nl)
        Assert-True ($badInput.ExitCode -eq 1) ('End of input must stop with exit code 1 but got ' + $badInput.ExitCode)
        Assert-True ((Get-Sha256 -Path $realPaths.JsonPath) -ceq $json -and (Get-Sha256 -Path $realPaths.MarkdownPath) -ceq $md) 'The real files changed.'
    }
    Invoke-Check $g 'Safety: test-only arguments need -TestMode; the real data folder and unmarked folders are rejected' {
        $json = Get-Sha256 -Path $realPaths.JsonPath
        $md = Get-Sha256 -Path $realPaths.MarkdownPath
        $noTest = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @('-Action', 'Show')
        Assert-True ($noTest.ExitCode -eq 1) 'Arguments without -TestMode must fail.'
        $real = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @('-TestMode', '-DataDirectory', $realPaths.DataDirectory, '-Action', 'SetStatus', '-Name', 'pytest', '-Status', 'disabled', '-SkipConfirmation')
        Assert-True ($real.ExitCode -eq 1) 'The real data folder must be rejected.'
        $unmarked = Join-Path $tempBase ('approved-packages-unmarked-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $unmarked)
        try {
            $run = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @('-TestMode', '-DataDirectory', $unmarked, '-Action', 'Show')
            Assert-True ($run.ExitCode -eq 1) 'An unmarked folder must be rejected.'
            $noDir = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @('-TestMode', '-Action', 'Show')
            Assert-True ($noDir.ExitCode -eq 1) '-TestMode without -DataDirectory must fail.'
            $noAction = Invoke-ToolProcess -ScriptName 'Manage-ApprovedPackage.ps1' -Arguments @('-TestMode', '-DataDirectory', $unmarked)
            Assert-True ($noAction.ExitCode -eq 1) '-TestMode without -Action must fail.'
        } finally {
            if ((Split-Path -Parent $unmarked) -ieq $tempBase -and (Split-Path -Leaf $unmarked) -cmatch '^approved-packages-unmarked-[0-9a-f]{32}$') { [System.IO.Directory]::Delete($unmarked, $true) }
        }
        Assert-True ((Get-Sha256 -Path $realPaths.JsonPath) -ceq $json -and (Get-Sha256 -Path $realPaths.MarkdownPath) -ceq $md) 'The real files changed.'
    }
}

# ---------------------------------------------------------------------------
# Group: Tools (static checks of the sources and message files)
# ---------------------------------------------------------------------------

function Invoke-ToolsGroup {
    $g = 'Tools'
    $scripts = @('ApprovedPackages.Common.ps1', 'Manage-ApprovedPackage.ps1', 'Update-ApprovedPackagesDocument.ps1', 'Install-Packages.ps1', 'Test-ApprovedPackages.ps1')
    Invoke-Check $g 'All tool scripts parse without errors in this PowerShell' {
        foreach ($name in $scripts) {
            $text = [System.IO.File]::ReadAllText((Join-Path $toolsDirectory $name), (New-Object System.Text.UTF8Encoding($false)))
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            Assert-True (@($errors).Count -eq 0) ('Parse errors in ' + $name)
        }
    }
    Invoke-Check $g 'Scripts are ASCII only, without BOM, CRLF only' {
        foreach ($name in $scripts) {
            $facts = Get-FileFacts -Path (Join-Path $toolsDirectory $name)
            Assert-True ($facts.NonAscii -eq 0) ($name + ' contains non-ASCII text (messages must live in JSON).')
            Assert-True (-not $facts.HasBom) ($name + ' has a BOM.')
            Assert-True ($facts.BareLf -eq 0 -and $facts.BareCr -eq 0 -and $facts.Crlf -gt 0) ($name + ' must use CRLF only.')
        }
    }
    Invoke-Check $g 'ApprovedPackages.messages.json: BOM-less, CRLF, Japanese intact, reloads' {
        $facts = Get-FileFacts -Path $realPaths.MessagesPath
        Assert-True (-not $facts.HasBom) 'BOM found.'
        Assert-True ($facts.BareLf -eq 0 -and $facts.BareCr -eq 0 -and $facts.Crlf -gt 0) 'CRLF only is required.'
        Assert-True ($facts.Text -match '[\u3040-\u30FF\u4E00-\u9FFF]') 'Japanese text is missing.'
        Assert-True (-not $facts.Text.Contains([string][char]0xFFFD)) 'Replacement characters found.'
        $loaded = $facts.Text | ConvertFrom-Json
        Assert-True (@($loaded.PSObject.Properties).Count -gt 60) 'Too few message keys.'
        $names = @($loaded.PSObject.Properties | ForEach-Object { $_.Name })
        Assert-True (@($names | Select-Object -Unique).Count -eq $names.Count) 'Duplicate keys.'
    }
    Invoke-Check $g 'Each tool validates only the keys it uses; those lists are all present in the file' {
        $loaded = (Get-FileFacts -Path $realPaths.MessagesPath).Text | ConvertFrom-Json
        $names = @($loaded.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($list in @($script:ManageRequiredKeys, $script:TestRequiredKeys)) {
            foreach ($key in $list) { Assert-True ($names -ccontains $key) ('Missing key: ' + $key) }
        }
        $updateText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'Update-ApprovedPackagesDocument.ps1')).Text
        $match = [regex]::Match($updateText, '(?s)\$script:UpdateRequiredKeys = @\((.*?)\r?\n\)')
        Assert-True $match.Success 'The Update key list was not found.'
        $updateKeys = @([regex]::Matches($match.Groups[1].Value, "'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value })
        Assert-True ($updateKeys.Count -gt 20) 'The Update key list is too short.'
        foreach ($key in $updateKeys) { Assert-True ($names -ccontains $key) ('Missing Update key: ' + $key) }
        Assert-True (@($updateKeys | Where-Object { $_ -like 'Mgr*' -or $_ -like 'Test*' }).Count -eq 0) 'Update must not require keys of other tools.'
        Assert-True (@($script:ManageRequiredKeys | Where-Object { $_ -like 'Upd*' -or $_ -like 'Md*' -or $_ -like 'Test*' }).Count -eq 0) 'Manage must not require keys of other tools.'
        $installText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'Install-Packages.ps1')).Text
        $installList = [regex]::Match($installText, '(?s)\$script:InstallRequiredKeys = @\((.*?)\r?\n\)').Groups[1].Value
        $installKeys = @([regex]::Matches($installList, "'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value })
        Assert-True ($installKeys.Count -gt 80) 'The Install key list is too short.'
        foreach ($key in $installKeys) { Assert-True ($names -ccontains $key) ('Missing Install key: ' + $key) }
        Assert-True (@($installKeys | Where-Object { $_ -like 'Mgr*' -or $_ -like 'Upd*' -or $_ -like 'Md*' -or $_ -like 'Test*' }).Count -eq 0) 'Install must not require keys of other tools.'
        Assert-True (@($updateKeys | Where-Object { $_ -like 'Inst*' }).Count -eq 0 -and @($script:ManageRequiredKeys | Where-Object { $_ -like 'Inst*' }).Count -eq 0) 'Other tools must not require Install keys.'
        $installNames = @($names | Where-Object { $_ -like 'Inst*' })
        Assert-True ($installNames.Count -ge 70) 'Too few Install keys.'
        foreach ($key in $installNames) { Assert-True ($installKeys -ccontains $key) ('An Install key is not required by Install: ' + $key) }
        Assert-True ($script:OriginalMessageKeys.Count -eq 88) 'The original key list is wrong.'
        Assert-True ((($names[0..87]) -join ',') -ceq ($script:OriginalMessageKeys -join ',')) 'The original 88 keys changed (order, names, or count).'
    }
    Invoke-Check $g 'Every message key used in the tool sources is declared as required by that tool' {
        $manageText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'Manage-ApprovedPackage.ps1')).Text
        $used = @([regex]::Matches($manageText, "Get-MgrMsg\s+'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        foreach ($key in $used) { Assert-True ($script:ManageRequiredKeys -ccontains $key) ('Manage uses an undeclared key: ' + $key) }
        $updateText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'Update-ApprovedPackagesDocument.ps1')).Text
        $updateUsed = @([regex]::Matches($updateText, "Get-UpdMsg\s+'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $updateList = [regex]::Match($updateText, '(?s)\$script:UpdateRequiredKeys = @\((.*?)\r?\n\)').Groups[1].Value
        foreach ($key in $updateUsed) { Assert-True ($updateList.Contains("'" + $key + "'")) ('Update uses an undeclared key: ' + $key) }
        $installText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'Install-Packages.ps1')).Text
        $installUsed = @([regex]::Matches($installText, "Get-InstMsg\s+'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $installList = [regex]::Match($installText, '(?s)\$script:InstallRequiredKeys = @\((.*?)\r?\n\)').Groups[1].Value
        foreach ($key in $installUsed) { Assert-True ($installList.Contains("'" + $key + "'")) ('Install uses an undeclared key: ' + $key) }
        $dynamicInstallKeys = @()
        foreach ($code in @('Option', 'Url', 'LocalPath', 'Extras', 'Marker', 'InlineComment', 'Operator', 'Format', 'Wildcard', 'UnsupportedVersion', 'EmptyVersion', 'Duplicate', 'DuplicateAcrossFiles')) { $dynamicInstallKeys += ('InstReqProblem' + $code) }
        foreach ($code in @('NotRegistered', 'StatusPending', 'StatusDeprecated', 'StatusDisabled', 'StatusInvalid', 'VersionUnsupportedFormat', 'VersionNotAllowed', 'NeedsPin')) { $dynamicInstallKeys += ('InstDec' + $code) }
        foreach ($code in @('Pinned', 'FixedFromList', 'RangeFromList', 'AnyVersion')) { $dynamicInstallKeys += ('InstMode' + $code) }
        foreach ($code in @('Added', 'Changed', 'Removed')) { $dynamicInstallKeys += ('InstKind' + $code) }
        foreach ($key in $dynamicInstallKeys) { Assert-True ($installList.Contains("'" + $key + "'")) ('Install does not require the dynamic key: ' + $key) }
        $commonText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'ApprovedPackages.Common.ps1')).Text
        $lineProblemBody = [regex]::Match($commonText, '(?s)function Get-RequirementLineProblem \{.*?\r?\n\}').Value
        $lineCodes = @([regex]::Matches($lineProblemBody, "return '([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        Assert-True ($lineCodes.Count -ge 10) 'The requirement problem codes were not found.'
        foreach ($code in $lineCodes) { Assert-True ($installList.Contains("'InstReqProblem" + $code + "'")) ('Install has no message for requirement problem ' + $code) }
    }
    Invoke-Check $g 'Every problem code emitted by Common has a Problem message and is required by Manage and Update' {
        $commonText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'ApprovedPackages.Common.ps1')).Text
        $codes = @([regex]::Matches($commonText, "New-ProblemRecord -Code '([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        Assert-True ($codes.Count -ge 15) ('Too few problem codes: ' + $codes.Count)
        $updateText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'Update-ApprovedPackagesDocument.ps1')).Text
        $loaded = (Get-FileFacts -Path $realPaths.MessagesPath).Text | ConvertFrom-Json
        foreach ($code in $codes) {
            Assert-True ($null -ne $loaded.PSObject.Properties['Problem' + $code]) ('No message for problem ' + $code)
            Assert-True ($script:ManageRequiredKeys -ccontains ('Problem' + $code)) ('Manage does not require Problem' + $code)
            Assert-True ($updateText.Contains("'Problem" + $code + "'")) ('Update does not require Problem' + $code)
        }
        foreach ($readCode in @('FileNotFound', 'InvalidUtf8', 'InvalidJson')) {
            Assert-True ($script:ManageRequiredKeys -ccontains ('ErrRead' + $readCode)) ('Manage does not require ErrRead' + $readCode)
            Assert-True ($updateText.Contains("'ErrRead" + $readCode + "'")) ('Update does not require ErrRead' + $readCode)
        }
    }
    Invoke-Check $g 'Import-ToolMessages rejects missing files, invalid JSON, and missing keys (no auto-repair)' {
        $root = New-DataRoot
        try {
            $bad = Join-Path $root.Path 'bad.json'
            [System.IO.File]::WriteAllText($bad, '{ not json', (New-Object System.Text.UTF8Encoding($false)))
            $before = Get-Sha256 -Path $bad
            Assert-Throws { Import-ToolMessages -Path (Join-Path $root.Path 'none.json') -RequiredKeys @('a') } 'A missing file must throw.'
            Assert-Throws { Import-ToolMessages -Path $bad -RequiredKeys @('a') } 'Invalid JSON must throw.'
            $partial = Join-Path $root.Path 'partial.json'
            [System.IO.File]::WriteAllText($partial, '{ "a": "x" }', (New-Object System.Text.UTF8Encoding($false)))
            Assert-Throws { Import-ToolMessages -Path $partial -RequiredKeys @('a', 'b') } 'A missing key must throw.'
            $ok = Import-ToolMessages -Path $partial -RequiredKeys @('a')
            Assert-True ((Get-ToolMessage -Messages $ok -Key 'a') -ceq 'x') 'Message lookup.'
            Assert-True ((Get-ToolMessage -Messages $ok -Key 'zzz') -like '`[message not found*') 'A missing key must yield a visible marker.'
            Assert-True ((Get-Sha256 -Path $bad) -ceq $before) 'The bad file was modified.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'Placeholders are applied to messages' {
        $messages = [pscustomobject]@{ k = 'A {0} B {1}'; arr = @('x {0}', 'y') }
        Assert-True ((Get-ToolMessage -Messages $messages -Key 'k' -FormatArgs @('1', '2')) -ceq 'A 1 B 2') 'Placeholder substitution.'
        Assert-True ((Get-ToolMessage -Messages $messages -Key 'arr' -FormatArgs @('z')) -ceq ('x z' + [Environment]::NewLine + 'y')) 'Array messages.'
    }
    Invoke-Check $g 'Sources contain no pip, git, network, ConvertTo-Json, or execution-policy handling (comments excluded)' {
        $forbiddenCommands = @('pip', 'pip3', 'git', 'python', 'py', 'curl', 'wget', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'ConvertTo-Json', 'Set-ExecutionPolicy', 'Install-Module', 'Install-Package')
        foreach ($name in @('ApprovedPackages.Common.ps1', 'Manage-ApprovedPackage.ps1', 'Update-ApprovedPackagesDocument.ps1', 'Install-Packages.ps1')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $toolsDirectory $name), (New-Object System.Text.UTF8Encoding($false)))
            $errors = $null
            $tokens = [System.Management.Automation.PSParser]::Tokenize($text, [ref]$errors)
            foreach ($token in $tokens) {
                if ($token.Type -eq 'Command') {
                    Assert-True ($forbiddenCommands -inotcontains $token.Content) ($name + ' calls a forbidden command: ' + $token.Content)
                }
                if ($token.Type -eq 'String' -or $token.Type -eq 'CommandArgument') {
                    Assert-True ($token.Content -notmatch '(?i)ExecutionPolicy|Bypass|git\s+(add|commit|push|tag|remote)') ($name + ' mentions a forbidden operation in code.')
                    Assert-True ($token.Content -cnotmatch '^(-U|--(trusted-host|upgrade|index-url|extra-index-url|cert|client-cert|proxy|no-verify|disable-pip-version-check))\b') ($name + ' passes a forbidden pip option: ' + $token.Content)
                }
            }
        }
    }
    Invoke-Check $g 'Tools are independent of the current directory (paths come from the script location)' {
        Push-Location $tempBase
        try {
            $paths = Get-ApprovedPackagesPaths
            Assert-True ($paths.JsonPath -ceq $realPaths.JsonPath -and $paths.MessagesPath -ceq $realPaths.MessagesPath) 'The paths depend on the current directory.'
            Assert-True ($paths.WorkspaceRoot -ceq (Split-Path -Parent $toolsDirectory | Split-Path -Parent)) 'The workspace root is wrong.'
        } finally { Pop-Location }
    }
    Invoke-Check $g 'No backup, history, or log files are created next to the data files' {
        $names = @(Get-ChildItem -LiteralPath $realPaths.DataDirectory -Force | Where-Object { $_.Name -cne '.gitkeep' } | ForEach-Object { $_.Name } | Sort-Object)
        Assert-True (($names -join '|') -ceq 'approved-packages.json|approved-packages.md') ('Unexpected files: ' + ($names -join ', '))
    }
}

function Invoke-ValidateOnlyGroup {
    $g = 'ValidateOnly'
    Invoke-Check $g '-ValidateOnly leaves .venv, requirements, the approved list, pip state, and the Git state unchanged and shows the plan' {
        $s = New-Scenario -RuntimeText "pytest`r`npdfplumber`r`nplaywright`r`n" -DevText "# dev`r`npyinstaller`r`n"
        try {
            $before = Get-TreeSnapshot -Path $s.Root.Path
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'All', '-ValidateOnly')
            Assert-True ($run.ExitCode -eq 0) ('Exit code ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $s.Root.Path 'pip.log'))) 'pip (the fake python) was called.'
            Assert-True ((Get-TreeSnapshot -Path $s.Root.Path) -ceq $before) 'A file under the test workspace changed.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $s.Project '.git')) -and -not (Test-Path -LiteralPath (Join-Path $s.Root.Path '.git'))) 'A Git folder was created.'
            foreach ($spec in @('pytest>=8,<9', 'pdfplumber==0.10.3', 'playwright', 'pyinstaller>=6,<7')) {
                Assert-True ($run.Output.Contains($spec)) ('The plan does not show: ' + $spec)
            }
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g '-ValidateOnly with a version-less any-version package shows the warning without prompting (stdin closed)' {
        $s = New-Scenario -RuntimeText "playwright`r`n"
        try {
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime', '-ValidateOnly')
            Assert-True ($run.ExitCode -eq 0) ('Exit code ' + $run.ExitCode)
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $s.Root.Path 'pip.log'))) 'pip was called.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g '-ValidateOnly still stops on every problem (exit code 1) and changes nothing' {
        $cases = @(
            @{ Runtime = "notregistered`r`n"; Switch = '' },
            @{ Runtime = "pytest>=8`r`n"; Switch = '' },
            @{ Runtime = "pytest==9.0.0`r`n"; Switch = '' },
            @{ Runtime = "pytest`r`n"; Switch = 'NoVenv' }
        )
        foreach ($case in $cases) {
            if ($case.Switch -ceq 'NoVenv') { $s = New-Scenario -RuntimeText $case.Runtime -NoVenv } else { $s = New-Scenario -RuntimeText $case.Runtime }
            try {
                $before = Get-TreeSnapshot -Path $s.Root.Path
                $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime', '-ValidateOnly')
                Assert-True ($run.ExitCode -eq 1) ('Expected exit code 1 for [' + $case.Runtime.Trim() + '] but got ' + $run.ExitCode)
                Assert-True ((Get-TreeSnapshot -Path $s.Root.Path) -ceq $before) 'Files changed.'
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $s.Root.Path 'pip.log'))) 'pip was called.'
            } finally { Remove-DataRoot -Entry $s.Root }
        }
    }
}

# ---------------------------------------------------------------------------
# Install tool: fake python, scenarios, and groups
# ---------------------------------------------------------------------------

$script:FakePythonSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class FakePython
{
    static string Env(string name) { return Environment.GetEnvironmentVariable(name); }
    static string Norm(string name) { return System.Text.RegularExpressions.Regex.Replace(name, "[-_.]+", "-").ToLowerInvariant(); }
    static void Log(string line)
    {
        string path = Env("FAKE_PIP_LOG");
        if (!string.IsNullOrEmpty(path)) { File.AppendAllText(path, line + "\r\n", new UTF8Encoding(false)); }
    }
    static SortedDictionary<string, string[]> LoadState()
    {
        SortedDictionary<string, string[]> state = new SortedDictionary<string, string[]>(StringComparer.Ordinal);
        string path = Env("FAKE_PIP_STATE");
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) { return state; }
        foreach (string raw in File.ReadAllLines(path))
        {
            int i = raw.IndexOf("==", StringComparison.Ordinal);
            if (i > 0) { state[Norm(raw.Substring(0, i))] = new string[] { raw.Substring(0, i), raw.Substring(i + 2) }; }
        }
        return state;
    }
    static void SaveState(SortedDictionary<string, string[]> state)
    {
        string path = Env("FAKE_PIP_STATE");
        if (string.IsNullOrEmpty(path)) { return; }
        List<string> lines = new List<string>();
        foreach (KeyValuePair<string, string[]> pair in state) { lines.Add(pair.Value[0] + "==" + pair.Value[1]); }
        File.WriteAllLines(path, lines.ToArray(), new UTF8Encoding(false));
    }
    static string Lookup(string file, string name)
    {
        if (string.IsNullOrEmpty(file) || !File.Exists(file)) { return null; }
        foreach (string raw in File.ReadAllLines(file))
        {
            int i = raw.IndexOf('=');
            if (i > 0 && Norm(raw.Substring(0, i)) == Norm(name)) { return raw.Substring(i + 1); }
        }
        return null;
    }
    static void AddTransitive(SortedDictionary<string, string[]> state, string parent)
    {
        string path = Env("FAKE_PIP_TRANSITIVE");
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) { return; }
        foreach (string raw in File.ReadAllLines(path))
        {
            int c = raw.IndexOf(':');
            if (c <= 0 || Norm(raw.Substring(0, c)) != Norm(parent)) { continue; }
            string dep = raw.Substring(c + 1);
            int e = dep.IndexOf("==", StringComparison.Ordinal);
            if (e > 0) { state[Norm(dep.Substring(0, e))] = new string[] { Norm(dep.Substring(0, e)), dep.Substring(e + 2) }; }
        }
    }
    public static int Main(string[] args)
    {
        Log("ARGS|" + string.Join("|", args));
        string stateFile = Env("FAKE_PIP_STATE");
        if (args.Length >= 3 && args[0] == "-m" && args[1] == "pip" && args[2] == "freeze")
        {
            string freezeMode = Env("FAKE_PIP_FREEZE_MODE");
            if (freezeMode == "fail") { Console.Error.WriteLine("ERROR: fake freeze failure"); return 1; }
            if (freezeMode == "fail-after-install" && stateFile != null && File.Exists(stateFile + ".installed")) { Console.Error.WriteLine("ERROR: fake freeze failure after install"); return 1; }
            foreach (KeyValuePair<string, string[]> pair in LoadState()) { Console.WriteLine(pair.Value[0] + "==" + pair.Value[1]); }
            return 0;
        }
        if (args.Length >= 3 && args[0] == "-m" && args[1] == "pip" && args[2] == "install")
        {
            string mode = Env("FAKE_PIP_MODE");
            if (mode == null) { mode = "ok"; }
            if (stateFile != null) { File.WriteAllText(stateFile + ".installed", "1"); }
            if (mode == "fail") { Console.Error.WriteLine("ERROR: fake pip failure"); return 1; }
            SortedDictionary<string, string[]> state = LoadState();
            for (int index = 3; index < args.Length; index++)
            {
                string spec = args[index];
                int cut = spec.IndexOfAny(new char[] { '=', '<', '>', '~', '!' });
                string name = cut > 0 ? spec.Substring(0, cut) : spec;
                string version = null;
                if (cut > 0 && spec.Substring(cut).StartsWith("==", StringComparison.Ordinal)) { version = spec.Substring(cut + 2); }
                if (version == null) { version = Lookup(Env("FAKE_PIP_RESOLVE"), name); }
                if (version == null) { version = "1.0.0"; }
                if (mode == "fail-partial" && index == 4) { SaveState(state); Console.Error.WriteLine("ERROR: fake partial failure"); return 1; }
                if (!(mode == "skip-record" && index == 3))
                {
                    state[Norm(name)] = new string[] { Norm(name), version };
                    AddTransitive(state, name);
                }
                Console.WriteLine("Installing " + name + " " + version);
            }
            SaveState(state);
            return 0;
        }
        Console.Error.WriteLine("fake python: unsupported arguments");
        return 2;
    }
}
'@

function Get-FakePython {
    if ($null -ne $script:FakePythonPath -and (Test-Path -LiteralPath $script:FakePythonPath -PathType Leaf)) { return $script:FakePythonPath }
    $holder = New-DataRoot
    $path = Join-Path $holder.Path 'python.exe'
    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $options = New-Object System.CodeDom.Compiler.CompilerParameters
    $options.GenerateExecutable = $true
    [void]$options.ReferencedAssemblies.Add('System.dll')
    $options.OutputAssembly = $path
    $options.CompilerOptions = '/nologo'
    $compiled = $provider.CompileAssemblyFromSource($options, $script:FakePythonSource)
    if ($compiled.Errors.HasErrors) {
        throw ('Could not compile the fake python: ' + (($compiled.Errors | ForEach-Object { $_.ErrorText }) -join '; '))
    }
    $script:FakePythonPath = $path
    return $path
}

function New-InstallRoot {
    $entry = New-DataRoot
    $ascii = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllText((Join-Path $entry.Path '.install-packages-test-root'), $entry.Guid, $ascii)
    [void](New-Item -ItemType Directory -Path (Join-Path $entry.Path 'Projects'))
    [void](New-Item -ItemType Directory -Path (Join-Path $entry.Path 'ApprovedPackages'))
    Copy-Item -LiteralPath $realPaths.JsonPath -Destination (Join-Path $entry.Path 'ApprovedPackages\approved-packages.json')
    return $entry
}

function ConvertTo-TextBytes {
    param([string]$Text, [switch]$Bom)

    $body = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    if ($Bom.IsPresent) { return [byte[]](@(0xEF, 0xBB, 0xBF) + @($body)) }
    return [byte[]]$body
}

function New-TestProject {
    param(
        [object]$Root,
        [string]$FolderName,
        [byte[]]$RuntimeBytes,
        [byte[]]$DevBytes,
        [switch]$NoVenv
    )

    $dir = Join-Path $Root.Path ('Projects\' + $FolderName)
    [void](New-Item -ItemType Directory -Path $dir)
    if (-not $NoVenv.IsPresent) {
        $scripts = Join-Path $dir '.venv\Scripts'
        [void](New-Item -ItemType Directory -Path $scripts -Force)
        Copy-Item -LiteralPath (Get-FakePython) -Destination (Join-Path $scripts 'python.exe')
    }
    if ($null -ne $RuntimeBytes) { [System.IO.File]::WriteAllBytes((Join-Path $dir 'requirements.txt'), $RuntimeBytes) }
    if ($null -ne $DevBytes) { [System.IO.File]::WriteAllBytes((Join-Path $dir 'requirements-dev.txt'), $DevBytes) }
    return $dir
}

function Initialize-FakeFiles {
    param([object]$Root, [string[]]$State, [string[]]$Resolve, [string[]]$Transitive)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines((Join-Path $Root.Path 'pip-state.txt'), $State, $utf8)
    [System.IO.File]::WriteAllLines((Join-Path $Root.Path 'resolve.txt'), $Resolve, $utf8)
    [System.IO.File]::WriteAllLines((Join-Path $Root.Path 'transitive.txt'), $Transitive, $utf8)
}

function New-Scenario {
    param(
        [string]$RuntimeText,
        [string]$DevText,
        [switch]$NoVenv,
        [string[]]$Resolve = @('pytest=8.4.2', 'python-pptx=1.0.2', 'pyinstaller=6.11.1', 'pyperclip=1.9.0', 'playwright=1.58.0'),
        [string[]]$Transitive = @('pytest:iniconfig==2.0.0')
    )

    $root = New-InstallRoot
    $runtime = $null
    if (-not [string]::IsNullOrEmpty($RuntimeText)) { $runtime = ConvertTo-TextBytes -Text $RuntimeText }
    $dev = $null
    if (-not [string]::IsNullOrEmpty($DevText)) { $dev = ConvertTo-TextBytes -Text $DevText }
    $project = New-TestProject -Root $root -FolderName 'Project Demo' -RuntimeBytes $runtime -DevBytes $dev -NoVenv:$NoVenv
    Initialize-FakeFiles -Root $root -State @('pip==24.0', 'setuptools==65.5.0') -Resolve $Resolve -Transitive $Transitive
    return [pscustomobject]@{
        Root = $root; Project = $project
        Runtime = Join-Path $project 'requirements.txt'; Dev = Join-Path $project 'requirements-dev.txt'
    }
}

function Get-FakeEnvironment {
    param([object]$Root, [hashtable]$Extra)

    $environment = @{
        FAKE_PIP_LOG         = Join-Path $Root.Path 'pip.log'
        FAKE_PIP_STATE       = Join-Path $Root.Path 'pip-state.txt'
        FAKE_PIP_RESOLVE     = Join-Path $Root.Path 'resolve.txt'
        FAKE_PIP_TRANSITIVE  = Join-Path $Root.Path 'transitive.txt'
        FAKE_PIP_MODE        = 'ok'
        FAKE_PIP_FREEZE_MODE = 'ok'
    }
    if ($null -ne $Extra) { foreach ($key in $Extra.Keys) { $environment[$key] = $Extra[$key] } }
    return $environment
}

function Invoke-Install {
    param(
        [object]$Root,
        [string[]]$Arguments,
        [hashtable]$Extra,
        [string]$InputText,
        [string]$WorkingDirectory,
        [switch]$Confirm
    )

    $all = @('-TestMode', '-TestWorkspaceRoot', $Root.Path) + @($Arguments)
    if (-not $Confirm.IsPresent -and -not ($all -contains '-ConfirmAnswer') -and [string]::IsNullOrEmpty($InputText) -and -not ($all -contains '-ValidateOnly')) {
        $all += '-SkipConfirmation'
    }
    return (Invoke-ToolProcess -ScriptName 'Install-Packages.ps1' -Arguments $all -InputText $InputText -WorkingDirectory $WorkingDirectory -Environment (Get-FakeEnvironment -Root $Root -Extra $Extra))
}

function Get-PipLogLines {
    param([object]$Root)

    $path = Join-Path $Root.Path 'pip.log'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    return @([System.IO.File]::ReadAllLines($path))
}

function Get-InstallCallLines {
    param([object]$Root)

    return @(Get-PipLogLines -Root $Root | Where-Object { $_.StartsWith('ARGS|-m|pip|install|') })
}

function Get-TreeSnapshot {
    param([string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $lines = @(Get-ChildItem -LiteralPath $full -Recurse -Force -File | ForEach-Object {
            $_.FullName.Substring($full.Length + 1) + '|' + $_.Length + '|' + (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        } | Sort-Object)
    return ($lines -join "`n")
}

function Get-StateText {
    param([object]$Root)

    return [System.IO.File]::ReadAllText((Join-Path $Root.Path 'pip-state.txt'))
}

function Set-ApprovedListForRoot {
    param([object]$Root, [object[]]$Packages)

    Write-ApprovedPackageList -Path (Join-Path $Root.Path 'ApprovedPackages\approved-packages.json') -Packages $Packages
}

function Assert-StopsWithoutInstall {
    param([object]$Scenario, [string[]]$Arguments, [int]$ExpectedExit = 1, [hashtable]$Extra, [string]$InputText, [string]$Label)

    $before = Get-TreeSnapshot -Path $Scenario.Root.Path
    $run = Invoke-Install -Root $Scenario.Root -Arguments $Arguments -Extra $Extra -InputText $InputText
    Assert-True ($run.ExitCode -eq $ExpectedExit) ($Label + ': expected exit code ' + $ExpectedExit + ' but got ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
    Assert-True (@(Get-InstallCallLines -Root $Scenario.Root).Count -eq 0) ($Label + ': pip install was called.')
    Assert-True ((Get-TreeSnapshot -Path $Scenario.Root.Path) -ceq $before) ($Label + ': files changed.')
}

function Invoke-InstallSpecGroup {
    $g = 'InstallSpec'
    $list = @($realRead.Data.packages)
    Invoke-Check $g 'Add-OneToDecimalString handles carries' {
        foreach ($pair in @(@('0', '1'), @('8', '9'), @('9', '10'), @('19', '20'), @('99', '100'), @('199', '200'), @('1299', '1300'))) {
            Assert-True ((Add-OneToDecimalString -Digits $pair[0]) -ceq $pair[1]) ($pair[0] + ' -> ' + (Add-OneToDecimalString -Digits $pair[0]))
        }
    }
    $expectations = @(
        @('pytest', $null, 'pytest>=8,<9', 'RangeFromList'),
        @('python-pptx', $null, 'python-pptx>=1,<2', 'RangeFromList'),
        @('pyinstaller', $null, 'pyinstaller>=6,<7', 'RangeFromList'),
        @('pyperclip', $null, 'pyperclip>=1,<2', 'RangeFromList'),
        @('pdfplumber', $null, 'pdfplumber==0.10.3', 'FixedFromList'),
        @('pypdf', $null, 'pypdf==6.8.0', 'FixedFromList'),
        @('pywin32', $null, 'pywin32==312', 'FixedFromList'),
        @('playwright', $null, 'playwright', 'AnyVersion'),
        @('pytest', '8.3.5', 'pytest==8.3.5', 'Pinned')
    )
    foreach ($case in $expectations) {
        $caseName = $case[0]; $caseVersion = $case[1]; $caseSpec = $case[2]; $caseMode = $case[3]
        Invoke-Check $g ("Spec for {0} (requested: {1}) is {2} [{3}]" -f $caseName, $caseVersion, $caseSpec, $caseMode) {
            $package = Find-ApprovedPackage -Packages $list -Name $caseName
            $result = Get-PipRequirementSpec -Name $caseName -Package $package -RequestedVersion $caseVersion
            Assert-True ($result.Spec -ceq $caseSpec -and $result.Mode -ceq $caseMode) ('Got ' + $result.Spec + ' [' + $result.Mode + ']')
        }
    }
    Invoke-Check $g 'Range generation for other wildcard shapes keeps the requirements spelling' {
        $cases = @(@('1.2.*', 'x>=1.2,<1.3'), @('0.10.*', 'x>=0.10,<0.11'), @('9.*', 'x>=9,<10'), @('99.*.*', 'x>=99,<100'), @('9.9.*', 'x>=9.9,<9.10'), @('08.*', 'x>=8,<9'))
        foreach ($case in $cases) {
            $package = New-ApprovedPackage -Name 'x' -AllowedVersions @($case[0]) -Purpose '' -Status 'approved' -ApprovedDate '2026-01-02' -Notes ''
            Assert-True ((Get-PipRequirementSpec -Name 'x' -Package $package -RequestedVersion $null).Spec -ceq $case[1]) ($case[0] + ' -> ' + (Get-PipRequirementSpec -Name 'x' -Package $package -RequestedVersion $null).Spec)
        }
        $pytest = Find-ApprovedPackage -Packages $list -Name 'pytest'
        Assert-True ((Get-PipRequirementSpec -Name 'Py_Test' -Package $pytest -RequestedVersion $null).Spec -ceq 'Py_Test>=8,<9') 'The requirements spelling must be kept.'
    }
    Invoke-Check $g 'Several allowed expressions cannot be expressed as one range, so a pin is required' {
        $package = New-ApprovedPackage -Name 'x' -AllowedVersions @('8.*.*', '7.*') -Purpose '' -Status 'approved' -ApprovedDate '2026-01-02' -Notes ''
        $unpinned = Get-PipRequirementSpec -Name 'x' -Package $package -RequestedVersion $null
        Assert-True ($unpinned.Mode -ceq 'NeedsPin' -and $unpinned.Spec -ceq '') 'NeedsPin expected.'
        $pinned = Get-PipRequirementSpec -Name 'x' -Package $package -RequestedVersion '7.4'
        Assert-True ($pinned.Mode -ceq 'Pinned' -and $pinned.Spec -ceq 'x==7.4') 'A pinned version must be passed through.'
    }
    Invoke-Check $g 'The requirements syntax rules from the plan: spaces around ==, inline comments, and normalized duplicates stop' {
        foreach ($case in @(@('package== 1.2.3', 'Format'), @('package ==1.2.3', 'Format'), @('package == 1.2.3', 'Format'), @('package==1.2.3 # comment', 'InlineComment'))) {
            $result = ConvertFrom-RequirementsText -Text ($case[0] + "`r`n")
            Assert-True (@($result.Entries).Count -eq 0 -and @($result.Problems).Count -eq 1 -and $result.Problems[0].Code -ceq $case[1]) ($case[0] + ' -> ' + (@($result.Problems | ForEach-Object { $_.Code }) -join ','))
        }
        $duplicate = ConvertFrom-RequirementsText -Text "types-openpyxl==1.0`r`ntypes_openpyxl==1.0`r`n"
        Assert-True (@($duplicate.Entries).Count -eq 1 -and @($duplicate.Problems).Count -eq 1 -and $duplicate.Problems[0].Code -ceq 'Duplicate') 'The normalized duplicate must stop.'
        $comment = ConvertFrom-RequirementsText -Text "# comment line`r`n"
        Assert-True (@($comment.Problems).Count -eq 0) 'A comment line is allowed.'
    }
    Invoke-Check $g 'ConvertTo-UpdatedRequirementsText changes only the target lines and keeps every line ending' {
        $text = "# top`r`n`r`n  pytest  `n# mid`rPython_PPTX`r`npdfplumber==0.10.3"
        $updates = @([pscustomobject]@{ LineNumber = 3; Name = 'pytest'; Version = '8.4.2' }, [pscustomobject]@{ LineNumber = 5; Name = 'Python_PPTX'; Version = '1.0.2' })
        $result = ConvertTo-UpdatedRequirementsText -Text $text -Updates $updates
        Assert-True ($result -ceq "# top`r`n`r`n  pytest==8.4.2  `n# mid`rPython_PPTX==1.0.2`r`npdfplumber==0.10.3") ('Result: ' + $result.Replace("`r", '<CR>').Replace("`n", '<LF>'))
        Assert-Throws { ConvertTo-UpdatedRequirementsText -Text $text -Updates @([pscustomobject]@{ LineNumber = 3; Name = 'other'; Version = '1.0' }) } 'A name mismatch must throw.'
        Assert-Throws { ConvertTo-UpdatedRequirementsText -Text $text -Updates @([pscustomobject]@{ LineNumber = 99; Name = 'pytest'; Version = '1.0' }) } 'A line number out of range must throw.'
        Assert-Throws { ConvertTo-UpdatedRequirementsText -Text $text -Updates @([pscustomobject]@{ LineNumber = 1; Name = '#'; Version = '1.0' }) } 'A comment line must never be rewritten.'
    }
    Invoke-Check $g 'Update-RequirementsPins keeps the BOM state and line endings, and leaves the file untouched on error' {
        $root = New-DataRoot
        try {
            foreach ($withBom in @($true, $false)) {
                $path = Join-Path $root.Path ('req-' + $withBom + '.txt')
                $original = ConvertTo-TextBytes -Text "# c`r`npytest`r`nother==1.0" -Bom:$withBom
                [System.IO.File]::WriteAllBytes($path, $original)
                Update-RequirementsPins -Path $path -Updates @([pscustomobject]@{ LineNumber = 2; Name = 'pytest'; Version = '8.4.2' })
                $expected = ConvertTo-TextBytes -Text "# c`r`npytest==8.4.2`r`nother==1.0" -Bom:$withBom
                Assert-True ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path)) -ceq [System.Convert]::ToBase64String($expected)) ('Bytes differ (BOM=' + $withBom + ').')
                $before = Get-Sha256 -Path $path
                Assert-Throws { Update-RequirementsPins -Path $path -Updates @([pscustomobject]@{ LineNumber = 2; Name = 'nope'; Version = '1.0' }) } 'A bad update must throw.'
                Assert-True ((Get-Sha256 -Path $path) -ceq $before) 'The file changed after a failed update.'
            }
            Assert-True (@(Get-ChildItem -LiteralPath $root.Path -Force | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) 'A temporary file remains.'
        } finally { Remove-DataRoot -Entry $root }
    }
    Invoke-Check $g 'pip freeze parsing and the before/after difference' {
        $before = ConvertFrom-PipFreezeText -Lines @('pip==24.0', 'Setup_Tools==65.5.0', '-e git+https://x#egg=y', 'WARNING: something', '')
        Assert-True ($before.Count -eq 2 -and $before['setup-tools'] -ceq '65.5.0') 'Parsing failed.'
        $after = ConvertFrom-PipFreezeText -Lines @('pip==24.1', 'setup-tools==65.5.0', 'pytest==8.4.2', 'iniconfig==2.0.0')
        $changes = @(Compare-FreezeSnapshots -Before $before -After $after)
        Assert-True ($changes.Count -eq 3) ('Expected 3 differences but got ' + $changes.Count)
        Assert-True (@($changes | Where-Object { $_.Kind -ceq 'Changed' -and $_.Name -ceq 'pip' }).Count -eq 1) 'pip change.'
        Assert-True (@($changes | Where-Object { $_.Kind -ceq 'Added' }).Count -eq 2) 'Added packages.'
        Assert-True (@(Compare-FreezeSnapshots -Before $before -After $before).Count -eq 0) 'No difference expected.'
    }
}

function Invoke-InstallProjectGroup {
    $g = 'InstallProject'
    $demoText = "pytest`r`n"
    Invoke-Check $g 'Project selection rules: neither or both of -ProjectPath/-SelectProject, a missing or bad -Target, and test-only options without -TestMode all stop' {
        $s = New-Scenario -RuntimeText $demoText
        try {
            $cases = @(
                @('-Target', 'Runtime'),
                @('-ProjectPath', $s.Project, '-SelectProject', '-Target', 'Runtime'),
                @('-ProjectPath', $s.Project),
                @('-ProjectPath', $s.Project, '-Target', 'Everything'),
                @('-ProjectPath', $s.Project, '-Target', 'runtime'),
                @('-SelectProject')
            )
            foreach ($case in $cases) {
                Assert-StopsWithoutInstall -Scenario $s -Arguments $case -Label ($case -join ' ')
            }
            $before = Get-TreeSnapshot -Path $s.Root.Path
            foreach ($extra in @(@('-SkipConfirmation'), @('-ConfirmAnswer', 'N'), @('-TestWorkspaceRoot', $s.Root.Path))) {
                $run = Invoke-ToolProcess -ScriptName 'Install-Packages.ps1' -Arguments (@('-ProjectPath', $s.Project, '-Target', 'Runtime') + $extra)
                Assert-True ($run.ExitCode -eq 1) ('Test-only options without -TestMode must fail: ' + ($extra -join ' '))
            }
            $normal = Invoke-ToolProcess -ScriptName 'Install-Packages.ps1' -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime', '-ValidateOnly')
            Assert-True ($normal.ExitCode -eq 1) 'A project outside the real Projects folder must be rejected in normal mode.'
            $noRoot = Invoke-ToolProcess -ScriptName 'Install-Packages.ps1' -Arguments @('-TestMode', '-ProjectPath', $s.Project, '-Target', 'Runtime')
            Assert-True ($noRoot.ExitCode -eq 1) '-TestMode without -TestWorkspaceRoot must fail.'
            foreach ($badRoot in @($realPaths.WorkspaceRoot, $tempBase, (Join-Path $s.Root.Path 'Projects'))) {
                $run = Invoke-ToolProcess -ScriptName 'Install-Packages.ps1' -Arguments @('-TestMode', '-TestWorkspaceRoot', $badRoot, '-ProjectPath', $s.Project, '-Target', 'Runtime', '-ValidateOnly')
                Assert-True ($run.ExitCode -eq 1) ('An unmarked test root must be rejected: ' + $badRoot)
            }
            Assert-True ((Get-TreeSnapshot -Path $s.Root.Path) -ceq $before) 'Files changed.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'No project is guessed from the current directory, even from inside a project folder' {
        $s = New-Scenario -RuntimeText $demoText
        try {
            $run = Invoke-Install -Root $s.Root -Arguments @('-Target', 'Runtime', '-ValidateOnly') -WorkingDirectory $s.Project
            Assert-True ($run.ExitCode -eq 1) 'Running without a project from inside a project must fail.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $s.Root.Path 'pip.log'))) 'pip was called.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g '-ProjectPath rejections: not under Projects, template, non-Project names, missing, file, link, nested, outside' {
        $s = New-Scenario -RuntimeText $demoText
        try {
            $projects = Join-Path $s.Root.Path 'Projects'
            [void](New-Item -ItemType Directory -Path (Join-Path $projects '_Template_Python'))
            [void](New-Item -ItemType Directory -Path (Join-Path $projects 'Other'))
            [void](New-Item -ItemType Directory -Path (Join-Path $s.Project 'sub'))
            [System.IO.File]::WriteAllText((Join-Path $projects 'Project File'), 'x')
            $linkTarget = Join-Path $s.Root.Path 'linktarget'
            [void](New-Item -ItemType Directory -Path $linkTarget)
            $link = Join-Path $projects 'Project Link'
            & cmd.exe /c ('mklink /J "' + $link + '" "' + $linkTarget + '"') | Out-Null
            $outside = New-DataRoot
            [void](New-Item -ItemType Directory -Path (Join-Path $outside.Path 'Project Z'))
            $candidates = @($s.Root.Path, $projects, (Join-Path $projects '_Template_Python'), (Join-Path $projects 'Other'), (Join-Path $projects 'Project Nope'),
                (Join-Path $projects 'Project File'), $link, (Join-Path $s.Project 'sub'), (Join-Path $outside.Path 'Project Z'), ($s.Project + '\..\Other'))
            foreach ($candidate in $candidates) {
                $before = Get-TreeSnapshot -Path $s.Root.Path
                $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $candidate, '-Target', 'Runtime', '-ValidateOnly')
                Assert-True ($run.ExitCode -eq 1) ('Expected a rejection for: ' + $candidate)
                Assert-True ((Get-TreeSnapshot -Path $s.Root.Path) -ceq $before) 'Files changed.'
            }
            $ok = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime', '-ValidateOnly')
            Assert-True ($ok.ExitCode -eq 0) 'The valid project must pass.'
            $upper = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project.ToUpperInvariant(), '-Target', 'Runtime', '-ValidateOnly')
            Assert-True ($upper.ExitCode -eq 0) 'A different letter case of the same folder must pass (Windows).'
            Assert-True (@(Get-PipLogLines -Root $s.Root).Count -eq 0) 'pip was called.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'A relative -ProjectPath works from the workspace root; Japanese and spaces in the folder name work' {
        $s = New-Scenario -RuntimeText $demoText
        try {
            $relative = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', '.\Projects\Project Demo', '-Target', 'Runtime', '-ValidateOnly') -WorkingDirectory $s.Root.Path
            Assert-True ($relative.ExitCode -eq 0) ('Relative path exit code ' + $relative.ExitCode + ': ' + $relative.Output)
            $japaneseName = 'Project ' + [char]0x90E8 + [char]0x54C1 + ' ' + [char]0x30C6 + [char]0x30B9 + [char]0x30C8
            $japanese = New-TestProject -Root $s.Root -FolderName $japaneseName -RuntimeBytes (ConvertTo-TextBytes -Text "pytest`r`n")
            Copy-Item -LiteralPath (Get-FakePython) -Destination (Join-Path (New-Item -ItemType Directory -Path (Join-Path $japanese '.venv\Scripts') -Force).FullName 'python.exe')
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $japanese, '-Target', 'Runtime', '-ValidateOnly')
            Assert-True ($run.ExitCode -eq 0) ('Japanese path exit code ' + $run.ExitCode)
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g '-SelectProject lists only visible Project folders and selects by number' {
        $s = New-Scenario -RuntimeText $demoText
        try {
            $projects = Join-Path $s.Root.Path 'Projects'
            Remove-Item -LiteralPath $s.Project -Recurse -Force
            [void](New-TestProject -Root $s.Root -FolderName 'Project B' -RuntimeBytes (ConvertTo-TextBytes -Text "pytest`r`n"))
            [void](New-TestProject -Root $s.Root -FolderName 'Project A' -RuntimeBytes (ConvertTo-TextBytes -Text "pytest`r`n"))
            foreach ($other in @('_Template_Python', '_Template_Combined', 'Other', 'Project Hidden')) { [void](New-Item -ItemType Directory -Path (Join-Path $projects $other)) }
            [System.IO.File]::SetAttributes((Join-Path $projects 'Project Hidden'), ([System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::Hidden))
            [System.IO.File]::WriteAllText((Join-Path $projects 'Project File'), 'x')
            $linkTarget = Join-Path $s.Root.Path 'linktarget'
            [void](New-Item -ItemType Directory -Path $linkTarget)
            & cmd.exe /c ('mklink /J "' + (Join-Path $projects 'Project Link') + '" "' + $linkTarget + '"') | Out-Null
            $nl = "`r`n"
            $run = Invoke-Install -Root $s.Root -Arguments @('-SelectProject', '-Target', 'Runtime', '-ValidateOnly') -InputText ('2' + $nl)
            Assert-True ($run.ExitCode -eq 0) ('Exit code ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
            foreach ($visible in @('Project A', 'Project B')) { Assert-True ($run.Output.Contains($visible)) ('The list must show: ' + $visible) }
            foreach ($hidden in @('Project Hidden', '_Template', 'Other', 'Project File', 'Project Link')) { Assert-True (-not $run.Output.Contains($hidden)) ('The list must not show: ' + $hidden) }
            Assert-True ($run.Output.Contains('Projects\Project B') -and -not $run.Output.Contains('Projects\Project A')) 'Entry 2 must select Project B.'
            $first = Invoke-Install -Root $s.Root -Arguments @('-SelectProject', '-Target', 'Runtime', '-ValidateOnly') -InputText ('1' + $nl)
            Assert-True ($first.ExitCode -eq 0 -and $first.Output.Contains('Projects\Project A')) 'Entry 1 must select Project A.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g '-SelectProject rejects non-numbers, 0, out-of-range, negative, and Enter, then accepts a valid number; end of input stops' {
        $s = New-Scenario -RuntimeText $demoText
        try {
            $nl = "`r`n"
            $run = Invoke-Install -Root $s.Root -Arguments @('-SelectProject', '-Target', 'Runtime', '-ValidateOnly') -InputText ('x' + $nl + '0' + $nl + '99' + $nl + $nl + '-1' + $nl + '1.5' + $nl + '1' + $nl)
            Assert-True ($run.ExitCode -eq 0 -and $run.Output.Contains('Projects\Project Demo')) ('Exit code ' + $run.ExitCode)
            $eof = Invoke-Install -Root $s.Root -Arguments @('-SelectProject', '-Target', 'Runtime', '-ValidateOnly') -InputText ('x' + $nl)
            Assert-True ($eof.ExitCode -eq 1) 'End of input must stop with exit code 1 (no endless loop).'
            $closed = Invoke-Install -Root $s.Root -Arguments @('-SelectProject', '-Target', 'Runtime', '-ValidateOnly')
            Assert-True ($closed.ExitCode -eq 1) 'A closed standard input must stop with exit code 1.'
            Assert-True (@(Get-PipLogLines -Root $s.Root).Count -eq 0) 'pip was called.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g '-SelectProject: no selectable project, or a selected project without .venv or requirements, stops without changes' {
        $s = New-Scenario -RuntimeText $demoText -NoVenv
        try {
            $nl = "`r`n"
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-SelectProject', '-Target', 'Runtime') -InputText ('1' + $nl) -Label 'no .venv'
            Remove-Item -LiteralPath $s.Project -Recurse -Force
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-SelectProject', '-Target', 'Runtime') -InputText ('1' + $nl) -Label 'no projects'
            [void](New-TestProject -Root $s.Root -FolderName 'Project Bare')
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-SelectProject', '-Target', 'Runtime') -InputText ('1' + $nl) -Label 'no requirements'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'Function level: Assert-ProjectFolder and Get-SelectableProjects apply the folder rules' {
        $s = New-Scenario -RuntimeText $demoText
        try {
            $projects = Join-Path $s.Root.Path 'Projects'
            $found = Assert-ProjectFolder -FullPath $s.Project -ProjectsRoot $projects
            Assert-True ($found.Name -ceq 'Project Demo') 'The valid project must be accepted.'
            Assert-Throws { Assert-ProjectFolder -FullPath (Join-Path $projects 'Project Nope') -ProjectsRoot $projects } 'A missing folder must be rejected.'
            Assert-Throws { Assert-ProjectFolder -FullPath $projects -ProjectsRoot $projects } 'The Projects folder itself must be rejected.'
            $names = @(Get-SelectableProjects -ProjectsRoot $projects | ForEach-Object { $_.Name })
            Assert-True (($names -join '|') -ceq 'Project Demo') ('Selectable: ' + ($names -join ','))
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'Function level: a project folder replaced after the list was shown is detected' {
        $s = New-Scenario -RuntimeText $demoText
        try {
            $projects = Join-Path $s.Root.Path 'Projects'
            $script:SwapTarget = $s.Project
            function Read-UserInput {
                param([string]$Prompt)
                [System.IO.Directory]::Delete($script:SwapTarget, $true)
                [void](New-Item -ItemType Directory -Path $script:SwapTarget)
                [System.IO.Directory]::SetCreationTimeUtc($script:SwapTarget, (Get-Date).AddDays(-400).ToUniversalTime())
                return '1'
            }
            Assert-Throws { Select-ProjectFromList -ProjectsRoot $projects } 'A replaced folder must be detected.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
}

function Invoke-InstallRunGroup {
    $g = 'InstallRun'
    $runtimeText = "# runtime packages`r`n`r`npytest`r`npdfplumber==0.10.3`r`nPython_PPTX`r`n"
    Invoke-Check $g 'Runtime: one pip call with only direct dependencies; specs are range, pinned, and range; recorded arguments are shown' {
        $s = New-Scenario -RuntimeText $runtimeText -DevText "pyinstaller`r`n"
        try {
            $devBefore = Get-Sha256 -Path $s.Dev
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime')
            Assert-True ($run.ExitCode -eq 0) ('Exit code ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
            $log = @(Get-PipLogLines -Root $s.Root)
            Write-Host ('    recorded fake python calls: ' + ($log -join '  ||  '))
            Assert-True ($log.Count -eq 3) ('Expected freeze, install, freeze but got ' + $log.Count)
            Assert-True ($log[0] -ceq 'ARGS|-m|pip|freeze' -and $log[2] -ceq 'ARGS|-m|pip|freeze') 'The freeze calls are missing.'
            Assert-True ($log[1] -ceq 'ARGS|-m|pip|install|pytest>=8,<9|pdfplumber==0.10.3|Python_PPTX>=1,<2') ('Install call: ' + $log[1])
            $installArgs = @($log[1].Split('|') | Select-Object -Skip 1)
            Assert-True (@($installArgs | Where-Object { $_.StartsWith('-') }).Count -eq 1) 'Only -m may start with a dash (no pip options).'
            foreach ($forbidden in @('--trusted-host', '--upgrade', '-U', '--index-url', '--cert', '--proxy', '--no-verify', '-r', '-e')) { Assert-True ($installArgs -cnotcontains $forbidden) ('Forbidden argument: ' + $forbidden) }
            Assert-True ((Get-Sha256 -Path $s.Dev) -ceq $devBefore) 'The development requirements file must not be touched for Target Runtime.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'After success: only unversioned lines are pinned to the installed version; comments, blank lines, and order stay; transitive packages are not added' {
        $s = New-Scenario -RuntimeText $runtimeText
        try {
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime')
            Assert-True ($run.ExitCode -eq 0) ('Exit code ' + $run.ExitCode)
            $after = [System.IO.File]::ReadAllText($s.Runtime)
            Assert-True ($after -ceq "# runtime packages`r`n`r`npytest==8.4.2`r`npdfplumber==0.10.3`r`nPython_PPTX==1.0.2`r`n") ('Requirements: ' + $after.Replace("`r`n", '<CRLF>'))
            Assert-True ($after -notmatch 'iniconfig') 'A transitive dependency was added.'
            Assert-True ((Get-StateText -Root $s.Root).Contains('iniconfig==2.0.0')) 'The fake transitive dependency was not installed.'
            Assert-True ($run.Output.Contains('iniconfig==2.0.0')) 'The installed-package list (pip freeze) is not shown.'
            $bytes = [System.IO.File]::ReadAllBytes($s.Runtime)
            Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF)) 'A BOM was added.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    $variants = @(
        @{ Label = 'BOM, CRLF, no trailing newline'; Bom = $true; Before = "# c`r`npytest`r`n`r`npdfplumber==0.10.3"; After = "# c`r`npytest==8.4.2`r`n`r`npdfplumber==0.10.3" },
        @{ Label = 'LF only, indentation and trailing spaces, trailing newline'; Bom = $false; Before = "  pytest  `n# note`n`n"; After = "  pytest==8.4.2  `n# note`n`n" },
        @{ Label = 'mixed CR, LF, and CRLF'; Bom = $false; Before = "pytest`r`n# a`npdfplumber==0.10.3`rPython_PPTX`n"; After = "pytest==8.4.2`r`n# a`npdfplumber==0.10.3`rPython_PPTX==1.0.2`n" },
        @{ Label = 'Japanese comment (UTF-8)'; Bom = $false; Before = ("# " + [char]0x65E5 + [char]0x672C + [char]0x8A9E + "`r`npytest`r`n"); After = ("# " + [char]0x65E5 + [char]0x672C + [char]0x8A9E + "`r`npytest==8.4.2`r`n") }
    )
    foreach ($variant in $variants) {
        $variantLabel = $variant.Label; $variantBom = $variant.Bom; $variantBefore = $variant.Before; $variantAfter = $variant.After
        Invoke-Check $g ('Rewrite keeps the file format: ' + $variantLabel) {
            $s = New-Scenario -RuntimeText 'x'
            try {
                [System.IO.File]::WriteAllBytes($s.Runtime, (ConvertTo-TextBytes -Text $variantBefore -Bom:$variantBom))
                $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime')
                Assert-True ($run.ExitCode -eq 0) ('Exit code ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
                $expected = ConvertTo-TextBytes -Text $variantAfter -Bom:$variantBom
                Assert-True ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($s.Runtime)) -ceq [System.Convert]::ToBase64String($expected)) 'The rewritten bytes differ from the expected bytes.'
            } finally { Remove-DataRoot -Entry $s.Root }
        }
    }
    Invoke-Check $g 'Target Development uses only requirements-dev.txt; Target All uses both files in one pip call and rewrites each file separately' {
        $s = New-Scenario -RuntimeText "pytest`r`npdfplumber`r`n" -DevText "# dev tools`r`npyinstaller`r`n"
        try {
            $dev = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Development')
            Assert-True ($dev.ExitCode -eq 0) 'Development failed.'
            $call = @(Get-InstallCallLines -Root $s.Root)
            Assert-True ($call.Count -eq 1 -and $call[0] -ceq 'ARGS|-m|pip|install|pyinstaller>=6,<7') ('Development call: ' + ($call -join ';'))
            Assert-True ([System.IO.File]::ReadAllText($s.Dev) -ceq "# dev tools`r`npyinstaller==6.11.1`r`n") 'The dev file was not pinned.'
            Assert-True ([System.IO.File]::ReadAllText($s.Runtime) -ceq "pytest`r`npdfplumber`r`n") 'The runtime file must not change.'
        } finally { Remove-DataRoot -Entry $s.Root }
        $s = New-Scenario -RuntimeText "pytest`r`npdfplumber`r`n" -DevText "# dev tools`r`npyinstaller`r`n"
        try {
            $all = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'All')
            Assert-True ($all.ExitCode -eq 0) ('All failed: ' + $all.Output)
            $call = @(Get-InstallCallLines -Root $s.Root)
            Assert-True ($call.Count -eq 1 -and $call[0] -ceq 'ARGS|-m|pip|install|pytest>=8,<9|pdfplumber==0.10.3|pyinstaller>=6,<7') ('All call: ' + ($call -join ';'))
            Write-Host ('    recorded install call (All): ' + $call[0])
            Assert-True ([System.IO.File]::ReadAllText($s.Runtime) -ceq "pytest==8.4.2`r`npdfplumber==0.10.3`r`n") 'The runtime file was not pinned correctly.'
            Assert-True ([System.IO.File]::ReadAllText($s.Dev) -ceq "# dev tools`r`npyinstaller==6.11.1`r`n") 'The dev file was not pinned correctly.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'Fixed and wildcard specs for the remaining approved packages (pypdf, pywin32, pyperclip) and an already pinned file' {
        $s = New-Scenario -RuntimeText "pypdf`r`npywin32`r`npyperclip`r`n"
        try {
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime')
            Assert-True ($run.ExitCode -eq 0) 'Failed.'
            Assert-True (@(Get-InstallCallLines -Root $s.Root)[0] -ceq 'ARGS|-m|pip|install|pypdf==6.8.0|pywin32==312|pyperclip>=1,<2') ('Call: ' + @(Get-InstallCallLines -Root $s.Root)[0])
            Assert-True ([System.IO.File]::ReadAllText($s.Runtime) -ceq "pypdf==6.8.0`r`npywin32==312`r`npyperclip==1.9.0`r`n") 'Pins.'
        } finally { Remove-DataRoot -Entry $s.Root }
        $s = New-Scenario -RuntimeText "pytest==8.3.5`r`npdfplumber==0.10.3`r`n"
        try {
            $before = Get-Sha256 -Path $s.Runtime
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime')
            Assert-True ($run.ExitCode -eq 0) 'Pinned run failed.'
            Assert-True (@(Get-InstallCallLines -Root $s.Root)[0] -ceq 'ARGS|-m|pip|install|pytest==8.3.5|pdfplumber==0.10.3') 'Pinned versions must be kept (not upgraded within the range).'
            Assert-True ((Get-Sha256 -Path $s.Runtime) -ceq $before) 'A fully pinned file must not be rewritten.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'An empty requirements file installs nothing (no pip call, exit code 0)' {
        $s = New-Scenario -RuntimeText "# nothing yet`r`n"
        try {
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime')
            Assert-True ($run.ExitCode -eq 0) 'Exit code.'
            Assert-True (@(Get-PipLogLines -Root $s.Root).Count -eq 0) 'pip was called.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'pip failure (exit 1): treated as failure, requirements unchanged, error output shown, no uninstall or rollback' {
        $s = New-Scenario -RuntimeText $runtimeText
        try {
            $before = Get-TreeSnapshot -Path $s.Project
            $stateBefore = Get-StateText -Root $s.Root
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -Extra @{ FAKE_PIP_MODE = 'fail' }
            Assert-True ($run.ExitCode -eq 1) ('Exit code ' + $run.ExitCode)
            Assert-True ($run.Output.Contains('ERROR: fake pip failure')) 'The pip error output was hidden.'
            Assert-True ((Get-TreeSnapshot -Path $s.Project) -ceq $before) 'The project changed.'
            Assert-True ((Get-StateText -Root $s.Root) -ceq $stateBefore) 'The installed packages changed.'
            $log = @(Get-PipLogLines -Root $s.Root)
            Assert-True (@($log | Where-Object { $_ -match 'uninstall' }).Count -eq 0) 'An uninstall was attempted.'
            Assert-True (@(Get-InstallCallLines -Root $s.Root).Count -eq 1) 'Exactly one install call is expected.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'Partial pip failure: requirements unchanged, the first package stays installed (no rollback), and the difference is reported' {
        $s = New-Scenario -RuntimeText $runtimeText
        try {
            $before = Get-TreeSnapshot -Path $s.Project
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -Extra @{ FAKE_PIP_MODE = 'fail-partial' }
            Assert-True ($run.ExitCode -eq 1) ('Exit code ' + $run.ExitCode)
            Assert-True ((Get-TreeSnapshot -Path $s.Project) -ceq $before) 'The requirements changed.'
            $state = Get-StateText -Root $s.Root
            Assert-True ($state.Contains('pytest==8.4.2')) 'The partially installed package must remain.'
            Assert-True ($run.Output -match 'pytest: .* -> 8\.4\.2') 'The difference report must list the added package with its version.'
            $log = @(Get-PipLogLines -Root $s.Root)
            Assert-True (@($log | Where-Object { $_ -match 'uninstall' }).Count -eq 0) 'An uninstall was attempted.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'pip succeeded but the result cannot be confirmed: nothing is rewritten (missing package, out-of-range version, unsupported version format, freeze failures)' {
        $cases = @(
            @{ Extra = @{ FAKE_PIP_MODE = 'skip-record' }; Resolve = $null; Label = 'package missing after install' },
            @{ Extra = @{ FAKE_PIP_FREEZE_MODE = 'fail-after-install' }; Resolve = $null; Label = 'freeze fails after install' },
            @{ Extra = @{}; Resolve = @('pytest=9.0.0', 'python-pptx=1.0.2'); Label = 'installed version outside the allowed range' },
            @{ Extra = @{}; Resolve = @('pytest=8.4.2.post1', 'python-pptx=1.0.2'); Label = 'installed version with an unsupported format' }
        )
        foreach ($case in $cases) {
            $s = New-Scenario -RuntimeText $runtimeText
            try {
                if ($null -ne $case.Resolve) { Initialize-FakeFiles -Root $s.Root -State @('pip==24.0') -Resolve $case.Resolve -Transitive @() }
                $before = Get-Sha256 -Path $s.Runtime
                $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -Extra $case.Extra
                Assert-True ($run.ExitCode -eq 1) ($case.Label + ': exit code ' + $run.ExitCode)
                Assert-True ((Get-Sha256 -Path $s.Runtime) -ceq $before) ($case.Label + ': the requirements changed.')
            } finally { Remove-DataRoot -Entry $s.Root }
        }
    }
    Invoke-Check $g 'A freeze failure before installing stops before any install call' {
        $s = New-Scenario -RuntimeText $runtimeText
        try {
            $before = Get-Sha256 -Path $s.Runtime
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -Extra @{ FAKE_PIP_FREEZE_MODE = 'fail' }
            Assert-True ($run.ExitCode -eq 1) 'Exit code.'
            Assert-True (@(Get-InstallCallLines -Root $s.Root).Count -eq 0) 'pip install was called.'
            Assert-True ((Get-Sha256 -Path $s.Runtime) -ceq $before) 'The requirements changed.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'allowedVersions [] (playwright): warning and explicit confirmation; N, Enter, or declining the final question stops; Y proceeds with no version given to pip' {
        $nl = "`r`n"
        $s = New-Scenario -RuntimeText "playwright`r`n"
        try {
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime', '-ConfirmAnswer', 'N') -ExpectedExit 2 -Label 'ConfirmAnswer N'
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -ExpectedExit 2 -InputText $nl -Label 'Enter only'
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -ExpectedExit 2 -InputText ('N' + $nl) -Label 'N'
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -ExpectedExit 2 -InputText ('Y' + $nl + 'N' + $nl) -Label 'Y then N'
            Assert-True (@(Get-PipLogLines -Root $s.Root).Count -eq 0) 'pip was called although the user did not agree.'
            $run = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -InputText ('Y' + $nl + 'Y' + $nl)
            Assert-True ($run.ExitCode -eq 0) ('Exit code ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
            Assert-True (@(Get-InstallCallLines -Root $s.Root)[0] -ceq 'ARGS|-m|pip|install|playwright') ('Install call: ' + @(Get-InstallCallLines -Root $s.Root)[0])
            Assert-True ([System.IO.File]::ReadAllText($s.Runtime) -ceq "playwright==1.58.0`r`n") 'The installed version was not pinned.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
}

function Invoke-InstallStopGroup {
    $g = 'InstallStops'
    $okRuntime = "pytest`r`n"
    function New-Custom { param([string]$Status, [string[]]$Versions) $date = ''; if ($Status -ceq 'approved') { $date = '2026-01-02' }; return @((New-ApprovedPackage -Name 'pytest' -AllowedVersions $Versions -Purpose '' -Status $Status -ApprovedDate $date -Notes '')) }
    $cases = @(
        @{ Label = 'approved list file is missing'; Runtime = $okRuntime; Setup = { param($s) Remove-Item -LiteralPath (Join-Path $s.Root.Path 'ApprovedPackages\approved-packages.json') -Force } },
        @{ Label = 'approved list is not valid JSON'; Runtime = $okRuntime; Setup = { param($s) [System.IO.File]::WriteAllText((Join-Path $s.Root.Path 'ApprovedPackages\approved-packages.json'), '{ broken', (New-Object System.Text.UTF8Encoding($false))) } },
        @{ Label = 'approved list has a bad schema'; Runtime = $okRuntime; Setup = { param($s) [System.IO.File]::WriteAllText((Join-Path $s.Root.Path 'ApprovedPackages\approved-packages.json'), '{ "schemaVersion": 2, "packages": [] }', (New-Object System.Text.UTF8Encoding($false))) } },
        @{ Label = 'unregistered package'; Runtime = "notregistered`r`n"; Setup = { param($s) } },
        @{ Label = 'status pending'; Runtime = $okRuntime; Setup = { param($s) Set-ApprovedListForRoot -Root $s.Root -Packages (New-Custom -Status 'pending' -Versions @('8.*.*')) } },
        @{ Label = 'status deprecated'; Runtime = $okRuntime; Setup = { param($s) Set-ApprovedListForRoot -Root $s.Root -Packages (New-Custom -Status 'deprecated' -Versions @('8.*.*')) } },
        @{ Label = 'status disabled'; Runtime = $okRuntime; Setup = { param($s) Set-ApprovedListForRoot -Root $s.Root -Packages (New-Custom -Status 'disabled' -Versions @('8.*.*')) } },
        @{ Label = 'pinned version outside the allowed range'; Runtime = "pytest==9.0.0`r`n"; Setup = { param($s) } },
        @{ Label = 'pinned version differs from a fixed allowed version'; Runtime = "pdfplumber==0.10.4`r`n"; Setup = { param($s) } },
        @{ Label = 'unsupported syntax (>=)'; Runtime = "pytest>=8`r`n"; Setup = { param($s) } },
        @{ Label = 'unsupported version text (rc)'; Runtime = "pytest==8.3.5rc1`r`n"; Setup = { param($s) } },
        @{ Label = 'several problem lines at once'; Runtime = "pytest == 1`r`npkg==1.0 # c`r`ntypes-x==1`r`ntypes_x==1`r`n-e .`r`n"; Setup = { param($s) } },
        @{ Label = 'several allowed expressions and no pin'; Runtime = $okRuntime; Setup = { param($s) Set-ApprovedListForRoot -Root $s.Root -Packages (New-Custom -Status 'approved' -Versions @('8.*.*', '7.*')) } },
        @{ Label = 'one blocked package stops the valid ones too'; Runtime = "pytest==8.3.5`r`nnotregistered`r`n"; Setup = { param($s) } },
        @{ Label = 'requirements is not valid UTF-8'; Runtime = $null; Setup = { param($s) [System.IO.File]::WriteAllBytes($s.Runtime, [byte[]](0x70, 0xFF, 0xFE, 0x0D, 0x0A)) } }
    )
    foreach ($case in $cases) {
        $caseLabel = $case.Label; $caseRuntime = $case.Runtime; $caseSetup = $case.Setup
        Invoke-Check $g ('Stops without installing: ' + $caseLabel) {
            if ($null -eq $caseRuntime) { $s = New-Scenario -RuntimeText 'pytest' } else { $s = New-Scenario -RuntimeText $caseRuntime }
            try {
                & $caseSetup $s
                Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -Label $caseLabel
            } finally { Remove-DataRoot -Entry $s.Root }
        }
    }
    Invoke-Check $g 'Stops without installing: no .venv; missing requirements for the target; Target All with one file missing; the same package in both files' {
        $s = New-Scenario -RuntimeText $okRuntime -NoVenv
        try { Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -Label 'no venv' } finally { Remove-DataRoot -Entry $s.Root }
        $s = New-Scenario -RuntimeText $null -DevText "pyinstaller`r`n"
        try {
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -Label 'runtime file missing'
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'All') -Label 'All with runtime missing'
        } finally { Remove-DataRoot -Entry $s.Root }
        $s = New-Scenario -RuntimeText $okRuntime -DevText $null
        try { Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'All') -Label 'All with dev missing' } finally { Remove-DataRoot -Entry $s.Root }
        $s = New-Scenario -RuntimeText $okRuntime -DevText "Pytest`r`n"
        try { Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'All') -Label 'same package in both files' } finally { Remove-DataRoot -Entry $s.Root }
    }
    Invoke-Check $g 'Declining the final question (N, Enter, or -ConfirmAnswer N) stops with exit code 2 and changes nothing' {
        $nl = "`r`n"
        $s = New-Scenario -RuntimeText $okRuntime
        try {
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime', '-ConfirmAnswer', 'N') -ExpectedExit 2 -Label 'ConfirmAnswer N'
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -ExpectedExit 2 -InputText $nl -Label 'Enter only'
            Assert-StopsWithoutInstall -Scenario $s -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -ExpectedExit 2 -InputText ('N' + $nl) -Label 'N'
            Assert-True (@(Get-PipLogLines -Root $s.Root).Count -eq 0) 'pip was called.'
            $yes = Invoke-Install -Root $s.Root -Arguments @('-ProjectPath', $s.Project, '-Target', 'Runtime') -InputText ('Y' + $nl)
            Assert-True ($yes.ExitCode -eq 0) 'Answering Y must install.'
        } finally { Remove-DataRoot -Entry $s.Root }
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

try {
    Invoke-DataGroup
    Invoke-NamesGroup
    Invoke-VersionsGroup
    Invoke-DecisionsGroup
    Invoke-RequirementsGroup
    Invoke-ValidationGroup
    Invoke-WriteGroup
    Invoke-MarkdownGroup
    Invoke-ManageGroup
    Invoke-ToolsGroup
    Invoke-InstallSpecGroup
    Invoke-InstallProjectGroup
    Invoke-InstallRunGroup
    Invoke-InstallStopGroup
    Invoke-ValidateOnlyGroup
    Invoke-Check 'Safety' 'The real approved-packages files are unchanged by this test' {
        Assert-True ((Get-Sha256 -Path $realPaths.JsonPath) -ceq $realBefore.Json) 'approved-packages.json changed.'
        Assert-True ((Get-Sha256 -Path $realPaths.MarkdownPath) -ceq $realBefore.Md) 'approved-packages.md changed.'
        Assert-True (@(Get-ChildItem -LiteralPath $realPaths.DataDirectory -Force | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) 'A temporary file remains in the real folder.'
    }
} finally {
    foreach ($entry in @($script:CreatedRoots)) {
        try { Remove-DataRoot -Entry $entry } catch { Write-Host ('Cleanup failed: ' + $_.Exception.Message) -ForegroundColor Red }
    }
}
Invoke-Check 'Safety' 'No temporary test folder remains under TEMP' {
    $left = @(Get-ChildItem -LiteralPath $tempBase -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'approved-packages-test-*' -or $_.Name -like 'approved-packages-unmarked-*' })
    Assert-True ($left.Count -eq 0) ('Remaining: ' + (($left | ForEach-Object { $_.Name }) -join ', '))
}

$pass = @($script:Results | Where-Object { $_.Status -eq 'Pass' }).Count
$fail = @($script:Results | Where-Object { $_.Status -eq 'Fail' }).Count
$notReady = @($script:Results | Where-Object { $_.Status -eq 'NotReady' }).Count
Write-Host ''
Write-Host (Get-ToolMessage -Messages $toolMessages -Key 'TestSummary' -FormatArgs @($pass, $fail, $notReady))
if ($fail -gt 0) { exit 1 }
exit 0
