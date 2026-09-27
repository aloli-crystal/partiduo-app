# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du socle — devises et cours (ADR-006 D1), successeurs de
    # `currency` et `currency_history`, avec les règles de `Currency_MTable::check`.
    module Core
      CURRENCY_CODE_FORMAT = /\A[A-Z]{3}\z/
      CURRENCY_NAME_MAX    = 80
      CURRENCY_DECIMALS    = 0..4
      # Précision d'un cours (`ch_value numeric(20,8)`).
      RATE_DECIMALS = 8

      # Création d'une devise étrangère : un premier cours est obligatoire.
      record CurrencyInput,
        code : String,
        name : String,
        decimals : Int32 = 2,
        rate : BigDecimal? = nil,
        valid_from : Time? = nil

      # Nouveau cours d'une devise, postérieur au dernier connu.
      record CurrencyRateInput, code : String, rate : BigDecimal, valid_from : Time

      record CurrencyRateView, valid_from : Time, rate : BigDecimal

      record CurrencyView,
        id : Int64,
        code : String,
        name : String,
        decimals : Int32,
        base : Bool,
        rates : Array(CurrencyRateView) do
        # Dernier cours connu, ou `nil` pour la devise de tenue.
        def latest_rate : CurrencyRateView?
          rates.last?
        end
      end

      # Devises : la devise de tenue d'abord, puis par code.
      def self.currencies(actor : Actor) : Array(CurrencyView)
        Guard.authorize!(actor, nil)
        Partiduo::Core::Currency.all.order("-base", "code").map { |currency| currency_view(currency) }
      end

      def self.currency(actor : Actor, code : String) : CurrencyView
        Guard.authorize!(actor, nil)
        currency_view(find_currency(code))
      end

      # Devise de tenue du dossier (l'euro), `NotFound` avant le provisionnement.
      def self.base_currency(actor : Actor) : CurrencyView
        Guard.authorize!(actor, nil)
        currency_view(Partiduo::Core::Currency.filter(base: true).first || raise NotFound.new("currency", "base"))
      end

      # Cours applicable à `day` : le dernier cours dont la date est antérieure
      # ou égale (`v_currency_last_value`) ; `1` pour la devise de tenue ;
      # `nil` si la devise n'a pas encore de cours à cette date.
      def self.rate_on(actor : Actor, code : String, day : Time) : BigDecimal?
        Guard.authorize!(actor, nil)
        currency = find_currency(code)
        return BigDecimal.new(1) if currency.base
        Partiduo::Core::CurrencyRate
          .filter(currency_id: currency.id, valid_from__lte: Partiduo::Core::Periods.date(day))
          .order("-valid_from").first.try(&.rate!)
      end

      # Crée une devise étrangère et son premier cours.
      def self.create_currency(actor : Actor, input : CurrencyInput) : Result(CurrencyView)
        Guard.authorize!(actor, "core.currency.write")
        code = input.code.strip.upcase
        name = input.name.strip
        errors = currency_errors(code, name, input.decimals, nil)
        rate, valid_from = input.rate, input.valid_from
        errors << FieldError.new("valid_from", "core.errors.currency.valid_from.blank") if valid_from.nil?
        if rate.nil?
          errors << FieldError.new("rate", "core.errors.currency.rate.blank")
        else
          errors.concat(rate_errors(rate))
        end
        return Result(CurrencyView).failure(errors) if !errors.empty? || rate.nil? || valid_from.nil?

        Transaction.run do
          currency = Partiduo::Core::Currency.create!(code: code, name: name, decimals: input.decimals, base: false)
          Partiduo::Core::CurrencyRate.create!(currency: currency, rate: rate,
            valid_from: Partiduo::Core::Periods.date(valid_from))
          Result(CurrencyView).success(currency_view(currency))
        end
      end

      # Renomme une devise ou change ses décimales. La devise de tenue ne se
      # modifie pas (`Currency_MTable::check`).
      def self.update_currency(actor : Actor, code : String, name : String, decimals : Int32) : Result(CurrencyView)
        Guard.authorize!(actor, "core.currency.write")
        Transaction.run do
          currency = Partiduo::Core::Currency.all.lock.filter(code: code.strip.upcase).first ||
                     raise NotFound.new("currency", code)
          errors = currency_errors(currency.code!, name.strip, decimals, currency)
          next Result(CurrencyView).failure(errors) unless errors.empty?

          currency.name = name.strip
          currency.decimals = decimals
          currency.save!
          Result(CurrencyView).success(currency_view(currency))
        end
      end

      # Ajoute un cours, strictement postérieur au dernier connu (« la date doit
      # être après la dernière valeur »).
      def self.add_currency_rate(actor : Actor, input : CurrencyRateInput) : Result(CurrencyView)
        Guard.authorize!(actor, "core.currency.write")
        Transaction.run do
          currency = Partiduo::Core::Currency.all.lock.filter(code: input.code.strip.upcase).first ||
                     raise NotFound.new("currency", input.code)
          day = Partiduo::Core::Periods.date(input.valid_from)
          errors = rate_errors(input.rate)
          errors << FieldError.new("code", "core.errors.currency.code.base_immutable") if currency.base
          last = Partiduo::Core::CurrencyRate.filter(currency_id: currency.id).order("-valid_from").first
          if last && day <= last.valid_from!
            errors << FieldError.new("valid_from", "core.errors.currency.valid_from.not_after_last",
              {"date" => last.valid_from!.to_s("%Y-%m-%d")})
          end
          next Result(CurrencyView).failure(errors) unless errors.empty?

          Partiduo::Core::CurrencyRate.create!(currency: currency, rate: input.rate, valid_from: day)
          Result(CurrencyView).success(currency_view(currency))
        end
      end

      # Supprime une devise étrangère que rien ne cite (opérations en devise,
      # factures…).
      def self.delete_currency(actor : Actor, code : String) : Result(Nil)
        Guard.authorize!(actor, "core.currency.write")
        Transaction.run do
          currency = Partiduo::Core::Currency.all.lock.filter(code: code.strip.upcase).first ||
                     raise NotFound.new("currency", code)
          if currency.base
            next Result(Nil).failure(FieldError.new("code", "core.errors.currency.code.base_immutable"))
          end
          deleted = Partiduo::Core::Db.delete_unless_referenced([
            {"DELETE FROM core_currency_rate WHERE currency_id = $1", [currency.id!.to_i64] of ::DB::Any},
            {"DELETE FROM core_currency WHERE id = $1", [currency.id!.to_i64] of ::DB::Any},
          ])
          next Result(Nil).failure(FieldError.new("code", "core.errors.currency.code.in_use")) unless deleted
          Result(Nil).success(nil)
        end
      end

      # Crée la devise de tenue (jeu de données initial). Sans effet si elle
      # existe déjà.
      def self.ensure_base_currency(actor : Actor, code : String = "EUR", name : String = "Euro") : CurrencyView
        raise Forbidden.new("core.currency.write") unless actor.system
        Guard.authorize!(actor, "core.currency.write")
        currency = Partiduo::Core::Currency.filter(base: true).first ||
                   Partiduo::Core::Currency.create!(code: code, name: name, decimals: 2, base: true)
        currency_view(currency)
      end

      private def self.currency_errors(code : String, name : String, decimals : Int32,
                                       current : Partiduo::Core::Currency?) : Array(FieldError)
        errors = [] of FieldError
        if current.try(&.base)
          errors << FieldError.new("code", "core.errors.currency.code.base_immutable")
        end
        if current.nil?
          if !code.matches?(CURRENCY_CODE_FORMAT)
            errors << FieldError.new("code", "core.errors.currency.code.invalid", {"value" => code})
          elsif Partiduo::Core::Currency.filter(code: code).exists?
            errors << FieldError.new("code", "core.errors.currency.code.taken", {"value" => code})
          end
        end
        if name.empty?
          errors << FieldError.new("name", "core.errors.currency.name.blank")
        elsif name.size > CURRENCY_NAME_MAX
          errors << FieldError.new("name", "core.errors.currency.name.too_long", {"max" => CURRENCY_NAME_MAX.to_s})
        end
        unless CURRENCY_DECIMALS.includes?(decimals)
          errors << FieldError.new("decimals", "core.errors.currency.decimals.out_of_range",
            {"min" => CURRENCY_DECIMALS.begin.to_s, "max" => CURRENCY_DECIMALS.end.to_s})
        end
        errors
      end

      private def self.rate_errors(rate : BigDecimal) : Array(FieldError)
        errors = [] of FieldError
        if rate <= 0
          errors << FieldError.new("rate", "core.errors.currency.rate.not_positive")
        elsif rate.round(RATE_DECIMALS) != rate
          errors << FieldError.new("rate", "core.errors.currency.rate.too_precise", {"decimals" => RATE_DECIMALS.to_s})
        elsif rate >= BigDecimal.new(10) ** 12
          errors << FieldError.new("rate", "core.errors.currency.rate.too_large")
        end
        errors
      end

      private def self.find_currency(code : String) : Partiduo::Core::Currency
        Partiduo::Core::Currency.filter(code: code.strip.upcase).first || raise NotFound.new("currency", code)
      end

      private def self.currency_view(currency : Partiduo::Core::Currency) : CurrencyView
        rates = Partiduo::Core::CurrencyRate.filter(currency_id: currency.id).order(:valid_from).map do |rate|
          CurrencyRateView.new(valid_from: rate.valid_from!, rate: rate.rate!)
        end
        CurrencyView.new(id: currency.id!.to_i64, code: currency.code!, name: currency.name!,
          decimals: currency.decimals!.to_i32, base: currency.base!, rates: rates)
      end
    end
  end
end
