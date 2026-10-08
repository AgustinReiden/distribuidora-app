import { describe, it, expect } from 'vitest'
import fixture from './cadenaSustitucion.espejo.json'
import { pasosDeCadena, type SustitucionRegistrada } from './repartoRegalo'

/**
 * PARIDAD DEL RECORRIDO DE LA CADENA DE SUSTITUCIONES (#1010), lado TypeScript.
 *
 * El recorrido está escrito dos veces: `pasosDeCadena()` acá (la pantalla de
 * edición) y `regalo_cadena_pasos()` en el server (lo que se guarda). Las dos
 * corren los MISMOS casos de `cadenaSustitucion.espejo.json` contra el mismo
 * resultado esperado, escrito a mano: este archivo el TS, y
 * `scripts/espejo-cadena-regalo.mjs` el SQL, en el gate de integridad, donde hay
 * credenciales. Si una de las dos cambia la regla sin la otra, su lado se pone
 * rojo.
 *
 * Lo que NO cubre: la conversión de cantidad. El server escala sólo si el
 * sustituto es de otra categoría o de otro empaque y acá eso no se sabe (ver
 * `cantidadTrasEslabon`); el recorrido —qué eslabones y en qué orden— sí es
 * idéntico, y es el que tenía el bug.
 */

interface CasoEspejo {
  caso: string
  producto: number
  eslabones: SustitucionRegistrada[]
  esperado: number[]
}

const casos = fixture.casos as unknown as CasoEspejo[]

describe('Paridad del recorrido de la cadena (TS contra el fixture compartido con el SQL)', () => {
  it.each(casos.map(c => [c.caso, c] as const))('%s', (_nombre, c) => {
    const pasos = pasosDeCadena(c.eslabones, 1, c.producto)
    expect(pasos.map(s => Number(s.id))).toEqual(c.esperado)
  })

  it('los casos tienen nombres únicos (el script del SQL los reporta por nombre)', () => {
    const nombres = casos.map(c => c.caso)
    expect(new Set(nombres).size).toBe(nombres.length)
  })
})
