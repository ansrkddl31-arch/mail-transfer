$ErrorActionPreference='Stop'
$root='/workspace/scratch/claude-mail-transfer-v17.2'
foreach($file in Get-ChildItem $root -Filter *.ps1){$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e);if($e.Count){$e|Out-String|Write-Host;throw ('PARSE_'+$file.Name)}}
Add-Type -Path (Join-Path $root 'InputGuard.cs')
. (Join-Path $root 'Start-Bridge.ps1') -LibraryOnly
'PASS PowerShell parse, C# compile, complete libraries load'
