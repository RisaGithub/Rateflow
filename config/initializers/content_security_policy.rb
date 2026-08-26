# Be sure to restart your server when you modify this file.

# Everything is served from our own origin except the Google Fonts pair.
# Inline code is allowed only through per-request nonces: the importmap and
# the theme bootstrap in the layout get one automatically, and Turbo reads
# the nonce from csp_meta_tag for its progress-bar <style>.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self, "https://fonts.googleapis.com"
    policy.font_src    :self, "https://fonts.gstatic.com"
    policy.img_src     :self, :data
    policy.connect_src :self
    policy.object_src  :none
    policy.frame_ancestors :none
    policy.base_uri    :self
    policy.form_action :self
  end

  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
