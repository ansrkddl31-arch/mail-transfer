$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'program/Start-Bridge.ps1') -LibraryOnly
# Compile the actual lazy Windows tab-check declaration without calling its native methods.
$maintenanceSource=[IO.File]::ReadAllText((Join-Path $repo 'program/Maintenance.ps1'))
$native=[regex]::Match($maintenanceSource,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
Add-Type -TypeDefinition $native
function Assert($Value,[string]$Message){if(-not$Value){throw $Message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('exmail-maintenance-'+[guid]::NewGuid().ToString('N'))
$inbox=Join-Path $root 'inbox';$stateDir=Join-Path $root 'Internal';$other=Join-Path $root 'other'
foreach($folder in @($inbox,$stateDir,$other)){[void][IO.Directory]::CreateDirectory($folder)}
$now=[DateTime]::UtcNow
function OldFile([string]$Path,[byte[]]$Bytes){[IO.File]::WriteAllBytes($Path,$Bytes);[IO.File]::SetLastWriteTimeUtc($Path,$now.AddMinutes(-5))}
try{
 $received=New-TransferProbe $inbox ('a'*32);[IO.File]::SetLastWriteTimeUtc($received.path,$now.AddMinutes(-5))
 $source=New-TransferProbe $stateDir ('b'*32);[IO.File]::SetLastWriteTimeUtc($source.path,$now.AddMinutes(-5))
 $locked=New-TransferProbe $stateDir ('c'*32);[IO.File]::SetLastWriteTimeUtc($locked.path,$now.AddMinutes(-5))
 $fake=Join-Path $inbox ('MailTransfer-Probe-'+('d'*32)+'.txt');OldFile $fake ([Text.Encoding]::UTF8.GetBytes('user data, not generated probe'))
 $attachment=Join-Path $inbox ('MailTransfer-Attachment-'+('e'*32)+'.txt');OldFile $attachment (Get-TransferProbeBytes ('e'*32))
 $original=Join-Path $inbox 'report.xlsx';OldFile $original ([byte[]]@(1,2,3,4))
 $trial=Join-Path $inbox ('EXMail-ImageTrial-'+('f'*32)+' (1).txt')
 $text="EXMAIL_IMAGE_SEND_TRIAL_V1`r`nID: EXMail-ImageTrial-$('f'*32).txt`r`nImage recognition transfer test only. No credentials or mail data."
 OldFile $trial ([Text.Encoding]::UTF8.GetBytes($text))
 $internal=New-InternalBridgeState;$internal.inbox=$inbox
 $app=@{role='Internal';internal=$internal;external=$null;stateDir=$stateDir;setupJob=$null}
 $script:windows=@(@{handle=1;path=$inbox},@{handle=2;path=$other});$script:closed=New-Object 'Collections.Generic.List[long]'
 $read={$script:windows};$close={param($handle,$path) $script:closed.Add($handle);return $true}
 Invoke-BridgeArtifactMaintenance $app $now $read $close
 Assert ($script:closed.Count-eq0-and(Test-Path $received.path)) 'BASELINE_WINDOW_OR_PROBE_REMOVED'
 $request=Join-Path $inbox ('MailTransfer-Request-'+('1'*32)+'.txt');[IO.File]::WriteAllText($request,'owned receipt event')
 $script:windows+=@(@{handle=3;path=$inbox},@{handle=4;path=$other})
 Invoke-BridgeArtifactMaintenance $app ($now.AddSeconds(2)) $read $close
 Assert ($script:closed.Count-eq1-and$script:closed[0]-eq3) 'DID_NOT_LIMIT_CLOSE_TO_NEW_RECEIVE_FOLDER'
 $script:windows+=,@{handle=5;path=$inbox}
 Invoke-BridgeArtifactMaintenance $app ($now.AddSeconds(25)) $read $close
 Assert (-not$script:closed.Contains(5)) 'IDLE_MANUAL_WINDOW_CLOSED'
 $second=Join-Path $inbox ('MailTransfer-Attachment-'+('2'*32)+'.pdf');[IO.File]::WriteAllBytes($second,[byte[]]@(4,5))
 Invoke-BridgeArtifactMaintenance $app ($now.AddSeconds(26)) $read $close
 Assert ($script:closed.Contains(5)-and(Test-Path $second)) 'ATTACHMENT_ARRIVAL_WINDOW_NOT_HANDLED_OR_FILE_DELETED'
 $script:windows+=@(@{handle=6;path=$inbox},@{handle=6;path=$other})
 Invoke-BridgeArtifactMaintenance $app ($now.AddSeconds(27)) $read $close
 Assert (-not$script:closed.Contains(6)) 'MULTITAB_WINDOW_CLOSED'
 $internal.busy=$true
 Invoke-BridgeArtifactMaintenance $app ($now.AddSeconds(65)) $read $close
 Assert (Test-Path $received.path) 'PROBE_REMOVED_DURING_ACTIVE_OPERATION'
 $internal.busy=$false
 $stream=[IO.File]::Open($locked.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
 try{Invoke-BridgeArtifactMaintenance $app ($now.AddSeconds(80)) $read $close;Assert (Test-Path $locked.path) 'LOCKED_PROBE_DELETED'}finally{$stream.Dispose()}
 Assert (-not(Test-Path $received.path)-and-not(Test-Path $source.path)-and-not(Test-Path $trial)) 'OLD_PROBES_NOT_REMOVED'
 Assert ((Test-Path $fake)-and(Test-Path $attachment)-and(Test-Path $original)-and(Test-Path $second)-and(Test-Path $request)) 'NON_PROBE_FILE_REMOVED'
 Invoke-BridgeArtifactMaintenance $app ($now.AddSeconds(95)) $read $close
 Assert (-not(Test-Path $locked.path)) 'UNLOCKED_PROBE_NOT_RETRIED'
 Assert (Test-Path (Join-Path $stateDir 'last-probe-receipt.json')) 'RECEIPT_NOT_RECORDED'
 $diagnostic=Get-MailTransferDiagnostics (Join-Path $repo 'program') 8765 $root -StateSnapshot @{role='Internal'}
 Assert ($diagnostic.Contains('probe.receivedId=')) 'PROBE_RECEIPT_NOT_IN_DIAGNOSTIC'
 # Test the actual attachment receiver too: both received bytes and original-name app copy must remain.
 $id='3'*32;$attachmentId='4'*32;$name='report-original.xlsx';$bytes=[byte[]]@(1,3,5,7)
 $transport=Get-AttachmentTransportName $id $name;$path=Join-Path $inbox $transport
 [IO.File]::WriteAllBytes($path,$bytes)
 $internal.attachments[$attachmentId]=@{requestId=$id;attachmentId=$attachmentId;status='receiving';started=$now.ToString('o');file=@{name=$name;transportName=$transport;hash=(Get-TransferBytesHash $bytes);size=$bytes.Length};path=''}
 Update-InternalAttachments $internal $inbox $stateDir
 $job=$internal.attachments[$attachmentId]
 Assert ($job.status-eq'ready'-and(Test-Path $path)-and(Test-Path $job.path)) 'ATTACHMENT_COPY_REMOVED'
 Assert ((Get-TransferBytesHash (Get-InternalAttachmentBytes $internal $id $stateDir))-ceq(Get-TransferBytesHash $bytes)) 'ATTACHMENT_DOWNLOAD_CHANGED'
 $worker=[IO.File]::ReadAllText((Join-Path $repo 'program/External-Worker.ps1'))
 Assert (-not$worker.Contains('[IO.File]::Delete($attachmentPath)')) 'EXTERNAL_ATTACHMENT_DELETE_REMAINS'
 'PASS old generated probe/source/duplicate cleanup, one-minute grace, busy/locked deferral, receipt record, attachment preservation'
 'PASS newly opened receive-folder window close policy, old/other/idle/multitab windows preserved (Shell COM calls mocked)'
}finally{Remove-Item $root -Recurse -Force}
