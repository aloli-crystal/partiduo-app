# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Invoicing
    # Canal d'émission des documents fiscaux et marquage B2C (ADR-004 D9).
    # NOALYSS n'en a pas : sa facture est une écriture, envoyée à la main ou
    # par `peppol-connect`. Le canal appartient au cœur et existe sans
    # extension de facturation électronique ; une extension le lit dans
    # `invoice.issued` ou par le contrat pour transmettre à sa plateforme.
    #
    # Proposition : professionnel (SIREN ou numéro de TVA) établi dans le pays
    # du dossier → plateforme agréée ; particulier ou client étranger →
    # courriel si la fiche a une adresse électronique, papier sinon. Un
    # client sans SIREN ni numéro de TVA est marqué B2C (DECISIONS D-INV-016).
    module Channels
      alias Api = Partiduo::Api::Invoicing
      alias FieldError = Partiduo::Api::FieldError

      def self.propose(card : Partiduo::Api::Cards::CardView) : Api::ChannelProposalView
        company_country = Configuration.company.country_code.upcase
        country = (card.address.try(&.country_code).presence || company_country).upcase
        professional = !card.siren.strip.empty? || !card.vat_number.strip.empty?
        international = country != company_country
        if professional && !international
          return Api::ChannelProposalView.new("platform", false, "domestic_business", false)
        end
        channel = card.email.strip.empty? ? "paper" : "email"
        Api::ChannelProposalView.new(channel, !professional, professional ? "foreign_business" : "private_customer",
          international)
      end

      def self.fiscal?(kind : String) : Bool
        Api::FISCAL_KINDS.includes?(kind)
      end

      # Contrôle du canal saisi sur un brouillon.
      def self.input_errors(input : Api::DocumentInput) : Array(FieldError)
        channel = input.issue_channel
        return [] of FieldError if channel.nil? && input.b2c.nil?
        unless fiscal?(input.kind)
          return [Documents.error("issue_channel", "document.issue_channel.fiscal_only")]
        end
        channel_errors(channel)
      end

      def self.channel_errors(channel : String?) : Array(FieldError)
        return [] of FieldError if channel.nil? || Api::ISSUE_CHANNELS.includes?(channel)
        [Documents.error("issue_channel", "document.issue_channel.invalid", {"value" => channel})]
      end

      # Canal et marquage d'un brouillon enregistré : ceux saisis, sinon ceux
      # déjà portés pour le même client, sinon la proposition.
      def self.apply(document : Document, input : Api::DocumentInput, customer : Partiduo::Api::Cards::CardView,
                     previous_customer_id : Int64?) : Nil
        unless fiscal?(input.kind)
          document.issue_channel = ""
          document.b2c = false
          return
        end
        same_customer = previous_customer_id == input.customer_card_id && !document.issue_channel.to_s.empty?
        proposal = propose(customer)
        document.issue_channel = input.issue_channel || (same_customer ? document.issue_channel.to_s : proposal.channel)
        b2c = input.b2c
        document.b2c = b2c.nil? ? (same_customer ? document.b2c! : proposal.b2c) : b2c
      end

      # Un avoir part par le canal de la facture qu'il corrige ; les autres
      # transformations reprennent la proposition.
      def self.inherited(source : Document, kind : String) : NamedTuple(issue_channel: String?, b2c: Bool?)
        channel = source.issue_channel.presence
        return {issue_channel: nil.as(String?), b2c: nil.as(Bool?)} unless kind == "credit_note" && channel
        {issue_channel: channel.as(String?), b2c: source.b2c.as(Bool?)}
      end

      # À l'émission : un brouillon sans canal (antérieur à la migration
      # `0002`) reçoit la proposition.
      def self.complete(document : Document, customer : Partiduo::Api::Cards::CardView) : Nil
        return unless fiscal?(document.kind!) && document.issue_channel.to_s.empty?
        proposal = propose(customer)
        document.issue_channel = proposal.channel
        document.b2c = proposal.b2c
      end

      # Changement du canal d'un document fiscal pas encore envoyé.
      def self.change!(document : Document, input : Api::ChannelInput,
                       actor : Partiduo::Api::Actor) : Partiduo::Api::Result(Api::DocumentView)
        result = Partiduo::Api::Result(Api::DocumentView)
        return result.failure(Documents.error(FieldError::BASE, "channel.not_fiscal")) unless fiscal?(document.kind!)
        return result.failure(Documents.error("issue_channel", "channel.already_sent")) if document.sent_at
        errors = channel_errors(input.channel)
        return result.failure(errors) unless errors.empty?
        document.issue_channel = input.channel
        input.b2c.try { |value| document.b2c = value }
        document.save!
        Documents.log(Documents.id_of(document.id), "channel_changed", actor, "",
          {"channel" => input.channel, "b2c" => document.b2c!.to_s})
        result.success(Documents.view(document))
      end

      # Document émis remis au client hors courriel de la Facturation (papier,
      # plateforme) : date d'envoi posée, canal figé. Sans effet s'il est déjà
      # envoyé.
      def self.mark_sent!(document : Document, actor : Partiduo::Api::Actor) : Partiduo::Api::Result(Api::DocumentView)
        result = Partiduo::Api::Result(Api::DocumentView)
        return result.failure(Documents.error(FieldError::BASE, "channel.draft")) if document.draft?
        return result.success(Documents.view(document)) if document.sent_at
        document.sent_at = Time.utc
        if Payments::PAYABLE_KINDS.includes?(document.kind)
          Payments.refresh_status(document)
        else
          document.save!
        end
        Documents.log(Documents.id_of(document.id), "marked_sent", actor, "", {"channel" => document.issue_channel.to_s})
        result.success(Documents.view(document))
      end
    end
  end
end
