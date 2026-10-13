-- Migración 356: el preventista ve el historial de los clientes a los que les vendió
--
-- Hasta acá la excepción "ya le vendió" (mig 214) existía SÓLO para el cliente
-- reservado a administración. Un cliente que se le reasignaba a OTRO preventista
-- le desaparecía al anterior, y con él sus pedidos viejos: el embed
-- `cliente:clientes(*)` devuelve NULL y los `!inner` de usePedidosQuery /
-- usePedidoStatsQuery los sacan de la lista y del count, en silencio. Medido en
-- prod antes de esta migración: 485 pedidos propios invisibles para su autor
-- (Marcelo 68, Osvaldo 233, Víctor 184). Y el link zona → preventista que viene
-- después reasigna en bloque, así que lo multiplicaría.
--
-- La regla nueva, para el rol PRINCIPAL preventista (`perfiles.rol` crudo, no
-- es_preventista(), que da true para admin y encargado):
--
--   ve el cliente  ⇔  (sin asignar o asignado a él) y no reservado     ← operar
--                     o tiene pedidos propios con él                    ← historial
--
-- Antes era  (sin asignar o asignado a él) y (no reservado o tiene pedidos).
-- Lo de antes está contenido en lo de ahora: esta migración SÓLO AGREGA filas
-- visibles, no saca ninguna.
--
-- Ver no es operar. Lo que el preventista no puede hacer con un cliente de
-- historial ya lo cierra la base por su lado, sin mirar esta policy:
--   * cargarle un pedido: trg_pedidos_cliente_asignado (216) y
--     trg_pedidos_cliente_reservado (214), por `pedidos.usuario_id`;
--   * marcarle una visita: registrar_visita_cliente;
--   * asignárselo: cliente_preventistas_no_ajeno.
-- Y el front lo saca de sus listados operativos (selectores, panel, recorrido)
-- con `esClienteOperable` (src/utils/clienteOperable.ts).
--
-- La rama de depósito (307) y la de "no soy preventista → veo todo" quedan
-- intactas.
--
-- ESPEJOS. Dos RPCs SECURITY DEFINER copian este predicado a mano y dicen "si
-- cambia uno, cambia el otro": obtener_resumen_cuenta_cliente (298 → 332) y
-- verificar_duplicado_cliente (250 → 260). Se editan acá abajo sobre su cuerpo
-- VIVO (replace exacto + assert), no copiando el del repo, que puede estar
-- atrás de prod. Las del bot (bot_buscar_cliente, bot_historico_pedidos_cliente,
-- bot_productos_*_cliente, clientes_ritmo_compra) NO se tocan: el bot es
-- operativo, y ahí "ve" significa "le puede vender".

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. La policy
-- ---------------------------------------------------------------------------
ALTER POLICY mt_clientes_select ON public.clientes
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      -- Roles que no son preventista ven todos los clientes de su sucursal
      NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol = 'preventista'
      )
      -- Operar: huérfanos + los míos, menos los reservados
      OR (
        (
          NOT EXISTS (
            SELECT 1 FROM public.cliente_preventistas cp
            WHERE cp.cliente_id = clientes.id
          )
          OR EXISTS (
            SELECT 1 FROM public.cliente_preventistas cp
            WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid()
          )
        )
        AND NOT clientes.reservado_admin
      )
      -- Historial: cualquier cliente al que ya le vendió (usa
      -- idx_pedidos_cliente_usuario, mig 214)
      OR EXISTS (
        SELECT 1 FROM public.pedidos pe
        WHERE pe.cliente_id = clientes.id AND pe.usuario_id = auth.uid()
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.perfiles pd
      WHERE pd.id = auth.uid() AND pd.rol = 'deposito'
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Espejos
-- ---------------------------------------------------------------------------
DO $espejos$
DECLARE
  v_def  text;
  v_new  text;
  v_old_resumen constant text :=
$o$        OR (
          (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
            OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                       WHERE cp.cliente_id = c.id AND cp.preventista_id = auth.uid())
          )
          AND (
            NOT c.reservado_admin
            OR EXISTS (SELECT 1 FROM pedidos pe
                       WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())
          )
        )$o$;
  v_new_resumen constant text :=
$n$        OR (
          (
            NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
            OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                       WHERE cp.cliente_id = c.id AND cp.preventista_id = auth.uid())
          )
          AND NOT c.reservado_admin
        )
        -- Historial (mig 356): ya le vendió, aunque hoy lo atienda otro
        OR EXISTS (SELECT 1 FROM pedidos pe
                   WHERE pe.cliente_id = c.id AND pe.usuario_id = auth.uid())$n$;
  v_old_dup constant text :=
$o$    SELECT (
        (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id))
        OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                    WHERE cp.cliente_id = c.id AND cp.preventista_id = v_uid)
      )
      AND (
        NOT c.reservado_admin
        OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = v_uid)
      )
      INTO v_visible$o$;
  v_new_dup constant text :=
$n$    SELECT (
        (
          (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id))
          OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                      WHERE cp.cliente_id = c.id AND cp.preventista_id = v_uid)
        )
        AND NOT c.reservado_admin
      )
      -- Historial (mig 356): ya le vendió, aunque hoy lo atienda otro
      OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = v_uid)
      INTO v_visible$n$;
BEGIN
  -- obtener_resumen_cuenta_cliente
  v_def := pg_get_functiondef('public.obtener_resumen_cuenta_cliente(integer)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, v_old_resumen, ''))) / length(v_old_resumen) <> 1 THEN
    RAISE EXCEPTION '356: el predicado de obtener_resumen_cuenta_cliente no está una sola vez en el cuerpo vivo';
  END IF;
  v_new := replace(v_def, v_old_resumen, v_new_resumen);
  EXECUTE v_new;

  -- verificar_duplicado_cliente
  v_def := pg_get_functiondef(
    'public.verificar_duplicado_cliente(numeric, numeric, text, bigint)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, v_old_dup, ''))) / length(v_old_dup) <> 1 THEN
    RAISE EXCEPTION '356: el predicado de verificar_duplicado_cliente no está una sola vez en el cuerpo vivo';
  END IF;
  v_new := replace(v_def, v_old_dup, v_new_dup);
  EXECUTE v_new;
END
$espejos$;

-- ---------------------------------------------------------------------------
-- 3. Ensayo: sólo agrega, y los pedidos propios tienen cliente
-- ---------------------------------------------------------------------------
-- Para cada preventista activo: todo pedido suyo que la RLS de pedidos le deja
-- ver tiene que poder embeber su cliente. Corre como el preventista (claims +
-- SET LOCAL ROLE) y vuelve a postgres antes de seguir.
DO $ensayo$
DECLARE
  r record;
  v_huerfanos int;
BEGIN
  FOR r IN SELECT id, nombre FROM perfiles WHERE rol = 'preventista' AND activo LOOP
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', r.id, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', r.id::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_huerfanos
      FROM pedidos pe
     WHERE pe.cliente_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM clientes c WHERE c.id = pe.cliente_id);
    EXECUTE 'RESET ROLE';
    IF v_huerfanos > 0 THEN
      RAISE EXCEPTION '356: % ve % pedidos propios sin su cliente', r.nombre, v_huerfanos;
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
END
$ensayo$;

COMMIT;
