-- 431d · Sustituir y dividir un regalo: la foto y el orden de locks (#1324, #1326,
-- #1375), y el guard (c) de dividir, que la conversión única deja sin caso (#1325).

BEGIN;

-- ---------------------------------------------------------------------------
-- Premisas: nada cambió en prod desde que se leyeron los cuerpos
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
         '0587288e9f16fb24f700580e9efd4117'),
        ('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)',
         '8d39ef579f1f45876992175aa7a3dd21')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 431d · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Parches por ancla
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _n_parche (firma text, orden int, ancla text, reemplazo text, veces int DEFAULT 1) ON COMMIT DROP;

INSERT INTO _n_parche (firma, orden, ancla, reemplazo) VALUES
('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 1,
$a$  v_regalo_mueve_stock := COALESCE(v_promo.regalo_mueve_stock, TRUE);
$a$,
$r$  -- #1324: el modo de la foto del pedido.
  v_regalo_mueve_stock := COALESCE(public._regalo_modo_del_pedido(v_item.pedido_id, v_item.promocion_id, v_sucursal), TRUE);
$r$),

('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 2,
$a$  IF v_regalo_mueve_stock THEN
    SELECT stock INTO v_stock_nuevo FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal FOR UPDATE;
$a$,
$r$  -- #1326 / #1375: los productos y los contenedores juntos y por id, antes de
  -- mover el primero: es el orden de la venta (#1255). Un original mayor que el
  -- sustituto se bloqueaba al reves, y contra una venta daba 40P01.
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT v_item.producto_id
                UNION SELECT p_producto_nuevo_id
                UNION SELECT v_ajuste_sustituto_efectivo
                UNION SELECT c FROM public._contenedores_de_promos(ARRAY[v_item.promocion_id], v_sucursal) c)
   ORDER BY id
     FOR UPDATE;

  IF v_regalo_mueve_stock THEN
    SELECT stock INTO v_stock_nuevo FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal FOR UPDATE;
$r$),

('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 3,
$a$  ELSE
    -- La barra default vive en promociones.usos_pendientes y el helper opera
$a$,
$r$  ELSIF public._regalo_barra_vale(v_item.pedido_id, v_item.promocion_id, v_sucursal) THEN
    -- La barra default vive en promociones.usos_pendientes y el helper opera
$r$),

('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 4,
$a$         unidades_por_bloque_al_crear = CASE WHEN v_regalo_mueve_stock THEN unidades_por_bloque_al_crear
$a$,
$r$         -- #1324: con la promo de otro modo, el factor de la linea tambien es de su foto.
         unidades_por_bloque_al_crear = CASE WHEN v_regalo_mueve_stock
                                               OR NOT public._regalo_barra_vale(v_item.pedido_id, v_item.promocion_id, v_sucursal)
                                             THEN unidades_por_bloque_al_crear
$r$),

('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)', 5,
$a$         origen_unidades_por_bloque = CASE WHEN v_regalo_mueve_stock THEN origen_unidades_por_bloque
$a$,
$r$         origen_unidades_por_bloque = CASE WHEN v_regalo_mueve_stock
                                             OR NOT public._regalo_barra_vale(v_item.pedido_id, v_item.promocion_id, v_sucursal)
                                           THEN origen_unidades_por_bloque
$r$),

('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 1,
$a$  -- (c) Una linea suelta a la que se le cambio la cantidad a mano (A4 -> B6 en
  --     la misma categoria): ni (a) la ve -- en la misma categoria el
  --     recorrido deja la cantidad como esta -- ni (b), que mira solo partes.
  --     Repartirla dejaria cortes que suman 6 contra una promo de 4 y el
  --     reparto se disolveria en el primer guardado. Se la reconoce porque su
  --     cantidad es la de recorrer la cadena desde su corte (el 4 vuelve 6).
  --     Si en cambio la promo paso despues de 4 a 5 (A4 -> B4 y la edicion la
  --     deja en B5), el corte sigue en 4 pero recorrerlo da B4 y no B5: la
  --     linea esta en la unidad de la promo y pasa. Rechazo de mas solo si la
  --     promo cambio justo a la cantidad tipeada a mano.
  IF v_item.regalo_cadena_id IS NOT NULL
     AND public.regalo_cantidad_base(public.regalo_eslabones(v_item.pedido_id, v_item.promocion_id, v_sucursal),
                                     v_item.regalo_cadena_id, v_item.cantidad) <> v_item.cantidad
     AND (SELECT r.cantidad
            FROM public.regalo_sustitucion_resuelta(
                   v_item.pedido_id, v_item.promocion_id,
                   COALESCE(public.regalo_raiz_cadena(v_item.pedido_id, v_item.promocion_id, v_item.producto_id,
                                                      v_sucursal, v_item.regalo_cadena_id),
                            v_item.producto_id),
                   v_sucursal,
                   public.regalo_cantidad_base(public.regalo_eslabones(v_item.pedido_id, v_item.promocion_id, v_sucursal),
                                               v_item.regalo_cadena_id, v_item.cantidad),
                   v_item.regalo_cadena_id) r) = v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error',
      'A este regalo ya se le cambió la cantidad (la promo daba ' ||
      public.regalo_cantidad_base(public.regalo_eslabones(v_item.pedido_id, v_item.promocion_id, v_sucursal),
                                  v_item.regalo_cadena_id, v_item.cantidad) ||
      '): para repartirlo, primero volvelo a esa cantidad. Si querés repartir y cambiar la cantidad, repartí primero.');
  END IF;
$a$,
''),

('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 2,
$a$  v_regalo_mueve_stock := COALESCE(v_promo.regalo_mueve_stock, TRUE);
$a$,
$r$  -- #1324: el modo de la foto del pedido.
  v_regalo_mueve_stock := COALESCE(public._regalo_modo_del_pedido(v_item.pedido_id, v_item.promocion_id, v_sucursal), TRUE);
$r$),

('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 3,
$a$  -- Stock ANTES de mover nada: las validaciones devuelven {success:false} sin
$a$,
$r$  -- #1326 / #1375: todos los productos y contenedores juntos y por id, antes de
  -- mover el primero: el original tambien, que abajo devuelve lo que sobra despues
  -- de que el chequeo bloqueo las partes. Es el orden de la venta (#1255).
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT v_item.producto_id
                UNION SELECT x FROM unnest(v_prod) x
                UNION SELECT c FROM public._contenedores_de_promos(ARRAY[v_item.promocion_id], v_sucursal) c)
   ORDER BY id
     FOR UPDATE;

  -- Stock ANTES de mover nada: las validaciones devuelven {success:false} sin
$r$),

('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)', 4,
$a$  ELSE
    -- Mismo motor que sustituir_regalo_pedido y que el alta: cada producto
$a$,
$r$  ELSIF public._regalo_barra_vale(v_item.pedido_id, v_item.promocion_id, v_sucursal) THEN
    -- Mismo motor que sustituir_regalo_pedido y que el alta: cada producto
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
        RAISE EXCEPTION 'mig 431d · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

COMMIT;
