$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../program'
. (Join-Path $root 'Image.Flow.ps1')
function Assert($Value,[string]$Message){if(-not$Value){throw $Message}}
$button=@{X=100;Y=300;Width=20;Height=20}
foreach($scenario in @('success','ambiguousPlus','nonEmpty','wrongFile','missingSend','ambiguousSend','completionUnknown','f4BeforePlus','f4BeforeSend','sendAdapterFails')){
 $script:clicks=New-Object 'System.Collections.Generic.List[string]';$script:registered=0;$script:stages=New-Object 'System.Collections.Generic.List[string]';$caught=''
 $snapshot={
  if($scenario-eq'ambiguousPlus'){return @{plus=@($button,$button);send=@()}}
  if($scenario-eq'nonEmpty'){return @{plus=@($button);send=@($button)}}
  return @{plus=@($button);send=@()}
 }
 $click={param($kind,$candidate) $script:clicks.Add($kind);if($scenario-eq'sendAdapterFails'-and$kind-eq'SEND'){throw 'INJECTED_SEND_FAILURE'}}
 $register={$script:registered++}
 $ready={return @{registered=($scenario-ne'wrongFile');plus=@();send=$(if($scenario-eq'missingSend'){@()}elseif($scenario-eq'ambiguousSend'){@($button,$button)}else{@($button)})}}
 $empty={return $scenario-ne'completionUnknown'}
 $stage={param($name) $script:stages.Add($name);if(($scenario-eq'f4BeforePlus'-and$name-eq'CLICK_PLUS')-or($scenario-eq'f4BeforeSend'-and$name-eq'CLICK_SEND_ONCE')){throw 'USER_ABORTED_F4'}}
 try{$result=Invoke-ImageSendTrial -Snapshot $snapshot -Click $click -Register $register -WaitReady $ready -WaitEmpty $empty -Stage $stage}catch{$caught=$_.Exception.Message}
 $sendCount=@($script:clicks|Where-Object{$_-eq'SEND'}).Count
 Assert ($sendCount-le1) "Repeated SEND: $scenario"
 if($scenario-eq'success'){
  Assert (-not$caught-and$result-eq'SEND_LIST_EMPTY_RECEIPT_NOT_VERIFIED'-and$sendCount-eq1-and$script:registered-eq1) 'SUCCESS_FLOW_FAILED'
 }else{
  Assert ([bool]$caught) "Failure did not stop: $scenario"
  if($scenario-notin@('completionUnknown','sendAdapterFails')){Assert ($sendCount-eq0) "Unsafe SEND: $scenario"}
  if($scenario-in@('ambiguousPlus','nonEmpty','f4BeforePlus')){Assert ($script:clicks.Count-eq0-and$script:registered-eq0) "Clicked before initial checks: $scenario"}
 }
 Write-Host ('PASS flow scenario '+$scenario+'; SEND attempts='+$sendCount)
}
foreach($name in @('Transfer.Image.ps1','Image.Flow.ps1','Transfer.Helpers.ps1')){
 $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
 Assert ($errors.Count-eq0) ($name+': '+($errors|Out-String))
}
Add-Type -Path (Join-Path $root 'Image.Native.cs')
'PASS all sender/helper scripts parse and native declarations compile. Windows interaction is NOT executed.'
Assert (Test-EmptyEditorEvidence @('총 0개 파일, 0 Bytes')) 'KOREAN_EMPTY_COUNTER_REJECTED'
Assert (Test-EmptyEditorEvidence @('총 0 개 파일, 0 바이트')) 'SPACED_EMPTY_COUNTER_REJECTED'
foreach($text in @('총 1개 파일, 0 Bytes','총 10개 파일, 0 Bytes','총 0개 파일, 157 Bytes','총 0개 파일, 0 Bytes.txt','0개 파일')){
 Assert (-not(Test-EmptyEditorEvidence @($text))) ('FALSE_EMPTY_COUNTER: '+$text)
}
foreach($scenario in @('emptyEditorReset','noZeroEvidence','resetFails','resetStillEditor','readyStillZero')){
 $script:reads=0;$script:resetCount=0;$script:clicks=New-Object 'System.Collections.Generic.List[string]';$caught=''
 $snapshot={
  $script:reads++
  if($script:reads-eq1-or$scenario-eq'resetStillEditor'){return @{plus=@();send=@($button);emptyEditor=($scenario-ne'noZeroEvidence')}}
  return @{plus=@($button);send=@();emptyEditor=$false}
 }
 $reset={$script:resetCount++;if($scenario-eq'resetFails'){throw 'CANCEL_NOT_FOUND'}}
 try{
  [void](Invoke-ImageSendTrial -Snapshot $snapshot -Click {param($kind,$candidate) $script:clicks.Add($kind)} -Register {} -WaitReady {return @{registered=$true;plus=@();send=@($button);emptyEditor=($scenario-eq'readyStillZero')}} -WaitEmpty {$true} -Stage {} -ResetEmptyEditor $reset)
 }catch{$caught=$_.Exception.Message}
 if($scenario-in@('emptyEditorReset','noZeroEvidence')){
  Assert (-not$caught-and$script:resetCount-eq1-and$script:clicks.Count-eq2) 'EMPTY_EDITOR_RESET_FAILED'
 }else{
  Assert ([bool]$caught) ('UNEXPECTED_SUCCESS: '+$scenario)
  Assert (@($script:clicks|Where-Object{$_-eq'SEND'}).Count-eq0) ('UNSAFE_SEND: '+$scenario)
 }
 Write-Host ('PASS empty-editor scenario '+$scenario)
}
$id='a'*32;$name='MailTransfer-Request-'+$id+'.txt';$full='C:\outbox\'+$name
foreach($text in @($name,('MailTransfer-Request-'+$id),$full,('"'+$full+'"'))){Assert (Test-ImageRegisteredName $text $name $full) ('VALID_ID_REJECTED: '+$text)}
foreach($text in @(('MailTransfer-Request-'+('b'*32)+'.txt'),($name+'.bad'),('MailTransfer-Request-'+$id.Substring(0,15)+'...'),'total 1 files')){Assert (-not(Test-ImageRegisteredName $text $name $full)) ('FALSE_ID_ACCEPTED: '+$text)}
'PASS registered unique ID: basename, hidden extension and full path accepted; other IDs and truncated names rejected'
foreach($case in @('stable','delayed','moving','neverFound','wrongName','cancelled')){
 $script:observations=0;$script:checks=0;$script:nameOk=$case-ne'wrongName';$caught=''
 $read={
  $script:observations++
  $target=@{X=$(if($case-eq'moving'-and$script:observations-eq1){50}else{100});Y=300;Width=114;Height=40}
  $send=if($case-eq'neverFound'-or($case-eq'delayed'-and$script:observations-eq1)){@()}else{@($target)}
  return @{plus=@();send=$send;emptyEditor=$false;originX=0;originY=0}
 }
 try{$frame=Wait-ImageActionFrame -Kind SEND -ReadSnapshot $read -NameMatches {$script:nameOk} -CheckContinue {$script:checks++;if($case-eq'cancelled'){throw 'USER_ABORTED'}} -Observe {} -Pause {} -MaxObservations 4}catch{$caught=$_.Exception.Message}
 if($case-in@('stable','delayed','moving')){Assert (-not$caught-and$script:observations-ge2-and$frame.target.X-eq100) ('PREFLIGHT_FAILED: '+$case)}
 else{Assert ([bool]$caught) ('PREFLIGHT_UNSAFE_SUCCESS: '+$case)}
 Write-Host ('PASS pre-click stable-frame check '+$case)
}
