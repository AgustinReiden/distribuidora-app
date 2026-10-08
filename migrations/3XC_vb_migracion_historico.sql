-- ============================================================================
-- 3XC — el vale blanco histórico pasa a ser comprobante VB (tanda 3: backfill)
-- ============================================================================
-- Hasta acá el vale blanco era una FORMA DE PAGO: se tomaba un pedido ZZ a lista
-- a una empresa propia (Comercial TP, los dos Refugio, Crecer Tucumán, "pérdidas
-- y otros") y se lo "cobraba" con un pago `vale_blanco` por el total. Las migs
-- 3XA/3XB lo convirtieron en un TERCER TIPO DE COMPROBANTE (`tipo_factura='VB'`):
-- consumo interno, a costo, saldado por naturaleza (monto_pagado = total, cero
-- filas en `pagos`), fuera de la venta, de las comisiones y de la rendición.
--
-- Esta migración trae el histórico a ese modelo. Va DESPUÉS de que el front nuevo
-- esté arriba (B6 de la revisión): marca a los 5 clientes como VB, y un PWA viejo
-- que copiara `tipo_factura_default` a un pedido mandaría VB sin saberlo.
--
-- Universo: los pedidos con un pago `vale_blanco` de los clientes 440, 455, 456,
-- 591 y 666 (193 al escribir esto, 2026-10-08, $17.671.100 a lista). Los 2 de
-- Federico Gutiérrez (376) NO son consumo interno: "se le descontó del sueldo".
-- Ese pago pasa a `adelanto_sueldo` y el pedido sigue siendo un ZZ.
--
-- ORDEN FIJO, todo en la transacción de la migración (si algo no cierra, falla
-- entera; nada queda a medias). El orden se verificó contra los triggers vivos:
--
--   0. Precondiciones + foto "antes" (saldos, auditoria_integridad, rendiciones,
--      comisiones). Si 3XA/3XB no están aplicadas, la migración no entra.
--   1. Clientes -> 'VB'. Corre como postgres: `clientes_vb_solo_admin` (3XA) sale
--      por `current_user <> 'authenticated'`.
--   2. Federico: pago `vale_blanco` -> `adelanto_sueldo`. Es UPDATE OF forma_pago:
--      no dispara `guard_pago_fecha_cerrada` (OF fecha, monto) ni el trigger de
--      saldo (OF monto, pedido_id, cliente_id).
--   3. Re-precio de las líneas a costo, CON el pedido todavía en ZZ y el pago VB
--      vivo. En `pedido_items` no hay ningún trigger que toque `pedidos`, así que el
--      total del pedido no se mueve todavía (VENTA-A queda transitoriamente
--      desfasada dentro de la transacción; el paso 4 la cierra).
--   4. UN SOLO UPDATE de pedidos con tipo_factura, total, total_neto, total_iva,
--      total_real, monto_pagado y forma_pago juntos (regla B1: los AFTER `OF total,
--      monto_pagado` disparan por la lista del SET, no por lo que cambie un BEFORE):
--        - `trigger_actualizar_estado_pago` (BEFORE ... OF monto_pagado, total: el
--          SET nombra las dos) corre `actualizar_estado_pago_pedido` con la rama VB
--          de la 3XA y fuerza monto_pagado = total, estado_pago = 'pagado'; el
--          `trigger_actualizar_estado_pago_vb` de la 3XA (OF tipo_factura,
--          estado_pago, WHEN VB) hace lo mismo después;
--        - `trigger_actualizar_saldo_pedido`: contrib vieja total-monto_pagado = 0,
--          nueva = 0 -> el saldo no se mueve;
--        - `zzz_pedidos_reconciliar_pagos`: con `app.reimputacion_pagos='on'` sale
--          enseguida; aun sin la red, monto_pagado = total => excedente 0, y
--          `desafectar_sobrepago_pedido` no recortaría el pago VB (que, recortado,
--          chocaría con `guard_pago_fecha_cerrada` en 182 pagos de caja cerrada: B8);
--        - `trigger_actualizar_recorrido_entrega` recalcula los 2 recorridos que
--          tienen pedidos del universo (135 y 36) con la definición de 3XA;
--        - `registrar_cambio_pedido` deja una fila 'total' (lista -> costo) por
--          pedido y una 'forma_pago' en los 20 que decían 'vale_blanco'.
--      NO se toca transportista_id, fecha_entrega ni orden_entrega: 75 pedidos del
--      universo tienen transportista y `trg_pedidos_anular_control` borraría los
--      `rendiciones_control` (cajas cerradas) de esos días (B4).
--   5. DELETE de los pagos VB del universo. Pasa `pagos_guard_anulacion_caja_cerrada`
--      (sale por current_user); `recalcular_monto_pagado_pedido` (3XA) no toca un VB,
--      y aunque lo tocara el BEFORE de estado de pago volvería a poner monto = total.
--   6. pedido_historial: una fila 'tipo_factura' por pedido (el trigger no la
--      registra).
--   7. pedidos.forma_pago 'vale_blanco' remanente -> 'efectivo' y CHECKs de dominio
--      en pagos y pedidos (N15: después de esto el valor no puede volver).
--   8. calcular_comisiones sin los filtros por vale_blanco de la 309 (quedan VB y
--      adelanto de sueldo).
--   9. obtener_resumen_rendiciones / obtener_detalle_rendicion sin la columna del
--      vale blanco (3XA la había conservado en 0 para el front viejo).
--  10. DO $ensayo$: foto "después" y comparación. Cualquier diferencia no explicada
--      => RAISE EXCEPTION y la migración no entra.
--
-- Precio = `round(costo_valuacion(costo_unitario_al_crear, promedio, real,
-- sin_iva, ii), 2)`: la misma cascada que escribe `costo_unitario_al_crear` en
-- `crear_pedido_completo` (migs 238/257/258), pero arrancando por el snapshot de la
-- línea. Al escribir esto, 105 de 489 líneas NO tienen snapshot (son anteriores a
-- la 257): para ellas el costo es el VIGENTE el día que corre la migración, no el
-- histórico, y se escribe en `costo_unitario_al_crear` el valor usado — si no, la
-- cascada de cualquier reporte futuro caería al promedio vivo y el "margen 0" del
-- consumo interno se desarmaría solo con el tiempo. Σ esperado ≈ $10.843.304.
--
-- ORDEN DE APLICACIÓN: 3XA → 3XB y 3XD → front → ESTA, sin demora después del
-- front. Entre la 3XA y ésta nadie puede cargar consumo interno (N15 rechaza
-- 'vale_blanco' y ningún cliente es VB todavía): lo que se haya cargado en esa
-- ventana como ZZ a los 5 clientes queda como venta y deuda. Las precondiciones
-- lo listan con un WARNING; no se convierte solo (a un cliente VB también se le
-- puede vender un ZZ de verdad, N3). Convertirlo, si corresponde, es con
-- "cambiar tipo de comprobante" una vez que esto corrió.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Fotos y universo. Tablas temporales: se descartan al COMMIT (por eso el
--     BEGIN explícito: sin transacción, ON COMMIT DROP las borra al terminar
--     cada sentencia).
-- ---------------------------------------------------------------------------

-- Los pedidos que pasan a VB, con lo que tenían antes (para el ensayo).
CREATE TEMP TABLE _vb_universo ON COMMIT DROP AS
SELECT p.id                AS pedido_id,
       p.cliente_id,
       p.sucursal_id,
       p.tipo_factura      AS tipo_antes,
       p.estado,
       p.canal,
       p.total             AS total_antes,
       p.monto_pagado      AS monto_pagado_antes,
       p.estado_pago       AS estado_pago_antes,
       p.forma_pago        AS forma_pago_antes,
       p.transportista_id,
       p.fecha_entrega,
       p.orden_entrega
  FROM pedidos p
 WHERE p.cliente_id IN (440, 455, 456, 591, 666)
   AND EXISTS (SELECT 1 FROM pagos g
                WHERE g.pedido_id = p.id AND g.forma_pago = 'vale_blanco');

-- TODOS los pagos vale_blanco (universo + Federico): los dos grupos salen de la
-- rendición (los del universo se borran; los de Federico pasan a adelanto, que las
-- RPCs de rendición excluyen desde la 273). Con esto se calcula cuánto tiene que
-- moverse cada fila de la grilla.
CREATE TEMP TABLE _vb_pagos ON COMMIT DROP AS
SELECT g.id, g.pedido_id, g.cliente_id, g.sucursal_id, g.fecha, g.monto,
       g.usuario_id, pd.transportista_id
  FROM pagos g
  LEFT JOIN pedidos pd ON pd.id = g.pedido_id
 WHERE g.forma_pago = 'vale_blanco';

-- Las líneas del universo con el costo que les toca. Se calcula ANTES de escribir
-- nada, para que un producto sin costo frene la migración en las precondiciones.
CREATE TEMP TABLE _vb_lineas ON COMMIT DROP AS
SELECT pi.id,
       pi.pedido_id,
       pi.cantidad,
       pi.es_bonificacion                                         AS era_bonificacion,
       pi.costo_unitario_al_crear                                 AS snapshot_previo,
       COALESCE(pr.nombre, 'Producto #' || pi.producto_id)        AS producto_nombre,
       public.costo_valuacion(pi.costo_unitario_al_crear, pr.costo_promedio,
                              pr.costo_real, pr.costo_sin_iva,
                              COALESCE(pr.impuestos_internos, 0)) AS costo
  FROM pedido_items pi
  JOIN _vb_universo u ON u.pedido_id = pi.pedido_id
  LEFT JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id;

ALTER TABLE _vb_lineas ADD COLUMN precio numeric(10,2);
ALTER TABLE _vb_lineas ADD COLUMN neto numeric;
ALTER TABLE _vb_lineas ADD COLUMN iva numeric;
ALTER TABLE _vb_lineas ADD COLUMN ingreso_real numeric;

-- Cuánto tiene que moverse cada fila (sucursal, transportista/cobrador, día) de
-- obtener_resumen_rendiciones: `g` sale de total_general (pagos VB, con la misma
-- atribución COALESCE(transportista, cobrador) de pagos_agg) y `e`/`n` salen de
-- total_entregado/cantidad_pedidos (pedidos VB con transportista, a lista, con la
-- misma fecha_entrega::date de entregas_agg — misma sesión, misma zona horaria).
CREATE TEMP TABLE _vb_delta ON COMMIT DROP AS
WITH g AS (
  SELECT sucursal_id AS s, COALESCE(transportista_id, usuario_id) AS t, fecha AS f,
         SUM(monto) AS g
    FROM _vb_pagos
   GROUP BY 1, 2, 3
), e AS (
  SELECT sucursal_id AS s, transportista_id AS t, fecha_entrega::date AS f,
         SUM(total_antes) AS e, COUNT(*)::bigint AS n
    FROM _vb_universo
   WHERE estado = 'entregado' AND transportista_id IS NOT NULL AND fecha_entrega IS NOT NULL
   GROUP BY 1, 2, 3
)
SELECT COALESCE(g.s, e.s) AS sucursal_id,
       COALESCE(g.t, e.t) AS transportista_id,
       COALESCE(g.f, e.f) AS fecha,
       COALESCE(g.g, 0)   AS g,
       COALESCE(e.e, 0)   AS e,
       COALESCE(e.n, 0)   AS n
  FROM g FULL JOIN e ON e.s = g.s AND e.t = g.t AND e.f = g.f;

-- Fotos de antes y después.
CREATE TEMP TABLE _vb_rend (
  etapa            text,
  sucursal_id      bigint,
  fecha            date,
  transportista_id uuid,
  total_general    numeric,
  total_entregado  numeric,
  cantidad_pedidos bigint,
  total_gastos     numeric,
  controlada       boolean
) ON COMMIT DROP;

CREATE TEMP TABLE _vb_audit (
  etapa       text,
  check_id    text,
  severidad   text,
  violaciones bigint
) ON COMMIT DROP;

CREATE TEMP TABLE _vb_foto (
  etapa text,
  clave text,
  valor jsonb
) ON COMMIT DROP;

CREATE TEMP TABLE _vb_param (
  admin_id     uuid,
  sucursales   bigint[],
  desde        date,
  hasta        date
) ON COMMIT DROP;

-- La foto se saca dos veces con el mismo código. Las RPCs exigen admin y sucursal
-- activa, así que se hace pasar por un admin (molde de la 241/244/252: set_config
-- local, y se limpia al salir para que los triggers de los pasos 1..9 no vean un
-- auth.uid() prestado). Las llamadas van por EXECUTE: entre una foto y la otra el
-- paso 9 dropea y recrea obtener_resumen_rendiciones con otro RETURNS TABLE, y un
-- plan cacheado de la primera no tiene que sobrevivir.
CREATE FUNCTION pg_temp._vb_foto(p_etapa text) RETURNS void
LANGUAGE plpgsql AS $foto$
DECLARE
  v_p   record;
  v_suc bigint;
BEGIN
  SELECT * INTO v_p FROM _vb_param;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p.admin_id)::text, true);

  FOREACH v_suc IN ARRAY v_p.sucursales LOOP
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    EXECUTE $q$
      INSERT INTO _vb_rend
      SELECT $1, $2, r.fecha, r.transportista_id, r.total_general, r.total_entregado,
             r.cantidad_pedidos, r.total_gastos, r.controlada
        FROM public.obtener_resumen_rendiciones($3, $4, NULL) r
    $q$ USING p_etapa, v_suc, v_p.desde, v_p.hasta;
  END LOOP;

  EXECUTE $q$
    INSERT INTO _vb_foto
    VALUES ($1, 'comisiones', public.calcular_comisiones($2, $3, $4))
  $q$ USING p_etapa, v_p.desde, v_p.hasta, v_p.sucursales;

  INSERT INTO _vb_audit
  SELECT p_etapa, c->>'id', c->>'severidad', (c->>'violaciones')::bigint
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c;

  INSERT INTO _vb_foto
  SELECT p_etapa, 'saldo:' || c.id, to_jsonb(COALESCE(c.saldo_cuenta, 0))
    FROM clientes c
   WHERE c.id IN (376, 440, 455, 456, 591, 666);

  INSERT INTO _vb_foto
  SELECT p_etapa, 'rendiciones_control',
         COALESCE(jsonb_agg(jsonb_build_array(rc.id, rc.estado) ORDER BY rc.id), '[]'::jsonb)
    FROM rendiciones_control rc;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
END;
$foto$;


-- ---------------------------------------------------------------------------
-- 0b · Precondiciones. Todo lo que el resto da por hecho se verifica acá.
-- ---------------------------------------------------------------------------
DO $precondiciones$
DECLARE
  v_n          int;
  v_lista      text;
  v_admin      uuid;
  v_sucursales bigint[];
  v_desde      date;
  v_hasta      date;
  v_d          record;
  v_a_ts       text;
BEGIN
  -- 3XA aplicada: sin su esquema y sus triggers, los pasos 3..5 dejarían saldo y
  -- estado de pago mal (o directamente chocarían con los CHECK).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'pedidos_tipo_factura_check'
                    AND pg_get_constraintdef(oid) LIKE '%''VB''%') THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: pedidos_tipo_factura_check no admite VB';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'pedido_items_origen_precio_check'
                    AND pg_get_constraintdef(oid) LIKE '%costo_interno%') THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: pedido_items_origen_precio_check no admite costo_interno';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pedidos_vb_coherente') THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: no existe el CHECK pedidos_vb_coherente';
  END IF;
  -- La 3XA dejó `trigger_actualizar_estado_pago` como estaba (OF monto_pagado,
  -- total) y agregó uno aparte para los VB. El paso 4 nombra total y
  -- monto_pagado, así que el original alcanza; se verifica que estén los dos y
  -- que la función tenga la rama VB.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'public.pedidos'::regclass
                    AND t.tgname = 'trigger_actualizar_estado_pago'
                    AND pg_get_triggerdef(t.oid) LIKE '%monto_pagado%'
                    AND pg_get_triggerdef(t.oid) LIKE '%total%')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger t
                     WHERE t.tgrelid = 'public.pedidos'::regclass
                       AND t.tgname = 'trigger_actualizar_estado_pago_vb'
                       AND pg_get_triggerdef(t.oid) LIKE '%tipo_factura%')
     OR pg_get_functiondef('public.actualizar_estado_pago_pedido'::regproc) NOT LIKE '%''VB''%' THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: trigger_actualizar_estado_pago(_vb) o la rama VB de actualizar_estado_pago_pedido';
  END IF;
  IF pg_get_functiondef('public.recalcular_monto_pagado_pedido'::regproc) NOT LIKE '%''VB''%' THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: recalcular_monto_pagado_pedido todavía toca los VB';
  END IF;
  SELECT d.neto, d.iva, d.ingreso_real INTO v_d
    FROM public.calcular_desglose_venta(100, 21, 0, 'VB') d;
  IF v_d.neto IS DISTINCT FROM 100::numeric OR v_d.iva IS DISTINCT FROM 0::numeric
     OR v_d.ingreso_real IS DISTINCT FROM 100::numeric THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: calcular_desglose_venta(100,21,0,''VB'') da (%,%,%), se esperaba (100,0,100)',
      v_d.neto, v_d.iva, v_d.ingreso_real;
  END IF;
  IF pg_get_functiondef('public.obtener_resumen_rendiciones'::regproc) NOT LIKE '%''VB''%' THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: obtener_resumen_rendiciones no excluye los VB de entregas_agg';
  END IF;
  IF pg_get_functiondef('public.auditoria_integridad'::regproc) NOT LIKE '%VB-A%' THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: auditoria_integridad no tiene la familia VB-';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'public.pagos'::regclass AND NOT t.tgisinternal
                    AND pg_get_functiondef(t.tgfoid) LIKE '%vale_blanco%') THEN
    RAISE EXCEPTION 'mig vb · falta 3XA: no hay trigger en pagos que rechace vale_blanco (N15)';
  END IF;
  -- 3XB aplicada: el ensayo compara calcular_comisiones antes/después, y "antes"
  -- tiene que ser la versión con VB + adelanto.
  IF pg_get_functiondef('public.calcular_comisiones'::regproc) NOT LIKE '%''VB''%'
     OR pg_get_functiondef('public.calcular_comisiones'::regproc) NOT LIKE '%adelanto_sueldo%' THEN
    RAISE EXCEPTION 'mig vb · falta 3XB: calcular_comisiones todavía no excluye VB y adelanto de sueldo';
  END IF;

  -- Las tres funciones que esta migración reescribe ENTERAS (pasos 8 y 9) parten
  -- de un cuerpo conocido; si el vivo es otro, un CREATE revertiría en silencio
  -- lo que haya cambiado otra sesión. md5(prosrc) esperado:
  --   · calcular_comisiones: el cuerpo que deja la 3XB (archivo 3XB, tal cual);
  --   · obtener_resumen_rendiciones: el de prod del 2026-10-08 con el parche por
  --     ancla de la 3XA en entregas_agg;
  --   · obtener_detalle_rendicion: el de prod del 2026-10-08 (nadie la toca antes).
  -- Si alguien edita el cuerpo de calcular_comisiones de la 3XB o el parche de
  -- rendiciones de la 3XA, este md5 deja de cerrar: recalcularlo y revisar que la
  -- copia de abajo siga siendo esa versión menos lo que se saca acá.
  FOR v_d IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.calcular_comisiones(date,date,bigint[])',            'b05113df69d3466fbb357d9e3a5b0f59'),
        ('public.obtener_resumen_rendiciones(date,date,uuid)',        '917262f449237610b3dc94dbf1f9549b'),
        ('public.obtener_detalle_rendicion(date,uuid)',               '0b83fe994873584491a9ad54b83d35f2')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_d.md5_vivo <> v_d.md5 THEN
      RAISE EXCEPTION 'mig vb · % no es la versión sobre la que se escribió esta migración (md5 %, esperado %): rehacer la copia',
        v_d.firma, v_d.md5_vivo, v_d.md5;
    END IF;
  END LOOP;

  -- I3 de la revisión: lo que se cargó a los 5 clientes como ZZ/FC DESPUÉS de la
  -- 3XA y sigue impago. En esa ventana no había forma de cargar un consumo
  -- interno (ni pago vale_blanco ni cliente VB), así que algo de esto puede ser
  -- un vale cargado como venta. No se convierte solo: a un cliente VB también se
  -- le vende un ZZ de verdad (N3). El instante de la 3XA es el del check VB-C.
  v_a_ts := substring(pg_get_functiondef('public.auditoria_integridad'::regproc)
                      from 'p\.created_at >= ''([^'']+)''::timestamptz');
  IF v_a_ts IS NULL THEN
    RAISE WARNING 'mig vb · no se pudo leer el instante de la 3XA del check VB-C: revisar a mano los ZZ/FC impagos de los clientes 440, 455, 456, 591 y 666';
  ELSE
    SELECT string_agg(format('#%s (cliente %s, %s, $%s)', p.id, p.cliente_id, p.tipo_factura, p.total - COALESCE(p.monto_pagado, 0)),
                      '; ' ORDER BY p.id)
      INTO v_lista
      FROM pedidos p
     WHERE p.cliente_id IN (440, 455, 456, 591, 666)
       AND p.created_at >= v_a_ts::timestamptz
       AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND p.estado NOT IN ('cancelado', 'anulado')
       AND p.total > COALESCE(p.monto_pagado, 0);
    IF v_lista IS NOT NULL THEN
      RAISE WARNING 'mig vb · pedidos ZZ/FC impagos a clientes internos cargados después de la 3XA (no se convierten; si eran consumo interno, pasarlos a VB con "cambiar tipo de comprobante"): %', v_lista;
    END IF;
  END IF;

  -- Universo: forma esperada. Cualquier desvío lo decide el dueño, no la migración.
  SELECT count(*) INTO v_n FROM _vb_universo;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'mig vb · el universo está vacío: ¿ya se aplicó esta migración?';
  END IF;
  SELECT string_agg(pedido_id::text, ', ' ORDER BY pedido_id) INTO v_lista
    FROM _vb_universo u
   WHERE u.tipo_antes IS DISTINCT FROM 'ZZ'
      OR u.estado IS DISTINCT FROM 'entregado'
      OR u.canal IS DISTINCT FROM 'app'
      OR u.estado_pago_antes IS DISTINCT FROM 'pagado'
      OR abs(COALESCE(u.monto_pagado_antes, 0) - u.total_antes) > 0.005
      OR (SELECT count(*) FROM pagos g WHERE g.pedido_id = u.pedido_id) <> 1
      OR (SELECT g.monto FROM pagos g WHERE g.pedido_id = u.pedido_id LIMIT 1) <> u.total_antes
      OR NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id = u.pedido_id);
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION 'mig vb · pedidos del universo fuera de la forma esperada (ZZ, entregado, app, un solo pago VB por el total): %', v_lista;
  END IF;
  SELECT string_agg(DISTINCT u.pedido_id::text, ', ') INTO v_lista
    FROM _vb_universo u
   WHERE EXISTS (SELECT 1 FROM salvedades_items s WHERE s.pedido_id = u.pedido_id)
      OR EXISTS (SELECT 1 FROM notas_credito_venta n WHERE n.pedido_id = u.pedido_id);
  IF v_lista IS NOT NULL THEN
    -- Una salvedad guarda el precio a lista y anular_salvedad lo restituiría así en
    -- un VB; una NC sobre un consumo interno no tiene sentido. Al escribir: 0 y 0.
    RAISE EXCEPTION 'mig vb · pedidos del universo con salvedad o nota de crédito: %', v_lista;
  END IF;

  -- Pagos vale_blanco fuera del universo: sólo se admiten los de Federico (376).
  -- Uno de otro cliente (cargado por un PWA viejo antes de 3XA) lo decide el dueño.
  SELECT string_agg(format('pago %s (cliente %s, pedido %s)', id, cliente_id, pedido_id), '; ')
    INTO v_lista
    FROM _vb_pagos g
   WHERE g.cliente_id <> 376
     AND NOT EXISTS (SELECT 1 FROM _vb_universo u WHERE u.pedido_id = g.pedido_id);
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION 'mig vb · pagos vale_blanco fuera del universo y que no son de Federico: %', v_lista;
  END IF;
  -- Y los de Federico tienen que ser plata de un pedido suyo, no un saldo a favor.
  IF EXISTS (SELECT 1 FROM _vb_pagos WHERE cliente_id = 376 AND pedido_id IS NULL) THEN
    RAISE EXCEPTION 'mig vb · Federico tiene un pago vale_blanco sin pedido: decidir a mano';
  END IF;
  -- pedidos.forma_pago = 'vale_blanco' fuera del universo: hoy 0 (los 20 que hay son
  -- del universo). El paso 7 los pasaría a 'efectivo' igual, pero que se sepa.
  SELECT count(*) INTO v_n FROM pedidos p
   WHERE p.forma_pago = 'vale_blanco'
     AND NOT EXISTS (SELECT 1 FROM _vb_universo u WHERE u.pedido_id = p.id);
  IF v_n > 0 THEN
    RAISE NOTICE 'mig vb · % pedidos fuera del universo dicen forma_pago=vale_blanco: pasan a efectivo en el paso 7', v_n;
  END IF;

  -- Costo de cada línea: sin costo no hay precio (N5). Al escribir: 0 de 489.
  SELECT string_agg(DISTINCT producto_nombre, ', ') INTO v_lista
    FROM _vb_lineas WHERE costo IS NULL OR round(costo, 2) <= 0;
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION 'mig vb · productos sin costo cargado en pedidos del universo (no pueden pasar a vale blanco): %', v_lista;
  END IF;
  UPDATE _vb_lineas l
     SET precio = round(l.costo, 2);
  -- Desglose VB de 3XA (iva 0, neto = ingreso real = precio), no una copia inline.
  UPDATE _vb_lineas l
     SET (neto, iva, ingreso_real) = (
           SELECT d.neto, d.iva, d.ingreso_real
             FROM pedido_items pi,
                  public.calcular_desglose_venta(l.precio, pi.porcentaje_iva, 0, 'VB') d
            WHERE pi.id = l.id);

  -- Admin para las fotos: uno que tenga TODAS las sucursales involucradas.
  SELECT array_agg(DISTINCT s ORDER BY s) INTO v_sucursales
    FROM (SELECT sucursal_id AS s FROM _vb_universo
          UNION SELECT sucursal_id FROM _vb_pagos) x;
  SELECT us.usuario_id INTO v_admin
    FROM usuario_sucursales us
    JOIN perfiles pf ON pf.id = us.usuario_id AND pf.rol = 'admin'
   WHERE us.sucursal_id = ANY(v_sucursales)
   GROUP BY us.usuario_id
  HAVING count(DISTINCT us.sucursal_id) = array_length(v_sucursales, 1)
   ORDER BY us.usuario_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'mig vb · el ensayo necesita un admin asignado a las sucursales %', v_sucursales;
  END IF;

  -- Rango de la grilla de rendiciones y de comisiones: desde lo más viejo del
  -- universo (fecha del pedido, de entrega o del pago) hasta hoy en Argentina.
  SELECT LEAST(
           (SELECT min(p.fecha) FROM pedidos p
             WHERE p.id IN (SELECT pedido_id FROM _vb_universo UNION SELECT pedido_id FROM _vb_pagos)),
           (SELECT min(fecha_entrega::date) FROM _vb_universo),
           (SELECT min(fecha) FROM _vb_pagos))
    INTO v_desde;
  v_hasta := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_hasta := GREATEST(v_hasta,
                      (SELECT max(fecha_entrega::date) FROM _vb_universo),
                      (SELECT max(fecha) FROM _vb_pagos));

  INSERT INTO _vb_param VALUES (v_admin, v_sucursales, v_desde, v_hasta);

  RAISE NOTICE 'mig vb · universo: % pedidos, % líneas (% sin snapshot de costo), % pagos VB en total, % de Federico',
    (SELECT count(*) FROM _vb_universo), (SELECT count(*) FROM _vb_lineas),
    (SELECT count(*) FROM _vb_lineas WHERE snapshot_previo IS NULL),
    (SELECT count(*) FROM _vb_pagos), (SELECT count(*) FROM _vb_pagos WHERE cliente_id = 376);
END
$precondiciones$;

SELECT pg_temp._vb_foto('antes');


-- ---------------------------------------------------------------------------
-- Redes para los pasos 3..5, locales a la transacción:
--   * app.omitir_minimo_venta: `trg_validar_minimo_venta_item` dispara por
--     UPDATE OF es_bonificacion (las 2 líneas bonificadas). Un VB no respeta el
--     mínimo de venta por producto (N6).
--   * app.reimputacion_pagos: `zzz_pedidos_reconciliar_pagos` y
--     `guard_pago_fecha_cerrada` salen por ella. No hay nada que reimputar (cada
--     pedido queda monto_pagado = total) y los 5 clientes no tienen saldo a favor.
-- ---------------------------------------------------------------------------
SELECT set_config('app.omitir_minimo_venta', '1', true);
SELECT set_config('app.reimputacion_pagos', 'on', true);


-- ---------------------------------------------------------------------------
-- 1 · Los 5 clientes internos quedan habilitados para vale blanco. Para ellos el
--     pedido nace VB por defecto en el front (N2); un ZZ/FC sigue siendo posible.
-- ---------------------------------------------------------------------------
UPDATE clientes
   SET tipo_factura_default = 'VB'
 WHERE id IN (440, 455, 456, 591, 666);


-- ---------------------------------------------------------------------------
-- 2 · Federico Gutiérrez (376): sus "vales" eran compras de empleado descontadas
--     del sueldo ("se le descontó del sueldo" en las notas), no consumo entre
--     empresas. Pasan a adelanto de sueldo (mig 273): siguen cancelando la deuda
--     del pedido, salen de la rendición y no comisionan (3XB). Sus pedidos siguen
--     siendo ZZ. UPDATE directo: actualizar_forma_pago_pago no admite el adelanto
--     a propósito (273).
-- ---------------------------------------------------------------------------
UPDATE pagos
   SET forma_pago = 'adelanto_sueldo'
 WHERE forma_pago = 'vale_blanco'
   AND cliente_id = 376;

-- Hoy los 2 pedidos dicen 'efectivo' y esto no toca nada; queda por si no.
UPDATE pedidos
   SET forma_pago = 'efectivo'
 WHERE forma_pago = 'vale_blanco'
   AND cliente_id = 376;


-- ---------------------------------------------------------------------------
-- 3 · Re-precio de las líneas a costo (N5), desglose VB (sin IVA: neto = precio =
--     ingreso real) y origen 'costo_interno'.
--     * Las 2 líneas bonificadas (6681 del pedido 1988 y 7549 del 2222, producto
--       206, promo 14) se valorizan: un vale blanco no lleva regalos (N6) y una
--       bonificación con precio pondría BONIF-A en rojo. Se conserva
--       `promocion_id` como rastro. Los contadores de la promo 14
--       (aplicar_uso_promo_acumulador) NO se revierten: si alguien cancela ese VB,
--       el stock vuelve por la rama no-bonif (que sí se había descontado,
--       regalo_mueve_stock) y el contador queda contado. Aceptado: es de mayo.
--     * `costo_unitario_al_crear` se escribe donde estaba NULL (ver encabezado).
--     * `precio_lista_al_crear` y `descuento_pct` no se tocan: son la foto del alta.
-- ---------------------------------------------------------------------------
UPDATE pedido_items pi
   SET precio_unitario         = l.precio,
       subtotal                = pi.cantidad * l.precio,
       neto_unitario           = l.neto,
       iva_unitario            = l.iva,
       ingreso_real_unitario   = l.ingreso_real,
       origen_precio           = 'costo_interno',
       es_bonificacion         = false,
       costo_unitario_al_crear = COALESCE(pi.costo_unitario_al_crear, l.costo)
  FROM _vb_lineas l
 WHERE pi.id = l.id;


-- ---------------------------------------------------------------------------
-- 4 · El pedido pasa a VB. UN solo UPDATE con total y monto_pagado nombrados
--     (ver el encabezado: es lo que hace que saldo, reconciliación y recorrido
--     vean el cambio). No se toca transportista_id, fecha_entrega ni orden_entrega.
-- ---------------------------------------------------------------------------
UPDATE pedidos p
   SET tipo_factura = 'VB',
       total        = t.total,
       total_neto   = t.total_neto,
       total_iva    = 0,
       total_real   = t.total_real,
       monto_pagado = t.total,
       forma_pago   = CASE WHEN p.forma_pago = 'vale_blanco' THEN 'efectivo' ELSE p.forma_pago END
  FROM (
    SELECT pi.pedido_id,
           SUM(pi.subtotal)                                      AS total,
           round(SUM(pi.cantidad * pi.neto_unitario), 2)         AS total_neto,
           round(SUM(pi.cantidad * pi.ingreso_real_unitario), 2) AS total_real
      FROM pedido_items pi
     WHERE pi.pedido_id IN (SELECT pedido_id FROM _vb_universo)
     GROUP BY pi.pedido_id
  ) t
 WHERE p.id = t.pedido_id;


-- ---------------------------------------------------------------------------
-- 5 · Los pagos VB del universo se borran: un VB no tiene pagos (§3.2). Esto saca
--     ~$17,7 M de "cobrado" de las rendiciones; el ensayo verifica cuánto se mueve
--     cada fila.
-- ---------------------------------------------------------------------------
DELETE FROM pagos
 WHERE forma_pago = 'vale_blanco'
   AND pedido_id IN (SELECT pedido_id FROM _vb_universo);


-- ---------------------------------------------------------------------------
-- 6 · Historial: registrar_cambio_pedido no registra tipo_factura. usuario_id
--     queda NULL (corre la migración, no una persona).
-- ---------------------------------------------------------------------------
INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
SELECT u.pedido_id, NULL, 'tipo_factura', u.tipo_antes,
       'VB (vale blanco pasa de forma de pago a comprobante)', u.sucursal_id
  FROM _vb_universo u;

SELECT set_config('app.omitir_minimo_venta', '', true);
SELECT set_config('app.reimputacion_pagos', '', true);


-- ---------------------------------------------------------------------------
-- 7 · `vale_blanco` deja de existir como forma de pago (N15). 3XA ya lo rechaza
--     por trigger; con el histórico limpio, el CHECK lo hace a prueba de bypass.
-- ---------------------------------------------------------------------------
UPDATE pedidos
   SET forma_pago = 'efectivo'
 WHERE forma_pago = 'vale_blanco';

DO $sin_vale$
DECLARE
  v_lista text;
BEGIN
  SELECT string_agg(format('pago %s (cliente %s, pedido %s)', id, cliente_id, pedido_id), '; ')
    INTO v_lista
    FROM pagos WHERE forma_pago = 'vale_blanco';
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION 'mig vb · quedaron pagos vale_blanco sin migrar: %', v_lista;
  END IF;
END
$sin_vale$;

ALTER TABLE pagos
  ADD CONSTRAINT pagos_sin_vale_blanco
  CHECK ((forma_pago)::text IS DISTINCT FROM 'vale_blanco');

ALTER TABLE pedidos
  ADD CONSTRAINT pedidos_sin_vale_blanco
  CHECK (forma_pago IS DISTINCT FROM 'vale_blanco');


-- ---------------------------------------------------------------------------
-- 8 · calcular_comisiones: se van los filtros por vale_blanco de la 309. Después
--     del backfill no queda ningún pago ni pedido 'vale_blanco' (y los CHECK de
--     arriba lo garantizan), así que eran código muerto. Quedan los de 3XB: el VB
--     (consumo interno) y el pedido con un pago adelanto_sueldo (consumo de
--     empleado) no comisionan. Copia literal de la vigente; sólo cambia `ped`.
--     El ensayo compara el resultado antes/después: tiene que ser idéntico.
--     Parte de la versión de la 3XB (la precondición verifica su md5): idéntica
--     salvo los dos filtros de la 309 y sus comentarios; `COALESCE(tipo_factura,
--     'ZZ') <> 'VB'` equivale al `IS DISTINCT FROM 'VB'` de la 3XB.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calcular_comisiones(p_desde date, p_hasta date, p_sucursal_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[];
  v_pct_prev   numeric;
  v_pct_otros  numeric;
  v_out        jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el calculo de comisiones' USING ERRCODE = '42501';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido';
  END IF;

  v_sucursales := COALESCE(
    p_sucursal_ids,
    ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid())
  );
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    v_sucursales := ARRAY(SELECT id FROM sucursales);
  END IF;

  SELECT COALESCE(MAX(pc.comision_pct_preventista), 2),
         COALESCE(MAX(pc.comision_pct_otros), 0)
    INTO v_pct_prev, v_pct_otros
    FROM politicas_comerciales pc
   WHERE pc.sucursal_id = ANY(v_sucursales);
  v_pct_prev  := COALESCE(v_pct_prev, 2);
  v_pct_otros := COALESCE(v_pct_otros, 0);

  WITH ped AS (
    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id
    FROM pedidos p
    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.sucursal_id = ANY(v_sucursales)
      AND p.usuario_id IN (SELECT id FROM perfiles)
      -- Vale blanco (comprobante VB): consumo interno, no comisiona (migs 309/3XB).
      AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
      -- Consumo de empleado, pagado con adelanto de sueldo: tampoco (3XB).
      AND NOT EXISTS (
        SELECT 1 FROM pagos g
        WHERE g.pedido_id = p.id AND g.forma_pago = 'adelanto_sueldo'
      )
  ),
  it AS (
    SELECT ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal,
           pi.producto_id,
           pi.origen_precio,
           prod.categoria_id,
           perf.rol AS rol_vendedor
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN perfiles perf ON perf.id = ped.usuario_id
    WHERE COALESCE(pi.es_bonificacion, false) = false
  ),
  con_pct AS (
    SELECT it.*,
      COALESCE((
        SELECT r.porcentaje FROM comision_reglas r
        WHERE r.activo
          AND (r.sucursal_id    IS NULL OR r.sucursal_id    = it.sucursal_id)
          AND (r.preventista_id IS NULL OR r.preventista_id = it.usuario_id)
          AND (r.origen_precio  IS NULL OR r.origen_precio  = it.origen_precio)
          AND (r.producto_id    IS NULL OR r.producto_id    = it.producto_id)
          AND (r.categoria_id   IS NULL OR r.categoria_id   = it.categoria_id)
          AND r.vigente_desde <= it.fecha
          AND (r.vigente_hasta IS NULL OR r.vigente_hasta >= it.fecha)
        ORDER BY
          (CASE WHEN r.preventista_id IS NOT NULL THEN 8 ELSE 0 END
         + CASE WHEN r.producto_id    IS NOT NULL THEN 4 ELSE 0 END
         + CASE WHEN r.categoria_id   IS NOT NULL THEN 2 ELSE 0 END
         + CASE WHEN r.origen_precio  IS NOT NULL THEN 1 ELSE 0 END) DESC,
          (r.sucursal_id IS NOT NULL) DESC,
          r.vigente_desde DESC,
          r.id DESC
        LIMIT 1
      ),
      CASE WHEN it.rol_vendedor = 'preventista'
           THEN COALESCE(pc.comision_pct_preventista, 2)
           ELSE COALESCE(pc.comision_pct_otros, 0)
      END) AS pct
    FROM it
    LEFT JOIN politicas_comerciales pc ON pc.sucursal_id = it.sucursal_id
  ),
  por_origen AS (
    SELECT usuario_id,
           COALESCE(origen_precio, 'sin_dato') AS origen,
           SUM(subtotal)                 AS base,
           SUM(subtotal * pct / 100.0)   AS comision,
           COUNT(*)                      AS items
    FROM con_pct
    GROUP BY usuario_id, COALESCE(origen_precio, 'sin_dato')
  ),
  por_preventista AS (
    SELECT c.usuario_id,
           COALESCE(pf.nombre, 'Sin nombre')                                  AS nombre,
           pf.email,
           SUM(c.subtotal)                                                    AS base,
           SUM(c.subtotal * c.pct / 100.0)                                    AS comision,
           COUNT(*)                                                           AS items,
           COUNT(*) FILTER (WHERE c.origen_precio IS NULL)                    AS items_sin_desglose,
           COALESCE(SUM(c.subtotal) FILTER (WHERE c.origen_precio IS NULL),0) AS base_sin_desglose
    FROM con_pct c
    LEFT JOIN perfiles pf ON pf.id = c.usuario_id
    GROUP BY c.usuario_id, pf.nombre, pf.email
  )
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'comision_default', v_pct_prev,
    'comision_pct_preventista', v_pct_prev,
    'comision_pct_otros', v_pct_otros,
    'preventistas', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'base')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'id', pp.usuario_id,
          'nombre', pp.nombre,
          'email', pp.email,
          'base', ROUND(pp.base, 2),
          'comision', ROUND(pp.comision, 2),
          'items', pp.items,
          'items_sin_desglose', pp.items_sin_desglose,
          'base_sin_desglose', ROUND(pp.base_sin_desglose, 2),
          'por_origen', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'origen', po.origen,
              'base', ROUND(po.base, 2),
              'comision', ROUND(po.comision, 2),
              'items', po.items
            ) ORDER BY po.base DESC)
            FROM por_origen po WHERE po.usuario_id = pp.usuario_id
          ), '[]'::jsonb)
        ) AS x
        FROM por_preventista pp
      ) s
    ), '[]'::jsonb),
    'totales', (
      SELECT jsonb_build_object(
        'base', COALESCE(ROUND(SUM(base), 2), 0),
        'comision', COALESCE(ROUND(SUM(comision), 2), 0),
        'items', COALESCE(SUM(items), 0),
        'items_sin_desglose', COALESCE(SUM(items_sin_desglose), 0),
        'base_sin_desglose', COALESCE(ROUND(SUM(base_sin_desglose), 2), 0)
      ) FROM por_preventista
    )
  ) INTO v_out;

  RETURN v_out;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 9 · Rendiciones sin la columna del vale blanco (N12, §3.5 C). 3XA la había
--     dejado devolviendo lo mismo para no romper el front viejo; el front nuevo la
--     lee de forma tolerante y acá desaparece. Cambia el RETURNS TABLE => DROP +
--     CREATE y se repite el grant de la vigente (authenticated + service_role, sin
--     PUBLIC ni anon: Supabase le concede EXECUTE a anon a toda función nueva).
--     `vale_blanco` sale también de los NOT IN de `otros`: con el CHECK del paso 7
--     ya no puede haber un pago así.
--     Escrito sobre la versión de prod + el filtro VB de `entregas_agg` que agrega
--     la 3XA; la precondición verifica el md5 de esa versión (y el de
--     obtener_detalle_rendicion, que nadie toca antes).
-- ---------------------------------------------------------------------------
DROP FUNCTION public.obtener_resumen_rendiciones(date, date, uuid);

CREATE FUNCTION public.obtener_resumen_rendiciones(p_fecha_desde date DEFAULT ((((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date - '30 days'::interval))::date, p_fecha_hasta date DEFAULT ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires'::text))::date, p_transportista_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(fecha date, transportista_id uuid, transportista_nombre text, total_efectivo numeric, total_transferencia numeric, total_cheque numeric, total_cuenta_corriente numeric, total_tarjeta numeric, total_otros numeric, total_adelanto_sueldo numeric, total_general numeric, total_entregas numeric, total_ctascte numeric, cantidad_pedidos bigint, total_entregado numeric, total_gastos numeric, cantidad_gastos bigint, estado text, observaciones text, controlada boolean, controlada_at timestamp with time zone, controlada_por_nombre text, resuelta_at timestamp with time zone, resuelta_por_nombre text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    -- #724: el transportista ve sólo su propia fila (null = yo, como
    -- avance_metas_preventista). es_transportista() incluye admin y rol
    -- extra (trampa 4); el admin ya entró por la rama de arriba.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS NOT NULL AND p_transportista_id <> auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    p_transportista_id := auth.uid();
  END IF;

  RETURN QUERY
  WITH pagos_agg AS (
    SELECT
      COALESCE(pd.transportista_id, pg.usuario_id) AS t_id,
      pg.fecha AS f,
      SUM(CASE WHEN pg.forma_pago = 'efectivo' THEN pg.monto ELSE 0 END)::numeric AS tot_ef,
      SUM(CASE WHEN pg.forma_pago = 'transferencia' THEN pg.monto ELSE 0 END)::numeric AS tot_tr,
      SUM(CASE WHEN pg.forma_pago = 'cheque' THEN pg.monto ELSE 0 END)::numeric AS tot_ch,
      SUM(CASE WHEN pg.forma_pago = 'cuenta_corriente' THEN pg.monto ELSE 0 END)::numeric AS tot_cc,
      SUM(CASE WHEN pg.forma_pago = 'tarjeta' THEN pg.monto ELSE 0 END)::numeric AS tot_tj,
      SUM(CASE WHEN pg.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta')
                OR pg.forma_pago IS NULL THEN pg.monto ELSE 0 END)::numeric AS tot_ot,
      SUM(pg.monto)::numeric AS tot_gen,
      SUM(CASE
        WHEN pg.pedido_id IS NOT NULL
         AND pd.estado = 'entregado'
         AND COALESCE(pd.fecha_entrega::date, pg.fecha) = pg.fecha
        THEN pg.monto ELSE 0 END)::numeric AS tot_entregas,
      SUM(CASE
        WHEN pg.pedido_id IS NULL
          OR pd.estado IS DISTINCT FROM 'entregado'
          OR COALESCE(pd.fecha_entrega::date, pg.fecha) IS DISTINCT FROM pg.fecha
        THEN pg.monto ELSE 0 END)::numeric AS tot_ctascte
    FROM pagos pg
    LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
    WHERE pg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pg.sucursal_id = v_sucursal_id
      -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
      AND COALESCE(pg.forma_pago, '') NOT IN ('adelanto_sueldo', 'nota_credito')
      AND COALESCE(pd.transportista_id, pg.usuario_id) IS NOT NULL
      AND (p_transportista_id IS NULL
           OR COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id)
    GROUP BY COALESCE(pd.transportista_id, pg.usuario_id), pg.fecha
  ),
  /* mig 273 (#832) · informativo: mismo criterio de atribucion que pagos_agg, pero NO
     aporta filas a fechas_activas (ver el encabezado de la migracion). */
  adelantos_agg AS (
    SELECT
      COALESCE(pd.transportista_id, pg.usuario_id) AS t_id,
      pg.fecha AS f,
      SUM(pg.monto)::numeric AS tot_adel
    FROM pagos pg
    LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
    WHERE pg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pg.sucursal_id = v_sucursal_id
      AND pg.forma_pago = 'adelanto_sueldo'
      AND COALESCE(pd.transportista_id, pg.usuario_id) IS NOT NULL
      AND (p_transportista_id IS NULL
           OR COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id)
    GROUP BY COALESCE(pd.transportista_id, pg.usuario_id), pg.fecha
  ),
  entregas_agg AS (
    SELECT
      pd.transportista_id AS t_id,
      pd.fecha_entrega::date AS f,
      SUM(pd.total)::numeric AS tot_entregado,
      COUNT(*)::bigint AS cant
    FROM pedidos pd
    WHERE pd.estado = 'entregado'
      AND pd.fecha_entrega IS NOT NULL
      AND pd.transportista_id IS NOT NULL
      AND pd.fecha_entrega::date BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pd.sucursal_id = v_sucursal_id
      -- 3XA (N12): el vale blanco no es mercadería que el transportista tenga que
      -- rendir. Los 75 VB históricos con transportista salen de lo entregado igual
      -- que su pago sale de lo cobrado, así los dos lados bajan juntos.
      AND COALESCE(pd.tipo_factura, 'ZZ') <> 'VB'
      AND (p_transportista_id IS NULL OR pd.transportista_id = p_transportista_id)
    GROUP BY pd.transportista_id, pd.fecha_entrega::date
  ),
  gastos_agg AS (
    SELECT
      rg.transportista_id AS t_id,
      rg.fecha AS f,
      SUM(rg.monto)::numeric AS tot_g,
      COUNT(*)::bigint AS cant_g
    FROM rendicion_gastos rg
    WHERE rg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND rg.sucursal_id = v_sucursal_id
      AND (p_transportista_id IS NULL OR rg.transportista_id = p_transportista_id)
    GROUP BY rg.transportista_id, rg.fecha
  ),
  /* mig 245 (#639) · fechas_activas es el esqueleto de la grilla. gastos_agg ya
     estaba calculado y LEFT-JOINeado abajo, pero no aportaba filas: un
     transportista que un dia solo cargo gastos --sin cobrar ni entregar-- no
     aparecia, y su rendicion de ese dia era invisible para el control. */
  fechas_activas AS (
    SELECT t_id, f FROM pagos_agg
    UNION
    SELECT t_id, f FROM entregas_agg
    UNION
    SELECT t_id, f FROM gastos_agg
  )
  SELECT
    fa.f::date AS fecha,
    fa.t_id AS transportista_id,
    tr.nombre::text AS transportista_nombre,
    COALESCE(pagos_agg.tot_ef, 0)::numeric AS total_efectivo,
    COALESCE(pagos_agg.tot_tr, 0)::numeric AS total_transferencia,
    COALESCE(pagos_agg.tot_ch, 0)::numeric AS total_cheque,
    COALESCE(pagos_agg.tot_cc, 0)::numeric AS total_cuenta_corriente,
    COALESCE(pagos_agg.tot_tj, 0)::numeric AS total_tarjeta,
    COALESCE(pagos_agg.tot_ot, 0)::numeric AS total_otros,
    COALESCE(adelantos_agg.tot_adel, 0)::numeric AS total_adelanto_sueldo,
    COALESCE(pagos_agg.tot_gen, 0)::numeric AS total_general,
    COALESCE(pagos_agg.tot_entregas, 0)::numeric AS total_entregas,
    COALESCE(pagos_agg.tot_ctascte, 0)::numeric AS total_ctascte,
    COALESCE(entregas_agg.cant, 0)::bigint AS cantidad_pedidos,
    COALESCE(entregas_agg.tot_entregado, 0)::numeric AS total_entregado,
    COALESCE(gastos_agg.tot_g, 0)::numeric AS total_gastos,
    COALESCE(gastos_agg.cant_g, 0)::bigint AS cantidad_gastos,
    COALESCE(rc.estado, 'pendiente')::text AS estado,
    rc.observaciones,
    (rc.id IS NOT NULL AND COALESCE(rc.estado, 'pendiente') IN ('confirmada','resuelta')) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre,
    rc.resuelta_at,
    rp.nombre::text AS resuelta_por_nombre
  FROM fechas_activas fa
  JOIN perfiles tr ON tr.id = fa.t_id
  LEFT JOIN pagos_agg ON pagos_agg.t_id = fa.t_id AND pagos_agg.f = fa.f
  LEFT JOIN adelantos_agg ON adelantos_agg.t_id = fa.t_id AND adelantos_agg.f = fa.f
  LEFT JOIN entregas_agg ON entregas_agg.t_id = fa.t_id AND entregas_agg.f = fa.f
  LEFT JOIN gastos_agg ON gastos_agg.t_id = fa.t_id AND gastos_agg.f = fa.f
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = fa.f
   AND rc.transportista_id = fa.t_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  LEFT JOIN perfiles rp ON rp.id = rc.resuelta_por
  ORDER BY fa.f DESC, tr.nombre ASC;
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO authenticated, service_role;


DROP FUNCTION public.obtener_detalle_rendicion(date, uuid);

CREATE FUNCTION public.obtener_detalle_rendicion(p_fecha date, p_transportista_id uuid)
 RETURNS TABLE(cliente_id bigint, cliente_nombre text, cobrado_por_id uuid, cobrado_por text, total numeric, total_entregas numeric, total_ctascte numeric, efectivo numeric, transferencia numeric, cheque numeric, tarjeta numeric, cuenta_corriente numeric, otros numeric, cantidad_pagos bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    -- #724: el transportista sólo abre su propia rendición.
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    pg.cliente_id::bigint AS cliente_id,
    COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente #' || pg.cliente_id)::text AS cliente_nombre,
    pg.usuario_id AS cobrado_por_id,
    COALESCE(u.nombre, 'Sin usuario')::text AS cobrado_por,
    SUM(pg.monto)::numeric AS total,
    SUM(CASE
      WHEN pg.pedido_id IS NOT NULL
       AND pd.estado = 'entregado'
       AND COALESCE(pd.fecha_entrega::date, pg.fecha) = pg.fecha
      THEN pg.monto ELSE 0 END)::numeric AS total_entregas,
    SUM(CASE
      WHEN pg.pedido_id IS NULL
        OR pd.estado IS DISTINCT FROM 'entregado'
        OR COALESCE(pd.fecha_entrega::date, pg.fecha) IS DISTINCT FROM pg.fecha
      THEN pg.monto ELSE 0 END)::numeric AS total_ctascte,
    SUM(CASE WHEN pg.forma_pago = 'efectivo' THEN pg.monto ELSE 0 END)::numeric AS efectivo,
    SUM(CASE WHEN pg.forma_pago = 'transferencia' THEN pg.monto ELSE 0 END)::numeric AS transferencia,
    SUM(CASE WHEN pg.forma_pago = 'cheque' THEN pg.monto ELSE 0 END)::numeric AS cheque,
    SUM(CASE WHEN pg.forma_pago = 'tarjeta' THEN pg.monto ELSE 0 END)::numeric AS tarjeta,
    SUM(CASE WHEN pg.forma_pago = 'cuenta_corriente' THEN pg.monto ELSE 0 END)::numeric AS cuenta_corriente,
    SUM(CASE WHEN pg.forma_pago NOT IN ('efectivo','transferencia','cheque','tarjeta','cuenta_corriente')
              OR pg.forma_pago IS NULL THEN pg.monto ELSE 0 END)::numeric AS otros,
    COUNT(*)::bigint AS cantidad_pagos
  FROM pagos pg
  LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
  LEFT JOIN clientes c ON c.id = pg.cliente_id
  LEFT JOIN perfiles u ON u.id = pg.usuario_id
  WHERE pg.fecha = p_fecha
    AND pg.sucursal_id = v_sucursal_id
    -- migs 273/276 (#832, #833): las formas no dinerarias no son plata de la rendicion.
    AND COALESCE(pg.forma_pago, '') NOT IN ('adelanto_sueldo', 'nota_credito')
    AND COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id
  GROUP BY pg.cliente_id, c.nombre_fantasia, c.razon_social, pg.usuario_id, u.nombre
  ORDER BY SUM(pg.monto) DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_detalle_rendicion(date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_detalle_rendicion(date, uuid) TO authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 10 · El ensayo. Foto "después" y comparación contra la de "antes".
--
--   Rendiciones: cada fila (sucursal, transportista/cobrador, día) tiene que
--   moverse EXACTAMENTE lo que explican los vales (`_vb_delta`): total_general
--   baja lo que sumaban sus pagos VB, total_entregado y cantidad_pedidos bajan lo
--   que sumaban sus pedidos VB a lista. Ninguna otra fila puede cambiar. Una fila
--   sólo puede desaparecer si toda su actividad eran vales (al escribir: 29 cajas
--   cerradas así, 28 de Jony/Pablo y 1 del transportista; el control
--   NO se borra, sólo deja de verse en la grilla porque `fechas_activas` sale de
--   pagos, entregas y gastos).
--
--   Cajas cerradas: en las del transportista (pago VB el mismo día que la entrega)
--   cobrado y entregado bajan juntos y la diferencia no cambia (17 al escribir).
--   PERO los vales de pedidos SIN transportista se atribuían al que los cargaba
--   (pagos_agg: COALESCE(transportista, cobrador)), y en sus cajas cerradas eran
--   "cobrado sobre entregado" sin contrapartida: al irse el vale, la diferencia de
--   esas cajas baja. Al escribir son 44 cajas cerradas que siguen visibles (de Jony
--   y Pablo) con −$5.965.290 en total. La especificación pedía diferencia igual en
--   toda caja controlada y eso no es posible con estos datos: queda frenado por
--   `v_acepta_cajas_cerradas` hasta que el dueño decida (PREGUNTA PARA EL DUEÑO).
-- ---------------------------------------------------------------------------
SELECT pg_temp._vb_foto('despues');

DO $ensayo$
DECLARE
  -- PREGUNTA PARA EL DUEÑO: ¿se acepta que la diferencia (cobrado − entregado) de
  -- cajas YA CERRADAS cambie, porque el vale blanco que contaban como cobrado sin
  -- entrega deja de ser plata? En false, la migración no entra si pasa.
  -- Medido por la revisión (2026-10-08): los pagos VB de pedidos SIN
  -- transportista caen en 72 pares (cobrador, día) con control confirmado o
  -- resuelto, por $9.742.390 (unos 29 dejan de verse en la grilla y 44 cambian
  -- su diferencia). Los buckets de plata (efectivo, transferencia, ...) no se
  -- mueven: sólo "cobrado". Hoy, con este flag en false, la C NO ENTRA.
  v_acepta_cajas_cerradas CONSTANT boolean := false;

  v_fallas       text := '';
  v_cerradas     text := '';
  v_n_cerradas   int := 0;
  v_sum_cerradas numeric := 0;
  v_desaparecen  int := 0;
  v_desap_cerr   int := 0;
  v_r            record;
  v_n            int;
  v_sum_total    numeric;
  v_sum_redondeo numeric;
  v_sum_exacto   numeric;
  v_sum_cant     numeric;
  v_ant          jsonb;
  v_des          jsonb;
BEGIN
  -- ===== Datos del universo =====
  SELECT count(*) INTO v_n
    FROM _vb_universo u JOIN pedidos p ON p.id = u.pedido_id
   WHERE p.tipo_factura IS DISTINCT FROM 'VB'
      OR p.estado IS DISTINCT FROM 'entregado'
      OR p.estado_pago IS DISTINCT FROM 'pagado'
      OR p.monto_pagado IS DISTINCT FROM p.total
      OR COALESCE(p.total_iva, 0) <> 0
      OR p.total_neto IS DISTINCT FROM p.total
      OR p.total_real IS DISTINCT FROM p.total
      OR p.forma_pago = 'vale_blanco'
      -- B4: nada que dispare trg_pedidos_anular_control.
      OR p.transportista_id IS DISTINCT FROM u.transportista_id
      OR p.fecha_entrega IS DISTINCT FROM u.fecha_entrega
      OR p.orden_entrega IS DISTINCT FROM u.orden_entrega
      OR abs(p.total - (SELECT COALESCE(SUM(pi.subtotal), 0) FROM pedido_items pi WHERE pi.pedido_id = p.id)) > 0.001;
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s pedidos del universo no quedaron como VB coherente]', v_n);
  END IF;

  SELECT count(*) INTO v_n
    FROM pedido_items pi JOIN _vb_lineas l ON l.id = pi.id
   WHERE pi.precio_unitario IS DISTINCT FROM l.precio
      OR pi.subtotal IS DISTINCT FROM pi.cantidad * l.precio
      OR pi.origen_precio IS DISTINCT FROM 'costo_interno'
      OR COALESCE(pi.es_bonificacion, false)
      OR pi.costo_unitario_al_crear IS NULL
      OR COALESCE(pi.iva_unitario, 0) <> 0
      OR pi.neto_unitario IS DISTINCT FROM pi.precio_unitario
      OR pi.ingreso_real_unitario IS DISTINCT FROM pi.precio_unitario;
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s líneas no quedaron a costo con desglose VB]', v_n);
  END IF;

  SELECT count(*) INTO v_n FROM pagos g
   WHERE g.pedido_id IN (SELECT pedido_id FROM _vb_universo);
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s pagos siguen colgando de pedidos VB]', v_n);
  END IF;
  SELECT count(*) INTO v_n FROM pagos WHERE forma_pago = 'vale_blanco';
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s pagos vale_blanco]', v_n);
  END IF;
  SELECT count(*) INTO v_n FROM pedidos WHERE forma_pago = 'vale_blanco';
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s pedidos con forma_pago vale_blanco]', v_n);
  END IF;
  SELECT count(*) INTO v_n FROM clientes
   WHERE id IN (440, 455, 456, 591, 666) AND tipo_factura_default IS DISTINCT FROM 'VB';
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s clientes internos sin VB por defecto]', v_n);
  END IF;
  SELECT count(*) INTO v_n FROM pagos
   WHERE id IN (SELECT id FROM _vb_pagos WHERE cliente_id = 376)
     AND forma_pago IS DISTINCT FROM 'adelanto_sueldo';
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s pagos de Federico no pasaron a adelanto_sueldo]', v_n);
  END IF;
  SELECT count(*) INTO v_n FROM _vb_universo u
   WHERE NOT EXISTS (SELECT 1 FROM pedido_historial h
                      WHERE h.pedido_id = u.pedido_id AND h.campo_modificado = 'tipo_factura'
                        AND h.valor_nuevo LIKE 'VB%');
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s pedidos sin la fila de historial tipo_factura]', v_n);
  END IF;

  -- Σ consumo interno = Σ costo de las líneas. Contra el costo redondeado, exacto;
  -- contra el costo sin redondear, medio centavo por unidad (precio es numeric(10,2)).
  SELECT SUM(p.total) INTO v_sum_total
    FROM pedidos p WHERE p.id IN (SELECT pedido_id FROM _vb_universo);
  SELECT SUM(cantidad * precio), SUM(cantidad * costo), SUM(cantidad)
    INTO v_sum_redondeo, v_sum_exacto, v_sum_cant
    FROM _vb_lineas;
  IF v_sum_total IS DISTINCT FROM v_sum_redondeo
     OR abs(v_sum_total - v_sum_exacto) > 0.005 * v_sum_cant + 0.01 THEN
    v_fallas := v_fallas || format(' [Σ total VB %s no cierra con Σ costo de las líneas %s (sin redondear %s)]',
                                   v_sum_total, v_sum_redondeo, round(v_sum_exacto, 4));
  END IF;

  -- ===== Saldos: los 5 internos en 0 y sin moverse; Federico sin moverse =====
  FOR v_r IN
    SELECT a.clave, a.valor AS antes, d.valor AS despues
      FROM _vb_foto a
      LEFT JOIN _vb_foto d ON d.etapa = 'despues' AND d.clave = a.clave
     WHERE a.etapa = 'antes' AND a.clave LIKE 'saldo:%'
  LOOP
    IF v_r.despues IS DISTINCT FROM v_r.antes THEN
      v_fallas := v_fallas || format(' [%s: %s -> %s]', v_r.clave, v_r.antes, v_r.despues);
    END IF;
    IF v_r.clave <> 'saldo:376' AND (v_r.despues)::text::numeric <> 0 THEN
      v_fallas := v_fallas || format(' [%s quedó en %s, tenía que ser 0]', v_r.clave, v_r.despues);
    END IF;
  END LOOP;

  -- ===== Comisiones: idénticas (antes las sacaba el pago VB, ahora el tipo VB y el adelanto) =====
  SELECT valor INTO v_ant FROM _vb_foto WHERE etapa = 'antes'   AND clave = 'comisiones';
  SELECT valor INTO v_des FROM _vb_foto WHERE etapa = 'despues' AND clave = 'comisiones';
  -- Por vendedor y no el jsonb entero: `preventistas` y `por_origen` vienen
  -- ordenados por base, y un empate podría invertir el orden sin que cambie nada.
  IF (v_ant->'totales') IS DISTINCT FROM (v_des->'totales') THEN
    v_fallas := v_fallas || format(' [calcular_comisiones cambió: totales %s -> %s]',
                                   v_ant->'totales', v_des->'totales');
  END IF;
  SELECT count(*) INTO v_n FROM (
    (SELECT x->>'id', x->>'base', x->>'comision', x->>'items'
       FROM jsonb_array_elements(v_ant->'preventistas') x
     EXCEPT
     SELECT x->>'id', x->>'base', x->>'comision', x->>'items'
       FROM jsonb_array_elements(v_des->'preventistas') x)
    UNION ALL
    (SELECT x->>'id', x->>'base', x->>'comision', x->>'items'
       FROM jsonb_array_elements(v_des->'preventistas') x
     EXCEPT
     SELECT x->>'id', x->>'base', x->>'comision', x->>'items'
       FROM jsonb_array_elements(v_ant->'preventistas') x)
  ) dif;
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [calcular_comisiones cambió para %s vendedores]', v_n);
  END IF;

  -- ===== rendiciones_control: ninguno se borró ni cambió de estado =====
  SELECT valor INTO v_ant FROM _vb_foto WHERE etapa = 'antes'   AND clave = 'rendiciones_control';
  SELECT valor INTO v_des FROM _vb_foto WHERE etapa = 'despues' AND clave = 'rendiciones_control';
  IF v_ant IS DISTINCT FROM v_des THEN
    v_fallas := v_fallas || ' [rendiciones_control cambió: se borró o se modificó un control]';
  END IF;

  -- ===== auditoria_integridad: ningún check empeora y la familia VB- en 0 =====
  FOR v_r IN
    SELECT d.check_id, d.severidad, COALESCE(a.violaciones, 0) AS antes, d.violaciones AS despues
      FROM _vb_audit d
      LEFT JOIN _vb_audit a ON a.etapa = 'antes' AND a.check_id = d.check_id
     WHERE d.etapa = 'despues'
       AND (d.violaciones > COALESCE(a.violaciones, 0)
            OR (d.check_id LIKE 'VB-%' AND d.violaciones > 0))
  LOOP
    v_fallas := v_fallas || format(' [auditoria %s (%s): %s -> %s]',
                                   v_r.check_id, v_r.severidad, v_r.antes, v_r.despues);
  END LOOP;

  -- ===== Rendiciones: cada fila se mueve exactamente lo que explican los vales =====
  -- Toda clave con vales tiene que haber estado en la grilla de antes (si no, el
  -- rango de la foto quedó corto y el ensayo no vería nada).
  SELECT count(*) INTO v_n
    FROM _vb_delta dl
   WHERE EXISTS (SELECT 1 FROM perfiles pf WHERE pf.id = dl.transportista_id)
     AND NOT EXISTS (SELECT 1 FROM _vb_rend a
                      WHERE a.etapa = 'antes' AND a.sucursal_id = dl.sucursal_id
                        AND a.transportista_id = dl.transportista_id AND a.fecha = dl.fecha);
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s filas con vales no aparecían en la foto de antes]', v_n);
  END IF;

  FOR v_r IN
    SELECT a.sucursal_id, a.fecha, a.transportista_id, a.controlada, a.total_gastos,
           a.total_general   AS gen_a,  a.total_entregado AS ent_a,  a.cantidad_pedidos AS cant_a,
           a.total_general   - COALESCE(dl.g, 0) AS gen_esp,
           a.total_entregado - COALESCE(dl.e, 0) AS ent_esp,
           a.cantidad_pedidos - COALESCE(dl.n, 0) AS cant_esp,
           d.total_general   AS gen_d,  d.total_entregado AS ent_d,  d.cantidad_pedidos AS cant_d,
           d.total_gastos    AS gastos_d,
           (d.sucursal_id IS NOT NULL) AS sigue
      FROM _vb_rend a
      LEFT JOIN _vb_delta dl
        ON dl.sucursal_id = a.sucursal_id AND dl.transportista_id = a.transportista_id AND dl.fecha = a.fecha
      LEFT JOIN _vb_rend d
        ON d.etapa = 'despues' AND d.sucursal_id = a.sucursal_id
       AND d.transportista_id = a.transportista_id AND d.fecha = a.fecha
     WHERE a.etapa = 'antes'
  LOOP
    IF NOT v_r.sigue THEN
      IF v_r.gen_esp <> 0 OR v_r.ent_esp <> 0 OR v_r.cant_esp <> 0 OR v_r.total_gastos <> 0 THEN
        v_fallas := v_fallas || format(' [rendición %s %s suc %s desapareció y tenía actividad que no era vale]',
                                       v_r.fecha, v_r.transportista_id, v_r.sucursal_id);
      END IF;
      v_desaparecen := v_desaparecen + 1;
      IF v_r.controlada THEN v_desap_cerr := v_desap_cerr + 1; END IF;
    ELSE
      IF v_r.gen_d <> v_r.gen_esp OR v_r.ent_d <> v_r.ent_esp OR v_r.cant_d <> v_r.cant_esp
         OR v_r.gastos_d <> v_r.total_gastos THEN
        v_fallas := v_fallas || format(
          ' [rendición %s %s suc %s: general %s->%s (esperado %s), entregado %s->%s (esperado %s), pedidos %s->%s (esperado %s)]',
          v_r.fecha, v_r.transportista_id, v_r.sucursal_id,
          v_r.gen_a, v_r.gen_d, v_r.gen_esp, v_r.ent_a, v_r.ent_d, v_r.ent_esp,
          v_r.cant_a, v_r.cant_d, v_r.cant_esp);
      ELSIF v_r.controlada AND (v_r.gen_d - v_r.ent_d) <> (v_r.gen_a - v_r.ent_a) THEN
        v_n_cerradas   := v_n_cerradas + 1;
        v_sum_cerradas := v_sum_cerradas + ((v_r.gen_d - v_r.ent_d) - (v_r.gen_a - v_r.ent_a));
        IF v_n_cerradas <= 10 THEN
          v_cerradas := v_cerradas || format(' [%s %s: %s -> %s]', v_r.fecha, v_r.transportista_id,
                                             v_r.gen_a - v_r.ent_a, v_r.gen_d - v_r.ent_d);
        END IF;
      END IF;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_n
    FROM _vb_rend d
   WHERE d.etapa = 'despues'
     AND NOT EXISTS (SELECT 1 FROM _vb_rend a
                      WHERE a.etapa = 'antes' AND a.sucursal_id = d.sucursal_id
                        AND a.transportista_id = d.transportista_id AND a.fecha = d.fecha);
  IF v_n > 0 THEN
    v_fallas := v_fallas || format(' [%s filas de rendición nuevas que antes no estaban]', v_n);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig vb · el ensayo no cierra:%', v_fallas;
  END IF;

  IF v_n_cerradas > 0 AND NOT v_acepta_cajas_cerradas THEN
    RAISE EXCEPTION 'mig vb · % cajas YA CERRADAS cambian su diferencia (cobrado − entregado) en % en total: eran vales cobrados sin entrega. Si el dueño lo acepta, poner v_acepta_cajas_cerradas := true. Primeras:%',
      v_n_cerradas, v_sum_cerradas, v_cerradas;
  END IF;

  RAISE NOTICE 'mig vb · OK: % pedidos a VB por $% (a lista eran $%), % filas de rendición dejan de verse (% con caja cerrada; los controles siguen), % cajas cerradas cambian su diferencia en $%',
    (SELECT count(*) FROM _vb_universo), v_sum_total,
    (SELECT SUM(total_antes) FROM _vb_universo),
    v_desaparecen, v_desap_cerr, v_n_cerradas, v_sum_cerradas;
END
$ensayo$;

DROP FUNCTION pg_temp._vb_foto(text);

COMMIT;
