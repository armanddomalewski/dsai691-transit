-- =============================================================================
-- create_and_load.sql
-- DSAI 691 — Relational Databases — Group Project, Task 2
-- Bay Area transit reliability: 511 regional archive, August 2026
--
-- Source: https://api.511.org/transit/datafeeds?operator_id=RG&historic=2026-08-so
--         ~600 MB compressed / ~3.7 GB uncompressed. stop_observations.txt alone
--         is 2.9 GB and ~25.8 M rows.
--
-- Expected setup: the archive's .txt files are extracted into the directory the
-- Postgres container mounts at /data (see compose.yaml, ./data:/data). Run with:
--
--     docker exec -i postgres psql -U transit -d postgres < create_and_load.sql
--
-- Note -d postgres, the maintenance database, NOT -d transit. This script drops
-- and recreates the transit database, and a database cannot be dropped from
-- inside itself.
--
-- This script is re-runnable end to end: it drops everything it creates before
-- creating it, and a second run produces an identical database.
-- =============================================================================


-- =============================================================================
-- SECTION 0 — reset
--
-- WITH (FORCE) terminates any open connections before dropping — without it,
-- Metabase's connection pool alone is enough to block the drop and stop the
-- script here.
-- =============================================================================

DROP DATABASE IF EXISTS transit WITH (FORCE);
CREATE DATABASE transit;
\c transit

-- Belt and braces: these make the rest of the script re-runnable on its own if
-- someone runs it against an existing database instead of from scratch.
-- Dropped in reverse dependency order so foreign keys never block a drop.
DROP TABLE IF EXISTS stop_observations CASCADE;
DROP TABLE IF EXISTS trips             CASCADE;
DROP TABLE IF EXISTS routes            CASCADE;
DROP TABLE IF EXISTS stops             CASCADE;
DROP TABLE IF EXISTS agency            CASCADE;

CREATE EXTENSION IF NOT EXISTS postgis;


-- =============================================================================
-- SECTION 1 — dimension tables
--
-- feed_version note: GTFS only guarantees that identifiers are unique *within*
-- one published feed. Agencies republish when service changes, and some of them
-- regenerate trip_id and route_id values each time. Loading a second month into
-- these tables without versioning would let one identifier describe two
-- different things, and every join through it would silently mix them. So
-- feed_version (the archive month, e.g. '2026-08') is part of the key on every
-- table whose identifiers can be recycled.
--
-- agency is exempt: agency codes like 'SF' and 'AC' are stable across feeds.
-- =============================================================================

CREATE TABLE agency (
    agency_id                  TEXT PRIMARY KEY,
    agency_name                TEXT NOT NULL
);


CREATE TABLE routes (
    route_id                   TEXT,
    feed_version               TEXT NOT NULL,
    agency_id                  TEXT NOT NULL,
    route_short_name           TEXT,
    route_long_name            TEXT,
    route_type                 INTEGER,
    route_color                TEXT,

    PRIMARY KEY (route_id, feed_version),

    -- Requires agency to be loaded first.
    CONSTRAINT fk_routes_agency
        FOREIGN KEY (agency_id)
        REFERENCES agency (agency_id)
);


CREATE TABLE stops (
    stop_id                    TEXT,
    feed_version               TEXT NOT NULL,
    stop_name                  TEXT,

    -- NUMERIC rather than DOUBLE PRECISION: exact decimal, no binary rounding.
    -- PostGIS functions take double precision, so the geom UPDATE casts.
    stop_lat                   NUMERIC,
    stop_lon                   NUMERIC,

    -- 0 = stop, 1 = station, 2 = station entrance, 3 = generic node,
    -- 4 = boarding area. Blank means 0. Filter to stops for the map, or you
    -- get pins on BART stairwells.
    location_type              INTEGER,

    -- Links a platform to its parent station, so several platform ids can be
    -- collapsed to one place name.
    parent_station             TEXT,

    -- Populated after load from stop_lat / stop_lon; 4326 is the WGS 84
    -- lat/lon system used by GPS and web maps.
    geom                       geometry(Point, 4326),

    PRIMARY KEY (stop_id, feed_version)
);


CREATE TABLE trips (
    trip_id                    TEXT,
    feed_version               TEXT NOT NULL,
    route_id                   TEXT,
    service_id                 TEXT,
    direction_id               INTEGER,
    trip_headsign              TEXT,

    PRIMARY KEY (trip_id, feed_version),

    -- Requires routes to be loaded first.
    CONSTRAINT fk_trips_routes
        FOREIGN KEY (route_id, feed_version)
        REFERENCES routes (route_id, feed_version)
);


-- =============================================================================
-- SECTION 2 — fact table
--
-- One row per observed vehicle movement between two consecutive stops.
--
-- Two decisions here came out of inspecting the real file rather than the
-- documentation, and both would have broken the load if taken on faith:
--
--   1. Time columns are INTERVAL, not TIME. GTFS represents after-midnight
--      service with hours past 24:00:00 — a 12:30 am arrival on an evening trip
--      is 24:30:00. This file reaches hour 32, and ~910 K rows (3.5%) are at or
--      past hour 24. Postgres TIME rejects those outright, so a TIME column
--      would have failed partway through a 25.8 M-row COPY. Combine with
--      service_date to get a real timestamp.
--
--   2. There is no stop_id. Rows are segments, carrying from_stop_id and
--      to_stop_id. At the first stop of a trip from_stop_id is empty and
--      to_stop_id holds the stop, so to_stop_id is the stop an observation
--      belongs to.
-- =============================================================================

CREATE TABLE stop_observations (

    -- Surrogate key. The natural candidate is
    -- (trip_id, service_date, stop_sequence, feed_version), but its uniqueness
    -- is unverified against 25.8 M rows. See Section 7 — if it holds, add it as
    -- a UNIQUE constraint rather than replacing this.
    observation_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- ---------- identity ----------
    trip_id                    TEXT,
    feed_version               TEXT NOT NULL,
    service_date               DATE,
    stop_sequence              INTEGER,          -- observed max 132

    -- ---------- what the vehicle actually did ----------
    observed_arrival_time      INTERVAL,
    observed_departure_time    INTERVAL,

    -- Provided by the feed, but unreliable: the minimum across the file is
    -- -86,382 seconds, almost exactly negative one day. That is a midnight
    -- wraparound — arrival near 23:59, departure just after midnight,
    -- subtracted without accounting for the date rolling over. The interval
    -- columns above do handle this correctly (they reach hour 32), so prefer
    -- recomputing dwell from them over trusting this column.
    dwell_time_secs            INTEGER,

    -- ---------- what the timetable promised ----------
    trip_start_time            INTERVAL,
    scheduled_arrival_time     INTERVAL,
    scheduled_departure_time   INTERVAL,
    scheduled_dwell_time_secs  INTEGER,

    -- ---------- computed at load ----------
    -- observed_arrival_time - scheduled_arrival_time, in seconds.
    -- Positive is late, negative is early, exactly zero is suspicious: a real
    -- bus essentially never arrives at its scheduled second, so a cluster of
    -- zeros means the agency's prediction engine is echoing the timetable
    -- rather than tracking a vehicle.
    -- Stored rather than computed live because nearly every dashboard panel
    -- groups on it, and a column can be indexed where an expression is awkward.
    delay_secs                 INTEGER,

    -- ---------- denormalized from the feed ----------
    -- route_id and agency_id are carried in the fact table itself, so the
    -- worst-routes leaderboard and the per-agency quality audit need no join
    -- to trips at all.
    route_id                   TEXT,
    agency_id                  TEXT,
    direction_id               INTEGER,          -- 0 / 1; 2,722 rows blank

    -- ---------- segment endpoints ----------
    from_stop_id               TEXT,
    to_stop_id                 TEXT,             -- the stop this row is about

    -- ---------- feed metadata ----------
    -- GTFS-RT trip-level enum: 0 = scheduled, 1 = added, 3 = cancelled.
    -- Confirmed empirically: all 892,262 rows with value 3 have no observed
    -- arrival, and all 7,306 rows with value 1 do have one — which rules out
    -- the stop-level enum, where 1 would mean SKIPPED.
    -- Filter to 0 for any delay statistic. Cancelled rows mostly drop out on
    -- their own (NULL delay, and aggregates skip nulls), but COUNT(*) still
    -- counts them, which is how a reliability percentage quietly goes wrong.
    schedule_relationship      INTEGER,

    -- The feed's own confidence measure, in seconds. Observed max 301.
    uncertainty                INTEGER,

    vehicle_id                 TEXT

    -- No foreign key to trips or stops. The observation feed and the schedule
    -- feed are produced by different pipelines, and an identifier appearing in
    -- one but not the other would reject rows mid-load rather than surfacing
    -- as something measurable. Coverage is better measured than enforced —
    -- see Section 7.
);


-- =============================================================================
-- SECTION 3 — data import
--
-- Pattern, used for every table:
--
--   1. a staging table with EVERY column of the source file, in file order,
--      all TEXT
--   2. COPY the raw file into it — no type can fail, because nothing is typed
--   3. INSERT ... SELECT into the real table, choosing columns and casting
--   4. drop the staging table
--
-- Why staging rather than loading straight into the real tables: COPY consumes
-- a file left to right and cannot skip columns, so a lean table needs the
-- intermediate step anyway. The payoff is that a malformed value fails at the
-- INSERT, where the offending row is still sitting in a queryable table, rather
-- than killing a COPY 12 million rows in with only a line number to go on.
--
-- Empty CSV fields arrive as empty strings, not NULL, and '' is not a valid
-- INTERVAL or INTEGER. NULL '' on the COPY is what prevents that.
--
-- Load order is forced by the foreign keys:
--     agency -> routes -> stops -> trips -> stop_observations
--
-- Paths are /data/..., which is the container's view of the host directory
-- mounted in compose.yaml. Nothing here depends on a particular host machine.
-- =============================================================================

-- ---------- agency ----------

CREATE TEMP TABLE stg_agency (
    agency_id        TEXT,
    agency_name      TEXT,
    agency_url       TEXT,
    agency_timezone  TEXT,
    agency_lang      TEXT,
    agency_phone     TEXT,
    agency_fare_url  TEXT,
    agency_email     TEXT,
    cemv_support     TEXT
);

COPY stg_agency FROM '/data/agency.txt'
    WITH (FORMAT csv, HEADER true, NULL '');

INSERT INTO agency (agency_id, agency_name)
SELECT agency_id, agency_name
  FROM stg_agency;


-- ---------- routes ----------

CREATE TEMP TABLE stg_routes (
    route_id             TEXT,
    agency_id            TEXT,
    route_short_name     TEXT,
    route_long_name      TEXT,
    route_desc           TEXT,
    route_type           TEXT,
    route_url            TEXT,
    route_color          TEXT,
    route_text_color     TEXT,
    route_sort_order     TEXT,
    continuous_pickup    TEXT,
    continuous_drop_off  TEXT,
    network_id           TEXT,
    cemv_support         TEXT,
    as_route             TEXT
);

COPY stg_routes FROM '/data/routes.txt'
    WITH (FORMAT csv, HEADER true, NULL '');

INSERT INTO routes (route_id, feed_version, agency_id,
                    route_short_name, route_long_name,
                    route_type, route_color)
SELECT route_id,
       '2026-08',
       agency_id,
       route_short_name,
       route_long_name,
       route_type::INTEGER,
       route_color
  FROM stg_routes;


-- ---------- stops ----------

CREATE TEMP TABLE stg_stops (
    stop_id              TEXT,
    stop_name            TEXT,
    stop_code            TEXT,
    stop_desc            TEXT,
    stop_lat             TEXT,
    stop_lon             TEXT,
    zone_id              TEXT,
    stop_url             TEXT,
    tts_stop_name        TEXT,
    platform_code        TEXT,
    location_type        TEXT,
    parent_station       TEXT,
    stop_timezone        TEXT,
    wheelchair_boarding  TEXT,
    level_id             TEXT,
    stop_access          TEXT
);

COPY stg_stops FROM '/data/stops.txt'
    WITH (FORMAT csv, HEADER true, NULL '');

INSERT INTO stops (stop_id, feed_version, stop_name,
                   stop_lat, stop_lon, location_type, parent_station)
SELECT stop_id,
       '2026-08',
       stop_name,
       stop_lat::NUMERIC,
       stop_lon::NUMERIC,
       location_type::INTEGER,
       parent_station
  FROM stg_stops;


-- ---------- trips ----------

CREATE TEMP TABLE stg_trips (
    route_id               TEXT,
    service_id             TEXT,
    trip_id                TEXT,
    trip_headsign          TEXT,
    trip_short_name        TEXT,
    direction_id           TEXT,
    block_id               TEXT,
    shape_id               TEXT,
    wheelchair_accessible  TEXT,
    bikes_allowed          TEXT,
    cars_allowed           TEXT,
    safe_duration_factor   TEXT,
    safe_duration_offset   TEXT
);

COPY stg_trips FROM '/data/trips.txt'
    WITH (FORMAT csv, HEADER true, NULL '');

INSERT INTO trips (trip_id, feed_version, route_id,
                   service_id, direction_id, trip_headsign)
SELECT trip_id,
       '2026-08',
       route_id,
       service_id,
       direction_id::INTEGER,
       trip_headsign
  FROM stg_trips;


-- ---------- stop_observations ----------
--
-- Not TEMP. At 25.8 M rows this is worth keeping on disk so that if the INSERT
-- fails on a cast, the raw rows are still queryable and the offending value can
-- be found. Dropped explicitly at the end of this block.

DROP TABLE IF EXISTS stg_stop_observations;

CREATE TABLE stg_stop_observations (
    trip_id                    TEXT,
    trip_start_time            TEXT,
    schedule_relationship      TEXT,
    service_date               TEXT,
    vehicle_id                 TEXT,
    stop_sequence              TEXT,
    observed_arrival_time      TEXT,
    observed_departure_time    TEXT,
    uncertainty                TEXT,
    dwell_time_secs            TEXT,
    scheduled_dwell_time_secs  TEXT,
    route_id                   TEXT,
    agency_id                  TEXT,
    direction_id               TEXT,
    from_stop_id               TEXT,
    to_stop_id                 TEXT,
    scheduled_arrival_time     TEXT,
    scheduled_departure_time   TEXT
);

COPY stg_stop_observations FROM '/data/stop_observations.txt'
    WITH (FORMAT csv, HEADER true, NULL '');

-- observation_id is GENERATED ALWAYS, so it is never named here.
-- service_date arrives as '20260831'; to_date is explicit about the format
-- rather than relying on the server's datestyle setting.
-- delay_secs is computed here rather than in a later UPDATE, so the 25.8 M
-- rows are written once instead of written and then rewritten.
INSERT INTO stop_observations (
    trip_id, feed_version, service_date, stop_sequence,
    observed_arrival_time, observed_departure_time, dwell_time_secs,
    trip_start_time, scheduled_arrival_time, scheduled_departure_time,
    scheduled_dwell_time_secs, delay_secs,
    route_id, agency_id, direction_id,
    from_stop_id, to_stop_id,
    schedule_relationship, uncertainty, vehicle_id
)
SELECT
    trip_id,
    '2026-08',
    to_date(service_date, 'YYYYMMDD'),
    stop_sequence::INTEGER,

    observed_arrival_time::INTERVAL,
    observed_departure_time::INTERVAL,
    dwell_time_secs::INTEGER,

    trip_start_time::INTERVAL,
    scheduled_arrival_time::INTERVAL,
    scheduled_departure_time::INTERVAL,
    scheduled_dwell_time_secs::INTEGER,

    EXTRACT(EPOCH FROM (observed_arrival_time::INTERVAL
                      - scheduled_arrival_time::INTERVAL))::INTEGER,

    route_id,
    agency_id,
    direction_id::INTEGER,

    from_stop_id,
    to_stop_id,

    schedule_relationship::INTEGER,
    uncertainty::INTEGER,
    vehicle_id
  FROM stg_stop_observations;

DROP TABLE stg_stop_observations;


-- =============================================================================
-- SECTION 4 — post-load derivations
-- =============================================================================

-- Build the point geometry from the coordinate columns. The cast is needed
-- because ST_MakePoint takes double precision and the columns are NUMERIC.
UPDATE stops
   SET geom = ST_SetSRID(
                ST_MakePoint(stop_lon::double precision,
                             stop_lat::double precision), 4326)
 WHERE stop_lat IS NOT NULL
   AND stop_lon IS NOT NULL;


-- =============================================================================
-- SECTION 5 — indexes
--
-- Deliberately created AFTER the import. Building an index first means
-- maintaining it on every one of 25.8 M inserts; building it after is a single
-- bulk sort and is dramatically faster.
-- =============================================================================

CREATE INDEX idx_obs_route     ON stop_observations (route_id, feed_version);
CREATE INDEX idx_obs_agency    ON stop_observations (agency_id);
CREATE INDEX idx_obs_date      ON stop_observations (service_date);
CREATE INDEX idx_obs_stop      ON stop_observations (to_stop_id, feed_version);
CREATE INDEX idx_obs_sched_rel ON stop_observations (schedule_relationship);
CREATE INDEX idx_stops_geom    ON stops USING GIST (geom);


-- =============================================================================
-- SECTION 6 — statistics
--
-- Without this the planner works from defaults until autovacuum catches up,
-- and the first dashboard queries can pick badly wrong plans on a table this
-- size.
-- =============================================================================

ANALYZE agency;
ANALYZE routes;
ANALYZE stops;
ANALYZE trips;
ANALYZE stop_observations;


-- =============================================================================
-- SECTION 7 — exploratory and validation queries
--
-- These do two jobs: they confirm the load is correct, and they document what
-- the team learned about the data. Several of them were run against the raw CSV
-- before the schema was designed, and the answers are why the schema looks the
-- way it does.
-- =============================================================================

-- PERCENTILE_CONT sorts every value within each group. At the shipped default
-- of 4 MB, sorting 25.8 M values spills to disk continuously. This is the
-- tuning the project plan anticipated, and it is the difference between a
-- dashboard panel that loads and one that times out.
SET work_mem = '256MB';


-- -----------------------------------------------------------------------------
-- Q1. Coverage and cancellation rate by agency.
--
-- The headline finding: BART reports ~69 K observations for an entire month
-- against Muni's ~9.8 M, despite running hundreds of trips a day across roughly
-- 50 stations. Its scheduled times are fine — it is simply barely reporting.
-- That is a coverage problem to disclose, not a bug in this load, and it means
-- the equity analysis runs on bus operators.
--
-- The cancellation column matters on its own. A late bus has a delay; a
-- cancelled bus has none and vanishes from the data entirely, even though from
-- a rider's perspective it is the worse outcome.
-- -----------------------------------------------------------------------------

SELECT o.agency_id,
       a.agency_name,
       COUNT(*)                                             AS observations,
       COUNT(*) FILTER (WHERE o.schedule_relationship = 3)  AS cancelled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.schedule_relationship = 3)
             / COUNT(*), 2)                                 AS pct_cancelled
  FROM stop_observations o
  LEFT JOIN agency a ON a.agency_id = o.agency_id
 GROUP BY 1, 2
 ORDER BY observations DESC;


-- -----------------------------------------------------------------------------
-- Q2. Schedule-echo detector.
--
-- observed_arrival_time is not a stopwatch reading — it is inferred from each
-- agency's own realtime prediction feed. When an agency loses vehicle tracking,
-- some prediction engines fall back to echoing the timetable, which appears in
-- the data as PERFECT on-time performance rather than as missing data.
--
-- A real vehicle essentially never arrives at its exact scheduled second, so a
-- high share here means that agency's numbers cannot be trusted. This has to be
-- checked before any cross-agency comparison: if operators serving lower-income
-- areas have worse telemetry, their delays are understated and the equity
-- finding shrinks for reasons that have nothing to do with service quality.
-- -----------------------------------------------------------------------------

SELECT o.agency_id,
       COUNT(*)                                             AS scheduled_obs,
       ROUND(100.0 * COUNT(*) FILTER (
             WHERE o.observed_arrival_time = o.scheduled_arrival_time)
             / COUNT(*), 3)                                 AS pct_exact_second_match
  FROM stop_observations o
 WHERE o.schedule_relationship = 0
   AND o.observed_arrival_time  IS NOT NULL
   AND o.scheduled_arrival_time IS NOT NULL
 GROUP BY 1
HAVING COUNT(*) >= 10000
 ORDER BY pct_exact_second_match DESC;


-- -----------------------------------------------------------------------------
-- Q3. Why the time columns are INTERVAL and not TIME.
--
-- GTFS represents after-midnight service with hours past 24:00:00 — a 12:30 am
-- arrival on an evening trip is 24:30:00. Postgres TIME rejects those values
-- outright, so a TIME column would have failed partway through the 25.8 M-row
-- load with no obvious cause.
--
-- These rows are overnight service, which is when headways are worst and riders
-- without a car are most stranded. Filtering them out as "bad data" would
-- quietly shrink the equity finding.
-- -----------------------------------------------------------------------------

SELECT COUNT(*) FILTER (WHERE observed_arrival_time  >= INTERVAL '24:00:00')
                                                            AS observed_past_24h,
       COUNT(*) FILTER (WHERE scheduled_arrival_time >= INTERVAL '24:00:00')
                                                            AS scheduled_past_24h,
       MAX(observed_arrival_time)                           AS latest_observed_time
  FROM stop_observations;


-- -----------------------------------------------------------------------------
-- Q4. Is the natural key actually unique?
--
-- stop_observations uses a surrogate key because this could not be verified
-- before loading. If this returns 0, add:
--
--   ALTER TABLE stop_observations
--     ADD CONSTRAINT uq_observation_natural_key
--     UNIQUE (trip_id, service_date, stop_sequence, feed_version);
-- -----------------------------------------------------------------------------

SELECT COUNT(*) AS duplicate_natural_keys
  FROM (SELECT trip_id, service_date, stop_sequence, feed_version
          FROM stop_observations
         GROUP BY 1, 2, 3, 4
        HAVING COUNT(*) > 1) d;


-- -----------------------------------------------------------------------------
-- Q5. Join coverage between the observation feed and the schedule feed.
--
-- There is deliberately no foreign key from stop_observations to stops. The two
-- feeds come from different pipelines, so an id present in one but not the
-- other would reject rows mid-load rather than surfacing as something
-- measurable. Coverage is better measured than enforced — and this number is
-- what the stop-to-census-tract join will inherit.
-- -----------------------------------------------------------------------------

SELECT COUNT(*)                                             AS observations,
       COUNT(s.stop_id)                                     AS matched_to_stops,
       ROUND(100.0 * COUNT(s.stop_id) / COUNT(*), 2)        AS pct_matched
  FROM stop_observations o
  LEFT JOIN stops s
    ON s.stop_id      = o.to_stop_id
   AND s.feed_version = o.feed_version;


-- -----------------------------------------------------------------------------
-- Q6. The archive's own dwell column is wrong for some rows.
--
-- dwell_time_secs reaches -86,382 seconds, which is -23h 59m 42s: a midnight
-- wraparound, where arrival near 23:59 and departure just after midnight were
-- subtracted without accounting for the date rolling over. The interval columns
-- handle midnight correctly, so dwell should be recomputed from them rather
-- than trusted as provided. This matters because excess dwell is a candidate
-- proxy for crowding, which the feed does not measure directly.
-- -----------------------------------------------------------------------------

SELECT COUNT(*) FILTER (WHERE dwell_time_secs < 0)          AS negative_dwell_rows,
       MIN(dwell_time_secs)                                 AS min_dwell_secs,
       COUNT(*) FILTER (
         WHERE dwell_time_secs <> EXTRACT(EPOCH FROM
               (observed_departure_time - observed_arrival_time))::INTEGER)
                                                            AS disagrees_with_recomputed
  FROM stop_observations
 WHERE observed_arrival_time   IS NOT NULL
   AND observed_departure_time IS NOT NULL
   AND dwell_time_secs         IS NOT NULL;


-- -----------------------------------------------------------------------------
-- Q7. Worst bus routes by 90th-percentile delay.
--
-- The project's core question in one query: two joins, aggregation, a
-- percentile, and a volume floor.
--
-- Restricted to route_type = 3 (bus) deliberately. Run without that filter and
-- the leaderboard fills with cable cars, whose terminal turnaround queuing
-- registers as enormous delay but is not lateness in any sense a rider would
-- recognize, and with small intercity operators whose long layovers do the
-- same. The naive version of this query measures the method, not the service.
--
-- Reported in minutes, because 8,167 seconds is harder to be skeptical about
-- than 136 minutes.
-- -----------------------------------------------------------------------------

SELECT r.route_short_name,
       a.agency_name,
       COUNT(*)                                             AS observations,
       ROUND(AVG(o.delay_secs) / 60.0, 1)                   AS mean_delay_min,
       ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY o.delay_secs))::NUMERIC
             / 60.0, 1)                                     AS p90_delay_min
  FROM stop_observations o
  JOIN routes r ON r.route_id     = o.route_id
               AND r.feed_version = o.feed_version
  JOIN agency a ON a.agency_id    = r.agency_id
 WHERE o.schedule_relationship = 0
   AND o.delay_secs IS NOT NULL
   AND r.route_type = 3
 GROUP BY 1, 2
HAVING COUNT(*) > 20000
 ORDER BY p90_delay_min DESC
 LIMIT 15;
