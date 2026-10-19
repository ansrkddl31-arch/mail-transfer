using System;
using System.Collections.Generic;
namespace EXMailImageProbe {
 public class Candidate {
  public string Kind; public int X,Y,Width,Height; public double Score;
 }
 // Read-only shape/color matching for the supplied i-oneNet screenshots.
 // RGB packed bytes, independent of Windows capture so detection can be tested separately.
 public static class Detector {
  static bool Gray(byte[] p,int w,int x,int y) {
   int i=(y*w+x)*3,r=p[i],g=p[i+1],b=p[i+2];
   return Math.Max(r,Math.Max(g,b))-Math.Min(r,Math.Min(g,b))<18 && r>=95 && r<=205;
  }
  static bool Light(byte[] p,int w,int x,int y) {
   int i=(y*w+x)*3;return p[i]>=225&&p[i+1]>=225&&p[i+2]>=225;
  }
  static bool Green(byte[] p,int w,int x,int y) {
   int i=(y*w+x)*3,r=p[i],g=p[i+1],b=p[i+2];
   return r>=45&&r<=145&&g>=145&&g<=220&&b>=120&&b<=200&&g-r>=35&&b-r>=20;
  }
  public static Candidate[] Find(byte[] p,int w,int h) {
   if(w<100||h<150||p==null||p.Length!=(long)w*h*3)throw new ArgumentException("INVALID_IMAGE");
   var found=new List<Candidate>();
   for(int radius=6;radius<=Math.Min(22,w/20);radius++) {
    for(int y=h/5+radius;y<h*3/4-radius;y++)for(int x=w/5+radius;x<w*4/5-radius;x++) {
     if(!Gray(p,w,x,y))continue;
     int ring=0,cross=0,light=0;
     // Search a narrow ring band to tolerate antialiasing and pixel rounding.
     for(int a=0;a<24;a++){
      double angle=a*Math.PI/12;bool hit=false;
      for(int dr=-1;dr<=1;dr++){
       int xx=x+(int)Math.Round(Math.Cos(angle)*(radius+dr));
       int yy=y+(int)Math.Round(Math.Sin(angle)*(radius+dr));
       if(Gray(p,w,xx,yy))hit=true;
      }
      if(hit)ring++;
     }
     int arm=Math.Max(2,(int)Math.Round(radius*.45));
     if(Gray(p,w,x-arm,y))cross++;if(Gray(p,w,x+arm,y))cross++;
     if(Gray(p,w,x,y-arm))cross++;if(Gray(p,w,x,y+arm))cross++;
     int d=Math.Max(2,(int)Math.Round(radius*.45));
     if(Light(p,w,x-d,y-d))light++;if(Light(p,w,x+d,y-d))light++;
     if(Light(p,w,x-d,y+d))light++;if(Light(p,w,x+d,y+d))light++;
     if(ring<21||cross!=4||light!=4)continue;
     double score=(ring/24.0)*.7+.3;
     var c=new Candidate{Kind="PLUS",X=x-radius-1,Y=y-radius-1,Width=radius*2+3,Height=radius*2+3,Score=score};
     bool duplicate=false;
     for(int j=0;j<found.Count;j++)if(found[j].Kind=="PLUS"&&Math.Abs(found[j].X+found[j].Width/2-x)<radius&&Math.Abs(found[j].Y+found[j].Height/2-y)<radius){if(found[j].Score<score)found[j]=c;duplicate=true;break;}
     if(!duplicate)found.Add(c);
    }
   }
   // Connected green regions. Rectangular lower buttons only; reject arrow circles/header.
   var seen=new bool[w*h];var queue=new Queue<int>();
   for(int y=h*7/10;y<h;y++)for(int x=0;x<w;x++) {
    int index=y*w+x;if(seen[index]||!Green(p,w,x,y))continue;
    seen[index]=true;queue.Enqueue(index);int minX=x,maxX=x,minY=y,maxY=y,count=0;
    while(queue.Count>0){int v=queue.Dequeue(),xx=v%w,yy=v/w;count++;minX=Math.Min(minX,xx);maxX=Math.Max(maxX,xx);minY=Math.Min(minY,yy);maxY=Math.Max(maxY,yy);
     int[] ns={v-1,v+1,v-w,v+w};
     for(int n=0;n<4;n++){int q=ns[n];if(q<0||q>=w*h||Math.Abs(q%w-xx)+Math.Abs(q/w-yy)!=1||seen[q])continue;if(Green(p,w,q%w,q/w)){seen[q]=true;queue.Enqueue(q);}}
    }
    int bw=maxX-minX+1,bh=maxY-minY+1;double fill=count/(double)(bw*bh),aspect=bw/(double)bh;
    if(bw<w*.15||bw>w*.48||bh<Math.Max(16,h*.025)||bh>h*.13||aspect<1.7||aspect>5||fill<.8)continue;
    found.Add(new Candidate{Kind="SEND",X=minX,Y=minY,Width=bw,Height=bh,Score=fill});
   }
   return found.ToArray();
  }
 }
}
