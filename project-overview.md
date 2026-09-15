# MySQL Backup and Restore Scripts

Two suites of backup scripts for MySQL, plus the docs and test harnesses that go
with them. Both write to the same SMB/CIFS storage, use the same lock interlock,
and recover to a file+position. They differ in how they are configured and how
the physical archive is written.

| | [standalone/](./standalone/) | [streaming/](./streaming/) |
|---|---|---|
| Configured by | editing the `CONFIGURATION` block in each script | `servers.json` |
| Scope | one server | many servers in one run |
| Physical archive | `tar.gz` — datadir written three times | `xbstream` — written once |
| `--prepare` runs | during backup | during restore |
| Orchestration | none; run each script yourself | `final.sh` chains four stages |
| Test harnesses | — | [streaming/tests/](./streaming/tests/) |

`streaming/` is a variant of `standalone/`, **not a replacement**. Both are
current. The behaviour they share is documented once, in
[standalone/physical/physical-backup.md](./standalone/physical/physical-backup.md);
[streaming/physical/streaming-backup.md](./streaming/physical/streaming-backup.md)
covers only what differs.

## Which restore do I run?

Read `archive_format` from the backup's manifest:

| `archive_format` | Restore with |
|---|---|
| `tar.gz` (physical) | [standalone/physical/restore_full.sh](./standalone/physical/restore_full.sh), then `apply_binlog.sh` |
| `xbstream` | [streaming/physical/restore.sh](./streaming/physical/restore.sh) |
| `tar.gz` (logical dump) | [standalone/logical/restore_logical.sh](./standalone/logical/restore_logical.sh) |
| `sql.zst.age` | [streaming/rnd/restore_logical_secure.sh](./streaming/rnd/restore_logical_secure.sh) — not production, see below |

Note that `tar.gz` appears twice: physical archives and logical dumps both use
it. The manifest sits beside the archive and tells you which is which.

## Layout

Each folder holds its scripts and the document that describes them, side by side.

```
standalone/
  logical/        mysqldump backup and restore            + logical-backup.md
  physical/       XtraBackup, binlog collection, PITR     + physical-backup.md

streaming/
  orchestration/  final.sh and the four stages it runs:
                    restore_vm.sh, logical.sh, backup_sync.sh, db_cleanup.sh
                  plus servers.json, which drives all of them
                                                          + restore-vm-pipeline.md
  physical/       xbstream backup, binlog collection, restore
                                                          + streaming-backup.md
  rnd/            compressed and encrypted logical backups — in development
  tests/          harnesses and benchmarks                + compression-benchmark.md

logs/             run and benchmark output — never committed
```

## Before you run anything

- **`servers.json` holds credentials.** The copy in `orchestration/` is the
  reference template. At deploy time the scripts read `/Data/script/servers.json`
  by default, overridable with `--config=`.
- **`final.sh` erases `MYSQL_DATADIR`,** once per server. It belongs on a
  dedicated restore VM and nowhere else. It checks `CONFIRM_RESTORE_VM` first.
- **Nothing in [streaming/rnd/](./streaming/rnd/) is production.** The encrypted
  logical backup work is unfinished — `logical_secure.sh` and
  `restore_logical_secure.sh` live there because they are still being developed,
  not because they are ready. Current status is in
  [security-status.md](./streaming/rnd/security-status.md).
