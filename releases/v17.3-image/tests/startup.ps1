$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert($Condition,[string]$Message){if(-not$Condition){throw $Message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('exmail17-startup-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$batch=Join-Path $repo 'dist/EX메일-익스플로러-자동설치-v17.3-이미지자동전송1.bat'
$raw=[IO.File]::ReadAllText($batch);$encoded=[regex]::Match($raw,'(?m)^::EXMAIL_SCRIPT:([A-Za-z0-9+/=]+)').Groups[1].Value
# The bootstrap must allow its unblocked local launcher script in this process.
# Without this flag a default Restricted policy accepts inline code but rejects dot-sourcing Launch-EXMail.ps1.
Assert ($raw-match'(?m)^powershell\.exe -NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -Command ') 'BOOTSTRAP_PROCESS_POLICY_MISSING'
Assert ($raw-notmatch'(?i)Set-ExecutionPolicy|-ExecutionPolicy\s+Bypass') 'PERSISTENT_OR_BYPASS_POLICY_CHANGE'
. ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)))) -LibraryOnly
$script:opened=0;$script:stopped=0
function Assert-EXMailStopped {$script:stopped++}
function New-EXMailShortcut {param($Path,$RecoveryBatch) [IO.File]::WriteAllText($Path,$RecoveryBatch)}
$open={param($Directory) $script:opened++}
try{
 $dest=Join-Path $root 'program';$desktop=Join-Path $root 'desktop';$startup=Join-Path $root 'Startup'
 [void][IO.Directory]::CreateDirectory($startup);[IO.File]::WriteAllText((Join-Path $startup 'EX메일 익스플로러.lnk'),'old')
 Invoke-EXMailInstall $batch $dest $desktop $startup 'Install' $open
 Assert ((Get-ChildItem $dest -File).Count-eq35) 'INSTALL_FILE_COUNT'
 $saved=Join-Path $startup 'EXMail-Recover.bat'
 Assert ((Get-EXMailDigest ([IO.File]::ReadAllBytes($saved)))-ceq(Get-EXMailDigest ([IO.File]::ReadAllBytes($batch)))) 'INCOMPLETE_STARTUP_BATCH'
 Assert ((Get-ChildItem $startup -File).Count-eq1) 'DUPLICATE_STARTUP_ENTRY'
 Assert ($opened-eq1) 'NOT_LAUNCHED'
 $settings=Join-Path $dest 'bridge-settings.json';[IO.File]::WriteAllText($settings,'{"role":"External","count":100}')
 $html=Join-Path $dest 'app.html';$old=[DateTime]::UtcNow.AddYears(-1);[IO.File]::SetLastWriteTimeUtc($html,$old)
 Invoke-EXMailInstall $saved $dest $desktop $startup 'Startup' $open
 Assert ([IO.File]::GetLastWriteTimeUtc($html)-eq$old-and$opened-eq2-and$stopped-eq1) 'HEALTHY_FILES_REINSTALLED'
 [IO.File]::WriteAllText($html,'broken');Invoke-EXMailInstall $saved $dest $desktop $startup 'Startup' $open
 Assert (Test-EXMailFiles (Get-EXMailBundle $saved) $dest) 'CORRUPT_FILE_NOT_REPAIRED'
 Assert (([IO.File]::ReadAllText($settings)|ConvertFrom-Json).role-eq'External') 'SETTINGS_OVERWRITTEN'
 Remove-Item $dest -Recurse -Force;Invoke-EXMailInstall $saved $dest $desktop $startup 'Startup' $open
 Assert ((Test-EXMailFiles (Get-EXMailBundle $saved) $dest)-and$opened-eq4) 'DELETED_FOLDER_NOT_RESTORED'
 Assert (([IO.File]::ReadAllText((Join-Path $desktop 'EX메일 익스플로러.lnk')))-ceq$saved) 'DESKTOP_NOT_RECOVERY_TARGET'
 # Upgrade replaces the same startup BAT atomically and leaves exactly one entry.
 Invoke-EXMailInstall $batch $dest $desktop $startup 'Install' $open
 Assert ((Get-ChildItem $startup -File).Count-eq1-and$opened-eq5) 'UPGRADE_DUPLICATE_ENTRY'
 Assert ($raw.Contains('if /i "%~nx0"=="EXMail-Recover.bat"')) 'STARTUP_MODE_MISSING'
 'PASS v17.3 startup BAT exact self-contained copy, no duplicate entry, immediate launch, healthy no-reinstall, damaged/deleted installation repair, existing settings preserved, desktop recovery target. COM and app launch mocked; Windows reboot not executed.'
}finally{Remove-Item $root -Recurse -Force}
