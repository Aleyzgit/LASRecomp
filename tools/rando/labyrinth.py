#!/usr/bin/env python3
"""Labyrinth (a Dungeon room shuffle option, request "dungeon-labyrinth"; user design 2026-10-09 / 2026-10-19).

Every dungeon becomes a wing of one big shuffled dungeon: the Color Dungeon is wing 0, dungeons 1-8 wings 1-8. It's
not a mode of its own - it interconnects the dungeons, each room shuffle mode keeps its rules:

  Coherent   doorways pair sensibly (north with south, west with east), two ways
  Chaos      any doorway with any doorway, two ways
  Madness    one-way: every doorway leads out somewhere and is where some other doorway leads in

  wings      each level is built by the Chaos placer (dungeon_gen.chaos_place: rooms joined physically where their
             doorways line up, every other doorway free) - Coherent's own placer closes every doorway and would leave
             nothing to link across wings. The free doorways of ALL wings are then paired together: a spanning tree
             through every piece of every wing (pieces of one wing link to each other, a share CROSS to another wing;
             the first piece of each wing always links to another wing), the rest within the wing, a share across.
             A doorway paired into another level is a level load (runtime: stage 2): its rows carry the target level
             (dungeon_gen.is_cross) and go to labyrinth_links.tsv, never door_jumps.tsv.
  Eagle's    kept whole (its rooms, pillars and collapse stay as they are; it isn't rebuilt). Its doorway out (08B
  Tower      south, to the overworld in the game) is one of the Labyrinth's free doorways: it leads into another wing,
             and that wing's doorway leads back into Eagle's Tower at its entrance (ET_START).
  doors      every overworld dungeon door (but Eagle's Tower's) leads into some room of the Labyrinth (pick_arrivals: any
             wing, any room but boss / mini-boss arenas, the instrument rooms and cells behind boss doors), arriving at
             one of its doorways. A wing whose entrance room no door leads to is reachable only through another wing;
             its entrance room's way out still leads to the overworld.
  keys       one shared small-key counter: the pool's small keys are all key-D1 (room_logic.SHARED_KEY_N), every lock
             of every wing takes them, the worst-case key rule runs over the whole Labyrinth. Keysanity off: anywhere in
             the Labyrinth; on: anywhere, as keysanity says.
  items      maps, compasses, Nightmare Keys and stone beaks stay per wing (dungeon-of: the wing a check is in now);
             their get text names the wing ("... for Wing 2 of the labyrinth!", keysanity_text.py).
  logic      one graph across every wing (room_logic.labyrinth_graph / apply(lab=...)): reachability, keys, boss doors
             (labyrinth_boss_ok: only the boss and instrument behind each boss door) and the fill check
             (labyrinth_fill_ok) all follow the cross-wing links.

    plan(cat, seed, romfs, mode, settings, et_locks) -> (layouts, rows, info)
"""
import json
import os
import random
import re

HERE = os.path.dirname(os.path.abspath(__file__))

import dungeon_gen as dg  # noqa: E402
import room_logic as rl  # noqa: E402
import rooms  # noqa: E402

ET = rl.ET_LEVEL
ET_CELL = ET + '_08B'
ET_STUB = (None, ET_CELL, 'S', 10)  # Eagle's Tower's way out: 08B's south doorway (AreaLevelOpen 'DungeonOut')
ET_START = 'Lv07EagleTower_08B_b'   # where its overworld door arrives (Field_01O) - and a doorway linked to its way out
# Share of the spanning tree's links (and of the other pairs, half that) that go to another wing. Every cross-wing
# doorway is a level load in the game, so most pairs stay within their wing.
CROSS = float(os.environ.get('LARECOMP_LAB_CROSS', 0.3))
OPP = rooms.OPP


def wing(level):
    return rl.LEVELS[level][0]


def level_of(stub):
    return rooms.level_of(stub[1])


def short(cell):
    return cell.rsplit('_', 1)[1]


# ---------------------------------------------------------------- doorway rows
def lab_row(cat, layouts, romfs, x, y):
    """door_jumps row out of stub x, in at stub y (dungeon_gen._jump_row), + the target level when it's another one."""
    lx, ly = level_of(x), level_of(y)
    if ly == ET:  # (arrives at ET_START, Eagle's Tower's own entrance)
        depth, height = 0.0, -100.0
    else:
        room = layouts[ly][y[1]]
        own = any(not d[2].endswith('(mirror)') and d[0] == y[2] and abs(d[3] - y[3]) <= 1
                  for d in cat[room]['doors'] if len(d) > 3)
        depth, height = dg.landing_depth(romfs, room, y[2], y[3], 1 if own else 0) if romfs else (2.2, 0.0)
    row = (lx, short(x[1]), x[2], x[3], y[3], short(y[1]), y[2], depth, height)
    return row + (ly,) if lx != ly else row


def with_followers(cat, layouts, romfs, follow, links):
    """links {stub: target stub} -> rows, + the rows of a cell side's other free doorways (they go where its paired
    one goes; a side leading back into itself - a wall - stays one)."""
    rows = [lab_row(cat, layouts, romfs, x, y) for x, y in links.items()]
    for (cell, s), xs in sorted(follow.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        lead = next((x for x in links if x[1] == cell and x[2] == s), None)
        if lead is None:
            continue
        tgt = links[lead]
        for x in xs:
            rows.append(lab_row(cat, layouts, romfs, x, x if tgt == lead else tgt))
    return rows


# ---------------------------------------------------------------- pairing
def _pair_list(stubs, rng, coherent):
    """Pairs within a list (Coherent: north-south / west-east only) -> (pairs, leftovers)."""
    if not coherent:
        pairs = [(stubs[i], stubs[i + 1]) for i in range(0, len(stubs) - 1, 2)]
        return pairs, stubs[len(pairs) * 2:]
    pairs, left = [], []
    for a, b in (('N', 'S'), ('W', 'E')):
        xs, ys = [s for s in stubs if s[2] == a], [s for s in stubs if s[2] == b]
        k = min(len(xs), len(ys))
        pairs += list(zip(xs[:k], ys[:k]))
        left += xs[k:] + ys[k:]
    return pairs, left


def pair_two_way(pieces, rng, coherent):
    """Coherent / Chaos: {piece: [stubs]} -> [(stub, stub)] (a stub paired with itself: a wall), or None."""
    keys = sorted(pieces, key=str)
    rng.shuffle(keys)
    keys.sort(key=lambda k: -len(pieces[k]))
    for v in pieces.values():
        rng.shuffle(v)
    linked, pairs = [keys[0]], []
    for k in keys[1:]:
        if not pieces[k]:
            return None
        cand = [q for q in linked if pieces[q]]
        same = [q for q in cand if q[0] == k[0]]
        other = [q for q in cand if q[0] != k[0]]
        groups = [other, same] if not same or rng.random() < CROSS else [same, other]
        for g in groups:
            if coherent:
                opts = [(q, a, b) for q in g for a in pieces[q] for b in pieces[k] if OPP[a[2]] == b[2]]
            else:
                opts = [(q, pieces[q][-1], pieces[k][-1]) for q in g]
            if not opts:
                continue
            most = max(len(pieces[o[0]]) for o in opts)
            q, a, b = rng.choice([o for o in opts if len(pieces[o[0]]) == most])
            pieces[q].remove(a)
            pieces[k].remove(b)
            pairs.append((a, b))
            break
        else:
            return None
        linked.append(k)
    tree = len(pairs)
    # the rest: within the wing (a share goes across), then what's left across
    by_level, across = {}, []
    rest = [x for k in keys for x in pieces[k]]
    rng.shuffle(rest)
    for x in rest:
        (across if rng.random() < CROSS / 2 else by_level.setdefault(level_of(x), [])).append(x)
    for lv in sorted(by_level):
        p, left = _pair_list(by_level[lv], rng, coherent)
        pairs += p
        across += left
    rng.shuffle(across)
    p, left = _pair_list(across, rng, coherent)
    pairs += p
    # a room never leads into itself: swap partners between the extra pairs (sides kept: Coherent stays sensible)
    for i in range(tree, len(pairs)):
        a, b = pairs[i]
        if a[1] != b[1]:
            continue
        for j in range(tree, len(pairs)):
            c, d = pairs[j]
            if c[2] != a[2]:
                c, d = d, c
            if j != i and c[2] == a[2] and c[1] != b[1] and d[1] != a[1]:
                pairs[i], pairs[j] = (a, d), (c, b)
                break
    return pairs + [(x, x) for x in left]  # (odd ones out: back into their own doorway - a wall)


def pair_madness(pieces, rng):
    """Madness: {stub: target stub}, a permutation of the free doorways. A ring through every piece (wing by wing,
    the wings in random order) keeps the Labyrinth reachable and escapable everywhere; the rest at random, within the
    wing mostly, never into the room it leaves."""
    by_wing = {}
    for k in sorted(pieces, key=str):
        if not pieces[k]:
            return None
        by_wing.setdefault(k[0], []).append(k)
    wings = sorted(by_wing)
    rng.shuffle(wings)
    ring = []
    for w in wings:
        ks = by_wing[w]
        rng.shuffle(ks)
        ring += ks
    exits, arrivals = {}, {}
    for k in ring:
        v = pieces[k][:]
        rng.shuffle(v)
        exits[k], arrivals[k] = v[0], v[-1]
    link = {}
    if len(ring) > 1:
        for i, k in enumerate(ring):
            link[exits[k]] = arrivals[ring[(i + 1) % len(ring)]]
    stubs = [x for k in ring for x in pieces[k]]
    free_out = [x for x in stubs if x not in link]
    taken = set(link.values())
    free_in = [x for x in stubs if x not in taken]
    rng.shuffle(free_in)
    for a in free_out:  # (same wing first, a share across; never into its own room)
        same = [y for y in free_in if level_of(y) == level_of(a) and y[1] != a[1]]
        other = [y for y in free_in if y[1] != a[1]]
        pick = same if same and rng.random() >= CROSS / 2 else other or same
        y = pick[0] if pick else free_in[0]
        free_in.remove(y)
        link[a] = y
    return link


# ---------------------------------------------------------------- overworld doors
def door_regions(levels):
    return {lv: rl.LEVELS[lv][1] for lv in levels}


def pick_arrivals(cat, layouts, rng, romfs):
    """{door region: (level, cell, side, slot, depth, height, start)}: where each overworld dungeon door (but Eagle's
    Tower's) arrives - a doorway of a room of any wing, no two doors in one room. start: the start point the game puts
    Link at - the dungeon's own entrance start for an entrance room, else a new one ('LabIn_<cell><side><slot>',
    added in stage 2)."""
    lr = json.load(open(os.path.join(HERE, 'location_rooms.json')))
    cand = []
    for lv in sorted(layouts):
        L = layouts[lv]
        inst = (lr.get(f'D{wing(lv)}-instrument') or {}).get('room')
        arena = set()
        for cell, room in L.items():
            for d in cat[room]['doors']:
                if len(d) > 3 and d[2] == 'bossdoor':
                    c, r = dg.cell_pos(cell)
                    arena.add(dg.cell_name(lv, c + rooms.STEP[d[0]][0], r + rooms.STEP[d[0]][1]))
        for cell, room in sorted(L.items()):
            if cell in arena or room == inst or dg.BOSS_TYPES & set(cat[room].get('types', ())):
                continue
            ways = [(s, x[0]) for s, xs in dg.openings(cat, room).items() for x in xs
                    if not isinstance(x[0], str) and dg.chaos_free(cat, room, s, x[0])
                    and not (cell == dg.ENTRANCES[lv] and s in dg._exit_sides(cat, cell))]
            if ways:
                cand.append((lv, cell, room, ways))
    out, used = {}, set()
    for lv in sorted(layouts):
        region = rl.LEVELS[lv][1]
        pool = [c for c in cand if c[1] not in used]
        lv2, cell, room, ways = rng.choice(pool)
        used.add(cell)
        if cell == dg.ENTRANCES[lv2]:  # (its own entrance start, as the game's door uses)
            out[region] = (lv2, short(cell), None, None, None, None, 'entrance')
            continue
        s, slot = rng.choice(ways)
        own = any(not d[2].endswith('(mirror)') and d[0] == s and abs(d[3] - slot) <= 1
                  for d in cat[room]['doors'] if len(d) > 3)
        depth, height = dg.landing_depth(romfs, room, s, slot, 1 if own else 0) if romfs else (2.2, 0.0)
        out[region] = (lv2, short(cell), s, slot, depth, height, f'LabIn_{short(cell)}{s}{slot}')
    return out


# ---------------------------------------------------------------- the plan
def plan(cat, seed, romfs, mode, settings=None, et_locks=0, rounds=None):
    """-> ({level: layout}, rows, info): the wings' layouts (dungeon_gen names: {'Lv01TailCave_08D': room}), every
    door_jumps row (rows into another level have 10 fields) and info (arrivals, links, statistics: labyrinth.json)."""
    levels = list(dg.ENTRANCES)
    if rounds is None:
        rounds = int(os.environ.get('LARECOMP_GEN_ROUNDS', 8))
    fixed = set()
    for lv in levels:
        fixed |= set(dg.anchors_of(cat, lv)) | {dg.ENTRANCES[lv]}
    pool = {k for k, v in cat.items() if len(v['unit']) == 1 and dg.movable(v) and k not in fixed
            and k.split('_')[0] in levels}
    keysanity = (settings or {}).get('keysanity', 'off') != 'off'
    best, why = None, {}
    for rnd in range(rounds):
        sub = seed if rnd == 0 else f'{seed}#{rnd}'
        rng = random.Random(sub + '-labyrinth')
        out = dg.chaos_place(cat, sub, romfs, levels, rng, pool, shuffle=rnd > 0)
        if out is None:
            why['placement'] = why.get('placement', 0) + 1
            continue
        pieces, follow = {}, {}
        for lv in levels:
            comps, by_comp, fol = dg.chaos_pieces(cat, out[lv], dg.ENTRANCES[lv], rng)
            if any(k not in by_comp for k in comps):  # (a piece without a free doorway: no way to link it)
                pieces = None
                break
            for root, st in by_comp.items():
                pieces[(lv, root)] = list(st)
            follow.update(fol)
        if pieces is None:
            why['closed piece'] = why.get('closed piece', 0) + 1
            continue
        pieces[(ET, 'ET')] = [ET_STUB]
        short_layouts = {lv: {short(c): r for c, r in L.items()} for lv, L in out.items()}
        need = {(lv, c) for lv, L in short_layouts.items() for c, r in L.items() if any(dg.openings(cat, r).values())}
        need.add(rl.ET_NODE)
        found = None
        for attempt in range(40):
            p = {k: list(v) for k, v in pieces.items()}
            if mode == 'madness':
                link = pair_madness(p, rng)
            else:
                pairs = pair_two_way(p, rng, mode == 'coherent')
                link = None
                if pairs is not None:
                    link = {}
                    for a, b in pairs:
                        link[a] = b
                        link[b] = a
            if link is None:
                why['pairing'] = why.get('pairing', 0) + 1
                continue
            rows = with_followers(cat, out, romfs, follow, link)
            edges, flags = rl.labyrinth_graph(cat, romfs, short_layouts, rows, et_locks)
            for _ in range(8):  # (the doors' rooms: drawn again when a boss door would shut off more than its boss)
                arrivals = pick_arrivals(cat, out, rng, romfs)
                starts = rl.labyrinth_starts({k: v[:2] for k, v in arrivals.items()})
                # every room with a doorway must be reachable from the doors at all: a piece is joined only one way
                # where a one-way door joins it (Color Dungeon 08E -> 07E): linked through that end alone, it and
                # whatever hangs off it were shut off (sweep seed NTB9S...: Bottle Grotto's upper half, its instrument)
                if need - rl._graph_reach(edges, starts):
                    why['unreachable rooms'] = why.get('unreachable rooms', 0) + 1
                    continue
                if not rl.labyrinth_boss_ok(cat, edges, starts, short_layouts):
                    why['boss door'] = why.get('boss door', 0) + 1
                    continue
                if not keysanity and not rl.labyrinth_fill_ok(cat, romfs, edges, starts, flags, short_layouts,
                                                              settings, et_locks):
                    why['fill'] = why.get('fill', 0) + 1
                    continue
                found = (rows, arrivals, link, edges, starts)
                break
            if found:
                break
        if not found:
            continue
        used = {src for L in out.values() for src in L.values() if src in pool}
        score = len(pool - used)
        if best is None or score < best[0]:
            best = (score, out, found)
        if score == 0:
            break
    if best is None:
        raise RuntimeError(f'no Labyrinth layout ({", ".join(f"{k}: {v}" for k, v in sorted(why.items()))})')
    unused, out, (rows, arrivals, link, edges, starts) = best
    info = stats(cat, out, rows, arrivals, link, edges, starts, mode)
    info['unused-rooms'] = unused
    print(f'labyrinth: {mode}, {unused} room(s) unused, {len(rows)} doorway rows, {info["cross-links"]} cross-wing '
          f'links, {len(info["only-through-another"])} wing(s) reachable only through another '
          f'({", ".join(map(str, info["only-through-another"]))})', flush=True)
    return out, rows, info


def stats(cat, layouts, rows, arrivals, link, edges, starts, mode):
    """labyrinth.json: the doors' arrivals, the cross-wing links, which wings only another wing leads into."""
    cross = sorted({tuple(sorted(((level_of(a), short(a[1]), a[2], a[3]), (level_of(b), short(b[1]), b[2], b[3]))))
                    if mode != 'madness' else ((level_of(a), short(a[1]), a[2], a[3]), (level_of(b), short(b[1]), b[2], b[3]))
                    for a, b in link.items() if level_of(a) != level_of(b)})
    door_wings = {v[0] for v in arrivals.values()} | {ET}
    only = sorted(wing(lv) for lv in list(layouts) + [ET] if lv not in door_wings)
    # wings some of whose rooms only another wing leads to (from its own doors' rooms, staying inside the wing)
    split = []
    for lv in layouts:
        own = {n for n in starts if n[0] == lv}
        cells = {n for n in edges if n[0] == lv}
        seen, todo = set(own), list(own)
        while todo:
            a = todo.pop()
            for b, _ in edges.get(a, ()):
                if b[0] == lv and b not in seen:
                    seen.add(b)
                    todo.append(b)
        if own and cells - seen:
            split.append(wing(lv))
    return {'mode': mode, 'wings': {str(wing(lv)): lv for lv in list(layouts) + [ET]},
            'arrivals': {k: list(v) for k, v in sorted(arrivals.items())},
            'eagle-tower': {'exit': [ET, short(ET_CELL), 'S', 10], 'start': ET_START,
                            'exit-leads-to': list(next(((level_of(b), short(b[1]), b[2], b[3])
                                                       for a, b in link.items() if a == ET_STUB), ()))},
            'cross-links': len(cross), 'cross': [list(map(list, c)) for c in cross],
            'only-through-another': only, 'partly-through-another': sorted(split)}
