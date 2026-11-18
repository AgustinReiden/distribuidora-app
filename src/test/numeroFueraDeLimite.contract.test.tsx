import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { useState } from 'react'
import { NumberInput } from '../components/ui/NumberInput'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../hooks/useRegistroIlegibles'

/**
 * B23 de #1603 (decisión del dueño, 18/11: «Que quede en rojo y no guarde»): un número fuera de su
 * límite queda en rojo y el formulario no guarda. Nada se recorta ni se completa en silencio: ni el
 * campo al salir (el blur del toque en Guardar recortaba y guardaba el recorte en el mismo toque),
 * ni el formulario en su `onChange` (`Math.max(n, minCantidad)`).
 *
 * Si este test falla, alguien volvió a recortar: el límite se dice con `motivoMin` / `motivoMax` /
 * `motivoVacio` y el campo queda en rojo en el registro del formulario.
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..')

function archivos(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const ruta = path.join(dir, e.name)
    if (e.isDirectory()) return e.name === '__tests__' ? [] : archivos(ruta)
    return /\.tsx$/.test(e.name) && !/\.(test|spec)\./.test(e.name) ? [ruta] : []
  })
}

const relativa = (r: string): string => path.relative(path.resolve(SRC, '..'), r).replace(/\\/g, '/')

describe('un número fuera de su límite no se recorta (B23)', () => {
  function Formulario({ onGuardar, onCambio, ...limites }: {
    onGuardar: (n: number | null) => void
    onCambio: (n: number) => void
    min?: number
    max?: number
    commitOnChange?: boolean
  }) {
    const [v, setV] = useState<number | null>(3)
    const ilegibles = useRegistroIlegibles()
    return (
      <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
        <NumberInput aria-label="num" integer value={v} onChange={n => { onCambio(n); setV(n) }} {...limites} />
        <button type="button" onClick={() => { if (!ilegibles.hay) onGuardar(v) }}>Guardar</button>
      </RegistroIlegiblesContext.Provider>
    )
  }

  it.each([
    { min: 6, texto: '2' },
    { max: 5, texto: '50' },
    { min: 1, max: 5, texto: '0' },
    { min: 1, max: 5, texto: '' },
  ])('$texto con min $min y max $max: no llega recortado ni se guarda (al salir ni en vivo)', async ({ texto, ...limites }) => {
    for (const commitOnChange of [false, true]) {
      const user = userEvent.setup()
      const onGuardar = vi.fn()
      const onCambio = vi.fn()
      const { unmount } = render(<Formulario onGuardar={onGuardar} onCambio={onCambio} commitOnChange={commitOnChange} {...limites} />)
      const input = screen.getByLabelText('num')

      await user.clear(input)
      if (texto) await user.type(input, texto)
      await user.click(screen.getByRole('button', { name: 'Guardar' }))

      expect(onGuardar).not.toHaveBeenCalled()
      expect(input).toHaveAttribute('aria-invalid', 'true')
      // El padre se queda con el valor de antes de tipear (3): nunca con el borde del límite.
      const ultimoCambio = (): number | undefined => (onCambio.mock.lastCall as [number] | undefined)?.[0]
      const ultimo = ultimoCambio()
      expect(ultimo === undefined || ultimo === 3, `el padre quedó con ${ultimo}`).toBe(true)
      await user.tab()
      const alSalir = ultimoCambio()
      expect(alSalir === undefined || alSalir === 3, `al salir, el padre quedó con ${alSalir}`).toBe(true)
      unmount()
    }
  })

  it('NumberInput no tiene un recorte contra min o max', () => {
    const fuente = fs.readFileSync(path.join(SRC, 'components/ui/NumberInput.tsx'), 'utf-8')
    expect(fuente).not.toMatch(/Math\.(max|min)\(\s*(min|max)\b/)
    expect(fuente).not.toMatch(/\bclamp\(/)
  })

  /**
   * El cuerpo de la función `nombre` declarada en el mismo archivo (`const nombre = (…) => {…}`,
   * `const nombre = useCallback((…) => {…})` o `function nombre(…) {…}`), o null si no está ahí.
   */
  function cuerpoDe(texto: string, nombre: string): string | null {
    const decl = new RegExp(`(?:const\\s+${nombre}\\s*=|function\\s+${nombre}\\s*\\()`).exec(texto)
    if (!decl) return null
    const resto = texto.slice(decl.index)
    if (decl[0].startsWith('const')) {
      const flecha = resto.indexOf('=>')
      if (flecha === -1) return null
      // Una flecha con expresión (sin llaves): hasta la próxima sentencia con la misma sangría.
      if (!/^=>\s*\{/.test(resto.slice(flecha))) {
        const sangria = /[ \t]*$/.exec(texto.slice(0, decl.index))?.[0] ?? ''
        const fin = resto.slice(flecha).search(new RegExp(`\\n${sangria}(?![ \\t])\\S`))
        return fin === -1 ? resto.slice(flecha) : resto.slice(flecha, flecha + fin)
      }
    }
    // Con llaves: la primera `{` después de `=>` (una flecha) o de `)` (una función).
    const inicio = decl[0].startsWith('const') ? resto.indexOf('=>') : resto.search(/\)\s*(?::[^{]*)?\{/)
    if (inicio === -1) return null
    const desde = decl.index + resto.indexOf('{', inicio)
    let profundidad = 0
    for (let i = desde; i < texto.length; i++) {
      if (texto[i] === '{') profundidad++
      else if (texto[i] === '}' && --profundidad === 0) return texto.slice(desde, i + 1)
    }
    return null
  }

  // Lo que mide: un Math.max / Math.min escrito en el onChange del NumberInput, o en el cuerpo de la
  // función del mismo archivo que ese onChange llama (`handleCantidadSet(id, n)`, un setter con
  // nombre). Lo que NO ve: un recorte dos llamadas más abajo, en otro archivo (el container, un
  // hook, un reducer) o con otro nombre (un `if (n > tope) n = tope`). Eso lo cubren los tests que
  // tipean en cada formulario y tocan Guardar sin salir del campo (`*.limites.test.tsx` y los
  // casos B23 de los tests de cada modal).
  it('ningún formulario recorta lo que le manda un NumberInput en su onChange ni en el handler que llama', () => {
    const recortan: string[] = []
    for (const ruta of archivos(SRC)) {
      const texto = fs.readFileSync(ruta, 'utf-8')
      for (const m of texto.matchAll(/<NumberInput\b[\s\S]*?\/>/g)) {
        const onChange = /onChange=\{([\s\S]*?)\}\s*(?:\n|\/>|[a-zA-Z-]+=)/.exec(m[0])?.[1] ?? ''
        const linea = `${relativa(ruta)}:${texto.slice(0, m.index).split('\n').length}`
        if (/Math\.(max|min)\(/.test(onChange)) recortan.push(linea)
        for (const [, nombre] of onChange.matchAll(/\b([a-zA-Z_]\w*)\s*\(/g)) {
          if (nombre === 'Math' || /^set[A-Z]/.test(nombre)) continue
          const cuerpo = cuerpoDe(texto, nombre)
          if (cuerpo && /Math\.(max|min)\(/.test(cuerpo)) recortan.push(`${linea} (en ${nombre})`)
        }
        // `onChange={handler}` sin llamarlo.
        const suelto = /^\s*([a-zA-Z_]\w*)\s*$/.exec(onChange)?.[1]
        if (suelto && !/^set[A-Z]/.test(suelto)) {
          const cuerpo = cuerpoDe(texto, suelto)
          if (cuerpo && /Math\.(max|min)\(/.test(cuerpo)) recortan.push(`${linea} (en ${suelto})`)
        }
      }
    }
    expect(recortan, 'El límite va en min/max del campo, con su motivo en rojo: no se recorta en el onChange').toEqual([])
  })
})
