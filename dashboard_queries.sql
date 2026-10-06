-- =============================================================================
-- dashboard_queries.sql
-- DSAI 691 — Relational Databases — Group Project, Task 3
-- Reliability dashboard panels 1–5
--
-- The SQL behind each panel. Each query is pasted into Metabase's SQL editor
-- and saved as a question in "Our analytics". This file is the record of them;
-- it is not run as a script.
--
-- Every query reads a view built by create_and_load.sql Section 8, so that
-- section must have been run first, or these fail with
-- "relation mv_... does not exist". Reading the views is also what makes each
-- panel return in under a second instead of scanning 25.8 M rows.
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