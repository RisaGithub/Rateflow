// One rule for every Chart.js chart on the site: the entry animation belongs
// to the first draw and nowhere else.
//
// Charts used to be created in connect() with empty datasets and updated again
// once the JSON arrived, so the line rose twice. Now a chart is built only when
// real data exists — until then a skeleton holds its place — and every later
// update (currency, period, sources, theme, playback step) redraws silently.

const ENTRY_MS = 460

// Turbo Drive paints a cached snapshot before swapping in the fresh response.
// Stimulus connects on that preview too; drawing there would animate the entry
// once for the snapshot and once for the real page.
const isPreview = () => document.documentElement.hasAttribute("data-turbo-preview")

export const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches

// The animation block for a chart's options: the single entry transition.
export const entryAnimation = () =>
  reducedMotion() ? { duration: 0 } : { duration: ENTRY_MS, easing: "easeOutQuart" }

// Creates the chart on first call, updates it silently afterwards. `mode`
// overrides the update mode; the default "none" is what keeps the line still.
export function upsertChart(charts, key, canvas, data, options, mode) {
  if (typeof Chart === "undefined" || isPreview()) return null

  const chart = charts[key]
  if (!chart) return (charts[key] = new Chart(canvas, { type: "line", data, options }))

  chart.data = data
  chart.options = options
  chart.update(mode || "none")
  return chart
}
