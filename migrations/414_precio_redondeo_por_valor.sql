-- =========================================================================
-- 414 · EL PRECIO SE REDONDEA POR SU VALOR, NO POR SU TEXTO (#1299)
--
-- Ensayo: scripts/test-precio-redondeo-1299.sql
--
-- _items_precio_redondeado (401, #1258) normaliza los items de venta antes de
-- que una RPC los inserte: precio_unitario es numeric(10,2), y con el precio
-- crudo el subtotal y el desglose no cierran contra el precio guardado (PRC-2).
-- Decidía mirando el texto con '^\s*-?[0-9]*\.[0-9]{3,}\s*$'. Pero las RPCs
-- convierten con (e->>'precio_unitario')::numeric, que acepta más formatos:
-- "1.0005e1", "+10.005", "1e-3", "10.00_5" (PG 16+). Mandado como texto, ese
-- precio se salteaba el redondeo: el cast daba 10,005, el control del total
-- pasaba, se guardaba 10,01 con subtotal 1.000,50 y el desglose daba 1.001,00.
--
-- Ahora decide por el VALOR, con el mismo cast que usan las RPCs: si el texto
-- es un numeric válido (pg_input_is_valid) y tiene más de 2 decimales
-- (scale > 2), va redondeado a 2. Así ve exactamente lo que van a ver ellas.
-- Lo que no es un numeric válido no se toca: la RPC falla en su propio cast,
-- como antes. NaN e Infinity tienen scale NULL y tampoco se tocan.
--
-- scale > 2 y no round(v, 2) <> v: es la misma regla que la regex ("3 o más
-- decimales"), así "10.000" sigue saliendo como 10.00 igual que hasta hoy.
--
-- STABLE y no IMMUTABLE: pg_input_is_valid es STABLE. Nadie la usa en un
-- índice ni en una columna generada; sólo la llaman los cuerpos de las RPCs.
--
-- Los llamadores no cambian (crear_pedido_completo, actualizar_pedido_items,
-- crear_pedido_completo_bot): el arreglo vive en el helper.
--
-- PERMISOS: como en la 401, helper de server (REVOKE PUBLIC, anon,
-- authenticated). CREATE OR REPLACE conserva el ACL; se revoca igual.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · El helper es el de hoy
-- -------------------------------------------------------------------------
-- md5(prosrc) de prod al escribir esto (2026-10-29), el cuerpo de la 401. Si
-- otra migración lo cambió en el medio, esta lo pisaría sin avisar: se aborta
-- y se rehace sobre la definición viva.
DO $vivas$
BEGIN
  IF to_regprocedure('public._items_precio_redondeado(jsonb)') IS NULL
     OR (SELECT md5(prosrc) FROM pg_proc
          WHERE oid = to_regprocedure('public._items_precio_redondeado(jsonb)'))
        <> '107f6c069cba89b32d810bc919d2961a' THEN
    RAISE EXCEPTION '_items_precio_redondeado no es la de prod del 2026-10-29: rehacer la migración sobre la definición viva';
  END IF;
END
$vivas$;

-- -------------------------------------------------------------------------
-- 1 · El helper
-- -------------------------------------------------------------------------
-- El CASE de adentro va anidado y no con AND: Postgres no garantiza el orden
-- de los operandos de un AND, y el cast tiene que correr sólo si el texto es
-- un numeric válido. El CASE sí evalúa en orden.
CREATE OR REPLACE FUNCTION public._items_precio_redondeado(p_items jsonb)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT CASE
    WHEN p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN p_items
    ELSE (
      SELECT COALESCE(jsonb_agg(
               CASE WHEN jsonb_typeof(x.e) = 'object'
                     AND jsonb_typeof(x.e->'precio_unitario') IN ('number', 'string')
                     AND pg_input_is_valid(x.e->>'precio_unitario', 'numeric')
                    THEN CASE WHEN scale((x.e->>'precio_unitario')::numeric) > 2
                              THEN jsonb_set(x.e, '{precio_unitario}',
                                             to_jsonb(round((x.e->>'precio_unitario')::numeric, 2)))
                              ELSE x.e END
                    ELSE x.e END
               ORDER BY x.o), '[]'::jsonb)
        FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, o))
  END
$fn$;

COMMENT ON FUNCTION public._items_precio_redondeado(jsonb) IS
  'Items de venta con precio_unitario a 2 decimales (lo que guarda pedido_items). '
  'Decide por el valor del cast a numeric que hacen las RPCs, no por el texto: '
  'un precio con 2 decimales o menos no se toca. #1258, #1299.';

REVOKE ALL ON FUNCTION public._items_precio_redondeado(jsonb) FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 2 · Verificación
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_fn regprocedure := 'public._items_precio_redondeado(jsonb)'::regprocedure;
BEGIN
  IF has_function_privilege('anon', v_fn, 'EXECUTE')
     OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                 WHERE p.oid = v_fn AND a.grantee = 0) THEN
    RAISE EXCEPTION '_items_precio_redondeado es alcanzable desde la API';
  END IF;

  -- Lo que ya hacía (los humos de la 401).
  IF public._items_precio_redondeado('[{"precio_unitario": 10.005, "cantidad": 100}]')->0->>'precio_unitario' <> '10.01'
     OR public._items_precio_redondeado('[{"precio_unitario": "10.004"}]')->0->>'precio_unitario' <> '10.00'
     OR public._items_precio_redondeado('[{"precio_unitario": 10}, {"precio_unitario": 7.5}]')
        IS DISTINCT FROM '[{"precio_unitario": 10}, {"precio_unitario": 7.5}]'::jsonb
     OR public._items_precio_redondeado(NULL) IS NOT NULL
     OR public._items_precio_redondeado('{}'::jsonb) IS DISTINCT FROM '{}'::jsonb THEN
    RAISE EXCEPTION '_items_precio_redondeado dejó de hacer lo de la 401';
  END IF;

  -- #1299: los textos que la regex dejaba pasar.
  IF public._items_precio_redondeado('[{"precio_unitario": "1.0005e1"}]')->0->>'precio_unitario' <> '10.01'
     OR public._items_precio_redondeado('[{"precio_unitario": "+10.005"}]')->0->>'precio_unitario' <> '10.01'
     OR public._items_precio_redondeado('[{"precio_unitario": " 10.005 "}]')->0->>'precio_unitario' <> '10.01'
     OR public._items_precio_redondeado('[{"precio_unitario": "1e-3"}]')->0->>'precio_unitario' <> '0.00' THEN
    RAISE EXCEPTION '_items_precio_redondeado sigue decidiendo por el texto (#1299)';
  END IF;

  -- Lo que no tiene que tocar: lo que no es un numeric válido (la RPC falla en
  -- su cast), NaN, y lo que ya tiene 2 decimales o menos aunque venga raro.
  IF public._items_precio_redondeado('[{"precio_unitario": "abc"}]')
       IS DISTINCT FROM '[{"precio_unitario": "abc"}]'::jsonb
     OR public._items_precio_redondeado('[{"precio_unitario": "NaN"}]')
       IS DISTINCT FROM '[{"precio_unitario": "NaN"}]'::jsonb
     OR public._items_precio_redondeado('[{"precio_unitario": "1.5e1"}]')
       IS DISTINCT FROM '[{"precio_unitario": "1.5e1"}]'::jsonb
     OR public._items_precio_redondeado('[{"cantidad": 3}, 7, {"precio_unitario": null}]')
       IS DISTINCT FROM '[{"cantidad": 3}, 7, {"precio_unitario": null}]'::jsonb THEN
    RAISE EXCEPTION '_items_precio_redondeado toca lo que no tiene que tocar';
  END IF;
END
$verif$;

-- ROLLBACK: volver a aplicar la definición de _items_precio_redondeado de
-- migrations/401_precio_e_iva_de_la_venta.sql (sección del helper, IMMUTABLE y
-- con la regex) y su REVOKE.
