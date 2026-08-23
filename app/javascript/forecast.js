// Naive trend: extend the series by `horizon` steps using a rolling mean.
// Each new point is the mean of the previous `window` values (actual or forecast).
//
// Backtest: for every historical point with enough history, "predict" it the
// same way from the points before it and compare with the fact. Returns mean
// absolute error (MAE) and mean absolute percentage error (MAPE).

export const WINDOW = 7
export const HORIZON = 7

export function forecast(values, { window = WINDOW, horizon = HORIZON } = {}) {
  if (values.length < 2) return []
  const w = Math.min(window, values.length)
  const buf = values.slice(-w)
  const out = []
  for (let i = 0; i < horizon; i++) {
    const next = buf.reduce((a, b) => a + b, 0) / buf.length
    out.push(next)
    buf.push(next)
    buf.shift()
  }
  return out
}

export function backtest(values, { window = WINDOW } = {}) {
  const errors = []
  for (let i = window; i < values.length; i++) {
    const pred = values.slice(i - window, i).reduce((a, b) => a + b, 0) / window
    errors.push({ abs: Math.abs(values[i] - pred), pct: Math.abs(values[i] - pred) / values[i] * 100 })
  }
  if (!errors.length) return null
  const mean = (k) => errors.reduce((a, e) => a + e[k], 0) / errors.length
  return { samples: errors.length, mae: mean("abs"), mape: mean("pct") }
}

// Next `n` calendar dates after an ISO date (YYYY-MM-DD).
export function nextDates(iso, n) {
  const out = []
  const d = new Date(iso + "T00:00:00Z")
  for (let i = 0; i < n; i++) {
    d.setUTCDate(d.getUTCDate() + 1)
    out.push(d.toISOString().slice(0, 10))
  }
  return out
}
