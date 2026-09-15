# `logical_secure.sh` — compressed and encrypted logical backups

`logical.sh` publishes `<database>_<run id>.tar.gz` in the clear. Anyone with
share credentials, filer admin, or a stolen disk reads every customer database.

`logical_secure.sh` publishes `<database>_<run id>.sql.zst.age` instead:
compressed with zstd -9, then encrypted to public keys the backup host cannot
decrypt with. Everything else — the pre-flight, the source check, the parallel
workers, the verify step, the failure handling — is unchanged.

| | `logical.sh` | `logical_secure.sh` |
| --- | ------------ | ------------------- |
| Compression | gzip -6, inside tar | zstd -9, no tar |
| Encryption  | none | age, multiple recipients |
| Artifact    | `<db>_<run>.tar.gz` | `<db>_<run>.sql.zst.age` |
| Sidecar     | `.sha256` | `.sha256` |
| Size (762 dbs) | 24.03 GB | **9.43 GB** |
| Backup window  | 39m 41s | **33m 46s** |

Sizing comes from [compression-benchmark.md](../tests/compression-benchmark.md).

---

## 1. The threat this closes

The dumps sit on a CIFS filer, and `backup_sync.sh` copies them to a second
one. Both are outside the database host's trust boundary. Plaintext dumps there
mean every customer schema is readable by anyone who reaches either filer.

**Public-key encryption is what makes this work.** The backup VM holds only the
*public* keys. It can encrypt and can never decrypt. So taking the VM, taking
either filer, or taking a disk out of either, yields nothing readable — the
private key is not in any of those places.

This has one consequence that must be understood before adopting it: **the
backup host cannot verify that an archive decrypts.** Proving that needs the
private key, and putting it here would undo the whole design. See §6.

---

## 2. Keys

### Generate two

Run this **off the backup VM** — on a workstation, or wherever secrets live.

```bash
age-keygen -o dbvault-ops.key
age-keygen -o dbvault-breakglass.key
```

Each prints its public key:

```
Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

**Two keys, not one.** age wraps a fresh random file key once per recipient, so
any single private key opens the archive and the others are unaffected. The
whole file costs about 200 extra bytes.

With one key, losing it makes every archive ever written with it permanently
unreadable. That is the most common way backup encryption projects fail, and a
second recipient is the entire fix.

### The recipients file

Only the **public** keys go on the backup VM:

```bash
sudo mkdir -p /etc/dbvault
sudo tee /etc/dbvault/recipients.txt <<'EOF'
age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
age1lggyhqrw2nlhcxprm67z43rta597azn8gknawjehu9d9dl0jq3yqqvfafg
EOF
sudo chmod 644 /etc/dbvault/recipients.txt
```

Public keys are not secret, so `0644` is correct. Blank lines and `#` comments
are ignored.

### Where the private keys go

| Key | Lives | Used for |
| --- | ----- | -------- |
| `dbvault-ops.key` | the restore host, `0600`, root only | day-to-day restores |
| `dbvault-breakglass.key` | offline — safe, printed, or a password manager | the day the ops key is lost |

**Neither ever goes on the backup VM.** Pre-flight refuses to start if it finds
an `AGE-SECRET-KEY-` line in the recipients file, because that single mistake
would hand every archive to whoever reaches the VM.

---

## 3. Configuring the script

PART 1A, on each backup VM:

```bash
MYSQL_USER="..."
MYSQL_PASSWORD="..."
MYSQL_HOST="..."
SMB_MOUNT_POINT="/livestorage"
AGE_RECIPIENTS_FILE="/etc/dbvault/recipients.txt"
```

PART 1B, if you ever need to change them:

```bash
ZSTD_LEVEL=9        # 1-19. 9 chosen by benchmark
ZSTD_THREADS=1      # per worker; PARALLEL is the concurrency knob
MIN_RECIPIENTS=2    # below this the run warns
```

`ZSTD_LEVEL` is capped at 19 deliberately. Levels 20-22 need a large memory
window to **decompress**, so choosing one commits every future restore host, not
just this one.

`ZSTD_THREADS=1` matters: `PARALLEL=3` workers each running `-T0` would
oversubscribe a box that is also running MySQL.

---

## 4. Running it

Identical to `logical.sh`:

```bash
logical_secure.sh --server_name=NAME --base_dir=PATH [--no-source-check]
```

```bash
logical_secure.sh \
  --server_name=Cloud-Live-DB-Default \
  --base_dir=/livestorage/Backup/Cloud-Live-DB-Default
```

### What gets published

```
<base_dir>/<database>/<database>_<run id>.sql.zst.age
<base_dir>/<database>/<database>_<run id>.sql.zst.age.sha256
<base_dir>/manifests/<run id>.manifest
<base_dir>/logs/<run id>/logical.log
```

---

## 5. What happens to one database

Steps 1-6 are entirely local; only step 7 crosses the network. `PARALLEL`
databases run at once, and each finishes before its slot is reused.

| # | Step | Fails as |
| - | ---- | -------- |
| 1 | `mysqldump` to `<db>_<run>.sql` | `fail mysqldump` |
| 2 | `zstd -9 --rm` to `<db>_<run>.sql.zst` | `fail zstd` |
| 3 | `zstd -t` — read the compressed stream back | `fail zstd_test` |
| 4 | `age -R recipients` to `<db>_<run>.sql.zst.age` | `fail age` |
| 5 | confirm the `age-encryption.org/v1` header is present | `fail not_encrypted` |
| 6 | `sha256sum` into the sidecar | `fail sha256` |
| 7 | copy to `<dest>.part`, `sync`, rename, copy sidecar | `fail publish` |

**Step 3 is the last point at which the content can be checked on this host.**
After step 4 there is no key here to open it again, so the compressed stream is
integrity-tested while that is still possible.

**Step 5 is the guard that matters most.** If `age` ever passed its input
through unencrypted — a broken build, a bad flag, a substituted binary — every
later step would succeed and plaintext dumps would land on the NAS reporting
success the whole way. The header check makes that a per-database failure that
publishes nothing.

`--rm` on step 2 drops the `.sql` as the `.zst` is written, so a worker holds
both copies for the shortest time it can. The `.zst` is removed as soon as the
`.age` exists.

A failure at any step is recorded and the run continues: one unreadable schema
must not cost the other 285. A run with any failure still exits 1 — a partial
dump set that reports success is how a missing database goes unnoticed.

---

## 6. What the verify step does, and does not, prove

Step 3 of the run re-reads every published archive off the share and checks it
against the checksum computed locally before the transfer.

**It proves** the bytes on the filer are exactly the bytes that were built. That
is the check that catches an archive which reached CIFS wrong, and it is
unchanged from `logical.sh` — a checksum does not care that the content is
encrypted.

**It cannot prove** the archive decrypts, because that needs a private key and
this host deliberately has none.

Three independent integrity guarantees still cover the content:

| Layer | Catches |
| ----- | ------- |
| sha256 sidecar | corruption in transit to the filer |
| age AEAD | any tampering or corruption, at decrypt time |
| zstd frame checksum | corruption of the compressed stream |

**Decryptability is proven separately**, on the restore host where the key
legitimately lives. Run a drill on a schedule:

```bash
# on the restore host, with the ops key
age -d -i /etc/dbvault/dbvault-ops.key \
    /livestorage/Backup/NAME/somedb/somedb_<run>.sql.zst.age \
  | zstd -t   &&  echo "decrypts and decompresses cleanly"
```

Do this after any key rotation, and periodically regardless. An untested
restore path is not a restore path.

---

## 7. Restoring

```bash
# decrypt and decompress to a .sql
age -d -i /etc/dbvault/dbvault-ops.key ARCHIVE.sql.zst.age \
  | zstd -d > restored.sql

# or straight into MySQL
age -d -i /etc/dbvault/dbvault-ops.key ARCHIVE.sql.zst.age \
  | zstd -d \
  | mysql --defaults-extra-file=/etc/dbvault/client.cnf
```

Verify the checksum first — it is the cheap check and it runs from inside the
directory wherever the tree is mounted:

```bash
cd /livestorage/Backup/NAME/somedb
sha256sum -c somedb_<run>.sql.zst.age.sha256
```

If `age -d` fails, try the break-glass key. Either one works on its own.

The dumps carry `CREATE DATABASE` and `USE`, so no database needs naming on the
command line.

---

## 8. The manifest

Every run writes `<base_dir>/manifests/<run id>.manifest`, which now records how
the archives were built:

```
archive_format=sql.zst.age
compression=zstd
compression_level=9
encryption=age
age_recipients=age1ql3z7...;age1lggyhq...
age_recipient_count=2
restore_requires=an age private key matching one of the recipients above
```

**The recipient list is the important line.** An archive found two years from
now says exactly which keys open it, so a rotated key does not turn old backups
into a guessing game. They are public keys, so nothing secret is recorded.

---

## 9. Key rotation

Old archives stay readable only by the keys that were recipients when they were
written. Adding a key does not retro-fit it to anything already published.

To rotate:

1. Generate the new keypair off the VM
2. Add its **public** key to `recipients.txt` — keep the old one for now
3. Run a backup; confirm the manifest lists both
4. Keep the old private key for as long as archives encrypted to it are retained
5. Remove the old public key from `recipients.txt` only once nothing on either
   filer still needs it

The retention window is what decides step 5. Destroying a private key while
archives encrypted to it are still on disk makes those archives unreadable.

---

## 10. Before this replaces `logical.sh`

Three things must be dealt with. They are not optional.

**`backup_sync.sh` and `db_cleanup.sh` both hardcode `ARCHIVE_GLOB="*.tar.gz"`.**
With the new extension, sync silently copies nothing and reports success, and
cleanup finds nothing to delete — **retention stops and the filer fills up**,
quietly. Both must learn `*.sql.zst.age` (and keep matching `*.tar.gz`, so
existing archives still expire normally). `backup_sync.sh` also looks for
`*.tar.gz.part` stale files in two places.

**There is no logical restore script in `streaming/`.** The only one in the
tree is `standalone/logical/restore_logical.sh`, which hardcodes a different
`BASE_DIR` and does `tar -xzf`. Until an encryption-aware replacement exists,
the procedure in §7 is manual.

**The keys must be somewhere you can actually reach.** An ops key on a host that
was rebuilt, or a break-glass key nobody can find, is the same as no key.

---

## 11. Notes

**Compression before encryption is not a choice.** Encrypted output is
indistinguishable from random data and does not compress. Encrypting first
would make zstd useless. age performs no compression of its own, which is why
zstd is needed at all — unlike GPG, which compresses internally.

**Encryption costs about 0.03% in size.** Measured: 100,000,000 bytes became
100,024,698. There is a fixed ~300-byte header (about 200 of that being the
second recipient) plus 16 bytes per 64 KiB chunk.

**Memory.** zstd -9 peaks around 85 MB per process against gzip's 2 MB, so
roughly 255 MB at `PARALLEL=3`. That is the entire cost of the change; CPU,
size, and time all improve.

**No tar.** A tar wrapper around a single file adds a header and a layer to
every restore, and buys nothing. `zstd -t` replaces `tar -tzf` as the integrity
test, and age's AEAD is stronger than either.
