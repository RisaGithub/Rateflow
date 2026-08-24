import { Controller } from "@hotwired/stimulus"

const fmt = (n, max = 2) => new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: max }).format(n)
const PROVIDER_NAMES = { cbr: "ЦБ РФ", erapi: "ER-API", currencyapi: "Currency API", apecon: "АПЭКОН" }
const dateRu = (iso) => iso.slice(8, 10) + "." + iso.slice(5, 7) + "." + iso.slice(0, 4)

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
    const info = this.ratesValue[cur]
    const amount = parseFloat(this.amountTarget.value)

    if (!info?.value) {
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
    const value = toRub ? amount * info.value : amount / info.value
    this.resultTarget.textContent = toRub ? `${fmt(value)} ₽` : `${fmt(value, 4)} ${cur}`
    // Name the rate the conversion used — same one the currency card shows.
    const source = [PROVIDER_NAMES[info.provider] || info.provider, info.date && dateRu(info.date)].filter(Boolean).join(", ")
    this.noteTarget.textContent = `1 ${cur} = ${fmt(info.value, 4)} ₽${source ? ` · ${source}` : ""}`
  }
}
