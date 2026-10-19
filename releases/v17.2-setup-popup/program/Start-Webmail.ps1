#requires -Version 5.1
param([string]$Profile,[string]$StatusFile,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
$startupProfile=$Profile;$startupStatus=$StatusFile;$startupLibrary=[bool]$LibraryOnly
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Collector.ps1') -LibraryOnly
function Open-OwnedWebmailWindow {
 param([string]$startupProfile,[string]$startupStatus)
try{
 Write-BridgeJson $startupStatus @{status='opening';code=''}
 Start-MailAutomationEdge $startupProfile
 $pages=@(Get-EdgeProfilePages $startupProfile | Where-Object {$_.type -eq 'page'})
 $mail=@($pages | Where-Object {$uri=$null;[Uri]::TryCreate($_.url,[UriKind]::Absolute,[ref]$uri) -and $uri.Host -eq 'mail.ex.co.kr'})
 if($mail.Count -eq 1){[void](Invoke-EdgeCdp $mail[0].webSocketDebuggerUrl 'Page.bringToFront' @{} -TimeoutSeconds 5)}
 elseif($mail.Count -eq 0 -and $pages.Count -eq 1){
  [void](Invoke-EdgeCdp $pages[0].webSocketDebuggerUrl 'Page.navigate' @{url='https://mail.ex.co.kr/login'} -TimeoutSeconds 5)
  [void](Invoke-EdgeCdp $pages[0].webSocketDebuggerUrl 'Page.bringToFront' @{} -TimeoutSeconds 5)
 }elseif($mail.Count -gt 1){throw 'EXACTLY_ONE_WEBMAIL_TAB_REQUIRED'}else{throw 'WEBMAIL_STARTUP_TAB_NOT_FOUND'}
 Write-BridgeJson $startupStatus @{status='ready';code=''}
}catch{
 $code='WEBMAIL_STARTUP_FAILED';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
 Write-BridgeJson $startupStatus @{status='failed';code=$code}
}finally{Close-MailCdpSessions}

}
if($startupLibrary){return}
Open-OwnedWebmailWindow $startupProfile $startupStatus
