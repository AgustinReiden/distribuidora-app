-- 473 · El replay del alta trae el saldo a favor que absorbió, y la rendición no le pasa ese crédito al chofer
-- de la boleta nueva (#1492, tarjeta 15 de #1477).
--
-- QUÉ PASABA
--   · Punto 2 de #1492. Desde la 463c la boleta nueva absorbe el saldo a favor del cliente y
--     crear_pedido_completo devuelve saldo_a_favor_aplicado. El front descuenta eso del cobro del alta
--     (montoCobroAlta). Pero si se pierde la respuesta y el PWA reintenta, crear_pedido_idempotente
--     contesta el replay con success, pedido_id, idempotente, total y cargo_envio, sin el saldo. El front
--     cobra el total entero, registrar_pagos_pedido_impl lo rechaza por pasarse de lo que falta, y el
--     preventista ve "se creó, pero no se pudo registrar el cobro". No hay plata mal.
--   · Punto 4 de #1492. _rendicion_pagos le asigna cada pago vivo a COALESCE(pd.transportista_id,
--     pg.usuario_id). Un crédito suelto es de quien lo cobró (pg.usuario_id). Cuando una boleta lo absorbe,
--     pasa a ser del chofer de esa boleta: si no estaba en ninguna foto confirmada, el chofer queda debiendo
--     plata que no cobró, y al que la cobró le desaparece. Venía de antes (imputar_credito_a_pedido,
--     aplicar_credito_cliente); la 463c lo vuelve rutinario.
--
-- QUÉ CAMBIA
--   · crear_pedido_idempotente: la rama de replay suma saldo_a_favor_aplicado, lo que la boleta tiene
--     cobrado desde un crédito (los pagos con de_saldo_a_favor, que pone un trigger). Es lo que devolvió el
--     alta; si después entró más crédito, es lo de hoy, que es lo que el front necesita para no cobrar de
--     más. saldo_a_favor_otras (lo que fue a boletas más viejas) no se guarda en ningún lado y no se repite:
--     el replay no muestra ese aviso.
--   · _rendicion_pagos: el dueño de un pago con de_saldo_a_favor es pg.usuario_id, el mismo que tenía como
--     crédito suelto. Los pedazos de aplicar_credito_cliente e imputar_credito_a_pedido_impl copian el
--     usuario_id del crédito, así que absorber o imputar un crédito ya no lo cambia de rendición.
--     Decisión del dueño (06/11, tarjeta 15).
--
-- QUÉ NO CAMBIA
--   Las firmas, los EXECUTE, ni nada de lo que se cobra o se imputa. La foto de una rendición confirmada
--   (rendicion_pagos_confirmados) no se toca: lo ya rendido sigue saliendo de ella. Los pagos de antes de la
--   463c tienen de_saldo_a_favor en false y su dueño no cambia. El cobro FIFO y el de boleta nacen en la
--   boleta (de_saldo_a_favor false): siguen siendo del chofer de la boleta.
--
-- Ensayo: scripts/test-saldo-bajos-1492.sql (corre en prod sin dejar rastro).
-- Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos son los que se leyeron de prod (06/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
         '4b3269a9cb146415c16f70de01dbe23a'),
        ('public._rendicion_pagos(bigint,date,date,bigint)', 'ec296d5b2db880870ff7bca67f158d1a')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 473 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'pagos' AND column_name = 'de_saldo_a_favor') THEN
    RAISE EXCEPTION 'mig 473 · falta pagos.de_saldo_a_favor (mig 463c)';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla sobre el cuerpo vivo
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
-- crear_pedido_idempotente · el replay trae el saldo a favor absorbido.
('public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)', 1,
$a$        RETURN jsonb_build_object('success', true, 'pedido_id', v_existing, 'idempotente', true,
                                  'total', v_existing_total, 'cargo_envio', v_existing_cargo);
$a$,
$r$        -- #1492: el replay devuelve también lo que la boleta absorbió de saldo a favor (los
        -- pagos que le llegaron desde un crédito, de_saldo_a_favor). Sin eso el front cobraba
        -- el total entero y registrar_pagos_pedido lo rechazaba por pasarse de lo que falta.
        -- Lo que fue a boletas más viejas (saldo_a_favor_otras) no se guarda y no se repite.
        RETURN jsonb_build_object('success', true, 'pedido_id', v_existing, 'idempotente', true,
                                  'total', v_existing_total, 'cargo_envio', v_existing_cargo,
                                  'saldo_a_favor_aplicado',
                                  (SELECT round(COALESCE(sum(pg.monto), 0), 2)
                                     FROM pagos pg
                                    WHERE pg.pedido_id = v_existing
                                      AND pg.de_saldo_a_favor));
$r$),
-- _rendicion_pagos · el crédito absorbido sigue siendo de quien lo cobró.
('public._rendicion_pagos(bigint,date,date,bigint)', 1,
$a$   CROSS JOIN LATERAL (SELECT COALESCE(pd.transportista_id, pg.usuario_id) AS t) dueno
$a$,
$r$    -- #1492: un pago que llegó a la boleta desde un crédito (de_saldo_a_favor) sigue siendo
    -- de quien lo tenía como crédito suelto, el que lo cobró, y no del chofer de la boleta
    -- que lo absorbió: si no, el chofer quedaba debiendo plata que no cobró.
   CROSS JOIN LATERAL (SELECT CASE WHEN pg.de_saldo_a_favor THEN pg.usuario_id
                                   ELSE COALESCE(pd.transportista_id, pg.usuario_id) END AS t) dueno
$r$);

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
        RAISE EXCEPTION 'mig 473 · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, t.definer, md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def
      FROM (VALUES
        ('public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)',
         '63f0759223a668afdd04ce684aee18ef', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true),
        ('public._rendicion_pagos(bigint,date,date,bigint)',
         '8f3bf05f8fd2690373baeb4915f62a4c', '{postgres=X/postgres,service_role=X/postgres}', false)
      ) AS t(firma, hash, acl, definer)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl OR r.def <> r.definer THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %, definer %)', r.firma, r.h, r.a, r.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
