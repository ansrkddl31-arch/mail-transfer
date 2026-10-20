$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot '../program/Image.Detector.cs')
Add-Type -TypeDefinition @'
using System;
public static class ProbeFixtures {
 static void Pixel(byte[] p,int w,int x,int y,byte r,byte g,byte b){int i=(y*w+x)*3;p[i]=r;p[i+1]=g;p[i+2]=b;}
 public static byte[] Create(int w,int h,int radius,bool plus,bool rectangle,bool decoys){
  byte[] p=new byte[w*h*3];for(int i=0;i<p.Length;i++)p[i]=255;
  int cx=w/2,cy=h*45/100;
  if(plus)for(int y=cy-radius-2;y<=cy+radius+2;y++)for(int x=cx-radius-2;x<=cx+radius+2;x++){
   double distance=Math.Sqrt((x-cx)*(x-cx)+(y-cy)*(y-cy));
   if(Math.Abs(distance-radius)<=.9 || (Math.Abs(x-cx)<=1&&Math.Abs(y-cy)<=radius*.6)||(Math.Abs(y-cy)<=1&&Math.Abs(x-cx)<=radius*.6))Pixel(p,w,x,y,157,157,157);
  }
  if(rectangle)for(int y=h*90/100;y<h*96/100;y++)for(int x=w*51/100;x<w*78/100;x++)Pixel(p,w,x,y,90,192,165);
  if(decoys){
   // Header, circular green download icon, solid gray square, gray empty ring.
   for(int y=0;y<h/12;y++)for(int x=0;x<w;x++)Pixel(p,w,x,y,90,192,165);
   for(int y=h*75/100;y<h*85/100;y++)for(int x=w*85/100;x<w*95/100;x++)if(Math.Pow(x-w*.9,2)+Math.Pow(y-h*.8,2)<Math.Pow(w*.035,2))Pixel(p,w,x,y,90,192,165);
   for(int y=h/3;y<h/3+20;y++)for(int x=w/3;x<w/3+20;x++)Pixel(p,w,x,y,157,157,157);
   for(int y=h/2-12;y<=h/2+12;y++)for(int x=w/3-12;x<=w/3+12;x++)if(Math.Abs(Math.Sqrt(Math.Pow(x-w/3,2)+Math.Pow(y-h/2,2))-9)<1)Pixel(p,w,x,y,157,157,157);
  }
  return p;
 }
}
'@
foreach($scale in @(1,1.25,1.5)){
 $w=[int](420*$scale);$h=[int](640*$scale);$radius=[int](9*$scale)
 $pixels=[ProbeFixtures]::Create($w,$h,$radius,$true,$true,$true)
 $found=@([EXMailImageProbe.Detector]::Find($pixels,$w,$h))
 $plus=@($found|Where-Object{$_.Kind-eq'PLUS'});$send=@($found|Where-Object{$_.Kind-eq'SEND'})
 if($plus.Count-ne1-or$send.Count-ne1){throw "Expected exactly one PLUS and SEND at scale $scale; got $($plus.Count), $($send.Count)"}
 if([Math]::Abs(($plus[0].X+$plus[0].Width/2)-$w/2)-gt3){throw 'PLUS center mismatch'}
 Write-Host "PASS actual detector: PLUS and SEND with decoys at scale $scale"
}
$empty=[ProbeFixtures]::Create(420,640,9,$false,$false,$false)
if(@([EXMailImageProbe.Detector]::Find($empty,420,640)).Count-ne0){throw 'Blank image false positive'}
$decoys=[ProbeFixtures]::Create(420,640,9,$false,$false,$true)
if(@([EXMailImageProbe.Detector]::Find($decoys,420,640)).Count-ne0){throw 'Decoy-only image false positive'}
$errors=$null;$tokens=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../program/Transfer.Image.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
Write-Host 'PASS blank/decoy rejection and capture script parser. Native Windows screen capture not executed.'
