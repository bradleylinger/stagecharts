#!/bin/bash
# shot.sh out.png [titleSubstring] — capture a StageCharts window (even if behind others).
id=$(/Volumes/ext/docker_data/sites/onsong_replacement/.build/winid "$2" | head -1 | cut -d' ' -f1)
[ -n "$id" ] && screencapture -x -o -l "$id" "$1" && echo "shot $1"
