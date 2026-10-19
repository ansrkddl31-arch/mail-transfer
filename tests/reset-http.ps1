param([int]$QaPort,[string]$QaRoot)
$ErrorActionPreference='Stop'
. /workspace/scratch/claude-mail-transfer-v17.2/Start-Bridge.ps1 -LibraryOnly
$state=New-InternalBridgeState;$state.attachmentDataDirectory=$QaRoot;$state.inbox=$QaRoot
$app=@{role='Internal';internal=$state;stateDir=$QaRoot;stateRoot=$QaRoot;setupActive=$false}
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$QaPort)
try{$listener.Start();[Console]::WriteLine('READY');[Console]::Out.Flush()
 foreach($i in 1..7){Handle-BridgeRequest ($listener.AcceptTcpClient()) $app 'page' 'qa-token' $QaPort}
 if($state.sendQueue.Count-ne1){throw 'HTTP_DUPLICATE_QUEUED_SEND'}
 $app.role='External';$app.external=New-ExternalBridgeState
 Handle-BridgeRequest ($listener.AcceptTcpClient()) $app 'page' 'qa-token' $QaPort
 $app.role='Internal';$app.setupActive=$true
 Handle-BridgeRequest ($listener.AcceptTcpClient()) $app 'page' 'qa-token' $QaPort
 'PASS actual HTTP reset token/role/format/setup guards, single explicit connection, duplicate operation idempotence'
}finally{$listener.Stop()}
