$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../tools/transfer-image-probe'
. (Join-Path $root 'Trial.Flow.ps1')
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
foreach($name in @('Test-ImageSend.ps1','Trial.Flow.ps1','Transfer.Helpers.ps1')){
 $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
 Assert ($errors.Count-eq0) ($name+': '+($errors|Out-String))
}
Add-Type -Path (Join-Path $root 'Trial.Native.cs')
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
 if($scenario-eq'emptyEditorReset'){
  Assert (-not$caught-and$script:resetCount-eq1-and$script:clicks.Count-eq2) 'EMPTY_EDITOR_RESET_FAILED'
 }else{
  Assert ([bool]$caught) ('UNEXPECTED_SUCCESS: '+$scenario)
  Assert (@($script:clicks|Where-Object{$_-eq'SEND'}).Count-eq0) ('UNSAFE_SEND: '+$scenario)
  if($scenario-eq'noZeroEvidence'){Assert ($script:resetCount-eq0) 'RESET_WITHOUT_ZERO_EVIDENCE'}
 }
 Write-Host ('PASS empty-editor scenario '+$scenario)
}
