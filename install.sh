#!/data/data/com.termux/files/usr/bin/bash
# rfhop installer - registers the self-updating `rfhop` command (Redfinger, rooted)
# auto mirror-rotation: if a pkg fetch fails, switch to another mirror and retry,
# cycling through Termux's bundled mirror list. curl required / termux-api optional.
set -u
REPO_RAW="https://raw.githubusercontent.com/lucivaantarez/rfhop/main"
MIRDIR="$PREFIX/etc/termux/mirrors"
SLIST="$PREFIX/etc/apt/sources.list"

echo "  installing rfhop ..."

apt_update(){ pkg update -y >/dev/null 2>&1 || apt-get update -y >/dev/null 2>&1; }

# install package(s); on failure, rotate through bundled mirrors (shuffled) and retry
ensure_pkg(){
  apt_update; pkg install -y "$@" >/dev/null 2>&1 && return 0
  if [ -d "$MIRDIR" ]; then
    local m
    while IFS= read -r m; do
      [ -f "$m" ] || continue
      echo "  mirror down - switching to $(basename "$m") ..."
      cp "$m" "$SLIST" 2>/dev/null || continue
      apt_update || continue
      pkg install -y "$@" >/dev/null 2>&1 && { echo "  installed via $(basename "$m")"; return 0; }
    done < <(find "$MIRDIR" -type f 2>/dev/null | sort -R)
  fi
  return 1
}

# curl is REQUIRED
if command -v curl >/dev/null 2>&1; then echo "  curl: ok"
elif ensure_pkg curl;          then echo "  curl: ready"
else echo "  ERROR: every mirror failed for curl - check the device network, then rerun."; exit 1; fi

# termux-api is OPTIONAL (needed later for clipboard/Delta) - never blocks install
if command -v termux-clipboard-get >/dev/null 2>&1; then echo "  termux-api: ok"
elif pkg install -y termux-api >/dev/null 2>&1;       then echo "  termux-api: ready"
elif ensure_pkg termux-api;                           then echo "  termux-api: ready"
else echo "  note: termux-api skipped - rfhop still works, add it later for the Delta side."; fi

command -v su >/dev/null 2>&1 || echo "  note: 'su' not found - device must be rooted for force-stop."
command -v termux-clipboard-get >/dev/null 2>&1 || echo "  note: also install the Termux:API APP for clipboard features."

# storage -> Download (fallback HOME)
if [ ! -d "$HOME/storage" ]; then termux-setup-storage || true; sleep 2; fi
DLDIR="$HOME/storage/downloads"; [ -d "$DLDIR" ] || DLDIR="$HOME"
mkdir -p "$HOME/.rfhop"; printf '%s' "$DLDIR" > "$HOME/.rfhop/dldir"

# write the self-updating launcher
echo "#!$PREFIX/bin/bash" > "$PREFIX/bin/rfhop"
cat >> "$PREFIX/bin/rfhop" <<'LAUNCHER'
REPO_RAW="https://raw.githubusercontent.com/lucivaantarez/rfhop/main"
DLDIR="$(cat "$HOME/.rfhop/dldir" 2>/dev/null)"; [ -d "$DLDIR" ] || DLDIR="$HOME/storage/downloads"; [ -d "$DLDIR" ] || DLDIR="$HOME"
SCRIPT="$DLDIR/rfhop.sh"; TMP="$(mktemp)"
if curl -fsSL "$REPO_RAW/rfhop.sh" -o "$TMP" 2>/dev/null && [ -s "$TMP" ]; then
  if [ ! -f "$SCRIPT" ] || ! cmp -s "$TMP" "$SCRIPT"; then cp "$TMP" "$SCRIPT"; echo "  rfhop: updated."; fi
fi
rm -f "$TMP"
[ -f "$SCRIPT" ] || { echo "rfhop: no local copy and github unreachable"; exit 1; }
chmod +x "$SCRIPT" 2>/dev/null
exec bash "$SCRIPT"
LAUNCHER
chmod +x "$PREFIX/bin/rfhop"

# pull the script now so first run is instant
curl -fsSL "$REPO_RAW/rfhop.sh" -o "$DLDIR/rfhop.sh" 2>/dev/null && chmod +x "$DLDIR/rfhop.sh" 2>/dev/null

echo
echo "  done. type:   rfhop"
echo "  first run: SETTINGS (2) -> pick both clones, set the 2 slots, T to test, S to save."
echo
