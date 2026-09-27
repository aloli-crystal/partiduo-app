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

describe "Partiduo::Api::Transaction imbriquée (D-024)" do
  it "renvoie l'échec d'une commande appelée dans une autre, n'annule que ses écritures" do
    inner = nil
    result = Partiduo::Api::Transaction.run do
      create_user("appelant@example.org")
      inner = Partiduo::Api::Transaction.run do
        create_user("appelee@example.org")
        Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.new("email", "auth.errors.user.email_taken"))
      end
      Partiduo::Api::Result(Nil).success(nil)
    end

    result.success?.should be_true
    failed = inner || raise "résultat imbriqué absent"
    failed.failure?.should be_true
    failed.errors.map(&.field).should eq(["email"])
    Partiduo::Auth::User.filter(email: "appelant@example.org").exists?.should be_true
    Partiduo::Auth::User.filter(email: "appelee@example.org").exists?.should be_false
  end

  it "garde les écritures d'une commande imbriquée réussie, annulées avec l'appelant" do
    result = Partiduo::Api::Transaction.run do
      Partiduo::Api::Transaction.run do
        create_user("imbriquee@example.org")
        Partiduo::Api::Result(Nil).success(nil)
      end
      Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("accounting.errors.entry.unbalanced"))
    end

    result.failure?.should be_true
    Partiduo::Auth::User.filter(email: "imbriquee@example.org").exists?.should be_false
  end

  it "annule le point de sauvegarde sur une exception et laisse l'appelant la traiter" do
    result = Partiduo::Api::Transaction.run do
      create_user("garde@example.org")
      begin
        Partiduo::Api::Transaction.run do
          create_user("exception-imbriquee@example.org")
          Partiduo::Events.ensure_known!("inconnu")
          Partiduo::Api::Result(Nil).success(nil)
        end
      rescue ArgumentError
      end
      Partiduo::Api::Result(Nil).success(nil)
    end

    result.success?.should be_true
    Partiduo::Auth::User.filter(email: "garde@example.org").exists?.should be_true
    Partiduo::Auth::User.filter(email: "exception-imbriquee@example.org").exists?.should be_false
  end

  it "abandonne les effets extérieurs d'un point de sauvegarde annulé" do
    effects = [] of String
    Partiduo::Api::Transaction.run do
      Partiduo::Api::Transaction.run do
        Partiduo::Events.after_commit { effects << "annule" }
        Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("accounting.errors.entry.unbalanced"))
      end
      Partiduo::Api::Transaction.run do
        Partiduo::Events.after_commit { effects << "garde" }
        Partiduo::Api::Result(Nil).success(nil)
      end
      effects.should be_empty
      Partiduo::Api::Result(Nil).success(nil)
    end
    effects.should eq(["garde"])
  end
end
