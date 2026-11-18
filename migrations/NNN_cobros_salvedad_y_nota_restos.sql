-- =========================================================================
-- NNN · COBROS, SALVEDAD Y NOTA DE CRÉDITO DE VENTA: LOS RESTOS DE LA OLA 2
--       (plan #1603, ola 2, tanda 5, tarjeta C1)
--
-- Ensayo: scripts/test-cobros-salvedad-nota-ola2-1603.sql (falla sin esta
-- migración, ENSAYO OK con ella). Se aplica en LF. Sólo funciones: ningún DDL
-- de tabla, así que no toma locks de tabla.
--
-- =========================================================================
-- 1 · 1595-b2 (#1595): EL COBRO REPUESTO CONSERVA SUS MARCAS
-- =========================================================================
-- Un adelanto de sueldo entra a la boleta por el FIFO de la ficha del empleado,
-- marcado a_cuenta (o como pedazo, con pago_origen_id/pago_padre_id). Una
-- salvedad lo recorta (no es plata que entró: desafectar_sobrepago_pedido lo
-- trata como un cobro de boleta) y, si lo borra entero, anular la salvedad lo
-- repone como un cobro NUEVO. Ese cobro nacía sin a_cuenta ni pago_origen_id:
-- después desimputar_pago no lo aceptaba («no figura como saldo a favor
-- aplicado») y el DELETE REST sí lo dejaba borrar.
-- Ahora el cobro nuevo copia las marcas del que se recortó: a_cuenta,
-- pago_origen_id y pago_padre_id (de_saldo_a_favor la sigue poniendo el
-- trigger, por el padre). Las marcas salen del pago vivo (el que está en la
-- foto de una rendición cerrada o en un día con la caja cerrada) o, si el
-- recorte lo borró, de la fila de su DELETE en audit_logs (el mismo camino con
-- el que anular_salvedad ya lee la alícuota de una línea borrada, #1274).
-- Quedan anotadas en el recorte (cobro_recortado[].marcas). Sin ninguna de las
-- dos, el cobro nace sin marcas, como antes. anular_salvedad se parcha por
-- ancla con premisa de forma (otra tarjeta de la tanda puede tocarla).
--
-- =========================================================================
-- 2 · COB-b6 (#1545): AL REAPLICAR UN CRÉDITO SE LIMPIAN TODAS SUS NOTAS
-- =========================================================================
-- Un crédito suelto lleva en sus notas «[saldo a favor]», «[saldo a favor por
-- cancelacion]» o «[saldo a favor por cambio de cliente]». Al aplicarlo a una
-- boleta, el replace sólo sacaba la primera: el pago aplicado seguía diciendo
-- «saldo a favor por cancelacion». La limpieza es una sola,
-- _notas_sin_saldo_a_favor, en los seis lugares que la hacían:
-- _aplicar_credito_pagos, imputar_credito_a_pedido_impl y
-- crear_nota_credito_venta_impl (dos cada una: el crédito entero y el pedazo).
--
-- =========================================================================
-- 3 · 1598-b4 (#1598): LA MARCA «TIENE SALVEDAD VIGENTE» DE UN PEDIDO
-- =========================================================================
-- El filtro «Con salvedad / Sin salvedad» de Pedidos mandaba en la URL los ids
-- de todos los pedidos con salvedad; pasados 700 cortaba con un aviso. Ahora
-- filtra por la columna calculada tiene_salvedad_vigente(pedidos): PostgREST la
-- expone como una columna más de pedidos (?tiene_salvedad_vigente=eq.true), sin
-- ids en la URL. pedidos se lee por REST con SELECT de tabla entera (no columna
-- por columna), así que la columna calculada no rompe ninguna consulta (trampa
-- 4 de CLAUDE.md; mismo caso que deuda_previa_detalle(pedidos)). Es definer por
-- el tiempo (se llama una vez por pedido), y mira lo mismo que la RLS de
-- salvedades_items sólo cuando el pedido tiene una salvedad vigente: da lo mismo
-- que la lista de ids de antes. Vigente = estado_resolucion <> 'anulada', el
-- criterio de siempre (#1180).
--
-- =========================================================================
-- 4 · N2 y N7 de la revisión de B22: LA NOTA POR UNIDADES
-- =========================================================================
-- N2 (decisión de la coordinadora, coherente con H4): una línea a la que un
-- descuento le dejó centavos daba, por unidades, un renglón de $ 0: solo, el
-- error genérico «total mayor a 0»; junto a otro renglón, entraba a $ 0,00 (y
-- con la marca, la unidad volvía al stock). Ahora se rechaza siempre que la
-- parte de ese renglón dé $ 0, con qué hacer: anular primero el descuento.
-- N7: los mensajes de la rama por unidades (y los mismos de la rama por monto)
-- nombran el producto, no el id de la línea.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 530.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._aplicar_credito_pagos(bigint,bigint,bigint[])', '0c77f1627f4d35eb6e0f13b7363deb89'),
    ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', 'ae896fc8c353b95438941b1a4dd43d86'),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'ebd8013484fe63e1fc285dc067a2e618'),
    -- anular_salvedad va por ancla, sin md5 (C2 puede parcharla en la misma tanda).
    ('public.anular_salvedad(bigint,text)', NULL),
    ('public.desimputar_pago(bigint,bigint)', NULL),
    ('public.pagos_marcar_saldo_a_favor()', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    IF r.h IS NULL THEN CONTINUE; END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regproc('public._notas_sin_saldo_a_favor') IS NOT NULL
     OR to_regproc('public.tiene_salvedad_vigente') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · algo de esta migración ya existe: revisar a mano';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pedidos'::regclass
                AND attname = 'tiene_salvedad_vigente' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · pedidos ya tiene una columna tiene_salvedad_vigente: la calculada la taparía';
  END IF;
END
$premisas$;

-- Reemplaza un ancla que tiene que aparecer exactamente p_n veces.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_n int, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> p_n THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba %', p_que, v_n, p_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- B15 (mig 531): una SECURITY DEFINER lleva pg_temp al final de su search_path.
-- Si la 531 ya entró, la definición ya lo trae y no se toca.
CREATE FUNCTION pg_temp.con_pg_temp(p_def text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  IF position(E'\n SET search_path TO ''public'', ''pg_temp''\n' in p_def) > 0 THEN
    RETURN p_def;
  END IF;
  RETURN pg_temp.parche(p_def, E'\n SET search_path TO ''public''\n',
                        E'\n SET search_path TO ''public'', ''pg_temp''\n', 1, p_que || ' (search_path)');
END
$f$;

-- =========================================================================
-- 2 · COB-b6: la limpieza de las notas de un crédito que se aplica
-- =========================================================================
CREATE FUNCTION public._notas_sin_saldo_a_favor(p_notas text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $f$
  -- COB-b6 (#1545): las tres marcas con que nace un crédito suelto. Se usa como
  -- NULLIF(trim(_notas_sin_saldo_a_favor(notas)), '').
  SELECT regexp_replace(COALESCE(p_notas, ''),
                        '\[saldo a favor( por (cancelacion|cambio de cliente))?\]', '', 'g');
$f$;

REVOKE ALL ON FUNCTION public._notas_sin_saldo_a_favor(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._notas_sin_saldo_a_favor(text) TO service_role;

DO $cobb6$
DECLARE
  r record;
  v_def text;
BEGIN
  -- crear_nota_credito_venta_impl lleva el mismo parche más abajo, con N2 y N7.
  FOR r IN SELECT * FROM (VALUES
    ('public._aplicar_credito_pagos(bigint,bigint,bigint[])', false),
    ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', true)
  ) AS t(f, definer) LOOP
    v_def := pg_get_functiondef(r.f::regprocedure);
    v_def := pg_temp.parche(v_def,
      $a$replace(COALESCE(notas, ''), '[saldo a favor]', '')$a$,
      $a$public._notas_sin_saldo_a_favor(notas)$a$,
      2, r.f);
    IF r.definer THEN
      v_def := pg_temp.con_pg_temp(v_def, r.f);
    END IF;
    EXECUTE v_def;
  END LOOP;
END
$cobb6$;

-- =========================================================================
-- 2 y 4 · COB-b6, N2 y N7: crear_nota_credito_venta_impl
-- =========================================================================
DO $nc$
DECLARE
  v_def text := pg_get_functiondef('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)'::regprocedure);
  v_que text := 'crear_nota_credito_venta_impl';
BEGIN
  -- COB-b6: la limpieza de las notas (el crédito entero y el pedazo).
  v_def := pg_temp.parche(v_def,
    $a$replace(COALESCE(notas, ''), '[saldo a favor]', '')$a$,
    $a$public._notas_sin_saldo_a_favor(notas)$a$,
    2, v_que || ' (notas)');
  -- N7: un renglón que no es de la boleta (las dos ramas).
  v_def := pg_temp.parche(v_def,
    $a$RAISE EXCEPTION 'El item % no pertenece al pedido #%', v_it.pedido_item_id_txt, p_pedido_id$a$,
    $a$RAISE EXCEPTION 'Uno de los renglones de la nota no es de la boleta #%: volvé a abrirla y cargá la nota de nuevo', p_pedido_id$a$,
    2, v_que || ' (renglón ajeno)');
  -- N7: la cantidad.
  v_def := pg_temp.parche(v_def,
    $a$RAISE EXCEPTION 'Cantidad invalida para el item %: %', v_it.pi_id, COALESCE(v_it.cantidad_txt, 'vacia')$a$,
    $a$RAISE EXCEPTION 'La cantidad de «%» tiene que ser un número entero mayor a 0 (llegó %)', v_it.nombre, COALESCE(v_it.cantidad_txt, 'vacía')$a$,
    1, v_que || ' (cantidad)');
  -- N7: el regalo (las dos ramas: las dos tienen v_it.nombre).
  v_def := pg_temp.parche(v_def,
    $a$RAISE EXCEPTION 'El item % es un regalo de promocion: no se cobro, no se acredita', v_it.pi_id$a$,
    $a$RAISE EXCEPTION '«%» es un regalo de promoción: no se cobró, no se acredita', v_it.nombre$a$,
    2, v_que || ' (regalo)');
  -- N7: la línea sin producto (no hay nombre que decir).
  v_def := pg_temp.parche(v_def,
    $a$RAISE EXCEPTION 'El item % es de un producto que ya no existe: no se puede acreditar por unidades', v_it.pi_id$a$,
    $a$RAISE EXCEPTION 'Una de las líneas es de un producto que ya no existe: no se puede acreditar por unidades'$a$,
    1, v_que || ' (sin producto)');
  -- N7: más de lo que queda.
  v_def := pg_temp.parche(v_def,
    $a$RAISE EXCEPTION 'Item %: se entregaron % y ya se acreditaron %; no se pueden acreditar %',
          v_it.pi_id, v_it.entregada,$a$,
    $a$RAISE EXCEPTION '«%»: se entregaron % y ya se acreditaron %; no se pueden acreditar %',
          v_it.nombre, v_it.entregada,$a$,
    1, v_que || ' (más de lo que queda)');
  -- N2: la parte de un renglón por unidades que da $ 0.
  v_def := pg_temp.parche(v_def,
    $a$                            ELSE GREATEST(round(v_cant * v_resto_m / v_resto_u, 2), 0) END);
$a$,
    $a$                            ELSE GREATEST(round(v_cant * v_resto_m / v_resto_u, 2), 0) END);
        -- N2 de la revisión de B22: con centavos en la línea, la parte de estas
        -- unidades puede redondear a $ 0. No hay renglón de $ 0 (como H4): se
        -- rechaza siempre, vaya solo o con otros renglones.
        IF v_sub <= 0 THEN
          RAISE EXCEPTION 'A «%» ya se le acreditó casi toda su plata con un descuento. Para devolver la mercadería, anulá primero ese descuento.',
            v_it.nombre USING ERRCODE = '22023';
        END IF;
$a$,
    1, v_que || ' (N2)');
  v_def := pg_temp.con_pg_temp(v_def, v_que);
  EXECUTE v_def;
END
$nc$;

-- =========================================================================
-- 1 · 1595-b2: anular_salvedad repone el cobro con sus marcas
-- =========================================================================
DO $salv$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_que text := 'anular_salvedad';
BEGIN
  v_def := pg_temp.parche(v_def,
    $a$  v_resultado     JSONB := '[]'::jsonb;
$a$,
    $a$  v_resultado     JSONB := '[]'::jsonb;
  -- 1595-b2 (#1595): las marcas del cobro que se repone como nuevo.
  v_marcas        JSONB;
$a$,
    1, v_que || ' (declaración)');

  v_def := pg_temp.parche(v_def,
    $a$      v_plan := v_plan || jsonb_build_array(r_rec.e || jsonb_build_object('accion', v_accion,
                                                                          'fecha_reposicion', v_fecha_rec));
$a$,
    $a$      -- 1595-b2 (#1595): el cobro que vuelve como nuevo es el mismo que se recortó,
      -- con sus marcas (a_cuenta, pago_origen_id, pago_padre_id): un adelanto de
      -- sueldo del FIFO de la ficha sigue siendo un pago a cuenta, y desimputar_pago
      -- lo acepta. Del pago vivo (foto de una rendición cerrada o caja cerrada) o, si
      -- el recorte lo borró, de la fila de su DELETE en audit_logs.
      v_marcas := NULL;
      IF v_accion = 'nuevo' THEN
        SELECT jsonb_build_object('a_cuenta', pg.a_cuenta, 'pago_origen_id', pg.pago_origen_id,
                                  'pago_padre_id', pg.pago_padre_id)
          INTO v_marcas
          FROM pagos pg
         WHERE pg.id = r_rec.pago_id AND pg.sucursal_id = v_sucursal;
        IF v_marcas IS NULL THEN
          SELECT jsonb_build_object('a_cuenta', a.old_data->'a_cuenta',
                                    'pago_origen_id', a.old_data->'pago_origen_id',
                                    'pago_padre_id', a.old_data->'pago_padre_id')
            INTO v_marcas
            FROM audit_logs a
           WHERE a.tabla = 'pagos' AND a.accion = 'DELETE'
             AND a.registro_id = r_rec.pago_id::text
             AND a.sucursal_id = v_sucursal
           ORDER BY a.created_at DESC
           LIMIT 1;
        END IF;
      END IF;

      v_plan := v_plan || jsonb_build_array(r_rec.e || jsonb_build_object('accion', v_accion,
                                                                          'fecha_reposicion', v_fecha_rec)
                                                    || CASE WHEN v_marcas IS NULL THEN '{}'::jsonb
                                                            ELSE jsonb_build_object('marcas', v_marcas) END);
$a$,
    1, v_que || ' (plan)');

  v_def := pg_temp.parche(v_def,
    $a$      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, referencia,
                         notas, usuario_id, sucursal_id)
      SELECT p.cliente_id, p.id, v_rep, r_rec.e->>'forma_pago', (r_rec.e->>'fecha_reposicion')::date,
             r_rec.e->>'referencia',
             'Cobro repuesto por anulacion de la salvedad #' || p_salvedad_id
               || ' (lo habia recortado del pago #' || (r_rec.e->>'pago_id') || ')',
             (r_rec.e->>'usuario_id')::uuid, v_sucursal
$a$,
    $a$      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, referencia,
                         notas, usuario_id, sucursal_id,
                         a_cuenta, pago_origen_id, pago_padre_id)
      SELECT p.cliente_id, p.id, v_rep, r_rec.e->>'forma_pago', (r_rec.e->>'fecha_reposicion')::date,
             r_rec.e->>'referencia',
             'Cobro repuesto por anulacion de la salvedad #' || p_salvedad_id
               || ' (lo habia recortado del pago #' || (r_rec.e->>'pago_id') || ')',
             (r_rec.e->>'usuario_id')::uuid, v_sucursal,
             -- 1595-b2: las marcas del recortado (CHECK pagos_pedazo_con_padre: las
             -- dos o ninguna).
             COALESCE((r_rec.e->'marcas'->>'a_cuenta')::boolean, false),
             COALESCE((r_rec.e->'marcas'->>'pago_origen_id')::bigint, (r_rec.e->'marcas'->>'pago_padre_id')::bigint),
             COALESCE((r_rec.e->'marcas'->>'pago_padre_id')::bigint, (r_rec.e->'marcas'->>'pago_origen_id')::bigint)
$a$,
    1, v_que || ' (cobro nuevo)');

  v_def := pg_temp.con_pg_temp(v_def, v_que);
  EXECUTE v_def;
END
$salv$;

-- =========================================================================
-- 3 · 1598-b4: la marca «tiene salvedad vigente» de un pedido
-- =========================================================================
CREATE FUNCTION public.tiene_salvedad_vigente(p public.pedidos)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $f$
  -- 1598-b4 (#1598): la columna calculada del filtro «Con salvedad / Sin
  -- salvedad» de Pedidos (?tiene_salvedad_vigente=eq.true). Vigente = no anulada
  -- (#1180). PostgREST la llama una vez por pedido: invoker, la RLS de
  -- salvedades_items (current_sucursal_id() y el rol) se evaluaba en cada llamada
  -- y con 20.000 pedidos tardaba 3 a 4 veces más. Definer: primero el índice
  -- por pedido_id, y sólo si hay una salvedad vigente, lo mismo que pide
  -- mt_salvedades_items_select (la sucursal activa, y admin o encargado, o el
  -- pedido es del que pregunta o lo reparte). Así una llamada directa a la RPC
  -- con una fila armada no dice nada que la RLS no deje ver.
  SELECT CASE
           WHEN EXISTS (SELECT 1
                          FROM salvedades_items s
                         WHERE s.pedido_id = p.id
                           AND s.sucursal_id = p.sucursal_id
                           AND s.estado_resolucion <> 'anulada')
           THEN COALESCE(p.sucursal_id = current_sucursal_id()
                         AND (es_encargado_o_admin()
                              OR EXISTS (SELECT 1
                                           FROM pedidos pe
                                          WHERE pe.id = p.id
                                            AND pe.sucursal_id = p.sucursal_id
                                            AND (pe.usuario_id = auth.uid() OR pe.transportista_id = auth.uid()))),
                         false)
           ELSE false
         END;
$f$;

REVOKE ALL ON FUNCTION public.tiene_salvedad_vigente(public.pedidos) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tiene_salvedad_vigente(public.pedidos) TO authenticated, service_role;

-- =========================================================================
-- Poscondiciones
-- =========================================================================
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._aplicar_credito_pagos(bigint,bigint,bigint[])', 'public._notas_sin_saldo_a_favor(notas)', 2, false),
    ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', 'public._notas_sin_saldo_a_favor(notas)', 2, true),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'public._notas_sin_saldo_a_favor(notas)', 2, true),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'ya se le acreditó casi toda su plata', 1, true),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'es un regalo de promoción: no se cobró', 2, true),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'El item %', 0, true),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', '''Item %:', 0, true),
    ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)', 'Cantidad invalida para el item', 0, true),
    ('public.anular_salvedad(bigint,text)', 'COALESCE((r_rec.e->''marcas''->>''a_cuenta'')::boolean, false)', 1, true),
    ('public.anular_salvedad(bigint,text)', '''pagos'' AND a.accion = ''DELETE''', 1, true)
  ) AS t(f, marca, n, definer) LOOP
    IF (SELECT (length(prosrc) - length(replace(prosrc, r.marca, ''))) / length(r.marca)
          FROM pg_proc WHERE oid = r.f::regprocedure) <> r.n
       OR (SELECT prosecdef FROM pg_proc WHERE oid = r.f::regprocedure) <> r.definer THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró (% debía aparecer % veces)', r.f, r.marca, r.n;
    END IF;
  END LOOP;
  -- Ningún replace del «[saldo a favor]» pelado quedó en los tres.
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('_aplicar_credito_pagos', 'imputar_credito_a_pedido_impl', 'crear_nota_credito_venta_impl')
                AND position($a$'[saldo a favor]', '')$a$ in prosrc) > 0) THEN
    RAISE EXCEPTION 'mig NNN · quedó un replace de «[saldo a favor]» sin la limpieza nueva';
  END IF;
  -- Las definer que se recrearon llevan pg_temp (B15).
  FOR r IN SELECT unnest(ARRAY['public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',
                               'public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)',
                               'public.anular_salvedad(bigint,text)']) AS f LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
      RAISE EXCEPTION 'mig NNN · % quedó sin pg_temp en su search_path', r.f;
    END IF;
  END LOOP;
  -- Los permisos: los de server sin la API; anular_salvedad y la columna calculada, para authenticated.
  FOR r IN SELECT unnest(ARRAY['public._aplicar_credito_pagos(bigint,bigint,bigint[])',
                               'public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',
                               'public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)',
                               'public._notas_sin_saldo_a_favor(text)']) AS f LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE') OR has_function_privilege('authenticated', r.f, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para la API', r.f;
    END IF;
  END LOOP;
  IF NOT has_function_privilege('authenticated', 'public.anular_salvedad(bigint,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.anular_salvedad(bigint,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.tiene_salvedad_vigente(public.pedidos)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.tiene_salvedad_vigente(public.pedidos)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig NNN · los permisos de anular_salvedad o de tiene_salvedad_vigente no son los esperados';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.tiene_salvedad_vigente(public.pedidos)'::regprocedure
                    AND prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
    RAISE EXCEPTION 'mig NNN · tiene_salvedad_vigente tiene que ser definer con pg_temp';
  END IF;
END
$post$;

COMMIT;
