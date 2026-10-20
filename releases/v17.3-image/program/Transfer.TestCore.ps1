#requires -Version 5.1
$ErrorActionPreference='Stop'
function Write-TransferJson {
 param([string]$Path,$Value)
 $folder=Split-Path -Parent $Path;[void][IO.Directory]::CreateDirectory($folder)
 $temp=Join-Path $folder ('.writing-'+[Guid]::NewGuid().ToString('N'))
 try{
  [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 20 -Compress),(New-Object Text.UTF8Encoding($true)))
  if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
 }finally{if(Test-Path -LiteralPath $temp){[IO.File]::Delete($temp)}}
}
function Read-TransferJson {
 param([string]$Path)
 $info=Get-Item -LiteralPath $Path
 if($info.Length -lt 2 -or $info.Length -gt 16384){throw 'SETTINGS_SIZE_INVALID'}
 return ([IO.File]::ReadAllText($Path)|ConvertFrom-Json)
}
function Get-TransferProbeBytes {
 param([string]$Id)
 if($Id -cnotmatch '^[a-f0-9]{32}$'){throw 'PROBE_ID_INVALID'}
 $text="MAIL_TRANSFER_PROBE_V1`r`nID: $Id`r`n자료교환 자동 전송 테스트`r`n첫 번째 줄`r`n두 번째 줄`r`nNo email data or credentials.`r`n"
 return ,([Text.Encoding]::UTF8.GetBytes($text))
}
function Get-TransferBytesHash {
 param([byte[]]$Bytes)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')}finally{$sha.Dispose()}
}
function New-TransferProbe {
 param([string]$Folder,[string]$Id='')
 [void][IO.Directory]::CreateDirectory($Folder)
 if([string]::IsNullOrEmpty($Id)){$Id=[Guid]::NewGuid().ToString('N')}
 if($Id -cnotmatch '^[a-f0-9]{32}$'){throw 'PROBE_ID_INVALID'}
 $id=$Id;$path=Join-Path $Folder ('MailTransfer-Probe-'+$id+'.txt')
 $bytes=Get-TransferProbeBytes $id;[IO.File]::WriteAllBytes($path,$bytes)
 return [pscustomobject]@{id=$id;path=$path;name=[IO.Path]::GetFileName($path);hash=(Get-TransferBytesHash $bytes);bytes=$bytes.Length}
}
function Test-TransferProbe {
 param([string]$Path)
 $name=[IO.Path]::GetFileName($Path)
 if($name -cnotmatch '^MailTransfer-Probe-([a-f0-9]{32})\.txt$'){throw 'PROBE_FILENAME_INVALID'}
 $id=$Matches[1];$info=Get-Item -LiteralPath $Path
 if($info.Length -gt 4096 -or $info.Length -lt 1){throw 'PROBE_SIZE_INVALID'}
 $actual=[IO.File]::ReadAllBytes($Path);$expected=Get-TransferProbeBytes $id
 $hash=Get-TransferBytesHash $actual
 return [pscustomobject]@{id=$id;name=$name;valid=($hash -ceq (Get-TransferBytesHash $expected));hash=$hash;bytes=$actual.Length}
}
function Test-TransferSettings {
 param($Settings)
 if($Settings.schemaVersion -ne 1 -or $Settings.kind -ne 'screen-transfer-test' -or $Settings.calibrated -ne $true){throw 'TRANSFER_CALIBRATION_REQUIRED'}
 foreach($point in @($Settings.plus,$Settings.send)){
  foreach($key in @('x','y','width','height')){if($null -eq $point.$key){throw 'TRANSFER_SETTINGS_INVALID'}}
  foreach($key in @('x','y','width','height')){if([double]::IsNaN([double]$point.$key) -or [double]::IsInfinity([double]$point.$key)){throw 'TRANSFER_SETTINGS_INVALID'}}
  if([double]$point.x -le 0 -or [double]$point.x -ge 1 -or [double]$point.y -le 0 -or [double]$point.y -ge 1 -or [double]$point.width -lt 200 -or [double]$point.height -lt 250){throw 'TRANSFER_SETTINGS_INVALID'}
 }
 foreach($hash in @($Settings.emptyHash,$Settings.sendButtonHash)){if([string]$hash -cnotmatch '^[A-F0-9]{64}$'){throw 'TRANSFER_SETTINGS_INVALID'}}
}
