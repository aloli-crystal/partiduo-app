# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private def run_provision(*options : String) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  command = Partiduo::Core::Commands::Provision.new(options.to_a, stdout: stdout, stderr: stderr, exit_raises: true)
  code = command.handle
  {code, stdout.to_s, stderr.to_s}
end

describe Partiduo::Core::Commands::Provision do
  it "provisionne l'instance et rend compte dans sa langue, pluriels compris" do
    with_active_modules("accounting,invoicing") do
      code, output, _ = run_provision(
        "--name=Exemple SARL", "--regime=fr", "--siren=732829320", "--capital=10000.00",
        "--domain=exemple.partiduo.localhost", "--modules=accounting,invoicing", "--auth-level=2",
      )

      code.should eq(0)
      output.should contain("Dossier « Exemple SARL » créé : exemple.partiduo.localhost.")
      output.should contain("Régime fiscal : France.")
      output.should contain("2 modules activés : ACCOUNTING, INVOICING.")
      settings = Partiduo::Api::Core.settings(actor_with)
      settings.share_capital.should eq(BigDecimal.new(10000))
      settings.auth_minimum_level.should eq(2)
    end
  end

  it "rend compte en néerlandais pour un dossier en néerlandais" do
    with_active_modules("invoicing") do
      code, output, _ = run_provision(
        "--name=Voorbeeld BV", "--regime=be", "--locale=nl", "--domain=voorbeeld.partiduo.localhost",
        "--modules=invoicing",
      )
      code.should eq(0)
      output.should contain("Fiscaal stelsel: België.")
      output.should contain("1 module geactiveerd: INVOICING.")
    end
  end

  it "affiche les erreurs traduites et échoue" do
    code, _, errors = run_provision("--regime=xx", "--domain=exemple.partiduo.localhost")
    code.should eq(1)
    errors.should contain("company_name : La raison sociale est obligatoire.")
    errors.should contain("tax_regime : Le régime fiscal « xx » est inconnu (fr ou be).")
    errors.should contain("Création du dossier refusée : 3 erreurs.")
    Partiduo::Core::Settings.all.count.should eq(0)
  end

  it "refuse une valeur numérique illisible" do
    code, _, errors = run_provision("--name=X", "--regime=fr", "--capital=dix mille", "--domain=x.partiduo.localhost")
    code.should eq(1)
    errors.should contain("Valeur numérique illisible")
  end
end
