#!/data/data/com.termux/files/usr/bin/bash
# rfhop installer - registers the self-updating `rfhop` command (Redfinger, rooted)
set -u
REPO_RAW="https://raw.githubusercontent.com/lucivaantarez/rfhop/main"

echo "  installing rfhop ..."

# dependencies
pkg install -y curl termux-api || { echo "  pkg install failed - check network"; }
command -v su >/dev/null 2>&1 || echo "  note: 'su' not found - device must be rooted for force-stop."
command -v termux-clipboard-get >/dev/null 2>&1 || echo "  note: also install the Termux:API APP (not just the pkg) for clipboard/API features."

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
echo "  first run: SETTINGS (2) -> pick both clones, set the 2 files, T to test, S to save."
echo
