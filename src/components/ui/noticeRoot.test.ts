/**
 * La pila de avisos fijos (#716): un solo nodo en `body`, creado a demanda y
 * reusado por todos los avisos.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { getNoticeRoot } from './noticeRoot'

function quitarPila(): void {
  document.getElementById('notice-root')?.remove()
}

describe('getNoticeRoot', () => {
  beforeEach(quitarPila)
  afterEach(() => {
    vi.unstubAllGlobals()
    quitarPila()
  })

  it('la primera vez crea #notice-root colgado de body', () => {
    expect(document.getElementById('notice-root')).toBeNull()

    const root = getNoticeRoot()

    expect(root).not.toBeNull()
    expect(root?.id).toBe('notice-root')
    expect(root?.parentElement).toBe(document.body)
  })

  it('las llamadas siguientes devuelven el mismo nodo, sin duplicarlo', () => {
    const primero = getNoticeRoot()
    const segundo = getNoticeRoot()

    expect(segundo).toBe(primero)
    expect(document.querySelectorAll('#notice-root')).toHaveLength(1)
  })

  it('si alguien lo saco del body, lo vuelve a crear en vez de devolver el nodo suelto', () => {
    const viejo = getNoticeRoot()
    viejo?.remove()

    const nuevo = getNoticeRoot()

    expect(nuevo).not.toBe(viejo)
    expect(nuevo?.parentElement).toBe(document.body)
  })

  it('se ancla abajo a lo ancho, debajo de los modales, apila de abajo hacia arriba sin comerse clicks, con tope de alto, sin achicar a los avisos y con los avisos inertes bajo una capa modal de Radix', () => {
    const root = getNoticeRoot()

    for (const clase of [
      'fixed',
      'left-0',
      'right-0',
      'bottom-0',
      'z-40',
      'flex',
      'flex-col-reverse',
      'items-end',
      'gap-2',
      'p-4',
      'pointer-events-none',
      'max-h-[calc(100dvh-4rem)]',
      'overflow-y-auto',
      'overscroll-contain',
      '*:shrink-0',
      '[body[style*="pointer-events:_none"]_&>*]:pointer-events-none',
    ]) {
      expect(root?.classList.contains(clase), clase).toBe(true)
    }
  })

  it('el padding de abajo suma --bottom-inset (0px si nadie lo define) a los 16 px de p-4', () => {
    const root = getNoticeRoot()

    expect(root?.style.paddingBottom).toBe('calc(1rem + var(--bottom-inset, 0px))')
  })

  it('sin document devuelve null en vez de tirar', () => {
    vi.stubGlobal('document', undefined)

    expect(() => getNoticeRoot()).not.toThrow()
    expect(getNoticeRoot()).toBeNull()
  })
})
