#!/bin/bash
# Watch what the audio pipeline is doing, live.
#
# Run this while switching mixes. The two numbers that matter:
#
#   min cushion  how close the output ring came to running dry
#   worst hop    the longest single hop, inference included
#
# A switch from a full mix to a separated one spends one hop's worth of the
# cushion. While "min cushion" stays clearly above "worst hop" the switch is
# inaudible; if they converge, raise the cushion floor in
# AudioController.cushionFloats — at the cost of that much added delay.
#
# "underruns" is the honest verdict: any non-zero value was audible.
log stream --predicate 'subsystem == "com.evanhu.transposify"' \
    --style compact --level info
