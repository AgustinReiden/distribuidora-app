-- Devolverle su cliente a los pedidos que quedo huerfanos (#490)
--
-- Nueve pedidos por $200.070 tenian cliente_id NULL. No fue un error de carga:
-- la FK pedidos_cliente_id_fkey era ON DELETE SET NULL, y alguien estuvo
-- deduplicando clientes -- creaba el nuevo y semanas despues borraba el viejo,
-- que se llevaba puestos sus pedidos en silencio.
--
-- La identidad NO se perdio: audit_logs guardo el UPDATE que disparo la FK, con
-- el cliente_id original de cada pedido. Los sucesores se identificaron por
-- direccion exacta:
--   282 "AMADOR LUCERO 2397"      -> 653 (misma direccion, Amador Lucero 2397)
--   823 "Despensa/Aguirre Cristina"-> 824 (mismo nombre y razon social, misma calle)
--   395 "Miranda dora"            -> 335 (razon social DORA MIRANDA, Pje Magallanes)
--   47  "SAN LORENZO Y CNEL ZELAYA"-> sin sucesor; se recrea desde el audit.
--
-- El zona_id original (13, "ZONA 1. JOAQUIN") ya no existe: el esquema de zonas
-- se reorganizo y hoy son Osvaldo/Marcelo/Christian. La FK compuesta
-- (zona_id, sucursal_id) rechaza el insert. Se guarda NULL y se conserva el
-- texto de la zona como dato historico: asignarle una zona actual seria inventar.
--
-- OJO: trigger_actualizar_saldo_pedido es UPDATE **OF total, monto_pagado**, asi
-- que mover cliente_id NO lo dispara. Los saldos se recalculan explicitamente al
-- final, con la formula canonica (verificada: reproduce los 702 saldos actuales).

BEGIN;

-- 1. Recrear el cliente 47 con los datos exactos que guardo el audit.
--    Inactivo: no es cartera viva, existe para que su pedido tenga dueno.
INSERT INTO clientes (
  id, codigo, nombre_fantasia, razon_social, direccion, telefono, contacto,
  latitud, longitud, zona, zona_id, cuit, tipo_documento, sucursal_id,
  horarios_atencion, horarios_atencion_original, notas,
  limite_credito, dias_credito, descuento_porcentaje, tipo_factura_default,
  saldo_cuenta, activo
)
SELECT
  47, 35, 'SAN LORENZO Y CORONEL ZELAYA', 'SAN LORENZO Y CORONEL ZELAYA',
  'Combate de San Lorenzo 2699, T4000CCI San Miguel de Tucuman, Tucuman, Argentina',
  '3813333456', 'MARCELO', -26.8264080, -65.2388950, 'ZONA 1. JOAQUIN', NULL,
  '00-00000001-3', 'CUIT', 1, '08:30-14:00', '8:30 A 14',
  'LOCAL 21 -- recreado por la migracion de huerfanos: se habia borrado el 2026-07-28 y dejo el pedido 1649 sin dueno.',
  0.00, 30, 0.00, 'ZZ', 0.00, false
WHERE NOT EXISTS (SELECT 1 FROM clientes WHERE id = 47);

-- 2. Reatribuir. Se lee el mapa del audit, no se hardcodean ids de pedido: si
--    aparecio otro huerfano desde que se escribio esto, entra solo.
WITH perdidos AS (
  SELECT DISTINCT ON (registro_id::bigint)
         registro_id::bigint AS pedido_id,
         (old_data->>'cliente_id')::bigint AS cliente_viejo
  FROM audit_logs
  WHERE tabla = 'pedidos' AND accion = 'UPDATE'
    AND old_data->>'cliente_id' IS NOT NULL
    AND new_data->>'cliente_id' IS NULL
  ORDER BY registro_id::bigint, created_at DESC
), mapa(viejo, nuevo) AS (
  VALUES (282::bigint, 653::bigint), (823, 824), (395, 335), (47, 47)
)
UPDATE pedidos pe
SET cliente_id = m.nuevo
FROM perdidos p
JOIN mapa m ON m.viejo = p.cliente_viejo
WHERE pe.id = p.pedido_id
  AND pe.cliente_id IS NULL
  AND EXISTS (SELECT 1 FROM clientes c WHERE c.id = m.nuevo);

-- 3. Recalcular el saldo de los clientes tocados (el trigger no se entera).
UPDATE clientes c
SET saldo_cuenta =
  COALESCE((SELECT SUM(p.total - COALESCE(p.monto_pagado, 0)) FROM pedidos p
            WHERE p.cliente_id = c.id AND p.estado NOT IN ('cancelado','anulado')), 0)
  - COALESCE((SELECT SUM(pg.monto) FROM pagos pg
              WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL), 0)
WHERE c.id IN (653, 824, 335, 47);

-- 4. Guarda: si quedo algun huerfano, la migracion no sirvio. Abortar.
DO $$
DECLARE v_quedan int;
BEGIN
  SELECT count(*) INTO v_quedan FROM pedidos WHERE cliente_id IS NULL;
  IF v_quedan > 0 THEN
    RAISE EXCEPTION 'Quedan % pedidos sin cliente; la reatribucion no cubrio todos', v_quedan;
  END IF;
END $$;

COMMIT;
