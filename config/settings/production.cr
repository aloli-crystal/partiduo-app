# SPDX-License-Identifier: AGPL-3.0-or-later

Marten.configure :production do |config|
  config.debug = false
  config.secret_key = ENV.fetch("MARTEN_SECRET_KEY")
end
