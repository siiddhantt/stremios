#!/usr/bin/env python3
"""Bounded standard-library checks for the pinned SVG/PNG player icon bundle."""
from pathlib import Path
import hashlib, json, re, struct, zlib, xml.etree.ElementTree as ET
p=Path(__file__).resolve().parent
manifest=json.loads((p/'manifest.json').read_text())
checks=0
def check(condition, message):
 global checks
 if not condition: raise AssertionError(message)
 checks+=1
def digest(data): return hashlib.sha256(data).hexdigest()
def rgba(data):
 check(data[:8]==b'\x89PNG\r\n\x1a\n','PNG signature')
 width,height,depth,colour,compression,filtering,interlace=struct.unpack('>IIBBBBB',data[16:29])
 check(depth==8 and colour==6 and compression==0 and filtering==0 and interlace==0,'Bounded noninterlaced RGBA')
 check(width==height and width in (24,48,72),'Supported icon dimension')
 at=8;packed=bytearray()
 while at<len(data):
  size,=struct.unpack('>I',data[at:at+4]);kind=data[at+4:at+8];value=data[at+8:at+8+size]
  check(size<100000 and at+size+12<=len(data),'Bounded PNG chunk')
  if kind==b'IDAT':packed.extend(value)
  at+=size+12
 raw=zlib.decompress(bytes(packed));stride=width*4
 check(len(raw)==height*(stride+1),'Exact decoded pixel count')
 rows=[];previous=bytearray(stride)
 for y in range(height):
  mode=raw[y*(stride+1)];row=bytearray(raw[y*(stride+1)+1:(y+1)*(stride+1)])
  check(mode<=4,'Valid PNG filter')
  for x in range(stride):
   left=row[x-4] if x>=4 else 0;above=previous[x];upper=previous[x-4] if x>=4 else 0
   if mode==1:pred=left
   elif mode==2:pred=above
   elif mode==3:pred=(left+above)//2
   elif mode==4:
    estimate=left+above-upper;distances=[abs(estimate-left),abs(estimate-above),abs(estimate-upper)]
    pred=[left,above,upper][distances.index(min(distances))]
   else:pred=0
   row[x]=(row[x]+pred)&255
  rows.append(bytes(row));previous=row
 return width,height,b''.join(rows)
check(manifest['commit']=='a4ce1404bc6d24d3c365afe7b258d6bf6f48d62d','Pinned source commit')
check(manifest['pointSize']==24 and manifest['strokeWidth']==2,'Unified official geometry')
check(manifest['license']=='MIT' and digest((p/'LICENSE.txt').read_bytes())==manifest['licenseSHA256'],'Exact upstream license')
expected={'close','view','audio','cc','fullscreen','fullscreen-exit','play','pause','back','forward','movies','series','filters','nav-back','save','saved'}
check({x['name'] for x in manifest['icons']}==expected,'Complete player action inventory')
header=(p/'GeneratedIcons.h').read_text();total=0;bounds={}
for icon in manifest['icons']:
 svg=(p/(('filled-' if icon.get('style')=='filled' else '')+icon['upstream']+'.svg')).read_bytes()
 check(digest(svg)==icon['svgSHA256'],'Unmodified upstream SVG hash')
 check(manifest['commit'] in icon['sourceURL'] and icon['sourceURL'].startswith('https://raw.githubusercontent.com/tabler/tabler-icons/'),'Pinned official provenance')
 root=ET.fromstring(svg)
 check(root.attrib['viewBox']=='0 0 24 24','Consistent official canvas')
 if icon.get('style')=='filled':check(root.attrib.get('fill')=='currentColor','Official selected-state fill')
 else:check(root.attrib['stroke-width']=='2' and root.attrib['stroke-linecap']=='round' and root.attrib['stroke-linejoin']=='round','Consistent official outline stroke')
 check({x['scale'] for x in icon['pngs']}=={1,2,3},'All device scales present')
 for raster in icon['pngs']:
  data=(p/raster['filename']).read_bytes();total+=len(data)
  check(digest(data)==raster['sha256'] and len(data)==raster['bytes'],'Raster digest and byte count')
  w,h,pixels=rgba(data);s=raster['scale']
  check(w==h==24*s and (w,h)==(raster['width'],raster['height']),'24-point size at device scale')
  ink=[(i//4%w,i//4//w) for i in range(0,len(pixels),4) if pixels[i+3]>0]
  check(len(ink)>w and len(ink)<w*h//2,'Visible glyph with transparent surround')
  check(all(pixels[i:i+3]==b'\xff\xff\xff' for i in range(0,len(pixels),4) if pixels[i+3]>0),'White template color only')
  box=[min(x for x,y in ink),min(y for x,y in ink),max(x for x,y in ink),max(y for x,y in ink)]
  check(box[0]>0 and box[1]>0 and box[2]<w-1 and box[3]<h-1,'No cropped edge pixels')
  symbol='MSPlayerPNG_'+icon['name'].replace('-','_')+'_'+str(s)
  match=re.search(r'unsigned char '+symbol+r'\[\] = \{(.*?)\};',header,re.S)
  embedded=bytes(int(x,16) for x in re.findall(r'0x([0-9a-f]{2})',match.group(1))) if match else b''
  check(embedded==data,'Embedded bytes exactly match committed raster')
  if s==2:bounds[icon['name']]=box
check(total==manifest['totalRasterBytes'] and total<22000,'Bounded complete raster footprint')
check('Paweł Kuna' in (p.parent/'ThirdPartyNotices.txt').read_text(),'License shipped in existing app notices')
print(json.dumps({'passed':True,'checks':checks,'icons':len(expected),'rasterVariants':len(expected)*3,'embeddedRasterBytes':total,'retinaInkBounds':bounds},indent=2))
