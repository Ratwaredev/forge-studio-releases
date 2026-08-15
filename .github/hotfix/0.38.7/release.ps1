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
$baseDir = Join-Path $env:RUNNER_TEMP 'forge-0387-base-download'
$baseInstall = Join-Path $env:RUNNER_TEMP 'forge-0387-base-install'
$patched = Join-Path $env:RUNNER_TEMP 'forge-0387-prepackaged'
Remove-Item $baseDir,$baseInstall,$patched -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $baseDir | Out-Null

$name0386 = 'Forge-Studio-Setup-0.38.6-x64.exe'
gh release download v0.38.6 --repo $repo --pattern $name0386 --dir $baseDir
$baseInstaller = Join-Path $baseDir $name0386
A (Test-Path $baseInstaller) 'Could not download Forge 0.38.6 base.'
$expected0386 = '41280fd49f68ff027b739eac75daa2ff5fc184dfa0bc673bd85e8199a9f12139'
$actual0386 = (Get-FileHash $baseInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
A ($actual0386 -eq $expected0386) "0.38.6 base checksum mismatch: $actual0386"
$installResult = Start-Process -FilePath $baseInstaller -ArgumentList '/S', "/D=$baseInstall" -Wait -PassThru
A ($installResult.ExitCode -eq 0) "0.38.6 base install failed: $($installResult.ExitCode)"
$baseApp = Join-Path $baseInstall 'resources\app'
A ((node -p "require('$($baseApp.Replace('\','/'))/package.json').version") -eq '0.38.6') 'Base payload is not 0.38.6.'
Copy-Item $baseInstall $patched -Recurse
Remove-Item (Join-Path $patched 'Uninstall Forge Studio.exe') -Force -ErrorAction SilentlyContinue
$app = Join-Path $patched 'resources\app'

# Version bump only; preserve verified 0.38.6 runtime/project behavior.
$packagePath = Join-Path $app 'package.json'
$package = Get-Content $packagePath -Raw | ConvertFrom-Json
A ($package.version -eq '0.38.6') "Unexpected package base $($package.version)"
$package.version = '0.38.7'
$package | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8NoBOM $packagePath

# Replace the update surface with Forge-owned background-first UX.
Copy-Item '.github/hotfix/0.38.7/forge-update-control.js' (Join-Path $app 'public\forge-update-control-0387.js') -Force
Copy-Item '.github/hotfix/0.38.7/forge-update-control.css' (Join-Path $app 'public\forge-update-control-0387.css') -Force
$indexPath = Join-Path $app 'public\index.html'
$index = Get-Content $indexPath -Raw
if($index -notmatch 'forge-update-control-0387\.css'){
  A ($index -match '</head>') 'index.html has no closing head tag.'
  $index = $index.Replace('</head>', '  <link rel="stylesheet" href="/forge-update-control-0387.css?build=forge-v0387" />' + "`n</head>")
}
if($index -notmatch 'forge-update-control-0387\.js'){
  A ($index -match '</body>') 'index.html has no closing body tag.'
  $index = $index.Replace('</body>', '  <script src="/forge-update-control-0387.js?build=forge-v0387"></script>' + "`n</body>")
}
Set-Content -Encoding utf8NoBOM $indexPath $index

# Explicit restart from the in-app updater must be a silent NSIS handoff.
$mainPath = Join-Path $app 'desktop\main.cjs'
$main = Get-Content $mainPath -Raw
$oldInstall = 'autoUpdater.quitAndInstall(false, true);'
A ($main.Contains($oldInstall)) 'Expected interactive updater handoff was not found in 0.38.6 base.'
$main = $main.Replace($oldInstall, 'autoUpdater.quitAndInstall(true, true);')
Set-Content -Encoding utf8NoBOM $mainPath $main

# Static UX gates before packaging.
$updateJsPath = Join-Path $app 'public\forge-update-control-0387.js'
$updateCssPath = Join-Path $app 'public\forge-update-control-0387.css'
$updateJs = Get-Content $updateJsPath -Raw
$updateCss = Get-Content $updateCssPath -Raw
$index = Get-Content $indexPath -Raw
$main = Get-Content $mainPath -Raw
A ($index -match 'forge-update-control-0387\.css\?build=forge-v0387') '0.38.7 updater CSS not injected.'
A ($index -match 'forge-update-control-0387\.js\?build=forge-v0387') '0.38.7 updater JS not injected.'
A ($updateJs -match 'action\.textContent = "Reiniciar"') 'Single restart action missing.'
A ($updateJs -match 'Se instala solo al cerrar') 'Background install copy missing.'
A ($updateJs -notmatch 'downloadUpdate\(') 'Manual Download update flow survived.'
A ($main -match 'autoUpdater\.autoDownload = true') 'Automatic update download regressed.'
A ($main -match 'autoUpdater\.autoInstallOnAppQuit = true') 'Install-on-quit regressed.'
A ($main -match 'autoUpdater\.quitAndInstall\(true, true\)') 'Silent explicit updater handoff missing.'
A ($updateCss -match '#forgeUpdateToast') 'Forge updater surface styling missing.'
& node --check $updateJsPath
A ($LASTEXITCODE -eq 0) '0.38.7 updater JS syntax check failed.'
& node --check $mainPath
A ($LASTEXITCODE -eq 0) '0.38.7 patched desktop main syntax check failed.'
Write-Host 'FORGE_0387_PATCH_OK'

# Wrap verified 0.38.6 as a per-user one-click NSIS installer.
Remove-Item builder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force 'builder\build' | Out-Null
Push-Location builder
@'
{
  "name":"forge-studio",
  "version":"0.38.7",
  "description":"Forge Studio one-click installer and background updater UX",
  "author":"Ratwaredev",
  "license":"MIT",
  "devDependencies":{"electron-builder":"26.15.3"},
  "build":{
    "appId":"com.ratwaredev.forgestudio",
    "productName":"Forge Studio",
    "electronVersion":"43.2.0",
    "generateUpdatesFilesForAllChannels":true,
    "directories":{"output":"release"},
    "win":{"target":["nsis"],"icon":"build/icon.svg"},
    "nsis":{"oneClick":true,"perMachine":false,"createDesktopShortcut":true,"createStartMenuShortcut":true,"runAfterFinish":true,"deleteAppDataOnUninstall":false,"shortcutName":"Forge Studio","include":"build/installer.nsh","artifactName":"Forge-Studio-Setup-${version}-${arch}.${ext}"},
    "publish":[{"provider":"github","owner":"Ratwaredev","repo":"forge-studio-releases","releaseType":"release"}]
  }
}
'@ | Set-Content -Encoding utf8NoBOM package.json
@'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" rx="224" fill="#f7f7f4"/>
  <g transform="translate(512 512) rotate(45) translate(-512 -512)">
    <rect x="212" y="212" width="600" height="600" rx="124" fill="none" stroke="#1b1d1f" stroke-width="64"/>
    <rect x="374" y="374" width="276" height="276" rx="62" fill="none" stroke="#1b1d1f" stroke-width="52"/>
  </g>
</svg>
'@ | Set-Content -Encoding utf8NoBOM 'build\icon.svg'
@'
!macro customHeader
  BrandingText "Forge Studio"
!macroend
'@ | Set-Content -Encoding utf8NoBOM 'build\installer.nsh'
npm install
A ($LASTEXITCODE -eq 0) 'Unable to install electron-builder.'
$builder = Resolve-Path 'node_modules/.bin/electron-builder.cmd'
$env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
& $builder --prepackaged "$patched" --win nsis --x64 --publish never
$buildExit = $LASTEXITCODE
Pop-Location
A ($buildExit -eq 0) 'electron-builder failed.'

$name = 'Forge-Studio-Setup-0.38.7-x64.exe'
$installer = "builder/release/$name"
$blockmap = "$installer.blockmap"
$latest = 'builder/release/latest.yml'
foreach($file in @($installer,$blockmap,$latest)){ A (Test-Path $file) "Missing 0.38.7 artifact: $file" }
A ((Get-Item $installer).Length -gt 150MB) 'Installer is too small to retain bundled Godot.'

# Fresh install: version, Godot and every previous reliability fix must survive.
$baseUninstaller = Join-Path $baseInstall 'Uninstall Forge Studio.exe'
if(Test-Path $baseUninstaller){ Start-Process -FilePath $baseUninstaller -ArgumentList '/S' -Wait | Out-Null }
$verify = Join-Path $env:RUNNER_TEMP 'forge-0387-final-install'
Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue
$verifyProcess = Start-Process -FilePath (Resolve-Path $installer) -ArgumentList '/S', "/D=$verify" -Wait -PassThru
A ($verifyProcess.ExitCode -eq 0) "0.38.7 fresh install failed: $($verifyProcess.ExitCode)"
$verifyApp = Join-Path $verify 'resources\app'
A ((node -p "require('$($verifyApp.Replace('\','/'))/package.json').version") -eq '0.38.7') 'Fresh install version is not 0.38.7.'
$godotVersion = (& (Godot $verifyApp) --version 2>&1 | Out-String).Trim()
A ($LASTEXITCODE -eq 0 -and $godotVersion -match '^4\.7\.1') "Bundled Godot changed unexpectedly: $godotVersion"
$verifyIndex = Get-Content (Join-Path $verifyApp 'public\index.html') -Raw
$verifyUpdate = Get-Content (Join-Path $verifyApp 'public\forge-update-control-0387.js') -Raw
$verifyMain = Get-Content (Join-Path $verifyApp 'desktop\main.cjs') -Raw
$verifyRuntime = Get-Content (Join-Path $verifyApp 'public\forge-0386-runtime-fix.js') -Raw
$verifyCritical = Get-Content (Join-Path $verifyApp 'public\forge-critical-ops.js') -Raw
$verifyServer = Get-Content (Join-Path $verifyApp 'dist\server\index.js') -Raw
A ($verifyIndex -match 'forge-update-control-0387\.js\?build=forge-v0387') 'Installed update UX missing.'
A ($verifyUpdate -match 'action\.textContent = "Reiniciar"' -and $verifyUpdate -notmatch 'downloadUpdate\(') 'Installed update UX is not background-first.'
A ($verifyMain -match 'quitAndInstall\(true, true\)') 'Installed updater is not silent.'
A ($verifyRuntime -match 'stopImmediatePropagation' -and $verifyRuntime -match 'preview quedó vacío') '0.38.6 runtime visibility fix regressed.'
A ($verifyCritical -match 'cancel-active' -and $verifyCritical -match 'method: "DELETE"') '0.38.5 critical bridge regressed.'
A ($verifyServer -match 'cancellationDeadline = Date\.now\(\) \+ 12000') '0.38.5 server hotfix regressed.'

$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name" | Set-Content -Encoding ascii 'builder/release/SHA256SUMS.txt'
@"
# Forge Studio v0.38.7

Desktop installation and update UX release.

- The Windows installer is now per-user one-click: no install-mode page, folder picker or multi-step wizard.
- Forge branding is used by the new installer build instead of the generic Electron fallback.
- Updates keep downloading automatically in the background.
- When an update is ready, Forge shows one compact `Reiniciar` action; closing Forge normally installs it automatically.
- Explicit restart uses silent NSIS handoff and relaunches Forge without showing the installer wizard.
- Preserves the validated 0.38.6 Activity/blank-preview fix, 0.38.5 critical operations and bundled Godot 4.7.1.
"@ | Set-Content -Encoding utf8 'builder/release/RELEASE_NOTES.md'

$tag = 'v0.38.7'
$assets = @($installer,$blockmap,$latest,'builder/release/SHA256SUMS.txt')
if(gh release view $tag --repo $repo 2>$null){
  gh release upload $tag @assets --repo $repo --clobber
  gh release edit $tag --repo $repo --title 'Forge Studio v0.38.7' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}else{
  gh release create $tag @assets --repo $repo --target main --title 'Forge Studio v0.38.7' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}

$published = Join-Path $env:RUNNER_TEMP 'forge-0387-published'
Remove-Item $published -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $published | Out-Null
gh release download $tag --repo $repo --dir $published
foreach($file in @($name,"$name.blockmap",'latest.yml','SHA256SUMS.txt')){ A (Test-Path (Join-Path $published $file)) "Published asset missing: $file" }
$publishedHash = (Get-FileHash (Join-Path $published $name) -Algorithm SHA256).Hash.ToLowerInvariant()
$declared = ((Get-Content (Join-Path $published 'SHA256SUMS.txt') -Raw).Trim().Split(' ')[0]).ToLowerInvariant()
A ($publishedHash -eq $hash -and $publishedHash -eq $declared) 'Published installer checksum mismatch.'
Write-Host "FORGE_0387_RELEASE_OK $publishedHash"
