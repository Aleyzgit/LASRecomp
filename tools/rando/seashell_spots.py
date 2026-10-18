#!/usr/bin/env python3
"""Secret Seashell spots as real checks: every place the original game hides a Secret Seashell - dug up with the
shovel (LAS subtype 'dig', 14), under a bush / rock / pot or in a tree Link dashes into ('hidden', 15), in a hole a
bomb goes into ('bomb-hole', 2) - holds a randomized item (LAS-Randomizer kept them vanilla: shuffler.py's
vanilla_locations). Logic: LAS's own conditions (shovel, bracelet, boots, bombs, ...).

In the game each one is the Secret Seashell actor (ItemSecretSeashell 0x87, parameter 0 = its seashell index):
  dig    placed in the room file, buried until the shovel digs its tile
  drop   spawned by the bush / rock / pot / tree / bomb hole through ItemDrop.gsheet's Seashell<n> entry (the item
         appears where the shell would; out of a tree - the shell falls out of its crown - or a bomb hole - it jumps out -
         on a free tile beside it)
The runtime (runtime/hle/shell_spots.c) turns it into the seed's item: a SinkingSword item actor (the actor LAS uses
for standing items) with the item's model, comes up out of the dug hole / drops where the shell would. Picking it up
runs its entry in SinkingSword.bfevfl - LAS's item-get, the game's message box - and sets the spot's own flag.

rando/<seed>/shell_spots.tsv: location, seashell index, kind (dig / drop / land: lands at x y z - trees, bomb holes), level, room, x, y, z, model path, model
name, flow entry, flag symbol, flag index, seashell (1/0), scale, turn.

Bushsanity / potsanity leave the bushes and the pot holding a Secret Seashell out (their check is this one), and
digsanity the buried shells' tiles (shell_tiles): one check per spot.

    apply(locations(logic_defs), mods, out_dir, romfs, leb, event_tools, oead_tools, item_get, data) -> spoiler lines
"""
import glob
import os
import re

import seed_tables

SUBTYPES = ('dig', 'hidden', 'bomb-hole')
T_SHELL = 0x87
T_SHELL_DROP_AREA = 0x233  # AreaShellDrop: the bomb holes (parameter 0 = the seashell index)
BURIED_LEVELS = ('Field', 'DogHouse')  # (levels whose rooms place a buried Secret Seashell)
LAWN = 0xb5  # ObjLawn: tall grass (an item may land in it)
TREES = (0xbb, 0xbc)  # ObjTree, ObjPalmTree: the shell falls out when Link dashes into one (Pegasus Boots)
DROP_KEY = re.compile(rb'Seashell(\d+)$')  # a bush's / rock's / tree's / pot's ItemDrop key


def locations(logic_defs):
    """{location: seashell index} of the Secret Seashell spots."""
    return {k: int(v['index']) for k, v in logic_defs.items()
            if v.get('type') == 'item' and v.get('subtype') in SUBTYPES and v.get('content') == 'seashell'
            and 'index' in v}


def _rooms(romfs, leb, levels=None):
    pat = os.path.join(romfs, 'region_common', 'level', '*', '*.leb')
    for f in sorted(glob.glob(pat)):
        level = os.path.basename(os.path.dirname(f))
        if levels and level not in levels:
            continue
        with open(f, 'rb') as fh:
            yield level, os.path.basename(f)[:-4], leb.Room(fh.read())


def _landing(romfs, leb, room, host, tree):
    """Where the item of a tree (ObjTree / ObjPalmTree: the shell falls out of its crown) or a bomb hole (the shell pops
    out of it) lands - the item doesn't fall or jump: the nearest free tile around (a tree stands on the corner of 2 x 2
    tiles, a hole is one), in front - toward the camera - first, at most 2 units above / below the host. None: none."""
    with open(os.path.join(romfs, 'region_common', 'level', 'Field', room + '.leb'), 'rb') as fh:
        r = leb.Room(fh.read(), edit_grid=True)
    m = re.match(r'Field_(\d\d)([A-P])$', room)
    ox, oz = (ord(m.group(2)) - 65) * 15.0, (int(m.group(1)) - 1) * 12.0
    if tree:  # (tiles x0..x1, z0..z1 under the host)
        cx, cz = round((host.posX - ox) / 1.5), round((host.posZ - oz) / 1.5)
        x0, x1, z0, z1 = cx - 1, cx, cz - 1, cz
    else:
        x0 = x1 = int((host.posX - ox) // 1.5)
        z0 = z1 = int((host.posZ - oz) // 1.5)
    taken = {(int((a.posX - ox) // 1.5), int((a.posZ - oz) // 1.5)) for a in r.actors
             if a is not host and a.type != LAWN and not a.name.startswith((b'Enemy', b'Tag', b'Area', b'Item'))}
    cands = []
    for ring in (1, 2):
        for tz in range(z0 - ring, z1 + ring + 1):
            for tx in range(x0 - ring, x1 + ring + 1):
                if max(x0 - tx, tx - x1, z0 - tz, tz - z1) == ring:
                    dx, dz = tx - (x0 + x1) / 2, tz - (z0 + z1) / 2
                    cands.append((ring, -dz, abs(dx), tx, tz))  # (nearest ring, then south, then centred)
    for _, _, _, tx, tz in sorted(cands):
        if not (0 <= tx < 10 and 0 <= tz < 8) or (tx, tz) in taken:
            continue
        t = r.grid.tilesdata[tz * 10 + tx]
        if t.flags1['containscollision'] or t.flags3['iswaterlava'] or t.flags1['deepwaterlava'] \
                or abs(t.elevation - host.posY) > 2.0:
            continue
        return ox + tx * 1.5 + 0.75, t.elevation, oz + tz * 1.5 + 0.75
    return None


def scan(romfs, leb):
    """{seashell index: (kind, level, room, x, y, z)}: the buried shells (dig: where), what drops the others (drop:
    the host's position; the item appears where the shell would), the trees and bomb holes (land: where the item lands)."""
    out = {}
    for level, room, r in _rooms(romfs, leb):
        for a in r.actors:
            if a.type == T_SHELL and level in BURIED_LEVELS and isinstance(a.parameters[0], int):
                out[a.parameters[0]] = ('dig', level, room, a.posX, a.posY, a.posZ)
            elif a.type == T_SHELL_DROP_AREA and isinstance(a.parameters[0], int):
                spot = _landing(romfs, leb, room, a, False)
                if not spot:
                    raise RuntimeError(f'{room}: no free tile beside the bomb hole {a.name}')
                out.setdefault(a.parameters[0], ('land', level, room) + spot)
            else:
                for p in a.parameters[:2]:
                    m = isinstance(p, bytes) and DROP_KEY.match(p)
                    if not m:
                        continue
                    spot = a.type in TREES and level == 'Field' and _landing(romfs, leb, room, a, True)
                    if a.type in TREES and not spot:
                        raise RuntimeError(f'{room}: no free tile beside the tree {a.name}')
                    out.setdefault(int(m.group(1)), ('land', level, room) + spot if spot else
                                   ('drop', level, room, a.posX, a.posY, a.posZ))
    return out


def holds_shell(actor):
    """A bush / pot whose drop is a Secret Seashell (bushes.py / pots.py leave it out: its check is this one)."""
    return any(isinstance(p, bytes) and DROP_KEY.match(p) for p in actor.parameters[:2])


def apply(locs, mods, out_dir, romfs, leb, event_tools, oead_tools, item_get, data):
    """locs: locations(logic_defs)."""
    common_out = os.path.join(out_dir, 'romfs', 'region_common')
    common_in = os.path.join(romfs, 'region_common')

    def path(rel):
        p = os.path.join(common_out, rel)
        return p if os.path.exists(p) else os.path.join(common_in, rel)

    def out(rel):
        p = os.path.join(common_out, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    spots = scan(romfs, leb)
    missing = [k for k, i in locs.items() if i not in spots]
    if missing:
        raise RuntimeError(f'Secret Seashell spots not found in the rooms: {missing}')

    sheet = oead_tools.readSheet(path('datasheets/GlobalFlags.gsheet'))
    names = {str(v['symbol']): int(v['index']) for v in sheet['values']}
    flow = event_tools.readFlow(path('event/SinkingSword.bfevfl'))
    rows = ['# location\tindex\tkind\tlevel\troom\tx\ty\tz\tmodel\tname\tentry\tflag\tflag index\tshell\tscale\tturn'
            '  (tools/rando/seashell_spots.py)\n']
    checks, spoiler = [], []
    for name, index in sorted(locs.items(), key=lambda kv: kv[1]):
        if name not in mods.placements:
            continue
        flag = f'LARShellSpot{index}'
        if flag not in names:
            names[flag] = seed_tables.next_flag(sheet, out_dir)
            sheet['values'].append({'symbol': flag, 'index': names[flag]})
        item_key, item_index, model_path, model_name = mods.getItemInfo(name, mods.trap_models)
        if item_key[:3] == 'Rup':
            get_anim = event_tools.createActionEvent(flow.flowchart, 'Inventory', 'AddItemByKey',
                                                     {'itemKey': item_key, 'count': 1, 'index': item_index,
                                                      'autoEquip': False})
        else:
            get_anim = item_get.insertItemGetAnimation(flow.flowchart, item_key, item_index)
        event_tools.addEntryPoint(flow.flowchart, name)
        event_tools.createActionChain(flow.flowchart, name, [  # (the flag first: found, whatever the get does)
            ('EventFlags', 'SetFlag', {'symbol': flag, 'value': True}),
            ('SinkingSword', 'Destroy', {})], get_anim)
        kind, level, room, x, y, z = spots[index]
        rows.append('\t'.join(str(v) for v in (
            name, index, kind, level, room, f'{x:g}', f'{y:g}', f'{z:g}', model_path, model_name, name, flag,
            names[flag], 1 if item_key == 'Seashell' else 0, f'{data.MODEL_SIZES.get(model_name, 1.0):g}',
            f'{data.MODEL_ROTATIONS.get(model_name, 0):g}')) + '\n')
        checks.append(f'{name}\t{names[flag]}\n')
        spoiler.append(f'{name}: {mods.placements[name]}')
    oead_tools.writeSheet(out('datasheets/GlobalFlags.gsheet'), sheet)
    event_tools.writeFlow(out('event/SinkingSword.bfevfl'), flow)
    with open(os.path.join(out_dir, 'shell_spots.tsv'), 'w') as f:
        f.writelines(rows)
    with open(os.path.join(out_dir, 'check_flags.tsv'), 'a') as f:  # tracker.py: location -> found flag
        f.writelines(checks)
    return spoiler
