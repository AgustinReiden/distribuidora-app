-- #1124 · La familia compras (compras, compra_items, compra_cargos y
-- compra_cargo_repartos) se escribe sólo por sus RPC; por REST, sólo se lee.
--
-- EL BUG
--   La 352 cerró la escritura REST de las notas de crédito y custodió con
--   triggers la compra CON notas, pero el resto de la familia seguía abierta:
--   authenticated y anon tenían todos los grants de tabla (INSERT, UPDATE,
--   DELETE, TRUNCATE) y las policies mt_<t>_insert/update/delete dejaban pasar
--   al admin (el INSERT también al depósito). Por REST un admin podía:
--   · PATCH compras.estado = 'cancelada' sobre una compra SIN notas: no revierte
--     el stock (anular_compra_atomica sí), y el trigger de la 224
--     (borrar_lotes_compra_cancelada) le borra los lotes, así que el stock queda
--     inflado y la mercadería pasa a la bolsa "sin vencimiento". Además la
--     compra sale de posicion_fiscal y del gerencial.
--   · DELETE de una compra sin notas: se lleva por CASCADE ítems, cargos,
--     repartos y lotes sin tocar el stock.
--   · PATCH de subtotal / iva / impuestos_internos / total, y escrituras
--     directas sobre compra_items, compra_cargos y compra_cargo_repartos, que
--     saltean los controles de actualizar_compra_items (#1077, la ventana de 7
--     días, el costo promedio de la 236 y los lotes).
--   · El depósito, insertar una compra suelta: sin stock, sin lotes y sin ledger
--     (registrar_compra_completa le exige admin o encargado).
--   El front sólo lee estas tablas (useComprasQuery, analyticsExport y el
--   conteo de useBackup); la cola offline no encola compras. Al escribir esto,
--   en prod: 0 perfiles con rol 'deposito', y audit_logs de compras sin ningún
--   DELETE.
--
-- EL ARREGLO (decisión del dueño, 2026-10-13: sólo cerrar REST, sin trigger)
--   · DROP de las 12 policies de escritura (mt_<t>_insert/update/delete de las
--     cuatro tablas), incluido el INSERT del depósito.
--   · REVOKE INSERT, UPDATE, DELETE, TRUNCATE de las cuatro tablas a
--     authenticated y anon (el mismo set que revocó la 352).
--   Las únicas que escriben estas tablas son cuatro SECURITY DEFINER de
--   postgres —registrar_compra_completa, actualizar_compra_items,
--   anular_compra_atomica y cambiar_proveedor_compra— (re-verificado en
--   pg_proc antes de aplicar: ninguna INVOKER) y las tablas son de postgres,
--   que tiene BYPASSRLS y no hay FORCE RLS: no dependen de grants ni policies.
--
--   Por qué no un trigger que custodie la cancelación o el borrado, como la 352:
--   allá hacía falta porque el CASCADE del DELETE de la compra se llevaba las
--   notas corriendo como dueño. Acá ningún CASCADE llega a compras (sucursales
--   es NO ACTION, proveedores SET NULL), ninguna DEFINER hace DELETE FROM
--   compras, y el UPDATE de estado sólo lo hacen anular_compra_atomica y
--   cambiar_proveedor_compra, que ya deciden antes qué hacer con el stock y con
--   los lotes. Con esto quedan esas dos como los únicos caminos que cancelan una
--   compra («Cancelar una compra le borra los lotes: todo camino que cancele
--   decide antes»).
--
-- NO CAMBIA
--   Ninguna función (no hay CREATE ni CREATE OR REPLACE: nada que revocar a
--   PUBLIC/anon). Las policies mt_<t>_select y el SELECT de las cuatro tablas.
--   service_role y postgres. Los triggers de compras (audit_compras,
--   trg_compras_proteger_cancelacion de la 352, trg_lotes_compra_cancelada de la
--   224 y trigger_update_compras_timestamp). STK-F / STK-D: no se mueve stock.
--   COSTO-D: nadie escribe costo_unitario_al_crear. No se agrega check a
--   auditoria_integridad.
--
-- LO QUE QUEDA (a sabiendas)
--   · El mantenimiento manual de compras pasa a ser cosa de postgres.
--   · El SELECT de anon queda como está (las policies son TO authenticated).
--   · REFERENCES y TRIGGER se dejan, igual que en la 352.
--   · Sin trigger de custodia, una DEFINER futura que cancele o borre una compra
--     sin manejar stock ni lotes no tendría red: se decide al escribirla. El caso
--     I del ensayo sí atrapa una inversión del orden de la 229 en
--     anular_compra_atomica.
--   · Si el negocio quiere que el depósito cargue compras, va por RPC, en otro
--     issue.
--
-- Ensayo: scripts/test-compras-rest-1124.sql (falla antes, pasa después).
-- Ajustado en el mismo cambio: scripts/test-compra-nc-rest-1113.sql (sus casos
-- REST A, C y R pasan a esperar 42501; los UPDATE de J corren como postgres).

-- 1 · Las policies de escritura. La lectura queda en las mt_<t>_select.
DROP POLICY mt_compras_insert               ON public.compras;
DROP POLICY mt_compras_update               ON public.compras;
DROP POLICY mt_compras_delete               ON public.compras;
DROP POLICY mt_compra_items_insert          ON public.compra_items;
DROP POLICY mt_compra_items_update          ON public.compra_items;
DROP POLICY mt_compra_items_delete          ON public.compra_items;
DROP POLICY mt_compra_cargos_insert         ON public.compra_cargos;
DROP POLICY mt_compra_cargos_update         ON public.compra_cargos;
DROP POLICY mt_compra_cargos_delete         ON public.compra_cargos;
DROP POLICY mt_compra_cargo_repartos_insert ON public.compra_cargo_repartos;
DROP POLICY mt_compra_cargo_repartos_update ON public.compra_cargo_repartos;
DROP POLICY mt_compra_cargo_repartos_delete ON public.compra_cargo_repartos;

-- 2 · Los grants de escritura.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON public.compras, public.compra_items, public.compra_cargos, public.compra_cargo_repartos
  FROM authenticated, anon;

-- 3 · Verificación post-DDL.
DO $verif$
DECLARE
  v_t    text;
  v_rol  text;
  v_priv text;
  v_pols text[];
  v_n    int;
BEGIN
  FOREACH v_t IN ARRAY ARRAY['public.compras', 'public.compra_items',
                             'public.compra_cargos', 'public.compra_cargo_repartos'] LOOP
    FOREACH v_rol IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
        IF has_table_privilege(v_rol, v_t, v_priv) THEN
          RAISE EXCEPTION '#1124 · % conserva % sobre %', v_rol, v_priv, v_t;
        END IF;
      END LOOP;
    END LOOP;
    IF NOT has_table_privilege('authenticated', v_t, 'SELECT') THEN
      RAISE EXCEPTION '#1124 · authenticated perdió SELECT sobre %', v_t;
    END IF;
    FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
      IF NOT has_table_privilege('service_role', v_t, v_priv) THEN
        RAISE EXCEPTION '#1124 · service_role perdió % sobre %', v_priv, v_t;
      END IF;
    END LOOP;
  END LOOP;

  SELECT array_agg(tablename || '.' || policyname ORDER BY tablename, policyname) INTO v_pols
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename IN ('compras', 'compra_items', 'compra_cargos', 'compra_cargo_repartos');
  IF v_pols IS DISTINCT FROM ARRAY['compra_cargo_repartos.mt_compra_cargo_repartos_select',
                                   'compra_cargos.mt_compra_cargos_select',
                                   'compra_items.mt_compra_items_select',
                                   'compras.mt_compras_select'] THEN
    RAISE EXCEPTION '#1124 · las policies de la familia compras quedaron %', v_pols;
  END IF;

  SELECT count(*) INTO v_n
    FROM pg_trigger
   WHERE tgrelid = 'public.compras'::regclass
     AND tgname IN ('audit_compras', 'trg_compras_proteger_cancelacion',
                    'trg_lotes_compra_cancelada', 'trigger_update_compras_timestamp')
     AND tgenabled = 'O';
  IF v_n <> 4 THEN
    RAISE EXCEPTION '#1124 · los triggers de compras no están los cuatro habilitados (hay %)', v_n;
  END IF;
END
$verif$;
