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

  it('ningún formulario recorta lo que le manda un NumberInput en su onChange', () => {
    const recortan: string[] = []
    for (const ruta of archivos(SRC)) {
      const texto = fs.readFileSync(ruta, 'utf-8')
      for (const m of texto.matchAll(/<NumberInput\b[\s\S]*?\/>/g)) {
        const onChange = /onChange=\{([\s\S]*?)\}\s*(?:\n|\/>|[a-zA-Z-]+=)/.exec(m[0])?.[1] ?? ''
        if (/Math\.(max|min)\(/.test(onChange)) {
          recortan.push(`${relativa(ruta)}:${texto.slice(0, m.index).split('\n').length}`)
        }
      }
    }
    expect(recortan, 'El límite va en min/max del campo, con su motivo en rojo: no se recorta en el onChange').toEqual([])
  })
})
