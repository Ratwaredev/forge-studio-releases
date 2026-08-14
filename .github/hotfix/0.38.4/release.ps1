$ErrorActionPreference = 'Stop'
function A([bool]$ok,[string]$message){ if(-not $ok){ throw $message } }
function Godot([string]$appRoot){
  $root = Join-Path $appRoot 'toolchains\godot'
  $g = Get-ChildItem $root -Filter '*_console.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if(-not $g){ $g = Get-ChildItem $root -Filter 'Godot_v4*.exe' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '_console\.exe$' } | Select-Object -First 1 }
  if(-not $g){ throw 'Bundled Godot missing.' }
  return $g.FullName
}
function SmokeGodot([string]$godot,[string]$label){
  $root = Join-Path $env:RUNNER_TEMP "forge-0384-godot-$label"
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $root | Out-Null
  "config_version=5`n[application]`nrun/main_scene=`"res://main.tscn`"`n" | Set-Content -Encoding utf8NoBOM (Join-Path $root 'project.godot')
  "extends Node`nfunc _ready():`n print(`"FORGE_0384_GODOT_OK`")`n get_tree().quit()`n" | Set-Content -Encoding utf8NoBOM (Join-Path $root 'main.gd')
  "[gd_scene load_steps=2 format=3]`n[ext_resource path=`"res://main.gd`" type=`"Script`" id=`"1`"]`n[node name=`"Main`" type=`"Node`"]`nscript=ExtResource(`"1`")`n" | Set-Content -Encoding utf8NoBOM (Join-Path $root 'main.tscn')
  $output = (& $godot --headless --path $root 2>&1 | Out-String)
  A ($LASTEXITCODE -eq 0 -and $output -match 'FORGE_0384_GODOT_OK') "Godot smoke failed ($label).`n$output"
  Write-Host "FORGE_0384_GODOT_SMOKE_OK $label"
}
function TestFastZip([string]$appRoot){
  $fixture = Join-Path $env:RUNNER_TEMP 'forge-0384-zip-fixture'
  $archive = Join-Path $env:RUNNER_TEMP 'forge-0384-many-files.zip'
  $output = Join-Path $env:RUNNER_TEMP 'forge-0384-zip-output'
  Remove-Item $fixture,$archive,$output -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $fixture | Out-Null
  1..800 | ForEach-Object { "asset $_" | Set-Content -Encoding utf8NoBOM (Join-Path $fixture ("asset-{0:D4}.txt" -f $_)) }
  Compress-Archive -Path (Join-Path $fixture '*') -DestinationPath $archive -CompressionLevel Fastest
  $module = (Join-Path $appRoot 'dist\shared\zip.js').Replace('\','/')
  $archiveJs = $archive.Replace('\','/').Replace("'","\'")
  $outputJs = $output.Replace('\','/').Replace("'","\'")
  $script = "import('file:///$module').then(async m=>{const t=Date.now();await m.extractZip('$archiveJs','$outputJs');console.log('FORGE_0384_ZIP_MS='+(Date.now()-t))}).catch(e=>{console.error(e);process.exit(1)})"
  $result = (& node --input-type=module -e $script 2>&1 | Out-String)
  A ($LASTEXITCODE -eq 0 -and $result -match 'FORGE_0384_ZIP_MS=') "Fast ZIP smoke failed.`n$result"
  A ((Get-ChildItem $output -File).Count -eq 800) 'Fast ZIP extractor lost files.'
  $ms = [int]([regex]::Match($result,'FORGE_0384_ZIP_MS=(\d+)').Groups[1].Value)
  A ($ms -lt 20000) "Fast ZIP extractor is unexpectedly slow: ${ms}ms"
  Write-Host "FORGE_0384_FAST_ZIP_OK ${ms}ms"
}

$repo = $env:GITHUB_REPOSITORY
if(-not $repo){ $repo = 'Ratwaredev/forge-studio-releases' }
$baseDir = Join-Path $env:RUNNER_TEMP 'forge-0384-base-download'
$baseInstall = Join-Path $env:RUNNER_TEMP 'forge-0384-base-install'
$patched = Join-Path $env:RUNNER_TEMP 'forge-0384-prepackaged'
Remove-Item $baseDir,$baseInstall,$patched -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $baseDir | Out-Null

$name0383 = 'Forge-Studio-Setup-0.38.3-x64.exe'
gh release download v0.38.3 --repo $repo --pattern $name0383 --dir $baseDir
$baseInstaller = Join-Path $baseDir $name0383
A (Test-Path $baseInstaller) 'Could not download Forge 0.38.3 base.'
$expected0383 = '7b4c774e44adcc608ff07c8963dc9efe87877b5a79bd38ba565bbb18201d881a'
$actual0383 = (Get-FileHash $baseInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
A ($actual0383 -eq $expected0383) "0.38.3 base checksum mismatch: $actual0383"
$installResult = Start-Process -FilePath $baseInstaller -ArgumentList '/S', "/D=$baseInstall" -Wait -PassThru
A ($installResult.ExitCode -eq 0) "0.38.3 base install failed: $($installResult.ExitCode)"
$baseApp = Join-Path $baseInstall 'resources\app'
A ((node -p "require('$($baseApp.Replace('\','/'))/package.json').version") -eq '0.38.3') 'Base payload is not 0.38.3.'
$baseGodot = Godot $baseApp
SmokeGodot $baseGodot 'base'
Copy-Item $baseInstall $patched -Recurse
Remove-Item (Join-Path $patched 'Uninstall Forge Studio.exe') -Force -ErrorAction SilentlyContinue
$app = Join-Path $patched 'resources\app'

# Version
$packagePath = Join-Path $app 'package.json'
$package = Get-Content $packagePath -Raw | ConvertFrom-Json
A ($package.version -eq '0.38.3') "Unexpected package base $($package.version)"
$package.version = '0.38.4'
$package | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8NoBOM $packagePath

# Visible Activity + robust project deletion.
Copy-Item '.github/hotfix/0.38.4/forge-0384-fixes.js' (Join-Path $app 'public\forge-0384-fixes.js') -Force
$indexPath = Join-Path $app 'public\index.html'
$index = Get-Content $indexPath -Raw
if($index -notmatch 'forge-0384-fixes\.js'){
  A ($index -match '</body>') 'index.html has no closing body tag.'
  $index = $index.Replace('</body>', '  <script src="/forge-0384-fixes.js?build=forge-v0384"></script>' + "`n</body>")
  Set-Content -Encoding utf8NoBOM $indexPath $index
}

# Show ZIP identity instead of invented v0.1.x/Actual labels for old and new rows.
$appJsPath = Join-Path $app 'public\app.js'
$appJs = Get-Content $appJsPath -Raw
$labelOccurrences = ([regex]::Matches($appJs, 'version\.label \|\| "actual"')).Count
A ($labelOccurrences -ge 2) "Expected visible version labels in app.js, found $labelOccurrences"
$appJs = $appJs.Replace('version.label || "actual"', '(version.sourceOriginalName || version.label || "actual").replace(/\.zip$/i, "")')
Set-Content -Encoding utf8NoBOM $appJsPath $appJs

# Future imports use the ZIP filename as the default version label.
$serverPath = Join-Path $app 'dist\server\index.js'
$server = Get-Content $serverPath -Raw
$oldLabel = 'req.body.label || (replacingExisting ? "Actual" : incrementVersionLabel(previousLabel, projectVersions.length))'
A ($server.Contains($oldLabel)) 'Could not locate generated import label logic.'
$server = $server.Replace($oldLabel, 'req.body.label || path.basename(req.file.originalname, path.extname(req.file.originalname))')
Set-Content -Encoding utf8NoBOM $serverPath $server

# Run path: use the canonical local snapshot directly, avoid verbose Godot log floods,
# and keep detailed output only for explicit Validate.
$agentPath = Join-Path $app 'dist\agent\index.js'
$agent = Get-Content $agentPath -Raw
A ($agent.Contains('if (!fs.existsSync(sourceZip)) {')) 'Could not locate workspace source materialization.'
A ($agent.Contains('await extractZip(sourceZip, extracted);')) 'Could not locate workspace extraction.'
$agent = $agent.Replace('if (!fs.existsSync(sourceZip)) {', 'const localSourceZip = path.join(config.paths.projectsDir, claim.project.id, "current", "source.zip");' + "`n    if (!fs.existsSync(sourceZip) && !fs.existsSync(localSourceZip)) {")
$agent = $agent.Replace('await extractZip(sourceZip, extracted);', 'await extractZip(fs.existsSync(localSourceZip) ? localSourceZip : sourceZip, extracted);')
$agent = $agent.Replace(' --path . --verbose${resolution}', ' --path .${resolution}')
$agent = $agent.Replace(' --editor --path . --verbose', ' --editor --path .')
$agent = $agent.Replace(' ${shellQuote(sceneRelative)} --verbose', ' ${shellQuote(sceneRelative)}')
Set-Content -Encoding utf8NoBOM $agentPath $agent

# Safe bounded parallel extraction instead of one-file-at-a-time yauzl extraction.
Copy-Item '.github/hotfix/0.38.4/fast-zip.js' (Join-Path $app 'dist\shared\zip.js') -Force

# Faster local job pickup and less fake ready delay.
$configPath = Join-Path $app 'dist\shared\config.js'
$configJs = Get-Content $configPath -Raw
A ($configJs.Contains('pollMs: envInt("FORGE_AGENT_POLL_MS", 1500)')) 'Agent polling default changed unexpectedly.'
$configJs = $configJs.Replace('pollMs: envInt("FORGE_AGENT_POLL_MS", 1500)', 'pollMs: envInt("FORGE_AGENT_POLL_MS", 350)')
$configJs = $configJs.Replace('nativeReadyDelayMs: envInt("FORGE_NATIVE_READY_DELAY_MS", 4000)', 'nativeReadyDelayMs: envInt("FORGE_NATIVE_READY_DELAY_MS", 900)')
Set-Content -Encoding utf8NoBOM $configPath $configJs

# Patch contract checks before packaging.
$appJs = Get-Content $appJsPath -Raw
$agent = Get-Content $agentPath -Raw
$server = Get-Content $serverPath -Raw
$configJs = Get-Content $configPath -Raw
$fixes = Get-Content (Join-Path $app 'public\forge-0384-fixes.js') -Raw
A ($appJs -match 'sourceOriginalName') 'ZIP filename display patch missing.'
A ($server -match 'path\.basename\(req\.file\.originalname, path\.extname\(req\.file\.originalname\)\)') 'Future ZIP label patch missing.'
A ($agent -match 'localSourceZip') 'Local source fast path missing.'
A ($agent -notmatch '--path \. --verbose\$\{resolution\}') 'Verbose Godot Run survived.'
A ($configJs -match 'FORGE_AGENT_POLL_MS", 350') 'Fast agent poll missing.'
A ($fixes -match 'Actividad' -and $fixes -match 'Eliminar' -and $fixes -match 'cancel-active') 'Activity/delete UX patch missing.'
TestFastZip $app
SmokeGodot (Godot $app) 'patched'
Write-Host 'FORGE_0384_PATCH_OK'

# Wrap the verified prepackaged Electron app.
Remove-Item builder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory builder | Out-Null
Push-Location builder
@'
{
  "name":"forge-studio",
  "version":"0.38.4",
  "description":"Forge Studio startup and project management reliability release",
  "author":"Ratwaredev",
  "license":"MIT",
  "devDependencies":{"electron-builder":"26.15.3"},
  "build":{
    "appId":"com.ratwaredev.forgestudio",
    "productName":"Forge Studio",
    "electronVersion":"43.2.0",
    "generateUpdatesFilesForAllChannels":true,
    "directories":{"output":"release"},
    "win":{"target":["nsis"]},
    "nsis":{"oneClick":false,"perMachine":false,"allowToChangeInstallationDirectory":true,"createDesktopShortcut":true,"createStartMenuShortcut":true,"deleteAppDataOnUninstall":false,"artifactName":"Forge-Studio-Setup-${version}-${arch}.${ext}"},
    "publish":[{"provider":"github","owner":"Ratwaredev","repo":"forge-studio-releases","releaseType":"release"}]
  }
}
'@ | Set-Content -Encoding utf8NoBOM package.json
npm install
A ($LASTEXITCODE -eq 0) 'Unable to install electron-builder.'
$builder = Resolve-Path 'node_modules/.bin/electron-builder.cmd'
$env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
& $builder --prepackaged "$patched" --win nsis --x64 --publish never
$buildExit = $LASTEXITCODE
Pop-Location
A ($buildExit -eq 0) 'electron-builder failed.'

$name = 'Forge-Studio-Setup-0.38.4-x64.exe'
$installer = "builder/release/$name"
$blockmap = "$installer.blockmap"
$latest = 'builder/release/latest.yml'
foreach($file in @($installer,$blockmap,$latest)){ A (Test-Path $file) "Missing 0.38.4 artifact: $file" }
A ((Get-Item $installer).Length -gt 150MB) 'Installer is too small to retain bundled Godot.'
$feed = Get-Content $latest -Raw
A ($feed -match '(?m)^version:\s*0\.38\.4\s*$' -and $feed -match [regex]::Escape($name)) 'Generated updater feed is wrong.'

# Fresh-install the exact EXE and repeat critical validation.
$baseUninstaller = Join-Path $baseInstall 'Uninstall Forge Studio.exe'
if(Test-Path $baseUninstaller){ Start-Process -FilePath $baseUninstaller -ArgumentList '/S' -Wait | Out-Null }
$verify = Join-Path $env:RUNNER_TEMP 'forge-0384-final-install'
Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue
$verifyProcess = Start-Process -FilePath (Resolve-Path $installer) -ArgumentList '/S', "/D=$verify" -Wait -PassThru
A ($verifyProcess.ExitCode -eq 0) "0.38.4 fresh install failed: $($verifyProcess.ExitCode)"
$verifyApp = Join-Path $verify 'resources\app'
A ((node -p "require('$($verifyApp.Replace('\','/'))/package.json').version") -eq '0.38.4') 'Fresh install version is not 0.38.4.'
$verifyGodot = Godot $verifyApp
$godotVersion = (& $verifyGodot --version 2>&1 | Out-String).Trim()
A ($LASTEXITCODE -eq 0 -and $godotVersion -match '^4\.7\.1') "Final bundled Godot is invalid: $godotVersion"
SmokeGodot $verifyGodot 'installed'
TestFastZip $verifyApp
$verifyAgent = Get-Content (Join-Path $verifyApp 'dist\agent\index.js') -Raw
$verifyServer = Get-Content (Join-Path $verifyApp 'dist\server\index.js') -Raw
$verifyAppJs = Get-Content (Join-Path $verifyApp 'public\app.js') -Raw
$verifyFixes = Get-Content (Join-Path $verifyApp 'public\forge-0384-fixes.js') -Raw
$verifyIndex = Get-Content (Join-Path $verifyApp 'public\index.html') -Raw
A ($verifyAgent -match 'localSourceZip' -and $verifyAgent -notmatch '--path \. --verbose\$\{resolution\}') 'Final Run fast path is missing.'
A ($verifyServer -match 'path\.basename\(req\.file\.originalname') 'Final ZIP label behavior is missing.'
A ($verifyAppJs -match 'sourceOriginalName') 'Final old-version display fix is missing.'
A ($verifyFixes -match 'Actividad' -and $verifyFixes -match 'Eliminar') 'Final Activity/Delete UI is missing.'
A ($verifyIndex -match 'forge-0384-fixes\.js\?build=forge-v0384') 'Final UI cache key is missing.'

$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name" | Set-Content -Encoding ascii 'builder/release/SHA256SUMS.txt'
Write-Host "FORGE_0384_INSTALLER_OK Godot=$godotVersion SHA256=$hash"
@"
# Forge Studio v0.38.4

Small reliability release focused on the real desktop workflow.

- Removes Godot `--verbose` from normal Run so Forge no longer forwards a flood of engine logs while the game is opening. Explicit Validate remains detailed.
- Uses the canonical local project ZIP directly instead of serving the same snapshot back to itself over local HTTP.
- Replaces serial ZIP extraction with bounded parallel extraction while preserving path-traversal checks.
- Reduces local agent pickup latency and the artificial native-ready delay.
- Shows imported versions by the original ZIP filename; future imports use that filename by default instead of synthetic v0.1.x / Actual labels.
- Adds a visible Activity action in the workspace.
- Adds a visible, robust Delete action that cancels active work first and then removes the project.
- Keeps bundled Godot Engine 4.7.1 and verifies a real Godot scene before and after packaging.
"@ | Set-Content -Encoding utf8 'builder/release/RELEASE_NOTES.md'

$tag = 'v0.38.4'
$assets = @($installer,$blockmap,$latest,'builder/release/SHA256SUMS.txt')
if(gh release view $tag --repo $repo 2>$null){
  gh release upload $tag @assets --repo $repo --clobber
  gh release edit $tag --repo $repo --title 'Forge Studio v0.38.4' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}else{
  gh release create $tag @assets --repo $repo --target main --title 'Forge Studio v0.38.4' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}

$published = Join-Path $env:RUNNER_TEMP 'forge-0384-published'
Remove-Item $published -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $published | Out-Null
gh release download $tag --repo $repo --dir $published
foreach($file in @($name,"$name.blockmap",'latest.yml','SHA256SUMS.txt')){ A (Test-Path (Join-Path $published $file)) "Published asset missing: $file" }
$publishedHash = (Get-FileHash (Join-Path $published $name) -Algorithm SHA256).Hash.ToLowerInvariant()
$declared = ((Get-Content (Join-Path $published 'SHA256SUMS.txt') -Raw).Trim().Split(' ')[0]).ToLowerInvariant()
A ($publishedHash -eq $hash -and $publishedHash -eq $declared) 'Published installer checksum mismatch.'
$publishedFeed = Get-Content (Join-Path $published 'latest.yml') -Raw
A ($publishedFeed -match '(?m)^version:\s*0\.38\.4\s*$' -and $publishedFeed -match [regex]::Escape($name)) 'Published latest.yml is wrong.'
Write-Host "FORGE_0384_RELEASE_OK $publishedHash"
