import { Controller } from "@hotwired/stimulus"

const FORECAST_NAMES = { apecon: "Прогноз АПЭКОН", internal: "Прогноз Rateflow" }
const SOURCE_NAMES = { apecon: "АПЭКОН", internal: "Rateflow" }
// Facts cover the backtest span, so matured forecast horizons meet their CBR line.
const FACT_DAYS = 730
const fmtRub = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 4 })

const dateRu = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7) + "." + iso.slice(0, 4)
const dateShort = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7)
const isoDaysAgo = (days) => {
  const d = new Date()
  d.setDate(d.getDate() - days)
  return d.toISOString().slice(0, 10)
}
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()

// The Прогнозы page: one currency + source choice drives every block.
// Facts come from GET /series (CBR only), forecast snapshots from
// GET /forecasts/data; the browser only picks snapshots and draws them.
export default class extends Controller {
  static targets = ["seg", "mainCanvas", "playback", "playBtn", "playSlider", "playLabel",
                    "mainLegend", "mainStatus"]

  connect() {
    this.state = { currency: "USD", source: "both" }
    this.runIndex = null
    this.charts = {}
    this.facts = []
    this.payload = null
    this.onTheme = () => this.render()
    window.addEventListener("theme:change", this.onTheme)
    this.render()
    this.load()
  }

  disconnect() {
    window.removeEventListener("theme:change", this.onTheme)
    this.stopPlay()
    this.abort?.abort()
    Object.values(this.charts).forEach((c) => c.destroy())
  }

  // ----- actions -----

  setOption(event) {
    const { key, value } = event.currentTarget.dataset
    this.state[key] = value
    this.resetPlayback()
    key === "currency" ? this.load() : this.render()
  }

  // ----- data -----

  async load() {
    this.abort?.abort()
    this.abort = new AbortController()
    const { currency } = this.state
    try {
      const [facts, forecasts] = await Promise.all([
        this.fetchJson(`/series?currency=${currency}&providers=cbr&from=${isoDaysAgo(FACT_DAYS)}`),
        this.fetchJson(`/forecasts/data?currency=${currency}`)
      ])
      this.facts = facts.series?.cbr?.points || []
      this.payload = forecasts
      this.render()
    } catch (error) {
      if (error.name === "AbortError") return
      this.mainStatusTarget.innerHTML = `<span>Не удалось загрузить данные — попробуйте обновить страницу</span>`
    }
  }

  async fetchJson(url) {
    const response = await fetch(url, { signal: this.abort.signal, headers: { Accept: "application/json" } })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return response.json()
  }

  sources() {
    return this.state.source === "both" ? ["apecon", "internal"] : [this.state.source]
  }

  runs(provider) {
    return this.payload?.series?.[provider]?.runs || []
  }

  index(provider) {
    return this.payload?.series?.[provider]?.index || []
  }

  // The snapshot on the main chart — the latest one until playback says otherwise.
  activeRun(provider) {
    const runs = this.runs(provider)
    if (!runs.length) return null
    if (provider === this.playbackProvider() && this.runIndex != null) return runs[Math.min(this.runIndex, runs.length - 1)]
    return runs.at(-1)
  }

  colorOf(provider) {
    return provider === "apecon" ? cssVar("--accent-2") : cssVar("--accent")
  }

  // ----- playback of forecast versions -----

  // The slider walks one provider's snapshots; in "both" mode it takes the
  // provider with the longer history — that is where playback has a story.
  playbackProvider() {
    if (this.state.source !== "both") return this.state.source
    return this.runs("internal").length > this.runs("apecon").length ? "internal" : "apecon"
  }

  resetPlayback() {
    this.stopPlay()
    this.runIndex = null
  }

  scrub(event) {
    this.stopPlay()
    this.runIndex = Number(event.target.value)
    this.renderMain("none")
    this.renderPlayback()
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
      this.renderMain("none")
      this.renderPlayback()
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
      `${SOURCE_NAMES[this.playbackProvider()]} · ${dateRu(runs[index].captured_at.slice(0, 10))} · версия ${index + 1} из ${runs.length}`
    this.playBtnTarget.hidden = this.reducedMotion()
    this.playBtnTarget.textContent = this.playTimer ? "⏸" : "▶"
    this.playBtnTarget.setAttribute("aria-label", this.playTimer ? "Пауза" : "Проиграть историю прогноза")
  }

  // ----- render -----

  render() {
    this.segTargets.forEach((b) => b.setAttribute("aria-pressed", String(this.state[b.dataset.key] === b.dataset.value)))
    this.renderMain()
    this.renderPlayback()
    this.renderMainLegend()
    this.renderMainStatus()
  }

  // Block 1: the fact as a muted solid line, active snapshots dashed on top,
  // АПЭКОН's min–max range as a shaded corridor.
  renderMain(mode) {
    if (typeof Chart === "undefined") return

    const factColor = cssVar("--text-3")
    const lines = this.sources().flatMap((p) => {
      const run = this.activeRun(p)
      return run ? [{ provider: p, run }] : []
    })
    const labels = [...new Set([
      ...this.facts.map(([d]) => d),
      ...lines.flatMap((l) => l.run.points.map(([d]) => d))
    ])].sort()

    const factByDate = Object.fromEntries(this.facts)
    const datasets = [{
      label: "ЦБ РФ (факт)",
      data: labels.map((d) => factByDate[d] ?? null),
      borderColor: factColor,
      borderWidth: 1.5,
      tension: 0.25,
      spanGaps: true,
      fill: false,
      pointRadius: 0,
      pointHoverRadius: 4,
      pointHoverBackgroundColor: factColor,
      pointHoverBorderColor: cssVar("--card"),
      pointHoverBorderWidth: 2
    }]

    const anchor = this.facts.at(-1)
    for (const line of lines) {
      const color = this.colorOf(line.provider)
      const byDate = Object.fromEntries(line.run.points.map(([d, v]) => [d, v]))
      // Dashed continuation joins the fact line when the forecast is purely in the future.
      if (anchor && line.run.points[0][0] > anchor[0]) byDate[anchor[0]] = anchor[1]
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
      const ranged = line.run.points.filter((p) => p[2] != null && p[3] != null)
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

    this.upsert("main", this.mainCanvasTarget, { labels, datasets }, this.baseOptions(labels), mode)
  }

  renderMainLegend() {
    const items = [`<span class="legend__item"><span class="legend__swatch legend__swatch--alt"></span>ЦБ РФ (факт)</span>`]
    this.sources().forEach((p) => {
      if (!this.activeRun(p)) return
      const cls = p === "apecon" ? "legend__swatch--apecon" : ""
      items.push(`<span class="legend__item"><span class="legend__swatch legend__swatch--dashed ${cls}"></span>${FORECAST_NAMES[p]}</span>`)
    })
    this.mainLegendTarget.innerHTML = items.join("")
  }

  // Which snapshots are on screen right now.
  renderMainStatus() {
    const parts = this.sources().flatMap((provider) => {
      const run = this.activeRun(provider)
      if (!run) return [`${FORECAST_NAMES[provider]}: снимков для ${this.state.currency} пока нет`]
      const version = this.runs(provider).indexOf(run) + 1
      return [`${FORECAST_NAMES[provider]}: снимок от ${dateRu(run.captured_at.slice(0, 10))} (${version} из ${this.runs(provider).length}) · ${run.points.length} тчк · до ${dateRu(run.points.at(-1)[0])}`]
    })
    parts.push("не является инвестиционной рекомендацией")
    this.mainStatusTarget.innerHTML = parts.map((t, i) => `<span class="${i ? "dot" : ""}">${t}</span>`).join("")
  }

  // ----- chart plumbing -----

  upsert(key, canvas, data, options, mode) {
    const chart = this.charts[key]
    if (chart) {
      chart.data = data
      chart.options = options
      chart.update(mode)
    } else {
      this.charts[key] = new Chart(canvas, { type: "line", data, options })
    }
  }

  // Shared line-chart scaffolding: fonts, muted grid, index tooltip that
  // skips the invisible corridor datasets.
  baseOptions(labels, overrides = {}) {
    const text3 = cssVar("--text-3")
    const line = cssVar("--line")
    // Days for short spans, month.year for a few years, the year alone beyond.
    const yearSpan = labels.length ? Number(labels.at(-1).slice(0, 4)) - Number(labels[0].slice(0, 4)) : 0
    const tickLabel = (iso) =>
      yearSpan >= 10 ? iso.slice(0, 4) : yearSpan >= 2 ? iso.slice(5, 7) + "." + iso.slice(0, 4) : dateShort(iso)

    return {
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
          displayColors: true,
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
      },
      ...overrides
    }
  }
}
