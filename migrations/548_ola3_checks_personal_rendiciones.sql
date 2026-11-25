-- =========================================================================
-- NNN · CHECKS DE INTEGRIDAD DEL PERSONAL Y DE LAS RENDICIONES: LIQ-A, LIQ-B, LIQ-C,
--       FALT-A, FALT-B y FALT-C (plan #1677, ola 3, tarjeta T1: #1392 y #1426)
--
-- Ensayo: scripts/test-ola3-checks-personal-rendiciones.sql. Se aplica en LF, en una sola
-- transacción o sentencia por sentencia. Sólo cambia auditoria_integridad(): ninguna tabla,
-- ningún dato, ninguna otra función.
--
-- QUÉ PASABA
--   · Las liquidaciones (gastos 5, mig 437) y los faltantes de rendición (gastos 6, mig 446)
--     tienen invariantes que sólo miraban los casos 19 de test-gastos-5.sql y 20 de
--     test-gastos-6.sql, cuando alguien los corría a mano. auditoria_integridad() no los
--     miraba, así que una liquidación descuadrada o un faltante suelto no ponía nada en rojo.
--
-- QUÉ CAMBIA: seis checks nuevos al final de la lista de auditoria_integridad(), todos
-- `high`, como los del personal que ya estaban (EMP-*, ROT-*, GASTO-A, REND-*): son plata de
-- la cuenta de un empleado o de una rendición cerrada.
--   LIQ-A  · liquidación vigente cuyos movimientos no suman sus conceptos menos lo pagado.
--   LIQ-B  · línea de comisión con dos filas no-ajuste vigentes del mismo vendedor (hoy lo
--            frena el índice único empleado_liquidacion_lineas_key: el check ve si se cae).
--   LIQ-C  · pago al personal (o su reversión) de una rendición cerrada, cargado después del
--            cierre: confirmada → controlada_at; resuelta → resuelta_at (mientras está en
--            disconformidad se le puede cargar un pago, m1 de #1392). Es el molde de GASTO-A.
--            No ve un pago borrado ni uno cambiado de monto (no hay foto de los pagos al
--            personal): no hay escritura REST de empleado_movimientos que lo permita.
--   FALT-A · línea de faltante viva sin su movimiento `faltante` vivo (que no exista, que no
--            sea su espejo —monto, empleado, rendición— o que ya tenga compensación) o sin su
--            gasto vivo de la misma rendición y el mismo monto.
--   FALT-B · movimiento `faltante` (no una compensación) que ninguna línea nombra.
--   FALT-C · línea anulada cuyo movimiento no tiene la compensación por el mismo monto, o
--            cuyo gasto sigue sin anular.
--   Los moldes son el caso 19 de test-gastos-5.sql (LIQ-A y LIQ-B tal cual) y el caso 20 de
--   test-gastos-6.sql (FALT-A, B y C tal cual).
--
-- IDS: antes de esta migración ninguno empieza con LIQ- ni con FALT- (lo mira la premisa).
--
-- PREMISA: md5(prosrc) de auditoria_integridad() es el de la 547. Reaplicarla aborta ahí.
-- Se parchea por ancla (la misma de la 537: el cierre de la lista VALUES) sobre
-- pg_get_functiondef, que conserva el SET search_path (public, pg_temp), SECURITY DEFINER y
-- STABLE; CREATE OR REPLACE conserva los grants (postgres, authenticated, service_role).
--
-- LOCKS: ninguno de tabla. CREATE OR REPLACE FUNCTION sólo toma la fila de pg_proc.
-- EMBEDS DE POSTGREST: no hay FK nuevas.
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Premisas: el cuerpo vivo es el de la 547 y los ids están libres
-- -------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_ancla text := $a$
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))$a$;
  v_def   text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_md5   text := (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.auditoria_integridad()'::regprocedure);
BEGIN
  IF v_md5 IS DISTINCT FROM 'c4d51a69a93898b12297b62194b7eacc' THEN
    RAISE EXCEPTION 'premisa · auditoria_integridad() no es la de la 547 (md5 %): ¿la migración ya se aplicó, u otra la cambió?', v_md5;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla) <> 1 THEN
    RAISE EXCEPTION 'premisa · el ancla de auditoria_integridad() no aparece exactamente una vez';
  END IF;
  IF v_def ~ '''(LIQ|FALT)-' THEN
    RAISE EXCEPTION 'premisa · auditoria_integridad() ya tiene un id LIQ- o FALT-';
  END IF;
  IF to_regclass('public.empleado_liquidaciones') IS NULL
     OR to_regclass('public.empleado_liquidacion_conceptos') IS NULL
     OR to_regclass('public.empleado_liquidacion_lineas') IS NULL
     OR to_regclass('public.rendicion_faltantes') IS NULL THEN
    RAISE EXCEPTION 'premisa · faltan las tablas de liquidaciones o de faltantes';
  END IF;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · auditoria_integridad(): LIQ-A, LIQ-B, LIQ-C, FALT-A, FALT-B y FALT-C
-- -------------------------------------------------------------------------
DO $integridad$
DECLARE
  v_def   text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_ancla text := $a$
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))$a$;
BEGIN
  v_def := replace(v_def, v_ancla, $n$,
    -- #1392 (gastos 5) · lo que la liquidación movió en la cuenta es lo que liquidó menos
    -- lo que pagó. La anulada no cuenta: su pago puede sobrevivir (GTO-4, #1521).
    ('LIQ-A','high','liquidaciones vigentes cuyos movimientos no suman sus conceptos menos lo pagado (#1392)',
      (SELECT count(*) FROM empleado_liquidaciones l
        WHERE l.anulada_at IS NULL
          AND COALESCE((SELECT sum(m.monto) FROM empleado_movimientos m WHERE m.liquidacion_id = l.id), 0)
              <> COALESCE((SELECT sum(c.monto) FROM empleado_liquidacion_conceptos c WHERE c.liquidacion_id = l.id), 0)
                 - l.pagado)),
    -- #1392 · una línea se comisiona una vez por vendedor; con otro vendedor es legítimo
    -- hasta que el anterior tenga su ajuste. Lo frena el índice único
    -- empleado_liquidacion_lineas_key: esto ve si se cae o se saltea.
    ('LIQ-B','high','líneas de comisión con dos filas no-ajuste vigentes del mismo vendedor (#1392)',
      (SELECT count(*) FROM (SELECT 1 FROM empleado_liquidacion_lineas
                              WHERE vigente AND tipo <> 'ajuste'
                              GROUP BY pedido_id, clave, usuario_id HAVING count(*) > 1) x)),
    -- #1392 · el efectivo a entregar de una rendición cerrada resta sus pagos al personal:
    -- un pago (o su reversión) cargado después del cierre cambia lo cerrado. Lo frenan
    -- _pago_de_rendicion y revertir_movimiento_empleado. La resuelta cierra en resuelta_at:
    -- en disconformidad todavía se le carga un pago (m1 de #1392). El molde es GASTO-A.
    ('LIQ-C','high','pagos al personal de una rendición cerrada cargados o revertidos después del cierre (#1392)',
      (SELECT count(*) FROM empleado_movimientos m
         JOIN rendiciones_control rc
           ON rc.transportista_id = m.rendicion_transportista_id AND rc.fecha = m.rendicion_fecha
          AND rc.sucursal_id = m.rendicion_sucursal_id
        WHERE m.tipo = 'pago'
          AND rc.estado IN ('confirmada', 'resuelta')
          AND m.created_at > CASE WHEN rc.estado = 'resuelta' THEN rc.resuelta_at ELSE rc.controlada_at END)),
    -- #1426 (gastos 6) · la línea viva de un faltante apunta a lo que creó, vivo y su espejo:
    -- el movimiento `faltante` del empleado por el monto en negativo y sin compensar, o el
    -- gasto de la rendición por el monto, sin anular.
    ('FALT-A','high','líneas de faltante vivas sin su movimiento o su gasto vivo (#1426)',
      (SELECT count(*) FROM rendicion_faltantes f
        WHERE f.anulada_at IS NULL
          AND NOT CASE WHEN f.causal = 'empleado'
                       THEN EXISTS (SELECT 1 FROM empleado_movimientos m
                                     WHERE m.id = f.movimiento_id AND m.tipo = 'faltante' AND m.monto = -f.monto
                                       AND m.empleado_id = f.empleado_id AND m.rendicion_fecha = f.rendicion_fecha
                                       AND m.rendicion_transportista_id = f.rendicion_transportista_id
                                       AND m.rendicion_sucursal_id = f.rendicion_sucursal_id)
                            AND NOT EXISTS (SELECT 1 FROM empleado_movimientos r WHERE r.revierte_id = f.movimiento_id)
                       ELSE EXISTS (SELECT 1 FROM gastos gs
                                     WHERE gs.id = f.gasto_id AND gs.anulado_at IS NULL AND gs.monto_total = f.monto
                                       AND gs.origen_pago = 'rendicion' AND gs.rendicion_fecha = f.rendicion_fecha
                                       AND gs.rendicion_transportista_id = f.rendicion_transportista_id
                                       AND gs.sucursal_id = f.rendicion_sucursal_id) END)),
    -- #1426 · un faltante nace sólo de resolver_rendicion, con su línea; la compensación
    -- (revierte_id) la deja deshacer_resolucion_rendicion y no lleva línea propia.
    ('FALT-B','high','movimientos «faltante» que ninguna línea de faltante nombra (#1426)',
      (SELECT count(*) FROM empleado_movimientos m
        WHERE m.tipo = 'faltante' AND m.revierte_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM rendicion_faltantes f WHERE f.movimiento_id = m.id))),
    -- #1426 · una resolución se deshace toda junta: la línea anulada deja su movimiento
    -- compensado por el mismo monto y su gasto anulado.
    ('FALT-C','high','líneas de faltante anuladas con su movimiento sin compensar o su gasto sin anular (#1426)',
      (SELECT count(*) FROM rendicion_faltantes f
        WHERE f.anulada_at IS NOT NULL
          AND NOT CASE WHEN f.causal = 'empleado'
                       THEN EXISTS (SELECT 1 FROM empleado_movimientos r
                                     WHERE r.revierte_id = f.movimiento_id AND r.monto = f.monto)
                       ELSE EXISTS (SELECT 1 FROM gastos gs WHERE gs.id = f.gasto_id AND gs.anulado_at IS NOT NULL) END))$n$
    || v_ancla);
  -- La regla del search_path (B15): termina en pg_temp. Si ya lo tenía, no cambia.
  IF v_def !~ 'SET search_path TO [^\n]*pg_temp' THEN
    v_def := regexp_replace(v_def, '(SET search_path TO [^\n]*)', '\1, ''pg_temp''');
  END IF;
  EXECUTE v_def;
END
$integridad$;

-- -------------------------------------------------------------------------
-- 2 · Poscondición
-- -------------------------------------------------------------------------
DO $post$
DECLARE
  v_src text := (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_integridad()'::regprocedure);
BEGIN
  IF md5(v_src) IS DISTINCT FROM 'c7dfa8d33ffc4b70a26a0ce1122d4eee' THEN
    RAISE EXCEPTION 'poscondición · auditoria_integridad() no quedó con el cuerpo esperado (md5 %)', md5(v_src);
  END IF;
  IF (SELECT count(*) FROM regexp_matches(v_src, '\(''(LIQ-A|LIQ-B|LIQ-C|FALT-A|FALT-B|FALT-C)'',''high''', 'g')) <> 6 THEN
    RAISE EXCEPTION 'poscondición · auditoria_integridad() no tiene los seis checks LIQ-A..C y FALT-A..C, una vez cada uno';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc
                  WHERE oid = 'public.auditoria_integridad()'::regprocedure
                    AND prosecdef AND provolatile = 's'
                    AND 'search_path=public, pg_temp' = ANY(proconfig)) THEN
    RAISE EXCEPTION 'poscondición · auditoria_integridad() perdió SECURITY DEFINER, STABLE o el search_path terminado en pg_temp';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.auditoria_integridad()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.auditoria_integridad()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.auditoria_integridad()', 'EXECUTE') THEN
    RAISE EXCEPTION 'poscondición · los permisos de auditoria_integridad() no son los de antes';
  END IF;
END
$post$;

COMMIT;
