-- Congelar el costo historico de las lineas que no lo tienen (#493, #494)
--
-- reporte_gerencial calcula el CMV con
--   COALESCE(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real, ...)
-- y el snapshot recien arranco el 2026-06-05. Para todo lo anterior cae al costo
-- de HOY, asi que el margen historico se calcula con precios de reposicion
-- actuales. Medido: el CMV del periodo sin snapshot da $69,65M a costo vivo
-- contra $65,06M a costo historico -- esta inflado en $4,59M (-6,6%).
--
-- Se llena SOLO costo_unitario_al_crear. No se tocan cantidad, precio_unitario
-- ni subtotal: pedido_items tiene dos triggers de validacion en UPDATE
-- (trg_validar_minimo_venta_item, trg_validar_precio_item_pedido) que despiertan
-- si se toca la venta, y ademas reescribir una venta ya facturada no es una
-- correccion contable, es otra cosa.
--
-- LA GUARDA, que es lo importante:
-- El costo historico sale de la ultima compra anterior al pedido. Eso falla
-- cuando la unidad de medida cambio entre la compra y la venta, y en este
-- catalogo pasa: hay productos comprados sueltos y vendidos por pack (SAL01
-- "SAL FINA X 500 GRS X 10 UDS", "PINDAPOY 200cc x 18", "AZUCAR X 1KG X 10") y
-- tambien el caso espejo (fideos comprados por pack y vendidos sueltos).
--
-- El umbral no es inventado: al medir la distribucion de costo/precio sobre las
-- 7.319 lineas reconstruibles, la banda 0.20-0.40 quedo COMPLETAMENTE VACIA.
-- Los datos sanos viven en >=0.40 (mediana 0.577) y las anomalias en <0.20, sin
-- nada en el medio. Ese hueco es la firma del desfasaje x10/x18. Se toma
-- 0.20 <= costo/precio <= 1.10 y las 277 lineas de las dos colas se dejan en
-- NULL: siguen cayendo al costo vivo, igual que hoy, sin empeorar nada.
--
-- Esto resuelve tambien el #494 sin caso especial. SAL01 en abril se compro Y se
-- vendio suelto ($180 vs $205, ratio 0.87): pasa la guarda y queda con su costo
-- real, con lo que el CMV de abril baja de $1.440.000 a $144.000 y el margen
-- negativo ficticio de -$1,27M desaparece. Las lineas de mayo en adelante, que
-- se vendieron por bulto, dan ratio 0.08 y quedan afuera -- que es correcto,
-- porque para esas el costo vivo ($1.800 el bulto) ES el costo bueno.
--
-- Las bonificaciones quedan afuera a proposito: tienen precio 0, asi que la
-- guarda no las puede evaluar, y su costeo tiene su propia complejidad de
-- botellas-vs-fardos que no corresponde tocar acá.
--
-- Reversible: solo escribe donde hoy hay NULL. Para volver atras basta poner
-- NULL en las mismas filas.

BEGIN;

WITH candidatas AS (
  SELECT pi.id, pi.precio_unitario,
    (SELECT ci.costo_unitario
     FROM compra_items ci JOIN compras c ON c.id = ci.compra_id
     WHERE ci.producto_id = pi.producto_id
       AND c.fecha_compra <= pe.fecha
       AND COALESCE(c.estado,'') <> 'cancelada'
       AND ci.costo_unitario > 0
     ORDER BY c.fecha_compra DESC, c.id DESC
     LIMIT 1) AS costo_hist
  FROM pedido_items pi
  JOIN pedidos pe ON pe.id = pi.pedido_id
  WHERE pi.costo_unitario_al_crear IS NULL
    AND COALESCE(pi.es_bonificacion, false) = false
    AND pi.precio_unitario > 0
)
UPDATE pedido_items pi
SET costo_unitario_al_crear = c.costo_hist
FROM candidatas c
WHERE pi.id = c.id
  AND c.costo_hist IS NOT NULL
  AND c.costo_hist / c.precio_unitario BETWEEN 0.20 AND 1.10;

COMMENT ON COLUMN pedido_items.costo_unitario_al_crear IS
  'Costo unitario congelado al crear la linea (COALESCE de costo_promedio, '
  'costo_real, costo_sin_iva+II). Las lineas anteriores al 2026-06-05 lo tienen '
  'backfilleado por la mig 202 desde la ultima compra previa, con guarda de '
  'unidad de medida. NULL = no reconstruible; el reporte cae al costo vivo.';

COMMIT;
