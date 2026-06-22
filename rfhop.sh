#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
#  rfhop  v2.1.0   —   Saturnity Roblox private-server hopper (Redfinger)
#  Rooted Redfinger, App Cloner Roblox clones, 2 clones per device.
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

VERSION="2.1.2"
NSLOTS=20

CONF_DIR="$HOME/.rfhop"
CONF="$CONF_DIR/config"

# ---- defaults (overridden by config) --------------------------------------
C1_PKG=""
C2_PKG=""
C1_SLOT=1
C2_SLOT=2
MASTER="$CONF_DIR/links.txt"
REPO_RAW="https://raw.githubusercontent.com/lucivaantarez/rfhop/main"   # for option 3 link sync
SPLIT_MODE="auto"          # auto | fixed
CHUNK=50                   # only used when SPLIT_MODE=fixed
LOAD_WAIT=20               # seconds to settle after launch
HOLD_TIME=180              # seconds to stay in a server
STAGGER=100                # seconds clone2 starts behind clone1
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
      c1_pkg) C1_PKG=$v;;  c2_pkg) C2_PKG=$v;;
      c1_slot) C1_SLOT=$v;; c2_slot) C2_SLOT=$v;;
      master) MASTER=$v;;  split_mode) SPLIT_MODE=$v;;
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
    echo "c1_pkg=$C1_PKG";   echo "c2_pkg=$C2_PKG"
    echo "c1_slot=$C1_SLOT"; echo "c2_slot=$C2_SLOT"
    echo "master=$MASTER";   echo "split_mode=$SPLIT_MODE"
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
  if curl -fsSL "$REPO_RAW/links.txt" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
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
  printf ' %s%s1%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "clone1 package" "$C_RESET" "$(sv "${C1_PKG:-none}")"
  printf ' %s%s2%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "clone1 slot"    "$C_RESET" "$(sv "$C1_SLOT")"
  printf ' %s%s3%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "clone2 package" "$C_RESET" "$(sv "${C2_PKG:-none}")"
  printf ' %s%s4%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "clone2 slot"    "$C_RESET" "$(sv "$C2_SLOT")"
  printf ' %s%s5%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "master file"    "$C_RESET" "$(sv "${MASTER##*/}")"
  printf ' %s%s6%s  %s%-15s%s %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "split mode" "$C_RESET" "$C_GRN" "$SPLIT_MODE" "$C_RESET"
  printf ' %s%s7%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "links per slot" "$C_RESET" "$(sv "$cv")"
  printf ' %s%s8%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "load wait"      "$C_RESET" "$(sv "${LOAD_WAIT}s")"
  printf ' %s%s9%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "hold time"      "$C_RESET" "$(sv "${HOLD_TIME}s")"
  printf ' %s%sG%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "stagger clone2" "$C_RESET" "$(sv "${STAGGER}s")"
  printf ' %s%sL%s  %s%-15s%s %s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "launch tmpl"    "$C_RESET" "$(sv "$LAUNCH_TMPL")"
  printf ' %s%sW%s  %s%-15s%s %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "wakelock" "$C_RESET" "$([ "$WAKELOCK" = on ] && echo "$C_GRN" || echo "$C_DIM")" "$WAKELOCK" "$C_RESET"
  printf ' %s%sA%s  %s%-15s%s %s%s%s\n' "$C_BRAND" "$B" "$C_RESET" "$C_WHT" "termux-api" "$C_RESET" "$([ "$TERMUX_API" = on ] && echo "$C_GRN" || echo "$C_DIM")" "$TERMUX_API" "$C_RESET"
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

edit_pkg(){                # $1 = clone number
  detect_pkgs
  show_cursor; cook; clr
  hdr "pick package · clone$1" "saturnity"; rule
  if [ ${#PKGS[@]} -eq 0 ]; then
    printf ' %sno roblox packages detected.%s\n' "$C_YEL" "$C_RESET"
    printf ' %stype a package name manually:%s\n %s>%s ' "$C_DIM" "$C_RESET" "$C_BRAND" "$C_RESET"
    local m; IFS= read -r m
    [ -n "$m" ] && { [ "$1" = 1 ] && C1_PKG=$m || C2_PKG=$m; }
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
  if [ "$1" = 1 ]; then C1_PKG=${PKGS[$((k-1))]}; else C2_PKG=${PKGS[$((k-1))]}; fi
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

screen_settings(){
  while :; do
    render_settings
    show_cursor; cook
    local k; read -rsn1 k
    case $k in
      1) edit_pkg 1;;
      2) edit_val C1_SLOT "clone1 slot (1-$NSLOTS)" int;;
      3) edit_pkg 2;;
      4) edit_val C2_SLOT "clone2 slot (1-$NSLOTS)" int;;
      5) edit_val MASTER "master file path" str; reload_master;;
      6) [ "$SPLIT_MODE" = auto ] && SPLIT_MODE=fixed || SPLIT_MODE=auto;;
      7) if [ "$SPLIT_MODE" = fixed ]; then edit_val CHUNK "links per slot" int; else flash "links per slot only applies in fixed mode"; fi;;
      8) edit_val LOAD_WAIT "load wait seconds" int;;
      9) edit_val HOLD_TIME "hold time seconds" int;;
      g|G) edit_val STAGGER "clone2 stagger seconds" int;;
      l|L) edit_val LAUNCH_TMPL "launch template (%PKG% %URL%)" str;;
      w|W) [ "$WAKELOCK" = on ] && WAKELOCK=off || WAKELOCK=on;;
      a|A) [ "$TERMUX_API" = on ] && TERMUX_API=off || TERMUX_API=on;;
      t|T) screen_test;;
      s|S) save_cfg; flash "saved";;
      0) return;;
    esac
  done
}

# ============================================================================
#  RUN LOOP  (the live dashboard)
# ============================================================================
idx1=-1; idx2=-1; ph1=NONE; ph2=NONE; te1=0; te2=0
c1_links=(); c2_links=()
hops=0; wraps=0; paused=0; t0=0

advance(){                 # $1 = clone number  (a hop: stop -> next link -> launch)
  local c=$1
  local -n IDX=idx$c TE=te$c PH=ph$c LINKS=c${c}_links
  local pkg; [ "$c" = 1 ] && pkg=$C1_PKG || pkg=$C2_PKG
  local n=${#LINKS[@]}
  [ "$n" -eq 0 ] && { PH=NONE; return; }
  stop_clone "$pkg"
  local prev=$IDX
  IDX=$(( (IDX+1) % n ))
  local hu=$((IDX+1))
  if [ "$prev" -lt 0 ]; then
    log INFO "clone$c start link $hu/$n"
  else
    if [ "$IDX" -eq 0 ]; then wraps=$((wraps+1)); log WARN "clone$c slot end -> wrap to 01"; fi
    log INFO "clone$c hop $((prev+1))->$hu"
  fi
  log DEBU "am ${pkg##*.}/..ProtocolLaunch"
  if ! launch_clone "$pkg" "${LINKS[$IDX]}"; then
    log ERRO "clone$c launch failed: $(printf '%s' "$LAST_OUT" | tail -1)"
  fi
  PH=LOAD; TE=$(( $(now) + LOAD_WAIT ))
  log INFO "clone$c launching, settle ${LOAD_WAIT}s"
  [ "$prev" -ge 0 ] && hops=$((hops+1))
}

tickphase(){               # $1 = clone number
  local c=$1
  local -n TE=te$c PH=ph$c
  [ "$PH" = NONE ] && return
  local T; T=$(now)
  if [ "$T" -ge "$TE" ]; then
    case $PH in
      WAIT) advance "$c" ;;
      LOAD) PH=HOLD; TE=$(( T + HOLD_TIME )); log INFO "clone$c holding ${HOLD_TIME}s" ;;
      HOLD) advance "$c" ;;
    esac
  fi
}

clone_line(){              # $1 = clone number
  local c=$1
  local -n IDX=idx$c PH=ph$c TE=te$c LINKS=c${c}_links
  local pkg; [ "$c" = 1 ] && pkg=$C1_PKG || pkg=$C2_PKG
  local short=${pkg##*.} n=${#LINKS[@]}
  local rem=$(( TE - $(now) )); [ $rem -lt 0 ] && rem=0
  local dot tagcol tag s2 linktxt
  case $PH in
    HOLD) dot=$C_GRN; tagcol=$C_GRN; tag=HOLD; s2="in server · next hop $(fmt_dur $rem)";;
    LOAD) dot=$C_YEL; tagcol=$C_YEL; tag=LOAD; s2="launching · ready in ${rem}s";;
    WAIT) dot=$C_YEL; tagcol=$C_DIM; tag=WAIT; s2="queued · starts in ${rem}s";;
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
  hdr "rfhop  v$VERSION" "saturnity"
  printf '%sredfinger · 2 clones · %s%s\n' "$C_DIM" "$(mode_label)" "$C_RESET"
  rule
  clone_line 1
  clone_line 2
  rule
  printf ' %scycle%s  %s%ss load + %ss hold%s   %sstagger%s %s%ss%s\n' \
    "$C_DIM" "$C_RESET" "$C_WHT" "$LOAD_WAIT" "$HOLD_TIME" "$C_RESET" "$C_DIM" "$C_RESET" "$C_WHT" "$STAGGER" "$C_RESET"
  local up=$(( $(now) - t0 ))
  printf ' %suptime%s %s%s%s    %shops%s %s%s%s   %swraps%s %s%s%s\n' \
    "$C_DIM" "$C_RESET" "$C_WHT" "$(fmt_up $up)" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$C_WHT" "$hops" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$C_WHT" "$wraps" "$C_RESET"
  rule
  local i start=$(( ${#LOG[@]} - 6 )); [ $start -lt 0 ] && start=0
  for (( i=start; i<${#LOG[@]}; i++ )); do print_log_line "${LOG[$i]}"; done
  rule
  if [ "$paused" -eq 1 ]; then
    printf ' %s%sPAUSED%s   %sP%s resume   %s1%s/%s2%s hop   %sQ%s quit\n' \
      "$C_YEL" "$B" "$C_RESET" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
  else
    printf ' %sP%s pause   %s1%s hop c1   %s2%s hop c2   %sQ%s quit\n' \
      "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
  fi
}

run_loop(){
  reload_master
  if [ "$MASTER_N" -eq 0 ]; then flash "no links loaded - set master file (settings, 5)"; return; fi
  if [ -z "$C1_PKG" ] && [ -z "$C2_PKG" ]; then flash "set clone packages in settings (1 and 3)"; return; fi

  local l
  c1_links=(); while IFS= read -r l; do c1_links+=("$l"); done < <(slot_links "$C1_SLOT")
  c2_links=(); while IFS= read -r l; do c2_links+=("$l"); done < <(slot_links "$C2_SLOT")

  idx1=-1; idx2=-1; hops=0; wraps=0; paused=0; t0=$(now); LOG=()
  if [ ${#c1_links[@]} -gt 0 ]; then ph1=WAIT; te1=$(now); else ph1=NONE; log WARN "clone1 slot $C1_SLOT empty"; fi
  if [ ${#c2_links[@]} -gt 0 ]; then ph2=WAIT; te2=$(( $(now) + STAGGER )); else ph2=NONE; log WARN "clone2 slot $C2_SLOT empty"; fi

  wake_on; hide_cursor
  local key
  while :; do
    if [ "$paused" -eq 0 ]; then
      tickphase 1
      tickphase 2
    else
      [ "$ph1" != NONE ] && te1=$((te1+1))
      [ "$ph2" != NONE ] && te2=$((te2+1))
    fi
    render_run
    if read -rsn1 -t 1 key; then
      case $key in
        p|P) [ "$paused" -eq 1 ] && { paused=0; log INFO "resumed"; } || { paused=1; log INFO "paused"; } ;;
        1)   [ "$ph1" != NONE ] && advance 1 ;;
        2)   [ "$ph2" != NONE ] && advance 2 ;;
        q|Q|0) break ;;
      esac
    fi
  done
  wake_off; show_cursor; cook
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

if [ "${RFHOP_TEST:-}" != "1" ]; then main; fi
