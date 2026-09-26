# SPDX-License-Identifier: AGPL-3.0-or-later

require "../../spec_helper"

describe Partiduo::Api::Result do
  it "porte une valeur en cas de succès" do
    result = Partiduo::Api::Result(Int32).success(42)
    result.success?.should be_true
    result.value!.should eq(42)
    result.errors.should be_empty
  end

  it "porte des erreurs par champ en cas d'échec" do
    error = Partiduo::Api::FieldError.new("date", "accounting.errors.entry.account_missing")
    result = Partiduo::Api::Result(Int32).failure(error)

    result.failure?.should be_true
    result.value?.should be_nil
    result.errors_for("date").should eq([error])
    result.error_keys.should eq(["accounting.errors.entry.account_missing"])
    expect_raises(NilAssertionError) { result.value! }
  end

  it "refuse un échec sans erreur" do
    expect_raises(ArgumentError) { Partiduo::Api::Result(Int32).failure([] of Partiduo::Api::FieldError) }
  end
end

describe Partiduo::Api::FieldError do
  it "traduit sa clé dans la langue courante, paramètres compris" do
    error = Partiduo::Api::FieldError.base("accounting.errors.entry.too_few_lines", {"min" => "2"})
    error.base?.should be_true

    I18n.with_locale("fr") { error.message.should eq("Une écriture compte au moins 2 lignes.") }
    I18n.with_locale("en") { error.message.should eq("An entry has at least 2 lines.") }
    I18n.with_locale("nl") { error.message.should eq("Een boeking telt minstens 2 lijnen.") }
  end
end
