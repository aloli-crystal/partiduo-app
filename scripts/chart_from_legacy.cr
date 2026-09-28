# SPDX-License-Identifier: AGPL-3.0-or-later

# Produit les plans comptables initiaux `src/accounting/data/chart_{be,fr}.yml`
# depuis les modèles de dossier de l'application d'origine (`include/sql/mod1` belge,
# `include/sql/mod2` français) : table `tmp_pcmn` (comptes), `parm_code`
# (comptes par défaut), `fiche_def` (compte de base des catégories de fiches),
# `jrn_def` (journaux) et `tva_rate.tva_poste` (comptes de TVA de chaque taux).
# Règles de reprise et corrections : voir DECISIONS.adoc, D-ACC-003, D-ACC-008
# et D-ACC-009.
#
#   crystal run scripts/chart_from_legacy.cr -- /chemin/vers/scripts-sql-d-origine
#
# Le paramètre est la racine de l'application d'origine, qui contient
# `include/sql/mod1` et `include/sql/mod2`.
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

# Corrections des types (et parents) erronés des modèles d'origine
# (D-ACC-008) : numéro → {type, parent ou nil pour garder celui du modèle}.
# Les numéros de préfixe (`28`, `29`…) valent pour tous les comptes qui en
# commencent, sauf s'ils sont corrigés un par un.
FR_FIXES = {
  "400" => {"liability", nil}, "419" => {"liability", nil}, # fournisseurs, clients créditeurs
  "409" => {"asset", nil}, "410" => {"asset", nil},         # fournisseurs débiteurs, clients
  "4456" => {"asset", nil}, "445661" => {"asset", "4456"},  # TVA déductible
  "445662" => {"asset", "4456"}, "445663" => {"asset", "4456"},
  "4457" => {"liability", nil}, "44571" => {"liability", "4457"}, # TVA collectée
  "44572" => {"liability", "4457"}, "44573" => {"liability", "4457"},
  "481" => {"asset", nil},                                        # charges à répartir
  "486" => {"asset", nil}, "487" => {"liability", nil},           # constatées d'avance, inversées
  "491" => {"asset_contra", nil}, "496" => {"asset_contra", nil}, # dépréciations de tiers
  "590" => {"asset_contra", nil},                                 # dépréciation des VMP
}
FR_CONTRA_PREFIXES = %w[28 29 39] # amortissements et dépréciations

# Comptes ajoutés au modèle, absents de `mod2` (D-ACC-008).
FR_ADDITIONS = [
  Account.new("44551", "TVA à décaisser", "445", "liability", true),
  # Créance de la liquidation de TVA (lot 4, D-TVA-005).
  Account.new("44567", "Crédit de TVA à reporter", "4456", "asset", true),
  # Acomptes (CA12) et remboursement demandé (CA3) de la liquidation
  # (lot 4, D-TVA-005).
  Account.new("44581", "Acomptes - Régime simplifié d'imposition", "445", "asset", true),
  Account.new("44583", "Remboursement de taxes sur le chiffre d'affaires demandé", "445", "asset", true),
]

# PCMN : « Réductions de valeur actées » (classes 2 à 5) en déduction d'actif.
BE_CONTRA_LABEL = /r[ée]ductions? de valeurs? act[ée]es?/i

# Comptes de TVA des taux Partiduo (`Partiduo::Vat::{Be,Fr}::RATES`), repris
# de `tva_rate.tva_poste` (« déductible,collectée ») par le code d'origine du
# taux ; `{déductible, collectée}` donnés directement quand le taux Partiduo
# n'a pas d'équivalent dans le modèle ou que le modèle se trompe (D-ACC-009).
BE_VAT = {
  "21G" => "21G", "12A" => "120A", "6A" => "60A", "0TVA" => "0TVA", "INTA" => "INT",
  "EXP" => {"41141", "45141"}, # modèle : 45144 (cocontractants)
  "INTL" => {"4114", "4514"}, "COC" => {"41144", "45144"},
}
FR_VAT = {
  "NOR" => "NOR", "TR55" => "TR55", "TP021" => "TP021", "DNOR" => "DNOR", "DR" => "DR", "DPRS" => "DPRS",
  "DOM1" => "DOM1", "COR13" => "COR1", "COR09" => "COR4", "EXP" => "EXP", "INTL" => "INTL", "INTS" => "INTS",
  "FRANC" => "0G", "AUTOL" => "AUT",
  "INT" => {"445661", "44571"}, # 10 % : absent du modèle, comptes du taux normal
}

TVA_INSERT = /^INSERT INTO public\.tva_rate \((.*)\) VALUES \((.*)\);$/

# `tva_code` → {déductible, collectée} d'après `tva_rate.tva_poste`.
def vat_postings(legacy : String, mod : String) : Hash(String, {String, String})
  postings = {} of String => {String, String}
  File.read_lines(File.join(legacy, "include/sql", mod, "data.sql")).each do |line|
    match = TVA_INSERT.match(line.strip) || next
    columns = match[1].split(',').map(&.strip)
    values = sql_values(match[2])
    row = columns.zip(values).to_h
    accounts = row["tva_poste"].to_s.split(',')
    postings[row["tva_code"].to_s] = {accounts[0]? || "", accounts[1]? || ""}
  end
  postings
end

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

def fixed_kind(regime : String, number : String, label : String, kind : String) : {String, String?}
  if regime == "fr"
    return FR_FIXES[number] if FR_FIXES.has_key?(number)
    return {"asset_contra", nil} if FR_CONTRA_PREFIXES.any? { |prefix| number.starts_with?(prefix) && number.size > prefix.size }
  elsif regime == "be"
    return {"asset_contra", nil} if "2345".includes?(number[0]) && label.matches?(BE_CONTRA_LABEL)
  end
  {kind, nil}
end

# ameba:disable Metrics/CyclomaticComplexity
def generate(legacy : String, mod : String, regime : String, exclude : Proc(Array(String?), Bool),
             defaults : Array({String, String}), categories : Array({String, String, Bool}), bank : String,
             vat : Hash(String, String | {String, String}), output : String) : Nil
  rows = File.read_lines(File.join(legacy, "include/sql", mod, "data.sql")).compact_map do |line|
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
    label = row[1].to_s.split.join(" ")
    kind, fixed_parent = fixed_kind(regime, number, label, KINDS[type])
    accounts[number] = Account.new(number, label, fixed_parent || parent, kind, row[5] == "Y")
  end
  FR_ADDITIONS.each { |account| accounts[account.number] = account } if regime == "fr"

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
    io.puts "# Plan comptable initial, régime « #{regime} », extrait des scripts SQL"
    io.puts "# d'origine (include/sql/#{mod}/data.sql, tables tmp_pcmn et parm_code)"
    io.puts "# par scripts/chart_from_legacy.cr ; voir DECISIONS.adoc, D-ACC-003."
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
    # Journal financier : une fiche Banque (catégorie BANK) rattachée à
    # `bank_account` est créée au chargement et citée par le journal
    # (`jrn_def_bank` est une fiche, D-ACC-010).
    io.puts "ledgers:"
    [{"purchase", "A01", "A-", nil}, {"sale", "V01", "V-", nil}, {"financial", "F01", "F-", bank}, {"misc", "O01", "O-", nil}].each do |kind, code, prefix, account|
      io.puts "  - {kind: #{kind}, code: #{code.to_json}, receipt_prefix: #{prefix.to_json}, receipt_padding: 5, bank_account: #{account.try(&.to_json) || "null"}}"
    end
    # Comptes de TVA par code de taux : [déductible, collectée].
    postings = vat_postings(legacy, mod)
    io.puts "vat_accounts:"
    vat.each do |code, source|
      deductible, collected = source.is_a?(String) ? (postings[source]? || abort("#{regime} : taux d'origine #{source} absent")) : source
      {deductible, collected}.each do |number|
        abort "#{regime} : compte de TVA #{number} (#{code}) absent du plan" unless accounts.has_key?(number)
      end
      io.puts "  #{code.to_json}: [#{deductible.to_json}, #{collected.to_json}]"
    end
  end
  STDERR.puts "#{output} : #{accounts.size} comptes"
end

legacy = ARGV[0]? || abort("usage : crystal run scripts/chart_from_legacy.cr -- /chemin/vers/scripts-sql-d-origine")
data = File.expand_path("../src/accounting/data", __DIR__)

# mod1 : comptes de démonstration des fiches livrées (Client 1, Banque 2…),
# numéros de 6 caractères et plus sous les comptes de base des catégories.
be_demo_parents = %w[400 440 604 61 700 701 5500 4890]
generate(legacy, "mod1", "be", ->(row : Array(String?)) { row[0].to_s.size >= 6 && be_demo_parents.includes?(row[2]) },
  [{"customer", "400"}, {"supplier", "440"}, {"bank", "550"}, {"cash", "57"}, {"sales", "70"},
   {"internal_transfer", "58"}, {"current_account", "56"}, {"vat", "451"}, {"non_deductible", "67"},
   {"non_deductible_vat", "6740"}, {"vat_deductible_tax", "619000"}, {"private_expense", "4890"}],
  # Catégories du socle (codes de `Partiduo::Cards::Defaults`) : `fiche_def`
  # de mod1 (fd_class_base, fd_create_account).
  [{"CUSTOMER", "400", true}, {"SUPPLIER", "440", true}, {"BANK", "5500", true},
   {"SALE", "700", true}, {"PURCHASE", "604", true}, {"EXPENSE", "61", true}],
  "550", BE_VAT.transform_values(&.as(String | {String, String})), File.join(data, "chart_be.yml"))

# mod2 : « 4000001 Four », fiche de démonstration.
generate(legacy, "mod2", "fr", ->(row : Array(String?)) { row[0] == "4000001" },
  # COMPTE_TVA est vide dans mod2 : 44551 « TVA à décaisser », ajouté.
  [{"customer", "410"}, {"supplier", "400"}, {"bank", "51"}, {"cash", "53"}, {"sales", "707"},
   {"internal_transfer", "58"}, {"current_account", "455"}, {"vat", "44551"}, {"non_deductible", "67"},
   {"private_expense", "4890"}],
  # `fiche_def` de mod2 ; ses comptes de base 604 et 700 manquent au plan :
  # 60 (Achats) et 706 (Prestations de services, `fiche_def_ref` « Vente
  # Service ») les remplacent.
  [{"CUSTOMER", "410", true}, {"SUPPLIER", "400", true}, {"BANK", "51", true},
   {"SALE", "706", true}, {"PURCHASE", "60", true}, {"EXPENSE", "61", true}],
  "510001", FR_VAT.transform_values(&.as(String | {String, String})), File.join(data, "chart_fr.yml"))
