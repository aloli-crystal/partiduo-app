# SPDX-License-Identifier: AGPL-3.0-or-later

require "../../spec_helper"

private def create_user(email : String) : Partiduo::Auth::User
  user = Partiduo::Auth::User.new(email: email)
  user.set_unusable_password
  user.save!
  user
end

describe Partiduo::Api::Transaction do
  it "valide les écritures d'une commande réussie" do
    result = Partiduo::Api::Transaction.run do
      Partiduo::Api::Result(Int64).success(create_user("ok@example.org").pk!.as(Int64))
    end

    result.success?.should be_true
    Partiduo::Auth::User.filter(email: "ok@example.org").exists?.should be_true
  end

  it "annule tout quand la commande échoue" do
    result = Partiduo::Api::Transaction.run do
      create_user("annule@example.org")
      Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("accounting.errors.entry.unbalanced"))
    end

    result.failure?.should be_true
    Partiduo::Auth::User.filter(email: "annule@example.org").exists?.should be_false
  end

  it "annule tout et propage l'exception d'un abonné" do
    expect_raises(ArgumentError, "événement inconnu : abonné en échec") do
      Partiduo::Api::Transaction.run do
        create_user("exception@example.org")
        Partiduo::Events.ensure_known!("abonné en échec")
        Partiduo::Api::Result(Nil).success(nil)
      end
    end

    Partiduo::Auth::User.filter(email: "exception@example.org").exists?.should be_false
  end
end
