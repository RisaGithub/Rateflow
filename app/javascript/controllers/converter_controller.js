import { Controller } from "@hotwired/stimulus"

const fmt = (n, max = 2) => new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: max }).format(n)

// Instant in-browser conversion using the latest rate shown on the cards.
export default class extends Controller {
  static targets = ["amount", "currency", "dir", "result", "note"]
  static values = { rates: Object }

  connect() {
    this.dir = "to_rub"
    this.calc()
  }

  setDir(event) {
    this.dir = event.currentTarget.dataset.value
    this.dirTargets.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.value === this.dir)))
    this.calc()
  }

  calc() {
    const cur = this.currencyTarget.value
    const rate = this.ratesValue[cur]
    const amount = parseFloat(this.amountTarget.value)

    if (!rate) {
      this.resultTarget.textContent = "—"
      this.noteTarget.textContent = `Нет курса для ${cur}`
      return
    }
    if (!(amount >= 0)) {
      this.resultTarget.textContent = "—"
      this.noteTarget.textContent = "Введите сумму"
      return
    }

    const toRub = this.dir === "to_rub"
    const value = toRub ? amount * rate : amount / rate
    this.resultTarget.textContent = toRub ? `${fmt(value)} ₽` : `${fmt(value, 4)} ${cur}`
    this.noteTarget.textContent = `1 ${cur} = ${fmt(rate, 4)} ₽`
  }
}
