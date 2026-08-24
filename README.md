# Rateflow

Public dashboard of USD, EUR, CNY and GBP exchange rates against the Russian ruble: full history back to 1999 from three independent sources, interactive charts, a naive trend forecast with backtest, a converter, and a log of every call made to the data sources.

![Rateflow dashboard](docs/screenshot.jpg)

## Stack

Ruby 3.4 · Rails 8.1 · PostgreSQL · Hotwire (Turbo + Stimulus) via importmap · Chart.js (vendored, so the chart works offline) · plain CSS with light/dark themes. No auth, no background workers, no extra gems.

## Run locally

```sh
bundle install
bin/rails db:create db:migrate
bundle exec rake rates:fetch          # recent data from all three providers
bundle exec rake rates:backfill       # optional: full archive since 1999 (~5 min)
bin/rails server                      # http://localhost:3000
```

Both tasks are idempotent (rows are upserted), so re-running them never creates duplicates. `rates:backfill[2010-01-01]` starts from a custom date; the default is 1999 because pre-denomination rates (~6000 ₽/$) would wreck the chart scale.

Tests: `bin/rails test` (no network — provider responses are stubbed with saved fixtures).

## Data sources

All three providers are equals: every run polls each of them, every attempt is logged, and each provider's rows are stored under its own key. One provider failing never stops the others.

| Provider | History | Endpoint | Notes |
|---|---|---|---|
| **CBR** (Bank of Russia) | since 1999 | `cbr.ru/scripts/XML_dynamic.asp` | Arbitrary date ranges per currency, XML in windows-1251, decimal comma, rate = `Value / Nominal`. No data on weekends/holidays. |
| **ER-API** (open.er-api.com) | today only | `open.er-api.com/v6/latest/USD` | RUB rate = `rates.RUB / rates[X]`; the rate date comes from the response's `time_last_update_utc`. |
| **Currency API** (jsDelivr) | per-date snapshots | `cdn.jsdelivr.net/npm/@fawazahmed0/currency-api` | Latest or per-date snapshot; rate = `usd.rub / usd[x]` (lowercase keys); Cloudflare Pages mirror as a CDN fallback; a 404 on a date just means no data for that day. |

All keyless. Every request has a 10-second timeout; network errors are caught and logged, never raised to the page. The app clock is pinned to Europe/Moscow, matching the time zone CBR rates are published in.

### Fetch and backfill

- `rake rates:fetch` — daily refresh: the last 14 days from CBR plus today's snapshot from ER-API and Currency API. One FetchLog entry per provider per run.
- `rake rates:backfill[from]` — one-off archive load: CBR in year-sized slices per currency since `from` (default 1999-01-01), Currency API sampled weekly over the last two years, 300 ms pause between requests. ER-API has no history and is skipped.

### Serving the chart

The page embeds only the initial series; every switch fetches `GET /series?currency=USD&providers=cbr,erapi&from=…&to=…`. Responses are cached for 10 minutes (keyed by the query plus the table's max `updated_at`) and downsampled server-side to ~400 points, so the all-time chart stays fast on tens of thousands of rows.

## Pages

- `/` — currency cards (each labeled with its source and date), chart with currency / period (7 days to all time, or a custom range) / multi-source switches, a divergence readout for the latest date the sources share, 7-day rolling-mean trend with a backtest error estimate, converter, history table with a source column and filter.
- `/sources` — provider health (last status, success share of the last 20 attempts, mean response time) plus data coverage per provider (first date, last date, point count — which is why CBR reaches 1999 and the others only recent months), and a paginated fetch log with provider/status filters.

## Deploy (Render + Supabase)

1. Create a Postgres database on Supabase and copy its connection URI.
2. On Render create a **Web Service** from this repo:
   - Build command: `bin/render-build.sh`
   - Start command: `bin/rails db:migrate && bin/rails server`
   - Environment: `DATABASE_URL` = Supabase URI, `RAILS_ENV=production`, `SECRET_KEY_BASE` = output of `bin/rails secret`
3. Add a **Cron Job** on Render with the same repo and env vars to refresh data daily:
   - Command: `bundle exec rake rates:fetch`
   - Schedule: e.g. `0 6 * * *`
4. Run `bundle exec rake rates:backfill` once (from the Render shell or locally against the production `DATABASE_URL`) to load the archive.

In production the database is read from `DATABASE_URL`; migrations run on every start.
