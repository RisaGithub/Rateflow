require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  setup do
    @old = ENV.values_at("ADMIN_USER", "ADMIN_PASSWORD")
    ENV["ADMIN_USER"] = "admin"
    ENV["ADMIN_PASSWORD"] = "pass"
    AdminController::RATE_LIMIT_STORE.clear
  end

  teardown { ENV["ADMIN_USER"], ENV["ADMIN_PASSWORD"] = @old }

  def basic(user, password)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user, password) }
  end

  test "without configured credentials the page answers 503, not open access" do
    ENV["ADMIN_USER"] = nil
    get admin_path
    assert_response :service_unavailable
    assert_match "ADMIN_USER", response.body
  end

  test "wrong password gets 401" do
    get admin_path, headers: basic("admin", "nope")
    assert_response :unauthorized
  end

  test "more than 20 requests per minute from one address get 429" do
    20.times { get admin_path, headers: basic("admin", "nope") }
    assert_response :unauthorized

    get admin_path, headers: basic("admin", "nope")
    assert_response :too_many_requests
  end

  test "valid credentials see the database state" do
    Rate.create!(provider: "cbr", currency: "USD", on_date: Date.new(2026, 8, 1), value: "80")

    get admin_path, headers: basic("admin", "pass")

    assert_response :success
    assert_match "Состояние базы", response.body
    assert_match "Обновить курсы", response.body
  end

  # The top line answers "is the schedule alive?", so only origin "task"
  # counts: the endpoint is also hit by hand from this very page.
  test "a fresh endpoint check does not pass for a working schedule" do
    RefreshCheck.create!(kind: "forecast", origin: "endpoint", outcome: "skipped",
                         detail: "обновлено меньше суток назад")

    get admin_path, headers: basic("admin", "pass")

    assert_response :success
    assert_match "Плановые проверки", response.body
    assert_match "Расписание молчит", response.body
    assert_match "Проверок по команде ещё не было", response.body
    assert_match "эндпоинт", response.body
  end

  test "a task check older than two hours is flagged as a problem" do
    RefreshCheck.create!(kind: "forecast", origin: "task", outcome: "skipped",
                         detail: "обновлено меньше суток назад", created_at: 3.hours.ago)

    get admin_path, headers: basic("admin", "pass")

    assert_match "Расписание молчит", response.body
    assert_match "3 ч назад", response.body
  end

  test "a recent task check reads as a working schedule, with its row below" do
    RefreshCheck.create!(kind: "forecast", origin: "task", outcome: "fetched",
                         currency: "USD", detail: "12 точек", created_at: 20.minutes.ago)

    get admin_path, headers: basic("admin", "pass")

    assert_match "Расписание работает", response.body
    assert_match "20 мин назад", response.body
    assert_match "Обновлено", response.body
    assert_match "12 точек", response.body
  end

  test "rebuild internal button recomputes and redirects with a flash" do
    post admin_rebuild_internal_path, headers: basic("admin", "pass")

    assert_redirected_to admin_path
    follow_redirect!(headers: basic("admin", "pass"))
    assert_match "пересчитан", response.body
  end
end
