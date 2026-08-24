import { Controller } from "@hotwired/stimulus"

const PROVIDER_NAMES = { cbr: "ЦБ РФ", erapi: "ER-API", currencyapi: "Currency API", apecon: "АПЭКОН", internal: "Rateflow" }
const RATE_PROVIDERS = ["cbr", "erapi", "currencyapi", "apecon"]
const FORECAST_NAMES = { apecon: "Прогноз АПЭКОН", internal: "Прогноз Rateflow" }
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
  static targets = ["card", "seg", "canvas", "legend", "status", "diverge", "tbody", "trend",
                    "range", "fromDate", "toDate", "sourceBox", "forecastMeta",
                    "playback", "playBtn", "playSlider", "playLabel"]
  static values = { initial: Object }

  connect() {
    this.state = {
      currency: "USD", period: 30, from: null, to: null,
      sources: [...RATE_PROVIDERS], tableSource: "all", rows: 10, forecast: "both"
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
    this.stopPlay()
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

    if (key === "forecast") {
      this.resetPlayback()
      return this.render()
    }
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

  // Forecast snapshots come from GET /forecasts: every stored version for the
  // current currency, both providers at once. Computation happens server-side;
  // the browser only picks a snapshot and draws it.
  async loadForecasts() {
    this.forecastAbort?.abort()
    this.forecastAbort = new AbortController()
    try {
      const response = await fetch(`/forecasts?currency=${this.state.currency}`, {
        signal: this.forecastAbort.signal,
        headers: { Accept: "application/json" }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.forecastPayload = await response.json()
      this.resetPlayback()
      this.render()
    } catch (error) {
      if (error.name !== "AbortError") this.forecastPayload = null
    }
  }

  runs(provider) {
    return this.forecastPayload?.series?.[provider]?.runs || []
  }

  // The snapshot currently on the chart — the latest one until playback says otherwise.
  activeRun(provider) {
    const runs = this.runs(provider)
    if (!runs.length) return null
    if (provider === this.playbackProvider() && this.runIndex != null) return runs[Math.min(this.runIndex, runs.length - 1)]
    return runs.at(-1)
  }

  // ----- playback of forecast versions -----

  // The slider walks the snapshots of one provider; in "both" mode АПЭКОН is
  // the one being scrubbed, the internal line stays at its latest version.
  playbackProvider() {
    return this.state.forecast === "internal" ? "internal" : "apecon"
  }

  resetPlayback() {
    this.stopPlay()
    this.runIndex = null
  }

  scrub(event) {
    this.stopPlay()
    this.runIndex = Number(event.target.value)
    this.render()
  }

  togglePlay() {
    this.playTimer ? this.stopPlay() : this.startPlay()
    this.renderPlayback()
  }

  // Steps through versions in a loop, ~600 ms per snapshot.
  startPlay() {
    const total = this.runs(this.playbackProvider()).length
    if (total < 2 || this.reducedMotion()) return
    this.playTimer = setInterval(() => {
      const runs = this.runs(this.playbackProvider())
      this.runIndex = ((this.runIndex ?? runs.length - 1) + 1) % runs.length
      this.render()
    }, 600)
  }

  stopPlay() {
    if (this.playTimer) clearInterval(this.playTimer)
    this.playTimer = null
  }

  reducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }

  renderPlayback() {
    const runs = this.runs(this.playbackProvider())
    this.playbackTarget.hidden = runs.length < 2
    if (runs.length < 2) {
      this.stopPlay()
      return
    }
    const index = this.runIndex != null ? Math.min(this.runIndex, runs.length - 1) : runs.length - 1
    this.playSliderTarget.max = runs.length - 1
    this.playSliderTarget.value = index
    this.playLabelTarget.textContent =
      `${dateRu(runs[index].captured_at.slice(0, 10))} · версия ${index + 1} из ${runs.length}`
    this.playBtnTarget.hidden = this.reducedMotion()
    this.playBtnTarget.textContent = this.playTimer ? "⏸" : "▶"
    this.playBtnTarget.setAttribute("aria-label", this.playTimer ? "Пауза" : "Проиграть историю прогноза")
  }

  forecastProviders() {
    return this.state.forecast === "both" ? ["apecon", "internal"] : [this.state.forecast]
  }

  // Latest actual [date, value] by provider priority — the anchor point that
  // joins the dashed forecast line to the solid history line.
  lastActual() {
    const provider = RATE_PROVIDERS.find((p) => this.points(p).length)
    return provider ? this.points(provider).at(-1) : null
  }

  // ----- render -----

  render() {
    this.cardTargets.forEach((c) => c.setAttribute("aria-pressed", String(c.dataset.currency === this.state.currency)))
    this.segTargets.forEach((b) => b.setAttribute("aria-pressed", String(String(this.state[b.dataset.key]) === b.dataset.value)))
    this.sourceBoxTargets.forEach((b) => (b.checked = this.state.sources.includes(b.value)))
    this.renderChart()
    this.renderPlayback()
    this.renderLegend()
    this.renderForecastMeta()
    this.renderDiverge()
    this.renderStatus()
    this.renderTable()
    this.renderTrend()
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

  // The trend panel shows the latest server-computed internal snapshot; the
  // browser no longer runs the model itself.
  renderTrend() {
    const run = this.runs("internal").at(-1)
    const anchor = this.lastActual()
    if (!run || !run.points.length || !anchor) {
      this.trendTarget.innerHTML = `<p class="panel__note">Недостаточно данных для прогноза Rateflow.</p>`
      return
    }
    const [endDate, end] = [run.points.at(-1)[0], run.points.at(-1)[1]]
    const delta = end - anchor[1]
    const cls = delta > 0 ? "is-up" : delta < 0 ? "is-down" : "is-flat"
    const sign = delta > 0 ? "+" : delta < 0 ? "−" : ""
    this.trendTarget.innerHTML = `
      <div class="panel__row">
        <div>
          <div class="panel__label">Ожидаемый курс на ${dateRu(endDate)}</div>
          <div class="panel__big">${fmtRub.format(end)} ₽</div>
        </div>
        <div>
          <div class="panel__label">К последнему значению</div>
          <div class="panel__value ${cls}">${sign}${fmtRub.format(Math.abs(delta))} ₽ · ${sign}${fmtPct.format(Math.abs(delta / anchor[1] * 100))}%</div>
        </div>
      </div>
      <p class="panel__note">
        <b>Метод:</b> скользящее среднее (окно 7), считается на сервере при каждом обновлении данных; снимок от ${dateRu(run.captured_at.slice(0, 10))}, ${run.points.length} точек (пунктир на графике).<br>
        <b>Точность:</b> сбывшиеся снимки сравниваются с фактом ЦБ РФ — блок «Точность прогнозов» ниже.<br>
        Это статистическая экстраполяция, а не инвестиционная рекомендация.
      </p>`
  }

  // Chart caption: which snapshots are on screen right now.
  renderForecastMeta() {
    const parts = this.forecastProviders().flatMap((provider) => {
      const run = this.activeRun(provider)
      if (!run) return []
      const version = this.runs(provider).indexOf(run) + 1
      return [`${FORECAST_NAMES[provider]}: снимок от ${dateRu(run.captured_at.slice(0, 10))} (${version} из ${this.runs(provider).length}) · ${run.points.length} тчк · до ${dateRu(run.points.at(-1)[0])}`]
    })
    if (!parts.length) {
      this.forecastMetaTarget.innerHTML = `<span>Прогнозов для ${this.state.currency} пока нет</span>`
      return
    }
    parts.push("не является инвестиционной рекомендацией")
    this.forecastMetaTarget.innerHTML = parts.map((t, i) => `<span class="${i ? "dot" : ""}">${t}</span>`).join("")
  }

  renderLegend() {
    const swatch = { cbr: "", erapi: "legend__swatch--alt", currencyapi: "legend__swatch--alt2", apecon: "legend__swatch--apecon" }
    const items = this.providers().map((p) =>
      `<span class="legend__item"><span class="legend__swatch ${swatch[p]}"></span>${PROVIDER_NAMES[p]} · ${this.total(p)} тчк</span>`)
    this.forecastProviders().forEach((p) => {
      if (!this.activeRun(p)) return
      const cls = p === "apecon" ? "legend__swatch--apecon" : ""
      items.push(`<span class="legend__item"><span class="legend__swatch legend__swatch--dashed ${cls}"></span>${FORECAST_NAMES[p]}</span>`)
    })
    this.legendTarget.innerHTML = items.join("")
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
    const history = [...new Set(provs.flatMap((p) => series[p].map(([d]) => d)))].sort()
    const lines = this.forecastLines(history)
    const labels = [...new Set([...history, ...lines.flatMap((l) => l.points.map(([d]) => d))])].sort()

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

    const anchor = this.lastActual()
    for (const line of lines) {
      const color = line.provider === "apecon" ? cssVar("--accent-2") : cssVar("--accent")
      const byDate = Object.fromEntries(line.points.map(([d, v]) => [d, v]))
      // Dashed continuation joins the actual line when the forecast is purely in the future.
      if (anchor && line.points[0][0] > anchor[0]) byDate[anchor[0]] = anchor[1]
      datasets.push({
        label: FORECAST_NAMES[line.provider],
        data: labels.map((d) => byDate[d] ?? null),
        borderColor: color,
        borderWidth: 2,
        borderDash: [5, 4],
        tension: 0.25,
        spanGaps: true,
        fill: false,
        pointRadius: line.provider === "apecon" ? 2.5 : 0,
        pointBackgroundColor: color,
        pointBorderColor: color,
        pointHoverRadius: 4,
        pointHoverBackgroundColor: color,
        pointHoverBorderColor: cssVar("--card"),
        pointHoverBorderWidth: 2
      })

      // АПЭКОН publishes a min–max range — drawn as a shaded corridor
      // between two invisible lines (fill: "+1" spans to the next dataset).
      const ranged = line.points.filter((p) => p[2] != null && p[3] != null)
      if (ranged.length > 1) {
        const corridor = [3, 2].map((i) => {
          const edge = Object.fromEntries(ranged.map((p) => [p[0], p[i]]))
          return labels.map((d) => edge[d] ?? null)
        })
        datasets.push(
          { label: "_high", data: corridor[0], borderWidth: 0, pointRadius: 0, pointHoverRadius: 0,
            tension: 0.25, spanGaps: true, fill: "+1", backgroundColor: color + "24" },
          { label: "_low", data: corridor[1], borderWidth: 0, pointRadius: 0, pointHoverRadius: 0,
            tension: 0.25, spanGaps: true, fill: false }
        )
      }
    }

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
          displayColors: provs.length > 1 || lines.length > 0,
          titleFont: { family: "JetBrains Mono", size: 12 },
          bodyFont: { family: "JetBrains Mono", size: 12 },
          filter: (item) => !item.dataset.label.startsWith("_"),
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

  // Forecast points worth drawing: those inside the visible window, extended
  // forward by at most the width of the shown history — otherwise a five-year
  // monthly forecast would squash a 30-day chart into a sliver.
  forecastLines(history) {
    if (!history.length) return []
    const first = history[0]
    const last = history.at(-1)
    const spanMs = Math.max(new Date(last) - new Date(first), 30 * 86400000)
    const maxIso = new Date(new Date(last).getTime() + spanMs).toISOString().slice(0, 10)
    return this.forecastProviders().flatMap((provider) => {
      const run = this.activeRun(provider)
      const points = run ? run.points.filter(([d]) => d >= first && d <= maxIso) : []
      return points.length ? [{ provider, run, points }] : []
    })
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
