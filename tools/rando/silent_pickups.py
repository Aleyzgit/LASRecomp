#!/usr/bin/env python3
"""Silent pickups (prototype): minor items picked up outside the dungeons skip the item-get cutscene.

Pieces of Heart, Heart Containers, Secret Seashells, recovery hearts and rupees that Link picks up from the ground -
the item actors of SinkingSword.bfevfl: standing items, pots, bushes, digs, Secret Seashell spots, tree / bomb-hole
fly-outs - are given without Link.GenericItemGetSequenceByKey (Link holding it up, "duh duh duh", the message box).
The runtime shows a small fly-in instead (runtime/hle/silent_pickups.c, runtime/ui/pickup_flyin.mm): Heart pieces
towards a full heart, the seashell count, "+1 heart" (and a refill) for a container, the rupees' value.

Only entries outside a dungeon (an entry point not named D<n>-..., LAS's dungeon locations) change; small keys,
dungeon items (maps, compasses, beaks, Nightmare Keys), Triforce pieces, souls, capacity upgrades, refills (their "nowhere
to put it" message) and every inventory / progression item keep the cutscene, and chests (TreasureBox.bfevfl) are
untouched. Shared chains (pots / digs give one chain per distinct item to every location holding it) that a dungeon
entry also runs are copied for the overworld entries.

The give itself stays the same Inventory.AddItemByKey (flags, the save, the heart-piece-to-container count all work
as before); the fly-in items carry index SILENT_BASE + 1 + their index, which the runtime's AddItem hook
(runtime/hle/keysanity.c rt_add_item -> rt_silent_add) turns back before the game adds it.

Runs after every other flow edit (keysanity_text, refill_gets, bomb / powder bag text).

The game's own item actors (ItemCommon.bfevfl: a Secret Seashell buried on a digsanity tile, at a Seashell spot, the
vanilla shells) get the same for Secret Seashells: patch_item_common.

    apply(out_dir, romfs) -> (gets made silent, chains copied, ItemCommon entries changed)
"""
import os
import re

SILENT_BASE = 3000  # (runtime/hle/silent_pickups.c)
FLYIN = ('HeartPiece', 'HeartContainer', 'Seashell')  # (and every Rupee*)
QUIET = ('Heart',)  # silent, no fly-in (the HUD hearts show it)
DUNGEON = re.compile(r'D\d-')


def _action(e):
    d = e.data
    if type(d).__name__ != 'ActionEvent':
        return None, None, None
    return d.actor.v.identifier.name, d.actor_action.v.v, d.params.data if d.params else {}


def _flyin(key):
    return key in FLYIN or key.startswith('Rupee')


def _wanted(key):
    return isinstance(key, str) and (_flyin(key) or key in QUIET)


def _next(e):
    d = e.data
    t = type(d).__name__
    if t == 'SwitchEvent':
        return [c.v for c in d.cases.values()]
    if t == 'ForkEvent':
        return [f.v for f in d.forks]
    return [d.nxt.v] if hasattr(d, 'nxt') else []


def _mark(params):
    idx = params.get('index', -1)
    if isinstance(idx, int) and _flyin(params.get('itemKey')) and -1 <= idx < 1000:
        params['index'] = SILENT_BASE + 1 + idx


def patch(fc, event_tools):
    """one flowchart (SinkingSword.bfevfl): returns (gets made silent, chains copied)"""
    # which entries reach each event: silent (outside a dungeon) / kept
    reach = {}
    for ep in fc.entry_points:
        kind = 'keep' if DUNGEON.match(ep.name) else 'silent'
        todo, seen = [ep.main_event.v], set()
        while todo:
            e = todo.pop()
            if e is None or id(e) in seen:
                continue
            seen.add(id(e))
            reach.setdefault(id(e), set()).add(kind)
            todo.extend(_next(e))

    def shared(e):
        return 'keep' in reach.get(id(e), ())

    n_silent, n_copied, done, copies = 0, 0, set(), {}
    for ep in fc.entry_points:
        if DUNGEON.match(ep.name):
            continue
        path, e = [], ep.main_event.v  # the straight chain up to the first wanted AddItemByKey
        add = None
        while e is not None and len(path) < 16:
            actor, act, prm = _action(e)
            if actor is None:
                break
            path.append(e)
            if act == 'AddItemByKey' and _wanted(prm.get('itemKey')):
                add = e
                break
            e = e.data.nxt.v
        if add is None or id(add) in done:
            continue
        key = _action(add)[2]['itemKey']
        gets = [g for g in path if _action(g)[1] == 'GenericItemGetSequenceByKey' and _action(g)[2].get('itemKey') == key]
        if not gets and not _flyin(key):
            continue  # (already silent, nothing to show)
        p = next((i for i, x in enumerate(path) if shared(x)), None)
        if p is None:  # only overworld entries run it: in place
            for g in gets:
                nxt = g.data.nxt.v
                for x in fc.events:
                    if type(x.data).__name__ in ('ActionEvent', 'SubFlowEvent', 'JoinEvent') and x.data.nxt.v is g:
                        x.data.nxt.v = nxt
                    elif type(x.data).__name__ == 'SwitchEvent':
                        for c in x.data.cases.values():
                            if c.v is g:
                                c.v = nxt
                for q in fc.entry_points:
                    if q.main_event.v is g:
                        q.main_event.v = nxt
            _mark(_action(add)[2])
            done.add(id(add))
            n_silent += 1
            continue
        # a dungeon entry runs it too: this entry gets its own copy from the first shared event on
        head = copies.get(id(path[p]))
        if head is None:
            nxt = add.data.nxt.v.name if add.data.nxt.v is not None else None
            for x in reversed(path[p:]):
                actor, act, prm = _action(x)
                if x in gets:
                    continue
                prm = dict(prm)
                if x is add:
                    _mark(prm)
                nxt = event_tools.createActionEvent(fc, actor, act, prm, nxt)
            head = copies[id(path[p])] = event_tools.findEvent(fc, nxt)
            n_copied += 1
            n_silent += 1
        if p == 0:
            ep.main_event.v = head
        else:
            path[p - 1].data.nxt.v = head
    return n_silent, n_copied


MARK_FLAG = 'unused0432'  # set around the add of a native Secret Seashell (runtime/hle/silent_pickups.c MARK_FLAG)


def patch_item_common(fc, event_tools):
    """ItemCommon.bfevfl 'get' (the game's own item actors: a Secret Seashell buried on a digsanity tile or at a
    Seashell spot, the vanilla shells): Deactivate -> PlayTailorGettingChannel -> GenericItemGetSequenceByKey ->
    AddItemByKey -> Destroy, all with the actor's itemKey / itemCount / itemIndex. A Secret Seashell skips the jingle
    and the get sequence; its add is marked (MARK_FLAG) for the runtime's fly-in. Returns the number of entries changed."""
    n = 0
    for ep in fc.entry_points:
        first = ep.main_event.v
        actor, act, _ = _action(first) if first is not None else (None, None, None)
        if act != 'Deactivate':
            continue
        chain, e = [], first.data.nxt.v
        while e is not None and _action(e)[0] is not None and len(chain) < 8:
            chain.append(e)
            e = e.data.nxt.v
        add = next((x for x in chain if _action(x)[1] == 'AddItemByKey'), None)
        if add is None or not any(_action(x)[1] == 'GenericItemGetSequenceByKey' for x in chain):
            continue
        prm = dict(_action(add)[2])
        after = add.data.nxt.v.name if add.data.nxt.v is not None else None
        off = event_tools.createActionEvent(fc, 'EventFlags', 'SetFlag', {'symbol': MARK_FLAG, 'value': False}, after)
        give = event_tools.createActionEvent(fc, 'Inventory', 'AddItemByKey', prm, off)
        on = event_tools.createActionEvent(fc, 'EventFlags', 'SetFlag', {'symbol': MARK_FLAG, 'value': True}, give)
        sw = event_tools.createSwitchEvent(fc, 'FlowControl', 'CompareString', {'value1': 'itemKey', 'value2': 'Seashell'},
                                           {0: on, 1: chain[0].name})
        first.data.nxt.v = event_tools.findEvent(fc, sw)
        n += 1
    return n


def _flow(out_dir, romfs, name, fn, event_tools):
    rel = os.path.join('region_common', 'event', name)
    p = os.path.join(out_dir, 'romfs', rel)
    if not os.path.exists(p):
        p = os.path.join(romfs, rel)
    flow = event_tools.readFlow(p)
    n = fn(flow.flowchart, event_tools)
    out = os.path.join(out_dir, 'romfs', rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    event_tools.writeFlow(out, flow)
    return n


def apply(out_dir, romfs):
    """-> (SinkingSword gets made silent, chains copied, ItemCommon entries changed)"""
    from RandomizerCore.Tools import event_tools
    n, copied = _flow(out_dir, romfs, 'SinkingSword.bfevfl', patch, event_tools)
    return n, copied, _flow(out_dir, romfs, 'ItemCommon.bfevfl', patch_item_common, event_tools)
