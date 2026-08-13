$ErrorActionPreference = 'Stop'

function Assert-True([bool]$condition, [string]$message) {
  if (-not $condition) { throw $message }
}

function Get-ForgeGodot([string]$appRoot) {
  $root = Join-Path $appRoot 'toolchains\godot'
  $console = Join-Path $root 'Godot_v4.7.1-stable_win64_console.exe'
  $editor = Join-Path $root 'Godot_v4.7.1-stable_win64.exe'
  if (Test-Path $console) { return $console }
  if (Test-Path $editor) { return $editor }
  throw 'Bundled Godot executable is missing.'
}

function Test-GodotProject([string]$godot) {
  $smoke = Join-Path $env:RUNNER_TEMP 'forge-godot-smoke'
  Remove-Item $smoke -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $smoke | Out-Null
  @'
config_version=5
[application]
run/main_scene="res://main.tscn"
[rendering]
renderer/rendering_method="gl_compatibility"
'@ | Set-Content -Encoding utf8NoBOM (Join-Path $smoke 'project.godot')
  @'
extends Node
func _ready():
    print("FORGE_GODOT_SMOKE_OK")
    get_tree().quit()
'@ | Set-Content -Encoding utf8NoBOM (Join-Path $smoke 'main.gd')
  @'
[gd_scene load_steps=2 format=3]
[ext_resource path="res://main.gd" type="Script" id="1"]
[node name="Main" type="Node"]
script = ExtResource("1")
'@ | Set-Content -Encoding utf8NoBOM (Join-Path $smoke 'main.tscn')
  $output = (& $godot --headless --path $smoke --verbose 2>&1 | Out-String)
  Assert-True ($LASTEXITCODE -eq 0 -and $output -match 'FORGE_GODOT_SMOKE_OK') "Bundled Godot could not run a real project.`n$output"
  Write-Host 'FORGE_GODOT_PROJECT_OK'
}

$repo = $env:GITHUB_REPOSITORY
if (-not $repo) { $repo = 'Ratwaredev/forge-studio-releases' }
$baseDownload = Join-Path $env:RUNNER_TEMP 'forge-0381-download'
$baseInstall = Join-Path $env:RUNNER_TEMP 'forge-0381-base'
$patched = Join-Path $env:RUNNER_TEMP 'forge-0382-prepackaged'
Remove-Item $baseDownload,$baseInstall,$patched -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $baseDownload | Out-Null

gh release download v0.38.1 --repo $repo --pattern 'Forge-Studio-Setup-0.38.1-x64.exe' --dir $baseDownload
$baseInstaller = Join-Path $baseDownload 'Forge-Studio-Setup-0.38.1-x64.exe'
Assert-True (Test-Path $baseInstaller) 'Forge 0.38.1 base installer was not downloaded.'
$baseProcess = Start-Process -FilePath $baseInstaller -ArgumentList '/S', "/D=$baseInstall" -Wait -PassThru
Assert-True ($baseProcess.ExitCode -eq 0) "Forge 0.38.1 installer exited with $($baseProcess.ExitCode)."
$baseApp = Join-Path $baseInstall 'resources\app'
$baseVersion = node -p "require('$($baseApp.Replace('\','/'))/package.json').version"
Assert-True ($baseVersion -eq '0.38.1') "Expected Forge 0.38.1 base, got $baseVersion."
Copy-Item $baseInstall $patched -Recurse
Remove-Item (Join-Path $patched 'Uninstall Forge Studio.exe') -Force -ErrorAction SilentlyContinue
$app = Join-Path $patched 'resources\app'

$godotDownload = Join-Path $env:RUNNER_TEMP 'godot-4.7.1'
Remove-Item $godotDownload -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $godotDownload | Out-Null
$archiveName = 'Godot_v4.7.1-stable_win64.exe.zip'
$expectedGodotSha = 'c7a289051eaefb460b0106b60e9cd5bee0ef55fd102dcb2bed1eb356cf3d90a1'
gh release download 4.7.1-stable --repo godotengine/godot-builds --pattern $archiveName --dir $godotDownload
$archive = Join-Path $godotDownload $archiveName
Assert-True (Test-Path $archive) 'Official Godot 4.7.1 archive was not downloaded.'
$godotArchiveSha = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-True ($godotArchiveSha -eq $expectedGodotSha) "Godot checksum mismatch: $godotArchiveSha"
$godotRoot = Join-Path $app 'toolchains\godot'
Remove-Item $godotRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $godotRoot | Out-Null
Expand-Archive -Path $archive -DestinationPath $godotRoot -Force
$godot = Get-ForgeGodot $app
$godotVersion = (& $godot --version 2>&1 | Out-String).Trim()
Assert-True ($LASTEXITCODE -eq 0 -and $godotVersion -match '^4\.7\.1') "Godot version smoke failed: $godotVersion"
@{
  schema = 1
  name = 'Godot Engine'
  version = '4.7.1-stable'
  archive = $archiveName
  sha256 = $expectedGodotSha
  source = 'https://github.com/godotengine/godot-builds/releases/tag/4.7.1-stable'
  verifiedVersion = $godotVersion
} | ConvertTo-Json | Set-Content -Encoding utf8NoBOM (Join-Path $godotRoot 'toolchain.json')
Write-Host "FORGE_GODOT_ARCHIVE_OK $godotVersion $godotArchiveSha"

$packagePath = Join-Path $app 'package.json'
$package = Get-Content $packagePath -Raw | ConvertFrom-Json
Assert-True ($package.version -eq '0.38.1') "Unexpected base package version: $($package.version)"
$package.version = '0.38.2'
$package | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8NoBOM $packagePath
Copy-Item '.github/hotfix/0.38.2/forge-runtime-guard.js' (Join-Path $app 'public\forge-runtime-guard.js') -Force
$indexPath = Join-Path $app 'public\index.html'
$index = Get-Content $indexPath -Raw
if ($index -notmatch 'forge-runtime-guard\.js') {
  $patchedIndex = $index -replace '(<script type="module" src="/app\.js[^\"]*\"></script>)', '<script src="/forge-runtime-guard.js?build=forge-v0382"></script>$1'
  Assert-True ($patchedIndex -ne $index) 'Could not inject runtime guard before app.js.'
  Set-Content -Encoding utf8NoBOM $indexPath $patchedIndex
}
@'
# Third-party notices

## Godot Engine 4.7.1-stable

Forge Studio for Windows bundles the official Godot Engine 4.7.1-stable x64 editor binaries.
Archive SHA-256: c7a289051eaefb460b0106b60e9cd5bee0ef55fd102dcb2bed1eb356cf3d90a1

Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
'@ | Set-Content -Encoding utf8NoBOM (Join-Path $app 'THIRD_PARTY_NOTICES.md')
Assert-True ((Get-Content (Join-Path $app 'public\product-surfaces.js') -Raw) -notmatch 'MutationObserver') '0.38.0 renderer regression reappeared.'
Assert-True ((Get-Content $indexPath -Raw) -match 'forge-runtime-guard\.js\?build=forge-v0382') 'Runtime guard was not loaded.'

Push-Location $app
try {
  $resolved = (& node --input-type=module -e "import('./dist/agent/tools.js').then(m=>{const p=m.findGodotExecutable(); if(!p) process.exit(2); console.log(p)})" 2>&1 | Out-String).Trim()
  Assert-True ($LASTEXITCODE -eq 0 -and $resolved -match 'toolchains[\\/]godot') "Forge resolver did not find bundled Godot: $resolved"
  Write-Host "FORGE_GODOT_RESOLVER_OK $resolved"
} finally { Pop-Location }
Test-GodotProject $godot

Remove-Item builder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory builder | Out-Null
Push-Location builder
@'
{
  "name": "forge-studio",
  "version": "0.38.2",
  "description": "Forge Studio with bundled Godot runtime",
  "author": "Ratwaredev",
  "license": "MIT",
  "devDependencies": { "electron-builder": "26.15.3" },
  "build": {
    "appId": "com.ratwaredev.forgestudio",
    "productName": "Forge Studio",
    "electronVersion": "43.2.0",
    "generateUpdatesFilesForAllChannels": true,
    "directories": { "output": "release" },
    "win": { "target": ["nsis"] },
    "nsis": {
      "oneClick": false,
      "perMachine": false,
      "allowToChangeInstallationDirectory": true,
      "createDesktopShortcut": true,
      "createStartMenuShortcut": true,
      "deleteAppDataOnUninstall": false,
      "artifactName": "Forge-Studio-Setup-${version}-${arch}.${ext}"
    },
    "publish": [{ "provider": "github", "owner": "Ratwaredev", "repo": "forge-studio-releases", "releaseType": "release" }]
  }
}
'@ | Set-Content -Encoding utf8NoBOM package.json
npm install
Assert-True ($LASTEXITCODE -eq 0) 'Unable to install electron-builder.'
$builder = Resolve-Path 'node_modules/.bin/electron-builder.cmd'
$env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
& $builder --prepackaged "$patched" --win nsis --x64 --publish never
$buildExit = $LASTEXITCODE
Pop-Location
Assert-True ($buildExit -eq 0) 'electron-builder prepackaged NSIS build failed.'

$name = 'Forge-Studio-Setup-0.38.2-x64.exe'
$installer = "builder/release/$name"
$blockmap = "$installer.blockmap"
$latest = 'builder/release/latest.yml'
foreach ($file in @($installer,$blockmap,$latest)) { Assert-True (Test-Path $file) "Missing 0.38.2 artifact: $file" }
Assert-True ((Get-Item $installer).Length -gt 150MB) '0.38.2 installer is too small to contain Forge plus Godot.'
$latestText = Get-Content $latest -Raw
Assert-True ($latestText -match '(?m)^version:\s*0\.38\.2\s*$' -and $latestText -match [regex]::Escape($name)) 'Updater feed does not target 0.38.2.'

$baseUninstaller = Join-Path $baseInstall 'Uninstall Forge Studio.exe'
if (Test-Path $baseUninstaller) { Start-Process -FilePath $baseUninstaller -ArgumentList '/S' -Wait | Out-Null }
$verifyInstall = Join-Path $env:RUNNER_TEMP 'forge-0382-verify'
Remove-Item $verifyInstall -Recurse -Force -ErrorAction SilentlyContinue
$verifyProcess = Start-Process -FilePath (Resolve-Path $installer) -ArgumentList '/S', "/D=$verifyInstall" -Wait -PassThru
Assert-True ($verifyProcess.ExitCode -eq 0) "0.38.2 installer exited with $($verifyProcess.ExitCode)."
$verifyApp = Join-Path $verifyInstall 'resources\app'
$verifyVersion = node -p "require('$($verifyApp.Replace('\','/'))/package.json').version"
Assert-True ($verifyVersion -eq '0.38.2') "Final installer installed version $verifyVersion instead of 0.38.2."
$verifyGodot = Get-ForgeGodot $verifyApp
$verifyGodotVersion = (& $verifyGodot --version 2>&1 | Out-String).Trim()
Assert-True ($LASTEXITCODE -eq 0 -and $verifyGodotVersion -match '^4\.7\.1') "Final bundled Godot is invalid: $verifyGodotVersion"
Assert-True (Test-Path (Join-Path $verifyApp 'public\forge-runtime-guard.js')) 'Final installer is missing runtime guard.'
Assert-True ((Get-Content (Join-Path $verifyApp 'public\index.html') -Raw) -match 'forge-runtime-guard\.js\?build=forge-v0382') 'Final UI does not load runtime guard.'
Assert-True ((Get-Content (Join-Path $verifyApp 'public\product-surfaces.js') -Raw) -notmatch 'MutationObserver') 'Final installer regressed the 0.38.1 renderer fix.'
Push-Location $verifyApp
try {
  $verifyResolved = (& node --input-type=module -e "import('./dist/agent/tools.js').then(m=>{const p=m.findGodotExecutable(); if(!p) process.exit(2); console.log(p)})" 2>&1 | Out-String).Trim()
  Assert-True ($LASTEXITCODE -eq 0 -and $verifyResolved -match 'toolchains[\\/]godot') "Installed Forge resolver cannot see bundled Godot: $verifyResolved"
} finally { Pop-Location }
Test-GodotProject $verifyGodot

$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name" | Set-Content -Encoding ascii 'builder/release/SHA256SUMS.txt'
Write-Host "FORGE_0382_INSTALLER_OK $verifyGodotVersion $hash"

@"
# Forge Studio v0.38.2

Godot execution recovery release.

- Bundles official Godot Engine 4.7.1-stable x64 inside Forge on Windows.
- Verifies the upstream Godot archive with pinned SHA-256 before packaging.
- Keeps Web export templates external; embedded preview falls back to native Godot when templates are unavailable.
- Adds a runtime preflight so a missing Godot capability fails visibly instead of leaving Ejecutar queued forever.
- Preserves the 0.38.1 renderer freeze fix.
"@ | Set-Content -Encoding utf8 'builder/release/RELEASE_NOTES.md'
$tag = 'v0.38.2'
$assets = @($installer,$blockmap,$latest,'builder/release/SHA256SUMS.txt')
if (gh release view $tag --repo $repo 2>$null) {
  gh release upload $tag @assets --repo $repo --clobber
  gh release edit $tag --repo $repo --title 'Forge Studio v0.38.2' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
} else {
  gh release create $tag @assets --repo $repo --target main --title 'Forge Studio v0.38.2' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}

$published = Join-Path $env:RUNNER_TEMP 'forge-0382-published'
Remove-Item $published -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $published | Out-Null
gh release download $tag --repo $repo --dir $published
$publishedInstaller = Join-Path $published $name
$publishedHash = (Get-FileHash $publishedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
$declaredHash = (Get-Content (Join-Path $published 'SHA256SUMS.txt') -Raw).Trim().Split(' ')[0].ToLowerInvariant()
Assert-True ($publishedHash -eq $hash -and $publishedHash -eq $declaredHash) 'Published 0.38.2 checksum mismatch.'
$publishedFeed = Get-Content (Join-Path $published 'latest.yml') -Raw
Assert-True ($publishedFeed -match '(?m)^version:\s*0\.38\.2\s*$' -and $publishedFeed -match [regex]::Escape($name)) 'Published updater feed is not 0.38.2.'
Write-Host "FORGE_0382_RELEASE_OK $publishedHash"
