<#
.SYNOPSIS
    Tests the approved-package tools and the initial approved package list.

.DESCRIPTION
    Uses only temporary files under %TEMP% (created and removed by this test), never installs packages,
    never uses the network, never runs git, and never changes the real ApprovedPackages folder.
    Results are Pass, Fail, or NotReady. The exit code is 1 only when a check Fails.
    Checks that depend on Install-Packages.ps1 (a later step) are reported as NotReady.
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

$script:TestRequiredKeys = @('ErrorPrefix', 'TestStart', 'TestSummary', 'TestFatal')
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:CreatedRoots = @()
$realPaths = Get-ApprovedPackagesPaths
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$jaAnyVersionNote = [regex]::Unescape('\u8a31\u53ef\u30d0\u30fc\u30b8\u30e7\u30f3\u306e\u6307\u5b9a\u306a\u3057')
$expectedOrder = @('pdfplumber', 'playwright', 'pyinstaller', 'pypdf', 'pyperclip', 'pytest', 'python-pptx', 'pywin32')
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
    [System.IO.Directory]::Delete($root, $true)
    $script:CreatedRoots = @($script:CreatedRoots | Where-Object { $_.Path -ne $Entry.Path })
}

function Invoke-ToolProcess {
    param(
        [string]$ScriptName,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$InputText
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
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root.Path 'approved-packages.md'))) 'The document was written after declining.'
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
    $scripts = @('ApprovedPackages.Common.ps1', 'Manage-ApprovedPackage.ps1', 'Update-ApprovedPackagesDocument.ps1', 'Test-ApprovedPackages.ps1')
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
        Assert-True (@($names | Where-Object { $_ -like 'Inst*' }).Count -eq 0) 'Install-Packages keys belong to the later step.'
    }
    Invoke-Check $g 'Every message key used in the tool sources is declared as required by that tool' {
        $manageText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'Manage-ApprovedPackage.ps1')).Text
        $used = @([regex]::Matches($manageText, "Get-MgrMsg\s+'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        foreach ($key in $used) { Assert-True ($script:ManageRequiredKeys -ccontains $key) ('Manage uses an undeclared key: ' + $key) }
        $updateText = (Get-FileFacts -Path (Join-Path $toolsDirectory 'Update-ApprovedPackagesDocument.ps1')).Text
        $updateUsed = @([regex]::Matches($updateText, "Get-UpdMsg\s+'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $updateList = [regex]::Match($updateText, '(?s)\$script:UpdateRequiredKeys = @\((.*?)\r?\n\)').Groups[1].Value
        foreach ($key in $updateUsed) { Assert-True ($updateList.Contains("'" + $key + "'")) ('Update uses an undeclared key: ' + $key) }
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
        foreach ($name in @('ApprovedPackages.Common.ps1', 'Manage-ApprovedPackage.ps1', 'Update-ApprovedPackagesDocument.ps1')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $toolsDirectory $name), (New-Object System.Text.UTF8Encoding($false)))
            $errors = $null
            $tokens = [System.Management.Automation.PSParser]::Tokenize($text, [ref]$errors)
            foreach ($token in $tokens) {
                if ($token.Type -eq 'Command') {
                    Assert-True ($forbiddenCommands -inotcontains $token.Content) ($name + ' calls a forbidden command: ' + $token.Content)
                }
                if ($token.Type -eq 'String' -or $token.Type -eq 'CommandArgument') {
                    Assert-True ($token.Content -notmatch '(?i)ExecutionPolicy|Bypass|git\s+(add|commit|push|tag|remote)') ($name + ' mentions a forbidden operation in code.')
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
        $names = @(Get-ChildItem -LiteralPath $realPaths.DataDirectory -Force | ForEach-Object { $_.Name } | Sort-Object)
        Assert-True (($names -join '|') -ceq 'approved-packages.json|approved-packages.md') ('Unexpected files: ' + ($names -join ', '))
    }
}

function Invoke-ValidateOnlyGroup {
    $g = 'ValidateOnly'
    $installScript = Join-Path $toolsDirectory 'Install-Packages.ps1'
    $reason = 'Install-Packages.ps1 is created in a later step; these checks run there.'
    if (Test-Path -LiteralPath $installScript -PathType Leaf) { $reason = 'Install-Packages.ps1 exists but its checks are not part of this test yet.' }
    foreach ($item in @(
            '-ValidateOnly leaves .venv unchanged',
            '-ValidateOnly leaves requirements files unchanged',
            '-ValidateOnly leaves the approved list unchanged',
            '-ValidateOnly leaves the Git state unchanged (checked through file and .git hashes)',
            '-ValidateOnly leaves installed packages unchanged',
            '-ValidateOnly shows the install plan without installing')) {
        Add-NotReady -GroupName $g -CheckName $item -Reason $reason
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
