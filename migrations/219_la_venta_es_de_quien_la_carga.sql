-- Migración 219: la venta es de quien la carga
--
-- Issue #549.
--
-- EL AGUJERO. `mt_pedidos_insert` es `(es_preventista() AND sucursal_id =
-- current_sucursal_id())` y no mira `usuario_id`. Por PostgREST, sin pasar por
-- ningún RPC, se podía hacer `INSERT INTO pedidos` con el `usuario_id` de otro
-- y atribuirle la venta a un tercero (o quitársela a uno mismo).
--
-- Y la superficie era más ancha de lo que parece: `es_preventista()` devuelve
-- true también para admin y encargado (trampa 4 de CLAUDE.md), así que el
-- predicado no acotaba casi nada.
--
-- POR QUÉ IMPORTA. `calcular_comisiones` agrupa por `pedidos.usuario_id`, igual
-- que los reportes de ventas por vendedor. Una atribución forjada mueve plata
-- de una liquidación a otra.
--
-- LA ASIMETRÍA QUE LO DEJÓ PASAR. El UPDATE ya estaba tapado: este mismo
-- trigger bloquea `usuario_id`, `creado_por`, `cliente_id`, `total` y otras
-- para todo el que no sea encargado ni admin. O sea que robarse una venta YA
-- HECHA era imposible; lo que faltaba era la misma protección en el alta. Por
-- eso el arreglo va acá adentro y no en una función nueva: la asimetría
-- INSERT/UPDATE fue justamente lo que hizo que el agujero pasara desapercibido,
-- y partir la regla en dos lugares la reproduce.
--
-- LA REGLA. Quien crea el pedido puede atribuírselo a sí mismo siempre. A OTRO,
-- solo si es admin o encargado. Un preventista no puede crear un pedido a
-- nombre de un tercero.
--
-- POR QUÉ NO ROMPE EL FLUJO DEL ADMIN. Un admin carga pedidos A NOMBRE de un
-- preventista (`p_preventista_id` en `crear_pedido_completo`, que escribe
-- `usuario_id = v_preventista_final` y `creado_por = p_usuario_id`): son 55 de
-- los 5.628 pedidos del último año. Ese caso sale por el `RETURN NEW` de
-- `es_encargado_o_admin()`, que ya estaba dos líneas más arriba y ahora también
-- gobierna el INSERT. No hizo falta agregarle nada.
--
-- QUIÉN ES EL AUTOR: `auth.uid()`, Y NO EL COALESCE DE LA MIG 216.
-- La 216 (`pedidos_cliente_asignado`) decide con
--   COALESCE((SELECT p.id FROM perfiles WHERE p.id = auth.uid()), NEW.creado_por, NEW.usuario_id)
-- porque ESE trigger corre para todos los caminos, incluidos los RPC (que
-- corren como `postgres`) y el bot (`service_role`), donde `auth.uid()` es NULL
-- y hace falta el fallback.
--
-- Acá no, y la diferencia importa en la dirección de la seguridad: este bloque
-- solo se alcanza si `current_user = 'authenticated'` —lo garantiza la primera
-- línea de la función, que ya estaba—, o sea que `auth.uid()` nunca es NULL y
-- es el autor, punto. Traer el COALESCE igual sería peor, no mejor:
--   * el término de `perfiles` depende de que la RLS de `perfiles` siga siendo
--     permisiva (hoy `perfiles_select_all USING (true)`). El día que alguien la
--     ajuste —que sería una mejora— ese término devuelve NULL y el guard cae al
--     término siguiente;
--   * y ese término siguiente es `NEW.creado_por`, que en un INSERT directo lo
--     manda el atacante. O sea: fail-OPEN.
-- Con `auth.uid()` pelado, un `auth.uid()` nulo hace que cualquier `usuario_id`
-- no nulo sea distinto del autor y el INSERT se rechaza: fail-CLOSED.
--
-- LOS RPC Y EL BOT NO PASAN POR ACÁ, a propósito: `crear_pedido_completo` y
-- `crear_pedido_completo_bot` son SECURITY DEFINER, así que adentro
-- `current_user` es `postgres` y la función sale por el `RETURN NEW` de la
-- primera línea. No es un olvido: los dos RPC ya validan lo mismo por su cuenta
-- (`p_usuario_id IS DISTINCT FROM auth.uid()` → error), y el camino del bot
-- —donde `auth.uid()` es NULL— tiene que seguir funcionando. Lo que este trigger
-- cubre es exactamente el INSERT directo por PostgREST, que es donde estaba el
-- agujero y el único lugar sin dueño.
--
-- POR QUÉ SIGUE SIENDO INVOKER (y no SECURITY DEFINER como los guards de las
-- migs 214 y 216): porque su primera línea es `current_user <> 'authenticated'`.
-- Adentro de una función SECURITY DEFINER `current_user` es el dueño, así que
-- pasarla a definer haría que ESA comparación diera siempre true y toda la
-- protección de columnas del UPDATE se apagaría en silencio. No necesita ser
-- definer: los roles los resuelve con `es_encargado_o_admin()` y
-- `es_transportista()`, que ya son SECURITY DEFINER, y la identidad con
-- `auth.uid()`, que sale del JWT y no se falsifica. Ninguna lee tablas bajo la
-- RLS del caller.
--
-- LO QUE NO CIERRA, dicho a propósito: un INSERT directo con `usuario_id NULL`
-- pasa. No es "atribuírsela a otro" —es no atribuirla a nadie—, y la columna es
-- nullable con 2 pedidos así en el último año (ambos de marzo, ambos también
-- sin `creado_por`). Cerrarlo es otra decisión, con otro riesgo: convierte en
-- error un dato que la base hoy admite.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. El guard, adentro de la función que ya protege las columnas en UPDATE
-- ---------------------------------------------------------------------------
-- El bloque nuevo va DESPUÉS del `RETURN NEW` de encargado/admin (así ese caso
-- queda cubierto sin escribir nada) y ANTES de todo lo que usa OLD, que en un
-- INSERT no existe. El resto del cuerpo queda byte por byte como estaba.

CREATE OR REPLACE FUNCTION public.pedidos_proteger_columnas()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_bloqueadas text;
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;

  -- ---- Alta: la venta es de quien la carga (mig 219, issue #549) ----------
  -- Acá abajo el caller ya no es admin ni encargado, así que solo puede
  -- atribuirse el pedido a sí mismo.
  IF TG_OP = 'INSERT' THEN
    IF NEW.usuario_id IS NOT NULL AND NEW.usuario_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Un pedido se atribuye a quien lo carga: no podés crear uno a nombre de otro usuario (usuario_id %). Solo un administrador o encargado puede hacerlo.',
        NEW.usuario_id
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  -- ---- De acá abajo es UPDATE (usa OLD) ----------------------------------
  IF es_transportista() THEN
    SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
    FROM jsonb_each(to_jsonb(OLD)) o
    JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
    WHERE o.value IS DISTINCT FROM n.value
      AND o.key NOT IN ('estado', 'fecha_entrega', 'updated_at');

    IF v_bloqueadas IS NOT NULL THEN
      RAISE EXCEPTION 'Un transportista solo puede confirmar la entrega. Columnas rechazadas: %',
        v_bloqueadas
        USING ERRCODE = '42501';
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado AND NEW.estado <> 'entregado' THEN
      RAISE EXCEPTION 'Un transportista solo puede marcar la entrega, no pasar el pedido a "%"',
        NEW.estado
        USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
  END IF;

  SELECT string_agg(o.key, ', ' ORDER BY o.key) INTO v_bloqueadas
  FROM jsonb_each(to_jsonb(OLD)) o
  JOIN jsonb_each(to_jsonb(NEW)) n ON n.key = o.key
  WHERE o.value IS DISTINCT FROM n.value
    AND o.key IN (
      'total', 'total_neto', 'total_iva', 'total_real', 'monto_pagado',
      'estado_pago', 'cliente_id', 'sucursal_id', 'usuario_id', 'creado_por',
      'preventista_id', 'tipo_factura', 'stock_descontado', 'offline_id'
    );

  IF v_bloqueadas IS NOT NULL THEN
    RAISE EXCEPTION 'No tenes permiso para modificar estas columnas de pedidos: %',
      v_bloqueadas
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. El trigger pasa a correr también en INSERT
-- ---------------------------------------------------------------------------
-- Se llama igual que antes. Por orden alfabético queda ANTES que
-- `trg_pedidos_cliente_asignado` (216) y `trg_pedidos_cliente_reservado` (214),
-- que son los otros dos BEFORE INSERT de la tabla. No se pisan: cada uno mira
-- otra cosa —la atribución acá, el cliente ajeno en la 216, el reservado en la
-- 214— y cada uno tira su propio mensaje. Si un INSERT viola dos reglas a la
-- vez, gana el mensaje de éste, que es igual de específico.

DROP TRIGGER IF EXISTS pedidos_proteger_columnas ON public.pedidos;
CREATE TRIGGER pedidos_proteger_columnas
  BEFORE INSERT OR UPDATE ON public.pedidos
  FOR EACH ROW
  EXECUTE FUNCTION public.pedidos_proteger_columnas();

-- ---------------------------------------------------------------------------
-- 3. ACL
-- ---------------------------------------------------------------------------
-- Una función de trigger no necesita EXECUTE para NADIE: la invoca el executor
-- como parte del DML, no el caller. `CREATE OR REPLACE` conserva el ACL que ya
-- tenía (postgres + service_role), pero se reafirma acá porque una función que
-- se reescribe entera merece que su ACL quede escrito al lado, y porque el gate
-- de CI (scripts/check-permisos.mjs) falla ante cualquier función alcanzable
-- con la anon key.

REVOKE ALL ON FUNCTION public.pedidos_proteger_columnas()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Verificación
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_acl text;
  v_eventos int;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'pedidos_proteger_columnas';

  IF v_acl IS NULL OR v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas quedo ejecutable por PUBLIC: %', coalesce(v_acl, '(default)');
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl LIKE '%authenticated=%' THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas quedo ejecutable por authenticated: %', v_acl;
  END IF;

  -- Que el trigger haya quedado en INSERT **y** UPDATE: si se pierde el UPDATE,
  -- se apaga toda la proteccion de columnas que ya existia y nada lo delata.
  SELECT t.tgtype::int INTO v_eventos
    FROM pg_trigger t
   WHERE t.tgrelid = 'public.pedidos'::regclass AND t.tgname = 'pedidos_proteger_columnas';

  IF v_eventos IS NULL THEN
    RAISE EXCEPTION 'el trigger pedidos_proteger_columnas no existe';
  END IF;
  IF (v_eventos & 4) = 0 THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas no quedo en INSERT (tgtype=%)', v_eventos;
  END IF;
  IF (v_eventos & 16) = 0 THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas perdio el UPDATE (tgtype=%)', v_eventos;
  END IF;
  IF (v_eventos & 2) = 0 THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas no quedo BEFORE (tgtype=%)', v_eventos;
  END IF;

  -- La funcion NO puede ser SECURITY DEFINER: adentro de una definer
  -- `current_user` es el dueño, la primera linea daria siempre true y toda la
  -- proteccion se apagaria en silencio.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'pedidos_proteger_columnas' AND p.prosecdef
  ) THEN
    RAISE EXCEPTION 'pedidos_proteger_columnas quedo SECURITY DEFINER: current_user dejaria de ser authenticated y el guard se apaga';
  END IF;
END
$verif$;

COMMIT;
