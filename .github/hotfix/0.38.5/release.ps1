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
$baseDir = Join-Path $env:RUNNER_TEMP 'forge-0385-base-download'
$baseInstall = Join-Path $env:RUNNER_TEMP 'forge-0385-base-install'
$patched = Join-Path $env:RUNNER_TEMP 'forge-0385-prepackaged'
Remove-Item $baseDir,$baseInstall,$patched -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $baseDir | Out-Null

$name0384 = 'Forge-Studio-Setup-0.38.4-x64.exe'
gh release download v0.38.4 --repo $repo --pattern $name0384 --dir $baseDir
$baseInstaller = Join-Path $baseDir $name0384
A (Test-Path $baseInstaller) 'Could not download Forge 0.38.4 base.'
$expected0384 = '0adc8e76a6c10b4ec158db08ebb0de3f0da24c9bf6cebd4f3e915e24557cf37a'
$actual0384 = (Get-FileHash $baseInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
A ($actual0384 -eq $expected0384) "0.38.4 base checksum mismatch: $actual0384"
$installResult = Start-Process -FilePath $baseInstaller -ArgumentList '/S', "/D=$baseInstall" -Wait -PassThru
A ($installResult.ExitCode -eq 0) "0.38.4 base install failed: $($installResult.ExitCode)"
$baseApp = Join-Path $baseInstall 'resources\app'
A ((node -p "require('$($baseApp.Replace('\','/'))/package.json').version") -eq '0.38.4') 'Base payload is not 0.38.4.'
Copy-Item $baseInstall $patched -Recurse
Remove-Item (Join-Path $patched 'Uninstall Forge Studio.exe') -Force -ErrorAction SilentlyContinue
$app = Join-Path $patched 'resources\app'

# Version bump only; keep every verified 0.38.4 runtime fix intact.
$packagePath = Join-Path $app 'package.json'
$package = Get-Content $packagePath -Raw | ConvertFrom-Json
A ($package.version -eq '0.38.4') "Unexpected package base $($package.version)"
$package.version = '0.38.5'
$package | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8NoBOM $packagePath

# UI recovery: ZIP replacement and project deletion first drain active work.
Copy-Item '.github/hotfix/0.38.5/forge-critical-ops.js' (Join-Path $app 'public\forge-critical-ops.js') -Force
$indexPath = Join-Path $app 'public\index.html'
$index = Get-Content $indexPath -Raw
if($index -notmatch 'forge-critical-ops\.js'){
  A ($index -match '</body>') 'index.html has no closing body tag.'
  $index = $index.Replace('</body>', '  <script src="/forge-critical-ops.js?build=forge-v0385"></script>' + "`n</body>")
  Set-Content -Encoding utf8NoBOM $indexPath $index
}

# Backend recovery: stale/running jobs no longer make replace/delete fail immediately with 409.
$serverPath = Join-Path $app 'dist\server\index.js'
$server = Get-Content $serverPath -Raw
$importPattern = 'if \(replacingExisting && activeJobsForProject\(store\.snapshot\(\), project\.id\)\.length\) \{\s*return res\.status\(409\)\.json\(\{ error: "Detené la ejecución antes de reemplazar el proyecto con un ZIP\." \}\);\s*\}'
$importReplacement = @'
if (replacingExisting && activeJobsForProject(store.snapshot(), project.id).length) {
            const cancellationAt = nowIso();
            await store.mutate((state) => { requestProjectCancellation(state, project.id, cancellationAt); });
            const cancellationDeadline = Date.now() + 12000;
            while (activeJobsForProject(store.snapshot(), project.id).length && Date.now() < cancellationDeadline) {
                await new Promise((resolve) => setTimeout(resolve, 250));
            }
            if (activeJobsForProject(store.snapshot(), project.id).length) {
                return res.status(409).json({ error: "Forge no pudo cerrar la ejecución activa para reemplazar el ZIP. Reiniciá Forge y repetí la operación." });
            }
        }
'@
$patchedServer = [regex]::Replace($server, $importPattern, $importReplacement, 1)
A ($patchedServer -ne $server) 'Could not patch ZIP replacement cancellation path.'
$server = $patchedServer

$deletePattern = 'if \(active\.length\)\s*return res\.status\(409\)\.json\(\{ error: "Detené las ejecuciones activas antes de eliminar el proyecto", activeJobs: active\.map\(\(job\) => job\.id\) \}\);'
$deleteReplacement = @'
if (active.length) {
            const cancellationAt = nowIso();
            await store.mutate((state) => { requestProjectCancellation(state, project.id, cancellationAt); });
            const cancellationDeadline = Date.now() + 12000;
            while (activeJobsForProject(store.snapshot(), project.id).length && Date.now() < cancellationDeadline) {
                await new Promise((resolve) => setTimeout(resolve, 250));
            }
            const remainingActive = activeJobsForProject(store.snapshot(), project.id);
            if (remainingActive.length) return res.status(409).json({ error: "Forge no pudo cerrar una ejecución activa para eliminar el proyecto.", activeJobs: remainingActive.map((job) => job.id) });
        }
'@
$patchedServer = [regex]::Replace($server, $deletePattern, $deleteReplacement, 1)
A ($patchedServer -ne $server) 'Could not patch project deletion cancellation path.'
$server = $patchedServer
Set-Content -Encoding utf8NoBOM $serverPath $server

# Static release gates.
$critical = Get-Content (Join-Path $app 'public\forge-critical-ops.js') -Raw
$index = Get-Content $indexPath -Raw
$server = Get-Content $serverPath -Raw
A ($critical -match 'cancel-active' -and $critical -match 'requestSubmit' -and $critical -match 'method: "DELETE"') 'Critical operation bridge is incomplete.'
A ($index -match 'forge-critical-ops\.js\?build=forge-v0385') '0.38.5 UI bridge was not injected.'
A ($server -match 'cancellationDeadline = Date\.now\(\) \+ 12000') 'Backend cancellation wait is missing.'
A ($server -notmatch 'Detené la ejecución antes de reemplazar el proyecto con un ZIP\.') 'Old ZIP replacement 409 path survived.'
& node --check (Join-Path $app 'public\forge-critical-ops.js')
A ($LASTEXITCODE -eq 0) 'Critical operation JS syntax check failed.'
& node --check $serverPath
A ($LASTEXITCODE -eq 0) 'Patched server syntax check failed.'
Write-Host 'FORGE_0385_PATCH_OK'

# Wrap the already verified 0.38.4 app as 0.38.5.
Remove-Item builder -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory builder | Out-Null
Push-Location builder
@'
{
  "name":"forge-studio",
  "version":"0.38.5",
  "description":"Forge Studio critical project operation reliability release",
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

$name = 'Forge-Studio-Setup-0.38.5-x64.exe'
$installer = "builder/release/$name"
$blockmap = "$installer.blockmap"
$latest = 'builder/release/latest.yml'
foreach($file in @($installer,$blockmap,$latest)){ A (Test-Path $file) "Missing 0.38.5 artifact: $file" }
A ((Get-Item $installer).Length -gt 150MB) 'Installer is too small to retain bundled Godot.'

# Fresh install verifies we did not produce a fake updater payload.
$baseUninstaller = Join-Path $baseInstall 'Uninstall Forge Studio.exe'
if(Test-Path $baseUninstaller){ Start-Process -FilePath $baseUninstaller -ArgumentList '/S' -Wait | Out-Null }
$verify = Join-Path $env:RUNNER_TEMP 'forge-0385-final-install'
Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue
$verifyProcess = Start-Process -FilePath (Resolve-Path $installer) -ArgumentList '/S', "/D=$verify" -Wait -PassThru
A ($verifyProcess.ExitCode -eq 0) "0.38.5 fresh install failed: $($verifyProcess.ExitCode)"
$verifyApp = Join-Path $verify 'resources\app'
A ((node -p "require('$($verifyApp.Replace('\','/'))/package.json').version") -eq '0.38.5') 'Fresh install version is not 0.38.5.'
$godotVersion = (& (Godot $verifyApp) --version 2>&1 | Out-String).Trim()
A ($LASTEXITCODE -eq 0 -and $godotVersion -match '^4\.7\.1') "Bundled Godot changed unexpectedly: $godotVersion"
$verifyIndex = Get-Content (Join-Path $verifyApp 'public\index.html') -Raw
$verifyCritical = Get-Content (Join-Path $verifyApp 'public\forge-critical-ops.js') -Raw
$verifyServer = Get-Content (Join-Path $verifyApp 'dist\server\index.js') -Raw
A ($verifyIndex -match 'forge-critical-ops\.js\?build=forge-v0385') 'Installed UI hotfix missing.'
A ($verifyCritical -match 'cancel-active' -and $verifyCritical -match 'method: "DELETE"') 'Installed critical bridge missing.'
A ($verifyServer -match 'cancellationDeadline = Date\.now\(\) \+ 12000') 'Installed server hotfix missing.'

$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name" | Set-Content -Encoding ascii 'builder/release/SHA256SUMS.txt'
@"
# Forge Studio v0.38.5

Critical reliability hotfix for project operations.

- Updating an existing project with a ZIP now stops active Run/Validate work first instead of immediately failing with 409.
- Project deletion now stops active work first and waits for the isolated process tree to close.
- The UI performs the same drain/retry flow, so stale `cancel_requested` jobs no longer make the buttons appear dead.
- Preserves every 0.38.4 startup, fast ZIP, Godot 4.7.1 and version-label fix unchanged.
"@ | Set-Content -Encoding utf8 'builder/release/RELEASE_NOTES.md'

$tag = 'v0.38.5'
$assets = @($installer,$blockmap,$latest,'builder/release/SHA256SUMS.txt')
if(gh release view $tag --repo $repo 2>$null){
  gh release upload $tag @assets --repo $repo --clobber
  gh release edit $tag --repo $repo --title 'Forge Studio v0.38.5' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}else{
  gh release create $tag @assets --repo $repo --target main --title 'Forge Studio v0.38.5' --notes-file 'builder/release/RELEASE_NOTES.md' --latest
}

$published = Join-Path $env:RUNNER_TEMP 'forge-0385-published'
Remove-Item $published -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $published | Out-Null
gh release download $tag --repo $repo --dir $published
foreach($file in @($name,"$name.blockmap",'latest.yml','SHA256SUMS.txt')){ A (Test-Path (Join-Path $published $file)) "Published asset missing: $file" }
$publishedHash = (Get-FileHash (Join-Path $published $name) -Algorithm SHA256).Hash.ToLowerInvariant()
$declared = ((Get-Content (Join-Path $published 'SHA256SUMS.txt') -Raw).Trim().Split(' ')[0]).ToLowerInvariant()
A ($publishedHash -eq $hash -and $publishedHash -eq $declared) 'Published installer checksum mismatch.'
Write-Host "FORGE_0385_RELEASE_OK $publishedHash"
