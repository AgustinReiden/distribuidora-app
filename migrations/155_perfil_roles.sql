-- =========================================================================
-- 155_perfil_roles.sql
--
-- Un usuario puede tener capacidades de mas de un rol en una sucursal.
--
-- El caso: en Taco Pozo, Juan (preventista) acompaña al camion. Vende, entrega
-- y cobra en la misma parada. `perfiles.rol` es escalar, asi que hoy o es
-- preventista o es transportista, nunca los dos: puede cargar el pedido pero
-- no ve la ruta, no marca entregado ni cobrado.
--
-- El intento anterior fue un rol a medida (`preventista_taco`, mig 050/055) y
-- salio caro: quedo con 6 funciones de permisos, gating repartido por la app,
-- el menu vacio y CERO usuarios. Cada combinacion futura seria un rol nuevo con
-- su propia deuda. Aca "tambien reparte" pasa a ser un dato que el admin asigna
-- desde la UI, por sucursal.
--
-- MODELO
-- ------
-- `perfiles.rol` sigue siendo la IDENTIDAD / PUESTO. Esta tabla son CAPACIDADES
-- OPERATIVAS que se SUMAN, y afecta EXCLUSIVAMENTE a dos helpers:
-- es_preventista() y es_transportista(). En ambos el cambio es ADITIVO
-- (`... OR tiene_rol_extra(...)`), nunca sustractivo.
--
-- Por eso NO cambia de comportamiento nada de lo que lee `perfiles.rol` crudo:
--   · registrar_pago_cliente_fifo / registrar_pago_combinado_cliente_fifo
--     (SELECT rol INTO v_rol FROM perfiles; IF v_rol NOT IN ('admin','encargado'))
--     => el pago a cuenta corriente desde la ficha sigue vedado a los
--        transportistas Y a Juan, sin escribir una linea para lograrlo.
--   · es_admin(), es_encargado_o_admin(), es_admin_rendiciones(),
--     es_admin_salvedades(), es_transportista_rendiciones(), get_mi_rol()
--   · crear_pedido_completo, actualizar_pedido_items, registrar_visita_cliente,
--     obtener_geolocalizacion_preventistas (mig 055)
--   · clientes_proteger_columnas_preventista (mig 080)
--   · mt_clientes_select (rama preventista, mig 055)
--   · las policies de `deposito` (rol leido inline)
--
-- Se aplica VACIA a proposito: cero cambio de comportamiento hasta que un admin
-- asigne una fila. El interruptor es un INSERT; el rollback, un DELETE.
--
-- La unica excepcion, y es deliberada: la rama nueva de `pagos` (seccion 5),
-- que habilita al transportista a cobrar los pedidos de SU ruta. Es aditiva:
-- solo puede otorgar, nunca revocar.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Tabla
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.perfil_roles (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  usuario_id  uuid        NOT NULL REFERENCES public.perfiles(id)   ON DELETE CASCADE,
  sucursal_id bigint      NOT NULL REFERENCES public.sucursales(id) ON DELETE CASCADE,
  rol         text        NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid        REFERENCES public.perfiles(id) ON DELETE SET NULL,

  -- Solo 'transportista' a proposito. La escalabilidad esta en la ESTRUCTURA
  -- (N:M por sucursal), no en habilitar valores sin caso de uso:
  --   · 'admin'/'encargado' quedan afuera para que esto nunca sea un vector de
  --     escalada de privilegios.
  --   · 'deposito' seria letra muerta: no existe es_deposito(), esas policies
  --     preguntan `perfiles.rol = 'deposito'` inline. Darlo aca daria falsa
  --     sensacion de permiso otorgado.
  --   · 'preventista' abriria clientes I/U, pedidos I, pedido_items I/U y
  --     `pagos` SELECT de TODA la sucursal. Sin caso real, no se habilita.
  -- Ampliar es un ALTER de una linea el dia que haga falta.
  CONSTRAINT perfil_roles_rol_check CHECK (rol IN ('transportista')),
  CONSTRAINT perfil_roles_uq UNIQUE (usuario_id, sucursal_id, rol)
);

CREATE INDEX IF NOT EXISTS idx_perfil_roles_lookup
  ON public.perfil_roles (usuario_id, sucursal_id, rol);
CREATE INDEX IF NOT EXISTS idx_perfil_roles_por_sucursal
  ON public.perfil_roles (sucursal_id, rol);

COMMENT ON TABLE public.perfil_roles IS
  'Capacidades operativas EXTRA por sucursal, que se SUMAN a perfiles.rol. '
  'perfiles.rol sigue siendo identidad/puesto y es lo que leen los gates '
  'sensibles (FIFO, es_admin, es_encargado_o_admin, mt_clientes_select). '
  'Esta tabla SOLO afecta a es_preventista() y es_transportista().';

-- -------------------------------------------------------------------------
-- 2. RLS
-- -------------------------------------------------------------------------
ALTER TABLE public.perfil_roles ENABLE ROW LEVEL SECURITY;

-- Sin filtro de sucursal a proposito: el frontend lee sus propios roles al
-- iniciar sesion, ANTES de setear el header X-Sucursal-ID.
DROP POLICY IF EXISTS perfil_roles_select_propio ON public.perfil_roles;
CREATE POLICY perfil_roles_select_propio
  ON public.perfil_roles FOR SELECT TO authenticated
  USING (usuario_id = auth.uid());

-- El ENCARGADO es imprescindible: en Taco Pozo la ruta la arma Jony (encargado)
-- y aplicar_orden_ruta gatea con es_encargado_o_admin(). Sin este SELECT, Juan
-- no apareceria en el picker de transportistas.
-- Espeja usuario_sucursales_select_sucursal_activa (mig 007).
DROP POLICY IF EXISTS perfil_roles_select_sucursal_activa ON public.perfil_roles;
CREATE POLICY perfil_roles_select_sucursal_activa
  ON public.perfil_roles FOR SELECT TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND EXISTS (
      SELECT 1 FROM public.perfiles p
      WHERE p.id = auth.uid() AND p.rol IN ('admin', 'encargado')
    )
  );

DROP POLICY IF EXISTS perfil_roles_write_admin ON public.perfil_roles;
CREATE POLICY perfil_roles_write_admin
  ON public.perfil_roles FOR ALL TO authenticated
  USING      (public.es_admin() AND sucursal_id = public.current_sucursal_id())
  WITH CHECK (public.es_admin() AND sucursal_id = public.current_sucursal_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.perfil_roles TO authenticated;

-- -------------------------------------------------------------------------
-- 3. Primitiva: SOLO los roles extra (no mira perfiles.rol)
-- -------------------------------------------------------------------------
-- SECURITY DEFINER para leer perfil_roles saltandose su propia RLS.
-- current_sucursal_id() devuelve NULL si el header falta o no esta autorizado
-- => EXISTS falso => fail-closed, igual que el resto del sistema.
CREATE OR REPLACE FUNCTION public.tiene_rol_extra(p_rol text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM public.perfil_roles pr
    WHERE pr.usuario_id  = auth.uid()
      AND pr.rol         = p_rol
      AND pr.sucursal_id = public.current_sucursal_id()
  );
$fn$;

REVOKE ALL ON FUNCTION public.tiene_rol_extra(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tiene_rol_extra(text) TO authenticated, service_role;

COMMENT ON FUNCTION public.tiene_rol_extra(text) IS
  'true si el usuario actual tiene ese rol EXTRA en la sucursal activa. '
  'No mira perfiles.rol: es la primitiva que usan es_preventista()/es_transportista().';

-- -------------------------------------------------------------------------
-- 4. Helpers reescritos: ADITIVO y con corto-circuito
-- -------------------------------------------------------------------------
-- El EXISTS de cada uno es IDENTICO al de la mig 055 / baseline: se agrega
-- unicamente un segundo RETURN. El IF/RETURN (en vez de `RETURN a OR b`)
-- garantiza que admin, preventista, preventista_taco y encargado NO paguen el
-- lookup extra: en el 99% del trafico el costo es exactamente el de hoy.
-- Ademas pasan de VOLATILE (default, sin marca) a STABLE, que es lo correcto
-- para funciones que solo leen y se evaluan dentro de policies.

CREATE OR REPLACE FUNCTION public.es_preventista()
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
BEGIN
  IF EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
      AND rol IN ('admin', 'preventista', 'preventista_taco', 'encargado')
  ) THEN
    RETURN true;
  END IF;
  RETURN public.tiene_rol_extra('preventista');
END;
$fn$;

CREATE OR REPLACE FUNCTION public.es_transportista()
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
BEGIN
  IF EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
      AND rol IN ('admin', 'transportista')
  ) THEN
    RETURN true;
  END IF;
  RETURN public.tiene_rol_extra('transportista');
END;
$fn$;

-- NO se tocan, a proposito: es_admin(), es_encargado_o_admin(),
-- es_admin_rendiciones(), es_admin_salvedades(), es_transportista_rendiciones(),
-- is_admin(), is_preventista(), is_transportista(), get_mi_rol().

-- -------------------------------------------------------------------------
-- 5. pagos: el transportista cobra los pedidos de SU ruta
-- -------------------------------------------------------------------------
-- Hasta hoy `mt_pagos_insert` exigia es_preventista(), que no incluye a
-- transportista: el chofer nunca pudo cobrar (0 pagos registrados por un
-- transportista en toda la historia de la base). La cobranza se cargaba en la
-- oficina al volver.
--
-- La rama nueva es por PERTENENCIA, igual que mt_pedidos_update,
-- registrar_salvedad y marcar_no_entregado. `pedido_id IS NOT NULL` es lo que
-- separa el cobro de la parada del pago a cuenta corriente: sin pedido no hay
-- pertenencia que verificar. El pago a cuenta va por los RPC FIFO, que leen
-- perfiles.rol crudo y exigen admin|encargado.
DROP POLICY IF EXISTS "mt_pagos_insert" ON public.pagos;
CREATE POLICY "mt_pagos_insert" ON public.pagos
  FOR INSERT TO authenticated
  WITH CHECK (
    pagos.sucursal_id = public.current_sucursal_id()
    AND (
      public.es_preventista()
      OR (
        public.es_transportista()
        AND pagos.pedido_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.pedidos pd
          WHERE pd.id               = pagos.pedido_id
            AND pd.transportista_id = auth.uid()
            AND pd.sucursal_id      = public.current_sucursal_id()
        )
      )
    )
  );

-- El SELECT es imprescindible ademas del INSERT: usePagos.registrarPago hace
-- `.insert(...).select('*, usuario:perfiles(id,nombre)').single()` y PostgREST
-- necesita poder LEER la fila recien insertada para devolverla.
DROP POLICY IF EXISTS "mt_pagos_select" ON public.pagos;
CREATE POLICY "mt_pagos_select" ON public.pagos
  FOR SELECT TO authenticated
  USING (
    pagos.sucursal_id = public.current_sucursal_id()
    AND (
      public.es_preventista()
      OR (
        public.es_transportista()
        AND pagos.pedido_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.pedidos pd
          WHERE pd.id               = pagos.pedido_id
            AND pd.transportista_id = auth.uid()
            AND pd.sucursal_id      = public.current_sucursal_id()
        )
      )
    )
  );

-- mt_pagos_update y mt_pagos_delete quedan admin-only, sin cambios.

-- SIN SEEDS: la fila de Juan la crea el admin desde la UI, asi created_by queda
-- poblado y el rollback operativo es un DELETE de una fila, sin deploy.

COMMIT;
