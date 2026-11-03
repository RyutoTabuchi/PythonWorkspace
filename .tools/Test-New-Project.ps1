<#
.SYNOPSIS
    Tests New-Project.ps1 and its template without touching the real Projects folder.

.DESCRIPTION
    Groups:
      Unit        - function-level checks (no .venv, no project creation)
      Tasks       - checks of .vscode\tasks.json (reported as NotReady until it is officially enabled)
      Integration - project creation in a unique folder under %TEMP% (creates a .venv there,
                    never installs packages, never uses the network)
      All         - runs all groups (default)

    Results are Pass, Fail, or NotReady. The exit code is 1 only when a check Fails.
    Requires Windows PowerShell 5.1 or later.
#>
[CmdletBinding()]
param(
    [ValidateSet('Unit', 'Tasks', 'Integration', 'All')]
    [string]$Group = 'All',
    [string]$IntegrationPythonPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$newProjectScript = Join-Path $PSScriptRoot 'New-Project.ps1'
$messagesFile = Join-Path $PSScriptRoot 'New-Project.messages.json'
$templateRoot = Join-Path $workspaceRoot 'Projects\_Template_Python'
$tasksFile = Join-Path $workspaceRoot '.vscode\tasks.json'
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Set to $true when .vscode\tasks.json has been updated for the new tools.
$script:TasksGroupReady = $false
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:CreatedRoots = @()

. $newProjectScript
Import-Messages -Path $messagesFile

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------

function Invoke-Check {
    param(
        [string]$GroupName,
        [string]$Name,
        [scriptblock]$Body
    )

    $status = 'Pass'
    $detail = ''
    try {
        & $Body | Out-Null
    } catch {
        $status = 'Fail'
        $detail = $_.Exception.Message
    }
    if ($GroupName -eq 'Tasks' -and -not $script:TasksGroupReady -and $status -eq 'Fail') {
        $status = 'NotReady'
    }
    $script:Results.Add([pscustomobject]@{ Group = $GroupName; Name = $Name; Status = $status; Detail = $detail })
    $line = '[{0}] {1}: {2}' -f $status, $GroupName, $Name
    if ($detail -ne '') { $line += '  -- ' + $detail }
    $color = 'Green'
    if ($status -eq 'Fail') { $color = 'Red' } elseif ($status -eq 'NotReady') { $color = 'Yellow' }
    Write-Host $line -ForegroundColor $color
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) { throw $Message }
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
# Temporary test infrastructure
# ---------------------------------------------------------------------------

function New-TestRoot {
    $guid = [guid]::NewGuid().ToString('N')
    $root = Join-Path $tempBase ('workspace-newproject-test-' + $guid)
    if (Test-Path -LiteralPath $root) { throw "Test folder already exists: $root" }
    [void](New-Item -ItemType Directory -Path $root -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'Projects') -ErrorAction Stop)
    [System.IO.File]::WriteAllText((Join-Path $root $script:TestRootMarkerName), $guid, (New-Object System.Text.ASCIIEncoding))
    $entry = [pscustomobject]@{ Path = $root; Guid = $guid }
    $script:CreatedRoots += $entry
    return $entry
}

function Unregister-TestRoot {
    param([object]$Entry)

    $script:CreatedRoots = @($script:CreatedRoots | Where-Object { $_.Path -ne $Entry.Path })
}

function Remove-TestRoot {
    param([object]$Entry)

    $root = [System.IO.Path]::GetFullPath($Entry.Path).TrimEnd('\')
    if ((Split-Path -Parent $root) -ine $tempBase) { throw "Refusing to delete (not directly under TEMP): $root" }
    if ((Split-Path -Leaf $root) -cnotmatch '^workspace-newproject-test-[0-9a-f]{32}$') { throw "Refusing to delete (unexpected name): $root" }
    $marker = Join-Path $root $script:TestRootMarkerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Refusing to delete (marker missing): $root" }
    if ([System.IO.File]::ReadAllText($marker).Trim() -ne $Entry.Guid) { throw "Refusing to delete (marker mismatch): $root" }
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Refusing to delete (reparse point): $root" }
    [System.IO.Directory]::Delete($root, $true)
}

function New-FakePythonExe {
    param([string]$Directory)

    $source = @'
using System;
using System.Threading;
public static class FakePython
{
    public static int Main(string[] args)
    {
        string mode = Environment.GetEnvironmentVariable("FAKE_PY_MODE");
        if (mode == null) { mode = "py3"; }
        string joined = string.Join(" ", args);
        if (mode == "stub") { Console.Error.WriteLine("Python was not found."); return 9009; }
        if (mode == "hang") { Thread.Sleep(60000); return 0; }
        if (args.Length >= 2 && args[0] == "-m" && args[1] == "venv") { Console.Error.WriteLine("fake venv failure"); return 1; }
        if (joined.Contains("keyword")) { Console.WriteLine("{\"kw\":[\"class\"],\"std\":null}"); return 0; }
        if (joined.Contains("sys.version_info"))
        {
            if (mode == "py2") { Console.WriteLine("2 7 18"); } else { Console.WriteLine("3 13 0"); }
            return 0;
        }
        return 0;
    }
}
'@
    $path = Join-Path $Directory 'python.exe'
    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $options = New-Object System.CodeDom.Compiler.CompilerParameters
    $options.GenerateExecutable = $true
    $options.OutputAssembly = $path
    $options.CompilerOptions = '/nologo'
    $compiled = $provider.CompileAssemblyFromSource($options, $source)
    if ($compiled.Errors.HasErrors) {
        throw ('Could not compile the fake Python: ' + (($compiled.Errors | ForEach-Object { $_.ErrorText }) -join '; '))
    }
    return $path
}

function New-FakeGitDirectory {
    param([string]$Directory)

    [void](New-Item -ItemType Directory -Path $Directory -Force)
    $lines = @('@echo off', 'echo %*>>"%FAKE_GIT_LOG%"', 'exit /b %FAKE_GIT_EXIT%')
    [System.IO.File]::WriteAllText((Join-Path $Directory 'git.cmd'), (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
}

function Invoke-NewProjectProcess {
    param(
        [string[]]$Arguments,
        [hashtable]$Environment = @{},
        [int]$TimeoutMilliseconds = 300000
    )

    $quoted = @($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powerShellExe
    $psi.Arguments = '-NoProfile -File "' + $newProjectScript + '" ' + $quoted
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        try { $process.Kill() } catch { }
        throw 'New-Project.ps1 timed out.'
    }
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ([string]$stdoutTask.Result + [string]$stderrTask.Result) }
}

function Get-RelativeFileList {
    param([string]$Root)

    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    return @(Get-ChildItem -LiteralPath $full -Recurse -Force -File | Where-Object {
            $_.FullName.Substring($full.Length + 1) -notmatch '^(\.venv|\.git)(\\|$)'
        } | ForEach-Object { $_.FullName.Substring($full.Length + 1) } | Sort-Object)
}

# ---------------------------------------------------------------------------
# Python used for the checks
# ---------------------------------------------------------------------------

$script:TestPython = $null
if (-not [string]::IsNullOrEmpty($IntegrationPythonPath)) {
    $script:TestPython = Get-PythonInfo -Path $IntegrationPythonPath
} else {
    $found = @(Get-PythonCandidates)
    $preferred = @($found | Where-Object { $_.MinorVersion -eq '3.13' })
    if ($preferred.Count -gt 0) { $script:TestPython = $preferred[0] } elseif ($found.Count -gt 0) { $script:TestPython = $found[0] }
}
if ($null -ne $script:TestPython) {
    Write-Host ('Python for tests: {0} ({1})' -f $script:TestPython.Version, $script:TestPython.Path)
    $script:TestNameInfo = Get-PythonNameInfo -PythonExecutable $script:TestPython.Path
} else {
    Write-Host 'Python for tests: not found'
    $script:TestNameInfo = [pscustomobject]@{ Keywords = @(); StdlibNames = $null }
}

# ---------------------------------------------------------------------------
# Unit group
# ---------------------------------------------------------------------------

function Invoke-UnitGroup {
    $g = 'Unit'
    $unitRoot = New-TestRoot
    try {
        $unitProjects = Join-Path $unitRoot.Path 'Projects'
        $fakeDir = Join-Path $unitRoot.Path 'fake'
        [void](New-Item -ItemType Directory -Path $fakeDir)

        Invoke-Check $g 'Host is Windows PowerShell 5.1 or later' {
            Assert-True ($PSVersionTable.PSVersion.Major -ge 5 -and $PSVersionTable.PSVersion.Minor -ge 1 -or $PSVersionTable.PSVersion.Major -gt 5) 'PowerShell 5.1 or later is required.'
        }
        Invoke-Check $g 'All .tools\*.ps1 parse without errors in this PowerShell' {
            foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
                $text = [System.IO.File]::ReadAllText($file.FullName, (New-Object System.Text.UTF8Encoding($false)))
                $tokens = $null
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
                Assert-True (@($errors).Count -eq 0) ('Parse errors in ' + $file.Name + ': ' + (@($errors) | ForEach-Object { $_.Message } | Select-Object -First 1))
            }
        }
        Invoke-Check $g 'New-Project.ps1 and Test-New-Project.ps1 are ASCII only (messages live in JSON)' {
            foreach ($name in @('New-Project.ps1', 'Test-New-Project.ps1')) {
                $facts = Get-FileFacts -Path (Join-Path $PSScriptRoot $name)
                Assert-True ($facts.NonAscii -eq 0 -and -not $facts.HasBom) ($name + ' must be ASCII without BOM.')
                Assert-True ($facts.BareLf -eq 0 -and $facts.BareCr -eq 0) ($name + ' must use CRLF only.')
            }
        }
        Invoke-Check $g 'New-Project.ps1 does not use Bypass or execution policy changes' {
            $text = (Get-FileFacts -Path $newProjectScript).Text
            Assert-True ($text -notmatch '(?i)ExecutionPolicy|Bypass') 'Execution policy handling must not appear.'
            Assert-True ($text -notmatch '(?im)^\s*&?\s*git\s+.*\b(add|commit|push|tag|remote)\b') 'git add/commit/push/tag/remote must not appear.'
        }
        Invoke-Check $g 'messages.json: UTF-8 without BOM, CRLF, Japanese intact, required keys present' {
            $facts = Get-FileFacts -Path $messagesFile
            Assert-True (-not $facts.HasBom) 'messages.json must not have a BOM.'
            Assert-True ($facts.BareLf -eq 0 -and $facts.BareCr -eq 0 -and $facts.Crlf -gt 0) 'messages.json must use CRLF only.'
            Assert-True ($facts.Text -match '[\u3040-\u30FF\u4E00-\u9FFF]') 'Japanese text is missing.'
            Assert-True (-not $facts.Text.Contains([string][char]0xFFFD)) 'Replacement characters found.'
            $loaded = $facts.Text | ConvertFrom-Json
            foreach ($key in $script:RequiredMessageKeys) {
                Assert-True ($null -ne $loaded.PSObject.Properties[$key]) ('Missing key: ' + $key)
            }
        }
        Invoke-Check $g 'Every message key used in New-Project.ps1 is declared as required' {
            $text = (Get-FileFacts -Path $newProjectScript).Text
            $used = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($m in [regex]::Matches($text, "Get-Msg\s+'([A-Za-z]+)'")) { [void]$used.Add($m.Groups[1].Value) }
            foreach ($m in [regex]::Matches($text, "return\s+'((?:Name|Id|MinVer)[A-Za-z]*)'")) { [void]$used.Add($m.Groups[1].Value) }
            foreach ($key in $used) {
                Assert-True ($script:RequiredMessageKeys -contains $key) ('Key is used but not required: ' + $key)
            }
        }
        Invoke-Check $g 'Import-Messages rejects invalid JSON and missing keys without changing loaded messages' {
            $bad1 = Join-Path $fakeDir 'bad1.json'
            $bad2 = Join-Path $fakeDir 'bad2.json'
            [System.IO.File]::WriteAllText($bad1, '{ not json', (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText($bad2, '{ "Usage": "x" }', (New-Object System.Text.UTF8Encoding($false)))
            $before = $script:Messages
            foreach ($bad in @($bad1, $bad2, (Join-Path $fakeDir 'nothing.json'))) {
                $threw = $false
                try { Import-Messages -Path $bad } catch { $threw = $true }
                Assert-True $threw ('Import-Messages must reject: ' + $bad)
            }
            Assert-True ([object]::ReferenceEquals($before, $script:Messages)) 'Loaded messages must not change after a failed import.'
        }

        Invoke-Check $g 'Display name: empty and whitespace-only are rejected' {
            foreach ($value in @('', ' ', '   ')) {
                Assert-True ((Get-DisplayNameProblem -Name $value) -eq 'NameEmpty') ('Not rejected: [' + $value + ']')
            }
        }
        Invoke-Check $g 'Display name: invalid file name characters are rejected' {
            foreach ($value in @('a/b', 'a\b', 'a:b', 'a*b', 'a?b', 'a"b', 'a<b', 'a>b', 'a|b', ('a' + [char]9 + 'b'))) {
                Assert-True ((Get-DisplayNameProblem -Name $value) -eq 'NameInvalidChars') ('Not rejected: [' + $value + ']')
            }
        }
        Invoke-Check $g 'Display name: Windows reserved names are rejected' {
            foreach ($value in @('CON', 'con', 'PRN', 'aux', 'NUL', 'COM1', 'com9', 'LPT1', 'lpt9', 'con.txt', 'NUL.tar.gz')) {
                Assert-True ((Get-DisplayNameProblem -Name $value) -eq 'NameReserved') ('Not rejected: [' + $value + ']')
            }
            Assert-True ($null -eq (Get-DisplayNameProblem -Name 'CONSOLE')) 'CONSOLE must be accepted.'
        }
        Invoke-Check $g 'Display name: trailing dot and edge whitespace are rejected' {
            Assert-True ((Get-DisplayNameProblem -Name 'abc.') -eq 'NameTrailingDot') 'Trailing dot not rejected.'
            Assert-True ((Get-DisplayNameProblem -Name '..') -eq 'NameTrailingDot') 'Double dot not rejected.'
            Assert-True ((Get-DisplayNameProblem -Name 'abc ') -eq 'NameEdgeSpace') 'Trailing space not rejected.'
            Assert-True ((Get-DisplayNameProblem -Name ' abc') -eq 'NameEdgeSpace') 'Leading space not rejected.'
            Assert-True ($null -eq (Get-DisplayNameProblem -Name 'a b.c')) 'Inner space and dot must be accepted.'
        }
        Invoke-Check $g 'Display name: leading "Project " is removed once, never duplicated' {
            Assert-True ((ConvertTo-ProjectDisplayName -InputName 'Project Foo') -ceq 'Foo') 'Project Foo'
            Assert-True ((ConvertTo-ProjectDisplayName -InputName 'project Foo') -ceq 'Foo') 'project Foo'
            Assert-True ((ConvertTo-ProjectDisplayName -InputName 'PROJECT   Foo') -ceq 'Foo') 'PROJECT   Foo'
            Assert-True ((ConvertTo-ProjectDisplayName -InputName 'Foo Project Bar') -ceq 'Foo Project Bar') 'Middle Project must stay.'
            Assert-True ((ConvertTo-ProjectDisplayName -InputName 'Project Project Foo') -ceq 'Project Foo') 'Only the leading prefix is removed.'
            Assert-True ((ConvertTo-ProjectDisplayName -InputName 'Projects') -ceq 'Projects') 'Projects is not a prefix.'
            Assert-True ((Get-ProjectFolderName -DisplayName 'Foo') -ceq 'Project Foo') 'Folder name.'
        }
        Invoke-Check $g 'Display name: a name that is empty after prefix removal is rejected and re-validated' {
            Assert-True ((Get-DisplayNameProblem -Name (ConvertTo-ProjectDisplayName -InputName 'Project ')) -eq 'NameEmpty') 'Prefix only.'
            Assert-True ((Get-DisplayNameProblem -Name (ConvertTo-ProjectDisplayName -InputName 'Project CON')) -eq 'NameReserved') 'Reserved after removal.'
            Assert-True ((Get-DisplayNameProblem -Name (ConvertTo-ProjectDisplayName -InputName 'Project abc.')) -eq 'NameTrailingDot') 'Trailing dot after removal.'
            Assert-True ((Get-DisplayNameProblem -Name (ConvertTo-ProjectDisplayName -InputName 'Project a|b')) -eq 'NameInvalidChars') 'Invalid char after removal.'
        }
        Invoke-Check $g 'Display name: existing project is detected case-insensitively' {
            [void](New-Item -ItemType Directory -Path (Join-Path $unitProjects 'Project Foo'))
            foreach ($value in @('Foo', 'foo', 'FOO', 'Project foo', 'project FOO')) {
                $threw = $false
                try { [void](Get-ValidDisplayName -Initial $value -ProjectsRoot $unitProjects) } catch { $threw = $true }
                Assert-True $threw ('Duplicate not detected: ' + $value)
            }
            Assert-True ((Get-ValidDisplayName -Initial 'Project Bar' -ProjectsRoot $unitProjects) -ceq 'Bar') 'A new name must be accepted.'
        }

        Invoke-Check $g 'Identifier: valid names are accepted' {
            foreach ($value in @('bom_comparison', '_private', 'a', 'a1', 'tool_2')) {
                Assert-True ($null -eq (Get-IdentifierProblem -Name $value -Keywords $script:TestNameInfo.Keywords)) ('Rejected: ' + $value)
            }
        }
        Invoke-Check $g 'Identifier: character, leading character, hyphen, Japanese, and space rules' {
            Assert-True ((Get-IdentifierProblem -Name '') -eq 'IdEmpty') 'empty'
            Assert-True ((Get-IdentifierProblem -Name 'Bom') -eq 'IdChars') 'uppercase'
            Assert-True ((Get-IdentifierProblem -Name '1abc') -eq 'IdLeadingDigit') 'leading digit'
            Assert-True ((Get-IdentifierProblem -Name 'a-b') -eq 'IdHyphen') 'hyphen'
            Assert-True ((Get-IdentifierProblem -Name 'a b') -eq 'IdSpace') 'space'
            Assert-True ((Get-IdentifierProblem -Name ('a' + [char]0x65E5)) -eq 'IdNonAscii') 'Japanese'
            Assert-True ((Get-IdentifierProblem -Name 'a.b') -eq 'IdChars') 'dot'
        }
        Invoke-Check $g 'Identifier: main is rejected in any letter case' {
            foreach ($value in @('main', 'Main', 'MAIN', 'mAiN')) {
                Assert-True ((Get-IdentifierProblem -Name $value -Keywords $script:TestNameInfo.Keywords) -eq 'IdMain') ('Not rejected: ' + $value)
            }
            Assert-True ($null -eq (Get-IdentifierProblem -Name 'main_tool')) 'main_tool must be accepted.'
        }
        Invoke-Check $g 'Identifier: reserved words come from the selected Python (keyword.kwlist)' {
            Assert-True ($null -ne $script:TestPython) 'No Python available for this check.'
            Assert-True ($script:TestNameInfo.Keywords.Count -gt 20) 'Keyword list was not obtained from Python.'
            foreach ($value in @('class', 'def', 'import', 'lambda', 'async', 'await', 'None')) {
                $expected = if ($value -ceq 'None') { 'IdChars' } else { 'IdKeyword' }
                Assert-True ((Get-IdentifierProblem -Name $value -Keywords $script:TestNameInfo.Keywords) -eq $expected) ('Unexpected result for ' + $value)
            }
        }
        Invoke-Check $g 'Identifier: standard library names are warnings, not errors' {
            if ($null -eq $script:TestNameInfo.StdlibNames) { throw 'This Python does not expose stdlib_module_names.' }
            foreach ($value in @('logging', 'json', 'pathlib', 'typing', 'email', 'subprocess')) {
                Assert-True ($null -eq (Get-IdentifierProblem -Name $value -Keywords $script:TestNameInfo.Keywords)) ($value + ' must not be an error.')
                Assert-True (Test-StdlibName -Name $value -StdlibNames $script:TestNameInfo.StdlibNames) ($value + ' must produce a warning.')
            }
            Assert-True (-not (Test-StdlibName -Name 'bom_comparison' -StdlibNames $script:TestNameInfo.StdlibNames)) 'bom_comparison must not warn.'
        }
        Invoke-Check $g 'Identifier: warning confirmation (Y accepts, N and Enter ask again)' {
            $info = [pscustomobject]@{ Keywords = @('class'); StdlibNames = @('logging') }
            $script:FakeAnswers = New-Object 'System.Collections.Generic.Queue[string]'
            function Read-UserInput { param([string]$Prompt) return $script:FakeAnswers.Dequeue() }
            try {
                foreach ($a in @('logging', 'N', 'logging', '', 'other_name')) { $script:FakeAnswers.Enqueue($a) }
                Assert-True ((Get-ValidIdentifier -Initial '' -NameInfo $info) -ceq 'other_name') 'N and Enter must ask for a new identifier.'
                foreach ($a in @('logging', 'Y')) { $script:FakeAnswers.Enqueue($a) }
                Assert-True ((Get-ValidIdentifier -Initial '' -NameInfo $info) -ceq 'logging') 'Y must accept the identifier.'
                foreach ($a in @('N')) { $script:FakeAnswers.Enqueue($a) }
                $threw = $false
                try { [void](Get-ValidIdentifier -Initial 'logging' -NameInfo $info) } catch { $threw = $true }
                Assert-True $threw 'A declined parameter value must fail.'
            } finally {
                function Read-UserInput { param([string]$Prompt) $value = Read-Host -Prompt $Prompt; if ($null -eq $value) { throw 'Input stream ended.' }; return $value }
            }
        }

        Invoke-Check $g 'Minimum version: default format and consistency with the selected Python' {
            $selected = [pscustomobject]@{ MinorVersion = '3.12'; Version = [version]'3.12.10' }
            Assert-True ($null -eq (Get-MinimumVersionProblem -Text '3.12' -Python $selected)) '3.12 equal'
            Assert-True ($null -eq (Get-MinimumVersionProblem -Text '3.11' -Python $selected)) '3.11 lower'
            Assert-True ($null -eq (Get-MinimumVersionProblem -Text '3.9' -Python $selected)) '3.9 lower (no floor below 3.10)'
            Assert-True ($null -eq (Get-MinimumVersionProblem -Text '3.0' -Python $selected)) '3.0'
            Assert-True ((Get-MinimumVersionProblem -Text '3.13' -Python $selected) -eq 'MinVerTooHigh') '3.13 above 3.12.10'
            Assert-True ((Get-MinimumVersionProblem -Text '99.0' -Python $selected) -eq 'MinVerTooHigh') '99.0'
            Assert-True ((Get-MinimumVersionProblem -Text '2.7' -Python $selected) -eq 'MinVerTooLow') '2.7'
            foreach ($value in @('', 'abc', '3', '3.12.1', '3.', '.12', '3.x', '3.12 ')) {
                Assert-True ((Get-MinimumVersionProblem -Text $value -Python $selected) -eq 'MinVerFormat') ('Format not rejected: [' + $value + ']')
            }
            $old = [pscustomobject]@{ MinorVersion = '3.9'; Version = [version]'3.9.13' }
            Assert-True ($null -eq (Get-MinimumVersionProblem -Text '3.9' -Python $old)) 'Python 3.9 must be usable as a selection.'
        }

        Invoke-Check $g 'Python detection: py launcher output is parsed' {
            $lines = @(
                'Installed Pythons found by py Launcher for Windows',
                ' -V:3.13 *        C:\Users\someone\AppData\Local\Programs\Python\Python313\python.exe',
                ' -V:3.12          C:\Program Files\Python312\python.exe',
                ' -3.11-64         C:\Python311\python.exe'
            )
            $paths = @(ConvertFrom-PyLauncherList -Lines $lines)
            Assert-True ($paths.Count -eq 3) ('Expected 3 paths but got ' + $paths.Count)
            Assert-True ($paths[1] -ceq 'C:\Program Files\Python312\python.exe') 'Paths with spaces must be kept.'
        }
        Invoke-Check $g 'Python detection: duplicate paths are removed (case, repeats, py/where overlap)' {
            $merged = @(Merge-PythonPaths -Paths @('C:\A\python.exe', 'c:\a\PYTHON.EXE', 'C:\A\python.exe', 'C:\B\python.exe', '', $null))
            Assert-True ($merged.Count -eq 2) ('Expected 2 but got ' + $merged.Count)
        }
        Invoke-Check $g 'Python detection: unusable candidates are excluded (missing, store-alias-like stub, Python 2, hang)' {
            $fake = New-FakePythonExe -Directory $fakeDir
            $oldMode = $env:FAKE_PY_MODE
            try {
                Assert-True ($null -eq (Get-PythonInfo -Path (Join-Path $fakeDir 'missing.exe'))) 'Missing file.'
                $env:FAKE_PY_MODE = 'stub'
                Assert-True ($null -eq (Get-PythonInfo -Path $fake)) 'Stub that exits with 9009 must be excluded.'
                $env:FAKE_PY_MODE = 'py2'
                Assert-True ($null -eq (Get-PythonInfo -Path $fake)) 'Python 2 must be excluded.'
                $env:FAKE_PY_MODE = 'hang'
                Assert-True ($null -eq (Get-PythonInfo -Path $fake -TimeoutMilliseconds 1500)) 'A hanging candidate must be excluded by timeout.'
                $env:FAKE_PY_MODE = 'py3'
                $info = Get-PythonInfo -Path $fake
                Assert-True ($null -ne $info -and $info.MinorVersion -eq '3.13') 'A working Python 3 must be accepted.'
            } finally {
                $env:FAKE_PY_MODE = $oldMode
            }
        }
        Invoke-Check $g 'Python detection: real candidates on this PC (informational)' {
            $candidates = @(Get-PythonCandidates)
            Assert-True ($candidates.Count -gt 0) 'No usable Python found.'
            $paths = @($candidates | ForEach-Object { $_.Path.ToLowerInvariant() })
            Assert-True (@($paths | Select-Object -Unique).Count -eq $paths.Count) 'Duplicate candidates were returned.'
            foreach ($candidate in $candidates) { Write-Host ('    candidate: {0}  {1}' -f $candidate.Version, $candidate.Path) }
        }

        Invoke-Check $g 'Template: all required files exist and nothing excluded exists' {
            Assert-True ($script:RequiredTemplateFiles.Count -eq 11) 'The required template file list must contain 11 files.'
            Assert-True (@(Get-MissingTemplateFiles -TemplateRoot $templateRoot).Count -eq 0) 'Template files are missing.'
            foreach ($path in @('Sandbox', 'tests\.gitkeep', 'tests\automated', 'tests\experiments', '.venv', '.vscode')) {
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $templateRoot $path))) ('Template must not contain: ' + $path)
            }
            Assert-True ($script:RequiredTemplateFiles -notcontains 'tests\.gitkeep') 'tests\.gitkeep must not be required.'
        }
        Invoke-Check $g 'Template: missing files are reported' {
            $copy = Join-Path $unitRoot.Path 'template-copy'
            [void](New-Item -ItemType Directory -Path $copy)
            Copy-TemplateTree -Source $templateRoot -Destination $copy
            Assert-True (@(Get-MissingTemplateFiles -TemplateRoot $copy).Count -eq 0) 'The copy must be complete.'
            Remove-Item -LiteralPath (Join-Path $copy 'tests\README.md') -Force
            $missing = @(Get-MissingTemplateFiles -TemplateRoot $copy)
            Assert-True ($missing.Count -eq 1 -and $missing[0] -eq 'tests\README.md') 'The missing tests\README.md must be reported.'
        }
        Invoke-Check $g 'Template: tests\README.md content rules' {
            $facts = Get-FileFacts -Path (Join-Path $templateRoot 'tests\README.md')
            Assert-True (-not $facts.HasBom) 'BOM found.'
            Assert-True ($facts.BareLf -eq 0 -and $facts.BareCr -eq 0 -and $facts.Crlf -gt 0) 'CRLF only is required.'
            Assert-True ($facts.Text -notmatch 'C:\\|[A-Za-z]:\\Users|/Users/') 'A personal absolute path was found.'
            Assert-True ($facts.Text -notmatch '\{\{') 'A placeholder was found.'
            Assert-True ($facts.Text -notmatch '(?i)sandbox') 'Sandbox must not be introduced as a standard folder.'
            Assert-True ($facts.Text.Contains('automated') -and $facts.Text.Contains('experiments')) 'The automated/experiments split is missing.'
            Assert-True ($facts.Text.Contains('test_')) 'The rule about not prefixing experiments with test_ is missing.'
            Assert-True ($facts.Text -match 'import' -and $facts.Text.Contains('tests/experiments/')) 'The no-import rule is missing.'
            Assert-True ($facts.Text.Contains('requirements-dev.txt')) 'The requirements-dev.txt rule is missing.'
        }
        Invoke-Check $g 'Template: root README tests row and placeholder count' {
            $facts = Get-FileFacts -Path (Join-Path $templateRoot 'README.md')
            Assert-True ($facts.Text -notmatch '(?i)sandbox') 'Sandbox must not be mentioned.'
            Assert-True ($facts.Text.Contains('automated/') -and $facts.Text.Contains('experiments/')) 'tests row must describe automated/experiments.'
            $tokens = [regex]::Matches($facts.Text, '\{\{([A-Z_]+)\}\}')
            foreach ($t in $tokens) { Assert-True (@('PROJECT_DISPLAY_NAME', 'PYTHON_IDENTIFIER', 'MIN_PYTHON_VERSION') -contains $t.Groups[1].Value) ('Unexpected token: ' + $t.Value) }
        }

        Invoke-Check $g 'Placeholders: every occurrence is replaced in one pass without re-expansion' {
            $values = @{ PROJECT_DISPLAY_NAME = 'A{{PYTHON_IDENTIFIER}}B'; PYTHON_IDENTIFIER = 'my_tool'; MIN_PYTHON_VERSION = '3.12' }
            $text = "# {{PROJECT_DISPLAY_NAME}}`r`n{{PROJECT_DISPLAY_NAME}} {{PYTHON_IDENTIFIER}} {{MIN_PYTHON_VERSION}}`r`n"
            $result = Expand-TemplateTokens -Text $text -Values $values
            Assert-True ($result -ceq "# A{{PYTHON_IDENTIFIER}}B`r`nA{{PYTHON_IDENTIFIER}}B my_tool 3.12`r`n") 'The replacement result is not as expected.'
        }
        Invoke-Check $g 'Placeholders: file update keeps UTF-8 without BOM and CRLF, and leaves nothing behind' {
            $project = Join-Path $unitRoot.Path 'token-project'
            [void](New-Item -ItemType Directory -Path $project)
            Copy-TemplateTree -Source $templateRoot -Destination $project
            Rename-Item -LiteralPath (Join-Path $project 'source\__PYTHON_IDENTIFIER__') -NewName 'my_tool'
            Assert-True (@(Find-TemplateLeftovers -ProjectPath $project).Count -eq 1) 'The unreplaced README must be reported.'
            $values = @{ PROJECT_DISPLAY_NAME = $([string][char]0x90E8) + 'X'; PYTHON_IDENTIFIER = 'my_tool'; MIN_PYTHON_VERSION = '3.12' }
            Update-TemplateTokensInFile -Path (Join-Path $project 'README.md') -Values $values
            $facts = Get-FileFacts -Path (Join-Path $project 'README.md')
            Assert-True (-not $facts.HasBom) 'A BOM was added.'
            Assert-True ($facts.BareLf -eq 0 -and $facts.BareCr -eq 0 -and $facts.Crlf -gt 0) 'CRLF was not preserved.'
            Assert-True ($facts.Text -notmatch '\{\{') 'Placeholders remain.'
            Assert-True ($facts.Text.Contains('.\Projects\Project ' + $values.PROJECT_DISPLAY_NAME)) 'The run path was not updated.'
            Assert-True ($facts.Text -notmatch 'C:\\|[A-Za-z]:\\Users') 'A personal absolute path was written.'
            Assert-True (@(Find-TemplateLeftovers -ProjectPath $project).Count -eq 0) 'Leftovers were reported after replacement.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $project ('source\' + $script:PlaceholderFolderName)))) 'The placeholder folder remains.'
        }
        Invoke-Check $g 'Leftover scan separates folder names from file text' {
            $project = Join-Path $unitRoot.Path 'leftover-project'
            [void](New-Item -ItemType Directory -Path (Join-Path $project 'source\__PYTHON_IDENTIFIER__') -Force)
            [System.IO.File]::WriteAllText((Join-Path $project 'a.md'), 'clean', (New-Object System.Text.UTF8Encoding($false)))
            $found = @(Find-TemplateLeftovers -ProjectPath $project)
            Assert-True ($found.Count -eq 1 -and $found[0].StartsWith('folder: ')) 'A folder leftover must be reported as a folder.'
            [System.IO.File]::WriteAllText((Join-Path $project 'b.md'), 'x {{MIN_PYTHON_VERSION}}', (New-Object System.Text.UTF8Encoding($false)))
            $found = @(Find-TemplateLeftovers -ProjectPath $project)
            Assert-True (@($found | Where-Object { $_.StartsWith('text: ') }).Count -eq 1) 'A text leftover must be reported as text.'
        }

        Invoke-Check $g 'Safe removal: only a folder created by this run directly under Projects' {
            $projects = Join-Path $unitRoot.Path 'Projects'
            $mine = Join-Path $projects 'Project Mine'
            [void](New-Item -ItemType Directory -Path $mine)
            Assert-True (Test-SafeToRemove -Path $mine -ProjectsRoot $projects -CreatedByThisRun $true) 'A created folder must be removable.'
            Assert-True (-not (Test-SafeToRemove -Path $mine -ProjectsRoot $projects -CreatedByThisRun $false)) 'A folder not created by this run must not be removable.'
            $other = Join-Path $unitRoot.Path 'Elsewhere\Project Mine'
            [void](New-Item -ItemType Directory -Path $other -Force)
            Assert-True (-not (Test-SafeToRemove -Path $other -ProjectsRoot $projects -CreatedByThisRun $true)) 'A folder outside Projects must not be removable.'
            $nested = Join-Path $mine 'Project Nested'
            [void](New-Item -ItemType Directory -Path $nested)
            Assert-True (-not (Test-SafeToRemove -Path $nested -ProjectsRoot $projects -CreatedByThisRun $true)) 'A nested folder must not be removable.'
            $wrongName = Join-Path $projects 'Documents'
            [void](New-Item -ItemType Directory -Path $wrongName)
            Assert-True (-not (Test-SafeToRemove -Path $wrongName -ProjectsRoot $projects -CreatedByThisRun $true)) 'A folder without the Project prefix must not be removable.'
            Assert-True (-not (Test-SafeToRemove -Path (Join-Path $projects 'Project Missing') -ProjectsRoot $projects -CreatedByThisRun $true)) 'A missing folder must not be removable.'
        }
        Invoke-Check $g 'Test mode: the destination root is limited to a marked folder under TEMP' {
            $threw = 0
            foreach ($bad in @($workspaceRoot, (Join-Path $workspaceRoot 'Projects'), $tempBase, (Join-Path $tempBase 'not-marked-folder'), '')) {
                try { [void](Resolve-TestProjectsRoot -Root $bad) } catch { $threw++ }
            }
            Assert-True ($threw -eq 5) 'Every unmarked or non-TEMP root must be rejected.'
            Assert-True ((Resolve-TestProjectsRoot -Root $unitRoot.Path) -ieq (Join-Path $unitRoot.Path 'Projects')) 'A marked TEMP root must be accepted.'
        }
        Invoke-Check $g 'Test mode: test-only arguments are rejected without -TestMode (child process)' {
            foreach ($argumentSet in @(@('-SkipConfirmation'), @('-SkipGitInit'), @('-SkipVenv'), @('-VenvFailureAnswer', 'Y'), @('-TestWorkspaceRoot', $unitRoot.Path))) {
                $before = Get-RelativeFileList -Root $unitRoot.Path
                $run = Invoke-NewProjectProcess -Arguments $argumentSet -TimeoutMilliseconds 60000
                Assert-True ($run.ExitCode -ne 0) ('Exit code must be non-zero for: ' + ($argumentSet -join ' '))
                $after = Get-RelativeFileList -Root $unitRoot.Path
                Assert-True (($before -join '|') -ceq ($after -join '|')) 'Files changed after a rejected call.'
            }
            $run = Invoke-NewProjectProcess -Arguments @('-TestMode') -TimeoutMilliseconds 60000
            Assert-True ($run.ExitCode -ne 0) '-TestMode without -TestWorkspaceRoot must fail.'
        }
    } finally {
        Remove-TestRoot -Entry $unitRoot
        Unregister-TestRoot -Entry $unitRoot
    }
}

# ---------------------------------------------------------------------------
# Tasks group (NotReady until .vscode\tasks.json is updated for the new tools)
# ---------------------------------------------------------------------------

function Invoke-TasksGroup {
    $g = 'Tasks'
    Invoke-Check $g 'tasks.json exists and is valid JSON' {
        Assert-True (Test-Path -LiteralPath $tasksFile -PathType Leaf) 'tasks.json not found.'
        [void]((Get-FileFacts -Path $tasksFile).Text | ConvertFrom-Json)
    }
    Invoke-Check $g 'tasks.json does not use ExecutionPolicy Bypass' {
        Assert-True ((Get-FileFacts -Path $tasksFile).Text -notmatch '(?i)ExecutionPolicy|Bypass') 'ExecutionPolicy or Bypass was found.'
    }
    Invoke-Check $g 'tasks.json has no Excel or UserForm tasks' {
        $text = (Get-FileFacts -Path $tasksFile).Text
        Assert-True ($text -notmatch '(?i)UserFormCsv|Excel:|Excel\.') 'Excel or UserForm tasks remain.'
        $config = $text | ConvertFrom-Json
        $excel = @($config.tasks | Where-Object { $_.label -match '^(Excel|New:)' })
        Assert-True ($excel.Count -eq 0) 'Old Excel or New: tasks remain.'
    }
    Invoke-Check $g 'tasks.json defines three Workspace: tasks and three Project: tasks' {
        $config = (Get-FileFacts -Path $tasksFile).Text | ConvertFrom-Json
        Assert-True (@($config.tasks | Where-Object { $_.label -like 'Workspace:*' }).Count -eq 3) 'Three Workspace: tasks are required.'
        Assert-True (@($config.tasks | Where-Object { $_.label -like 'Project:*' }).Count -eq 3) 'Three Project: tasks are required.'
    }
    Invoke-Check $g 'tasks.json references existing scripts only' {
        $text = (Get-FileFacts -Path $tasksFile).Text
        $names = @([regex]::Matches($text, '\.tools\\\\([A-Za-z\-]+\.ps1)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        foreach ($required in @('New-Project.ps1', 'Manage-ApprovedPackage.ps1', 'Update-ApprovedPackagesDocument.ps1', 'Install-Packages.ps1')) {
            Assert-True ($names -contains $required) ('tasks.json does not reference ' + $required)
        }
        foreach ($name in $names) { Assert-True (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf) ('Referenced script does not exist: ' + $name) }
    }
}

# ---------------------------------------------------------------------------
# Integration group (temporary folders under %TEMP% only)
# ---------------------------------------------------------------------------

function Invoke-IntegrationGroup {
    $g = 'Integration'
    if ($null -eq $script:TestPython) {
        Invoke-Check $g 'A usable Python is required' { throw 'No usable Python was found.' }
        return
    }
    $realProjects = Join-Path $workspaceRoot 'Projects'
    $realBefore = @(Get-ChildItem -LiteralPath $realProjects -Force -Name | Sort-Object)
    $root = New-TestRoot
    try {
        $projects = Join-Path $root.Path 'Projects'
        $py = $script:TestPython.Path
        $minor = $script:TestPython.MinorVersion
        $baseArgs = @('-TestMode', '-TestWorkspaceRoot', $root.Path, '-PythonPath', $py, '-MinimumPythonVersion', $minor, '-SkipConfirmation')
        $keep = Join-Path $projects 'Project Keep'
        [void](New-Item -ItemType Directory -Path $keep)
        [System.IO.File]::WriteAllText((Join-Path $keep 'keep.txt'), 'must stay', (New-Object System.Text.UTF8Encoding($false)))
        $keepHash = (Get-FileHash -LiteralPath (Join-Path $keep 'keep.txt')).Hash

        $display = 'Project ' + [char]0x90E8 + [char]0x54C1 + ' Sample'
        $folder = 'Project ' + [char]0x90E8 + [char]0x54C1 + ' Sample'
        $project = Join-Path $projects $folder
        $env:FAKE_GIT_LOG = Join-Path $root.Path 'git-real-not-used.log'

        Invoke-Check $g 'Create a project with a real .venv and a real git init (Japanese and space in the path)' {
            $run = Invoke-NewProjectProcess -Arguments ($baseArgs + @('-ProjectDisplayName', $display, '-PythonIdentifier', 'sample_tool'))
            Assert-True ($run.ExitCode -eq 0) ('Exit code was ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
            Assert-True (Test-Path -LiteralPath $project -PathType Container) 'The project folder was not created.'
            foreach ($file in $script:RequiredTemplateFiles) {
                $expected = $file.Replace('__PYTHON_IDENTIFIER__', 'sample_tool')
                Assert-True (Test-Path -LiteralPath (Join-Path $project $expected) -PathType Leaf) ('Missing in the new project: ' + $expected)
            }
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $project 'source\__PYTHON_IDENTIFIER__'))) 'The placeholder folder remains.'
            Assert-True (Test-Path -LiteralPath (Join-Path $project 'source\sample_tool\__init__.py')) 'The identifier folder is missing.'
            Assert-True ((Get-Item -LiteralPath (Join-Path $project 'source\sample_tool\__init__.py')).Length -eq 0) '__init__.py must be empty.'
        }
        Invoke-Check $g 'New project: exact file list, no extra folders, no VS Code settings' {
            $expected = @($script:RequiredTemplateFiles | ForEach-Object { $_.Replace('__PYTHON_IDENTIFIER__', 'sample_tool') } | Sort-Object)
            $actual = Get-RelativeFileList -Root $project
            Assert-True (($expected -join '|') -ceq ($actual -join '|')) ('File list differs: ' + ($actual -join ', '))
            foreach ($path in @('Sandbox', 'tests\automated', 'tests\experiments', 'tests\.gitkeep', '.vscode')) {
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $project $path))) ('Must not be created: ' + $path)
            }
        }
        Invoke-Check $g 'New project: README tokens replaced, title without the Project prefix, no leftovers' {
            $facts = Get-FileFacts -Path (Join-Path $project 'README.md')
            $shortName = [string][char]0x90E8 + [char]0x54C1 + ' Sample'
            Assert-True ($facts.Text.StartsWith('# ' + $shortName + "`r`n")) 'The README title is wrong.'
            Assert-True ($facts.Text.Contains('.\Projects\Project ' + $shortName)) 'The run path is wrong.'
            Assert-True ($facts.Text.Contains('`sample_tool`')) 'The identifier is missing.'
            Assert-True ($facts.Text -match ('\uFF1A' + [regex]::Escape($minor))) 'The minimum version is missing.'
            Assert-True (-not $facts.HasBom -and $facts.BareLf -eq 0 -and $facts.BareCr -eq 0) 'Encoding or line endings changed.'
            Assert-True (@(Find-TemplateLeftovers -ProjectPath $project).Count -eq 0) 'Template leftovers were found.'
            Assert-True ($facts.Text -notmatch '[A-Za-z]:\\Users') 'A personal path was written.'
        }
        Invoke-Check $g 'New project: tests\README.md is an exact copy of the template' {
            $a = (Get-FileHash -LiteralPath (Join-Path $templateRoot 'tests\README.md')).Hash
            $b = (Get-FileHash -LiteralPath (Join-Path $project 'tests\README.md')).Hash
            Assert-True ($a -eq $b) 'tests\README.md differs from the template.'
            $facts = Get-FileFacts -Path (Join-Path $project 'tests\README.md')
            Assert-True (-not $facts.HasBom -and $facts.BareLf -eq 0 -and $facts.BareCr -eq 0) 'Encoding or line endings changed.'
        }
        Invoke-Check $g 'New project: requirements files are empty and no package was installed' {
            Assert-True ((Get-Item -LiteralPath (Join-Path $project 'requirements.txt')).Length -eq 0) 'requirements.txt must be empty.'
            Assert-True ((Get-Item -LiteralPath (Join-Path $project 'requirements-dev.txt')).Length -eq 0) 'requirements-dev.txt must be empty.'
            $sitePackages = Join-Path $project '.venv\Lib\site-packages'
            $names = @(Get-ChildItem -LiteralPath $sitePackages -Directory -Force | ForEach-Object { $_.Name.ToLowerInvariant() })
            $unexpected = @($names | Where-Object { $_ -notmatch '^(pip|setuptools|wheel|pkg_resources|_distutils_hack|__pycache__)(-|$|\.)' })
            Assert-True ($unexpected.Count -eq 0) ('Unexpected packages: ' + ($unexpected -join ', '))
        }
        Invoke-Check $g 'New project: .venv works and main.py runs silently' {
            $venvPython = Join-Path $project '.venv\Scripts\python.exe'
            Assert-True (Test-Path -LiteralPath $venvPython -PathType Leaf) '.venv\Scripts\python.exe is missing.'
            $info = Get-PythonInfo -Path $venvPython
            Assert-True ($null -ne $info -and $info.MinorVersion -eq $minor) 'The .venv Python version is wrong.'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $venvPython
            $psi.Arguments = '-B "' + (Join-Path $project 'source\main.py') + '"'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $process = [System.Diagnostics.Process]::Start($psi)
            $out = $process.StandardOutput.ReadToEnd()
            $err = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            Assert-True ($process.ExitCode -eq 0 -and $out -eq '' -and $err -eq '') 'main.py must exit 0 without output.'
        }
        Invoke-Check $g 'New project: git init -b main only (no commit, nothing staged)' {
            Assert-True (Test-Path -LiteralPath (Join-Path $project '.git') -PathType Container) '.git was not created.'
            $head = [System.IO.File]::ReadAllText((Join-Path $project '.git\HEAD')).Trim()
            Assert-True ($head -ceq 'ref: refs/heads/main') ('HEAD is ' + $head)
            & git -C $project rev-parse --verify --quiet HEAD 2>$null | Out-Null
            Assert-True ($LASTEXITCODE -ne 0) 'A commit exists.'
            $staged = @(& git -C $project diff --cached --name-only)
            Assert-True ($staged.Count -eq 0) 'Files were staged.'
        }
        Invoke-Check $g 'Existing projects are neither overwritten nor deleted' {
            $before = Get-RelativeFileList -Root $project
            $readmeHash = (Get-FileHash -LiteralPath (Join-Path $project 'README.md')).Hash
            $run = Invoke-NewProjectProcess -Arguments ($baseArgs + @('-ProjectDisplayName', 'Keep', '-PythonIdentifier', 'keep_tool'))
            Assert-True ($run.ExitCode -ne 0) 'Creating an existing project must fail.'
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $keep 'keep.txt')).Hash -eq $keepHash) 'The existing project was changed.'
            $run = Invoke-NewProjectProcess -Arguments ($baseArgs + @('-ProjectDisplayName', ('project ' + $folder.Substring(8).ToUpperInvariant()), '-PythonIdentifier', 'other_tool'))
            Assert-True ($run.ExitCode -ne 0) 'A case-different duplicate must fail.'
            $after = Get-RelativeFileList -Root $project
            Assert-True (($before -join '|') -ceq ($after -join '|')) 'The first project changed.'
            Assert-True ($readmeHash -eq (Get-FileHash -LiteralPath (Join-Path $project 'README.md')).Hash) 'README.md changed.'
        }
        Invoke-Check $g 'Rejected inputs create nothing (main, keyword, bad name, too-high minimum version)' {
            $cases = @(
                @('-ProjectDisplayName', 'Rej1', '-PythonIdentifier', 'main'),
                @('-ProjectDisplayName', 'Rej2', '-PythonIdentifier', 'Main'),
                @('-ProjectDisplayName', 'Rej3', '-PythonIdentifier', 'class'),
                @('-ProjectDisplayName', 'CON', '-PythonIdentifier', 'ok_name'),
                @('-ProjectDisplayName', 'Rej5.', '-PythonIdentifier', 'ok_name'),
                @('-ProjectDisplayName', 'Rej6', '-PythonIdentifier', 'bad-name')
            )
            foreach ($case in $cases) {
                $run = Invoke-NewProjectProcess -Arguments ($baseArgs + $case)
                Assert-True ($run.ExitCode -ne 0) ('Must fail: ' + ($case -join ' '))
            }
            $tooHigh = @('-TestMode', '-TestWorkspaceRoot', $root.Path, '-PythonPath', $py, '-MinimumPythonVersion', '99.0', '-SkipConfirmation', '-ProjectDisplayName', 'Rej7', '-PythonIdentifier', 'ok_name')
            Assert-True ((Invoke-NewProjectProcess -Arguments $tooHigh).ExitCode -ne 0) 'A too-high minimum version must fail.'
            $names = @(Get-ChildItem -LiteralPath $projects -Force -Name)
            Assert-True (@($names | Where-Object { $_ -like 'Project Rej*' }).Count -eq 0) 'A rejected input created a folder.'
        }

        $fakeDir = Join-Path $root.Path 'fake'
        [void](New-Item -ItemType Directory -Path $fakeDir)
        $fakePython = New-FakePythonExe -Directory $fakeDir
        $fakeBase = @('-TestMode', '-TestWorkspaceRoot', $root.Path, '-PythonPath', $fakePython, '-MinimumPythonVersion', '3.13', '-SkipConfirmation', '-SkipGitInit')

        Invoke-Check $g '.venv failure with answer N keeps the project; answer Y deletes only this run''s project' {
            $env:FAKE_PY_MODE = 'py3'
            $before = @(Get-ChildItem -LiteralPath $projects -Force -Name | Sort-Object)
            $run = Invoke-NewProjectProcess -Arguments ($fakeBase + @('-ProjectDisplayName', 'VenvKeep', '-PythonIdentifier', 'venv_keep', '-VenvFailureAnswer', 'N')) -Environment @{ FAKE_PY_MODE = 'py3' }
            Assert-True ($run.ExitCode -ne 0) 'A venv failure must produce a non-zero exit code.'
            Assert-True (Test-Path -LiteralPath (Join-Path $projects 'Project VenvKeep\README.md')) 'Answer N must keep the project.'
            $run = Invoke-NewProjectProcess -Arguments ($fakeBase + @('-ProjectDisplayName', 'VenvDelete', '-PythonIdentifier', 'venv_delete', '-VenvFailureAnswer', 'Y')) -Environment @{ FAKE_PY_MODE = 'py3' }
            Assert-True ($run.ExitCode -ne 0) 'A venv failure must produce a non-zero exit code.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $projects 'Project VenvDelete'))) 'Answer Y must delete the project created by this run.'
            Assert-True (Test-Path -LiteralPath (Join-Path $projects 'Project VenvKeep\README.md')) 'Answer Y must not delete another project.'
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $keep 'keep.txt')).Hash -eq $keepHash) 'An existing project was changed.'
            Assert-True (Test-Path -LiteralPath $project -PathType Container) 'An existing real project was deleted.'
            $after = @(Get-ChildItem -LiteralPath $projects -Force -Name | Sort-Object)
            $added = @($after | Where-Object { $before -notcontains $_ })
            Assert-True ($added.Count -eq 1 -and $added[0] -ceq 'Project VenvKeep') ('Unexpected folders: ' + ($added -join ', '))
        }

        $gitDir = Join-Path $root.Path 'fakegit'
        New-FakeGitDirectory -Directory $gitDir
        $gitLog = Join-Path $root.Path 'fake-git.log'
        $pathWithFake = $gitDir + ';' + $env:PATH
        $gitBase = @('-TestMode', '-TestWorkspaceRoot', $root.Path, '-PythonPath', $py, '-MinimumPythonVersion', $minor, '-SkipConfirmation')

        Invoke-Check $g 'git init failure keeps the project and .venv and records only git init' {
            if (Test-Path -LiteralPath $gitLog) { Remove-Item -LiteralPath $gitLog -Force }
            $run = Invoke-NewProjectProcess -Arguments ($gitBase + @('-ProjectDisplayName', 'GitFail', '-PythonIdentifier', 'git_fail')) -Environment @{ PATH = $pathWithFake; FAKE_GIT_LOG = $gitLog; FAKE_GIT_EXIT = '1' }
            Assert-True ($run.ExitCode -eq 0) ('A git failure must only warn. Exit code: ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
            $gitProject = Join-Path $projects 'Project GitFail'
            Assert-True (Test-Path -LiteralPath (Join-Path $gitProject 'README.md')) 'The project was removed.'
            Assert-True (Test-Path -LiteralPath (Join-Path $gitProject '.venv\Scripts\python.exe')) 'The .venv was removed.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitProject '.git'))) '.git must not exist after the fake failure.'
            $lines = @(Get-Content -LiteralPath $gitLog)
            Assert-True ($lines.Count -eq 1) ('Expected one git call but got ' + $lines.Count)
            Assert-True ($lines[0] -cmatch '^-C ".+" init -b main\s*$') ('Unexpected git call: ' + $lines[0])
            Assert-True ($lines[0] -notmatch '\b(add|commit|push|tag|remote)\b') 'A forbidden git subcommand was recorded.'
            Write-Host ('    recorded git calls: ' + ($lines -join ' | '))
        }
        Invoke-Check $g 'git init success records only git init (no add, commit, push, tag, remote)' {
            if (Test-Path -LiteralPath $gitLog) { Remove-Item -LiteralPath $gitLog -Force }
            $skipVenvArgs = $gitBase + @('-SkipVenv', '-ProjectDisplayName', 'GitOk', '-PythonIdentifier', 'git_ok')
            $run = Invoke-NewProjectProcess -Arguments $skipVenvArgs -Environment @{ PATH = $pathWithFake; FAKE_GIT_LOG = $gitLog; FAKE_GIT_EXIT = '0' }
            Assert-True ($run.ExitCode -eq 0) ('Exit code was ' + $run.ExitCode + [Environment]::NewLine + $run.Output)
            $lines = @(Get-Content -LiteralPath $gitLog)
            Assert-True ($lines.Count -eq 1 -and $lines[0] -cmatch '^-C ".+" init -b main\s*$') 'Only git init -b main may be recorded.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $projects 'Project GitOk\.venv'))) '-SkipVenv must not create .venv.'
        }
        Invoke-Check $g 'Normal-mode safety: no Sandbox, tests\automated, or tests\experiments were created anywhere' {
            foreach ($created in @(Get-ChildItem -LiteralPath $projects -Directory -Force)) {
                foreach ($path in @('Sandbox', 'tests\automated', 'tests\experiments')) {
                    Assert-True (-not (Test-Path -LiteralPath (Join-Path $created.FullName $path))) ($created.Name + ' contains ' + $path)
                }
            }
        }
    } finally {
        Remove-Item Env:\FAKE_GIT_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\FAKE_PY_MODE -ErrorAction SilentlyContinue
        Remove-TestRoot -Entry $root
        Unregister-TestRoot -Entry $root
    }
    Invoke-Check $g 'Cleanup: the temporary test folder is gone and the real Projects folder is unchanged' {
        Assert-True (-not (Test-Path -LiteralPath $root.Path)) 'The temporary folder remains.'
        $realAfter = @(Get-ChildItem -LiteralPath $realProjects -Force -Name | Sort-Object)
        Assert-True (($realBefore -join '|') -ceq ($realAfter -join '|')) 'The real Projects folder changed.'
        Assert-True (@($realAfter | Where-Object { $_ -like 'Project Test*' }).Count -eq 0) 'A Project Test folder exists.'
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

try {
    if ($Group -eq 'Unit' -or $Group -eq 'All') { Invoke-UnitGroup }
    if ($Group -eq 'Tasks' -or $Group -eq 'All') { Invoke-TasksGroup }
    if ($Group -eq 'Integration' -or $Group -eq 'All') { Invoke-IntegrationGroup }
} finally {
    foreach ($entry in @($script:CreatedRoots)) {
        try { Remove-TestRoot -Entry $entry } catch { Write-Host ('Cleanup failed: ' + $_.Exception.Message) -ForegroundColor Red }
    }
}

$pass = @($script:Results | Where-Object { $_.Status -eq 'Pass' }).Count
$fail = @($script:Results | Where-Object { $_.Status -eq 'Fail' }).Count
$notReady = @($script:Results | Where-Object { $_.Status -eq 'NotReady' }).Count
Write-Host ''
Write-Host ('Summary: Pass={0} Fail={1} NotReady={2}' -f $pass, $fail, $notReady)
if ($fail -gt 0) { exit 1 }
exit 0
