import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * 1564-b6 parte 2 (#1564, D50; H8 de la revisión de C6): desde los cierres de C6 `authenticated`
 * lee `politicas_comerciales` columna por columna. Si el select del front nombra una columna sin
 * su GRANT, la consulta ENTERA da 42501 para todos y el alta queda sin la política. Este test es
 * el espejo: lo que pide el front (más `sucursal_id`, que filtra la RLS) es exactamente el último
 * `GRANT SELECT (...) ON public.politicas_comerciales TO authenticated` de migrations/.
 *
 * Las constantes se leen del texto del hook (importarlo arranca el cliente de supabase).
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const RAIZ = path.resolve(__dirname, '..', '..', '..')
const HOOK = fs.readFileSync(path.join(__dirname, 'usePoliticasComercialesQuery.ts'), 'utf8')
const columnas = (lista: string) => lista.split(',').map(c => c.trim()).filter(Boolean)
function constante(nombre: string): string[] {
  const m = new RegExp(`export const ${nombre} =\\s*'([^']*)'`).exec(HOOK)
  if (!m) throw new Error(`no encontré ${nombre} en usePoliticasComercialesQuery.ts`)
  return columnas(m[1])
}

describe('politicas_comerciales: el select del front es lo que la migración concede (H8)', () => {
  it('POLITICA_COLUMNAS_PARA_VENDER + sucursal_id = el último GRANT por columna', () => {
    const dir = path.join(RAIZ, 'migrations')
    const RE_GRANT = /GRANT SELECT \(([^)]*)\)\s+ON public\.politicas_comerciales TO authenticated/g
    const grants = fs.readdirSync(dir)
      .filter(n => n.endsWith('.sql'))
      .sort()
      .flatMap(n => [...fs.readFileSync(path.join(dir, n), 'utf8').matchAll(RE_GRANT)].map(m => m[1]))
    expect(grants.length).toBeGreaterThan(0)
    const concedidas = columnas(grants[grants.length - 1]).sort()
    expect([...constante('POLITICA_COLUMNAS_PARA_VENDER'), 'sucursal_id'].sort()).toEqual(concedidas)
  })

  it('lo reservado no está en el select de vender', () => {
    const vender = new Set(constante('POLITICA_COLUMNAS_PARA_VENDER'))
    const reservadas = constante('POLITICA_COLUMNAS_RESERVADAS')
    expect(reservadas.length).toBeGreaterThan(0)
    for (const c of reservadas) expect(vender.has(c)).toBe(false)
  })
})
