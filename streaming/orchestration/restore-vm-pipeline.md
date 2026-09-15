# The Restore-VM Pipeline (restore → dump → sync → retention)

| Script | Role | Pre-flight |
|---|---|---|
| `final.sh` | drives the whole run from `servers.json` | 12 checks |
| `restore_vm.sh` | rebuilds the datadir from one server's archive | 16 checks |
| `logical.sh` | dumps the rebuilt instance, per database | 12 checks |
| `backup_sync.sh` | copies the newest dumps to the second share | 9 checks |
| `db_cleanup.sh` | retention over both trees on the first share | 8 checks |

Each script takes `--help`. Their `PART` banners are the in-file map; this
document is the reasoning behind them.

## 1. What the pipeline is for

A physical `.xbstream` archive is the fastest way to get a whole server back and
the worst way to get one table back: it restores a datadir, not a database. The
pipeline turns the physical archives into per-database logical dumps, on a
machine where wiping the datadir costs nothing.

Nightly, for each production server in turn:

```
backup.sh on prod  ──►  <backup_base>/20260821.xbstream        (physical, one file)
                                    │
restore_vm.sh      ──────────────────┘   erases /Data/mysql, rebuilds it,
                                         prepares it, starts MySQL, applies binlogs
                                    │
logical.sh         ──────────────────┘   mysqldump per database
                                    ▼
                        <base_dir>/<db>/<db>_20260821.tar.gz   (logical, one per db)
                                    │
backup_sync.sh     ──────────────────┘   newest per database ──► second share
db_cleanup.sh      ──────────────────┘   retention on the first share
```

Two products come out of it: the dumps, which give per-table and per-database
recovery and can be restored anywhere; and the answer to the question the
physical chain cannot answer on its own — *does that archive actually restore?*
Every night, for every server, the pipeline proves it or reports that it did not.

The restored datadir is disposable. Only the last server of the night is still on
disk when the run ends, and the next run erases that too.

## 2. The two dangers it is built around

Everything unusual in these five scripts traces back to one of these.

### 2.1 One datadir, many servers

`final.sh` restores every configured server onto the same `MYSQL_DATADIR`, one
after another. Three consequences the scripts handle explicitly:

**A wrong-server dump is invisible.** If server B's restore fails and the dump
runs anyway, it dumps server A's data — still mounted from the previous iteration
— and publishes it, checksummed and verified, under B's name. Nothing downstream
can tell. Two independent guards stop it: `final.sh` does not dump a server whose
restore failed, and `logical.sh` refuses to run unless the newest restore marker
in `STATE_DIR` belongs to the server it was told to dump. The second catches a
hand-run in the wrong order; `--no-source-check` is the documented way out when
the operator knows better.

**Markers and logs must be keyed by server, not by backup id.** Every server's
daily archive is called `20260821`. `restore.sh` keys its marker on the id alone,
which is right when one host restores one server; here it would have the second
server of the night reading the first one's binlog anchor. So `restore_vm.sh`
writes `${SERVER_NAME}_${BACKUP_ID}_restore_state` and names its logs, its staged
binlog directory and its dry-run preview the same way.

**`CONFIRM_RESTORE_VM`.** `final.sh` erases the datadir once per configured
server — on a production host, a self-inflicted outage repeated N times. The
switch exists so a deployment copied onto the wrong machine refuses to run, which
only works while it ships unset. It is a PART 1A value: it arrives as
`__SET_ME__` and the run stops until somebody decides, on that host, which answer
is true.

### 2.2 The destination is CIFS, and CIFS lies

[streaming-backup.md](../physical/streaming-backup.md) §1 covers the base case: an
unmounted share is an ordinary empty directory that passes `-d`, `-w`, `ls` and
`mkdir -p`, and writes land on the root filesystem.

What is new here is that the paths are **arguments**, so a typo is a plausible
daily event rather than a one-off edit. Every script taking a path argument checks
two separate things:

| Check | Catches |
|---|---|
| `mountpoint -q "$SMB_MOUNT_POINT"` | the share is not mounted at all |
| `[[ "$PATH_ARG" == "$SMB_MOUNT_POINT"/* ]]` | a path spelled wrong, or pointing off the share entirely |

`mountpoint` is only ever true for the mount point itself, never a subdirectory,
which is why the prefix test has to be a separate string comparison. Without it
`--base_dir=/livestorge/Logical/X` (one letter missing) is a perfectly writable
local directory that fills the root filesystem while every step reports success.

`EXTRA_MOUNTS` extends the prefix test when the trees are spread over more than
one filer. A path under none of the listed mounts is an ordinary local directory,
and is refused.

`db_cleanup.sh` inverts the same reasoning: unmounted, it would find nothing to
delete and report a clean run, hiding the fact that retention has silently
stopped. It refuses to walk a path that is not under the mount.

## 3. Published layout

Two trees on the primary share. `backup_base` is written by the production host;
`base_dir` is written by the restore VM.

```
/livestorage/
├── Backup/<server>/                       ← backup_base, one per prod server
│   │   the seven parts below share one backup id and expire together under
│   │   physical_retention; deleting the archive alone would strand binlog/<id>
│   ├── 20260821.xbstream                     physical archive
│   ├── 20260821.sha256
│   ├── 20260821.manifest
│   ├── 20260821_binlog_info
│   ├── binlog/20260821/                      collected binlogs
│   ├── meta/20260821/
│   └── logs/20260821/restore_<stamp>/        ← restore_vm.sh publishes here
│
├── Logical/<server>/                      ← base_dir, one per prod server
│   ├── <database>/
│   │   ├── <database>_20260821.tar.gz         the dump
│   │   └── <database>_20260821.tar.gz.sha256
│   ├── manifests/20260821.manifest
│   └── logs/20260821/                         ← logical.sh publishes here
│
├── final/pipeline_logs/<stamp>/           ← final.sh publishes here
└── final/cleanup_logs/<stamp>/            ← db_cleanup.sh publishes here

/southstorage/                             ← the second share
├── <sync_dest>/<database>/<database>_20260821.tar.gz(+.sha256)
└── backup_latest/_sync_logs/<stamp>/       ← backup_sync.sh publishes here

/Data/dbvault-stage/                        ← LOCAL, holds nothing after a run
├── <script>_<stamp>.log                       logs, until they are published
└── .logical_<server>_<stamp>/build/            one .sql + .tar.gz per slot
```

`sync_dest` is per server, from the config file; it defaults to
`/southstorage/backup_latest/<server_name>`.

### Naming

Dumps follow the same rule as the physical archives: **bare date, with a time
appended only when that day's archives already exist on the share**
(`db_20260821.tar.gz`, then `db_20260821_175047.tar.gz`). The share is the
authoritative collision test — local staging is emptied as each database
finishes, so a published archive is the only proof the day is taken. The test
sits after the lock, or two runs starting together would both decide they were
first.

A `.tar.gz` contains exactly one file, `<database>_<run id>.sql`, which is what
[`standalone/logical/restore_logical.sh`](../../standalone/logical/restore_logical.sh)
expects.

Archive discovery is by **mtime** (`find -printf '%T@'`), not by name, so it does
not depend on the producer's naming convention; `.part` files cannot match the
glob.

### Directories that are not databases

`logical.sh` writes `logs/` and `manifests/` inside `base_dir`, beside the
per-database directories. `backup_sync.sh` and `db_cleanup.sh` skip them by name
and skip anything beginning with `.` or `_`:

```
NON_DB_DIRS="logs manifests cleanup_logs restart-logs meta"
```

Without that, `logs/` reads as a database with no archives in it. Both scripts
must carry the same list, or one copies what the other expires.

## 4. `final.sh`

No arguments in normal use. The server list comes from `CONFIG_FILE` in PART 1C,
default `/Data/script/servers.json`; `--config=PATH` overrides it.

### The config file

A JSON array, processed in order:

```json
[
  {
    "server_name": "Cloud-Live-DB-Default",
    "backup_base": "/livestorage/Backup/Cloud-Live-DB-Default",
    "base_dir":    "/livestorage/Logical/Cloud-Live-DB-Default"
  },
  {
    "server_name": "GSP-Cloud-Live-DB",
    "backup_base": "/livestorage/Backup/GSP-Cloud-Live-DB",
    "base_dir":    "/livestorage/Logical/GSP-Cloud-Live-DB",
    "skip_binlog": true,
    "physical_retention": "days:14"
  }
]
```

| Key | Required | Read by | Meaning |
|---|---|---|---|
| `server_name` | yes | all three | identity: names the dump tree, the marker, the logs |
| `backup_base` | yes | `final`, `db_cleanup` | where that server's `backup.sh` publishes its `.xbstream` |
| `base_dir` | yes | all three | where this run's logical dumps are published |
| `backup_id` | no | `final` | an exact archive id, instead of the date's latest |
| `skip_binlog` | no | `final` | `true` restores that one server to the backup point only |
| `sync_dest` | no | `final`, `backup_sync` | `backup_sync.sh`: destination on the second share |
| `retention` | no | `final`, `db_cleanup` | `"smart"` or `"days:N"`, over `base_dir` |
| `physical_retention` | no | `final`, `db_cleanup` | `"smart"` or `"days:N"`, over `backup_base` |

> **`servers.example.json` also carries `mode`, `db_list_dir` and `mysql_host`.
> No script reads any of them** — `final.sh` passes `logical.sh` only
> `--server_name` and `--base_dir`, and `logical.sh` accepts nothing else. They
> are inert: setting them changes nothing and raises no error. Either drop them
> from the example file, or wire them through before relying on them.

**This one file drives all four steps.** No script carries its own server list, so
adding a server is one JSON entry, and removing one cannot leave a stale array
behind that keeps expiring a tree nothing writes to any more. `final.sh` validates
`sync_dest` and `retention` even though it never uses them — a typo surfaces in
pre-flight instead of three hours later, in the step that does consume it.

[`servers.example.json`](./servers.example.json) is a working starting point.

### The last two steps are opt-in

| Config state | Step 2 sync | Step 3 cleanup |
|---|---|---|
| no `sync_dest` on an entry | that server is not copied | — |
| no `sync_dest` on any entry | **does not run** (skipped) | — |
| no `retention` on an entry | — | that server's dumps never expire |
| no `retention` on any entry | — | the dump pass deletes nothing |
| no `physical_retention` on an entry | — | that server's `.xbstream` sets never expire |
| neither retention field anywhere | — | **does not run** (skipped) |

With neither field anywhere, the pipeline restores and dumps and stops, and still
reports `RESULT ok`. A skipped step is a deliberate outcome, not a failure — only
a step that was asked for and then broke sets the exit status.

Because of that, a host that never syncs need not deploy `backup_sync.sh` at all.
Pre-flight notes a missing child script but does not refuse; if the config *does*
ask for that step and the script is absent, the step fails with `SCRIPT MISSING`
and the run exits non-zero.

### Validated before the first datadir is erased

Pre-flight reads every entry, checks the three required keys, that `server_name`
is a safe single path component, that both paths are under the mount, and that no
`server_name` appears twice. Every problem is printed, then the run stops with a
count.

Discovering a typo in entry four *after* entries one to three have been restored
and dumped costs hours and leaves the night half finished — hence one pass up
front rather than a per-iteration check. The entries are read into arrays once, so
editing the config mid-run cannot change what the running pipeline does.

### A failed server is data, not an abort

`fail_run` is for the pipeline: bad config, a missing child script, an unreachable
share. A **server** failing is recorded in `FAILED_SERVERS` and the loop continues,
because the other sixteen dumps are still worth having. A restore failure skips
that server's dump; a dump failure is reported against the server that had already
restored.

Sync and cleanup still run afterwards. Sync copies the newest dump of each
database, so a server that failed tonight still has yesterday's copied forward;
cleanup never deletes the newest archive of a database, so that copy survives the
gap. The exit status is non-zero if any server, the sync, or the cleanup failed.

### Child output, order, shutdown

Children use the same log engine, so their lines land in the pipeline log already
formatted. `run_child` tees each child's output to the terminal and the run log and
reads the child's own `RESULT` line back to quote it in the summary.
`PIPESTATUS[0]` decides success — `tee`'s status is always 0.

Cleanup runs **after** sync: retention deletes from the primary share, and an
archive not yet copied to the second share must not be a deletion candidate in the
same run.

`shutdown -h +10` comes after `publish_logs`, always in that order — a VM that
powers off with its only log on local disk has thrown the run away.
`--no-shutdown` skips it, `--dry-run` implies it (a dry run never erases a
datadir, so it never needs the VM to stop), and `SHUTDOWN_ON_FAILURE=0` keeps the
machine up when the run was incomplete. A pipeline that dies in `fail_run` never
schedules a shutdown at all.

## 5. `restore_vm.sh`

The same three phases as [`restore.sh`](../physical/restore.sh) — verify, restore
(**copy → wipe → extract → decompress → prepare → start**), apply — with the same
one-shot binlog apply and the same state-selected failure advice, plus one
addition: the source server is an argument. See
[streaming-backup.md](../physical/streaming-backup.md) §9 for the phase logic; only
the differences are below.

| `restore.sh` | `restore_vm.sh` |
|---|---|
| `SECONDARY_STORAGE_DIR` is a constant | `--backup_base`, validated to be under the mount |
| backup id is a positional argument | `--backup_id`, or the latest archive of `--backup_date` (default today) |
| marker `${BACKUP_ID}_restore_state` | marker `${SERVER_NAME}_${BACKUP_ID}_restore_state` |
| 14 pre-flight checks | 16 — adds `backup base` under the mount and `archive staging space` |
| extracts straight off the share | copies the archive to local disk first (`STAGE_ARCHIVE=1`) |
| next step: take a fresh backup | next step: `logical.sh` — this datadir is temporary |

`restore.sh` is unchanged and stays the tool for restoring a server onto itself.

### Staging the archive on local disk

`STAGE_ARCHIVE=1` (the default) copies the `.xbstream` from the share to
`ARCHIVE_STAGE_DIR` **before** MySQL is stopped, checksums the local copy, and
extracts from there. Set it to `0` for the old behaviour.

**The network leaves the destructive window.** The wipe happens only once a
verified local copy exists, so a share that drops costs a retry instead of leaving
a half-populated datadir with the old data already gone.

**It is also much faster.** `xbstream` reads stdin serially in small chunks and
interleaves thousands of file creations; over SMB each one pays link latency.
Measured on the same 14GiB archive, same share, same run:

| | over the network | throughput |
|---|---|---|
| flat read (`sha256sum` of the archive) | 14 GiB | 71 MiB/s |
| `xbstream -x` reading the same file | 14 GiB | 17 MiB/s |

The old flow paid that slower read *and* read the archive twice, once to verify
and once to extract. Staging reads it once, at the faster rate. Checksumming the
local copy is also a stronger guarantee: it certifies the exact bytes the extract
will consume, where the old order left a window in which two separate reads could
disagree.

On success the staged file is deleted. On failure it is **kept**
(`KEEP_STAGED_ON_FAILURE=1`) — already verified, so a re-run checksums it and
skips the copy, turning a ~25-minute redo into roughly 8 minutes.

`archive staging space` is a pre-flight check of its own because the stage and the
datadir may share a filesystem and compete for one budget. It compares
`stat -c %d` on both paths and sizes the requirement accordingly. Getting this
wrong means ENOSPC *after* the wipe.

### One-pass extract (`XBSTREAM_DECOMPRESS`)

Off by default. Set to `1`, `xbstream -x --decompress` writes the datadir already
expanded, so the `.zst` files are never created and never read back — saving a
1x-compressed write plus read (~2 minutes on a 14GiB archive; the 94GiB write
dominates either way and remains).

The real gain is not speed. The two-pass flow has a silent-corruption path:
`--prepare` skips a leftover compressed file without complaint and it becomes an
unreadable tablespace at runtime. The script guards it with a `find` for
`*.zst *.qp *.lz4`, but one-pass extraction removes the intermediate compressed
state altogether, so there is nothing to leave behind. Verify support before
enabling — not every build has it:

```bash
xbstream --help | grep -i decompress
```

### Waiting for MySQL after the restore

Readiness and authentication are checked **separately**, and this matters more
than it sounds.

A physical restore overwrites `mysql.user` with the **source** server's accounts.
After restoring server A onto host B, `MYSQL_USER`'s password is whatever it is on
A — so a credential-based readiness probe can be rejected by a server that
restored perfectly and is serving normally.

The probe is therefore `mysqladmin ping`, and an `Access denied` reply counts as
**up**: the server parsed the handshake in order to refuse it. Three states are
distinguished where the old loop reported all of them as
`MySQL did not accept connections within 120s`:

| State | Client error | What happens |
|---|---|---|
| still starting | 2002 / 2003 | keep waiting, up to `MYSQL_READY_TIMEOUT` |
| process gone | any, and `mysql_up` false | **fail immediately**, with the mysqld error log |
| up, password rejected | 1045 | readiness passes; the credential is reported separately |

`MYSQL_READY_TIMEOUT` (default `900`) replaces a hardcoded 60 × 2s: a large
datadir can spend well over two minutes opening tablespaces, and waiting is far
cheaper than repeating the restore. A dead mysqld is detected on the next poll
rather than at the timeout. Every failure prints the tail of **mysqld's own error
log**, located from `my_print_defaults` rather than from the server.

If the credentials are rejected the restore is already complete and the marker
already written, so recovery does not repeat it:

```bash
systemctl stop mysql
# start with --skip-grant-tables, reset the account, restart
restore_vm.sh --server_name=NAME --backup_base=PATH --binlog-only
```

`fail_run` reports this accurately. Its `DATADIR_WIPED` branch used to state
"MySQL is stopped" as fixed text, which was false whenever the failure came
*after* the start — precisely when it misleads. It now observes `mysql_up`, so a
failure after a completed restore says so instead of sending the operator to redo
work that is intact.

### Resolving "today's latest"

With no `--backup_id`, the id is the newest archive whose name starts with the
date. Both naming forms coexist on the share, so date and time are **separate sort
keys**, with a bare date read as time `000000`:

```
20260821          → 20260821 000000
20260821_143005   → 20260821 143005
```

A plain lexical sort puts `20260821_143005` *before* `20260821` (`_` sorts before
end-of-string) and would quietly anchor on the day's *first* backup. This is the
same rule `binlog_collect.sh` uses for anchor discovery, and it is load-bearing —
do not reduce it to `sort | tail -1`.

Resolution happens in PART 7, **before** the log exists, because the log is named
after the id. Failures there print plainly and exit; they are the one class of
failure in these scripts with no formatted output. The mount is checked first, so
"the share is gone" and "there is no archive for that date" are different messages.

`--binlog-only` resolves against the restore markers in `STATE_DIR` instead of the
archives: it needs an id that was restored *here*, and the archive may since have
been pruned. On `--binlog-only` the marker wins, because it records what this
server actually restored.

## 6. `logical.sh`

Four steps: `list` → `dump` → `verify` → `manifest`. Derived from
[`standalone/logical/logical.sh`](../../standalone/logical/logical.sh) — same
`mysqldump` options, same per-database `.tar.gz`, same bare-filename checksum
sidecar — restructured onto the streaming log engine, with the buffer-pool
machinery (commented out in the original) dropped.

Its only arguments are `--server_name=`, `--base_dir=` and `--no-source-check`.

### The connection and the source check

`MYSQL_HOST` is a PART 1A value — empty selects the local socket, and there is no
command-line override. On the restore VM this must be the instance
`restore_vm.sh` just rebuilt. It is not a production host: pointing it at one
turns a DR drill into load on live data.

The source check is the guard from §2.1 — the newest `*_restore_state` in
`STATE_DIR` must belong to `--server_name`, or the run dies before dumping
anything. It also gives the manifest something useful:
`restored_from_backup_id` ties every dump back to the physical archive it came out
of. `--no-source-check` downgrades it to a skipped check, for an instance that
holds the right data by some other route.

### Built locally, published once

The archive is built on **local disk** and only the finished file crosses the
network. Dumping straight onto the share costs three passes over the same data:

| Where the work happens | Network passes over one database |
|---|---|
| On the share | write the `.sql`, read it back for `tar`, write the `.tar.gz`, read that back for `sha256sum` — plus the verify read |
| Locally (this script) | write the finished `.tar.gz` once — plus the verify read |

`PARALLEL` databases at a time, and each goes all the way through before its slot
is reused:

1. `mysqldump` to `<build>/<db>_<run id>.sql` — local
2. `tar -czf --remove-files` to `<build>/<db>_<run id>.tar.gz` — local; the `.sql`
   is dropped as the archive is written, so the slot holds both copies for the
   shortest time it can
3. `tar -tzf` — local, so reading the archive back costs nothing
4. `sha256sum` into `<archive>.sha256` — local. This hash is the reference the copy
   on the share is verified against; hashing *after* the transfer would only prove
   the share agrees with itself
5. `cp` to `<dest>.tar.gz.part`, `sync`, rename, copy the sidecar across, then
   delete both local files

A failure at any step is recorded and the run continues: one unreadable schema must
not cost the other sixteen. `.part` matters because `backup_sync.sh` and
`db_cleanup.sh` both glob `*.tar.gz` — a half-written archive must not be visible
to either.

Because the archive is staged locally, `LOCAL_STAGE` needs room for the `PARALLEL`
largest databases at once — each slot holds an uncompressed `.sql` and, briefly,
its archive. **Pre-flight checks only that `LOCAL_STAGE` is writable, not that it
is large enough**: there is no space check here and no `LOCAL_SPACE_PCT`. On a host
that also runs MySQL, filling that filesystem is the failure mode to watch, so
size `LOCAL_STAGE` against the largest `PARALLEL` schemas by hand, or add the
check.

A dump that dies on a lock error is retried: `DUMP_ATTEMPTS` (3) tries per
database, `DUMP_RETRY_WAIT` (5s) apart. Only lock errors retry — any other failure
is recorded once and the run moves on.

Workers run under `xargs` in their own subshells, so a variable a worker sets dies
with it. Each writes a status file into `WORK_DIR` — pessimistically, before it
starts, so a worker killed outright still reads as a failure rather than as a
database nobody looked at — and the parent tallies those files.

### Verify, and partial success

The verify step is the one deliberate re-read. Every published archive is read back
off the share and checked against the checksum computed locally before the
transfer, so it proves the file on CIFS matches the file that was built — the only
check that catches an archive which reached the share wrong. A mismatch fails the
run and the file is **left in place**: its sidecar already fails, so nothing
downstream will trust it, and it is evidence.

`RESULT failed` and exit 1 whenever any database failed, even though the archives
that did publish are complete and restorable. A partial dump set that reports
success is how a missing database goes unnoticed for a month.

## 7. `backup_sync.sh`

Four steps: `discover` → `copy` → `retention` → `prune`.

Both source and destination come from the config file, per server: `base_dir` is
the source, `sync_dest` the destination. There is no server array in the script and
no `--source_base`/`--dest_base` — one server, one entry, one place.

**`sync_dest` is opt-in and has no default.** An entry without it is not copied
anywhere, and is named in the log as skipped rather than silently omitted. A config
where no entry has one means there is nothing to do: the script prints
`BACKUP SYNC NOT CONFIGURED`, exits 0, and `final.sh` records the step as *skipped*.
Inventing a default destination would start copying data somewhere nobody asked
for — on a share that may not even be mounted.

Two different mounts, so both get the full treatment: `mountpoint` on each, plus a
prefix test on every `base_dir` against `SOURCE_MOUNT_POINT` and every `sync_dest`
against `DEST_MOUNT_POINT`. An entry whose source and destination are the same path
is refused outright — copying a tree onto itself and then expiring it deletes
backups.

**Discover first.** The whole copy set — the newest archive of every database of
every configured server — is resolved before anything is written, so the
destination is sized once instead of being discovered full halfway through. A tight
fit warns rather than dies: most of the set is usually already there and will be
skipped, and the retention pass has not run yet.

**Copy, verify, then rename.** `cp` to `<name>.part`, verify at the destination,
`mv` into place. Verification prefers the producer's `.sha256`, because that proves
the copy matches what was *dumped*, not merely what the source file currently reads
as; size is the fallback for archives predating the sidecars. A mismatch deletes
the copy and records the failure. The sidecar travels with the archive, so the
second share can be verified on its own later without reaching back to the first.
An archive already at the destination with the same name and size is skipped — the
name embeds the run id, so a same-name archive is the same archive.

**Retention, destination only.** Nothing on the source is ever deleted by this
script; that is `db_cleanup.sh`'s job. On the destination, `*.tar.gz` older than
`DEST_RETENTION_DAYS` goes, **except the newest archive in the directory**, however
old: a server that has stopped producing dumps must not have its last copy aged
out, because that is precisely when the copy matters. `DEST_RETENTION_DAYS=0` is
refused in pre-flight — it would delete a copy the day it was made.

The stray `shutdown -h +5` at the end of the `vm-scripts/` original is gone.
Shutting the VM down is `final.sh`'s decision, and a sync run by hand should not
take the machine with it.

## 8. `db_cleanup.sh`

Two steps: `retention` → `prune`. Two independent, opt-in rules over two trees:

| Config key | Tree | Expires |
|---|---|---|
| `retention` | `base_dir` | the logical dumps, file by file |
| `physical_retention` | `backup_base` | the physical backups, set by set |

```json
{ "server_name": "Cloud-Live-DB-Default",
  "base_dir":    "/livestorage/Logical/Cloud-Live-DB-Default",
  "retention":   "smart" }
```

**Both are opt-in with no default.** An entry without a key is never expired under
that rule, and is named in the log as skipped. A config where no entry has either
prints `DB CLEANUP NOT CONFIGURED`, exits 0, and `final.sh` records the step as
*skipped*. A script whose only job is `rm` deletes exactly what it was told to and
nothing by assumption. There is no `SERVERS` array either: a server removed from
the pipeline stops being expired at the same moment it stops being dumped.

| Pattern | Keeps |
|---|---|
| `days:N` | every archive from the last N days |
| `smart` | every archive from the last `SMART_DAILY_DAYS` (7) days, plus the last `SMART_WEEKDAY_KEEP` (3) archives written on `SMART_WEEKDAY` (7 = Sunday) |

`smart` keeps a fixed recent window and then thins to one chosen weekday, so the
guard window it needs is `SMART_DAILY_DAYS + SMART_WEEKDAY_KEEP * 7` days.

### A physical backup is not one file

`backup.sh` and `binlog_collect.sh` publish seven parts per backup id, and they
only mean anything together:

```
PHYSICAL_GLOB="*.xbstream"
PHYS_SET_SUFFIXES=".xbstream .sha256 .manifest _binlog_info"
PHYS_SET_DIRS="binlog meta logs"
```

So the physical pass expires an **id**, not a file. Deleting the archive alone
would strand `binlog/<id>`, which keeps growing until the next full backup and is
unreplayable without the anchor it belongs to.

`delete_set` removes the `.xbstream` **first**, deliberately: `restore_vm.sh`
discovers backups by globbing `*.xbstream`, so removing it makes the set invisible
to the resolver immediately — no restore can select a set that is half gone — and
it frees the bulk of the space up front. An interrupted delete then leaves only
small metadata behind, which `sweep_orphans` collects on the next run.

Three further constraints:

- **Every entry, path and pattern, is validated in pre-flight,** before anything is
  deleted. A typo in entry four must not be discovered after entries one to three
  have been pruned.
- **`ALWAYS_KEEP_NEWEST=1`.** The newest archive of a database, and the newest
  physical set of a server, are never deleted under either pattern. Without it, a
  database that stopped being dumped loses its last backup on a quiet Tuesday.
- **The `.sha256` sidecar goes with the archive.** An orphan checksum is a file
  that looks like a backup record and refers to nothing.

`fail_run` reports the count of deletions already made: they are permanent, and a
run that aborted mid-pass left retention partly applied.

## 9. What is deliberately not here

- **No retention for anything an entry did not ask for** — see §8.
- **No cross-database consistency in the dumps.** `--single-transaction` gives each
  database an internally consistent snapshot at its own moment. The physical
  archive underneath is a single point in time; the dump set taken from it is not.
- **No PITR from the dumps.** `--source-data=2` records a binlog coordinate as a
  comment, and pre-flight drops the option rather than failing every database when
  the user lacks `REPLICATION CLIENT`. Point-in-time recovery is the physical
  chain's job.
- **No parallel servers.** One datadir means one restore at a time. `final.sh`
  holds a lock for the whole run and each child takes its own.

## 10. Deploying and first run

```bash
# on the restore VM
install -m 755 restore_vm.sh logical.sh backup_sync.sh db_cleanup.sh final.sh /Data/script/
install -m 644 servers.example.json /Data/script/servers.json   # then edit it

# LF line endings and the exec bit both matter
bash -n /Data/script/final.sh
```

### Then fill in PART 1A

Each script ships with its per-VM settings set to `__SET_ME__` and **refuses to
start** until they are replaced. Run one and it names the lines to edit:

```
[ERROR] final.sh has not been configured for this host.
        Open it, find PART 1A, and replace __SET_ME__ in:
          CONFIRM_RESTORE_VM
          SMB_MOUNT_POINT
        Nothing has been read, written or deleted.
```

Twelve lines in total across the five scripts. On this fleet:

| Script | PART 1A |
|---|---|
| `final.sh` | `CONFIRM_RESTORE_VM=1`, `SMB_MOUNT_POINT="/livestorage"` |
| `restore_vm.sh` | `MYSQL_USER`, `MYSQL_PASSWORD`, `SMB_MOUNT_POINT="/livestorage"` |
| `logical.sh` | `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_HOST=""`, `SMB_MOUNT_POINT="/livestorage"` |
| `backup_sync.sh` | `SOURCE_MOUNT_POINT="/livestorage"`, `DEST_MOUNT_POINT="/southstorage"` |
| `db_cleanup.sh` | `SMB_MOUNT_POINT="/livestorage"` |

Nothing else in PART 1 has to be touched to deploy.

### First run, in this order

```bash
# 1. Prove the pipeline can read everything, without touching a datadir.
/Data/script/final.sh --dry-run

# 2. One server, by hand, no binlogs, no shutdown — the first destructive run.
/Data/script/restore_vm.sh --server_name=Cloud-Live-DB-Default \
  --backup_base=/livestorage/Backup/Cloud-Live-DB-Default --skip-binlog
/Data/script/logical.sh --server_name=Cloud-Live-DB-Default \
  --base_dir=/livestorage/Logical/Cloud-Live-DB-Default

# 3. Retention, previewed, before it is ever allowed to delete.
/Data/script/db_cleanup.sh --dry-run

# 4. The whole thing, still without the shutdown.
/Data/script/final.sh --no-shutdown

# 5. Nightly.
#    30 2 * * *  /Data/script/final.sh >/dev/null 2>&1
```

Take a VM snapshot of the restore VM before step 2.

### Reading a run afterwards

Every script's log ends with one greppable line:

```bash
grep -h ' RESULT ' /livestorage/final/pipeline_logs/*/pipeline.log | tail -20
```

```
 RESULT ok server=Cloud-Live-DB-Default id=20260821 applied=6 gaps=0 dur_s=1841 warn=0
 RESULT ok server=Cloud-Live-DB-Default run=20260821 dbs=17 ok=17 failed=0 bytes=41231089664 dur_s=2260 warn=0
 RESULT ok servers=5 copied=17 skipped=0 failed=0 deleted=12 bytes=41231089664 dur_s=612 warn=0
 RESULT ok servers=5 deleted=9 kept=131 errors=0 freed=31889063936 dur_s=44 warn=0
 RESULT ok run=20260821_023001 servers=5 ok=5 failed=0 sync=ok cleanup=ok dur_s=14022 warn=0
```

The pipeline log contains every child's output as well, so it is the only file that
has to be read after a failure. Per-step logs stay where the child put them:
`<backup_base>/logs/<id>/restore_<stamp>/` and `<base_dir>/logs/<run id>/`.

## 11. Configuration reference

Settings live in three places, and the split is deliberate:

| Where | What | Changes when |
|---|---|---|
| `servers.json` | per **server**: which trees, which retention | a server is added or removed |
| PART 1A of a script | per **VM**: credentials, mount points, the wipe switch | the deployment moves to a new host |
| PART 1B / 1C | tuning, and constants shared between the scripts | rarely, and deliberately |

Nothing else is configuration. Binaries, the datadir and the systemd unit are asked
for at run time, and per-run choices arrive as arguments.

### The PART 1 tiers

| Tier | Heading | Rule |
|---|---|---|
| 1A | SET PER VM | Ships as `__SET_ME__`. The script refuses to start while any is untouched. |
| 1B | TUNING | Working defaults. Change for a measured reason. |
| 1C | SHARED | The other scripts on this host assume these values. Change in all of them, or none. |
| 1D | NOT SET HERE | Detected at run time, or passed as arguments. Nothing to fill in. |
| 1E | GUARD | The check itself. |

The guard runs before the log engine starts, before the lock is taken and before
the share is touched, so a misconfigured copy costs a second and changes nothing.
That matters because the alternative is silent: a script carrying another host's
values runs perfectly and does the wrong thing, and here the wrong thing is a wiped
datadir. In `logical.sh` and `restore_vm.sh` the guard is deferred slightly, so a
credential override on the command line has its chance first.

### 1A — the per-VM values

| Setting | In | What it is | What a copied value does |
|---|---|---|---|
| `CONFIRM_RESTORE_VM` | `final.sh` | `1` on the dedicated restore VM, `0` everywhere else | `1` on a production host erases that host's datadir once per server in `servers.json`, nightly, unattended |
| `MYSQL_USER`, `MYSQL_PASSWORD` | `restore_vm.sh`, `logical.sh` | the local account | fails loudly at the connection check |
| `MYSQL_HOST` | `logical.sh` | the instance to dump — the LOCAL restored one. `""` selects the local socket | an address copied from another VM turns the dump into read load on live production data, the one thing this VM exists to avoid |
| `SMB_MOUNT_POINT` | `final.sh`, `restore_vm.sh`, `logical.sh`, `db_cleanup.sh` | the CIFS mount point itself, not a directory beneath it | `mountpoint -q` is true only for the exact mount path. Wrong here and the "is the share really mounted" check never fires, so a dropped share reads as an empty local directory and the run writes to the root filesystem |
| `SOURCE_MOUNT_POINT`, `DEST_MOUNT_POINT` | `backup_sync.sh` | the two shares | as above, once per share. They should be different filers — the script verifies each is mounted and that the JSON paths sit under the right one, but it cannot tell two mounts of one filer apart |

`CONFIRM_RESTORE_VM` is why the guard exists. Every other mistake in this table is
recoverable; that one is an outage repeated until somebody notices.

### 1B — tuning

| Setting | Script | Default | Notes |
|---|---|---|---|
| `CONFIRM_WIPE` | `restore_vm.sh` | `1` | `0` disables restores on this host entirely |
| `PARALLEL_THREADS` | `restore_vm.sh` | blank | xbstream extract and `--decompress`. Blank means half the cores of whatever VM it lands on; fill in a number to pin it |
| `PREPARE_USE_MEMORY` | `restore_vm.sh` | `1G` | xtrabackup's own default is 100MB, which makes the redo apply crawl |
| `DATADIR_SPACE_PCT` | `restore_vm.sh` | `120` | space requirement, % of the source datadir |
| `ARCHIVE_EXPANSION_FACTOR` | `restore_vm.sh` | `5` | fallback when the manifest carries no `datadir_bytes` |
| `STAGE_ARCHIVE` | `restore_vm.sh` | `1` | copy the archive to local disk before the wipe; `0` extracts straight off the share |
| `ARCHIVE_STAGE_DIR` | `restore_vm.sh` | `/Data/dbvault-stage` | where the staged `.xbstream` lives |
| `KEEP_STAGED_ON_FAILURE` | `restore_vm.sh` | `1` | a retry then skips the copy |
| `XBSTREAM_DECOMPRESS` | `restore_vm.sh` | `0` | one-pass extract. Verify the build first |
| `MYSQL_READY_TIMEOUT`, `MYSQL_READY_INTERVAL` | `restore_vm.sh` | `900`, `2` | how long to wait for the restored server to accept a connection |
| `PARALLEL` | `logical.sh` | `3` | databases dumped at once. NOT derived from the core count — this is load on the MySQL instance, not CPU work on this box |
| `SOURCE_CHECK` | `logical.sh` | `1` | refuse to dump when the newest restore marker names a different server |
| `DUMP_ATTEMPTS`, `DUMP_RETRY_WAIT` | `logical.sh` | `3`, `5` | retries per database, on a lock error only |
| `DUMP_OPTS` | `logical.sh` | — | `--hex-blob` is deliberately absent: no binary columns in these schemas |
| `SYNC_LOG_BASE`, `DEST_LOG_DAYS` | `backup_sync.sh` | — | keep the log base under `DEST_MOUNT_POINT`; the point is that the logs survive losing the source |
| `DEST_RETENTION_DAYS` | `backup_sync.sh` | `3` | destination retention. `0` would delete a copy the moment it was made, so pre-flight refuses it |
| `SMART_DAILY_DAYS`, `SMART_WEEKDAY`, `SMART_WEEKDAY_KEEP` | `db_cleanup.sh` | `7`, `7`, `3` | what `"smart"` means: full daily coverage, then the last three Sundays |
| `ALWAYS_KEEP_NEWEST` | `db_cleanup.sh` | `1` | never delete a database's last archive or a server's last physical set, however old |
| `LOG_KEPT` | `db_cleanup.sh` | `1` | log every archive kept and why; `0` logs deletions only |
| `EXTRA_MOUNTS` | `backup_sync.sh`, `db_cleanup.sh` | empty | other mounts that may legitimately hold a configured path |
| `PIPELINE_LOG_BASE` | `final.sh` | — | one directory per pipeline run |
| `SHUTDOWN_DELAY_MIN`, `SHUTDOWN_ON_FAILURE` | `final.sh` | `10`, `1` | shut down even after a failure: every log is on the share by then |
| `KEEP_LOCAL_DAYS` | all five | `14` | prunes logs stranded on the VM by a dead share |

### 1C — shared between the scripts

| Setting | Value | Why it has to match |
|---|---|---|
| `CONFIG_FILE` | `/Data/script/servers.json` | `final.sh`, `backup_sync.sh` and `db_cleanup.sh` each default to it. `final.sh` passes its own value down with `--config=`, so a pipeline run stays consistent even if a child's default was edited |
| `LOCAL_STAGE` | `/Data/dbvault-stage` | logs and staging during a run |
| `LOCK_DIR` | `/var/lock/dbvault` | `final.sh` holds the pipeline lock; each child takes its own beside it |
| `STATE_DIR` | `/var/lib/dbvault` | the restore marker. `restore_vm.sh` writes it, `logical.sh` reads it for the source check — different values there and the check silently never matches |
| `NON_DB_DIRS` | `logs manifests cleanup_logs restart-logs meta` | directories in a dump tree that are not databases. `backup_sync.sh` and `db_cleanup.sh` must agree, or one copies what the other expires |
| `ARCHIVE_GLOB` | `*.tar.gz` | what a logical archive looks like |
| `PHYSICAL_GLOB`, `PHYS_SET_SUFFIXES`, `PHYS_SET_DIRS` | see §8 | `db_cleanup.sh` only: what a complete physical set is |
| `BINLOG_PREFIX` | `binlog` | the **producing** host's `log_bin` basename, which is what names the binlog files on the share. Not this host's — this host's datadir is about to be erased, and its own naming is irrelevant to the chain being applied |

### 1D — not set anywhere

Resolved at run time. Each honours an environment variable, for the rare host where
the detected answer is wrong.

| Value | How it is found | Override |
|---|---|---|
| `MYSQL_DATADIR` | `SELECT @@datadir` from the running server, then `my_print_defaults mysqld` when it is down | `MYSQL_DATADIR=/srv/mysql ./restore_vm.sh ...` |
| `MYSQL_SERVICE` | the first of `mysql`, `mysqld`, `mariadb` that `systemctl cat` knows | `MYSQL_SERVICE=mysqld ./restore_vm.sh ...` |
| `MYSQL_BIN`, `MYSQLDUMP_BIN`, `XTRABACKUP_BIN`, `XBSTREAM_BIN`, `MYSQLADMIN_BIN`, `MYSQLBINLOG_BIN` | `command -v` | `MYSQLDUMP_BIN=/opt/mysql/bin/mysqldump ./logical.sh ...` |
| `RESTORE_SCRIPT`, `LOGICAL_SCRIPT`, `SYNC_SCRIPT`, `CLEANUP_SCRIPT` | beside `final.sh`, via `SCRIPT_DIR` | `RESTORE_SCRIPT=/Data/script/restore_vm.sh.known-good ./final.sh` |
| `SERVER_NAME`, `SECONDARY_STORAGE_DIR` | `--server_name=`, `--backup_base=` | — |
| `BASE_DIR` | `--base_dir=` | — |

The datadir is the one worth understanding. `restore_vm.sh` **erases** it on every
run. Asking the server where it is beats a path typed into a file that was copied
from another host; and when the server is down, `my_print_defaults` reads the same
`my.cnf` that `mysqld` itself would read, so a VM whose MySQL has never started
still resolves correctly. If neither answers, the script stops rather than guessing
at a directory it is about to delete. Both the value and where it came from are
printed in the run header:

```
 datadir         : /Data/mysql  (@@datadir)
```

`MYSQL_SERVICE` is resolved before `MYSQL_DATADIR`, because the readiness probe
needs the service name and the datadir lookup consults that probe.

### Checking a deployment

`--dry-run` resolves everything, prints the header and the full pre-flight, and
touches nothing. It is the fastest way to see what a host will actually use:

```bash
/Data/script/final.sh --dry-run
```
