import { Controller } from "@hotwired/stimulus"
import { crossfade, dropSkeleton, fadeIn } from "lib/skeletons"
import { entryAnimation, upsertChart } from "lib/chart_upsert"

const PROVIDER_NAMES = { cbr: "ЦБ РФ", erapi: "ER-API", currencyapi: "Currency API", apecon: "АПЭКОН", internal: "Rateflow" }
const RATE_PROVIDERS = ["cbr", "erapi", "currencyapi", "apecon"]
const SYMBOLS = { USD: "$", EUR: "€", CNY: "¥", GBP: "£" }
const fmtRub = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 4 })
const fmtPct = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 1, maximumFractionDigits: 2 })
const fmt2 = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 2 })

const dateRu = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7) + "." + iso.slice(0, 4)
const dateShort = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7)
const isoDaysAgo = (days) => {
  const d = new Date()
  d.setDate(d.getDate() - days)
  return d.toISOString().slice(0, 10)
}
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()
const signed = (value, suffix = "") =>
  (value > 0 ? "+" : value < 0 ? "−" : "") + fmt2.format(Math.abs(value)) + suffix
// Same two arrows the server icon partial draws.
const ARROWS = { up: '<path d="M6 15l6-6 6 6"/>', down: '<path d="M6 9l6 6 6-6"/>' }
const arrow = (name) =>
  `<svg class="icon" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" ` +
  `stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ARROWS[name]}</svg>`

// The card sparkline, same geometry as the helper that used to render it
// server-side: values scaled into a 96×40 box.
const sparkline = (values, width = 96, height = 40) => {
  if (values.length < 2) return ""

  const min = Math.min(...values)
  const span = Math.max(...values) - min || 1
  const step = width / (values.length - 1)
  const line = values
    .map((v, i) => `${(i * step).toFixed(1)},${(height - 2 - (v - min) / span * (height - 4)).toFixed(1)}`)
    .join(" ")
  return `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none">` +
    `<polygon points="0,${height} ${line} ${width},${height}" fill="currentColor" opacity="0.12"/>` +
    `<polyline points="${line}" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/></svg>`
}

const trendClass = (delta) => (delta == null || delta === 0 ? "is-flat" : delta > 0 ? "is-up" : "is-down")
const retryButton = (action) =>
  `<button type="button" class="retry-btn" data-action="dashboard#${action}">Повторить</button>`

// Dashboard state lives here: selected currency / period / sources. The page
// arrives as skeletons and nothing else — the cards and the converter's rates
// come from GET /dashboard/data, the chart and the table from GET /series, the
// forecast teaser from GET /forecasts/data.
export default class extends Controller {
  static targets = ["card", "cardSlot", "seg", "canvas", "chartWrap", "legend", "status", "diverge",
                    "tbody", "forecast", "converter", "emptyNotice", "range", "fromDate", "toDate", "sourceBox"]

  connect() {
    this.state = {
      currency: "USD", period: 30, from: null, to: null,
      sources: [...RATE_PROVIDERS], tableSource: "all", rows: 10
    }
    this.summary = null
    this.payload = null
    this.forecastPayload = null
    this.charts = {}
    this.onTheme = () => this.render()
    window.addEventListener("theme:change", this.onTheme)
    // The custom-range popup closes on an outside click or Escape; the period
    // stays "custom" — clicking «Свой» again reopens it.
    this.onDocPointer = (e) => {
      if (this.rangeTarget.hidden || this.rangeTarget.contains(e.target)) return
      if (e.target.closest?.('[data-key="period"][data-value="custom"]')) return
      this.rangeTarget.hidden = true
    }
    this.onDocKey = (e) => { if (e.key === "Escape") this.rangeTarget.hidden = true }
    document.addEventListener("pointerdown", this.onDocPointer)
    document.addEventListener("keydown", this.onDocKey)
    // Controls are drawable without any data; everything else waits for it.
    this.renderControls()
    this.loadSummary()
    this.load()
    this.loadForecasts()
  }

  disconnect() {
    window.removeEventListener("theme:change", this.onTheme)
    document.removeEventListener("pointerdown", this.onDocPointer)
    document.removeEventListener("keydown", this.onDocKey)
    this.summaryAbort?.abort()
    this.abortController?.abort()
    this.forecastAbort?.abort()
    Object.values(this.charts).forEach((c) => c.destroy())
  }

  // ----- actions -----

  selectCurrency(event) {
    this.state.currency = event.currentTarget.dataset.currency
    this.load()
    this.loadForecasts()
  }

  setOption(event) {
    const { key, value } = event.currentTarget.dataset
    const previousPeriod = this.state.period
    const num = Number(value)
    this.state[key] = Number.isNaN(num) ? value : num

    if (key === "rows" || key === "tableSource") return this.render()
    if (key === "period") {
      this.rangeTarget.hidden = this.state.period !== "custom"
      if (this.state.period === "custom") {
        // First open starts from the period that was on screen instead of
        // empty fields — the user adjusts dates, not types them from scratch.
        if (!this.state.from) this.prefillRange(previousPeriod)
        // preventScroll: focusing the field must not scroll the page around.
        this.fromDateTarget.focus({ preventScroll: true })
      }
    }
    this.load()
  }

  prefillRange(previousPeriod) {
    const days = typeof previousPeriod === "number" ? previousPeriod : 30
    this.state.from = this.fromDateTarget.value = isoDaysAgo(days)
    this.state.to = this.toDateTarget.value = isoDaysAgo(0)
  }

  // Custom period: two date fields; refetch as soon as a start date exists.
  setRange() {
    this.state.from = this.fromDateTarget.value || null
    this.state.to = this.toDateTarget.value || null
    if (this.state.from) this.load()
  }

  toggleSource() {
    const checked = this.sourceBoxTargets.filter((b) => b.checked).map((b) => b.value)
    this.state.sources = RATE_PROVIDERS.filter((p) => checked.includes(p))
    this.state.sources.length ? this.load() : this.render()
  }

  // «Повторить» next to a failure message repeats exactly that request.
  retrySummary() { this.loadSummary() }
  retrySeries() { this.load() }
  retryForecasts() { this.loadForecasts() }

  // ----- data -----

  // Cards, converter rates and the empty-database flag — one request, and the
  // switches above stay usable while it is in flight.
  async loadSummary() {
    this.summaryAbort?.abort()
    this.summaryAbort = new AbortController()
    try {
      const response = await fetch("/dashboard/data", {
        signal: this.summaryAbort.signal,
        headers: { Accept: "application/json" }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.summary = await response.json()
      this.emptyNoticeTarget.hidden = !this.summary.empty
      this.converterTarget.setAttribute("data-converter-rates-value", JSON.stringify(this.summary.rates))
      this.renderCards()
      this.renderForecastCard()
    } catch (error) {
      if (error.name === "AbortError") return
      this.cardSlotTargets.forEach(dropSkeleton)
      this.cardSlotTargets[0].innerHTML =
        `<div class="load-error"><span>Не удалось загрузить курсы</span>${retryButton("retrySummary")}</div>`
    }
  }

  // Fetches the series for the current state and re-renders. A failed fetch
  // keeps the previous data on screen and reports the problem in the status line.
  async load() {
    const params = new URLSearchParams({ currency: this.state.currency, providers: this.providers().join(",") })
    const { from, to } = this.range()
    if (from) params.set("from", from)
    if (to) params.set("to", to)
    this.abortController?.abort()
    this.abortController = new AbortController()
    this.render()
    try {
      const response = await fetch(`/series?${params}`, {
        signal: this.abortController.signal,
        headers: { Accept: "application/json" }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.payload = await response.json()
      this.render()
    } catch (error) {
      if (error.name === "AbortError") return
      this.revealChart()
      this.statusTarget.innerHTML =
        `<span>Не удалось загрузить данные${this.payload ? " — показаны последние загруженные" : ""}</span>` +
        retryButton("retrySeries")
    }
  }

  // Points of one provider as loaded for the current currency and period.
  points(provider) {
    return this.payload?.series?.[provider]?.points || []
  }

  total(provider) {
    return this.payload?.series?.[provider]?.total || 0
  }

  providers() {
    return this.state.sources
  }

  // {from, to} of the selected period; "all" means no bounds at all.
  range() {
    if (this.state.period === "all") return {}
    if (this.state.period === "custom") return { from: this.state.from, to: this.state.to }
    return { from: isoDaysAgo(this.state.period) }
  }

  // The forecast teaser needs one snapshot per source, nothing more —
  // GET /forecasts/data?latest=1 returns exactly that. The full history
  // lives on the /forecasts page.
  async loadForecasts() {
    this.forecastAbort?.abort()
    this.forecastAbort = new AbortController()
    try {
      const response = await fetch(`/forecasts/data?currency=${this.state.currency}&latest=1`, {
        signal: this.forecastAbort.signal,
        headers: { Accept: "application/json" }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.forecastPayload = await response.json()
      this.renderForecastCard()
    } catch (error) {
      if (error.name === "AbortError") return
      this.forecastPayload = null
      fadeIn(this.forecastTarget)
      this.forecastTarget.innerHTML =
        `<div class="load-error"><span>Не удалось загрузить прогноз</span>${retryButton("retryForecasts")}</div>`
    }
  }

  latestRun(provider) {
    return this.forecastPayload?.series?.[provider]?.runs?.at(-1) || null
  }

  // ----- render -----

  render() {
    this.renderControls()
    this.renderChart()
    if (!this.payload) return // still loading: the skeletons keep the boxes

    this.renderLegend()
    this.renderDiverge()
    this.renderStatus()
    this.renderTable()
    this.renderForecastCard()
  }

  // Everything that needs no data at all — drawn immediately on connect so the
  // switches answer clicks while the first requests are still in flight.
  renderControls() {
    this.cardTargets.forEach((c) => c.setAttribute("aria-pressed", String(c.dataset.currency === this.state.currency)))
    this.segTargets.forEach((b) => b.setAttribute("aria-pressed", String(String(this.state[b.dataset.key]) === b.dataset.value)))
    this.sourceBoxTargets.forEach((b) => (b.checked = this.state.sources.includes(b.value)))
  }

  // Each card drops into its own slot, crossfading over the skeleton that held
  // the box — so the grid never jumps when the summary lands.
  renderCards() {
    const byCode = Object.fromEntries(this.summary.cards.map((c) => [c.code, c]))
    this.cardSlotTargets.forEach((slot) => {
      const card = byCode[slot.dataset.currency]
      if (!card || slot.dataset.swapped) return
      slot.insertAdjacentHTML("beforeend", this.cardHtml(card))
      crossfade(slot)
    })
    this.renderControls()
  }

  cardHtml(card) {
    const trend = trendClass(card.delta)
    const delta = card.delta == null
      ? `<span>нет данных за прошлый день</span>`
      : `${arrow(card.delta < 0 ? "down" : "up")}<span>${signed(card.delta)}</span>` +
        `<span>${card.pct == null ? "—" : signed(card.pct, "%")}</span>`
    const body = card.value == null
      ? `<div class="ccard__empty">Нет данных</div>`
      : `<div class="ccard__spark ${trend}">${sparkline(card.spark || [])}</div>
         <div class="ccard__value num">${fmt2.format(card.value)}<small>₽</small></div>
         <div class="ccard__src">${PROVIDER_NAMES[card.provider] || card.provider} · ${dateRu(card.on_date)}</div>
         <div class="ccard__delta num ${trend}" title="Изменение за сутки">${delta}</div>`

    return `<button type="button" class="card ccard swap__content" data-dashboard-target="card"
              data-currency="${card.code}" data-action="dashboard#selectCurrency" aria-pressed="false">
        <div class="ccard__head">
          <span class="ccard__sym" aria-hidden="true">${SYMBOLS[card.code] || card.code}</span>
          <div>
            <div class="ccard__code">${card.code}</div>
            <div class="ccard__name">${card.name}</div>
          </div>
        </div>${body}</button>`
  }

  // Spread between sources on the most recent date at least two of them share.
  renderDiverge() {
    fadeIn(this.divergeTarget)
    const withData = this.providers().filter((p) => this.points(p).length)
    if (withData.length < 2) {
      const only = withData.length === 1 ? ` — данные только от одного источника (${PROVIDER_NAMES[withData[0]]})` : ""
      this.divergeTarget.innerHTML = withData.length ? `<span>Расхождение не посчитать${only}</span>` : ""
      return
    }

    const byDate = {}
    withData.forEach((p) => this.points(p).forEach(([d, v]) => ((byDate[d] ||= {})[p] = v)))
    const common = Object.keys(byDate).filter((d) => Object.keys(byDate[d]).length >= 2).sort().at(-1)
    if (!common) {
      this.divergeTarget.innerHTML = `<span>Расхождение не посчитать — у источников нет общих дат в этом периоде</span>`
      return
    }

    const entries = Object.entries(byDate[common])
    const values = entries.map(([, v]) => v)
    const spread = Math.max(...values) - Math.min(...values)
    const pct = spread / Math.min(...values) * 100
    const detail = entries.map(([p, v]) => `${PROVIDER_NAMES[p]} ${fmtRub.format(v)}`).join(" · ")
    this.divergeTarget.innerHTML =
      `<span>Расхождение на ${dateRu(common)}: <b>${fmtRub.format(spread)} ₽ · ${fmtPct.format(pct)}%</b></span>` +
      `<span class="dot">${detail}</span>`
  }

  // Compact teaser instead of the old forecast lines: what each source
  // predicts for the nearest date both cover; when the horizons don't
  // overlap, each source shows its own nearest point. Details on /forecasts.
  renderForecastCard() {
    // The teaser only trusts a payload for the currency on screen; until then
    // its skeleton stays put.
    if (this.forecastPayload?.currency !== this.state.currency) return

    fadeIn(this.forecastTarget)
    const today = new Date().toISOString().slice(0, 10)
    const future = (provider) => (this.latestRun(provider)?.points || []).filter(([d]) => d > today)
    const outlook = { apecon: future("apecon"), internal: future("internal") }
    const foot = `<div class="panel__foot"><span class="panel__note">Не является инвестиционной рекомендацией</span>` +
      `<a class="more-link" href="/forecasts">Подробнее о прогнозах →</a></div>`

    if (!outlook.apecon.length && !outlook.internal.length) {
      this.forecastTarget.innerHTML = `<p class="panel__note">Прогнозов для ${this.state.currency} пока нет.</p>${foot}`
      return
    }

    const apeconDates = new Set(outlook.apecon.map(([d]) => d))
    const common = outlook.internal.map(([d]) => d).find((d) => apeconDates.has(d))
    const head = common
      ? `<div class="panel__label">${this.state.currency} на ${dateRu(common)} — ближайшая дата, которую покрывают оба источника</div>`
      : `<div class="panel__label">${this.state.currency} — горизонты источников не пересекаются, у каждого своя ближайшая дата</div>`

    // Against the rate the currency card shows right now.
    const current = this.summary?.rates?.[this.state.currency]
    const delta = (value) => {
      if (!current?.value) return ""
      const diff = value - current.value
      const cls = diff > 0 ? "is-up" : diff < 0 ? "is-down" : "is-flat"
      const sign = diff > 0 ? "+" : diff < 0 ? "−" : ""
      return `<div class="forecast-cell__delta ${cls}">` +
        `${sign}${fmt2.format(Math.abs(diff))} ₽ · ${sign}${fmtPct.format(Math.abs(diff / current.value * 100))}% к текущему курсу</div>`
    }

    const cells = ["apecon", "internal"].flatMap((p) => {
      if (!outlook[p].length) return []
      const [date, value] = common ? outlook[p].find(([d]) => d === common) : outlook[p][0]
      const swatch = p === "apecon" ? " legend__swatch--apecon" : ""
      return [`
        <div class="forecast-cell">
          <div class="panel__label"><span class="legend__swatch legend__swatch--dashed${swatch}"></span>` +
            `${PROVIDER_NAMES[p]}${common ? "" : ` · ${dateRu(date)}`}</div>
          <div class="panel__big">${fmtRub.format(value)} ₽</div>
          ${delta(value)}
        </div>`]
    })

    this.forecastTarget.innerHTML = `${head}<div class="forecast-cells">${cells.join("")}</div>${foot}`
  }

  renderLegend() {
    fadeIn(this.legendTarget)
    const swatch = { cbr: "", erapi: "legend__swatch--alt", currencyapi: "legend__swatch--alt2", apecon: "legend__swatch--apecon" }
    this.legendTarget.innerHTML = this.providers().map((p) =>
      `<span class="legend__item"><span class="legend__swatch ${swatch[p]}"></span>${PROVIDER_NAMES[p]} · ${this.total(p)} тчк</span>`).join("")
  }

  renderTable() {
    fadeIn(this.tbodyTarget)
    const shown = this.providers().filter((p) => this.state.tableSource === "all" || p === this.state.tableSource)
    // Day-over-day change is computed inside each provider's own series.
    const rows = shown.flatMap((p) => {
      const pts = this.points(p)
      return pts.map(([d, v], i) => ({ d, v, p, delta: i > 0 ? v - pts[i - 1][1] : null, prev: i > 0 ? pts[i - 1][1] : null }))
    })
    rows.sort((a, b) => (a.d < b.d ? 1 : a.d > b.d ? -1 : a.p.localeCompare(b.p)))

    const visible = rows.slice(0, this.state.rows)
    if (!visible.length) {
      this.tbodyTarget.innerHTML = `<tr><td colspan="5" class="table-empty">Нет данных за выбранный период</td></tr>`
      return
    }

    const cls = (x) => (x == null || x === 0 ? "is-flat" : x > 0 ? "is-up" : "is-down")
    const sign = (x, f) => (x > 0 ? "+" : x < 0 ? "−" : "") + f.format(Math.abs(x))
    this.tbodyTarget.innerHTML = visible.map((r) => `
      <tr>
        <td>${dateRu(r.d)}</td>
        <td class="num">${fmtRub.format(r.v)}</td>
        <td class="num ${cls(r.delta)}">${r.delta == null ? "—" : sign(r.delta, fmtRub)}</td>
        <td class="num ${cls(r.delta)}">${r.delta == null ? "—" : sign(r.delta / r.prev * 100, fmtPct) + "%"}</td>
        <td class="muted">${PROVIDER_NAMES[r.p]}</td>
      </tr>`).join("")
  }

  // Fades the canvas in over its skeleton; after that the chart is just there.
  revealChart() {
    crossfade(this.chartWrapTarget)
  }

  renderChart() {
    if (!this.payload) return // no chart before real data: the entry animates once
    if (typeof Chart === "undefined") return this.revealChart() // script missing — keep the page alive

    const colors = { cbr: cssVar("--accent"), erapi: cssVar("--text-3"), currencyapi: cssVar("--text-2"), apecon: cssVar("--accent-2") }
    const text3 = cssVar("--text-3")
    const line = cssVar("--line")
    const provs = this.providers()
    const series = Object.fromEntries(provs.map((p) => [p, this.points(p)]))
    const labels = [...new Set(provs.flatMap((p) => series[p].map(([d]) => d)))].sort()

    const datasets = provs.map((p) => {
      const byDate = Object.fromEntries(series[p])
      return {
        label: PROVIDER_NAMES[p],
        data: labels.map((d) => byDate[d] ?? null),
        borderColor: colors[p],
        borderWidth: p === "cbr" ? 2 : 1.5,
        tension: 0.25,
        spanGaps: true,
        fill: provs.length === 1,
        backgroundColor: (ctx) => this.gradient(ctx.chart, colors[p]),
        pointRadius: 0,
        pointHoverRadius: 4,
        pointHoverBackgroundColor: colors[p],
        pointHoverBorderColor: cssVar("--card"),
        pointHoverBorderWidth: 2
      }
    })

    // Tick format follows the range: days for short spans, month.year for a few
    // years, the year alone for decades — otherwise labels repeat or lose meaning.
    const yearSpan = labels.length ? Number(labels.at(-1).slice(0, 4)) - Number(labels[0].slice(0, 4)) : 0
    const tickLabel = (iso) =>
      yearSpan >= 10 ? iso.slice(0, 4) : yearSpan >= 2 ? iso.slice(5, 7) + "." + iso.slice(0, 4) : dateShort(iso)

    const data = { labels, datasets }
    const options = {
      responsive: true,
      maintainAspectRatio: false,
      animation: entryAnimation(),
      interaction: { mode: "index", intersect: false },
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: cssVar("--card"),
          titleColor: cssVar("--text"),
          bodyColor: cssVar("--text-2"),
          borderColor: line,
          borderWidth: 1,
          padding: 10,
          displayColors: provs.length > 1,
          titleFont: { family: "JetBrains Mono", size: 12 },
          bodyFont: { family: "JetBrains Mono", size: 12 },
          callbacks: {
            title: (items) => dateRu(items[0].label),
            label: (item) => `${item.dataset.label}: ${fmtRub.format(item.parsed.y)} ₽`
          }
        }
      },
      scales: {
        x: {
          grid: { display: false },
          border: { color: line },
          ticks: { color: text3, maxTicksLimit: 8, maxRotation: 0, font: { family: "JetBrains Mono", size: 11 }, callback: (v) => tickLabel(labels[v]) }
        },
        y: {
          position: "right",
          grid: { color: line, drawTicks: false },
          border: { display: false, dash: [3, 3] },
          ticks: { color: text3, padding: 8, maxTicksLimit: 6, font: { family: "JetBrains Mono", size: 11 }, callback: (v) => fmtRub.format(v) }
        }
      }
    }

    if (upsertChart(this.charts, "main", this.canvasTarget, data, options)) this.revealChart()
  }

  // Vertical fill from ~18% opacity at the top to 0 at the bottom.
  gradient(chart, color) {
    const { ctx, chartArea } = chart
    if (!chartArea) return "transparent"
    const g = ctx.createLinearGradient(0, chartArea.top, 0, chartArea.bottom)
    g.addColorStop(0, color + "2E")
    g.addColorStop(1, color + "00")
    return g
  }

  renderStatus() {
    fadeIn(this.statusTarget)
    const provs = this.providers()
    const withData = provs.filter((p) => this.points(p).length)
    if (!withData.length) {
      this.statusTarget.innerHTML = `<span>Нет данных по ${this.state.currency}</span>`
      return
    }

    const parts = [`Источники: ${withData.map((p) => PROVIDER_NAMES[p]).join(", ")}`]
    const lastDate = withData.map((p) => this.points(p).at(-1)[0]).sort().at(-1)
    parts.push(`обновлено ${dateRu(lastDate)}`)
    this.statusTarget.innerHTML = parts.map((t, i) => `<span class="${i ? "dot" : ""}">${t}</span>`).join("")
  }
}
