#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
#  rfhop  v2.1.0   —   Saturnity Roblox private-server hopper (Redfinger)
#  Rooted Redfinger, App Cloner Roblox clones, up to 3 clones per device.
#  Time-based hopping (container isolation blocks process detection).
#
#  This build:
#    - launch activity  com.roblox.client.ActivityProtocolLaunch  (the real one)
#    - split mode  auto | fixed   (auto = even split across all 20 slots)
#    - LOAD / HOLD phase loop with staggered clone2
#    - Charm-palette, line-based TUI (no padded boxes -> never misaligns)
#
#  Terminal-safety carried over: ASCII-only padded fields, full clear each
#  frame, stty-sane before every input, INT/TERM cleanup, WINCH re-fit.
# ============================================================================

shopt -s checkwinsize 2>/dev/null

VERSION="2.10.0"
NSLOTS=20

CONF_DIR="$HOME/.rfhop"
CONF="$CONF_DIR/config"

# ---- defaults (overridden by config) --------------------------------------
NCLONES=2                  # clones per device; leave a clone's package blank to skip it
C1_PKG="com.roblox.clienv"; C2_PKG="com.roblox.clienw"; C3_PKG=""; C4_PKG=""; C5_PKG=""; C6_PKG=""
C1_SLOT=1; C2_SLOT=2; C3_SLOT=3; C4_SLOT=4; C5_SLOT=5; C6_SLOT=6
pkg_of(){  local v="C${1}_PKG";  printf '%s' "${!v}"; }
slot_of(){ local v="C${1}_SLOT"; printf '%s' "${!v}"; }
MASTER="$CONF_DIR/links.txt"
REPO_RAW="https://raw.githubusercontent.com/lucivaantarez/rfhop/main"   # script self-update base
# per-device link source (raw GitHub). Default = your repo's links.txt; other users point this at their own raw file.
LINKS_URL="https://raw.githubusercontent.com/lucivaantarez/rfhop/main/links.txt"
# --- discord dashboard reporting ---
REPORT="off"               # on = send state to the worker
DEVICE_NAME=""             # this device label on the dashboard, e.g. RF01
REPORT_URL=""              # your worker /report endpoint
SQLITE="/data/data/com.termux/files/usr/bin/sqlite3"
SPLIT_MODE="auto"          # auto | fixed
CHUNK=50                   # only used when SPLIT_MODE=fixed
LOAD_WAIT=20               # seconds to settle after launch
HOLD_TIME=180              # seconds to stay in a server
STAGGER=100                # seconds each clone starts behind the previous
LAUNCH_TMPL="am start -n %PKG%/com.roblox.client.ActivityProtocolLaunch -d '%URL%'"
WAKELOCK="on"
TERMUX_API="off"

# ---- palette (24-bit ANSI; reproducible in Termux) ------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; B=$'\033[1m'
  C_DIM=$'\033[38;2;88;88;102m'
  C_TS=$'\033[38;2;124;124;136m'
  C_TXT=$'\033[38;2;232;232;238m'
  C_WHT=$'\033[38;2;242;242;246m'
  C_PUR=$'\033[38;2;140;127;245m'
  C_GRN=$'\033[38;2;70;206;128m'
  C_YEL=$'\033[38;2;236;201;75m'
  C_RED=$'\033[38;2;240;96;106m'
  C_MAG=$'\033[38;2;255;79;163m'
  C_BRAND=$'\033[38;2;125;86;244m'
  C_MARK=$'\033[38;2;238;111;248m'
  C_RULE=$'\033[38;2;47;47;58m'
else
  C_RESET=""; B=""; C_DIM=""; C_TS=""; C_TXT=""; C_WHT=""; C_PUR=""
  C_GRN=""; C_YEL=""; C_RED=""; C_MAG=""; C_BRAND=""; C_MARK=""; C_RULE=""
fi

# ---- terminal helpers ------------------------------------------------------
W=40; RULE=""
fit(){
  local w=""
  w=$( { stty size; } 2>/dev/null | awk '{print $2}' )
  case "$w" in ''|*[!0-9]*) w=${COLUMNS:-} ;; esac
  case "$w" in ''|*[!0-9]*) w=$(tput cols 2>/dev/null) ;; esac
  case "$w" in ''|*[!0-9]*) w=80 ;; esac
  W=$w
  [ "$W" -gt 200 ] && W=200
  [ "$W" -lt 24 ] && W=24
  RULE=$(printf '─%.0s' $(seq 1 "$W"))
}
# Print one line truncated to W visible columns. ANSI-escape aware (escapes
# don't count) and UTF-8 aware (multibyte glyph = 1 column, never split).
# Forces byte-wise slicing via LC_ALL=C so it is correct regardless of locale.
emit(){
  local LC_ALL=C
  local s=$1 out= vis=0 i=0 n=${#1} b code
  while [ "$i" -lt "$n" ]; do
    [ "$vis" -ge "$W" ] && break
    b=${s:i:1}
    if [ "$b" = $'\033' ]; then
      out+=$b; i=$((i+1))
      while [ "$i" -lt "$n" ]; do b=${s:i:1}; out+=$b; i=$((i+1)); case $b in [a-zA-Z]) break;; esac; done
      continue
    fi
    out+=$b; i=$((i+1))
    printf -v code '%d' "'$b" 2>/dev/null || code=0
    if [ "$code" -ge 192 ]; then
      while [ "$i" -lt "$n" ]; do b=${s:i:1}; printf -v code '%d' "'$b" 2>/dev/null || code=0
        if [ "$code" -ge 128 ] && [ "$code" -lt 192 ]; then out+=$b; i=$((i+1)); else break; fi
      done
    fi
    vis=$((vis+1))
  done
  printf '%s%s\n' "$out" "$C_RESET"
}
# emit a printf-formatted line (truncated): el 'FMT' args...
el(){ local fmt=$1; shift; emit "$(printf "$fmt" "$@")"; }
clr(){ [ -t 1 ] && stty opost onlcr 2>/dev/null; printf '\033[3J\033[H\033[2J\033[?7l'; }
hide_cursor(){ printf '\033[?25l'; }
show_cursor(){ printf '\033[?25h'; }
cook(){ [ -t 0 ] && stty sane 2>/dev/null; [ -t 1 ] && printf '\033[?7h'; return 0; }
rule(){ printf '%s%s%s\n' "$C_RULE" "$RULE" "$C_RESET"; }
flash(){ printf '\n %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; sleep 1; }

cleanup(){ show_cursor; cook; wake_off; }
trap 'cleanup; exit 130' INT TERM
trap 'cleanup' EXIT
trap 'fit' WINCH

# mark+space counts as 2 columns; left text is ASCII so ${#} == columns
hdr(){
  local left=$1 right=$2
  local leftw=$(( 2 + ${#left} ))
  local pad=$(( W - leftw - ${#right} )); [ $pad -lt 1 ] && pad=1
  printf '%s◆%s %s%s%s%*s%s%s%s\n' \
    "$C_MARK" "$C_RESET" "$C_WHT$B" "$left" "$C_RESET" "$pad" "" "$C_BRAND" "$right" "$C_RESET"
}

fmt_dur(){ local s=$1; if [ $s -ge 60 ]; then printf '%dm%02ds' $((s/60)) $((s%60)); else printf '%ds' $s; fi; }
fmt_up(){ local s=$1; printf '%dh%02dm' $((s/3600)) $(( (s%3600)/60 )); }
fmt_clock(){ date -d "@$1" +'%-I:%M%p' 2>/dev/null || date -r "$1" +'%-I:%M%p' 2>/dev/null || printf '--'; }
trunc(){ local s=$1 n=$2; if [ ${#s} -gt $n ]; then printf '%s..' "${s:0:$((n-2))}"; else printf '%s' "$s"; fi; }
now(){ date +%s; }

# ---- optional Termux API / wakelock (guarded, never breaks core) ----------
wake_on(){ [ "$WAKELOCK" = on ] && command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock >/dev/null 2>&1; return 0; }
wake_off(){ command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock >/dev/null 2>&1; return 0; }
toast(){ [ "$TERMUX_API" = on ] && command -v termux-toast >/dev/null 2>&1 && (printf '%s' "$1" | termux-toast -g top -b '#16161c' -c '#e8e8ee' -s >/dev/null 2>&1 &); return 0; }

# ---- config ----------------------------------------------------------------
load_cfg(){
  [ -f "$CONF" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case $k in
      nclones) NCLONES=$v;;
      c1_pkg) C1_PKG=$v;;  c2_pkg) C2_PKG=$v;;  c3_pkg) C3_PKG=$v;;
      c4_pkg) C4_PKG=$v;;  c5_pkg) C5_PKG=$v;;  c6_pkg) C6_PKG=$v;;
      c1_slot) C1_SLOT=$v;; c2_slot) C2_SLOT=$v;; c3_slot) C3_SLOT=$v;;
      c4_slot) C4_SLOT=$v;; c5_slot) C5_SLOT=$v;; c6_slot) C6_SLOT=$v;;
      master) MASTER=$v;;  split_mode) SPLIT_MODE=$v;;
      links_url) LINKS_URL=$v;;
      report) REPORT=$v;; device_name) DEVICE_NAME=$v;; report_url) REPORT_URL=$v;;
      chunk) CHUNK=$v;;    load_wait) LOAD_WAIT=$v;;
      hold_time) HOLD_TIME=$v;; stagger) STAGGER=$v;;
      launch_tmpl) LAUNCH_TMPL=$v;;
      wakelock) WAKELOCK=$v;; termux_api) TERMUX_API=$v;;
    esac
  done < "$CONF"
}
save_cfg(){
  mkdir -p "$CONF_DIR"
  {
    echo "nclones=$NCLONES"
    echo "c1_pkg=$C1_PKG";   echo "c2_pkg=$C2_PKG";   echo "c3_pkg=$C3_PKG"
    echo "c4_pkg=$C4_PKG";   echo "c5_pkg=$C5_PKG";   echo "c6_pkg=$C6_PKG"
    echo "c1_slot=$C1_SLOT"; echo "c2_slot=$C2_SLOT"; echo "c3_slot=$C3_SLOT"
    echo "c4_slot=$C4_SLOT"; echo "c5_slot=$C5_SLOT"; echo "c6_slot=$C6_SLOT"
    echo "master=$MASTER"; echo "links_url=$LINKS_URL";
    echo "report=$REPORT"; echo "device_name=$DEVICE_NAME"; echo "report_url=$REPORT_URL";   echo "split_mode=$SPLIT_MODE"
    echo "chunk=$CHUNK";     echo "load_wait=$LOAD_WAIT"
    echo "hold_time=$HOLD_TIME"; echo "stagger=$STAGGER"
    echo "launch_tmpl=$LAUNCH_TMPL"
    echo "wakelock=$WAKELOCK"; echo "termux_api=$TERMUX_API"
  } > "$CONF"
}

# ---- master links + slot slicing ------------------------------------------
MASTER_LINKS=(); MASTER_N=0
reload_master(){
  MASTER_LINKS=(); MASTER_N=0
  [ -f "$MASTER" ] || return 0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -z "$line" ] && continue
    case $line in \#*) continue;; esac
    MASTER_LINKS+=("$line")
  done < "$MASTER"
  MASTER_N=${#MASTER_LINKS[@]}
}

# option 3: pull the latest links.txt from the repo, then reload (offline-safe)
update_links(){
  printf '\n %ssyncing links from repo...%s\n' "$C_DIM" "$C_RESET"
  local tmp; tmp="$(mktemp 2>/dev/null)"; [ -n "$tmp" ] || tmp="$CONF_DIR/.lpull"
  if curl -fsSL "$LINKS_URL" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mkdir -p "$(dirname "$MASTER")"
    if [ ! -f "$MASTER" ] || ! cmp -s "$tmp" "$MASTER"; then
      cp "$tmp" "$MASTER"; reload_master; flash "links updated: $MASTER_N"
    else
      reload_master; flash "already latest: $MASTER_N"
    fi
  else
    reload_master; flash "offline - local links: $MASTER_N"
  fi
  rm -f "$tmp"
}

# sets RS RE = 1-based inclusive range for a slot, or 0 0 if empty
RS=0; RE=0
slot_range(){
  local s=$1 N=$MASTER_N
  if [ "$N" -le 0 ]; then RS=0; RE=0; return; fi
  if [ "$SPLIT_MODE" = auto ]; then
    local base=$(( N / NSLOTS )) extra=$(( N % NSLOTS ))
    if [ "$s" -le "$extra" ]; then
      RS=$(( (s-1)*(base+1) + 1 )); RE=$(( s*(base+1) ))
    else
      RS=$(( extra*(base+1) + (s-1-extra)*base + 1 )); RE=$(( RS + base - 1 ))
    fi
  else
    RS=$(( (s-1)*CHUNK + 1 )); RE=$(( s*CHUNK ))
    [ "$RE" -gt "$N" ] && RE=$N
  fi
  if [ "$RS" -gt "$N" ] || [ "$RE" -lt "$RS" ]; then RS=0; RE=0; fi
}
slot_count(){ slot_range "$1"; if [ "$RS" -eq 0 ]; then echo 0; else echo $(( RE - RS + 1 )); fi; }
slot_links(){
  slot_range "$1"; [ "$RS" -eq 0 ] && return
  local i
  for (( i=RS; i<=RE; i++ )); do printf '%s\n' "${MASTER_LINKS[$((i-1))]}"; done
}

# ---- packages --------------------------------------------------------------
PKGS=()
detect_pkgs(){
  PKGS=()
  local raw
  raw=$(pm list packages 2>/dev/null | sed 's/^package://' | grep -i roblox)
  [ -z "$raw" ] && raw=$(su -c "pm list packages" 2>/dev/null | sed 's/^package://' | grep -i roblox)
  local p
  while IFS= read -r p; do [ -n "$p" ] && PKGS+=("$p"); done <<< "$raw"
}

# ---- launch / stop (root) --------------------------------------------------
LAST_OUT=""
launch_clone(){            # $1=pkg $2=url  -> 0 ok / 1 failed
  local cmd=${LAUNCH_TMPL//%PKG%/$1}
  cmd=${cmd//%URL%/$2}
  LAST_OUT=$(su -c "$cmd" 2>&1)
  local rc=$?
  [ -t 1 ] && stty opost onlcr 2>/dev/null   # am/app_process flips opost off -> restore CR mapping
  if [ $rc -ne 0 ] || printf '%s' "$LAST_OUT" | grep -qiE 'Error type|does not exist|Exception'; then
    return 1
  fi
  return 0
}
stop_clone(){ su -c "am force-stop $1" >/dev/null 2>&1; [ -t 1 ] && stty opost onlcr 2>/dev/null; }

# ---- log ring --------------------------------------------------------------
LOG=()
log(){                     # $1=level $2=msg
  local ts; ts=$(date +'%-I:%M%p' 2>/dev/null || date +'%I:%M%p')
  LOG+=("$ts|$1|$2")
  [ ${#LOG[@]} -gt 200 ] && LOG=("${LOG[@]: -200}")
  dirty=1
  case $1 in ERRO|FATA) toast "$2";; esac
}
print_log_line(){
  local e=$1 ts lvl msg col
  ts=${e%%|*}; e=${e#*|}; lvl=${e%%|*}; msg=${e#*|}
  case $lvl in INFO) col=$C_GRN;; DEBU) col=$C_PUR;; WARN) col=$C_YEL;; ERRO) col=$C_RED;; FATA) col=$C_MAG;; *) col=$C_TXT;; esac
  local mw=$(( W - 14 )); [ "$mw" -lt 8 ] && mw=8   # prefix = space+ts(7)+space+lvl(4)+space
  msg=$(trunc "$msg" "$mw")
  printf ' %s%-7s%s %s%s%-4s%s %s%s%s\n' \
    "$C_TS" "$ts" "$C_RESET" "$col" "$B" "$lvl" "$C_RESET" "$C_TXT" "$msg" "$C_RESET"
}

mode_label(){ if [ "$SPLIT_MODE" = auto ]; then printf 'auto split'; else printf 'fixed %s' "$CHUNK"; fi; }

# ============================================================================
#  HOME
# ============================================================================
render_home(){
  fit; clr
  hdr "rfhop  v$VERSION" "saturnity"
  printf '%sprivate server hopper · redfinger · rooted%s\n' "$C_DIM" "$C_RESET"
  rule
  local n1 n2 s1 s2
  n1=$(slot_count "$C1_SLOT"); n2=$(slot_count "$C2_SLOT")
  s1=${C1_PKG##*.}; [ -z "$s1" ] && s1="none"
  s2=${C2_PKG##*.}; [ -z "$s2" ] && s2="none"
  printf ' %s%-7s%s %s%-9s%s %sslot %s%s   %s%s links%s\n' \
    "$C_WHT" "clone1" "$C_RESET" "$C_DIM" "$s1" "$C_RESET" "$C_WHT" "$C1_SLOT" "$C_RESET" "$C_DIM" "$n1" "$C_RESET"
  printf ' %s%-7s%s %s%-9s%s %sslot %s%s   %s%s links%s\n' \
    "$C_WHT" "clone2" "$C_RESET" "$C_DIM" "$s2" "$C_RESET" "$C_WHT" "$C2_SLOT" "$C_RESET" "$C_DIM" "$n2" "$C_RESET"
  printf ' %s%-7s%s %s%-9s%s %s%s links total%s\n' \
    "$C_WHT" "master" "$C_RESET" "$C_DIM" "$(trunc "${MASTER##*/}" 9)" "$C_RESET" "$C_WHT" "$MASTER_N" "$C_RESET"
  printf ' %s%-7s%s %s%ss load + %ss hold · stagger %ss%s\n' \
    "$C_WHT" "timing" "$C_RESET" "$C_DIM" "$LOAD_WAIT" "$HOLD_TIME" "$STAGGER" "$C_RESET"
  printf ' %s%-7s%s %s%s%s\n' "$C_WHT" "mode" "$C_RESET" "$C_DIM" "$(mode_label)" "$C_RESET"
  rule
  printf ' %s%s1%s  %sstart hopping%s\n'  "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "$C_RESET"
  printf ' %s%s2%s  %ssettings%s\n'       "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "$C_RESET"
  printf ' %s%s3%s  %supdate links%s\n'   "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "$C_RESET"
  printf ' %s%s0%s  %sexit%s\n'           "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "$C_RESET"
  rule
  printf ' %sselect 1-3 / 0%s ' "$C_DIM" "$C_RESET"
}

# ============================================================================
#  SETTINGS
# ============================================================================
sv(){ printf '%s%s%s' "$C_DIM" "$(trunc "$1" $(( W>40 ? W-20 : 20 )))" "$C_RESET"; }
render_settings(){
  fit; clr
  hdr "rfhop  settings" "saturnity"
  rule
  local cv; if [ "$SPLIT_MODE" = auto ]; then cv="(auto)"; else cv="$CHUNK"; fi
  local _c
  for _c in $(seq 1 $NCLONES); do
    local _pv="C${_c}_PKG" _slv="C${_c}_SLOT" _pk
    _pk=${!_pv}; if [ -z "$_pk" ]; then _pk="(none)"; else _pk=${_pk##*.}; fi
    printf ' %s%s%d%s  %s%-8s%s %-14s %sslot %s%s\n' \
      "$C_BRAND" "$B" "$_c" "$C_RESET" "$C_WHT" "clone$_c" "$C_RESET" \
      "$(sv "$_pk")" "$C_DIM" "${!_slv}" "$C_RESET"
  done
  printf ' %s%s7%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "master file"    "$C_RESET" "$(sv "${MASTER##*/}")"
  printf ' %s%sU%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "links url"      "$C_RESET" "$(sv "${LINKS_URL##*/}")"
  printf ' %s%s8%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "load wait"      "$C_RESET" "$(sv "${LOAD_WAIT}s")"
  printf ' %s%s9%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "hold time"      "$C_RESET" "$(sv "${HOLD_TIME}s")"
  printf ' %s%sM%s  %s%-15s%s %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "split mode" "$C_RESET" "$C_GRN" "$SPLIT_MODE" "$C_RESET"
  printf ' %s%sC%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "links per slot" "$C_RESET" "$(sv "$cv")"
  printf ' %s%sG%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "stagger step"   "$C_RESET" "$(sv "${STAGGER}s")"
  printf ' %s%sL%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "launch tmpl"    "$C_RESET" "$(sv "$LAUNCH_TMPL")"
  printf ' %s%sW%s  %s%-15s%s %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "wakelock" "$C_RESET" "$([ "$WAKELOCK" = on ] && echo "$C_GRN" || echo "$C_DIM")" "$WAKELOCK" "$C_RESET"
  printf ' %s%sA%s  %s%-15s%s %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "termux-api" "$C_RESET" "$([ "$TERMUX_API" = on ] && echo "$C_GRN" || echo "$C_DIM")" "$TERMUX_API" "$C_RESET"
  printf ' %s%sN%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "device name"    "$C_RESET" "$(sv "${DEVICE_NAME:-none}")"
  printf ' %s%sR%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "report url"     "$C_RESET" "$(sv "${REPORT_URL:-none}")"
  printf ' %s%sY%s  %s%-15s%s %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "reporting" "$C_RESET" "$([ "$REPORT" = on ] && echo "$C_GRN" || echo "$C_DIM")" "$REPORT" "$C_RESET"
  printf ' %s%sX%s  %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_DIM" "reset to defaults" "$C_RESET"
  printf ' %s%sT%s  %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "test launch clone1" "$C_RESET"
  rule
  printf ' %s%sS%s %ssave%s   %s%s0%s %sback%s   %sapplies on next start%s ' \
    "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "$C_RESET" "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "$C_RESET" "$C_DIM" "$C_RESET"
}

edit_val(){                # $1=varname $2=prompt $3=type(int|str)
  local -n V=$1
  show_cursor; cook
  printf '\n %s%s%s\n %scurrent:%s %s%s%s\n %s>%s ' \
    "$C_WHT" "$2" "$C_RESET" "$C_DIM" "$C_RESET" "$C_TXT" "$V" "$C_RESET" "$C_BRAND" "$C_RESET"
  local in; IFS= read -r in
  [ -z "$in" ] && return
  if [ "$3" = int ]; then case $in in ''|*[!0-9]*) flash "not a number"; return;; esac; fi
  V=$in
  case $1 in C1_SLOT|C2_SLOT) [ "$V" -lt 1 ] && V=1; [ "$V" -gt $NSLOTS ] && V=$NSLOTS;; esac
  case $1 in LOAD_WAIT|HOLD_TIME|CHUNK) [ "$V" -lt 1 ] && V=1;; esac
}

edit_clone(){              # $1 = clone number: pick package, then set its slot
  edit_pkg "$1"
  edit_val "C${1}_SLOT" "clone$1 slot (1-$NSLOTS)" int
}
edit_pkg(){                # $1 = clone number
  detect_pkgs
  show_cursor; cook; clr
  hdr "pick package · clone$1" "saturnity"; rule
  if [ ${#PKGS[@]} -eq 0 ]; then
    printf ' %sno roblox packages detected.%s\n' "$C_YEL" "$C_RESET"
    printf ' %stype a package name manually:%s\n %s>%s ' "$C_DIM" "$C_RESET" "$C_BRAND" "$C_RESET"
    local m; IFS= read -r m
    [ -n "$m" ] && printf -v "C${1}_PKG" '%s' "$m"
    return
  fi
  local i
  for i in "${!PKGS[@]}"; do
    printf ' %s%s%2d%s  %s%s%s\n' "$C_BRAND" "$B" $((i+1)) "$C_RESET" "$C_WHT" "${PKGS[$i]}" "$C_RESET"
  done
  rule
  printf ' %sselect 1-%d / 0 cancel%s ' "$C_DIM" "${#PKGS[@]}" "$C_RESET"
  local k; read -rsn2 k
  case $k in ''|*[!0-9]*) return;; esac
  [ "$k" -ge 1 ] && [ "$k" -le ${#PKGS[@]} ] || return
  printf -v "C${1}_PKG" '%s' "${PKGS[$((k-1))]}"
}

screen_test(){
  show_cursor; cook; clr
  hdr "test launch · clone1" "saturnity"; rule
  if [ -z "$C1_PKG" ]; then flash "set clone1 package first (option 1)"; return; fi
  reload_master
  local url; url=$(slot_links "$C1_SLOT" | head -1)
  [ -z "$url" ] && url="https://www.roblox.com/games/920587237/Adopt-Me"
  printf ' %spkg%s  %s%s%s\n' "$C_DIM" "$C_RESET" "$C_WHT" "$C1_PKG" "$C_RESET"
  printf ' %surl%s  %s%s%s\n\n' "$C_DIM" "$C_RESET" "$C_TXT" "$(trunc "$url" $((W-6)))" "$C_RESET"
  printf ' %slaunching...%s\n\n' "$C_DIM" "$C_RESET"
  if launch_clone "$C1_PKG" "$url"; then
    printf ' %s%sOK%s  clone opened\n' "$C_GRN" "$B" "$C_RESET"
  else
    printf ' %s%sFAILED%s\n' "$C_RED" "$B" "$C_RESET"
  fi
  printf ' %s%s%s\n' "$C_DIM" "$(printf '%s' "$LAST_OUT" | tail -2)" "$C_RESET"
  printf '\n %spress enter%s ' "$C_DIM" "$C_RESET"
  read -r _
}

reset_defaults(){         # wipe config and restore shipped defaults
  clr; hdr "rfhop  reset" "saturnity"; rule
  printf ' %sthis clears this device'"'"'s saved settings%s\n' "$C_WHT" "$C_RESET"
  printf ' %spackages, slots, device name, report url, timings%s\n\n' "$C_DIM" "$C_RESET"
  show_cursor; cook
  printf ' %stype%s %sRESET%s %sto confirm, anything else cancels:%s ' \
    "$C_DIM" "$C_RESET" "$C_YEL$B" "$C_RESET" "$C_DIM" "$C_RESET"
  local ans; IFS= read -r ans
  hide_cursor
  if [ "$ans" != "RESET" ]; then flash "cancelled"; return; fi
  rm -f "$CONF" 2>/dev/null
  rm -f "$CONF_DIR"/acct_* "$CONF_DIR"/pres_* 2>/dev/null   # cached accounts/presence too
  # restore shipped defaults
  NCLONES=2
  C1_PKG="com.roblox.clienv"; C2_PKG="com.roblox.clienw"
  C3_PKG=""; C4_PKG=""; C5_PKG=""; C6_PKG=""
  C1_SLOT=1; C2_SLOT=2; C3_SLOT=3; C4_SLOT=4; C5_SLOT=5; C6_SLOT=6
  MASTER="$CONF_DIR/links.txt"
  LINKS_URL="https://raw.githubusercontent.com/lucivaantarez/rfhop/main/links.txt"
  SPLIT_MODE="auto"; CHUNK=50
  LOAD_WAIT=20; HOLD_TIME=180; STAGGER=100
  WAKELOCK="on"; TERMUX_API="off"
  REPORT="off"; DEVICE_NAME=""; REPORT_URL=""
  flash "reset to defaults - set slots + device name, then S to save"
}

screen_settings(){
  while :; do
    render_settings
    show_cursor; cook
    local k; read -rsn1 k
    case $k in
      [1-6]) edit_clone "$k";;
      7) edit_val MASTER "master file path" str; reload_master;;
      u|U) edit_val LINKS_URL "links url (raw github .txt)" str;;
      8) edit_val LOAD_WAIT "load wait seconds" int;;
      9) edit_val HOLD_TIME "hold time seconds" int;;
      m|M) [ "$SPLIT_MODE" = auto ] && SPLIT_MODE=fixed || SPLIT_MODE=auto;;
      c|C) if [ "$SPLIT_MODE" = fixed ]; then edit_val CHUNK "links per slot" int; else flash "links per slot only applies in fixed mode"; fi;;
      g|G) edit_val STAGGER "stagger step seconds" int;;
      l|L) edit_val LAUNCH_TMPL "launch template (%PKG% %URL%)" str;;
      w|W) [ "$WAKELOCK" = on ] && WAKELOCK=off || WAKELOCK=on;;
      a|A) [ "$TERMUX_API" = on ] && TERMUX_API=off || TERMUX_API=on;;
      n|N) edit_val DEVICE_NAME "device name (e.g. RF01)" str;;
      r|R) edit_val REPORT_URL "worker /report url" str;;
      y|Y) [ "$REPORT" = on ] && REPORT=off || REPORT=on;;
      x|X) reset_defaults;;
      t|T) screen_test;;
      s|S) save_cfg; flash "saved";;
      0) return;;
    esac
  done
}

# ============================================================================
#  RUN LOOP  (the live dashboard)
# ============================================================================
idx1=-1;idx2=-1;idx3=-1;idx4=-1;idx5=-1;idx6=-1; ph1=NONE;ph2=NONE;ph3=NONE;ph4=NONE;ph5=NONE;ph6=NONE; te1=0;te2=0;te3=0;te4=0;te5=0;te6=0; lh1=0;lh2=0;lh3=0;lh4=0;lh5=0;lh6=0; sn1=0;sn2=0;sn3=0;sn4=0;sn5=0;sn6=0; dirty=1
c1_links=(); c2_links=()
hops=0; wraps=0; paused=0; t0=0

set_lasthop(){            # $1=clone number -> stamp last hop time
  case $1 in 1) lh1=$(now);; 2) lh2=$(now);; 3) lh3=$(now);; 4) lh4=$(now);; 5) lh5=$(now);; 6) lh6=$(now);; esac
}

set_since(){              # $1=clone number -> stamp when this clone entered its phase
  case $1 in 1) sn1=$(now);; 2) sn2=$(now);; 3) sn3=$(now);; 4) sn4=$(now);; 5) sn5=$(now);; 6) sn6=$(now);; esac
}

advance(){                 # $1 = clone number  (a hop: stop -> next link -> launch)
  local c=$1
  local -n IDX=idx$c TE=te$c PH=ph$c LINKS=c${c}_links
  local pkg; pkg=$(pkg_of "$c")
  local n=${#LINKS[@]}
  [ "$n" -eq 0 ] && { PH=NONE; return; }
  stop_clone "$pkg"
  local prev=$IDX
  IDX=$(( (IDX+1) % n ))
  local hu=$((IDX+1))
  local url="${LINKS[$IDX]}" tag=""
  if [ "$prev" -lt 0 ]; then
    log INFO "clone$c open link $hu/$n"
  else
    if [ "$IDX" -eq 0 ]; then
      wraps=$((wraps+1))
      # finished my own slot -> if I'm covering a stuck clone, sweep its slot now
      local orph; orph=$(get_i ov "$c")
      if [ "$orph" != 0 ]; then
        local -n OL=c${orph}_links
        local on=${#OL[@]}
        if [ "$on" -gt 0 ]; then
          local oi; oi=$(( $(get_i sweep "$c") % on ))
          url="${OL[$oi]}"; tag=" (sweeping clone$orph $((oi+1))/$on)"
          set_i sweep "$c" $(( oi + 1 ))
          [ $(( oi + 1 )) -ge "$on" ] && set_i sweep "$c" 0
        fi
      else
        log WARN "clone$c slot end -> wrap to 01"
      fi
    fi
    log INFO "clone$c hop $((prev+1))->$hu$tag"
  fi
  if ! launch_clone "$pkg" "$url"; then
    log ERRO "clone$c launch failed: $(printf '%s' "$LAST_OUT" | tail -1)"
  fi
  PH=LOAD; TE=$(( $(now) + LOAD_WAIT )); set_since "$c"
  set_lasthop "$c"
}

# ---- captcha takeover: a stuck clone's slot is swept by a healthy sibling -----
# stk<c> = consecutive failed join checks   ov<c> = clone number whose slot c is sweeping
stk1=0;stk2=0;stk3=0;stk4=0;stk5=0;stk6=0
ov1=0;ov2=0;ov3=0;ov4=0;ov5=0;ov6=0
sweep1=0;sweep2=0;sweep3=0;sweep4=0;sweep5=0;sweep6=0
RETRY_CAP=${RETRY_CAP:-3}          # failed checks before the slot is handed over

get_i(){ local v="$1$2"; echo "${!v:-0}"; }          # get_i stk 3  -> $stk3
set_i(){ eval "$1$2=$3"; }                            # set_i stk 3 1

# is this clone actually in game? uses the cached presence check
clone_in_game(){           # $1=clone number -> 0 yes / 1 no
  local c=$1 pkg acct uid
  pkg=$(pkg_of "$c"); [ -n "$pkg" ] || return 1
  acct=$(resolve_acct "$pkg"); uid=${acct##*|}
  [ -n "$uid" ] || return 0                           # no uid -> can't tell, assume ok
  [ "$(presence_status "$uid" "in game")" = "in game" ]
}

# find a healthy clone that can sweep clone $1's slot (not already sweeping)
find_sweeper(){            # $1 = orphaned clone number -> echoes clone number or nothing
  local orphan=$1 c
  for c in $(seq 1 "$NCLONES"); do
    [ "$c" = "$orphan" ] && continue
    local phv="ph$c"; [ "${!phv}" = NONE ] && continue
    [ "$(get_i ov "$c")" != 0 ] && continue           # already covering something
    [ "$(get_i stk "$c")" -ge "$RETRY_CAP" ] && continue   # itself stuck
    echo "$c"; return 0
  done
}

# give clone $1's slot to a healthy sibling (sequential: sweeper finishes its own first)
hand_over(){               # $1 = stuck clone number
  local orphan=$1
  [ "$(get_i ov "$orphan")" != 0 ] && return           # already handed over
  local sw; sw=$(find_sweeper "$orphan")
  if [ -z "$sw" ]; then log WARN "clone$orphan stuck, no healthy clone free to sweep"; return; fi
  set_i ov "$sw" "$orphan"
  log WARN "clone$orphan stuck -> clone$sw will sweep its slot after its own"
}

# stuck clone recovered: pull its slot back from whoever was sweeping it
reclaim_slot(){            # $1 = recovered clone number
  local me=$1 c
  for c in $(seq 1 "$NCLONES"); do
    if [ "$(get_i ov "$c")" = "$me" ]; then
      set_i ov "$c" 0
      log INFO "clone$me recovered -> clone$c returns to its own slot"
    fi
  done
}

tickphase(){               # $1 = clone number
  local c=$1
  local -n TE=te$c PH=ph$c
  [ "$PH" = NONE ] && return
  local T; T=$(now)
  if [ "$T" -ge "$TE" ]; then
    case $PH in
      WAIT) advance "$c" ;;
      LOAD)
        if clone_in_game "$c"; then
          set_i stk "$c" 0
          PH=HOLD; TE=$(( T + HOLD_TIME )); set_since "$c"
          hops=$((hops+1))                              # only count confirmed joins
          log INFO "clone$c joined, hold ${HOLD_TIME}s"
          reclaim_slot "$c"                             # recovered -> take my slot back
        else
          local k; k=$(( $(get_i stk "$c") + 1 )); set_i stk "$c" "$k"
          log WARN "clone$c not in game (try $k/$RETRY_CAP)"
          [ "$k" -eq "$RETRY_CAP" ] && hand_over "$c"   # cap reached -> sibling sweeps my slot
          PH=LOAD; TE=$(( T + 60 ))                     # keep rechecking this same link
        fi ;;
      HOLD) advance "$c" ;;
    esac
  fi
}

clone_line(){              # $1 = clone number
  local c=$1
  local -n IDX=idx$c PH=ph$c TE=te$c LINKS=c${c}_links
  local pkg; pkg=$(pkg_of "$c")
  local short=${pkg##*.} n=${#LINKS[@]}
  local dot tagcol tag s2 linktxt
  case $PH in
    HOLD) dot=$C_GRN; tagcol=$C_GRN; tag=HOLD; s2="in server · next hop $(fmt_clock $TE)";;
    LOAD) dot=$C_YEL; tagcol=$C_YEL; tag=LOAD; s2="opening · joins ~$(fmt_clock $TE)";;
    WAIT) dot=$C_YEL; tagcol=$C_DIM; tag=WAIT; s2="queued · opens $(fmt_clock $TE)";;
    *)    dot=$C_DIM; tagcol=$C_DIM; tag=IDLE; s2="empty slot";;
  esac
  if [ "$PH" = NONE ]; then
    linktxt="link --/--"
  elif [ "$IDX" -lt 0 ]; then
    linktxt=$(printf 'link --/%02d' "$n")
  else
    linktxt=$(printf 'link %02d/%02d' "$((IDX+1))" "$n")
  fi
  printf ' %s●%s  %s%-6s%s %s%-7s%s %s%-10s%s  %s%s%-4s%s\n' \
    "$dot" "$C_RESET" "$C_WHT" "clone$c" "$C_RESET" "$C_DIM" "$short" "$C_RESET" \
    "$C_WHT" "$linktxt" "$C_RESET" "$tagcol" "$B" "$tag" "$C_RESET"
  printf '            %s%s%s\n' "$C_DIM" "$s2" "$C_RESET"
}

render_run(){
  fit; clr
  local nc=0 c phv
  for c in $(seq 1 $NCLONES); do phv="ph$c"; [ "${!phv}" != NONE ] && nc=$((nc+1)); done
  hdr "rfhop  v$VERSION" "saturnity"
  printf '%sredfinger · %d clone%s · %s%s\n' "$C_DIM" "$nc" "$([ "$nc" = 1 ] && echo '' || echo s)" "$(mode_label)" "$C_RESET"
  rule
  for c in $(seq 1 $NCLONES); do phv="ph$c"; [ "${!phv}" != NONE ] && clone_line "$c"; done
  rule
  printf ' %scycle%s  %s%ss load + %ss hold%s   %sstagger%s %s%ss%s\n' \
    "$C_DIM" "$C_RESET" "$C_WHT" "$LOAD_WAIT" "$HOLD_TIME" "$C_RESET" "$C_DIM" "$C_RESET" "$C_WHT" "$STAGGER" "$C_RESET"
  local up=$(( $(now) - t0 ))
  printf ' %suptime%s %s%s%s    %shops%s %s%s%s   %swraps%s %s%s%s\n' \
    "$C_DIM" "$C_RESET" "$C_WHT" "$(fmt_up $up)" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$C_WHT" "$hops" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$C_WHT" "$wraps" "$C_RESET"
  rule
  local i start=$(( ${#LOG[@]} - 8 )); [ $start -lt 0 ] && start=0
  for (( i=start; i<${#LOG[@]}; i++ )); do print_log_line "${LOG[$i]}"; done
  rule
  if [ "$paused" -eq 1 ]; then
    printf ' %s%sPAUSED%s   %sP%s resume   %shop%s %s1-%s%s   %sQ%s quit\n' \
      "$C_YEL" "$B" "$C_RESET" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET" "$C_WHT" "$nc" "$C_RESET" "$C_DIM" "$C_RESET"
  else
    printf ' %sP%s pause   %shop%s %s1-%s%s   %sQ%s quit\n' \
      "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET" "$C_WHT" "$nc" "$C_RESET" "$C_DIM" "$C_RESET"
  fi
}

# ---- discord dashboard reporting (via cloudflare worker) -------------------
# resolve "username|userId" from a clone's ROBLOSECURITY cookie (cached per pkg).
# returns empty if logged out or the cookie value is encrypted/unreadable.
resolve_acct(){            # $1=pkg
  local pkg=$1 cache="$CONF_DIR/acct_$pkg"
  [ -f "$cache" ] && { cat "$cache"; return; }
  local db="/data/data/$pkg/app_webview/Default/Cookies"
  local ck; ck=$(su -c "$SQLITE '$db' \"SELECT value FROM cookies WHERE name LIKE '%ROBLOSECURITY%' AND length(value)>0 LIMIT 1;\"" 2>/dev/null)
  [ -n "$ck" ] || return 0
  local j; j=$(curl -fsS -m 8 'https://users.roblox.com/v1/users/authenticated' -H "Cookie: .ROBLOSECURITY=$ck" 2>/dev/null)
  local uid name
  uid=$(printf '%s' "$j" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')
  name=$(printf '%s' "$j" | grep -oE '"name":"[^"]*"' | head -1 | sed 's/.*"name":"//; s/".*//')
  [ -n "$uid" ] || return 0
  printf '%s|%s' "$name" "$uid" | tee "$cache"
}

# presence-based status for a userId; falls back to $2 if unavailable.
# userPresenceType: 0 offline · 1 online(not in game = captcha/menu) · 2 in game
presence_status(){        # $1=userId $2=fallback  (cached with TTL to avoid rate-limits)
  local uid=$1 fb=$2
  [ -n "$uid" ] || { printf '%s' "$fb"; return; }
  local cache="$CONF_DIR/pres_$uid" ttl=${PRESENCE_TTL:-30} nowt ts val
  nowt=$(now)
  if [ -f "$cache" ]; then
    IFS='|' read -r ts val < "$cache"
    [ -n "$ts" ] && [ $(( nowt - ts )) -lt "$ttl" ] && { printf '%s' "$val"; return; }
  fi
  local j; j=$(curl -fsS -m 8 'https://presence.roblox.com/v1/presence/users' \
        -H 'content-type: application/json' -d "{\"userIds\":[$uid]}" 2>/dev/null)
  local t; t=$(printf '%s' "$j" | grep -oE '"userPresenceType":[0-9]+' | head -1 | grep -oE '[0-9]+$')
  local out
  case $t in
    2) out='in game';;
    1) out='captcha';;
    0) out='dead';;
    *) out=$fb;;
  esac
  printf '%s|%s' "$nowt" "$out" > "$cache" 2>/dev/null
  printf '%s' "$out"
}

# build one clone's JSON object
clone_json(){             # $1=clone number
  local c=$1
  local phv="ph$c" idxv="idx$c" lhv="lh$c" snv="sn$c" lv="c${c}_links[@]"
  local PH=${!phv} IDX=${!idxv} LH=${!lhv} SN=${!snv}
  local pkg; pkg=$(pkg_of "$c")
  [ -n "$pkg" ] || return 1
  local links=( ${!lv} ) n=${#links[@]} link=0
  [ "$IDX" -ge 0 ] && link=$((IDX+1))
  local st; case $PH in HOLD) st="in game";; LOAD) st="joining";; WAIT) st="queued";; *) st="dead";; esac
  local user="" uid="" acct; acct=$(resolve_acct "$pkg"); user=${acct%%|*}; uid=${acct##*|}
  [ "$user" = "$uid" ] && user=""
  # refine HOLD -> real presence (captcha detection) when we know the userId
  [ "$PH" = HOLD ] && [ -n "$uid" ] && st=$(presence_status "$uid" "in game")
  user=${user//\"/}       # sanitise for JSON
  printf '{"pkg":"%s","user":"%s","link":%d,"max":%d,"status":"%s","lastHop":%d,"since":%d}' \
    "${pkg##*.}" "$user" "$link" "$n" "$st" "${LH:-0}" "${SN:-0}"
}

# POST current state to the worker (backgrounded so it never blocks the loop)
report_state(){
  [ "$REPORT" = on ] && [ -n "$REPORT_URL" ] && [ -n "$DEVICE_NAME" ] || return 0
  local tsf="$CONF_DIR/.report_ts" nowt lt; nowt=$(now)
  lt=$(cat "$tsf" 2>/dev/null || echo 0)
  [ $(( nowt - lt )) -lt "${REPORT_MIN:-8}" ] && return 0   # throttle: at most one report / 8s
  echo "$nowt" > "$tsf" 2>/dev/null
  { local parts=() c j
    for c in $(seq 1 $NCLONES); do j=$(clone_json "$c") && parts+=("$j"); done
    local body clones; clones=$(IFS=,; echo "${parts[*]}")
    body="{\"device\":\"$DEVICE_NAME\",\"hops\":${hops:-0},\"wraps\":${wraps:-0},\"clones\":[$clones]}"
    curl -fsS -m 10 -X POST "$REPORT_URL" -H 'content-type: application/json' -d "$body" >/dev/null 2>&1
  } &
}
setup_clone(){             # $1 = clone number  (build links + init phase, staggered)
  local c=$1 pkg; pkg=$(pkg_of "$c")
  local -n LK=c${c}_links PH=ph$c TE=te$c IDX=idx$c LH=lh$c
  LK=(); IDX=-1; LH=0
  if [ -z "$pkg" ]; then PH=NONE; return; fi
  local l; while IFS= read -r l; do LK+=("$l"); done < <(slot_links "$(slot_of "$c")")
  if [ ${#LK[@]} -gt 0 ]; then PH=WAIT; TE=$(( $(now) + (c-1)*STAGGER )); set_since "$c"; else PH=NONE; log WARN "clone$c slot $(slot_of "$c") empty"; fi
}
run_loop(){
  reload_master
  if [ "$MASTER_N" -eq 0 ]; then flash "no links loaded - set master file (settings, 7)"; return; fi
  local _any="" _c
  for _c in $(seq 1 $NCLONES); do [ -n "$(pkg_of $_c)" ] && _any=1; done
  [ -z "$_any" ] && { flash "set at least one clone package in settings"; return; }

  hops=0; wraps=0; paused=0; t0=$(now); LOG=(); dirty=1; local last_report=0
  local c; for c in $(seq 1 $NCLONES); do setup_clone "$c"; done


  wake_on; hide_cursor
  local key
  while :; do
    if [ "$paused" -eq 0 ]; then
      for c in $(seq 1 $NCLONES); do tickphase "$c"; done
    else
      for c in $(seq 1 $NCLONES); do phv="ph$c"; tev="te$c"; [ "${!phv}" != NONE ] && printf -v "$tev" '%d' "$(( ${!tev} + 1 ))"; done
    fi
    [ "$dirty" -eq 1 ] && { render_run; dirty=0; report_state; last_report=$(now); }
    if [ $(( $(now) - last_report )) -ge 25 ]; then report_state; last_report=$(now); fi
    if read -rsn1 -t 1 key; then
      case $key in
        p|P) [ "$paused" -eq 1 ] && { paused=0; log INFO "resumed"; } || { paused=1; log INFO "paused"; } ;;
        [1-6]) phv="ph$key"; [ "${!phv}" != NONE ] && advance "$key" ;;
        q|Q|0) break ;;
      esac
    fi
  done
  wake_off; show_cursor; cook
}

# ---- non-interactive setup: rfhop --setup RF01 1 2 [report_url] ---------------
cli_setup(){
  local dev=$1 s1=$2 s2=$3 url=$4
  if [ -z "$dev" ] || [ -z "$s1" ] || [ -z "$s2" ]; then
    printf 'usage:   rfhop --setup <device> <slot1> <slot2> [report_url]\n'
    printf 'example: rfhop --setup RF01 1 2 https://saturnity-hop.susilobambangyowaimo.workers.dev/report\n'
    return 1
  fi
  mkdir -p "$CONF_DIR"
  load_cfg 2>/dev/null
  DEVICE_NAME=$dev
  C1_SLOT=$s1; C2_SLOT=$s2
  C1_PKG="com.roblox.clienv"; C2_PKG="com.roblox.clienw"
  C3_PKG=""; C4_PKG=""; C5_PKG=""; C6_PKG=""
  NCLONES=2
  if [ -n "$url" ]; then REPORT_URL=$url; REPORT="on"; fi
  save_cfg
  printf '%s configured: clienv->slot %s, clienw->slot %s%s\n' \
    "$dev" "$s1" "$s2" "$([ -n "$url" ] && printf ', reporting on' || printf '')"
}

# ============================================================================
#  MAIN
# ============================================================================
main(){
  mkdir -p "$CONF_DIR"
  load_cfg
  detect_pkgs
  [ -z "$C1_PKG" ] && [ ${#PKGS[@]} -ge 1 ] && C1_PKG=${PKGS[0]}
  [ -z "$C2_PKG" ] && [ ${#PKGS[@]} -ge 2 ] && C2_PKG=${PKGS[1]}
  reload_master
  while :; do
    render_home
    show_cursor; cook
    local k; read -rsn1 k
    case $k in
      1) run_loop ;;
      2) screen_settings ;;
      3) update_links ;;
      0|q|Q) clr; show_cursor; exit 0 ;;
    esac
  done
}

if [ "${RFHOP_TEST:-}" != "1" ]; then
  case ${1:-} in
    --setup) shift; cli_setup "$@"; exit $? ;;
    --show)  load_cfg 2>/dev/null; printf 'device=%s c1=%s slot %s · c2=%s slot %s · report=%s\n' \
               "${DEVICE_NAME:-none}" "${C1_PKG##*.}" "$C1_SLOT" "${C2_PKG##*.}" "$C2_SLOT" "$REPORT"; exit 0 ;;
  esac
  main
fi
