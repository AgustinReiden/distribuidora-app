import { describe, it, expect } from 'vitest'
import {
  esAjustePromocion,
  valorizarMerma,
  totalizarMermas,
  resumenPorMotivo,
  MOTIVOS_AJUSTE_PROMOCION,
} from './valorizacionMermas'
import { costoCanonicoUnitario } from './costoCanonico'

function merma(over: Partial<Parameters<typeof valorizarMerma>[0]> = {}) {
  return {
    id: 'm1',
    producto_id: 'p1',
    cantidad: 3,
    motivo: 'rotura',
    costo_unitario: 100,
    created_at: '2026-08-15T14:00:00Z',
    ...over,
  }
}

const producto = {
  id: 'p1',
  nombre: 'Producto A',
  codigo: 'PA1',
  precio: 500,
  costo_promedio: 120,
  costo_real: 140,
  costo_sin_iva: 150,
  impuestos_internos: 0,
}

describe('esAjustePromocion', () => {
  it('promociones y su reversión no son pérdida', () => {
    // Son la contrapartida de un regalo YA contabilizado en el pedido. El
    // reporte gerencial los excluye del KPI de mermas (mig 130); si el modal
    // los sumara mostraría ~$2,5M donde el gerencial muestra ~$597.600.
    expect(esAjustePromocion('promociones')).toBe(true)
    expect(esAjustePromocion('promociones_reversion')).toBe(true)
  })

  it('los motivos de pérdida real sí cuentan', () => {
    for (const m of ['rotura', 'vencimiento', 'robo', 'decomiso', 'devolucion', 'error_inventario', 'muestra', 'otro']) {
      expect(esAjustePromocion(m)).toBe(false)
    }
  })

  it('la lista es exactamente la que excluye el gerencial', () => {
    expect([...MOTIVOS_AJUSTE_PROMOCION]).toEqual(['promociones', 'promociones_reversion'])
  })
})

describe('valorizarMerma', () => {
  describe('costo', () => {
    it('usa el costo CONGELADO al momento de la merma, no el de hoy', () => {
      // Si usara el costo vivo, el total de un mes ya cerrado cambiaría solo
      // cada vez que llega una compra.
      const v = valorizarMerma(merma({ costo_unitario: 100 }), producto)
      expect(v.costoUnitario).toBe(100)
      expect(v.costoTotal).toBe(300)
      expect(v.costoEstimado).toBe(false)
    })

    it('sin snapshot cae a la cascada canónica y queda MARCADA como estimada', () => {
      // Son 479 filas viejas (abril a julio 2026). No pueden mezclarse en
      // silencio con las que sí tienen el costo del momento.
      const v = valorizarMerma(merma({ costo_unitario: null }), producto)
      expect(v.costoUnitario).toBe(120) // costo_promedio, no costo_real
      expect(v.costoEstimado).toBe(true)
    })

    it('un snapshot de 0 es un valor, no un hueco', () => {
      const v = valorizarMerma(merma({ costo_unitario: 0 }), producto)
      expect(v.costoUnitario).toBe(0)
      expect(v.costoEstimado).toBe(false)
      expect(v.sinCosto).toBe(false)
    })
  })

  describe('sinCosto: 0 no es lo mismo que "no sabemos"', () => {
    it('marca la fila cuando el producto no tiene NINGÚN costo cargado', () => {
      // costoCanonicoUnitario devuelve 0 en ese caso. Para un SUM da igual,
      // pero en el historial una fila en $0 se lee como "no vale nada" cuando
      // en realidad es "no sabemos".
      const sinNada = { id: 'p9', precio: 500 }
      const v = valorizarMerma(merma({ costo_unitario: null }), sinNada)
      expect(v.costoUnitario).toBe(0)
      expect(v.sinCosto).toBe(true)
    })

    it('un costo cargado en 0 NO se marca: es una decisión, no un vacío', () => {
      const gratis = { id: 'p9', precio: 500, costo_promedio: 0 }
      const v = valorizarMerma(merma({ costo_unitario: null }), gratis)
      expect(v.costoUnitario).toBe(0)
      expect(v.sinCosto).toBe(false)
    })

    it('sin producto tampoco sabemos el costo', () => {
      const v = valorizarMerma(merma({ costo_unitario: null }), undefined)
      expect(v.sinCosto).toBe(true)
      expect(v.costoTotal).toBe(0)
    })

    // Este test es el que atrapa que las dos funciones se desalineen: la marca
    // vive acá y la cascada en costoCanonico.ts.
    it('sinCosto implica que la cascada devolvió 0', () => {
      const casos = [{ id: 'x' }, { id: 'x', precio: 10 }, { id: 'x', costo_sin_iva: null }]
      for (const p of casos) {
        const v = valorizarMerma(merma({ costo_unitario: null }), p)
        expect(v.sinCosto).toBe(true)
        expect(costoCanonicoUnitario(null, p)).toBe(0)
      }
    })
  })

  describe('precio de venta', () => {
    it('valúa contra el precio de HOY, porque no hay precio histórico', () => {
      // mermas_stock no tiene ninguna columna de precio: no se puede saber a
      // cuánto se vendía el día de la merma.
      const v = valorizarMerma(merma(), producto)
      expect(v.precioUnitario).toBe(500)
      expect(v.precioTotal).toBe(1500)
      expect(v.sinPrecio).toBe(false)
    })

    it('marca la fila cuando el producto no tiene precio', () => {
      const v = valorizarMerma(merma(), { id: 'p1' })
      expect(v.precioTotal).toBe(0)
      expect(v.sinPrecio).toBe(true)
    })
  })

  describe('cantidades negativas', () => {
    it('una reversión conserva el signo y no lo duplica', () => {
      // El CHECK pasó a `cantidad <> 0` (mig 011), así que las reversiones
      // entran negativas. La tarjeta imprimía "-{cantidad}" y mostraba "--3".
      const v = valorizarMerma(
        merma({ cantidad: -3, motivo: 'promociones_reversion', costo_unitario: 100 }),
        producto,
      )
      expect(v.cantidad).toBe(-3)
      expect(v.costoTotal).toBe(-300)
      expect(v.esAjustePromocion).toBe(true)
    })
  })
})

describe('totalizarMermas', () => {
  const filas = [
    valorizarMerma(merma({ id: 'a', cantidad: 2, motivo: 'rotura', costo_unitario: 100 }), producto),
    valorizarMerma(merma({ id: 'b', cantidad: 1, motivo: 'vencimiento', costo_unitario: 200 }), producto),
    valorizarMerma(merma({ id: 'c', cantidad: 10, motivo: 'promociones', costo_unitario: 50 }), producto),
    valorizarMerma(merma({ id: 'd', cantidad: -4, motivo: 'promociones_reversion', costo_unitario: 50 }), producto),
  ]

  it('el total en plata EXCLUYE los ajustes de promoción', () => {
    // Es lo que hace que el modal cuadre con el reporte gerencial.
    const t = totalizarMermas(filas)
    expect(t.costoTotal).toBe(400) // 2*100 + 1*200
    expect(t.precioTotal).toBe(1500) // 3 unidades * 500
  })

  it('las unidades perdidas también excluyen los ajustes', () => {
    expect(totalizarMermas(filas).unidades).toBe(3)
  })

  it('los ajustes se cuentan aparte, no se esconden', () => {
    const t = totalizarMermas(filas)
    expect(t.registrosAjustePromocion).toBe(2)
    expect(t.costoAjustePromocion).toBe(300) // 10*50 + (-4)*50
  })

  it('cuenta TODOS los registros, sean pérdida o ajuste', () => {
    expect(totalizarMermas(filas).registros).toBe(4)
  })

  // Las dos marcas son DISJUNTAS: una fila sin ningún costo no es una
  // estimación, es un dato ausente. Contarla como estimada diría que hay un
  // número aproximado cuando no hay ninguno.
  it('cuenta por separado las estimadas y las que no tienen costo', () => {
    const mezcla = [
      valorizarMerma(merma({ id: 'e', costo_unitario: null }), producto),
      valorizarMerma(merma({ id: 'f', costo_unitario: null }), { id: 'p2' }),
      valorizarMerma(merma({ id: 'g', costo_unitario: 100 }), producto),
    ]
    const t = totalizarMermas(mezcla)
    expect(t.filasCostoEstimado).toBe(1)
    expect(t.filasSinCosto).toBe(1)
  })

  it('ninguna fila es estimada y sin costo a la vez', () => {
    const filas = [
      valorizarMerma(merma({ costo_unitario: null }), producto),
      valorizarMerma(merma({ costo_unitario: null }), { id: 'p2' }),
      valorizarMerma(merma({ costo_unitario: 5 }), producto),
    ]
    expect(filas.every(f => !(f.costoEstimado && f.sinCosto))).toBe(true)
  })

  it('sin filas devuelve ceros, no NaN', () => {
    const t = totalizarMermas([])
    expect(t).toMatchObject({ registros: 0, unidades: 0, costoTotal: 0, precioTotal: 0 })
    expect(Number.isNaN(t.costoTotal)).toBe(false)
  })
})

describe('resumenPorMotivo', () => {
  it('agrupa unidades y plata por motivo, ordenado por costo', () => {
    const filas = [
      valorizarMerma(merma({ id: 'a', cantidad: 2, motivo: 'rotura', costo_unitario: 100 }), producto),
      valorizarMerma(merma({ id: 'b', cantidad: 1, motivo: 'rotura', costo_unitario: 100 }), producto),
      valorizarMerma(merma({ id: 'c', cantidad: 1, motivo: 'vencimiento', costo_unitario: 1000 }), producto),
    ]

    expect(resumenPorMotivo(filas)).toEqual([
      { motivo: 'vencimiento', esAjustePromocion: false, registros: 1, unidades: 1, costo: 1000, precio: 500 },
      { motivo: 'rotura', esAjustePromocion: false, registros: 2, unidades: 3, costo: 300, precio: 1500 },
    ])
  })

  it('los ajustes de promoción aparecen en el resumen, marcados', () => {
    const filas = [
      valorizarMerma(merma({ id: 'c', cantidad: 10, motivo: 'promociones', costo_unitario: 50 }), producto),
    ]
    expect(resumenPorMotivo(filas)[0]).toMatchObject({
      motivo: 'promociones',
      esAjustePromocion: true,
      costo: 500,
    })
  })
})
