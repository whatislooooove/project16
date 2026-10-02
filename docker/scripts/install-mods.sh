#!/usr/bin/env bash
set -euo pipefail

HLDS="${HLDS_DIR:-/opt/hlds}"
TMP="${TMPDIR:-/tmp}/cs16-mods"
mkdir -p "$TMP" "$HLDS/cstrike/addons/metamod" "$HLDS/cstrike/addons/reunion"

download() {
  local url="$1"
  local out="$2"
  echo "Downloading $url"
  curl -fsSL "$url" -o "$out"
}

# ReHLDS
download "$REHLDS_URL" "$TMP/rehlds.zip"
unzip -qo "$TMP/rehlds.zip" -d "$TMP/rehlds"

cp -a "$TMP/rehlds/bin/linux32/engine_i486.so" "$HLDS/engine_i486.so"
chmod +x "$HLDS/engine_i486.so"

test -f "$HLDS/engine_i486.so"

# Metamod-R
download "$METAMOD_URL" "$TMP/metamod.zip"
unzip -qo "$TMP/metamod.zip" -d "$TMP/metamod"
cp -a "$TMP/metamod/addons/." "$HLDS/cstrike/addons/"
test -f "$HLDS/cstrike/addons/metamod/metamod_i386.so"

# AMX Mod X (base + cstrike package)
curl -fsSL "$AMXX_BASE_URL" | tar -C "$HLDS/cstrike" -xzf -
curl -fsSL "$AMXX_CSTRIKE_URL" | tar -C "$HLDS/cstrike" -xzf -
test -f "$HLDS/cstrike/addons/amxmodx/dlls/amxmodx_mm_i386.so"

# ReGameDLL_CS
download "$REGAMEDLL_URL" "$TMP/regamedll.zip"
unzip -qo "$TMP/regamedll.zip" -d "$TMP/regamedll"
cp -a "$TMP/regamedll/bin/linux32/cstrike/." "$HLDS/cstrike/"
test -f "$HLDS/cstrike/dlls/cs.so"

# ReAPI
download "$REAPI_URL" "$TMP/reapi.zip"
unzip -qo "$TMP/reapi.zip" -d "$TMP/reapi"
if [ -d "$TMP/reapi/addons" ]; then
  cp -a "$TMP/reapi/addons/." "$HLDS/cstrike/addons/"
fi

# ReUnion
download "$REUNION_URL" "$TMP/reunion.zip"
unzip -qo "$TMP/reunion.zip" -d "$TMP/reunion"
if [ -d "$TMP/reunion/bin/Linux" ]; then
  cp -a "$TMP/reunion/bin/Linux/." "$HLDS/cstrike/addons/reunion/"
elif [ -d "$TMP/reunion/bin/linux" ]; then
  cp -a "$TMP/reunion/bin/linux/." "$HLDS/cstrike/addons/reunion/"
else
  find "$TMP/reunion" -name 'reunion_mm*.so' -exec cp -a {} "$HLDS/cstrike/addons/reunion/" \;
fi
if [ -f "$TMP/reunion/reunion.cfg" ] && [ ! -f "$HLDS/cstrike/reunion.cfg" ]; then
  cp "$TMP/reunion/reunion.cfg" "$HLDS/cstrike/reunion.cfg"
fi
test -f "$HLDS/cstrike/addons/reunion/reunion_mm_i386.so" \
  || test -f "$HLDS/cstrike/addons/reunion/reunion_mm.so"

# YaPB
download "$YAPB_URL" "$TMP/yapb.tar.xz"
tar -C "$HLDS/cstrike" -xJf "$TMP/yapb.tar.xz"
test -f "$HLDS/cstrike/addons/yapb/bin/yapb.so"

# Point the Linux game DLL at Metamod-R
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
echo "90" > "$HLDS/steam_appid.txt"

rm -rf "$TMP"
echo "Mods installed."
