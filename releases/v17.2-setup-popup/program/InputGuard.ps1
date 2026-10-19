#requires -Version 5.1
# No hooks are installed when this library is loaded.
function Initialize-MailInputGuard {
 if('MailTransfer.InputGuard'-as[type]){return}
 Add-Type -Path (Join-Path $PSScriptRoot 'InputGuard.cs')
}
function Start-MailInputGuard {
 param([string]$Id,[switch]$Locked,[string]$Phase='요청 준비',[int]$ControllerPid=0,[long]$ControllerStart=0)
 if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){throw 'WINDOWS_REQUIRED'}
 if($Id-cnotmatch'^[a-f0-9]{32}$'){throw 'INPUT_GUARD_NAME_INVALID'}
 Initialize-MailInputGuard
 try{[MailTransfer.InputGuard]::Start(('Local\MailTransferCancel-'+$Id),[bool]$Locked,$Phase);if($ControllerPid-gt0){[MailTransfer.InputGuard]::WatchController($ControllerPid,$ControllerStart)}}catch{$code=$_.Exception.GetBaseException().Message;if($code-cmatch'^[A-Z][A-Z0-9_]+$'){throw $code};throw 'INPUT_GUARD_START_FAILED'}
}
function Assert-MailOperationContinue {
 if(('MailTransfer.InputGuard'-as[type])-and[MailTransfer.InputGuard]::Cancelled){throw 'USER_ABORTED'}
}
function Set-MailOperationPhase {
 param([string]$Phase,[switch]$Locked)
 Assert-MailOperationContinue
 if(('MailTransfer.InputGuard'-as[type])-and[MailTransfer.InputGuard]::Active){[MailTransfer.InputGuard]::SetLocked([bool]$Locked,$Phase)}
}
function Stop-MailInputGuard {
 if('MailTransfer.InputGuard'-as[type]){[MailTransfer.InputGuard]::Stop()}
}
function Get-MailInputGuardContext {
 if(('MailTransfer.InputGuard'-as[type])-and[MailTransfer.InputGuard]::Active){return @{name=[MailTransfer.InputGuard]::Name;ownerPid=[MailTransfer.InputGuard]::OwnerPid;ownerStart=[MailTransfer.InputGuard]::OwnerStart}}
 return $null
}

function Set-TransferCursorPosition {
 param([int]$X,[int]$Y)
 Assert-MailOperationContinue
 if($null-ne(Get-MailInputGuardContext)){return [MailTransfer.InputGuard]::MoveCursor($X,$Y)}
 return [MailBridge.Native]::SetCursorPos($X,$Y)
}
