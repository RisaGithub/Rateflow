# Health summary for one provider, derived from its recent FetchLog entries.
class ProviderStatus
  WINDOW = 20

  INFO = {
    "cbr"         => { name: "ЦБ РФ", role: "история с 1999 года", url: "cbr.ru/scripts/XML_dynamic.asp" },
    "erapi"       => { name: "ER-API", role: "только текущий день", url: "open.er-api.com/v6/latest/USD" },
    "currencyapi" => { name: "Currency API", role: "срезы по датам", url: "cdn.jsdelivr.net/npm/@fawazahmed0/currency-api" },
    "apecon"      => { name: "АПЭКОН", role: "прогнозы и котировки", url: "apecon.ru" }
  }.freeze

  attr_reader :key

  def initialize(key)
    @key = key
    @recent = FetchLog.for_provider(key).recent.limit(WINDOW).to_a
  end

  def name = INFO.dig(key, :name)
  def role = INFO.dig(key, :role)
  def url = INFO.dig(key, :url)
  def last = @recent.first
  def attempts = @recent.size

  # Stored-data coverage: honestly shows why CBR reaches back to 1999 while
  # the other two only cover recent months.
  def coverage_from = coverage[0]
  def coverage_to = coverage[1]
  def points_count = coverage[2].to_i

  private def coverage
    @coverage ||= Rate.where(provider: key).pick(Arel.sql("MIN(on_date), MAX(on_date), COUNT(*)")) || []
  end

  # :ok, :fail or :unknown (never called yet)
  def state
    return :unknown unless last

    last.ok? ? :ok : :fail
  end

  def success_rate
    return nil if @recent.empty?

    (@recent.count(&:ok?) * 100.0 / @recent.size).round
  end

  def avg_duration_ms
    return nil if @recent.empty?

    (@recent.sum(&:duration_ms) / @recent.size.to_f).round
  end
end
