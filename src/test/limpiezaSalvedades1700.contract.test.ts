import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * La limpieza de las salvedades pendientes (#1700) es un `DO $limpieza$ … $limpieza$` de la
 * migración, que no se puede llamar desde un ensayo. `scripts/test-salvedades-limpieza-1700.sql`
 * prueba el MISMO cuerpo como `pg_temp.limpieza_1700()`. Este test fija que sean iguales: si se
 * cambia la limpieza de la migración sin cambiar la del ensayo (o al revés), el ensayo prueba otra
 * cosa y nadie se entera.
 *
 * La migración se busca por su nombre, con «NNN» o ya numerada (`5xx_salvedades_oficina_resueltas.sql`).
 */
const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

function cuerpoLimpieza(texto: string): string | null {
  const m = texto.replace(/\r\n/g, '\n').match(/\$limpieza\$\n([\s\S]*?)\$limpieza\$;/)
  return m ? m[1] : null
}

describe('la limpieza de #1700: el ensayo prueba el bloque de la migración', () => {
  const migraciones = fs.readdirSync(path.join(RAIZ, 'migrations'))
    .filter(f => /^(NNN|\d+[a-z]?)_salvedades_oficina_resueltas\.sql$/.test(f))

  it('hay una sola migración de la limpieza', () => {
    expect(migraciones).toHaveLength(1)
  })

  it('el cuerpo entre los $limpieza$ es el mismo, byte a byte', () => {
    const deLaMigracion = cuerpoLimpieza(fs.readFileSync(path.join(RAIZ, 'migrations', migraciones[0]), 'utf8'))
    const delEnsayo = cuerpoLimpieza(
      fs.readFileSync(path.join(RAIZ, 'scripts', 'test-salvedades-limpieza-1700.sql'), 'utf8'),
    )
    expect(deLaMigracion).not.toBeNull()
    expect(deLaMigracion).toContain('c_n_oficina CONSTANT int := 84;')
    expect(deLaMigracion).toContain('c_n_calle   CONSTANT int := 7;')
    expect(delEnsayo).toBe(deLaMigracion)
  })
})
