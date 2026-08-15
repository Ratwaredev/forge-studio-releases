$ErrorActionPreference = 'Stop'
function A([bool]$ok,[string]$message){ if(-not $ok){ throw $message } }
function Godot([string]$appRoot){
  $root = Join-Path $appRoot 'toolchains\godot'
  $g = Get-ChildItem $root -Filter '*_console.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if(-not $g){ $g = Get-ChildItem $root -Filter 'Godot_v4*.exe' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '_console\.exe$' } | Select-Object -First 1 }
  if(-not $g){ throw 'Bundled Godot missing.' }
  return $g.FullName
}

$repo = $env:GITHUB_REPOSITORY
if(-not $repo){ $repo = 'Ratwaredev/forge-studio-releases' }
$baseDir = Join-Path $env:RUNNER_TEMP 'forge-0386-base-download'
$baseInstall = Join-Path $env:RUNNER_TEMP 'forge-0386-base-install'
$patched = Join-Path $env:RUNNER_TEMP 'forge-0386-prepackaged'
Remove-Item $baseDir,$baseInstall,$patched -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $baseDir | Out-Null

$name0385 = 'Forge-Studio-Setup-0.38.5-x64.exe'
gh release download v0.38.5 --repo $repo --pattern $name0385 --dir $baseDir
$baseInstaller = Join-Path $baseDir $name0385
A (Test-Path $baseInstaller) 'Could not download Forge 0.38.5 base.'
$expected0385 = 'c69275b4f07eede0917ef27ffc1097c59031164deb60f318fcec6ebfac5e5c16'
$actual0385 = (Get-FileHash $baseInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
A ($actual0385 -eq $expected0385) "0.38.5 base checksum mismatch: $actual0385"
$installResult = Start-Process -FilePath $baseInstaller -ArgumentList '/S', "/D=$baseInstall" -Wait -PassThru
A ($installResult.ExitCode -eq 0) "0.38.5 base install failed: $($installResult.ExitCode)"
$baseApp = Join-Path $baseInstall 'resources\app'
A ((node -p "require('$($baseApp.Replace('\','/'))/package.json').version") -eq '0.38.5') 'Base payload is not 0.38.5.'
Copy-Item $baseInstall $patched -Recurse
Remove-Item (Join-Path $patched 'Uninstall Forge Studio.exe') -Force -ErrorAction SilentlyContinue
$app = Join-Path $patched 'resources\app'

# Version bump only; preserve the verified 0.38.5 backend, ZIP, Godot and critical-operation fixes.
$packagePath = Join-Path $app 'package.json'
$package = Get-Content $packagePath -Raw | ConvertFrom-Json
A ($package.version -eq '0.38.5') "Unexpected package base $($package.version)"
$package.version = '0.38.6'
$package | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8NoBOM $packagePath

# Runtime visibility fix: Activity must open the visible 0.34 log surface; blank embedded previews must explain themselves.
$runtimeFixSource = '.github/hotfix/0.38.6/forge-runtime-fix.js'
$runtimeFixPath = Join-Path $app 'public\forge-0386-runtime-fix.js'
Copy-Item $runtimeFixSource $runtimeFixPath -Force
$indexPath = Join-Path $app 'public\index.html'
$index = Get-Content $indexPath -Raw
if($index -notmatch 'forge-0386-runtime-fix\.js'){
  A ($index -match '</body>') 'index.html has no closing body tag.'
  $index = $index.Replace('</body>', '  <script src="/forge-0386-runtime-fix.js?build=forge-v0386"></script>' + "`n</body>")
  Set-Content -Encoding utf8NoBOM $indexPath $index
}

# Preserve the 0.38.5 reliability hotfix and prove the exact UI bug we are bridging still exists in the base payload.
$criticalPath = Join-Path $app 'public\forge-critical-ops.js'
$serverPath = Join-Path $app 'dist\server\index.js'
$workbenchCssPath = Join-Path $app 'public\forge-workbench-034.css'
A (Test-Path $criticalPath) '0.38.5 critical operation bridge disappeared.'
A (Test-Path $serverPath) '0.38.5 server payload missing.'
A (Test-Path $workbenchCssPath) '0.38.5 workbench CSS missing.'
$critical = Get-Content $criticalPath -Raw
$server = Get-Content $serverPath -Raw
$workbenchCss = Get-Content $workbenchCssPath -Raw
A ($critical -match 'cancel-active' -and $critical -match 'method: "DELETE"') '0.38.5 critical operation behavior regressed.'
A ($server -match 'cancellationDeadline = Date\.now\(\) \+ 12000') '0.38.5 backend cancellation behavior regressed.'
A ($workbenchCss -match '\.activity-panel,[\s\S]*display: none !important') 'Expected 0.34 hidden legacy activity panel invariant changed; review the hotfix before release.'

# Static hotfix gates.
$runtimeFix = Get-Content $runtimeFixPath -Raw
$index = Get-Content $indexPath -Raw
A ($index -match 'forge-0386-runtime-fix\.js\?build=forge-v0386') '0.38.6 runtime bridge was not injected.'
A ($runtimeFix -match '#forgeActivityButton,\[data-workspace-action="terminal"\]') 'Activity bridge trigger is missing.'
A ($runtimeFix -match 'data-forge034-view="terminal"') 'Visible Activity target is missing.'
A ($runtimeFix -match 'stopImmediatePropagation') 'Legacy hidden drawer is not blocked.'
A ($runtimeFix -match 'La app arrancó, pero el preview quedó vacío') 'Blank-preview diagnosis is missing.'
A ($runtimeFix -match 'url\.origin !== location\.origin' -and $runtimeFix -match 'startsWith\("/preview/"\)') 'Preview health same-origin boundary is missing.'
A ($runtimeFix -notmatch 'MutationObserver' -and $runtimeFix -notmatch 'setInterval') 'Renderer polling/observer regression detected.'
& node --check $runtimeFixPath
A ($LASTEXITCODE -eq 0) '0.38.6 runtime fix JS syntax check failed.'
Write-Host 'FORGE_0386_PATCH_OK'

# Wrap the verified 0.38.5 app as 0.38.6.
Remove-Item builder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory builder | Out-Null
Push-Location builder
@'
{
  "name":"forge-studio",
  "version":"0.38.6",
  "description":"Forge Studio runtime visibility hotfix",
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

$name = 'Forge-Studio-Setup-0.38.6-x64.exe'
$installer = "builder/release/$name"
$blockmap = "$installer.blockmap"
$latest = 'builder/release/latest.yml'
foreach($file in @($installer,$blockmap,$latest)){ A (Test-Path $file) "Missing 0.38.6 artifact: $file" }
A ((Get-Item $installer).Length -gt 150MB) 'Installer is too small to retain bundled Godot.'

# Fresh install: version, Godot and runtime fix must all survive packaging.
$baseUninstaller = Join-Path $baseInstall 'Uninstall Forge Studio.exe'
if(Test-Path $baseUninstaller){ Start-Process -FilePath $baseUninstaller -ArgumentList '/S' -Wait | Out-Null }
$verify = Join-Path $env:RUNNER_TEMP 'forge-0386-final-install'
Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue
$verifyProcess = Start-Process -FilePath (Resolve-Path $installer) -ArgumentList '/S', "/D=$verify" -Wait -PassThru
A ($verifyProcess.ExitCode -eq 0) "0.38.6 fresh install failed: $($verifyProcess.ExitCode)"
$verifyApp = Join-Path $verify 'resources\app'
A ((node -p "require('$($verifyApp.Replace('\','/'))/package.json').version") -eq '0.38.6') 'Fresh install version is not 0.38.6.'
$godotVersion = (& (Godot $verifyApp) --version 2>&1 | Out-String).Trim()
A ($LASTEXITCODE -eq 0 -and $godotVersion -match '^4\.7\.1') "Bundled Godot changed unexpectedly: $godotVersion"
$verifyIndex = Get-Content (Join-Path $verifyApp 'public\index.html') -Raw
$verifyRuntime = Get-Content (Join-Path $verifyApp 'public\forge-0386-runtime-fix.js') -Raw
$verifyCritical = Get-Content (Join-Path $verifyApp 'public\forge-critical-ops.js') -Raw
$verifyServer = Get-Content (Join-Path $verifyApp 'dist\server\index.js') -Raw
A ($verifyIndex -match 'forge-0386-runtime-fix\.js\?build=forge-v0386') 'Installed runtime hotfix missing.'
A ($verifyRuntime -match 'stopImmediatePropagation' -and $verifyRuntime -match 'preview quedó vacío') 'Installed runtime fix is incomplete.'
A ($verifyCritical -match 'cancel-active' -and $verifyCritical -match 'method: "DELETE"') 'Installed 0.38.5 critical bridge regressed.'
A ($verifyServer -match 'cancellationDeadline = Date\.now\(\) \+ 12000') 'Installed 0.38.5 server hotfix regressed.'

$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name" | Set-Content -Encoding ascii 'builder/release/SHA256SUMS.txt'
@"
# Forge Studio v0.38.6

Runtime visibility hotfix for the 0.38 workbench.

- `Actividad` now opens the visible workbench log view instead of the legacy drawer hidden by the 0.34 layout.
- The top `Terminal` tab is presented consistently as `Actividad`.
- Embedded previews that load a Forge proxy error or remain visually empty now show a compact explanation and a direct `Abrir Actividad` action instead of a silent white frame.
- No backend, ZIP, Godot, project-operation or updater behavior was changed from 0.38.5.
"@ | Set-Content -Encoding utf8 'builder/release/RELEASE_NOTES.md'

$tag = 'v0.38.6'
$assets = @($installer,$blockmap,$latest,'builder/release/SHA256SUMS.txt')
if(gh release view $tag --repo $repo 2>$null){
  gh release upload $tag @assets --repo $repo --clobber
  gh release edit $tag --repo $repo --title 'Forge Studio v0.38.6' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}else{
  gh release create $tag @assets --repo $repo --target main --title 'Forge Studio v0.38.6' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}

$published = Join-Path $env:RUNNER_TEMP 'forge-0386-published'
Remove-Item $published -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $published | Out-Null
gh release download $tag --repo $repo --dir $published
foreach($file in @($name,"$name.blockmap",'latest.yml','SHA256SUMS.txt')){ A (Test-Path (Join-Path $published $file)) "Published asset missing: $file" }
$publishedHash = (Get-FileHash (Join-Path $published $name) -Algorithm SHA256).Hash.ToLowerInvariant()
$declared = ((Get-Content (Join-Path $published 'SHA256SUMS.txt') -Raw).Trim().Split(' ')[0]).ToLowerInvariant()
A ($publishedHash -eq $hash -and $publishedHash -eq $declared) 'Published installer checksum mismatch.'
Write-Host "FORGE_0386_RELEASE_OK $publishedHash"
