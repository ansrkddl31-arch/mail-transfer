# Non-secret role/path backup beside the self-contained Startup BAT. Never stores credentials or mail.
function Get-EXMailRecoveryPaths {
 param([string]$Startup='')
 if(-not$Startup){$Startup=[Environment]::GetFolderPath('Startup')}
 if(-not$Startup){return $null}
 $Startup=[IO.Path]::GetFullPath($Startup).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 return @{folder=$Startup;batch=(Join-Path $Startup 'EXMail-Recover.bat');settings=(Join-Path (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Startup))) 'EXMailRecovery') 'settings.json')}
}
function Save-EXMailRecoveryConfiguration {
 param([string]$ConfigurationFile,[string]$Startup='')
 try{
  $paths=Get-EXMailRecoveryPaths $Startup
  if(-not$paths-or-not(Test-Path -LiteralPath $paths.batch -PathType Leaf)){return $false}
  $config=[IO.File]::ReadAllText($ConfigurationFile)|ConvertFrom-Json
  if($config.role-notin@('Internal','External')-or$config.folderConfirmed-ne$true-or-not[IO.Path]::IsPathRooted([string]$config.inbox)){return $false}
  $safe=@{role=[string]$config.role;inbox=[string]$config.inbox;folderConfirmed=$true;port=8765}
  if($config.count-ge1-and$config.count-le1000){$safe.count=[int]$config.count}
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($paths.settings))
  $temp=$paths.settings+'.tmp';[IO.File]::WriteAllText($temp,($safe|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($true)))
  if(Test-Path -LiteralPath $paths.settings){[IO.File]::Replace($temp,$paths.settings,[NullString]::Value)}else{[IO.File]::Move($temp,$paths.settings)}
  return $true
 }catch{return $false}
}
function Restore-EXMailRecoveryConfiguration {
 param([string]$Destination,[string]$Startup='')
 $target=Join-Path $Destination 'bridge-settings.json'
 if(Test-Path -LiteralPath $target){return $false}
 $paths=Get-EXMailRecoveryPaths $Startup
 if(-not$paths-or-not(Test-Path -LiteralPath $paths.settings -PathType Leaf)){return $false}
 $info=Get-Item -LiteralPath $paths.settings
 if($info.Length-gt16384-or($info.Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'RECOVERY_SETTINGS_INVALID'}
 $cfg=[IO.File]::ReadAllText($paths.settings)|ConvertFrom-Json
 if($cfg.role-notin@('Internal','External')-or$cfg.folderConfirmed-ne$true-or-not[IO.Path]::IsPathRooted([string]$cfg.inbox)){throw 'RECOVERY_SETTINGS_INVALID'}
 $safe=@{role=[string]$cfg.role;inbox=[string]$cfg.inbox;folderConfirmed=$true;port=8765}
 if($cfg.count-ge1-and$cfg.count-le1000){$safe.count=[int]$cfg.count}
 [IO.File]::WriteAllText($target,($safe|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($true)))
 return $true
}
