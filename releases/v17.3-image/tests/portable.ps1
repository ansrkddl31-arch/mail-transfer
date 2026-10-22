$ErrorActionPreference='Stop'
$release=Split-Path -Parent $PSScriptRoot
. (Join-Path $release 'portable/Portable.ps1') -LibraryOnly
function Assert($value,$message){if(-not$value){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('EX메일 포터블 시험 '+[guid]::NewGuid().ToString('N'))
$program=Join-Path $root 'program';[void][IO.Directory]::CreateDirectory($program)
$envBefore=[Environment]::GetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT')
try{
 $paths=Get-EXMailPortablePaths $root
 Assert ($paths.data-eq(Join-Path $root 'data')) 'data scoped to portable root'
 Assert ($paths.configuration-eq(Join-Path $paths.data 'bridge-settings.json')) 'settings must be portable'
 $fixture=@'
param($Port,$ConfigurationFile,$StateRoot)
if($Port-ne8765-or$ConfigurationFile-ne(Join-Path $StateRoot 'bridge-settings.json')){throw 'wrong bridge args'}
if($env:EXMAIL_PORTABLE_STATE_ROOT-ne$StateRoot){throw 'worker environment not propagated'}
[IO.File]::WriteAllText((Join-Path $StateRoot 'args.json'),(@{root=$StateRoot;configuration=$ConfigurationFile}|ConvertTo-Json))
'@
 foreach($name in @('Common.ps1','app.html','Maintenance.ps1','Transfer.Image.ps1')){[IO.File]::WriteAllText((Join-Path $program $name),'fixture')}
 [IO.File]::WriteAllText((Join-Path $program 'Start-Bridge.ps1'),$fixture)
 function Test-EXMailPortablePort{return $false}
 Invoke-EXMailPortable $root
 Assert ([IO.File]::Exists((Join-Path $paths.data 'args.json'))) 'bridge ran with portable paths'
 Assert (-not[IO.File]::Exists($paths.owner)) 'owner cleaned after normal shutdown'
 Assert ([Environment]::GetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT')-eq$envBefore) 'environment restored'
 # A live port from another installation must never be opened/reused silently.
 function Test-EXMailPortablePort{return $true}
 $blocked=$false;try{Invoke-EXMailPortable $root}catch{$blocked=$_.Exception.Message-like'*8765*'}
 Assert $blocked 'occupied port not rejected'
 function Test-EXMailPortablePort{return $false}
 [IO.File]::WriteAllText((Join-Path $program 'Start-Bridge.ps1'),"throw 'fixture failure'")
 $failed=$false;try{Invoke-EXMailPortable $root}catch{$failed=$_.Exception.Message-like'*fixture failure*'}
 Assert ($failed-and-not[IO.File]::Exists($paths.owner)) 'failed bridge cleanup'
 Assert ([Environment]::GetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT')-eq$envBefore) 'environment restored on failure'
 # Verify real common-library transfer-path selection without altering installed default.
 . (Join-Path $release 'program/Common.ps1')
 $default=Get-BridgeTransferConfiguration 'Internal'
 [Environment]::SetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT',$paths.data,'Process')
 Assert ((Get-BridgeTransferConfiguration 'External')-eq(Join-Path (Join-Path (Join-Path $paths.data 'Transfer') 'External') 'sender-settings.json')) 'transfer launch settings leak outside portable folder'
 [Environment]::SetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT',$envBefore,'Process')
 Assert ((Get-BridgeTransferConfiguration 'Internal')-eq$default) 'installed path changed'
 Write-Host 'PASS portable paths, worker environment, bridge arguments, occupied port rejection, success/failure cleanup and installed path preserved'
}finally{[Environment]::SetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT',$envBefore,'Process');Remove-Item -LiteralPath $root -Recurse -Force}
