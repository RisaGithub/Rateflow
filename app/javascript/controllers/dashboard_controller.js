import { Controller } from "@hotwired/stimulus"
import { forecast, backtest, nextDates, WINDOW, HORIZON } from "forecast"

const PROVIDER_NAMES = { cbr: "ЦБ РФ", erapi: "ER-API", currencyapi: "Currency API" }
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
  static targets = ["card", "seg", "canvas", "legend", "status", "tbody", "trend"]
  static values = { initial: Object }

  connect() {
    this.state = { currency: "USD", days: 30, source: "cbr", rows: 10 }
    this.payload = this.initialValue
    this.onTheme = () => this.render()
    window.addEventListener("theme:change", this.onTheme)
    this.render()
  }

  disconnect() {
    window.removeEventListener("theme:change", this.onTheme)
    this.abortController?.abort()
    this.chart?.destroy()
  }

  // ----- actions -----

  selectCurrency(event) {
    this.state.currency = event.currentTarget.dataset.currency
    this.load()
  }

  setOption(event) {
    const { key, value } = event.currentTarget.dataset
    this.state[key] = key === "days" || key === "rows" ? Number(value) : value
    key === "rows" ? this.render() : this.load()
  }

  // ----- data -----

  // Fetches the series for the current state and re-renders. A failed fetch
  // keeps the previous data on screen and reports the problem in the status line.
  async load() {
    const params = new URLSearchParams({
      currency: this.state.currency,
      providers: this.providers().join(","),
      from: isoDaysAgo(this.state.days)
    })
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
    return this.state.source === "both" ? ["cbr", "erapi"] : [this.state.source]
  }

  // Rolling-mean forecast for the first visible provider that has enough data.
  trend() {
    const provider = this.providers().find((p) => this.points(p).length >= WINDOW + 1)
    if (!provider) return null

    const all = this.points(provider)
    const values = all.map(([, v]) => v)
    const [from, last] = all.at(-1)
    return {
      provider, from, last,
      dates: nextDates(from, HORIZON),
      values: forecast(values),
      backtest: backtest(values)
    }
  }

  // ----- render -----

  render() {
    this.cardTargets.forEach((c) => c.setAttribute("aria-pressed", String(c.dataset.currency === this.state.currency)))
    this.segTargets.forEach((b) => b.setAttribute("aria-pressed", String(String(this.state[b.dataset.key]) === b.dataset.value)))
    this.renderChart()
    this.renderLegend()
    this.renderStatus()
    this.renderTable()
    this.renderTrend()
  }

  renderTrend() {
    const t = this.trend()
    if (!t) {
      this.trendTarget.innerHTML = `<p class="panel__note">Недостаточно данных: для тренда нужно хотя бы ${WINDOW + 1} точек.</p>`
      return
    }
    const end = t.values.at(-1)
    const delta = end - t.last
    const cls = delta > 0 ? "is-up" : delta < 0 ? "is-down" : "is-flat"
    const sign = delta > 0 ? "+" : delta < 0 ? "−" : ""
    const bt = t.backtest
    this.trendTarget.innerHTML = `
      <div class="panel__row">
        <div>
          <div class="panel__label">Ожидаемый курс через ${HORIZON} дн.</div>
          <div class="panel__big">${fmtRub.format(end)} ₽</div>
        </div>
        <div>
          <div class="panel__label">К последнему значению</div>
          <div class="panel__value ${cls}">${sign}${fmtRub.format(Math.abs(delta))} ₽ · ${sign}${fmtPct.format(Math.abs(delta / t.last * 100))}%</div>
        </div>
      </div>
      <p class="panel__note">
        <b>Метод:</b> скользящее среднее за ${WINDOW} точек по данным ${PROVIDER_NAMES[t.provider]}, продолжение на ${HORIZON} дней (пунктир на графике).<br>
        <b>Бэктест:</b> ${bt ? `средняя ошибка ${fmtRub.format(bt.mae)} ₽ (${fmtPct.format(bt.mape)}%) на ${bt.samples} исторических точках` : "недостаточно данных"}.<br>
        Это статистическая экстраполяция, а не инвестиционная рекомендация.
      </p>`
  }

  renderLegend() {
    const items = this.providers().map((p) =>
      `<span class="legend__item"><span class="legend__swatch ${p === "cbr" ? "" : "legend__swatch--alt"}"></span>${PROVIDER_NAMES[p]} · ${this.total(p)} тчк</span>`)
    if (this.trend()) items.push(`<span class="legend__item"><span class="legend__swatch legend__swatch--dashed"></span>Прогноз</span>`)
    this.legendTarget.innerHTML = items.join("")
  }

  renderTable() {
    // Day-over-day change is computed inside each provider's own series.
    const rows = this.providers().flatMap((p) => {
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
    const colors = { cbr: cssVar("--accent"), erapi: cssVar("--text-3"), currencyapi: cssVar("--text-2") }
    const text3 = cssVar("--text-3")
    const line = cssVar("--line")
    const provs = this.providers()
    const series = Object.fromEntries(provs.map((p) => [p, this.points(p)]))
    const history = [...new Set(provs.flatMap((p) => series[p].map(([d]) => d)))].sort()
    const trend = this.trend()
    const labels = trend ? history.concat(trend.dates) : history

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

    if (trend) {
      // Dashed continuation: starts at the last actual point so the lines join.
      const byDate = Object.fromEntries(trend.dates.map((d, i) => [d, trend.values[i]]))
      byDate[trend.from] = trend.last
      datasets.push({
        label: "Прогноз",
        data: labels.map((d) => byDate[d] ?? null),
        borderColor: colors.cbr,
        borderWidth: 2,
        borderDash: [5, 4],
        tension: 0.25,
        spanGaps: false,
        fill: false,
        pointRadius: 0,
        pointHoverRadius: 4,
        pointHoverBackgroundColor: colors.cbr,
        pointHoverBorderColor: cssVar("--card"),
        pointHoverBorderWidth: 2
      })
    }

    const data = { labels, datasets }
    const options = {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 250 },
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
          displayColors: provs.length > 1 || !!trend,
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
          ticks: { color: text3, maxTicksLimit: 8, maxRotation: 0, font: { family: "JetBrains Mono", size: 11 }, callback: (v) => dateShort(labels[v]) }
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
