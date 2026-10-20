function Test-EmptyEditorEvidence {
 param([string[]]$Texts)
 foreach($text in $Texts){if($text-match'^\s*총\s*0\s*개\s*파일\s*[,，]?\s*0\s*(Bytes?|B|바이트)\s*$'){return $true}}
 return $false
}
function Invoke-ImageSendTrial {
 param([scriptblock]$Snapshot,[scriptblock]$Click,[scriptblock]$Register,[scriptblock]$WaitReady,[scriptblock]$WaitEmpty,[scriptblock]$Stage,[scriptblock]$ResetEmptyEditor=$null)
 & $Stage 'CHECK_EMPTY'
 $initial=& $Snapshot
 if(@($initial.plus).Count-eq0-and@($initial.send).Count-eq1){
  if($ResetEmptyEditor){
   & $Stage 'RESET_EXISTING_REGISTRATION'
   & $ResetEmptyEditor
   $initial=& $Snapshot
  }else{throw 'SEND_EDITOR_VIEW_USE_CANCEL_AND_RETRY'}
 }
 if(@($initial.plus).Count-ne1-or@($initial.send).Count-ne0){throw 'EMPTY_SEND_LIST_NOT_CONFIRMED'}
 & $Stage 'CLICK_PLUS'
 & $Click 'PLUS' $initial.plus[0]
 & $Stage 'REGISTER_TEST_FILE'
 & $Register
 & $Stage 'CHECK_REGISTERED_FILE'
 $ready=& $WaitReady
 if(-not$ready.registered-or$ready.emptyEditor-or@($ready.send).Count-ne1-or@($ready.plus).Count-ne0){throw 'TEST_FILE_REGISTRATION_NOT_CONFIRMED'}
 & $Stage 'CLICK_SEND_ONCE'
 # No retries surround this call, including if the completion check fails.
 & $Click 'SEND' $ready.send[0]
 & $Stage 'WAIT_SEND_LIST_EMPTY'
 if(-not(& $WaitEmpty)){throw 'SEND_OUTCOME_UNCONFIRMED_DO_NOT_RESEND'}
 & $Stage 'SEND_LIST_EMPTY_RECEIPT_NOT_VERIFIED'
 return 'SEND_LIST_EMPTY_RECEIPT_NOT_VERIFIED'
}
function Test-ImageRegisteredName {
 param([string]$Text,[string]$FileName,[string]$FullPath)
 $value=$Text.Trim().Trim('"')
 if($FileName-cnotmatch'^MailTransfer-(?:(?:Probe|Request|Result)-[a-f0-9]{32}\.txt|Attachment-[a-f0-9]{32}(?:\.[^\\/:*?"<>|\x00-\x1f]{1,20})?)$'){return $false}
 return $value-ceq$FileName-or$value-ceq[IO.Path]::GetFileNameWithoutExtension($FileName)-or$value-ceq$FullPath
}
