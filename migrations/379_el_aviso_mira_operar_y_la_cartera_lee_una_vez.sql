-- 379 (número final al aplicar) · #1186 y #1187: el aviso mira operar y la cartera lee una vez
--
-- #1186 · El aviso a administración de verificar_duplicado_cliente mira OPERAR, no VER.
--   v_visible sigue la regla de mt_clientes_select (operar + historial de la 358 + reparto
--   de la 378), y el aviso 'cliente_duplicado_oculto' dependía de NOT v_visible: un vecino
--   que el preventista ve sólo por historial o por reparto no lo puede tomar, el alta se le
--   bloqueaba (o se le pedía confirmar) y administración no se enteraba. En prod eran 142
--   pares preventista–cliente, todos por historial.
--   ESTO REVIERTE A PROPÓSITO el "efecto declarado" de la 358 y de la 378 (el vecino
--   visible por historial o por reparto no disparaba 'cliente_duplicado_oculto').
--   v_operable = la regla de esClienteOperable (la rama de operar de mt_clientes_select):
--   sin asignar o asignado a él, y no reservado. Va por ROL BASE (perfiles.rol =
--   'preventista'), igual que v_es_prev, mt_clientes_select y esClienteOperable: el
--   preventista base con un extra de otro rol no cambia, y el extra 'preventista' no
--   avisa, a propósito, hasta que se abran los candados de rol (#1179, mig 377).
--   La lectura de clientes por id incluye INACTIVOS a propósito: el guard mira inactivos
--   desde la 199, y un vecino inactivo que no es de su cartera también se avisa.
--   cliente_visible sigue dependiendo de v_visible: no se le revela a nadie un cliente
--   que no ve.
--   Textos del aviso: el título de distancia pasa a '...muy cerca de otro que no es de su
--   cartera' y el cierre a 'Puede ser el mismo comercio: revisalo.' (el 'si corresponde,
--   asignáselo' no aplica a un reservado, y desde la 359 la asignación la manda la zona).
-- #1187 · mt_clientes_select: (SELECT auth.uid()) en las ramas de historial y de los suyos.
--   Con auth.uid() pelado, el SubPlan de historial (hasheado, corre una vez) recorría los
--   pedidos de toda la sucursal. Medido como preventista base de la sucursal 1 (mínimo de
--   5 corridas): 160 -> 83 ms (historial) -> 68 ms (además los suyos). Los clientes
--   visibles son los mismos. Las ramas de perfiles (preventista y depósito) no dependen de
--   la fila, ya son initPlan y medidas no ganan (67,6 ms): quedan peladas a propósito,
--   aunque el advisor auth_rls_initplan las siga marcando. La de reparto ya iba así (378).
--
-- NO CAMBIA: v_visible ni cliente_visible, el bloqueo y sus distancias, la deduplicación
--   del aviso (uno por día por vecino), quién lo recibe (_notificar_sucursal_roles), la
--   firma ni el ACL de verificar_duplicado_cliente, el front. No hay función ni tabla nueva.
-- Ensayo: scripts/test-duplicado-operable-y-cartera-1186-1187.sql.

SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION pg_temp.cc_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · #1187: la policy (guarda del estado previo: el md5 que dejó la 378)
-- ---------------------------------------------------------------------------
DO $guarda_policy$
BEGIN
  IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public'
        AND tablename = 'clientes' AND policyname = 'mt_clientes_select')
     IS DISTINCT FROM 'f715c80865fe01f8c0ab11f1a7c8a835' THEN
    RAISE EXCEPTION 'mt_clientes_select cambió desde el relevamiento: revisar a mano';
  END IF;
END
$guarda_policy$;

ALTER POLICY mt_clientes_select ON public.clientes
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      -- perfiles: no depende de la fila, ya es initPlan; no se envuelve (medido, #1187)
      NOT EXISTS (SELECT 1 FROM public.perfiles p WHERE p.id = auth.uid() AND p.rol = 'preventista')
      OR (
        (
          NOT EXISTS (SELECT 1 FROM public.cliente_preventistas cp WHERE cp.cliente_id = clientes.id)
          -- (SELECT auth.uid()): initPlan, entra por idx_cliente_preventistas_prev (#1187)
          OR EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                      WHERE cp.cliente_id = clientes.id AND cp.preventista_id = (SELECT auth.uid()))
        )
        AND NOT clientes.reservado_admin
      )
      -- Historial (358). (SELECT auth.uid()): entra por pedidos_usuario_fecha_idx (#1187)
      OR EXISTS (SELECT 1 FROM public.pedidos pe
                  WHERE pe.cliente_id = clientes.id AND pe.usuario_id = (SELECT auth.uid()))
      -- Reparto (#1182)
      OR EXISTS (SELECT 1 FROM public.pedidos pe
                  WHERE pe.cliente_id = clientes.id AND pe.transportista_id = (SELECT auth.uid())
                    AND pe.tipo_factura IS DISTINCT FROM 'VB')
    )
    AND NOT EXISTS (SELECT 1 FROM public.perfiles pd WHERE pd.id = auth.uid() AND pd.rol = 'deposito')
  );

-- ---------------------------------------------------------------------------
-- 2 · #1186: verificar_duplicado_cliente avisa por v_operable (parche por ancla)
-- ---------------------------------------------------------------------------
DO $duplicado$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)'::regprocedure);
  IF md5(v_def) <> '414aa889f25350e7e670a523e7bd2fe2' THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente cambió desde el relevamiento: revisar a mano';
  END IF;
  v_def := pg_temp.cc_parchar(v_def,
$o$  v_visible   boolean := true;
$o$,
$n$  v_visible   boolean := true;
  v_operable  boolean := true;
$n$, 'declaración de v_operable');
  v_def := pg_temp.cc_parchar(v_def,
$o$      INTO v_visible
      FROM clientes c
     WHERE c.id = v_id;
  END IF;$o$,
$n$      INTO v_visible
      FROM clientes c
     WHERE c.id = v_id;

    -- #1186: el aviso mira OPERAR, no ver (esClienteOperable; rama de operar de
    -- mt_clientes_select): sin asignar o asignado a él, y no reservado. Rol base, como
    -- v_es_prev. Por id, con inactivos (el guard los mira desde la 199).
    SELECT (
        (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
         OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                     WHERE cp.cliente_id = c.id AND cp.preventista_id = v_uid))
        AND NOT c.reservado_admin
      )
      INTO v_operable
      FROM clientes c
     WHERE c.id = v_id;
  END IF;$n$, 'cálculo de v_operable');
  v_def := pg_temp.cc_parchar(v_def,
$o$  IF v_es_prev AND NOT v_visible THEN$o$,
$n$  IF v_es_prev AND NOT v_operable THEN$n$, 'condición del aviso');
  v_def := pg_temp.cc_parchar(v_def,
$o$ELSE 'Alta de cliente muy cerca de otro que el preventista no ve' END,$o$,
$n$ELSE 'Alta de cliente muy cerca de otro que no es de su cartera' END,$n$, 'título del aviso');
  v_def := pg_temp.cc_parchar(v_def,
$o$'Puede ser el mismo comercio: si corresponde, asignáselo.',$o$,
$n$'Puede ser el mismo comercio: revisalo.',$n$, 'cierre del aviso');
  EXECUTE v_def;
END
$duplicado$;

-- ---------------------------------------------------------------------------
-- 3 · Comentarios
-- ---------------------------------------------------------------------------
COMMENT ON POLICY mt_clientes_select ON public.clientes IS
'Decide por perfiles.rol = ''preventista'' a propósito (#1179, unión de roles). Para el '
'preventista base: operar (huérfanos + los suyos, sin reservados), historial (358: ya le '
'vendió) y reparto (#1182: el cliente de un pedido que reparte, sin VB). Las ramas que '
'dependen de la fila comparan contra (SELECT auth.uid()) por rendimiento (#1182, #1187): '
'pelado, el SubPlan recorre los pedidos de toda la sucursal. Las de perfiles quedan peladas a '
'propósito: no dependen de la fila, ya son initPlan y medidas no ganan; el aviso del advisor '
'auth_rls_initplan sobre ellas se acepta. Ver no es operar: lo deciden mt_clientes_update, '
'clientes_proteger_columnas_preventista y los triggers de pedidos. Espejos: '
'verificar_duplicado_cliente (v_visible) y obtener_resumen_cuenta_cliente; si cambia uno, '
'cambian los otros. El aviso de verificar_duplicado_cliente mira operar (v_operable, #1186), no ver.';

COMMENT ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, bigint) IS
  'Única puerta del guard de clientes duplicados. Devuelve {bloquea, avisa, motivo, distancia_m, cliente_visible{id, codigo, nombre, activo}}. DOS reglas, las dos sobre el LUGAR: dirección normalizada con altura (bloqueo) y distancia real en metros (<1 m bloqueo, 1-30 m aviso). El nombre NO es parte del criterio desde la mig 260: marcaba homónimos, no duplicados; desde #688 tampoco está en la firma. El número que se le muestra al usuario es codigo, no id. SECURITY DEFINER: ve por encima de la RLS pero no revela la identidad de un cliente que al caller se le tapa (cliente_visible sigue v_visible, la regla de mt_clientes_select). El aviso a administración mira OPERAR (v_operable, #1186), no VER: sale también cuando el vecino se ve por historial (358) o por reparto (378) pero el preventista no puede operarlo. Por rol base, como v_es_prev. Fail-closed sin sesión o sin sucursal.';

-- ---------------------------------------------------------------------------
-- 4 · Verificación
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f_dup text := 'public.verificar_duplicado_cliente(numeric,numeric,text,bigint)';
  v_src text;
BEGIN
  IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public'
        AND tablename = 'clientes' AND policyname = 'mt_clientes_select')
     IS DISTINCT FROM 'c9a4aff2b69aabdb09bb712f66a05b55' THEN
    RAISE EXCEPTION 'mt_clientes_select no quedó con la qual ensayada';
  END IF;
  v_src := (SELECT prosrc FROM pg_proc WHERE oid = f_dup::regprocedure);
  IF position('NOT v_operable THEN' IN v_src) = 0 OR position('NOT v_visible THEN' IN v_src) > 0 THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente no decide el aviso por v_operable';
  END IF;
  IF position('transportista_id = v_uid' IN v_src) = 0 THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente perdió la rama de reparto de v_visible';
  END IF;
  IF position('asignáselo' IN v_src) > 0 OR position('que no es de su cartera' IN v_src) = 0 THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente no quedó con los textos nuevos del aviso';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        AND proname = 'verificar_duplicado_cliente') <> 1 THEN
    RAISE EXCEPTION 'apareció una sobrecarga de verificar_duplicado_cliente';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f_dup::regprocedure) THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente dejó de ser SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', f_dup::regprocedure, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', f_dup::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'ACL de verificar_duplicado_cliente: EXECUTE para anon o sin EXECUTE para authenticated';
  END IF;
  IF position('v_operable' IN coalesce(obj_description(f_dup::regprocedure, 'pg_proc'), '')) = 0 THEN
    RAISE EXCEPTION 'el COMMENT de verificar_duplicado_cliente no quedó actualizado';
  END IF;
END
$verif$;
