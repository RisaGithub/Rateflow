# Rateflow

Public dashboard of USD, EUR, CNY and GBP exchange rates against the Russian ruble: full history back to 1999 from four independent sources, interactive charts, versioned forecasts (АПЭКОН monthly + our own rolling mean) with history playback and accuracy scoring, a converter, and a log of every call made to the data sources.

![Rateflow dashboard](docs/screenshot.jpg)

## Stack

Ruby 3.4 · Rails 8.1 · PostgreSQL · Hotwire (Turbo + Stimulus) via importmap · Chart.js (vendored, so the chart works offline) · plain CSS with light/dark themes. No user accounts, no background workers, no extra gems.

## Run locally

```sh
bundle install
bin/rails db:create db:migrate
bundle exec rake rates:fetch          # recent data from all four providers (~40 s: АПЭКОН enforces a 10 s crawl delay)
bundle exec rake rates:backfill       # optional: full archive since 1999 (~5 min)
bin/rails server                      # http://localhost:3000
```

Both tasks are idempotent (rows are upserted), so re-running them never creates duplicates. `rates:backfill[2010-01-01]` starts from a custom date; the default is 1999 because pre-denomination rates (~6000 ₽/$) would wreck the chart scale. The full backfill is deliberately a rake task — it is far too slow for a web request.

Tests: `bin/rails test` (no network — provider responses are stubbed with saved fixtures, including a real `apecon.ru` page in `test/fixtures/files/apecon_usd.html`).

## Environment variables

| Variable | Used by | Behavior when unset |
|---|---|---|
| `DATABASE_URL` | production database | — |
| `SECRET_KEY_BASE` | production | — |
| `CRON_TOKEN` | `GET /cron/*` endpoints | endpoints answer **503** (never open to everyone) |
| `ADMIN_USER`, `ADMIN_PASSWORD` | `/admin` (HTTP Basic) | page answers **503** with a hint |

## Data sources

All four providers are equals: every run polls each of them, every attempt is logged, and each provider's rows are stored under its own key. One provider failing never stops the others.

| Provider | History | Endpoint | Notes |
|---|---|---|---|
| **CBR** (Bank of Russia) | since 1999 | `cbr.ru/scripts/XML_dynamic.asp` | Arbitrary date ranges per currency, XML in windows-1251, decimal comma, rate = `Value / Nominal`. No data on weekends/holidays. Also the source of *facts* for forecast accuracy. |
| **ER-API** (open.er-api.com) | today only | `open.er-api.com/v6/latest/USD` | RUB rate = `rates.RUB / rates[X]`; the rate date comes from the response's `time_last_update_utc`. |
| **Currency API** (jsDelivr) | per-date snapshots | `cdn.jsdelivr.net/npm/@fawazahmed0/currency-api` | Latest or per-date snapshot; rate = `usd.rub / usd[x]` (lowercase keys); Cloudflare Pages mirror as a CDN fallback; a 404 on a date just means no data for that day. |
| **АПЭКОН** (apecon.ru) | today's quote + monthly forecast | one HTML page per currency | Parsed with Nokogiri by table *shape* («Ммм ГГГГ» + «мин-макс»), not CSS classes. `robots.txt` demands `Crawl-delay: 10`, enforced in the provider itself; forecasts are refreshed at most once a day per currency. Custom User-Agent `Rateflow/1.0 (+https://github.com/RisaGithub/Rateflow)`. |

All keyless. Every request has a 10-second timeout; network errors are caught, logged to FetchLog, and never raised to the page.

## Forecasts

A forecast is a **snapshot in time**: the same month may be predicted differently tomorrow, and that evolution is the point. Snapshots are stored in `forecast_runs` (provider, currency, captured_at) with points in `forecast_points` (horizon date, value, optional min–max range). A snapshot identical to the previous one only refreshes its `captured_at` — no duplicate versions pile up.

- **АПЭКОН** — monthly forecast parsed from the site, with a min–max corridor.
- **internal** — our rolling mean (window 7, horizon 7 days), computed server-side (`app/services/internal_forecast.rb`) and re-snapshotted on every data update.

The chart draws either or both as dashed lines over the facts (АПЭКОН gets a shaded corridor). A slider + play button under the chart replays all stored versions of the selected source (~600 ms per version, hidden when there is only one snapshot, auto-play disabled under `prefers-reduced-motion`). Data comes from `GET /forecasts?currency=USD` (optionally `&provider=apecon`), cached for 10 minutes like `/series`.

**Accuracy**: every matured forecast point (horizon date passed, CBR fact exists, and the prediction was made *before* the date) is scored. The dashboard shows per provider: comparisons count, MAE in ₽, MAPE in %, bucketed by lead time (≤7 / 8–30 / 30+ days). No invented numbers — until forecasts mature, the block says so.

## Refreshing data

### Cron endpoints (for an external scheduler)

Plain GET with a shared token, because many free schedulers can only GET:

```
GET /cron/refresh?token=...     # rates: all four providers, last 14 days
GET /cron/forecasts?token=...   # forecasts: one АПЭКОН currency (the stalest) + internal for all
```

- Token from `ENV["CRON_TOKEN"]`, compared with `secure_compare`. No token configured → 503; wrong token → 401.
- The same update having run less than 10 minutes ago → `{"status":"skipped"}` with no network calls.
- `/cron/forecasts` touches **one** currency per call (АПЭКОН's 10 s crawl delay makes four too slow for one request). Schedule it ~4 times a day and every currency rotates through within a day.

Example (cron-job.org, GitHub Actions cron, Render Cron hitting a URL):

```
0 6,12,18 * * *   curl -fsS "https://your-app/cron/refresh?token=$CRON_TOKEN"
30 6,10,14,18 * * *  curl -fsS "https://your-app/cron/forecasts?token=$CRON_TOKEN"
```

### Admin page

`/admin` (HTTP Basic from `ADMIN_USER` / `ADMIN_PASSWORD`) shows row counts and date coverage per provider, forecast snapshot counts, the last 20 FetchLog entries, and buttons for: refresh rates (14 days), backfill one year of CBR history, refresh forecasts (one currency), recompute the internal forecast. Buttons disable while submitting (Turbo). The full archive load stays a rake task: `bin/rails "rates:backfill[1999-01-01]"`.

### Rake tasks

- `rake rates:fetch` — same as `/cron/refresh`, from the console.
- `rake rates:backfill[from]` — one-off archive load: CBR in year-sized slices per currency since `from` (default 1999-01-01), Currency API sampled weekly over the last two years, 300 ms pause between requests.

### Serving the chart

The page embeds only the initial series; every switch fetches `GET /series?currency=USD&providers=cbr,erapi&from=…&to=…`. Responses are cached for 10 minutes (keyed by the query plus the table's max `updated_at`) and downsampled server-side to ~400 points, so the all-time chart stays fast on tens of thousands of rows. `/forecasts` follows the same caching rules.

## Pages

- `/` — currency cards (each labeled with its source and date), chart with currency / period / multi-source / forecast-source switches, forecast version playback, a divergence readout for the latest date the sources share, the internal trend panel, forecast accuracy block, converter, history table with a source column and filter.
- `/sources` — provider health (last status, success share of the last 20 attempts, mean response time) plus data coverage per provider, and a paginated fetch log with provider/status filters.
- `/admin` — see above.

## Deploy (Render + Supabase)

1. Create a Postgres database on Supabase and copy its connection URI.
2. On Render create a **Web Service** from this repo:
   - Build command: `bin/render-build.sh`
   - Start command: `bin/rails db:migrate && bin/rails server`
   - Environment: `DATABASE_URL` = Supabase URI, `RAILS_ENV=production`, `SECRET_KEY_BASE` = output of `bin/rails secret`, `CRON_TOKEN`, `ADMIN_USER`, `ADMIN_PASSWORD`
3. Point any external scheduler (e.g. cron-job.org) at the two `/cron/*` URLs above — `/cron/refresh` once or twice a day, `/cron/forecasts` about four times a day.
4. Run `bundle exec rake rates:backfill` once (from the Render shell or locally against the production `DATABASE_URL`) to load the archive.

In production the database is read from `DATABASE_URL`; migrations run on every start.
