#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  RFHOP  -  Saturnity fleet hopper  (Redfinger, ROOTED)
#  2 Roblox clones per device - timed hopping
#  ONE master links file on github, sliced per clone by slot
#  repo: github.com/lucivaantarez/rfhop
#  v1.3 - master+slot links, ASCII frame, auto-fit, hard refresh,
#         Ctrl-C stops, optional Termux API
# ============================================================
VERSION="1.3.0"

REPO_RAW="https://raw.githubusercontent.com/lucivaantarez/rfhop/main"
DIR="$HOME/.rfhop"; CFG="$DIR/config"
mkdir -p "$DIR"

if [ -z "${NO_COLOR:-}" ]; then
  PINK=$'\033[1;95m'; WHITE=$'\033[1;97m'; CYAN=$'\033[1;96m'
  GREEN=$'\033[1;92m'; YEL=$'\033[1;93m'; RED=$'\033[1;91m'; R=$'\033[0m'
else PINK=; WHITE=; CYAN=; GREEN=; YEL=; RED=; R=; fi

# ---- defaults ----
CLONE1_PKG=""; CLONE2_PKG=""
CLONE1_SLOT=1; CLONE2_SLOT=2
MASTER="links.txt"; CHUNK=50
SETTLE=20; HOLD=180; STAGGER=1; FORCESTOP=1
WAKELOCK=1; TERMUXAPI=0
START_TMPL='am start -n %PKG%/com.roblox.client.startup.ActivityProtocolLaunch -d "%URL%"'
load_config(){ [ -f "$CFG" ] && . "$CFG"; }
save_config(){ { echo "CLONE1_PKG=\"$CLONE1_PKG\""; echo "CLONE2_PKG=\"$CLONE2_PKG\""
  echo "CLONE1_SLOT=$CLONE1_SLOT"; echo "CLONE2_SLOT=$CLONE2_SLOT"
  echo "MASTER=\"$MASTER\""; echo "CHUNK=$CHUNK"
  echo "SETTLE=$SETTLE"; echo "HOLD=$HOLD"; echo "STAGGER=$STAGGER"; echo "FORCESTOP=$FORCESTOP"
  echo "WAKELOCK=$WAKELOCK"; echo "TERMUXAPI=$TERMUXAPI"; echo "START_TMPL='$START_TMPL'"; } > "$CFG"; }

# ---- termux api (optional, graceful) ----
_have(){ command -v "$1" >/dev/null 2>&1; }
NOTIF_ID=7321
wakelock_on(){  ((WAKELOCK==1)) && _have termux-wake-lock   && termux-wake-lock 2>/dev/null; }
wakelock_off(){ _have termux-wake-unlock && termux-wake-unlock 2>/dev/null; }
toast(){  ((TERMUXAPI==1)) && _have termux-toast   && termux-toast -g middle "$1" >/dev/null 2>&1; }
notify(){ ((TERMUXAPI==1)) && _have termux-notification && termux-notification --id "$NOTIF_ID" -t "rfhop" -c "$1" --ongoing >/dev/null 2>&1; }
notify_clear(){ _have termux-notification-remove && termux-notification-remove "$NOTIF_ID" >/dev/null 2>&1; }

# ---- width auto-fit + ASCII frame ----
INNER=38; RULE=""; EMPTY=""
detect_width(){ local w="${COLUMNS:-}"; [ -z "$w" ] && w=$(tput cols 2>/dev/null)
  [[ "$w" =~ ^[0-9]+$ ]] || w=40; INNER=$((w-2)); ((INNER>40))&&INNER=40; ((INNER<24))&&INNER=24; }
build_frame(){ local i b="" s=""; for((i=0;i<INNER;i++)); do b+="-"; s+=" "; done; RULE="+$b+"; EMPTY="|$s|"; }
fit(){ detect_width; build_frame; }
CLR=$'\033[H\033[2J'; clr(){ printf '%s' "$CLR"; }
cleanup(){ printf '\033[0m'; wakelock_off; notify_clear; }
trap 'cleanup; printf "\n"; exit 0' INT TERM

prule(){ printf "%s%s%s\n" "$PINK" "$RULE" "$R"; }
rowc(){ local c="${1:0:INNER}" col="$2" pad; pad=$((INNER-${#c})); ((pad<0))&&pad=0
  printf "%s|%s%s%s%*s%s|%s\n" "$PINK" "$R" "$col" "$c" "$pad" "" "$PINK" "$R"; }
center(){ local t="${1:0:INNER}" col="$2" len pad l r; len=${#t}; pad=$((INNER-len)); l=$((pad/2)); r=$((pad-l))
  printf "%s|%s%*s%s%s%s%*s%s|%s\n" "$PINK" "$R" "$l" "" "$col" "$t" "$R" "$r" "" "$PINK" "$R"; }
kv(){ local lw=8 vw; vw=$((INNER-3-lw))
  printf "%s|%s   %s%-*s%s%s%-*s%s%s|%s\n" "$PINK" "$R" "$CYAN" "$lw" "$1" "$R" "$WHITE" "$vw" "${2:0:$vw}" "$R" "$PINK" "$R"; }
menurow(){ local lw; lw=$((INNER-8))
  printf "%s|%s   %s%s%s    %s%-*s%s%s|%s\n" "$PINK" "$R" "$CYAN" "$1" "$R" "$WHITE" "$lw" "${2:0:$lw}" "$R" "$PINK" "$R"; }
titlerow(){ local col="$2" lft=" RFHOP" rgt="$1 " gap; gap=$((INNER-${#lft}-${#rgt})); ((gap<1))&&gap=1
  printf "%s|%s%s%s%s%*s%s%s%s%s|%s\n" "$PINK" "$R" "$CYAN" "$lft" "$R" "$gap" "" "$col" "$rgt" "$R" "$PINK" "$R"; }
pause_enter(){ printf "  ${PINK}press enter${R} "; read -r _; }
short_pkg(){ printf '%s' "${1##*.}"; }

# ---- master links + slicing ----
ALL=()
fetch_master(){ curl -fsSL "$REPO_RAW/$MASTER" -o "$DIR/$MASTER.tmp" 2>/dev/null && mv "$DIR/$MASTER.tmp" "$DIR/$MASTER"; }
load_master(){ ALL=(); [ -f "$DIR/$MASTER" ] || fetch_master; [ -f "$DIR/$MASTER" ] || return
  local l; while IFS= read -r l || [ -n "$l" ]; do l="${l%$'\r'}"; l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
    [ -z "$l" ] && continue; [ "${l:0:1}" = "#" ] && continue; ALL+=("$l"); done < "$DIR/$MASTER"; }
slice_into(){ local -n a="$1"; local slot="$2"; a=(); local start=$(((slot-1)*CHUNK)) k idx
  for ((k=0;k<CHUNK;k++)); do idx=$((start+k)); [ -n "${ALL[idx]:-}" ] && a+=("${ALL[idx]}"); done; }

# ---- launch (rooted) ----
launch(){ [ -z "$1" ] && return; local cmd="${START_TMPL//%PKG%/$1}"; cmd="${cmd//%URL%/$2}"
  { echo "#!/system/bin/sh"; [ "$FORCESTOP" = 1 ] && { echo "am force-stop $1"; echo "sleep 1"; }; echo "$cmd"; } > "$DIR/.launch.sh"
  su -c "sh $DIR/.launch.sh" >/dev/null 2>&1; }

DETECTED=()
detect_clones(){ DETECTED=(); local out p; out=$(su -c "pm list packages" 2>/dev/null); [ -z "$out" ] && out=$(pm list packages 2>/dev/null)
  while IFS= read -r p; do p="${p#package:}"; [ -n "$p" ] && DETECTED+=("$p"); done < <(printf '%s\n' "$out" | grep -i roblox); }

save_sess(){ echo "$2" > "$DIR/session$1"; }
load_sess(){ local f="$DIR/session$1" v=1; [ -f "$f" ] && v=$(cat "$f"); [[ "$v" =~ ^[0-9]+$ ]] || v=1; ((v<1))&&v=1; echo "$v"; }

# ===================== screens =====================
home_screen(){ fit; local p1 p2; p1=$(short_pkg "$CLONE1_PKG"); [ -z "$p1" ]&&p1="(unset)"; p2=$(short_pkg "$CLONE2_PKG"); [ -z "$p2" ]&&p2="(unset)"
  clr; prule; center "RFHOP" "$PINK"; center "v$VERSION" "$WHITE"; prule
  kv "CLONE 1" "$p1  slot $CLONE1_SLOT"; kv "CLONE 2" "$p2  slot $CLONE2_SLOT"
  kv "MASTER" "$MASTER"; kv "TIMING" "${SETTLE}s + ${HOLD}s"; prule
  menurow "1" "START HOPPING"; menurow "2" "SETTINGS"; menurow "3" "REFRESH LINKS NOW"; menurow "0" "EXIT"; prule
  printf "  ${PINK}SELECT >${R} "; }

settings_screen(){ fit
  local sp1 sp2 stg wl api; sp1=$(short_pkg "$CLONE1_PKG"); [ -z "$sp1" ]&&sp1="(unset)"; sp2=$(short_pkg "$CLONE2_PKG"); [ -z "$sp2" ]&&sp2="(unset)"
  stg=$([ "$STAGGER" = 1 ]&&echo on||echo off); wl=$([ "$WAKELOCK" = 1 ]&&echo on||echo off); api=$([ "$TERMUXAPI" = 1 ]&&echo on||echo off)
  clr; prule; center "SETTINGS" "$PINK"; prule
  menurow "1" "C1 PKG   $sp1"; menurow "2" "C1 SLOT  $CLONE1_SLOT"; menurow "3" "C2 PKG   $sp2"; menurow "4" "C2 SLOT  $CLONE2_SLOT"
  menurow "5" "MASTER   $MASTER"; menurow "6" "CHUNK    $CHUNK"; menurow "7" "LOAD     ${SETTLE}s"; menurow "8" "HOLD     ${HOLD}s"; menurow "9" "STAGGER  $stg"
  menurow "L" "LAUNCH TEMPLATE"; menurow "W" "WAKELOCK $wl"; menurow "A" "TERMUX API $api"
  menurow "T" "TEST CLONE 1 JOIN"; menurow "S" "SAVE / 0 BACK"; prule
  printf "  ${PINK}SELECT >${R} "; }

PICKED=""
pick_pkg(){ PICKED=""; detect_clones; fit; clr; prule; center "PICK PACKAGE" "$PINK"; prule; echo
  if [ ${#DETECTED[@]} -eq 0 ]; then printf "  ${YEL}no roblox packages found${R}\n  (need root + clones installed)\n"; pause_enter; return 1; fi
  local i=1 p; for p in "${DETECTED[@]}"; do printf "  ${CYAN}%2d${R}  ${WHITE}%s${R}\n" "$i" "$p"; i=$((i+1)); done
  printf "\n  pick # (enter=cancel): "; read -r n
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#DETECTED[@]} )); then PICKED="${DETECTED[n-1]}"; return 0; fi; return 1; }

edit_tmpl(){ fit; clr; printf "  ${CYAN}current launch template:${R}\n  ${WHITE}%s${R}\n\n  placeholders: ${CYAN}%%PKG%%  %%URL%%${R}\n  new (enter=keep):\n  " "$START_TMPL"; read -r v; [ -n "$v" ] && START_TMPL="$v"; }

test_join(){ load_master; slice_into TLINKS "$CLONE1_SLOT"; fit; clr
  if [ -z "$CLONE1_PKG" ] || [ ${#TLINKS[@]} -eq 0 ]; then printf "  ${YEL}set clone 1 pkg + a slot with links first${R}\n"; pause_enter; return; fi
  printf "  ${CYAN}testing clone 1${R}\n  pkg : ${WHITE}%s${R}\n  slot: ${WHITE}%s (%s links)${R}\n\n" "$CLONE1_PKG" "$CLONE1_SLOT" "${#TLINKS[@]}"
  launch "$CLONE1_PKG" "${TLINKS[0]}"
  printf "  ${GREEN}fired.${R} did clone 1 land in a server?\n  if not, edit option L and retest.\n"; pause_enter; }

settings(){ load_config; while true; do settings_screen; read -r s; case "$s" in
  1) pick_pkg && CLONE1_PKG="$PICKED";; 2) printf "  clone 1 slot #: "; read -r v; [[ "$v" =~ ^[0-9]+$ ]]&&CLONE1_SLOT="$v";;
  3) pick_pkg && CLONE2_PKG="$PICKED";; 4) printf "  clone 2 slot #: "; read -r v; [[ "$v" =~ ^[0-9]+$ ]]&&CLONE2_SLOT="$v";;
  5) printf "  master file name: "; read -r v; [ -n "$v" ]&&MASTER="$v";; 6) printf "  links per slot: "; read -r v; [[ "$v" =~ ^[0-9]+$ ]]&&CHUNK="$v";;
  7) printf "  load seconds: "; read -r v; [[ "$v" =~ ^[0-9]+$ ]]&&SETTLE="$v";; 8) printf "  hold seconds: "; read -r v; [[ "$v" =~ ^[0-9]+$ ]]&&HOLD="$v";;
  9) [ "$STAGGER" = 1 ]&&STAGGER=0||STAGGER=1;; l|L) edit_tmpl;;
  w|W) [ "$WAKELOCK" = 1 ]&&WAKELOCK=0||WAKELOCK=1;; a|A) [ "$TERMUXAPI" = 1 ]&&TERMUXAPI=0||TERMUXAPI=1;;
  t|T) test_join;; s|S) save_config; printf "  ${GREEN}saved${R}\n"; sleep 0.6;; 0) save_config; return;; esac; done; }

refresh_now(){ load_config; fit; clr; prule; center "REFRESH LINKS" "$PINK"; prule; echo
  fetch_master; load_master; local L1 L2; slice_into L1 "$CLONE1_SLOT"; slice_into L2 "$CLONE2_SLOT"
  printf "  ${CYAN}%-12s${R} ${WHITE}%s links total${R}\n" "$MASTER" "${#ALL[@]}"
  printf "  ${CYAN}slot %-7s${R} ${WHITE}%s links${R}\n" "$CLONE1_SLOT" "${#L1[@]}"
  printf "  ${CYAN}slot %-7s${R} ${WHITE}%s links${R}\n\n" "$CLONE2_SLOT" "${#L2[@]}"; pause_enter; }

# ===================== run =====================
i1=1; i2=1; n1=0; n2=0; nx1=0; nx2=0; last1=0; last2=0; en1=0; en2=0; paused=0; cycle=60
ST=""; STCOL=""
cstate(){ local en="$1" last="$2" now; now=$(date +%s)
  if ((en==0)); then ST="NONE"; STCOL="$RED"; elif ((now-last<SETTLE)); then ST="LOAD"; STCOL="$YEL"; else ST="HOLD"; STCOL="$GREEN"; fi; }
clone_lines(){ local slot="$1" pkg="$2" idx="$3" n="$4" last="$5" nx="$6" en="$7"
  local sp now secs; sp=$(short_pkg "$pkg"); [ -z "$sp" ]&&sp="(unset)"
  rowc " $sp  slot $slot" "$WHITE"; cstate "$en" "$last"; now=$(date +%s); secs=$((nx-now)); ((secs<0))&&secs=0; ((secs>999))&&secs=999
  rowc "   $(printf '%02d/%02d' "$idx" "$n") $ST  next ${secs}s" "$STCOL"; }
render_run(){ clr; prule
  if ((paused==1)); then titlerow "PAUSED" "$YEL"; else titlerow "RUNNING" "$GREEN"; fi
  prule; clone_lines "$CLONE1_SLOT" "$CLONE1_PKG" "$i1" "$n1" "$last1" "$nx1" "$en1"
  clone_lines "$CLONE2_SLOT" "$CLONE2_PKG" "$i2" "$n2" "$last2" "$nx2" "$en2"; prule
  local p="P pause"; ((paused==1))&&p="P resume"; rowc " $p  1/2 hop  Q stop" "$CYAN"; prule; }

run_loop(){ load_config; fit
  if [ -z "$CLONE1_PKG" ] && [ -z "$CLONE2_PKG" ]; then clr; printf "  ${YEL}no clones set - open SETTINGS first.${R}\n"; pause_enter; return; fi
  load_master; slice_into LINKS1 "$CLONE1_SLOT"; slice_into LINKS2 "$CLONE2_SLOT"; n1=${#LINKS1[@]}; n2=${#LINKS2[@]}
  i1=$(load_sess 1); i2=$(load_sess 2); (( i1<1||i1>n1 ))&&i1=1; (( i2<1||i2>n2 ))&&i2=1
  cycle=$((SETTLE+HOLD)); ((cycle<1))&&cycle=1; local now; now=$(date +%s)
  en1=1; en2=1; { [ -z "$CLONE1_PKG" ] || ((n1==0)); }&&en1=0; { [ -z "$CLONE2_PKG" ] || ((n2==0)); }&&en2=0
  nx1=$now; nx2=$now; last1=0; last2=0; paused=0; ((STAGGER==1))&&nx2=$((now+cycle/2)); local pause_at=0 k d
  wakelock_on; toast "rfhop started"
  while true; do now=$(date +%s)
    if ((paused==0)); then
      if ((en1==1)) && ((now>=nx1)); then launch "$CLONE1_PKG" "${LINKS1[i1-1]}"; last1=$now; save_sess 1 "$i1"
        i1=$((i1+1)); if ((i1>n1)); then i1=1; load_master; slice_into LINKS1 "$CLONE1_SLOT"; n1=${#LINKS1[@]}; ((n1==0))&&en1=0; ((i1>n1))&&i1=1; fi; nx1=$((now+cycle))
        notify "C1 #$i1/$n1  -  C2 #$i2/$n2"; fi
      if ((en2==1)) && ((now>=nx2)); then launch "$CLONE2_PKG" "${LINKS2[i2-1]}"; last2=$now; save_sess 2 "$i2"
        i2=$((i2+1)); if ((i2>n2)); then i2=1; load_master; slice_into LINKS2 "$CLONE2_SLOT"; n2=${#LINKS2[@]}; ((n2==0))&&en2=0; ((i2>n2))&&i2=1; fi; nx2=$((now+cycle))
        notify "C1 #$i1/$n1  -  C2 #$i2/$n2"; fi
    fi
    render_run
    if read -rsn1 -t 1 k; then case "$k" in
      p|P) if ((paused==0)); then paused=1; pause_at=$now; notify "paused"; else d=$(( $(date +%s)-pause_at )); nx1=$((nx1+d)); nx2=$((nx2+d)); paused=0; fi;;
      1) nx1=$(date +%s);; 2) nx2=$(date +%s);;
      q|Q|0) wakelock_off; notify_clear; toast "rfhop stopped"; clr; return;; esac
    fi
  done; }

# ===================== main =====================
load_config
while true; do load_config; home_screen; read -r c; case "$c" in
  1) run_loop;; 2) settings;; 3) refresh_now;;
  0|q|Q) clr; save_config; wakelock_off; notify_clear; printf "  ${GREEN}saved${R}\n\n  ${PINK}SATURNITY  *  BYE${R}\n\n"; exit 0;; esac
done
