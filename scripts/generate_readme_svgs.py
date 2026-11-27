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
        self.dither(32,33,3,3,.8,3)
        self.text(47,41,kicker,12,LIGHT,500,True)
        self.text(32,76,title,30,INK,500)
        self.text(32,102,subtitle,15,MUTED)
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
    s=SVG(960, 390, "Lumen architecture", "Logical data flow: capture to project; analysis and direction derive edits; shared rendering and audio feed preview and export. UI and agent commands edit the same project.")
    s.dither(32, 33, 3, 3, 0.8, 3)
    s.text(47, 41, "01 / System", 12, "#A7DFFF", 500, True, "start")
    s.text(32, 76, "One recording. One source of truth.", 30, "#F5F5F5", 500, False, "start")
    s.text(32, 102, "Swift · ScreenCaptureKit · Metal", 15, "#A3A3A3", 400, False, "start")
    s.rect(32, 132, 256, 65, "#121212", 7)
    s.dither(46, 147, 3, 3, 0.85, 3)
    s.text(61, 156, "Capture", 18, "#F5F5F5", 500, False, "start")
    s.text(46, 179, "Screen · input · audio", 13, "#A3A3A3", 400, False, "start")
    s.rect(352, 132, 256, 65, "#121212", 7)
    s.dither(366, 147, 3, 3, 0.85, 3)
    s.text(381, 156, ".lumen project", 18, "#F5F5F5", 500, False, "start")
    s.text(366, 179, "Source media + timeline", 13, "#A3A3A3", 400, False, "start")
    s.rect(672, 132, 256, 65, "#121212", 7)
    s.dither(686, 147, 3, 3, 0.85, 3)
    s.text(701, 156, "Director", 18, "#F5F5F5", 500, False, "start")
    s.text(686, 179, "Analysis → shot plan", 13, "#A3A3A3", 400, False, "start")
    s.arrow([[288,164],[352,164]], "#1688FF")
    s.arrow([[608,164],[672,164]], "#1688FF")
    s.rect(352, 230, 256, 65, "#121212", 7)
    s.dither(366, 245, 3, 3, 0.85, 3)
    s.text(381, 254, "Composition", 18, "#F5F5F5", 500, False, "start")
    s.text(366, 277, "TimeMap · Metal · audio", 13, "#A3A3A3", 400, False, "start")
    s.arrow([[480,197],[480,230]], "#1688FF")
    s.arrow([[800,197],[800,262],[608,262]], "#1688FF")
    s.rect(32, 308, 256, 60, "#121212", 7)
    s.dither(46, 323, 3, 3, 0.85, 3)
    s.text(61, 332, "Native preview", 18, "#F5F5F5", 500, False, "start")
    s.text(46, 355, "SwiftUI · AppKit", 13, "#A3A3A3", 400, False, "start")
    s.rect(672, 308, 256, 60, "#121212", 7)
    s.dither(686, 323, 3, 3, 0.85, 3)
    s.text(701, 332, "Offline export", 18, "#F5F5F5", 500, False, "start")
    s.text(686, 355, "GPU → encoder", 13, "#A3A3A3", 400, False, "start")
    s.arrow([[352,262],[160,262],[160,308]], "#A7DFFF")
    s.arrow([[608,281],[640,281],[640,338],[672,338]], "#A7DFFF")
    s.text(480, 334, "Editor + MCP", 14, "#A7DFFF", 500, False, "middle")
    s.text(480, 353, "Edit the shared project", 12, "#A3A3A3", 400, False, "middle")
    return s

def project():
    s=SVG(960, 284, "Non-destructive timeline", "Illustrative source-time and output-time mapping. A cut removes an interval from output, not from original media.")
    s.dither(32, 33, 3, 3, 0.8, 3)
    s.text(47, 41, "02 / Project", 12, "#A7DFFF", 500, True, "start")
    s.text(32, 76, "Edit the story, not the source.", 30, "#F5F5F5", 500, False, "start")
    s.text(32, 102, "One .lumen bundle · source time → output time", 15, "#A3A3A3", 400, False, "start")
    s.text(32, 143, "Source", 14, "#A3A3A3", 400, False, "start")
    s.text(32, 213, "Output", 14, "#A3A3A3", 400, False, "start")
    s.dither(156, 128, 188, 5, 0.65, 4)
    s.rect(404, 125, 112, 24, "#090909", 0)
    s.line(404, 137, 516, 137, "#777777", 1)
    s.text(460, 120, "Cut", 12, "#A3A3A3", 400, False, "middle")
    s.dither(156, 198, 62, 5, 0.65, 4)
    s.dither(404, 198, 98, 5, 0.65, 4)
    s.arrow([[156,154],[156,194]], "#A7DFFF")
    s.arrow([[516,154],[516,169],[404,169],[404,194]], "#A7DFFF")
    s.arrow([[908,154],[908,169],[796,169],[796,194]], "#A7DFFF")
    s.text(156, 250, "Original media is retained.", 14, "#F5F5F5", 500, False, "start")
    s.text(928, 250, "Illustrative TimeMap", 12, "#777777", 400, True, "end")
    return s

def render():
    s=SVG(960, 300, "Shared composition", "Frame sources and a timeline feed the Metal renderer. Audio mixing and rendering are shared by native preview and offline export; export overlaps GPU rendering and encoding.")
    s.dither(32, 33, 3, 3, 0.8, 3)
    s.text(47, 41, "04 / Render", 12, "#A7DFFF", 500, True, "start")
    s.text(32, 76, "Two outputs. One composition.", 30, "#F5F5F5", 500, False, "start")
    s.text(32, 102, "Shared renderer + audio mix", 15, "#A3A3A3", 400, False, "start")
    s.rect(32, 140, 238, 65, "#121212", 7)
    s.dither(46, 155, 3, 3, 0.85, 3)
    s.text(61, 164, "Frame sources", 18, "#F5F5F5", 500, False, "start")
    s.text(46, 187, "Screen · camera · timeline", 13, "#A3A3A3", 400, False, "start")
    s.rect(357, 140, 246, 65, "#121212", 7)
    s.dither(371, 155, 3, 3, 0.85, 3)
    s.text(386, 164, "Metal + audio", 18, "#F5F5F5", 500, False, "start")
    s.text(371, 187, "Frame composition · mix", 13, "#A3A3A3", 400, False, "start")
    s.arrow([[270,172],[357,172]], "#1688FF")
    s.rect(690, 120, 238, 65, "#121212", 7)
    s.dither(704, 135, 3, 3, 0.85, 3)
    s.text(719, 144, "Preview", 18, "#F5F5F5", 500, False, "start")
    s.text(704, 167, "Latest-frame presentation", 13, "#A3A3A3", 400, False, "start")
    s.rect(690, 213, 238, 65, "#121212", 7)
    s.dither(704, 228, 3, 3, 0.85, 3)
    s.text(719, 237, "Export", 18, "#F5F5F5", 500, False, "start")
    s.text(704, 260, "GPU / encoder overlap", 13, "#A3A3A3", 400, False, "start")
    s.arrow([[603,162],[650,162],[650,152],[690,152]], "#A7DFFF")
    s.arrow([[603,184],[650,184],[650,245],[690,245]], "#A7DFFF")
    s.text(32, 248, "Same edits. Same composition.", 15, "#F5F5F5", 500, False, "start")
    return s

def judgment():
    s=SVG(960, 254, "Product judgment", "Three explicit product choices: native macOS instead of a web wrapper, editable rather than baked-in direction, and focused recording instead of a general-purpose editor.")
    s.dither(32, 33, 3, 3, 0.8, 3)
    s.text(47, 41, "05 / Judgment", 12, "#A7DFFF", 500, True, "start")
    s.text(32, 76, "Less, but better.", 30, "#F5F5F5", 500, False, "start")
    s.text(32, 102, "Three boundaries that keep the product focused.", 15, "#A3A3A3", 400, False, "start")
    s.dither(32, 137, 12, 3, 0.7, 4)
    s.text(32, 181, "Native macOS", 20, "#F5F5F5", 500, False, "start")
    s.text(32, 207, "Not a web wrapper", 14, "#A3A3A3", 400, False, "start")
    s.line(314, 136, 314, 220, "#262626", 1)
    s.dither(336, 137, 12, 3, 0.7, 4)
    s.text(336, 181, "Editable direction", 20, "#F5F5F5", 500, False, "start")
    s.text(336, 207, "Not baked-in motion", 14, "#A3A3A3", 400, False, "start")
    s.line(618, 136, 618, 220, "#262626", 1)
    s.dither(640, 137, 12, 3, 0.7, 4)
    s.text(640, 181, "Focused workflow", 20, "#F5F5F5", 500, False, "start")
    s.text(640, 207, "Not a general video editor", 14, "#A3A3A3", 400, False, "start")
    return s

def director():
    s=SVG(960,416,'Attention-first direction','Illustrative example of an intent timeline, a planned shot and a continuous camera path. Not a recording or benchmark.')
    s.header('03 / Director','Attention before motion.','Signals become an editable shot plan.')
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
    s.header('06 / Dieother','Pixels carry information.','Two blues for the interface. Semantic color for media.')
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
    for name,make in [('architecture',architecture),('project',project),('director',director),('render',render),('judgment',judgment),('design',design)]:
        target=args.out/f'{name}.svg';make().save(target);print(f'{target.name}: {target.stat().st_size:,} bytes')
if __name__=='__main__':main()
