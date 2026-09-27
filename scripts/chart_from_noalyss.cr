# SPDX-License-Identifier: AGPL-3.0-or-later

# Produit les plans comptables initiaux `src/accounting/data/chart_{be,fr}.yml`
# depuis les modèles de dossier de NOALYSS (`include/sql/mod1` belge,
# `include/sql/mod2` français) : table `tmp_pcmn` (comptes), `parm_code`
# (comptes par défaut), `fiche_def` (compte de base des catégories de fiches)
# et `jrn_def` (journaux). Règles de reprise : voir
# DECISIONS.adoc, D-ACC-003.
#
#   crystal run scripts/chart_from_noalyss.cr -- /chemin/vers/noalyss-app
#
# Le résultat est versionné : ce script ne sert qu'à le régénérer.

require "json"

KINDS = {
  "ACT" => "asset", "PAS" => "liability", "ACTINV" => "asset_contra", "PASINV" => "liability_contra",
  "PRO" => "income", "PROINV" => "income_contra", "CHA" => "expense", "CHAINV" => "expense_contra",
  "CON" => "context",
}

INSERT = /^INSERT INTO public\.tmp_pcmn \(pcm_val, pcm_lib, pcm_val_parent, pcm_type, id, pcm_direct_use\) VALUES \((.*)\);$/

record Account, number : String, label : String, parent : String?, kind : String, direct_use : Bool

# Valeurs d'un `VALUES (...)` : chaînes entre apostrophes (`''` échappé), `NULL`, nombres.
def sql_values(text : String) : Array(String?)
  values = [] of String?
  reader = Char::Reader.new(text)
  while reader.has_next?
    char = reader.current_char
    if char == ' ' || char == ','
      reader.next_char
    elsif char == '\''
      buffer = String::Builder.new
      loop do
        char = reader.next_char
        if char == '\''
          if reader.peek_next_char == '\''
            buffer << '\''
            reader.next_char
          else
            reader.next_char
            break
          end
        else
          buffer << char
        end
      end
      values << buffer.to_s
    else
      buffer = String::Builder.new
      while reader.has_next? && reader.current_char != ','
        buffer << reader.current_char
        reader.next_char
      end
      value = buffer.to_s.strip
      values << (value == "NULL" ? nil : value)
    end
  end
  values
end

def generate(noalyss : String, mod : String, regime : String, exclude : Proc(Array(String?), Bool),
             defaults : Array({String, String}), categories : Array({String, String, Bool}), bank : String,
             output : String) : Nil
  rows = File.read_lines(File.join(noalyss, "include/sql", mod, "data.sql")).compact_map do |line|
    INSERT.match(line.strip).try { |match| sql_values(match[1]) }
  end
  rows.reject!(&exclude)
  numbers = rows.map(&.[0].to_s).to_set

  accounts = {} of String => Account
  rows.each do |row|
    number = row[0].to_s
    source_parent = row[2]
    # Parent absent du modèle (mod1 : 551 à 559) : le plus long préfixe
    # existant, comme `comptaproc.account_parent` ; `0` : racine.
    parent = if source_parent && source_parent != number && numbers.includes?(source_parent)
               source_parent
             else
               (1...number.size).reverse_each.map { |size| number[0, size] }.find { |prefix| numbers.includes?(prefix) }
             end
    type = row[3].to_s
    # mod2 type les produits (classe 7) en passif : corrigé en produit.
    type = "PRO" if regime == "fr" && number.starts_with?('7') && type == "PAS"
    accounts[number] = Account.new(number, row[1].to_s.split.join(" "), parent, KINDS[type], row[5] == "Y")
  end

  depth = ->(number : String) do
    level = 0
    while parent = accounts[number].parent
      number = parent
      level += 1
    end
    level
  end
  ordered = accounts.keys.sort_by! { |number| {depth.call(number), number} }

  File.open(output, "w") do |io|
    io.puts "# SPDX-License-Identifier: AGPL-3.0-or-later"
    io.puts "# Plan comptable initial, régime « #{regime} », extrait de NOALYSS"
    io.puts "# (noalyss-app/include/sql/#{mod}/data.sql, tables tmp_pcmn et parm_code)"
    io.puts "# par scripts/chart_from_noalyss.cr ; voir DECISIONS.adoc, D-ACC-003."
    io.puts "# Colonnes d'un compte : numéro, libellé, parent (null = racine), type,"
    io.puts "# utilisation directe. Parents avant enfants."
    io.puts "accounts:"
    ordered.each do |number|
      account = accounts[number]
      parent = account.parent.try(&.to_json) || "null"
      io.puts "  - [#{account.number.to_json}, #{account.label.to_json}, #{parent}, #{account.kind}, #{account.direct_use}]"
    end
    io.puts "default_accounts:"
    defaults.each do |code, number|
      if accounts.has_key?(number)
        io.puts "  #{code}: #{number.to_json}"
      else
        STDERR.puts "#{regime} : compte par défaut #{code} = #{number} absent du plan, ignoré"
      end
    end
    io.puts "card_categories:"
    categories.each do |code, number, create|
      abort "#{regime} : compte de base #{number} de #{code} absent du plan" unless accounts.has_key?(number)
      io.puts "  #{code}: {base_account: #{number.to_json}, create_account: #{create}}"
    end
    io.puts "ledgers:"
    [{"purchase", "A01", "A-", nil}, {"sale", "V01", "V-", nil}, {"financial", "F01", "F-", bank}, {"misc", "O01", "O-", nil}].each do |kind, code, prefix, account|
      io.puts "  - {kind: #{kind}, code: #{code.to_json}, receipt_prefix: #{prefix.to_json}, receipt_padding: 5, default_account: #{account.try(&.to_json) || "null"}}"
    end
  end
  STDERR.puts "#{output} : #{accounts.size} comptes"
end

noalyss = ARGV[0]? || abort("usage : crystal run scripts/chart_from_noalyss.cr -- /chemin/vers/noalyss-app")
data = File.expand_path("../src/accounting/data", __DIR__)

# mod1 : comptes de démonstration des fiches livrées (Client 1, Banque 2…),
# numéros de 6 caractères et plus sous les comptes de base des catégories.
be_demo_parents = %w[400 440 604 61 700 701 5500 4890]
generate(noalyss, "mod1", "be", ->(row : Array(String?)) { row[0].to_s.size >= 6 && be_demo_parents.includes?(row[2]) },
  [{"customer", "400"}, {"supplier", "440"}, {"bank", "550"}, {"cash", "57"}, {"sales", "70"},
   {"internal_transfer", "58"}, {"current_account", "56"}, {"vat", "451"}, {"non_deductible", "67"},
   {"non_deductible_vat", "6740"}, {"vat_deductible_tax", "619000"}, {"private_expense", "4890"}],
  # Catégories du socle (codes de `Partiduo::Cards::Defaults`) : `fiche_def`
  # de mod1 (fd_class_base, fd_create_account).
  [{"CUSTOMER", "400", true}, {"SUPPLIER", "440", true}, {"BANK", "5500", true},
   {"SALE", "700", true}, {"PURCHASE", "604", true}, {"EXPENSE", "61", true}],
  "550", File.join(data, "chart_be.yml"))

# mod2 : « 4000001 Four », fiche de démonstration.
generate(noalyss, "mod2", "fr", ->(row : Array(String?)) { row[0] == "4000001" },
  [{"customer", "410"}, {"supplier", "400"}, {"bank", "51"}, {"cash", "53"}, {"sales", "707"},
   {"internal_transfer", "58"}, {"current_account", "455"}, {"non_deductible", "67"}, {"private_expense", "4890"}],
  # `fiche_def` de mod2 ; ses comptes de base 604 et 700 manquent au plan :
  # 60 (Achats) et 706 (Prestations de services, `fiche_def_ref` « Vente
  # Service ») les remplacent.
  [{"CUSTOMER", "410", true}, {"SUPPLIER", "400", true}, {"BANK", "51", true},
   {"SALE", "706", true}, {"PURCHASE", "60", true}, {"EXPENSE", "61", true}],
  "510001", File.join(data, "chart_fr.yml"))
