-- =============================================================================
-- dashboard_queries.sql
-- DSAI 691 — Relational Databases — Group Project, Task 3
-- Reliability dashboard panels 1–5, equity panels 6–8
--
-- The SQL behind each panel. Each query is pasted into Metabase's SQL editor
-- and saved as a question in "Our analytics". The panel queries are SELECTs and
-- change nothing, so the file runs end to end as a script too:
--     docker exec -i postgres psql -U transit -d transit < dashboard_queries.sql
--
-- The appendix at the end reproduces the view and materialized-view
-- definitions the panels read (create_and_load.sql Section 8), so the full SQL
-- behind the dashboard is in this one file. It is for reference: running it
-- rebuilds the views, which takes several minutes.
--
-- Panels 1–8 read views built by create_and_load.sql Section 8, so that
-- section must have been run first, or these fail with
-- "relation mv_... does not exist". Reading the views is also what makes each
-- panel return in under a second instead of scanning 25.8 M rows. Panels 6–8
-- also need census_tracts.sql and stop_tract_mapping.sql loaded. Panel 9, the
-- data-quality audit, is the exception that reads stop_observations directly —
-- see its note.
--
-- Dashboard filters: to make a panel respond to a Metabase dashboard filter,
-- add a variable to the saved question in Metabase, e.g.
--     AND agency_id = {{agency}}
-- If a query is changed in Metabase, change it here too.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Panel 1. Worst bus routes by p90 delay, weekdays.
-- Visualization: table, or a bar chart on p90_delay_min.
--
-- route_type = 3 for the reason in create_and_load.sql Q7: cable cars and long-
-- layover intercity routes otherwise top the list for reasons that are not
-- lateness. The volume floor keeps a route with a handful of bad trips off it.
-- -----------------------------------------------------------------------------

SELECT agency_id || ' ' || route_label                          AS route,
       agency_name,
       observations,
       median_delay_min,
       p90_delay_min,
       pct_on_time,
       pct_cancelled
  FROM mv_route_summary
 WHERE day_type = 'weekday'
   AND route_type = 3
   AND observations >= 20000
 ORDER BY p90_delay_min DESC
 LIMIT 15;


-- -----------------------------------------------------------------------------
-- Panel 2. Route x hour heatmap — p90 delay by scheduled hour, weekdays, for
-- the 15 routes on the panel 1 leaderboard.
-- Visualization: Table, with conditional formatting as a color range across
-- the hour columns. Metabase has no heatmap chart type, and its Pivot Table
-- only works on query-builder questions, not SQL — so the pivot is done here,
-- one column per scheduled hour (24-hour clock), and the table does the rest.
--
-- Rows are in leaderboard order, worst first. A blank cell means the route
-- does not run that hour, or ran too few trips to score: the per-cell floor
-- stops a single late-night trip from painting a cell red.
--
-- Cells with a p90 over 120 minutes are also blanked. A handful of such cells
-- (SO 20 at 06:00 showed 609 min with a 3.9 min median) come from a small
-- cluster of arrivals 10+ hours "late": vehicles matched to the wrong trip in
-- the real-time feed, not buses that late. They are a data-quality artifact,
-- the kind panel 9 audits, so they are left out rather than colored.
-- -----------------------------------------------------------------------------

WITH worst AS (
    SELECT agency_id, route_id, feed_version, route_label, p90_delay_min
      FROM mv_route_summary
     WHERE day_type = 'weekday'
       AND route_type = 3
       AND observations >= 20000
     ORDER BY p90_delay_min DESC
     LIMIT 15
),
cells AS (
    SELECT h.route_id, h.feed_version, h.sched_hour, h.p90_delay_min
      FROM mv_route_hour h
      JOIN worst w ON w.route_id     = h.route_id
                  AND w.feed_version = h.feed_version
     WHERE h.day_type = 'weekday'
       AND h.observations >= 200
       AND h.p90_delay_min <= 120
)
SELECT w.agency_id || ' ' || w.route_label                          AS route,
       w.p90_delay_min                                              AS "all day",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  0)        AS "00",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  1)        AS "01",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  2)        AS "02",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  3)        AS "03",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  4)        AS "04",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  5)        AS "05",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  6)        AS "06",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  7)        AS "07",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  8)        AS "08",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour =  9)        AS "09",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 10)        AS "10",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 11)        AS "11",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 12)        AS "12",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 13)        AS "13",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 14)        AS "14",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 15)        AS "15",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 16)        AS "16",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 17)        AS "17",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 18)        AS "18",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 19)        AS "19",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 20)        AS "20",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 21)        AS "21",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 22)        AS "22",
       MAX(c.p90_delay_min) FILTER (WHERE c.sched_hour = 23)        AS "23"
  FROM worst w
  LEFT JOIN cells c ON c.route_id     = w.route_id
                   AND c.feed_version = w.feed_version
 GROUP BY w.agency_id, w.route_label, w.p90_delay_min
 ORDER BY w.p90_delay_min DESC;


-- -----------------------------------------------------------------------------
-- Panel 3. Delay over time — daily p90 delay for the five largest agencies.
-- Visualization: line chart, x = service_date, y = p90_delay_min,
-- series = agency_name.
--
-- Weekends are left in, since a weekly rhythm is part of what the chart shows.
-- -----------------------------------------------------------------------------

SELECT service_date,
       agency_name,
       median_delay_min,
       p90_delay_min,
       pct_on_time
  FROM mv_daily_agency
 WHERE agency_id IN (SELECT agency_id
                       FROM mv_daily_agency
                      GROUP BY agency_id
                      ORDER BY SUM(observations) DESC
                      LIMIT 5)
 ORDER BY service_date, agency_name;


-- -----------------------------------------------------------------------------
-- Panel 4. Headway reliability — the bus routes that bunch most, weekdays,
-- frequent service only. The LAG window function behind it is in mv_headway.
-- Visualization: stacked bar chart, pct_bunched and pct_gapped by route.
--
-- Percentages are rebuilt from the stored counts, which is why mv_headway
-- keeps counts rather than per-hour rates.
--
-- LIMIT 10 because Metabase's row chart folds anything past ten rows into an
-- "Other" bar that sums the percentages, which is meaningless.
-- -----------------------------------------------------------------------------

SELECT s.agency_id || ' ' || s.route_label                          AS route,
       SUM(h.headways)                                              AS headways,
       ROUND(100.0 * SUM(h.bunched) / SUM(h.headways), 1)           AS pct_bunched,
       ROUND(100.0 * SUM(h.gapped)  / SUM(h.headways), 1)           AS pct_gapped
  FROM mv_headway h
  JOIN mv_route_summary s ON s.route_id     = h.route_id
                         AND s.feed_version = h.feed_version
                         AND s.day_type     = h.day_type
 WHERE h.day_type = 'weekday'
   AND s.route_type = 3
 GROUP BY 1
HAVING SUM(h.headways) >= 5000
 ORDER BY pct_bunched DESC
 LIMIT 10;


-- -----------------------------------------------------------------------------
-- Panel 5. Stop map — weekday median delay at every stop.
-- Visualization: map, using latitude / longitude. delay_band is there to
-- color or filter by, since a pin map colors every pin the same.
--
-- The floor drops stops with too few weekday observations for a median to mean
-- anything.
-- -----------------------------------------------------------------------------

SELECT stop_name,
       latitude,
       longitude,
       agency_id,
       observations,
       median_delay_min,
       p90_delay_min,
       delay_band
  FROM mv_stop_delay
 WHERE day_type = 'weekday'
   AND observations >= 100
   AND median_delay_min >= 4;

-- =============================================================================

-- -----------------------------------------------------------------------------
-- Panel 6. Income vs. delay — weekday delay by band of tract income.
-- Visualization: bar chart (or line), x = income_band, y = avg_p90_delay_min
-- and avg_median_delay_min.
--
-- $25k bands of tract median household income. The last band is the ACS
-- top-code, 250,000+. Tracts with fewer than 2,000 weekday observations are
-- dropped. Delay is weighted by observations across every stop in the band,
-- so a band's number is the rider's-eye average, not an average of tract
-- averages.
-- -----------------------------------------------------------------------------

WITH bus_agency AS (
    SELECT agency_id
      FROM mv_route_summary
     WHERE agency_id NOT IN ('')        -- panel 9 exclusions go here
     GROUP BY agency_id
    HAVING BOOL_OR(route_type = 3)
),
tract AS (
    SELECT c.geoid,
           LEAST(FLOOR(c.median_household_income / 25000) * 25000, 250000)::INTEGER
                                                                    AS band_start,
           SUM(d.p90_delay_min    * d.observations)                 AS p90_weighted,
           SUM(d.median_delay_min * d.observations)                 AS median_weighted,
           SUM(d.observations)                                      AS observations
      FROM mv_stop_delay d
      JOIN bus_agency b         ON b.agency_id = d.agency_id
      JOIN stop_tract_mapping m ON m.stop_id   = d.stop_id
      JOIN census_tracts c      ON c.geoid     = m.geoid
     WHERE d.day_type = 'weekday'
       AND c.median_household_income IS NOT NULL
       AND c.total_households > 0
     GROUP BY c.geoid, c.median_household_income
    HAVING SUM(d.observations) >= 2000
)
SELECT CASE WHEN band_start = 250000 THEN '$250k+'
            ELSE '$' || (band_start / 1000) || '–'
                 || ((band_start + 25000) / 1000) || 'k' END        AS income_band,
       COUNT(*)                                                     AS tracts,
       SUM(observations)                                            AS observations,
       ROUND(SUM(p90_weighted)    / SUM(observations), 1)           AS avg_p90_delay_min,
       ROUND(SUM(median_weighted) / SUM(observations), 1)           AS avg_median_delay_min
  FROM tract
 GROUP BY band_start
 ORDER BY band_start;


-- -----------------------------------------------------------------------------
-- Panel 7. Delay by vehicle-access quintile, weekdays.
-- Visualization: bar chart, x = quintile_label, y = avg_median_delay_min and
-- avg_p90_delay_min side by side.
--
-- Quintiles of zero_vehicle_pct, the share of households with no car.
-- Q1 = the fewest car-free households, Q5 = the most car-free, i.e. least
-- able to fall back on a car. The question is whether bars rise toward Q5.
-- -----------------------------------------------------------------------------

WITH bus_agency AS (
    SELECT agency_id
      FROM mv_route_summary
     WHERE agency_id NOT IN ('')
     GROUP BY agency_id
    HAVING BOOL_OR(route_type = 3)
),
q AS (
    SELECT geoid,
           zero_vehicle_pct,
           NTILE(5) OVER (ORDER BY zero_vehicle_pct, geoid)         AS quintile
      FROM census_tracts
     WHERE total_households > 0
       AND zero_vehicle_pct IS NOT NULL
)
SELECT 'Q' || q.quintile
       || CASE q.quintile WHEN 1 THEN ' (most car access)'
                          WHEN 5 THEN ' (least car access)'
                          ELSE '' END                               AS quintile_label,
       ROUND(MIN(q.zero_vehicle_pct), 1) || '–'
           || ROUND(MAX(q.zero_vehicle_pct), 1) || '%'              AS zero_vehicle_range,
       COUNT(DISTINCT q.geoid)                                      AS tracts,
       SUM(d.observations)                                          AS observations,
       ROUND(SUM(d.median_delay_min * d.observations)
             / SUM(d.observations), 1)                              AS avg_median_delay_min,
       ROUND(SUM(d.p90_delay_min * d.observations)
             / SUM(d.observations), 1)                              AS avg_p90_delay_min,
       ROUND(SUM(d.pct_on_time * d.observations)
             / SUM(d.observations), 1)                              AS pct_on_time
  FROM mv_stop_delay d
  JOIN bus_agency b ON b.agency_id = d.agency_id
  JOIN stop_tract_mapping m ON m.stop_id   = d.stop_id
  JOIN q ON q.geoid     = m.geoid
 WHERE d.day_type = 'weekday'
 GROUP BY q.quintile
 ORDER BY q.quintile;


-- -----------------------------------------------------------------------------
-- Panel 8. Cancellation rate by income quintile, weekdays.
-- Visualization: bar chart, x = quintile_label, y = pct_cancelled.
--
-- Replaces the planned crowding-by-income panel: the 511 feed carries no
-- occupancy data. A late bus has a delay; a cancelled bus has none and
-- vanishes from every delay statistic, so this is the reliability failure
-- panels 6 and 7 cannot see — and from a rider's side it is the worse one.
--
-- Same construction as panel 7: quintiles of tracts (here by median household
-- income), bus agencies only, counts summed before dividing so each quintile's
-- rate is the share of its scheduled stops that were cancelled.
-- Reads mv_stop_cancellations from create_and_load.sql Section 8.
-- -----------------------------------------------------------------------------

WITH bus_agency AS (
    SELECT agency_id
      FROM mv_route_summary
     GROUP BY agency_id
    HAVING BOOL_OR(route_type = 3)
),
q AS (
    SELECT geoid,
           median_household_income,
           NTILE(5) OVER (ORDER BY median_household_income, geoid)  AS quintile
      FROM census_tracts
     WHERE total_households > 0
       AND median_household_income IS NOT NULL
)
SELECT 'Q' || q.quintile
       || CASE q.quintile WHEN 1 THEN ' (lowest income)'
                          WHEN 5 THEN ' (highest income)'
                          ELSE '' END                               AS quintile_label,
       '$' || ROUND(MIN(q.median_household_income) / 1000) || 'k–$'
           || ROUND(MAX(q.median_household_income) / 1000) || 'k'   AS income_range,
       COUNT(DISTINCT q.geoid)                                      AS tracts,
       SUM(x.scheduled)                                             AS scheduled_stops,
       SUM(x.cancelled)                                             AS cancelled_stops,
       ROUND(100.0 * SUM(x.cancelled) / NULLIF(SUM(x.scheduled), 0), 2)
                                                                    AS pct_cancelled
  FROM mv_stop_cancellations x
  JOIN bus_agency b         ON b.agency_id = x.agency_id
  JOIN stop_tract_mapping m ON m.stop_id   = x.stop_id
  JOIN q                    ON q.geoid     = m.geoid
 WHERE x.day_type = 'weekday'
 GROUP BY q.quintile
 ORDER BY q.quintile;


-- -----------------------------------------------------------------------------
-- Panel 9. Data-quality audit — two cards.
--
-- observed_arrival_time is inferred from each agency's realtime prediction
-- feed, not measured, so feed quality varies by agency. This panel decides
-- which agencies the other panels should trust; any agency it rules out goes
-- in the bus_agency exclusion list in panels 6–8.
--
-- Both cards read stop_observations directly rather than a view. They scan
-- all 25.8 M rows and take tens of seconds, which is acceptable for an audit
-- opened occasionally but is why they are not built the way panels 1–8 are.
-- -----------------------------------------------------------------------------

-- Panel 9a. Data check: arrivals logged exactly on schedule, by agency.
-- (The schedule-echo detector.)
-- Visualization: row chart, pct_exact_second_match by agency.
-- A real vehicle essentially never arrives at its exact scheduled second.
-- When an agency loses vehicle tracking, some prediction engines fall back to
-- echoing the timetable, which looks like perfect on-time performance rather
-- than missing data. A high share here means that agency's delays are
-- understated — and if it serves lower-income areas, so is the equity gap.

SELECT o.agency_id,
       a.agency_name,
       COUNT(*)                                             AS scheduled_obs,
       ROUND(100.0 * COUNT(*) FILTER (
             WHERE o.observed_arrival_time = o.scheduled_arrival_time)
             / COUNT(*), 3)                                 AS pct_exact_second_match
  FROM stop_observations o
  LEFT JOIN agency a ON a.agency_id = o.agency_id
 WHERE o.schedule_relationship = 0
   AND o.observed_arrival_time  IS NOT NULL
   AND o.scheduled_arrival_time IS NOT NULL
 GROUP BY o.agency_id, a.agency_name
HAVING COUNT(*) >= 10000
 ORDER BY pct_exact_second_match DESC;


-- Panel 9b. Data check: observations and cancellations, by agency.
-- Visualization: table.
-- The coverage finding: BART reports ~69 K observations for the month against
-- Muni's ~9.8 M despite running hundreds of trips a day — it is barely
-- reporting, which is why the equity analysis runs on bus operators.

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


-- =============================================================================
-- APPENDIX. View definitions the panels read.
-- Copied verbatim from create_and_load.sql Section 8, which is the source of
-- truth: if a view changes there, re-copy it here.
-- =============================================================================

-- SECTION 8 — dashboard layer: metric definitions and pre-aggregated rollups
--
-- Reliability panels 1–5, plus the cancellation rollup behind equity panel 8.
--
-- Metabase runs every panel query live, and a percentile over 25.8 M rows takes
-- far too long for a dashboard. So the expensive work happens here, once, at
-- build time, and the panel queries in dashboard_queries.sql read small views.
--
-- A percentile cannot be re-aggregated: a route's p90 is not any combination of
-- the p90s of its hours. So each view is built at exactly the grain its panel
-- displays, and raw counts are stored alongside so that percentages, unlike
-- percentiles, CAN be rolled up further.
--
-- This section can be run on its own against an already-loaded database,
-- without repeating the load:
--
--     sed -n '/^-- SECTION 8/,$p' create_and_load.sql \
--       | docker exec -i postgres psql -U transit -d transit
--
-- Metric definitions. PROPOSED — to be confirmed by the group. Every one of
-- them lives in obs_dashboard below, so changing a definition means changing
-- it in one place and re-running this section.
--
--   scored       schedule_relationship = 0 and delay_secs present. The only
--                rows any delay statistic is computed from.
--   on time      between 1 minute early and 4 minutes late (-60 to +240 s),
--                SFMTA's on-time standard.
--   statistics   median and p90, both. Rankings use p90: riders plan around
--                the bad days, not the typical one.
--   hour         clock hour of the SCHEDULED arrival, 0–23. Feed times past
--                24:00:00 are folded back by building a real timestamp first.
--   day type     weekday / weekend, from service_date. A 00:30 trip on Friday
--                night's service belongs to Friday, which is how agencies
--                schedule it and how the feed records it.
--   period       weekday AM peak 06–09, midday 09–16, PM peak 16–19,
--                evening 19–24, overnight 00–06. Weekends are their own period.
--   unobserved   cancelled stops (schedule_relationship = 3) and scheduled
--                stops with no observed arrival are counted and reported as
--                their own rates, never folded into delay.
--   bunching     a bus arriving less than half the scheduled headway behind
--                the one ahead; a gap is more than 1.5x the scheduled headway.
--                Scored only on frequent service (scheduled headway 1–15 min):
--                on a 30-minute route riders time their trip to the timetable,
--                so schedule adherence matters there, not headway.
--   agencies     not filtered here. Which agencies to trust is the quality
--                audit's call (panel 9); panels filter on agency_id.
-- =============================================================================

-- The SET in Section 7 lasts only for the psql session that ran this script.
-- Metabase opens its own connections and would still get the 4 MB default.
-- ALTER DATABASE makes 256 MB the default for every new connection; already-
-- open connections keep the old value until they reconnect.
ALTER DATABASE transit SET work_mem = '256MB';
SET work_mem = '256MB';

DROP MATERIALIZED VIEW IF EXISTS mv_stop_delay;
DROP MATERIALIZED VIEW IF EXISTS mv_headway;
DROP MATERIALIZED VIEW IF EXISTS mv_daily_agency;
DROP MATERIALIZED VIEW IF EXISTS mv_route_hour;
DROP MATERIALIZED VIEW IF EXISTS mv_route_summary;
DROP MATERIALIZED VIEW IF EXISTS mv_stop_cancellations;
DROP VIEW              IF EXISTS obs_dashboard;


-- -----------------------------------------------------------------------------
-- obs_dashboard — every observation, with the metric definitions applied.
--
-- A plain view, not materialized: it costs nothing to store, and every rollup
-- below reads through it, so the definitions exist exactly once.
--
-- No row filter. The rollups need cancelled and unobserved rows too, to report
-- them as rates, so they select scored rows with FILTER (WHERE scored) instead.
-- -----------------------------------------------------------------------------

CREATE VIEW obs_dashboard AS
SELECT o.agency_id,
       o.route_id,
       o.feed_version,
       o.direction_id,
       o.to_stop_id,
       o.service_date,
       o.schedule_relationship,
       o.scheduled_arrival_time,
       o.observed_arrival_time,
       o.delay_secs,

       (o.schedule_relationship = 0 AND o.delay_secs IS NOT NULL)  AS scored,
       (o.delay_secs BETWEEN -60 AND 240)                          AS on_time,

       -- date + interval is a timestamp, so 24:30:00 on Aug 7 becomes
       -- 00:30 on Aug 8 and the hour comes out as 0, not 24.
       EXTRACT(HOUR FROM o.service_date + o.scheduled_arrival_time)::INTEGER
                                                                   AS sched_hour,

       CASE WHEN EXTRACT(ISODOW FROM o.service_date) IN (6, 7)
            THEN 'weekend' ELSE 'weekday' END                      AS day_type,

       CASE WHEN EXTRACT(ISODOW FROM o.service_date) IN (6, 7)  THEN 'weekend'
            WHEN EXTRACT(HOUR FROM o.service_date + o.scheduled_arrival_time)
                 BETWEEN 6 AND 8                                 THEN 'AM peak'
            WHEN EXTRACT(HOUR FROM o.service_date + o.scheduled_arrival_time)
                 BETWEEN 9 AND 15                                THEN 'midday'
            WHEN EXTRACT(HOUR FROM o.service_date + o.scheduled_arrival_time)
                 BETWEEN 16 AND 18                               THEN 'PM peak'
            WHEN EXTRACT(HOUR FROM o.service_date + o.scheduled_arrival_time)
                 BETWEEN 19 AND 23                               THEN 'evening'
            ELSE 'overnight' END                                   AS period
  FROM stop_observations o;


-- -----------------------------------------------------------------------------
-- mv_route_summary — one row per route x day type.
-- Feeds panel 1 (leaderboard), and supplies route labels to panels 2 and 4.
--
-- Cancellations sit next to delay deliberately. A route can look reliable by
-- delay alone because its worst trips never ran, and the delay columns cannot
-- show that.
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW mv_route_summary AS
SELECT d.agency_id,
       a.agency_name,
       d.route_id,
       d.feed_version,
       COALESCE(r.route_short_name, r.route_long_name, d.route_id)  AS route_label,
       r.route_type,
       d.day_type,

       COUNT(*) FILTER (WHERE d.scored)                             AS observations,
       COUNT(*) FILTER (WHERE d.schedule_relationship = 3)          AS cancelled,
       COUNT(*) FILTER (WHERE d.schedule_relationship = 0
                          AND d.delay_secs IS NULL)                 AS unobserved,

       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d.delay_secs)
              FILTER (WHERE d.scored))::NUMERIC / 60.0, 1)          AS median_delay_min,
       ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY d.delay_secs)
              FILTER (WHERE d.scored))::NUMERIC / 60.0, 1)          AS p90_delay_min,
       ROUND(100.0 * COUNT(*) FILTER (WHERE d.scored AND d.on_time)
             / NULLIF(COUNT(*) FILTER (WHERE d.scored), 0), 1)      AS pct_on_time,
       ROUND(100.0 * COUNT(*) FILTER (WHERE d.schedule_relationship = 3)
             / NULLIF(COUNT(*) FILTER (
                      WHERE d.schedule_relationship IN (0, 3)), 0), 1)
                                                                    AS pct_cancelled
  FROM obs_dashboard d
  LEFT JOIN routes r ON r.route_id     = d.route_id
                    AND r.feed_version = d.feed_version
  LEFT JOIN agency a ON a.agency_id    = d.agency_id
 GROUP BY 1, 2, 3, 4, 5, 6, 7;


-- -----------------------------------------------------------------------------
-- mv_route_hour — one row per route x day type x scheduled hour.
-- Feeds panel 2 (route x hour heatmap).
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW mv_route_hour AS
SELECT agency_id,
       route_id,
       feed_version,
       day_type,
       sched_hour,
       period,
       COUNT(*)                                                     AS observations,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delay_secs))::NUMERIC
             / 60.0, 1)                                             AS median_delay_min,
       ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY delay_secs))::NUMERIC
             / 60.0, 1)                                             AS p90_delay_min,
       ROUND(100.0 * COUNT(*) FILTER (WHERE on_time) / COUNT(*), 1) AS pct_on_time
  FROM obs_dashboard
 WHERE scored
 GROUP BY 1, 2, 3, 4, 5, 6;


-- -----------------------------------------------------------------------------
-- mv_daily_agency — one row per agency x service date.
-- Feeds panel 3 (delay over time).
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW mv_daily_agency AS
SELECT d.agency_id,
       a.agency_name,
       d.service_date,
       d.day_type,
       COUNT(*) FILTER (WHERE d.scored)                             AS observations,
       COUNT(*) FILTER (WHERE d.schedule_relationship = 3)          AS cancelled,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d.delay_secs)
              FILTER (WHERE d.scored))::NUMERIC / 60.0, 1)          AS median_delay_min,
       ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY d.delay_secs)
              FILTER (WHERE d.scored))::NUMERIC / 60.0, 1)          AS p90_delay_min,
       ROUND(100.0 * COUNT(*) FILTER (WHERE d.scored AND d.on_time)
             / NULLIF(COUNT(*) FILTER (WHERE d.scored), 0), 1)      AS pct_on_time
  FROM obs_dashboard d
  LEFT JOIN agency a ON a.agency_id = d.agency_id
 GROUP BY 1, 2, 3, 4;


-- -----------------------------------------------------------------------------
-- mv_headway — headway reliability and bunching, one row per
-- route x day type x scheduled hour.
-- Feeds panel 4.
--
-- LAG pairs each arrival with the trip scheduled immediately before it at the
-- same stop, in the same direction, on the same service day. Pairing in
-- SCHEDULED order rather than observed order is what makes overtaking visible:
-- when bus B passes bus A, B's actual headway behind A goes negative, which
-- counts as bunched. In observed order the two would simply swap places and
-- both look normal.
--
-- Known undercount: a cancelled or unobserved trip is absent, so the trips on
-- either side of it pair with each other at roughly double the scheduled
-- headway. Usually that lands above the 15-minute cutoff and drops out, so
-- the gaps riders feel most are partly missing here — they show up instead as
-- pct_cancelled and unobserved in mv_route_summary.
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW mv_headway AS
WITH paired AS (
    SELECT agency_id,
           route_id,
           feed_version,
           day_type,
           sched_hour,
           period,
           EXTRACT(EPOCH FROM scheduled_arrival_time
                   - LAG(scheduled_arrival_time) OVER w)            AS sched_headway_secs,
           EXTRACT(EPOCH FROM observed_arrival_time
                   - LAG(observed_arrival_time)  OVER w)            AS actual_headway_secs
      FROM obs_dashboard
     WHERE scored
       AND direction_id IS NOT NULL
    WINDOW w AS (PARTITION BY route_id, feed_version, direction_id,
                              to_stop_id, service_date
                     ORDER BY scheduled_arrival_time)
)
SELECT agency_id,
       route_id,
       feed_version,
       day_type,
       sched_hour,
       period,
       COUNT(*)                                                     AS headways,
       COUNT(*) FILTER (WHERE actual_headway_secs
                              < 0.5 * sched_headway_secs)           AS bunched,
       COUNT(*) FILTER (WHERE actual_headway_secs
                              > 1.5 * sched_headway_secs)           AS gapped,
       ROUND(AVG(sched_headway_secs)::NUMERIC / 60.0, 1)            AS avg_sched_headway_min,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (
              ORDER BY actual_headway_secs / sched_headway_secs))::NUMERIC, 2)
                                                                    AS median_headway_ratio
  FROM paired
 -- frequent service only; the lower bound also excludes two trips scheduled
 -- at the same second, which would divide by zero above
 WHERE sched_headway_secs BETWEEN 60 AND 900
 GROUP BY 1, 2, 3, 4, 5, 6;


-- -----------------------------------------------------------------------------
-- mv_stop_delay — one row per stop x agency x day type, with coordinates.
-- Feeds panel 5 (stop map), and is the stop-level input for the census-tract
-- join behind the equity panels.
--
-- Aggregated before joining to stops, so the join touches ~20 K rows rather
-- than 25.8 M. Inner join: a stop with no coordinates cannot go on a map, and
-- how many observations that loses is Section 7 Q5's number.
-- Restricted to location_type 0 (or blank, which means 0) so the map does not
-- put pins on station entrances.
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW mv_stop_delay AS
WITH by_stop AS (
    SELECT agency_id,
           to_stop_id,
           feed_version,
           day_type,
           COUNT(*)                                                 AS observations,
           ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delay_secs))::NUMERIC
                 / 60.0, 1)                                         AS median_delay_min,
           ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY delay_secs))::NUMERIC
                 / 60.0, 1)                                         AS p90_delay_min,
           ROUND(100.0 * COUNT(*) FILTER (WHERE on_time) / COUNT(*), 1)
                                                                    AS pct_on_time
      FROM obs_dashboard
     WHERE scored
     GROUP BY 1, 2, 3, 4
)
SELECT b.agency_id,
       b.to_stop_id                                                 AS stop_id,
       b.feed_version,
       s.stop_name,
       -- named latitude / longitude so Metabase recognizes them for its map
       s.stop_lat::DOUBLE PRECISION                                 AS latitude,
       s.stop_lon::DOUBLE PRECISION                                 AS longitude,
       b.day_type,
       b.observations,
       b.median_delay_min,
       b.p90_delay_min,
       b.pct_on_time,
       -- numbered so the bands sort in order in a legend
       CASE WHEN b.median_delay_min <  1  THEN '1. early or under 1 min'
            WHEN b.median_delay_min <  4  THEN '2. 1–4 min'
            WHEN b.median_delay_min < 10  THEN '3. 4–10 min'
            ELSE                               '4. 10+ min' END     AS delay_band
  FROM by_stop b
  JOIN stops s ON s.stop_id      = b.to_stop_id
              AND s.feed_version = b.feed_version
 WHERE COALESCE(s.location_type, 0) = 0
   AND s.stop_lat IS NOT NULL
   AND s.stop_lon IS NOT NULL;


-- -----------------------------------------------------------------------------
-- mv_stop_cancellations — scheduled and cancelled stops, one row per
-- stop x agency x day type.
-- Feeds panel 8 (cancellation rate by tract income).
--
-- Without it, panel 8 has to scan every observation through obs_dashboard on
-- each dashboard load, which took well over a minute in testing. Counts, not
-- rates, so they can be summed up to any grouping (tract, income quintile).
-- The denominator matches pct_cancelled in mv_route_summary: rows that were
-- either scheduled (0) or cancelled (3); added trips (1) are excluded.
--
-- Dropped above, before obs_dashboard, because it depends on obs_dashboard:
-- Postgres refuses to drop a view that another object is built on.
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW mv_stop_cancellations AS
SELECT agency_id,
       to_stop_id                                                   AS stop_id,
       feed_version,
       day_type,
       COUNT(*) FILTER (WHERE schedule_relationship IN (0, 3))      AS scheduled,
       COUNT(*) FILTER (WHERE schedule_relationship = 3)            AS cancelled
  FROM obs_dashboard
 GROUP BY 1, 2, 3, 4;


ANALYZE mv_route_summary;
ANALYZE mv_route_hour;
ANALYZE mv_daily_agency;
ANALYZE mv_headway;
ANALYZE mv_stop_delay;
ANALYZE mv_stop_cancellations;

