module ApplicationHelper
  PROVIDER_NAMES = { "cbr" => "ЦБ РФ", "erapi" => "ER-API", "currencyapi" => "Currency API",
                     "apecon" => "АПЭКОН", "internal" => "Rateflow" }.freeze

  def provider_name(key) = PROVIDER_NAMES.fetch(key, key)

  CURRENCY_SYMBOLS = { "USD" => "$", "EUR" => "€", "CNY" => "¥", "GBP" => "£", "RUB" => "₽" }.freeze

  def currency_symbol(code) = CURRENCY_SYMBOLS.fetch(code, code)

  # 71.5532 -> "71,5532"; Russian locale uses a decimal comma.
  def rub(value, precision: 4)
    return "—" if value.nil?

    number_with_precision(value, precision: precision, separator: ",", delimiter: " ")
  end

  def signed(value, precision: 4, suffix: "")
    return "—" if value.nil?

    sign = value.positive? ? "+" : (value.negative? ? "−" : "")
    "#{sign}#{rub(value.abs, precision: precision)}#{suffix}"
  end

  def trend_class(delta)
    return "is-flat" if delta.nil? || delta.zero?

    delta.positive? ? "is-up" : "is-down"
  end

  # Tiny inline SVG sparkline. Values are scaled to fit a 96×40 box.
  def sparkline(values, width: 96, height: 40)
    return "" if values.size < 2

    min, max = values.minmax
    span = (max - min).zero? ? 1.0 : (max - min)
    step = width.to_f / (values.size - 1)
    pts = values.each_with_index.map do |v, i|
      [ (i * step).round(1), (height - 2 - (v - min) / span * (height - 4)).round(1) ]
    end
    line = pts.map { |x, y| "#{x},#{y}" }.join(" ")
    area = "0,#{height} #{line} #{width},#{height}"

    tag.svg(viewBox: "0 0 #{width} #{height}", preserveAspectRatio: "none") do
      tag.polygon(points: area, fill: "currentColor", opacity: 0.12) +
        tag.polyline(points: line, fill: "none", stroke: "currentColor", "stroke-width": 1.5, "stroke-linejoin": "round")
    end
  end

  def date_ru(date) = date&.strftime("%d.%m.%Y")

  # Provider errors often quote the URL that failed, query string and all.
  # Those parameters are noise on a public page at best, so the log shows the
  # address without them.
  URL_QUERY = %r{(https?://[^\s?]+)\?\S*}

  def redacted_error(text)
    return "—" if text.blank?

    text.gsub(URL_QUERY, '\1?…')
  end

  # Donut ring for a 0–100 percentage with the number in the middle.
  # The arc starts at 12 o'clock and is drawn with stroke-dasharray.
  def donut(pct, size: 48, stroke: 5)
    half = size / 2.0
    radius = half - stroke / 2.0
    circumference = 2 * Math::PI * radius
    ring = { cx: half, cy: half, r: radius, fill: "none", "stroke-width": stroke }

    tag.svg(class: "donut", viewBox: "0 0 #{size} #{size}", width: size, height: size, role: "img",
            "aria-label": "#{pct}% успешных") do
      tag.circle(**ring, class: "donut__track") +
        tag.circle(**ring, class: "donut__value", "stroke-linecap": "round",
                   "stroke-dasharray": "#{(circumference * pct / 100.0).round(2)} #{circumference.round(2)}",
                   transform: "rotate(-90 #{half} #{half})") +
        tag.text("#{pct}%", x: half, y: half, class: "donut__num",
                 "text-anchor": "middle", "dominant-baseline": "central")
    end
  end
end
