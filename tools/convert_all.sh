#!/bin/bash
out="$1"
mkdir -p "$out"
for f in samples/pdf/*.pdf; do
  n=$(basename "$f" .pdf)
  .build/debug/chordpro "$f" > "$out/$n.cho" 2>/dev/null
  secs=$(grep -o '{comment: [^}]*}' "$out/$n.cho" | sed 's/{comment: //;s/}//' | paste -sd, -)
  echo "== $n | $secs"
done
