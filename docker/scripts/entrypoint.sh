#!/usr/bin/env bash
set -euo pipefail

HLDS="${HLDS_DIR:-/opt/hlds}"
CUSTOM="${CUSTOM_DIR:-/custom}"
cd "$HLDS"

overlay_dir() {
  local src="$1"
  local dst="$2"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    rsync -a "$src"/ "$dst"/
  fi
}

# Overlay host cstrike files, but never replace Linux engine/plugin binaries.
if [ -d "$CUSTOM" ]; then
  rsync -a \
    --exclude '*.dll' \
    --exclude '*.exe' \
    --exclude '*.pdb' \
    --exclude 'dlls/' \
    --exclude 'cl_dlls/' \
    --exclude 'addons/metamod/*.dll' \
    --exclude 'addons/reunion/*.dll' \
    --exclude 'addons/yapb/bin/*.dll' \
    --exclude 'addons/amxmodx/dlls/*.dll' \
    --exclude 'addons/amxmodx/modules/*.dll' \
    "$CUSTOM"/ "$HLDS/cstrike"/
fi

overlay_dir /custom-maps "$HLDS/cstrike/maps"
overlay_dir /custom-models "$HLDS/cstrike/models"
overlay_dir /custom-sound "$HLDS/cstrike/sound"
overlay_dir /custom-sprites "$HLDS/cstrike/sprites"

if [ -f "$HLDS/cstrike/liblist.gam" ]; then
  sed -i 's|^gamedll_linux.*|gamedll_linux "addons/metamod/metamod_i386.so"|' "$HLDS/cstrike/liblist.gam"
fi

PLUGINS="$HLDS/cstrike/addons/metamod/plugins.ini"
mkdir -p "$(dirname "$PLUGINS")"
touch "$PLUGINS"
for line in \
  "linux addons/reunion/reunion_mm_i386.so" \
  "linux addons/amxmodx/dlls/amxmodx_mm_i386.so" \
  "linux addons/yapb/bin/yapb.so"
do
  grep -qF "$line" "$PLUGINS" || echo "$line" >> "$PLUGINS"
done

touch "$HLDS/cstrike/listip.cfg" "$HLDS/cstrike/banned.cfg"

MAP="${START_MAP:-de_dust2}"
MAX="${MAXPLAYERS:-16}"
PORT="${PORT:-27015}"

extra=()
if [ -n "${CS_HOSTNAME:-}" ]; then
  extra+=(+hostname "$CS_HOSTNAME")
fi
if [ -n "${RCON_PASSWORD:-}" ]; then
  extra+=(+rcon_password "$RCON_PASSWORD")
fi
if [ -n "${SV_PASSWORD:-}" ]; then
  extra+=(+sv_password "$SV_PASSWORD")
fi

export CPU_MHZ="${CPU_MHZ:-2300}"
export LD_LIBRARY_PATH="$HLDS:${LD_LIBRARY_PATH:-}"

exec ./hlds_run \
  -game cstrike \
  -console \
  -norestart \
  -port "$PORT" \
  +ip 0.0.0.0 \
  +maxplayers "$MAX" \
  +map "$MAP" \
  "${extra[@]}" \
  "$@"
