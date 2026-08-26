require "test_helper"

class AboutControllerTest < ActionDispatch::IntegrationTest
  test "GET /about renders the page" do
    get about_path

    assert_response :success
    assert_select "h1", text: "О проекте"
    assert_select "a[href=?]", "https://github.com/RisaGithub/Rateflow"
    assert_select "a[href=?]", "mailto:rateflow.app@proton.me"
  end

  test "the top bar link is marked as current only on the about page" do
    get about_path
    assert_select ".topbar__tools a.icon-btn[aria-current=page]"

    get sources_path
    assert_select ".topbar__tools a.icon-btn"
    assert_select ".topbar__tools a.icon-btn[aria-current]", count: 0
  end
end
