import { Controller } from "@hotwired/stimulus"

const PROVIDER_NAMES = { cbr: "ЦБ РФ", erapi: "ER-API", currencyapi: "Currency API", apecon: "АПЭКОН", internal: "Rateflow" }
const RATE_PROVIDERS = ["cbr", "erapi", "currencyapi", "apecon"]
const fmtRub = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 4 })
const fmtPct = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 1, maximumFractionDigits: 2 })

const dateRu = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7) + "." + iso.slice(0, 4)
const dateShort = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7)
const isoDaysAgo = (days) => {
  const d = new Date()
  d.setDate(d.getDate() - days)
  return d.toISOString().slice(0, 10)
}
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()

// Dashboard state lives here: selected currency / period / sources.
// Only the initial payload is embedded in the page; every switch fetches
// the needed series from GET /series.
export default class extends Controller {
  static targets = ["card", "seg", "canvas", "legend", "status", "diverge", "tbody", "forecast",
                    "range", "fromDate", "toDate", "sourceBox"]
  static values = { initial: Object }

  connect() {
    this.state = {
      currency: "USD", period: 30, from: null, to: null,
      sources: [...RATE_PROVIDERS], tableSource: "all", rows: 10
    }
    this.payload = this.initialValue
    this.forecastPayload = null
    this.onTheme = () => this.render()
    window.addEventListener("theme:change", this.onTheme)
    this.render()
    this.loadForecasts()
  }

  disconnect() {
    window.removeEventListener("theme:change", this.onTheme)
    this.abortController?.abort()
    this.forecastAbort?.abort()
    this.chart?.destroy()
  }

  // ----- actions -----

  selectCurrency(event) {
    this.state.currency = event.currentTarget.dataset.currency
    this.load()
    this.loadForecasts()
  }

  setOption(event) {
    const { key, value } = event.currentTarget.dataset
    const num = Number(value)
    this.state[key] = Number.isNaN(num) ? value : num

    if (key === "rows" || key === "tableSource") return this.render()
    if (key === "period") {
      this.rangeTarget.hidden = this.state.period !== "custom"
      // A custom range only makes sense once at least the start date is set.
      if (this.state.period === "custom" && !this.state.from) return this.render()
    }
    this.load()
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

  // ----- data -----

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
      this.statusTarget.innerHTML = `<span>Не удалось загрузить данные — показаны последние загруженные</span>`
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
      if (error.name !== "AbortError") this.forecastPayload = null
    }
  }

  latestRun(provider) {
    return this.forecastPayload?.series?.[provider]?.runs?.at(-1) || null
  }

  reducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }

  // ----- render -----

  render() {
    this.cardTargets.forEach((c) => c.setAttribute("aria-pressed", String(c.dataset.currency === this.state.currency)))
    this.segTargets.forEach((b) => b.setAttribute("aria-pressed", String(String(this.state[b.dataset.key]) === b.dataset.value)))
    this.sourceBoxTargets.forEach((b) => (b.checked = this.state.sources.includes(b.value)))
    this.renderChart()
    this.renderLegend()
    this.renderDiverge()
    this.renderStatus()
    this.renderTable()
    this.renderForecastCard()
  }

  // Spread between sources on the most recent date at least two of them share.
  renderDiverge() {
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
    // The teaser only trusts a payload for the currency on screen.
    if (this.forecastPayload?.currency !== this.state.currency) {
      this.forecastTarget.innerHTML = `<p class="panel__note">Загрузка прогноза…</p>`
      return
    }
    const today = new Date().toISOString().slice(0, 10)
    const future = (provider) => (this.latestRun(provider)?.points || []).filter(([d]) => d > today)
    const outlook = { apecon: future("apecon"), internal: future("internal") }
    const more = `<p class="panel__note"><a class="more-link" href="/forecasts">Подробнее о прогнозах →</a></p>`

    if (!outlook.apecon.length && !outlook.internal.length) {
      this.forecastTarget.innerHTML = `<p class="panel__note">Прогнозов для ${this.state.currency} пока нет.</p>${more}`
      return
    }

    const apeconDates = new Set(outlook.apecon.map(([d]) => d))
    const common = outlook.internal.map(([d]) => d).find((d) => apeconDates.has(d))
    const head = common
      ? `<div class="panel__label">На ${dateRu(common)} — ближайшую дату, которую покрывают оба источника</div>`
      : `<div class="panel__label">Горизонты источников сейчас не пересекаются — у каждого его ближайшая дата</div>`

    const cells = ["apecon", "internal"].flatMap((p) => {
      if (!outlook[p].length) return []
      const [date, value] = common ? outlook[p].find(([d]) => d === common) : outlook[p][0]
      return [`
        <div>
          <div class="panel__label">${PROVIDER_NAMES[p]}${common ? "" : ` · ${dateRu(date)}`}</div>
          <div class="panel__big">${fmtRub.format(value)} ₽</div>
        </div>`]
    })

    this.forecastTarget.innerHTML =
      `${head}<div class="panel__row">${cells.join("")}</div>` +
      `<p class="panel__note">не является инвестиционной рекомендацией</p>${more}`
  }

  renderLegend() {
    const swatch = { cbr: "", erapi: "legend__swatch--alt", currencyapi: "legend__swatch--alt2", apecon: "legend__swatch--apecon" }
    this.legendTarget.innerHTML = this.providers().map((p) =>
      `<span class="legend__item"><span class="legend__swatch ${swatch[p]}"></span>${PROVIDER_NAMES[p]} · ${this.total(p)} тчк</span>`).join("")
  }

  renderTable() {
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

  renderChart() {
    if (typeof Chart === "undefined") return // chart script missing — keep the rest of the page alive

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
      animation: { duration: this.reducedMotion() ? 0 : 250 },
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

    if (this.chart) {
      this.chart.data = data
      this.chart.options = options
      this.chart.update()
    } else {
      this.chart = new Chart(this.canvasTarget, { type: "line", data, options })
    }
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
