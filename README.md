# Rateflow

Public dashboard of USD, EUR, CNY and GBP exchange rates against the Russian ruble: 90 days of history, interactive charts, a naive trend forecast with backtest, a converter, and a log of every call made to the data sources.

![Rateflow dashboard](docs/screenshot.jpg)

## Stack

Ruby 3.4 · Rails 8.1 · PostgreSQL · Hotwire (Turbo + Stimulus) via importmap · Chart.js (CDN) · plain CSS with light/dark themes. No auth, no background workers, no extra gems.

## Run locally

```sh
bundle install
bin/rails db:create db:migrate
bin/rails db:seed        # fetches the last 90 days of real data
bin/rails server         # http://localhost:3000
```

Refresh the data at any time with `bundle exec rake rates:fetch` — it is idempotent (rows are upserted).

## Data sources

| Provider | Role | Endpoint | Notes |
|---|---|---|---|
| **CBR** (Bank of Russia) | primary | `cbr.ru/scripts/XML_dynamic.asp` | Full history per currency, XML in windows-1251, decimal comma, rate = `Value / Nominal`. No data on weekends/holidays. |
| **ER-API** (open.er-api.com) | fallback | `open.er-api.com/v6/latest/USD` | Today's snapshot only; RUB rate = `rates.RUB / rates[X]`. |

Both are keyless. Every request has a 10-second timeout; network errors are caught and logged, never raised to the page.

### How the fallback works

`RatesFetcher` asks CBR for each currency over the last 90 days. ER-API is then called once per run (one request covers all currencies) and serves two purposes:

1. **Fallback** — if CBR failed or returned nothing for a currency, the ER-API value is what the dashboard falls back to.
2. **Reference series** — its daily snapshots accumulate under `provider = erapi`, so the dashboard can plot both sources together and show how far they diverge.

Every attempt — success or failure — is written to `fetch_logs` with HTTP status, duration, record count and error text. The `/sources` page is built on that table.

## Pages

- `/` — currency cards with 30-day sparklines, chart with currency / period / source switches, 7-day rolling-mean trend with a backtest error estimate, converter, history table, data status line.
- `/sources` — provider health (last status, success share of the last 20 attempts, mean response time) and the last 50 fetch-log entries with provider/status filters.

## Deploy (Render + Supabase)

1. Create a Postgres database on Supabase and copy its connection URI.
2. On Render create a **Web Service** from this repo:
   - Build command: `bin/render-build.sh`
   - Start command: `bin/rails db:migrate && bin/rails server`
   - Environment: `DATABASE_URL` = Supabase URI, `RAILS_ENV=production`, `SECRET_KEY_BASE` = output of `bin/rails secret`
3. Add a **Cron Job** on Render with the same repo and env vars to refresh data daily:
   - Command: `bundle exec rake rates:fetch`
   - Schedule: e.g. `0 6 * * *`

In production the database is read from `DATABASE_URL`; migrations run on every start.
