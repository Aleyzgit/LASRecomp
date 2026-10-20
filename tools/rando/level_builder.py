#!/usr/bin/env python3
"""Write a dungeon level (.lvb) for any layout of top-down rooms (generated dungeons with new shapes).

A level holds (decoded 2026-10-08, notes/PLAN.md):
  area   one per room cell, named after the room: AABB (x0,-3.1,z0)-(x1,6,z1), a second AABB (y to 3.15),
         +0x30 offset of "level/<Lv>/<room>.leb" in the names section, CRC32(name) at +0x34, +0x3C zone index,
         +0x3E row (0-based), +0x3F column
  node   bounding-volume tree over the areas: AABB, u32 count<<16 | first area, u32 right<<16 | left (-1 = leaf);
         nodes in pre-order, areas ordered so every node's areas are contiguous
  zone   camera regions: u32 id, centre xyz, half extents xyz, camera params, then (+0x9c) u32 1, u8 type,
         u8 0, u8 count, u8 area indices[] (0xFF padded), BGM / ambience / environment names
  tagPlayerStart  named spawn points (name + xyz + rotation); staticObject  dungeon-map objects (doors, chests)
Everything not listed is copied from the level the layout is built in (base .lvb).

    build(base_lvb, rooms, starts=None, static=True) -> bytes
        rooms: [{'name': 'Lv01TailCave_04B', 'unit': 0, 'area_data': <the room's area record from its source
                 level>, 'fixed': side-view rooms keep the record as is, 'zone_data': their zone record}, ...]
                 (cells of one unit share a camera zone; area records are moved to the cell and renamed),
                 'path': the room file to load (default level/<Lv>/<name>.leb; a cell the game's RomFS has no file
                 for must point at an existing file name - the seed overrides that file's content),
                 'keep_zone': the zone id to keep (unchanged rooms: their actors carry it)
"""
import copy
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fixedhash  # noqa: E402

LEAF = 3


def cell_box(name):
    rc = name.rsplit('_', 1)[1][:3]
    x0, z0 = (ord(rc[2]) - ord('A')) * 15.0, (int(rc[:2]) - 1) * 12.0
    return x0, z0, x0 + 15.0, z0 + 12.0


GRID_Y = (-3.1, 6.0)  # height range of a top-down cell (vanilla node boxes)


def _bvh(items):
    """items: [(name, x0, z0, x1, z1[, y0, y1])] -> (ordered names, nodes [(aabb6, count, first, left, right)]).
    Node boxes span their areas' heights: side-view passages reach y 13 (ladders up to the rooms above end at
    y ~12). A node capped at the grid's y 6 (as before 2026-10-18) left Link outside every room near a ladder's
    top - the game never saw him reach the AreaUpstairs there and he was stuck on the ladder (Tail Cave 01F/01G)."""
    order, nodes = [], []

    def rec(its):
        i = len(nodes)
        nodes.append(None)
        x0 = min(t[1] for t in its); z0 = min(t[2] for t in its)
        x1 = max(t[3] for t in its); z1 = max(t[4] for t in its)
        y0 = min((t[5] if len(t) > 5 else GRID_Y[0]) for t in its)
        y1 = max((t[6] if len(t) > 5 else GRID_Y[1]) for t in its)
        first = len(order)
        if len(its) <= LEAF:
            order.extend(t[0] for t in its)
            nodes[i] = ((x0, y0, z0, x1, y1, z1), len(its), first, -1, -1)
            return i
        axis = 1 if (x1 - x0) >= (z1 - z0) else 2
        its = sorted(its, key=lambda t: (t[axis] + t[axis + 2]) / 2)
        h = len(its) // 2
        left = rec(its[:h])
        right = rec(its[h:])
        nodes[i] = ((x0, y0, z0, x1, y1, z1), len(its), first, left, right)
        return i
    rec(items)
    return order, nodes


def build(base, rooms, starts=None, static=True, keep_tree=False):
    fh = fixedhash.FixedHash(base)
    area_e = fh.get(b'area').data
    node_e = fh.get(b'node').data
    zone_e = fh.get(b'zone').data
    tmpl_area = area_e.entries[0]
    top_zones = [e for e in zone_e.entries if e.data[0x9c + 4] == 3]
    tmpl_zone = top_zones[0] if top_zones else zone_e.entries[0]

    def box(r):  # 'fixed' rooms (side-view etc.) keep their area record as is
        if r.get('fixed'):
            x0, _, z0, x1, _, z1 = struct.unpack_from('<6f', r['area_data'], 0)
            return x0, z0, x1, z1
        return cell_box(r['name'])
    def ybox(r):  # height range: side-view rooms their own area box's, grid cells the usual one
        if r.get('fixed'):
            _, y0, _, _, y1, _ = struct.unpack_from('<6f', r['area_data'], 0)
            return min(y0, GRID_Y[0]), max(y1, GRID_Y[1])
        return GRID_Y
    by_name = {r['name']: r for r in rooms}
    items = [(r['name'],) + box(r) + ybox(r) for r in rooms]
    order, nodes = _bvh(items)
    if keep_tree:  # (debug) the base level's own tree and area order
        order = [e.name.decode() for e in area_e.entries]
        nodes = None
    idx = {n: i for i, n in enumerate(order)}

    # areas
    new_areas = []
    for n in order:
        r = by_name[n]
        d = bytearray(r.get('area_data') or tmpl_area.data)  # the room's own record (from its source level)
        if not r.get('fixed'):
            ox, _, oz = struct.unpack_from('<3f', d, 0)
            x0, z0, x1, z1 = cell_box(n)
            dx, dz = x0 - ox, z0 - oz
            for o in (0, 0x18):  # both boxes moved to the target cell
                bx0, by0, bz0, bx1, by1, bz1 = struct.unpack_from('<6f', d, o)
                struct.pack_into('<6f', d, o, bx0 + dx, by0, bz0 + dz, bx1 + dx, by1, bz1 + dz)
            struct.pack_into('<I', d, 0x34, zlib.crc32(n.encode()))
        e = copy.copy(tmpl_area)
        e.name, e.data, e.name_off = n.encode(), bytes(d), None
        new_areas.append(e)
    # names: "level/<Lv>/<room>.leb\0<room>\0" per area; the area record's +0x30 is the offset of its .leb path
    lv = order[0].rsplit('_', 1)[0] if order else ''
    names = bytearray()
    for e in new_areas:
        n = e.name.decode()
        path_off = len(names)
        path = by_name[n].get('path') or f'level/{n.rsplit("_", 1)[0] if "_" in n else lv}/{n}.leb'
        names += path.encode() + b'\0'
        e.name_off = len(names)
        names += e.name + b'\0'
        d = bytearray(e.data)
        struct.pack_into('<I', d, 0x30, path_off)
        e.data = bytes(d)
    area_e.entries = new_areas
    area_e.names = bytes(names)
    area_e.rebuild_index()

    # BVH
    tmpl_node = node_e.entries[0]
    new_nodes = list(node_e.entries) if nodes is None else []
    nodes = nodes or []
    for aabb, count, first, left, right in nodes:
        d = bytearray(tmpl_node.data)
        struct.pack_into('<6f', d, 0, *aabb)
        struct.pack_into('<I', d, 0x18, (count << 16) | first)
        struct.pack_into('<I', d, 0x1C, 0xFFFFFFFF if left < 0 else ((right << 16) | left))
        e = copy.copy(tmpl_node)
        e.data = bytes(d)
        new_nodes.append(e)
    node_e.entries = new_nodes

    # camera zones: one per unit
    units = {}
    for r in rooms:
        units.setdefault(r.get('unit', r['name']), []).append(r['name'])
    new_zones = []
    # zones are written sorted by id (the game looks them up by id): kept ids (unchanged rooms) and new ids mixed
    def unit_zid(kv):
        r0 = by_name[kv[1][0]]
        if r0.get('keep_zone') is not None:
            return r0['keep_zone']
        return kv[0] if isinstance(kv[0], int) else 1 << 30
    unit_items = sorted(units.items(), key=lambda kv: (unit_zid(kv), str(kv[0])))
    for zi, (u, names) in enumerate(unit_items):
        boxes = [box(by_name[n]) for n in names]
        x0 = min(b[0] for b in boxes); z0 = min(b[1] for b in boxes)
        x1 = max(b[2] for b in boxes); z1 = max(b[3] for b in boxes)
        r0 = by_name[names[0]]
        zd = r0.get('zone_data')  # the room's own zone record (camera settings, environment, music)
        d = bytearray(zd if zd else tmpl_zone.data)
        # 'keep_zone': rooms whose files are unchanged (anchors, side-view rooms) keep their zone id - their actors
        # record it (actor roomID)
        zid = r0['keep_zone'] if r0.get('keep_zone') is not None else (u if isinstance(u, int) and u >= 300 else 300 + zi)
        struct.pack_into('<I', d, 0, zid)
        if not r0.get('fixed'):  # side-view zones keep their own camera box
            cy, hy = struct.unpack_from('<f', d, 8)[0], struct.unpack_from('<f', d, 20)[0]
            struct.pack_into('<6f', d, 4, (x0 + x1) / 2, cy, (z0 + z1) / 2, (x1 - x0) / 2, hy, (z1 - z0) / 2)
        ids = sorted(idx[n] for n in names)[:12]
        tail = bytearray(d[0x9c:0xb0])
        tail[6] = len(ids)
        tail[7:19] = bytes(ids + [0xFF] * (12 - len(ids)))
        d[0x9c:0xb0] = tail
        e = copy.copy(tmpl_zone)
        e.data = bytes(d)
        new_zones.append(e)
    zone_e.entries = new_zones
    # area record +0x3C = index of the zone holding it (the level indexes a per-zone list with it: a stale value
    # from the source level throws std::out_of_range), +0x3E / +0x3F = the cell's row (0-based) and column
    zone_of = {}
    for zi, (u, names) in enumerate(unit_items):
        for n in names:
            zone_of[n] = zi
    for e in area_e.entries:
        n = e.name.decode()
        d = bytearray(e.data)
        struct.pack_into('<H', d, 0x3C, zone_of.get(n, 0))
        if not by_name[n].get('fixed'):
            rc = n.rsplit('_', 1)[1][:3]
            d[0x3E] = int(rc[:2]) - 1
            d[0x3F] = ord(rc[2]) - ord('A')
            # floor margin: some rooms' boxes start at y -0.1 (Face Shrine 04A/05A); Link settling after a door jump
            # dips to -0.14 -> outside every room -> the game puts him back at the entrance. Never above -0.5.
            for off in (0x04, 0x1C):
                if struct.unpack_from('<f', d, off)[0] > -0.5:
                    struct.pack_into('<f', d, off, -0.5)
        e.data = bytes(d)

    if starts is not None:
        st = fh.get(b'tagPlayerStart').data
        tmpl = st.entries[0]
        new = []
        for name, (x, y, z, rot) in starts.items():
            e = copy.copy(tmpl)
            e.name, e.name_off = name.encode(), None
            e.data = struct.pack('<4f', x, y, z, rot) + tmpl.data[16:]
            new.append(e)
        st.entries = new
        st.names = b''
        st.rebuild_index()
    if not static:
        fh.get(b'staticObject').data.entries = []
    return fh.write()

# ---- passage fog (prototype, hidden setting 'passage-fog', default off)
# Dungeon Room Shuffle joins rooms that were never neighbours. Where Link can see or walk through such a join (a
# doorway without a door, 2 tiles or wider), the far side can look wrong: a neighbour cut off at its edge, another
# dungeon's floor, or black void past a door-jump doorway. The fog hangs a veil of smoke in those passages, so Link
# visibly runs into it and the shuffle reads as deliberate. Kinds:
#   'woods'          TagMysteriousWoodsFog (0x26F): the Mysterious Woods fog tag (no level places it; the game's
#                    code makes one) - plays MysteriousWoods_Fog_00 from tailor/TagMysteriousWoodsFog.drsb
#   'tailor:<entry>' TagTailorPlayer (0x1C1) playing an entry of tailor/TagTailorPlayer.drsb, e.g.
#                    'Field_12B_Effect_00' (Mabe Village chimney smoke, BdUlrira_Smoke_00)
#   'cloud'          MapFixture (0x1F8) drawing the island-vanishing cloud bank (DisappearIsland, copied at
#                    generation time from the player's actor/ObjDisappearIsland.bfres into the seed's map/)
#   'shade'          the game's own room-edge darkness, deepened on the passage's side: MapFixtures drawing Tail
#                    Cave's one-sided fade strip (DungeonFade1_05D, a 15 x 0.75 band at roof height, black at its outer
#                    edge, clear at its inner one; the seed gets a copy of the player's map/DungeonRoofLv1.bfres under
#                    that name), turned to face the doorway and stretched along the cell's whole side (strips only as
#                    wide as the doorway left hard-edged dark boxes: the strip fades in depth only), 3 layers of
#                    falling depth for a soft falloff (_shade_layers). 'shade:<depth>': the deepest layer's depth into
#                    the room (units, default 4.5), less where a fire stands near that side (_shade_room_depth). One
#                    set per side, however many passages it has
#   '<a>+<b>'        both, e.g. 'shade+tailor:Field_12B_Effect_00:5' (dark edge + smoke)
TAILOR, WOODS_FOG, MAPFIXTURE = 0x1C1, 0x26F, 0x1F8
FOG_KEY_TAG = 0x7F  # actor keys: tag << 56 | part << 40 | slot << 32 | row << 24 | col << 16 | side << 8 | n
_FOG_STEP = {'N': (0, -1), 'S': (0, 1), 'W': (-1, 0), 'E': (1, 0)}
_FOG_OPP = {'N': 'S', 'S': 'N', 'W': 'E', 'E': 'W'}
_FOG_IN = {'N': (0, 1), 'S': (0, -1), 'W': (1, 0), 'E': (-1, 0)}  # into the room
CLOUD_MODEL, CLOUD_SRC = 'DisappearIsland', 'actor/ObjDisappearIsland.bfres'
SHADE_MODEL, SHADE_SRC = 'DungeonFade1_05D', 'map/DungeonRoofLv1.bfres'
# the strip: x -7.5..7.5, z -6..-5.25 (dark at -6) at the roof actors' height (y 3); rotY turns its dark edge (-z) to
# the doorway's side
_SHADE_ROT = {'N': 0.0, 'S': 180.0, 'W': 90.0, 'E': -90.0}


def _shade_layers(depth=4.5):
    """Depths (units into the room) of the layers; each is black at the cell's edge."""
    return [depth, depth * 0.6, depth * 0.3]


def _shade_room_depth(cell, side, fires, depth):
    """The shade's depth on `side` of `cell`, stopping 0.5 short of the room's fires (sconces / lamps: TagTailorPlayer
    '*_Fire' entries) along that side: the strips sit at roof height in front of them and a flame under one isn't
    drawn (Face Shrine 08D's stand lamps 2.25 in from the edge went out). None: too shallow to bother (< 0.75)."""
    rc = cell.rsplit('_', 1)[1]
    x0, z0 = (ord(rc[2]) - ord('A')) * 15.0, (int(rc[:2]) - 1) * 12.0
    for a in fires:
        lx, lz = a.posX - x0, a.posZ - z0
        if not (-0.5 <= lx <= 15.5 and -0.5 <= lz <= 12.5):
            continue
        dist = {'N': lz, 'S': 12.0 - lz, 'W': lx, 'E': 15.0 - lx}[side]
        depth = min(depth, dist - 0.5)
    return depth if depth >= 0.75 else None


def _slot_span(slot):
    """Doorway centre and width along its edge (units) of an openings slot: half tiles, or 'w<a>-<b>' (tiles)."""
    if isinstance(slot, str):
        a, b = map(int, slot[1:].split('-'))
        return (a + b + 1) * 0.75, (b - a + 1) * 1.5
    return slot * 0.75, (1.5 if slot % 2 else 3.0)


def fog_spots(cat, level, layout, rows):
    """[(cell, side, slot, how)]: the passages that get fog. `how`: 'join' = lined-up open doorways into a room that
    wasn't this one's neighbour (both rooms get a veil at the shared edge), 'jump' = an open doorway whose door
    jump leads somewhere other than the room next door. Only doorways without a door (shutters, locks, bombable
    walls stay as they are) and at least 2 tiles wide (1-tile gaps are left alone)."""
    import dungeon_gen as g
    import rooms as rm

    def is_open(room, side, slot):
        if isinstance(slot, str):
            return True
        if slot % 2:
            return False  # a 1-tile gap
        return not any(d[0] == side and abs(d[3] - slot) <= 1 and not d[2].endswith('(mirror)')
                       for d in cat[room]['doors'] if len(d) > 3)
    out = []
    rows = [r for r in rows or () if r[0] == level]
    jumped = {('%s_%s' % (level, r[1]), r[2], int(r[3])) for r in rows}  # (a doorway with a jump row is a jump)
    pos = {g.cell_pos(c): c for c in layout}
    for cell, room in sorted(layout.items()):
        if room not in cat:
            continue
        c, r = g.cell_pos(cell)
        mine = g.openings(cat, room)
        for s in 'NSWE':
            nb = pos.get((c + _FOG_STEP[s][0], r + _FOG_STEP[s][1]))
            if not nb or not mine[s] or layout[nb] not in cat:
                continue
            other = layout[nb]
            if rm.neighbour(room, s) == other:
                continue  # the vanilla pair (moved together or never moved)
            theirs = g.openings(cat, other)[_FOG_OPP[s]]
            if [x[0] for x in mine[s]] != [x[0] for x in theirs] or not g._openings_match(mine[s], theirs):
                continue  # not lined up: door jumps (below) / sealed
            for x, y in zip(mine[s], theirs):
                if (cell, s, x[0]) in jumped or x[2] or y[2] or not is_open(room, s, x[0]) or \
                        not is_open(other, _FOG_OPP[s], y[0]):
                    continue
                out.append((cell, s, x[0], 'join'))
    for row in rows:
        cell = '%s_%s' % (level, row[1])
        side, own = row[2], int(row[3])
        room = layout.get(cell)
        if room not in cat or own not in [x[0] for x in g.openings(cat, room)[side]] or not is_open(room, side, own):
            continue
        if len(row) > 6:  # lined up with the doorway next door: the jump lands where Link would walk anyway
            c, r = g.cell_pos(cell)
            nb = pos.get((c + _FOG_STEP[side][0], r + _FOG_STEP[side][1]))
            if nb == '%s_%s' % (level, row[5]) and row[6] == _FOG_OPP[side] and int(row[4]) == own:
                continue
        if not any(o[:3] == (cell, side, own) for o in out):
            out.append((cell, side, own, 'jump'))
    return out


def fog_template(romfs, kind):
    """A vanilla actor to copy the fog actors from: Tail Cave 05A's Black_Plane tailor tag / the Wind Fish's Egg's
    BlackWall MapFixture."""
    from RandomizerCore.Tools import leb
    room, t = ('Lv09WindFishsEgg_07C', MAPFIXTURE) if kind.split(':')[0] in ('cloud', 'shade') else \
        ('Lv01TailCave_05A', TAILOR)
    p = os.path.join(romfs, 'region_common', 'level', room.split('_')[0], room + '.leb')
    for a in leb.Room(open(p, 'rb').read()).actors:
        if a.type == t:
            return a
    raise RuntimeError('no actor to copy the passage fog from')


def fog_actors(template, kind, cell, side, slot, how, room_id, part=0):
    """The fog actors for one passage of grid cell `cell` (full name, e.g. 'Lv01TailCave_04B'): emitters every ~3
    units along the opening, 0.75 inside this room's edge (a join gets a veil from each side: a band Link walks
    through), or one cloud card per opening."""
    rc = cell.rsplit('_', 1)[1]
    row, col = int(rc[:2]), ord(rc[2]) - ord('A')
    x0, z0 = col * 15.0, (row - 1) * 12.0
    along, width = _slot_span(slot)
    ix, iz = _FOG_IN[side]
    ex, ez = {'N': (x0 + along, z0), 'S': (x0 + along, z0 + 12.0), 'W': (x0, z0 + along),
              'E': (x0 + 15.0, z0 + along)}[side]
    if kind == 'cloud':
        offs = [0.0]
    elif kind.split(':')[0] == 'shade':
        offs = _shade_layers(float(kind.split(':')[1])) if ':' in kind else _shade_layers()
    else:
        n = max(1, int(round(width / 3.0)))
        offs = [(i - (n - 1) / 2.0) * width / n for i in range(n)]
        if kind.startswith('tailor:') and kind.count(':') == 2:  # 'tailor:<entry>:<n>': a veil of n emitters spread
            # along the doorway (90% of its width), 1 / 1.5 units inside it (alternately) at 0.4 scale. The plume
            # rises and drifts: from the edge (0 / 0.5 in) or past it, the doorway's wall and the dark cover of the
            # cell beyond hid it (Tail Cave 07D showed nothing; the same effect mid-floor there showed fine)
            n = max(1, min(8, int(kind.rsplit(':', 1)[1])))
            offs = [0.0] if n == 1 else [(i / (n - 1) - 0.5) * width * 0.9 for i in range(n)]
    out = []
    for i, o in enumerate(offs):
        a = copy.deepcopy(template)
        shade = kind.split(':')[0] == 'shade'
        oo = 0.0 if shade else o  # (along the edge)
        px, pz = (ex + oo, ez) if side in 'NS' else (ex, ez + oo)
        a.rotX = a.rotY = a.rotZ = 0.0
        if shade:  # one layer: the cell's whole side, o units deep
            side_len = 15.0 if side in 'NS' else 12.0
            mid, sz = side_len / 2.0 - along, o / 0.75
            px, pz = (px + mid, pz) if side in 'NS' else (px, pz + mid)
            a.scaleX, a.scaleY, a.scaleZ = side_len / 15.0, 1.0, sz
            a.posX, a.posY, a.posZ = px + 6.0 * sz * ix, 3.0, pz + 6.0 * sz * iz  # (dark edge on the cell's edge)
            a.rotY = _SHADE_ROT[side]
            a.type = MAPFIXTURE
            a.parameters = [SHADE_MODEL.encode(), 0, b'', b'', b'', b'', b'', b'']
        elif kind == 'cloud':  # a card facing the camera (+z), as wide as the opening, standing in the doorway (a
            # west / east doorway: at its front end, across the wall - it hides the doorway behind it)
            if side in 'WE':
                pz += width / 2.0
            s = (width + 1.5) / _CLOUD_W
            a.scaleX, a.scaleY, a.scaleZ = s, 0.55, s
            a.posX, a.posY, a.posZ = px + 0.75 * ix, -0.3, pz + 0.75 * iz - _CLOUD_Z * s
            a.type = MAPFIXTURE
            a.parameters = [CLOUD_MODEL.encode(), 0, b'', b'', b'', b'', b'', b'']
        else:
            dense = kind.count(':') == 2
            d = 0.75 if not dense else 1.0 + 0.5 * (i % 2)  # (into the room)
            a.posX, a.posY, a.posZ = px + d * ix, 0.0, pz + d * iz
            a.scaleX = a.scaleY = a.scaleZ = 0.4 if dense else 1.0
            if kind == 'woods':
                a.type = WOODS_FOG
                a.parameters = [b'', b'', b'', b'', b'', b'', b'', b'']
            else:
                a.type = TAILOR
                a.parameters = [kind.split(':')[1].encode(), 0, b'', b'', b'', b'', b'', b'']
        a.roomID = room_id
        sid = 0 if shade else _slot_id(slot)  # (shade: one set per side)
        a.key = (FOG_KEY_TAG << 56) | (part << 40) | (sid << 32) | (row << 24) | (col << 16) | (ord(side) << 8) | i
        prefix = {MAPFIXTURE: b'MapFixture', TAILOR: b'TagTailorPla', WOODS_FOG: b'TagMysteriou'}[a.type]
        a.name = prefix + b'-%016X' % a.key
        a.switches = [(4, 0), (4, 0), (4, 0), (4, 0)]
        rel = a.relationships
        rel.section_1, rel.section_2, rel.section_3 = [], [], []
        rel.x = rel.y = rel.z = 0
        out.append(a)
    return out


def _slot_id(slot):
    return (int(slot[1:].split('-')[0]) + 20) if isinstance(slot, str) else slot


def add_passage_fog(romfs, out, cat, level, layout, rows, kind):
    """Setting 'passage-fog' ('woods' / 'tailor:<entry>[:<n>]' / 'cloud' / 'shade[:<depth>]', or two joined with
    '+'): fog in `level`'s passages (fog_spots). Room files are the seed's (out); the cloud / shade models' files are
    copied from the player's game files. Returns the number of passages."""
    from RandomizerCore.Tools import leb
    parts = kind.split('+')
    if not all(k in ('woods', 'cloud', 'shade') or k.startswith(('tailor:', 'shade:')) for k in parts):
        return 0
    for k, model, src in (('cloud', CLOUD_MODEL, CLOUD_SRC), ('shade', SHADE_MODEL, SHADE_SRC)):
        dst = os.path.join(out, 'region_common', 'map', model + '.bfres')
        if k in [x.split(':')[0] for x in parts] and not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(os.path.join(romfs, 'region_common', src), 'rb') as f, open(dst, 'wb') as g:
                g.write(f.read())
    tpls = [fog_template(romfs, k) for k in parts]
    by_cell = {}
    for sp in fog_spots(cat, level, layout, rows):
        by_cell.setdefault(sp[0], []).append(sp)
    n = 0
    for cell, spots in sorted(by_cell.items()):
        p = os.path.join(out, 'region_common', 'level', level, cell + '.leb')
        if not os.path.exists(p):
            p0 = os.path.join(romfs, 'region_common', 'level', level, cell + '.leb')
            if not os.path.exists(p0):
                continue
            data = open(p0, 'rb').read()
        else:
            data = open(p, 'rb').read()
        r = leb.Room(data)
        room_id = next((a.roomID for a in r.actors if a.type == 0x1B6), r.actors[0].roomID if r.actors else 0)
        keys = {a.key for a in r.actors}
        fires = [a for a in r.actors if a.type == TAILOR and b'Fire' in (a.parameters[0] or b'')]
        for _, side, slot, how in spots:
            for part, (k, tpl) in enumerate(zip(parts, tpls)):
                if k.split(':')[0] == 'shade':
                    d = _shade_room_depth(cell, side, fires, float(k.split(':')[1]) if ':' in k else 4.5)
                    if d is None:
                        continue
                    k = 'shade:%g' % d
                for a in fog_actors(tpl, k, cell, side, slot, how, room_id, part):
                    if a.key not in keys:
                        r.actors.append(a)  # (appended last: no actor index shifts)
                        keys.add(a.key)
            n += 1
            print('passage fog: %s %s %s (%s)' % (cell, side, slot, how), flush=True)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'wb').write(r.repack())
    return n


if __name__ == '__main__':
    # self-test: rebuild a level from its own areas, keep starts / static objects
    base = open(sys.argv[1], 'rb').read()
    fh = fixedhash.FixedHash(base)
    names = [e.name.decode() for e in fh.get(b'area').data.entries]
    zones = fh.get(b'zone').data.entries
    unit_of = {}
    for zi, z in enumerate(zones):
        n = z.data[0x9c + 6]
        for a in z.data[0x9c + 7:0x9c + 7 + n]:
            unit_of[names[a]] = zi
    areas = {e.name.decode(): e.data for e in fh.get(b'area').data.entries}
    rooms = []
    for n in names:
        zi = unit_of.get(n)
        r = {'name': n, 'area_data': areas[n]}
        if zi is not None:
            r['unit'] = struct.unpack_from('<I', zones[zi].data, 0)[0]  # keep zone ids (static objects use them)
            r['zone_data'] = zones[zi].data
            r['fixed'] = zones[zi].data[0x9c + 4] != 3  # side-view: keep area + zone as they are
        else:
            r['unit'] = n
        rooms.append(r)
    out = build(base, rooms, keep_tree=len(sys.argv) > 3)
    open(sys.argv[2], 'wb').write(out)
    print('ok', len(rooms), 'rooms', len(out), 'bytes')
