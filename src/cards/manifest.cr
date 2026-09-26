# SPDX-License-Identifier: AGPL-3.0-or-later

Partiduo::Modules.register do
  code "CARDS"
  name "cards.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Socle
  permission "cards.card.read"
  permission "cards.card.write"
end
