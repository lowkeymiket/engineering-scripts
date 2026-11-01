#!/bin/bash
# Reference listing, edited for publication to share the approach. Environment
# values are replaced by lines marked REPLACE and the script exits until every
# one is filled in. Review the logic before use. Provided under the MIT License,
# without warranty, and run at your own risk.

# Startup guard: this must stay the first executable code in the file.
assert_reference_listing() {
  # The marker is built from two pieces so that this function does not match its own text.
  local marker="<<REPL""ACE:"
  if [ ! -f "$0" ] || grep -F -q "$marker" "$0"; then
    echo "Reference listing. Replace every placeholder and review the logic before running."
    exit 2
  fi
}
assert_reference_listing

# Swap the Level RMM agent from an old tenant to a new one on macOS (derived copy of a published note).
#
# Report-only by default: without --apply the script prints each step and changes nothing.
# With --apply it copies itself into a private work directory and relaunches that copy as a background job.
# That relaunch is the point of the design: the agent that delivers the script is the agent the script
# removes, so the work has to continue after that agent and its terminal session are gone.
#
# Lines marked ADDED are not in the published note: the report-only default, the exit-code logging,
# the read-back, the key handling and the private work directory. The step order is the published order.
# The published script writes its log and output to fixed paths in a shared folder as root; this copy writes
# them into a new directory that only root can enter, so no other user can plant a link there first.
# This copy still pipes the vendor install script into bash, as the published note does, with no hash check.
#
# Before --apply, run as root and export RMM_TENANT_KEY with the new tenant's key for that device group.
# The key is never stored in this file.

umask 077   # ADDED: files this script creates are readable by root only
set -C      # ADDED: noclobber, so a redirection never overwrites a file that already exists

APPLY=0
DETACHED=0
WORK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --detached) DETACHED=1 ;;
    --workdir) shift; WORK="$1" ;;
  esac
  shift
done

# ADDED: this sentinel stands for "no key supplied". Replace the placeholder with any fixed text that is not a key;
# the key itself always comes from the environment variable, never from this file.
KEY_UNSET="<<REPLACE: sentinel text meaning no tenant key was supplied>>"
NEW_KEY="${RMM_TENANT_KEY:-$KEY_UNSET}"          # ADDED: the key comes from the environment
INSTALL_URL="<<REPLACE: vendor install script URL>>"   # ADDED: placeholder for the vendor's install script address
APP_NAME="Level"                                 # the application bundle name; the suffix is added where it is used
FAILURES=0                                       # ADDED

# ADDED: a work directory is usable only if it exists, is not a symlink, is owned by root and has mode 0700.
check_workdir() {
  [ -n "$1" ] && [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -f %u "$1")" = "0" ] && [ "$(stat -f %Lp "$1")" = "700" ]
}

# ADDED: create a new private directory with a random name under a root-owned base that is not a symlink.
make_workdir() {
  local base="" d
  for d in /private/var/root /Library/Logs; do
    if [ -d "$d" ] && [ ! -L "$d" ] && [ "$(stat -f %u "$d")" = "0" ]; then base="$d"; break; fi
  done
  [ -n "$base" ] || return 1
  WORK="$(mktemp -d "$base/rmm-swap.XXXXXXXX")" || return 1
  chmod 700 "$WORK" || return 1
  check_workdir "$WORK"
}

# ADDED: print in report-only mode, write to the log in apply mode.
say() {
  if [ "$APPLY" = "1" ]; then echo "$1" >> "$LOG"; else echo "[report-only] $1"; fi
}

# ADDED: count a failed check.
note_fail() {
  FAILURES=$((FAILURES + 1))
  echo "FAILED: $1" >> "$LOG"
}

# ADDED: refuse to apply without root or without a supplied key.
if [ "$APPLY" = "1" ]; then
  if [ "$(id -u)" != "0" ]; then
    echo "Refusing to run: --apply needs root."
    exit 2
  fi
  if [ "$NEW_KEY" = "$KEY_UNSET" ]; then
    echo "Refusing to run: export RMM_TENANT_KEY with the new tenant key first."
    exit 2
  fi
fi

# The launch: copy this script into the private work directory and run the copy as a background job whose
# output goes to a file there. The published wrapper does the same with a plain background job and prints a
# start marker. It reports nothing about the result.
if [ "$APPLY" = "1" ] && [ "$DETACHED" != "1" ]; then
  if ! make_workdir; then
    echo "Refusing to run: no safe private work directory could be made."
    exit 2
  fi
  if ! cp "$0" "$WORK/swap.sh" || ! chmod 700 "$WORK/swap.sh"; then
    echo "Refusing to run: the script could not be copied into the work directory."
    exit 2
  fi
  RMM_TENANT_KEY="$NEW_KEY" /bin/bash "$WORK/swap.sh" --apply --detached --workdir "$WORK" >"$WORK/swap.out" 2>&1 &
  echo "migration_started"
  exit 0
fi

if [ "$APPLY" = "1" ]; then
  if ! check_workdir "$WORK"; then
    echo "Refusing to run: the work directory is missing, is a symlink, or is not private to root."
    exit 2
  fi
  LOG="$WORK/swap.log"
  OUT="$WORK/swap.out"
else
  LOG="(work directory)/swap.log"
  OUT="(work directory)/swap.out"
  say "Create a private work directory (mode 0700, owned by root, not a symlink) under /private/var/root or /Library/Logs, copy this script into it and relaunch the copy as a background job"
fi

say "=== START MIGRATION ==="

# Attempt uninstall (continue even if it errors).
if [ -x "/usr/local/bin/level" ]; then
  say "Vendor uninstall: /usr/local/bin/level --action uninstall"
  if [ "$APPLY" = "1" ]; then
    /usr/local/bin/level --action uninstall >> "$OUT" 2>&1 || echo "Vendor uninstall exit code $?" >> "$LOG"   # ADDED: the exit code is logged
  fi
else
  say "No vendor binary at /usr/local/bin/level, its uninstall is skipped"
fi

say "Wait 5 seconds"
if [ "$APPLY" = "1" ]; then sleep 5; fi

# Remove leftover identity and config. A stale identity re-enrolls the Mac in the old tenant.
say "Remove /var/lib/level, the application bundle and /usr/local/bin/level"
if [ "$APPLY" = "1" ]; then
  rm -rf /var/lib/level >> "$OUT" 2>&1 || true
  rm -rf "/Applications/${APP_NAME}.app" >> "$OUT" 2>&1 || true
  rm -f /usr/local/bin/level >> "$OUT" 2>&1 || true
  if [ -e /var/lib/level ]; then note_fail "/var/lib/level still exists after removal"; fi   # ADDED
fi

# Install for the new tenant. The published script pipes the download into bash and does not check the result.
say "Install for the NEW tenant: download the vendor install script from $INSTALL_URL and run it with LEVEL_API_KEY exported"
if [ "$APPLY" = "1" ]; then
  export LEVEL_API_KEY="$NEW_KEY"
  ( set -o pipefail; curl -fsSL "$INSTALL_URL" | /bin/bash >> "$OUT" 2>&1 )   # ADDED: pipefail, so a failed download counts
  rc=$?
  if [ "$rc" != "0" ]; then note_fail "install exit code $rc"; fi              # ADDED
fi

# ADDED: the published script has no read-back. These checks assume the new install recreates the paths
# that the cleanup step removes. They cannot show which tenant the Mac enrolled in.
say "Read-back: the vendor binary and the identity folder exist again"
if [ "$APPLY" = "1" ]; then
  if [ ! -x /usr/local/bin/level ]; then note_fail "no vendor binary after install"; fi
  if [ ! -d /var/lib/level ]; then note_fail "no identity folder after install"; fi
  echo "Read-back cannot show which tenant the Mac enrolled in: confirm that in the new tenant console." >> "$LOG"
fi

say "=== DONE MIGRATION, failed checks: $FAILURES ==="
if [ "$FAILURES" != "0" ]; then exit 1; fi
