# Bay Area Transit Reliability

Which Bay Area transit routes are unreliable, at what hours — and does the delay
burden fall hardest on neighborhoods least able to fall back on a car?

A PostgreSQL + Metabase analysis of **25.8 million observed transit arrivals**
across 40 Bay Area operators, August 2026.

Course project for DSAI 691 (Relational Databases), University of San Francisco.

---

## The data

511 SF Bay publishes a monthly regional archive containing `stop_observations.txt`:
observed arrival times for every trip at every stop, with the scheduled times
already joined alongside. Requesting it requires the `-so` suffix, which is easy
to miss — without it you get a 50 MB schedule archive and no observations at all.

```
https://api.511.org/transit/datafeeds?operator_id=RG&historic=2026-08-so&api_key=KEY
```

~600 MB compressed, ~3.7 GB extracted. `stop_observations.txt` alone is 2.9 GB.
A free key comes from [511.org/open-data/token](https://511.org/open-data/token).

**An important caveat about what "observed" means.** These are not stopwatch
readings. Each observation is inferred from the agency's own realtime prediction
feed by taking the last prediction issued before the vehicle passed the stop. The
chain runs vehicle GPS → agency CAD/AVL → the agency's proprietary prediction
algorithm → 511 aggregation → a daily batch job. Quality therefore varies by
operator, and that variation turns out to matter — see Findings.

---

## Rebuilding the database

You need Docker and a 511 API key.

```bash
# 1. secrets
cp .env.example .env         # then fill in FIVEONEONE_KEY and POSTGRES_PASSWORD

# 2. start Postgres (with PostGIS) and Metabase
docker compose up -d

# 3. fetch and extract the archive into ./data
mkdir -p data && cd data
set -a; source ../.env; set +a
curl -L -C - -o rg-2026-08-so.zip \
  "https://api.511.org/transit/datafeeds?operator_id=RG&historic=2026-08-so&api_key=$FIVEONEONE_KEY"
unzip -o rg-2026-08-so.zip agency.txt routes.txt trips.txt stops.txt stop_observations.txt
cd ..

# 4. build everything — all three files, in this order, as one psql session
cat create_and_load.sql census_tracts.sql stop_tract_mapping.sql \
  | docker exec -i postgres psql -U transit -d postgres
```

Note `-d postgres`, not `-d transit`: the script drops and recreates the
`transit` database, which cannot be done from inside it. Its `\c transit` line
then switches the session into the new database, which is why the census files
must be piped through the same session rather than run separately against
`postgres`.

**Run all three files.** `create_and_load.sql` drops the whole database, so
running it alone deletes the census tables, and the equity panels (6–8) break.

The load itself takes about **9 minutes** on 4 vCPU / 16 GB; Section 8's
dashboard rollups add more on top. Metabase is then at
`http://localhost:3000`; connect it to host `postgres`, port 5432, database
`transit`.

The script is re-runnable — a second run produces an identical database.

---

## Schema

Five tables. `stop_observations` is the fact table at 25.8M rows; the rest are
dimensions from the same archive.

```
agency ──< routes ──< trips
                 
stops                          stop_observations
```

Row counts after load: 40 agencies · 685 routes · 21,866 stops · 230,205 trips ·
25,768,104 observations.

Three decisions are worth knowing before reading the DDL.

**Time columns are `INTERVAL`, not `TIME`.** GTFS represents after-midnight
service with hours past `24:00:00` — a 12:30 am arrival on an evening trip is
`24:30:00`. This archive reaches **hour 32**, and ~910K rows (3.5%) are at or
past hour 24. Postgres `TIME` rejects those outright, so a `TIME` column fails
partway through the load with no obvious cause. Combine with `service_date` for a
real timestamp.

**`feed_version` is part of every key.** GTFS only guarantees identifiers are
unique *within* one published feed. Agencies republish when service changes, and
some regenerate `trip_id` values each time. Load a second month into unversioned
tables and one identifier describes two different things, with every join
silently mixing them. The cost is an extra condition on every join; the benefit
is a database that can hold more than one month without lying.

**Scheduled times come from the fact table, never from `stop_times`.** They are
already present in `stop_observations`, joined against the schedule version that
was actually in effect on that service date. Looking them up in `stop_times`
instead succeeds and returns wrong answers, because `trip_id` values are reused
across schedule versions.

---

## Findings

Section 7 of `create_and_load.sql` contains the validation queries these came
from.

**BART barely reports.** 69,448 observations for an entire month, against Muni's
9.8 million — despite running hundreds of trips a day across ~50 stations. Its
scheduled times are fine (97% populated); it simply isn't reporting. That is a
coverage problem to disclose, not a load bug, and it means the equity analysis
runs on bus operators. Arguably the stronger version of the argument anyway,
since bus riders are more car-constrained than BART riders.

**892,262 cancelled stops are invisible to delay analysis.** 3.5% of the file.
A late bus has a delay; a cancelled bus has none and vanishes from the data
entirely. From a rider's perspective that is the *worse* outcome, and a
delay-only dashboard reports it as nothing.

**The naive "worst routes" leaderboard measures the method, not the service.**
Ranked by p90 delay without filtering, the top results are San Francisco's cable
cars — whose terminal turnaround queuing registers as enormous delay but is not
lateness in any sense a rider would recognize — and small intercity operators
with long scheduled layovers. Restricting to `route_type = 3` produces a
recognizable list of buses with p90 delays of 13–18 minutes.

**The archive's own dwell column is wrong for some rows.** `dwell_time_secs`
reaches −86,382 seconds: almost exactly negative one day. Arrival near 23:59,
departure just after midnight, subtracted without accounting for the date rolling
over. The interval columns handle midnight correctly, so dwell is better
recomputed than trusted.

**A schedule-echo detector is necessary before any cross-agency comparison.**
When an agency loses vehicle tracking, some prediction engines fall back to
echoing the timetable — which appears in the data as *perfect on-time
performance* rather than as missing data. The tell is the share of observations
where observed equals scheduled to the exact second; a real vehicle essentially
never does this. This matters directly for the equity claim: if operators serving
lower-income areas have worse telemetry, their delays are understated and the
finding shrinks for reasons unrelated to service quality.

---

## Repository layout

| File | Purpose |
| :-- | :-- |
| `create_and_load.sql` | Creates the database, all tables, loads the archive, runs validation queries, and builds the dashboard views (Section 8). |
| `census_tracts.sql` | ACS income and vehicle-availability data for 1,772 Bay Area tracts, with TIGER boundaries. Run after `create_and_load.sql`. |
| `stop_tract_mapping.sql` | Which census tract each stop falls in. Run after `create_and_load.sql`. |
| `dashboard_queries.sql` | The SQL behind each Metabase panel, 1–9. A record, not a script. |
| `compose.yaml` | Postgres (with PostGIS) and Metabase. Postgres is deliberately not exposed to the internet. |
| `.env.example` | Required environment variables. Copy to `.env`, which is gitignored. |

Source data is not committed — the archive is 600 MB and re-downloadable.

---

## Conventions

For anyone adding to this:

- **Everything in the database must exist in `create_and_load.sql`.** If a table
  is created at a psql prompt but never lands in the script, the script quietly
  stops reproducing the real database.
- **Identifiers are `TEXT`.** GTFS ids carry prefixes and meaningful leading
  zeros (`BA:101053210`, `14R`, `06075`). Casting them to integers fails, or
  worse, silently corrupts.
- **Indexes go after the load**, not before. Maintaining an index across 25.8M
  inserts is dramatically slower than one bulk build afterward.
- **Measure coverage rather than enforcing it** where two feeds meet. There is no
  foreign key from `stop_observations` to `stops`: the observation and schedule
  feeds come from different pipelines, and an id present in one but not the other
  should surface as a number to report, not as rows rejected mid-load.
