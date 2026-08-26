#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# restore.sh test harness
#
# Runs restore.sh end to end against stub binaries and a fake share, so the
# restore, staging and MySQL-readiness paths can be exercised WITHOUT a MySQL
# instance, root, systemd, or a real archive. Every stub is a few lines of bash
# written into bin/ below; nothing here touches a real datadir.
#
# The sibling of restore_vm_harness.sh. restore.sh takes its server from
# constants rather than arguments, so build() rewrites SECONDARY_STORAGE_DIR
# too and run() passes a bare backup id.
#
#   ./tests/restore_harness.sh          # all scenarios
#   ./tests/restore_harness.sh 3        # one scenario by number
#   KEEP=1 ./tests/restore_harness.sh   # keep the sandbox for inspection
#
# Exit 0 = every scenario reached its expected outcome.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/../scripts/restore.sh"
[[ -f "$TARGET" ]] || { echo "cannot find restore.sh next to tests/"; exit 1; }

H="$(mktemp -d)"; export HARNESS="$H"
cleanup() { if [[ "${KEEP:-0}" == "1" ]]; then echo "sandbox kept: $H"; else rm -rf "$H"; fi; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()    { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n== %s\n' "$1"; }

mkdir -p "$H"/bin "$H"/state "$H"/livestorage/YK/Restore-VM/binlog/20260821 \
         "$H"/Data/mysql "$H"/Data/dbvault-stage "$H"/var/lib/dbvault \
         "$H"/var/lock/dbvault "$H"/var/log/mysql "$H"/elsewhere
cd "$H"

# ─── stubs.  STUB_PING picks the MySQL scenario: alive|denied|slow|crash ──
cat > bin/systemctl <<'STUB'
#!/bin/bash
case "$1" in
  start)     echo running > "$HARNESS/state/mysqld"; exit "${STUB_START_RC:-0}" ;;
  stop)      rm -f "$HARNESS/state/mysqld"; exit 0 ;;
  is-active) [[ -f "$HARNESS/state/mysqld" ]] && exit 0 || exit 3 ;;
esac
exit 0
STUB
cat > bin/pgrep <<'STUB'
#!/bin/bash
[[ -f "$HARNESS/state/mysqld" ]] && { echo 1234; exit 0; }; exit 1
STUB
printf '#!/bin/bash\nexit 0\n' > bin/mountpoint
printf '#!/bin/bash\nexit 0\n' > bin/flock
printf '#!/bin/bash\nexit 0\n' > bin/chown
printf '#!/bin/bash\necho "--log-error=$HARNESS/var/log/mysql/error.log"\n' > bin/my_print_defaults
printf '#!/bin/bash\necho "-- stub binlog output"\n' > bin/mysqlbinlog
cat > bin/mysqladmin <<'STUB'
#!/bin/bash
# "crash": the process is already gone when the first ping lands.
[[ "${STUB_PING:-alive}" == "crash" ]] && rm -f "$HARNESS/state/mysqld"
[[ -f "$HARNESS/state/mysqld" ]] || {
  echo "mysqladmin: connect to server at 'localhost' failed"
  echo "error: 'Cannot connect through socket /var/run/mysqld/mysqld.sock (2)'"
  exit 1; }
case "${STUB_PING:-alive}" in
  alive)  echo "mysqld is alive"; exit 0 ;;
  denied) echo "mysqladmin: connect failed: ERROR 1045 (28000): Access denied for user Admin@localhost"; exit 1 ;;
  slow)   echo "mysqladmin: connect to server at 'localhost' failed"; exit 1 ;;
esac
STUB
cat > bin/mysql <<'STUB'
#!/bin/bash
[[ -f "$HARNESS/state/mysqld" ]] || exit 1
[[ "${STUB_PING:-alive}" == "denied" ]] && { echo "ERROR 1045 Access denied" >&2; exit 1; }
prev=""; for a in "$@"; do [[ "$prev" == "-NBe" ]] && echo 7; prev="$a"; done
cat > /dev/null 2>/dev/null
exit 0
STUB
cat > bin/xbstream <<'STUB'
#!/bin/bash
[[ "$*" == *--help* ]] && { echo "  --decompress"; exit 0; }
D=""; prev=""; for a in "$@"; do [[ "$prev" == "-C" ]] && D="$a"; prev="$a"; done
mkdir -p "$D/mysql"; : > "$D/ibdata1"
# Without --decompress the datadir is left holding a compressed file, as the
# real two-pass flow does.
[[ "$*" == *--decompress* ]] || : > "$D/sbtest.ibd.zst"
cat > /dev/null
exit 0
STUB
cat > bin/xtrabackup <<'STUB'
#!/bin/bash
T=""; for a in "$@"; do case "$a" in --target-dir=*) T="${a#--target-dir=}";; esac; done
if [[ "$*" == *--decompress* ]]; then
  find "$T" -name '*.zst' -delete 2>/dev/null; echo "completed OK!"
elif [[ "$*" == *--prepare* ]]; then
  printf 'backup_type = full-prepared\n' > "$T/xtrabackup_checkpoints"; echo "completed OK!"
fi
exit 0
STUB
cat > bin/rsync <<'STUB'
#!/bin/bash
args=(); for a in "$@"; do [[ "$a" == -* ]] || args+=("$a"); done
n=${#args[@]}; mkdir -p "${args[$((n-1))]}"
cp -r "${args[0]}"/. "${args[$((n-1))]}"/ 2>/dev/null
exit 0
STUB
chmod +x bin/*
export PATH="$H/bin:$PATH"

# ─── fake share ──────────────────────────────────────────────────────────
BASE="$H/livestorage/YK/Restore-VM"
head -c 41943040 /dev/urandom > "$BASE/20260821.xbstream"
SHA=$(sha256sum "$BASE/20260821.xbstream" | awk '{print $1}')
{ echo "archive_format=xbstream"
  echo "prepared=no"
  echo "backup_type=full-backuped"
  echo "mysql_version=8.4.4"
  echo "datadir_bytes=104857600"
  echo "archive_sha256=$SHA"
  echo "binlog_file=binlog.001530"
  echo "binlog_pos=158"
  echo "compression=zstd"; } > "$BASE/20260821.manifest"
echo "$SHA  20260821.xbstream" > "$BASE/20260821.sha256"
echo "binlog.001530 158"       > "$BASE/20260821_binlog_info"
head -c 1024 /dev/urandom > "$BASE/binlog/20260821/binlog.001530"
head -c 1024 /dev/urandom > "$BASE/binlog/20260821/binlog.001531"
{ echo "2026-08-21T15:00:00Z 0 [ERROR] [MY-012596] [InnoDB] Cannot open datafile ./ibdata1"
  echo "2026-08-21T15:00:01Z 0 [ERROR] [MY-010457] [Server] Data Dictionary initialization failed."
} > var/log/mysql/error.log

# ─── the script under test, rewritten onto sandbox paths ─────────────────
build() {
  sed -e "s|^SECONDARY_STORAGE_DIR=.*|SECONDARY_STORAGE_DIR=\"$BASE\"|" \
      -e "s|^SMB_MOUNT_POINT=.*|SMB_MOUNT_POINT=\"$H/livestorage\"|" \
      -e "s|^LOCAL_STAGE=.*|LOCAL_STAGE=\"$H/Data/dbvault-stage\"|" \
      -e "s|^MYSQL_DATADIR=.*|MYSQL_DATADIR=\"$H/Data/mysql\"|" \
      -e "s|^ARCHIVE_STAGE_DIR=.*|ARCHIVE_STAGE_DIR=\"$H/Data/dbvault-stage\"|" \
      -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$H/var/lock/dbvault\"|" \
      -e "s|^STATE_DIR=.*|STATE_DIR=\"$H/var/lib/dbvault\"|" \
      -e "s|^XTRABACKUP_BIN=.*|XTRABACKUP_BIN=\"$H/bin/xtrabackup\"|" \
      -e "s|^XBSTREAM_BIN=.*|XBSTREAM_BIN=\"$H/bin/xbstream\"|" \
      -e "s|^MYSQL_BIN=.*|MYSQL_BIN=\"$H/bin/mysql\"|" \
      -e "s|^MYSQLADMIN_BIN=.*|MYSQLADMIN_BIN=\"$H/bin/mysqladmin\"|" \
      -e "s|^MYSQLBINLOG_BIN=.*|MYSQLBINLOG_BIN=\"$H/bin/mysqlbinlog\"|" \
      -e "s|^MYSQL_READY_TIMEOUT=.*|MYSQL_READY_TIMEOUT=${TIMEOUT:-6}|" \
      -e "s|^STAGE_ARCHIVE=.*|STAGE_ARCHIVE=${STAGE:-1}|" \
      -e "s|^KEEP_STAGED_ON_FAILURE=.*|KEEP_STAGED_ON_FAILURE=${KEEPSTAGE:-1}|" \
      -e "s|^XBSTREAM_DECOMPRESS=.*|XBSTREAM_DECOMPRESS=${ONEPASS:-0}|" \
      -e 's|^\[\[ \$EUID -eq 0 \]\]|[[ 0 -eq 0 ]]|' \
      "$TARGET" > "$H/r.sh"
  bash -n "$H/r.sh" || { echo "SYNTAX ERROR in the generated copy"; exit 1; }
}
fresh() { rm -rf Data/mysql; rm -f var/lib/dbvault/*; mkdir -p Data/mysql
          echo junk > Data/mysql/old.ibd; echo running > state/mysqld; }
run()   { bash "$H/r.sh" 20260821 "$@" 2>&1; }
# expect <label> <regex>...   — checks every regex against $OUT
expect() {
  local label="$1"; shift; local re miss=""
  for re in "$@"; do grep -qE "$re" <<< "$OUT" || miss="$miss [missing: $re]"; done
  if [[ -z "$miss" ]]; then ok "$label"; else bad "$label"; printf '       %s\n' "$miss"; fi
}
absent() { if grep -qE "$2" <<< "$OUT"; then bad "$1"; else ok "$1"; fi; }

WANT="${1:-}"
want() { [[ -z "$WANT" || "$WANT" == "$1" ]]; }

# ═══ scenarios ═══════════════════════════════════════════════════════════

if want 1; then head_ "1  healthy restore, credentials fine"
  STAGE=1 build; fresh; rm -f Data/dbvault-stage/*.xbstream
  OUT="$(STUB_PING=alive run)"
  expect "runs clean to RESULT ok" 'copying the archive to local disk' \
         'archive checksum .* OK' 'restore source' 'mysql serving .* OK' \
         'credentials accepted' 'RESULT ok ' 'removed the staged archive'
  # The whole point of the port: the extract must not be reading the share.
  expect "extract reads local disk" 'extracting the xbstream from local disk'
  absent "network is NOT in the critical path" 'network in the critical path'
fi

if want 2; then head_ "2  mysqld up, password rejected (the 2026-08-21 failure)"
  STAGE=1 build; fresh; OUT="$(STUB_PING=denied run)"
  expect "names the credential, not a timeout" 'mysql serving .* OK' \
         'credentials .* REJECTED' 'restore marker written' \
         'THE RESTORE COMPLETED' 'binlog-only'
  absent "no bogus connection-timeout message" 'did not answer'
fi

if want 3; then head_ "3  mysqld exits during startup: fail fast + error log"
  STAGE=1 build; fresh; T0=$(date +%s); OUT="$(STUB_PING=crash run)"
  D=$(( $(date +%s) - T0 ))
  expect "detects the dead process, prints mysqld's own log" \
         'mysqld exited while starting up' 'Data Dictionary initialization failed'
  if [[ $D -lt 30 ]]; then ok "failed fast (${D}s, not the whole timeout)"
  else bad "took ${D}s — should not wait the timeout out"; fi
fi

if want 4; then head_ "4  mysqld up but never serving: timeout names the setting"
  STAGE=1 build; fresh; OUT="$(STUB_PING=slow run)"
  expect "times out with guidance and the error log" 'did not answer within 6s' \
         'raise MYSQL_READY_TIMEOUT' 'Cannot open datafile'
fi

if want 5; then head_ "5  a valid staged archive is reused"
  STAGE=1 build; fresh; cp "$BASE/20260821.xbstream" Data/dbvault-stage/
  OUT="$(STUB_PING=alive run)"
  expect "reuses it" 'staged archive reused' 'RESULT ok '
  absent "did not re-copy" 'copying the archive to local disk'
fi

if want 6; then head_ "6  a corrupt staged archive is detected and re-copied"
  STAGE=1 build; fresh; head -c 41943040 /dev/urandom > Data/dbvault-stage/20260821.xbstream
  OUT="$(STUB_PING=alive run)"
  expect "re-copies over the stale file" 'staged archive .* STALE' \
         'copying the archive to local disk' 'archive checksum .* OK' 'RESULT ok '
fi

if want 7; then head_ "7  XBSTREAM_DECOMPRESS=1 folds the two passes"
  STAGE=1 ONEPASS=1 build; fresh; rm -f Data/dbvault-stage/*.xbstream
  OUT="$(STUB_PING=alive run)"
  expect "one pass, decompress skipped" 'in one pass' \
         'decompressed .*folded into the extract' 'RESULT ok '
fi

if want 8; then head_ "8  STAGE_ARCHIVE=0 keeps the old off-the-share path"
  STAGE=0 build; fresh; OUT="$(STUB_PING=alive run)"
  expect "extracts from the share as before" 'staging space .*STAGE_ARCHIVE=0' \
         'reading the whole archive off the share' \
         'network in the critical path' 'RESULT ok '
fi

if want 9; then head_ "9  a stage dir inside the datadir is refused at pre-flight"
  STAGE=1 build; fresh
  sed -i "s|^ARCHIVE_STAGE_DIR=.*|ARCHIVE_STAGE_DIR=\"$H/Data/mysql/stage\"|" "$H/r.sh"
  OUT="$(STUB_PING=alive run)"
  expect "refuses before touching anything" 'staging space .* UNSAFE PATH' \
         'would be erased by the wipe'
  if [[ -f Data/mysql/old.ibd ]]; then ok "datadir untouched"
  else bad "the datadir was modified"; fi
fi

if want 10; then head_ "10  --dry-run neither stages nor wipes"
  STAGE=1 build; fresh; rm -f Data/dbvault-stage/*.xbstream
  OUT="$(STUB_PING=alive run --dry-run)"
  expect "dry run completes" 'DRY RUN' 'archive checksum .* OK'
  if [[ -f Data/mysql/old.ibd ]]; then ok "datadir untouched"
  else bad "the datadir was wiped"; fi
  if [[ -z "$(ls Data/dbvault-stage/*.xbstream 2>/dev/null)" ]]; then ok "nothing staged"
  else bad "staged a copy during a dry run"; fi
fi

if want 11; then head_ "11  rejected credentials recover via --binlog-only"
  STAGE=1 build; fresh; OUT="$(STUB_PING=denied run)"
  expect "step 1 leaves a usable marker" 'credentials .* REJECTED' 'restore marker written'
  OUT="$(STUB_PING=alive run --binlog-only)"
  expect "step 2 applies the binlogs alone" 'applied 2 file' 'RESULT ok '
fi

if want 12; then head_ "12  a backup base off the share is refused"
  STAGE=1 build; fresh
  # The directory EXISTS, so smb_ready passes and only the prefix test can
  # catch it — which is the case the check was added for.
  cp "$BASE"/20260821.* "$H/elsewhere/" 2>/dev/null
  sed -i "s|^SECONDARY_STORAGE_DIR=.*|SECONDARY_STORAGE_DIR=\"$H/elsewhere\"|" "$H/r.sh"
  OUT="$(STUB_PING=alive run)"
  expect "names the real problem" 'backup base .* OFF THE SHARE' \
         'not under the mount point'
  if [[ -f Data/mysql/old.ibd ]]; then ok "datadir untouched"
  else bad "the datadir was modified"; fi
fi

if want 13; then head_ "13  a failure keeps the staged archive for the retry"
  # STUB_START_RC=1 fails the start AFTER the wipe and the extract, so the
  # staged copy exists and the retry advice depends on it being kept.
  STAGE=1 KEEPSTAGE=1 build; fresh; rm -f Data/dbvault-stage/*.xbstream
  OUT="$(STUB_PING=alive STUB_START_RC=1 run)"
  expect "reports the failure after the wipe" 'MySQL failed to start'
  if [[ -f Data/dbvault-stage/20260821.xbstream ]]; then
    ok "staged archive kept for the retry"
  else bad "the staged archive was deleted — the retry re-copies for nothing"; fi
  expect "the advice says the copy is skipped" 'already staged on local disk'

  # And the opposite setting actually removes it.
  STAGE=1 KEEPSTAGE=0 build; fresh; rm -f Data/dbvault-stage/*.xbstream
  OUT="$(STUB_PING=alive STUB_START_RC=1 run)"
  if [[ ! -f Data/dbvault-stage/20260821.xbstream ]]; then
    ok "KEEP_STAGED_ON_FAILURE=0 removes it"
  else bad "KEEP_STAGED_ON_FAILURE=0 left the staged archive behind"; fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
