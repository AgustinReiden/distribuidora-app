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
import { ESCENARIOS, redondear2 } from './orquestacionPrecios.fixture'

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
