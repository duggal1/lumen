#!/usr/bin/env python3
"""Build Lumen's README diagrams. Python 3.10+, standard library only."""
from pathlib import Path
from html import escape
from math import sin, cos
import argparse
import xml.etree.ElementTree as ET

BG='#090909'; PANEL='#121212'; INK='#F5F5F5'; MUTED='#A3A3A3'; QUIET='#777777'; BLUE='#1688FF'; LIGHT='#A7DFFF'; DUST='#262626'
BAYER=(0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5)
FONT='-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif'
MONO='ui-monospace, SFMono-Regular, Consolas, monospace'

class SVG:
    def __init__(self, w, h, title, desc):
        self.w=w; self.h=h; self.parts=[f'<title>{escape(title)}</title><desc>{escape(desc)}</desc>']
        self.rect(0,0,w,h,BG,12)
    def add(self, s): self.parts.append(s)
    def rect(self,x,y,w,h,fill,r=0):
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}"'+(f' rx="{r}"' if r else '')+'/>')
    def text(self,x,y,s,size=16,fill=INK,weight=400,mono=False,anchor='start'):
        self.add(f'<text x="{x}" y="{y}" fill="{fill}" font-family="{MONO if mono else FONT}" font-size="{size}" font-weight="{weight}" text-anchor="{anchor}">{escape(s)}</text>')
    def path(self,d,fill=BLUE,stroke=None,width=1):
        self.add(f'<path d="{d}" fill="{fill}"'+(f' stroke="{stroke}" stroke-width="{width}" stroke-linejoin="round"' if stroke else '')+'/>')
    def line(self,x1,y1,x2,y2,color=DUST,width=1): self.path(f'M{x1} {y1}L{x2} {y2}','none',color,width)
    def cells(self, cells, pitch=4, size=3):
        # One compound path per color, rather than thousands of rect nodes.
        groups={}
        for x,y,color in cells:
            groups.setdefault(color,[]).append(f'M{x} {y}h{size}v{size}h-{size}z')
        for color,paths in groups.items(): self.path(''.join(paths),color)
    def dither(self,x,y,cols,rows,density=1,pitch=4):
        cells=[]
        for j in range(rows):
            for i in range(cols):
                q=BAYER[(j%4)*4+i%4]
                if q < density*16: cells.append((x+i*pitch,y+j*pitch,LIGHT if q<4 else BLUE))
        self.cells(cells,pitch,pitch-1)
    def header(self,kicker,title,subtitle):
        self.dither(32,32,5,5,.8)
        self.text(60,44,kicker,13,LIGHT,500,True)
        self.text(32,88,title,30,INK,500)
        self.text(32,114,subtitle,15,MUTED)
    def node(self,x,y,w,h,label,details,tag=None):
        self.rect(x,y,w,h,PANEL,8)
        self.dither(x+14,y+15,3,3,.85,4)
        self.text(x+34,y+26,label,19,INK,500)
        for i,s in enumerate(details): self.text(x+14,y+51+i*19,s,13,MUTED)
        if tag: self.text(x+w-14,y+h-12,tag,11,LIGHT,400,True,'end')
    def arrow(self,points,color=BLUE):
        d='M'+'L'.join(f'{x} {y}' for x,y in points)
        self.path(d,'none',color,1.5)
        (a,b),(x,y)=points[-2:]; dx=x-a;dy=y-b
        if abs(dx)>=abs(dy): self.path(f'M{x} {y}l{-6 if dx>0 else 6} -4v8z',color)
        else: self.path(f'M{x} {y}l-4 {-6 if dy>0 else 6}h8z',color)
    def save(self,path):
        xml=f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" role="img">'+''.join(self.parts)+'</svg>\n'
        ET.fromstring(xml); path.write_text(xml,encoding='utf-8')

def architecture():
    s=SVG(960,744,'Lumen architecture','Logical runtime data flow. Capture writes a project bundle; analysis and director derive editable tracks. Preview and export share the renderer and audio mix. Native UI and agent control edit the same project.')
    s.header('01 / System','One recording. One source of truth.','Logical runtime flow, not a Swift package dependency graph.')
    # Source row and project hub
    s.node(32,142,270,102,'Capture',['ScreenCaptureKit · AVFoundation','Screen, webcam, audio, input'],'LumenCapture')
    s.node(345,142,270,102,'.lumen bundle',['Original media · event logs','Recovery journal · editable state'],'LumenProject')
    s.node(658,142,270,102,'Analysis',['Activity · OCR · typing','Speech · face / person mask'],'LumenAnalysis')
    s.arrow([(302,193),(345,193)]); s.arrow([(615,193),(658,193)])
    # Director and project session
    s.node(32,304,270,104,'Project session',['Frame readers · cached analysis','TimeMap · revisioned edits'],'LumenExport')
    s.node(345,304,270,104,'Director / Planner',['Intent / shots / camera path','Crop · zoom · pacing · cursor'],'LumenDirector')
    s.node(658,304,270,104,'Audio + speech',['Voice processing · music / SFX','Mix · waveform · transcript'],'LumenAudio / Speech')
    s.arrow([(480,244),(480,274),(167,274),(167,304)])
    s.arrow([(793,244),(793,274),(480,274),(480,304)])
    s.arrow([(302,356),(345,356)])
    s.arrow([(615,224),(638,224),(638,292),(793,292),(793,304)],LIGHT)
    # Render
    s.node(345,470,270,98,'Shared composition',['Metal renderer · camera / layers','FrameState + timeline time'],'LumenRender')
    s.arrow([(480,408),(480,470)]);s.arrow([(167,408),(167,519),(345,519)])
    # Audio separate to outputs via bus
    s.line(793,408,793,600,LIGHT,1.5);s.line(793,600,167,600,LIGHT,1.5)
    s.node(32,622,270,90,'Native preview',['SwiftUI / AppKit · playback','Latest-frame presentation'],'LumenUI')
    s.node(345,622,270,90,'Offline export',['GPU / encoder pipeline','Video + mixed audio'],'LumenExport')
    s.node(658,622,270,90,'Agent / CLI',['MCP · policy · approvals','Shared project commands'],'LumenControl')
    s.arrow([(480,568),(480,584),(167,584),(167,622)]);s.arrow([(480,584),(480,622)])
    s.text(928,608,'Edits the shared project',12,QUIET,400,False,'end')
    # audio branch explicit separate
    s.arrow([(215,600),(215,622)],LIGHT);s.arrow([(540,600),(540,622)],LIGHT)
    return s

def director():
    s=SVG(960,416,'Attention-first direction','Illustrative example of an intent timeline, a planned shot and a continuous camera path. Not a recording or benchmark.')
    s.header('02 / Director','Attention before motion.','Clicks, typing, visual activity and context inform an editable shot plan.')
    x0=180; x1=912
    for i in range(7):
        x=x0+i*120;s.text(x,153,f'{i*2:02d}s',12,QUIET,400,True);s.line(x,164,x,338,DUST)
    for y,label in [(190,'Signals'),(240,'Shot plan'),(294,'Camera scale')]:s.text(32,y,label,15,MUTED)
    cells=[]
    for i in range(183):
        x=x0+4*i
        if 8<=i<=35 or 74<=i<=115 or 145<=i<=164:
            a=1+int(abs(sin(i*1.8)*cos(i*.13))*4)
            for j in range(a):cells.append((x,195-j*4,LIGHT if j%2==0 else BLUE))
        else:cells.append((x,195,DUST))
    s.cells(cells)
    for a,b,txt in [(10,42,'Click'),(68,121,'Typing / visual'),(143,169,'Click')]:
        s.dither(x0+a*4,213,b-a,4,.65);s.text(x0+a*4,250,txt,12,LIGHT)
    # continuous curve: conceptual scale not measured
    s.path('M180 329C210 329 216 278 244 278L306 278C331 278 345 329 370 329L420 329C447 329 453 268 482 268L640 268C667 268 681 329 707 329L730 329C749 329 759 285 782 285L843 285C867 285 878 329 912 329','none',LIGHT,2.5)
    s.text(32,331,'1× baseline',12,QUIET,400,True)
    s.line(180,344,912,344,DUST)
    s.text(32,383,'Planner chooses what and when. Camera solver determines how.',16,INK,500)
    s.text(928,383,'Illustrative trace',11,QUIET,400,True,'end')
    return s

def design():
    s=SVG(960,548,'Pixel instrument design','Five semantic lanes, deterministic square cells, mirrored audio envelopes, a playhead and two-blue controls. Illustrative, not a screenshot.')
    s.header('03 / Dieother','Pixels carry information.','Neutral chrome. Two-blue interface accents. Semantic color inside the timeline.')
    s.rect(32,140,896,288,'#0C0C0C',8)
    x0=144; n=190; pitch=4
    for i in range(7):s.text(x0+120*i,166,f'0:{i*5:02d}',11,QUIET,400,True)
    labels=['Clips','Zoom','Events','Voice','Music']; hues=['#599CFF','#FA8E3B','#A373FF','#55D3F1','#F267B0']
    cells=[]
    for lane,label in enumerate(labels):
        y0=184+lane*44;s.text(46,y0+17,label,13,MUTED)
        for i in range(n):
            for j in range(9):
                q=BAYER[(j%4)*4+i%4]; color=DUST; lit=False
                if lane==0:lit=i not in (56,57,128,129) and 1<=j<=7 and q<13;color=hues[0] if i<129 else '#6FDB73'
                elif lane==1:lit=(13<i<45 or 77<i<116 or 144<i<174) and 2<=j<=6 and q<12;color=hues[1]
                elif lane==2:lit=(i%29==8 or i%37==20) and 1<=j<=7;color=hues[2]
                elif lane==3:lit=abs(j-4)<=int(abs(sin(i*1.29)*cos(i*.071))*4);color=hues[3]
                else:lit=i>20 and abs(j-4)<=int(abs(sin(i*.39)*cos(i*.105))*3);color=hues[4]
                if lit or q==0:cells.append((x0+i*pitch,y0+j*pitch,color if lit else DUST))
    s.cells(cells);s.line(524,174,524,410,INK,1.5);s.rect(505,145,38,15,INK,3);s.text(524,156,'15.8',10,BG,500,True,'middle')
    # UI accents only, with pixel progress / slider
    s.text(32,458,'Export progress',13,MUTED);s.text(502,458,'Precision slider',13,MUTED)
    s.cells([(32+i*4,471+j*4,(BLUE if (i+j)%2 else LIGHT) if i<68 else DUST) for i in range(103) for j in range(3)])
    for i in range(106):s.rect(502+i*4,470 if i<66 else 474,2,12 if i<66 else 4,BLUE if i<66 else DUST)
    s.rect(766,467,2,18,INK)
    s.text(32,521,'4 pt pitch / 3 pt cells / 1 pt gap',13,LIGHT,400,True);s.text(928,521,'Illustrative design study',12,QUIET,400,True,'end')
    return s

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,default=Path(__file__).resolve().parents[1]/'readme-assets');args=p.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    for name,make in [('architecture',architecture),('director',director),('design',design)]:
        target=args.out/f'{name}.svg';make().save(target);print(f'{target.name}: {target.stat().st_size:,} bytes')
if __name__=='__main__':main()
