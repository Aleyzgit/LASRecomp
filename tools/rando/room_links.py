"""Room links: actors in a room refer to each other by their index in it (relationship section 1 entries
[[p1, p2], index] and section 3 index lists - a kill-all trigger to its enemies, a mini-boss to its kit: Rolling
Bones' spike bar, Smasher's iron ball). An edit that removes or reorders actors without renumbering them leaves links
past the room's actor list or at the wrong actor, and the game crashes building that actor when its screen loads (Open
Mabe's removals did, 2026-10-18). Checked over every room file the seed writes (las_headless.py, before it finishes;
seed_sweep.py's --full runs), so such a seed fails generation instead of crashing in game.

    check(out_dir, leb) -> list of problems ('<room>: ...'), empty when every link is sound
"""
import os

KIT_KEY_TAG = 0x6B  # (RandomizerCore/Randomizers/enemies.py: keys of the kit actors copied next to a mini-boss)


def check_room(name, room):
    out = []
    n = len(room.actors)
    for i, a in enumerate(room.actors):
        rl = a.relationships
        links = [s[1] for s in rl.section_1] + list(rl.section_3)
        bad = [j for j in links if not 0 <= j < n]
        if bad:
            out.append(f'{name}: actor {i} ({a.name.decode(errors="replace")}) links to {bad}, the room has {n} actors')
        elif a.key >> 56 == KIT_KEY_TAG:  # (a kit actor: back to the mini-boss that links to it)
            for j in rl.section_3:
                if not any(s[1] == i for s in room.actors[j].relationships.section_1):
                    out.append(f'{name}: kit actor {i} ({a.name.decode(errors="replace")}) points back to actor {j}, '
                               'which does not link to it')
    return out


def check(out_dir, leb):
    levels = os.path.join(out_dir, 'romfs', 'region_common', 'level')
    problems = []
    for lv in sorted(os.listdir(levels)) if os.path.isdir(levels) else []:
        d = os.path.join(levels, lv)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith('.leb'):
                with open(os.path.join(d, f), 'rb') as fh:
                    problems += check_room(f[:-4], leb.Room(fh.read()))
    return problems
