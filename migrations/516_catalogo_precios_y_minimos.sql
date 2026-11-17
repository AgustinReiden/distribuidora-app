-- =========================================================================
-- NNN · CATÁLOGO, PRECIOS Y MÍNIMOS
--       (tarjeta B6a de la ola 2 del plan #1603: los bajos 1561-b2, b7, b8, b9 y
--        c4 de #1561; CAT-13 y los bajos 1596-b2, b3, b6 y b7 de #1596; y la fecha
--        de `cambiar_alicuota_ii`, que anotó M4 en la ola 1)
--
-- Parcha por ancla, con premisa de md5 sobre el cuerpo vivo del 16/11 (ledger en
-- la 512) y poscondición de md5, definer y ACL: `actualizar_precios_masivo`,
-- `actualizar_politica_minimo_pedido`, `actualizar_monto_minimo_pedido`,
-- `pedido_incumple_minimo`, `actualizar_minimo_venta_masivo`,
-- `sync_producto_categoria_id`, `verificar_duplicado_cliente`,
-- `productos_rechazar_borrado_con_historial`,
-- `bot_metricas_admin_dia` y `cambiar_alicuota_ii`. Crea dos funciones sólo de
-- server (`unidad_direccion_cliente`, `_otra_unidad_misma_puerta`). Suma un CHECK a
-- `politicas_comerciales` y cambia el índice único de `categorias`. No cambia
-- firmas ni grants, ni la forma del JSON de ninguna función.
-- Ensayo: scripts/test-catalogo-precios-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · 1596-b2 y 1561-c4 (#1596, #1561) · actualizar_precios_masivo
-- =========================================================================
-- · Un precio neto mayor que el final no entra: se compara lo que quedaría (lo
--   que manda el lote, o lo guardado si no lo manda). Igual sí (exento). El
--   producto se informa en `errores`, como cualquier otro que no se cambió.
-- · Un producto que viene más de una vez en el lote no se cambia (¿cuál de los
--   dos precios valía?), con un solo aviso. El resto del lote sigue.
-- · La escala de una condición se cambia sólo si alguno de sus productos cambió
--   en esta llamada. Una condición sin productos pasaba la guarda «todos sus
--   productos cambiaron» sin que cambiara ninguno.
--
-- =========================================================================
-- 2 · 1561-b9, 1596-b3 y 1561-b8 (#1561, #1596) · los mínimos
-- =========================================================================
-- Decisiones del dueño (15/11): D35, la compra mínima del pedido la cambia sólo
-- el admin, como la ventana de precio anterior; D36, la compra mínima y el mínimo
-- de venta tienen un techo de $ 99.999.999 contra un error de tipeo.
-- · actualizar_politica_minimo_pedido y actualizar_monto_minimo_pedido (la vieja):
--   sólo admin (es_admin(), que además mira `activo`: salen de
--   scripts/rol-sin-activo-permitidas.json), y el mínimo hasta 99.999.999 con un
--   22023 y su motivo (un NaN también se rechaza ahí). La política entera (modo,
--   envío gratis, cargo) es la de la compra mínima: va toda con el admin.
-- · La vieja, en una sucursal en modo escalas, rechaza con su motivo un mínimo que
--   no queda por debajo del envío gratis (antes, el 23514 crudo del CHECK).
-- · CHECK politicas_monto_minimo_pedido_techo: el techo en la columna.
-- · pedido_incumple_minimo: la máscara de los montos llega a 12 cifras; con un
--   total de mil millones o más el mensaje mostraba «###».
-- · actualizar_minimo_venta_masivo: el mínimo de venta hasta 99.999.999 u. (D36,
--   confirmado por el dueño el 16/11), con su motivo. Es el mismo techo del CHECK
--   productos_cantidad_minima_venta_check que pone la tarjeta B7 (1596-b1), así que
--   nadie ve el 23514 crudo de ese CHECK.
--
-- =========================================================================
-- 3 · 1596-b6 y 1561-b7 (#1596, #1561) · rubros
-- =========================================================================
-- · El índice único de categorias pasa de `nombre` a `upper(btrim(nombre))`, por
--   sucursal y por rubro padre: «Bebidas» y « BEBIDAS » ya no conviven (las RPC
--   comparan con upper(btrim()), y un rubro duplicado así partía sus productos).
--   Premisa: aborta con el listado si hoy hay duplicados.
-- · sync_producto_categoria_id busca el rubro con la misma comparación (usa el
--   índice) y con ORDER BY: con el índice hay a lo sumo uno, y si no, el más viejo.
-- · 1596-b9 (tiempo de renombrar y eliminar un rubro) no se arregla acá: más de la
--   mitad del tiempo es el trigger de auditoría de productos (audit_log_changes), que
--   es de otra tarjeta. Ver el PR.
--
-- =========================================================================
-- 4 · 1596-b7 (#1596) · el duplicado de cliente y la coma
-- =========================================================================
-- La clave de dirección (clave_direccion_cliente, la del índice
-- idx_clientes_clave_direccion) es lo anterior a la primera coma: «Mitre 450, Local
-- 1» y «Mitre 450, Local 2» chocaban por dirección y, con las coordenadas de Google
-- (las dos en el mismo punto), también por punto. Regla de la coordinadora, dentro
-- de la intención del hallazgo: dos direcciones con la misma calle y altura CHOCAN,
-- salvo que LAS DOS tengan unidad y sean distintas. Entonces no chocan por dirección
-- y tampoco bloquean por punto (menos de 1 m): pasa a ser el aviso. Todo lo demás
-- sigue igual, también el bloqueo por punto contra cualquier otro.
-- · La clave no cambia (ni el índice). La unidad sale aparte, de
--   unidad_direccion_cliente: los segmentos después de la primera coma, con los
--   sinónimos al mismo token (loc = local; dpto/depto/dto/departamento; of/oficina;
--   pb = planta baja; uf = unidad funcional…), y una palabra de unidad cuenta sólo
--   con un identificador detrás (un número o una letra suelta) o si es PB: «Puesto
--   Viejo», «Planta Urbana» o «Unidad Turística» son localidades. «N°», «Nº», «Nro.»,
--   «No.» y «#» se descartan, y la letra suelta que sigue al número se le pega («3 B»
--   es «3b»). El orden no importa; las unidades salen separadas por coma.
-- · _otra_unidad_misma_puerta(a, b) es la regla: la usa verificar_duplicado_cliente
--   en el bloqueo por dirección y en el de punto. La misma unidad con más detalle
--   («Local 1» y «Local 1, PB») es la misma puerta: son otra unidad sólo si ninguna
--   lista de unidades contiene a la otra.
-- · Espejo: claveDireccionConAltura, unidadDireccion y otraUnidadMismaPuerta
--   (src/utils/duplicadoCliente.ts), con el fixture src/utils/direccionCliente.espejo.json.
--
-- =========================================================================
-- 5 · 1561-b2 (#1561) · borrar un producto
-- =========================================================================
-- Decisión del dueño (15/11, D32): un producto con stock o con lotes no se puede
-- borrar; se desactiva. Sin historial se borraba y se llevaba por CASCADE el stock,
-- los lotes (aun los agotados) y su stock_historico. Además, el regalo (o el
-- producto de ajuste) de una promoción no se borra: la FK lo ponía en NULL y la
-- promo quedaba activa sin regalo. Lo frena el trigger que ya frena el borrado con
-- historial, con su motivo (23503). Sin stock, sin lotes y sin promo se sigue
-- borrando, y su stock_historico se va con él. Las FK no cambian.
--
-- =========================================================================
-- 6 · CAT-13 (#1596) · el stock mínimo en el resumen del bot
-- =========================================================================
-- Decisión del dueño (15/11, D30): un stock mínimo de 0 es «sin alerta»; vacío (o
-- negativo) usa 10; con alerta, está bajo cuando stock <= mínimo. Es la regla de
-- `stockBajo` (src/utils/stockMinimo.ts). bot_metricas_admin_dia contaba el 0 como
-- un mínimo de 0 (alerta con stock 0). El `stock_minimo` de cada fila del top es el
-- que rige (10 si estaba vacío). bot_stock_y_ventas y bot_ficha_producto no
-- deciden la alerta: devuelven el mínimo crudo y la decide la edge function, que
-- pasa a la misma regla en este PR (supabase/functions/_shared/utils/stockMinimo.ts).
--
-- =========================================================================
-- 7 · cambiar_alicuota_ii sin fecha (anotado por M4, ola 1)
-- =========================================================================
-- Con p_vigente_desde NULL daba el 23502 crudo del INSERT. Ahora, 22023 con su motivo.
--
-- Revertir: volver los cuerpos a los de la premisa, borrar el CHECK
-- politicas_monto_minimo_pedido_techo, volver al índice de categorias por nombre y
-- borrar unidad_direccion_cliente y _otra_unidad_misma_puerta.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- Las tablas que esta migración altera (el CHECK de politicas_comerciales y el índice
-- único de categorias), juntas y sin esperar: tomadas de a una, en otro orden que el
-- del alta de un pedido, darían un deadlock con la app. Si alguna está tomada, falla
-- al instante y se reintenta.
LOCK TABLE public.politicas_comerciales, public.categorias
  IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 16/11 (ledger en la 512), los índices y los datos
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_precios_masivo(jsonb,jsonb)', '4fc32edf38d3d5985c6d7075525720cf'),
    ('public.actualizar_politica_minimo_pedido(text,numeric,numeric,numeric)', '769c5fdf22df99001bf7f2d80d708d09'),
    ('public.actualizar_monto_minimo_pedido(numeric)', 'af8325ede474eb1215f83b51ff1b6651'),
    ('public.pedido_incumple_minimo(numeric,bigint)', '6993a5780cb062aa02ef3e2cbf64c65e'),
    ('public.actualizar_minimo_venta_masivo(uuid,integer)', '2362bb2308f60d87ef409b017ebbde9b'),
    ('public.sync_producto_categoria_id()', '732fe79e957e988bf933ffc4d3ea3a76'),
    ('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)', 'c431610338f04a2387264ee8638e48d7'),
    ('public.productos_rechazar_borrado_con_historial()', '781025173330d3e58aff853ae8de9855'),
    ('public.bot_metricas_admin_dia(date,bigint)', 'd4a41fccc09211dad035a82200ee3d74'),
    ('public.cambiar_alicuota_ii(bigint,numeric,date)', '8dcbeb41fb5dcb5b505e5a28f8697f8b'),
    -- No cambian, pero lo de arriba cuenta con ellas como están: la clave de dirección
    -- (la del índice de clientes), y las RPC de rubros que comparan con upper(btrim()).
    ('public.clave_direccion_cliente(text)', '723f836397e4dca8a2c713373d28fab2'),
    ('public.renombrar_rubro(uuid,text,text)', 'b2d1c5d7c645205423f9a71930984295'),
    ('public.eliminar_rubro(uuid,text,boolean)', '7179adade957b3b85f377273ed951820')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- Las dos funciones nuevas de la unidad de una dirección.
  IF to_regproc('public.unidad_direccion_cliente') IS NOT NULL
     OR to_regproc('public._otra_unidad_misma_puerta') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · unidad_direccion_cliente o _otra_unidad_misma_puerta ya existen';
  END IF;

  -- El índice único de categorias que se reemplaza.
  SELECT indexdef INTO v FROM pg_indexes
   WHERE schemaname = 'public' AND indexname = 'categorias_sucursal_padre_nombre_uk';
  IF v IS DISTINCT FROM 'CREATE UNIQUE INDEX categorias_sucursal_padre_nombre_uk ON public.categorias USING btree (sucursal_id, COALESCE(parent_id, ''00000000-0000-0000-0000-000000000000''::uuid), nombre)' THEN
    RAISE EXCEPTION 'mig NNN · el índice categorias_sucursal_padre_nombre_uk cambió (%): rehacer sobre lo vigente', v;
  END IF;
  IF to_regclass('public.categorias_sucursal_padre_nombre_norm_uk') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · categorias_sucursal_padre_nombre_norm_uk ya existe';
  END IF;

  -- Premisa de datos: rubros (y subrubros del mismo rubro) que difieren sólo en
  -- mayúsculas o espacios. Si hay, se listan y no se aplica.
  SELECT string_agg(format('sucursal %s, %s: %s', d.sucursal_id,
                           COALESCE('subrubros de ' || d.parent_id::text, 'rubros'), d.nombres), '; ')
    INTO v
    FROM (SELECT c.sucursal_id, c.parent_id,
                 string_agg(format('«%s» (%s)', c.nombre, c.id), ', ' ORDER BY c.nombre, c.id) AS nombres
            FROM public.categorias c
           GROUP BY c.sucursal_id, c.parent_id, upper(btrim(c.nombre))
          HAVING count(*) > 1) d;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · hay rubros que difieren sólo en mayúsculas o espacios; fusionarlos antes: %', v;
  END IF;

  -- Premisa de datos: el techo de la compra mínima.
  SELECT string_agg(format('sucursal %s: %s', pc.sucursal_id, pc.monto_minimo_pedido), ', ' ORDER BY pc.sucursal_id)
    INTO v
    FROM public.politicas_comerciales pc
   WHERE pc.monto_minimo_pedido > 99999999;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · hay compras mínimas por encima de $ 99.999.999 (%): bajarlas antes', v;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.politicas_comerciales'::regclass
                AND conname = 'politicas_monto_minimo_pedido_techo') THEN
    RAISE EXCEPTION 'mig NNN · politicas_monto_minimo_pedido_techo ya existe';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 1 · actualizar_precios_masivo
-- =========================================================================
DO $parche_masivo$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_precios_masivo(jsonb,jsonb)'::regprocedure);
BEGIN
  -- 1a · variables
  v_def := pg_temp.parche(v_def,
$a$  v_hallada BOOLEAN;
BEGIN
$a$,
$r$  v_hallada BOOLEAN;
  -- 1596-b2 (#1596): los productos que vienen más de una vez en el lote, y el último
  -- que se avisó; y el neto y el final que quedarían.
  v_repetidos NUMERIC[];
  v_rep_avisado BIGINT;
  v_neto_ef NUMERIC;
  v_final_ef NUMERIC;
BEGIN
$r$, 'actualizar_precios_masivo (variables)');

  -- 1b · los repetidos, antes del bucle
  v_def := pg_temp.parche(v_def,
$a$  FOR v_item IN
    SELECT t.e
      FROM jsonb_array_elements(p_productos) WITH ORDINALITY AS t(e, n)
$a$,
$r$  -- 1596-b2 (#1596): un producto que viene dos veces no se cambia (¿cuál precio valía?).
  IF jsonb_typeof(p_productos) = 'array' THEN
    SELECT array_agg(x.id) INTO v_repetidos
      FROM (SELECT btrim(t.e->>'producto_id')::numeric AS id
              FROM jsonb_array_elements(p_productos) AS t(e)
             WHERE btrim(t.e->>'producto_id') ~ '^[0-9]{1,18}$'
             GROUP BY 1
            HAVING count(*) > 1) x;
  END IF;

  FOR v_item IN
    SELECT t.e
      FROM jsonb_array_elements(p_productos) WITH ORDINALITY AS t(e, n)
$r$, 'actualizar_precios_masivo (repetidos)');

  -- 1c · el repetido se saltea con un aviso
  v_def := pg_temp.parche(v_def,
$a$      v_producto_id := (v_item->>'producto_id')::INT;

$a$,
$r$      v_producto_id := (v_item->>'producto_id')::INT;

      IF v_producto_id::NUMERIC = ANY (v_repetidos) THEN
        IF v_rep_avisado IS DISTINCT FROM v_producto_id THEN
          v_rep_avisado := v_producto_id;
          RAISE EXCEPTION 'viene más de una vez en el lote y no se cambió' USING ERRCODE = '22023';
        END IF;
        CONTINUE;
      END IF;

$r$, 'actualizar_precios_masivo (salteo del repetido)');

  -- 1d · el neto no puede pasar al final (con lo que quedaría)
  v_def := pg_temp.parche(v_def,
$a$      PERFORM set_config('lock_timeout', v_lock_timeout, true);

      UPDATE productos
$a$,
$r$      PERFORM set_config('lock_timeout', v_lock_timeout, true);

      -- 1596-b2 (#1596): el neto no puede pasar al final. Se compara lo que quedaría:
      -- lo que manda el lote, o lo guardado si no lo manda. Igual sí (exento).
      IF v_neto IS NOT NULL OR v_final IS NOT NULL THEN
        SELECT COALESCE(v_neto, precio_sin_iva), COALESCE(v_final, precio)
          INTO v_neto_ef, v_final_ef
          FROM productos
         WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;
        IF v_neto_ef > 0 AND v_final_ef > 0 AND v_neto_ef > v_final_ef THEN
          RAISE EXCEPTION 'el precio neto (%) no puede ser mayor que el precio final (%)', v_neto_ef, v_final_ef
            USING ERRCODE = '22023';
        END IF;
      END IF;

      UPDATE productos
$r$, 'actualizar_precios_masivo (neto y final)');

  -- 1e · 1561-c4: la escala de una condición sin productos en el lote no cambia
  v_def := pg_temp.parche(v_def,
$a$        UPDATE grupo_precio_escalas SET precio_unitario = v_precio WHERE id = v_escala_id;
$a$,
$r$        -- 1561-c4 (#1561): una condición sin productos pasaba la guarda de arriba sin
        -- que cambiara ninguno. Alguno de sus productos tiene que haber cambiado acá.
        IF NOT EXISTS (SELECT 1 FROM grupo_precio_productos gpp
                        WHERE gpp.grupo_precio_id = v_e.grupo_precio_id
                          AND gpp.producto_id = ANY(v_ok)) THEN
          RAISE EXCEPTION 'la escala de % u. de «%» no se cambió: la condición no tiene productos en este lote',
            v_e.cantidad_minima, v_e.grupo USING ERRCODE = '22023';
        END IF;

        UPDATE grupo_precio_escalas SET precio_unitario = v_precio WHERE id = v_escala_id;
$r$, 'actualizar_precios_masivo (escala sin productos)');

  EXECUTE v_def;
END
$parche_masivo$;

-- =========================================================================
-- 2 · Los mínimos
-- =========================================================================
ALTER TABLE public.politicas_comerciales
  ADD CONSTRAINT politicas_monto_minimo_pedido_techo
  CHECK (monto_minimo_pedido <= 99999999);

DO $parche_politica$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_politica_minimo_pedido(text,numeric,numeric,numeric)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;
$a$,
$r$  -- 1561-b9 (#1561, decision del dueño D35): la compra minima la cambia solo el
  -- admin, como la ventana de precio anterior. es_admin() mira tambien `activo`.
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede cambiar la compra mínima del pedido' USING ERRCODE = '42501';
  END IF;
$r$, 'actualizar_politica_minimo_pedido (rol)');

  v_def := pg_temp.parche(v_def,
$a$  IF p_monto_minimo IS NULL OR p_monto_minimo < 0 THEN
    RAISE EXCEPTION 'El monto minimo no puede ser negativo';
  END IF;
$a$,
$r$  IF p_monto_minimo IS NULL OR p_monto_minimo < 0 THEN
    RAISE EXCEPTION 'El monto minimo no puede ser negativo';
  END IF;
  -- 1596-b3 (#1596, decision del dueño D36): el techo, contra un error de tipeo.
  -- Deja afuera el NaN, que pasa la guarda de arriba.
  IF NOT (p_monto_minimo <= 99999999) THEN
    RAISE EXCEPTION 'La compra mínima va hasta $ 99.999.999.' USING ERRCODE = '22023';
  END IF;
$r$, 'actualizar_politica_minimo_pedido (techo)');

  EXECUTE v_def;
END
$parche_politica$;

DO $parche_monto$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_monto_minimo_pedido(numeric)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;
$a$,
$r$  -- 1561-b9 (#1561, decision del dueño D35): solo el admin.
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede cambiar la compra mínima del pedido' USING ERRCODE = '42501';
  END IF;
$r$, 'actualizar_monto_minimo_pedido (rol)');

  v_def := pg_temp.parche(v_def,
$a$  IF p_monto IS NULL OR p_monto < 0 THEN
    RAISE EXCEPTION 'El monto minimo no puede ser negativo';
  END IF;
$a$,
$r$  IF p_monto IS NULL OR p_monto < 0 THEN
    RAISE EXCEPTION 'El monto minimo no puede ser negativo';
  END IF;
  -- 1596-b3 (#1596, D36): el techo. Deja afuera el NaN.
  IF NOT (p_monto <= 99999999) THEN
    RAISE EXCEPTION 'La compra mínima va hasta $ 99.999.999.' USING ERRCODE = '22023';
  END IF;
  -- 1561-b8 (#1561): en escalas el envio gratis tiene que superar al minimo. Antes
  -- lo frenaba el CHECK politicas_escalas_envio_check con un 23514 crudo.
  IF EXISTS (SELECT 1 FROM public.politicas_comerciales pc
              WHERE pc.sucursal_id = v_sucursal
                AND pc.modo_minimo_pedido = 'escalas'
                AND pc.monto_envio_gratis <= p_monto) THEN
    RAISE EXCEPTION 'En escalas, el monto desde el cual el envío es gratis tiene que superar al mínimo: cambialos juntos desde Configuración.'
      USING ERRCODE = '22023';
  END IF;
$r$, 'actualizar_monto_minimo_pedido (techo y escalas)');

  EXECUTE v_def;
END
$parche_monto$;

DO $parche_incumple$
DECLARE
  v_def text := pg_get_functiondef('public.pedido_incumple_minimo(numeric,bigint)'::regprocedure);
BEGIN
  -- 1561-b8 (#1561): con mil millones o más, la máscara de 9 cifras daba «###».
  v_def := pg_temp.parche(v_def,
$a$    to_char(v_minimo, 'FM$999G999G999D00'),
    to_char(COALESCE(p_total, 0), 'FM$999G999G999D00')
$a$,
$r$    to_char(v_minimo, 'FM$999G999G999G999D00'),
    to_char(COALESCE(p_total, 0), 'FM$999G999G999G999D00')
$r$, 'pedido_incumple_minimo (máscara)');

  EXECUTE v_def;
END
$parche_incumple$;

DO $parche_minimo_venta$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_minimo_venta_masivo(uuid,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF p_cantidad IS NOT NULL AND p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad mínima debe ser mayor a 0 (o NULL para quitarla)';
  END IF;
$a$,
$r$  IF p_cantidad IS NOT NULL AND p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad mínima debe ser mayor a 0 (o NULL para quitarla)';
  END IF;
  -- 1596-b3 (#1596, decision del dueño D36): el techo, contra un error de tipeo. Es
  -- el del CHECK productos_cantidad_minima_venta_check (1596-b1): con su motivo, no
  -- el 23514.
  IF p_cantidad > 99999999 THEN
    RAISE EXCEPTION 'La cantidad mínima de venta va hasta 99.999.999.' USING ERRCODE = '22023';
  END IF;
$r$, 'actualizar_minimo_venta_masivo (techo)');

  EXECUTE v_def;
END
$parche_minimo_venta$;

-- =========================================================================
-- 3 · Rubros: el índice único y la búsqueda del trigger
-- =========================================================================
CREATE UNIQUE INDEX categorias_sucursal_padre_nombre_norm_uk
  ON public.categorias (sucursal_id, COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), upper(btrim(nombre)));
COMMENT ON INDEX public.categorias_sucursal_padre_nombre_norm_uk IS
  '1596-b6 (#1596): un rubro (o un subrubro del mismo rubro) por nombre, sin mirar mayúsculas ni espacios de los bordes. Las RPC de rubros y sync_producto_categoria_id comparan igual.';
DROP INDEX public.categorias_sucursal_padre_nombre_uk;

DO $parche_sync$
DECLARE
  v_def text := pg_get_functiondef('public.sync_producto_categoria_id()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT c.id INTO NEW.categoria_id
  FROM categorias c
  WHERE c.sucursal_id = NEW.sucursal_id
    AND c.parent_id IS NULL
    AND lower(trim(c.nombre)) = lower(trim(NEW.categoria))
  LIMIT 1;
$a$,
$r$  -- 1561-b7 (#1561): la comparacion del indice unico (categorias_sucursal_padre_nombre_norm_uk)
  -- y de las RPC de rubros, escrita para que lo use; hay a lo sumo uno. El ORDER BY
  -- deja el LIMIT determinista igual.
  SELECT c.id INTO NEW.categoria_id
  FROM categorias c
  WHERE c.sucursal_id = NEW.sucursal_id
    AND c.parent_id IS NULL
    AND COALESCE(c.parent_id, '00000000-0000-0000-0000-000000000000'::uuid) = '00000000-0000-0000-0000-000000000000'::uuid
    AND upper(btrim(c.nombre)) = upper(btrim(NEW.categoria))
  ORDER BY c.created_at, c.id
  LIMIT 1;
$r$, 'sync_producto_categoria_id (búsqueda)');

  EXECUTE v_def;
END
$parche_sync$;

-- =========================================================================
-- 4 · Dos unidades distintas de la misma puerta (duplicado de cliente)
-- =========================================================================
-- La unidad dentro de la puerta, normalizada: los segmentos después de la primera
-- coma, con los sinónimos al mismo token, ordenada y sin repetir. NULL si no hay.
-- Espejo: unidadDireccion (src/utils/duplicadoCliente.ts).
CREATE FUNCTION public.unidad_direccion_cliente(p_direccion text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_seg      text;
  t          text[];
  i          int;
  v_palabra  text;
  v_salto    int;
  v_id       text;
  v_unidades text[] := '{}';
BEGIN
  IF p_direccion IS NULL THEN
    RETURN NULL;
  END IF;
  FOR v_seg IN
    SELECT u.seg FROM unnest(string_to_array(p_direccion, ',')) WITH ORDINALITY AS u(seg, n)
     WHERE u.n > 1 ORDER BY u.n
  LOOP
    -- La misma normalización que la clave: sin acentos, en minúsculas, y lo que no es
    -- alfanumérico es un espacio.
    t := array_remove(regexp_split_to_array(
           trim(regexp_replace(lower(f_unaccent(v_seg)), '[^a-z0-9]+', ' ', 'g')), ' '), '');
    i := 1;
    WHILE i <= COALESCE(array_length(t, 1), 0) LOOP
      IF t[i] = 'pb' THEN
        v_unidades := v_unidades || 'pb'::text;
      ELSIF t[i] = 'planta' AND t[i + 1] = 'baja' THEN
        v_unidades := v_unidades || 'pb'::text;
        i := i + 1;
      ELSE
        v_palabra := CASE t[i]
          WHEN 'local' THEN 'local' WHEN 'loc' THEN 'local' WHEN 'lc' THEN 'local'
          WHEN 'dpto' THEN 'dpto' WHEN 'depto' THEN 'dpto' WHEN 'dto' THEN 'dpto'
          WHEN 'departamento' THEN 'dpto'
          WHEN 'piso' THEN 'piso'
          WHEN 'of' THEN 'of' WHEN 'ofic' THEN 'of' WHEN 'oficina' THEN 'of'
          WHEN 'puesto' THEN 'puesto' WHEN 'galpon' THEN 'galpon' WHEN 'deposito' THEN 'deposito'
          WHEN 'box' THEN 'box' WHEN 'stand' THEN 'stand'
          WHEN 'uf' THEN 'uf' WHEN 'unidad' THEN 'uf'
          WHEN 'torre' THEN 'torre' WHEN 'block' THEN 'block' WHEN 'modulo' THEN 'modulo'
        END;
        IF v_palabra IS NOT NULL THEN
          v_salto := CASE WHEN t[i] = 'unidad' AND t[i + 1] = 'funcional' THEN 2 ELSE 1 END;
          -- «Local N° 2», «Nro. 2», «No. 2», «# 2»: el «número» no es el identificador.
          IF t[i + v_salto] IN ('n', 'nro', 'no', 'num', 'numero') AND t[i + v_salto + 1] ~ '^[0-9]' THEN
            v_salto := v_salto + 1;
          END IF;
          v_id := t[i + v_salto];
          -- Sólo con un identificador detrás: un número (con una letra pegada) o una
          -- letra suelta. «Puesto Viejo» o «Unidad Turística» no son unidades.
          IF v_id ~ '^([0-9]+[a-z]?|[a-z])$' THEN
            -- «Dpto 3 B» es «dpto 3b», como «Dpto 3B».
            IF v_id ~ '^[0-9]+$' AND t[i + v_salto + 1] ~ '^[a-z]$' AND t[i + v_salto + 1] <> 'y' THEN
              v_id := v_id || t[i + v_salto + 1];
              v_salto := v_salto + 1;
            END IF;
            v_unidades := v_unidades || (v_palabra || ' ' || regexp_replace(v_id, '^0+([0-9])', '\1'));
            i := i + v_salto;
          END IF;
        END IF;
      END IF;
      i := i + 1;
    END LOOP;
  END LOOP;
  -- Ordenadas byte a byte (COLLATE "C"), como el sort() del espejo, y separadas por
  -- coma: _otra_unidad_misma_puerta las vuelve a separar.
  RETURN NULLIF(array_to_string(ARRAY(SELECT DISTINCT (x COLLATE "C") FROM unnest(v_unidades) x
                                        ORDER BY 1), ', '), '');
END
$function$;

COMMENT ON FUNCTION public.unidad_direccion_cliente(text) IS
  '1596-b7 (#1596): la unidad dentro de la puerta de una dirección («Local 2», «Dpto. B», «PB»), normalizada y ordenada; NULL si no hay. Espejo: unidadDireccion (src/utils/duplicadoCliente.ts).';

-- La regla: la misma calle y altura, y las dos con una unidad, distinta. La misma
-- unidad con más detalle («Local 1» y «Local 1, PB») es la misma puerta: son otra
-- unidad sólo si ninguna de las dos listas contiene a la otra.
CREATE FUNCTION public._otra_unidad_misma_puerta(p_a text, p_b text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
           public.clave_direccion_cliente(p_a) = public.clave_direccion_cliente(p_b)
           AND NOT (string_to_array(ua, ', ') <@ string_to_array(ub, ', '))
           AND NOT (string_to_array(ub, ', ') <@ string_to_array(ua, ', ')),
           false)
    FROM (SELECT public.unidad_direccion_cliente(p_a) AS ua,
                 public.unidad_direccion_cliente(p_b) AS ub) u;
$function$;

COMMENT ON FUNCTION public._otra_unidad_misma_puerta(text, text) IS
  '1596-b7 (#1596): dos direcciones son unidades distintas de la misma puerta si tienen la misma calle y altura, las dos dicen una unidad y ninguna lista de unidades contiene a la otra. No chocan por dirección y no bloquean por punto: es un aviso. Espejo: otraUnidadMismaPuerta.';

-- Sólo de server: las llama verificar_duplicado_cliente (DEFINER).
REVOKE ALL ON FUNCTION public.unidad_direccion_cliente(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._otra_unidad_misma_puerta(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.unidad_direccion_cliente(text) TO service_role;
GRANT EXECUTE ON FUNCTION public._otra_unidad_misma_puerta(text, text) TO service_role;

DO $parche_duplicado$
DECLARE
  v_def text := pg_get_functiondef('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)'::regprocedure);
BEGIN
  -- 4a · por dirección: otra unidad de la misma puerta no choca
  v_def := pg_temp.parche(v_def,
$a$       AND clave_direccion_cliente(c.direccion) = v_clave
     ORDER BY c.activo DESC, c.id
$a$,
$r$       AND clave_direccion_cliente(c.direccion) = v_clave
       -- 1596-b7 (#1596): «Local 1» y «Local 2» de la misma puerta no chocan.
       AND NOT _otra_unidad_misma_puerta(p_direccion, c.direccion)
     ORDER BY c.activo DESC, c.id
$r$, 'verificar_duplicado_cliente (dirección)');

  -- 4b · por punto: primero el que bloquea; otra unidad de la misma puerta, aviso
  v_def := pg_temp.parche(v_def,
$a$     ORDER BY haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
     LIMIT 1;
$a$,
$r$     -- 1596-b7 (#1596): primero el que está a menos de 1 m y no es otra unidad de la
     -- misma puerta (ése bloquea, aunque haya otra unidad más cerca); después, el más
     -- cercano, que avisa.
     ORDER BY (haversine_m(p_latitud, p_longitud, c.latitud, c.longitud) < c_bloqueo_m
               AND NOT _otra_unidad_misma_puerta(p_direccion, c.direccion)) DESC,
              haversine_m(p_latitud, p_longitud, c.latitud, c.longitud), c.id
     LIMIT 1;
$r$, 'verificar_duplicado_cliente (orden del vecino)');

  v_def := pg_temp.parche(v_def,
$a$      IF v_dist < c_bloqueo_m THEN
$a$,
$r$      -- Google pone las dos unidades de una puerta en el mismo punto: es un aviso.
      IF v_dist < c_bloqueo_m
         AND NOT _otra_unidad_misma_puerta(p_direccion, (SELECT c2.direccion FROM clientes c2 WHERE c2.id = t_id)) THEN
$r$, 'verificar_duplicado_cliente (punto)');

  EXECUTE v_def;
END
$parche_duplicado$;

-- =========================================================================
-- 5 · Borrar un producto con stock, lotes o en una promoción
-- =========================================================================
DO $parche_borrado$
DECLARE
  v_def text := pg_get_functiondef('public.productos_rechazar_borrado_con_historial()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$DECLARE
  v_donde text;
BEGIN
$a$,
$r$DECLARE
  v_donde text;
  v_frena text;
BEGIN
$r$, 'productos_rechazar_borrado_con_historial (variables)');

  v_def := pg_temp.parche(v_def,
$a$      USING ERRCODE = '23503';
  END IF;

  RETURN OLD;
$a$,
$r$      USING ERRCODE = '23503';
  END IF;

  -- 1561-b2 (#1561, decision del dueño D32): con stock o con lotes (aun agotados) no
  -- se borra, se desactiva. El CASCADE se llevaba el stock, los lotes y su
  -- historial sin aviso. Y el regalo (o el producto de ajuste) de una promocion
  -- tampoco: la FK lo ponia en NULL y la promo quedaba activa sin regalo.
  SELECT string_agg(x.que, ', ' ORDER BY x.orden) INTO v_frena
  FROM (
    SELECT 1 AS orden, format('tiene %s u. en stock', OLD.stock) AS que
     WHERE COALESCE(OLD.stock, 0) <> 0
    UNION ALL
    SELECT 2, 'tiene lotes'
     WHERE EXISTS (SELECT 1 FROM producto_lotes WHERE producto_id = OLD.id)
    UNION ALL
    SELECT 3, 'está en ' || string_agg(format('la promoción «%s»', pr.nombre), ', ' ORDER BY pr.nombre, pr.id)
      FROM promociones pr
     WHERE pr.producto_regalo_id = OLD.id OR pr.ajuste_producto_id = OLD.id
    HAVING count(*) > 0
  ) x;

  IF v_frena IS NOT NULL THEN
    RAISE EXCEPTION 'No se puede borrar "%": %. Desactivalo en lugar de borrarlo.',
      OLD.nombre, v_frena
      USING ERRCODE = '23503';
  END IF;

  RETURN OLD;
$r$, 'productos_rechazar_borrado_con_historial (stock, lotes y promos)');

  EXECUTE v_def;
END
$parche_borrado$;

-- =========================================================================
-- 6 · CAT-13: el stock crítico del resumen del bot
-- =========================================================================
DO $parche_bot$
DECLARE
  v_def text := pg_get_functiondef('public.bot_metricas_admin_dia(date,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  stock_critico_base AS (
    SELECT
      id, codigo, nombre, stock, stock_minimo,
      ROW_NUMBER() OVER (
        ORDER BY (COALESCE(stock_minimo, 10) - COALESCE(stock, 0)) DESC, id ASC
      ) AS rn
    FROM productos
    WHERE COALESCE(stock, 0) <= COALESCE(stock_minimo, 10)
      AND activo  -- #1310 (BOT-3): un producto dado de baja no se repone
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
$a$,
$r$  -- CAT-13 (#1596, decision del dueño D30): la regla de stockBajo
  -- (src/utils/stockMinimo.ts). Vacio o negativo usa 10; 0 es "sin alerta"; con
  -- alerta, esta bajo cuando stock <= minimo. El stock_minimo del top es el que rige.
  stock_minimo_efectivo AS (
    SELECT p.id, p.codigo, p.nombre, p.stock, p.sucursal_id, p.activo,
           CASE WHEN p.stock_minimo IS NULL OR p.stock_minimo < 0 THEN 10
                ELSE p.stock_minimo END AS stock_minimo
      FROM productos p
  ),
  stock_critico_base AS (
    SELECT
      id, codigo, nombre, stock, stock_minimo,
      ROW_NUMBER() OVER (
        ORDER BY (stock_minimo - COALESCE(stock, 0)) DESC, id ASC
      ) AS rn
    FROM stock_minimo_efectivo
    WHERE stock_minimo > 0
      AND COALESCE(stock, 0) <= stock_minimo
      AND activo  -- #1310 (BOT-3): un producto dado de baja no se repone
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
$r$, 'bot_metricas_admin_dia (stock crítico)');

  EXECUTE v_def;
END
$parche_bot$;

-- =========================================================================
-- 7 · cambiar_alicuota_ii sin fecha
-- =========================================================================
DO $parche_alicuota$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_alicuota_ii(bigint,numeric,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  SELECT id INTO v_id FROM public.ii_alicuotas
   WHERE encuadre_id = p_encuadre_id AND vigente_desde = p_vigente_desde
$a$,
$r$  -- Sin fecha el INSERT daba el 23502 crudo (lo anoto M4 en la ola 1 de #1603).
  IF p_vigente_desde IS NULL THEN
    RAISE EXCEPTION 'Falta la fecha desde la que rige la alícuota.' USING ERRCODE = '22023';
  END IF;

  SELECT id INTO v_id FROM public.ii_alicuotas
   WHERE encuadre_id = p_encuadre_id AND vigente_desde = p_vigente_desde
$r$, 'cambiar_alicuota_ii (fecha)');

  EXECUTE v_def;
END
$parche_alicuota$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_precios_masivo(jsonb,jsonb)', 'd055473f216e1f7b9efc370e3551e3f3', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_politica_minimo_pedido(text,numeric,numeric,numeric)', '732be70125ce4815c9965f24fc2c46de', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_monto_minimo_pedido(numeric)', '79ca56e3d12df497f69a90bfbfb05b57', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.pedido_incumple_minimo(numeric,bigint)', '72288ef55afb37543159d81d0873c727', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_minimo_venta_masivo(uuid,integer)', '629480b92775e38b7b3020be2b87c35d', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.sync_producto_categoria_id()', '08e272b3fcbf50a28aebc4403e3a1ee2', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)', '3f95ea7d1843c7dade9bbc84baf50dd9', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.clave_direccion_cliente(text)', '723f836397e4dca8a2c713373d28fab2', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.unidad_direccion_cliente(text)', '34f7930ec9ac932aeea15856acc231ea', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._otra_unidad_misma_puerta(text,text)', '63d66577fab9558e87b174b2582790ea', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.productos_rechazar_borrado_con_historial()', '945ad427e04031ac694f0afdc1ffe450', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.bot_metricas_admin_dia(date,bigint)', 'e891cbfefb1084c765e7c7d84b389593', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.cambiar_alicuota_ii(bigint,numeric,date)', 'faeeed6f369bd53b4dc0a8962dd54003', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;

  IF to_regclass('public.categorias_sucursal_padre_nombre_uk') IS NOT NULL
     OR to_regclass('public.categorias_sucursal_padre_nombre_norm_uk') IS NULL THEN
    RAISE EXCEPTION 'mig NNN · el índice único de categorias no quedó como en el repo';
  END IF;
END
$post$;

COMMIT;
