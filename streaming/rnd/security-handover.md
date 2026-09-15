# Logical Backups — Compression and Encryption Handover

What we do today, what we are changing it to, and why.

---

## 1. How it works today

`logical.sh` runs once per database:

1. `mysqldump` writes a plain `.sql` file
2. `tar -czf` wraps it and compresses it with **gzip** — output is `<database>_<run id>.tar.gz`
3. `sha256sum` writes a checksum file next to it
4. The archive is copied to the SMB share
5. `backup_sync.sh` copies the whole tree to a second share

To restore, `restore_logical.sh` does `tar -xzf` and feeds the `.sql` into `mysql`.

**There is no encryption anywhere in this.** The dumps are compressed, not protected.

### Why that is a problem

The archives sit on two CIFS filers. Both are outside the database server's
trust boundary. That means every customer schema is readable by:

- anyone with the share credentials
- any filer administrator
- anyone who walks off with a disk from either filer

gzip is not security. `tar -xzf` needs no key and no password.

---

## 2. What we are changing

The same pipeline. Two steps change, everything else stays as it is.

| | Today | New |
| --- | ----- | --- |
| Compression | gzip, inside a tar | **zstd level 9**, no tar |
| Encryption | none | **age**, two recipients |
| File published | `<db>_<run>.tar.gz` | `<db>_<run>.sql.zst.age` |
| Checksum file | `.sha256` | `.sha256` (unchanged) |

The new script is `logical_secure.sh`. The pre-flight checks, the parallel
workers, the verify step and the failure handling are all the same as
`logical.sh`.

---

## 3. What each database goes through

Steps 1-6 happen on the backup server. Only step 7 touches the network.

| # | Step |
| - | ---- |
| 1 | `mysqldump` writes `<db>_<run>.sql` |
| 2 | `zstd -9` compresses it to `.sql.zst` and deletes the `.sql` |
| 3 | `zstd -t` reads the compressed file back to prove it is good |
| 4 | `age` encrypts it to `.sql.zst.age` and the `.zst` is deleted |
| 5 | the file is checked to confirm it really is encrypted |
| 6 | `sha256sum` writes the checksum file |
| 7 | both files are copied to the share |

**Step 3 matters.** It is the last moment the backup server can look inside the
file. After step 4 there is no key on that machine to open it again.

**Step 5 matters more.** If `age` ever failed to encrypt — wrong flag, broken
build, replaced binary — every later step would still succeed and plain dumps
would land on the filer while the log said everything was fine. This check
turns that into a visible per-database failure that publishes nothing.

If one database fails, the run records it and carries on with the rest. The run
still exits with an error, so a partial backup is never reported as a success.

---

## 4. Why compress first, then encrypt

Encrypted data looks like random noise, and random noise does not compress.

If we encrypted first, zstd would save nothing. So the order is fixed:
**compress, then encrypt.** It is not a preference, it is the only order that works.

---

## 5. How age works — the short version

age uses a **key pair**: a public key and a private key.

- The **public key** can only lock a file
- The **private key** is the only thing that can unlock it

Only the public keys are installed on the backup server. That server can create
backups it cannot read. Steal the server, steal a filer, steal a disk — none of
it gets you the data, because the key that opens it was never there.

### We use two keys, not one

The recipients file holds two public keys:

| Key | Where the private half lives | Used for |
| --- | ---------------------------- | -------- |
| ops key | the restore host, root-only | normal restores |
| break-glass key | offline — safe or password manager | when the ops key is lost |

**Either private key opens any archive on its own.** They are not halves of one
key; they are two independent ways in. The second key costs about 200 bytes per
file and exists so that one lost key does not destroy every backup we hold.

---

## 6. How zstd works — the short version

zstd does the same job as gzip, with a newer algorithm. It has levels 1 to 19;
higher means smaller and slower. **We use level 9.**

Level 9 was chosen by measuring every level against 762 real databases. It is
smaller, faster and cheaper on CPU than the gzip setting it replaces.

---

## 7. Restoring

Use `restore_logical_secure.sh`. It runs six steps and dumps the current data
first, so you can roll back. The manual path below does not.

By hand, one stage at a time:

```bash
cd /path/to/database

# 1. verify — the archive is intact
sha256sum -c mydb_<run>.sql.zst.age.sha256

# 2. decrypt — produces the compressed dump
age -d -i /etc/dbvault/dbvault-ops.key \
    -o mydb_<run>.sql.zst \
    mydb_<run>.sql.zst.age

# 3. decompress — produces the plain SQL
zstd -d mydb_<run>.sql.zst -o mydb_<run>.sql

# 4. inspect — confirm it is the database you meant
head -40 mydb_<run>.sql
grep -m2 -E 'CREATE DATABASE|^USE ' mydb_<run>.sql

# 5. load
mysql -u<user> -p < mydb_<run>.sql
```

**No pipes.** Each stage writes a file, so you can check it at step 4 before
anything is loaded. You also see which stage failed.

The `.sql.zst` and `.sql` files hold live data in the clear. Delete them when you
are done.

If the ops key does not work, use the break-glass key.

The dump carries `CREATE DATABASE` and `USE`, so it picks its own target
database. That is why step 4 matters.
