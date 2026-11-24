/**
 * infra-INF-4 (tanda 6 de #1603): `supabase/.temp/` es estado local del CLI de Supabase (el ref
 * del proyecto y el id de la organización). El repo es PÚBLICO: no se versiona y está en el
 * `.gitignore`, para que un `supabase link` no lo vuelva a sumar.
 */
import { describe, it, expect } from 'vitest'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

describe('supabase/.temp no se versiona (infra-INF-4)', () => {
  it('está en el .gitignore', () => {
    const lineas = readFileSync(join(raiz, '.gitignore'), 'utf8').split(/\r?\n/).map(l => l.trim())
    expect(lineas).toContain('supabase/.temp/')
  })

  it('no hay archivos de supabase/.temp en el índice de git', () => {
    let versionados: string
    try {
      versionados = execFileSync('git', ['ls-files', 'supabase/.temp'], { cwd: raiz, encoding: 'utf8' })
    } catch {
      // Sin git (un export del código): no hay índice que mirar.
      return
    }
    expect(versionados.trim()).toBe('')
  })
})
