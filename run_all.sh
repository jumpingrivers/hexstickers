#!/usr/bin/env bash
# Restart download_hexes.R after hard crashes (e.g. ImageMagick aborts).
# Stops when the script exits cleanly, or after 200 restarts.
cd "$(dirname "$0")"
for i in $(seq 1 200); do
  Rscript download_hexes.R "$@" && exit 0
  echo "$(date +%H:%M:%S) Rscript exited with status $?, restarting ($i)"
  sleep 5
done
echo "Too many restarts, giving up"
exit 1
