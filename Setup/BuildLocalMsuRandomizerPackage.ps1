[CmdletBinding()]
param(
    [string]$ConfigRepository = (Join-Path $PSScriptRoot "..\..\ALttPMSUShuffler"),
    [string]$RandomizerRepository = (Join-Path $PSScriptRoot "..\..\MSURandomizer"),
    [string]$PackageVersion
)

$ErrorActionPreference = "Stop"
$scripterRepository = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$configRepository = (Resolve-Path $ConfigRepository).Path
$randomizerRepository = (Resolve-Path $RandomizerRepository).Path
$bundleScript = Join-Path $configRepository "CreateBundle.ps1"
$bundlePath = Join-Path $configRepository "msu_types.json"
$libraryProject = Join-Path $randomizerRepository "MSURandomizerLibrary\MSURandomizerLibrary.csproj"
$libraryTypes = Join-Path $randomizerRepository "MSURandomizerLibrary\msu_types.json"
$libraryTests = Join-Path $randomizerRepository "MSURandomizerLibraryTests\MSURandomizerLibraryTests.csproj"
$yamlTemplates = Join-Path $randomizerRepository "Docs\YamlTemplates"
$packageSource = Join-Path $scripterRepository ".local-packages"
$localProps = Join-Path $scripterRepository "MSUScripter.Local.props"

foreach ($path in @($bundleScript, $libraryProject, $libraryTypes, $libraryTests))
{
    if (!(Test-Path -LiteralPath $path)) { throw "Required file not found: $path" }
}

$dirtyTypes = git -C $randomizerRepository status --porcelain -- "MSURandomizerLibrary/msu_types.json"
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect the MSURandomizer worktree" }
if ($dirtyTypes) { throw "MSURandomizerLibrary/msu_types.json has local changes; preserve them before building the local package" }

$typesBackup = [IO.Path]::GetTempFileName()
$yamlBackup = Join-Path ([IO.Path]::GetTempPath()) "MSURandomizerYaml-$([guid]::NewGuid())"
$githubOutput = [IO.Path]::GetTempFileName()
$previousGithubOutput = $env:GITHUB_OUTPUT
$restoreTypes = $false
$restoreYaml = $false

try
{
    $env:GITHUB_OUTPUT = $githubOutput
    & $bundleScript

    $bundle = @(Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json)
    $quadRando = @($bundle | Where-Object { $_.meta.path -eq "snes/quad-rando" })
    if ($quadRando.Count -ne 1) { throw "Generated bundle must contain exactly one snes/quad-rando entry" }
    if (@($quadRando[0].copy | Where-Object { $_.msu -eq "snes/z3m3" }).Count -ne 1)
    {
        throw "Generated Quad rando config must copy snes/z3m3"
    }

    Copy-Item -LiteralPath $libraryTypes -Destination $typesBackup -Force
    Copy-Item -LiteralPath $bundlePath -Destination $libraryTypes -Force
    $restoreTypes = $true
    Copy-Item -LiteralPath $yamlTemplates -Destination $yamlBackup -Recurse
    $restoreYaml = $true

    & dotnet test $libraryTests --nologo
    if ($LASTEXITCODE -ne 0) { throw "MSURandomizer library tests failed" }

    if (!$PackageVersion)
    {
        [xml]$project = Get-Content -LiteralPath $libraryProject -Raw
        $baseVersion = @($project.Project.PropertyGroup.Version)[0]
        $PackageVersion = "$baseVersion-local.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    }

    New-Item -ItemType Directory -Path $packageSource -Force | Out-Null
    & dotnet pack $libraryProject --configuration Release --output $packageSource --nologo "-p:PackageVersion=$PackageVersion" -p:GeneratePackageOnBuild=false
    if ($LASTEXITCODE -ne 0) { throw "MSURandomizer library package build failed" }

    $escapedPackageSource = [Security.SecurityElement]::Escape($packageSource)
    $props = @"
<Project>
  <PropertyGroup>
    <MsuRandomizerLibraryVersion>$PackageVersion</MsuRandomizerLibraryVersion>
    <RestoreAdditionalProjectSources>$escapedPackageSource</RestoreAdditionalProjectSources>
  </PropertyGroup>
</Project>
"@
    [IO.File]::WriteAllText($localProps, $props, [Text.UTF8Encoding]::new($false))

    & dotnet restore (Join-Path $scripterRepository "MSUScripter.sln") --force-evaluate --nologo
    if ($LASTEXITCODE -ne 0) { throw "MSUScripter restore failed" }
    & dotnet build (Join-Path $scripterRepository "MSUScripter.sln") --no-restore --nologo
    if ($LASTEXITCODE -ne 0) { throw "MSUScripter build failed" }

    $assetPaths = @(
        (Join-Path $scripterRepository "MSUScripter\obj\project.assets.json"),
        (Join-Path $scripterRepository "SchemaGenerator\obj\project.assets.json")
    )
    $missingPackage = $assetPaths.Where({
        $assets = Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json -AsHashtable
        !$assets.libraries.ContainsKey("MattEqualsCoder.MSURandomizer.Library/$PackageVersion")
    })
    if ($missingPackage.Count -gt 0)
    {
        throw "The solution did not restore MattEqualsCoder.MSURandomizer.Library $PackageVersion in: $($missingPackage -join ', ')"
    }

    [pscustomobject]@{
        PackageVersion = $PackageVersion
        PackageSource = $packageSource
        LocalProperties = $localProps
    }
}
finally
{
    if ($restoreTypes) { Copy-Item -LiteralPath $typesBackup -Destination $libraryTypes -Force }
    if ($restoreYaml)
    {
        Remove-Item -LiteralPath $yamlTemplates -Recurse -Force
        Move-Item -LiteralPath $yamlBackup -Destination $yamlTemplates
    }
    if ($null -eq $previousGithubOutput) { Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue }
    else { $env:GITHUB_OUTPUT = $previousGithubOutput }
    Remove-Item -LiteralPath $typesBackup, $yamlBackup, $githubOutput -Recurse -Force -ErrorAction SilentlyContinue
}
