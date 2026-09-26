# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

describe "Mot de passe (ADR-002 D1, CNIL 2022-100)" do
  it "applique le préréglage « 14 caractères sans caractère spécial obligatoire »" do
    policy = Partiduo::Auth::Config.password_policy
    policy.minimum_length.should eq(14)
    policy.require_special?.should be_false
    policy.require_uppercase?.should be_true
    policy.require_lowercase?.should be_true
    policy.require_digit?.should be_true
    policy.use_case.should eq(PasswordPolicy::UseCase::WithAccessRestriction)
  end

  it "atteint l'entropie exigée par son palier (satisfies_use_case?)" do
    Partiduo::Auth::Config.password_policy.satisfies_use_case?.should be_true
  end

  it "plafonne le mot de passe à 71 octets, limite du BCrypt de Crystal" do
    Partiduo::Auth::Config.password_policy.maximum_bytesize.should eq(71)
    view = Partiduo::Api::Auth.password_policy(Partiduo::Api::Actor.anonymous)
    view.maximum_bytes.should eq(71)
    view.minimum_length.should eq(14)
    view.require_special.should be_false
    view.entropy_bits.should be >= 50.0
  end

  it "refuse par clés i18n, par champ, ce que la politique rejette" do
    actor = Partiduo::Api::Actor.anonymous
    Partiduo::Api::Auth.check_password(actor, AuthSpec::PASSWORD).success?.should be_true

    short = Partiduo::Api::Auth.check_password(actor, "Court1a")
    short.error_keys.should contain("auth.errors.password.too_short")
    short.errors.first.field.should eq("password")
    short.errors.first.params["minimum"].should eq("14")

    Partiduo::Api::Auth.check_password(actor, "sansmajusculeni1chiffre").error_keys
      .should contain("auth.errors.password.missing_uppercase")
    Partiduo::Api::Auth.check_password(actor, "SansChiffreAucunIci").error_keys
      .should contain("auth.errors.password.missing_digit")
  end

  it "compte les octets et non les caractères (lettres accentuées)" do
    accented = "Éé1" + "é" * 34 # 37 caractères, 73 octets
    accented.size.should be < 71
    result = Partiduo::Api::Auth.check_password(Partiduo::Api::Actor.anonymous, accented)
    result.error_keys.should contain("auth.errors.password.too_many_bytes")
  end

  it "refuse un mot de passe qui contient le nom ou l'adresse" do
    result = Partiduo::Api::Auth.check_password(Partiduo::Api::Actor.anonymous, "Martin2026Printemps",
      email: "alice@example.com", first_name: "Alice", last_name: "Martin")
    result.error_keys.should contain("auth.errors.password.personal")
  end

  it "traduit chaque motif de refus en fr, en et nl" do
    PasswordPolicy::Violation.values.each do |violation|
      key = "auth.errors.password.#{violation.to_s.underscore}"
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { I18n.t(key, {"minimum" => "14", "maximum" => "128", "max_bytes" => "71"}).should_not contain("missing") }
      end
    end
  end

  it "hache en BCrypt par authn et vérifie" do
    hash = Partiduo::Auth::Passwords.hash(AuthSpec::PASSWORD)
    hash.should start_with("$2")
    created = AuthSpec.create_user
    user = AuthSpec.user_model(created.user.id)
    Partiduo::Auth::Passwords.verify(user, AuthSpec::PASSWORD).should be_true
    Partiduo::Auth::Passwords.verify(user, "Autrechose42Motdepasse").should be_false
  end

  it "change le mot de passe en exigeant l'actuel" do
    AuthSpec.create_user
    actor = AuthSpec.actor(AuthSpec.session_token)
    wrong = Partiduo::Api::Auth.change_password(actor,
      Partiduo::Api::Auth::ChangePasswordInput.new(new_password: "Nouveau42MotDePasse", current_password: "faux"))
    wrong.error_keys.should eq(["auth.errors.password.current_invalid"])

    ok = Partiduo::Api::Auth.change_password(actor,
      Partiduo::Api::Auth::ChangePasswordInput.new(new_password: "Nouveau42MotDePasse", current_password: AuthSpec::PASSWORD))
    ok.success?.should be_true
    AuthSpec.login(password: "Nouveau42MotDePasse").success?.should be_true
  end
end
