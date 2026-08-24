module ApplicationHelper
  PROVIDER_NAMES = { "cbr" => "ЦБ РФ", "erapi" => "ER-API", "currencyapi" => "Currency API",
                     "apecon" => "АПЭКОН", "internal" => "Свой прогноз" }.freeze

  def provider_name(key) = PROVIDER_NAMES.fetch(key, key)

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
end
