# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "yaml"

private def flatten_keys(node : YAML::Any, prefix : String, keys : Set(String)) : Set(String)
  if hash = node.as_h?
    hash.each { |key, value| flatten_keys(value, prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}", keys) }
  else
    keys << prefix
  end
  keys
end

describe "Traductions (ADR-005 D7)" do
  it "fournit les mêmes clés en fr, en et nl dans chaque application" do
    src = File.expand_path("../../src", __DIR__)
    Dir.glob(File.join(src, "*", "locales")).sort.each do |dir|
      keys = Partiduo::LOCALES.to_h do |locale|
        path = File.join(dir, "#{locale}.yml")
        File.exists?(path).should be_true
        {locale, flatten_keys(YAML.parse(File.read(path))[locale], "", Set(String).new)}
      end
      keys["en"].should eq(keys["fr"])
      keys["nl"].should eq(keys["fr"])
    end
  end

  it "traduit le nom de chaque pièce du registre" do
    Partiduo::Modules.manifests.each_value do |manifest|
      Partiduo::LOCALES.each do |locale|
        I18n.with_locale(locale) { I18n.t(manifest.name).should_not contain("missing") }
      end
    end
  end
end
