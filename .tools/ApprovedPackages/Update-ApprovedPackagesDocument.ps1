<#
.SYNOPSIS
    Generates ApprovedPackages\approved-packages.md from approved-packages.json.

.DESCRIPTION
    The JSON file is the source of truth. The Markdown file is overwritten and must not be edited by hand.
    The output contains no timestamps, so running the tool twice produces identical bytes.
    Messages are read from ApprovedPackages.messages.json (UTF-8, no BOM).
    The tool never runs git, never installs packages, and never changes the execution policy.

    -TestMode and -DataDirectory are for automated tests only. The directory must be inside the
    temporary folder and contain the test marker file.
#>
[CmdletBinding()]
param(
    [switch]$TestMode,
    [string]$DataDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ApprovedPackages.Common.ps1')

$script:UpdateBoundNames = @($PSBoundParameters.Keys)
$script:UpdateMessages = $null
$script:UpdateRequiredKeys = @(
    'ErrorPrefix',
    'UpdUsage', 'UpdErrTestModeOnly', 'UpdErrTestRootRequired', 'UpdErrTestRootInvalid',
    'UpdGenerated', 'UpdUnchanged',
    'ErrReadFileNotFound', 'ErrReadInvalidUtf8', 'ErrReadInvalidJson',
    'ProblemRootNotObject', 'ProblemSchemaVersionMissing', 'ProblemSchemaVersionUnsupported', 'ProblemPackagesNotArray',
    'ProblemUnknownField', 'ProblemPackageNotObject', 'ProblemFieldMissing', 'ProblemFieldNotString',
    'ProblemNameInvalid', 'ProblemNameDuplicate', 'ProblemNameDuplicateNormalized',
    'ProblemAllowedVersionsNotArray', 'ProblemAllowedVersionInvalid', 'ProblemAllowedVersionDuplicate',
    'ProblemStatusInvalid', 'ProblemApprovedDateInvalid', 'ProblemApprovedDateMustBeEmpty',
    'MdNotice', 'MdTitle', 'MdHeaderName', 'MdHeaderVersions', 'MdHeaderStatus', 'MdHeaderApprovedDate',
    'MdHeaderPurpose', 'MdHeaderNotes', 'MdNoVersions'
)

function Get-UpdMsg {
    param(
        [string]$Key,
        [object[]]$FormatArgs
    )

    return (Get-ToolMessage -Messages $script:UpdateMessages -Key $Key -FormatArgs $FormatArgs)
}

function Get-MarkdownLabels {
    return [pscustomobject]@{
        NoticeLines        = @((Get-UpdMsg 'MdNotice') -split "\r?\n")
        Title              = (Get-UpdMsg 'MdTitle')
        HeaderName         = (Get-UpdMsg 'MdHeaderName')
        HeaderVersions     = (Get-UpdMsg 'MdHeaderVersions')
        HeaderStatus       = (Get-UpdMsg 'MdHeaderStatus')
        HeaderApprovedDate = (Get-UpdMsg 'MdHeaderApprovedDate')
        HeaderPurpose      = (Get-UpdMsg 'MdHeaderPurpose')
        HeaderNotes        = (Get-UpdMsg 'MdHeaderNotes')
        NoVersions         = (Get-UpdMsg 'MdNoVersions')
    }
}

function Invoke-UpdateDocument {
    $paths = Get-ApprovedPackagesPaths
    $script:UpdateMessages = Import-ToolMessages -Path $paths.MessagesPath -RequiredKeys $script:UpdateRequiredKeys

    $used = @($script:UpdateBoundNames)
    if (-not $TestMode.IsPresent) {
        if ($used.Count -gt 0) {
            throw ((Get-UpdMsg 'UpdErrTestModeOnly' @(($used | ForEach-Object { '-' + $_ }) -join ', ')) + [Environment]::NewLine + (Get-UpdMsg 'UpdUsage'))
        }
    } else {
        if ([string]::IsNullOrEmpty($DataDirectory)) {
            throw ((Get-UpdMsg 'UpdErrTestRootRequired') + [Environment]::NewLine + (Get-UpdMsg 'UpdUsage'))
        }
        $resolved = Resolve-TestDataDirectory -Directory $DataDirectory
        if ($null -eq $resolved) { throw (Get-UpdMsg 'UpdErrTestRootInvalid' @($DataDirectory)) }
        $paths = Get-ApprovedPackagesPaths -DataDirectory $resolved
    }

    $read = Read-ApprovedPackageList -Path $paths.JsonPath
    if (-not $read.Success) { throw (Get-UpdMsg ('ErrRead' + $read.ErrorCode) @($read.ErrorDetail)) }
    $problems = @(Test-ApprovedPackageList -Data $read.Data)
    if ($problems.Count -gt 0) {
        $lines = @($problems | ForEach-Object { Get-UpdMsg ('Problem' + $_.Code) @($_.Package, $_.Detail) })
        throw ($lines -join [Environment]::NewLine)
    }

    $text = ConvertTo-ApprovedPackagesMarkdown -Packages @($read.Data.packages) -Labels (Get-MarkdownLabels)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $paths.MarkdownPath -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllBytes($paths.MarkdownPath)
        if ([System.Convert]::ToBase64String($existing) -ceq [System.Convert]::ToBase64String($utf8.GetBytes($text))) {
            Write-Host (Get-UpdMsg 'UpdUnchanged' @($paths.MarkdownPath))
            return 0
        }
    }
    Write-TextFileSafely -Path $paths.MarkdownPath -Text $text
    Write-Host (Get-UpdMsg 'UpdGenerated' @($paths.MarkdownPath))
    return 0
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $results = @(Invoke-UpdateDocument)
    $exitCode = [int]$results[$results.Count - 1]
} catch {
    $errorText = $_.Exception.Message
    if ($null -ne $script:UpdateMessages) { $errorText = Get-UpdMsg 'ErrorPrefix' @($errorText) }
    Write-Host $errorText -ForegroundColor Red
    $exitCode = 1
}
exit $exitCode
