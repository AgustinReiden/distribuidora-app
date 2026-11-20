/**
 * El «atrás» del teléfono cierra la ventana abierta (decisión 4 del dueño, #1603). Con el historial REAL de
 * jsdom (`pushState`, `history.back()`, `popstate`): un comportamiento por test.
 */
import { StrictMode, useState } from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { asentar, atras, marca } from '../test/atrasHelpers'
import { render, cleanup, act } from '@testing-library/react'
import { useAtrasCierraModal } from '../hooks/useAtrasCierraModal'
import { limpiarAtrasAlCargar, reiniciarAtrasModales, volverUnaPantalla } from './atrasModales'

/** Deja pasar los `setTimeout 0` de la mecánica y los `popstate` de jsdom. */

/** Una ventana que, ante el «atrás», se cierra (o no, según `seCierra`). */
function Ventana({ alPedirCierre, seCierra = true, activo = true }: { alPedirCierre: () => void; seCierra?: boolean; activo?: boolean }) {
  const [abierta, setAbierta] = useState(true)
  useAtrasCierraModal(() => {
    alPedirCierre()
    if (seCierra) setAbierta(false)
  }, activo && abierta)
  return abierta ? <div role="dialog">ventana</div> : null
}

beforeEach(() => {
  reiniciarAtrasModales()
  window.history.replaceState(null, '', '/')
})

afterEach(async () => {
  cleanup()
  await asentar()
  reiniciarAtrasModales()
})

describe('atrás cierra la ventana abierta', () => {
  // (`history.length` no sirve para contar: un `pushState` después de un `go(-n)` descarta las entradas de
  // adelante. Se cuenta con la marca de la entrada y con cuántos «atrás» hacen falta para sacarla.)
  it('abrir una ventana suma UNA entrada al historial, con la marca', async () => {
    const pedir = vi.fn()
    render(<Ventana alPedirCierre={pedir} />)
    await asentar()
    expect(marca()).toBe(1)

    await atras()
    expect(pedir).toHaveBeenCalledTimes(1)
    expect(marca()).toBeUndefined()
  })

  it('«atrás» le pide el cierre a la ventana y no navega de más', async () => {
    window.history.pushState({ pantalla: 'pedidos' }, '', '/pedidos')
    const pedir = vi.fn()
    render(<Ventana alPedirCierre={pedir} />)
    await asentar()

    await atras()

    expect(pedir).toHaveBeenCalledTimes(1)
    // Seguimos en la pantalla de la ventana, no en la de antes.
    expect(window.location.pathname).toBe('/pedidos')
    expect(marca()).toBeUndefined()
  })

  it('dos ventanas apiladas: el «atrás» cierra la de arriba primero, de a una', async () => {
    const abajo = vi.fn()
    const arriba = vi.fn()
    render(<><Ventana alPedirCierre={abajo} /><Ventana alPedirCierre={arriba} /></>)
    await asentar()
    expect(marca()).toBe(2)

    await atras()
    expect(arriba).toHaveBeenCalledTimes(1)
    expect(abajo).not.toHaveBeenCalled()
    expect(marca()).toBe(1)

    await atras()
    expect(abajo).toHaveBeenCalledTimes(1)
    expect(marca()).toBeUndefined()
  })

  it('si la ventana no se cierra (pide confirmar), la entrada se repone y el siguiente «atrás» vuelve a pedirlo', async () => {
    const pedir = vi.fn()
    render(<Ventana alPedirCierre={pedir} seCierra={false} />)
    await asentar()

    await atras()
    expect(pedir).toHaveBeenCalledTimes(1)
    expect(marca()).toBe(1)

    await atras()
    expect(pedir).toHaveBeenCalledTimes(2)
  })

  it('al cerrarse por otro camino (se desmonta), su entrada se retira sin navegar de más', async () => {
    window.history.pushState({ pantalla: 'pedidos' }, '', '/pedidos')
    const pedir = vi.fn()
    const { unmount } = render(<Ventana alPedirCierre={pedir} />)
    await asentar()
    expect(marca()).toBe(1)

    unmount()
    await asentar()

    expect(marca()).toBeUndefined()
    expect(window.location.pathname).toBe('/pedidos')
    expect(pedir).not.toHaveBeenCalled()
  })

  it('cerrar con la ventana de arriba y que la de abajo siga: queda una sola entrada', async () => {
    const { rerender } = render(<><Ventana alPedirCierre={vi.fn()} /><Ventana alPedirCierre={vi.fn()} /></>)
    await asentar()
    expect(marca()).toBe(2)

    rerender(<Ventana alPedirCierre={vi.fn()} />)
    await asentar()
    expect(marca()).toBe(1)
  })

  it('sin ventanas abiertas, el «atrás» navega como siempre y nadie recibe el cierre', async () => {
    const pedir = vi.fn()
    const { unmount } = render(<Ventana alPedirCierre={pedir} />)
    await asentar()
    unmount()
    await asentar()
    window.history.pushState({ pantalla: 'a' }, '', '/a')
    window.history.pushState({ pantalla: 'b' }, '', '/b')

    await atras()

    expect(window.location.pathname).toBe('/a')
    expect(pedir).not.toHaveBeenCalled()
  })

  it('una ventana inactiva (`activo` en false) no suma entrada', async () => {
    render(<Ventana alPedirCierre={vi.fn()} activo={false} />)
    await asentar()
    expect(marca()).toBeUndefined()
  })

  it('en StrictMode (monta, desmonta, monta) queda UNA entrada, no dos ni cero', async () => {
    const pedir = vi.fn()
    render(<StrictMode><Ventana alPedirCierre={pedir} /></StrictMode>)
    await asentar()
    expect(marca()).toBe(1)

    // Con dos entradas, el primer «atrás» dejaría la marca en 1; con una, la saca.
    await atras()
    expect(pedir).toHaveBeenCalledTimes(1)
    expect(marca()).toBeUndefined()
  })

  it('si el router navegó encima de la entrada de la ventana, al cerrarla no se vuelve a otra pantalla', async () => {
    const { unmount } = render(<Ventana alPedirCierre={vi.fn()} />)
    await asentar()
    // La ventana navegó a otra ruta (algo como `navigate('/otra')`) y después se cierra.
    window.history.pushState({ pantalla: 'otra' }, '', '/otra')
    unmount()
    await asentar()

    expect(window.location.pathname).toBe('/otra')
  })

  it('el «atrás» usa el cierre de AHORA, no el del render en que se abrió', async () => {
    const primero = vi.fn()
    const segundo = vi.fn()
    const { rerender } = render(<Ventana alPedirCierre={primero} seCierra={false} />)
    await asentar()
    rerender(<Ventana alPedirCierre={segundo} seCierra={false} />)

    await atras()

    expect(primero).not.toHaveBeenCalled()
    expect(segundo).toHaveBeenCalledTimes(1)
  })
})

describe('recargar con una ventana abierta', () => {
  it('el historial que quedó con la marca vuelve a la entrada de abajo: no queda un «atrás» fantasma', async () => {
    window.history.pushState({ pantalla: 'base' }, '', '/pedidos')
    // Una recarga con la ventana abierta: la entrada actual conserva la marca, pero no hay ventana.
    window.history.pushState({ pantalla: 'base', atrasModales: 1 }, '', '/pedidos')
    expect(marca()).toBe(1)

    limpiarAtrasAlCargar()
    await asentar()

    expect(marca()).toBeUndefined()
    expect(window.location.pathname).toBe('/pedidos')
  })

  it('sin marca no hace nada', async () => {
    window.history.pushState({ pantalla: 'base' }, '', '/pedidos')
    const antes = window.history.state
    limpiarAtrasAlCargar()
    await asentar()
    expect(window.history.state).toEqual(antes)
  })
})

describe('un modal que es una ruta (el recorrido del preventista)', () => {
  it('«volver a la pantalla de antes» vuelve a la ruta anterior de una, sin dejar la entrada de la ventana ni pedirle el cierre', async () => {
    window.history.pushState({ pantalla: 'pedidos' }, '', '/pedidos')
    window.history.pushState({ pantalla: 'recorrido' }, '', '/recorrido')
    const pedir = vi.fn()
    const { unmount } = render(<Ventana alPedirCierre={pedir} />)
    await asentar()
    expect(marca()).toBe(1)

    act(() => { volverUnaPantalla() })
    // Al cambiar de ruta, la pantalla con la ventana se desmonta.
    unmount()
    await asentar()

    expect(window.location.pathname).toBe('/pedidos')
    expect(marca()).toBeUndefined()
    expect(pedir).not.toHaveBeenCalled()
  })

  it('sin ventana abierta es un «atrás» común', async () => {
    window.history.pushState({ pantalla: 'pedidos' }, '', '/pedidos')
    window.history.pushState({ pantalla: 'recorrido' }, '', '/recorrido')
    act(() => { volverUnaPantalla() })
    await asentar()
    expect(window.location.pathname).toBe('/pedidos')
  })
})
