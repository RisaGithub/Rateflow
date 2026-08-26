require "test_helper"

class SourcesControllerTest < ActionDispatch::IntegrationTest
  test "the log strips query parameters out of provider error messages" do
    FetchLog.create!(provider: "cbr", kind: "rates", ok: false,
                     error_message: "HTTP 500 for https://www.cbr.ru/scripts/XML_dynamic.asp?date_req1=01.01.2026&VAL_NM_RQ=R01235")

    get sources_path

    assert_response :success
    assert_select "td.wrap", text: /XML_dynamic\.asp\?…\z/
    assert_no_match(/VAL_NM_RQ/, response.body)
  end
end
