$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../program/Start-Bridge.ps1') -LibraryOnly
function Assert($v,$message){if(-not$v){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('exmail-first-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$inbox=Join-Path $root 'inbox';[void][IO.Directory]::CreateDirectory($inbox)
function State { $s=New-InternalBridgeState;$s.inbox=$inbox;$s.attachmentDataDirectory=$root;return $s }
function Reply($s,$xml){$path=Join-Path $inbox ('MailTransfer-Result-'+$s.keyRequestId+'.txt');Write-BridgeJson $path @{schemaVersion=4;kind='public-key';requestId=$s.keyRequestId;publicXml=$xml};Update-InternalBridgeInbox $s $inbox $root}
$rsa=New-BridgeKey
try{
 $s=State
 Assert ($s.sendQueue.Count-eq0) 'startup must wait'
 Submit-InternalBridgeRequest $s 'refresh' '' '' $root '' 37
 Assert ($s.connecting-and$s.collectAfterConnect-and$s.sendQueue.Count-eq1) 'first click must prepare connection'
 $first=$s.sendQueue.Dequeue();Assert ((Read-BridgeJson $first.path).kind-eq'key-request') 'key request first'
 Reply $s ($rsa.ToXmlString($false))
 Assert ($s.busy-and-not$s.connecting-and-not$s.collectAfterConnect-and$s.sendQueue.Count-eq1) 'key reply must continue exactly once'
 $next=$s.sendQueue.Dequeue();$packet=Read-BridgeJson $next.path
 Assert ($packet.kind-eq'mail-request'-and$packet.count-eq37-and$next.action-eq'refresh') 'automatically continue original count'
 Update-InternalBridgeInbox $s $inbox $root
 Assert ($s.sendQueue.Count-eq0) 'duplicate reply must not enqueue'
 $s.busy=$false
 Submit-InternalBridgeRequest $s 'refresh' '' '' $root '' 42
 Assert ((Read-BridgeJson $s.sendQueue.Dequeue().path).kind-eq'mail-request') 'reuse connection without another handshake'
 $early=State;Submit-InternalBridgeRequest $early 'refresh' '' '' $root '' 11;$early.sendQueue.Clear();$early.sending=$true;Reply $early ($rsa.ToXmlString($false))
 Assert ($early.collectAfterConnect-and$early.sendQueue.Count-eq0) 'early key reply waits for sender completion'
 $early.sending=$false;Update-InternalBridgeInbox $early $inbox $root
 Assert ($early.busy-and$early.sendQueue.Count-eq1) 'collection continues after sender completion'
 $s=State;Submit-InternalBridgeRequest $s 'refresh' '' '' $root '' 10;$s.sendQueue.Clear();Reply $s '<RSAKeyValue><D>private</D></RSAKeyValue>'
 Assert (-not$s.collectAfterConnect-and-not$s.busy-and$s.sendQueue.Count-eq0-and-not$s.publicXml) 'invalid key must not continue'
 $s=State;Submit-InternalBridgeRequest $s 'refresh' '' '' $root '' 10;$s.sendQueue.Clear();$s.lastKeyAt=[DateTime]::UtcNow.AddSeconds(-61);Update-InternalBridgeInbox $s $inbox $root
 Assert (-not$s.connecting-and-not$s.collectAfterConnect-and-not$s.busy) 'timeout must discard continuation'
 $s=State;Submit-InternalBridgeRequest $s 'refresh' '' '' $root '' 10;$oldId=$s.keyRequestId
 Stop-BridgeOperation @{role='Internal';internal=$s}
 Write-BridgeJson (Join-Path $inbox ('MailTransfer-Result-'+$oldId+'.txt')) @{kind='public-key';requestId=$oldId;publicXml=$rsa.ToXmlString($false)}
 Update-InternalBridgeInbox $s $inbox $root
 Assert (-not$s.collectAfterConnect-and$s.sendQueue.Count-eq0-and-not$s.publicXml) 'cancelled late reply must not resume'
 $s=State;Submit-InternalBridgeRequest $s 'refresh' '' '' $root '' 10
 Start-InternalConnectionReset @{role='Internal';internal=$s;setupActive=$false} ('f'*32) $false
 Assert (-not$s.collectAfterConnect-and$s.sendQueue.Count-eq0-and-not$s.publicXml) 'reset must wait for explicit next click'
 Write-Host 'PASS one click key exchange -> collection, count retained, key reuse, duplicate/invalid/late reply, timeout, cancel and reset'
}finally{$rsa.Dispose();Remove-Item -LiteralPath $root -Recurse -Force}
