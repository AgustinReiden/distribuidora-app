-- Migración 216: solo le vendés a tu cliente o al huérfano
--
-- Cierra el agujero del issue #544: `crear_pedido_completo` y
-- `crear_pedido_completo_bot` NO chequean `cliente_preventistas`. La regla de
-- asignación vivía en todos lados (RLS `mt_clientes_select`, `bot_buscar_cliente`,
-- `registrar_visita_cliente`, `ficha_cliente.ts`, `previsualizar_pedido.ts`) menos
-- en el alta del pedido: el front le ocultaba el cliente y el RPC igual le
-- aceptaba el pedido si conocía el `id` — un bigint correlativo, visible en
-- cualquier pedido viejo o export.
--
-- No es solo visibilidad: la venta se atribuye a `pedidos.usuario_id`, así que
-- era plata mal atribuida entre preventistas.
--
-- LA REGLA. Si quien crea el pedido tiene rol 'preventista', el cliente tiene
-- que estar SIN ASIGNAR (huérfano) o ASIGNADO A ÉL. Los demás roles pasan sin
-- chequeo: admin y encargado siguen sin restricción.
--
-- POR QUÉ UN TRIGGER Y NO UN CHEQUEO ADENTRO DEL RPC — mismo molde que la 214 §7:
--   * cubre `crear_pedido_completo` Y `crear_pedido_completo_bot` de una sola vez.
--     El bot corre con service_role y NO pasa por RLS: adentro de un RPC habría
--     que repetir el guard en el otro y alguien se lo va a olvidar;
--   * no toca ningún cuerpo vivo. La 205 le INYECTA código a
--     `crear_pedido_completo` con `_mig205_insertar_tras_ancla`: un
--     `CREATE OR REPLACE` desde el repo lo borraría en silencio;
--   * atrapa además el INSERT directo por PostgREST, que hoy `mt_pedidos_insert`
--     deja pasar (`es_preventista() AND sucursal_id = current_sucursal_id()`,
--     sin mirar `usuario_id`).
--
-- OJO es_preventista(): devuelve true también para admin y encargado. Acá se lee
-- `perfiles.rol` CRUDO, nunca el helper.
--
-- IMPACTO MEDIDO ANTES DE APLICAR (90 días al 2026-09-09): 200 de 2723 pedidos de
-- preventistas matchean la consulta cruda, pero 198 son ARTEFACTO — la asignación
-- del cliente se creó DESPUÉS del pedido, así que en su momento el cliente era
-- huérfano y esta regla los habría dejado pasar. Casos reales de un preventista
-- facturándole al cliente ya asignado a otro: 2 (pedidos 5086 y 5192, $26.800).

BEGIN;

-- ---------------------------------------------------------------------------
-- El guard
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER a propósito, igual que la 214: lee `cliente_preventistas` y
-- `perfiles`, que la RLS le tapa al preventista. Como INVOKER los EXISTS darían
-- false y el guard quedaría FAIL-OPEN — dejaría pasar todo.
--
-- QUIÉN ES EL AUTOR (y por qué NO es `usuario_id`). `crear_pedido_completo`
-- escribe `usuario_id = v_preventista_final` y `creado_por = p_usuario_id`: son
-- columnas distintas. Con `p_preventista_id` un ADMIN carga un pedido A NOMBRE
-- de un preventista, y ahí `usuario_id` es el vendedor ATRIBUIDO, no el autor.
-- Si el guard mirara `usuario_id`, ese pedido del admin se rechazaría cada vez
-- que el preventista atribuido no tenga el cliente — y la decisión es que admin
-- y encargado van sin restricción. Por eso se decide por el AUTOR:
--
--   COALESCE(perfil de auth.uid(), creado_por, usuario_id)
--
--   * `auth.uid()` primero porque es lo único NO FALSIFICABLE: sale del JWT, no
--     de la fila. Un preventista que hace INSERT directo no puede escaparse
--     mandando `creado_por` de un admin. Funciona aunque el trigger corra dentro
--     de un SECURITY DEFINER (es un GUC, no depende del owner).
--   * se exige que `auth.uid()` sea un perfil real antes de usarlo: en el camino
--     del bot el JWT es de service_role y no trae `sub`, así que cae a
--     `creado_por` (= `p_perfil_id`, el preventista de Telegram). Si algún día un
--     token de servicio trajera un `sub` ajeno a `perfiles`, el COALESCE lo
--     ignora en vez de quedar fail-open.
--   * `usuario_id` al final: `creado_por` es NULL en las filas viejas, anteriores
--     a la columna (mig 100).
--
-- OJO, convive con `trg_pedidos_cliente_reservado` (214 §7), que SÍ mira
-- `usuario_id`. No se pisan y las dos claves son deliberadas: un cliente
-- `reservado_admin` NO tiene asignaciones (la 214 las borra y prohíbe), o sea
-- que para ESTE guard es huérfano y pasa derecho; lo rechaza el otro, con su
-- propio mensaje. Un cliente asignado a otro nunca está reservado, así que lo
-- rechaza éste. Cada mensaje dice qué regla se violó — un "no podés crear este
-- pedido" pelado es un llamado telefónico.
--
-- Solo BEFORE INSERT, a propósito: reatribuir un pedido ya creado (mover
-- `cliente_id` o `usuario_id`) es tarea de administración y de las migraciones
-- de datos. Poner el guard en UPDATE las rompería.
CREATE OR REPLACE FUNCTION public.pedidos_cliente_asignado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_autor uuid;
  v_duenos text;
  v_cliente text;
BEGIN
  IF NEW.cliente_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_autor := COALESCE(
    (SELECT p.id FROM perfiles p WHERE p.id = auth.uid()),
    NEW.creado_por,
    NEW.usuario_id
  );

  IF v_autor IS NULL THEN
    RETURN NEW;
  END IF;

  -- `perfiles.rol` crudo: es_preventista() incluye a admin y encargado.
  IF NOT EXISTS (
    SELECT 1 FROM perfiles p WHERE p.id = v_autor AND p.rol = 'preventista'
  ) THEN
    RETURN NEW;
  END IF;

  -- Huérfano: sin ninguna asignación ⇒ visible para todos los preventistas
  -- (mig 028). Pasa.
  IF NOT EXISTS (
    SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = NEW.cliente_id
  ) THEN
    RETURN NEW;
  END IF;

  -- Asignado a él. Pasa.
  IF EXISTS (
    SELECT 1 FROM cliente_preventistas cp
    WHERE cp.cliente_id = NEW.cliente_id AND cp.preventista_id = v_autor
  ) THEN
    RETURN NEW;
  END IF;

  SELECT string_agg(pf.nombre, ', ' ORDER BY pf.nombre)
    INTO v_duenos
    FROM cliente_preventistas cp
    JOIN perfiles pf ON pf.id = cp.preventista_id
   WHERE cp.cliente_id = NEW.cliente_id;

  SELECT COALESCE(c.nombre_fantasia, c.razon_social)
    INTO v_cliente
    FROM clientes c WHERE c.id = NEW.cliente_id;

  RAISE EXCEPTION 'Cliente asignado a otro preventista: % (#%) lo atiende %. No podés cargarle pedidos.',
    COALESCE(v_cliente, '?'), NEW.cliente_id, COALESCE(v_duenos, 'otro preventista')
    USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS trg_pedidos_cliente_asignado ON public.pedidos;
CREATE TRIGGER trg_pedidos_cliente_asignado
  BEFORE INSERT ON public.pedidos
  FOR EACH ROW
  EXECUTE FUNCTION public.pedidos_cliente_asignado();

-- ---------------------------------------------------------------------------
-- ACL
-- ---------------------------------------------------------------------------
-- Toda función nueva de `public` nace con EXECUTE para PUBLIC (la entrada
-- `=X/postgres` sin grantee) y Supabase le concede `authenticated` por separado:
-- hay que revocar las DOS mitades acá, en la misma migración. Es lo que la 212 se
-- olvidó y la 213 tuvo que venir a cerrar.
--
-- Una función de trigger no necesita EXECUTE para NADIE: la invoca el executor
-- como parte del DML, no el caller. Queda en postgres, igual que
-- `pedidos_cliente_reservado` (214) y `completar_origen_precio_item` (148).

REVOKE ALL ON FUNCTION public.pedidos_cliente_asignado()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verificación de ACL (gate de CI: scripts/check-permisos.mjs)
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_acl text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'pedidos_cliente_asignado';

  IF v_acl IS NULL OR v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'trigger pedidos_cliente_asignado quedo ejecutable por PUBLIC: %',
      coalesce(v_acl, '(default)');
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'trigger pedidos_cliente_asignado quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl LIKE '%authenticated=%' THEN
    RAISE EXCEPTION 'trigger pedidos_cliente_asignado quedo ejecutable por authenticated: %', v_acl;
  END IF;
END
$verif$;

COMMIT;
