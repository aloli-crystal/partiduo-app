# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial du socle (convention C6) : la devise de tenue. Les
# régimes FR et BE tiennent tous deux leur comptabilité en euros (NOALYSS :
# `currency.id = 0`, `EUR`).
Partiduo::Api::InitialData.register("CORE", "base_currency", order: 2) do |context|
  name = I18n.with_locale(Partiduo::LOCALES.includes?(context.locale) ? context.locale : "fr") do
    I18n.t("core.currencies.eur")
  end
  Partiduo::Api::Core.ensure_base_currency(context.actor, "EUR", name)
end
