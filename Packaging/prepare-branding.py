#!/usr/bin/env python3
"""Prepare signed-bundle resources deterministically. Original is never redrawn.
A clearly marked CI placeholder is used only when the approved binary is absent.
No final signing or publication is permitted with that placeholder."""
import argparse, hashlib, json, math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

APPROVED_SHA256 = "0dd750be1d060b75f6b4075122e7ef2bf7f59d74090a3872217dc9a417bd5620"
RESAMPLE = Image.Resampling.LANCZOS

def arrows(draw, center, radius, width, color):
    x, y = center
    bounds = (x-radius, y-radius, x+radius, y+radius)
    for start, end in ((205, 335), (25, 155)):
        draw.arc(bounds, start=start, end=end, fill=color, width=width)
        angle = math.radians(end)
        p = (x+radius*math.cos(angle), y+radius*math.sin(angle))
        t = (-math.sin(angle), math.cos(angle))
        n = (math.cos(angle), math.sin(angle))
        k = width*2.1
        draw.polygon([(p[0]+t[0]*k*.65,p[1]+t[1]*k*.65),
                      (p[0]-t[0]*k+n[0]*k*.68,p[1]-t[1]*k+n[1]*k*.68),
                      (p[0]-t[0]*k-n[0]*k*.68,p[1]-t[1]*k-n[1]*k*.68)], fill=color)

def placeholder():
    n=1024
    tile=Image.new("RGBA",(n,n))
    d=ImageDraw.Draw(tile)
    d.rounded_rectangle((88,88,936,936),radius=235,fill="#073b88")
    d.rounded_rectangle((88,88,936,936),radius=235,outline="#27b6ee",width=12)
    d.rounded_rectangle((270,300,530,470),radius=74,fill="#c6d9f0")
    d.rounded_rectangle((248,372,776,733),radius=78,fill="#eef5ff")
    arrows(d,(512,550),146,38,"#087bd7")
    return tile

def approved_icon(source):
    image=Image.open(source)
    image.load()
    if image.size != (1254,1254):
        raise SystemExit("Approved original has unexpected dimensions")
    image=image.convert("RGBA")
    # Trace the ORIGINAL silhouette using smooth cubic curves. Preserve
    # artwork, excluding the white canvas and exterior drop shadow.
    points=[]
    def start(p): points.append(p)
    def line(p): points.append(p)
    def curve(a,b,c):
        p=points[-1]
        for i in range(1,65):
            t=i/64; u=1-t
            points.append(tuple(u**3*p[j]+3*u*u*t*a[j]+3*u*t*t*b[j]+t**3*c[j] for j in (0,1)))
    start((430,103)); line((827,103))
    curve((1010,103),(1138,220),(1143,405))
    line((1143,835)); curve((1143,1014),(1022,1149),(841,1150))
    line((410,1150)); curve((230,1150),(96,1026),(96,844))
    line((96,415)); curve((96,230),(230,103),(430,103))
    # Supersampled matte for an anti-aliased transparent edge.
    mask=Image.new("L",(2508,2508))
    ImageDraw.Draw(mask).polygon([(round(x*2),round(y*2)) for x,y in points],fill=255)
    image.putalpha(mask.resize(image.size,RESAMPLE))
    return image.resize((1024,1024),RESAMPLE)

def menu_template():
    size=144
    im=Image.new("RGBA",(size,size))
    d=ImageDraw.Draw(im)
    # Recognizable folder with paired arrows at status-bar scale.
    d.line([(12,44),(12,30),(49,30),(60,45),(130,45),(130,112),(12,112),(12,44)],
           fill=(0,0,0,255),width=9,joint="curve")
    arrows(d,(71,80),20,8,(0,0,0,255))
    return im.resize((36,36),RESAMPLE)

def font(size,bold=False):
    for name in ["/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"]:
        try: return ImageFont.truetype(name,size)
        except OSError: pass
    return ImageFont.load_default(size=size)

def background(approved):
    w,h=720,430
    im=Image.new("RGB",(w,h))
    d=ImageDraw.Draw(im)
    for y in range(h):
        t=y/(h-1)
        d.line((0,y,w,y),fill=(int(12+9*t),int(29+20*t),int(59+34*t)))
    d.text((36,27),"MacSync",font=font(30,True),fill="#ffffff")
    d.text((37,66),"Installa la versione 0.17.0",font=font(15),fill="#b9d2ee")
    d.rounded_rectangle((38,109,682,307),radius=24,fill="#eef5ff")
    d.line((310,198,410,198),fill="#2478cf",width=8)
    d.polygon([(410,181),(440,198),(410,215)],fill="#2478cf")
    d.text((360,124),"Trascina MacSync in Applicazioni",font=font(17,True),anchor="mt",fill="#17395d")
    d.text((36,335),"Primo avvio",font=font(17,True),fill="#ffffff")
    d.text((36,362),"Leggi la guida inclusa prima del collaudo.",font=font(14),fill="#c4d8ed")
    if not approved:
        d.text((36,398),"BUILD DI TEST  ·  ICONA PROVVISORIA",font=font(12,True),fill="#ffdc94")
    else:
        d.text((36,398),"macOS 13+  ·  Intel e Apple Silicon",font=font(12),fill="#c4d8ed")
    return im

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--source",type=Path,default=Path("Packaging/Branding/MacSync-Approved-Original.png"))
    p.add_argument("--output",required=True,type=Path)
    p.add_argument("--require-approved",action="store_true")
    args=p.parse_args()
    source=args.source
    approved=source.is_file()
    if approved and hashlib.sha256(source.read_bytes()).hexdigest()!=APPROVED_SHA256:
        raise SystemExit("Approved source hash mismatch. Do not silently substitute.")
    if args.require_approved and not approved:
        raise SystemExit("Approved original missing; release signing blocked.")
    out=args.output
    out.mkdir(parents=True,exist_ok=True)
    image=approved_icon(source) if approved else placeholder()
    assert image.mode=="RGBA" and image.getpixel((0,0))[3]==0
    image.save(out/"MacSyncBrand.png")
    menu_template().save(out/"MacSyncMenuTemplate.png")
    iconset=out/"MacSync.iconset"
    iconset.mkdir(exist_ok=True)
    for n in (16,32,128,256,512):
        for scale in (1,2):
            suffix="@2x" if scale==2 else ""
            target=iconset/f"icon_{n}x{n}{suffix}.png"
            image.resize((n*scale,n*scale),RESAMPLE).save(target)
    background(approved).save(out/"MacSync-DMG-Background.png")
    metadata={"approved_original":approved,
              "source_sha256":APPROVED_SHA256 if approved else None,
              "status":"approved-original" if approved else "placeholder-ci-only"}
    (out/"branding-provenance.json").write_text(json.dumps(metadata,indent=2)+"\n")
    print(json.dumps(metadata))
if __name__=="__main__": main()
