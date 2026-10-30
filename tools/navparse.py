#!/usr/bin/env python3
# navparse.py — 解析 ANHS V社 nav 文件（magic 0xFEEDFACE, version 16），
#               导出 area 图（id / 中心 / 4方向邻接 id），供 SM 插件 A* 使用。
# navparse.py — parse ANHS Valve .nav files (magic 0xFEEDFACE, version 16) and
#               export the area graph (id / center / 4-direction neighbour ids)
#               for the SourceMod plugin's A* pathfinder.
#
# v16 area 记录布局（依据 Valve source nav_file.cpp CNavArea::Load，v16）：
#   u32 id
#   i32 attributeFlags
#   f32 nwCorner[3] ; f32 seCorner[3] ; f32 neZ ; f32 swZ
#   for dir in N,E,S,W: u32 connCount ; connCount * u32 areaID
#   u8  hidingCount ; hidingCount * HidingSpot(hidingSize bytes)
#   u32 encounterCount ; each: { u32 from; u8 fromDir; u32 to; u8 toDir; u8 spotCount; spotCount*(u32 id,u8 t) }
#   u16 placeIndex
#   for up,down: u32 ladderCount ; ladderCount * u32 ladderID
#   f32 earliestOccupyTime[maxNavTeams]
#   f32 lightIntensity[NUM_CORNERS(=4)]
#   u32 visibleCount ; each { u32 areaID ; u8 attr }
#   u32 inheritVisibilityFrom
# 未知量 hidingSize / maxNavTeams 通过"解析到尾部干净收束 + 连接 id 全合法"自校验确定。
import struct, sys, os

def u8 (b,o): return b[o], o+1
def u16(b,o): return struct.unpack_from("<H",b,o)[0], o+2
def u32(b,o): return struct.unpack_from("<I",b,o)[0], o+4
def i32(b,o): return struct.unpack_from("<i",b,o)[0], o+4
def f32(b,o): return struct.unpack_from("<f",b,o)[0], o+4
def vec3(b,o):
    x,y,z = struct.unpack_from("<fff",b,o); return (x,y,z), o+12

def parse_header(b):
    magic, o = u32(b,0)
    assert magic == 0xFEEDFACE, "bad magic %x" % magic
    version, o = u32(b,o)
    sub = 0
    if version >= 10: sub, o = u32(b,o)
    if version >= 4:  bspSize, o = u32(b,o)
    isAnalyzed = 0
    if version >= 14: isAnalyzed, o = u8(b,o)
    places = []
    if version >= 5:
        pcount, o = u16(b,o)
        for _ in range(pcount):
            nlen, o = u16(b,o)
            nm = b[o:o+nlen-1].decode('latin1','replace'); o += nlen
            places.append(nm)
        hasUnnamed = 0
        if version > 11: hasUnnamed, o = u8(b,o)
    # LoadCustomDataPreArea: ANHS 基类默认空，跳过（假设 0 字节）
    areaCount, o = u32(b,o)
    return dict(version=version, sub=sub, bspSize=(bspSize if version>=4 else 0),
                isAnalyzed=isAnalyzed, places=places, areaCount=areaCount), o

def parse_area(b, o, hidingSize, maxNavTeams, numCorners=4):
    aid, o = u32(b,o)
    attr, o = i32(b,o)
    nw, o = vec3(b,o)
    se, o = vec3(b,o)
    neZ, o = f32(b,o)
    swZ, o = f32(b,o)
    conns = []
    for _ in range(4):
        c, o = u32(b,o)
        for _ in range(c):
            cid, o = u32(b,o)
            if cid != aid: conns.append(cid)
    hid, o = u8(b,o)
    o += hid*hidingSize
    enc, o = u32(b,o)
    for _ in range(enc):
        o += 4+1+4+1          # from,fromDir,to,toDir
        sc, o = u8(b,o)
        o += sc*(4+1)         # each: id u32 + t u8
    placeIdx, o = u16(b,o)
    for _ in range(2):        # ladder up/down
        lc, o = u32(b,o)
        o += lc*4
    o += maxNavTeams*4        # earliestOccupyTime
    o += numCorners*4         # lightIntensity
    vis, o = u32(b,o)
    o += vis*(4+1)
    inherit, o = u32(b,o)
    cx = (nw[0]+se[0])*0.5; cy=(nw[1]+se[1])*0.5; cz=(neZ+swZ)*0.5
    return dict(id=aid, center=(cx,cy,cz), conns=conns, attr=attr), o

def try_parse(b, hidingSize, maxNavTeams):
    hdr, o = parse_header(b)
    n = hdr['areaCount']
    areas = []
    for _ in range(n):
        a, o = parse_area(b, o, hidingSize, maxNavTeams)
        areas.append(a)
    return hdr, areas, o

def validate(path, verbose=True):
    b = open(path,'rb').read()
    hdr0, o0 = parse_header(b)
    n = hdr0['areaCount']
    if verbose: print("file=%s size=%d version=%d sub=%d bspSize=%d analyzed=%d places=%d areaCount=%d"
                      % (os.path.basename(path), len(b), hdr0['version'], hdr0['sub'],
                         hdr0['bspSize'], hdr0['isAnalyzed'], len(hdr0['places']), n))
    idset_target = n
    good = []
    for hs in range(0, 33):
        for mt in range(0, 9):
            try:
                hdr, areas, endoff = try_parse(b, hs, mt)
            except Exception:
                continue
            if len(areas) != n: continue
            # 连接 id 合法性
            ids = set(a['id'] for a in areas)
            okconn = all(all(c in ids for c in a['conns']) for a in areas)
            if not okconn: continue
            # 尾部收束：剩余应是小尾巴（ladderCount(4)+若干梯子+customData）
            remain = len(b) - endoff
            ladderCount = struct.unpack_from("<I", b, endoff)[0] if remain>=4 else -1
            if remain < 4: continue
            if ladderCount < 0 or ladderCount > 20000: continue
            # 中心坐标有限
            if not all(abs(a['center'][0])<1e6 and abs(a['center'][1])<1e6 for a in areas): continue
            good.append((hs, mt, endoff, remain, ladderCount, len(ids)))
    if verbose:
        for g in good:
            print("  OK hidingSize=%d maxNavTeams=%d endoff=%d remain=%d ladderCount=%d distinctIDs=%d" % g)
    return good

if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == 'validate':
        for p in sys.argv[2:]:
            validate(p)
    else:
        path = sys.argv[1] if len(sys.argv)>1 else r"D:/anh/anhsource/maps/ann_shooting_range.nav"
        good = validate(path)
        if good:
            hs, mt = good[0][0], good[0][1]
            hdr, areas, endoff = try_parse(open(path,'rb').read(), hs, mt)
            print("\nsample areas (hidingSize=%d maxNavTeams=%d):" % (hs,mt))
            for a in areas[:8]:
                print("  id=%d center=(%.0f,%.0f,%.0f) conns=%s" % (a['id'],*a['center'], a['conns']))
