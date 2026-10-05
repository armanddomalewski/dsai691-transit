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

SELECT route_label,
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
-- Visualization: Metabase has no heatmap chart type; use a Pivot Table
-- (rows = route, columns = hour, values = p90_delay_min) with conditional
-- formatting as a color range.
--
-- The per-cell floor stops a single late-night trip from painting a cell red.
-- -----------------------------------------------------------------------------

WITH worst AS (
    SELECT agency_id, route_id, feed_version, route_label
      FROM mv_route_summary
     WHERE day_type = 'weekday'
       AND route_type = 3
       AND observations >= 20000
     ORDER BY p90_delay_min DESC
     LIMIT 15
)
SELECT w.agency_id || ' ' || w.route_label                          AS route,
       h.sched_hour                                                 AS hour,
       h.p90_delay_min
  FROM worst w
  JOIN mv_route_hour h ON h.route_id     = w.route_id
                      AND h.feed_version = w.feed_version
 WHERE h.day_type = 'weekday'
   AND h.observations >= 200
 ORDER BY route, hour;


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
 LIMIT 15;


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
   AND observations >= 100;