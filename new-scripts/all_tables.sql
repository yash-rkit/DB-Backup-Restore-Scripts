-- =============================================================================
-- all_tables.sql
-- Consolidated schema for every status/progress table created by the backup
-- and restore scripts under new-scripts/.
--
-- In the scripts these tables live in a status database referenced as
-- ${STATUS_DB}. Here that is replaced with a configurable schema; adjust the
-- CREATE DATABASE / USE lines below to match your STATUS_DB.
--
--   Table   Source script(s)                              Purpose
--   ------  --------------------------------------------  -----------------------------
--   BLS01   logical/db_backup_all.sh                      Logical backup, per-database
--           logical/db_backup_selected.sh
--   BLS02   physical/physical_backup.sh                   Physical backup, run summary
--   BLS03   physical/physical_backup.sh                   Physical backup, per-stage log
--   BLS04   physical/physical_backup.sh                   Binlog collection status
--           physical/binlog_collect.sh
--   RLS02   logical/restore.sh                            Logical restore, per-database
--   RLS03   physical/restore_direct.sh                    Physical restore, run summary
--   RLS04   physical/restore_direct.sh                    Physical restore, per-stage log
-- =============================================================================

CREATE DATABASE IF NOT EXISTS status_db
    DEFAULT CHARSET=utf8mb4
    COLLATE=utf8mb4_unicode_ci;

USE status_db;

-- =============================================================================
-- BLS01 — Logical backup status (one row per database)
-- Source: logical/db_backup_all.sh, logical/db_backup_selected.sh
-- =============================================================================
CREATE TABLE IF NOT EXISTS BLS01 (
    S01F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'StatusId PK',
    S01F02 BIGINT NULL
        COMMENT 'CentralResultId FK→BJR01',
    S01F05 VARCHAR(255) NOT NULL
        COMMENT 'DatabaseName',
    S01F07 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL
        COMMENT 'Status',
    S01F08 INT NULL
        COMMENT 'Pid',
    S01C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S01C07 DATETIME NULL
        COMMENT 'CompletedAt',
    S01F09 VARCHAR(500) NULL
        COMMENT 'CurrentFilePath',
    S01F10 BIGINT NULL
        COMMENT 'CurrentFileSize',
    S01F11 BIGINT NULL
        COMMENT 'FinalFileSize',
    S01F12 VARCHAR(64) NULL
        COMMENT 'Sha256Checksum',
    S01F13 INT NULL
        COMMENT 'ExitCode',
    S01F14 TEXT NULL
        COMMENT 'ErrorMessage',
    S01C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt',
    PRIMARY KEY (S01F01),
    INDEX idx_bls01_result (S01F02),
    INDEX idx_bls01_status (S01F07)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;

-- =============================================================================
-- BLS02 — Physical backup status (run summary; progress bar + heartbeat)
-- Source: physical/physical_backup.sh
-- =============================================================================
CREATE TABLE IF NOT EXISTS BLS02 (
    S02F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'StatusId PK',
    S02F02 BIGINT NULL
        COMMENT 'CentralResultId FK→BJR01',
    S02F03 VARCHAR(255) NULL
        COMMENT 'ServerName',
    S02F04 VARCHAR(120) NULL
        COMMENT 'CurrentStage (live progress text)',
    S02F07 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL
        COMMENT 'Status',
    S02F08 INT NULL
        COMMENT 'Pid',
    S02C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S02C07 DATETIME NULL
        COMMENT 'CompletedAt',
    S02F09 VARCHAR(500) NULL
        COMMENT 'ArchiveFilePath',
    S02F10 BIGINT NULL
        COMMENT 'CompressedSizeBytes',
    S02F11 BIGINT NULL
        COMMENT 'UncompressedSizeBytes',
    S02F12 VARCHAR(64) NULL
        COMMENT 'Sha256Checksum',
    S02F13 VARCHAR(255) NULL
        COMMENT 'BinlogFile',
    S02F14 BIGINT NULL
        COMMENT 'BinlogPosition',
    S02F15 INT NULL
        COMMENT 'ExitCode',
    S02F16 TEXT NULL
        COMMENT 'ErrorMessage',
    S02F17 TINYINT NULL
        COMMENT 'StageNumber (1..7; used with TotalStages for progress bar)',
    S02F18 TINYINT NULL
        COMMENT 'TotalStages',
    S02F19 INT NULL
        COMMENT 'ConfigId (BJC03.ConfigId — the backup job definition, positional arg 8)',
    S02C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt (heartbeat — bumps on every write)',
    PRIMARY KEY (S02F01),
    INDEX idx_bls02_result (S02F02),
    INDEX idx_bls02_status (S02F07)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;

-- =============================================================================
-- BLS03 — Physical backup per-stage log
-- Source: physical/physical_backup.sh
-- =============================================================================
CREATE TABLE IF NOT EXISTS BLS03 (
    S03F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'StageId PK',
    S03F02 BIGINT NULL
        COMMENT 'CentralResultId FK→BJR01/BLS02',
    S03F03 TINYINT NULL
        COMMENT 'StageNumber (0=pre-flight, 1..7=backup steps)',
    S03F04 VARCHAR(120) NULL
        COMMENT 'StageText',
    S03F05 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL
        COMMENT 'StageStatus (RUNNING until the stage finishes)',
    S03F06 TEXT NULL
        COMMENT 'Message (e.g. failure reason)',
    S03C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S03C07 DATETIME NULL
        COMMENT 'CompletedAt (set when the stage finishes)',
    PRIMARY KEY (S03F01),
    INDEX idx_bls03_result (S03F02),
    INDEX idx_bls03_result_stage (S03F02, S03F01)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;

-- =============================================================================
-- BLS04 — Binlog collection status
-- Source: physical/physical_backup.sh, physical/binlog_collect.sh
-- =============================================================================
CREATE TABLE IF NOT EXISTS BLS04 (
    S04F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'CollectId PK',
    S04F02 BIGINT NULL
        COMMENT 'CentralResultId (the collection run — the backup RESULT_ID here)',
    S04F03 INT NULL
        COMMENT 'ConfigId (the backup job definition)',
    S04F04 VARCHAR(255) NULL
        COMMENT 'ServerName',
    S04F05 VARCHAR(64) NULL
        COMMENT 'ReferenceAnchor (job<cfg>_<date>)',
    S04F06 VARCHAR(32) NULL
        COMMENT 'ReferenceDate (yyyymmdd of the anchoring backup)',
    S04F07 ENUM('RUNNING','SUCCESS','FAILED','SKIPPED') NOT NULL
        COMMENT 'Status',
    S04F08 INT NULL
        COMMENT 'Pid',
    S04F09 VARCHAR(255) NULL
        COMMENT 'StartBinlog',
    S04F10 VARCHAR(255) NULL
        COMMENT 'LatestBinlog (live: file being copied; on success: newest in archive = coverage endpoint)',
    S04F11 INT NULL
        COMMENT 'CopiedThisRun',
    S04F12 INT NULL
        COMMENT 'SkippedThisRun',
    S04F13 INT NULL
        COMMENT 'ErrorsThisRun',
    S04F14 INT NULL
        COMMENT 'TotalBinlogsInArchive (cumulative for this reference)',
    S04F15 BIGINT NULL
        COMMENT 'TotalArchiveSizeBytes (cumulative)',
    S04F16 INT NULL
        COMMENT 'ExitCode',
    S04F17 TEXT NULL
        COMMENT 'ErrorMessage',
    S04C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S04C07 DATETIME NULL
        COMMENT 'CompletedAt',
    S04C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt (heartbeat)',
    PRIMARY KEY (S04F01),
    INDEX idx_bls04_result (S04F02),
    INDEX idx_bls04_config (S04F03),
    INDEX idx_bls04_ref (S04F06),
    INDEX idx_bls04_status (S04F07)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;

-- =============================================================================
-- RLS02 — Logical restore status (one row per database)
-- Source: logical/restore.sh
-- =============================================================================
CREATE TABLE IF NOT EXISTS RLS02 (
    S02F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'StatusId PK',
    S02F02 BIGINT NOT NULL
        COMMENT 'CentralResultId FK→RJR03 (many rows per result — one per database, like BLS01)',
    S02F03 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL
        COMMENT 'Status',
    S02F04 ENUM('VERIFYING_CHECKSUM','EXTRACTING','CREATING_DB','LOADING','SUCCESS','FAILED')
        NOT NULL DEFAULT 'VERIFYING_CHECKSUM'
        COMMENT 'CurrentPhase (per database)',
    S02F05 INT NULL
        COMMENT 'Pid',
    S02C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S02C07 DATETIME NULL
        COMMENT 'CompletedAt',
    S02F06 VARCHAR(255) NULL
        COMMENT 'DatabaseName (this row''s single database — placeholder until renamed post-extraction)',
    S02F07 INT NULL
        COMMENT 'ExitCode',
    S02F08 TEXT NULL
        COMMENT 'ErrorMessage',
    S02C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt',
    PRIMARY KEY (S02F01),
    INDEX idx_rls02_result (S02F02),
    INDEX idx_rls02_status (S02F03)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;

-- =============================================================================
-- RLS03 — Physical restore status (run summary; progress + heartbeat)
-- Source: physical/restore_direct.sh
-- =============================================================================
CREATE TABLE IF NOT EXISTS RLS03 (
    S03F01 INT NOT NULL AUTO_INCREMENT COMMENT 'StatusId PK',
    S03F02 BIGINT NOT NULL COMMENT 'CentralResultId FK->RJR03',
    S03F03 INT NULL COMMENT 'ConfigId (RJC04.BackupConfigId)',
    S03F04 VARCHAR(255) NOT NULL COMMENT 'ServerName',
    S03F05 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL COMMENT 'Status',
    S03F06 VARCHAR(120) NULL COMMENT 'CurrentStage (live text)',
    S03F07 TINYINT NULL COMMENT 'StageNumber (1..5)',
    S03F08 TINYINT NULL COMMENT 'TotalStages (=5)',
    S03F09 INT NULL COMMENT 'Pid',
    S03C06 DATETIME NOT NULL COMMENT 'StartedAt',
    S03C07 DATETIME NULL COMMENT 'CompletedAt',
    S03F10 VARCHAR(255) NULL COMMENT 'BackupRestored (archive basename)',
    S03F11 VARCHAR(64) NULL COMMENT 'BackupSha256',
    S03F12 VARCHAR(255) NULL COMMENT 'StartBinlog',
    S03F13 VARCHAR(32) NULL COMMENT 'StartPos',
    S03F14 INT NULL COMMENT 'DatabasesRestored',
    S03F15 INT NULL COMMENT 'BinlogsApplied',
    S03F16 INT NULL COMMENT 'BinlogErrors',
    S03F17 INT NULL COMMENT 'ExitCode',
    S03F18 TEXT NULL COMMENT 'ErrorMessage',
    S03F19 VARCHAR(255) NULL COMMENT 'CurrentBinlog (live during apply)',
    S03C04 DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt (heartbeat)',
    PRIMARY KEY (S03F01),
    INDEX idx_rls03_result (S03F02),
    INDEX idx_rls03_config (S03F03),
    INDEX idx_rls03_status (S03F05)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =============================================================================
-- RLS04 — Physical restore per-stage log
-- Source: physical/restore_direct.sh
-- =============================================================================
CREATE TABLE IF NOT EXISTS RLS04 (
    S04F01 INT NOT NULL AUTO_INCREMENT COMMENT 'StageId PK',
    S04F02 BIGINT NOT NULL COMMENT 'CentralResultId FK->RJR03',
    S04F03 TINYINT NOT NULL COMMENT 'StageNumber (0=pre-flight, 1..5)',
    S04F04 VARCHAR(120) NOT NULL COMMENT 'StageText',
    S04F05 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL COMMENT 'StageStatus',
    S04F06 TEXT NULL COMMENT 'Message',
    S04C06 DATETIME NOT NULL COMMENT 'StartedAt',
    S04C07 DATETIME NULL COMMENT 'CompletedAt',
    PRIMARY KEY (S04F01),
    INDEX idx_rls04_result (S04F02),
    INDEX idx_rls04_result_stage (S04F02, S04F01)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
