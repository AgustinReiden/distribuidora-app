/**
 * H1/H7 de la revisión de B12a: lo que frena la recarga obligatoria (D57) es lo
 * que se ve en el DOM (un modal, un campo con foco) y lo que una pantalla declara.
 */
import { describe, it, expect, afterEach } from 'vitest'
import { hayTrabajoEnCurso, marcarTrabajoEnCurso, motivosDeTrabajoEnCurso, _resetTrabajoEnCursoParaTests } from './trabajoEnCurso'

afterEach(() => {
  _resetTrabajoEnCursoParaTests()
  document.body.innerHTML = ''
})

describe('hayTrabajoEnCurso', () => {
  it('sin nada en pantalla ni marcas, no hay', () => {
    expect(hayTrabajoEnCurso()).toBe(false)
  })

  it('un modal abierto o un campo con el foco cuentan', () => {
    document.body.innerHTML = '<div role="dialog"></div>'
    expect(hayTrabajoEnCurso()).toBe(true)
    document.body.innerHTML = '<input id="x" />'
    document.getElementById('x')?.focus()
    expect(hayTrabajoEnCurso()).toBe(true)
  })

  it('H7: una marca de la pantalla cuenta, sin modal y sin foco, hasta que se baja', () => {
    const soltar = marcarTrabajoEnCurso('monto tipeado sin guardar')
    const soltarOtra = marcarTrabajoEnCurso('sincronizando la cola')
    expect(hayTrabajoEnCurso()).toBe(true)
    expect(motivosDeTrabajoEnCurso()).toEqual(['monto tipeado sin guardar', 'sincronizando la cola'])
    soltar()
    expect(hayTrabajoEnCurso()).toBe(true)
    soltarOtra()
    expect(hayTrabajoEnCurso()).toBe(false)
  })
})
