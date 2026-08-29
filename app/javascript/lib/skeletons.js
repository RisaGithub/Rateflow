// Skeleton → content handover, shared by both page controllers.
//
// Every placeholder keeps the box its real content will occupy, so the swap
// costs no layout shift; all that is left is a short opacity crossfade. Both
// helpers are one-shot: later re-renders (currency, period, source switches)
// must not flash the page again.

const FADE_MS = 180

// A `.swap` block (or a `.chart-wrap`) stacks its skeleton and its content in
// one cell: marking it ready fades one out while the other fades in, then the
// skeleton leaves the layout for good.
export function crossfade(container) {
  if (!container || container.dataset.swapped) return

  container.dataset.swapped = "1"
  container.classList.add("is-ready")
  container.querySelectorAll(".swap__skel").forEach((skel) => {
    setTimeout(() => (skel.hidden = true), FADE_MS + 40)
  })
}

// For blocks whose skeleton is the very markup being replaced (table bodies,
// legends, status lines): the fresh content fades in over the same 180 ms.
export function fadeIn(element) {
  if (!element || element.dataset.faded) return

  element.dataset.faded = "1"
  element.classList.add("is-revealed")
}

// Error state: the skeleton must not keep sweeping behind a failure message.
export function dropSkeleton(container) {
  if (!container) return

  container.dataset.swapped = "1"
  container.classList.add("is-ready")
  container.querySelectorAll(".swap__skel").forEach((skel) => (skel.hidden = true))
}
