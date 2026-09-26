# SPDX-License-Identifier: AGPL-3.0-or-later

# Specs d'un module activable (ADR-006 D7) : le groupe ne s'exécute que si le
# module est actif dans la configuration courante (`PARTIDUO_MODULES`) ; sinon
# il est signalé en attente. Les specs qui vérifient le refus d'un module
# inactif (`ModuleDisabled`) s'écrivent, elles, avec `describe` ordinaire.
#
# ```
# describe_module "ACCOUNTING", Partiduo::Api::Accounting do
#   it "..." { }
# end
# ```
def describe_module(module_code : String, description, file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  if Partiduo::Modules.active?(module_code)
    describe(description, file: file, line: line, end_line: end_line, &block)
  else
    pending("#{description} (module #{module_code} inactif)", file: file, line: line, end_line: end_line) { }
  end
end

# Exécute le bloc avec une autre liste de modules actifs, puis restaure la
# configuration. À réserver aux specs du registre et des refus d'accès.
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end
