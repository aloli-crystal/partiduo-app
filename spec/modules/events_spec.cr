# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Pièce de spec abonnée à `entry.posted`, retirée du registre après le bloc.
def with_subscriber(& : String, Array(Partiduo::Events::Event) ->) : Nil
  received = [] of Partiduo::Events::Event
  code = "SPEC#{Random::Secure.hex(3).upcase}"
  Partiduo::Modules.register do
    code code
    on("entry.posted") do |event|
      raise "refus de l'abonné" if event["entry_id"] == "0"
      received << event
    end
  end
  begin
    yield code, received
  ensure
    Partiduo::Modules.manifests.delete(code)
  end
end

describe Partiduo::Events do
  it "couvre la liste fermée de l'ADR-003 D7 et de l'ADR-006 D3 (plus payment.unmatched, D-2F-003, delivery_note.issued, D-STK-004, et les registres micro et liberal, ADR-007 D2, D6)" do
    Partiduo::Events::NAMES.sort.should eq(%w[
      card.saved credit_note.issued delivery_note.issued entry.cancelled entry.posted
      invoice.issued invoice.platform_deposited liberal.asset.recorded liberal.expense.recorded liberal.receipt.recorded
      micro.purchase.recorded micro.receipt.recorded payment.matched payment.recorded
      payment.unmatched period.closed
    ])
  end

  it "refuse un événement inconnu ou une charge utile incomplète" do
    expect_raises(ArgumentError, /événement inconnu/) { Partiduo::Events.publish("entry.deleted") }
    expect_raises(ArgumentError, /clé\(s\) manquante\(s\) entry_id/) { Partiduo::Events.publish("entry.posted") }
  end

  it "n'appelle que les abonnés des pièces actives" do
    with_subscriber do |code, received|
      with_active_modules(code.downcase) do
        Partiduo::Events.subscribers("entry.posted").should eq([code])
        Partiduo::Events.publish("entry.posted", {"entry_id" => "7"}, actor_user_id: 3_i64)
      end
      with_active_modules("accounting") do
        Partiduo::Events.subscribers("entry.posted").should_not contain(code)
        Partiduo::Events.publish("entry.posted", {"entry_id" => "8"})
      end

      received.map(&.["entry_id"]).should eq(["7"])
      received.first.actor_user_id.should eq(3_i64)
      received.first["absent"]?.should be_nil
      expect_raises(KeyError) { received.first["absent"] }
    end
  end

  it "publie dans la transaction : l'échec d'un abonné annule l'opération" do
    with_subscriber do |code, _received|
      with_active_modules("none") do
        expect_raises(Exception, "refus de l'abonné") do
          Partiduo::Api::Transaction.run do
            # L'état enregistré active l'abonné ; il disparaît avec l'annulation.
            Partiduo::Modules::Activation.create!(code: code, active: true)
            Partiduo::Modules.active?(code).should be_true
            Partiduo::Events.publish("entry.posted", {"entry_id" => "0"})
            Partiduo::Api::Result(Nil).success(nil)
          end
        end
        Partiduo::Modules::Activation.filter(code: code).exists?.should be_false
        Partiduo::Modules.active?(code).should be_false
      end
    end
  end

  it "exécute les effets extérieurs après la validation seulement" do
    effects = [] of String
    Partiduo::Api::Transaction.run do
      Partiduo::Events.after_commit { effects << "validé" }
      effects.should be_empty
      Partiduo::Api::Result(Nil).success(nil)
    end
    effects.should eq(["validé"])

    Partiduo::Api::Transaction.run do
      Partiduo::Events.after_commit { effects << "annulé" }
      Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("modules.errors.activation.socle"))
    end
    effects.should eq(["validé"])

    Partiduo::Events.after_commit { effects << "immédiat" }
    effects.should eq(["validé", "immédiat"])
  end
end
