-- NNN · anular_salvedad: de dónde sale la alícuota de la línea que recrea (#1274).
--
-- Cuando la salvedad se llevó la línea entera, anular la vuelve a insertar. La
-- alícuota salía de `COALESCE(productos.porcentaje_iva, 21)`: el IVA de hoy del
-- producto, y un exento sin porcentaje volvía al 21%. Hoy no muerde porque los
-- 355 productos son gravados al 21, pero un súper tiene exentos y 10,5.
--
-- La regla es la de #1258: la foto de la línea, y si no la hay,
-- `_alicuota_iva_venta`. La foto de una línea borrada no está en `pedido_items`
-- ni en `salvedades_items`, que no guarda la alícuota. Está en la fila que dejó su
-- DELETE en `audit_logs` (`audit_pedido_items` guarda la fila entera, y es el
-- camino que ya usa `precio_fuera_de_politica` para el precio anterior). Con eso
-- alcanza sin tocar `registrar_salvedad` ni el esquema, y vale también para las
-- 303 salvedades vivas sin línea: todas tienen su fila, 275 con foto y 28 con la
-- foto 0 de legado. La lectura tarda unos 9 ms, y anular es de un admin.
--
-- Una foto 0 es ambigua, como en `cambiar_tipo_factura_pedido`: miles de líneas
-- viejas la tienen por el default de la columna. Esa, y la línea sin fila en el
-- log, caen a la regla sobre el producto. Se mira la última fila de esa misma
-- clase de línea: el regalo del mismo producto tiene foto 0, y si la salvedad se
-- lo llevó en la misma transacción empata en `created_at`.
--
-- El parche toca sólo el SELECT de la alícuota: el impuesto interno y los costos
-- siguen saliendo del producto.

BEGIN;

DO $premisa$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(prosrc) INTO v_md5
    FROM pg_proc
   WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '8fc04077a039451525301545e971e1b0' THEN
    RAISE EXCEPTION 'mig NNN · anular_salvedad cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', v_md5;
  END IF;
END
$premisa$;

DO $parche$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_ancla text := $a$    SELECT COALESCE(porcentaje_iva, 21), COALESCE(impuestos_internos, 0), costo_promedio, costo_real, costo_sin_iva
      INTO v_pct_iva, v_pct_ii, v_costo_prom, v_costo_real, v_costo_sin
$a$;
  v_nuevo text := $r$    -- #1274: la alicuota de la venta, no la de hoy. La linea ya no existe y
    -- la salvedad no la guarda: la foto es la fila que dejo su DELETE en
    -- audit_logs. Una foto 0 es ambigua (#1258) y cae, como la falta de fila, a
    -- la regla sobre el producto.
    SELECT COALESCE(
             (SELECT NULLIF((a.old_data->>'porcentaje_iva')::numeric, 0)
                FROM audit_logs a
               WHERE a.tabla = 'pedido_items' AND a.accion = 'DELETE'
                 AND a.sucursal_id = v_sucursal
                 AND a.old_data->>'pedido_id' = v_salvedad.pedido_id::text
                 AND a.old_data->>'producto_id' = v_salvedad.producto_id::text
                 AND COALESCE((a.old_data->>'es_bonificacion')::boolean, FALSE) = COALESCE(v_salvedad.es_bonificacion, FALSE)
               ORDER BY a.created_at DESC
               LIMIT 1),
             public._alicuota_iva_venta(condicion_iva, porcentaje_iva)),
           COALESCE(impuestos_internos, 0), costo_promedio, costo_real, costo_sin_iva
      INTO v_pct_iva, v_pct_ii, v_costo_prom, v_costo_real, v_costo_sin
$r$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · el ancla de anular_salvedad aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_nuevo);
END
$parche$;

COMMIT;
