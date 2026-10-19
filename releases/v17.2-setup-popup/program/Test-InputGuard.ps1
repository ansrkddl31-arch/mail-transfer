#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'InputGuard.ps1')
Write-Host '입력 보호 확인: 파일 전송과 메일 수집은 하지 않습니다.'
Write-Host '시작되면 키보드·마우스 입력이 제한됩니다. F4를 누르면 해제합니다.'
Write-Host '누르지 않아도 10초 뒤 별도 감시 타이머가 자동으로 해제합니다.'
[void](Read-Host '준비됐으면 Enter')
try{
 Start-MailInputGuard ([Guid]::NewGuid().ToString('N')) -Phase '10초 입력 보호 확인'
 [MailTransfer.InputGuard]::SetTestDeadline(10)
 Set-MailOperationPhase '10초 입력 보호 확인' -Locked
 while(-not[MailTransfer.InputGuard]::Cancelled){Start-Sleep -Milliseconds 100}
 Write-Host ('입력 제한을 해제했습니다. 결과: '+[MailTransfer.InputGuard]::Reason)
}catch{Write-Host ('검사를 시작하지 못했습니다: '+$_.Exception.GetBaseException().Message)}
finally{Stop-MailInputGuard}
Write-Host 'F4로 해제되지 않았다면 운영 자동화를 시작하지 말고 이 결과를 알려주세요.'
