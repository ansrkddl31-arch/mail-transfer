param([string]$SocketUrl,[string]$Expected)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../program/Collector.ps1') -LibraryOnly
try{
 $value=Invoke-EdgeCdp $SocketUrl 'Runtime.evaluate' @{expression='1';returnByValue=$true} -TimeoutSeconds 5
 if($Expected-ne'OK'-or$value.result.value-ne1){throw 'UNEXPECTED_CDP_SUCCESS'}
 Write-Host 'PASS OK'
}catch{
 if($_.Exception.Message-ne$Expected){throw}
 Write-Host ('PASS '+$Expected)
}finally{Close-MailCdpSessions}
