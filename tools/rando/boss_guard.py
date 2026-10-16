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

# boss type -> its event flow, the actor in it, and what an overworld copy (switch 2 set) skips there:
#   item: (the event LAS's item get follows, the event after it) - the dungeon boss's check isn't given again
#   start: its Start entry - only shows itself (no camera, text, title card or music) and fights at once, like any
#          enemy; the dungeon's boss keeps its intro
#   end: (its End entry, the actions it plays instead) - no boss item drop, doors, fanfare or autosave
#   quiet: {entry: the event it goes on to} - mid-fight entries that also show text skip to their own animation
GUARDS = {
    0x63: dict(flow='DeguTail.bfevfl', actor='DeguTail', item=('Event8', 'Event45'), start='DeguTailStart'),  # Moldorm
    0x68: dict(flow='MatFace.bfevfl', actor='MatFace', item=('Event8', 'Event35'), start='MatFaceStart'),     # Facade
    0x62: dict(flow='DonPawn.bfevfl', actor='DonPawn', start='DonPawnStart',  # Hardhit Beetle (the Evil Orb)
               end=('DonPawnEnd', [('PlayAnimation', {'name': 'dead', 'blendTime': 0.1}),
                                   ('PlayTailorOtherChannelEx', {'channel': 'Dead_Boss', 'time': 4.0, 'restart': False,
                                                                 'index': 0}),
                                   ('ModelVisibility', {'modelIndex': 0, 'visible': False})]),
               quiet={'DonPawnBattle1': 'Event49', 'DonPawnBattle2': 'Event46'}),
}
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
        g = GUARDS[t]
        actor = g['actor']
        flow = event_tools.readFlow(path(f"event/{g['flow']}"))
        fc = flow.flowchart

        def guard(entry, overworld):  # (the entry's first event when switch 2 isn't set, `overworld` when it is)
            ep = next(e for e in fc.entry_points if e.name == entry)
            sw = event_tools.createSwitchEvent(fc, actor, 'CheckSawTheFirstEvent', {'switchIndex': 2},
                                               {0: ep.main_event.v.name, 1: overworld})
            event_tools.insertEventAfter(fc, entry, sw)

        if 'item' in g:
            before, after = g['item']
            first = event_tools.findEvent(fc, before).data.nxt.v.name  # (LAS's item get, inserted after `before`)
            sw = event_tools.createSwitchEvent(fc, actor, 'CheckSawTheFirstEvent', {'switchIndex': 2},
                                               {0: first, 1: after})
            event_tools.insertEventAfter(fc, before, sw)
        guard(g['start'], event_tools.createActionEvent(fc, actor, 'ModelVisibility', {'modelIndex': 0, 'visible': True}))
        if 'end' in g:
            entry, acts = g['end']
            nxt = None
            for action, params in reversed(acts):
                nxt = event_tools.createActionEvent(fc, actor, action, params, nxt)
            guard(entry, nxt)
        for entry, to in g.get('quiet', {}).items():
            guard(entry, to)
        os.makedirs(os.path.join(common_out, 'event'), exist_ok=True)
        event_tools.writeFlow(os.path.join(common_out, f"event/{g['flow']}"), flow)
    return f'{len(rooms)} rooms, marker flag {idx}'
