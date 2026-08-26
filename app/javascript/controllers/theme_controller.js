import { Controller } from "@hotwired/stimulus"

// Light/dark toggle. Dark is the default; the choice is stored in localStorage
// and applied in <head> before first paint (see the layout). The switch itself
// crossfades via the View Transitions API, falling back to CSS transitions
// (.theme-anim in application.css).
export default class extends Controller {
  toggle() {
    const root = document.documentElement
    const next = root.dataset.theme === "light" ? "dark" : "light"

    const apply = () => {
      root.dataset.theme = next
      try { localStorage.setItem("theme", next) } catch (_) {}
      window.dispatchEvent(new CustomEvent("theme:change", { detail: { theme: next } }))
    }

    if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
      apply()
    } else if (document.startViewTransition) {
      document.startViewTransition(apply)
    } else {
      root.classList.add("theme-anim")
      apply()
      clearTimeout(this.animTimer)
      this.animTimer = setTimeout(() => root.classList.remove("theme-anim"), 300)
    }
  }
}
