/**
 * Columnas de `Gasto` a mano: un `*` no distingue lo que la tabla sume mañana.
 * Vive aparte para que `useGastosQuery` y `useVehiculosQuery` (la ficha del
 * vehículo lee gastos) la compartan sin importarse entre sí.
 */
export const GASTO_COLUMNAS = [
  'id', 'sucursal_id', 'compartido', 'fecha', 'rubro_id', 'monto_total', 'comprobante',
  'comprobante_numero', 'alicuota_iva', 'iva', 'percepcion_iva', 'percepcion_iibb',
  'otros_impuestos', 'neto', 'costo', 'vehiculo_id', 'litros', 'mes_imputado',
  'repartir_meses', 'mes_fin', 'origen_pago', 'observacion', 'creado_por', 'anulado_at',
  'created_at',
  'rubro:gasto_rubros(id,nombre,grupo)',
  'vehiculo:vehiculos(id,patente,descripcion)',
].join(',')
