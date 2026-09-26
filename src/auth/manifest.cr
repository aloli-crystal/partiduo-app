# SPDX-License-Identifier: AGPL-3.0-or-later

# Authentification et droits (ADR-002) : pièce du socle, toujours active.
#
# Les permissions `auth.*` sont *administratives* : le rôle `comptable` ne peut
# jamais les détenir (ADR-002 D4), quel que soit son profil.
Partiduo::Modules.register do
  code "AUTH"
  name "auth.module.name"
  version Partiduo::VERSION
  kind Partiduo::Modules::Kind::Socle
  # Utilisateurs : création, rôle, profil, révocation, déblocage, droits par journal.
  permission "auth.users.manage"
  # Profils et permissions cochées (héritiers de profile_menu).
  permission "auth.profiles.manage"
  # Journal d'audit nominatif (héritier d'audit_connect).
  permission "auth.audit.view"
  # Fournisseurs d'identité (SAML, OIDC) et identités fédérées.
  permission "auth.providers.manage"
end
