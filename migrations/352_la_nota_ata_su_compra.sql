-- #1113 · Una compra con notas de crédito no se cancela, y la nota no se
-- despega, no se borra ni se reescribe, por ningún camino.
--
-- EL BUG
--   La 348 hizo que anular_compra_atomica rechace una compra con notas, pero el
--   invariante vivía sólo en la RPC. Por REST un admin podía saltearla por
--   siete puertas (las policies mt_compras_update/delete y las ALL de
--   notas_credito y nota_credito_items, con los grants de tabla completos a
--   authenticated y anon):
--   · PATCH compras.estado = 'cancelada' sobre una compra con notas: la compra
--     sale de posicion_fiscal y del gerencial (`c.estado <> 'cancelada'`) y la
--     nota se va con ella; además el trigger de la 224 le borra los lotes.
--   · PATCH compras.estado desde 'cancelada': reabre una compra cuyos lotes ya
--     se borraron y cuyo stock ya se revirtió. Ninguna función lo hace.
--   · DELETE de la nota.
--   · DELETE de la compra, que se lleva las notas por CASCADE
--     (notas_credito_compra_id_fkey).
--   · UPDATE notas_credito.compra_id: la nota se pasa a otra compra.
--   · PATCH de fecha, iva, impuestos_internos o total de la nota: posicion_fiscal
--     y reporte_gerencial la filtran por nc.fecha y suman nc.iva y
--     nc.impuestos_internos, así que la nota se muda de período o se vacía.
--   · DELETE o PATCH de los renglones: el tope de lo acreditable de la 236 es
--     SUM(nota_credito_items.cantidad), así que achicarlos reabre el tope y deja
--     acreditar dos veces la misma mercadería.
--   El front sólo lee estas tablas; las escrituras van por las RPC DEFINER.
--   En prod, al escribir esto: 0 compras canceladas con notas.
--
-- EL ARREGLO (decisión del dueño, 2026-10-13: triggers + cerrar REST de notas)
--   1 · compras_proteger_cancelacion (BEFORE UPDATE OF estado ON compras):
--       rechaza cancelar una compra que tiene notas y rechaza reabrir una
--       cancelada. Las únicas que escriben estado (anular_compra_atomica y
--       cambiar_proveedor_compra) ponen sólo 'cancelada' y ya miran las notas
--       antes, así que para ellas es un no-op.
--   2 · notas_credito_proteger_vinculo (BEFORE INSERT OR DELETE OR UPDATE OF
--       compra_id, sucursal_id ON notas_credito): la nota no se borra (ni sola
--       ni por el CASCADE del DELETE de su compra), no cambia de compra ni de
--       sucursal, y no nace sobre una compra cancelada.
--   3 · nota_credito_items_inmutable (BEFORE UPDATE OR DELETE ON
--       nota_credito_items): un renglón no se edita ni se borra.
--   4 · Se dropean mt_notas_credito_all y mt_nota_credito_items_all y se
--       revoca INSERT/UPDATE/DELETE/TRUNCATE de las dos tablas a authenticated y
--       anon. La lectura sigue por mt_*_select (es_admin ⊂ es_encargado_o_admin).
--       Las únicas que escriben (registrar_nota_credito y
--       registrar_nota_credito_lote) son DEFINER de postgres y no dependen de
--       esos grants.
--
--   Por qué hacen falta las dos cosas. Sólo con triggers, un PATCH de fecha o
--   de iva de la nota la saca del período igual (el trigger mira el vínculo, no
--   los importes). Sólo con el REVOKE, el DELETE de la compra sigue llevándose
--   las notas: la acción referencial del CASCADE corre como dueño de la tabla y
--   no la ve ningún grant ni ninguna policy. Y los triggers cubren además a una
--   función DEFINER futura, que tampoco ve los grants.
--
-- LOCKS
--   El BEFORE ROW de compras corre con la fila ya bloqueada por el UPDATE. El
--   conteo de notas es una sentencia propia (función VOLATILE: snapshot nuevo en
--   READ COMMITTED), así que ve toda nota cuya puerta tomó la compra FOR SHARE
--   antes y ya commiteó. El BEFORE INSERT de notas_credito toma la compra FOR
--   SHARE: es el mismo primer lock que las dos puertas de la 348, para ellas un
--   no-op, y le da el mismo orden a un INSERT que llegue por otro camino.
--   Por eso las tres funciones son SECURITY DEFINER: el FOR SHARE exige
--   privilegio de UPDATE y el conteo no puede depender de la RLS del que llama
--   (precedente: productos_rechazar_borrado_con_historial).
--
-- NO CAMBIA
--   Ninguna función existente (no hay CREATE OR REPLACE), ni las policies de
--   compras, ni service_role. STK-F / STK-D: no se mueve stock. No se agrega
--   check a auditoria_integridad. Las tres funciones son de trigger: EXECUTE
--   revocado a PUBLIC, anon y authenticated (quedan postgres y service_role,
--   como completar_origen_precio_item).
--
-- LO QUE QUEDA (a sabiendas)
--   · No existe una RPC para anular o editar una nota de compra. Si algún día se
--     hace, ese camino decide qué hace con estos triggers (un GUC de excepción o
--     una baja lógica de la nota).
--   · Reabrir una compra cancelada queda prohibido por cualquier camino. El
--     mantenimiento manual (una cancelación por error, un dato roto) pasa por
--     `SET session_replication_role = replica` o
--     `ALTER TABLE … DISABLE TRIGGER`, a sabiendas.
--   · TRUNCATE no dispara triggers de fila: queda revocado a authenticated y anon
--     y es cosa de postgres.
--   · La escritura REST del resto de la familia compras (cancelar o borrar una
--     compra SIN notas sin revertir stock, editar totales y líneas, compra_items,
--     compra_cargos, compra_cargo_repartos) va a un issue aparte.
--   · Supera la nota "LO QUE QUEDA" de la 348 sobre REST.
--
-- Ensayo: scripts/test-compra-nc-rest-1113.sql (falla antes, pasa después).

BEGIN;

-- 0 · Pre-check: el invariante tiene que valer hoy, o los triggers nacerían
--     custodiando un estado que ya está roto.
DO $pre$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
    FROM compras c
   WHERE c.estado = 'cancelada'
     AND EXISTS (SELECT 1 FROM notas_credito nc WHERE nc.compra_id = c.id);
  IF v_n > 0 THEN
    RAISE EXCEPTION '#1113 · hay % compra(s) cancelada(s) con notas de crédito: resolverlas a mano antes de aplicar', v_n;
  END IF;
END
$pre$;

-- 1 · compras: no se cancela con notas, no se reabre.
CREATE FUNCTION public.compras_proteger_cancelacion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_n integer;
BEGIN
  -- La WHEN del trigger ya garantiza que el estado cambia y que uno de los dos
  -- lados es 'cancelada'.
  IF OLD.estado = 'cancelada' THEN
    RAISE EXCEPTION 'La compra % está cancelada: no se reabre. Si se anuló por error, cargala de nuevo.', OLD.id;
  END IF;

  -- La fila de compras ya está bloqueada por este UPDATE; el conteo es una
  -- sentencia nueva y ve las notas ya commiteadas (ver el encabezado).
  SELECT count(*) INTO v_n FROM notas_credito WHERE compra_id = OLD.id;
  IF v_n > 0 THEN
    -- Mismo texto que anular_compra_atomica (348).
    RAISE EXCEPTION 'La compra tiene % nota(s) de crédito: no se puede anular. Si se devuelve el resto de la mercadería, registralo con otra nota de crédito.', v_n;
  END IF;

  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_compras_proteger_cancelacion
  BEFORE UPDATE OF estado ON public.compras
  FOR EACH ROW
  WHEN (OLD.estado IS DISTINCT FROM NEW.estado
        AND (OLD.estado = 'cancelada' OR NEW.estado = 'cancelada'))
  EXECUTE FUNCTION public.compras_proteger_cancelacion();

-- 2 · notas_credito: no se borra, no se despega, no nace sobre una cancelada.
CREATE FUNCTION public.notas_credito_proteger_vinculo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_estado text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    -- Cubre el DELETE directo y el CASCADE del DELETE de la compra, que corre
    -- como dueño de la tabla: el DELETE de la compra aborta entero.
    RAISE EXCEPTION 'La nota de crédito % de la compra % es un comprobante del proveedor: no se borra, ni sola ni con su compra.',
      OLD.id, OLD.compra_id;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.compra_id IS DISTINCT FROM OLD.compra_id
       OR NEW.sucursal_id IS DISTINCT FROM OLD.sucursal_id THEN
      RAISE EXCEPTION 'La nota de crédito % es de la compra %: no se pasa a otra compra ni a otra sucursal.',
        OLD.id, OLD.compra_id;
    END IF;
    RETURN NEW;
  END IF;

  -- INSERT: la compra FOR SHARE, el mismo primer lock que las puertas de la
  -- 348 (para ellas, que ya la tienen, es un no-op). Si no existe, decide la FK.
  SELECT estado INTO v_estado
    FROM compras
   WHERE id = NEW.compra_id AND sucursal_id = NEW.sucursal_id
     FOR SHARE;
  IF v_estado = 'cancelada' THEN
    RAISE EXCEPTION 'La compra % está cancelada: no se le puede registrar una nota de crédito.', NEW.compra_id;
  END IF;

  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_notas_credito_proteger_vinculo
  BEFORE INSERT OR DELETE OR UPDATE OF compra_id, sucursal_id ON public.notas_credito
  FOR EACH ROW
  EXECUTE FUNCTION public.notas_credito_proteger_vinculo();

-- 3 · nota_credito_items: inmutable.
--     El CASCADE desde notas_credito no llega (lo frena antes el trigger 2), y
--     el CASCADE desde productos ya lo ataja
--     productos_rechazar_borrado_con_historial; un producto sin renglones de
--     nota no dispara nada. DEFINER por uniformidad: no lee nada.
CREATE FUNCTION public.nota_credito_items_inmutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  RAISE EXCEPTION 'Un renglón de nota de crédito de compra no se edita ni se borra (nota %, renglón %).',
    OLD.nota_credito_id, OLD.id;
END;
$fn$;

CREATE TRIGGER trg_nota_credito_items_inmutable
  BEFORE UPDATE OR DELETE ON public.nota_credito_items
  FOR EACH ROW
  EXECUTE FUNCTION public.nota_credito_items_inmutable();

-- Funciones de trigger: no las llama nadie, las invoca el executor.
REVOKE EXECUTE ON FUNCTION public.compras_proteger_cancelacion()   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notas_credito_proteger_vinculo() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.nota_credito_items_inmutable()   FROM PUBLIC, anon, authenticated;

-- 4 · Cerrar la escritura REST de las notas. La lectura queda en las mt_*_select.
DROP POLICY mt_notas_credito_all       ON public.notas_credito;
DROP POLICY mt_nota_credito_items_all  ON public.nota_credito_items;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.notas_credito, public.nota_credito_items
  FROM authenticated, anon;

-- 5 · Verificación post-DDL.
DO $verif$
DECLARE
  v_t   text;
  v_def text;
  v_fn  regprocedure;
  v_rol text;
  v_priv text;
  v_pols text[];
BEGIN
  FOR v_t, v_def IN
    SELECT t.tgname, pg_get_triggerdef(t.oid)
      FROM pg_trigger t
     WHERE t.tgname IN ('trg_compras_proteger_cancelacion',
                        'trg_notas_credito_proteger_vinculo',
                        'trg_nota_credito_items_inmutable')
       AND t.tgenabled = 'O'
  LOOP
    IF NOT (
         (v_t = 'trg_compras_proteger_cancelacion'
          AND v_def LIKE '%BEFORE UPDATE OF estado ON public.compras FOR EACH ROW WHEN%')
      OR (v_t = 'trg_notas_credito_proteger_vinculo'
          AND v_def LIKE '%BEFORE INSERT OR DELETE OR UPDATE OF compra_id, sucursal_id ON public.notas_credito FOR EACH ROW%')
      OR (v_t = 'trg_nota_credito_items_inmutable'
          AND v_def LIKE '%BEFORE DELETE OR UPDATE ON public.nota_credito_items FOR EACH ROW%')) THEN
      RAISE EXCEPTION '#1113 · el trigger % quedó distinto de lo esperado: %', v_t, v_def;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_trigger
       WHERE tgname IN ('trg_compras_proteger_cancelacion',
                        'trg_notas_credito_proteger_vinculo',
                        'trg_nota_credito_items_inmutable')
         AND tgenabled = 'O') <> 3 THEN
    RAISE EXCEPTION '#1113 · faltan triggers habilitados';
  END IF;

  FOREACH v_fn IN ARRAY ARRAY['public.compras_proteger_cancelacion()'::regprocedure,
                              'public.notas_credito_proteger_vinculo()'::regprocedure,
                              'public.nota_credito_items_inmutable()'::regprocedure]
  LOOP
    FOREACH v_rol IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF has_function_privilege(v_rol, v_fn, 'EXECUTE') THEN
        RAISE EXCEPTION '#1113 · % quedó ejecutable por %', v_fn, v_rol;
      END IF;
    END LOOP;
  END LOOP;

  FOREACH v_t IN ARRAY ARRAY['public.notas_credito', 'public.nota_credito_items'] LOOP
    FOREACH v_rol IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
        IF has_table_privilege(v_rol, v_t, v_priv) THEN
          RAISE EXCEPTION '#1113 · % conserva % sobre %', v_rol, v_priv, v_t;
        END IF;
      END LOOP;
    END LOOP;
    IF NOT has_table_privilege('authenticated', v_t, 'SELECT') THEN
      RAISE EXCEPTION '#1113 · authenticated perdió SELECT sobre %', v_t;
    END IF;
  END LOOP;

  SELECT array_agg(tablename || '.' || policyname ORDER BY tablename, policyname) INTO v_pols
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename IN ('notas_credito', 'nota_credito_items');
  IF v_pols IS DISTINCT FROM ARRAY['nota_credito_items.mt_nota_credito_items_select',
                                   'notas_credito.mt_notas_credito_select'] THEN
    RAISE EXCEPTION '#1113 · las policies de las notas quedaron %', v_pols;
  END IF;
END
$verif$;

COMMIT;
