#!/bin/bash
#
# macaudit — read-only macOS audit: apps, processes, startup items, security.
# Changes nothing in the system. No sudo. No network.
#
#   ./macaudit.sh                  full report (2-4 min)
#   ./macaudit.sh --fast           skip du and codesign (~15 s)
#   ./macaudit.sh --diff           compare against the previous snapshot
#   ./macaudit.sh --diff-with F    compare against a specific snapshot
#
set -u
umask 077

# Only SIP-protected system directories are on PATH: nothing from /usr/local,
# /opt/homebrew or the current directory can shadow the tools we rely on.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH LC_ALL=C

VERSION="1.3"
FAST=0
OPENIT=1
SYSAPPS=0
DODIFF=0
SNAPSHOT=1
DIFFWITH=""
REDACT=0
OUT=""

usage() {
  cat <<'USAGE'
macaudit — read-only report on the state of macOS

  -o, --out FILE      where to save the HTML (default: ~/Desktop/mac-audit-<date>.html)
      --fast          skip app sizes and signature checks
      --system-apps   include /System/Applications
      --diff          add a "changes" section comparing to the previous snapshot
      --diff-with F   compare against a specific snapshot file
      --no-snapshot   do not save a snapshot on this run
      --redact        replace hostname, user name and home paths with placeholders
      --no-open       do not open the report when done
  -V, --version       print the version
  -h, --help          this help

The script only reads system state. It writes exactly two things: the report
itself, and a small snapshot under ~/Library/Application Support/macaudit
so that later runs can show what changed.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) shift; OUT="${1:-}" ;;
    --fast) FAST=1 ;;
    --system-apps) SYSAPPS=1 ;;
    --diff) DODIFF=1 ;;
    --diff-with) shift; DIFFWITH="${1:-}"; DODIFF=1 ;;
    --no-snapshot) SNAPSHOT=0 ;;
    --redact) REDACT=1 ;;
    --no-open) OPENIT=0 ;;
    -V|--version) echo "macaudit $VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || { echo "This script only runs on macOS." >&2; exit 1; }

if [ -z "$OUT" ]; then
  base="$HOME/Desktop"; [ -d "$base" ] || base="$HOME"
  OUT="$base/mac-audit-$(date +%Y%m%d-%H%M).html"
fi

SNAPDIR="$HOME/Library/Application Support/macaudit"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macaudit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ── helpers ──────────────────────────────────────────────────────────────────
p()    { printf '%s\n' "$*" >> "$OUT"; }
esc()  { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
sed_esc() { printf '%s' "${1:-}" | sed 's/[][\.*^$#&/]/\\&/g'; }
R_HOME=""; R_USER=""; R_HOST=""          # filled in once the machine section has run
red() {   # strips identifying strings from anything on its way into the report
  if [ $REDACT -eq 1 ]; then
    sed ${R_HOME:+-e "s#$R_HOME#~#g"} ${R_USER:+-e "s#$R_USER#user#g"} ${R_HOST:+-e "s#$R_HOST#this-mac#g"}
  else
    cat
  fi
}
e()    { printf '%s' "${1:-}" | red | esc; }
step() { printf '  %s\n' "$1" >&2; }
one()  { local o; o=$("$@" 2>/dev/null | head -1); [ -n "$o" ] && printf '%s' "$o" || printf '—'; }
dflt() { [ -n "${1:-}" ] && printf '%s' "$1" || printf '—'; }
snap_when() {   # human-readable timestamp of a snapshot file
  local b ts
  b=$(basename "$1")
  case "$b" in
    snapshot-????????-??????.tsv)
      ts=${b#snapshot-}; ts=${ts%.tsv}
      printf '%s-%s-%s %s:%s' "${ts:0:4}" "${ts:4:2}" "${ts:6:2}" "${ts:9:2}" "${ts:11:2}" ;;
    *) stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null || printf '%s' "$b" ;;
  esac
}
human_kb() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k>=1048576) printf "%.1f GB", k/1048576;
    else if (k>=1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k }'
}

SNAP="$TMP/snapshot.tsv"; : > "$SNAP"
snap() { printf '%s\n' "$*" >> "$SNAP"; }          # already tab-joined
snap_s() { printf 'S\t%s\t%s\n' "$1" "$2" >> "$SNAP"; }
snap_v() { printf 'V\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SNAP"; }

WARN_FILE="$TMP/warn"; : > "$WARN_FILE"
warn() { printf '%s\t%s\n' "$1" "$2" >> "$WARN_FILE"; }

# ── collect: machine ─────────────────────────────────────────────────────────
step "Machine…"
OS_NAME=$(one sw_vers -productName)
OS_VER=$(one sw_vers -productVersion)
OS_BUILD=$(one sw_vers -buildVersion)
ARCH=$(one uname -m)
HOST=$(one scutil --get ComputerName)
MODEL=$(one sysctl -n hw.model)
CHIP=$(one sysctl -n machdep.cpu.brand_string)
CORES=$(one sysctl -n hw.ncpu)
RAM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}')
UPTIME=$(dflt "$(uptime 2>/dev/null | sed 's/^ *//')")
LOAD=$(dflt "$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')")

USER_NAME=$(id -un 2>/dev/null)
R_HOME=$(sed_esc "$HOME")
R_HOST=$(sed_esc "$HOST")
[ ${#USER_NAME} -ge 3 ] && R_USER=$(sed_esc "$USER_NAME")

# Full Disk Access decides how complete this report can be, so it is measured,
# not assumed: a TCC-protected file is readable only when the terminal has it.
FDA=0
head -c1 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1 && FDA=1
[ $FDA -eq 0 ] && warn warn "No Full Disk Access — parts of this report may be incomplete. System Settings › Privacy & Security › Full Disk Access, add your terminal, restart it."

DISK_LINE=$(df -k / 2>/dev/null | tail -1)
DISK_TOTAL=$(printf '%s' "$DISK_LINE" | awk '{print $2}')
DISK_USED=$(printf '%s' "$DISK_LINE" | awk '{print $3}')
DISK_PCT=$(df -H / 2>/dev/null | tail -1 | awk '{gsub("%","",$5); print $5}')
[ -n "${DISK_PCT:-}" ] || DISK_PCT=0
[ "$DISK_PCT" -ge 90 ] && warn bad "Startup disk is ${DISK_PCT}% full — under 10% free"

snap_s "macOS version" "$OS_VER ($OS_BUILD)"
snap_v "Disk usage, %" "$DISK_PCT" 3

# ── collect: security ────────────────────────────────────────────────────────
step "Security…"
SIP=$(dflt "$(csrutil status 2>/dev/null | sed 's/System Integrity Protection status: //' | head -1)")
FV=$(one fdesetup status)
GK=$(one spctl --status)
FW=$(one /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate)
[ "$FW" = "—" ] && FW=$(one defaults read /Library/Preferences/com.apple.alf globalstate)
FW_STEALTH=$(one /usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode)
XPROTECT=$(one defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist CFBundleShortVersionString)
[ "$XPROTECT" = "—" ] && XPROTECT=$(one defaults read /System/Library/CoreServices/XProtect.bundle/Contents/Info.plist CFBundleShortVersionString)
SECBOOT=$(dflt "$(system_profiler SPiBridgeDataType 2>/dev/null | awk -F': ' '/Secure Boot/{print $2}' | head -1)")
TM_LAST=$(one tmutil latestbackup)
TM_DEST=$(dflt "$(tmutil destinationinfo 2>/dev/null | awk -F': ' '/Name/{print $2}' | head -1)")

case "$SIP" in *enabled*) ;; —) ;; *) warn bad "SIP is disabled — system files are unprotected";; esac
case "$FV" in *"On"*) ;; *"Off"*) warn bad "FileVault is off — the disk is not encrypted";; esac
case "$GK" in *enabled*) ;; *) warn bad "Gatekeeper is off — unsigned software will launch";; esac
case "$FW" in *"enabled"*|*"= 1"*|*"= 2"*|1|2) ;; *) warn warn "Application firewall is off";; esac
[ "$TM_LAST" = "—" ] && warn warn "Time Machine: no recent backup found"

snap_s "SIP" "$SIP"
snap_s "FileVault" "$FV"
snap_s "Gatekeeper" "$GK"
snap_s "Firewall" "$FW"
snap_s "Stealth mode" "$FW_STEALTH"
snap_s "XProtect" "$XPROTECT"
snap_s "Secure Boot" "$SECBOOT"

LISTEN="$TMP/listen.txt"
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | tail -n +2 | sort -u > "$LISTEN" || true
EXT_LISTEN=$(awk '{print $(NF-1)}' "$LISTEN" | grep -Ev '^(127\.0\.0\.1|\[::1\])' | grep -cE '^\*:|^0\.0\.0\.0')
[ "${EXT_LISTEN:-0}" -gt 0 ] && warn warn "Ports bound to all interfaces: $EXT_LISTEN (see Network)"
awk '{print "N\t" $1 "\t" $(NF-1)}' "$LISTEN" | sort -u >> "$SNAP"

SYSEXT="$TMP/sysext.txt"; systemextensionsctl list 2>/dev/null > "$SYSEXT" || : > "$SYSEXT"
KEXTS=$(kmutil showloaded --list-only 2>/dev/null | grep -v 'com\.apple\.' | grep -c . )

# ── collect: applications ────────────────────────────────────────────────────
step "Applications (this is the slow part)…"
APPDIRS=()
for d in "/Applications" "$HOME/Applications"; do [ -d "$d" ] && APPDIRS+=("$d"); done
[ $SYSAPPS -eq 1 ] && [ -d /System/Applications ] && APPDIRS+=("/System/Applications")
[ ${#APPDIRS[@]} -gt 0 ] || { echo "No application directories are readable." >&2; exit 1; }

APPS_RAW="$TMP/apps.tsv"; : > "$APPS_RAW"
NOW_TS=$(date +%s)
find "${APPDIRS[@]}" -maxdepth 3 -name '*.app' -prune -print 2>/dev/null | sort -f > "$TMP/applist"
APP_COUNT=$(wc -l < "$TMP/applist" | tr -d ' ')
i=0
while IFS= read -r app; do
  [ -n "$app" ] || continue
  i=$((i+1))
  printf '\r    %s/%s %-42.42s' "$i" "$APP_COUNT" "$(basename "$app")" >&2
  name=$(basename "$app" .app)
  ver=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null | head -1)
  [ -n "$ver" ] || ver="—"
  if [ $FAST -eq 0 ]; then
    szk=$(du -sk "$app" 2>/dev/null | awk '{print $1}')
    signer=$(codesign -dv --verbose=2 "$app" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')
    [ -n "$signer" ] || signer="unsigned"
  else
    szk=0; signer="—"
  fi
  [ -n "${szk:-}" ] || szk=0
  used=$(mdls -raw -name kMDItemLastUsedDate "$app" 2>/dev/null | cut -c1-10)
  case "$used" in ""|"(nu"|"(null)") used="—"; days=-1 ;;
    *) ts=$(date -j -f "%Y-%m-%d" "$used" +%s 2>/dev/null)
       if [ -n "${ts:-}" ]; then days=$(( (NOW_TS - ts) / 86400 )); else days=-1; fi ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$szk" "$name" "$ver" "$signer" "$used" "$days" "$app" >> "$APPS_RAW"
  printf 'A\t%s\t%s\t%s\t%s\t%s\n' "$app" "$name" "$ver" "$szk" "$signer" >> "$SNAP"
done < "$TMP/applist"
printf '\r%-60s\r' '' >&2

APPS_TOTAL_KB=$(awk -F'\t' '{s+=$1} END{printf "%d", s}' "$APPS_RAW")
STALE=$(awk -F'\t' '$6>180' "$APPS_RAW" | grep -c . )
UNSIGNED=$(awk -F'\t' '$4=="unsigned"' "$APPS_RAW" | grep -c . )
[ "${UNSIGNED:-0}" -gt 0 ] && warn warn "Unsigned applications: $UNSIGNED"

# ── collect: package managers ────────────────────────────────────────────────
BREW_F=""; BREW_C=""; BREW_PREFIX=""; BREW=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { BREW="$b"; break; }; done
if [ -n "$BREW" ]; then
  step "Homebrew…"   # the one non-system binary we run, by absolute path
  BREW_PREFIX=$("$BREW" --prefix 2>/dev/null)
  BREW_F=$("$BREW" list --formula --versions 2>/dev/null)
  BREW_C=$("$BREW" list --cask --versions 2>/dev/null)
  printf '%s\n' "$BREW_F" | grep . | awk '{n=$1; v=$2; print "B\tformula: " n "\t" v}' >> "$SNAP"
  printf '%s\n' "$BREW_C" | grep . | awk '{n=$1; v=$2; print "B\tcask: " n "\t" v}' >> "$SNAP"
fi
MAS_LIST=$(mdfind "kMDItemAppStoreHasReceipt=1" 2>/dev/null | head -200)

# ── collect: startup items ───────────────────────────────────────────────────
step "Startup items…"
AUTORUN="$TMP/autorun.tsv"; : > "$AUTORUN"
for d in "/Library/LaunchAgents" "/Library/LaunchDaemons" "$HOME/Library/LaunchAgents"; do
  [ -d "$d" ] || continue
  for f in "$d"/*.plist; do
    [ -e "$f" ] || continue
    lbl=$(defaults read "$f" Label 2>/dev/null | head -1)
    [ -n "$lbl" ] || lbl=$(basename "$f" .plist)
    prog=$(defaults read "$f" Program 2>/dev/null | head -1)
    [ -n "$prog" ] || prog=$(defaults read "$f" ProgramArguments 2>/dev/null | sed -n '2p' | tr -d ' ",')
    [ -n "$prog" ] || prog="—"
    ra=$(defaults read "$f" RunAtLoad 2>/dev/null | head -1)
    printf '%s\t%s\t%s\t%s\n' "$lbl" "$d" "$prog" "${ra:-0}" >> "$AUTORUN"
    printf 'L\t%s\t%s\t%s\n' "$lbl" "$d" "$prog" >> "$SNAP"
  done
done
AUTORUN_N=$(grep -c . "$AUTORUN")
LOGIN_ITEMS=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)

# ── collect: processes ───────────────────────────────────────────────────────
step "Processes…"
PS_CPU=$(ps -A -r -o pid,%cpu,%mem,rss,etime,user,ucomm 2>/dev/null | head -16)
PS_MEM=$(ps -A -m -o pid,%cpu,%mem,rss,etime,user,ucomm 2>/dev/null | head -16)
PROC_N=$(ps -Ao pid= 2>/dev/null | grep -c . )

# ── snapshot + diff ──────────────────────────────────────────────────────────
PREV=""
DIFF_TSV="$TMP/diff.tsv"; : > "$DIFF_TSV"
DIFF_STATE="none"   # none | baseline | ok
if [ $DODIFF -eq 1 ]; then
  if [ -n "$DIFFWITH" ]; then
    [ -f "$DIFFWITH" ] && PREV="$DIFFWITH" || { echo "Snapshot not found: $DIFFWITH" >&2; exit 1; }
  else
    PREV=$(ls -1t "$SNAPDIR"/snapshot-*.tsv 2>/dev/null | head -1)
  fi
  if [ -n "$PREV" ]; then
    step "Comparing with $(basename "$PREV")…"
    awk -F'\t' -v OFS='\t' '
      FNR==NR {
        if      ($1=="S") oS[$2]=$3
        else if ($1=="V") oV[$2]=$3
        else if ($1=="A") { oA[$2]=1; oAn[$2]=$3; oAv[$2]=$4; oAz[$2]=$5; oAs[$2]=$6 }
        else if ($1=="L") { k=$2 "\t" $3; oL[k]=1; oLp[k]=$4 }
        else if ($1=="N") { if (port($3)<49152) oN[$2 " @ " $3]=1 }
        else if ($1=="B") oB[$2]=$3
        next
      }
      {
        if      ($1=="S") nS[$2]=$3
        else if ($1=="V") { nV[$2]=$3; nT[$2]=$4 }
        else if ($1=="A") { nA[$2]=1; nAn[$2]=$3; nAv[$2]=$4; nAz[$2]=$5; nAs[$2]=$6 }
        else if ($1=="L") { k=$2 "\t" $3; nL[k]=1; nLp[k]=$4 }
        else if ($1=="N") { if (port($3)<49152) nN[$2 " @ " $3]=1 }
        else if ($1=="B") nB[$2]=$3
      }
      function port(a,  n) { n=a; sub(/.*:/,"",n); return (n+0) }
      function mb(k) { return sprintf("%+.0f MB", k/1024) }
      END {
        for (k in nS) if ((k in oS) && oS[k]!=nS[k]) print "change","Security",k,oS[k] " → " nS[k]
        for (k in nV) if (k in oV) { d=nV[k]-oV[k]; if (d>=nT[k] || d<=-nT[k]) print "change","System",k,oV[k] " → " nV[k] }

        for (k in nA) {
          if (!(k in oA)) print "add","Application",nAn[k],(nAv[k]=="—"?k:nAv[k] " · " k)
          else {
            if (oAv[k]!=nAv[k]) print "change","Application",nAn[k],oAv[k] " → " nAv[k]
            if (oAs[k]!="—" && nAs[k]!="—" && oAs[k]!=nAs[k]) print "change","Signature",nAn[k],oAs[k] " → " nAs[k]
            if (oAz[k]+0>0 && nAz[k]+0>0) { d=nAz[k]-oAz[k]; if (d>20480 || d<-20480) print "change","App size",nAn[k],mb(d) }
          }
        }
        for (k in oA) if (!(k in nA)) print "remove","Application",oAn[k],k

        for (k in nL) { split(k,f,"\t"); if (!(k in oL)) print "add","Startup item",f[1],f[2] "  ·  " nLp[k];
                        else if (oLp[k]!=nLp[k]) print "change","Startup item",f[1],oLp[k] " → " nLp[k] }
        for (k in oL) { split(k,f,"\t"); if (!(k in nL)) print "remove","Startup item",f[1],f[2] }

        for (k in nN) if (!(k in oN)) print "add","Listening port",k,""
        for (k in oN) if (!(k in nN)) print "remove","Listening port",k,""

        for (k in nB) { if (!(k in oB)) print "add","Package",k,nB[k]
                        else if (oB[k]!=nB[k]) print "change","Package",k,oB[k] " → " nB[k] }
        for (k in oB) if (!(k in nB)) print "remove","Package",k,oB[k]
      }
    ' "$PREV" "$SNAP" | sort -t$'\t' -k2,2 -k1,1 -k3,3 > "$DIFF_TSV"
    DIFF_STATE="ok"
  else
    DIFF_STATE="baseline"
  fi
fi

if [ $SNAPSHOT -eq 1 ]; then
  mkdir -p "$SNAPDIR" 2>/dev/null
  cp "$SNAP" "$SNAPDIR/snapshot-$(date +%Y%m%d-%H%M%S).tsv" 2>/dev/null
  ls -1t "$SNAPDIR"/snapshot-*.tsv 2>/dev/null | tail -n +31 | while IFS= read -r old; do rm -f "$old"; done
fi

# ── render ───────────────────────────────────────────────────────────────────
SELF_HASH=$(shasum -a 256 "$0" 2>/dev/null | cut -c1-16)
step "Writing report…"
: > "$OUT"

cat >> "$OUT" <<'HEAD'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>System report</title>
<style>
:root{
  --ink:#11161d; --ink-2:#4a5563; --ink-3:#7a8695;
  --paper:#eef1f4; --panel:#ffffff; --line:#d5dce4;
  --ok:#0d7a5f; --warn:#a55b00; --bad:#b02020;
  --mono:ui-monospace,"SF Mono",Menlo,monospace;
  --ui:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
}
@media (prefers-color-scheme:dark){:root{
  --ink:#e6ebf2; --ink-2:#a3aebd; --ink-3:#6f7c8c;
  --paper:#10141a; --panel:#171d25; --line:#28303a;
  --ok:#4fd1a5; --warn:#e0a44a; --bad:#f27272;
}}
*{box-sizing:border-box}
body{margin:0;padding:0 20px 80px;background:var(--paper);color:var(--ink);
     font:15px/1.55 var(--ui);-webkit-font-smoothing:antialiased}
.wrap{max-width:1040px;margin:0 auto}
header{padding:44px 0 26px;border-bottom:2px solid var(--ink)}
h1{margin:0;font-size:30px;font-weight:640;letter-spacing:-.02em}
.sub{margin-top:6px;font:12px/1.5 var(--mono);color:var(--ink-3);letter-spacing:.02em}
section{margin-top:34px}
h2{margin:0 0 2px;font-size:13px;font-weight:680;letter-spacing:.09em;text-transform:uppercase}
.src{font:11px/1.6 var(--mono);color:var(--ink-3);margin-bottom:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
.pad{padding:14px 16px}
table{width:100%;border-collapse:collapse;font-size:13.5px}
th{font:11px/1.4 var(--mono);text-transform:uppercase;letter-spacing:.06em;color:var(--ink-3);
   text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap;
   position:sticky;top:0;background:var(--panel);cursor:pointer;user-select:none}
th:hover{color:var(--ink)}
td{padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}
tbody tr:hover{background:color-mix(in srgb,var(--line) 32%,transparent)}
.num{text-align:right;font-variant-numeric:tabular-nums;font-family:var(--mono);font-size:12.5px;white-space:nowrap}
.mono{font-family:var(--mono);font-size:12px;color:var(--ink-2);word-break:break-all}
.kv td:first-child{width:210px;color:var(--ink-2);font-size:13px}
.kv td:last-child{font-family:var(--mono);font-size:12.5px}
.strip{display:grid;grid-template-columns:repeat(auto-fit,minmax(168px,1fr));gap:1px;
       background:var(--line);border:1px solid var(--line);border-radius:10px;overflow:hidden}
.chip{background:var(--panel);padding:12px 14px}
.chip .lbl{font:10px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3)}
.chip .st{margin-top:4px;font-size:14px;font-weight:600;display:flex;align-items:center;gap:7px}
.dot{width:7px;height:7px;border-radius:50%;flex:none}
.ok .dot{background:var(--ok)} .ok .st{color:var(--ok)}
.warn .dot{background:var(--warn)} .warn .st{color:var(--warn)}
.bad .dot{background:var(--bad)} .bad .st{color:var(--bad)}
.neutral .dot{background:var(--ink-3)}
ul.flags{list-style:none;margin:0;padding:0}
ul.flags li{padding:9px 16px;border-bottom:1px solid var(--line);display:flex;gap:10px;align-items:baseline}
ul.flags li:last-child{border-bottom:0}
.tag{font:10px/1.6 var(--mono);letter-spacing:.06em;text-transform:uppercase;padding:1px 7px;
     border-radius:4px;border:1px solid currentColor;flex:none}
.tag.bad{color:var(--bad)} .tag.warn{color:var(--warn)}
.bar{height:6px;background:var(--line);border-radius:3px;overflow:hidden;margin-top:9px}
.bar i{display:block;height:100%;background:var(--ink)}
input.filter{width:100%;padding:10px 14px;border:0;border-bottom:1px solid var(--line);
  background:transparent;color:var(--ink);font:13px var(--mono);outline:none}
input.filter:focus{background:color-mix(in srgb,var(--line) 25%,transparent)}
pre{margin:0;padding:14px 16px;overflow-x:auto;font:12px/1.5 var(--mono);color:var(--ink-2)}
.stale{color:var(--warn)}
.grid2{display:grid;gap:16px;grid-template-columns:1fr 1fr}
@media (max-width:760px){.grid2{grid-template-columns:1fr}.kv td:first-child{width:auto}}
/* changes ledger */
table.ledger td.sign{width:26px;text-align:center;font-family:var(--mono);font-size:14px;font-weight:700;padding-right:0}
table.ledger tr.add td.sign{color:var(--ok)}
table.ledger tr.remove td.sign{color:var(--bad)}
table.ledger tr.change td.sign{color:var(--warn)}
table.ledger td.cat{width:120px;font:11px/1.5 var(--mono);color:var(--ink-3);text-transform:uppercase;letter-spacing:.05em}
footer{margin-top:44px;padding-top:16px;border-top:1px solid var(--line);
       font:11px/1.7 var(--mono);color:var(--ink-3)}
</style></head><body><div class="wrap">
HEAD

p "<header><h1>System report</h1><div class=\"sub\">$(e "$HOST") · $(e "$OS_NAME") $(e "$OS_VER") ($(e "$OS_BUILD")) · $(e "$ARCH") · $(date '+%d %b %Y, %H:%M')</div></header>"

chip() { p "<div class=\"chip $1\"><div class=\"lbl\">$(e "$2")</div><div class=\"st\"><span class=\"dot\"></span>$(e "$3")</div></div>"; }

p '<section><h2>Summary</h2><div class="src">csrutil · fdesetup · spctl · socketfilterfw</div><div class="strip">'
case "$SIP" in *enabled*) chip ok "SIP" "enabled";; *) chip bad "SIP" "$SIP";; esac
case "$FV" in *"On"*) chip ok "FileVault" "on";; *"Off"*) chip bad "FileVault" "off";; *) chip neutral "FileVault" "$FV";; esac
case "$GK" in *enabled*) chip ok "Gatekeeper" "enabled";; *) chip bad "Gatekeeper" "disabled";; esac
case "$FW" in *"enabled"*|*"= 1"*|*"= 2"*|1|2) chip ok "Firewall" "on";; *) chip warn "Firewall" "off";; esac
if   [ "$DISK_PCT" -ge 90 ]; then chip bad "Disk" "${DISK_PCT}% used"
elif [ "$DISK_PCT" -ge 75 ]; then chip warn "Disk" "${DISK_PCT}% used"
else chip ok "Disk" "${DISK_PCT}% used"; fi
chip neutral "Applications" "$APP_COUNT"
chip neutral "Processes" "$PROC_N"
[ $FDA -eq 1 ] && chip ok "Full Disk Access" "granted" || chip warn "Full Disk Access" "not granted"
[ "$TM_LAST" = "—" ] && chip warn "Time Machine" "no backups" || chip ok "Time Machine" "$(printf '%s' "$TM_LAST" | sed 's#.*/##' | cut -c1-10)"
p '</div>'

if [ -s "$WARN_FILE" ]; then
  p '<div class="card" style="margin-top:16px"><ul class="flags">'
  while IFS=$'\t' read -r lvl txt; do
    p "<li><span class=\"tag $lvl\">$([ "$lvl" = bad ] && echo "action" || echo "check")</span><span>$(e "$txt")</span></li>"
  done < "$WARN_FILE"
  p '</ul></div>'
fi
p '</section>'

# --- changes
if [ $DODIFF -eq 1 ]; then
  p '<section><h2>Changes</h2>'
  if [ "$DIFF_STATE" = "baseline" ]; then
    p '<div class="src">no earlier snapshot found</div><div class="card"><div class="pad src">Baseline saved. Run with --diff again later and this section will list what changed.</div></div>'
  elif [ ! -s "$DIFF_TSV" ]; then
    p "<div class=\"src\">compared with $(e "$(basename "$PREV")")</div><div class=\"card\"><div class=\"pad src\">Nothing changed since $(e "$(snap_when "$PREV")").</div></div>"
  else
    n=$(grep -c . "$DIFF_TSV")
    p "<div class=\"src\">$n change(s) since $(e "$(snap_when "$PREV")") · $(e "$(basename "$PREV")")</div>"
    p '<div class="card"><table class="ledger"><tbody>'
    while IFS=$'\t' read -r cls cat item detail; do
      case "$cls" in add) sg="+";; remove) sg="−";; *) sg="Δ";; esac
      p "<tr class=\"$cls\"><td class=\"sign\">$sg</td><td class=\"cat\">$(e "$cat")</td><td>$(e "$item")</td><td class=\"mono\">$(e "$detail")</td></tr>"
    done < "$DIFF_TSV"
    p '</tbody></table></div>'
  fi
  p '</section>'
fi

# --- machine
p '<section><h2>Machine</h2><div class="src">sw_vers · sysctl · df</div><div class="grid2"><div class="card"><table class="kv">'
p "<tr><td>Model</td><td>$(e "$MODEL")</td></tr>"
p "<tr><td>CPU</td><td>$(e "$CHIP") · $(e "$CORES") cores</td></tr>"
p "<tr><td>Memory</td><td>${RAM_GB} GB</td></tr>"
p "<tr><td>Load (1/5/15)</td><td>$(e "$LOAD")</td></tr>"
p "<tr><td>Secure Boot</td><td>$(e "$SECBOOT")</td></tr>"
p '</table></div><div class="card"><table class="kv">'
p "<tr><td>Disk, total</td><td>$(human_kb "${DISK_TOTAL:-0}")</td></tr>"
p "<tr><td>Used</td><td>$(human_kb "${DISK_USED:-0}") ($DISK_PCT%)<div class=\"bar\"><i style=\"width:${DISK_PCT}%\"></i></div></td></tr>"
p "<tr><td>Applications occupy</td><td>$(human_kb "${APPS_TOTAL_KB:-0}")</td></tr>"
p "<tr><td>Uptime</td><td>$(e "$UPTIME")</td></tr>"
p '</table></div></div></section>'

# --- security
p '<section><h2>Security</h2><div class="src">csrutil status · fdesetup status · spctl --status · socketfilterfw · XProtect · tmutil</div><div class="card"><table class="kv">'
p "<tr><td>SIP</td><td>$(e "$SIP")</td></tr>"
p "<tr><td>FileVault</td><td>$(e "$FV")</td></tr>"
p "<tr><td>Gatekeeper</td><td>$(e "$GK")</td></tr>"
p "<tr><td>Firewall</td><td>$(e "$FW")</td></tr>"
p "<tr><td>Stealth mode</td><td>$(e "$FW_STEALTH")</td></tr>"
p "<tr><td>XProtect</td><td>version $(e "$XPROTECT")</td></tr>"
p "<tr><td>Third-party kexts</td><td>$(e "$KEXTS")</td></tr>"
p "<tr><td>Latest backup</td><td>$(e "$TM_LAST")</td></tr>"
p "<tr><td>Backup destination</td><td>$(e "$TM_DEST")</td></tr>"
p '</table></div>'
if [ -s "$SYSEXT" ]; then
  p '<div class="card" style="margin-top:16px"><pre>'
  sed -n '1,40p' "$SYSEXT" | red | esc >> "$OUT"
  p '</pre></div>'
fi
p '</section>'

# --- applications
p '<section><h2>Applications</h2>'
p "<div class=\"src\">find $(e "${APPDIRS[*]}") · du -sk · codesign -dv · mdls kMDItemLastUsedDate</div>"
p '<div class="card"><input class="filter" data-for="apps" placeholder="filter: name, signer, path…" aria-label="Filter applications">'
p '<table id="apps"><thead><tr><th data-n>Size</th><th>Name</th><th>Version</th><th>Signed by</th><th data-n>Unused, days</th><th>Path</th></tr></thead><tbody>'
sort -t$'\t' -k1,1nr "$APPS_RAW" | while IFS=$'\t' read -r szk name ver signer used days path; do
  cls=""; [ "${days:-0}" -gt 180 ] 2>/dev/null && cls=' class="stale"'
  dshow="—"; case "$days" in ''|-1) ;; *) dshow="$days";; esac
  p "<tr><td class=\"num\" data-v=\"$szk\">$( [ "$szk" -gt 0 ] && human_kb "$szk" || echo '—')</td>\
<td>$(e "$name")</td><td class=\"num\">$(e "$ver")</td><td class=\"mono\">$(e "$signer")</td>\
<td class=\"num\" data-v=\"$days\"$cls>$dshow</td><td class=\"mono\">$(e "$path")</td></tr>"
done
p '</tbody></table></div>'
p "<div class=\"src\" style=\"margin-top:10px\">$APP_COUNT applications, $(human_kb "${APPS_TOTAL_KB:-0}") total. Untouched for over six months: $STALE.</div></section>"

# --- packages
if [ -n "$BREW_F$BREW_C" ] || [ -n "$MAS_LIST" ]; then
  p '<section><h2>Packages and Store</h2><div class="src">brew list --versions · mdfind kMDItemAppStoreHasReceipt</div><div class="grid2">'
  if [ -n "$BREW_F$BREW_C" ]; then
    p "<div class=\"card\"><div class=\"pad src\">Homebrew at $(e "$BREW_PREFIX") · $(printf '%s' "$BREW_F" | grep -c . ) formulae · $(printf '%s' "$BREW_C" | grep -c . ) casks</div><pre>"
    { printf '%s\n' "$BREW_F"; printf '%s\n' "$BREW_C"; } | grep . | sort | red | esc >> "$OUT"
    p '</pre></div>'
  fi
  if [ -n "$MAS_LIST" ]; then
    p "<div class=\"card\"><div class=\"pad src\">From the App Store: $(printf '%s' "$MAS_LIST" | grep -c . )</div><pre>"
    printf '%s\n' "$MAS_LIST" | sed 's#.*/##;s#\.app$##' | sort | red | esc >> "$OUT"
    p '</pre></div>'
  fi
  p '</div></section>'
fi

# --- startup
p '<section><h2>Startup items</h2><div class="src">/Library/LaunchAgents · /Library/LaunchDaemons · ~/Library/LaunchAgents · System Events login items</div><div class="card">'
if [ "${AUTORUN_N:-0}" -gt 0 ]; then
  p '<table id="auto"><thead><tr><th>Label</th><th>Location</th><th>Runs</th><th>At load</th></tr></thead><tbody>'
  sort -t$'\t' -k2,2 -k1,1 "$AUTORUN" | while IFS=$'\t' read -r lbl dir prog ra; do
    p "<tr><td class=\"mono\">$(e "$lbl")</td><td class=\"mono\">$(e "$dir")</td><td class=\"mono\">$(e "$prog")</td><td class=\"num\">$([ "$ra" = "1" ] && echo yes || echo '—')</td></tr>"
  done
  p '</tbody></table>'
else
  p '<div class="pad src">No third-party agents or daemons found.</div>'
fi
p '</div>'
if [ -n "$LOGIN_ITEMS" ]; then
  p "<div class=\"card\" style=\"margin-top:16px\"><div class=\"pad\"><div class=\"src\">Login items</div><div class=\"mono\">$(e "$LOGIN_ITEMS")</div></div></div>"
fi
p '</section>'

# --- processes
p '<section><h2>Processes</h2><div class="src">ps -A -r -o (by CPU) · ps -A -m -o (by memory)</div><div class="grid2">'
for pair in "Top by CPU|$PS_CPU" "Top by memory|$PS_MEM"; do
  ttl="${pair%%|*}"; body="${pair#*|}"
  p "<div class=\"card\"><div class=\"pad src\">$(e "$ttl")</div><table><thead><tr><th>PID</th><th>CPU</th><th>MEM</th><th>RSS</th><th>Process</th></tr></thead><tbody>"
  printf '%s\n' "$body" | tail -n +2 | while read -r pid cpu mem rss _etime _usr cmd; do
    p "<tr><td class=\"num\">$(e "$pid")</td><td class=\"num\">$(e "$cpu")</td><td class=\"num\">$(e "$mem")</td><td class=\"num\">$(human_kb "$rss")</td><td class=\"mono\">$(e "$cmd")</td></tr>"
  done
  p '</tbody></table></div>'
done
p '</div></section>'

# --- network
p '<section><h2>Network: who is listening</h2><div class="src">lsof -nP -iTCP -sTCP:LISTEN — without sudo you only see your own processes</div><div class="card">'
if [ -s "$LISTEN" ]; then
  p '<table id="net"><thead><tr><th>Process</th><th>PID</th><th>User</th><th>Address</th></tr></thead><tbody>'
  awk '{print $1"\t"$2"\t"$3"\t"$(NF-1)}' "$LISTEN" | sort -u | while IFS=$'\t' read -r c pid usr addr; do
    p "<tr><td class=\"mono\">$(e "$c")</td><td class=\"num\">$(e "$pid")</td><td class=\"mono\">$(e "$usr")</td><td class=\"mono\">$(e "$addr")</td></tr>"
  done
  p '</tbody></table>'
else
  p '<div class="pad src">No listening sockets found.</div>'
fi
p '</div></section>'

cat >> "$OUT" <<FOOT
<footer>macaudit $VERSION · $(date '+%d %b %Y %H:%M') · read-only, nothing was modified<br>
Produced by $(basename "$0") · sha256 ${SELF_HASH:-unavailable}… · PATH pinned to /usr/bin:/bin:/usr/sbin:/sbin<br>
$([ $REDACT -eq 1 ] && echo "Redacted: hostname, user name and home paths were replaced before writing this file." || echo "Not redacted: this file contains your hostname, user name and full paths. Re-run with --redact before sharing it.")<br>
Every section is labelled with the command its data came from, so any line can be checked by hand.</footer>
</div>
<script>
document.querySelectorAll('th').forEach(function(th){
  th.addEventListener('click',function(){
    var tb=th.closest('table').tBodies[0], i=[].indexOf.call(th.parentNode.children,th);
    var num=th.hasAttribute('data-n'), dir=th.dataset.d==='1'?-1:1; th.dataset.d=dir===1?'1':'0';
    var rows=[].slice.call(tb.rows);
    rows.sort(function(a,b){
      var x=a.cells[i], y=b.cells[i];
      if(num){return (parseFloat(y.dataset.v||y.textContent)-parseFloat(x.dataset.v||x.textContent))*dir;}
      return x.textContent.localeCompare(y.textContent,'en')*dir;
    });
    rows.forEach(function(r){tb.appendChild(r)});
  });
});
document.querySelectorAll('input.filter').forEach(function(inp){
  inp.addEventListener('input',function(){
    var q=inp.value.toLowerCase(), t=document.getElementById(inp.dataset.for);
    [].forEach.call(t.tBodies[0].rows,function(r){
      r.style.display=r.textContent.toLowerCase().indexOf(q)>-1?'':'none';
    });
  });
});
</script>
</body></html>
FOOT

step "Done: $OUT"
[ $OPENIT -eq 1 ] && open "$OUT" 2>/dev/null
exit 0
