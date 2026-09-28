# SPDX-License-Identifier: AGPL-3.0-or-later

require "../../spec_helper"

describe "Précision des dates-heures (microseconde, comme PostgreSQL)" do
  it "tronque à la microseconde avant l'écriture, pour que la valeur en mémoire égale la valeur relue" do
    user = Partiduo::Auth::User.new(email: "horloge@example.org")
    user.set_unusable_password
    user.last_login_at = Time.utc(2026, 9, 28, 11, 5, 20, nanosecond: 836_215_742)
    user.save!

    user.last_login_at.should eq(Time.utc(2026, 9, 28, 11, 5, 20, nanosecond: 836_215_000))
    Partiduo::Auth::User.get!(pk: user.pk).last_login_at.should eq(user.last_login_at)
  end

  it "ramène une heure à la microseconde" do
    Partiduo.to_microseconds(Time.utc(2026, 1, 1, nanosecond: 999_999_999))
      .should eq(Time.utc(2026, 1, 1, nanosecond: 999_999_000))
  end
end
