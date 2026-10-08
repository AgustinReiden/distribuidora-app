-- #1003 (1/2) · plata que se lee por REST · más #1013 y #1014
--
-- Las policies de SELECT de estas tablas filtraban sólo por sucursal (o por
-- `es_transportista()`), así que cualquier sesión de la sucursal leía costos por
-- REST con la anon key, aunque la UI no los mostrara. Medido en prod el
-- 2026-10-08 con `scripts/test-permisos-plata-rest.sql`: preventista,
-- transportista y un depósito con transportista extra leían mermas con su costo
-- y los movimientos entre sucursales con el costo de cada línea.
--
-- Criterio (dueño, 2026-10-08): los costos los ven admin y encargado; los
-- precios de venta, quien vende. Lo que sigue lo aplica tabla por tabla. Acá va
-- por POLICY y no por REVOKE de columna porque nadie fuera de esos roles lee
-- estas filas para trabajar: no hay `*` del front que se rompa ni columnas que
-- nazcan invisibles.
--
--   * movimientos_sucursal / movimiento_sucursal_items: admin y encargado (los
--     únicos que abren /transferencias). Arrastra a `compras_transferencias_netas`,
--     que es SECURITY INVOKER: a quien no lee las filas le devuelve vacío.
--   * transferencias_stock / transferencia_items: admin y encargado. Son
--     históricas; nadie las lee.
--   * mermas_stock: sólo admin, igual que `registrar_merma_manual` (mig 232) y
--     el reporte. Sale `es_transportista()`, que además arrastraba al rol extra
--     (`perfil_roles`): el borde de depósito con transportista extra de #1003.
--     #1013: la misma `es_transportista()` dejaba INSERTAR mermas por REST,
--     salteándose la RPC (sin bajar stock y con el costo que uno quisiera).
--   * compras / compra_items / compra_cargos / compra_cargo_repartos /
--     notas_credito / nota_credito_items: la familia de compras se lee con UN
--     predicado: admin, encargado y depósito. #1014: el
--     encargado registra y anula compras y notas de crédito por RPC, pero no las
--     leía, y /compras le quedaba vacía. Depósito sigue leyendo compras a
--     propósito (mig 192). Las notas de crédito de proveedor quedaban abiertas a
--     cualquier rol; ahora siguen a compras.
--   * promocion_reglas.valor NO se toca: sus únicas claves son
--     `cantidad_compra` y `cantidad_bonificacion`, unidades y no plata, y el
--     preventista las necesita para calcular los regalos en el carrito.
--
-- `pedido_items.costo_unitario_al_crear` va por REVOKE de columna, porque el
-- preventista y el transportista sí necesitan la fila (precios de venta). Esta
-- mitad crea la RPC por la que la piden admin y encargado; la mitad 2/2 (la
-- otra migración de #1003, en un PR aparte) revoca la columna DESPUÉS de
-- desplegar el front, que hoy la trae con `pedido_items(*)`.
--
-- Todas usan `es_encargado_o_admin()` / `es_admin()`, que miran `perfiles.rol`
-- (rol principal), como `costos_productos()` (mig 299). No `es_preventista()` ni
-- `es_transportista()`, que dan true por el rol extra (CLAUDE.md, trampa 4).
--
-- Esta mitad no rompe el front viejo: admin y encargado siguen viendo lo mismo,
-- y a los demás sólo se les vacían lecturas que el front no les hace.

-- costos_pedido_items(): el costo de la venta para admin y encargado -----

CREATE OR REPLACE FUNCTION public.costos_pedido_items(p_ids bigint[])
 RETURNS TABLE (id bigint, costo_unitario_al_crear numeric)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Mismo alcance que costos_productos(): admin o encargado por rol principal,
  -- sucursal actual. A cualquier otro rol, cero filas sin error.
  SELECT pi.id, pi.costo_unitario_al_crear
    FROM public.pedido_items pi
   WHERE public.es_encargado_o_admin()
     AND pi.sucursal_id = public.current_sucursal_id()
     AND pi.id = ANY (p_ids);
$function$;

REVOKE EXECUTE ON FUNCTION public.costos_pedido_items(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.costos_pedido_items(bigint[]) TO authenticated;

-- Movimientos y transferencias entre sucursales: admin y encargado --------

ALTER POLICY mov_suc_select ON public.movimientos_sucursal
  USING (public.es_encargado_o_admin()
         AND (sucursal_origen_id = public.current_sucursal_id()
              OR sucursal_destino_id = public.current_sucursal_id()));

ALTER POLICY mov_items_select ON public.movimiento_sucursal_items
  USING (public.es_encargado_o_admin()
         AND EXISTS (SELECT 1 FROM public.movimientos_sucursal m
                      WHERE m.id = movimiento_sucursal_items.movimiento_id
                        AND (m.sucursal_origen_id = public.current_sucursal_id()
                             OR m.sucursal_destino_id = public.current_sucursal_id())));

ALTER POLICY mt_transferencias_stock_select ON public.transferencias_stock
  USING (public.es_encargado_o_admin()
         AND (tenant_sucursal_id = public.current_sucursal_id()
              OR sucursal_id = public.current_sucursal_id()));

ALTER POLICY mt_transferencia_items_select ON public.transferencia_items
  USING (public.es_encargado_o_admin()
         AND EXISTS (SELECT 1 FROM public.transferencias_stock ts
                      WHERE ts.id = transferencia_items.transferencia_id
                        AND (ts.tenant_sucursal_id = public.current_sucursal_id()
                             OR ts.sucursal_id = public.current_sucursal_id())));

-- Mermas: sólo admin (#1003 el SELECT, #1013 el INSERT) --------------------

ALTER POLICY mt_mermas_stock_select ON public.mermas_stock
  USING (public.es_admin() AND sucursal_id = public.current_sucursal_id());

ALTER POLICY mt_mermas_stock_insert ON public.mermas_stock
  WITH CHECK (public.es_admin() AND sucursal_id = public.current_sucursal_id());

-- La familia de compras: admin, encargado y depósito (#1003 + #1014) -------

ALTER POLICY mt_compras_select ON public.compras
  USING ((public.es_encargado_o_admin()
          OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
         AND sucursal_id = public.current_sucursal_id());

ALTER POLICY mt_compra_items_select ON public.compra_items
  USING ((public.es_encargado_o_admin()
          OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
         AND sucursal_id = public.current_sucursal_id());

-- Los cargos de la compra (flete, etc., mig 192) son parte de leerla: sin
-- ellos el encargado vería "Esta compra no tiene cargos." en una compra con
-- flete, y no tendría la plantilla de cargos del proveedor al cargar una.
ALTER POLICY mt_compra_cargos_select ON public.compra_cargos
  USING ((public.es_encargado_o_admin()
          OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
         AND sucursal_id = public.current_sucursal_id());

ALTER POLICY mt_compra_cargo_repartos_select ON public.compra_cargo_repartos
  USING ((public.es_encargado_o_admin()
          OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
         AND EXISTS (SELECT 1 FROM public.compra_cargos c
                      WHERE c.id = compra_cargo_repartos.cargo_id
                        AND c.sucursal_id = public.current_sucursal_id()));

ALTER POLICY mt_notas_credito_select ON public.notas_credito
  USING ((public.es_encargado_o_admin()
          OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
         AND sucursal_id = public.current_sucursal_id());

ALTER POLICY mt_nota_credito_items_select ON public.nota_credito_items
  USING ((public.es_encargado_o_admin()
          OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
         AND sucursal_id = public.current_sucursal_id());

-- Verificación ---------------------------------------------------------------

DO $verif$
DECLARE
  v_mal text;
BEGIN
  IF has_function_privilege('anon', 'public.costos_pedido_items(bigint[])', 'EXECUTE') THEN
    RAISE EXCEPTION '#1003 · anon puede ejecutar costos_pedido_items';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.costos_pedido_items(bigint[])', 'EXECUTE') THEN
    RAISE EXCEPTION '#1003 · authenticated no puede ejecutar costos_pedido_items';
  END IF;

  -- Ninguna policy de lectura de estas tablas queda abierta por sucursal sola
  -- ni por es_transportista().
  SELECT string_agg(tablename || '.' || policyname, ', ') INTO v_mal
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('movimientos_sucursal', 'movimiento_sucursal_items', 'transferencias_stock',
                       'transferencia_items', 'mermas_stock', 'compras', 'compra_items',
                       'compra_cargos', 'compra_cargo_repartos', 'notas_credito', 'nota_credito_items')
     -- 'ALL' también concede SELECT: una permisiva FOR ALL abierta lo tapa todo.
     AND cmd IN ('SELECT', 'INSERT', 'ALL')
     AND (coalesce(qual, '') || coalesce(with_check, '')) NOT LIKE '%es_admin()%'
     AND (coalesce(qual, '') || coalesce(with_check, '')) NOT LIKE '%es_encargado_o_admin()%';
  IF v_mal IS NOT NULL THEN
    RAISE EXCEPTION '#1003 · policies sin filtro de rol: %', v_mal;
  END IF;

  SELECT string_agg(tablename || '.' || policyname, ', ') INTO v_mal
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'mermas_stock'
     AND (coalesce(qual, '') || coalesce(with_check, '')) LIKE '%es_transportista()%';
  IF v_mal IS NOT NULL THEN
    RAISE EXCEPTION '#1013 · mermas_stock sigue mirando es_transportista(): %', v_mal;
  END IF;
END
$verif$;
