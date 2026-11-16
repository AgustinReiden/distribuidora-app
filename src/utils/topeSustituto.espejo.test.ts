import { describe, it, expect } from 'vitest'
import fixture from './topeSustituto.espejo.json'
import { topeSustitutoRegalo } from './regaloOtroEmpaque'

/**
 * PARIDAD DEL TOPE DEL SUSTITUTO DE UN REGALO (#1592, PRM-1), lado TypeScript.
 *
 * La regla está escrita dos veces: `topeSustitutoRegalo()` acá (lo que la pantalla
 * sugiere y deja confirmar a quien no es admin) y `regalo_tope_sustituto()` en el
 * server, con la que `sustituir_regalo_pedido` y `actualizar_pedido_items` topean.
 * Las dos corren los MISMOS casos de `topeSustituto.espejo.json` contra el resultado
 * escrito a mano: este archivo el TS, y `scripts/espejo-tope-sustituto.mjs` el SQL,
 * en el gate de integridad. Si una cambia la regla sin la otra, su lado se pone rojo.
 */

interface CasoEspejo {
  caso: string
  corte: number
  precio_regalo: number | null
  factor_regalo: number | null
  precio_sustituto: number | null
  factor_sustituto: number | null
  mismo_rubro: boolean
  esperado: number
}

const casos = fixture.casos as unknown as CasoEspejo[]

describe('Paridad del tope del sustituto (TS contra el fixture compartido con el SQL)', () => {
  it.each(casos.map(c => [c.caso, c] as const))('%s', (_nombre, c) => {
    expect(topeSustitutoRegalo({
      corte: c.corte,
      precioRegalo: c.precio_regalo,
      factorRegalo: c.factor_regalo,
      precioSustituto: c.precio_sustituto,
      factorSustituto: c.factor_sustituto,
      mismoRubro: c.mismo_rubro,
    })).toBe(c.esperado)
  })

  it('los casos tienen nombres únicos (el script del SQL los reporta por nombre)', () => {
    const nombres = casos.map(c => c.caso)
    expect(new Set(nombres).size).toBe(nombres.length)
  })
})
