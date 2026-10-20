#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1,20)][int]$Count = 3,
    [string]$OutputDirectory = [Environment]::GetFolderPath('Desktop'),
    [System.Management.Automation.PSCredential]$LoginCredential,
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'
if(-not(Get-Command Assert-MailOperationContinue -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'InputGuard.ps1')}
if(-not(Get-Command Set-OperationStep -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'OperationTrace.ps1')}
function Get-MailLoginErrorCode {
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return $null }
    $text = [regex]::Replace($Message, '\s+', '')
    if ([regex]::IsMatch($text, '(?:아이디|비밀번호|암호|패스워드).{0,60}(?:틀렸|틀립니다|잘못되|잘못됐|일치하지않|불일치|올바르지않|정확하지않|맞지않|바르지않|다릅니다)|(?:invalid|incorrect|wrong).{0,35}(?:password|credentials|username)|(?:password|credentials|username).{0,35}(?:invalid|incorrect|wrong|doesnotmatch|mismatch)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return 'LOGIN_INVALID_CREDENTIALS' }
    if ([regex]::IsMatch($text, '(?:계정|아이디).{0,30}(?:잠겼|잠겨있|잠금상태|잠금처리되|잠금되었습니다|잠금됐|차단되었습니다|차단됐|차단되어있)|account(?:is|was|hasbeen)?(?:currently|temporarily)?(?:locked|disabled)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return 'LOGIN_ACCOUNT_LOCKED' }
    if ([regex]::IsMatch($text, '로그인.{0,30}(?:실패했|실패하|실패입니다)|login.{0,30}(?:failed|failure)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return 'LOGIN_FAILED' }
    if ([regex]::IsMatch($text, '세션.{0,30}(?:타임아웃|만료되)|session.{0,30}(?:timeout|expired)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return 'WEBMAIL_SESSION_EXPIRED' }
    return $null
}

function Get-MailLoginStatusExpression {
    return @'
function mailLoginErrorCode(text){text=String(text||'').replace(/\s+/g,'');
  if(new RegExp("(?:아이디|비밀번호|암호|패스워드).{0,60}(?:틀렸|틀립니다|잘못되|잘못됐|일치하지않|불일치|올바르지않|정확하지않|맞지않|바르지않|다릅니다)|(?:invalid|incorrect|wrong).{0,35}(?:password|credentials|username)|(?:password|credentials|username).{0,35}(?:invalid|incorrect|wrong|doesnotmatch|mismatch)","i").test(text))return "LOGIN_INVALID_CREDENTIALS";
  if(new RegExp("(?:계정|아이디).{0,30}(?:잠겼|잠겨있|잠금상태|잠금처리되|잠금되었습니다|잠금됐|차단되었습니다|차단됐|차단되어있)|account(?:is|was|hasbeen)?(?:currently|temporarily)?(?:locked|disabled)","i").test(text))return "LOGIN_ACCOUNT_LOCKED";
  if(new RegExp("로그인.{0,30}(?:실패했|실패하|실패입니다)|login.{0,30}(?:failed|failure)","i").test(text))return "LOGIN_FAILED";
  if(new RegExp("세션.{0,30}(?:타임아웃|만료되)|session.{0,30}(?:timeout|expired)","i").test(text))return "WEBMAIL_SESSION_EXPIRED";
  return null;
}
function readMailLoginStatus() {
  function visible(element){const r=element.getBoundingClientRect();for(let n=element;n;n=n.parentElement){const c=n.ownerDocument.defaultView.getComputedStyle(n);if(c.display==='none'||c.visibility==='hidden')return false;}return r.width>0&&r.height>0;}
  if(location.protocol!=='https:'||location.hostname!=='mail.ex.co.kr')return {ready:false,reason:'WRONG_ORIGIN'};
  const docs=[document];
  for(let i=0;i<docs.length&&i<10;i++)for(const frame of docs[i].querySelectorAll('iframe,frame')){try{const d=frame.contentDocument;if(d&&d.location.origin===location.origin&&!docs.includes(d))docs.push(d)}catch(_){}}
  for(const d of docs){
    for(const modal of d.querySelectorAll('.x-window,[role="dialog"],[role="alertdialog"],.modal')){
      if(!visible(modal))continue;const code=mailLoginErrorCode(modal.textContent);if(code)return {ready:false,errorCode:code,reason:'VISIBLE_AUTH_ERROR'};
    }
  }
  if(!/^\/mail\/mainframe\/?$/.test(location.pathname)){
    let text='';if(document.body){const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;while((node=walk.nextNode())&&text.length<20000){const p=node.parentElement;if(p&&!p.closest('script,style,noscript,textarea,input,a,button,select,option')&&visible(p))text+=' '+node.textContent;}}
    return {ready:false,errorCode:mailLoginErrorCode(text),reason:'LOGIN_PAGE'};
  }
  if(document.readyState!=='complete')return {ready:false,reason:'PAGE_LOADING'};
  for(const d of docs){
    const controls=[...d.querySelectorAll('a,button,input[type="button"],input[type="submit"],[role="button"]')];
    const text=e=>String(e.value||e.getAttribute('aria-label')||e.textContent||'').replace(/\s+/g,'').trim();
    const logout=controls.some(e=>visible(e)&&(/^로그아웃$/.test(text(e))||/\/logout(?:[/?#]|$)/i.test(e.getAttribute('href')||'')));
    const inbox=[...d.querySelectorAll('.x-tree-action-id-1 a,.x-tree-node-text,.x-tree-node-anchor,[role="treeitem"],a,button')].some(e=>visible(e)&&/^받은메일함(?:\(?\d+\)?)?$/.test(text(e)));
    const compose=controls.some(e=>visible(e)&&/^메일쓰기$/.test(text(e)));
    if(logout&&(inbox||compose))return {ready:true,reason:'AUTHENTICATED_MAIL_SHELL'};
    // Preserve support for the previously validated Ext tree even without a logout control.
    if([...d.querySelectorAll('.x-tree-action-id-1 a')].some(e=>visible(e)&&/^받은메일함(?:\(?\d+\)?)?$/.test(text(e))))return {ready:true,reason:'AUTHENTICATED_INBOX_TREE'};
  }
  return {ready:false,reason:'MAIL_SHELL_NOT_READY'};
}
readMailLoginStatus()
'@
}

function Get-MailSessionKeepAliveExpression {
    # Clicks a visible "시간연장"(extend session) control if present; reports LOGIN_REQUIRED when the
    # page is the login screen (session ended). Never clicks logout/end. No credentials involved.
    return @'
(function(){
  if(location.protocol!=='https:'||location.hostname!=='mail.ex.co.kr')return {code:'LOGIN_REQUIRED'};
  if(location.pathname==='/login')return {code:'LOGIN_REQUIRED'};
  function vis(e){const r=e.getBoundingClientRect();const c=getComputedStyle(e);return r.width>0&&r.height>0&&c.display!=='none'&&c.visibility!=='hidden'&&!e.disabled;}
  const label=e=>String(e.getAttribute('aria-label')||e.getAttribute('title')||e.value||e.textContent||'').replace(/\s+/g,'');
  const controls=[...document.querySelectorAll('button,a,input[type="button"],input[type="submit"],[role="button"]')];
  const extend=controls.filter(e=>{
    if(!vis(e)||! /^(사용연장|시간연장|세션연장|연장하기|로그인연장|시간늘리기)$/.test(label(e)))return false;
    if(e.tagName==='A'){const box=e.closest('.x-window,[role="dialog"],[role="alertdialog"],.modal');if(!box||!/(로그아웃|세션|남은시간)/.test(box.textContent.replace(/\s+/g,'')))return false;}
    return true;
  });
  if(extend.length>1)return {code:'SESSION_EXTENSION_NOT_UNIQUE'};
  let clicked=false;
  if(extend.length){try{extend[0].click();clicked=true;}catch(_){}}
  return {clicked:clicked,extendControls:extend.length};
})()
'@
}
function Get-MailFailureMessage {
    param([string]$Code)
    switch ($Code) {
        'LOGIN_REQUIRED' { return '외부 웹메일 로그인이 필요합니다. 프로그램이 연 Edge 창의 로그인 상태를 확인하세요.' }
        'WEBMAIL_LOGIN_REQUIRED' { return '외부 웹메일 로그인이 필요합니다.' }
        'AUTHENTICATED_MAIL_PAGE_REQUIRED' { return '로그인된 받은메일함 화면을 확인하지 못했습니다.' }
        'LOGIN_PAGE_REQUIRED' { return '외부 웹메일 로그인 화면을 확인하세요.' }
        'LOGIN_INVALID_CREDENTIALS' { return '아이디 또는 비밀번호가 틀렸습니다.' }
        'LOGIN_ACCOUNT_LOCKED' { return '웹메일 계정이 잠기거나 차단되었습니다.' }
        'LOGIN_PAGE_NOT_READY' { return '자동화용 Edge에서 로그인 입력 화면을 찾지 못했습니다. 외부 웹메일 창과 로그인 상태를 확인하세요.' }
        'ORIGINAL_MAIL_TEXT_NOT_FOUND' { return '이 메일의 원문을 추출하지 못했습니다.' }
        'LOGIN_FAILED' { return '웹메일 로그인이 실패했습니다.' }
        'LOGIN_INPUT_CANCELLED' { return '로그인 정보 입력을 취소했습니다.' }
        'LOGIN_RETRY_PAGE_UNAVAILABLE' { return '시험용 Edge의 로그인 창을 찾지 못했습니다.' }
        'LOGIN_RETRY_NAVIGATION_FAILED' { return '웹메일 로그인 화면으로 돌아가지 못했습니다.' }
        'WEBMAIL_SESSION_EXPIRED' { return '웹메일 로그인 세션이 만료되었습니다.' }
        'WEBMAIL_LOGIN_TIMEOUT' { return '생체 인증 완료를 기다리는 시간이 초과되었습니다.' }
        'ONE_LOGIN_BUTTON_REQUIRED' { return '웹메일 로그인 버튼을 하나로 식별하지 못했습니다.' }
        'ONE_ACTIVE_INBOX_REQUIRED' { return '현재 표시된 받은메일함 목록을 하나로 식별하지 못했습니다.' }
        'INBOX_DATE_SORT_UNAVAILABLE' { return '받은메일함의 받은날짜 정렬 기능을 찾지 못했습니다.' }
        'INBOX_DATE_SORT_FAILED' { return '받은메일함을 받은날짜 내림차순으로 정렬하지 못했습니다.' }
        'INBOX_SORT_FAILED' { return '받은메일함 정렬에 실패했습니다.' }
        'INBOX_SORT_TIMEOUT' { return '받은메일함 정렬 응답 시간이 초과되었습니다.' }
        'INBOX_PAGE_LOAD_FAILED' { return '받은메일함의 다음 페이지를 불러오지 못했습니다. 일부 메일만 성공으로 반환하지 않고 수집을 중단했습니다.' }
        'INBOX_PAGE_LOAD_TIMEOUT' { return '받은메일함 페이지 로딩 시간이 초과되었습니다.' }
        'INBOX_PAGE_NO_PROGRESS' { return '다음 페이지에서도 같은 메일 목록이 반복되어 수집을 중단했습니다.' }
        'INBOX_MAIL_COUNT_NOT_REACHED' { return '받은메일함의 메일 수에 비해 가져온 건수가 부족합니다.' }
        'MAIL_DATE_RANGE_INVALID' { return '수집 시작일과 종료일을 확인하세요.' }
        'MAIL_RECEIVED_DATE_UNREADABLE' { return '이 메일의 받은 날짜를 확인하지 못해 날짜 범위 수집에서 제외했습니다.' }
        'INBOX_DATE_SCAN_LIMIT' { return '기간을 찾는 목록 조회 한도를 넘었습니다. 기간을 좁혀 다시 요청하세요.' }
        'INBOX_PAGINATION_UNAVAILABLE' { return '받은메일함 페이지 이동 기능을 찾지 못했습니다.' }
        default { return '메일 수집에 실패했습니다.' }
    }
}

function Write-MailFailureResult {
    param([string]$OutputDirectory, [string]$RequestId, [string]$Code, [string]$Stage)
    $payload = [ordered]@{ schemaVersion = 3; kind = 'mail-result'; requestId = $RequestId; createdAt = (Get-Date).ToUniversalTime().ToString('o'); status = 'failed'; error = [ordered]@{ code = $Code; message = (Get-MailFailureMessage $Code); stage = $Stage }; mails = @() }
    $path = Join-Path $OutputDirectory ('MailText-BackgroundResult-{0}-{1}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 6))
    [IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding($true)))
    return $path
}
$script:MailLoginErrorSource = $null
$script:MailCdpSessions = @{}
function Close-MailCdpSessions {
    foreach ($session in @($script:MailCdpSessions.Values)) { $session.Client.Dispose() }
    $script:MailCdpSessions.Clear()
}
function Invoke-EdgeCdp {
    param([string]$SocketUrl, [string]$Method, [hashtable]$Parameters, [ValidateRange(1,600)][int]$TimeoutSeconds=100)
    $socketUri = [Uri]$SocketUrl
    if ($socketUri.Scheme -ne 'ws' -or $socketUri.Host -notin @('127.0.0.1', 'localhost', '[::1]')) { throw 'DEBUG_SOCKET_MUST_BE_LOCAL' }
    if(Get-Command Assert-MailOperationContinue -ErrorAction SilentlyContinue){Assert-MailOperationContinue}
    $guard=if(Get-Command Get-MailInputGuardContext -ErrorAction SilentlyContinue){Get-MailInputGuardContext}else{$null}
    $cancel=if($null-ne$guard){[Threading.CancellationTokenSource]::CreateLinkedTokenSource([Threading.CancellationToken[]]@([MailTransfer.InputGuard]::Token))}else{New-Object Threading.CancellationTokenSource}
    $cancel.CancelAfter($TimeoutSeconds*1000)
    $traceCallCode='';Start-OperationCall $Method $TimeoutSeconds
    try {
        if (-not $script:MailCdpSessions.ContainsKey($SocketUrl)) {
            $client = New-Object Net.WebSockets.ClientWebSocket
            $client.Options.Proxy = $null
            try { [void]$client.ConnectAsync($socketUri, $cancel.Token).GetAwaiter().GetResult() }
            catch { $client.Dispose(); throw }
            $session = @{ Client = $client; NextId = 2 }
            $script:MailCdpSessions[$SocketUrl] = $session
            # Keep this connection across the login click and biometric wait, so
            # asynchronous password-error alerts are not lost between commands.
            $enable = [Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Page.enable","params":{}}')
            $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$enable)
            [void]$client.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
        }
        $session = $script:MailCdpSessions[$SocketUrl]
        $client = $session.Client
        $commandId = $session.NextId; $session.NextId++
        $command = @{ id = $commandId; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 12 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($command)
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$bytes)
        [void]$client.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
        $buffer = New-Object byte[] 32768
        $receiveSegment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buffer)
        $commandReply = $null; $dialogError = $null; $dialogReplyId = 0
        for ($messages = 0; $messages -lt 1000; $messages++) {
            $stream = New-Object IO.MemoryStream
            try {
                do {
                    $received = $client.ReceiveAsync($receiveSegment, $cancel.Token).GetAwaiter().GetResult()
                    if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'DEBUG_SOCKET_CLOSED' }
                    $stream.Write($buffer, 0, $received.Count)
                    if ($stream.Length -gt 32MB) { throw 'DEBUG_REPLY_SIZE_LIMIT' }
                } while (-not $received.EndOfMessage)
                $reply = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
            }
            finally { $stream.Dispose() }
            if ($reply.method -eq 'Page.javascriptDialogOpening' -and $reply.params.type -eq 'alert') {
                $code = Get-MailLoginErrorCode ([string]$reply.params.message)
                if (-not [string]::IsNullOrEmpty($code)) {
                    $script:MailLoginErrorSource = 'native-alert'
                    $dialogError = $code
                    $dialogReplyId = $session.NextId; $session.NextId++
                    # Acknowledge only a recognized error alert. Never answer a
                    # prompt/confirmation or complete the biometric second factor.
                    $ack = @{ id = $dialogReplyId; method = 'Page.handleJavaScriptDialog'; params = @{ accept = $true } } | ConvertTo-Json -Depth 5 -Compress
                    $ackBytes = [Text.Encoding]::UTF8.GetBytes($ack)
                    $ackSegment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$ackBytes)
                    [void]$client.SendAsync($ackSegment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
                }
            }
            if ($dialogReplyId -ne 0 -and $reply.id -eq $dialogReplyId) { throw $dialogError }
            if ($reply.id -eq $commandId) { $commandReply = $reply }
            if ($null -ne $commandReply -and $dialogReplyId -eq 0) {
                if ($null -ne $commandReply.error) { throw 'DEBUG_PROTOCOL_ERROR' }
                return $commandReply.result
            }
        }
        throw 'DEBUG_COMMAND_REPLY_NOT_RECEIVED'
    }
    catch {
        if ($script:MailCdpSessions.ContainsKey($SocketUrl)) {
            $script:MailCdpSessions[$SocketUrl].Client.Dispose(); $script:MailCdpSessions.Remove($SocketUrl)
        }
        try{if(Get-Command Assert-MailOperationContinue -ErrorAction SilentlyContinue){Assert-MailOperationContinue}}catch{$traceCallCode='USER_ABORTED';throw}
        $traceCallCode=if($cancel.IsCancellationRequested){'CDP_TIMEOUT'}elseif($_.Exception.Message-cmatch'^[A-Z][A-Z0-9_]+$'){$_.Exception.Message}else{'CDP_CALL_FAILED'}
        throw $traceCallCode
    }
    finally { Stop-OperationCall $traceCallCode;$cancel.Dispose() }
}

function Get-MailEncoding {
    param([string]$Charset)
    if ([string]::IsNullOrWhiteSpace($Charset)) { $Charset = 'us-ascii' }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # Windows PowerShell already supports these legacy encodings.
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    }
    return [Text.Encoding]::GetEncoding($Charset,
        [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
}

function ConvertFrom-MailQuotedPrintable {
    param([string]$Value, [switch]$Header)
    if ($Header) { $Value = $Value.Replace('_', ' ') }
    else { $Value = [regex]::Replace($Value, '=\r?\n', '') }
    $stream = New-Object IO.MemoryStream
    try {
        for ($i = 0; $i -lt $Value.Length; $i++) {
            if ($Value[$i] -eq '=') {
                if ($i + 2 -ge $Value.Length -or
                    $Value.Substring($i + 1, 2) -notmatch '^[0-9A-Fa-f]{2}$') {
                    throw 'INVALID_QUOTED_PRINTABLE'
                }
                $stream.WriteByte([Convert]::ToByte($Value.Substring($i + 1, 2), 16))
                $i += 2
            }
            else {
                if ([int]$Value[$i] -gt 255) { throw 'INVALID_MIME_BYTE' }
                $stream.WriteByte([byte][int]$Value[$i])
            }
        }
        # Keep an empty byte array an array in the PowerShell pipeline.
        return ,($stream.ToArray())
    }
    finally { $stream.Dispose() }
}

function ConvertFrom-MailEncodedWord {
    param([string]$Value)
    # Whitespace between adjacent RFC 2047 encoded words is not displayed.
    $Value = [regex]::Replace($Value, '(?<=\?=)[ \t\r\n]+(?==\?)', '')
    $pattern = '=\?([^?\s]+)\?([BbQq])\?([^?]*)\?='
    return [regex]::Replace($Value, $pattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $encoding = Get-MailEncoding $match.Groups[1].Value
        if ($match.Groups[2].Value -ieq 'B') {
            $bytes = [Convert]::FromBase64String($match.Groups[3].Value)
        }
        else {
            $bytes = ConvertFrom-MailQuotedPrintable $match.Groups[3].Value -Header
        }
        return $encoding.GetString($bytes)
    })
}

function Split-MailEntity {
    param([string]$Raw, [int]$Depth = 0, [switch]$AllowEmptyHeaders)
    # A MIME child with no headers starts with one empty line (RFC 2046).
    if ($AllowEmptyHeaders -and $Raw -match '^(?:\r\n|\n)') {
        $newline = if ($Raw.StartsWith("`r`n")) { 2 } else { 1 }
        return [pscustomobject]@{ Headers = @{}; Body = $Raw.Substring($newline) }
    }
    $separator = [regex]::Match($Raw, '\r?\n\r?\n')
    if (-not $separator.Success) { throw 'MIME_HEADER_SEPARATOR_MISSING' }
    $headerText = $Raw.Substring(0, $separator.Index)
    $headers = @{}; $currentKey = ''; $ignoreFold = $false; $lineNumber = 0
    foreach ($line in ($headerText -split '\r?\n')) {
        $lineNumber++
        if ($line -match '^[ \t]' -and $currentKey) {
            if (-not $ignoreFold) { $headers[$currentKey] += ' ' + $line.TrimStart([char[]]@([char]32, [char]9)) }
            continue
        }
        # RFC 5322 field-name allows printable ASCII except colon, including _ and .
        $match = [regex]::Match($line, '^([\x21-\x39\x3B-\x7E]+):[ \t]*(.*)$')
        if (-not $match.Success) {
            $headerError = New-Object FormatException('INVALID_MIME_HEADER')
            $reason = if ($line -match '^[ \t]') { 'ORPHAN_CONTINUATION' } elseif ($line -match '[^\x00-\x7F]') { 'NON_ASCII_HEADER_LINE' } elseif ($line -notmatch ':') { 'HEADER_COLON_MISSING' } else { 'INVALID_FIELD_NAME' }
            $headerError.Data['headerReason'] = $reason
            $headerError.Data['headerLine'] = $lineNumber
            $headerError.Data['mimeDepth'] = $Depth
            throw $headerError
        }
        $key = $match.Groups[1].Value
        # Preserve the first value for duplicate headers, including its folded lines.
        if (-not $headers.ContainsKey($key)) {
            $headers[$key] = $match.Groups[2].Value; $ignoreFold = $false
        } else { $ignoreFold = $true }
        $currentKey = $key
    }
    return [pscustomobject]@{
        Headers = $headers
        Body = $Raw.Substring($separator.Index + $separator.Length)
    }
}

function Get-MailParameter {
    param([string]$Value, [string]$Name)
    $pattern = '(?:^|;)\s*' + [regex]::Escape($Name) +
        '\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;\s]+))'
    $match = [regex]::Match($Value, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return '' }
    if ($match.Groups[1].Success) {
        return [regex]::Replace($match.Groups[1].Value, '\\(.)', '$1')
    }
    return $match.Groups[2].Value
}

function Get-MailTextParts {
    param([string]$Raw, [int]$Depth = 0)
    if ($Depth -gt 20) { throw 'MIME_NESTING_LIMIT' }
    $entity = Split-MailEntity $Raw -Depth $Depth -AllowEmptyHeaders:($Depth -gt 0)
    $headers = $entity.Headers
    $contentType = [string]$headers['Content-Type']
    if ([string]::IsNullOrWhiteSpace($contentType)) { $contentType = 'text/plain' }
    $mediaType = ($contentType -split ';', 2)[0].Trim().ToLowerInvariant()
    $disposition = [string]$headers['Content-Disposition']
    # Exclude file parts even if an attached file itself has type text/plain.
    if ($disposition -match '^\s*attachment(?:\s*;|\s*$)' -or
        $disposition -match '(?i)(?:^|;)\s*filename\*?\s*=' -or
        $contentType -match '(?i)(?:^|;)\s*name\*?\s*=') { return }

    if ($mediaType.StartsWith('multipart/')) {
        $boundary = Get-MailParameter $contentType 'boundary'
        if ([string]::IsNullOrWhiteSpace($boundary) -or $boundary.Length -gt 200) {
            throw 'INVALID_MIME_BOUNDARY'
        }
        $pattern = '(?m)^--' + [regex]::Escape($boundary) + '(--)?[ \t]*\r?$'
        $delimiters = [regex]::Matches($entity.Body, $pattern)
        if ($delimiters.Count -lt 2 -or $delimiters.Count -gt 200) {
            throw 'INVALID_MIME_PART_COUNT'
        }
        $closed = $false
        for ($i = 0; $i -lt $delimiters.Count - 1; $i++) {
            $delimiter = $delimiters[$i]
            if ($delimiter.Groups[1].Success) { break }
            $start = $delimiter.Index + $delimiter.Length
            if ($start -lt $entity.Body.Length -and $entity.Body[$start] -eq [char]10) { $start++ }
            $length = $delimiters[$i + 1].Index - $start
            $part = $entity.Body.Substring($start, $length)
            # Drop only the boundary's leading newline, never the header separator.
            $partSeparator = [regex]::Match($part, '\r?\n\r?\n')
            $ending = if ($part.EndsWith("`r`n")) { 2 } elseif ($part.EndsWith("`n")) { 1 } else { 0 }
            if ($ending -gt 0 -and $partSeparator.Success -and ($part.Length - $ending) -ge ($partSeparator.Index + $partSeparator.Length)) {
                $part = $part.Substring(0, $part.Length - $ending)
            }
            Get-MailTextParts -Raw $part -Depth ($Depth + 1)
            if ($delimiters[$i + 1].Groups[1].Success) { $closed = $true; break }
        }
        if (-not $closed) { throw 'MIME_CLOSING_BOUNDARY_MISSING' }
        return
    }
    if ($mediaType -ne 'text/plain' -and $mediaType -ne 'text/html') { return }
    $encoding = Get-MailEncoding (Get-MailParameter $contentType 'charset')
    $transfer = ([string]$headers['Content-Transfer-Encoding']).Trim().ToLowerInvariant()
    switch ($transfer) {
        'base64' { $bytes = [Convert]::FromBase64String($entity.Body) }
        'quoted-printable' { $bytes = ConvertFrom-MailQuotedPrintable $entity.Body }
        default {
            if ($transfer -notin @('', '7bit', '8bit', 'binary')) {
                throw 'UNSUPPORTED_CONTENT_TRANSFER_ENCODING'
            }
            $bytes = [Text.Encoding]::GetEncoding(28591).GetBytes($entity.Body)
        }
    }
    return [pscustomobject]@{ Type = $mediaType; Text = $encoding.GetString($bytes) }
}

function Convert-MailHtmlToText {
    param([string]$Html)
    # Output plain text only. No HTML is executed or loaded in a browser.
    $text = [regex]::Replace($Html, '(?is)<(script|style)\b[^>]*>.*?</\1\s*>', '')
    $text = [regex]::Replace($text, '(?s)<!--.*?-->', '')
    $text = [regex]::Replace($text, '(?i)<br\b[^>]*>|</(?:p|div|li|tr|h[1-6])\s*>', [Environment]::NewLine)
    $text = [regex]::Replace($text, '(?s)<[^>]*>', '')
    return [Net.WebUtility]::HtmlDecode($text).Trim()
}

function ConvertFrom-MailBytes {
    param([byte[]]$Bytes)
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt 50MB) { throw 'INPUT_SIZE_LIMIT' }
    $offset = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        $offset = 3
    }
    $raw = [Text.Encoding]::GetEncoding(28591).GetString($Bytes, $offset, $Bytes.Length - $offset)
    $entity = Split-MailEntity $raw
    $headers = $entity.Headers
    # Subject is optional in an RFC message. The UI displays '(제목 없음)' for it.
    $parts = @(Get-MailTextParts $raw)
    $plain = @($parts | Where-Object { $_.Type -eq 'text/plain' -and -not [string]::IsNullOrWhiteSpace($_.Text) })
    $html = @($parts | Where-Object { $_.Type -eq 'text/html' -and -not [string]::IsNullOrWhiteSpace($_.Text) })
    $body = ''
    $source = 'empty'
    if ($plain.Count -gt 0) { $body = $plain[0].Text; $source = 'text/plain' }
    elseif ($html.Count -gt 0) { $body = Convert-MailHtmlToText $html[0].Text; $source = 'text/html' }
    $id = ([string]$headers['Message-ID']).Trim()
    if ([string]::IsNullOrWhiteSpace($id)) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $id = 'sha256:' + ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    $attachments=@();$attachmentError=''
    if(Get-Command Get-MailAttachmentParts -ErrorAction SilentlyContinue){try{$attachments=@(Get-MailAttachmentParts $raw)}catch{$attachmentError='ATTACHMENT_METADATA_FAILED'}}
    return [pscustomobject]@{
        attachments=$attachments
        attachmentError=$attachmentError
        id = $id
        subject = ConvertFrom-MailEncodedWord ([string]$headers['Subject'])
        from = ConvertFrom-MailEncodedWord ([string]$headers['From'])
        to = ConvertFrom-MailEncodedWord ([string]$headers['To'])
        date = [string]$headers['Date']
        body = $body
        bodyText = $body
        bodyHtml = $(if ($html.Count -gt 0) { $html[0].Text } else { '' })
        bodySource = $source
    }
}


function Get-MailFormatScript {
    return @'
// Formatting data for the TXT exchange payload. Uses the source document's
// computed styles, so formatting does not depend on copying a stylesheet.
// No HTML source, script, URL, or event handler is included in the result.
function captureMailBodyFormat(root) {
  if (!root || root.nodeType !== 1) throw new Error('MAIL_BODY_ELEMENT_REQUIRED');
  const permittedTags = new Set('div span p br hr table thead tbody tfoot tr td th caption colgroup col b strong i em u s strike font center blockquote pre code ul ol li dl dt dd h1 h2 h3 h4 h5 h6 a section article'.split(' '));
  const excludedTags = new Set('script style iframe frame object embed applet meta base link form input button textarea select option svg math template noscript'.split(' '));
  const properties = ['color','backgroundColor','fontFamily','fontSize','fontWeight','fontStyle',
    'lineHeight','letterSpacing','textAlign','textDecorationLine','whiteSpace','verticalAlign','textIndent','wordBreak','overflowWrap',
    'marginTop','marginRight','marginBottom','marginLeft',
    'paddingTop','paddingRight','paddingBottom','paddingLeft',
    'borderTopWidth','borderRightWidth','borderBottomWidth','borderLeftWidth',
    'borderTopStyle','borderRightStyle','borderBottomStyle','borderLeftStyle',
    'borderTopColor','borderRightColor','borderBottomColor','borderLeftColor',
    'borderCollapse','borderSpacing','listStyleType'];
  let count = 0;
  function read(node, depth) {
    if (++count > 10000 || depth > 40) throw new Error('MAIL_BODY_COMPLEXITY_LIMIT');
    if (node.nodeType === 3) return {type:'text',text:node.data};
    if (node.nodeType !== 1 || node.namespaceURI !== 'http://www.w3.org/1999/xhtml') return null;
    const tag = node.localName.toLowerCase();
    if (excludedTags.has(tag)) return null;
    const css = node.ownerDocument.defaultView.getComputedStyle(node);
    if (css.display === 'none' || css.visibility === 'hidden') return null;
    const style = {};
    for (const property of properties) if (css[property]) style[property] = css[property];
    const result = {type:'element',tag:permittedTags.has(tag) ? tag : (css.display === 'inline' ? 'span' : 'div'),style,children:[]};
    if (tag === 'td' || tag === 'th') {
      result.colSpan = Math.min(100,Math.max(1,node.colSpan || 1));
      result.rowSpan = Math.min(100,Math.max(1,node.rowSpan || 1));
    }
    if (tag === 'img') {
      return {type:'text',text:node.alt ? '[이미지: '+node.alt+']' : '[이미지]'};
    }
    for (const child of node.childNodes) {
      const captured = read(child,depth+1);
      if (captured) result.children.push(captured);
    }
    return result;
  }
  // Read the root too: body-level font and background styles can affect all children.
  const capturedRoot = read(root,0);
  function plain(node) {
    if (!node) return '';
    if (node.type === 'text') return node.text;
    if (node.tag === 'br') return '\n';
    const content = node.children.map(plain).join('');
    return content + (/^(div|p|tr|li|blockquote|pre|h[1-6])$/.test(node.tag) ? '\n' : '');
  }
  return {version:1,root:capturedRoot,text:plain(capturedRoot).trim()};
}

function renderMailBodyFormat(model, container) {
  if (!model || model.version !== 1 || !model.root) throw new Error('INVALID_MAIL_BODY_FORMAT');
  const permittedTags = new Set('div span p br hr table thead tbody tfoot tr td th caption colgroup col b strong i em u s strike font center blockquote pre code ul ol li dl dt dd h1 h2 h3 h4 h5 h6 a section article'.split(' '));
  const properties = new Set(['color','backgroundColor','fontFamily','fontSize','fontWeight','fontStyle',
    'lineHeight','letterSpacing','textAlign','textDecorationLine','whiteSpace','verticalAlign','textIndent','wordBreak','overflowWrap',
    'marginTop','marginRight','marginBottom','marginLeft',
    'paddingTop','paddingRight','paddingBottom','paddingLeft',
    'borderTopWidth','borderRightWidth','borderBottomWidth','borderLeftWidth',
    'borderTopStyle','borderRightStyle','borderBottomStyle','borderLeftStyle',
    'borderTopColor','borderRightColor','borderBottomColor','borderLeftColor',
    'borderCollapse','borderSpacing','listStyleType']);
  let count = 0;
  const doc = container.ownerDocument;
  function build(node, depth) {
    if (++count > 10000 || depth > 40) throw new Error('MAIL_BODY_COMPLEXITY_LIMIT');
    if (node.type === 'text') return doc.createTextNode(String(node.text || ''));
    if (node.type !== 'element' || !permittedTags.has(node.tag)) throw new Error('INVALID_FORMAT_ELEMENT');
    const element = doc.createElement(node.tag);
    for (const [key,value] of Object.entries(node.style || {})) {
      if (properties.has(key) && typeof value === 'string' && value.length < 300) element.style[key] = value;
    }
    if (node.tag === 'table') element.style.maxWidth = '100%';
    if (node.tag === 'td' || node.tag === 'th') {
      element.colSpan = Math.min(100,Math.max(1,Number(node.colSpan) || 1));
      element.rowSpan = Math.min(100,Math.max(1,Number(node.rowSpan) || 1));
    }
    if (!Array.isArray(node.children)) throw new Error('INVALID_FORMAT_CHILDREN');
    for (const child of node.children) element.appendChild(build(child,depth+1));
    return element;
  }
  // Build completely before replacing the displayed mail.
  const body = build(model.root,0);
  container.replaceChildren(body);
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {captureMailBodyFormat,renderMailBodyFormat};
}

'@
}
function Get-DirectMailExpression {
    param([int]$MailCount,[switch]$IdsOnly,[string[]]$MailIds=@(),[string]$DateFrom='',[string]$DateTo='')
    $collector = @'
// Uses the logged-in browser's normal original-message page in memory.
// Inbox pages are loaded through their existing store; original-message pages are fetched in memory.
async function readEdgeMailBackground(count,options={}) {
  if(!Number.isInteger(count)||count<1||count>1000)throw new Error('MAIL_COUNT_INVALID');
  if(location.protocol!=='https:'||location.hostname!=='mail.ex.co.kr'||location.pathname!=='/mail/mainframe')throw new Error('AUTHENTICATED_MAIL_PAGE_REQUIRED');
  function originalFromPage(text,parsed,contentType) {
    const pageTexts=[];
    for(const element of parsed.querySelectorAll('textarea,pre,xmp'))pageTexts.push(element.tagName==='TEXTAREA'?element.value:element.textContent);
    pageTexts.push(parsed.body&&parsed.body.textContent||'');
    // textContent loses line breaks represented by BR and block elements.
    let rendered='';
    function walk(node,preformatted) {
      if(node.nodeType===3){
        const value=node.data;
        if(!preformatted&&!value.trim()&&/[\r\n]/.test(value))return;
        rendered+=preformatted?value:value.replace(/\r?\n/g,' ');return;
      }
      if(node.nodeType!==1)return;
      const tag=node.localName;
      if(/^(script|style|button|input|select|noscript)$/.test(tag)||node.hidden||node.style.display==='none')return;
      if(tag==='a'&&/^(PC에\s*저장|헤더\s*보기|닫기)$/.test(node.textContent.trim()))return;
      if(tag==='br'){rendered+='\n';return;}
      if(tag==='textarea'){rendered+=node.value;return;}
      const block=/^(div|p|tr|li|section|article)$/.test(tag)||node.style.display==='block';
      if(block&&rendered&&!rendered.endsWith('\n'))rendered+='\n';
      const pre=preformatted||tag==='pre'||tag==='xmp'||/^pre/.test(node.style.whiteSpace);
      const beforeChildren=rendered.length;
      for(const child of node.childNodes)walk(child,pre);
      if(block&&(rendered.length===beforeChildren||!rendered.endsWith('\n')))rendered+='\n';
    }
    if(parsed.body)walk(parsed.body,false);
    pageTexts.push(rendered);
    const candidates=/^(?:text\/plain|message\/rfc822)/i.test(contentType)?[text,...pageTexts]:[...pageTexts,text];
    // Some viewers keep their source in a JSON or JavaScript string. Read only
    // the literal data; never execute fetched code or use eval/Function.
    const literals=/"(?:[^"\\]|\\[\s\S])*"|'(?:[^'\\]|\\[\s\S])*'/g;
    let match,literalCount=0;
    while((match=literals.exec(text))&&++literalCount<=1024) {
      const quoted=match[0];
      if(quoted.length<80)continue;
      let value;
      try {
        if(quoted[0]==='"')value=JSON.parse(quoted);
        else value=quoted.slice(1,-1).replace(/\\(?:u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|\r\n|[\s\S])/g,token=>{
          const code=token.slice(1);
          if(code[0]==='u'||code[0]==='x')return String.fromCharCode(parseInt(code.slice(1),16));
          if(code==='\n'||code==='\r\n')return '';
          return ({n:'\n',r:'\r',t:'\t',b:'\b',f:'\f'})[code]||code;
        });
      }catch(_){continue;}
      if(typeof value==='string'&&/(?:^|\r?\n)(?:Subject|From|Received|Return-Path|Message-ID):/i.test(value)&&/(?:^|\r?\n)(?:Date|MIME-Version|Content-Type|To):/i.test(value)) {
        if(/&(?:lt|gt);/i.test(value))value=value.replace(/&(?:lt|gt|amp|quot|apos|#\d+|#x[0-9a-f]+);/gi,entity=>{
          const decoder=parsed.createElement('textarea');decoder.innerHTML=entity;return decoder.value;
        });
        candidates.push(value);
      }
    }
    for(const candidate of candidates) {
      const start=candidate.search(/(?:^|\r?\n)(?:Return-Path|Received|Message-ID|Date|To|Cc|Sender|MIME-Version|Content-Type|From|Subject):/i);
      if(start<0)continue;
      const raw=candidate.slice(start).replace(/^\r?\n/,'');
      const separator=/\r?\n\r?\n/.exec(raw);
      if(!separator)continue;
      const header=raw.slice(0,separator.index);
      let current=false,valid=true;
      for(const line of header.split(/\r?\n/)) {
        if(/^[ \t]/.test(line)){if(!current){valid=false;break;}continue;}
        if(!/^[\x21-\x39\x3B-\x7E]+:[ \t]*[^\r\n]*$/.test(line)){valid=false;break;}
        current=true;
      }
      const hasMime=/^(?:MIME-Version|Content-Type):/im.test(header);
      const hasEnvelope=/^(?:From|Received|Return-Path|Message-ID):/im.test(header);
      const fields=header.split(/\r?\n/).filter(line=>/^[\x21-\x39\x3B-\x7E]+:/.test(line)).length;
      // Plain RFC mail can omit MIME headers; a mail can also omit Subject.
      if(valid&&fields>=2&&((/^Subject:/im.test(header)&&hasMime)||hasEnvelope))return raw;
    }
    return '';
  }
  function visible(element) {
    const r=element.getBoundingClientRect();
    for(let node=element;node;node=node.parentElement) {
      const css=getComputedStyle(node);
      if(css.display==='none'||css.visibility==='hidden')return false;
    }
    return r.width>0&&r.height>0;
  }
  function componentFor(grid) {
    for(let node=grid;node;node=node.parentElement) {
      if(!node.id)continue;
      try {
        const component=window.Ext&&window.Ext.getCmp(node.id);
        if(!component)continue;
        const store=typeof component.getStore==='function'?component.getStore():component.store;
        if(store&&typeof store.getAt==='function')return {component,store};
      }catch(_){}
    }
    return {component:null,store:null};
  }
  const idSources=[],ids=[],seen=new Set();let pagesRead=0,dateMetadata={dateFailures:[],unreadableDates:0,dateLimitReached:false};
  let grid=null, component=null, store=null, gridCount=0, visibleGridCount=0;
  if(!options.ids) {
  const deadline=Date.now()+15000;
  do {
    const grids=[];
    for(const header of document.querySelectorAll('.x-grid3-hd-subject')) {
      const candidate=header.closest('.x-grid3');
      if(candidate&&!grids.includes(candidate))grids.push(candidate);
    }
    gridCount=grids.length;
    const active=[];
    for(const candidate of grids) {
      const header=candidate.querySelector('.x-grid3-hd-subject');
      if(header&&visible(header))active.push(candidate);
    }
    visibleGridCount=active.length;
    if(active.length===1){grid=active[0];({component,store}=componentFor(grid));break;}
    await new Promise(resolve=>setTimeout(resolve,200));
  }while(Date.now()<deadline);
  if(!grid) {
    const error=new Error('ONE_ACTIVE_INBOX_REQUIRED');
    error.details={gridCount,visibleGridCount};throw error;
  }
  let dateField='';
  try {
    const model=component&&(typeof component.getColumnModel==='function'?component.getColumnModel():component.colModel);
    for(const column of model&&model.config||[]) {
      if(/받은\s*(날짜|일시|시간)|수신\s*(일시|날짜|시간)/.test(String(column.header||''))&&/^[A-Za-z_][A-Za-z0-9_]{0,60}$/.test(column.dataIndex||'')){dateField=column.dataIndex;break;}
    }
  }catch(_){}
  if(!dateField&&grid.querySelector('.x-grid3-td-timeMillis'))dateField='timeMillis';
  const descendingHeader=!!grid.querySelector('.x-grid3-td-timeMillis.sort-desc,.x-grid3-td-timeMillis .sort-desc');
  let state=null;
  try {state=store&&(typeof store.getSortState==='function'?store.getSortState():store.sortInfo);}catch(_){}
  const ordered=state&&state.field===dateField&&String(state.direction).toUpperCase()==='DESC';
  const componentFound=!!component;
  let sortedRemotely=false;
  if(!ordered&&store&&dateField&&typeof store.sort==='function') {
    if(store.remoteSort) {
      if(typeof store.on!=='function'||typeof store.un!=='function')throw new Error('INBOX_SORT_EVENTS_UNAVAILABLE');
      await new Promise((resolve,reject)=>{
        let done=false;
        const finish=error=>{
          if(done)return;done=true;clearTimeout(timer);
          store.un('load',loaded);store.un('exception',failed);store.un('loadexception',failed);
          if(error)reject(error);else resolve();
        };
        const loaded=()=>finish();
        const failed=()=>finish(new Error('INBOX_SORT_FAILED'));
        const timer=setTimeout(()=>finish(new Error('INBOX_SORT_TIMEOUT')),15000);
        store.on('load',loaded);store.on('exception',failed);store.on('loadexception',failed);
        try {if(store.sort(dateField,'DESC')===false)failed();}catch(_){failed();}
      });
      sortedRemotely=true;
    } else {store.sort(dateField,'DESC');}
    const sorted=typeof store.getSortState==='function'?store.getSortState():store.sortInfo;
    if(!sorted||sorted.field!==dateField||String(sorted.direction).toUpperCase()!=='DESC')throw new Error('INBOX_DATE_SORT_FAILED');
  } else if(!ordered&&(!descendingHeader||state)) {
    const error=new Error('INBOX_DATE_SORT_UNAVAILABLE');
    error.details={gridCount,visibleGridCount,componentFound,storeFound:!!store,dateFieldFound:!!dateField,sortMethodFound:!!(store&&typeof store.sort==='function')};throw error;
  }
  if(!sortedRemotely&&store&&typeof store.reload==='function'&&store.lastOptions) {
    await new Promise((resolve,reject)=>{
      let done=false;
      const canObserve=typeof store.on==='function'&&typeof store.un==='function';
      const finish=error=>{
        if(done)return;done=true;clearTimeout(timer);
        if(canObserve){store.un('load',loaded);store.un('exception',failed);store.un('loadexception',failed);}
        if(error)reject(error);else resolve();
      };
      const loaded=()=>finish();
      const failed=()=>finish(new Error('INBOX_REFRESH_FAILED'));
      const timer=setTimeout(()=>finish(new Error('INBOX_REFRESH_TIMEOUT')),15000);
      // Register before reload: some Ext stores emit load but replace the supplied callback.
      if(canObserve){store.on('load',loaded);store.on('exception',failed);store.on('loadexception',failed);}
      try {
        const accepted=store.reload({callback:(_records,_options,success)=>{
          if(success===false)failed();else loaded();
        }});
        if(accepted===false)failed();
      }catch(_){failed();}
    });
  }
  // One received-inbox page holds a fixed number of rows (e.g. 20). To collect more than one page,
  // walk the store's pages newest-first, gathering mail IDs, until we have the requested count or run out.
  function extractId(record, table) {
    const data = record && record.data;
    if(data) {
      const keys=Object.keys(data);
      let field='';
      for(const key of keys) if(/^(_?uid|mail_?uid|mail_?id|muid|message_?uid)$/i.test(key) && /^\d{6,15}$/.test(String(data[key]))){field=key;break;}
      if(!field) for(const key of keys) if(/^id$/i.test(key) && /^\d{6,15}$/.test(String(data[key]))){field=key;break;}
      if(field) return {id:String(data[field]),src:'loaded-record-field:'+field};
    }
    const cell=table&&table.querySelector('td.x-grid3-td-subject');
    const controls=cell?Array.from(cell.querySelectorAll('[onclick],a[href]')):[];
    for(const control of controls) {
      const value=(control.getAttribute('onclick')||'')+' '+(control.getAttribute('href')||'');
      const numbers=Array.from(new Set(value.match(/(?<!\d)\d{6,15}(?!\d)/g)||[]));
      if(numbers.length===1) return {id:numbers[0],src:'mail-link'};
    }
    if(record&&/^\d{6,15}$/.test(String(record.id))) return {id:String(record.id),src:'loaded-record-id'};
    return null;
  }
  const range=options.dateFrom||options.dateTo?{from:String(options.dateFrom||''),to:String(options.dateTo||'')}:null;
  if(range&&(!/^\d{4}-\d{2}-\d{2}$/.test(range.from)||!/^\d{4}-\d{2}-\d{2}$/.test(range.to)||range.from>range.to))throw new Error('MAIL_DATE_RANGE_INVALID');
  const dateFailures=[];let unreadableDates=0,rangeFinished=false;
  const seoulDate=value=>new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(value);
  function receivedDate(record,table){
    const values=[];
    try{if(dateField&&record&&typeof record.get==='function')values.push(record.get(dateField));}catch(_){}
    const data=record&&record.data;
    if(data){if(dateField)values.push(data[dateField]);for(const key of ['timeMillis','receivedAt','receivedDate','receiveTime','recvDate'])if(key!==dateField)values.push(data[key]);}
    if(table){const cell=table.querySelector(dateField?'.x-grid3-td-'+dateField:'.x-grid3-td-timeMillis');if(cell)values.push(cell.getAttribute('title'),cell.textContent);}
    for(let value of values){
      if(value===null||value===undefined||value==='')continue;
      if(value instanceof Date){if(Number.isFinite(value.getTime()))return seoulDate(value);continue;}
      if(typeof value==='number'||/^\d{10,13}$/.test(String(value))){const n=Number(value);if(Number.isFinite(n)&&n>=1e9){const date=new Date(n<1e12?n*1000:n);if(Number.isFinite(date.getTime()))return seoulDate(date);}continue;}
      value=String(value).trim();
      if(/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d\d:?\d\d)$/i.test(value)){const date=new Date(value);if(Number.isFinite(date.getTime()))return seoulDate(date);continue;}
      const m=value.match(/(?:^|\D)(\d{4})[.\/-](\d{1,2})[.\/-](\d{1,2})(?!\d)/);
      if(m){const y=Number(m[1]),month=Number(m[2]),day=Number(m[3]),date=new Date(Date.UTC(y,month-1,day));if(date.getUTCFullYear()===y&&date.getUTCMonth()===month-1&&date.getUTCDate()===day)return `${m[1]}-${m[2].padStart(2,'0')}-${m[3].padStart(2,'0')}`;}
    }
    return '';
  }
  function takeRow(record,table,position){
    const found=extractId(record,table);
    if(!found){const error=new Error('MAIL_ID_NOT_FOUND');error.details={page:pagesRead,rowInPage:position,storeFound:!!store};throw error;}
    if(seen.has(found.id))return;
    seen.add(found.id);
    if(range){
      const date=receivedDate(record,table);
      if(!date){unreadableDates++;if(dateFailures.length<100)dateFailures.push({mailIndex:position,code:'MAIL_RECEIVED_DATE_UNREADABLE',details:{page:pagesRead}});return;}
      if(date>range.to)return;
      if(date<range.from){rangeFinished=true;return;}
    }
    ids.push(found.id);idSources.push(found.src);
  }
  const savedParams={...((store&&store.lastOptions&&store.lastOptions.params)||{})};
  const parameterNames=(store&&store.paramNames)||{};
  const startParam=parameterNames.start||'start',limitParam=parameterNames.limit||'limit';
  function loadStorePage(startAt,limitAt) {
    return new Promise((resolve,reject)=>{
      let done=false;const finish=error=>{if(done)return;done=true;clearTimeout(timer);error?reject(error):resolve();};
      const timer=setTimeout(()=>finish(new Error('INBOX_PAGE_LOAD_TIMEOUT')),20000);
      const params={...savedParams,[startParam]:startAt,[limitParam]:limitAt};
      try {if(store.load({params,callback:(_records,_options,success)=>finish(success===false?new Error('INBOX_PAGE_LOAD_FAILED'):null)})===false)finish(new Error('INBOX_PAGE_LOAD_FAILED'));}
      catch(_){finish(new Error('INBOX_PAGE_LOAD_FAILED'));}
    });
  }
  if(store&&typeof store.load==='function') {
    let toolbar=null;try{toolbar=component.getBottomToolbar?component.getBottomToolbar():component.bottomToolbar;}catch(_){}
    let pageSize=Number(savedParams[limitParam])||Number(toolbar&&toolbar.pageSize)||store.getCount()||20;
    if(!Number.isInteger(pageSize)||pageSize<1||pageSize>1000)throw new Error('INBOX_PAGE_SIZE_INVALID');
    // The currently displayed page may be page 2 or later. Always load actual page 1 first.
    let start=0,exhausted=false,total=0;
    for(let guard=0;ids.length<count&&guard<1000;guard++) {
      await loadStorePage(start,pageSize);
      const pageN=store.getCount();pagesRead++;
      try{total=Number(store.getTotalCount&&store.getTotalCount())||0;}catch(_){}
      if(!pageN){exhausted=true;break;}
      const pageTables=Array.from(grid.querySelectorAll('.x-grid3-row-table'));const before=seen.size;
      for(let i=0;i<pageN&&ids.length<count;i++) {
        let record=null;try{record=store.getAt(i);}catch(_){}
        takeRow(record,pageTables[i],start+i+1);
        if(rangeFinished)break;
      }
      if(rangeFinished){exhausted=true;break;}
      if(seen.size===before)throw new Error('INBOX_PAGE_NO_PROGRESS');
      start+=pageSize;
      if((total>0&&start>=total)||pageN<pageSize){exhausted=true;break;}
    }
    if(range){if(ids.length<count&&!exhausted)throw new Error('INBOX_DATE_SCAN_LIMIT');}
    else if(ids.length<count&&(!exhausted||(total>0&&ids.length<Math.min(count,total))))throw new Error('INBOX_MAIL_COUNT_NOT_REACHED');
    // Refresh the page indicator/list back to page 1 after successful multi-page discovery.
    if(pagesRead>1)await loadStorePage(0,pageSize);
  } else {
    const tables=Array.from(grid.querySelectorAll('.x-grid3-row-table'));pagesRead=1;
    if(range||count>tables.length)throw new Error('INBOX_PAGINATION_UNAVAILABLE');
    for(let i=0;i<tables.length&&ids.length<count;i++) {
      const found=extractId(null,tables[i]);
      if(!found)throw new Error('MAIL_ID_NOT_FOUND');
      if(seen.has(found.id))continue;
      seen.add(found.id);ids.push(found.id);idSources.push(found.src);
    }
  }
  dateMetadata={dateFailures,unreadableDates,dateLimitReached:!!range&&ids.length>=count};
  } else {
    if(!Array.isArray(options.ids)||!options.ids.length||options.ids.length>count)throw new Error('MAIL_IDS_INVALID');
    for(const value of options.ids){const id=String(value);if(!/^\d{6,15}$/.test(id)||seen.has(id))throw new Error('MAIL_IDS_INVALID');seen.add(id);ids.push(id);idSources.push('paged-inbox-id');}
  }
  if(options.idsOnly)return {ok:true,ids,requested:count,collected:ids.length,pagesRead,...dateMetadata};
  if(ids.length<1)throw new Error('NOT_ENOUGH_MAIL_ROWS');
  const target=Math.min(count,ids.length);
  const sources = new Array(target);
  let next = 0,fatalCode='';
  async function worker() {
    while(next<target) {
      const index=next++;
      if(fatalCode){sources[index]={ok:false,code:fatalCode};continue;}
      try{
      // This is the page URL supplied by the user, fetched with the existing login.
      const address=new URL('/mail/manage/viewMime/'+ids[index],location.origin);
      if(address.protocol!=='https:'||address.hostname!=='mail.ex.co.kr')throw new Error('WEBMAIL_ORIGIN_MISMATCH');
      const abort=new AbortController();
      const timer=setTimeout(()=>abort.abort(),15000);
      let response, text;
      try {
        response=await fetch(address.href,{credentials:'same-origin',cache:'no-store',signal:abort.signal});
        if(!response.ok)throw new Error('MAIL_PAGE_HTTP_FAILED');
        const finalUrl=new URL(response.url||address.href);
        if(finalUrl.origin!==address.origin||finalUrl.pathname!==address.pathname)throw new Error('WEBMAIL_LOGIN_REQUIRED');
        text=await response.text();
        if(text.length>12*1024*1024)throw new Error('MAIL_PAGE_SIZE_LIMIT');
      } catch(error) {
        if(error.name==='AbortError')throw new Error('MAIL_PAGE_FETCH_TIMEOUT');
        throw error;
      } finally { clearTimeout(timer); }
      const parsed=new DOMParser().parseFromString(text,'text/html');
      const contentType=response.headers.get('content-type')||'';
      let original=originalFromPage(text,parsed,contentType);
      let frameReadAttempts=0;
      // A source viewer may put its text in a separate same-origin read page.
      if(!original)for(const frame of parsed.querySelectorAll('iframe[src],frame[src]')) {
        if(frameReadAttempts>=2)break;
        let childAddress;
        try{childAddress=new URL(frame.getAttribute('src'),address.href);}catch(_){continue;}
        if(childAddress.origin!==address.origin||childAddress.href===address.href||
            !/^\/mail\//i.test(childAddress.pathname)||!/(view|read|mime|source|raw|body|content)/i.test(childAddress.pathname)||
            /(delete|remove|send|logout|logoff|trash|approve|compose|write)/i.test(childAddress.pathname+childAddress.search))continue;
        frameReadAttempts++;
        const childAbort=new AbortController();
        const childTimer=setTimeout(()=>childAbort.abort(),15000);
        try {
          const childResponse=await fetch(childAddress.href,{credentials:'same-origin',cache:'no-store',signal:childAbort.signal});
          if(!childResponse.ok)continue;
          const childFinal=new URL(childResponse.url||childAddress.href);
          if(childFinal.origin!==address.origin||childFinal.pathname!==childAddress.pathname)continue;
          const childText=await childResponse.text();
          if(childText.length>12*1024*1024)continue;
          const childDoc=new DOMParser().parseFromString(childText,'text/html');
          original=originalFromPage(childText,childDoc,childResponse.headers.get('content-type')||'');
          if(original)break;
        }catch(_){}finally{clearTimeout(childTimer);}
      }
      if(!original) {
        const error=new Error('ORIGINAL_MAIL_TEXT_NOT_FOUND');
        const fields=[];
        try {const record=store&&store.getAt(index);if(record&&record.data)for(const key of Object.keys(record.data))if(/^[A-Za-z_][A-Za-z0-9_]{0,60}$/.test(key))fields.push(key);}catch(_){}
        error.details={mailIndex:index+1,idSource:idSources[index],recordFields:fields,status:response.status||200,
          contentType:contentType.slice(0,120),responseChars:text.length,
          textareaCount:parsed.querySelectorAll('textarea').length,preCount:parsed.querySelectorAll('pre,xmp').length,
          breakCount:parsed.querySelectorAll('br').length,frameCount:parsed.querySelectorAll('iframe,frame').length,
          scriptCount:parsed.querySelectorAll('script').length,frameReadAttempts,subjectTokenPresent:/Subject:/i.test(text),
          mimeTokenPresent:/(MIME-Version|Content-Type):/i.test(text),loginTitle:/login|로그인/i.test(parsed.title),errorTitle:/error|오류/i.test(parsed.title)};
        throw error;
      }
      sources[index]={ok:true,original};
      }catch(error){
        const code=/^[A-Z0-9_]+$/.test(String(error.message))?error.message:'DIRECT_PAGE_READ_FAILED';
        const details={};
        for(const key of ['responseChars','textareaCount','preCount','breakCount','frameCount','scriptCount','frameReadAttempts','subjectTokenPresent','mimeTokenPresent','loginTitle','errorTitle']) {
          const value=error.details&&error.details[key];
          if(typeof value==='boolean'||(Number.isInteger(value)&&value>=0&&value<=12*1024*1024))details[key]=value;
        }
        sources[index]={ok:false,code,details};
        if(/^(WEBMAIL_LOGIN_REQUIRED|LOGIN_REQUIRED|AUTHENTICATED_MAIL_PAGE_REQUIRED|WEBMAIL_SESSION_EXPIRED)$/.test(code))fatalCode=code;
      }
    }
  }
  await Promise.all([worker(),worker()]);
  if(new TextEncoder().encode(JSON.stringify(sources)).length>24*1024*1024)throw new Error('DIRECT_BATCH_SIZE_LIMIT');
  return {ok:true,sources,requested:count,collected:target,pagesRead,idSources};
}
if(typeof module!=='undefined'&&module.exports)module.exports={readEdgeMailBackground};

'@
    $options=@{idsOnly=[bool]$IdsOnly}
    if($DateFrom-or$DateTo){$options.dateFrom=$DateFrom;$options.dateTo=$DateTo}
    if($MailIds.Count -gt 0){$options.ids=@($MailIds)}
    $optionsJson=$options|ConvertTo-Json -Compress
    $keepAlive=Get-MailSessionKeepAliveExpression
    return (Get-MailFormatScript) + "`n" + $collector + "`n(async()=>{const extend=()=> $keepAlive; let keepError=''; const keep=()=>{try{const state=extend();if(state.code)keepError=state.code;}catch(_){}};keep();if(keepError)throw new Error(keepError);const timer=setInterval(keep,5000);try{const value=await readEdgeMailBackground($MailCount,$optionsJson);keep();if(keepError){if(!value.sources)throw new Error(keepError);value.sessionError=keepError;}return value;}finally{clearInterval(timer);}})().then(value => ({ok:true,...value}), error => ({ok:false,code:/^[A-Z0-9_]+$/.test(error.message) ? error.message : 'DIRECT_PAGE_READ_FAILED',details:error.details || {}}))"
}
function Read-PagedInboxMails {
 param($Tab,[int]$MailCount,$Filter=$null)
 Set-OperationStep 'INBOX_IDS' 190
 $reply=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Runtime.evaluate' @{expression=(Get-DirectMailExpression $MailCount -IdsOnly -DateFrom $(if($Filter.mode-eq'range'){$Filter.from}else{''}) -DateTo $(if($Filter.mode-eq'range'){$Filter.to}else{''}));returnByValue=$true;awaitPromise=$true} -TimeoutSeconds 180
 $collection=$reply.result.value
 if($null -ne $reply.exceptionDetails -or $collection.ok -ne $true){
  if([string]$collection.code -cmatch '^[A-Z][A-Z0-9_]+$'){throw [string]$collection.code};throw 'MAIL_COLLECTION_FAILED'
 }
 $ids=@($collection.ids)
 if(($ids.Count-lt1-and$Filter.mode-ne'range')-or$ids.Count-gt$MailCount){throw 'INBOX_MAIL_COUNT_NOT_REACHED'}
 $seen=@{}
 foreach($id in $ids){if([string]$id -cnotmatch '^\d{6,15}$' -or $seen.ContainsKey([string]$id)){throw 'MAIL_IDS_INVALID'};$seen[[string]$id]=$true}
 $mails=New-Object 'System.Collections.Generic.List[object]'
 $failures=New-Object 'System.Collections.Generic.List[object]'
 foreach($failure in @($collection.dateFailures|Where-Object{$null-ne$_})){$failures.Add($failure)}
 $mailSeen=@{};$fatalCode=''
 for($offset=0;$offset -lt $ids.Count;){
  Assert-MailOperationContinue
  $batchSize=[Math]::Min(2,$ids.Count-$offset)
  $sources=@();$batchSessionCode=''
  if(-not$fatalCode){
   while($true){
    Set-OperationStep 'MAIL_BODY' 110 ($offset+1) $ids.Count
    $batch=@($ids[$offset..($offset+$batchSize-1)])
    try{
     $reply=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Runtime.evaluate' @{expression=(Get-DirectMailExpression $MailCount -MailIds $batch);returnByValue=$true;awaitPromise=$true}
     $result=$reply.result.value
     if($null -ne $reply.exceptionDetails -or $result.ok -ne $true){if([string]$result.code -cmatch '^[A-Z][A-Z0-9_]+$'){throw [string]$result.code};throw 'MAIL_COLLECTION_FAILED'}
     $sources=@($result.sources);$batchSessionCode=[string]$result.sessionError
     if($sources.Count -ne $batchSize){throw 'COLLECTED_MAIL_COUNT_MISMATCH'}
     break
    }catch{
     Assert-MailOperationContinue
     if($_.Exception.Message-eq'USER_ABORTED'){throw}
     $code='DEBUG_READ_FAILED';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
     # A failed batch is isolated to single messages before attributing a failure.
     if($batchSize -gt 1){$batchSize=1;continue}
     $sources=@(@{ok=$false;code=$code})
     break
    }finally{$reply=$null;$result=$null}
   }
  }else{$sources=@(1..$batchSize|ForEach-Object{@{ok=$false;code=$fatalCode}})}
  for($i=0;$i -lt $sources.Count;$i++){
   Set-OperationStep 'MAIL_PARSE' 30 ($offset+$i+1) $ids.Count
   $source=$sources[$i];$messageStage='MAIL_READ'
   try{
    if($source.ok -eq $false){
     $sourceCode=if([string]$source.code-cmatch'^[A-Z][A-Z0-9_]+$'){[string]$source.code}else{'MAIL_COLLECTION_FAILED'}
     $sourceError=New-Object InvalidOperationException($sourceCode)
     foreach($key in @('responseChars','textareaCount','preCount','breakCount','frameCount','scriptCount','frameReadAttempts','subjectTokenPresent','mimeTokenPresent','loginTitle','errorTitle')){
      $value=$source.details.$key
      if($value-is[bool]-or(($value-is[int]-or$value-is[long])-and$value-ge0-and$value-le12582912)){$sourceError.Data[$key]=$value}
     }
     throw $sourceError
    }
    if([string]::IsNullOrWhiteSpace([string]$source.original)){throw 'ORIGINAL_MAIL_TEXT_NOT_FOUND'}
    $messageStage='MAIL_PARSE'
    $mail=ConvertFrom-MailBytes ([Text.Encoding]::UTF8.GetBytes([string]$source.original))
    $mail|Add-Member -NotePropertyName sourceUid -NotePropertyValue ([string]$ids[$offset+$i]) -Force
    $messageStage='MAIL_IDENTITY'
    if([string]::IsNullOrWhiteSpace($mail.id)){throw 'MAIL_RESULT_ID_MISSING'}
    if($mailSeen.ContainsKey($mail.id)){
     # Message-ID is supplied by the sender and may be reused for distinct mailbox copies.
     # Discovery already validated unique server UIDs. Preserve both messages without
     # changing IDs/caches for the normal, non-colliding case.
     $messageId=[string]$mail.id
     $mail|Add-Member -NotePropertyName messageId -NotePropertyValue $messageId -Force
     $mail.id=$messageId+'#mailbox-uid='+[string]$ids[$offset+$i]
     if($mailSeen.ContainsKey($mail.id)){throw 'DUPLICATE_MAIL_RESULT'}
    }
    $mailSeen[$mail.id]=$true;$mails.Add($mail)
   }catch{
    Assert-MailOperationContinue
    if($_.Exception.Message-eq'USER_ABORTED'){throw}
    $code='MAIL_COLLECTION_FAILED';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
    $details=@{}
    foreach($key in @('headerLine','mimeDepth','responseChars','textareaCount','preCount','breakCount','frameCount','scriptCount','frameReadAttempts')){$value=$_.Exception.Data[$key];if(($value-is[int]-or$value-is[long])-and$value-ge0-and$value-le12582912){$details[$key]=$value}}
    foreach($key in @('subjectTokenPresent','mimeTokenPresent','loginTitle','errorTitle')){$value=$_.Exception.Data[$key];if($value-is[bool]){$details[$key]=$value}}
    $reason=[string]$_.Exception.Data['headerReason']
    if($reason-in@('ORPHAN_CONTINUATION','NON_ASCII_HEADER_LINE','HEADER_COLON_MISSING','INVALID_FIELD_NAME')){$details.headerReason=$reason}
    Record-OperationFailure $code
    $failures.Add(@{mailIndex=($offset+$i+1);sourceUid=[string]$ids[$offset+$i];stage=$messageStage;code=$code;details=$details})
    if($code-match'^(?:LOGIN_|WEBMAIL_LOGIN_|WEBMAIL_SESSION_|AUTHENTICATED_MAIL_PAGE_REQUIRED$|DEBUG_)'){$fatalCode=$code}
   }
  }
  if($batchSessionCode-match'^(?:LOGIN_|WEBMAIL_LOGIN_|WEBMAIL_SESSION_)'){$fatalCode=$batchSessionCode}
  $offset+=$batchSize
 }
 return @{mails=@($mails.ToArray());failures=@($failures.ToArray());requested=$MailCount;attempted=$ids.Count;collected=$mails.Count;failed=$failures.Count;pagesRead=$collection.pagesRead;dateLimitReached=($collection.dateLimitReached-eq$true);unreadableDates=$collection.unreadableDates}
}

function Write-DirectMailPreview {
    param($Payload, [string]$Path)
    $json = $Payload | ConvertTo-Json -Depth 100 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $template = @'
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'none'; frame-src about:; connect-src 'none'; base-uri 'none'; form-action 'none'"><title>외부메일</title><style>
*{box-sizing:border-box}body{margin:0;background:#f3f5f8;color:#202a3a;font-family:Arial,"Malgun Gothic",sans-serif;font-size:15px}header{padding:20px 24px;background:white;border-bottom:1px solid #ddd;font-size:22px;font-weight:bold}.layout{display:grid;grid-template-columns:320px minmax(0,1fr);height:calc(100vh - 70px)}nav{background:white;overflow:auto;border-right:1px solid #ddd;padding:12px}nav button{display:block;width:100%;text-align:left;white-space:normal;background:white;border:1px solid #e2e7ee;border-radius:8px;margin-bottom:10px;padding:16px;font:inherit;cursor:pointer}nav button[aria-pressed=true]{border-color:#2865d5;background:#edf4ff}main{overflow:auto;padding:24px}.sheet{max-width:1100px;margin:auto;background:white;border-radius:10px;padding:24px}h1{font-size:21px;line-height:1.5;margin-top:0}.meta{color:#687387;font-size:13px;margin-bottom:20px}.body-canvas{overflow:auto;padding:8px;border-top:1px solid #e5e9ef}.count{font-size:14px;color:#667;margin-left:12px}@media(max-width:800px){.layout{grid-template-columns:1fr;height:auto}nav{border-right:0}main{padding:12px}.sheet{padding:16px}}</style></head><body><header>외부메일<span id="count" class="count"></span></header><div class="layout"><nav id="list" aria-label="메일 목록"></nav><main><article class="sheet"><h1 id="subject"></h1><div class="meta" id="meta"></div><div class="body-canvas" id="body"></div></article></main></div><script>
__FORMAT_SCRIPT__
const payload=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__PAYLOAD__'),c=>c.charCodeAt(0))));
const list=document.getElementById('list');
document.getElementById('count').textContent=payload.mails.length+'건';
function showMailBody(mail,container) {
  if(!mail.bodyHtml){const pre=document.createElement('pre');pre.style.whiteSpace='pre-wrap';pre.style.font='inherit';pre.textContent=mail.body;container.replaceChildren(pre);return;}
  const parsed=new DOMParser().parseFromString(mail.bodyHtml,'text/html');
  const clean=document.createElement('div');
  const allowed=new Set('div span p br hr table thead tbody tfoot tr td th caption colgroup col b strong i em u s strike font center blockquote pre code ul ol li dl dt dd h1 h2 h3 h4 h5 h6 a style section article'.split(' '));
  const attrs=new Set('style class id align valign width height cellpadding cellspacing border colspan rowspan bgcolor color size face alt title lang dir start type'.split(' '));
  const blocked=new Set('script iframe frame object embed applet meta base link form input button textarea select option svg math template noscript'.split(' '));
  let nodes=0;
  function copy(node,parent,depth){
    if(++nodes>10000||depth>64)throw new Error('MAIL_BODY_COMPLEXITY_LIMIT');
    if(node.nodeType===3){parent.appendChild(document.createTextNode(node.data));return;}
    if(node.nodeType!==1||node.namespaceURI!=='http://www.w3.org/1999/xhtml'||blocked.has(node.localName))return;
    if(node.localName==='img'){parent.appendChild(document.createTextNode(node.alt?'[이미지: '+node.alt+']':'[이미지]'));return;}
    let dest=parent;
    if(allowed.has(node.localName)||node.localName==='body'){
      dest=document.createElement(node.localName==='body'?'div':node.localName);
      for(const attr of node.attributes)if(attrs.has(attr.name.toLowerCase()))dest.setAttribute(attr.name,attr.value);
      parent.appendChild(dest);
    }
    for(const child of node.childNodes)copy(child,dest,depth+1);
  }
  if(parsed.head)for(const style of parsed.head.querySelectorAll('style'))copy(style,clean,0);
  copy(parsed.body,clean,0);
  const frame=document.createElement('iframe');frame.setAttribute('sandbox','');frame.title='메일 본문';frame.style.cssText='width:100%;height:70vh;border:0;background:white';
  frame.srcdoc='<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'"></head><body>'+clean.innerHTML+'</body></html>';
  container.replaceChildren(frame);
}

function select(index){const mail=payload.mails[index];document.getElementById('subject').textContent=mail.subject;document.getElementById('meta').textContent=mail.from+' · '+mail.date;showMailBody(mail,document.getElementById('body'));Array.from(list.children).forEach((button,i)=>button.setAttribute('aria-pressed',String(i===index)));}
payload.mails.forEach((mail,index)=>{const button=document.createElement('button');button.textContent=mail.subject;button.addEventListener('click',()=>select(index));list.appendChild(button);});
if(payload.mails.length)select(0);
</script></body></html>
'@
    $html = $template.Replace('__FORMAT_SCRIPT__', (Get-MailFormatScript)).Replace('__PAYLOAD__', $encoded)
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding($false)))
}

function Get-EdgeProfilePages {
    param([string]$Profile)
    $portFile = Join-Path $Profile 'DevToolsActivePort'
    if (-not (Test-Path -LiteralPath $portFile -PathType Leaf)) { return }
    $lines = [IO.File]::ReadAllLines($portFile)
    $port = 0
    if ($lines.Length -lt 1 -or -not [int]::TryParse($lines[0], [ref]$port) -or $port -lt 1024 -or $port -gt 65535) { return }
    try {
        $reply = Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/json/list' -f $port) -TimeoutSec 2
        foreach ($page in @($reply)) { $page }
    }
    catch { return }
}
function Get-LoggedInWebmailTab {
    param([string]$Profile, [int]$TimeoutSeconds = 180)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $nextNotice = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Assert-MailOperationContinue
        $pages = @(Get-EdgeProfilePages $Profile)
        $tabs = @($pages | Where-Object {
            $uri = $null
            $_.type -eq 'page' -and [Uri]::TryCreate($_.url, [UriKind]::Absolute, [ref]$uri) -and
                $uri.Scheme -eq 'https' -and $uri.Host -eq 'mail.ex.co.kr' -and $uri.AbsolutePath -in @('/login','/mail/mainframe')
        })
        foreach ($candidate in @($tabs|Sort-Object {if(([Uri]$_.url).AbsolutePath-eq'/mail/mainframe'){0}else{1}})) {
            $state = $null
            try {
                $state = Invoke-EdgeCdp $candidate.webSocketDebuggerUrl 'Runtime.evaluate' @{
                    expression = (Get-MailLoginStatusExpression); returnByValue = $true
                }
            }
            catch {
                Assert-MailOperationContinue
                if ($_.Exception.Message -in @('LOGIN_INVALID_CREDENTIALS','LOGIN_ACCOUNT_LOCKED','LOGIN_FAILED','WEBMAIL_SESSION_EXPIRED')) { throw }
                # Retry only transient context changes during authentication navigation.
            }
            if ($null -ne $state -and $null -ne $state.result.value) {
                $value = $state.result.value
                if ($value.errorCode -in @('LOGIN_INVALID_CREDENTIALS','LOGIN_ACCOUNT_LOCKED','LOGIN_FAILED','WEBMAIL_SESSION_EXPIRED')) {
                    $script:MailLoginErrorSource = 'page-message'
                    throw $value.errorCode
                }
                if ($value.ready -eq $true) { return $candidate }
            }
        }
        if ([DateTime]::UtcNow -ge $nextNotice) {
            Write-Host '생체 인증 완료와 받은메일함 준비를 기다리고 있습니다.'
            $nextNotice = [DateTime]::UtcNow.AddSeconds(15)
        }
        Start-Sleep -Milliseconds 800
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'WEBMAIL_LOGIN_TIMEOUT'
}

function Set-MailAutomationProfileOwner {
 param([string]$Profile)
 # Called only for the automation's dedicated profile before launching Edge.
 $name=Split-Path -Leaf $Profile
 if($name -ne 'EdgeProfile' -and $name -cnotmatch '^ExternalLoginTest-[a-f0-9]{32}$'){throw 'AUTOMATION_PROFILE_REQUIRED'}
 [void][IO.Directory]::CreateDirectory($Profile)
 [IO.File]::WriteAllText((Join-Path $Profile 'MailTransfer-Owner.json'),'{"schemaVersion":1,"purpose":"mail-transfer-automation"}',(New-Object Text.UTF8Encoding($false)))
}
function Test-MailAutomationProfileOwner {
 param([string]$Profile)
 if([string]::IsNullOrWhiteSpace($Profile)){return $false}
 $name=Split-Path -Leaf $Profile
 if($name -ne 'EdgeProfile' -and $name -cnotmatch '^ExternalLoginTest-[a-f0-9]{32}$'){return $false}
 $marker=Join-Path $Profile 'MailTransfer-Owner.json'
 try{
  if(-not (Test-Path -LiteralPath $marker -PathType Leaf) -or (Get-Item -LiteralPath $marker).Length -gt 256){return $false}
  $owner=[IO.File]::ReadAllText($marker)|ConvertFrom-Json
  return ($owner.schemaVersion -eq 1 -and $owner.purpose -ceq 'mail-transfer-automation')
 }catch{return $false}
}
function Close-MailAutomationBrowser {
 param([string]$Profile)
 # Do not enumerate or kill msedge processes. Validate the dedicated profile's
 # browser target identity, then close that browser through its own CDP socket.
 if(-not (Test-MailAutomationProfileOwner $Profile)){return 'NOT_OWNED'}
 $portFile=Join-Path $Profile 'DevToolsActivePort';$client=$null;$cancel=$null
 try{
  if(-not (Test-Path -LiteralPath $portFile -PathType Leaf)){return 'NOT_RUNNING'}
  $lines=[IO.File]::ReadAllLines($portFile);$port=0
  if($lines.Length -lt 2 -or -not [int]::TryParse($lines[0],[ref]$port) -or $port -lt 1024 -or $port -gt 65535 -or $lines[1] -cnotmatch '^/devtools/browser/[A-Za-z0-9-]{1,128}$'){return 'INVALID_DEBUG_IDENTITY'}
  $expectedPath=$lines[1]
  try{$version=Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/json/version' -f $port) -TimeoutSec 2}catch{return 'NOT_RUNNING'}
  $uri=$null
  if(-not [Uri]::TryCreate([string]$version.webSocketDebuggerUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'ws' -or $uri.Host -notin @('127.0.0.1','localhost') -or $uri.Port -ne $port -or $uri.AbsolutePath -cne $expectedPath -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){return 'DEBUG_IDENTITY_MISMATCH'}
  $cancel=New-Object Threading.CancellationTokenSource;$cancel.CancelAfter(5000)
  $client=New-Object Net.WebSockets.ClientWebSocket;$client.Options.Proxy=$null
  [void]$client.ConnectAsync($uri,$cancel.Token).GetAwaiter().GetResult()
  $bytes=[Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Browser.close","params":{}}')
  $segment=New-Object 'System.ArraySegment[byte]' -ArgumentList (,$bytes)
  [void]$client.SendAsync($segment,[Net.WebSockets.WebSocketMessageType]::Text,$true,$cancel.Token).GetAwaiter().GetResult()
  $buffer=New-Object byte[] 8192;$receive=New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buffer)
  $acknowledged=$false;$socketEnded=$false
  for($message=0;$message -lt 8;$message++){
   $memory=New-Object IO.MemoryStream
   try{
    do{
     $reply=$client.ReceiveAsync($receive,$cancel.Token).GetAwaiter().GetResult()
     if($reply.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){$socketEnded=$true;break}
     $memory.Write($buffer,0,$reply.Count);if($memory.Length -gt 8192){throw 'CLOSE_REPLY_TOO_LARGE'}
    }while(-not $reply.EndOfMessage)
    if($socketEnded){break}
    $packet=[Text.Encoding]::UTF8.GetString($memory.ToArray())|ConvertFrom-Json
    if($packet.id -eq 1){if($packet.error){return 'CLOSE_REJECTED'};$acknowledged=$true;break}
   }finally{$memory.Dispose()}
  }
  if(-not $acknowledged -and -not $socketEnded){return 'CLOSE_UNCONFIRMED'}
  $deadline=[DateTime]::UtcNow.AddSeconds(3)
  do{
   Start-Sleep -Milliseconds 150
   try{$current=Invoke-RestMethod -Uri ('http://127.0.0.1:{0}/json/version' -f $port) -TimeoutSec 1}catch{return 'CLOSED'}
   if([string]$current.webSocketDebuggerUrl -cne [string]$version.webSocketDebuggerUrl){return 'CLOSED'}
  }while([DateTime]::UtcNow -lt $deadline)
  return 'CLOSE_UNCONFIRMED'
 }catch{return 'CLOSE_FAILED'}
 finally{if($client){$client.Dispose()};if($cancel){$cancel.Dispose()}}
}

function Start-MailAutomationEdgeCore {
    param([string]$Profile)
    $candidates = @()
    foreach ($base in @([Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
            [Environment]::GetEnvironmentVariable('ProgramFiles'), [Environment]::GetFolderPath('LocalApplicationData'))) {
        if (-not [string]::IsNullOrWhiteSpace($base)) { $candidates += Join-Path $base 'Microsoft\Edge\Application\msedge.exe' }
    }
    $edge = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -eq $edge) { throw 'INSTALLED_EDGE_NOT_FOUND' }
    $null = New-Item -ItemType Directory -Path $Profile -Force
    Set-MailAutomationProfileOwner $Profile
    $arguments = @('--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
        ('--user-data-dir="{0}"' -f $Profile), '--no-first-run', '--no-default-browser-check',
        '--new-window', 'https://mail.ex.co.kr/login')
    $null = Start-Process -FilePath $edge -ArgumentList $arguments -PassThru
    Write-Host '시험용 Edge를 열었습니다. 입력한 정보로 자동 로그인을 진행합니다.'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (@(Get-EdgeProfilePages $Profile).Count -gt 0) { return }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'EDGE_DEBUG_ENDPOINT_UNAVAILABLE'
}


function Start-MailAutomationEdge {
 param([string]$Profile)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Profile).ToUpperInvariant())))).Replace('-','')}finally{$sha.Dispose()}
 $mutex=New-Object Threading.Mutex($false,('Local\MailTransferEdgeStartup-'+$key.Substring(0,32)));$owned=$false
 try{
  try{$owned=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$owned=$true}
  if(-not $owned){throw 'EDGE_STARTUP_BUSY'}
  if(@(Get-EdgeProfilePages $Profile | Where-Object {$_.type -eq 'page'}).Count -gt 0){return}
  Start-MailAutomationEdgeCore $Profile
 }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Invoke-MailLoginUntilBiometric {
    param($Tab, [System.Management.Automation.PSCredential]$Credential, $Report = $null)
    if ($null -eq $Credential) { throw 'CREDENTIALS_REQUIRED' }
    $script = @'
// Called only with credentials already decrypted in memory on the external PC.
// One login click. The human must complete the biometric second factor.
function submitMailLogin(userId,password) {
  const fail=(code,details)=>({ok:false,code,...(details?{details}:{})});
  if(location.protocol!=='https:'||location.hostname!=='mail.ex.co.kr'||location.pathname!=='/login')return fail('LOGIN_PAGE_REQUIRED');
  const visible=element=>{
    const r=element.getBoundingClientRect();
    const c=getComputedStyle(element);
    return r.width>0&&r.height>0&&c.display!=='none'&&c.visibility!=='hidden'&&!element.disabled;
  };
  const norm=value=>String(value||'').replace(/\s+/g,' ').trim();
  const passwords=[];
  for(const element of document.querySelectorAll('input[type="password"]'))if(visible(element))passwords.push(element);
  if(passwords.length!==1)return fail('ONE_PASSWORD_FIELD_REQUIRED');
  const pass=passwords[0];
  const scope=pass.form||document;
  const users=[];
  for(const element of scope.querySelectorAll('input')) {
    if(!/^(text|email)$/.test(element.type)||!visible(element)||element.readOnly)continue;
    if(element.compareDocumentPosition(pass)&Node.DOCUMENT_POSITION_FOLLOWING)users.push(element);
  }
  if(users.length!==1)return fail('ONE_USERNAME_FIELD_REQUIRED');
  // Use all explicit labels, including spaced text and image-only login buttons.
  // A child and its clickable wrapper are one physical button, not two choices.
  const candidates=[];
  const isLoginLabel=value=>/^(로그인|login|signin)$/i.test(norm(value).replace(/\s/g,''));
  let examined=0;
  for(const element of document.querySelectorAll('button,a,input[type="submit"],input[type="button"],input[type="image"],img,[role="button"],[onclick],div,span,p,li,label')) {
    if(!visible(element))continue;
    const form=element.closest('form');
    if(pass.form&&form&&form!==pass.form)continue;
    examined++;
    const labels=[element.getAttribute('aria-label'),element.getAttribute('alt'),element.getAttribute('title'),element.textContent];
    if(element.matches('input[type="submit"],input[type="button"],input[type="image"]'))labels.push(element.value);
    let matches=labels.some(isLoginLabel);
    if(!matches&&element.matches('img,input[type="image"]')) {
      const filename=(element.getAttribute('src')||'').split(/[?#]/)[0].split('/').pop();
      matches=/^(?:(?:bt|btn|button)[_-]?)?login(?:[_-]?(?:btn|button|on|off|over|out|normal|hover|[0-9]+))*\.(?:gif|png|svg|webp|jpe?g)$/i.test(filename);
    }
    if(!matches) {
      // Some portals use a styled DIV with an attached event listener, not a button.
      const names=(element.id+' '+String(element.className||'')).split(/\s+/);
      matches=names.some(name=>/^(?:(?:bt|btn|button)[_-]?login|login[_-]?(?:btn|button|submit))$/i.test(name));
    }
    if(!matches) {
      const action=element.getAttribute('onclick')||(/^javascript:/i.test(element.getAttribute('href')||'')?element.getAttribute('href'):'');
      const calls=action.match(/[A-Za-z_$][\w$]*\s*(?=\()/g)||[];
      matches=calls.some(call=>/^(?:(?:go|do|fn|check|proc|submit)[_-]?)?login(?:[_-]?(?:submit|action|check|process))?$/i.test(call.trim()));
    }
    if(!matches)continue;
    const target=element.closest('button,a,input,[role="button"],[onclick]')||element;
    if(visible(target)&&!candidates.includes(target))candidates.push(target);
  }
  const buttons=[];
  for(const target of candidates) {
    // Clicking the inner target also bubbles to its wrapper's normal handler.
    if(!candidates.some(other=>other!==target&&target.contains(other)))buttons.push(target);
  }
  let buttonStrategy='explicit-login-control';
  if(buttons.length===0&&pass.form) {
    const submitters=[];
    for(const control of document.querySelectorAll('button,input')) {
      if(control.form===pass.form&&/^(submit|image)$/.test(control.type)&&visible(control))submitters.push(control);
    }
    if(submitters.length===1){buttons.push(submitters[0]);buttonStrategy='credential-form-submit-control';}
  }
  const buttonDetails={visibleControls:examined,matchedTargets:candidates.length,distinctButtons:buttons.length,strategy:buttonStrategy};
  if(buttons.length!==1)return fail('ONE_LOGIN_BUTTON_REQUIRED',buttonDetails);
  const biometric=[];
  for(const radio of scope.querySelectorAll('input[type="radio"]')) {
    let label='';
    for(const item of radio.labels||[])label+=' '+item.textContent;
    if(!label.trim()) {
      let sibling=radio.nextSibling;
      for(let i=0;sibling&&i<3;i++,sibling=sibling.nextSibling) {
        if(sibling.nodeType===1&&sibling.matches('input'))break;
        label+=' '+sibling.textContent;
      }
    }
    if(/생체\s*인증/.test(label)&&!/OTP|카톡/i.test(label)&&visible(radio))biometric.push(radio);
  }
  if(biometric.length!==1)return fail('BIOMETRIC_OPTION_NOT_IDENTIFIED');
  userId=norm(userId).replace(/@ex\.co\.kr$/i,'');
  if(!userId||typeof password!=='string'||!password)return fail('CREDENTIALS_REQUIRED');
  // Validate the credential fields and biometric choice before filling the form.
  if(!biometric[0].checked)biometric[0].click();
  const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  for(const [element,value] of [[users[0],userId],[pass,password]]) {
    setter.call(element,value);
    element.dispatchEvent(new Event('input',{bubbles:true}));
    element.dispatchEvent(new Event('change',{bubbles:true}));
  }
  if(!biometric[0].checked||users[0].value!==userId||pass.value!==password)return fail('LOGIN_FORM_CHANGED');
  password='';
  buttons[0].click();
  return {ok:true,state:'AWAITING_BIOMETRIC',details:buttonDetails};
}
async function openReceivedInbox() {
  if(location.protocol!=='https:'||location.hostname!=='mail.ex.co.kr'||location.pathname!=='/mail/mainframe')return {ok:false,code:'AUTHENTICATED_MAIL_PAGE_REQUIRED'};
  const deadline=Date.now()+12000;let target=null;
  const visible=e=>{const r=e.getBoundingClientRect();for(let n=e;n;n=n.parentElement){const c=getComputedStyle(n);if(c.display==='none'||c.visibility==='hidden')return false;}return r.width>0&&r.height>0;};
  const inbox=e=>/^받은메일함(?:\(?\d+\)?)?$/.test(String(e.textContent||e.getAttribute('aria-label')||'').replace(/\s+/g,''));
  do {
    const anchors=[...document.querySelectorAll('.x-tree-action-id-1 a,.x-tree-node-anchor,.x-tree-node-text,[role="treeitem"],nav a,aside a,.x-tree-view a,.x-tree-panel a,.x-tree-node a')].filter(e=>visible(e)&&inbox(e));
    if(anchors.length){target=anchors[0].closest('a')||anchors[0].querySelector('a')||anchors[0].closest('[role="treeitem"]')||anchors[0];break;}
    await new Promise(resolve=>setTimeout(resolve,200));
  }while(Date.now()<deadline);
  if(!target)return {ok:false,code:'RECEIVED_INBOX_LINK_NOT_FOUND'};
  const options={bubbles:true,cancelable:true,view:window,button:0};
  for(const type of ['mousedown','mouseup','click'])target.dispatchEvent(new MouseEvent(type,{...options,buttons:type==='mousedown'?1:0}));
  do {
    const row=target.closest('.x-tree-action-id-1,.x-tree-node-el,.x-tree-node,[role="treeitem"]');
    const selected=!!(row&&(row.matches('.x-tree-selected,.x-tree-node-selected,[aria-selected="true"]')||row.querySelector('.x-tree-selected,.x-tree-node-selected,[aria-selected="true"]')));
    const activeInbox=[...document.querySelectorAll('.x-tab-strip-active,[role="tab"][aria-selected="true"]')].some(e=>visible(e)&&inbox(e));
    const header=[...document.querySelectorAll('.x-grid3-hd-subject,[data-columnid="subject"],[role="columnheader"]')].some(e=>visible(e)&&(e.matches('.x-grid3-hd-subject,[data-columnid="subject"]')||String(e.textContent).trim()==='제목'));
    if((selected||activeInbox)&&header)return {ok:true,state:'RECEIVED_INBOX_READY'};
    await new Promise(resolve=>setTimeout(resolve,200));
  }while(Date.now()<deadline);
  return {ok:false,code:'RECEIVED_INBOX_NOT_READY'};
}
if(typeof module!=='undefined'&&module.exports)module.exports={submitMailLogin};

'@
    $values = $null
    $expression = $null
    try {
        $values = @($Credential.UserName, $Credential.GetNetworkCredential().Password) | ConvertTo-Json -Compress
        $expression = $script + "`nsubmitMailLogin(...$values)"
        $reply = Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Runtime.evaluate' @{
            expression = $expression; returnByValue = $true; userGesture = $true
        }
        if ($null -ne $reply.exceptionDetails -or $null -eq $reply.result.value) { throw 'LOGIN_INPUT_FAILED' }
        $state = $reply.result.value
        if ($null -ne $Report -and $null -ne $state.details) {
            $Report.Add(('Login button structure: {0}' -f ($state.details | ConvertTo-Json -Depth 3 -Compress)))
        }
        if ($state.ok -ne $true) {
            if ($state.code -cmatch '^[A-Z][A-Z0-9_]+$') { throw $state.code }
            throw 'LOGIN_INPUT_FAILED'
        }
        return $state.state
    }
    finally { $values = $null; $expression = $null }
}
function Wait-MailLoginPage {
    param([string]$Profile, [int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Assert-MailOperationContinue
        $pages = @(Get-EdgeProfilePages $Profile)
        $tabs = @($pages | Where-Object {
            $uri = $null
            $_.type -eq 'page' -and [Uri]::TryCreate($_.url, [UriKind]::Absolute, [ref]$uri) -and
                $uri.Scheme -eq 'https' -and $uri.Host -eq 'mail.ex.co.kr' -and $uri.AbsolutePath -eq '/login'
        })
        if ($tabs.Count -gt 1) { throw 'EXACTLY_ONE_LOGIN_TAB_REQUIRED' }
        if ($tabs.Count -eq 1) {
            try {
                $state = Invoke-EdgeCdp $tabs[0].webSocketDebuggerUrl 'Runtime.evaluate' @{
                    expression = 'document.readyState === "complete" && !!document.querySelector("input[type=password]")'; returnByValue = $true
                }
                if ($state.result.value -eq $true) { return $tabs[0] }
            } catch {}
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'LOGIN_PAGE_NOT_READY'
}


function Reset-MailLoginPage {
    param([string]$Profile)
    $pages = @(Get-EdgeProfilePages $Profile | Where-Object {
        $uri = $null
        $_.type -eq 'page' -and [Uri]::TryCreate($_.url, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -eq 'https' -and $uri.Host -eq 'mail.ex.co.kr' -and $uri.AbsolutePath -in @('/login','/mail/mainframe')
    })
    if ($pages.Count -eq 0) { throw 'LOGIN_RETRY_PAGE_UNAVAILABLE' }
    if ($pages.Count -gt 1) { throw 'EXACTLY_ONE_LOGIN_TAB_REQUIRED' }
    $uri = [Uri]$pages[0].url
    if ($uri.AbsolutePath -eq '/login') { return }
    $reply = Invoke-EdgeCdp $pages[0].webSocketDebuggerUrl 'Page.navigate' @{ url = 'https://mail.ex.co.kr/login' }
    if ($null -ne $reply.errorText) { throw 'LOGIN_RETRY_NAVIGATION_FAILED' }
}

function Select-ReceivedInbox {
    param($Tab)
    $script = @'
// Called only with credentials already decrypted in memory on the external PC.
// One login click. The human must complete the biometric second factor.
function submitMailLogin(userId,password) {
  const fail=(code,details)=>({ok:false,code,...(details?{details}:{})});
  if(location.protocol!=='https:'||location.hostname!=='mail.ex.co.kr'||location.pathname!=='/login')return fail('LOGIN_PAGE_REQUIRED');
  const visible=element=>{
    const r=element.getBoundingClientRect();
    const c=getComputedStyle(element);
    return r.width>0&&r.height>0&&c.display!=='none'&&c.visibility!=='hidden'&&!element.disabled;
  };
  const norm=value=>String(value||'').replace(/\s+/g,' ').trim();
  const passwords=[];
  for(const element of document.querySelectorAll('input[type="password"]'))if(visible(element))passwords.push(element);
  if(passwords.length!==1)return fail('ONE_PASSWORD_FIELD_REQUIRED');
  const pass=passwords[0];
  const scope=pass.form||document;
  const users=[];
  for(const element of scope.querySelectorAll('input')) {
    if(!/^(text|email)$/.test(element.type)||!visible(element)||element.readOnly)continue;
    if(element.compareDocumentPosition(pass)&Node.DOCUMENT_POSITION_FOLLOWING)users.push(element);
  }
  if(users.length!==1)return fail('ONE_USERNAME_FIELD_REQUIRED');
  // Use all explicit labels, including spaced text and image-only login buttons.
  // A child and its clickable wrapper are one physical button, not two choices.
  const candidates=[];
  const isLoginLabel=value=>/^(로그인|login|signin)$/i.test(norm(value).replace(/\s/g,''));
  let examined=0;
  for(const element of document.querySelectorAll('button,a,input[type="submit"],input[type="button"],input[type="image"],img,[role="button"],[onclick],div,span,p,li,label')) {
    if(!visible(element))continue;
    const form=element.closest('form');
    if(pass.form&&form&&form!==pass.form)continue;
    examined++;
    const labels=[element.getAttribute('aria-label'),element.getAttribute('alt'),element.getAttribute('title'),element.textContent];
    if(element.matches('input[type="submit"],input[type="button"],input[type="image"]'))labels.push(element.value);
    let matches=labels.some(isLoginLabel);
    if(!matches&&element.matches('img,input[type="image"]')) {
      const filename=(element.getAttribute('src')||'').split(/[?#]/)[0].split('/').pop();
      matches=/^(?:(?:bt|btn|button)[_-]?)?login(?:[_-]?(?:btn|button|on|off|over|out|normal|hover|[0-9]+))*\.(?:gif|png|svg|webp|jpe?g)$/i.test(filename);
    }
    if(!matches) {
      // Some portals use a styled DIV with an attached event listener, not a button.
      const names=(element.id+' '+String(element.className||'')).split(/\s+/);
      matches=names.some(name=>/^(?:(?:bt|btn|button)[_-]?login|login[_-]?(?:btn|button|submit))$/i.test(name));
    }
    if(!matches) {
      const action=element.getAttribute('onclick')||(/^javascript:/i.test(element.getAttribute('href')||'')?element.getAttribute('href'):'');
      const calls=action.match(/[A-Za-z_$][\w$]*\s*(?=\()/g)||[];
      matches=calls.some(call=>/^(?:(?:go|do|fn|check|proc|submit)[_-]?)?login(?:[_-]?(?:submit|action|check|process))?$/i.test(call.trim()));
    }
    if(!matches)continue;
    const target=element.closest('button,a,input,[role="button"],[onclick]')||element;
    if(visible(target)&&!candidates.includes(target))candidates.push(target);
  }
  const buttons=[];
  for(const target of candidates) {
    // Clicking the inner target also bubbles to its wrapper's normal handler.
    if(!candidates.some(other=>other!==target&&target.contains(other)))buttons.push(target);
  }
  let buttonStrategy='explicit-login-control';
  if(buttons.length===0&&pass.form) {
    const submitters=[];
    for(const control of document.querySelectorAll('button,input')) {
      if(control.form===pass.form&&/^(submit|image)$/.test(control.type)&&visible(control))submitters.push(control);
    }
    if(submitters.length===1){buttons.push(submitters[0]);buttonStrategy='credential-form-submit-control';}
  }
  const buttonDetails={visibleControls:examined,matchedTargets:candidates.length,distinctButtons:buttons.length,strategy:buttonStrategy};
  if(buttons.length!==1)return fail('ONE_LOGIN_BUTTON_REQUIRED',buttonDetails);
  const biometric=[];
  for(const radio of scope.querySelectorAll('input[type="radio"]')) {
    let label='';
    for(const item of radio.labels||[])label+=' '+item.textContent;
    if(!label.trim()) {
      let sibling=radio.nextSibling;
      for(let i=0;sibling&&i<3;i++,sibling=sibling.nextSibling) {
        if(sibling.nodeType===1&&sibling.matches('input'))break;
        label+=' '+sibling.textContent;
      }
    }
    if(/생체\s*인증/.test(label)&&!/OTP|카톡/i.test(label)&&visible(radio))biometric.push(radio);
  }
  if(biometric.length!==1)return fail('BIOMETRIC_OPTION_NOT_IDENTIFIED');
  userId=norm(userId).replace(/@ex\.co\.kr$/i,'');
  if(!userId||typeof password!=='string'||!password)return fail('CREDENTIALS_REQUIRED');
  // Validate the credential fields and biometric choice before filling the form.
  if(!biometric[0].checked)biometric[0].click();
  const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  for(const [element,value] of [[users[0],userId],[pass,password]]) {
    setter.call(element,value);
    element.dispatchEvent(new Event('input',{bubbles:true}));
    element.dispatchEvent(new Event('change',{bubbles:true}));
  }
  if(!biometric[0].checked||users[0].value!==userId||pass.value!==password)return fail('LOGIN_FORM_CHANGED');
  password='';
  buttons[0].click();
  return {ok:true,state:'AWAITING_BIOMETRIC',details:buttonDetails};
}
async function openReceivedInbox() {
  if(location.protocol!=='https:'||location.hostname!=='mail.ex.co.kr'||location.pathname!=='/mail/mainframe')return {ok:false,code:'AUTHENTICATED_MAIL_PAGE_REQUIRED'};
  const deadline=Date.now()+12000;let target=null;
  const visible=e=>{const r=e.getBoundingClientRect();for(let n=e;n;n=n.parentElement){const c=getComputedStyle(n);if(c.display==='none'||c.visibility==='hidden')return false;}return r.width>0&&r.height>0;};
  const inbox=e=>/^받은메일함(?:\(?\d+\)?)?$/.test(String(e.textContent||e.getAttribute('aria-label')||'').replace(/\s+/g,''));
  do {
    const anchors=[...document.querySelectorAll('.x-tree-action-id-1 a,.x-tree-node-anchor,.x-tree-node-text,[role="treeitem"],nav a,aside a,.x-tree-view a,.x-tree-panel a,.x-tree-node a')].filter(e=>visible(e)&&inbox(e));
    if(anchors.length){target=anchors[0].closest('a')||anchors[0].querySelector('a')||anchors[0].closest('[role="treeitem"]')||anchors[0];break;}
    await new Promise(resolve=>setTimeout(resolve,200));
  }while(Date.now()<deadline);
  if(!target)return {ok:false,code:'RECEIVED_INBOX_LINK_NOT_FOUND'};
  const options={bubbles:true,cancelable:true,view:window,button:0};
  for(const type of ['mousedown','mouseup','click'])target.dispatchEvent(new MouseEvent(type,{...options,buttons:type==='mousedown'?1:0}));
  do {
    const row=target.closest('.x-tree-action-id-1,.x-tree-node-el,.x-tree-node,[role="treeitem"]');
    const selected=!!(row&&(row.matches('.x-tree-selected,.x-tree-node-selected,[aria-selected="true"]')||row.querySelector('.x-tree-selected,.x-tree-node-selected,[aria-selected="true"]')));
    const activeInbox=[...document.querySelectorAll('.x-tab-strip-active,[role="tab"][aria-selected="true"]')].some(e=>visible(e)&&inbox(e));
    const header=[...document.querySelectorAll('.x-grid3-hd-subject,[data-columnid="subject"],[role="columnheader"]')].some(e=>visible(e)&&(e.matches('.x-grid3-hd-subject,[data-columnid="subject"]')||String(e.textContent).trim()==='제목'));
    if((selected||activeInbox)&&header)return {ok:true,state:'RECEIVED_INBOX_READY'};
    await new Promise(resolve=>setTimeout(resolve,200));
  }while(Date.now()<deadline);
  return {ok:false,code:'RECEIVED_INBOX_NOT_READY'};
}
if(typeof module!=='undefined'&&module.exports)module.exports={submitMailLogin};

'@
    $reply = Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Runtime.evaluate' @{
        expression = $script + "`nopenReceivedInbox()"; returnByValue = $true; awaitPromise = $true; userGesture = $true
    }
    if ($null -ne $reply.exceptionDetails -or $null -eq $reply.result.value) { throw 'INBOX_NAVIGATION_FAILED' }
    $state = $reply.result.value
    if ($state.ok -ne $true) {
        if ($state.code -cmatch '^[A-Z][A-Z0-9_]+$') { throw $state.code }
        throw 'INBOX_NAVIGATION_FAILED'
    }
    return $state.state
}

if ($LibraryOnly) { return }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { throw 'Output folder unavailable.' }
$report = New-Object 'System.Collections.Generic.List[string]'
$report.Add('Mail Automation v8 - external login, manual biometric authentication, received inbox, collection')
$report.Add(('Generated: {0:o}' -f (Get-Date)))
$report.Add(('Requested mail count: {0}' -f $Count))
$report.Add('Mail contents, browser credentials, and URLs are omitted from this report.')
$report.Add('EML files saved: none; original-message pages read in memory')
$timer = [Diagnostics.Stopwatch]::StartNew()
$profile = $null
$stage = 'CONNECT_AUTOMATION_EDGE'
$result = 'FAILED'
$requestId = 'external-test-' + [Guid]::NewGuid().ToString('N')
try {
    $stage = 'GET_LOGIN_CREDENTIALS'
    Write-Host '외부 웹메일 로그인 → 생체 인증 직접 완료 → 받은메일함 선택 → 최신 3건 수집'
    if ($null -eq $LoginCredential) {
        $LoginCredential = Get-Credential -Message '외부 웹메일 아이디(@ 앞부분)와 비밀번호를 입력하세요. 비밀번호를 파일이나 로그에 저장하지 않습니다.'
    }
    if ($null -eq $LoginCredential) { throw 'LOGIN_INPUT_CANCELLED' }
    $profile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('MailTransfer\ExternalLoginTest-' + [Guid]::NewGuid().ToString('N'))
    $report.Add('Isolated login test session: yes')
    $pages = @(Get-EdgeProfilePages $profile)
    $hasMailTab = @($pages | Where-Object {
        $uri = $null
        $_.type -eq 'page' -and [Uri]::TryCreate($_.url, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -eq 'https' -and $uri.Host -eq 'mail.ex.co.kr'
    }).Count -gt 0
    if ($pages.Count -eq 0 -or -not $hasMailTab) {
        $stage = 'START_AUTOMATION_EDGE'
        Start-MailAutomationEdge $profile
        $report.Add('Automation Edge started: yes')
    }
    else { $report.Add('Automation Edge started: no; existing session reused') }
    $loginAttempt = 0
    while ($true) {
        $loginAttempt++
        $script:MailLoginErrorSource = $null
        $report.Add(('Login attempt: {0}' -f $loginAttempt))
        try {
            $stage = 'ENTER_LOGIN_CREDENTIALS'
            $loginTab = Wait-MailLoginPage $profile
            try { $loginState = Invoke-MailLoginUntilBiometric $loginTab $LoginCredential $report }
            finally { $LoginCredential = $null }
            $report.Add(('Login state: {0}' -f $loginState))
            if ($loginState -ne 'AWAITING_BIOMETRIC') { throw 'UNEXPECTED_LOGIN_STATE' }
            $stage = 'WAIT_SECOND_FACTOR'
            Write-Host '아이디·비밀번호 입력과 로그인 버튼 클릭을 완료했습니다. 생체 인증을 직접 진행하세요.'
            Write-Host '메일함이 열릴 때까지 수집하지 않습니다. 인증이 끝나면 자동으로 수집합니다.'
            $tabs = @(Get-LoggedInWebmailTab $profile)
            $report.Add(('Matching logged-in webmail tabs: {0}' -f $tabs.Count))
            break
        }
        catch {
            $LoginCredential = $null
            $loginErrorCode = $_.Exception.Message
            if ($loginErrorCode -notin @('LOGIN_INVALID_CREDENTIALS','LOGIN_FAILED','LOGIN_ACCOUNT_LOCKED','WEBMAIL_SESSION_EXPIRED')) { throw }
            $loginErrorMessage = Get-MailFailureMessage $loginErrorCode
            $report.Add(('Login attempt {0} failed: {1}; stage: {2}' -f $loginAttempt, $loginErrorCode, $stage))
            if ($null -ne $script:MailLoginErrorSource) { $report.Add(('Login error source: {0}' -f $script:MailLoginErrorSource)) }
            Write-Host ('로그인 실패: {0} ({1})' -f $loginErrorMessage, $loginErrorCode)
            # Native error alerts have already been acknowledged by Invoke-EdgeCdp.
            # Publish the failed attempt before asking for fresh credentials.
            try {
                $attemptFailurePath = Write-MailFailureResult $OutputDirectory $requestId $loginErrorCode $stage
                $report.Add(('Login attempt {0} failure TXT written: yes' -f $loginAttempt))
                Write-Host ('실패 결과 TXT: {0}' -f $attemptFailurePath)
            }
            catch { $report.Add(('Login attempt {0} failure TXT written: no' -f $loginAttempt)) }
            $stage = 'GET_RETRY_LOGIN_CREDENTIALS'
            Write-Host '로그인 정보를 다시 입력하세요. 입력 창에서 취소하면 종료합니다.'
            $LoginCredential = Get-Credential -Message ($loginErrorMessage + ' 아이디(@ 앞부분)와 비밀번호를 다시 입력하세요. 취소하면 종료합니다.')
            if ($null -eq $LoginCredential) { throw 'LOGIN_INPUT_CANCELLED' }
            $stage = 'RESET_LOGIN_PAGE'
            Reset-MailLoginPage $profile
        }
    }
    $stage = 'SELECT_RECEIVED_INBOX'
    $inboxState = Select-ReceivedInbox $tabs[0]
    $report.Add(('Inbox state: {0}' -f $inboxState))
    Write-Host '생체 인증과 받은메일함 선택이 완료됐습니다. 최신 3건을 수집합니다.'
    $stage = 'READ_LOGGED_IN_MAIL_PAGES'
    $readTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host ('로그인된 웹메일에서 최신 {0}건을 백그라운드로 읽습니다.' -f $Count)
    $reply = Invoke-EdgeCdp $tabs[0].webSocketDebuggerUrl 'Runtime.evaluate' @{
        expression = (Get-DirectMailExpression $Count); returnByValue = $true; awaitPromise = $true
    }
    if ($null -ne $reply.exceptionDetails -or $null -eq $reply.result.value) { throw 'DIRECT_READ_EVALUATION_FAILED' }
    $readTimer.Stop()
    $report.Add(('Background read seconds: {0:F2}' -f $readTimer.Elapsed.TotalSeconds))
    $collection = $reply.result.value
    if ($collection.ok -ne $true) {
        if ($null -ne $collection.details) { $report.Add(('Browser state: {0}' -f ($collection.details | ConvertTo-Json -Depth 5 -Compress))) }
        if ($collection.code -cmatch '^[A-Z][A-Z0-9_]+$') { throw $collection.code }
        throw 'DIRECT_PAGE_READ_FAILED'
    }
    $stage = 'VALIDATE_RESULT'
    $mails = @($collection.sources | ForEach-Object {
        $rawBytes = [Text.Encoding]::UTF8.GetBytes([string]$_.original)
        ConvertFrom-MailBytes $rawBytes
    })
    $report.Add(('Mail identity sources: {0}' -f ($collection.idSources -join ', ')))
    if ($mails.Count -ne $Count) { throw 'COLLECTED_MAIL_COUNT_MISMATCH' }
    $report.Add(('Visible inbox rows: {0}' -f $collection.visibleRowCount))
    $ids = @{}
    for ($index = 0; $index -lt $mails.Count; $index++) {
        $mail = $mails[$index]
        if ([string]::IsNullOrWhiteSpace($mail.subject) -or [string]::IsNullOrWhiteSpace($mail.body)) {
            throw 'INCOMPLETE_MAIL_RESULT'
        }
        $sourceKey = [string]$mail.id
        if ([string]::IsNullOrWhiteSpace($sourceKey) -or $ids.ContainsKey($sourceKey)) { throw 'DUPLICATE_MAIL_IDENTITY' }
        $ids[$sourceKey] = $true
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $mail.id = 'page-sha256:' + ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($sourceKey)))).Replace('-', '').ToLowerInvariant() }
        finally { $hash.Dispose() }
        $report.Add(('Mail {0}: subjectChars={1}; bodyChars={2}; htmlBodyChars={3}' -f ($index+1), $mail.subject.Length, $mail.body.Length, $mail.bodyHtml.Length))
    }
    $stage = 'WRITE_RESULT'
    $stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $payload = [ordered]@{ schemaVersion = 3; kind = 'mail-result'; requestId = $requestId; createdAt = (Get-Date).ToUniversalTime().ToString('o'); status = 'success'; mails = $mails }
    $payloadPath = Join-Path $OutputDirectory ('MailText-BackgroundResult-{0}.txt' -f $stamp)
    $previewPath = Join-Path $OutputDirectory ('MailText-BackgroundPreview-{0}.html' -f $stamp)
    $json = $payload | ConvertTo-Json -Depth 100 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 8MB) { throw 'TXT_PAYLOAD_SIZE_LIMIT' }
    [IO.File]::WriteAllText($payloadPath, $json, (New-Object Text.UTF8Encoding($true)))
    Write-DirectMailPreview $payload $previewPath
    $report.Add(('Exported mail count: {0}' -f $mails.Count))
    $report.Add(('TXT byte count: {0}' -f (Get-Item -LiteralPath $payloadPath).Length))
    $report.Add('Attachment downloads: none')
    $report.Add('Formatting: original body markup retained; paragraphs, line breaks, emphasis, colors and tables')
    $result = 'PASSED'
    Write-Host ('결과 TXT: {0}' -f $payloadPath)
    Write-Host ('서식 미리보기: {0}' -f $previewPath)
    try { $null = Start-Process -FilePath $previewPath -PassThru }
    catch { $report.Add('Preview auto-open failed; open the generated HTML file manually.') }
}
catch {
    $report.Add(('Failure stage: {0}' -f $stage))
    $report.Add(('Error type: {0}' -f $_.Exception.GetType().Name))
    if ($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$') { $report.Add(('Error code: {0}' -f $_.Exception.Message)) }
    $LoginCredential = $null
    $errorCode = 'MAIL_COLLECTION_FAILED'
    if ($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$') { $errorCode = $_.Exception.Message }
    $publicMessage = Get-MailFailureMessage $errorCode
    $report.Add(('Error message: {0}' -f $publicMessage))
    if ($null -ne $script:MailLoginErrorSource) { $report.Add(('Login error source: {0}' -f $script:MailLoginErrorSource)) }
    Write-Host ('오류: {0} ({1})' -f $publicMessage, $errorCode)
    try {
        $failurePath = Write-MailFailureResult $OutputDirectory $requestId $errorCode $stage
        $report.Add('Structured failure TXT written: yes')
        Write-Host ('실패 결과 TXT: {0}' -f $failurePath)
    }
    catch { $report.Add('Structured failure TXT written: no') }
    Write-Host ('수집이 중단됐습니다. 단계: {0}' -f $stage)
    if ($_.Exception.Message -eq 'AUTOMATION_EDGE_NOT_OPEN') { Write-Host '앞서 DOM 확인에 사용한 자동화용 Edge 창을 열어두세요.' }
}
Close-MailCdpSessions
$cleanup=Close-MailAutomationBrowser $profile
$report.Add(('Automation mail browser cleanup: {0}' -f $cleanup))
if($cleanup -eq 'CLOSED'){Write-Host '메일 수집용 Edge 창을 닫았습니다.'}
elseif($cleanup -notin @('NOT_RUNNING','NOT_OWNED')){Write-Host ('메일 창 종료를 확인하지 못했습니다: '+$cleanup)}
$timer.Stop()
$report.Add(('Elapsed seconds: {0:F2}' -f $timer.Elapsed.TotalSeconds))
$report.Add(('Result: {0}' -f $result))
$reportPath = Join-Path $OutputDirectory ('MailAutomation-Biometric3-v8-{0}-{1}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 6))
[IO.File]::WriteAllLines($reportPath, $report.ToArray(), (New-Object Text.UTF8Encoding($true)))
Write-Host ('진단 보고서: {0}' -f $reportPath)
if ($result -ne 'PASSED') { exit 1 }
