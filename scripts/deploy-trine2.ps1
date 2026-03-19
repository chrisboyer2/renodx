param(
  [string]$GamePath = "E:\SteamLibrary\steamapps\common\Trine 2",
  [ValidateSet("x86", "x64")]
  [string]$Arch = "x86",
  [switch]$IncludeDevkit,
  [switch]$AllowDebugDevkit
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $GamePath)) {
  throw "Game path does not exist: $GamePath"
}

$addonSuffix = if ($Arch -eq "x64") { "64" } else { "32" }

function Resolve-FirstExistingPath {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Candidates
  )

  foreach ($candidate in $Candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  return $null
}

$releaseAddonCandidates = if ($Arch -eq "x64") {
  @(
    (Join-Path $repoRoot "build.vs\Release\renodx-trine2.addon$addonSuffix"),
    (Join-Path $repoRoot "build\Release\renodx-trine2.addon$addonSuffix")
  )
} else {
  @(
    (Join-Path $repoRoot "build32\Release\renodx-trine2.addon$addonSuffix")
  )
}

$releaseAddon = Resolve-FirstExistingPath -Candidates $releaseAddonCandidates
if ($null -eq $releaseAddon) {
  throw "Missing addon build output. Checked: $($releaseAddonCandidates -join ', ')"
}

Copy-Item -Force $releaseAddon (Join-Path $GamePath "renodx-trine2.addon$addonSuffix")

if ($IncludeDevkit) {
  $releaseDevkitCandidates = if ($Arch -eq "x64") {
    @(
      (Join-Path $repoRoot "build.vs\Release\renodx-devkit.addon$addonSuffix"),
      (Join-Path $repoRoot "build\Release\renodx-devkit.addon$addonSuffix")
    )
  } else {
    @(
      (Join-Path $repoRoot "build32\Release\renodx-devkit.addon$addonSuffix")
    )
  }

  $devkitAddon = Resolve-FirstExistingPath -Candidates $releaseDevkitCandidates

  if ($null -eq $devkitAddon -and $AllowDebugDevkit) {
    $debugDevkitCandidates = if ($Arch -eq "x64") {
      @(
        (Join-Path $repoRoot "build.vs\Debug\renodx-devkit.addon$addonSuffix"),
        (Join-Path $repoRoot "build\Debug\renodx-devkit.addon$addonSuffix")
      )
    } else {
      @(
        (Join-Path $repoRoot "build32\Debug\renodx-devkit.addon$addonSuffix")
      )
    }

    $devkitAddon = Resolve-FirstExistingPath -Candidates $debugDevkitCandidates
    if ($null -eq $devkitAddon) {
      throw "Missing devkit build output. Checked release: $($releaseDevkitCandidates -join ', '); checked debug: $($debugDevkitCandidates -join ', ')"
    }

    Write-Warning "Deploying a debug devkit build. This can trigger CRT heap assertions in retail game launches."
  }

  if ($null -eq $devkitAddon) {
    throw "Missing release devkit build output. Checked: $($releaseDevkitCandidates -join ', '). Build 'build.vs\\devkit.vcxproj' in Release or pass -AllowDebugDevkit if you intentionally want the debug devkit."
  }

  Copy-Item -Force $devkitAddon (Join-Path $GamePath "renodx-devkit.addon$addonSuffix")
}

Write-Host "Deployed renodx-trine2.addon$addonSuffix from $releaseAddon to $GamePath"
if ($IncludeDevkit) {
  Write-Host "Deployed renodx-devkit.addon$addonSuffix from $devkitAddon to $GamePath"
}
