# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs des écritures (lot 2) : dossier français complet (taux et
# comptes de TVA, plan, journaux A01, V01, F01, O01, exercice 2026), fiches,
# saisies par le contrat.
module EntrySpec
  alias Api = Partiduo::Api::Accounting

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.setup(regime : String = "fr", year : Int32 = 2026) : Nil
    Partiduo::Api::Vat.load_rates(system, regime)
    AccountingSpec.load(regime)
    ReferentialSpec.fiscal_year(year)
    nil
  end

  def self.date(text : String) : Time
    ReferentialSpec.date(text)
  end

  def self.ledger(code : String) : Api::LedgerView
    Api.ledger_by_code(system, code)
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  # Fiche d'une catégorie par défaut ; son compte est calculé (D-ACC-006).
  def self.card(category : String, name : String) : Partiduo::Api::Cards::CardView
    found = Partiduo::Api::Cards.category_by_code(system, category) || raise "catégorie #{category} absente"
    ReferentialSpec.card(found.id, name)
  end

  def self.card_account(card : Partiduo::Api::Cards::CardView) : String
    (Api.card_account(system, card.id) || raise "fiche sans compte").account.number
  end

  def self.line(account : String, side : Api::Side, amount : String, card : String? = nil, label : String = "") : Api::EntryLineInput
    Api::EntryLineInput.new(account, side, d(amount), card, label)
  end

  def self.debit(account : String, amount : String, card : String? = nil) : Api::EntryLineInput
    line(account, Api::Side::Debit, amount, card)
  end

  def self.credit(account : String, amount : String, card : String? = nil) : Api::EntryLineInput
    line(account, Api::Side::Credit, amount, card)
  end

  def self.misc_input(lines : Array(Api::EntryLineInput), day : String = "2026-03-15", ledger : String = "O01",
                      **options) : Api::EntryInput
    Api::EntryInput.new(ledger_id: self.ledger(ledger).id, date: date(day), lines: lines).copy_with(**options)
  end

  def self.post_misc(lines : Array(Api::EntryLineInput), day : String = "2026-03-15", ledger : String = "O01",
                     actor : Partiduo::Api::Actor = system, **options) : Api::EntryView
    Api.post_entry(actor, misc_input(lines, day, ledger, **options)).value!
  end

  def self.document(ledger : String, third_party : String, lines : Array(Api::DocumentLineInput),
                    day : String = "2026-03-15", **options) : Api::DocumentInput
    Api::DocumentInput.new(ledger_id: self.ledger(ledger).id, date: date(day), third_party: third_party, lines: lines)
      .copy_with(**options)
  end

  def self.item(amount : String, vat_rate : String? = "NOR", item : String? = nil, **options) : Api::DocumentLineInput
    Api::DocumentLineInput.new(amount: d(amount), item: item, vat_rate: vat_rate).copy_with(**options)
  end

  # Lignes d'une vue par numéro de compte : {sens, montant}.
  def self.lines_by_account(view : Api::EntryView) : Hash(String, Array({String, BigDecimal}))
    view.lines.group_by(&.account_number).transform_values(&.map { |line| {line.side.code, line.amount} })
  end

  def self.period(day : String) : Partiduo::Api::Core::PeriodView
    Partiduo::Api::Core.period_for(system, date(day)) || raise "période absente"
  end

  # SQL direct dans une transaction ouverte sur une connexion *dédiée*, hors
  # du pool de Marten : les déclencheurs différés jouent au `COMMIT`, dont
  # l'échec est levé tel quel. (crystal-db garde une connexion marquée « en
  # transaction » quand son `COMMIT` échoue, BLOCAGES B-ACC-002.)
  def self.sql_transaction(& : DB::Connection ->) : Nil
    DB.connect(Partiduo::Config.database_url) do |db|
      db.exec("BEGIN")
      begin
        yield db
      rescue ex
        db.exec("ROLLBACK")
        raise ex
      end
      db.exec("COMMIT")
    end
  end

  def self.sql(statement : String, *args) : Nil
    Marten::DB::Connection.default.open(&.exec(statement, *args))
  end

  def self.scalar(statement : String, *args)
    Marten::DB::Connection.default.open(&.scalar(statement, *args))
  end
end
