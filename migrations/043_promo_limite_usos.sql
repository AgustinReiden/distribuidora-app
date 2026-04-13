-- Agrega columna limite_usos a promociones
-- NULL = sin limite (comportamiento actual)
-- Cuando usos_pendientes >= limite_usos, la promo se desactiva automaticamente

ALTER TABLE promociones ADD COLUMN IF NOT EXISTS limite_usos INTEGER DEFAULT NULL;

COMMENT ON COLUMN promociones.limite_usos IS 'Numero maximo de bonificaciones antes de auto-desactivacion. NULL = sin limite.';

-- Crear trigger que auto-desactiva la promo cuando se alcanza el limite
CREATE OR REPLACE FUNCTION check_promo_limite_usos()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.limite_usos IS NOT NULL AND NEW.usos_pendientes >= NEW.limite_usos AND NEW.activo = true THEN
    NEW.activo := false;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_promo_limite ON promociones;
CREATE TRIGGER trg_check_promo_limite
  BEFORE UPDATE OF usos_pendientes ON promociones
  FOR EACH ROW
  EXECUTE FUNCTION check_promo_limite_usos();
