#!/bin/sh
# Turns the TRACE lines of an integration_test/pipeline_test.dart log into a
# fixture for test/real_swings_test.dart.
#   tool/trace_to_fixture.sh run.log [clip-number] > test/fixtures/swings/name.txt
# With a clip number, reads the lines of that clip from a batch (VIDEOS=) run.
prefix=""
[ -n "$2" ] && prefix="CLIP $2 "
grep -o "${prefix}TRACE .*" "$1" | sed -E 's/^.*TRACE //' |
  sed -E 's/([0-9]+) hand=([0-9-]+),([0-9-]+) hip=([0-9-]+),([0-9-]+) torso=[0-9]+ ls=([0-9-]+),([0-9-]+) rs=([0-9-]+),([0-9-]+).*/\1 \2 \3 \4 \5 \6 \7 \8 \9/'
