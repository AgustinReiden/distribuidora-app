-- La venta del vendedor tiene una sola definicion
--
-- EL PROBLEMA
-- -----------
-- "Cuanto vendio Fulano" se contestaba de CUATRO formas distintas, segun que
-- pantalla abrieras, y ninguna era la canonica (#568, #569):
--
--   · reporte_ventas_por_preventista (208) · estado <> 'cancelado', SIN filtro
--     de canal, SUM(pedidos.total). Cuenta pendientes y en camino.
--   · reporte_gerencial (130)              · estado = 'entregado', canal='app',
--     SUM(pedido_items.subtotal).
--   · calcular_comisiones (207)            · estado <> 'cancelado', canal='app'.
--   · bot_ranking_preventistas_por_producto (026) · estado NOT IN
--     ('cancelado','anulado'), sin canal.
--
-- Y el canal partia el universo en dos mitades incoherentes: un pedido tomado
-- por el bot de Telegram (`canal = 'bot'`, crear_pedido_completo_bot, mig 132)
-- no sumaba al gerencial, no comisionaba y ni siquiera bot_mis_ventas se lo
-- contaba al preventista que lo habia cargado, mientras que /reportes y
-- jornadas_preventista (179) si lo contaban. El mismo preventista, la misma
-- mercaderia, dos respuestas.
--
-- LA DECISION (D-1 del plan de auditoria 2026-09-11, tomada por el dueno)
-- ----------------------------------------------------------------------
-- La venta de un vendedor es:
--
--     estado = 'entregado'            -- se reconoce cuando la mercaderia salio
--     AND canal <> 'cambio'           -- todo canal de VENTA: 'app' y 'bot'
--     por pedidos.fecha               -- nunca created_at
--     atribuida a pedidos.usuario_id  -- quien la cargo (mig 219)
--
-- Las tres partes, una por una:
--
--   · ENTREGADA, no comprometida. La comision se devenga con la entrega, no con
--     la carga del pedido. Medido contra prod antes de aplicar: en los OCHO
--     meses cerrados de 2026 las dos definiciones dan diferencia EXACTA 0.00,
--     porque un pedido termina entregado o cancelado y `cancelar_pedido` pone
--     total = 0 (mig 175). O sea: esto NO cambia ninguna comision ya liquidada.
--     Lo unico que cambia es el periodo ABIERTO, que es justamente donde la
--     venta todavia no es venta.
--
--   · `canal <> 'cambio'` y no `canal = 'app'`. El dominio de canal es
--     exactamente ('app','cambio','bot') --lo fija el check VENTA-D de
--     auditoria_integridad--, y 'cambio' no es una venta: es la comanda de un
--     canje, que por el invariante CAMBIO-01 tiene total = 0. Escrito en
--     negativo, el canal que venga despues cuenta solo: una venta nueva no
--     tiene que acordarse de pasar por aca para existir. Es la forma que ya
--     usaba jornadas_preventista (179), que por eso NO se toca en esta
--     migracion: era la unica que ya estaba del lado correcto.
--
--   · `pedidos.fecha`, no `created_at`. Cierra #569: reporte_rentabilidad era
--     el unico que filtraba por fecha de CARGA, asi que no cerraba contra
--     ningun otro reporte, y encima cortaba el dia a medianoche UTC.
--
-- QUE SE TOCA
-- -----------
-- Once funciones, con parches por ancla sobre el cuerpo VIVO (migrations/ es
-- vista curada, no espejo). Ocho son las que nombra el issue; las otras tres
-- entran porque contestan la MISMA pregunta y dejarlas afuera haria falsa la
-- premisa de esta migracion:
--
--   · avance_metas_preventista (160) y rendimiento_preventistas · son venta por
--     vendedor con otro nombre: el avance de metas y el panel de rendimiento.
--   · reporte_alerta_detalle (109) · su propio comentario dice "mismos estados,
--     mismo canal y mismo predicado que el KPI". Si se mueve el KPI y no el
--     detalle, la lista detras de la alerta deja de sumar el numero de la
--     alerta: es exactamente el bug que la 238 acaba de arreglar para mermas.
--
-- QUE NO SE TOCA, A PROPOSITO
-- ---------------------------
--   · jornadas_preventista (179) · ya usa `canal <> 'cambio'`. Ver arriba.
--   · posicion_fiscal · tambien filtra canal='app', pero la posicion fiscal es
--     otra pregunta (que se facturo, no quien vendio) y moverla es una decision
--     impositiva, no de reporting comercial. Queda en issue.
--   · auditoria_integridad · cuatro de sus checks estan acotados a canal='app'.
--     Ampliarlos puede poner un gate en rojo y merece su propia migracion.
--     Queda en issue.
--   · El redondeo del costo (la 130 no redondea, la 208 si): lo resolvio la
--     funcion compartida costo_valuacion de la 238. No se toca.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · El andamio: cirugia por ancla sobre el cuerpo vivo.
--     Mismo helper que usan la 229, la 236 y la 240. Falla si el ancla no
--     aparece exactamente una vez: si otra sesion cambio el cuerpo, esta
--     migracion no entra a medias.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._migvc_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · reporte_ventas_por_preventista · "Por Preventista" de /reportes.
--
--     Era la mas lejana de la definicion: contaba pendientes y en camino, y no
--     miraba el canal. Ademas devolvia tres contadores de pipeline
--     --pedidosPendientes, pedidosAsignados, pedidosEntregados-- que con el
--     universo acotado a entregados quedan en 0, 0 y "todos". Un cero que
--     significa "no aplica" se lee como "no hay ninguno", asi que se van: no los
--     renderiza ninguna pantalla (el unico consumidor es
--     useMetricasQuery.calcularReportePreventistas, que hace passthrough).
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.reporte_ventas_por_preventista(date, date, bigint)'::regprocedure;
BEGIN
  PERFORM public._migvc_ancla(v_fn,
$ancla$    WHERE p.estado <> 'cancelado'
      AND p.sucursal_id = ANY(v_sucursales)$ancla$,
$nuevo$    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      AND p.sucursal_id = ANY(v_sucursales)$nuevo$);

  PERFORM public._migvc_ancla(v_fn,
$ancla$           SUM(GREATEST(0, ped.total - ped.monto_pagado))  AS total_pendiente,
           COUNT(*) FILTER (WHERE ped.estado = 'pendiente') AS pedidos_pendientes,
           COUNT(*) FILTER (WHERE ped.estado = 'asignado')  AS pedidos_asignados,
           COUNT(*) FILTER (WHERE ped.estado = 'entregado') AS pedidos_entregados
    FROM ped GROUP BY ped.usuario_id$ancla$,
$nuevo$           SUM(GREATEST(0, ped.total - ped.monto_pagado))  AS total_pendiente
    FROM ped GROUP BY ped.usuario_id$nuevo$);

  PERFORM public._migvc_ancla(v_fn,
$ancla$      'totalPendiente',    ROUND(pu.total_pendiente,2),
      'pedidosPendientes', pu.pedidos_pendientes,
      'pedidosAsignados',  pu.pedidos_asignados,
      'pedidosEntregados', pu.pedidos_entregados
    ) ORDER BY pu.total_ventas DESC)$ancla$,
$nuevo$      'totalPendiente',    ROUND(pu.total_pendiente,2)
    ) ORDER BY pu.total_ventas DESC)$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · reporte_gerencial · cinco anclas.
--
--     `ped` es el universo del reporte; `nc` es la base de comision simulada y
--     tiene que mirar lo mismo que calcular_comisiones; `k_nuevos` y las dos
--     alertas (cobranza vencida, clientes inactivos) recortaban el canal por su
--     cuenta. `p_incluir_no_entregados` se queda: es un toggle explicito del
--     usuario para mirar el pipeline, no una definicion de venta.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure := 'public.reporte_gerencial(bigint, date, date, boolean, boolean)'::regprocedure;
BEGIN
  PERFORM public._migvc_ancla(v_fn,
$ancla$    FROM pedidos WHERE estado = ANY(v_estados) AND canal='app'$ancla$,
$nuevo$    FROM pedidos WHERE estado = ANY(v_estados) AND canal <> 'cambio'$nuevo$);

  PERFORM public._migvc_ancla(v_fn,
$ancla$    WHERE estado<>'cancelado' AND canal='app'$ancla$,
$nuevo$    WHERE estado='entregado' AND canal <> 'cambio'$nuevo$);

  PERFORM public._migvc_ancla(v_fn,
$ancla$      WHERE estado='entregado' AND sucursal_id = ANY(v_sucursales) GROUP BY cliente_id$ancla$,
$nuevo$      WHERE estado='entregado' AND canal <> 'cambio' AND sucursal_id = ANY(v_sucursales) GROUP BY cliente_id$nuevo$);

  PERFORM public._migvc_ancla(v_fn,
$ancla$  WHERE estado='entregado' AND canal='app' AND sucursal_id = ANY(v_sucursales)
    AND COALESCE(estado_pago,'pendiente') IN ('pendiente','parcial')$ancla$,
$nuevo$  WHERE estado='entregado' AND canal <> 'cambio' AND sucursal_id = ANY(v_sucursales)
    AND COALESCE(estado_pago,'pendiente') IN ('pendiente','parcial')$nuevo$);

  PERFORM public._migvc_ancla(v_fn,
$ancla$    WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)$ancla$,
$nuevo$    WHERE p.estado='entregado' AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · calcular_comisiones · lo que se liquida.
--
--     Pasa de "comprometida" a "entregada". En los ocho meses cerrados de 2026
--     la diferencia medida es 0.00, asi que ninguna liquidacion pasada cambia;
--     de aca en mas, la comision se devenga con la entrega.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migvc_ancla('public.calcular_comisiones(date, date, bigint[])'::regprocedure,
$ancla$    WHERE p.estado <> 'cancelado'
      AND p.canal = 'app'$ancla$,
$nuevo$    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · Las cuatro RPCs del bot.
--
--     Las tres de venta ya contaban solo entregados: lo unico que les faltaba
--     era dejar de excluir al propio canal del bot. `bot_ranking_...` ademas
--     contaba no-cancelados, que era la CUARTA definicion.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_periodo regprocedure := 'public.bot_ventas_periodo(date, date, bigint, integer)'::regprocedure;
BEGIN
  PERFORM public._migvc_ancla(v_periodo,
$ancla$      AND estado = 'entregado' AND canal = 'app'$ancla$,
$nuevo$      AND estado = 'entregado' AND canal <> 'cambio'$nuevo$);

  -- El CTE `en_curso` mira el pipeline, no la venta, pero el canal es el mismo.
  PERFORM public._migvc_ancla(v_periodo,
$ancla$      AND canal = 'app'
      AND COALESCE(estado, '') IN ('asignado', 'pendiente')$ancla$,
$nuevo$      AND canal <> 'cambio'
      AND COALESCE(estado, '') IN ('asignado', 'pendiente')$nuevo$);

  PERFORM public._migvc_ancla('public.bot_mis_ventas(uuid, date, date, bigint, integer)'::regprocedure,
$ancla$      AND p.estado = 'entregado' AND p.canal = 'app'$ancla$,
$nuevo$      AND p.estado = 'entregado' AND p.canal <> 'cambio'$nuevo$);

  PERFORM public._migvc_ancla('public.bot_ventas_por_preventista(date, date, bigint, boolean, integer)'::regprocedure,
$ancla$      AND p.estado = 'entregado' AND p.canal = 'app'$ancla$,
$nuevo$      AND p.estado = 'entregado' AND p.canal <> 'cambio'$nuevo$);

  PERFORM public._migvc_ancla('public.bot_ranking_preventistas_por_producto(bigint[], date, date, bigint, integer)'::regprocedure,
$ancla$      AND COALESCE(p.estado, '') NOT IN ('cancelado', 'anulado')$ancla$,
$nuevo$      AND p.estado = 'entregado'
      AND p.canal <> 'cambio'$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · reporte_rentabilidad · #569.
--
--     Unico reporte que filtraba por created_at. Pasa a pedidos.fecha, que de
--     paso mata el corte de dia a medianoche UTC (el `::timestamp` comparaba un
--     timestamptz contra la medianoche de Greenwich, no la de aca).
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migvc_ancla('public.reporte_rentabilidad(date, date, bigint)'::regprocedure,
$ancla$    WHERE p.estado <> 'cancelado'
      AND p.sucursal_id = ANY(v_sucursales)
      AND (p_desde IS NULL OR p.created_at >= p_desde::timestamp)
      AND (p_hasta IS NULL OR p.created_at < (p_hasta + 1)::timestamp)$ancla$,
$nuevo$    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      AND p.sucursal_id = ANY(v_sucursales)
      AND (p_desde IS NULL OR p.fecha >= p_desde)
      AND (p_hasta IS NULL OR p.fecha <= p_hasta)$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · Las tres que contestan la misma pregunta con otro nombre.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_metas  regprocedure := 'public.avance_metas_preventista(uuid, date)'::regprocedure;
  v_rend   regprocedure := 'public.rendimiento_preventistas(bigint, date)'::regprocedure;
  v_alerta regprocedure := 'public.reporte_alerta_detalle(bigint, text, date, date, boolean)'::regprocedure;
BEGIN
  PERFORM public._migvc_ancla(v_metas,
$ancla$      AND estado = 'entregado'
      AND canal = 'app'$ancla$,
$nuevo$      AND estado = 'entregado'
      AND canal <> 'cambio'$nuevo$);

  PERFORM public._migvc_ancla(v_metas,
$ancla$    WHERE p.estado = 'entregado' AND p.canal = 'app'$ancla$,
$nuevo$    WHERE p.estado = 'entregado' AND p.canal <> 'cambio'$nuevo$);

  PERFORM public._migvc_ancla(v_rend,
$ancla$    WHERE estado = 'entregado' AND canal = 'app'$ancla$,
$nuevo$    WHERE estado = 'entregado' AND canal <> 'cambio'$nuevo$);

  PERFORM public._migvc_ancla(v_rend,
$ancla$    WHERE p.estado = 'entregado' AND p.canal = 'app'$ancla$,
$nuevo$    WHERE p.estado = 'entregado' AND p.canal <> 'cambio'$nuevo$);

  -- Las dos primeras anclas de reporte_alerta_detalle comparten la linea del
  -- WHERE: se desambiguan con la linea de abajo.
  PERFORM public._migvc_ancla(v_alerta,
$ancla$      WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
        AND COALESCE(p.estado_pago,'pendiente') IN ('pendiente','parcial')$ancla$,
$nuevo$      WHERE p.estado='entregado' AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)
        AND COALESCE(p.estado_pago,'pendiente') IN ('pendiente','parcial')$nuevo$);

  PERFORM public._migvc_ancla(v_alerta,
$ancla$      WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
      GROUP BY c.id, c.nombre_fantasia, c.razon_social$ancla$,
$nuevo$      WHERE p.estado='entregado' AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)
      GROUP BY c.id, c.nombre_fantasia, c.razon_social$nuevo$);

  PERFORM public._migvc_ancla(v_alerta,
$ancla$      WHERE p.estado = ANY(v_estados) AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)$ancla$,
$nuevo$      WHERE p.estado = ANY(v_estados) AND p.canal <> 'cambio' AND p.sucursal_id = ANY(v_sucursales)$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 7 · El ensayo: las cuatro pantallas tienen que dar el MISMO numero.
--
--     Se corre contra los datos reales del ultimo mes cerrado, por sucursal, y
--     compara vendedor por vendedor las cuatro definiciones que el issue #568
--     enumeraba como distintas. Si alguna se despega, la migracion no entra.
--
--     calcular_comisiones exige es_admin(), asi que el ensayo se hace pasar por
--     un admin con todas las sucursales (set_config local: se descarta al
--     COMMIT).
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_admin  uuid;
  v_desde  date;
  v_hasta  date;
  v_suc    bigint;
  v_fallas text := '';
  v_fila   record;
  v_rg     jsonb;
  v_rent   jsonb;
  v_comp   int := 0;
BEGIN
  -- El admin con mas sucursales ACTIVAS asignadas. Las inactivas no entran:
  -- reporte_gerencial consolida sobre `sucursales WHERE activa`, asi que pedirle
  -- una sucursal apagada seria comparar contra un universo que la pantalla no
  -- muestra. Se recorren SOLO las de este admin: asi cada llamada pasa el guard
  -- de pertenencia en vez de chocarlo.
  SELECT us.usuario_id INTO v_admin
    FROM usuario_sucursales us
    JOIN perfiles pf   ON pf.id = us.usuario_id AND pf.rol = 'admin'
    JOIN sucursales s  ON s.id = us.sucursal_id AND s.activa
   GROUP BY us.usuario_id
   ORDER BY count(*) DESC, us.usuario_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'migvc · el ensayo necesita un admin con al menos una sucursal activa asignada';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

  v_hasta := (date_trunc('month', CURRENT_DATE) - interval '1 day')::date;
  v_desde := date_trunc('month', v_hasta)::date;

  FOR v_suc IN
    SELECT s.id FROM sucursales s
      JOIN usuario_sucursales us ON us.sucursal_id = s.id AND us.usuario_id = v_admin
     WHERE s.activa ORDER BY s.id
  LOOP
    v_rg := public.reporte_gerencial(v_suc, v_desde, v_hasta);

    FOR v_fila IN
      WITH rvp AS (
        SELECT (x->>'id')::uuid AS id, ROUND((x->>'totalVentas')::numeric, 2) AS monto
          FROM jsonb_array_elements(public.reporte_ventas_por_preventista(v_desde, v_hasta, v_suc)) x
      ),
      rg AS (
        SELECT (x->>'id')::uuid AS id, ROUND((x->>'venta')::numeric, 2) AS monto
          FROM jsonb_array_elements(v_rg->'vendedores') x
      ),
      cc AS (
        SELECT (x->>'id')::uuid AS id, ROUND((x->>'base')::numeric, 2) AS monto
          FROM jsonb_array_elements(
                 public.calcular_comisiones(v_desde, v_hasta, ARRAY[v_suc])->'preventistas') x
      ),
      bot AS (
        SELECT (x->>'usuario_id')::uuid AS id, ROUND((x->>'total_vendido')::numeric, 2) AS monto
          FROM json_array_elements(
                 public.bot_ventas_por_preventista(v_desde, v_hasta, v_suc, false, 1000)
                 -> 'preventistas') x
      ),
      ids AS (
        SELECT id FROM rvp UNION SELECT id FROM rg UNION SELECT id FROM cc UNION SELECT id FROM bot
      )
      SELECT i.id,
             COALESCE(rvp.monto, 0) AS m_rvp,
             COALESCE(rg.monto, 0)  AS m_rg,
             COALESCE(cc.monto, 0)  AS m_cc,
             COALESCE(bot.monto, 0) AS m_bot
        FROM ids i
        LEFT JOIN rvp ON rvp.id = i.id
        LEFT JOIN rg  ON rg.id  = i.id
        LEFT JOIN cc  ON cc.id  = i.id
        LEFT JOIN bot ON bot.id = i.id
       WHERE i.id IS NOT NULL
    LOOP
      v_comp := v_comp + 1;
      IF GREATEST(v_fila.m_rvp, v_fila.m_rg, v_fila.m_cc, v_fila.m_bot)
       - LEAST(v_fila.m_rvp, v_fila.m_rg, v_fila.m_cc, v_fila.m_bot) > 0.01 THEN
        v_fallas := v_fallas || format(
          ' [suc %s · vendedor %s · Por Preventista %s · Equipo comercial %s · comision %s · bot %s]',
          v_suc, v_fila.id, v_fila.m_rvp, v_fila.m_rg, v_fila.m_cc, v_fila.m_bot);
      END IF;
    END LOOP;

    -- #569: rentabilidad tiene que cerrar contra el gerencial ahora que las dos
    -- miran pedidos.fecha y el mismo universo.
    v_rent := public.reporte_rentabilidad(v_desde, v_hasta, v_suc);
    IF abs(COALESCE((v_rent->'totales'->>'ventasBrutas')::numeric, 0)
         - COALESCE((v_rg->'kpis'->>'venta')::numeric, 0)) > 0.01 THEN
      v_fallas := v_fallas || format(
        ' [suc %s · Rentabilidad ventasBrutas %s <> gerencial venta %s]',
        v_suc, (v_rent->'totales'->>'ventasBrutas'), (v_rg->'kpis'->>'venta'));
    END IF;
  END LOOP;

  IF v_comp = 0 THEN
    RAISE EXCEPTION 'migvc · el ensayo no comparo ningun vendedor en % .. %: sin datos para verificar', v_desde, v_hasta;
  END IF;
  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'migvc · las definiciones de venta siguen sin coincidir en % .. %:%', v_desde, v_hasta, v_fallas;
  END IF;

  RAISE NOTICE 'migvc · ensayo OK: % vendedor(es) comparados en % .. %, cuatro definiciones identicas', v_comp, v_desde, v_hasta;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 8 · Se saca el andamio.
--     Ninguna funcion nueva queda viva, asi que no hay EXECUTE nuevo que
--     revocar: CREATE OR REPLACE preserva la ACL de cada funcion parcheada.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._migvc_ancla(regprocedure, text, text);

COMMIT;
