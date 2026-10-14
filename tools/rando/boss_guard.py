#!/usr/bin/env python3
"""Bosses on the overworld (enemy randomizer "Include bosses", RandomizerCore enemies.FIELD_BOSSES) share their event
flow with their dungeon's boss, and LAS gives the dungeon's boss check in that flow's end event (mod_generator
moldormChanges...). An overworld copy beaten must not give that item again: its actor gets switch 2 = a new global
flag (OverworldBossMarker) that the runtime sets when it arms an overworld boss (runtime/hle/miniboss.c, settings.json
"boss-marker-flag"); each boss's end event first asks CheckSawTheFirstEvent(switchIndex 2) - the dungeon's boss has no
switch 2 (0: the item, as before), an overworld one has the set marker (1: straight past the item get).

    apply(out_dir, romfs, leb, event_tools, oead_tools, settings) -> summary
"""
import os

# boss type -> (event flow, actor name in it, the event the item get follows, the event after it, start entry)
GUARDS = {
    0x63: ('DeguTail.bfevfl', 'DeguTail', 'Event8', 'Event45', 'DeguTailStart'),  # Moldorm (mod_generator.moldormChanges)
    0x68: ('MatFace.bfevfl', 'MatFace', 'Event8', 'Event35', 'MatFaceStart'),     # Facade (mod_generator.facadeChanges)
}
# The same switch heads each boss's Start entry: an overworld copy skips its intro (no camera, text, title card or
# music: it only shows itself) and fights at once, like any enemy; the dungeon's boss keeps its intro.
MARKER = 'OverworldBossMarker'


def apply(out_dir, romfs, leb, event_tools, oead_tools, settings):
    common_out = os.path.join(out_dir, 'romfs', 'region_common')
    common_in = os.path.join(romfs, 'region_common')

    def path(rel):
        p = os.path.join(common_out, rel)
        return p if os.path.exists(p) else os.path.join(common_in, rel)

    field = os.path.join(common_out, 'level', 'Field')
    rooms = []
    for f in sorted(os.listdir(field)) if os.path.isdir(field) else []:
        if not f.endswith('.leb'):
            continue
        room = leb.Room(open(os.path.join(field, f), 'rb').read())
        if any(a.type in GUARDS for a in room.actors):
            rooms.append((f, room))
    if not rooms:
        return 'no overworld bosses'
    # the marker flag (after every other flag: existing indices stay)
    rel = 'datasheets/GlobalFlags.gsheet'
    sheet = oead_tools.readSheet(path(rel))
    have = {str(v['symbol']): int(v['index']) for v in sheet['values']}
    if MARKER in have:
        idx = have[MARKER]
    else:
        idx = max(i for i in have.values() if i < 2048) + 1
        if idx >= 2048:
            raise RuntimeError('out of GlobalFlags indices for the overworld boss marker')
        sheet['values'].append({'symbol': MARKER, 'index': idx})
        os.makedirs(os.path.join(common_out, 'datasheets'), exist_ok=True)
        oead_tools.writeSheet(os.path.join(common_out, rel), sheet)
    settings['boss-marker-flag'] = idx
    kinds = set()
    for f, room in rooms:
        for a in room.actors:
            if a.type in GUARDS:
                sw = list(a.switches)
                sw[2] = (1, idx)
                a.switches = sw
                kinds.add(a.type)
        with open(os.path.join(field, f), 'wb') as fh:
            fh.write(room.repack())
    for t in sorted(kinds):
        name, actor, before, after, start = GUARDS[t]
        flow = event_tools.readFlow(path(f'event/{name}'))
        fc = flow.flowchart
        first = event_tools.findEvent(fc, before).data.nxt.v.name  # (LAS's item get, inserted after `before`)
        sw = event_tools.createSwitchEvent(fc, actor, 'CheckSawTheFirstEvent', {'switchIndex': 2},
                                           {0: first, 1: after})
        event_tools.insertEventAfter(fc, before, sw)
        ep = next(e for e in fc.entry_points if e.name == start)
        intro = ep.main_event.v.name
        show = event_tools.createActionEvent(fc, actor, 'ModelVisibility', {'modelIndex': 0, 'visible': True})
        sw2 = event_tools.createSwitchEvent(fc, actor, 'CheckSawTheFirstEvent', {'switchIndex': 2}, {0: intro, 1: show})
        event_tools.insertEventAfter(fc, start, sw2)
        os.makedirs(os.path.join(common_out, 'event'), exist_ok=True)
        event_tools.writeFlow(os.path.join(common_out, f'event/{name}'), flow)
    return f'{len(rooms)} rooms, marker flag {idx}'
