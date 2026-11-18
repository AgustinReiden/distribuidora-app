import { describe, it, expect } from 'vitest'
import fixture from './repartoDescuentoNC.espejo.json'
import { repartirDescuentoNC } from './notaCreditoVenta'

/**
 * PARIDAD DEL REPARTO DE UN DESCUENTO COMERCIAL (B22 de #1603, H2 de la revisión), lado TypeScript.
 *
 * El reparto de un descuento sobre toda la boleta está escrito dos veces: `_nc_venta_repartir` en
 * el server (el que vale, lo usa `crear_nota_credito_venta_impl`) y `repartirDescuentoNC` acá (lo
 * que el modal muestra antes de emitir). Las dos corren los MISMOS casos de
 * `repartoDescuentoNC.espejo.json`, con las partes al centavo: este archivo el TS, y
 * `scripts/espejo-reparto-descuento-nc.mjs` el SQL (en los gates locales y en integridad). Si una
 * cambia la cuenta sin la otra, su lado se pone rojo.
 */
interface CasoEspejo {
  caso: string
  monto: number
  restos: Record<string, number>
  partes: Record<string, number> | null
}

const casos = (fixture as { casos: CasoEspejo[] }).casos

describe('espejo de _nc_venta_repartir', () => {
  it.each(casos.map(c => [c.caso, c] as const))('%s', (_caso, c) => {
    const ts = repartirDescuentoNC(c.monto, c.restos)
    if (c.partes == null) {
      expect(ts).toBeNull()
      return
    }
    expect(ts).toEqual(c.partes)
  })

  it('ninguna parte pasa lo que le queda a su renglón y todas suman el monto', () => {
    for (const c of casos) {
      if (c.partes == null) continue
      const partes = repartirDescuentoNC(c.monto, c.restos) ?? {}
      for (const [id, m] of Object.entries(partes)) expect(m).toBeLessThanOrEqual(c.restos[id])
      const suma = Object.values(partes).reduce((s, m) => s + Math.round(m * 100), 0)
      expect(suma).toBe(Math.round(c.monto * 100))
    }
  })
})
