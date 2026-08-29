# Rateflow

Public dashboard of USD, EUR, CNY and GBP exchange rates against the Russian ruble: full history back to 1999 from four independent sources, interactive charts, versioned forecasts (АПЭКОН monthly + our own rolling mean) with history playback and accuracy scoring, a converter, and a log of every call made to the data sources.

**Live: [rateflow-forecast.onrender.com](https://rateflow-forecast.onrender.com)**

![Rateflow dashboard](docs/screenshot.jpg)

## Stack

Ruby 3.4 · Rails 8.1 · PostgreSQL · Hotwire (Turbo + Stimulus) via importmap · Chart.js (vendored, so the chart works offline) · plain CSS, dark theme by default with a light toggle. No user accounts, no background workers, no extra gems.

## Architecture

```
external sources                 services                       storage → pages
────────────────                 ────────                       ───────────────
CBR / ER-API / Currency API ──▶  RatesFetcher ────────────────▶ rates ──────────▶ / (dashboard), /series
apecon.ru (HTML) ─────────────▶  ForecastsFetcher ─┐
                                 InternalForecast ─┴──────────▶ forecast_runs ──▶ /forecasts, /forecasts/data
                                                                + forecast_points
every fetch attempt ──────────▶  (logged inline) ─────────────▶ fetch_logs ─────▶ /sources, /admin
```

An external scheduler GETs `/cron/refresh` and `/cron/forecasts`; the controllers call the same service objects the admin buttons and rake tasks use, everything runs inside the request (no queues), results are upserted, and every attempt lands in `fetch_logs`. Pages themselves query nothing: `/` and `/forecasts` render a shell of skeletons and fill it from JSON (`/dashboard/data`, `/series`, `/forecasts/data`) and one HTML fragment (`/forecasts/accuracy`). Those go through thin read models (`Dashboard`, `RateSeries`, `ForecastSeries`, `ForecastAccuracy`) that keep the heavy lifting in SQL, and are cached for 10 minutes, invalidated by the tables' `max(updated_at)`.

## Data schema

Four tables, no users, no queues:

- **rates** — one row per (currency, provider, date): the fact. Unique index on the triple; upserts keep re-fetches idempotent, and a row is only written when its value actually changed, so a fetch that brings nothing new leaves `updated_at` — and the caches keyed on it — alone.
- **forecast_runs** — one stored forecast snapshot: provider (`apecon` / `internal`), currency, `captured_at`. A snapshot identical to the previous one only bumps `captured_at`.
- **forecast_points** — the payload of a run: horizon date, predicted value, optional min–max corridor. `belongs_to :forecast_run`, unique per (run, horizon date).
- **fetch_logs** — journal of every call to every source: provider, kind (`rates` / `forecast`), ok flag, HTTP status, duration, error, rows written. Feeds `/sources`, `/admin` and the cron throttle; pruned after 90 days.

## Run locally

```sh
bundle install
bin/rails db:create db:migrate
bundle exec rake rates:fetch          # recent data from the three API providers (seconds; АПЭКОН rides with forecasts)
bundle exec rake rates:backfill       # optional: full archive since 1999 (~5 min)
bin/rails server                      # http://localhost:3000
```

Both tasks are idempotent (rows are upserted), so re-running them never creates duplicates. `rates:backfill[2010-01-01]` starts from a custom date; the default is 1999 because pre-denomination rates (~6000 ₽/$) would wreck the chart scale. The full backfill is deliberately a rake task — it is far too slow for a web request.

Tests: `bin/rails test` (no network — provider responses are stubbed with saved fixtures, including a real `apecon.ru` page in `test/fixtures/files/apecon_usd.html`).

## Environment variables

| Variable | Used by | Behavior when unset |
|---|---|---|
| `DATABASE_URL` | production database (Supabase **session pooler** string — see Deploy) | app cannot boot |
| `RAILS_MASTER_KEY` | production: decrypts `config/credentials.yml.enc` (holds `secret_key_base`) | app cannot boot |
| `RAILS_SERVE_STATIC_FILES` | production: the app itself serves precompiled assets (nothing sits in front of it on Render) | assets 404 |
| `APP_HOST` | production: extra allowed domain besides `*.onrender.com` | only the Render domain is allowed |
| `TZ` | keeps the OS clock in Moscow time, matching `config.time_zone` | logs/cron timestamps drift to UTC |
| `RAILS_MAX_THREADS` | Puma thread count **and** the Active Record pool size (kept equal so the app never wants more DB connections than Supabase's free tier gives) | both default to 3 (5 for the pool outside Puma) |
| `CRON_TOKEN` | `GET /cron/*` endpoints | endpoints answer **503** (never open to everyone) |
| `ADMIN_USER`, `ADMIN_PASSWORD` | `/admin` (HTTP Basic) | page answers **503** with a hint |

`.env.example` lists every variable with a comment; copy it to `.env` for development — the file is gitignored and loaded automatically in development and test.

## Data sources

The three API providers are polled together on every rates run; АПЭКОН's quote is saved by the forecast fetch, from the same page load (its 10 s crawl delay is too slow for the rates endpoint). Every attempt is logged, each provider's rows are stored under its own key, and one provider failing never stops the others.

| Provider | History | Endpoint | Notes |
|---|---|---|---|
| **CBR** (Bank of Russia) | since 1999 | `cbr.ru/scripts/XML_dynamic.asp` | Arbitrary date ranges per currency, XML in windows-1251, decimal comma, rate = `Value / Nominal`. No data on weekends/holidays. Also the source of *facts* for forecast accuracy. |
| **ER-API** (open.er-api.com) | today only | `open.er-api.com/v6/latest/USD` | RUB rate = `rates.RUB / rates[X]`; the rate date comes from the response's `time_last_update_utc`. |
| **Currency API** (jsDelivr) | per-date snapshots | `cdn.jsdelivr.net/npm/@fawazahmed0/currency-api` | Latest or per-date snapshot; rate = `usd.rub / usd[x]` (lowercase keys); Cloudflare Pages mirror as a CDN fallback; a 404 on a date just means no data for that day. |
| **АПЭКОН** (apecon.ru) | today's quote + monthly forecast | one HTML page per currency | Parsed with Nokogiri by table *shape* («Ммм ГГГГ» + «мин-макс»), not CSS classes. `robots.txt` demands `Crawl-delay: 10`, enforced in the provider itself; forecasts are refreshed at most once a day per currency. Custom User-Agent `Rateflow/1.0 (+https://github.com/RisaGithub/Rateflow)`. |

All keyless. Every request has a 10-second timeout; network errors are caught, logged to FetchLog, and never raised to the page.

![Sources page](docs/sources.jpg)

## Forecasts

A forecast is a **snapshot in time**: the same month may be predicted differently tomorrow, and that evolution is the point. Snapshots are stored in `forecast_runs` (provider, currency, captured_at) with points in `forecast_points` (horizon date, value, optional min–max range). A snapshot identical to the previous one only refreshes its `captured_at` — no duplicate versions pile up.

- **АПЭКОН** — monthly forecast parsed from the site, with a min–max corridor.
- **internal** — our rolling mean (window 7, horizon 7 days), computed server-side (`app/services/internal_forecast.rb`) and re-snapshotted on every data update.

![Forecasts page](docs/forecasts.jpg)

Everything forecast-related lives on the `/forecasts` page (the dashboard keeps only a compact teaser card with each source's nearest prediction). One currency + period + source switch drives four views over the same snapshots: forecast-over-fact chart (dashed lines, АПЭКОН with a shaded corridor, a slider + play button replaying versions at ~600 ms, auto-play disabled under `prefers-reduced-motion`), a fan of all versions at once (newer = brighter), a revision chart for one chosen horizon date (with the CBR fact line once the date has passed), and the accuracy block. The period switch (default 90 days, plus a «Свой» custom from–to range in a small popover — same as on the dashboard) bounds the fact line and the snapshot capture dates — the forecast part of the main chart always shows in full. Data comes from `GET /forecasts/data?currency=USD` (optionally `&provider=apecon`, `&from=date&to=date` for the period, `&latest=1` for the teaser, `&run=id` for one exact snapshot), cached for 10 minutes like `/series`; the runs carrying points are thinned to ≤100 per provider (newest always kept), while the metadata index behind the snapshot table stays complete. The accuracy section body is served by `GET /forecasts/accuracy?from=date&to=date` so the period switch can rescore it without a reload.

**Accuracy**: every matured forecast point (horizon date passed, CBR fact exists, and the prediction was made *before* the date) is scored per provider and currency — comparisons count, MAE in ₽, MAPE in %, bucketed by lead time (≤7 / 8–30 / 30+ days). Deliberately no headline totals: the providers forecast different horizons, so only buckets where both have matured points are marked comparable; the rest are dimmed. No invented numbers — until forecasts mature, the block says so. The internal model's figures come from a backtest — the same model replayed over past data with no peeking ahead — while АПЭКОН's come from predictions it actually published; the UI labels which is which.

## Refreshing data

### Cron endpoints (for an external scheduler)

Plain GET with a shared token, because many free schedulers can only GET:

```
GET /cron/refresh?token=...     # rates: the three API providers, last 14 days (seconds, no apecon.ru visits)
GET /cron/forecasts?token=...   # forecasts: the internal one for every currency (its АПЭКОН half cannot run on the server — see below)
```

`/cron/refresh` is meant to be **attempted every two hours** — often enough that a new CBR rate shows up within the hours it is published, cheap enough to be free. Trying often only works because a try that finds nothing new costs nothing: the providers resend two weeks of history every time, and only rows whose value actually changed are written. On a quiet run nothing is touched, `updated_at` does not move, the JSON caches keyed on it survive, and the internal forecast is not recomputed. The response spells both numbers out:

```json
{"status":"ok","kind":"rates","rows_written":0,"rows_received":168,"duration_ms":842}
```

`records_count` in the fetch log stays the number of rows the provider handed over — that is a measure of the provider being up, and `/sources` reads it as such.

- Token from `ENV["CRON_TOKEN"]`, compared with `secure_compare`. No token configured → 503; wrong token → 401.
- The same update having run less than 10 minutes ago → `{"status":"skipped"}` with no network calls. That is a guard against a double call, not a schedule: it does not get in the way of a two-hourly one.
- Both endpoints (and `/admin`) are rate-limited to 20 requests per minute per IP; past that the answer is 429.
- The day's first successful `/cron/refresh` also prunes housekeeping data (see `logs:prune` below), so no separate cleanup scheduler is needed.
- `/cron/forecasts` recomputes the internal Rateflow forecast for all four currencies. That half is a rolling mean over rates already in the database — no outside request at all — so it always works on the server.
- The same endpoint also *attempts* one АПЭКОН currency (the stalest — the site's 10 s crawl delay makes four too slow for one request), but that half cannot succeed from the deployed service. apecon.ru sits behind an sgcaptcha bot check that challenges by IP address and answers a datacenter address with a 168-byte meta-refresh stub, status 200, instead of the page. `Providers::Apecon` recognises the stub and reports a bot check, so the fetch log says what actually happened rather than blaming a redesign that did not occur — and the internal half of the call is unaffected.
- АПЭКОН snapshots are refreshed instead by a scheduled client running outside the deployment, through the same `rake forecasts:fetch`. `ForecastsFetcher` keeps the site's 10-second pause and skips any currency refreshed within the last day, so even hourly attempts mean at most one page load per currency per day.

Example (cron-job.org, GitHub Actions cron, Render Cron hitting a URL):

```
0 */2 * * *          curl -fsS "https://your-app/cron/refresh?token=$CRON_TOKEN"
30 6 * * *           curl -fsS "https://your-app/cron/forecasts?token=$CRON_TOKEN"
```

### Admin page

`/admin` (HTTP Basic from `ADMIN_USER` / `ADMIN_PASSWORD`) shows row counts and date coverage per provider, forecast snapshot counts, the last 20 FetchLog entries, and buttons for: refresh rates (14 days), backfill one year of CBR history, refresh forecasts (one currency), recompute the internal forecast. Buttons disable while submitting (Turbo). The full archive load stays a rake task: `bin/rails "rates:backfill[1999-01-01]"`.

### Rake tasks

- `rake rates:fetch` — same as `/cron/refresh`, from the console.
- `rake forecasts:fetch[currency]` — АПЭКОН forecasts from the console: one currency, or (without the argument) all four in turn with the site's mandatory 10-second pause between page loads (~1 min). Same code path as `/cron/forecasts`, so today's АПЭКОН quote lands in `rates` along the way and a currency refreshed less than a day ago is skipped.
- `rake forecasts:backtest[days]` — replays the internal forecast daily over the last `days` (default 180) of CBR facts; deterministic and idempotent.
- `rake rates:backfill[from]` — one-off archive load: CBR in year-sized slices per currency since `from` (default 1999-01-01), Currency API sampled weekly over the last two years, 300 ms pause between requests.
- `rake logs:prune[days]` — housekeeping (also run automatically once a day by `/cron/refresh`). Deletes fetch-log rows older than `days` (default 90) — the sources page only ever shows recent attempts, so an unbounded journal is pure dead weight — and internal forecast snapshots older than a year, which lose nothing because the model is deterministic and `forecasts:backtest` can replay them from CBR facts at any moment. АПЭКОН snapshots are **never** deleted: they were scraped at a point in time and cannot be recovered.

### Serving the chart

Pages ship as an empty frame behind skeletons and ask for their data afterwards: the dashboard fetches `GET /dashboard/data` (cards and quotes) together with `GET /series?currency=USD&providers=cbr,erapi&from=…&to=…`, and every switch refetches the series. Responses are cached for 10 minutes (keyed by the query plus the table's max `updated_at`) and downsampled server-side to ~400 points, so the all-time chart stays fast on tens of thousands of rows. `/forecasts/data` follows the same caching rules.

## Pages

- `/` — currency cards (each labeled with its source and date), chart with currency / period / multi-source switches, a divergence readout for the latest date the sources share, a forecast teaser card linking to `/forecasts`, converter, history table with a source column and filter.
- `/forecasts` — the four forecast views described above plus a paginated table of every stored snapshot (a row click puts that version on the main chart).
- `/sources` — provider health (last status, success share of the last 20 attempts, mean response time) plus data coverage per provider, and a paginated fetch log with provider/status filters.
- `/about` — a plain-language explainer (reachable from the top bar): what the site shows, where the data comes from, how the forecast and its honest accuracy work. No operational details.
- `/admin` — see above.

Right after a fresh deploy, while the tables are still empty, the dashboard, forecasts and sources pages lead with a calm first-run notice instead of blank charts; it disappears once the first refresh lands.

## Deploy (Render + Supabase)

The repo ships a Render **Blueprint** (`render.yaml`): one Ruby web service, `bin/render-build.sh` as the build command (gems → assets → `db:migrate`, `errexit` so a broken step fails the deploy and the previous version stays live), Puma as the start command, health check on `/up`. The database lives on Supabase and reaches the app through `DATABASE_URL`.

> **Before the first deploy**: the service's region and subdomain come from `render.yaml` (`region`, `name`) and are fixed at creation — Render does not let you change either afterwards, so a mistake means deleting and recreating the service. The blueprint pins `region: frankfurt` (next to the Supabase database) and `name: rateflow-forecast` (the subdomain `rateflow-forecast.onrender.com`).

### Which Supabase connection string — and why

Supabase offers three connection strings; only one of them is right here:

- **Direct connection** (port 5432) — resolves to IPv6 only unless you pay for a dedicated IPv4 address. Render's runtime has no outbound IPv6, so this string will simply not connect. **Do not use.**
- **Session pooler** (Supavisor, port 5432) — IPv4-friendly and built for long-lived backends holding persistent connections, which is exactly what Puma is. Behaves like plain Postgres, prepared statements included. **This is the one to copy.**
- **Transaction pooler** (port 6543) — for serverless functions that connect per request; requires prepared statements to be switched off. Wrong tool for this app.

### Step by step

1. **Supabase**: create a project (Region — pick one close to Render's), wait for it to provision. Press **Connect** at the top of the dashboard, switch to the **Session pooler** tab, copy the URI (`postgresql://postgres.xxxx:[YOUR-PASSWORD]@aws-0-<region>.pooler.supabase.com:5432/postgres`) and substitute the database password you set at project creation.
2. **Render**: New → **Blueprint**, connect the `RisaGithub/Rateflow` GitHub repo, branch `main`. Render reads `render.yaml` and asks for the values marked `sync: false`:
   - `DATABASE_URL` — the session pooler URI from step 1;
   - `RAILS_MASTER_KEY` — the contents of your local `config/master.key` (one line; it is gitignored, which is why Render must be told it);
   - `CRON_TOKEN` — any long random string (`openssl rand -hex 24`);
   - `ADMIN_USER`, `ADMIN_PASSWORD` — credentials for `/admin`.
   `RAILS_ENV`, `RAILS_SERVE_STATIC_FILES`, `RAILS_MAX_THREADS` and `TZ` come preset from the blueprint. Deploy; the first build also migrates the empty Supabase database.
3. **First data** (the tables are empty): either press the `/admin` buttons in order («Обновить курсы», «Догрузить год ЦБ РФ», «Обновить прогнозы», «Пересчитать прогноз Rateflow») for a live last year, or — better — run the full seed from a laptop as described in the next section. The long tasks (full archive and forecast backtest) are too slow for a web request, and the free Render tier has no shell, so the laptop route (see [Seeding the production database from a laptop](#seeding-the-production-database-from-a-laptop)) is the only way to get the complete 1999-onwards archive.
4. **Scheduler** (e.g. cron-job.org): two GET jobs with the token from step 2 —
   - `https://rateflow-forecast.onrender.com/cron/refresh?token=…` every 2 hours;
   - `https://rateflow-forecast.onrender.com/cron/forecasts?token=…` 4 times a day (each call refreshes one АПЭКОН currency, so all four rotate through daily).
5. **Custom domain later**: add it in Render, then set `APP_HOST` to that domain so Rails' host allowlist accepts it.

**Free-tier sleep**: Render suspends a free service after ~15 minutes of no traffic, and the next request waits several seconds while it wakes. The scheduler calls above double as keep-alive pings — with them the app is asleep at most between cron hits, and the health check `/up` never redirects to HTTPS so wake-ups stay cheap.

### Seeding the production database from a laptop

The session pooler string works from a laptop too, so anything too slow for a web request runs locally against Supabase. `bin/prod` makes that a one-word prefix: it reads `DATABASE_URL` from `.env.production.local` (git-ignored; create it at the repo root with that single line — the session pooler URI, **not** Direct, which is IPv6-only) and runs any command with `RAILS_ENV=production`:

```sh
bin/prod rails db:migrate                    # schema, if not migrated yet
bin/prod rake rates:fetch                    # quick write check: recent rates
bin/prod rake "rates:backfill[1999-01-01]"   # full CBR archive, ~5 min
bin/prod rake "forecasts:backtest[180]"      # historical internal snapshots, seconds
bin/prod rake forecasts:fetch                # АПЭКОН, all four currencies, ~1 min
```

Every task is idempotent (rows are upserted, snapshots dedup) — if a step dies half-way, just rerun that step. If the connection refuses: make sure the string is from the **Session pooler** tab, try appending `?sslmode=require`, and URL-encode any special characters in the password. `bin/prod rails server` also works for a final look at the real data before sharing the link — remember that you are then writing to the production database.

## Roadmap

The data model and the scoring harness were built to be extended — these are the next things they make possible:

- **More currencies, driven by configuration.** Adding a pair today means touching `Rate::CURRENCIES` and the АПЭКОН page map; moving that into a registry opens the door to JPY, TRY, KZT and the rest without code changes.
- **Stronger forecasting models.** The rolling mean is a deliberate baseline — something honest to measure against. Exponential smoothing, ARIMA and a seasonal model can drop straight into `InternalForecast` and be scored side by side in the accuracy block that already exists.
- **More forecast providers.** `forecast_runs` / `forecast_points` are provider-agnostic by design, so a new source of predictions is a parser and a key, not a migration.
- **Intraday rates.** Official daily fixings are the backbone; adding an exchange feed alongside them would turn the dashboard into something you can watch during the day, not just read in the morning.
- **A public JSON API.** `/series` and `/forecasts/data` already speak JSON — documenting them, versioning them and adding CORS makes the whole archive reusable by other projects.
- **Data export.** One-click CSV or JSON for any series and period, straight from the chart.
- **Alerts.** Notify when a rate crosses a threshold, or when a forecast for a date gets revised sharply — the revision history needed for that is already stored.
- **Always-on hosting.** Moving off the free tier removes the cold start after quiet stretches and lets the cache and rate limiter live in Redis instead of process memory.

## License

[MIT](LICENSE) © Elizaveta Trapeznikova.
