# Backup Security Work — Status

Where each task stands as of 15 September 2026.

| # | Task | Status |
| - | ---- | ------ |
| 1 | Remove plaintext password from backup script | **Not done** — deferred on purpose |
| 2 | Integrate age encryption into backup pipeline | **Done** |
| 3 | Integrate zstd compression into pipeline, confirm sequencing | **Done** |
| 4 | Live plan for the zstd sequencing decision | **Done** |
| 5 | Network round-trip review — protect data in transit | **Part done** |
| 6 | Test full pipeline: dump, compress, encrypt, transfer, decrypt-verify | **Part done** |
| 7 | Roll out across the DB server fleet | **Not started** |

Everything built so far lives in `logical_secure.sh` and
`restore_logical_secure.sh`. **Nothing in production has changed yet** —
`logical.sh` is still what runs.

---

## 1. Remove plaintext password — not done

The password is still written in the script and still passed on the command
line. MySQL warns about it on every run.

**This was deferred deliberately.** Backups are moving to the portal, which will
read the credentials from a database. Fixing it in the script now would be
thrown away. It gets fixed when that lands.

Until then the risk is unchanged from today: anyone who can read the script, or
run `ps` while a dump is in flight, sees the password.

---

## 2. age encryption — done

Every dump is encrypted immediately after it is compressed, before it goes
anywhere near the network or the share.

- Encrypted to **two public keys**; either private key alone opens the archive
- Only public keys are on the backup server — it cannot read what it writes
- The run refuses to start if a private key is found in the recipients file
- Every file is checked after encryption to confirm it really is encrypted
- The manifest records which keys open that run

---

## 3. zstd compression — done

`tar -czf` with gzip is replaced by **zstd level 9**, and the tar wrapper is
gone — it was one file inside it and bought nothing.

**Sequencing is confirmed: compress first, then encrypt.** Encrypted data does
not compress, so this is the only order that works.

Level 9 was chosen by measuring every level from 1 to 19 against 762 real
databases across two servers. Measured on a real run of 476 databases: 42.42 GB
of SQL became 6.4 GiB, against 16.91 GB under gzip.

---

## 4. Live plan for the sequencing decision — done

Written up in [compression-benchmark.md](../tests/compression-benchmark.md), with the
raw per-database data behind it. It records why level 9 and not 6, 12 or 19.

---

## 5. Network round-trip review — part done

Three legs carry backup data. Two are now covered, one is not.

| Leg | State |
| --- | ----- |
| MySQL server → backup server (the dump) | **Not protected** |
| Backup server → SMB share | Covered |
| SMB share → second share (`backup_sync.sh`) | Covered |

Legs 2 and 3 are covered because the file is already encrypted before it moves.
Nothing readable crosses those links, and nothing readable sits at the far end.

**Leg 1 is the gap.** The backup server pulls dumps from `10.10.0.4` over a
plain TCP connection. That is roughly 42 GB of readable customer SQL crossing
the network on every run. Encryption happens after the dump arrives, so it does
not help here.

Two ways to close it — pick one:

- turn on TLS for the MySQL connection, or
- run the backup on the database server itself so the dump never leaves the box

This needs a decision before rollout.

---

## 6. Test the full pipeline — part done

| Stage | Tested |
| ----- | ------ |
| Dump | Yes — 476 databases, no failures |
| Compress | Yes — every file read back and verified |
| Encrypt | Yes — every file confirmed encrypted |
| Transfer | Yes — all 476 re-read off the share and checksummed |
| **Decrypt-verify** | **No — not run yet** |

One full run against a copy of production: 476 of 476 published, zero failures,
zero warnings, 43m56s.

**Decrypt has never been tested against a real archive.** `restore_logical_secure.sh`
is written but has not been run. This is the last thing standing between the
pipeline and "proven", and it is the one step that matters most — a backup that
will not open is not a backup.

It must be run on the restore host, with **both** private keys tried
separately, before rollout.

---

## 7. Fleet rollout — not started

Three things must be fixed first. None is optional.

**Retention will silently stop.** `backup_sync.sh` and `db_cleanup.sh` both look
for `*.tar.gz`. The new archives end in `.sql.zst.age`, so sync would copy
nothing and cleanup would delete nothing — both reporting success while the
filer fills up. Both scripts must learn the new name and keep matching the old
one so existing archives still expire.

**Decrypt must be proven.** See task 6.

**The keys must be somewhere real.** An ops key on a machine that gets rebuilt,
or a break-glass key nobody can find, is the same as no key at all. Where both
private keys live needs to be written down and agreed before a single production
backup is encrypted.

---

## What to do next, in order

1. Run the decrypt test with both keys — proves the whole thing works
2. Decide how leg 1 gets protected, TLS or local dumps
3. Fix the `*.tar.gz` patterns in `backup_sync.sh` and `db_cleanup.sh`
4. Agree and record where the two private keys live
5. Run `logical.sh` once on the test machine for a fair before/after on timing
6. Roll out to one server, watch it for a week, then the rest
