-- Fixtures de scripts/concurrencia/b16-nota-y-liquidacion.sh (tarjeta B16 de #1603, H1 de la revisión
-- de la v3): una nota de crédito de venta creada o anulada MIENTRAS se liquida al vendedor.
--
-- Se carga y se CONFIRMA en una base descartable (`docker run … conc-base:<n>` con la migración de B16
-- aplicada), en el esquema b16c. NUNCA contra prod. Cada escenario arma su vendedor, su empleado y sus
-- boletas del mes pasado (b16c.escenario), y b16c.veredicto dice cómo quedó.
\set ON_ERROR_STOP 1
\set QUIET on
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS b16c CASCADE;
CREATE SCHEMA b16c;

CREATE TABLE b16c.fx (k text PRIMARY KEY, v text);
CREATE FUNCTION b16c.fx(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM b16c.fx WHERE k = p_k $f$;
CREATE FUNCTION b16c.adm() RETURNS uuid LANGUAGE sql AS $f$ SELECT '00000000-0000-0000-0000-0000000004e7'::uuid $f$;
CREATE FUNCTION b16c.mes() RETURNS date LANGUAGE sql AS $f$
  SELECT (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date
$f$;

-- Corre p_sql como p_uid (authenticated, parado en p_suc).
CREATE FUNCTION b16c.como(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE x text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO x;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE;
  END;
  EXECUTE 'RESET ROLE';
  RETURN x;
END $f$;

-- Un escenario nuevo: sucursal, admin asignado, vendedor que comisiona desde el mes pasado, tres
-- boletas del día 10 de ese mes (A×10 a 100) y, si p_con_nota, una nota de rechazo de 2 sobre la primera.
CREATE FUNCTION b16c.escenario(p_con_nota boolean) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_s bigint; v_c bigint; v_a bigint; v_v uuid := gen_random_uuid(); v_e bigint; v_p bigint; k int; v_r jsonb;
BEGIN
  DELETE FROM b16c.fx;
  INSERT INTO sucursales (nombre) VALUES ('B16 conc ' || left(gen_random_uuid()::text, 8)) RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (b16c.adm(), v_s) ON CONFLICT DO NOTHING;
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v_v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b16c-' || v_v || '@ensayo.invalid',
            jsonb_build_object('rol', 'preventista', 'sucursal_id', v_s), '{"nombre":"B16 conc"}', now(), now());
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B16 conc', 'B16 conc', 'x', v_s) RETURNING id INTO v_c;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('B16 conc A', 100, 100000, 60, v_s) RETURNING id INTO v_a;
  INSERT INTO empleados (nombre, puesto, sucursal_id, usuario_id, creado_por)
    VALUES ('B16 conc', 'preventista', v_s, v_v, b16c.adm()) RETURNING id INTO v_e;
  INSERT INTO empleado_arreglos (empleado_id, vigente_desde, sueldo, frecuencia, comisiona, creado_por)
    VALUES (v_e, b16c.mes(), 0, 'mensual', true, b16c.adm());
  INSERT INTO b16c.fx VALUES ('s', v_s), ('v', v_v), ('e', v_e);
  FOR k IN 1..3 LOOP
    -- creado_por: lo pide el centinela de atribución de auditoria_integridad (COMIS-05).
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, total, estado, fecha, fecha_entrega, canal, retiro_deposito, tipo_factura)
      VALUES (v_c, v_s, v_v, v_v, 1000, 'entregado', b16c.mes() + 9,
              (b16c.mes() + 9 + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'app', true, 'ZZ')
      RETURNING id INTO v_p;
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
      VALUES (v_p, v_a, 10, 100, 1000, v_s, 60);
    INSERT INTO b16c.fx VALUES ('p' || k, v_p);
  END LOOP;
  IF p_con_nota THEN
    v_r := b16c.nc();
    INSERT INTO b16c.fx VALUES ('n', v_r->>'nota_credito_id');
  END IF;
END $f$;

-- La nota de rechazo (2 u., 200) sobre la primera boleta, por la RPC.
CREATE FUNCTION b16c.nc() RETURNS jsonb LANGUAGE sql AS $f$
  SELECT b16c.como(b16c.adm(), b16c.fx('s')::bigint, format(
    'SELECT public.crear_nota_credito_venta(%s, %s, %L::jsonb, %L, %L, %L::uuid)::text',
    b16c.fx('p1'), (SELECT cliente_id FROM pedidos WHERE id = b16c.fx('p1')::bigint),
    jsonb_build_array(jsonb_build_object('pedido_item_id', (SELECT min(id) FROM pedido_items WHERE pedido_id = b16c.fx('p1')::bigint),
                                         'cantidad', 2)),
    'cliente_rechaza', 'conc B16', gen_random_uuid()))::jsonb;
$f$;

CREATE FUNCTION b16c.anular() RETURNS jsonb LANGUAGE sql AS $f$
  SELECT b16c.como(b16c.adm(), b16c.fx('s')::bigint, format(
    'SELECT public.anular_nota_credito_venta(%s, %L)::text', b16c.fx('n'), 'conc B16'))::jsonb;
$f$;

-- liquidar_empleado de verdad, con lo que muestra la vista previa (como el modal). Si contesta «Algo
-- cambió desde que abriste la liquidación» (la nota entró mientras esperaba), vuelve a abrir la vista
-- previa y confirma otra vez, como haría el admin; lo dice en la respuesta.
CREATE FUNCTION b16c.liquidar() RETURNS text LANGUAGE plpgsql AS $f$
DECLARE j jsonb; k int; v_aviso text := '';
BEGIN
  FOR k IN 1..2 LOOP
    j := b16c.como(b16c.adm(), b16c.fx('s')::bigint, format('SELECT public.previsualizar_liquidacion(%s)::text', b16c.fx('e')))::jsonb;
    BEGIN
      RETURN v_aviso || 'liquidación ' || b16c.como(b16c.adm(), b16c.fx('s')::bigint,
        format('SELECT public.liquidar_empleado(%s, %L::jsonb)::text', b16c.fx('e'),
          jsonb_build_object('desde', j#>>'{periodo,desde}', 'hasta', j#>>'{periodo,hasta}',
                             'sueldo', COALESCE(j#>>'{sueldo,propuesto}', '0'), 'pago', 0, 'fecha_pago', public._tablero_hoy(),
                             'a_pagar_esperado', j->>'a_pagar')));
    EXCEPTION WHEN OTHERS THEN
      IF k = 1 AND SQLERRM LIKE 'Algo cambió%' THEN
        v_aviso := '(la primera vez: «Algo cambió», se reabrió) ';
        CONTINUE;
      END IF;
      RETURN v_aviso || 'ERROR ' || SQLERRM;
    END;
  END LOOP;
  RETURN v_aviso;
END $f$;

-- Anula la última liquidación vigente del empleado del escenario (como el admin).
CREATE FUNCTION b16c.anular_liq() RETURNS text LANGUAGE sql AS $f$
  SELECT 'liquidación ' || l.id || ' anulada' || COALESCE(b16c.como(b16c.adm(), b16c.fx('s')::bigint,
           format('SELECT public.anular_liquidacion(%s, %L)::text', l.id, 'conc B16')), '')
    FROM empleado_liquidaciones l
   WHERE l.empleado_id = b16c.fx('e')::bigint AND l.anulada_at IS NULL
   ORDER BY l.id DESC LIMIT 1
$f$;

-- Cómo quedó tras anular la liquidación (E5 a E8): no queda nada liquidado de la boleta, y la nota está
-- como si se hubiera creado con la boleta sin liquidar (decisión del dueño del 18/11): anulada, no resta y
-- la próxima liquidación trae la boleta por 1.000; vigente, resta y la trae por 800.
CREATE FUNCTION b16c.veredicto_sin_liquidar() RETURNS text LANGUAGE sql AS $f$
  WITH n AS (SELECT * FROM notas_credito_venta WHERE pedido_id = b16c.fx('p1')::bigint),
  lib AS (SELECT count(*) AS k FROM empleado_liquidacion_lineas l WHERE l.pedido_id = b16c.fx('p1')::bigint AND l.vigente),
  prox AS (SELECT COALESCE(sum(l.base) FILTER (WHERE l.pedido_id = b16c.fx('p1')::bigint), 0) AS base,
                  string_agg(DISTINCT l.tipo, ',') AS tipos
             FROM public._liquidacion_lineas((SELECT e FROM empleados e WHERE e.id = b16c.fx('e')::bigint),
                                             (b16c.mes() + interval '2 month')::date) l)
  SELECT CASE WHEN (SELECT count(*) FROM n) = 1
               AND (SELECT n.resta_comision = NOT n.anulada FROM n)
               AND lib.k = 0
               AND round(prox.base, 2) = CASE WHEN (SELECT n.anulada FROM n) THEN 1000 ELSE 800 END
               AND prox.tipos = 'inicial'
              THEN 'OK' ELSE 'FALLA' END
         || format(' · nota anulada=%s resta_comision=%s · líneas vigentes de la boleta %s · la próxima liquidación la trae por %s (%s)',
                   (SELECT string_agg(n.anulada::text, ',') FROM n), (SELECT string_agg(n.resta_comision::text, ',') FROM n),
                   lib.k, round(prox.base, 2), prox.tipos)
    FROM lib, prox
$f$;

-- Cómo quedó: la nota, el libro, y lo que traería la próxima liquidación. «OK» si no queda ningún ajuste
-- pendiente y lo liquidado de la primera boleta es lo que la nota dice (800 si resta, 1.000 si no).
CREATE FUNCTION b16c.veredicto() RETURNS text LANGUAGE sql AS $f$
  WITH n AS (SELECT * FROM notas_credito_venta WHERE pedido_id = b16c.fx('p1')::bigint),
  lib AS (SELECT COALESCE(sum(l.base), 0) AS base FROM empleado_liquidacion_lineas l
           WHERE l.pedido_id = b16c.fx('p1')::bigint AND l.vigente),
  pend AS (SELECT string_agg(format('%s:%s', l.tipo, round(l.base, 2)), ' | ') AS t
             FROM public._liquidacion_lineas((SELECT e FROM empleados e WHERE e.id = b16c.fx('e')::bigint),
                                             (b16c.mes() + interval '2 month')::date) l)
  SELECT CASE WHEN pend.t IS NULL
               AND round(lib.base, 2) = CASE WHEN (SELECT bool_or(n.resta_comision) FROM n) THEN 800 ELSE 1000 END
              THEN 'OK' ELSE 'FALLA' END
         || format(' · nota resta_comision=%s anulada=%s · liquidado de la boleta %s · pendiente %s',
                   (SELECT string_agg(n.resta_comision::text, ',') FROM n), (SELECT string_agg(n.anulada::text, ',') FROM n),
                   round(lib.base, 2), COALESCE(pend.t, '(nada)'))
    FROM lib, pend
$f$;

\set QUIET off
SELECT 'fixtures b16c listas';
