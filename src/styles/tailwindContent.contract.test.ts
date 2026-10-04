import { describe, expect, it } from 'vitest'

/**
 * Test de CONTRATO del `content` de Tailwind (#743).
 *
 * Tailwind escanea como texto cualquier archivo que matchee `content` y genera
 * una regla por cada string con forma de clase, la use un componente o no. Con
 * `./src/**` a secas, el `'bg-brand-600'` de un `expect(...)` terminaba en
 * `dist/assets/index-*.css`. Los tests se excluyen con globs negados, y este
 * archivo fija que sigan ahi y que no se haya perdido ninguna fuente real.
 *
 * Asevera la config, no el CSS compilado: un build no corre dentro de vitest.
 * La medicion (CSS antes/despues, selectores que se fueron) se hizo a mano en el
 * PR; lo que evita que alguien la deshaga sin querer es esto.
 */

// Ruta en una variable a proposito: tailwind.config.js es JS puro y fuera de
// `include` del tsconfig, y un import literal falla el typecheck (TS7016).
const RUTA_CONFIG = '../../tailwind.config.js'
const { default: config } = (await import(/* @vite-ignore */ RUTA_CONFIG)) as {
  default: { content: string[] }
}

const positivos = config.content.filter((p) => !p.startsWith('!'))
const negativos = config.content.filter((p) => p.startsWith('!'))

describe('tailwind.config.js: content (#743)', () => {
  it('sigue escaneando index.html y el codigo de src', () => {
    expect(positivos).toEqual(['./index.html', './src/**/*.{js,ts,jsx,tsx}'])
  })

  it('excluye los archivos de test del escaneo', () => {
    expect(negativos).toEqual(
      expect.arrayContaining(['!./src/**/*.test.{js,ts,jsx,tsx}']),
    )
  })

  it('excluye las carpetas __tests__ (con sus fixtures)', () => {
    expect(negativos).toContain('!./src/**/__tests__/**')
  })

  it('excluye src/test (setup, utils y stubs)', () => {
    expect(negativos).toContain('!./src/test/**')
  })

  it('no excluye nada mas que tests', () => {
    // Un negado nuevo que no sea de tests esconderia clases reales del CSS.
    for (const patron of negativos) {
      expect(patron).toMatch(/\.test\.|__tests__|\/src\/test\//)
    }
  })
})
