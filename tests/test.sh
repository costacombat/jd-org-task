#!/usr/bin/env bash
# ot end to end, in a throwaway HOME: every command, once with
# `emacs --batch` (OT_DAEMON=0) and once through a daemon ot starts itself.
# Then Emacs itself reads the file ot wrote. Needs ot, emacs and jq on PATH.
set -euo pipefail

t=$(mktemp -d)
export HOME=$t/home XDG_RUNTIME_DIR=$t/run TMPDIR=$t
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
here=$(cd "$(dirname "$0")" && pwd)

pass=0
no() {
  echo "not ok - $1" >&2
  exit 1
}
ok() {
  echo "ok - $1"
  pass=$((pass + 1))
}
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1: expected [$2], got [$3]"; fi
}

for mode in 0 auto; do
  export OT_DAEMON=$mode OT_FILE=$t/$mode/jdex.org
  mkdir -p "$t/$mode"
  cp "$here/jdex.org" "$OT_FILE"
  chmod u+w "$OT_FILE"
  m="[$mode]"

  ot add Call the bank >/dev/null
  same "$m add without --under goes in the inbox" Inbox "$(ot ls --json | jq -r '.[0].under')"
  OT_INBOX=11.01 ot add File the receipt >/dev/null
  same "$m OT_INBOX names the inbox by number" 11.01 \
    "$(ot ls --json | jq -r '.[] | select(.title == "File the receipt") | .under')"

  ot add Renew it --under 11.11 --due 2026-12-01 >/dev/null
  same "$m --under an ID, with a deadline" '11.11 <2026-12-01 Tue>' \
    "$(ot ls --under 11.11 --json | jq -r '.[0] | "\(.under) \(.deadline)"')"

  ot add 'Say "hi" \ back' --under W0011 --state NEXT >/dev/null
  same "$m --under a work package, quotes kept" 'W0011 NEXT Say "hi" \ back' \
    "$(ot ls --under W0011 --json | jq -r '.[0] | "\(.under) \(.state) \(.title)"')"
  ot add Pack --under W0012~11.11 >/dev/null
  same "$m --under W0012~11.11 finds it by its title" W0012~11.11 \
    "$(ot ls --under W0012 --json | jq -r '.[0].under')"

  err=$(ot add x --under W0011~12.11 2>&1) && no "$m wrong address accepted"
  same "$m --under refuses a work package from another ID" \
    'ot: W0011 is "W0011~11.11 Renew passport", not under 12.11' "$err"
  err=$(ot add x --under 99.99 2>&1) && no "$m missing heading accepted"
  ok "$m --under refuses a missing heading"
  err=$(ot add x --state NOPE 2>&1) && no "$m bad state accepted"
  ok "$m add refuses an unknown state"

  same "$m ls lists the open tasks" 5 "$(ot ls --json | jq length)"
  same "$m ls --state" 1 "$(ot ls --state NEXT --json | jq length)"
  same "$m ls of an empty subtree is []" '[]' "$(ot ls --under 11.01 --state WAIT --json)"

  id=$(ot ls --under W0011 --json | jq -r '.[0].id')
  same "$m ids are 8 characters" 8 "${#id}"
  ot set "$id" WAIT >/dev/null
  same "$m set changes the state" WAIT "$(ot ls --under W0011 --json | jq -r '.[0].state')"
  ot "done" "$id" >/dev/null
  same "$m done hides it from ls" 0 "$(ot ls --under W0011 --json | jq length)"
  same "$m ls --all shows it" DONE "$(ot ls --under W0011 --all --json | jq -r '.[0].state')"

  where=$(ot where "$id")
  same "$m where gives the heading's line" '*** DONE Say "hi" \ back' \
    "$(sed -n "${where##*:}p" "$OT_FILE")"
  same "$m open runs OT_EDITOR with +LINE FILE" "+${where##*:} $OT_FILE" \
    "$(OT_EDITOR="echo" ot open "$id")"

  # Emacs, not ot, reads what ot wrote
  got=$(emacs -Q --batch "$OT_FILE" --eval '(progn (require (quote org-lint))
    (princ (format "%d %S" (length (org-map-entries t "TODO=\"TODO\"")) (org-lint))))' 2>/dev/null)
  same "$m Org reads the file, and org-lint finds nothing" '4 nil' "$got"
done

# Inboxes, narrowest first, in a system with the standard zeros and a
# matching tree on disk
for mode in 0 auto; do
  export OT_DAEMON=$mode OT_FILE=$t/inbox-$mode/system.org OT_ROOT=$t/inbox-$mode/root
  m="[inbox $mode]"
  r=$OT_ROOT
  mkdir -p "$r/10-19 Life admin/11 Me/11.11 Passport" "$r/10-19 Life admin/11 Me/11.12 Bank" \
    "$r/W0000-9999 Work packages/W0011~11.11 Renew passport"
  cp "$here/system.org" "$OT_FILE"
  chmod u+w "$OT_FILE"
  under() { ot ls --json | jq -r --arg t "$1" '.[] | select(.title == $t) | .under'; }

  (cd "$t" && ot add Anywhere >/dev/null)
  same "$m no --in, outside the system: 00.01" 00.01 "$(under Anywhere)"
  ot add Sys --in system >/dev/null
  same "$m --in system" 00.01 "$(under Sys)"
  ot add Area --in 10-19 >/dev/null
  same "$m --in 10-19: the area's 10.01" 10.01 "$(under Area)"
  ot add Cat --in 11 >/dev/null
  same "$m --in 11: the category's 11.01" 11.01 "$(under Cat)"
  ot add Id --in 11.11 >/dev/null
  same "$m --in 11.11: the ID's + Inbox" 11.11+Inbox "$(under Id)"
  same "$m 11.11+ Inbox sits right after 11.11" '*** 11.11+ Inbox' \
    "$(grep -A4 '^\*\*\* 11.11 Passport' "$OT_FILE" | grep '^\*' | sed -n 2p)"
  [ -d "$r/10-19 Life admin/11 Me/11.11+ Inbox" ] || no "$m no 11.11+ Inbox folder"
  ok "$m and its folder sits next to 11.11's"
  ot add Id2 --in 11.11+ >/dev/null
  same "$m a second time it reuses it" 1 "$(grep -c '^\*\*\* 11.11+ Inbox' "$OT_FILE")"

  ot add Wp --in W0011 >/dev/null
  same "$m --in W0011: the work package's + Inbox" W0011+Inbox "$(under Wp)"
  same "$m the work package takes the space form" 1 \
    "$(grep -c '^\*\* W0011 11.11 Renew passport' "$OT_FILE")"
  [ -d "$r/W0000-9999 Work packages/W0011 11.11 Renew passport" ] || no "$m WP folder not renamed"
  [ -d "$r/W0000-9999 Work packages/W0011+ Inbox" ] || no "$m no W0011+ Inbox folder"
  ok "$m and on disk: W0011 11.11 Renew passport, W0011+ Inbox"
  ot add Wp2 --in W0011~11.11 >/dev/null
  same "$m --in W0011~11.11 after the rename" W0011+Inbox "$(under Wp2)"

  (cd "$r/10-19 Life admin/11 Me/11.12 Bank" && ot add Here >/dev/null)
  same "$m no --in, inside 11.12's folder: 11.12+ Inbox" 11.12+Inbox "$(under Here)"
  (cd "$r/10-19 Life admin/11 Me" && ot add InCat >/dev/null)
  same "$m inside 11 Me: 11.01" 11.01 "$(under InCat)"
  (cd "$r/10-19 Life admin/11 Me" && OT_CONTEXT=0 ot add NoCtx >/dev/null)
  same "$m OT_CONTEXT=0 ignores the folder" 00.01 "$(under NoCtx)"
  (cd "$t" && OT_INBOX=21 ot add Fallback >/dev/null)
  same "$m OT_INBOX when the folder gives none" 21.01 "$(under Fallback)"
  err=$(ot add x --in 12 2>&1) && no "$m --in a category with no x.01"
  same "$m a missing x.01 is an error" \
    "ot: No 12.01 Inbox in $OT_FILE: declare it and run jd scaffold" "$err"

  same "$m ot inbox: broadest first" \
    "00.01 00.01 00.01 10.01 11.01 11.01 21.01 11.11+ 11.11+ 11.12+ W0011+ W0011+" \
    "$(ot inbox --json | jq -r '[.[].inbox] | join(" ")')"
  same "$m ot inbox 11: category 11 and below, its work packages too" \
    "11.01 11.01 11.11+ 11.11+ 11.12+ W0011+ W0011+" \
    "$(ot inbox 11 --json | jq -r '[.[].inbox] | join(" ")')"
  same "$m ot inbox 10-19: the area" 8 "$(ot inbox 10-19 --json | jq length)"
  same "$m ot inbox W0011" 2 "$(ot inbox W0011 --json | jq length)"

  id=$(ot inbox system --json | jq -r '.[] | select(.title == "Sys") | .id')
  ot move "$id" --in 11.11 >/dev/null
  same "$m move --in an inbox" 11.11+Inbox "$(under Sys)"
  ot move "$id" --under 11.11 >/dev/null
  same "$m move --under files it" 11.11 "$(under Sys)"
  same "$m and it's out of the inboxes" 0 "$(ot inbox --json | jq '[.[] | select(.title == "Sys")] | length')"
  same "$m its id survives the moves" "$id" "$(ot ls --under 11.11 --json | jq -r '.[] | select(.title == "Sys") | .id')"

  got=$(emacs -Q --batch "$OT_FILE" --eval '(progn (require (quote org-lint)) (princ (format "%S" (org-lint))))' 2>/dev/null)
  same "$m org-lint finds nothing" nil "$got"
done
unset OT_ROOT

ot stop
emacsclient -s ot --eval t >/dev/null 2>&1 && no "stop left the daemon running"
ok "stop stops the daemon"

# auto mode used a daemon, and one on an absolute socket path, as the
# service runs it, works the same
export OT_DAEMON=auto OT_SOCKET=$t/sock/server OT_FILE=$t/auto/jdex.org
ot ls >/dev/null
emacsclient -s "$OT_SOCKET" --eval t >/dev/null 2>&1 || no "no daemon on $OT_SOCKET"
ok "ot starts a daemon on OT_SOCKET"
same "and it serves the same tasks" 4 "$(ot ls --json | jq length)"
ot stop
echo "$pass passed"
