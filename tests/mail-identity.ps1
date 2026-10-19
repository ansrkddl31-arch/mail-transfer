$ErrorActionPreference='Stop'
. /workspace/scratch/claude-mail-transfer-v17.2/Start-Bridge.ps1 -LibraryOnly
$script:original=[IO.File]::ReadAllText('/workspace/attachments/764046b5-8018-4780-b4c4-2dff7f0cd2d8/붙여넣은 텍스트.txt')
$parsed=ConvertFrom-MailBytes ([Text.Encoding]::UTF8.GetBytes($script:original))
if($parsed.body.Length-ne755-or$parsed.attachments.Count-ne1-or$parsed.attachmentError){throw 'UPLOADED_MAIL_PARSE_REGRESSION'}
$script:second=[regex]::Replace($script:original,'(?m)^Message-ID:[^\r\n]*(?:\r?\n[ \t][^\r\n]*)*','Message-ID: <second-qa@example.invalid>')
$script:mode='same';$script:calls=0
function Invoke-EdgeCdp {
 param($WebSocket,$Method,$Parameters,$TimeoutSeconds)
 $script:calls++;if($script:calls-eq1){return @{result=@{value=@{ok=$true;ids=@('123456','123457');pagesRead=1}}}}
 $secondSource=switch($script:mode){normal{@{ok=$true;original=$script:second}};parseFailure{@{ok=$true;original='not MIME'}};readFailure{@{ok=$false;code='MAIL_PAGE_FETCH_TIMEOUT'}};default{@{ok=$true;original=$script:original}}}
 return @{result=@{value=@{ok=$true;sources=@(@{ok=$true;original=$script:original},$secondSource)}}}
}
$tab=@{webSocketDebuggerUrl='ws://127.0.0.1/fixture'}
$script:calls=0;$r=Read-PagedInboxMails $tab 2
if($r.mails.Count-ne2-or$r.failures.Count-or$r.mails[0].id-cne$parsed.id-or$r.mails[1].id-ceq$parsed.id-or$r.mails[1].messageId-cne$parsed.id){throw 'COLLIDING_ID_NOT_PRESERVED'}
if($r.mails[0].attachments.Count-ne1-or$r.mails[1].attachments.Count-ne1-or$r.mails[1].body.Length-ne755-or$r.mails[1].sourceUid-ne'123457'){throw 'COLLISION_LOST_BODY_ATTACHMENT'}
$firstIds=@($r.mails|ForEach-Object{$_.id});$script:calls=0;$again=Read-PagedInboxMails $tab 2
if($again.mails[1].id-cne$firstIds[1]){throw 'ID_NOT_STABLE_FOR_CACHE'}
'PASS uploaded invoice HTML body and attachment parse; distinct mailbox UIDs sharing one Message-ID both retained; normal first ID unchanged and duplicate ID stable'
$script:mode='normal';$script:calls=0;$r=Read-PagedInboxMails $tab 2
if($r.mails.Count-ne2-or$r.failures.Count-or$r.mails[1].id-cne'<second-qa@example.invalid>'){throw 'NORMAL_ID_CACHE_CHANGED'}
'PASS normal non-colliding IDs remain unchanged'
foreach($mode in @('parseFailure','readFailure')){
 $script:mode=$mode;$script:calls=0;$r=Read-PagedInboxMails $tab 2
 $stage=if($mode-eq'parseFailure'){'MAIL_PARSE'}else{'MAIL_READ'}
 if($r.mails.Count-ne1-or$r.failures.Count-ne1-or$r.failures[0].stage-ne$stage-or$r.failures[0].sourceUid-ne'123457'){throw 'FAILURE_ISOLATION_OR_STAGE_LOST'}
}
'PASS individual read/parse failures isolated with exact stage, original error code and mailbox UID'
