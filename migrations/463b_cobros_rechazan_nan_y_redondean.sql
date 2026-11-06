-- 463 · Cobros: el monto NaN, el centavo de tolerancia y la baja "anulado" (#1468).
--
-- QUÉ PASABA
--   1. COB-F-1. En Postgres 'NaN'::numeric > 0 es verdadero y LEAST('NaN', falta) da la
--      falta. Un admin o encargado que llamaba el cobro FIFO con p_monto "NaN" (PostgREST
--      convierte el texto) pasaba la guarda `<= 0` y el CHECK pagos_monto_positivo: el FIFO
--      saldaba enteras todas las boletas impagas del cliente con plata que no entró, y el
--      resto quedaba como un pago NaN que volvía NaN el saldo_cuenta. El combinado, el
--      cobro de boleta (el monto va como texto "NaN" en el JSON) y la imputación de un
--      crédito (LEAST con NaN imputaba el crédito entero) tenían el mismo agujero.
--   2. COB-F-2. registrar_pagos_pedido_impl comparaba con 0,005 de tolerancia y sin
--      redondear: 100,005 sobre una falta de 100,00 entraba, se guardaba 100,01 y dejaba
--      monto_pagado > total (CC-C rojo). En los FIFO, 100,005 imputaba 100 y dejaba un
--      pedazo de 0,005 que se guardaba como 0,01 a favor; 100,004, uno de 0,00 que chocaba
--      con el CHECK.
--   3. COB-F-6 (servidor). obtener_resumen_cuenta_cliente y reporte_cuentas_por_cobrar
--      daban de baja sólo 'cancelado'. El resto del sistema (los cobros, el trigger
--      pagos_rechazar_pedido_de_baja, pedidos_guard_baja) usa ('cancelado', 'anulado').
--      Hoy hay 0 pedidos anulados.
--
-- QUÉ CAMBIA
--   - `_monto_de_cobro(numeric)`: rechaza NaN e infinito con 22023 y redondea al centavo.
--     NULL sigue siendo NULL: cada llamador conserva su propio rechazo de NULL y de <= 0,
--     que ahora mira el monto redondeado (0,004 es 0). Es de server: sin EXECUTE para
--     PUBLIC, anon ni authenticated; la llaman sólo las RPCs DEFINER.
--   - Los dos FIFO, el cobro de boleta y imputar_credito_a_pedido_impl pasan cada monto
--     del cliente por ahí antes de compararlo o imputarlo, y el cobro de boleta compara
--     sin tolerancia (los dos lados ya son centavos). La lógica va en el _impl: las RPCs
--     de pago son wrappers (mig 167).
--   - CHECK pagos_monto_no_nan en `pagos` (0 filas NaN hoy). El infinito no cabe en
--     numeric(12,2).
--   - La baja es ('cancelado', 'anulado') en las dos lecturas. `estado` es NOT NULL, así
--     que `NOT IN` no cambia nada más.
--
-- QUÉ NO CAMBIA
--   Las firmas, los EXECUTE, los mensajes de error de siempre y el resto de los cuerpos.
--   aplicar_credito_cliente y actualizar_forma_pago_pago no reciben montos del cliente:
--   no se tocan. Los masivos (marcar_pagos_masivo_impl, marcar_entrega_y_pago_masivo_impl)
--   no son de esta tarjeta; el CHECK nuevo les cierra el NaN igual.
--
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: los cuerpos vivos son los que se leyeron el 05/11
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_premisa (firma text PRIMARY KEY, md5_antes text, md5_despues text, acl text) ON COMMIT DROP;

INSERT INTO _n_premisa (firma, md5_antes, md5_despues) VALUES
('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)',
 '1d8f2a4a23c249bdbc5ad21b6ca06f7a', '2bc25566a28abf747779a026d1ac5a0b'),
('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)',
 'e7036637cb189259839094415247ae1f', 'e3cdf655997c7f79ee15418fc34683e5'),
('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)',
 '64e4eaf1ab99af02c7718d2cd6fc632f', '9285a8f7dff736eb60503867f05e80ad'),
('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',
 '59db660b20b9f8e36ad918990ac65150', 'ae896fc8c353b95438941b1a4dd43d86'),
('public.obtener_resumen_cuenta_cliente(integer)',
 '7c55183dd55e7f8adb7670f8a0e5568f', '8e60a772daa3594038b18e6a22fd294b'),
('public.reporte_cuentas_por_cobrar(bigint)',
 '24a7fb85efa3487cf4a3eb772aa5999b', '3304593de122f74f4568eb104bb7bf8b');

DO $premisas$
DECLARE
  r     record;
  v_md5 text;
  v_acl text;
BEGIN
  FOR r IN SELECT * FROM _n_premisa ORDER BY firma LOOP
    SELECT md5(p.prosrc), p.proacl::text INTO v_md5, v_acl
      FROM pg_proc p WHERE p.oid = r.firma::regprocedure;
    IF v_md5 IS DISTINCT FROM r.md5_antes THEN
      RAISE EXCEPTION 'mig 463 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        r.firma, v_md5, r.md5_antes;
    END IF;
    UPDATE _n_premisa SET acl = v_acl WHERE firma = r.firma;
  END LOOP;

  IF to_regprocedure('public._monto_de_cobro(numeric)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 463 · _monto_de_cobro ya existe: rehacer sobre lo vigente';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pagos'::regclass AND conname = 'pagos_monto_no_nan') THEN
    RAISE EXCEPTION 'mig 463 · pagos_monto_no_nan ya existe: rehacer sobre lo vigente';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1. El monto de un cobro: un número, al centavo
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._monto_de_cobro(p_monto numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $function$
BEGIN
  -- #1468: 'NaN'::numeric > 0 es verdadero y LEAST('NaN', x) da x, así que un NaN pasaba
  -- toda guarda `<= 0`. El infinito, igual. NULL vuelve NULL: el llamador lo rechaza con
  -- su propio mensaje, como el <= 0 del monto ya redondeado.
  IF p_monto = 'NaN'::numeric OR p_monto IN ('Infinity'::numeric, '-Infinity'::numeric) THEN
    RAISE EXCEPTION 'El monto (%) no es un número', p_monto USING ERRCODE = '22023';
  END IF;
  -- pagos.monto es numeric(12,2): se compara contra lo que falta con el valor que se va a
  -- guardar, no con el crudo.
  RETURN round(p_monto, 2);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public._monto_de_cobro(numeric) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._monto_de_cobro(numeric) IS
  '#1468: el monto de un cobro que manda el cliente. Rechaza NaN e infinito (22023) y redondea al centavo. Sólo la llaman las RPCs de cobro (DEFINER).';

-- ---------------------------------------------------------------------------
-- 2. CHECK: un pago NaN no entra por ningún camino
-- ---------------------------------------------------------------------------
ALTER TABLE public.pagos
  ADD CONSTRAINT pagos_monto_no_nan CHECK (monto <> 'NaN'::numeric);

-- ---------------------------------------------------------------------------
-- 3. Parche por ancla sobre los cuerpos vivos
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
-- registrar_pago_cliente_fifo_impl
('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 1,
$a$  v_restante numeric := p_monto;
$a$,
$r$  v_monto numeric;
  v_restante numeric;
$r$),
('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 2,
$a$  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'Monto debe ser mayor a 0' USING ERRCODE = '22023';
  END IF;
$a$,
$r$  -- #1468: un NaN pasaba esta guarda (NaN > 0 es verdadero) y LEAST(NaN, falta) saldaba
  -- las boletas con plata que no entró. Y sin redondear, 100,005 imputaba 100 y dejaba
  -- 0,005 que se guardaba como 0,01 a favor. _monto_de_cobro rechaza el NaN y redondea.
  v_monto := public._monto_de_cobro(p_monto);
  IF v_monto IS NULL OR v_monto <= 0 THEN
    RAISE EXCEPTION 'Monto debe ser mayor a 0' USING ERRCODE = '22023';
  END IF;
  v_restante := v_monto;
$r$),
('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 3,
$a$    'monto_total', p_monto,
$a$,
$r$    'monto_total', v_monto,
$r$),
-- registrar_pago_combinado_cliente_fifo_impl
('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 1,
$a$    v_monto := NULLIF(v_metodo->>'monto', '')::numeric;
$a$,
$r$    -- #1468: un "NaN" pasaba el <= 0, y sin redondear se imputaba un monto que no es el
    -- que se guarda. Ver registrar_pago_cliente_fifo_impl.
    v_monto := public._monto_de_cobro(NULLIF(v_metodo->>'monto', '')::numeric);
$r$),
('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)', 2,
$a$    v_monto := (v_metodo->>'monto')::numeric;
$a$,
$r$    v_monto := public._monto_de_cobro((v_metodo->>'monto')::numeric);
$r$),
-- registrar_pagos_pedido_impl
('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)', 1,
$a$    v_monto := NULLIF(v_metodo->>'monto', '')::numeric;
$a$,
$r$    -- #1468: un "NaN" pasaba el <= 0; y el monto se compara contra lo que falta ya
    -- redondeado al centavo, que es lo que se guarda.
    v_monto := public._monto_de_cobro(NULLIF(v_metodo->>'monto', '')::numeric);
$r$),
('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)', 2,
$a$  IF v_total > v_falta + 0.005 THEN
$a$,
$r$  -- #1468: sin tolerancia. Los dos lados son centavos; con 0,005, un cobro de 100,005
  -- sobre 100 entraba, se guardaba 100,01 y dejaba monto_pagado > total.
  IF v_total > v_falta THEN
$r$),
('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)', 3,
$a$      v_pedido.cliente_id, v_pedido.id, (v_metodo->>'monto')::numeric,
$a$,
$r$      v_pedido.cliente_id, v_pedido.id, public._monto_de_cobro((v_metodo->>'monto')::numeric),
$r$),
-- imputar_credito_a_pedido_impl
('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', 1,
$a$  IF p_monto IS NOT NULL AND p_monto <= 0 THEN
$a$,
$r$  -- #1468: un NaN pasaba esta guarda y LEAST(..., NaN) imputaba el crédito entero en vez
  -- de lo pedido. _monto_de_cobro lo rechaza; NULL (imputar todo) sigue pasando.
  IF public._monto_de_cobro(p_monto) <= 0 THEN
$r$),
-- obtener_resumen_cuenta_cliente
('public.obtener_resumen_cuenta_cliente(integer)', 1,
$a$  -- Un pedido cancelado tampoco, igual que en la copia _bot (#1044).
$a$,
$r$  -- Un pedido de baja tampoco (#1044): cancelado o anulado, como en el resto del
  -- sistema (#1468).
$r$);

INSERT INTO _n_parche (firma, orden, ancla, reemplazo, veces) VALUES
('public.obtener_resumen_cuenta_cliente(integer)', 2,
$a$estado IS DISTINCT FROM 'cancelado'$a$,
$r$estado NOT IN ('cancelado', 'anulado')$r$, 5);

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
-- reporte_cuentas_por_cobrar
('public.reporte_cuentas_por_cobrar(bigint)', 1,
$a$    WHERE p.estado <> 'cancelado'
$a$,
$r$    WHERE p.estado NOT IN ('cancelado', 'anulado')  -- #1468: la baja son los dos
$r$),
('public.reporte_cuentas_por_cobrar(bigint)', 2,
$a$'Pedidos no cancelados con saldo$a$,
$r$'Pedidos no cancelados ni anulados con saldo$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _n_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _n_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig 463 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos quedaron como en el repo, con los mismos EXECUTE; el helper
-- es de server, lo pueden llamar los dueños de las RPCs, y el CHECK está validado.
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r       record;
  v_md5   text;
  v_acl   text;
  v_falla boolean;
BEGIN
  FOR r IN SELECT * FROM _n_premisa ORDER BY firma LOOP
    SELECT md5(p.prosrc), p.proacl::text INTO v_md5, v_acl
      FROM pg_proc p WHERE p.oid = r.firma::regprocedure;
    IF v_md5 IS DISTINCT FROM r.md5_despues OR v_acl IS DISTINCT FROM r.acl THEN
      RAISE EXCEPTION 'mig 463 · % no quedó como en el repo (md5 %, esperado %; acl %, antes %)',
        r.firma, v_md5, r.md5_despues, v_acl, r.acl;
    END IF;
    IF NOT has_function_privilege((SELECT p.proowner FROM pg_proc p WHERE p.oid = r.firma::regprocedure),
                                  'public._monto_de_cobro(numeric)', 'EXECUTE') THEN
      RAISE EXCEPTION 'mig 463 · el dueño de % no puede ejecutar _monto_de_cobro', r.firma;
    END IF;
  END LOOP;

  SELECT p.proacl::text INTO v_acl FROM pg_proc p WHERE p.oid = 'public._monto_de_cobro(numeric)'::regprocedure;
  IF v_acl IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'mig 463 · _monto_de_cobro quedó con EXECUTE %', v_acl;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.pagos'::regclass AND conname = 'pagos_monto_no_nan' AND convalidated) THEN
    RAISE EXCEPTION 'mig 463 · falta el CHECK pagos_monto_no_nan validado';
  END IF;

  IF public._monto_de_cobro(100.005) <> 100.01 OR public._monto_de_cobro(0.004) <> 0
     OR public._monto_de_cobro(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'mig 463 · _monto_de_cobro no redondea al centavo';
  END IF;
  BEGIN
    PERFORM public._monto_de_cobro('NaN'::numeric);
    v_falla := false;
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_falla := true;
  END;
  IF NOT v_falla THEN
    RAISE EXCEPTION 'mig 463 · _monto_de_cobro dejó pasar un NaN';
  END IF;
END
$post$;

COMMIT;
