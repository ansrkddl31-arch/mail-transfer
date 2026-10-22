#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Transfer.TestCore.ps1')
. (Join-Path $PSScriptRoot 'InputGuard.ps1')
. (Join-Path $PSScriptRoot 'OperationTrace.ps1')
. (Join-Path $PSScriptRoot 'Attachments.ps1')
. (Join-Path $PSScriptRoot 'MailAssistant.ps1')
. (Join-Path $PSScriptRoot 'Calendar.ps1')
. (Join-Path $PSScriptRoot 'CollectionFilter.ps1')
. (Join-Path $PSScriptRoot 'Transfer.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Transfer.Startup.ps1')
. (Join-Path $PSScriptRoot 'Image.Flow.ps1')
. (Join-Path $PSScriptRoot 'Transfer.Image.ps1')
. (Join-Path $PSScriptRoot 'Maintenance.ps1')
function Write-BridgeJson {
    param([string]$Path, $Value)
    $folder = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($folder)
    $temp = Join-Path $folder ('.writing-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 100 -Compress), (New-Object Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
}
function Read-BridgeJson {
    param([string]$Path, [long]$MaximumBytes = 67108864)
    $info = Get-Item -LiteralPath $Path
    if ($info.Length -gt $MaximumBytes -or $info.Length -lt 2) { throw 'PACKET_SIZE_INVALID' }
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}
function Get-BridgeRandom {
    param([int]$Length)
    $bytes = New-Object byte[] $Length
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    return ,$bytes
}
function New-BridgeKey {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
    $rsa.PersistKeyInCsp = $false
    return $rsa
}
function Get-ExternalBridgeKey {
    param([string]$StateDirectory)
    Add-Type -AssemblyName System.Security
    [void][IO.Directory]::CreateDirectory($StateDirectory)
    $path = Join-Path $StateDirectory 'external-private-key.dpapi'
    $rsa = New-BridgeKey
    if (Test-Path -LiteralPath $path) {
        $privateBytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($privateBytes)) } finally { [Array]::Clear($privateBytes, 0, $privateBytes.Length) }
    } else {
        $privateBytes = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
        try { [IO.File]::WriteAllBytes($path, [Security.Cryptography.ProtectedData]::Protect($privateBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)) }
        finally { [Array]::Clear($privateBytes, 0, $privateBytes.Length) }
    }
    return $rsa
}
function Protect-BridgeCredential {
    param([string]$PublicXml, [string]$UserName, [string]$Password, [string]$RequestId)
    if ($PublicXml -match '<(?:D|P|Q|DP|DQ|InverseQ)>') { throw 'PUBLIC_KEY_REQUIRED' }
    if ([string]::IsNullOrWhiteSpace($UserName) -or [string]::IsNullOrEmpty($Password)) { throw 'CREDENTIALS_REQUIRED' }
    $rsa = New-BridgeKey; $aes = [Security.Cryptography.Aes]::Create()
    $keys = Get-BridgeRandom 64
    $enc = New-Object byte[] 32; $macKey = New-Object byte[] 32
    [Array]::Copy($keys,0,$enc,0,32); [Array]::Copy($keys,32,$macKey,0,32)
    $hmac = New-Object Security.Cryptography.HMACSHA256(,$macKey)
    $plain = [Text.Encoding]::UTF8.GetBytes((@{ userName=$UserName; password=$Password; requestId=$RequestId } | ConvertTo-Json -Compress))
    try {
        $rsa.FromXmlString($PublicXml)
        $aes.Key=$enc; $aes.GenerateIV(); $aes.Mode=[Security.Cryptography.CipherMode]::CBC; $aes.Padding=[Security.Cryptography.PaddingMode]::PKCS7
        $transform=$aes.CreateEncryptor()
        try { $cipher=$transform.TransformFinalBlock($plain,0,$plain.Length) } finally { $transform.Dispose() }
        $authenticated = New-Object byte[] ($aes.IV.Length+$cipher.Length)
        [Array]::Copy($aes.IV,0,$authenticated,0,16); [Array]::Copy($cipher,0,$authenticated,16,$cipher.Length)
        return [ordered]@{ algorithm='RSA-OAEP-AES256-CBC-HMAC256'; key=[Convert]::ToBase64String($rsa.Encrypt($keys,$true)); iv=[Convert]::ToBase64String($aes.IV); ciphertext=[Convert]::ToBase64String($cipher); mac=[Convert]::ToBase64String($hmac.ComputeHash($authenticated)) }
    } finally {
        [Array]::Clear($plain,0,$plain.Length); [Array]::Clear($keys,0,$keys.Length); [Array]::Clear($enc,0,$enc.Length); [Array]::Clear($macKey,0,$macKey.Length)
        $hmac.Dispose(); $aes.Dispose(); $rsa.Dispose(); $Password=$null
    }
}
function Unprotect-BridgeCredential {
    param($Key, $Envelope, [string]$RequestId)
    if ($Envelope.algorithm -ne 'RSA-OAEP-AES256-CBC-HMAC256') { throw 'CREDENTIAL_ENVELOPE_INVALID' }
    $keys=$null; $plain=$null; $enc=$null; $macKey=$null; $data=$null; $aes=[Security.Cryptography.Aes]::Create(); $hmac=$null
    try {
        $keys=$Key.Decrypt([Convert]::FromBase64String($Envelope.key),$true)
        if ($keys.Length -ne 64) { throw 'CREDENTIAL_ENVELOPE_INVALID' }
        $iv=[Convert]::FromBase64String($Envelope.iv); $cipher=[Convert]::FromBase64String($Envelope.ciphertext); $tag=[Convert]::FromBase64String($Envelope.mac)
        if ($iv.Length -ne 16 -or $tag.Length -ne 32 -or $cipher.Length -gt 16384) { throw 'CREDENTIAL_ENVELOPE_INVALID' }
        $enc=New-Object byte[] 32; $macKey=New-Object byte[] 32
        [Array]::Copy($keys,0,$enc,0,32); [Array]::Copy($keys,32,$macKey,0,32)
        $hmac=New-Object Security.Cryptography.HMACSHA256(,$macKey)
        $authenticated=New-Object byte[] (16+$cipher.Length)
        [Array]::Copy($iv,0,$authenticated,0,16); [Array]::Copy($cipher,0,$authenticated,16,$cipher.Length)
        $expected=$hmac.ComputeHash($authenticated); $different=0
        for($i=0;$i -lt 32;$i++){ $different=$different -bor ($expected[$i] -bxor $tag[$i]) }
        if($different -ne 0){ throw 'CREDENTIAL_ENVELOPE_INVALID' }
        $aes.Key=$enc; $aes.IV=$iv; $aes.Mode=[Security.Cryptography.CipherMode]::CBC; $aes.Padding=[Security.Cryptography.PaddingMode]::PKCS7
        $transform=$aes.CreateDecryptor()
        try{$plain=$transform.TransformFinalBlock($cipher,0,$cipher.Length)}finally{$transform.Dispose()}
        $data=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json
        if($data.requestId -cne $RequestId){throw 'CREDENTIAL_REQUEST_MISMATCH'}
        return New-Object System.Management.Automation.PSCredential([string]$data.userName,(ConvertTo-SecureString ([string]$data.password) -AsPlainText -Force))
    } finally {
        if($null -ne $plain){[Array]::Clear($plain,0,$plain.Length)}
        if($null -ne $keys){[Array]::Clear($keys,0,$keys.Length)}
        if($null -ne $hmac){$hmac.Dispose()}; $aes.Dispose(); $data=$null
        if($null -ne $enc){[Array]::Clear($enc,0,$enc.Length)}
        if($null -ne $macKey){[Array]::Clear($macKey,0,$macKey.Length)}
    }
}
function Get-BridgeTransferConfiguration {
    # Per-role path anchors transfer-launch.json only; image sender never reads saved coordinates.
    param([ValidateSet('Internal','External')][string]$Role)
    $portableRoot=[Environment]::GetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT')
    if(-not[string]::IsNullOrWhiteSpace($portableRoot)){
        if(-not[IO.Path]::IsPathRooted($portableRoot)){throw 'PORTABLE_STATE_ROOT_INVALID'}
        return (Join-Path (Join-Path (Join-Path $portableRoot 'Transfer') $Role) 'sender-settings.json')
    }
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('MailTransferBridge\Transfer\' + $Role + '\sender-settings.json'))
}
function Test-BridgeTransferReady {
    param([string]$Configuration)
    foreach($file in @('Image.Detector.cs','Image.Native.cs','Image.Flow.ps1','Transfer.Image.ps1')){if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)){return $false}};return $true
}
function Start-BridgePacketSend {
    # The i-oneNet screen automation runs in its own process so the caller (the internal web
    # server) keeps answering the browser while the mouse is driven for 10-20 seconds.
    param([string]$Path, [string]$Configuration,[ValidateSet('Internal','External')][string]$Role='Internal')
    $resultFile = [IO.Path]::ChangeExtension($Path, '.send.json')
    if (Test-Path -LiteralPath $resultFile) { [IO.File]::Delete($resultFile) }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{0}" -Path "{1}" -Configuration "{2}" -ResultFile "{3}"' -f (Join-Path $PSScriptRoot 'Send-Packet.ps1'), $Path, $Configuration, $resultFile
    $arguments+=(' -ControllerPid {0} -ControllerStart {1}' -f $PID,([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks))
    if($Role -eq 'External'){$arguments+=' -ExternalRole'}
    $guard=Get-MailInputGuardContext
    if($null-ne$guard){$arguments+=(' -GuardName "{0}" -GuardOwnerPid {1} -GuardOwnerStart {2}' -f $guard.name,$guard.ownerPid,$guard.ownerStart)}
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    return [pscustomobject]@{ process = $process; resultFile = $resultFile; path = $Path; guardName=('Local\MailTransferCancel-'+[regex]::Match([IO.Path]::GetFileName($Path),'^MailTransfer-(?:Request|Result|Probe|Attachment)-([a-f0-9]{32})(?:\.[^\\/:*?"<>|\x00-\x1f]+)?$').Groups[1].Value); cancelObservedAt=[DateTime]::MinValue }
}
function Complete-BridgePacketSend {
    # $null while the send is still running; otherwise its outcome. Never throws.
    param($Job)
    if (-not $Job.process.HasExited) {
        if($Job.guardName){
            Initialize-MailInputGuard
            if([MailTransfer.InputGuard]::IsStopRequested($Job.guardName)){
                if($Job.cancelObservedAt-eq[DateTime]::MinValue){$Job.cancelObservedAt=[DateTime]::UtcNow}
                if(([DateTime]::UtcNow-$Job.cancelObservedAt).TotalSeconds-ge2){try{$Job.process.Kill()}catch{}}
            }
        }
        if(-not$Job.process.HasExited){return $null}
    }
    try { return (Read-BridgeJson $Job.resultFile) }
    catch { if($Job.cancelObservedAt-and$Job.cancelObservedAt-ne[DateTime]::MinValue){return [pscustomobject]@{result='CANCELLED';clicked=$null;error='USER_ABORTED';stage='STOPPED'}};return [pscustomobject]@{ result = 'FAILED'; clicked = $false; error = 'SEND_PROCESS_FAILED' } }
}
function Send-BridgePacket {
    param([string]$Path, [string]$Configuration,[ValidateSet('Internal','External')][string]$Role='Internal')
    $job = Start-BridgePacketSend $Path $Configuration -Role $Role
    while(-not$job.process.WaitForExit(150)){
        try{Assert-MailOperationContinue}catch{
            # This is the child created for this exact send. Do not touch other processes.
            if(-not$job.process.WaitForExit(2000)){try{$job.process.Kill()}catch{}}
            throw
        }
    }
    Assert-MailOperationContinue
    $outcome = Complete-BridgePacketSend $job
    if ($outcome.result -eq 'SUBMITTED_UI_CONFIRMED') { return }
    # The button may already have been pressed: never resend automatically.
    if ($outcome.clicked) { throw 'TRANSFER_SUBMITTED_UNCONFIRMED' }
    if ([string]$outcome.error -cmatch '^[A-Z][A-Z0-9_]+$') { throw [string]$outcome.error }
    throw 'TRANSFER_FAILED'
}
function Get-BridgeSendFailureMessage {
    param([string]$Code)
    switch ($Code) {
        'USER_ABORTED' { return 'F4로 중지했습니다. 이미 전송이 실행됐을 수 있으므로 수신 여부를 확인한 뒤 다시 요청하세요.' }
        'F4_HOTKEY_UNAVAILABLE' { return 'F4 중지 키를 확보하지 못해 작업을 시작하지 않았습니다. 다른 자동화 작업을 종료한 뒤 다시 시도하세요.' }
        'INPUT_HOOK_UNAVAILABLE' { return '입력 보호를 시작하지 못해 작업을 중단했습니다.' }
        'ANOTHER_INPUT_GUARD_IS_RUNNING' { return '이 PC에서 다른 자동화 작업이 실행 중입니다.' }
        'TRANSFER_SUBMITTED_UNCONFIRMED' { return '자료교환 보내기는 눌렀지만 완료를 확인하지 못했습니다. 다시 누르기 전에 자료교환 보내기 목록을 확인하세요.' }
         'EDITOR_CANCEL_NOT_UNIQUE' { return '자료교환의 취소 버튼을 확인하지 못했습니다. 직접 취소한 뒤 다시 실행하세요.' }
        'EMPTY_SEND_LIST_NOT_CONFIRMED' { return '자료교환 보내기 목록을 비우고 초기 ＋ 화면으로 돌아온 뒤 다시 실행하세요.' }
        'SEND_EDITOR_VIEW_USE_CANCEL_AND_RETRY' { return '자료교환의 취소를 눌러 초기 ＋ 화면으로 돌아온 뒤 다시 실행하세요.' }
        'EMPTY_EDITOR_CANCEL_NOT_FOUND_USE_CANCEL_MANUALLY' { return '자료교환의 취소를 눌러 초기 ＋ 화면으로 돌아온 뒤 다시 실행하세요.' }
        'TEST_FILE_REGISTRATION_NOT_CONFIRMED' { return '자료교환에 보낼 파일이 등록됐는지 확인하지 못했습니다. 보내기는 누르지 않았습니다.' }
        'TEST_FILENAME_NOT_VERIFIED' { return '자료교환에 등록된 파일명을 확인하지 못했습니다. 보내기는 누르지 않았습니다.' }
        'CLICK_TARGET_NOT_UNIQUE' { return '자료교환 버튼을 하나로 인식하지 못했습니다. 다른 창이 가리지 않게 한 뒤 다시 실행하세요.' }
        'CLICK_TARGET_MOVED' { return '자료교환 버튼 위치가 도중에 바뀌어 중지했습니다. 창을 움직이지 말고 다시 실행하세요.' }
        'SEND_OUTCOME_UNCONFIRMED_DO_NOT_RESEND' { return '보내기를 누른 뒤 완료 화면을 확인하지 못했습니다. 다시 보내기 전에 반대쪽 수신 여부를 확인하세요.' }
        'IMAGE_TRANSFER_FAILED' { return '자료교환 이미지 전송에 실패했습니다. 자료교환 창과 진단 로그를 확인하세요.' }
        'TRANSFER_CALIBRATION_REQUIRED' { return '이 PC의 자료교환 이미지 모듈을 확인하지 못했습니다. 새 설치 파일을 다시 실행하세요.' }
        'ANOTHER_TRANSFER_IS_RUNNING' { return '다른 자료교환 자동 전송이 실행 중입니다. 잠시 후 다시 시도하세요.' }
        'TRANSFER_SENDER_NOT_EMPTY_OR_LAYOUT_CHANGED' { return '자료교환 보내기 목록이 비어 있지 않습니다. 목록을 비운 뒤 다시 시도하세요.' }
        'TRANSFER_WINDOW_STARTUP_TIMEOUT' { return '자료교환 창을 찾지 못했습니다. 자료교환에 로그인돼 있는지 확인하세요.' }
        default { return ('자료교환으로 보내지 못했습니다 (' + $Code + '). 자료교환 창이 열려 있고 보내기 목록이 비어 있는지 확인하세요.') }
    }
}
function Test-BridgeId {
    param([string]$Value)
    return $Value -cmatch '^[a-f0-9]{32}$'
}
function Read-BridgeInbox {
    param([string]$Folder)
    foreach($file in @(Get-ChildItem -LiteralPath $Folder -Filter 'MailTransfer-*.txt' -File -ErrorAction SilentlyContinue)){
        if($file.Name-cnotmatch'^MailTransfer-(?:Request|Result)-[a-f0-9]{32}(?: \([0-9]+\))?\.txt$'){continue}
        try {
            # Ignore partial gateway downloads; the poll loop tries them again.
            $packet=Read-BridgeJson $file.FullName
            if($packet.schemaVersion -eq 4 -and (Test-BridgeId $packet.requestId)){
                [pscustomobject]@{ File=$file; Packet=$packet }
            }
        } catch { }
    }
}

function Add-BridgeExchangeCleanup {
 param([string]$StateDirectory,[string]$Inbox,[ValidateSet('Internal','External')][string]$Role,[string]$RequestId,[string]$ReceivedPath)
 try{
  if(-not (Test-BridgeId $RequestId)){return}
  $folder=[IO.Path]::GetFullPath($Inbox).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  if(-not [string]::Equals([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReceivedPath)).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),$folder,[StringComparison]::OrdinalIgnoreCase)){return}
  $prefix=if($Role -eq 'External'){'Request'}else{'Result'}
  $name=[IO.Path]::GetFileName($ReceivedPath)
  if($name -notmatch ('^MailTransfer-'+$prefix+'-'+[regex]::Escape($RequestId)+'(?: \([0-9]+\))?\.txt$')){return}
  Write-BridgeJson (Join-Path $StateDirectory ('cleanup-'+$RequestId+'.json')) @{schemaVersion=1;kind='exchange-cleanup';role=$Role;requestId=$RequestId;inbox=$folder;receivedName=$name}
 }catch{} # Deletion scheduling must not change the collection/send outcome.
}
function Remove-BridgeExchangePacket {
 param([string]$Path,[string]$Folder,[string]$RequestId,[ValidateSet('Request','Result')][string]$Prefix)
 try{
  $full=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetDirectoryName($full).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  $allowed=[IO.Path]::GetFullPath($Folder).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
  if(-not [string]::Equals($parent,$allowed,[StringComparison]::OrdinalIgnoreCase)){return $false}
  if([IO.Path]::GetFileName($full) -notmatch ('^MailTransfer-'+$Prefix+'-'+[regex]::Escape($RequestId)+'(?: \([0-9]+\))?\.txt$')){return $false}
  if(-not (Test-Path -LiteralPath $full)){return $true}
  $file=Get-Item -LiteralPath $full
  if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}
  $packet=Read-BridgeJson $full
  $kinds=if($Prefix -eq 'Request'){@('key-request','mail-request','attachment-request')}else{@('public-key','mail-result','attachment-result')}
  if($packet.schemaVersion -ne 4 -or $packet.requestId -cne $RequestId -or $packet.kind -notin $kinds){return $false}
  [IO.File]::Delete($full);return $true
 }catch{return $false}
}
function Invoke-BridgeExchangeCleanup {
 param([string]$StateDirectory,[string]$Inbox,[ValidateSet('Internal','External')][string]$Role)
 if([string]::IsNullOrWhiteSpace($StateDirectory) -or [string]::IsNullOrWhiteSpace($Inbox)){return}
 foreach($file in @(Get-ChildItem -LiteralPath $StateDirectory -Filter 'cleanup-*.json' -File -ErrorAction SilentlyContinue)){
  try{
   if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
   $task=Read-BridgeJson $file.FullName -MaximumBytes 4096
   $id=[string]$task.requestId
   if(-not (Test-BridgeId $id) -or $file.Name -cne ('cleanup-'+$id+'.json') -or $task.schemaVersion -ne 1 -or $task.kind -cne 'exchange-cleanup' -or $task.role -cne $Role){continue}
   if(-not [string]::Equals([IO.Path]::GetFullPath([string]$task.inbox).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),[IO.Path]::GetFullPath($Inbox).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){continue}
   $receivedPrefix=if($Role -eq 'External'){'Request'}else{'Result'}
   $sentPrefix=if($Role -eq 'External'){'Result'}else{'Request'}
   $outbox=Join-Path $StateDirectory 'outbox'
   $received=Join-Path $Inbox ([string]$task.receivedName)
   $sent=Join-Path $outbox ('MailTransfer-'+$sentPrefix+'-'+$id+'.txt')
   $receivedRemoved=Remove-BridgeExchangePacket $received $Inbox $id $receivedPrefix
   $sentRemoved=Remove-BridgeExchangePacket $sent $outbox $id $sentPrefix
   $sidecarsRemoved=$true
   if($sentRemoved){
    foreach($suffix in @('.send.json','.send.progress.json')){
     $path=[IO.Path]::ChangeExtension($sent,$suffix)
     if(Test-Path -LiteralPath $path){try{$info=Get-Item -LiteralPath $path;if($info.Attributes -band [IO.FileAttributes]::ReparsePoint){$sidecarsRemoved=$false;continue};[IO.File]::Delete($path)}catch{$sidecarsRemoved=$false}}
    }
   }
   if($receivedRemoved -and $sentRemoved -and $sidecarsRemoved){[IO.File]::Delete($file.FullName)}
  }catch{} # Locked downloads or gateway reads are retried on the next poll/startup.
 }
}

function Restore-BridgeExchangeCleanup {
 # Recover confirmed historical submissions; unconfirmed sends never authorize cleanup.
 param([string]$StateDirectory,[string]$Inbox,[ValidateSet('Internal','External')][string]$Role)
 try{
  if($Role -eq 'External'){
   foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $StateDirectory 'outbox') -Filter 'MailTransfer-Result-*.send.json' -File -ErrorAction SilentlyContinue)){
    if($file.Name -cnotmatch '^MailTransfer-Result-([a-f0-9]{32})\.send\.json$' -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
    $id=$Matches[1]
    try{$outcome=Read-BridgeJson $file.FullName -MaximumBytes 16384;if($outcome.result -eq 'SUBMITTED_UI_CONFIRMED' -and $outcome.clicked -eq $true){Add-BridgeExchangeCleanup $StateDirectory $Inbox $Role $id (Join-Path $Inbox ('MailTransfer-Request-'+$id+'.txt'))}}catch{}
   }
  }else{
   $cache=Read-BridgeJson (Join-Path $StateDirectory 'last-mail-result.json')
   if($cache.schemaVersion -eq 4 -and $cache.kind -eq 'mail-result' -and $cache.status -eq 'success' -and (Test-BridgeId ([string]$cache.requestId))){Add-BridgeExchangeCleanup $StateDirectory $Inbox $Role ([string]$cache.requestId) (Join-Path $Inbox ('MailTransfer-Result-'+$cache.requestId+'.txt'))}
  }
 }catch{}
}

function Test-BridgeLoginRequiredCode {
 param([string]$Code)
 return $Code-in@('LOGIN_REQUIRED','LOGIN_INVALID_CREDENTIALS','LOGIN_FAILED','LOGIN_ACCOUNT_LOCKED','WEBMAIL_SESSION_EXPIRED','LOGIN_PAGE_NOT_READY','WEBMAIL_LOGIN_REQUIRED','AUTHENTICATED_MAIL_PAGE_REQUIRED','LOGIN_PAGE_REQUIRED','WEBMAIL_LOGIN_TIMEOUT')
}
