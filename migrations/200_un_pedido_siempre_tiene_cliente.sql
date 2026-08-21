-- Que un pedido no pueda volver a quedarse sin cliente (#492, #491)
--
-- La mig 199 devolvio los 9 huerfanos a su dueno. Esto cierra la puerta por la
-- que se habian ido: la FK era ON DELETE SET NULL, asi que borrar un cliente
-- vaciaba la columna en silencio en vez de fallar.
--
-- Dos cambios que van juntos:
--   1. cliente_id NOT NULL -- un pedido sin cliente no existe en el dominio.
--   2. ON DELETE RESTRICT  -- si el cliente tiene pedidos, no se borra. Es lo
--      unico coherente con NOT NULL: SET NULL ya no seria ni siquiera posible.
--
-- Consecuencia buscada: el borrado de un cliente con pedidos ahora falla en la
-- base. El front (#491) tiene que contarlos ANTES y ofrecer desactivar. Los 4
-- borrados que causaron esto fueron una deduplicacion legitima; lo que faltaba
-- era que la app dijera que se estaba llevando puesto.

BEGIN;

DO $$
DECLARE v_huerfanos int;
BEGIN
  SELECT count(*) INTO v_huerfanos FROM pedidos WHERE cliente_id IS NULL;
  IF v_huerfanos > 0 THEN
    RAISE EXCEPTION 'Hay % pedidos sin cliente. Corre antes la mig 199.', v_huerfanos;
  END IF;
END $$;

ALTER TABLE pedidos ALTER COLUMN cliente_id SET NOT NULL;

-- OJO: la FK es COMPUESTA (cliente_id, sucursal_id) -> clientes(id, sucursal_id).
-- Es el aislamiento por sucursal de las migs 186/187: sin las dos columnas, un
-- pedido podria apuntar al cliente de OTRA sucursal y la RLS de la hija no lo
-- ve. Se recrea igual de compuesta; lo unico que cambia es la accion de borrado.
ALTER TABLE pedidos DROP CONSTRAINT pedidos_cliente_id_fkey;
ALTER TABLE pedidos ADD CONSTRAINT pedidos_cliente_id_fkey
  FOREIGN KEY (cliente_id, sucursal_id) REFERENCES clientes(id, sucursal_id)
  ON DELETE RESTRICT;

COMMIT;
