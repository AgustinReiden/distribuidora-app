/**
 * Tests de `orquestarPrecios` (app) + paridad con la copia del bot.
 *
 * Los casos salen de `orquestacionPrecios.fixture.ts`, que está sincronizado
 * byte a byte con la copia del bot: la suite Deno
 * (`supabase/functions/tests/orquestacion_precios.test.ts`) corre exactamente
 * los mismos escenarios.
 */
import { describe, it, expect } from 'vitest'
import { orquestarPrecios } from './orquestacionPrecios'
// La copia del bot, importada tal cual (imports con extensión .ts explícita:
// Vite los resuelve igual que Deno). Es lo que convierte "los dos archivos son
// iguales" en "los dos archivos dan el mismo total".
import { orquestarPrecios as orquestarPreciosBot } from '../../supabase/functions/_shared/utils/orquestacionPrecios.ts'
import { ESCENARIOS, promoMapDe, redondear2 } from './orquestacionPrecios.fixture'
import type { OrquestacionPreciosInput } from './orquestacionPrecios'

describe('orquestarPrecios', () => {
  for (const escenario of ESCENARIOS) {
    it(escenario.nombre, () => {
      const r = orquestarPrecios(escenario.input)
      const esp = escenario.esperado

      expect(redondear2(r.totalOriginal)).toBe(esp.totalOriginal)
      expect(redondear2(r.totalSinDescuentoCliente)).toBe(esp.totalSinDescuentoCliente)
      expect(redondear2(r.total)).toBe(esp.total)

      expect([...r.promoResolucion.productosConPromo].sort()).toEqual(
        [...esp.productosConPromo].sort(),
      )
      expect(
        r.promoResolucion.bonificaciones.map(b => ({
          productoId: String(b.productoId),
          cantidad: b.cantidadBonificacion,
        })),
      ).toEqual(esp.bonificaciones)

      const precios: Record<string, number> = {}
      for (const item of r.items) {
        if (item.esBonificacion) continue
        precios[String(item.productoId)] = redondear2(item.precioUnitario)
      }
      expect(precios).toEqual(esp.precioFinalPorProducto)
    })
  }

  it('sin promos, sin condiciones y sin cliente: los precios quedan intactos', () => {
    const r = orquestarPrecios({
      items: [{ productoId: '1', cantidad: 3, precioUnitario: 100 }],
    })
    expect(r.total).toBe(300)
    expect(r.totalSinDescuentoCliente).toBe(300)
    expect(r.ahorro).toBe(0)
    expect(r.hayDescuentoPrecios).toBe(false)
    expect(r.hayDescuentoCliente).toBe(false)
  })

  it('etiqueta el origen del descuento: categoría vs general', () => {
    // Escenario 2: 1 y 2 caen en el general, 3 en una regla por categoría.
    const r = orquestarPrecios(ESCENARIOS[1].input)
    expect(r.descuentoClientePct.get('1')).toBe(10)
    expect(r.descuentoClientePct.get('3')).toBe(0)
    expect(r.descuentoPorCategoria.has('3')).toBe(true)
    expect(r.descuentoPorCategoria.has('1')).toBe(false)
  })
})

describe('paridad app ↔ bot', () => {
  for (const escenario of ESCENARIOS) {
    it(`mismo total por app y por Telegram: ${escenario.nombre}`, () => {
      const app = orquestarPrecios(escenario.input)
      const bot = orquestarPreciosBot(escenario.input)

      expect(bot.total).toBe(app.total)
      expect(bot.totalSinDescuentoCliente).toBe(app.totalSinDescuentoCliente)
      expect(bot.totalOriginal).toBe(app.totalOriginal)
      expect(bot.items).toEqual(app.items)
      expect([...bot.promoResolucion.productosConPromo]).toEqual(
        [...app.promoResolucion.productosConPromo],
      )
      expect(bot.promoResolucion.bonificaciones).toEqual(app.promoResolucion.bonificaciones)
      expect([...bot.descuentoClientePct]).toEqual([...app.descuentoClientePct])
      expect([...bot.descuentoPorCategoria]).toEqual([...app.descuentoPorCategoria])
    })
  }
})

// =============================================================================
// Regalo elegido a mano: una parte = cambiar el producto; varias = reparto
// =============================================================================
describe('orquestarPrecios — override del regalo', () => {
  // Compra 24 Manaos 3L (cualquier sabor de la promo), lleva 12 de regalo.
  // Con 48 de naranja la promo da 24 de naranja.
  const promoManaos = promoMapDe([{
    id: 'promo-24',
    nombre: 'Manaos 3L 24+12',
    tipo: 'bonificacion',
    productoIds: ['naranja', 'manzana', 'pomelo'],
    reglas: { cantidad_compra: 24, cantidad_bonificacion: 12 },
    productoRegaloId: 'naranja',
  }])
  const base: OrquestacionPreciosInput = {
    items: [{ productoId: 'naranja', cantidad: 48, precioUnitario: 1000 }],
    promoMap: promoManaos,
  }
  const bonifs = (r: ReturnType<typeof orquestarPrecios>) =>
    r.items.filter(i => i.esBonificacion).map(i => ({
      productoId: String(i.productoId),
      cantidad: i.cantidad,
      promoId: i.promoId,
      precioUnitario: i.precioUnitario,
    }))

  it('sin override: una sola línea de regalo con el default de la promo', () => {
    const r = orquestarPrecios(base)
    expect(bonifs(r)).toEqual([{ productoId: 'naranja', cantidad: 24, promoId: 'promo-24', precioUnitario: 0 }])
    expect(r.regalosInvalidos).toEqual([])
    expect(r.bonificacionesBase).toEqual(r.promoResolucion.bonificaciones)
  })

  it('con una parte se comporta como el override de siempre: cambia el producto y la cantidad sigue a la promo', () => {
    // La cantidad de la parte se ignora: si el cliente compra más, el regalo crece.
    const r = orquestarPrecios({
      ...base,
      overridesRegalo: { 'promo-24': { partes: [{ productoId: 'manzana', cantidad: 3, descripcionRegalo: 'Manaos Manzana 3L' }] } },
    })
    expect(bonifs(r)).toEqual([{ productoId: 'manzana', cantidad: 24, promoId: 'promo-24', precioUnitario: 0 }])
    expect(r.items.find(i => i.esBonificacion)?.descripcionRegalo).toBe('Manaos Manzana 3L')
    expect(r.regalosInvalidos).toEqual([])
    // Los disparadores y el total no se tocan.
    const sinOverride = orquestarPrecios(base)
    expect(r.total).toBe(sinOverride.total)
    expect([...r.promoResolucion.productosConPromo]).toEqual([...sinOverride.promoResolucion.productosConPromo])
  })

  it('con dos partes que suman la bonificación: dos líneas de la misma promo', () => {
    const r = orquestarPrecios({
      ...base,
      overridesRegalo: { 'promo-24': { partes: [
        { productoId: 'naranja', cantidad: 12 },
        { productoId: 'manzana', cantidad: 12 },
      ] } },
    })
    expect(bonifs(r)).toEqual([
      { productoId: 'naranja', cantidad: 12, promoId: 'promo-24', precioUnitario: 0 },
      { productoId: 'manzana', cantidad: 12, promoId: 'promo-24', precioUnitario: 0 },
    ])
    expect(r.promoResolucion.bonificaciones.map(b => b.cantidadBonificacion)).toEqual([12, 12])
    // La base sigue siendo UNA bonificación de 24: es la que tiene que sumar el reparto.
    expect(r.bonificacionesBase).toEqual([expect.objectContaining({ productoId: 'naranja', cantidadBonificacion: 24 })])
    expect(r.regalosInvalidos).toEqual([])
    // El regalo es gratis: repartirlo no cambia el total.
    expect(r.total).toBe(orquestarPrecios(base).total)
  })

  it('un reparto que no suma la bonificación no se aplica: va el default y se informa', () => {
    const r = orquestarPrecios({
      ...base,
      overridesRegalo: { 'promo-24': { partes: [
        { productoId: 'naranja', cantidad: 12 },
        { productoId: 'manzana', cantidad: 10 },
      ] } },
    })
    expect(bonifs(r)).toEqual([{ productoId: 'naranja', cantidad: 24, promoId: 'promo-24', precioUnitario: 0 }])
    expect(r.regalosInvalidos).toEqual(['promo-24'])
  })

  it.each([
    ['una fila sin producto', [{ productoId: 'naranja', cantidad: 12 }, { productoId: '', cantidad: 12 }]],
    ['un sabor repetido', [{ productoId: 'naranja', cantidad: 12 }, { productoId: 'naranja', cantidad: 12 }]],
    ['una cantidad no entera', [{ productoId: 'naranja', cantidad: 11.5 }, { productoId: 'manzana', cantidad: 12.5 }]],
    ['una cantidad en cero', [{ productoId: 'naranja', cantidad: 24 }, { productoId: 'manzana', cantidad: 0 }]],
  ])('tampoco se aplica con %s', (_caso, partes) => {
    const r = orquestarPrecios({ ...base, overridesRegalo: { 'promo-24': { partes } } })
    expect(bonifs(r)).toEqual([{ productoId: 'naranja', cantidad: 24, promoId: 'promo-24', precioUnitario: 0 }])
    expect(r.regalosInvalidos).toEqual(['promo-24'])
  })

  it('si la bonificación cambia, el reparto que sumaba deja de cerrar', () => {
    // 12+12 era para 24; con 72 comprados la promo da 36.
    const r = orquestarPrecios({
      items: [{ productoId: 'naranja', cantidad: 72, precioUnitario: 1000 }],
      promoMap: promoManaos,
      overridesRegalo: { 'promo-24': { partes: [
        { productoId: 'naranja', cantidad: 12 },
        { productoId: 'manzana', cantidad: 12 },
      ] } },
    })
    expect(r.regalosInvalidos).toEqual(['promo-24'])
    expect(bonifs(r)).toEqual([{ productoId: 'naranja', cantidad: 36, promoId: 'promo-24', precioUnitario: 0 }])
  })

  it('la copia del bot reparte igual', () => {
    const input: OrquestacionPreciosInput = {
      ...base,
      overridesRegalo: { 'promo-24': { partes: [
        { productoId: 'naranja', cantidad: 12 },
        { productoId: 'manzana', cantidad: 12 },
      ] } },
    }
    const app = orquestarPrecios(input)
    const bot = orquestarPreciosBot(input)
    expect(bot.items).toEqual(app.items)
    expect(bot.regalosInvalidos).toEqual(app.regalosInvalidos)
    expect(bot.bonificacionesBase).toEqual(app.bonificacionesBase)
  })
})
