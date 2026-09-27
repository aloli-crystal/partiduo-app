# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Compléments de couverture de la limitation des tentatives (D-AUTH-005) :
# temporisation, blocage au dixième échec quel que soit le secret en cause,
# et les trois voies de déblocage.

private BAD_PASSWORD = "Mauvais42MotDePasse"

# Recule la date du dernier échec : la temporisation en cours est écoulée.
private def age_failures(user_id : Int64, by : Time::Span = 1.hour) : Nil
  user = AuthSpec.user_model(user_id)
  user.last_failed_at = (user.last_failed_at || Time.utc) - by
  user.save!
end

private def second_factor(pending : String, code : String, kind : String = "totp")
  Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous,
    Partiduo::Api::Auth::SecondFactorInput.new(pending_token: pending, code: code, kind: kind))
end

private def failures(user_id : Int64) : Int32
  (AuthSpec.user_model(user_id).failed_attempts || 0).to_i32
end

private def audit_actions(user_id : Int64) : Array({String, String})
  Partiduo::Api::Auth.audit_events(AuthSpec.system, Partiduo::Api::Auth::AuditQuery.new(user_id: user_id))
    .map { |event| {event.action, event.state} }
end

describe "Limitation des tentatives : temporisation (D-AUTH-005)" do
  it "ne temporise pas avant le troisième échec" do
    created = AuthSpec.create_user
    2.times { AuthSpec.login(password: BAD_PASSWORD) }
    Partiduo::Auth::Throttle.retry_after(AuthSpec.user_model(created.user.id)).should be_nil
    AuthSpec.login.success?.should be_true
  end

  it "ne compte pas une tentative refusée pendant la temporisation, même fausse" do
    created = AuthSpec.create_user
    3.times { AuthSpec.login(password: BAD_PASSWORD) }
    failures(created.user.id).should eq(3)

    5.times { AuthSpec.login(password: BAD_PASSWORD).error_keys.should eq(["auth.errors.login.throttled"]) }
    failures(created.user.id).should eq(3) # le secret n'a pas été examiné
    audit_actions(created.user.id).count({"login.password", "FAIL"}).should eq(8)
  end

  it "double le délai à chaque échec, et en rend compte en secondes" do
    created = AuthSpec.create_user
    3.times { AuthSpec.login(password: BAD_PASSWORD) }
    first = AuthSpec.login.errors.first.params["count"].to_i
    first.should be <= 5
    first.should be > 0

    age_failures(created.user.id)
    AuthSpec.login(password: BAD_PASSWORD).error_keys.should eq(["auth.errors.login.invalid_credentials"])
    second = AuthSpec.login.errors.first.params["count"].to_i
    second.should be > 5
    second.should be <= 10
  end

  it "plafonne le délai à quinze minutes" do
    Partiduo::Auth::Throttle.delay_for(9).should eq(320.seconds)  # 5 s × 2⁶
    Partiduo::Auth::Throttle.delay_for(10).should eq(640.seconds) # 5 s × 2⁷
    Partiduo::Auth::Throttle.delay_for(11).should eq(15.minutes)  # 1 280 s, plafonné
    (3..1000).each { |count| Partiduo::Auth::Throttle.delay_for(count).should be <= 15.minutes }
    Partiduo::Auth::Throttle.delay_for(0).should eq(Time::Span.zero)
  end

  it "remet le compteur à zéro après un succès : les échecs suivants repartent de un" do
    created = AuthSpec.create_user
    2.times { AuthSpec.login(password: BAD_PASSWORD) }
    AuthSpec.login.success?.should be_true
    failures(created.user.id).should eq(0)
    2.times { AuthSpec.login(password: BAD_PASSWORD) }
    failures(created.user.id).should eq(2)
    AuthSpec.login.success?.should be_true
  end

  it "réserve les tentatives de façon atomique, même sur une copie périmée" do
    created = AuthSpec.create_user
    first = AuthSpec.user_model(created.user.id)
    second = AuthSpec.user_model(created.user.id) # copie lue avant la première réservation
    Partiduo::Auth::Throttle.reserve(first).count.should eq(1)
    Partiduo::Auth::Throttle.reserve(second).count.should eq(2)
    failures(created.user.id).should eq(2)
  end

  it "n'examine pas plus de secrets que la temporisation n'en admet sous des requêtes simultanées (D-AUTH-012)" do
    created = AuthSpec.create_user
    done = Channel(Array(String)).new
    20.times do
      spawn { done.send(AuthSpec.login(password: BAD_PASSWORD).error_keys) }
    end
    keys = Array.new(20) { done.receive }.flatten
    keys.count("auth.errors.login.invalid_credentials").should eq(3)
    keys.count("auth.errors.login.throttled").should eq(17)
    failures(created.user.id).should eq(3)
  end

  it "rend la tentative d'un mot de passe juste suivi d'un second facteur, sans remise à zéro" do
    created = AuthSpec.create_user
    AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    2.times { AuthSpec.login(password: BAD_PASSWORD) }
    AuthSpec.login.value!.pending_token!.should_not be_empty
    failures(created.user.id).should eq(2)
    AuthSpec.login(password: BAD_PASSWORD) # 3ᵉ échec
    AuthSpec.login.error_keys.should eq(["auth.errors.login.throttled"])
  end

  it "temporise aussi le second facteur, sans examiner le code" do
    created = AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    pending = AuthSpec.login.value!.pending_token!
    3.times { second_factor(pending, "000000") }
    failures(created.user.id).should eq(3)

    refused = second_factor(pending, AuthSpec.totp_code(secret))
    refused.error_keys.should eq(["auth.errors.login.throttled"])
    failures(created.user.id).should eq(3)

    age_failures(created.user.id)
    second_factor(pending, AuthSpec.totp_code(secret)).value!.level.should eq(2)
    failures(created.user.id).should eq(0)
  end

  it "temporise l'élévation par TOTP et y compte les codes faux" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    anonymous = Partiduo::Api::Actor.anonymous
    3.times do
      Partiduo::Api::Auth.elevate_with_totp(anonymous, token, "000000").error_keys
        .should eq(["auth.errors.login.invalid_code"])
    end
    failures(created.user.id).should eq(3)
    Partiduo::Api::Auth.elevate_with_totp(anonymous, token, AuthSpec.totp_code(secret)).error_keys
      .should eq(["auth.errors.login.throttled"])
    AuthSpec.actor(token).level.should eq(1)
  end
end

describe "Limitation des tentatives : blocage au dixième échec (D-AUTH-005)" do
  it "bloque par des codes TOTP faux ; le bon code ne passe plus" do
    created = AuthSpec.create_user
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    pending = AuthSpec.login.value!.pending_token!
    keys = [] of String
    10.times do
      keys = second_factor(pending, "000000").error_keys
      age_failures(created.user.id)
    end
    keys.should eq(["auth.errors.login.locked"])
    AuthSpec.user_model(created.user.id).locked?.should be_true

    second_factor(pending, AuthSpec.totp_code(secret)).error_keys.should eq(["auth.errors.login.locked"])
    AuthSpec.login.error_keys.should eq(["auth.errors.login.locked"])
  end

  it "additionne les échecs de mot de passe, de code TOTP et de code de récupération" do
    created = AuthSpec.create_user
    AuthSpec.enable_totp(AuthSpec.actor(AuthSpec.session_token))
    4.times do
      AuthSpec.login(password: BAD_PASSWORD)
      age_failures(created.user.id)
    end
    pending = AuthSpec.login.value!.pending_token! # bon mot de passe : l'étape 1 réussit…
    failures(created.user.id).should eq(4)         # … sans remettre le compteur à zéro
    3.times do
      second_factor(pending, "000000")
      age_failures(created.user.id)
    end
    2.times do
      second_factor(pending, "AAAA-BBBB-CCCC-DDDD", "recovery_code")
      age_failures(created.user.id)
    end
    failures(created.user.id).should eq(9)
    AuthSpec.user_model(created.user.id).locked?.should be_false

    second_factor(pending, "AAAA-BBBB-CCCC-DDDD", "recovery_code").error_keys.should eq(["auth.errors.login.locked"])
    AuthSpec.user_model(created.user.id).locked?.should be_true
  end

  it "consigne le blocage dans le journal d'audit" do
    created = AuthSpec.create_user
    10.times do
      AuthSpec.login(password: BAD_PASSWORD)
      age_failures(created.user.id)
    end
    audit_actions(created.user.id).should contain({"account.lock", "FAIL"})
    AuthSpec.login # refus d'un compte bloqué, consigné aussi
    events = Partiduo::Api::Auth.audit_events(AuthSpec.system, Partiduo::Api::Auth::AuditQuery.new(user_id: created.user.id))
    events.any? { |event| event.detail == "locked" }.should be_true
  end

  it "laisse entrer par passkey un compte bloqué, sans lever le blocage du mot de passe" do
    created = AuthSpec.create_user
    authenticator, _enrollment = AuthSpec.enroll_passkey(AuthSpec.actor(AuthSpec.session_token))
    AuthSpec.user_model(created.user.id).tap { |user| user.locked_at = Time.utc; user.failed_attempts = 10 }.save!

    AuthSpec.passkey_login(authenticator).value!.level.should eq(3) # la passkey ne se devine pas
    AuthSpec.user_model(created.user.id).locked?.should be_true
    AuthSpec.login.error_keys.should eq(["auth.errors.login.locked"])
  end

  it "refuse l'élévation par TOTP d'une session dont le compte est bloqué" do
    created = AuthSpec.create_user
    token = AuthSpec.session_token
    secret, _codes = AuthSpec.enable_totp(AuthSpec.actor(token))
    AuthSpec.user_model(created.user.id).tap { |user| user.locked_at = Time.utc; user.failed_attempts = 10; user.last_failed_at = nil }.save!
    Partiduo::Api::Auth.elevate_with_totp(Partiduo::Api::Actor.anonymous, token, AuthSpec.totp_code(secret))
      .error_keys.should eq(["auth.errors.login.locked"])
  end
end

describe "Limitation des tentatives : déblocage (D-AUTH-005)" do
  it "réserve le déblocage par l'administrateur à auth.users.manage et le consigne" do
    created = AuthSpec.create_user
    AuthSpec.user_model(created.user.id).tap { |user| user.locked_at = Time.utc; user.failed_attempts = 10 }.save!
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.unlock_user(actor_with, created.user.id) }
    expect_raises(Partiduo::Api::Forbidden) { Partiduo::Api::Auth.unlock_user(Partiduo::Api::Actor.anonymous, created.user.id) }
    AuthSpec.user_model(created.user.id).locked?.should be_true

    view = Partiduo::Api::Auth.unlock_user(actor_with("auth.users.manage"), created.user.id).value!
    view.locked.should be_false
    view.failed_attempts.should eq(0)
    Partiduo::Api::Auth.audit_events(AuthSpec.system, Partiduo::Api::Auth::AuditQuery.new(state: "ADMIN"))
      .map(&.action).should contain("user.unlock")
  end

  it "fait repartir le compteur de zéro après le déblocage" do
    created = AuthSpec.create_user
    10.times do
      AuthSpec.login(password: BAD_PASSWORD)
      age_failures(created.user.id)
    end
    Partiduo::Api::Auth.unlock_user(AuthSpec.system, created.user.id)
    AuthSpec.login(password: BAD_PASSWORD).error_keys.should eq(["auth.errors.login.invalid_credentials"])
    failures(created.user.id).should eq(1)
    AuthSpec.login.success?.should be_true
  end

  it "lève NotFound pour un utilisateur inconnu" do
    expect_raises(Partiduo::Api::NotFound) { Partiduo::Api::Auth.unlock_user(AuthSpec.system, 999_999_i64) }
  end

  it "ne délivre de jeton de déblocage qu'à un compte bloqué et connu" do
    AuthSpec.create_user
    anonymous = Partiduo::Api::Actor.anonymous
    Partiduo::Api::Auth.request_unlock(anonymous, "personne@example.com").should be_nil
    Partiduo::Api::Auth.request_unlock(anonymous, "alice@example.com").should be_nil
  end

  it "refuse un jeton de déblocage expiré, remplacé ou d'un autre usage" do
    created = AuthSpec.create_user
    AuthSpec.user_model(created.user.id).tap { |user| user.locked_at = Time.utc; user.failed_attempts = 10 }.save!
    anonymous = Partiduo::Api::Actor.anonymous

    first = Partiduo::Api::Auth.request_unlock(anonymous, "Alice@Example.com") || raise "jeton attendu"
    first.expires_at.should be <= Time.utc + 1.hour
    first.expires_at.should be > Time.utc + 59.minutes
    first.email.should eq("alice@example.com")                                       # adresse enregistrée, pas celle saisie
    Partiduo::Api::Auth.request_unlock(anonymous, "alice@example.com").should be_nil # demande trop rapprochée
    Partiduo::Auth::Token.filter(purpose: "unlock").update(created_at: Time.utc - 3.minutes)
    second = Partiduo::Api::Auth.request_unlock(anonymous, "alice@example.com") || raise "jeton attendu"
    Partiduo::Api::Auth.unlock_with_token(anonymous, first.token).error_keys.should eq(["auth.errors.token.invalid"])

    reset = Partiduo::Api::Auth.request_password_reset(anonymous, "alice@example.com") || raise "jeton attendu"
    Partiduo::Api::Auth.unlock_with_token(anonymous, reset.token).error_keys.should eq(["auth.errors.token.invalid"])
    Partiduo::Api::Auth.unlock_with_token(anonymous, "").error_keys.should eq(["auth.errors.token.invalid"])

    Partiduo::Auth::Token.filter(purpose: "unlock").update(expires_at: Time.utc - 1.second)
    Partiduo::Api::Auth.unlock_with_token(anonymous, second.token).error_keys.should eq(["auth.errors.token.invalid"])
    AuthSpec.user_model(created.user.id).locked?.should be_true
  end

  it "consigne le déblocage par jeton et remet le compteur à zéro" do
    created = AuthSpec.create_user
    AuthSpec.user_model(created.user.id).tap { |user| user.locked_at = Time.utc; user.failed_attempts = 10; user.last_failed_at = Time.utc }.save!
    anonymous = Partiduo::Api::Actor.anonymous
    token = Partiduo::Api::Auth.request_unlock(anonymous, "alice@example.com") || raise "jeton attendu"
    Partiduo::Api::Auth.unlock_with_token(anonymous, token.token).success?.should be_true

    user = AuthSpec.user_model(created.user.id)
    user.locked?.should be_false
    user.failed_attempts.should eq(0)
    user.last_failed_at.should be_nil
    audit_actions(created.user.id).should contain({"account.unlock", "SUCCESS"})
  end
end
