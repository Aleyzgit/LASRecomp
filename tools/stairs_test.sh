#!/bin/bash
# Take every stairs / ladder of a seed's generated dungeons and check Link arrives in the room its locator names:
# tools/stairs_test.sh <seed> [level ...]. One hidden, muted game run per level; in it each case is a warp into the
# trigger's room (its own start - a side-view passage's is at its ladder top), then either the stick held up (a
# ladder up out of a side-view passage: he climbs down on arrival, then back up) or Link put onto the trigger
# (LARECOMP_PLACE: stairs in a room, side-view exits at floor level). Cases: tools/rando/stairs_cases.py.
# Results: build/stairs_<seed>.txt (PASS / FAIL per case) + the run logs build/run_shot_stairs_<seed>_<level>.log.
SEED=$1; shift
P=${STAIRS_PERIOD:-900}  # frames per case
PY=${LAS_PY:-third_party/LAS-Randomizer/venv/bin/python3}
[ -x "$PY" ] || PY=python3
OUT=build/stairs_$SEED.txt; : > "$OUT"
CASES=$(mktemp); "$PY" tools/rando/stairs_cases.py extracted/romfs "rando/$SEED" > "$CASES" || exit 1
levels=${*:-$(cut -f1 "$CASES" | uniq)}
for lv in $levels; do
    job="stairs_${SEED}_$lv"
    # warps, input and placements of this level's cases (case k starts at frame 2700 + k * P)
    plan=$(awk -F'\t' -v lv="$lv" -v P="$P" '$1 == lv {
        t = 2700 + n * P
        warp = warp (warp ? "," : "") t ":" lv ":" $3
        if ($2 == "up" && $5 >= 5 && $6 == "0.00") input = input "," (t + 450) ":STICK_UP:${STAIRS_CLIMB:-100}"  # ladder up (not longer: he walks on
        else place = place (place ? ";" : "") (t + 350) ":" $4 ":" $6
        if ($12 >= 0) flags = flags (flags ? "," : "") $12  # (stairs that appear once the room is cleared: shown)
        n++ } END { print warp "|" input "|" place "|" flags "|" n }' "$CASES")
    IFS='|' read -r warp input place flags n <<< "$plan"
    if [ -z "$STAIRS_NO_RUN" ]; then  # (STAIRS_NO_RUN=1: only read the last run's logs again)
    tools/fresh_save.sh "$job" >/dev/null 2>&1
    LARECOMP_HIDDEN=1 LARECOMP_NO_AUDIO=1 LARECOMP_NO_MOVIE_AUDIO=1 LARECOMP_CHEATS=hearts LARECOMP_RANDO_SEED=$SEED \
    LARECOMP_SAVE_DIR="build/$job" LARECOMP_WINDOW=640x360 SHOT_ID="$job" LARECOMP_LOG_LINK=10 \
    LARECOMP_INPUT="400:A:6,520:A:6,900:ZL:8,900:ZR:8,1300:A:6,1600:A:6,1900:A:6,2200:A:6$input" \
    LARECOMP_WARP_AT="$warp" LARECOMP_PLACE="$place" LARECOMP_SET_FLAGS="$flags" \
    tools/shot.sh $((2700 + n * P)) $((120 + (2700 + n * P) / 30)) </dev/null 2>/dev/null
    fi
    # Link's position near the end of each case: inside the target room's box?
    awk -F'\t' -v lv="$lv" -v P="$P" -v lf="build/run_shot_$job.log" '
        BEGIN { while ((getline l < lf) > 0) if (l ~ /^\[link\] f[0-9]+ /) {
                    split(l, a, /[ (),]+/); f = substr(a[2], 2) + 0; X[f] = a[3]; Y[f] = a[4]; Z[f] = a[5] } }
        $1 == lv { t = 2700 + n * P + P - 20; n++
            x = ""; for (f = t; f > t - 60; f--) if (f in X) { x = X[f]; y = Y[f]; z = Z[f]; break }
            ok = x != "" && x >= $8 - 0.5 && x <= $10 + 0.5 && z >= $9 - 0.5 && z <= $11 + 0.5
            printf "%s %s %s -> %s: Link at (%s, %s, %s): %s%s\n", $3, $2, $4 "/" $6, $7, x, y, z, (ok ? "PASS" : "FAIL"),
                   ($12 >= 2048 ? " (gate flag " $12 ": not settable by the test)" : "") }' "$CASES" |
        tee -a "$OUT"
    grep -q '\[crash\]' "build/run_shot_$job.log" && echo "$lv: game stopped (crash) - see build/run_shot_$job.log" | tee -a "$OUT"
done
rm -f "$CASES"
echo "$(grep -c PASS "$OUT") pass / $(grep -c -v PASS "$OUT") other -> $OUT"
