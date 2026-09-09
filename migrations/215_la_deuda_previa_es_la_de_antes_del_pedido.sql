-- La deuda previa de un pedido es la de ANTES del pedido, no el saldo de hoy
--
-- El aviso de deuda en la tarjeta del pedido (PR #530) derivaba el numero de
-- `clientes.saldo_cuenta` restandole la parte impaga de ESE pedido, para
-- quedarse con "lo anterior". El calculo estaba bien y la premisa mal:
-- `saldo_cuenta` es un escalar del PRESENTE, asi que lo que quedaba incluia
-- tambien los pedidos POSTERIORES. Cada pedido nuevo inflaba el aviso de todas
-- las tarjetas viejas del mismo cliente. Medido antes de esta migracion: de
-- 1.083 tarjetas que mostraban el aviso, 1.009 eran falsas -- el 93% -- con
-- hasta $1.834.150 de sobreestimacion en una sola tarjeta.
--
-- La deuda que habia AL MOMENTO de un pedido no se puede derivar de un escalar:
-- hay que sumar lo impago de los pedidos ANTERIORES de ese cliente y restarle
-- los pagos a cuenta anteriores. Es la misma formula canonica del saldo (la que
-- usa la mig 199), pero cortada en el instante del pedido.
--
-- POR QUE ES UNA COMPUTED COLUMN Y NO UN RPC
-- Viaja dentro del `select` de pedidos que el front ya hace: cero queries
-- nuevas, y no es un embed, asi que no puede volverse ambiguo (PGRST201).
--
-- POR QUE ES SECURITY DEFINER
-- La RLS de `pedidos` (`mt_pedidos_select`) le muestra al preventista solo SUS
-- pedidos: medido con su propio JWT, 1.330 de 5.612. Una funcion invoker
-- sumaria unicamente esos, e ignoraria los que le cargo al mismo cliente otro
-- preventista, o un admin, o un encargado.
--
-- Con los datos de hoy la diferencia no se ve: los dos unicos pedidos cuya
-- deuda previa viene de otro vendedor son de un admin, para quien la RLS no
-- aplica. Pero hay una contradiccion que si es actual: el aviso del ALTA sale
-- de `clientes.saldo_cuenta`, que no pasa por RLS y suma todo. Con una funcion
-- invoker, el mismo cliente mostraria una deuda en el alta y otra --menor-- en
-- la tarjeta, sin que nada lo explique.
--
-- No agrega exposicion: ese total ya lo ve cualquiera de ellos en
-- `clientes.saldo_cuenta`, que incluye lo mismo y mas.
--
-- LA GUARDA QUE NO ES OBVIA
-- Una computed column tambien es invocable como RPC, y ahi el caller elige el
-- contenido de la fila. Si la funcion confiara en el `cliente_id`/`sucursal_id`
-- que le pasan, un authenticated podria pedir la deuda de cualquier cliente de
-- CUALQUIER sucursal inventandose una fila -- rompiendo el aislamiento por
-- sucursal, que no depende de la buena fe del caller en ningun otro lado.
-- Por eso NO se usa nada de `p` salvo `p.id`: el cliente, la fecha y la
-- sucursal se releen de la tabla, y filtrados por `current_sucursal_id()`. Una
-- fila inventada no matchea y devuelve 0.
--
-- Revertir: `DROP FUNCTION public.deuda_previa(public.pedidos);`. El front deja
-- de mostrar el aviso en la tarjeta; nada mas depende de ella.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.deuda_previa(p public.pedidos)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH ref AS (
    -- Solo `p.id` viene del caller; el resto se relee. Ver LA GUARDA arriba.
    SELECT pe.cliente_id, pe.created_at, pe.id, pe.sucursal_id
    FROM pedidos pe
    WHERE pe.id = p.id
      AND pe.sucursal_id = current_sucursal_id()
  )
  SELECT GREATEST(0, ROUND(
      COALESCE((
        SELECT SUM(GREATEST(0, p2.total - COALESCE(p2.monto_pagado, 0)))
        FROM pedidos p2, ref
        WHERE p2.cliente_id  = ref.cliente_id
          AND p2.sucursal_id = ref.sucursal_id
          -- Un pedido cancelado tiene total 0 (mig 175) y no deberia sumar
          -- igual; se excluye explicito para no depender de eso.
          AND p2.estado NOT IN ('cancelado', 'anulado')
          -- Desempate por id: dos pedidos pueden compartir `created_at`.
          AND (p2.created_at, p2.id) < (ref.created_at, ref.id)
      ), 0)
    - COALESCE((
        SELECT SUM(pg.monto)
        FROM pagos pg, ref
        WHERE pg.cliente_id  = ref.cliente_id
          AND pg.sucursal_id = ref.sucursal_id
          -- pedido_id IS NULL = pago a cuenta. Los pagos contra un pedido ya
          -- estan en su `monto_pagado`; contarlos aca los restaria dos veces.
          AND pg.pedido_id IS NULL
          AND pg.created_at < ref.created_at
      ), 0)
  , 2));
$$;

COMMENT ON FUNCTION public.deuda_previa(public.pedidos) IS
  'Deuda del cliente inmediatamente ANTES de este pedido (computed column de PostgREST). '
  'No es el saldo de hoy: excluye este pedido y todos los posteriores.';

-- Supabase le da EXECUTE a PUBLIC (implicito) y a anon (explicito) a toda
-- funcion nueva; revocar una sola mitad no cierra nada. `authenticated` si lo
-- necesita: PostgREST evalua la computed column como el usuario logueado.
REVOKE ALL ON FUNCTION public.deuda_previa(public.pedidos) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.deuda_previa(public.pedidos) TO authenticated;

DO $verif$
DECLARE
  v_abiertas text;
  v_definer  boolean;
  v_malos    int;
BEGIN
  -- 1. Ni PUBLIC (entrada sin grantee, arranca con '=') ni anon.
  SELECT array_to_string(array_agg(a::text), ' ') INTO v_abiertas
  FROM pg_proc p, unnest(p.proacl) a
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = 'deuda_previa'
    AND (a::text LIKE '=%' OR a::text LIKE 'anon=%');
  IF v_abiertas IS NOT NULL THEN
    RAISE EXCEPTION 'mig 215: el ACL quedo abierto (%).', v_abiertas;
  END IF;

  -- 2. Sin DEFINER la RLS la vaciaria para el preventista, en silencio.
  SELECT p.prosecdef INTO v_definer
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'deuda_previa';
  IF NOT COALESCE(v_definer, false) THEN
    RAISE EXCEPTION 'mig 215: la funcion no quedo SECURITY DEFINER.';
  END IF;

  -- 3. Invariante: el PRIMER pedido de cada cliente no puede tener deuda
  --    previa por pedidos (no hay ninguno antes). Es la prueba de que corta
  --    en el instante correcto y no arrastra los posteriores, que es el bug
  --    que esta migracion existe para cerrar. Se mira contra la suma cruda,
  --    sin los pagos a cuenta, que si pueden ser anteriores a todo.
  SELECT count(*) INTO v_malos
  FROM (
    SELECT DISTINCT ON (pe.cliente_id) pe.id, pe.cliente_id, pe.created_at, pe.sucursal_id
    FROM pedidos pe
    WHERE pe.estado NOT IN ('cancelado', 'anulado')
    ORDER BY pe.cliente_id, pe.created_at, pe.id
  ) primeros
  WHERE COALESCE((
          SELECT SUM(GREATEST(0, p2.total - COALESCE(p2.monto_pagado, 0)))
          FROM pedidos p2
          WHERE p2.cliente_id  = primeros.cliente_id
            AND p2.sucursal_id = primeros.sucursal_id
            AND p2.estado NOT IN ('cancelado', 'anulado')
            AND (p2.created_at, p2.id) < (primeros.created_at, primeros.id)
        ), 0) <> 0;
  IF v_malos > 0 THEN
    RAISE EXCEPTION 'mig 215: % primeros pedidos tendrian deuda previa; el corte temporal esta mal.', v_malos;
  END IF;
END
$verif$;

COMMIT;
