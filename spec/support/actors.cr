# SPDX-License-Identifier: AGPL-3.0-or-later

# Acteur de spec authentifié, muni des permissions citées (aucune par défaut).
def actor_with(*permissions : String) : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(1_i64, permissions.to_a)
end

def actor_with : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(1_i64, [] of String)
end
