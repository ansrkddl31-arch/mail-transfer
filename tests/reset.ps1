$ErrorActionPreference='Stop'
. /workspace/scratch/claude-mail-transfer-v17.2/Start-Bridge.ps1 -LibraryOnly
$root=Join-Path /tmp ('reset-qa-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$s=New-InternalBridgeState;$s.attachmentDataDirectory=$root;$s.inbox=Join-Path $root inbox;[void][IO.Directory]::CreateDirectory($s.inbox)
$s.mails=@(@{subject='보존';body='원문'});$s.aiPreferences=@{enabled=$true;provider='openai';extractSchedule=$true;maxCount=20};$s.lastCount=35;$s.collectionFilter=@{mode='range';from='2026-10-01';to='2026-10-15'}
$s.attachments=@{ready=@{status='ready';requestId=('a'*32);name='다운로드.xlsx'};pending=@{status='receiving';requestId=('b'*32);name='대기.xlsx'}}
Write-BridgeJson (Join-Path $root 'calendar.json') @{items=@(@{title='일정 유지'})};Write-BridgeJson (Join-Path $root 'ai-settings.json') @{keyProtected='keep-encrypted-key'}
$s.publicXml='old-key';$s.pendingId='c'*32;$s.keyRequestId='d'*32;$s.loginNeeded=$true;$s.loginError='old';$s.busy=$true
$s.sendQueue.Enqueue(@{requestId=('c'*32);path='old.txt';action='refresh'})
$app=@{role='Internal';internal=$s;stateDir=$root;setupActive=$false}
$before=(Get-FileHash (Join-Path $root 'calendar.json')).Hash;$keys=(Get-FileHash (Join-Path $root 'ai-settings.json')).Hash
Start-InternalConnectionReset $app ('e'*32) $true
if($s.connectionResetPending-or$s.pendingId-or$s.publicXml-or$s.loginNeeded-or$s.loginError-or$s.sessionReady-or-not$s.connecting-or$s.sendQueue.Count-ne1){throw 'RESET_STATE_OR_SINGLE_CONNECT_FAILED'}
$packet=Read-BridgeJson $s.sendQueue.Peek().path
if($packet.kind-ne'key-request'-or$packet.requestId-eq('c'*32)-or$s.mails[0].body-ne'원문'-or$s.attachments.ready.status-ne'ready'-or$s.attachments.pending.status-ne'failed'-or$s.lastCount-ne35-or$s.collectionFilter.mode-ne'range'){throw 'DATA_NOT_PRESERVED'}
if((Get-FileHash (Join-Path $root 'calendar.json')).Hash-ne$before-or(Get-FileHash (Join-Path $root 'ai-settings.json')).Hash-ne$keys){throw 'PERSISTENT_DATA_CHANGED'}
$first=$s.keyRequestId;Start-InternalConnectionReset $app ('e'*32) $true
if($s.sendQueue.Count-ne1-or$s.keyRequestId-ne$first){throw 'RESET_REPLAY_DUPLICATED_CONNECTION'}
# A late old mail reply must not replace the stored inbox after reset.
Write-BridgeJson (Join-Path $s.inbox ('MailTransfer-Result-'+('c'*32)+'.txt')) @{schemaVersion=4;kind='mail-result';requestId=('c'*32);createdAt=[DateTime]::UtcNow.ToString('o');status='success';mails=@(@{subject='stale';body='stale'})}
Update-InternalBridgeInbox $s $s.inbox $root
if($s.mails[0].body-ne'원문'){throw 'STALE_RESPONSE_APPLIED'}
'PASS idle/pending reset, single fresh key test, duplicate POST idempotence, late result rejection, mails/calendar/AI/settings/ready attachments preserved'
# Active send must stop before clearing active state or starting a new sender.
function Stop-BridgeOperation {param($App) $script:stopCalls++}
$script:stopCalls=0;$s.sendQueue.Clear();$s.connecting=$false;$s.busy=$true;$s.sending=$true
$process=[pscustomobject]@{HasExited=$false};$process|Add-Member ScriptMethod Kill {$this.HasExited=$true}
$s.activeSend=@{job=@{process=$process};requestId=('f'*32);action='refresh'}
Start-InternalConnectionReset $app ('1'*32) $true
if(-not$s.connectionResetPending-or$script:stopCalls-ne1-or$s.sendQueue.Count){throw 'RESET_DID_NOT_WAIT_FOR_SENDER'}
$s.connectionResetAt=[DateTime]::UtcNow.AddSeconds(-4);Update-InternalBridgeSends $s
if($s.connectionResetPending-or$s.activeSend-or$s.busy-or$s.sending-or$s.sendQueue.Count-or-not$s.status.Contains('전송 여부')){throw 'UNCERTAIN_SEND_RECONNECTED'}
'PASS active sender cancellation waits asynchronously; only exact worker stopped; uncertain transfer never auto reconnects or replays old request'
# Missing calibration resets locally without inventing readiness or starting transfer.
$s.transferReady=$false;Start-InternalConnectionReset $app ('2'*32) $true
if($s.sendQueue.Count-or$s.connecting-or-not$s.status.Contains('설정')){throw 'RESET_IGNORED_CONFIGURATION'}
'PASS incomplete settings retain safe disconnected state and provide recovery instruction'
