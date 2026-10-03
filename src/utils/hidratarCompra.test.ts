/**
 * Caracterización de la hidratación de una compra guardada.
 *
 * El fixture es SINTÉTICO (el repo es público) pero tiene la forma de la compra
 * 304 que motivó el diseño:
 *  - un flete con base 'cantidad' y pesos TIPEADOS a mano (4 / 1 / 1 / 0,5) que
 *    no son las cantidades: si algo recalculara el pre-llenado, quedarían 240 /
 *    160 / 60 / 75 y el flete se repartiría distinto;
 *  - pallets no gravados en factura, que son los que arman `compras.no_gravado`;
 *  - una bonificación gravada con base 'monto' que sólo toca una línea: peso 0
 *    explícito en dos líneas y SIN fila de reparto en la otra (las dos formas en
 *    que la base dice "excluida"), y que afecta la base del impuesto interno.
 *
 * Los `costo_real_unitario` del fixture están hechos a mano (cuentas abajo), no
 * copiados de una corrida del motor: si la hidratación o el motor se corren, el
 * test lo dice.
 */
import { describe, it, expect } from 'vitest'
import { hidratarCompraGuardada } from './hidratarCompra'
import { calcularCostosCompra } from './prorrateoCompra'
import { redondearSQL } from './calculations'
import {
  compraReducer, lineasParaMotor, cargosParaMotor, iiDeclaradoParaMotor,
} from '../components/modals/ModalCompra.reducer'
import type { CompraDBExtended } from '../types'

/*
 * Cuentas a mano (FC, IVA 21):
 *  línea │ cant │ neto     │ flete 9.000 (4/1/1/0,5) │ pallets 4.000 (2/2/1/1) │ bonif −6.000 │ II 10%
 *  11    │ 240  │ 240.000  │ 5.538,45 (residuo)      │ 1.333,33 (residuo)      │ —            │ —
 *  12    │ 160  │ 240.000  │ 1.384,62                │ 1.333,33                │ —            │ —
 *  13    │  60  │ 120.000  │ 1.384,62                │   666,67                │ −6.000       │ 10% s/114.000 = 11.400
 *  14    │  75  │  60.000  │   692,31                │   666,67                │ —            │ 10% s/60.000  =  6.000
 *
 *  costo_real = (neto + cargos gravados al costo + II + no gravados al costo) / cant
 *  11: (240.000 + 6.871,78) / 240            = 1.028,6324
 *  12: (240.000 + 2.717,95) / 160            = 1.516,9872
 *  13: (114.000 + 11.400 + 2.051,29) / 60    = 2.124,1882
 *  14: (60.000 + 6.000 + 1.358,98) / 75      =   898,1197
 */
function compraTestigo(noGravado = 4000): CompraDBExtended {
  const item = (id: string, productoId: string, nombre: string, cantidad: number, costo: number, ii: number, costoReal: number) => ({
    id, compra_id: '304', producto_id: productoId,
    // La ficha de HOY dice otra cosa a propósito: la hidratación no la mira.
    producto: { id: productoId, nombre, codigo: null, impuestos_internos: 99, porcentaje_iva: 10.5, condicion_iva: 'exento' } as never,
    cantidad, costo_unitario: costo, bonificacion: 0, subtotal: cantidad * costo,
    porcentaje_iva: 21, condicion_iva: 'gravado' as const, impuestos_internos: ii,
    costo_real_unitario: costoReal, stock_anterior: 0, stock_nuevo: cantidad,
  })
  return {
    id: '304',
    proveedor_id: '7',
    proveedor: { id: '7', nombre: 'Bebidas Testigo SA' } as never,
    numero_factura: 'A0005-00012345',
    fecha_compra: '2026-09-12',
    tipo_factura: 'FC',
    forma_pago: 'transferencia',
    estado: 'activa',
    subtotal: 654000,
    iva: 0,
    total: 0,
    no_gravado: noGravado,
    percepcion_iva: 1234.5,
    percepcion_iibb: 0,
    ii_declarado: null,
    // Desordenadas a propósito: el embed no garantiza orden.
    items: [
      item('13', '503', 'Gaseosa 3L', 60, 2000, 10, 2124.1882),
      item('11', '501', 'Agua 600 x12', 240, 1000, 0, 1028.6324),
      item('14', '504', 'Gaseosa 500cc', 75, 800, 10, 898.1197),
      item('12', '502', 'Agua 2L', 160, 1500, 0, 1516.9872),
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
          // la 14 no tiene fila: también es exclusión
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
  }
}

describe('hidratarCompraGuardada (forma de la compra 304)', () => {
  it('numera las líneas por id de compra_items y toma el snapshot, no la ficha', () => {
    const { estado, itemPorLinea } = hidratarCompraGuardada(compraTestigo())
    expect(estado.items.map(i => [i.lineaId, i.productoId])).toEqual([[1, '501'], [2, '502'], [3, '503'], [4, '504']])
    expect(itemPorLinea.get(3)?.id).toBe('13')
    const tres = estado.items[2]
    expect(tres).toMatchObject({ impuestosInternos: 10, porcentajeIva: 21, condicionIva: 'gravado', costoUnitario: 2000, cantidad: 60 })
    expect(estado).toMatchObject({
      proveedorId: '7', proveedorNombre: 'Bebidas Testigo SA', usarProveedorNuevo: false,
      numeroFactura: 'A0005-00012345', fechaCompra: '2026-09-12', formaPago: 'transferencia',
      tipoFactura: 'FC', percepcionIva: 1234.5,
    })
  })

  it('los pesos son los guardados, todos manuales, y el sin-reparto es 0', () => {
    const { estado } = hidratarCompraGuardada(compraTestigo())
    const [flete, pallets, bonif] = estado.cargos
    expect(estado.cargos.map(c => c.concepto)).toEqual(['Flete', 'Pallets', 'Bonificacion 3L'])
    expect(flete.pesos).toEqual({ 1: 4, 2: 1, 3: 1, 4: 0.5 })
    expect(pallets.pesos).toEqual({ 1: 2, 2: 2, 3: 1, 4: 1 })
    expect(bonif.pesos).toEqual({ 1: 0, 2: 0, 3: 120000, 4: 0 })
    for (const c of estado.cargos) {
      expect(c.pesosManuales).toEqual({ 1: true, 2: true, 3: true, 4: true })
      expect(c.afectaBaseIIManual).toBe(true)
    }
    expect(estado.cargos.map(c => c.afectaBaseII)).toEqual([false, false, true])
  })

  it('el costo por línea que deriva el motor es el guardado', () => {
    const { estado, costoGuardadoPorLinea } = hidratarCompraGuardada(compraTestigo())
    const costos = calcularCostosCompra(
      lineasParaMotor(estado.items, estado.tipoFactura),
      cargosParaMotor(estado.cargos),
      iiDeclaradoParaMotor(estado.iiDeclarado, estado.tipoFactura),
    )
    for (const l of costos.lineas) {
      expect(redondearSQL(l.costoRealUnitario, 4)).toBe(costoGuardadoPorLinea.get(l.id))
    }
  })

  it('pasar por el reducer no recalcula nada: ni HIDRATAR ni una acción que re-sincroniza', () => {
    const { estado } = hidratarCompraGuardada(compraTestigo())
    expect(compraReducer(estado, { type: 'HIDRATAR', payload: estado })).toBe(estado)
    // Tocar una línea SÍ corre el wrapper (sincronizarCargos + solver): las
    // marcas de manual son lo que impide que el flete vuelva a 240/160/60/75.
    const tocado = compraReducer(estado, { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 240 } })
    expect(tocado.cargos.map(c => c.pesos)).toEqual(estado.cargos.map(c => c.pesos))
    expect(tocado.cargos.map(c => c.afectaBaseII)).toEqual([false, false, true])
    expect(tocado.noGravado).toBe(4000)
  })

  it('control: sin las marcas de manual el wrapper SÍ pisaría los pesos tipeados', () => {
    const { estado } = hidratarCompraGuardada(compraTestigo())
    const sinMarcas = { ...estado, cargos: estado.cargos.map(c => ({ ...c, pesosManuales: {} })) }
    const tocado = compraReducer(sinMarcas, { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 240 } })
    expect(tocado.cargos[0].pesos).toEqual({ 1: 240, 2: 160, 3: 60, 4: 75 })
  })

  it('noGravadoManual sólo si lo guardado difiere de los cargos', () => {
    const igual = hidratarCompraGuardada(compraTestigo(4000)).estado
    expect(igual).toMatchObject({ noGravado: 4000, noGravadoManual: false })
    const distinto = hidratarCompraGuardada(compraTestigo(4500)).estado
    expect(distinto).toMatchObject({ noGravado: 4500, noGravadoManual: true })
    // Y el wrapper respeta lo tipeado.
    const tocado = compraReducer(distinto, { type: 'ACTUALIZAR_ITEM', payload: { index: 0, campo: 'cantidad', valor: 240 } })
    expect(tocado.noGravado).toBe(4500)
  })

  it('sin líneas ni cargos (lo que deja la RLS) no rompe: lo avisa', () => {
    const compra = { ...compraTestigo(), items: [], cargos: [] }
    const r = hidratarCompraGuardada(compra)
    expect(r.sinLineas).toBe(true)
    expect(r.estado.items).toEqual([])
    expect(r.estado.cargos).toEqual([])
  })

  it('ZZ: el costo guardado es lo pagado más los cargos, sin II', () => {
    const compra: CompraDBExtended = {
      ...compraTestigo(),
      tipo_factura: 'ZZ',
      no_gravado: 0,
      items: [{
        id: '1', compra_id: '9', producto_id: '501', cantidad: 10, costo_unitario: 121, bonificacion: 0,
        impuestos_internos: 10, porcentaje_iva: 21, condicion_iva: 'gravado', costo_real_unitario: 126,
      }],
      cargos: [{
        id: '1', orden: 0, concepto: 'Flete', monto: 50, condicion_iva: 'no_gravado', en_factura: false,
        prorratea_al_costo: true, afecta_base_ii: false, base_prorrateo: 'unidades',
        repartos: [{ compra_item_id: '1', peso: 1 }],
      }],
    }
    const { estado, costoGuardadoPorLinea } = hidratarCompraGuardada(compra)
    const costos = calcularCostosCompra(lineasParaMotor(estado.items, 'ZZ'), cargosParaMotor(estado.cargos), {})
    expect(redondearSQL(costos.lineas[0].costoRealUnitario, 4)).toBe(costoGuardadoPorLinea.get(1))
  })

  it('el II declarado vuelve con claves numéricas', () => {
    const { estado } = hidratarCompraGuardada({ ...compraTestigo(), ii_declarado: { '8.6956': 100.5 } as never })
    expect(estado.iiDeclarado).toEqual({ 8.6956: 100.5 })
  })
})
