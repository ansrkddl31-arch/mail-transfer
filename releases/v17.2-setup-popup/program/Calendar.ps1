# Local schedules only. Gemini candidates are proposals and require explicit user confirmation.
function Test-CalendarDate {
 param([string]$Date)
 $d=[DateTime]::MinValue
 return [DateTime]::TryParseExact($Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$d)
}
function Get-BridgeCalendar {
 param([string]$Directory)
 $p=Join-Path $Directory 'calendar.json'
 if(-not(Test-Path -LiteralPath $p)){return @{items=@();error=''}}
 try{
  $data=Read-BridgeJson $p -MaximumBytes 4194304
  if($data.version-ne1-or@($data.items).Count-gt5000){throw 'CALENDAR_DATA_INVALID'}
  foreach($item in @($data.items)){
   if(-not(Test-BridgeId ([string]$item.id))-or-not(Test-CalendarDate ([string]$item.date))-or$item.title-isnot[string]-or$item.title.Length-gt200-or$item.done-isnot[bool]){throw 'CALENDAR_DATA_INVALID'}
  }
  return @{items=@($data.items);error=''}
 }catch{return @{items=@();error='CALENDAR_UNREADABLE'}}
}
function Save-BridgeCalendarAction {
 param([string]$Directory,$State,$Data)
 $calendar=Get-BridgeCalendar $Directory
 if($calendar.error){throw $calendar.error} # Never replace unreadable user data with an empty calendar.
 $items=New-Object 'Collections.Generic.List[object]';foreach($item in @($calendar.items)){$items.Add($item)}
 switch([string]$Data.action){
  'add'{
   $title=([string]$Data.title).Trim();$date=[string]$Data.date;$time=[string]$Data.time;$source=[string]$Data.sourceKey
   if(-not$title-or$title.Length-gt200-or-not(Test-CalendarDate $date)-or($time-and$time-cnotmatch'^(?:[01]\d|2[0-3]):[0-5]\d$')){throw 'CALENDAR_INPUT_INVALID'}
   if($source){
    if($source-cnotmatch'^[a-f0-9]{64}$'){throw 'CALENDAR_SOURCE_INVALID'}
    if(@($items|Where-Object{$_.sourceKey-ceq$source}).Count){return}
    $candidates=@(foreach($mail in @($State.mails)){if($mail.ai.status-eq'success'){foreach($c in @($mail.ai.candidates)){if($c.id-ceq$source){$c}}}})
    if($candidates.Count-ne1){throw 'CALENDAR_SOURCE_INVALID'}
   }
   if($items.Count-ge5000){throw 'CALENDAR_LIMIT'}
   $items.Add(@{id=[guid]::NewGuid().ToString('N');title=$title;date=$date;time=$time;done=$false;sourceKey=$source;createdAt=[DateTime]::UtcNow.ToString('o')})
  }
  'update'{
   if(-not(Test-BridgeId ([string]$Data.id))){throw 'CALENDAR_INPUT_INVALID'}
   $match=@($items|Where-Object{$_.id-ceq$Data.id});if($match.Count-ne1){throw 'CALENDAR_ITEM_NOT_FOUND'}
   $title=([string]$Data.title).Trim();$date=[string]$Data.date;$time=[string]$Data.time
   if(-not$title-or$title.Length-gt200-or-not(Test-CalendarDate $date)-or($time-and$time-cnotmatch'^(?:[01]\d|2[0-3]):[0-5]\d$')){throw 'CALENDAR_INPUT_INVALID'}
   $match[0].title=$title;$match[0].date=$date;$match[0].time=$time
  }
  'complete'{
   if(-not(Test-BridgeId ([string]$Data.id))-or$Data.done-isnot[bool]){throw 'CALENDAR_INPUT_INVALID'}
   $match=@($items|Where-Object{$_.id-ceq$Data.id});if($match.Count-ne1){throw 'CALENDAR_ITEM_NOT_FOUND'}
   $match[0].done=[bool]$Data.done
  }
  'delete'{
   if(-not(Test-BridgeId ([string]$Data.id))){throw 'CALENDAR_INPUT_INVALID'}
   $match=@($items|Where-Object{$_.id-ceq$Data.id});if($match.Count-ne1){throw 'CALENDAR_ITEM_NOT_FOUND'}
   [void]$items.Remove($match[0])
  }
  default{throw 'CALENDAR_ACTION_INVALID'}
 }
 Write-BridgeJson (Join-Path $Directory 'calendar.json') @{version=1;items=@($items.ToArray());updatedAt=[DateTime]::UtcNow.ToString('o')}
}
