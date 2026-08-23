import { Controller } from "@hotwired/stimulus"

const PROVIDER_NAMES = { cbr: "ЦБ РФ", erapi: "ER-API" }
const fmtRub = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 4 })
const fmtPct = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 1, maximumFractionDigits: 2 })

const dateRu = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7) + "." + iso.slice(0, 4)
const dateShort = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7)
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()

// Dashboard state lives here: selected currency / period / source.
// All series for the last 90 days are embedded in the page, so every switch
// is a pure client-side re-render — no round trips.
export default class extends Controller {
  static targets = ["card", "canvas", "status"]
  static values = { series: Object }

  connect() {
    this.state = { currency: "USD", days: 30, source: "cbr" }
    this.onTheme = () => this.render()
    window.addEventListener("theme:change", this.onTheme)
    this.render()
  }

  disconnect() {
    window.removeEventListener("theme:change", this.onTheme)
    this.chart?.destroy()
  }

  // ----- actions -----

  selectCurrency(event) {
    this.state.currency = event.currentTarget.dataset.currency
    this.render()
  }

  // ----- data -----

  // Points of one provider for the current currency, limited to the selected period.
  points(provider) {
    const all = this.seriesValue[this.state.currency]?.[provider] || []
    const from = new Date()
    from.setDate(from.getDate() - this.state.days)
    const iso = from.toISOString().slice(0, 10)
    return all.filter(([d]) => d >= iso)
  }

  providers() {
    return this.state.source === "both" ? ["cbr", "erapi"] : [this.state.source]
  }

  // ----- render -----

  render() {
    this.cardTargets.forEach((c) => c.setAttribute("aria-pressed", String(c.dataset.currency === this.state.currency)))
    this.renderChart()
    this.renderStatus()
  }

  renderChart() {
    const colors = { cbr: cssVar("--accent"), erapi: cssVar("--text-3") }
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
        borderWidth: 2,
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
    const cur = this.state.currency
    const all = this.seriesValue[cur] || {}
    const last = (p) => all[p]?.at(-1)
    const cbr = last("cbr"), erapi = last("erapi")
    const primary = this.state.source === "erapi" ? "erapi" : "cbr"
    const main = last(primary) || last(primary === "cbr" ? "erapi" : "cbr")
    const parts = []

    if (!main) {
      this.statusTarget.innerHTML = `<span>Нет данных по ${cur}</span>`
      return
    }

    parts.push(this.state.source === "both" ? "Источники: ЦБ РФ и ER-API" : `Источник: ${PROVIDER_NAMES[primary]}`)
    parts.push(`обновлено ${dateRu(main[0])}`)
    if (cbr && erapi) {
      const diff = Math.abs(cbr[1] - erapi[1]) / cbr[1] * 100
      const other = this.state.source === "erapi" ? "ЦБ РФ" : "ER-API"
      parts.push(`расхождение с ${other} ${fmtPct.format(diff)}%`)
    }
    this.statusTarget.innerHTML = parts.map((t, i) => `<span class="${i ? "dot" : ""}">${t}</span>`).join("")
  }
}
