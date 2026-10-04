/**
 * Una compra GUARDADA con la forma de la compra 304, para los tests del modo
 * 'editar'. Números SINTÉTICOS (el repo es público), hechos a mano:
 *
 *  - Flete 9.000, no gravado, fuera de factura, base 'cantidad' con pesos
 *    TIPEADOS (4 / 1 / 1 / 0,5) que no son las cantidades.
 *  - Pallets 4.000, no gravado, en factura (arman `no_gravado`), 2 / 2 / 1 / 1.
 *  - Bonificación 3L −6.000, gravada, en factura, base 'monto', que afecta la
 *    base del II y sólo pesa en la línea 13: 0 explícito en 11 y 12, y SIN fila
 *    de reparto en la 14.
 *  - II 10% en las líneas 13 y 14. La ficha de HOY dice otra cosa a propósito.
 *
 *  línea │ cant │ neto     │ flete 9.000 │ pallets 4.000 │ bonif −6.000 │ II 10%
 *  11    │ 240  │ 240.000  │ 5.538,45    │ 1.333,33      │ —            │ —
 *  12    │ 160  │ 240.000  │ 1.384,62    │ 1.333,33      │ —            │ —
 *  13    │  60  │ 120.000  │ 1.384,62    │   666,67      │ −6.000       │ 11.400
 *  14    │  75  │  60.000  │   692,31    │   666,67      │ —            │  6.000
 *
 *  costo_real: 11 = 1.028,6324 · 12 = 1.516,9872 · 13 = 2.124,1882 · 14 = 898,1197
 *
 *  Cabecera: subtotal 660.000; bonificaciones −6.000; IVA 21% sobre
 *  654.000 = 137.340; II 17.400; percepción IVA 1.234,50; no gravado 4.000
 *  (los pallets); total 813.974,50.
 */
import type { CompraDBExtended } from '../../types'

export const COSTOS_GUARDADOS_304: Record<string, number> = {
  '501': 1028.6324,
  '502': 1516.9872,
  '503': 2124.1882,
  '504': 898.1197,
}

export function compraTestigoEdicion(over: Partial<CompraDBExtended> = {}): CompraDBExtended {
  const item = (id: string, productoId: string, nombre: string, cantidad: number, costo: number, ii: number) => ({
    id, compra_id: '304', producto_id: productoId,
    producto: { id: productoId, nombre, codigo: null, impuestos_internos: 99, porcentaje_iva: 10.5, condicion_iva: 'exento' } as never,
    cantidad, costo_unitario: costo, bonificacion: 0, subtotal: cantidad * costo,
    porcentaje_iva: 21, condicion_iva: 'gravado' as const, impuestos_internos: ii,
    costo_real_unitario: COSTOS_GUARDADOS_304[productoId], stock_anterior: 0, stock_nuevo: cantidad,
  })
  return {
    id: '304',
    proveedor_id: '7',
    proveedor: { id: '7', nombre: 'Bebidas Testigo SA', cuit: '30-12345678-9' } as never,
    numero_factura: 'A0005-00012345',
    fecha_compra: '2026-09-12',
    created_at: '2026-09-12T15:30:00Z',
    tipo_factura: 'FC',
    forma_pago: 'transferencia',
    estado: 'recibida' as never,
    notas: 'Llegó con un pallet roto',
    subtotal: 660000,
    iva: 137340,
    impuestos_internos: 17400,
    percepcion_iva: 1234.5,
    percepcion_iibb: 0,
    no_gravado: 4000,
    bonificaciones: -6000,
    otros_impuestos: 0,
    total: 813974.5,
    ii_declarado: null,
    // Desordenadas a propósito: el embed no garantiza orden.
    items: [
      item('13', '503', 'Gaseosa 3L', 60, 2000, 10),
      item('11', '501', 'Agua 600 x12', 240, 1000, 0),
      item('14', '504', 'Gaseosa 500cc', 75, 800, 10),
      item('12', '502', 'Agua 2L', 160, 1500, 0),
    ],
    cargos: [
      {
        id: '92', orden: 2, concepto: 'Bonificacion 3L', monto: -6000,
        condicion_iva: 'gravado', en_factura: true, prorratea_al_costo: true,
        afecta_base_ii: true, base_prorrateo: 'monto',
        repartos: [
          { compra_item_id: '13', peso: 120000 },
          { compra_item_id: '11', peso: 0 },
          { compra_item_id: '12', peso: 0 },
        ],
      },
      {
        id: '90', orden: 0, concepto: 'Flete', monto: 9000,
        condicion_iva: 'no_gravado', en_factura: false, prorratea_al_costo: true,
        afecta_base_ii: false, base_prorrateo: 'cantidad',
        repartos: [
          { compra_item_id: '11', peso: 4 },
          { compra_item_id: '12', peso: 1 },
          { compra_item_id: '13', peso: 1 },
          { compra_item_id: '14', peso: 0.5 },
        ],
      },
      {
        id: '91', orden: 1, concepto: 'Pallets', monto: 4000,
        condicion_iva: 'no_gravado', en_factura: true, prorratea_al_costo: true,
        afecta_base_ii: false, base_prorrateo: 'cantidad',
        repartos: [
          { compra_item_id: '11', peso: 2 },
          { compra_item_id: '12', peso: 2 },
          { compra_item_id: '13', peso: 1 },
          { compra_item_id: '14', peso: 1 },
        ],
      },
    ],
    ...over,
  }
}
