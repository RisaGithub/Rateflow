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

  test "rebuild internal button recomputes and redirects with a flash" do
    post admin_rebuild_internal_path, headers: basic("admin", "pass")

    assert_redirected_to admin_path
    follow_redirect!(headers: basic("admin", "pass"))
    assert_match "пересчитан", response.body
  end
end
