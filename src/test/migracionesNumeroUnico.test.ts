import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * Dos archivos de `migrations/` no pueden compartir número.
 *
 * El número se reserva aplicando la migración, no escribiendo el archivo
 * (CLAUDE.md, Trampa 3), y dos sesiones en paralelo pueden tomar el mismo: pasó
 * con el 283 y el 284 el 2026-10-05. El que aplicó segundo renombra su archivo
 * con sufijo de letra (`284b_...`, como `190b_` y `012b_`): el gate de CI
 * (`scripts/check-migrations.mjs`) compara por stem y saca `^\d+[a-z]?_`, así
 * que el ledger puede seguir diciendo `284_...` sin que nada se ponga rojo.
 *
 * Corre en el PR mezclado con `main`, que es justo donde aparece el choque: la
 * rama de cada sesión, sola, no lo ve.
 *
 * Los duplicados históricos están documentados en `migrations/MANIFEST.md` §A
 * y quedan congelados acá. La lista sólo puede achicarse.
 */
const DUPLICADOS_HISTORICOS = new Set([
  '030', '040', '080', '081', '091', '100', '139', '140', '167',
  // Repetidos desde antes y que §A no listaba: aparecieron al escribir este test.
  '109', '132', '141', '142',
])

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DIR = path.resolve(__dirname, '../../migrations')

describe('migrations/: un número por archivo', () => {
  it('no hay dos migraciones con el mismo número (salvo las históricas de MANIFEST §A)', () => {
    const porNumero = new Map<string, string[]>()
    for (const archivo of fs.readdirSync(DIR)) {
      const m = /^(\d+[a-z]?)_.+\.sql$/.exec(archivo)
      if (!m) continue
      porNumero.set(m[1], [...(porNumero.get(m[1]) ?? []), archivo])
    }
    const nuevos = [...porNumero]
      .filter(([numero, archivos]) => archivos.length > 1 && !DUPLICADOS_HISTORICOS.has(numero))
      .map(([numero, archivos]) => `${numero}: ${archivos.join(', ')}`)

    expect(nuevos, 'Renombrá el que se aplicó SEGUNDO con sufijo de letra (NNNb_...)').toEqual([])
  })
})
