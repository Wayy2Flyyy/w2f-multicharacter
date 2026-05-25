-- =============================================================================
-- W2F Multicharacter — full database install
-- Run once on your server database (HeidiSQL, phpMyAdmin, oxmysql, etc.)
--
-- Requires: MariaDB / MySQL 10.3+
-- Also ensure oxmysql is configured in server.cfg before starting resources.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Qbox / QBCore — core player storage
-- (from qbx_core/qbx_core.sql — safe to re-run)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `players` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `citizenid` varchar(50) NOT NULL,
  `cid` int(11) DEFAULT NULL,
  `license` varchar(255) NOT NULL,
  `name` varchar(255) NOT NULL,
  `money` text NOT NULL,
  `charinfo` text DEFAULT NULL,
  `job` text NOT NULL,
  `gang` text DEFAULT NULL,
  `position` text NOT NULL,
  `metadata` text NOT NULL,
  `inventory` longtext DEFAULT NULL,
  `phone_number` VARCHAR(20) DEFAULT NULL,
  `last_updated` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`citizenid`),
  KEY `id` (`id`),
  KEY `last_updated` (`last_updated`),
  KEY `license` (`license`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE `players`
  ADD COLUMN IF NOT EXISTS `last_logged_out` timestamp NULL DEFAULT NULL AFTER `last_updated`,
  MODIFY COLUMN `name` varchar(255) NOT NULL COLLATE utf8mb4_unicode_ci;

ALTER TABLE `players`
  ADD COLUMN IF NOT EXISTS `userId` INT UNSIGNED DEFAULT NULL AFTER `id`;

CREATE TABLE IF NOT EXISTS `bans` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(50) DEFAULT NULL,
  `license` varchar(50) DEFAULT NULL,
  `discord` varchar(50) DEFAULT NULL,
  `ip` varchar(50) DEFAULT NULL,
  `reason` text DEFAULT NULL,
  `expire` int(11) DEFAULT NULL,
  `bannedby` varchar(255) NOT NULL DEFAULT 'LeBanhammer',
  PRIMARY KEY (`id`),
  KEY `license` (`license`),
  KEY `discord` (`discord`),
  KEY `ip` (`ip`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `player_groups` (
  `citizenid` VARCHAR(50) NOT NULL,
  `group` VARCHAR(50) NOT NULL,
  `type` VARCHAR(50) NOT NULL,
  `grade` TINYINT(3) UNSIGNED NOT NULL,
  PRIMARY KEY (`citizenid`, `type`, `group`),
  CONSTRAINT `fk_citizenid` FOREIGN KEY (`citizenid`) REFERENCES `players` (`citizenid`) ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Qbox — user accounts (links license → userId for character creation)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `users` (
  `userId` int UNSIGNED NOT NULL AUTO_INCREMENT,
  `username` varchar(255) DEFAULT NULL,
  `license` varchar(50) DEFAULT NULL,
  `license2` varchar(50) DEFAULT NULL,
  `fivem` varchar(20) DEFAULT NULL,
  `discord` varchar(30) DEFAULT NULL,
  PRIMARY KEY (`userId`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- illenium-appearance — character skins & outfits
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `playerskins` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `citizenid` varchar(255) NOT NULL,
  `model` varchar(255) NOT NULL,
  `skin` text NOT NULL,
  `active` tinyint(4) NOT NULL DEFAULT 1,
  PRIMARY KEY (`id`),
  KEY `citizenid` (`citizenid`),
  KEY `active` (`active`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `player_outfits` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `citizenid` varchar(50) DEFAULT NULL,
  `outfitname` varchar(50) NOT NULL DEFAULT '0',
  `model` varchar(50) DEFAULT NULL,
  `props` varchar(1000) DEFAULT NULL,
  `components` varchar(1500) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `citizenid_outfitname_model` (`citizenid`,`outfitname`,`model`),
  KEY `citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `player_outfit_codes` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `outfitid` int(11) NOT NULL,
  `code` varchar(50) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `FK_player_outfit_codes_player_outfits` (`outfitid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `management_outfits` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `job_name` varchar(50) NOT NULL,
  `type` varchar(50) NOT NULL,
  `minrank` int(11) NOT NULL DEFAULT 0,
  `name` varchar(50) NOT NULL DEFAULT '0',
  `gender` varchar(50) NOT NULL DEFAULT 'male',
  `model` varchar(50) DEFAULT NULL,
  `props` varchar(1000) DEFAULT NULL,
  `components` varchar(1500) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- W2F — optional creation audit log (not required for gameplay)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `w2f_multicharacter_log` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `license` varchar(255) NOT NULL,
  `citizenid` varchar(50) DEFAULT NULL,
  `action` varchar(64) NOT NULL,
  `detail` text DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `license` (`license`),
  KEY `citizenid` (`citizenid`),
  KEY `action` (`action`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Phase 2 hardening migration (idempotent — safe to re-run)
-- -----------------------------------------------------------------------------
-- (license, cid) uniqueness: prevents the TOCTOU race in createCharacter
-- where two concurrent creates could both pick cid=1 on the same license.
-- The application also serializes with GET_LOCK + a transaction, but this
-- is the last line of defence at the DB level.
SET @stmt := (
  SELECT IF(
    EXISTS (
      SELECT 1 FROM information_schema.statistics
       WHERE table_schema = DATABASE()
         AND table_name = 'players'
         AND index_name = 'uq_license_cid'
    ),
    'SELECT 1',
    'ALTER TABLE `players` ADD UNIQUE KEY `uq_license_cid` (`license`, `cid`)'
  )
);
PREPARE addUq FROM @stmt; EXECUTE addUq; DEALLOCATE PREPARE addUq;

-- Index on `properties.owner` so `playerOwnsProperty` / apartment-claim
-- lookups don't full-scan when the table grows past a few thousand rows.
SET @stmt := (
  SELECT IF(
    NOT EXISTS (
      SELECT 1 FROM information_schema.tables
       WHERE table_schema = DATABASE() AND table_name = 'properties'
    ),
    'SELECT 1',
    IF(
      EXISTS (
        SELECT 1 FROM information_schema.statistics
         WHERE table_schema = DATABASE()
           AND table_name = 'properties'
           AND index_name = 'idx_properties_owner'
      ),
      'SELECT 1',
      'ALTER TABLE `properties` ADD KEY `idx_properties_owner` (`owner`)'
    )
  )
);
PREPARE addPropOwner FROM @stmt; EXECUTE addPropOwner; DEALLOCATE PREPARE addPropOwner;

-- Composite index used by the lineup / slot summary queries
-- (license + cid ordering for fast slot enumeration).
SET @stmt := (
  SELECT IF(
    EXISTS (
      SELECT 1 FROM information_schema.statistics
       WHERE table_schema = DATABASE()
         AND table_name = 'players'
         AND index_name = 'idx_players_license_cid'
    ),
    'SELECT 1',
    'ALTER TABLE `players` ADD KEY `idx_players_license_cid` (`license`, `cid`)'
  )
);
PREPARE addLicCid FROM @stmt; EXECUTE addLicCid; DEALLOCATE PREPARE addLicCid;
