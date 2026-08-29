import { Controller } from "@hotwired/stimulus"
import { crossfade, dropSkeleton, fadeIn } from "lib/skeletons"
import { entryAnimation, reducedMotion, upsertChart } from "lib/chart_upsert"

const FORECAST_NAMES = { apecon: "Прогноз АПЭКОН", internal: "Прогноз Rateflow" }
const SOURCE_NAMES = { apecon: "АПЭКОН", internal: "Rateflow" }
const FAN_MAX = 60 // more translucent lines than this is mud, not a fan
const PAGE_SIZE = 50 // snapshot table rows per page, same as the sources log
const fmtRub = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 4 })

const dateRu = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7) + "." + iso.slice(0, 4)
const dateShort = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7)
const dateTimeRu = (iso) => `${dateRu(iso.slice(0, 10))} ${iso.slice(11, 16)}`
const isoDaysAgo = (days) => {
  const d = new Date()
  d.setDate(d.getDate() - days)
  return d.toISOString().slice(0, 10)
}
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()
// Dot radius follows the x-axis density: the more labels share the width,
// the smaller the dots — a five-year span must not turn into one blob.
const dotRadius = (labelCount) =>
  labelCount > 400 ? 1 : labelCount > 150 ? 1.5 : labelCount > 60 ? 2 : 2.5
const alphaHex = (a) => Math.round(a * 255).toString(16).padStart(2, "0")
const retryButton = (action) =>
  `<button type="button" class="retry-btn" data-action="forecasts#${action}">Повторить</button>`
// Evenly sampled max items; the first and the newest always survive.
const thinEven = (items, max) => {
  if (items.length <= max) return items
  const last = items.length - 1
  const picked = new Set()
  for (let i = 0; i < max; i++) picked.add(Math.round(i * last / (max - 1)))
  return [...picked].sort((a, b) => a - b).map((i) => items[i])
}

// The Прогнозы page: one currency + period + source choice drives every
// block. Facts come from GET /series (CBR only), forecast snapshots from
// GET /forecasts/data; the browser only picks snapshots and draws them.
// The period bounds the fact line and the snapshot capture dates — the
// forecast part of the main chart always shows in full.
export default class extends Controller {
  static targets = ["seg", "range", "fromDate", "toDate", "emptyNotice",
                    "mainCanvas", "mainWrap", "playback", "playBtn", "playSlider", "playLabel",
                    "mainLegend", "mainStatus", "fanCanvas", "fanWrap", "fanStatus",
                    "horizonSelect", "revisionCanvas", "revisionWrap", "revisionLegend", "revisionStatus",
                    "accuracyBox", "accuracyGroup", "accuracyCard",
                    "snapshotsBody", "pagerPrev", "pagerNext", "pagerInfo"]

  connect() {
    this.state = { currency: "USD", period: 90, from: null, to: null, source: "both", horizonDate: null }
    this.runIndex = null
    this.pinned = {} // exact table-picked snapshots by provider
    this.selectedRunId = null
    this.page = 1
    this.charts = {}
    this.facts = []
    this.payload = null
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
    // Controls are drawable without any data; every block below waits for it.
    this.renderControls()
    this.load()
    this.loadAccuracy()
  }

  disconnect() {
    window.removeEventListener("theme:change", this.onTheme)
    document.removeEventListener("pointerdown", this.onDocPointer)
    document.removeEventListener("keydown", this.onDocKey)
    this.stopPlay()
    this.abort?.abort()
    this.accuracyAbort?.abort()
    Object.values(this.charts).forEach((c) => c.destroy())
  }

  // ----- actions -----

  setOption(event) {
    const { key, value } = event.currentTarget.dataset
    const previousPeriod = this.state.period
    const num = Number(value)
    this.state[key] = Number.isNaN(num) ? value : num
    this.resetPlayback()
    this.page = 1
    if (key === "source") return this.render()
    // Currency and period both change what the server should send; the
    // accuracy block only depends on the period (it holds every currency).
    if (key === "period") {
      this.rangeTarget.hidden = this.state.period !== "custom"
      if (this.state.period === "custom") {
        // First open starts from the period that was on screen instead of
        // empty fields — the user adjusts dates, not types them from scratch.
        if (!this.state.from) this.prefillRange(previousPeriod)
        // preventScroll: focusing the field must not scroll the page around.
        this.fromDateTarget.focus({ preventScroll: true })
      }
      this.loadAccuracy()
    }
    this.load()
  }

  prefillRange(previousPeriod) {
    const days = typeof previousPeriod === "number" ? previousPeriod : 90
    this.state.from = this.fromDateTarget.value = isoDaysAgo(days)
    this.state.to = this.toDateTarget.value = isoDaysAgo(0)
  }

  // Custom period: two date fields; refetch as soon as a start date exists.
  setRange() {
    this.state.from = this.fromDateTarget.value || null
    this.state.to = this.toDateTarget.value || null
    if (!this.state.from) return
    this.resetPlayback()
    this.page = 1
    this.loadAccuracy()
    this.load()
  }

  setHorizon(event) {
    this.state.horizonDate = event.target.value
    this.renderRevision()
  }

  // A table row puts that exact version on the main chart. When the snapshot
  // survives in the thinned payload, the playback slider jumps right to it;
  // a thinned-out one is fetched individually and pinned.
  async selectSnapshot(event) {
    const { runId, provider } = event.currentTarget.dataset
    const id = Number(runId)
    this.stopPlay()
    this.selectedRunId = id

    const position = this.runs(provider).findIndex((r) => r.id === id)
    if (position >= 0 && provider === this.playbackProvider()) {
      this.runIndex = position
      delete this.pinned[provider]
    } else if (position >= 0) {
      this.pinned[provider] = this.runs(provider)[position]
    } else {
      try {
        this.pinned[provider] = await this.fetchJson(`/forecasts/data?run=${id}`)
      } catch (error) {
        if (error.name === "AbortError") return
        this.mainStatusTarget.innerHTML = `<span>Не удалось загрузить снимок</span>`
        return
      }
      if (provider === this.playbackProvider()) this.runIndex = null
    }
    this.renderMain()
    this.renderPlayback()
    this.renderMainStatus()
    this.renderSnapshots()
  }

  prevPage() {
    this.page = Math.max(1, this.page - 1)
    this.renderSnapshots()
  }

  nextPage() {
    this.page += 1
    this.renderSnapshots()
  }

  // ----- data -----

  async load() {
    this.abort?.abort()
    this.abort = new AbortController()
    const { currency } = this.state
    const range = this.rangeQuery()
    try {
      const [facts, forecasts] = await Promise.all([
        this.fetchJson(`/series?currency=${currency}&providers=cbr${range}`),
        this.fetchJson(`/forecasts/data?currency=${currency}${range}`)
      ])
      this.facts = facts.series?.cbr?.points || []
      this.payload = forecasts
      this.emptyNoticeTarget.hidden = !forecasts.empty
      this.render()
    } catch (error) {
      if (error.name === "AbortError") return
      this.dropChartSkeletons()
      this.mainStatusTarget.innerHTML =
        `<span>Не удалось загрузить данные${this.payload ? " — показаны последние загруженные" : ""}</span>` +
        retryButton("retryData")
    }
  }

  // «Повторить» next to a failure message repeats exactly that request.
  retryData() { this.load() }
  retryAccuracy() { this.loadAccuracy() }

  // A failed load must not leave placeholders sweeping behind the message.
  dropChartSkeletons() {
    [ this.mainWrapTarget, this.fanWrapTarget, this.revisionWrapTarget ].forEach(dropSkeleton)
    this.snapshotsBodyTarget.innerHTML = ""
  }

  // The accuracy section is server-rendered HTML: refetched per period,
  // while currency and source switches only toggle what is visible.
  async loadAccuracy() {
    this.accuracyAbort?.abort()
    this.accuracyAbort = new AbortController()
    const range = this.rangeQuery()
    try {
      const response = await fetch(`/forecasts/accuracy${range ? `?${range.slice(1)}` : ""}`,
        { signal: this.accuracyAbort.signal })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.accuracyBoxTarget.innerHTML = await response.text()
      fadeIn(this.accuracyBoxTarget)
      this.renderAccuracy()
    } catch (error) {
      if (error.name === "AbortError") return
      this.accuracyBoxTarget.innerHTML =
        `<div class="load-error"><span>Не удалось загрузить точность</span>${retryButton("retryAccuracy")}</div>`
    }
  }

  // {from, to} of the selected period; "all" means no bounds at all.
  range() {
    if (this.state.period === "all") return {}
    if (this.state.period === "custom") return { from: this.state.from, to: this.state.to }
    return { from: isoDaysAgo(this.state.period) }
  }

  // "&from=…&to=…" ready to append to a query string; "" without bounds.
  rangeQuery() {
    const { from, to } = this.range()
    return (from ? `&from=${from}` : "") + (to ? `&to=${to}` : "")
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

  // The snapshot on the main chart: playback position first, then a snapshot
  // pinned from the table, the latest one otherwise.
  activeRun(provider) {
    const runs = this.runs(provider)
    if (provider === this.playbackProvider() && this.runIndex != null && runs.length) {
      return runs[Math.min(this.runIndex, runs.length - 1)]
    }
    return this.pinned[provider] || runs.at(-1) || null
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
    this.pinned = {}
    this.selectedRunId = null
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
    if (total < 2 || reducedMotion()) return
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
    this.playBtnTarget.hidden = reducedMotion()
    this.playBtnTarget.textContent = this.playTimer ? "⏸" : "▶"
    this.playBtnTarget.setAttribute("aria-label", this.playTimer ? "Пауза" : "Проиграть историю прогноза")
  }

  // ----- render -----

  render() {
    this.renderControls()
    this.renderAccuracy()
    if (!this.payload) return // still loading: the skeletons keep the boxes

    this.renderMain()
    this.renderPlayback()
    this.renderMainLegend()
    this.renderMainStatus()
    this.renderFan()
    this.renderRevision()
    this.renderSnapshots()
  }

  // Everything that needs no data at all — drawn on connect so the switches
  // answer clicks while the first requests are still in flight.
  renderControls() {
    this.segTargets.forEach((b) => b.setAttribute("aria-pressed", String(String(this.state[b.dataset.key]) === b.dataset.value)))
  }

  // Block 5: the complete snapshot log from the metadata index — every stored
  // version, not just the thinned hundred the charts draw.
  renderSnapshots() {
    fadeIn(this.snapshotsBodyTarget)
    const rows = this.sources().flatMap((p) => this.index(p).map((r) => ({ ...r, provider: p })))
    rows.sort((a, b) => (a.captured_at < b.captured_at ? 1 : -1))

    const pages = Math.max(1, Math.ceil(rows.length / PAGE_SIZE))
    this.page = Math.min(this.page, pages)
    const visible = rows.slice((this.page - 1) * PAGE_SIZE, this.page * PAGE_SIZE)

    this.snapshotsBodyTarget.innerHTML = visible.length ? visible.map((r) => `
      <tr data-run-id="${r.id}" data-provider="${r.provider}" data-action="click->forecasts#selectSnapshot"
          class="${r.id === this.selectedRunId ? "is-selected" : ""}">
        <td>${dateTimeRu(r.captured_at)}</td>
        <td class="muted">${SOURCE_NAMES[r.provider]}</td>
        <td class="num">${r.points_count}</td>
        <td>${r.horizon_to ? dateRu(r.horizon_to) : "—"}</td>
      </tr>`).join("")
      : `<tr><td colspan="4" class="table-empty">${this.emptyNote()}</td></tr>`

    this.pagerPrevTarget.hidden = this.page <= 1
    this.pagerNextTarget.hidden = this.page >= pages
    this.pagerInfoTarget.textContent = `Страница ${this.page} из ${pages} · ${rows.length} снимков`
  }

  // Block 4 is server-rendered per currency; the switches only pick what shows.
  renderAccuracy() {
    this.accuracyGroupTargets.forEach((g) => (g.hidden = g.dataset.currency !== this.state.currency))
    this.accuracyCardTargets.forEach((c) => (c.hidden = !this.sources().includes(c.dataset.provider)))
  }

  // Block 1: the fact as a muted solid line, active snapshots dashed on top,
  // АПЭКОН's min–max range as a shaded corridor.
  renderMain(mode) {
    const factColor = cssVar("--text-3")
    const lines = this.sources().flatMap((p) => {
      const run = this.activeRun(p)
      return run ? [{ provider: p, run }] : []
    })
    const labels = [...new Set([
      ...this.facts.map(([d]) => d),
      ...lines.flatMap((l) => l.run.points.map(([d]) => d))
    ])].sort()

    const datasets = [this.factDataset(labels, factColor)]

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
        pointRadius: line.provider === "apecon" ? dotRadius(labels.length) : 0,
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

    this.upsert("main", this.mainCanvasTarget, this.mainWrapTarget, { labels, datasets }, this.baseOptions(labels), mode)
  }

  // Block 2: every snapshot captured in the period at once, translucent —
  // newer lines brighter and thicker. One look shows how the forecast drifted
  // and how stable it is. Static by design: no animation, no hover, thinned
  // to FAN_MAX per provider; the true per-period totals come from the index.
  renderFan() {
    const fans = this.sources().map((p) => ({
      provider: p,
      total: this.index(p).length || this.runs(p).length,
      shown: thinEven(this.runs(p), FAN_MAX)
    }))
    const labels = [...new Set([
      ...this.facts.map(([d]) => d),
      ...fans.flatMap((f) => f.shown.flatMap((r) => r.points.map(([d]) => d)))
    ])].sort()

    const datasets = [this.factDataset(labels, cssVar("--text-3"))]
    for (const fan of fans) {
      const color = this.colorOf(fan.provider)
      const count = fan.shown.length
      fan.shown.forEach((run, i) => {
        const rank = count > 1 ? i / (count - 1) : 1
        const byDate = Object.fromEntries(run.points.map(([d, v]) => [d, v]))
        datasets.push({
          label: `_${fan.provider}-${i}`,
          data: labels.map((d) => byDate[d] ?? null),
          borderColor: color + alphaHex(0.1 + rank * 0.9),
          borderWidth: i === count - 1 ? 2.5 : 1 + rank,
          tension: 0.25,
          spanGaps: true,
          fill: false,
          pointRadius: 0
        })
      })
    }

    const options = this.baseOptions(labels)
    options.animation = { duration: 0 }
    options.events = [] // dozens of lines: hover picking would cost more than it tells
    options.plugins.tooltip.enabled = false
    this.upsert("fan", this.fanCanvasTarget, this.fanWrapTarget, { labels, datasets }, options, "none")

    fadeIn(this.fanStatusTarget)
    if (fans.every((f) => !f.shown.length)) {
      this.fanStatusTarget.innerHTML = `<span>${this.emptyNote()}</span>`
      return
    }
    const parts = fans.map((f) =>
      `${SOURCE_NAMES[f.provider]}: ${f.shown.length === f.total ? f.total : `${f.shown.length} из ${f.total} (прорежено)`} снимков`)
    parts.push("свежие снимки ярче и толще")
    this.fanStatusTarget.innerHTML = parts.map((t, i) => `<span class="${i ? "dot" : ""}">${t}</span>`).join("")
  }

  // Block 3: how the forecast for one fixed date was revised, snapshot by
  // snapshot. When the date has already come, the CBR fact runs as a flat
  // line — did the revisions converge on the truth or walk away from it?
  renderRevision() {
    fadeIn(this.revisionLegendTarget)
    fadeIn(this.revisionStatusTarget)
    const dates = this.horizonDates()
    this.syncHorizonSelect(dates)
    const date = this.state.horizonDate
    if (!date) {
      crossfade(this.revisionWrapTarget)
      this.charts.revision?.destroy()
      delete this.charts.revision
      this.revisionLegendTarget.innerHTML = ""
      this.revisionStatusTarget.innerHTML =
        `<span>Нет дат, на которые есть хотя бы три снимка прогноза${this.state.period === "all" ? "" : " в выбранном периоде"}</span>`
      return
    }

    // Per provider: [snapshot date, what it predicted for the chosen date].
    const revisions = this.sources().flatMap((provider) => {
      const points = this.runs(provider).flatMap((run) => {
        const point = run.points.find(([d]) => d === date)
        return point ? [[run.captured_at.slice(0, 10), point[1]]] : []
      })
      return points.length ? [{ provider, points }] : []
    })

    const labels = [...new Set(revisions.flatMap((r) => r.points.map(([d]) => d)))].sort()
    const datasets = revisions.map((r) => {
      const color = this.colorOf(r.provider)
      const byDate = Object.fromEntries(r.points)
      return {
        label: FORECAST_NAMES[r.provider],
        data: labels.map((d) => byDate[d] ?? null),
        borderColor: color,
        borderWidth: 2,
        tension: 0.25,
        spanGaps: true,
        fill: false,
        pointRadius: dotRadius(labels.length),
        pointBackgroundColor: color,
        pointBorderColor: color,
        pointHoverRadius: 4,
        pointHoverBackgroundColor: color,
        pointHoverBorderColor: cssVar("--card"),
        pointHoverBorderWidth: 2
      }
    })

    const fact = this.factFor(date)
    if (fact) {
      const factColor = cssVar("--text-3")
      datasets.push({ label: "Факт ЦБ РФ", data: labels.map(() => fact[1]), borderColor: factColor,
                      borderWidth: 1.5, tension: 0, spanGaps: true, fill: false, pointRadius: 0, pointHoverRadius: 0 })
    }

    const options = this.baseOptions(labels)
    options.plugins.tooltip.callbacks.title = (items) => `снимок от ${dateRu(items[0].label)}`
    this.upsert("revision", this.revisionCanvasTarget, this.revisionWrapTarget, { labels, datasets }, options)

    const items = revisions.map((r) => {
      const cls = r.provider === "apecon" ? "legend__swatch--apecon" : ""
      return `<span class="legend__item"><span class="legend__swatch ${cls}"></span>${FORECAST_NAMES[r.provider]} · ${r.points.length} снимков</span>`
    })
    if (fact) items.push(`<span class="legend__item"><span class="legend__swatch legend__swatch--alt"></span>Факт ЦБ РФ</span>`)
    this.revisionLegendTarget.innerHTML = items.join("")

    const today = new Date().toISOString().slice(0, 10)
    const parts = [`по оси X — дата снимка, по оси Y — что тогда прогнозировали на ${dateRu(date)}`]
    parts.push(fact ? `факт ЦБ РФ: ${fmtRub.format(fact[1])} ₽${fact[0] === date ? "" : ` (курс от ${dateRu(fact[0])})`}`
      : date > today ? "дата ещё не наступила — факта пока нет" : "факта ЦБ РФ на эту дату нет")
    this.revisionStatusTarget.innerHTML = parts.map((t, i) => `<span class="${i ? "dot" : ""}">${t}</span>`).join("")
  }

  // Horizon dates worth a revision chart: at least three snapshots of one
  // provider predicted that exact date.
  horizonDates() {
    const qualified = new Set()
    this.sources().forEach((provider) => {
      const perDate = {}
      this.runs(provider).forEach((run) => run.points.forEach(([d]) => { perDate[d] = (perDate[d] || 0) + 1 }))
      Object.entries(perDate).forEach(([d, n]) => { if (n >= 3) qualified.add(d) })
    })
    return [...qualified].sort()
  }

  // Keeps the current choice when it survives the source/currency switch;
  // otherwise defaults to the most recent already-matured date.
  syncHorizonSelect(dates) {
    if (!dates.includes(this.state.horizonDate)) {
      const today = new Date().toISOString().slice(0, 10)
      this.state.horizonDate = dates.filter((d) => d <= today).at(-1) || dates[0] || null
    }
    this.horizonSelectTarget.innerHTML = dates.map((d) =>
      `<option value="${d}"${d === this.state.horizonDate ? " selected" : ""}>${dateRu(d)}</option>`).join("")
    this.horizonSelectTarget.hidden = !dates.length
  }

  // The [date, value] fact effective on the date. CBR skips weekends and
  // holidays, so the closest earlier rate counts — but a week back at most.
  factFor(date) {
    if (date > new Date().toISOString().slice(0, 10)) return null
    const hit = [...this.facts].reverse().find(([d]) => d <= date)
    if (!hit || new Date(date) - new Date(hit[0]) > 7 * 86400000) return null
    return hit
  }

  renderMainLegend() {
    fadeIn(this.mainLegendTarget)
    const items = [`<span class="legend__item"><span class="legend__swatch legend__swatch--alt"></span>ЦБ РФ (факт)</span>`]
    this.sources().forEach((p) => {
      const run = this.activeRun(p)
      if (!run) return
      const cls = p === "apecon" ? "legend__swatch--apecon" : ""
      items.push(`<span class="legend__item"><span class="legend__swatch legend__swatch--dashed ${cls}"></span>${FORECAST_NAMES[p]}</span>`)
      // Same condition renderMain uses to draw the shaded min–max corridor.
      if (run.points.filter((pt) => pt[2] != null && pt[3] != null).length > 1) {
        items.push(`<span class="legend__item"><span class="legend__swatch legend__swatch--band ${cls}"></span>${FORECAST_NAMES[p]} · вилка мин–макс</span>`)
      }
    })
    this.mainLegendTarget.innerHTML = items.join("")
  }

  // Says in plain words when the chosen period holds nothing to draw.
  emptyNote() {
    return `Снимков для ${this.state.currency} ${this.state.period === "all" ? "пока нет" : "в выбранном периоде нет"}`
  }

  // Which snapshots are on screen right now.
  renderMainStatus() {
    fadeIn(this.mainStatusTarget)
    const parts = this.sources().flatMap((provider) => {
      const run = this.activeRun(provider)
      if (!run) return [`${FORECAST_NAMES[provider]}: снимков ${this.state.period === "all" ? `для ${this.state.currency} пока нет` : "в выбранном периоде нет"}`]
      const position = this.runs(provider).indexOf(run)
      const version = position >= 0 ? ` (${position + 1} из ${this.runs(provider).length})` : " (выбран в таблице)"
      return [`${FORECAST_NAMES[provider]}: снимок от ${dateRu(run.captured_at.slice(0, 10))}${version} · ${run.points.length} тчк · до ${dateRu(run.points.at(-1)[0])}`]
    })
    parts.push("не является инвестиционной рекомендацией")
    this.mainStatusTarget.innerHTML = parts.map((t, i) => `<span class="${i ? "dot" : ""}">${t}</span>`).join("")
  }

  // ----- chart plumbing -----

  // The CBR fact as a muted solid line — the shared backdrop of every chart here.
  factDataset(labels, color) {
    const byDate = Object.fromEntries(this.facts)
    return {
      label: "ЦБ РФ (факт)",
      data: labels.map((d) => byDate[d] ?? null),
      borderColor: color,
      borderWidth: 1.5,
      tension: 0.25,
      spanGaps: true,
      fill: false,
      pointRadius: 0,
      pointHoverRadius: 4,
      pointHoverBackgroundColor: color,
      pointHoverBorderColor: cssVar("--card"),
      pointHoverBorderWidth: 2
    }
  }

  // Creates the chart once real data exists and updates it silently ever
  // after, then fades it in over the skeleton that held its box.
  upsert(key, canvas, wrap, data, options, mode) {
    if (typeof Chart === "undefined") return crossfade(wrap) // script missing — keep the page alive
    if (upsertChart(this.charts, key, canvas, data, options, mode)) crossfade(wrap)
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
