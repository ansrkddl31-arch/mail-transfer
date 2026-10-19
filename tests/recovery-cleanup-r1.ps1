$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
function Assert($Condition,[string]$Message){if(-not$Condition){throw $Message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('exmail-r1-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$batch=Join-Path $repo 'dist/EX메일-익스플로러-자동설치-v18.2-r1.bat'
$raw=[IO.File]::ReadAllText($batch);$encoded=[regex]::Match($raw,'(?m)^::EXMAIL_SCRIPT:([A-Za-z0-9+/=]+)').Groups[1].Value
. ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)))) -LibraryOnly
$script:opened=0;$script:stopped=0
function Assert-EXMailStopped {$script:stopped++}
function New-EXMailShortcut {param($Path,$RecoveryBatch) [IO.File]::WriteAllText($Path,$RecoveryBatch)}
$open={param($Directory) $script:opened++}
try{
 $dest=Join-Path $root 'program';$desktop=Join-Path $root 'desktop';$startup=Join-Path $root 'Startup'
 [void][IO.Directory]::CreateDirectory($startup);[IO.File]::WriteAllText((Join-Path $startup 'EX메일 익스플로러.lnk'),'old')
 Invoke-EXMailInstall $batch $dest $desktop $startup 'Install' $open
 Assert ((Get-ChildItem $dest -File).Count-eq36) 'INSTALL_FILE_COUNT'
 $savedBatch=Join-Path $startup 'EXMail-Recover.bat'
 Assert ((Get-EXMailDigest ([IO.File]::ReadAllBytes($savedBatch)))-ceq(Get-EXMailDigest ([IO.File]::ReadAllBytes($batch)))) 'RECOVERY_COPY_INCOMPLETE'
 Assert (-not(Test-Path (Join-Path $startup 'EX메일 익스플로러.lnk'))) 'DOUBLE_STARTUP_ENTRY'
 Assert ((Get-ChildItem $startup -File).Count-eq1) 'STARTUP_HAS_DATA_FILES'
 Assert ($opened-eq1) 'NOT_LAUNCHED_AFTER_INSTALL'
 . (Join-Path $repo 'program/Recovery.ps1')
 $settings=Join-Path $dest 'bridge-settings.json'
 [IO.File]::WriteAllText($settings,(@{role='External';inbox=$root;folderConfirmed=$true;count=73;password='DO_NOT_BACK_UP'}|ConvertTo-Json))
 Assert (Save-EXMailRecoveryConfiguration $settings $startup) 'SETTINGS_BACKUP'
 $paths=Get-EXMailRecoveryPaths $startup
 Assert (-not([IO.File]::ReadAllText($paths.settings).Contains('DO_NOT_BACK_UP'))) 'PRIVATE_DATA_IN_BACKUP'
 $html=Join-Path $dest 'app.html';$oldTime=[DateTime]::UtcNow.AddYears(-1);[IO.File]::SetLastWriteTimeUtc($html,$oldTime)
 Invoke-EXMailInstall $savedBatch $dest $desktop $startup 'Startup' $open
 Assert ([IO.File]::GetLastWriteTimeUtc($html)-eq$oldTime-and$opened-eq2-and$stopped-eq1) 'STARTUP_REINSTALLED_HEALTHY_FILES'
 [IO.File]::WriteAllText($html,'corrupted file');Invoke-EXMailInstall $savedBatch $dest $desktop $startup 'Startup' $open
 Assert ((Test-EXMailFiles (Get-EXMailBundle $savedBatch) $dest)-and$opened-eq3) 'DAMAGED_FILE_NOT_REPAIRED'
 Assert (([IO.File]::ReadAllText($settings)|ConvertFrom-Json).count-eq73) 'SETTINGS_OVERWRITTEN'
 Remove-Item $dest -Recurse -Force
 Invoke-EXMailInstall $savedBatch $dest $desktop $startup 'Startup' $open
 $cfg=[IO.File]::ReadAllText($settings)|ConvertFrom-Json
 Assert ($cfg.role-eq'External'-and$cfg.count-eq73-and$opened-eq4) 'DELETED_FOLDER_NOT_RESTORED_WITH_ROLE'
 Assert (([IO.File]::ReadAllText((Join-Path $desktop 'EX메일 익스플로러.lnk')))-ceq$savedBatch) 'SHORTCUT_CANNOT_RECOVER_MISSING_INSTALL'
 $tampered=Join-Path $root 'bad.bat';[IO.File]::WriteAllText($tampered,($raw-replace '(?m)(^::EXMAIL_ZIP:).','$1A'))
 $rejected=$false;try{[void](Get-EXMailBundle $tampered)}catch{$rejected=$true};Assert $rejected 'TAMPERED_BUNDLE_ACCEPTED'
 'PASS self-contained startup BAT, immediate launch, healthy no-reinstall, damaged/deleted install recovery, non-secret role/path backup, unique startup entry and checksum rejection (Windows shortcut COM/launch mocked)'
 . (Join-Path $repo 'program/Start-Bridge.ps1') -LibraryOnly
 function PutPacket($Path,$Kind,$Id){Write-BridgeJson $Path @{schemaVersion=4;kind=$Kind;requestId=$Id;createdAt=[DateTime]::UtcNow.ToString('o')}}
 foreach($role in @('Internal','External')){
  $state=Join-Path $root $role;$inbox=Join-Path $state 'inbox';$outbox=Join-Path $state 'outbox';[void][IO.Directory]::CreateDirectory($inbox);[void][IO.Directory]::CreateDirectory($outbox);[void][IO.Directory]::CreateDirectory((Join-Path $state 'logs'))
  $id=if($role-eq'Internal'){'a'*32}else{'b'*32}
  $rp=if($role-eq'Internal'){'Result'}else{'Request'};$sp=if($role-eq'Internal'){'Request'}else{'Result'}
  $received=Join-Path $inbox ('MailTransfer-'+$rp+'-'+$id+'.txt');$sent=Join-Path $outbox ('MailTransfer-'+$sp+'-'+$id+'.txt')
  $rk=if($role-eq'Internal'){'public-key'}else{'key-request'};$sk=if($role-eq'Internal'){'key-request'}else{'public-key'}
  PutPacket $received $rk $id;PutPacket $sent $sk $id
  $duplicate=Join-Path $inbox ('MailTransfer-'+$rp+'-'+$id+' (1).txt');PutPacket $duplicate $rk $id
  $unrelated=Join-Path $inbox ('MailTransfer-'+$rp+'-'+$id+'-notes.txt');[IO.File]::WriteAllText($unrelated,'keep')
  Write-BridgeJson ([IO.Path]::ChangeExtension($sent,'.send.json')) @{result='SUBMITTED_UI_CONFIRMED';clicked=$true}
  Write-BridgeJson ([IO.Path]::ChangeExtension($sent,'.send.progress.json')) @{stage='DONE'}
  Write-BridgeJson (Join-Path $state ('worker-'+$id+'.trace.json')) @{state='failed';code='TEST_CONNECTION_ERROR';body='DO_NOT_LOG'}
  Write-BridgeJson (Join-Path $state ('worker-'+$id+'.status.json')) @{phase='done'}
  [IO.File]::WriteAllText((Join-Path (Join-Path $state 'logs') ('MailTransfer-Trace-'+$id+'.jsonl')),'old success/detail trace')
  $producer=if($role-eq'External'){$PID}else{0};$ticks=if($producer){[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks}else{0}
  Add-BridgeExchangeCleanup $state $inbox $role $id $received -ProducerPid $producer -ProducerStart $ticks
  if($role-eq'External'){
   Invoke-BridgeExchangeCleanup $state $inbox $role -Now ([DateTime]::UtcNow.AddDays(1));Assert (Test-Path $sent) 'REMOVED_LIVE_WORKER_FILE'
   $task=Join-Path $state ('cleanup-'+$id+'.json');$value=Read-BridgeJson $task;$value.producerPid=0;Write-BridgeJson $task $value
   Invoke-BridgeExchangeCleanup $state $inbox $role -Now ([DateTime]::UtcNow.AddSeconds(1));Assert (Test-Path $sent) 'GRACE_NOT_OBSERVED'
  }
  $lock=[IO.File]::Open($sent,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  try{Invoke-BridgeExchangeCleanup $state $inbox $role -Now ([DateTime]::UtcNow.AddMinutes(1));Assert (Test-Path $sent) 'LOCKED_SEND_DELETED'}finally{$lock.Dispose()}
  Invoke-BridgeExchangeCleanup $state $inbox $role -Now ([DateTime]::UtcNow.AddMinutes(1))
  Assert (-not(Test-Path $received)-and-not(Test-Path $duplicate)-and-not(Test-Path $sent)-and(Test-Path $unrelated)) 'PACKET_CLEANUP_OR_COLLATERAL_DELETE'
  Assert (-not(Test-Path (Join-Path $state ('cleanup-'+$id+'.json')))-and-not(Test-Path (Join-Path $state ('worker-'+$id+'.status.json')))) 'CONNECTION_METADATA_LEFT'
  $logs=@(Get-ChildItem (Join-Path $state 'logs') -File);Assert ($logs.Count-eq1-and$logs[0].Name-like'errors-*.jsonl') 'SUCCESS_TRACE_LEFT'
  $text=[IO.File]::ReadAllText($logs[0].FullName);Assert ($text.Contains('TEST_CONNECTION_ERROR')-and-not$text.Contains('DO_NOT_LOG')) 'ERROR_LOG_LEAK'
 }
 'PASS connection packet/duplicate/sidecar/success trace removal, live-worker/grace/locked-file deferral, errors-only logs and unrelated file preservation'
}finally{Remove-Item $root -Recurse -Force}
