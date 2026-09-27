# SPDX-License-Identifier: AGPL-3.0-or-later

# Outils des specs du module Stock (lot 6) : dépôts, articles suivis et
# mouvements créés par le contrat.
module StockSpec
  alias Api = Partiduo::Api::Stock

  record Setup,
    main : Api::RepositoryView,
    annex : Api::RepositoryView,
    screws : Partiduo::Api::Cards::CardView,
    bolts : Partiduo::Api::Cards::CardView,
    service : Partiduo::Api::Cards::CardView

  def self.system : Partiduo::Api::Actor
    Partiduo::Api::Actor.system
  end

  def self.d(text : String) : BigDecimal
    BigDecimal.new(text)
  end

  def self.date(text : String) : Time
    Time.parse_utc(text, "%Y-%m-%d")
  end

  def self.repository(name : String, **options) : Api::RepositoryView
    Api.create_repository(system, Api::RepositoryInput.new(name: name).copy_with(**options)).value!
  end

  # Deux dépôts (le premier par défaut), deux articles suivis, une
  # prestation non suivie ; catégorie `GOODS` créée si elle manque.
  def self.setup : Setup
    category = Partiduo::Api::Cards.category_by_code(system, "GOODS") ||
               ReferentialSpec.category("GOODS", "item", "Marchandises")
    screws = ReferentialSpec.card(category.id, "Vis inox", code: "VIS")
    bolts = ReferentialSpec.card(category.id, "Boulons", code: "BOULON")
    service = ReferentialSpec.card(category.id, "Montage", code: "MONTAGE")
    main = repository("Entrepôt principal", city: "Nantes", country_code: "fr")
    annex = repository("Annexe")
    Api.track_item(system, Api::ItemInput.new(screws.id)).value!
    Api.track_item(system, Api::ItemInput.new(bolts.id, "BOUL-01")).value!
    Setup.new(main, annex, screws, bolts, service)
  end

  def self.change(repository : Api::RepositoryView, day : String, *lines : {Partiduo::Api::Cards::CardView, String, String?},
                  comment : String = "") : Api::ChangeView
    rows = lines.to_a.map do |(card, quantity, cost)|
      Api::ChangeLineInput.new(card.id, d(quantity), cost.try { |value| d(value) })
    end
    input = Api::ChangeInput.new(repository.id, date(day), rows, comment)
    result = Api.record_change(system, input)
    raise "mouvement refusé : #{result.error_keys.join(", ")}" if result.failure?
    result.value!
  end

  def self.quantity(card : Partiduo::Api::Cards::CardView, day : String = "2026-12-31", repository : Api::RepositoryView? = nil) : BigDecimal
    Api.quantity(system, card.id, date(day), repository.try(&.id))
  end

  def self.row(state : Api::StateView, repository : Api::RepositoryView, code : String) : Api::StateRowView
    state.rows.find! { |row| row.repository_id == repository.id && row.stock_code == code }
  end
end
