param([string]$ImagePath='')
$ErrorActionPreference='Stop'
$bitmap=$null;$graphics=$null;$lock=$null
try {
 if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){throw 'WINDOWS_REQUIRED'}
 Add-Type -AssemblyName System.Drawing
 Add-Type -AssemblyName System.Windows.Forms
 Add-Type -Path (Join-Path $PSScriptRoot 'Detector.cs')
 Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;using System.Collections.Generic;
namespace EXMailImageProbe {
 public class Window {public IntPtr Handle;public string Title;}
 public static class CaptureNative {
  public delegate bool EnumProc(IntPtr h,IntPtr p);
  [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
  [StructLayout(LayoutKind.Sequential)]public struct Point{public int X,Y;}
  [DllImport("user32.dll")]static extern bool EnumWindows(EnumProc cb,IntPtr p);
  [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")]public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
  [DllImport("user32.dll")]public static extern bool GetClientRect(IntPtr h,out Rect r);
  [DllImport("user32.dll")]public static extern bool ClientToScreen(IntPtr h,ref Point p);
  [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]public static extern bool SetProcessDPIAware();
  public static Window[] Find(){var result=new List<Window>();EnumWindows((h,p)=>{var title=new StringBuilder(512);GetWindowText(h,title,512);if(IsWindowVisible(h)&&title.ToString().Contains("자료교환"))result.Add(new Window{Handle=h,Title=title.ToString()});return true;},IntPtr.Zero);return result.ToArray();}
 }
}
'@
 $logRoot=Join-Path $PSScriptRoot 'logs';[void][IO.Directory]::CreateDirectory($logRoot)
 $run=Join-Path $logRoot ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6));[void][IO.Directory]::CreateDirectory($run)
 $title='image-file'
 if($ImagePath){
  $inputImage=[Drawing.Image]::FromFile([IO.Path]::GetFullPath($ImagePath))
  try{$bitmap=New-Object Drawing.Bitmap($inputImage.Width,$inputImage.Height,[Drawing.Imaging.PixelFormat]::Format24bppRgb);$graphics=[Drawing.Graphics]::FromImage($bitmap);$graphics.DrawImageUnscaled($inputImage,0,0);$graphics.Dispose();$graphics=$null}finally{$inputImage.Dispose()}
 }else{
  [void][EXMailImageProbe.CaptureNative]::SetProcessDPIAware()
  Write-Host '자료교환 보내기 화면을 클릭하세요. 8초 후 해당 창만 캡처합니다.'
  Write-Host '아무 버튼도 누르지 않으며 파일을 보내지 않습니다.'
  for($i=8;$i-ge1;$i--){Write-Host ($i.ToString()+'...');Start-Sleep -Seconds 1}
  $front=[EXMailImageProbe.CaptureNative]::GetForegroundWindow();$windows=@([EXMailImageProbe.CaptureNative]::Find()|Where-Object{$_.Handle-eq$front})
  if($windows.Count-ne1){throw '자료교환 창이 맨 앞에 없습니다. 해당 창을 클릭한 뒤 다시 실행하세요.'}
  $window=$windows[0];if([EXMailImageProbe.CaptureNative]::IsIconic($window.Handle)){throw '자료교환 창이 최소화되어 있습니다.'}
  $rect=New-Object EXMailImageProbe.CaptureNative+Rect;$point=New-Object EXMailImageProbe.CaptureNative+Point
  if(-not[EXMailImageProbe.CaptureNative]::GetClientRect($window.Handle,[ref]$rect)-or-not[EXMailImageProbe.CaptureNative]::ClientToScreen($window.Handle,[ref]$point)){throw '창 영역을 확인하지 못했습니다.'}
  $w=$rect.Right-$rect.Left;$h=$rect.Bottom-$rect.Top
  if($w-lt150-or$h-lt200-or$w-gt2000-or$h-gt2500){throw '자료교환 창 크기가 진단 범위를 벗어났습니다.'}
  $area=New-Object Drawing.Rectangle($point.X,$point.Y,$w,$h)
  if(-not[Windows.Forms.SystemInformation]::VirtualScreen.Contains($area)){throw '자료교환 창 전체가 화면 안에 들어오도록 옮겨주세요.'}
  $bitmap=New-Object Drawing.Bitmap($w,$h,[Drawing.Imaging.PixelFormat]::Format24bppRgb);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  $graphics.CopyFromScreen($point.X,$point.Y,0,0,$bitmap.Size);$graphics.Dispose();$graphics=$null;$title='자료교환 창'
 }
 $bitmap.Save((Join-Path $run 'capture.png'),[Drawing.Imaging.ImageFormat]::Png)
 $bounds=New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)
 $lock=$bitmap.LockBits($bounds,[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
 $pixels=New-Object byte[] ($bitmap.Width*$bitmap.Height*3);$row=New-Object byte[] ($bitmap.Width*3)
 for($y=0;$y-lt$bitmap.Height;$y++){
  [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($lock.Scan0,$y*$lock.Stride),$row,0,$row.Length)
  for($x=0;$x-lt$bitmap.Width;$x++){$j=($y*$bitmap.Width+$x)*3;$pixels[$j]=$row[$x*3+2];$pixels[$j+1]=$row[$x*3+1];$pixels[$j+2]=$row[$x*3]}
 }
 $bitmap.UnlockBits($lock);$lock=$null
 $candidates=@([EXMailImageProbe.Detector]::Find($pixels,$bitmap.Width,$bitmap.Height))
 $graphics=[Drawing.Graphics]::FromImage($bitmap);$pen=New-Object Drawing.Pen([Drawing.Color]::Red,3);$font=New-Object Drawing.Font('Arial',11)
 try{foreach($c in $candidates){$graphics.DrawRectangle($pen,$c.X,$c.Y,$c.Width,$c.Height);$graphics.DrawString(($c.Kind+' candidate'),$font,[Drawing.Brushes]::Red,$c.X,[Math]::Max(0,$c.Y-19))}}finally{$pen.Dispose();$font.Dispose();$graphics.Dispose();$graphics=$null}
 $bitmap.Save((Join-Path $run 'candidates.png'),[Drawing.Imaging.ImageFormat]::Png)
 $result=@{mode='READ_ONLY_NO_CLICK';algorithm='shape-and-color-prototype';capturedAt=(Get-Date).ToString('o');width=$bitmap.Width;height=$bitmap.Height;plusCount=@($candidates|Where-Object{$_.Kind-eq'PLUS'}).Count;sendCount=@($candidates|Where-Object{$_.Kind-eq'SEND'}).Count;candidates=$candidates;note='후보 표시만 수행합니다. 점수는 정확도 확률이 아닙니다. 사람이 표시 위치를 확인해야 합니다.'}
 [IO.File]::WriteAllText((Join-Path $run 'result.json'),($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
 Write-Host ('완료: PLUS 후보 '+$result.plusCount+' / SEND 후보 '+$result.sendCount)
 Write-Host ('결과 폴더: '+$run)
 Start-Process explorer.exe -ArgumentList ('"'+$run+'"')
}catch{
 Write-Host ('진단 실패: '+$_.Exception.Message) -ForegroundColor Red
 try{if(-not$run){$run=Join-Path $PSScriptRoot 'logs';[void][IO.Directory]::CreateDirectory($run)};[IO.File]::WriteAllText((Join-Path $run 'error.txt'),($_.Exception.Message),(New-Object Text.UTF8Encoding($true)))}catch{}
 exit 1
}finally{if($lock-and$bitmap){$bitmap.UnlockBits($lock)};if($graphics){$graphics.Dispose()};if($bitmap){$bitmap.Dispose()}}
