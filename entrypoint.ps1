<#
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Profile
)

$ErrorActionPreference = "Stop"
. ./ps-cibootstrap/bootstrap.ps1

########
# Capture version information
$version = @($Env:GITHUB_REF, "v0.1.0") | Select-ValidVersions -First -Required

Write-Information "Version:"
$version

########
# Build stage
Invoke-CIProfile -Name $Profile -Steps @{

    lint = @{
        Script = {
            Use-PowershellGallery
            Install-Module PSScriptAnalyzer -Scope CurrentUser
            Import-Module PSScriptAnalyzer
            $results = Invoke-ScriptAnalyzer -IncludeDefaultRules -Recurse .
            if ($null -ne $results)
            {
                $results
                Write-Error "Linting failure"
            }
        }
    }

    build = @{
        Script = {
            # Template PowerShell module definition
            Write-Information "Templating TrelloTaskMgmt.psd1"
            Format-TemplateFile -Template source/TrelloTaskMgmt.psd1.tpl -Target source/TrelloTaskMgmt/TrelloTaskMgmt.psd1 -Content @{
                __FULLVERSION__ = $version.PlainVersion
            }

            # Trust powershell gallery
            Write-Information "Setup for access to powershell gallery"
            Use-PowerShellGallery

            # Install any dependencies for the module manifest
            Write-Information "Installing required dependencies from manifest"
            Install-PSModuleFromManifest -ManifestPath source/TrelloTaskMgmt/TrelloTaskMgmt.psd1

            # Test the module manifest
            Write-Information "Testing module manifest"
            Test-ModuleManifest source/TrelloTaskMgmt/TrelloTaskMgmt.psd1

            # Import modules as test
            Write-Information "Importing module"
            Import-Module ./source/TrelloTaskMgmt/TrelloTaskMgmt.psm1
        }
    }

    pr = @{
        # Dependencies = $("lint", "build")
        Dependencies = $("build")
    }

    latest = @{
        # Dependencies = $("lint", "build")
        Dependencies = $("build")
    }

    release = @{
        Dependencies = $("build")
        Script = {
            $owner = "archmachina"
            $repo = "ps-trellotaskmgmt"

            $releaseParams = @{
                Owner = $owner
                Repo = $repo
                Name = ("Release " + $version.Tag)
                TagName = $version.Tag
                Draft = $false
                Prerelease = $version.IsPrerelease
                Token = $Env:GITHUB_TOKEN
            }

            Write-Information "Creating release"
            New-GithubRelease @releaseParams

            Publish-Module -Path ./source/TrelloTaskMgmt -NuGetApiKey $Env:NUGET_API_KEY
        }
    }
}
