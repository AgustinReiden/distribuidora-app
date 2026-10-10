import { describe, it, expect } from 'vitest'
import fixture from './cadenaSustitucion.espejo.json'
import {
  pasosDeCadena,
  raizDeSustitucion,
  raizDescrita,
  type SustitucionRegistrada,
} from './repartoRegalo'

/**
 * PARIDAD DEL RECORRIDO DE LA CADENA DE SUSTITUCIONES (#1010, #1057), lado TypeScript.
 *
 * El recorrido está escrito dos veces: `pasosDeCadena()` acá (la pantalla de
 * edición) y `regalo_cadena_pasos()` en el server (lo que se guarda). Las dos
 * corren los MISMOS casos de `cadenaSustitucion.espejo.json` contra el mismo
 * resultado esperado, escrito a mano: este archivo el TS, y
 * `scripts/espejo-cadena-regalo.mjs` el SQL, en el gate de integridad, donde hay
 * credenciales. Si una de las dos cambia la regla sin la otra, su lado se pone
 * rojo.
 *
 * Desde #1057 cada línea de regalo tiene su clave de cadena (`cadena`) y sólo ve
 * los eslabones con esa misma `cadena_id`; sin clave no se aplica ninguno. Un
 * caso puede traer además `raiz` (qué devuelve `raizDeSustitucion`, que es
 * `regalo_raiz_de_eslabones` en el server) y `raizDescrita` (`regalo_raiz_descrita`).
 *
 * Lo que NO cubre: la conversión de cantidad. El server escala sólo si el
 * sustituto es de otra categoría o de otro empaque y acá eso no se sabe (ver
 * `cantidadTrasEslabon`); el recorrido —qué eslabones y en qué orden— sí es
 * idéntico, y es el que tenía el bug.
 */

interface CasoEspejo {
  caso: string
  producto: number
  cadena: string | null
  eslabones: SustitucionRegistrada[]
  esperado: number[]
  raiz?: number | null
  raizDescrita?: number
}

const casos = fixture.casos as unknown as CasoEspejo[]

describe('Paridad del recorrido de la cadena (TS contra el fixture compartido con el SQL)', () => {
  it.each(casos.map(c => [c.caso, c] as const))('%s', (_nombre, c) => {
    const pasos = pasosDeCadena(c.eslabones, 1, c.cadena, c.producto)
    expect(pasos.map(s => Number(s.id))).toEqual(c.esperado)

    if ('raiz' in c) {
      expect(raizDeSustitucion(c.eslabones, 1, c.cadena, c.producto))
        .toBe(c.raiz == null ? null : String(c.raiz))
    }
    if ('raizDescrita' in c) {
      expect(raizDescrita(c.eslabones, 1, c.cadena, c.producto)).toBe(String(c.raizDescrita))
    }
  })

  it('los casos tienen nombres únicos (el script del SQL los reporta por nombre)', () => {
    const nombres = casos.map(c => c.caso)
    expect(new Set(nombres).size).toBe(nombres.length)
  })

  it('todos los eslabones de todos los casos declaran su cadena_id (null sólo donde el caso prueba la falta de clave)', () => {
    for (const c of casos) {
      for (const e of c.eslabones) {
        expect(e, `${c.caso} · eslabón ${e.id}`).toHaveProperty('cadena_id')
      }
    }
  })
})
