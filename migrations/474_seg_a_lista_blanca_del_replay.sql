-- 474 · La lista blanca de SEG-A reconoce el cuerpo nuevo de crear_pedido_idempotente (#1492, tarjeta 15 de #1477).
--
-- QUÉ PASABA
--   La 473 cambió el cuerpo de crear_pedido_idempotente: el replay suma saldo_a_favor_aplicado. La función es
--   SECURITY DEFINER sin guard de rol propio (delega en crear_pedido_completo) y está en la lista blanca de
--   auditoria_definer_sin_rol() por firma + md5 del cuerpo (#1074). Con el md5 viejo, SEG-A de
--   auditoria_integridad() quedó en rojo con una violación: "está en la lista blanca pero el cuerpo cambió".
--   Lo vio la tarjeta 14 al auditar después de su 472.
--
-- QUÉ CAMBIA
--   Sólo el md5 de esa entrada, 4b3269a9… → 63f07592… (el de la 473). Se revisó el cuerpo nuevo: el replay
--   lee los pagos del mismo pedido que ya devolvía (por offline_id y sucursal, con su total y su cargo), sin
--   nada que pida un rol que no pidiera antes.
--
-- QUÉ NO CAMBIA
--   Ninguna otra entrada, la lógica de la auditoría, ni los EXECUTE.
--
-- Ensayo: scripts/test-saldo-bajos-1492.sql (L4). Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: el cuerpo vivo de la auditoría es el que se leyó de prod (06/11), y la 473 está aplicada
-- ---------------------------------------------------------------------------
DO $premisas$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.auditoria_definer_sin_rol()'::regprocedure)
     <> '406ca02dcace71779dbd70471ea639c6' THEN
    RAISE EXCEPTION 'mig 474 · auditoria_definer_sin_rol() cambió en prod desde que se leyó: rehacer sobre la definición vigente';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)'::regprocedure)
     <> '63f0759223a668afdd04ce684aee18ef' THEN
    RAISE EXCEPTION 'mig 474 · crear_pedido_idempotente no tiene el cuerpo de la 473';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parche por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
DO $parche$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
  v_ancla text := $a$    ('crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
                                                 '4b3269a9cb146415c16f70de01dbe23a'),
$a$;
  v_reemplazo text := $r$    -- #1492 (mig 473): el replay suma lo que el pedido absorbió de saldo a favor, del
    -- mismo pedido que ya devolvía (total y cargo), sin otro guard.
    ('crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
                                                 '63f0759223a668afdd04ce684aee18ef'),
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 474 · el ancla aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche$;

-- ---------------------------------------------------------------------------
-- Poscondición: el cuerpo y los EXECUTE quedaron como en el repo, y SEG-A ya no ve el replay
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO r
    FROM pg_proc WHERE oid = 'public.auditoria_definer_sin_rol()'::regprocedure;
  IF r.h <> '0273d33a122c2ab5c19b6ad17a8c57ab'
     OR r.a IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}'
     OR NOT r.def THEN
    RAISE EXCEPTION 'auditoria_definer_sin_rol() no quedó como en el repo (md5 %, acl %, definer %)', r.h, r.a, r.def;
  END IF;
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() h WHERE h::text ~ 'crear_pedido_idempotente') THEN
    RAISE EXCEPTION 'mig 474 · SEG-A sigue viendo crear_pedido_idempotente';
  END IF;
END
$post$;

COMMIT;
