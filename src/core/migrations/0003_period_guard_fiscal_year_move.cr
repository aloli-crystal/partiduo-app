# SPDX-License-Identifier: AGPL-3.0-or-later

# Relecture des lots P, 0 et 1 : `core_period_guard` refuse aussi de déplacer
# une période (même ouverte) vers un exercice clos ou hors d'un exercice clos
# (D-REF-010 : « exercice clos sans ajout »).
class Migration::Core::V0003 < Marten::Migration
  depends_on :core, "0002_core_referential"

  GUARD = <<-SQL
    CREATE OR REPLACE FUNCTION core_period_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF OLD.closed_at IS NOT NULL THEN
          RAISE EXCEPTION 'période % close : suppression refusée', OLD.id
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN OLD;
      END IF;
      IF TG_OP = 'INSERT' THEN
        IF EXISTS (SELECT 1 FROM core_fiscal_year WHERE id = NEW.fiscal_year_id AND closed_at IS NOT NULL) THEN
          RAISE EXCEPTION 'exercice % clos : ajout de période refusé', NEW.fiscal_year_id
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END IF;
      IF OLD.closed_at IS NOT NULL AND (NEW.starts_on <> OLD.starts_on OR NEW.ends_on <> OLD.ends_on
                                        OR NEW.fiscal_year_id <> OLD.fiscal_year_id) THEN
        RAISE EXCEPTION 'période % close : modification refusée', OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.fiscal_year_id <> OLD.fiscal_year_id
         AND EXISTS (SELECT 1 FROM core_fiscal_year
                      WHERE id IN (NEW.fiscal_year_id, OLD.fiscal_year_id) AND closed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'période % : déplacement vers ou depuis un exercice clos refusé', OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      IF OLD.closed_at IS NOT NULL AND NEW.closed_at IS NULL
         AND EXISTS (SELECT 1 FROM core_fiscal_year WHERE id = NEW.fiscal_year_id AND closed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'exercice % clos : réouverture de la période % refusée', NEW.fiscal_year_id, OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    SQL

  PREVIOUS = <<-SQL
    CREATE OR REPLACE FUNCTION core_period_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF OLD.closed_at IS NOT NULL THEN
          RAISE EXCEPTION 'période % close : suppression refusée', OLD.id
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN OLD;
      END IF;
      IF TG_OP = 'INSERT' THEN
        IF EXISTS (SELECT 1 FROM core_fiscal_year WHERE id = NEW.fiscal_year_id AND closed_at IS NOT NULL) THEN
          RAISE EXCEPTION 'exercice % clos : ajout de période refusé', NEW.fiscal_year_id
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END IF;
      IF OLD.closed_at IS NOT NULL AND (NEW.starts_on <> OLD.starts_on OR NEW.ends_on <> OLD.ends_on
                                        OR NEW.fiscal_year_id <> OLD.fiscal_year_id) THEN
        RAISE EXCEPTION 'période % close : modification refusée', OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      IF OLD.closed_at IS NOT NULL AND NEW.closed_at IS NULL
         AND EXISTS (SELECT 1 FROM core_fiscal_year WHERE id = NEW.fiscal_year_id AND closed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'exercice % clos : réouverture de la période % refusée', NEW.fiscal_year_id, OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    SQL

  def plan
    execute(GUARD, PREVIOUS)
  end
end
