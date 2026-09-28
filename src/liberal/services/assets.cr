# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Liberal
    # Registre des immobilisations et des amortissements (ADR-007 D6) :
    # acquisition, contre-passation la même année, cession, plan
    # d'amortissement linéaire, tableau de la 2035-B et plus ou moins-values.
    # Publie `liberal.asset.recorded` (`operation` : `acquisition`,
    # `reversal`, `disposal`). Service interne.
    #
    # Amortissement linéaire (DECISIONS D-LIB-005) : annuité = base ÷ durée ;
    # prorata temporis en jours, sur une année de 360 jours (mois de 30
    # jours), la première année depuis la mise en service et l'année de la
    # cession jusqu'à la cession ; la dernière annuité solde la base ; chaque
    # annuité est arrondie au centime.
    module Assets
      alias FieldError = Partiduo::Api::FieldError
      alias Api = Partiduo::Api::Liberal

      # Terrains et clientèle : non amortissables (durée 0 imposée).
      NON_DEPRECIABLE = %w[land goodwill]

      def self.error(field : String, code : String, params : Hash(String, String) = {} of String => String) : FieldError
        Registers.error(field, code, params)
      end

      def self.day(time : Time) : Time
        Registers.day(time)
      end

      def self.zero : BigDecimal
        BigDecimal.new(0)
      end

      # --- Contrôle -------------------------------------------------------------------

      def self.errors(input : Api::AssetInput, actor : Partiduo::Api::Actor, manual : Bool = true) : Array(FieldError)
        errors = [] of FieldError
        errors << error("label", "asset.label.blank") if input.label.strip.empty?
        unless Api::ASSET_CATEGORIES.includes?(input.category)
          errors << error("category", "asset.category.invalid")
        end
        errors.concat(Registers.date_errors(input.acquired_on, manual, "acquired_on"))
        if (service_on = input.service_on) && day(service_on) < day(input.acquired_on)
          errors << error("service_on", "asset.service_before_acquisition")
        end
        errors.concat(Registers.amount_errors("amount", input.amount))
        if input.duration_years < 0 || input.duration_years > 50
          errors << error("duration_years", "asset.duration.invalid")
        elsif input.duration_years > 0 && NON_DEPRECIABLE.includes?(input.category)
          errors << error("duration_years", "asset.duration.not_depreciable")
        end
        errors << error("method", "line.method.invalid") unless Api::METHODS.includes?(input.method)
        errors.concat(Registers.party_errors(input.card_id, input.party_name, input.label, input.reference,
          input.attachment_id, actor))
        errors
      end

      # Contre-passation : immobilisation vivante, sans cession, la même
      # année civile que l'acquisition (au-delà, l'immobilisation a déjà
      # compté dans une 2035 : on la cède), hors période close.
      def self.reverse_errors(row : Asset, input : Api::ReverseInput) : Array(FieldError)
        errors = [] of FieldError
        errors << error("id", "line.reversal.is_reversal") if row.reversal_of_id
        errors << error("id", "line.reversal.already") if Asset.filter(reversal_of_id: row.pk).exists?
        errors << error("id", "asset.reversal.disposed") if Disposal.filter(asset_id: row.pk).exists?
        date = day(input.date)
        errors << error("date", "line.reversal.before_line") if date < row.acquired_on!
        errors << error("date", "asset.reversal.other_year") if date.year != row.acquired_on!.year
        errors.concat(Registers.date_errors(input.date))
        errors
      end

      def self.disposal_errors(input : Api::DisposalInput) : Array(FieldError)
        errors = [] of FieldError
        asset = Asset.filter(id: input.asset_id).first
        if asset.nil? || asset.reversal_of_id || Asset.filter(reversal_of_id: asset.pk).exists?
          errors << error("asset_id", "disposal.asset.unknown")
        elsif Disposal.filter(asset_id: asset.pk).exists?
          errors << error("asset_id", "disposal.asset.already")
        elsif day(input.date) < asset.acquired_on!
          errors << error("date", "disposal.before_acquisition")
        end
        errors.concat(Registers.date_errors(input.date))
        if input.price < 0 || input.price.round(2) != input.price
          errors << error("price", "disposal.price.invalid")
        end
        errors << error("method", "line.method.invalid") unless Api::METHODS.includes?(input.method)
        errors << error("reference", "line.too_long", {"max" => "100"}) if input.reference.size > 100
        errors
      end

      # --- Inscription ----------------------------------------------------------------

      def self.create!(input : Api::AssetInput, actor_user_id : Int64?) : Asset
        acquired_on = day(input.acquired_on)
        asset = Asset.create!(number: Registers.next_number("asset", acquired_on), label: input.label.strip,
          category: input.category, acquired_on: acquired_on, service_on: day(input.service_on || acquired_on),
          amount: input.amount, duration_years: input.duration_years, method: input.method, card_id: input.card_id,
          party_name: Registers.party_name(input.card_id, input.party_name), reference: input.reference.strip,
          attachment_id: input.attachment_id, recorded_by_id: actor_user_id, recorded_at: Time.utc)
        publish(asset, "acquisition", asset.acquired_on!, asset.amount!, actor_user_id)
        asset
      end

      def self.reverse!(row : Asset, input : Api::ReverseInput, actor_user_id : Int64?) : Asset
        date = day(input.date)
        label = input.label.strip.presence || I18n.t("liberal.reversal_label", {"number" => row.number.to_s})
        reversal = Asset.create!(number: Registers.next_number("asset", date), label: label,
          category: row.category, acquired_on: date, service_on: date, amount: -row.amount!,
          duration_years: row.duration_years, method: row.method, card_id: row.card_id, party_name: row.party_name,
          reference: row.number, reversal_of_id: row.pk, recorded_by_id: actor_user_id, recorded_at: Time.utc)
        publish(reversal, "reversal", date, reversal.amount!, actor_user_id)
        reversal
      end

      def self.dispose!(input : Api::DisposalInput, actor_user_id : Int64?) : Disposal
        asset = Asset.filter(id: input.asset_id).first || raise Partiduo::Api::NotFound.new("liberal_asset", input.asset_id)
        disposal = Disposal.create!(asset_id: input.asset_id, date: day(input.date), price: input.price,
          method: input.method, reference: input.reference.strip, recorded_by_id: actor_user_id, recorded_at: Time.utc)
        publish(asset, "disposal", disposal.date!, disposal.price!, actor_user_id, disposal)
        disposal
      end

      # Charge utile complète (ADR-006 D3) : la Comptabilité passe l'écriture
      # d'acquisition, d'annulation ou d'encaissement du prix de cession.
      def self.publish(asset : Asset, operation : String, date : Time, amount : BigDecimal, actor_user_id : Int64?,
                       disposal : Disposal? = nil) : Nil
        Partiduo::Events.publish("liberal.asset.recorded", {
          "asset_id"       => asset.pk!.to_s,
          "operation"      => operation,
          "disposal_id"    => disposal.try(&.pk).to_s,
          "number"         => asset.number.to_s,
          "date"           => date.to_s("%Y-%m-%d"),
          "amount"         => amount.to_s,
          "category"       => asset.category.to_s,
          "category_label" => I18n.t("liberal.asset_categories.#{asset.category}"),
          "method"         => (disposal.try(&.method) || asset.method).to_s,
          "card_id"        => asset.card_id.to_s,
          "party_name"     => asset.party_name.to_s,
          "label"          => asset.label.to_s,
          "reference"      => (disposal.try(&.reference.to_s.presence) || asset.reference).to_s,
          "attachment_id"  => asset.attachment_id.to_s,
          "reversal_of_id" => asset.reversal_of_id.to_s,
        }, actor_user_id: actor_user_id)
      end

      # Republie acquisitions, contre-passations et cessions ; renvoie le
      # nombre d'événements publiés.
      def self.republish(actor_user_id : Int64?) : Int32
        count = 0
        Asset.all.order(:id).each do |asset|
          operation = asset.reversal_of_id ? "reversal" : "acquisition"
          publish(asset, operation, asset.acquired_on!, asset.amount!, actor_user_id)
          count += 1
        end
        Disposal.all.order(:id).each do |disposal|
          asset = Asset.filter(id: disposal.asset_id).first || next
          publish(asset, "disposal", disposal.date!, disposal.price!, actor_user_id, disposal)
          count += 1
        end
        count
      end

      # --- Vues -------------------------------------------------------------------------

      def self.views(rows : Array(Asset)) : Array(Api::AssetView)
        return [] of Api::AssetView if rows.empty?
        ids = rows.map(&.pk!.as(Int64))
        reversals = Asset.filter(reversal_of_id__in: ids).to_a.to_h { |row| {row.reversal_of_id!.to_i64, row.pk!.as(Int64)} }
        disposals = Disposal.filter(asset_id__in: ids).to_a.to_h { |row| {row.asset_id!.to_i64, disposal_view(row)} }
        closed = Registers.closed_periods
        rows.map do |row|
          id = row.pk!.as(Int64)
          Api::AssetView.new(id: id, number: row.number.to_s, label: row.label.to_s, category: row.category.to_s,
            acquired_on: row.acquired_on!, service_on: row.service_on!, amount: row.amount!,
            duration_years: (row.duration_years || 0).to_i32, method: row.method.to_s, card_id: row.card_id.try(&.to_i64),
            party_name: row.party_name.to_s, reference: row.reference.to_s,
            attachment_id: row.attachment_id.try(&.to_i64), reversal_of_id: row.reversal_of_id.try(&.to_i64),
            reversed_by_id: reversals[id]?, disposal: disposals[id]?,
            locked: Registers.locked?(row.acquired_on!, closed), recorded_at: row.recorded_at || Time.utc)
        end
      end

      def self.view(row : Asset) : Api::AssetView
        views([row]).first
      end

      def self.disposal_view(row : Disposal) : Api::DisposalView
        Api::DisposalView.new(row.pk!.as(Int64), row.asset_id!.to_i64, row.date!, row.price!, row.method.to_s,
          row.reference.to_s)
      end

      # Immobilisations vivantes (ni contre-passées ni contre-passations)
      # acquises au plus tard l'année `year` et non cédées avant elle.
      def self.live(year : Int32) : Array(Api::AssetView)
        rows = Asset.filter(acquired_on__lte: Time.utc(year, 12, 31), reversal_of_id__isnull: true).order(:acquired_on, :number)
        views(rows.to_a).select do |asset|
          disposal = asset.disposal
          asset.live? && (disposal.nil? || disposal.date.year >= year)
        end
      end

      # --- Amortissement linéaire -------------------------------------------------------

      # Jours écoulés depuis le 1er janvier jusqu'à `date` incluse, sur une
      # année de 360 jours (mois de 30 jours).
      def self.days_to(date : Time) : Int32
        (date.month - 1) * 30 + Math.min(date.day, 30)
      end

      # Plan d'amortissement : annuités par année civile, cession comprise.
      def self.schedule(amount : BigDecimal, duration : Int32, service_on : Time,
                        disposed_on : Time? = nil) : Array({Int32, BigDecimal})
        result = [] of {Int32, BigDecimal}
        return result if duration <= 0 || amount <= 0
        return result if disposed_on && disposed_on < service_on
        last_year = service_on.year + duration - (361 - days_to(service_on) >= 360 ? 1 : 0)
        denominator = BigDecimal.new(360 * duration)
        cumulated = zero
        (service_on.year..last_year).each do |year|
          remaining = amount - cumulated
          break if remaining <= 0
          disposed = disposed_on.try(&.year) == year
          value = if year == last_year && !disposed
                    remaining
                  else
                    (amount * BigDecimal.new(days(year, service_on, disposed_on)) / denominator).round(2, mode: :ties_away)
                  end
          value = Math.min(value, remaining)
          result << {year, value}
          cumulated += value
          break if disposed
        end
        result
      end

      # Jours d'amortissement de l'année `year` (sur 360) : depuis la mise en
      # service la première année, jusqu'à la cession l'année de la cession.
      def self.days(year : Int32, service_on : Time, disposed_on : Time?) : Int32
        start = year == service_on.year ? days_to(service_on) - 1 : 0
        finish = disposed_on && disposed_on.year == year ? days_to(disposed_on) : 360
        finish - start
      end

      def self.schedule(asset : Api::AssetView) : Array({Int32, BigDecimal})
        schedule(asset.amount, asset.duration_years, asset.service_on, asset.disposal.try(&.date))
      end

      # Tableau des immobilisations et amortissements de l'année (2035-B).
      def self.depreciation(year : Int32) : Array(Api::DepreciationRowView)
        live(year).map do |asset|
          plan = schedule(asset)
          prior = plan.select { |(at, _)| at < year }.sum(zero, &.[1])
          current = plan.find { |(at, _)| at == year }.try(&.[1]) || zero
          Api::DepreciationRowView.new(asset.id, asset.number, asset.label, asset.category, asset.acquired_on,
            asset.service_on, asset.amount, asset.duration_years, asset.rate, prior, current, asset.disposal.try(&.date))
        end
      end

      # Plus ou moins-values des cessions de l'année (DECISIONS D-LIB-005) :
      # détention de moins de deux ans, tout à court terme ; au-delà, pour un
      # bien amortissable, plus-value à court terme à hauteur des
      # amortissements et à long terme au-delà, moins-value à court terme ;
      # pour un bien non amortissable, tout à long terme.
      def self.disposals(year : Int32) : Array(Api::DisposalResultView)
        live(year).compact_map do |asset|
          disposal = asset.disposal || next
          next unless disposal.date.year == year
          disposal_result(asset, disposal)
        end
      end

      # Plus ou moins-value de la cession d'une immobilisation, `nil` si elle
      # n'est pas cédée (requête légère : une immobilisation, pas la 2035).
      def self.disposal_result(asset : Api::AssetView) : Api::DisposalResultView?
        asset.disposal.try { |disposal| disposal_result(asset, disposal) }
      end

      def self.disposal_result(asset : Api::AssetView, disposal : Api::DisposalView) : Api::DisposalResultView
        depreciation = schedule(asset).sum(zero, &.[1])
        net_value = asset.amount - depreciation
        gain = disposal.price - net_value
        long_held = disposal.date >= asset.acquired_on.shift(years: 2)
        short, long = if !long_held
                        {gain, zero}
                      elsif asset.duration_years <= 0
                        {zero, gain}
                      elsif gain >= 0
                        short_part = Math.min(gain, depreciation)
                        {short_part, gain - short_part}
                      else
                        {gain, zero}
                      end
        Api::DisposalResultView.new(asset.id, asset.number, asset.label, disposal.date, disposal.price, net_value,
          depreciation, short, long)
      end
    end
  end
end
