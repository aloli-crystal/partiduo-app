# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial de l'authentification (convention C6, D-SET-005) :
# profils par défaut (administrateur, comptable) et, si le provisionnement
# désigne un administrateur, son compte — sans mot de passe : il reçoit une
# invitation (`Partiduo::Api::Auth.issue_invitation`), qui mène d'abord à
# l'enrôlement d'une passkey (ADR-002 D6).
Partiduo::Api::InitialData.register("AUTH", "profiles_and_admin", order: 5) do |context|
  profiles = Partiduo::Api::Auth.ensure_default_profiles(context.actor)
  if email = context.admin_email
    next if Partiduo::Api::Auth.user_by_email(context.actor, email)
    admin = profiles.find! { |profile| profile.code == "ADMIN" }
    locale = Partiduo::LOCALES.includes?(context.locale) ? context.locale : "fr"
    input = Partiduo::Api::Auth::UserInput.new(email: email, locale: locale, profile_id: admin.id)
    result = Partiduo::Api::Auth.create_user(context.actor, input)
    raise ArgumentError.new("administrateur refusé : #{result.error_keys.join(", ")}") if result.failure?
  end
end
