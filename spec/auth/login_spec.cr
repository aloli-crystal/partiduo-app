# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def age_failures(user_id : Int64, by : Time::Span = 1.hour) : Nil
  user = AuthSpec.user_model(user_id)
  user.last_failed_at = (user.last_failed_at || Time.utc) - by
  user.save!
end

describe "Connexion par mot de passe et limitation des tentatives" do
  it "ouvre une session de niveau 1 et donne l'acteur du profil" do
    created = AuthSpec.create_user
    result = AuthSpec.login
    result.success?.should be_true
    view = result.value!
    view.authenticated?.should be_true
    view.level.should eq(1)
    view.required_level.should eq(1)
    view.elevation_required.should be_false
    view.suggest_passkey.should be_true

    actor = AuthSpec.actor(view.session_token!)
    actor.user_id.should eq(created.user.id)
    actor.level.should eq(1)
    actor.can?("auth.users.manage").should be_true # profil administrateur
  end

  it "ne dit pas si l'adresse existe" do
    AuthSpec.create_user
    AuthSpec.login("inconnu@example.com").error_keys.should eq(["auth.errors.login.invalid_credentials"])
    AuthSpec.login(password: "Mauvais42MotDePasse").error_keys.should eq(["auth.errors.login.invalid_credentials"])
  end

  it "normalise l'adresse (casse, espaces)" do
    AuthSpec.create_user
    AuthSpec.login("  Alice@Example.COM ").success?.should be_true
  end

  it "temporise de façon croissante à partir du troisième échec" do
    Partiduo::Auth::Throttle.delay_for(1).should eq(Time::Span.zero)
    Partiduo::Auth::Throttle.delay_for(2).should eq(Time::Span.zero)
    Partiduo::Auth::Throttle.delay_for(3).should eq(5.seconds)
    Partiduo::Auth::Throttle.delay_for(4).should eq(10.seconds)
    Partiduo::Auth::Throttle.delay_for(5).should eq(20.seconds)
    Partiduo::Auth::Throttle.delay_for(30).should eq(15.minutes)

    created = AuthSpec.create_user
    2.times { AuthSpec.login(password: "Mauvais42MotDePasse").error_keys.should eq(["auth.errors.login.invalid_credentials"]) }
    AuthSpec.login(password: "Mauvais42MotDePasse") # 3ᵉ échec : temporisation
    throttled = AuthSpec.login                      # même le bon mot de passe est refusé sans examen
    throttled.error_keys.should eq(["auth.errors.login.throttled"])
    throttled.errors.first.params["seconds"].to_i.should be > 0
    AuthSpec.user_model(created.user.id).failed_attempts.should eq(3)

    age_failures(created.user.id)
    AuthSpec.login.success?.should be_true
    AuthSpec.user_model(created.user.id).failed_attempts.should eq(0)
  end

  it "bloque le compte au dixième échec, même avec le bon mot de passe ensuite" do
    created = AuthSpec.create_user
    keys = [] of String
    10.times do
      keys = AuthSpec.login(password: "Mauvais42MotDePasse").error_keys
      age_failures(created.user.id)
    end
    keys.should eq(["auth.errors.login.locked"])
    user = AuthSpec.user_model(created.user.id)
    user.locked?.should be_true
    user.failed_attempts.should eq(10)
    AuthSpec.login.error_keys.should eq(["auth.errors.login.locked"])
  end

  it "débloque par l'administrateur" do
    created = AuthSpec.create_user
    AuthSpec.user_model(created.user.id).tap { |user| user.locked_at = Time.utc; user.failed_attempts = 10 }.save!
    AuthSpec.login.error_keys.should eq(["auth.errors.login.locked"])

    Partiduo::Api::Auth.unlock_user(AuthSpec.system, created.user.id).value!.locked.should be_false
    AuthSpec.login.success?.should be_true
  end

  it "débloque par jeton à usage unique" do
    created = AuthSpec.create_user
    anonymous = Partiduo::Api::Actor.anonymous
    Partiduo::Api::Auth.request_unlock(anonymous, "alice@example.com").should be_nil # pas bloqué
    AuthSpec.user_model(created.user.id).tap { |user| user.locked_at = Time.utc; user.failed_attempts = 10 }.save!

    token = Partiduo::Api::Auth.request_unlock(anonymous, "alice@example.com") || raise "jeton attendu"
    token.purpose.should eq("unlock")
    Partiduo::Api::Auth.unlock_with_token(anonymous, token.token).success?.should be_true
    Partiduo::Api::Auth.unlock_with_token(anonymous, token.token).error_keys.should eq(["auth.errors.token.invalid"])
    AuthSpec.login.success?.should be_true
  end

  it "débloque par la remise à zéro du mot de passe, qui coupe les sessions" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    AuthSpec.user_model(created.user.id).tap { |user| user.locked_at = Time.utc; user.failed_attempts = 10 }.save!
    anonymous = Partiduo::Api::Actor.anonymous
    Partiduo::Api::Auth.request_password_reset(anonymous, "personne@example.com").should be_nil
    reset = Partiduo::Api::Auth.request_password_reset(anonymous, "alice@example.com") || raise "jeton attendu"

    Partiduo::Api::Auth.reset_password(anonymous, reset.token, "court").error_keys
      .should contain("auth.errors.password.too_short")
    Partiduo::Api::Auth.reset_password(anonymous, reset.token, "Renouvele42MotDePasse").success?.should be_true
    Partiduo::Api::Auth.reset_password(anonymous, reset.token, "Encore42AutreMotDePasse").error_keys
      .should eq(["auth.errors.token.invalid"])

    AuthSpec.actor(token).authenticated?.should be_false
    AuthSpec.login(password: "Renouvele42MotDePasse").success?.should be_true
  end

  it "consigne succès et échecs dans le journal d'audit, nominativement" do
    created = AuthSpec.create_user
    AuthSpec.login(password: "Mauvais42MotDePasse")
    AuthSpec.login
    events = Partiduo::Api::Auth.audit_events(AuthSpec.system,
      Partiduo::Api::Auth::AuditQuery.new(user_id: created.user.id))
    events.map { |event| {event.action, event.state} }.should contain({"login.password", "FAIL"})
    events.map { |event| {event.action, event.state} }.should contain({"login.password", "SUCCESS"})
    events.first.user_label.should eq("Alice Martin <alice@example.com>")
    events.first.ip.should eq("192.0.2.1")
  end

  it "ferme la session à la déconnexion" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    Partiduo::Api::Auth.session(token).try(&.method).should eq("password")
    Partiduo::Api::Auth.logout(Partiduo::Api::Actor.anonymous, token)
    Partiduo::Api::Auth.session(token).should be_nil
    AuthSpec.actor(token).should eq(Partiduo::Api::Actor.anonymous)
  end

  it "expire une session inactive" do
    AuthSpec.create_user
    token = AuthSpec.session_token
    session = Partiduo::Auth::Session.filter(token_digest: Partiduo::Auth::Secrets.digest(token)).first!
    session.last_seen_at = Time.utc - 2.hours
    session.save!
    AuthSpec.actor(token).authenticated?.should be_false
  end
end
