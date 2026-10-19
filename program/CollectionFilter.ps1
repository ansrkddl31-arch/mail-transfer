# Date-range collection is separate from display pagination and maximum collection count.
function Get-DefaultMailCollectionFilter {return @{mode='recent';from='';to=''}}
function ConvertTo-MailCollectionFilter {
 param($Data)
 if($null-eq$Data){return (Get-DefaultMailCollectionFilter)}
 if($Data.mode-eq'recent'){return (Get-DefaultMailCollectionFilter)}
 if($Data.mode-ne'range'-or-not(Test-CalendarDate ([string]$Data.from))-or-not(Test-CalendarDate ([string]$Data.to))-or([string]$Data.from)-cgt([string]$Data.to)){throw 'MAIL_DATE_RANGE_INVALID'}
 return @{mode='range';from=[string]$Data.from;to=[string]$Data.to}
}
function Get-MailCollectionFilter {
 param([string]$Directory)
 $p=Join-Path $Directory 'collection-filter.json'
 if(-not(Test-Path -LiteralPath $p)){return (Get-DefaultMailCollectionFilter)}
 try{return (ConvertTo-MailCollectionFilter (Read-BridgeJson $p -MaximumBytes 4096))}catch{$value=Get-DefaultMailCollectionFilter;$value.error='MAIL_DATE_SETTINGS_UNREADABLE';return $value}
}
function Save-MailCollectionFilter {
 param([string]$Directory,$State,$Data)
 $value=ConvertTo-MailCollectionFilter $Data
 Write-BridgeJson (Join-Path $Directory 'collection-filter.json') $value
 $State.collectionFilter=$value
}
