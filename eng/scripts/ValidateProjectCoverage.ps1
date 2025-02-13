﻿#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Validates the code coverage policy for each project.
.DESCRIPTION
    This script compares code coverage with thresholds given in "MinCodeCoverage" property in each project.
    The script writes an error for each project that does not comply with the policy.
.PARAMETER CoberturaReportXml
    Path to the XML file to read the code coverage report from in Cobertura format
.EXAMPLE
    PS> .\ValidatePerProjectCoverage.ps1 -CoberturaReportXml .\Cobertura.xml
#>

param (
    [Parameter(Mandatory = $true, HelpMessage="Path to the XML file to read the code coverage report from")]
    [string]$CoberturaReportXml
)

function Write-Header {
    param($message, [bool]$isError);
    $color = if ($isError) { 'Red' } else { 'Green' };
    Write-Host $message -ForegroundColor $color;
    Write-Host ("=" * 80)
 }
function Get-XmlValue { param($X, $Y); return $X.SelectSingleNode($Y).'#text' }

Write-Verbose "Reading cobertura report..."
[xml]$CoberturaReport = Get-Content $CoberturaReportXml
if ($null -eq $CoberturaReport.coverage -or 
    $null -eq $CoberturaReport.coverage.packages -or
    $null -eq $CoberturaReport.coverage.packages.package -or 
    0 -eq $CoberturaReport.coverage.packages.package.count)
{
    return
}

$ProjectToMinCoverageMap = @{}

Get-ChildItem -Path src -Include '*.*sproj' -Recurse | ForEach-Object {
    $XmlDoc = [xml](Get-Content $_)
    $AssemblyName = Get-XmlValue $XmlDoc "//Project/PropertyGroup/AssemblyName"
    $MinCodeCoverage = Get-XmlValue $XmlDoc "//Project/PropertyGroup/MinCodeCoverage"

    if ([string]::IsNullOrWhiteSpace($AssemblyName)) {
        $AssemblyName = $_.BaseName
    }

    if ([string]::IsNullOrWhiteSpace($MinCodeCoverage)) {
        # Test projects may not legitimely have min code coverage set.
        Write-Warning "$AssemblyName doesn't declare 'MinCodeCoverage' property"
        return
    }

    $ProjectToMinCoverageMap[$AssemblyName] = $MinCodeCoverage
}

$esc = [char]27
$Errors = New-Object System.Collections.ArrayList
$Kudos = New-Object System.Collections.ArrayList

Write-Verbose "Collecting projects from code coverage report..."
$CoberturaReport.coverage.packages.package | ForEach-Object {
    $Name = $_.name
    $LineCoverage = [math]::Round([double]$_.'line-rate' * 100, 2)
    $BranchCoverage = [math]::Round([double]$_.'branch-rate' * 100, 2)
    $IsFailed = $false

    Write-Verbose "Project $Name with line coverage $LineCoverage and branch coverage $BranchCoverage"

    if ($ProjectToMinCoverageMap.ContainsKey($Name)) {
        if ($ProjectToMinCoverageMap[$Name] -eq 'n/a')
        {
            Write-Host "$Name ...code coverage is not applicable"
            return
        }

        [double]$MinCodeCoverage = $ProjectToMinCoverageMap[$Name]

        # Detect the under-coverage
        if ($MinCodeCoverage -gt $LineCoverage) {
            $IsFailed = $true
            [void]$Errors.Add(
                (
                    New-Object PSObject -Property @{
                        "Project" = $Name;
                        "Coverage Type" = "Line";
                        "Expected" = $MinCodeCoverage;
                        "Actual" = "$esc[1m$esc[0;31m$($LineCoverage)$esc[0m"
                    }
                )
            )
        }

        if ($MinCodeCoverage -gt $BranchCoverage) {
            $IsFailed = $true
            [void]$Errors.Add(
                (
                    New-Object PSObject -Property @{
                        "Project" = $Name;
                        "Coverage Type" = "Branch";
                        "Expected" = $MinCodeCoverage;
                        "Actual" = "$esc[1m$esc[0;31m$($BranchCoverage)$esc[0m"
                    }
                )
            )
        }

        # Detect the over-coverage
        [int]$lowestReported = [math]::Min([math]::Truncate($LineCoverage), [math]::Truncate($BranchCoverage));
        Write-Debug "line: $LineCoverage, branch: $BranchCoverage, min: $lowestReported, threshold: $MinCodeCoverage"
        if ([int]$MinCodeCoverage -lt $lowestReported) {
            [void]$Kudos.Add(
                (
                    New-Object PSObject -Property @{
                        "Project" = $Name;
                        "Expected" = $MinCodeCoverage;
                        "Actual" = "$esc[1m$esc[0;32m$($lowestReported)$esc[0m";
                    }
                )
            )
        }

        if ($IsFailed) { Write-Host "$Name" -NoNewline; Write-Host " ...failed validation" -ForegroundColor Red }
                  else { Write-Host "$Name" -NoNewline; Write-Host " ...ok" -ForegroundColor Green }
    }
    else {
        Write-Host "$Name ...skipping"
    }
}

if ($Kudos.Count -ne 0)
{
    Write-Header -message "`r`nGood job! The coverage increased" -isError $false
    $Kudos | `
        Sort-Object Project | `
        Format-Table "Project", `
                    @{ Name="Expected"; Expression="Expected"; Width=10; Alignment = "Right" }, `
                    @{ Name="Actual"; Expression="Actual"; Width=10; Alignment = "Right" } `
                    -AutoSize -Wrap
    Write-Host "##vso[task.logissue type=warning;]Good job! The coverage increased, please update your projects"
}

if ($Errors.Count -eq 0)
{
    Write-Host "`r`nAll good, no issues found."
    exit 0;
}

Write-Header -message "`r`n[!!] Found $($Errors.Count) issues!" -isError ($Errors.Count -ne 0)
$Errors | `
    Sort-Object Project, 'Coverage Type' | `
    Format-Table "Project", `
                @{ Name="Expected"; Expression="Expected"; Width=10; Alignment = "Right" }, `
                @{ Name="Actual"; Expression="Actual"; Width=10; Alignment = "Right" }, `
                @{ Name="Coverage Type"; Expression="Coverage Type"; Width=10; Alignment = "Center" } `
                -AutoSize -Wrap
exit -1;

