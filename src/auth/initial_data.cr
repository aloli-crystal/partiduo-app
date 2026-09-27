# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial de l'authentification (convention C6, D-SET-005) :
# profils par défaut (administrateur, comptable) et, si le provisionnement
# désigne un administrateur, son compte — sans mot de passe : il reçoit une
# invitation, qui mène d'abord à l'enrôlement d'une passkey (ADR-002 D6).
# Le jeton est rendu à l'opérateur par `ProvisionView#invitations` : la
# commande `provision` affiche le lien à transmettre (D-J1-001).
Partiduo::Api::InitialData.register("AUTH", "profiles_and_admin", order: 5) do |context|
  profiles = Partiduo::Api::Auth.ensure_default_profiles(context.actor)
  if email = context.admin_email
    next if Partiduo::Api::Auth.user_by_email(context.actor, email)
    admin = profiles.find! { |profile| profile.code == "ADMIN" }
    locale = Partiduo::LOCALES.includes?(context.locale) ? context.locale : "fr"
    input = Partiduo::Api::Auth::UserInput.new(email: email, locale: locale, profile_id: admin.id)
    result = Partiduo::Api::Auth.create_user(context.actor, input)
    raise ArgumentError.new("administrateur refusé : #{result.error_keys.join(", ")}") if result.failure?
    invitation = result.value!.invitation
    context.invitations << Partiduo::Api::InitialData::Invitation.new(
      email: result.value!.user.email, token: invitation.token, expires_at: invitation.expires_at,
    )
  end
end
