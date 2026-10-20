$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot;$program=Join-Path $repo 'program'
function Assert($Value,[string]$Message){if(-not$Value){throw $Message}}
foreach($file in @(Get-ChildItem $program -Filter '*.ps1')){
 $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
 Assert ($errors.Count-eq0) ($file.Name+': '+($errors|Out-String))
}
 . (Join-Path $program 'Start-Bridge.ps1') -LibraryOnly
Assert (Test-BridgeTransferReady '/nonexistent/sender-settings.json') 'CALIBRATION_STILL_REQUIRED'
Add-Type -Path (Join-Path $program 'Image.Native.cs')
Add-Type -Path (Join-Path $program 'InputGuard.cs')
$policy=New-Object MailTransfer.InputPolicy
$policy.SetLocked($true,'test')
Assert ($policy.Mouse($false)) 'PHYSICAL_MOUSE_NOT_BLOCKED'
Assert (-not$policy.Mouse($true)) 'INJECTED_CURSOR_BLOCKED'
Assert (-not$policy.MouseButton(1,$true,$true,$false)) 'INJECTED_IMAGE_CLICK_BLOCKED'
Assert (-not$policy.Key(13,$true,$true,$false)) 'INJECTED_PICKER_ENTER_BLOCKED'
$policy.Cancel('USER_ABORTED');Assert (-not$policy.Locked-and$policy.Cancelled) 'F4_CANCEL_POLICY'
'PASS no saved coordinates required; all PS scripts parse; native classes compile; input policy permits injected click/Enter while blocking physical input'

$root=Join-Path ([IO.Path]::GetTempPath()) ('exmail-image-app-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$script:initializations=0
function Initialize-ImageTransfer {$script:initializations++}
function Ensure-TransferWindow {param($Configuration) return [pscustomobject]@{Current=[pscustomobject]@{NativeWindowHandle=[IntPtr]42;ProcessId=1}}}
function Focus-TransferWindow {param($Window)}
function Set-MailOperationPhase {param($Phase,[switch]$Locked)}
function Invoke-ImageSendTrial {
 param($Snapshot,$Click,$Register,$WaitReady,$WaitEmpty,$Stage,$ResetEmptyEditor)
 if($script:scenario-eq'beforeClickFailure'){throw 'CLICK_TARGET_NOT_UNIQUE'}
 $script:sendAttempted=$true;$script:sendClicks=1;$script:trialStage='WAIT_SEND_LIST_EMPTY'
 if($script:scenario-eq'afterClickFailure'){throw 'SEND_OUTCOME_UNCONFIRMED_DO_NOT_RESEND'}
 if($script:scenario-eq'cancelled'){throw 'USER_ABORTED_F4'}
 return 'SEND_LIST_EMPTY_RECEIPT_NOT_VERIFIED'
}
try{
 # The actual role setup starts ready without a sender-settings.json and without any send.
 foreach($role in @('Internal','External')){
  $roleRoot=Join-Path $root $role;[void][IO.Directory]::CreateDirectory($roleRoot)
  $app=@{role='';stateRoot=$roleRoot;stateDir=$roleRoot;configurationFile=(Join-Path $roleRoot 'bridge-settings.json');internal=$null;external=$null}
  Set-BridgeRole $app $role $roleRoot
  $active=if($role-eq'Internal'){$app.internal}else{$app.external}
  Assert ($active.transferReady-and$active.configured) ('ROLE_BLOCKED_ON_OLD_COORDINATES_'+$role)
 }
 'PASS real internal/external role initialization ready without saved coordinates or automatic test send'
 foreach($kind in @('Request','Result','Probe','Attachment')){
  $id=[guid]::NewGuid().ToString('N');$name='MailTransfer-'+$kind+'-'+$id+$(if($kind-eq'Attachment'){'.xlsx'}else{'.txt'})
  $path=Join-Path $root $name;[IO.File]::WriteAllText($path,'test payload')
  $script:scenario='success';$outcome=Send-ImageTransferFile $path (Join-Path $root 'nonexistent-settings.json')
  Assert ($outcome.result-eq'SUBMITTED_UI_CONFIRMED'-and$outcome.clicked-and$outcome.name-ceq$name) ('SEND_ADAPTER_FAILED_'+$kind)
 }
 $path=Join-Path $root ('MailTransfer-Request-'+('a'*32)+'.txt');[IO.File]::WriteAllText($path,'test')
 foreach($mode in @('beforeClickFailure','afterClickFailure','cancelled')){
  $script:scenario=$mode;$outcome=Send-ImageTransferFile $path (Join-Path $root 'missing-settings.json')
  if($mode-eq'beforeClickFailure'){Assert ($outcome.result-eq'FAILED'-and-not$outcome.clicked) 'PRE_CLICK_FAILURE_MISREPORTED'}
  else{Assert ($outcome.result-eq'SUBMITTED_UI_UNCONFIRMED'-and$outcome.clicked) 'POST_CLICK_FAILURE_RETRY_RISK'}
  if($mode-eq'cancelled'){Assert ($outcome.error-eq'USER_ABORTED') 'F4_ERROR_NOT_MAPPED'}
 }
 $outcome=Send-ImageTransferFile $path (Join-Path $root 'missing-settings.json') -MaxBytes 1
 Assert ($outcome.result-eq'FAILED'-and-not$outcome.clicked-and$outcome.error-eq'TRANSFER_FILE_SIZE_INVALID') 'SIZE_LIMIT_FAILED'
 $bad=Join-Path $root 'arbitrary.txt';[IO.File]::WriteAllText($bad,'test')
 $outcome=Send-ImageTransferFile $bad (Join-Path $root 'missing-settings.json')
 Assert ($outcome.result-eq'FAILED'-and-not$outcome.clicked-and$outcome.error-eq'TRANSFER_FILENAME_INVALID') 'ARBITRARY_FILENAME_ACCEPTED'
 'PASS real app sender adapter: request/result/probe/attachment, no settings file, before/after click failure, F4, file validation; only Windows interactions mocked'
 $send=[IO.File]::ReadAllText((Join-Path $program 'Send-Packet.ps1'));$setup=[IO.File]::ReadAllText((Join-Path $program 'Setup-Transfer.ps1'))
 Assert ($send.Contains('Send-ImageTransferFile')-and$setup.Contains('Send-ImageTransferFile')) 'NOT_ALL_SEND_PATHS_CONNECTED'
 Assert (-not$send.Contains('Test-Send.ps1')-and-not$setup.Contains('Invoke-TransferCalibration')) 'LEGACY_CALIBRATION_ACTIVE'
 Assert (-not([IO.File]::ReadAllText((Join-Path $program 'Transfer.Image.ps1'))-match'System.Windows.Automation|AutomationElement')) 'UIA_IN_NEW_SENDER'
 'PASS operational send and optional setup test both use image path; no UIA in new sender'
}finally{Remove-Item $root -Recurse -Force}
