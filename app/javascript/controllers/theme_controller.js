import { Controller } from "@hotwired/stimulus"

// Light/dark toggle. The choice is stored in localStorage and applied in <head>
// before first paint (see the layout), so here we only flip it and notify charts.
export default class extends Controller {
  toggle() {
    const root = document.documentElement
    const dark = root.dataset.theme ? root.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches
    const next = dark ? "light" : "dark"
    root.dataset.theme = next
    try { localStorage.setItem("theme", next) } catch (_) {}
    window.dispatchEvent(new CustomEvent("theme:change", { detail: { theme: next } }))
  }
}
