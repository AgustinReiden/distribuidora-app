import { describe, expect, it } from 'vitest'
import {
  MOTIVOS_NC_VENTA,
  diaEmisionNotaCreditoVenta,
  esMotivoPorMonto,
  itemsDescuentoParaRPC,
  leyendaMercaderiaNCVenta,
  mercaderiaDeNotaNC,
  montoDePorcentaje,
  montoDisponibleBoleta,
  montoUnidadesNC,
  repartoDescuentoNC,
  repartirDescuentoNC,
  resumenMercaderiaNC,
  leyendaPorcentajeNC,
  motivoMueveMercaderia,
  unidadesNotaCreditoVenta,
  totalDescuentoNC,
  validarDescuentoNC,
  fechasNotaCreditoVenta,
  itemsNotaCreditoParaRPC,
  lineasAcreditables,
  lineasReparticionCreditoNC,
  motivoNCVentaLabel,
  reparticionCreditoNC,
  totalNotaCreditoVenta,
  totalNotasCreditoVigentes,
  validarNotaCreditoVenta,
} from './notaCreditoVenta'

// Pedido 6510 de prod (el del ensayo de la mig 276), con un renglón duplicado de
// producto para cubrir que la clave es la línea y no el producto.
const items = [
  { id: 23807, producto_id: 10, cantidad: 1, precio_unitario: 11100, es_bonificacion: false, producto: { nombre: 'Fideos' } },
  { id: 23808, producto_id: 11, cantidad: 1, precio_unitario: '5600', es_bonificacion: false, producto: { nombre: 'Arroz' } },
  { id: 23809, producto_id: 10, cantidad: 3, precio_unitario: 6000, es_bonificacion: false, producto: { nombre: 'Fideos' } },
  { id: 23811, producto_id: 12, cantidad: 2, precio_unitario: 0, es_bonificacion: true, producto: { nombre: 'Regalo' } },
]

describe('lineasAcreditables', () => {
  it('deja afuera los regalos y descuenta lo acreditado en NCs vigentes, por línea', () => {
    const lineas = lineasAcreditables(items, [
      { anulada: false, items: [{ pedido_item_id: 23809, cantidad: 2 }] },
      { anulada: true, items: [{ pedido_item_id: 23807, cantidad: 1 }] }, // anulada: no cuenta
      { anulada: false, items: [{ pedido_item_id: null, cantidad: 5 }] },   // renglón recreado: no se atribuye
    ])
    expect(lineas.map(l => l.pedidoItemId)).toEqual(['23807', '23808', '23809'])
    const porId = Object.fromEntries(lineas.map(l => [l.pedidoItemId, l]))
    expect(porId['23807']).toMatchObject({ entregada: 1, yaAcreditada: 0, disponible: 1 })
    expect(porId['23809']).toMatchObject({ entregada: 3, yaAcreditada: 2, disponible: 1 })
    expect(porId['23808'].precioUnitario).toBe(5600)
  })
})

describe('totalNotaCreditoVenta', () => {
  const lineas = lineasAcreditables(items)

  it('suma cantidad × precio del pedido (NC#2 del ensayo de la 276: 11.100 + 5.600 = 16.700)', () => {
    expect(totalNotaCreditoVenta(lineas, { '23807': 1, '23808': 1 })).toBe(16700)
    expect(totalNotaCreditoVenta(lineas, { '23807': 1, '23809': 2 })).toBe(23100)
  })

  it('ignora cantidades en cero o negativas y redondea a centavos', () => {
    const l = lineasAcreditables([{ id: 1, producto_id: 1, cantidad: 3, precio_unitario: 0.105 }])
    expect(totalNotaCreditoVenta(l, { '1': 3 })).toBe(0.32)
    expect(totalNotaCreditoVenta(lineas, { '23807': 0, '23808': -1 })).toBe(0)
  })
})

describe('validarNotaCreditoVenta', () => {
  const lineas = lineasAcreditables(items, [{ anulada: false, items: [{ pedido_item_id: 23809, cantidad: 2 }] }])

  it('exige al menos una línea', () => {
    expect(validarNotaCreditoVenta(lineas, {})).toMatch(/al menos un producto/)
  })

  it('no deja pasar de lo entregado menos lo ya acreditado', () => {
    expect(validarNotaCreditoVenta(lineas, { '23809': 2 })).toMatch(/hasta 1 \(entregadas 3, ya acreditadas 2\)/)
    expect(validarNotaCreditoVenta(lineas, { '23809': 1 })).toBeNull()
  })

  it('rechaza fracciones', () => {
    expect(validarNotaCreditoVenta(lineas, { '23807': 0.5 })).toMatch(/Cantidad inválida/)
  })
})

describe('itemsNotaCreditoParaRPC', () => {
  it('manda sólo las líneas con cantidad, con ids numéricos', () => {
    const lineas = lineasAcreditables(items)
    expect(itemsNotaCreditoParaRPC(lineas, { '23807': 1, '23808': 0 }, 'otro')).toEqual([
      { pedido_item_id: 23807, cantidad: 1 },
    ])
  })

  // B22, H1 de la revisión: sin la marca el server no mueve la mercadería.
  it('con un motivo que mueve mercadería, cada renglón la pide; con uno que no, no', () => {
    const lineas = lineasAcreditables(items)
    for (const motivo of ['cliente_rechaza', 'error_pedido', 'error_entrega', 'producto_vencido', 'producto_danado']) {
      expect(itemsNotaCreditoParaRPC(lineas, { '23807': 1, '23809': 2 }, motivo)).toEqual([
        { pedido_item_id: 23807, cantidad: 1, mercaderia: true },
        { pedido_item_id: 23809, cantidad: 2, mercaderia: true },
      ])
    }
    expect(itemsNotaCreditoParaRPC(lineas, { '23807': 1 }, 'descuento_comercial')).toEqual([{ pedido_item_id: 23807, cantidad: 1 }])
    expect(itemsNotaCreditoParaRPC(lineas, { '23807': 1 }, '')).toEqual([{ pedido_item_id: 23807, cantidad: 1 }])
    expect(MOTIVOS_NC_VENTA.filter(m => motivoMueveMercaderia(m.value)).map(m => m.mercaderia))
      .toEqual(['reingresa', 'reingresa', 'reingresa', 'merma', 'merma'])
  })
})

describe('resumen', () => {
  it('total de NCs vigentes ignora las anuladas', () => {
    expect(totalNotasCreditoVigentes([
      { total: 20100, anulada: true },
      { total: '16700', anulada: false },
    ])).toBe(16700)
  })

  it('etiqueta del motivo', () => {
    expect(motivoNCVentaLabel('producto_vencido')).toBe('Producto vencido')
    expect(motivoNCVentaLabel('raro')).toBe('raro')
  })
})

describe('reparticionCreditoNC (mig 479, COB-1)', () => {
  it('lee adónde fue el crédito: este pedido, otras boletas y lo que quedó suelto', () => {
    expect(reparticionCreditoNC({
      total: 16700, credito_aplicado_pedido: 10000, credito_aplicado_otras: '4000', credito_disponible: 2700,
    })).toEqual({ aplicadoPedido: 10000, aplicadoOtras: 4000, disponible: 2700 })
  })

  it('con un server viejo (sin los campos) todo el total sigue suelto', () => {
    expect(reparticionCreditoNC({ total: 16700 }))
      .toEqual({ aplicadoPedido: 0, aplicadoOtras: 0, disponible: 16700 })
  })

  it('sin credito_disponible lo suelto es lo que no se aplicó, nunca negativo', () => {
    expect(reparticionCreditoNC({ total: 1000, credito_aplicado_pedido: 600 }).disponible).toBe(400)
    expect(reparticionCreditoNC({ total: 1000, credito_aplicado_pedido: 1500 }).disponible).toBe(0)
  })
})

describe('lineasReparticionCreditoNC', () => {
  it('sólo cuenta las partes que no son 0', () => {
    const lineas = lineasReparticionCreditoNC({ aplicadoPedido: 0, aplicadoOtras: 4000, disponible: 0 })
    expect(lineas).toHaveLength(1)
    expect(lineas[0]).toMatch(/4\.000.* a otras boletas del cliente/)
  })

  it('las tres, en orden', () => {
    const lineas = lineasReparticionCreditoNC({ aplicadoPedido: 10000, aplicadoOtras: 4000, disponible: 2700 })
    expect(lineas).toHaveLength(3)
    expect(lineas[0]).toMatch(/^Se aplicaron .*10\.000.* a este pedido$/)
    expect(lineas[2]).toMatch(/^Quedan .*2\.700.* de saldo a favor$/)
  })

  it('sin nada que contar, no hay líneas', () => {
    expect(lineasReparticionCreditoNC({ aplicadoPedido: 0, aplicadoOtras: 0, disponible: 0 })).toEqual([])
  })
})

// B16 (decisión del dueño del 16/11): `fecha` es la de imputación (la de la boleta)
// y `created_at`, cuándo se emitió. El día de emisión es el argentino.
describe('fechas de una nota (B16)', () => {
  it('emitida otro día que su boleta: muestra las dos', () => {
    const nc = { fecha: '2026-09-15', created_at: '2026-10-03T15:00:00Z' }
    expect(diaEmisionNotaCreditoVenta(nc)).toBe('2026-10-03')
    expect(fechasNotaCreditoVenta(nc)).toBe('Imputada al 15/9 (día de la boleta) · emitida el 3/10')
  })

  it('emitida el día de su boleta: una sola fecha', () => {
    expect(fechasNotaCreditoVenta({ fecha: '2026-10-03', created_at: '2026-10-03T15:00:00Z' })).toBe('3/10')
  })

  it('el día de emisión es el argentino: a las 22 h del 31/10 todavía es 31/10', () => {
    // 01:00 UTC del 1/11 son las 22 h del 31/10 en Argentina.
    const nc = { fecha: '2026-10-31', created_at: '2026-11-01T01:00:00Z' }
    expect(diaEmisionNotaCreditoVenta(nc)).toBe('2026-10-31')
    expect(fechasNotaCreditoVenta(nc)).toBe('31/10')
  })

  it('sin created_at: la fecha de la nota', () => {
    expect(diaEmisionNotaCreditoVenta({ fecha: '2026-09-15' })).toBe('2026-09-15')
    expect(fechasNotaCreditoVenta({ fecha: '2026-09-15', created_at: null })).toBe('15/9')
  })
})

// B22 (decisiones del dueño del 17 y 18/11): la mercadería según el motivo y el
// descuento comercial por monto. Los números del descuento son los del ensayo del server
// (scripts/test-nc-stock-y-descuento-ola2-1603.sql, D1, D5 y D6): la pantalla tiene que
// mostrar el mismo reparto que hace prorratear_cargo.
describe('B22 · la mercadería según el motivo', () => {
  it('dice qué pasa con la mercadería de cada motivo', () => {
    expect(leyendaMercaderiaNCVenta('cliente_rechaza')).toMatch(/vuelven al stock, al lote del que salieron/)
    expect(leyendaMercaderiaNCVenta('error_entrega')).toMatch(/vuelven al stock/)
    expect(leyendaMercaderiaNCVenta('producto_vencido')).toMatch(/quedan como merma/)
    expect(leyendaMercaderiaNCVenta('producto_danado')).toMatch(/quedan como merma/)
    expect(leyendaMercaderiaNCVenta('descuento_comercial')).toBe('No se mueve mercadería.')
    expect(leyendaMercaderiaNCVenta('otro')).toBe('No se mueve mercadería.')
  })

  it('antes de guardar dice qué va a pasar, con las unidades (H1)', () => {
    expect(resumenMercaderiaNC('cliente_rechaza', 2)).toBe('Vuelven al stock 2 u.')
    expect(resumenMercaderiaNC('error_entrega', 1)).toBe('Vuelven al stock 1 u.')
    expect(resumenMercaderiaNC('producto_vencido', 2)).toBe('Van a merma 2 u.')
    expect(resumenMercaderiaNC('producto_danado', 3)).toBe('Van a merma 3 u.')
    expect(resumenMercaderiaNC('otro', 2)).toBe('No mueve stock')
    expect(resumenMercaderiaNC('descuento_comercial', 0)).toBe('No mueve stock')
    expect(resumenMercaderiaNC('cliente_rechaza', 0)).toBe('No mueve stock')
    expect(unidadesNotaCreditoVenta({ a: 2, b: 0, c: 3 })).toBe(5)
  })

  it('sólo el descuento comercial va por monto', () => {
    expect(MOTIVOS_NC_VENTA.filter(m => esMotivoPorMonto(m.value)).map(m => m.value)).toEqual(['descuento_comercial'])
  })

  it('la ficha dice si la nota movió mercadería (por la anotación del server)', () => {
    expect(mercaderiaDeNotaNC({ motivo: 'cliente_rechaza', items: [{ lotes_devueltos: [] }] })).toBe('reingresa')
    expect(mercaderiaDeNotaNC({ motivo: 'producto_vencido', items: [{ lotes_devueltos: [], merma_id: '7' }] })).toBe('merma')
    // Una nota anterior a B22 (sin anotación) o un descuento no movió nada.
    expect(mercaderiaDeNotaNC({ motivo: 'cliente_rechaza', items: [{ lotes_devueltos: null, merma_id: null }] })).toBeNull()
    expect(mercaderiaDeNotaNC({ motivo: 'descuento_comercial', items: [{}] })).toBeNull()
  })
})

describe('B22 · el descuento comercial por monto', () => {
  // FC: G21 3 × 121, G105 2 × 110,50 y EX 1 × 100 = 684.
  const fc = [
    { id: 1, producto_id: 21, cantidad: 3, precio_unitario: 121, subtotal: 363, producto: { nombre: 'G21' } },
    { id: 2, producto_id: 105, cantidad: 2, precio_unitario: 110.5, subtotal: 221, producto: { nombre: 'G105' } },
    { id: 3, producto_id: 1, cantidad: 1, precio_unitario: 100, subtotal: 100, producto: { nombre: 'EX' } },
    { id: 4, producto_id: 9, cantidad: 2, precio_unitario: 0, es_bonificacion: true, producto: { nombre: 'Regalo' } },
  ]

  it('lo que le queda a cada línea descuenta los renglones por monto (cantidad 0) y por unidades', () => {
    const lineas = lineasAcreditables(fc, [
      { anulada: false, items: [{ pedido_item_id: 1, cantidad: 0, subtotal: 53.07 }, { pedido_item_id: 2, cantidad: 1, subtotal: '110.50' }] },
      { anulada: true, items: [{ pedido_item_id: 3, cantidad: 0, subtotal: 50 }] },
    ])
    expect(lineas.map(l => [l.pedidoItemId, l.disponible, l.montoDisponible])).toEqual([
      ['1', 3, 309.93], ['2', 1, 110.5], ['3', 1, 100],
    ])
    expect(montoDisponibleBoleta(lineas)).toBe(520.43)
  })

  it('una línea sin producto (borrado) no se ofrece', () => {
    expect(lineasAcreditables([{ id: 5, producto_id: null, cantidad: 1, precio_unitario: 100 }])).toEqual([])
  })

  it('reparte 100 sobre toda la boleta como el server: 53,07 / 32,31 / 14,62 (D1)', () => {
    const reparto = repartoDescuentoNC(lineasAcreditables(fc), 100)
    expect(reparto.map(r => [r.nombre, r.monto])).toEqual([['G21', 53.07], ['G105', 32.31], ['EX', 14.62]])
    expect(reparto.reduce((s, r) => s + r.monto, 0)).toBeCloseTo(100, 10)
  })

  it('un centavo va entero a la línea de más peso, y las partes en 0 no aparecen (D5)', () => {
    expect(repartoDescuentoNC(lineasAcreditables(fc), 0.01)).toEqual([{ pedidoItemId: '1', nombre: 'G21', monto: 0.01 }])
  })

  it('un porcentaje se convierte a plata sobre lo que le queda a la boleta, y lo dice con sus números (D6)', () => {
    expect(montoDePorcentaje(lineasAcreditables(fc), 10)).toBe(68.4)
    expect(montoDePorcentaje(lineasAcreditables(fc), 0)).toBe(0)
    const setecientos = lineasAcreditables([{ id: 1, producto_id: 1, cantidad: 7, precio_unitario: 100 }])
    expect(leyendaPorcentajeNC(setecientos, 10)).toMatch(/^10 % de \$\s?700,00 que quedan por acreditar = \$\s?70,00$/)
    expect(leyendaPorcentajeNC(setecientos, 2.5)).toMatch(/^2,5 % de /)
  })

  // H2 de la revisión: con tope. El reparto viejo (prorratear_cargo, el residuo a la de más peso)
  // podía pasar lo que le queda a un renglón; éste no, y todo lo que queda entra.
  it('el reparto no pasa lo que le queda a ningún renglón y todo lo que queda entra', () => {
    const treinta = Object.fromEntries(Array.from({ length: 30 }, (_, i) => [String(i + 1), 10]))
    const p = repartirDescuentoNC(299.84, treinta) ?? {}
    expect(Object.values(p).every(m => m <= 10)).toBe(true)
    expect(Object.values(p).reduce((s, m) => s + Math.round(m * 100), 0)).toBe(29984)
    expect(repartirDescuentoNC(300, treinta)).toEqual(treinta)
    expect(repartirDescuentoNC(300.01, treinta)).toBeNull()
    expect(repartirDescuentoNC(0, treinta)).toEqual({})
  })

  it('las unidades después de un descuento acreditan lo que le queda a la línea (D6: 103,31 y 206,61)', () => {
    const [g21] = lineasAcreditables(fc, [{ anulada: false, items: [
      { pedido_item_id: 1, cantidad: 0, subtotal: 53.07 }, { pedido_item_id: 1, cantidad: 0, subtotal: 0.01 },
    ] }])
    expect(g21.montoDisponible).toBe(309.92)
    expect(montoUnidadesNC(g21, 1)).toBe(103.31)
    expect(montoUnidadesNC(g21, 3)).toBe(309.92)
    // Sin descuento en la línea, cantidad × precio, como siempre.
    expect(montoUnidadesNC(lineasAcreditables(fc)[0], 2)).toBe(242)
  })

  // N1 de la revisión (espejo de D7 del server): 3 × 100, un descuento de 30, una unidad acreditó 90 y
  // después se anuló el descuento: a la línea le quedan 210 para 2 unidades (105 c/u), pero una unidad
  // nunca acredita más que su precio.
  it('una unidad nunca acredita más que su precio (D7)', () => {
    const [l] = lineasAcreditables([{ id: 1, producto_id: 1, cantidad: 3, precio_unitario: 100 }], [
      { anulada: false, items: [{ pedido_item_id: 1, cantidad: 1, subtotal: 90 }] },
      { anulada: true, items: [{ pedido_item_id: 1, cantidad: 0, subtotal: 30 }] },
    ])
    expect([l.disponible, l.montoDisponible]).toEqual([2, 210])
    expect(montoUnidadesNC(l, 1)).toBe(100)
    expect(montoUnidadesNC(l, 2)).toBe(200)
    // Con el descuento vigente, por debajo del precio: lo que le queda por unidad.
    const [d] = lineasAcreditables([{ id: 1, producto_id: 1, cantidad: 3, precio_unitario: 100 }], [
      { anulada: false, items: [{ pedido_item_id: 1, cantidad: 0, subtotal: 30 }] },
    ])
    expect(montoUnidadesNC(d, 1)).toBe(90)
  })

  // N5 de la revisión: el reparto sale del monto al centavo, el mismo que se manda.
  it('con más de dos decimales, el reparto es el del monto al centavo', () => {
    const lineas = lineasAcreditables(fc)
    // 128,015 × 100 da 12801,4999… en double: redondeado así sería 128,01, y se manda 128,02.
    const reparto = repartoDescuentoNC(lineas, 128.015)
    expect(Math.round(reparto.reduce((s, r) => s + r.monto, 0) * 100)).toBe(12802)
    expect(itemsDescuentoParaRPC(lineas, 128.015, null)).toEqual([{ monto: 128.02 }])
  })

  it('valida el tope de la boleta y el de cada renglón', () => {
    const lineas = lineasAcreditables(fc)
    expect(validarDescuentoNC(lineas, 0, null)).toMatch(/Escribí el monto/)
    expect(validarDescuentoNC(lineas, 684.01, null)).toMatch(/pasa lo que le queda a la boleta/)
    expect(validarDescuentoNC(lineas, 684, null)).toBeNull()
    expect(validarDescuentoNC(lineas, 0, {})).toMatch(/al menos un producto/)
    expect(validarDescuentoNC(lineas, 0, { '3': 100.01 })).toMatch(/EX: le quedan/)
    expect(validarDescuentoNC(lineas, 0, { '2': 50, '3': 20 })).toBeNull()
  })

  it('arma el payload de la RPC: {monto} sobre la boleta, o un renglón por producto', () => {
    const lineas = lineasAcreditables(fc)
    expect(itemsDescuentoParaRPC(lineas, 100.004, null)).toEqual([{ monto: 100 }])
    expect(itemsDescuentoParaRPC(lineas, 0, { '2': 50, '3': 20, '1': 0 })).toEqual([
      { pedido_item_id: 2, monto: 50 }, { pedido_item_id: 3, monto: 20 },
    ])
    expect(totalDescuentoNC(0, { '2': 50, '3': 20 })).toBe(70)
    expect(totalDescuentoNC(12.345, null)).toBe(12.35)
  })
})
