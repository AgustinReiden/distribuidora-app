/**
 * INF-1 (#1600): un aviso persistente queda en pantalla hasta que el usuario lo cierra.
 *
 * Los avisos con `persist: true` se veían 4 segundos y después no los veía nadie: el
 * centro de notificaciones que los guardaba se borró, y «el pedido #N sí se guardó, no
 * lo cargues de nuevo» o «el cobro de $X no se registró» se perdían. No se repone el
 * centro: el aviso mismo se queda hasta que se lo cierra a mano. Un error común sigue
 * yéndose solo.
 *
 * INF-2 (#1600): el mismo aviso no se repite mientras siga en pantalla.
 */
import React from 'react'
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { act, fireEvent, renderHook, screen } from '@testing-library/react'
import { NotificationProvider, useNotification } from './NotificationContext'

let hook: ReturnType<typeof renderHook<ReturnType<typeof useNotification>, unknown>>
const notify = () => hook.result.current

function montar() {
  hook = renderHook(() => useNotification(), {
    wrapper: ({ children }: { children: React.ReactNode }) => <NotificationProvider>{children}</NotificationProvider>,
  })
}

const avisos = () => Array.from(document.querySelectorAll('[role="alert"], [role="status"]'))
const textos = () => avisos().map(a => a.textContent)

describe('INF-1: el aviso persistente se queda hasta que se cierra a mano', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('un aviso con persist sigue visible mucho después de lo que antes tardaba en irse', () => {
    montar()
    act(() => {
      notify().warning('El pedido #7 sí se guardó: no lo cargues de nuevo.', { persist: true })
    })
    expect(textos()).toContain('El pedido #7 sí se guardó: no lo cargues de nuevo.')

    act(() => { vi.advanceTimersByTime(10 * 60 * 1000) })

    expect(textos()).toContain('El pedido #7 sí se guardó: no lo cargues de nuevo.')
  })

  it('un aviso común se va solo', () => {
    montar()
    act(() => {
      notify().success('Pedido creado correctamente')
      notify().warning('Algo menor')
      notify().info('Un dato')
    })
    expect(avisos()).toHaveLength(3)

    act(() => { vi.advanceTimersByTime(6000) })

    expect(avisos()).toHaveLength(0)
  })

  it('un error común no persiste: sólo lo hace el que lo pide', () => {
    montar()
    act(() => {
      notify().error('Error al cambiar estado')
      notify().error('El cobro de $1.000 no se registró', { persist: true })
    })
    expect(avisos()).toHaveLength(2)

    act(() => { vi.advanceTimersByTime(6000) })

    expect(textos()).toEqual(['El cobro de $1.000 no se registró'])
  })

  it('se cierra con el botón, que tiene nombre para el lector de pantalla', () => {
    montar()
    act(() => { notify().error('Quedan 2 operaciones sin sincronizar', { persist: true }) })

    const cerrar = screen.getByRole('button', { name: 'Cerrar aviso' })
    expect(cerrar.tagName).toBe('BUTTON')
    fireEvent.click(cerrar)
    act(() => { vi.advanceTimersByTime(300) })

    expect(avisos()).toHaveLength(0)
  })

  it('un error o una advertencia se anuncian en el acto (alert); el resto con cortesía (status)', () => {
    montar()
    act(() => {
      notify().error('e', { persist: true })
      notify().warning('w', { persist: true })
      notify().success('s', { persist: true })
    })

    expect(screen.getAllByRole('alert').map(a => a.textContent)).toEqual(['e', 'w'])
    expect(screen.getAllByRole('status').map(a => a.textContent)).toEqual(['s'])
  })

  it('con varios avisos fijos aparece «Cerrar todos» y los cierra de una vez', () => {
    montar()
    act(() => { notify().error('a', { persist: true }) })
    expect(screen.queryByRole('button', { name: 'Cerrar todos los avisos' })).toBeNull()

    act(() => {
      notify().error('b', { persist: true })
      notify().warning('c', { persist: true })
    })
    fireEvent.click(screen.getByRole('button', { name: 'Cerrar todos los avisos' }))

    expect(avisos()).toHaveLength(0)
  })

  it('la pila no cubre el celular: topea en la mitad de la ventana y scrollea por dentro', () => {
    montar()
    act(() => {
      for (let i = 0; i < 12; i++) notify().error(`Aviso fijo ${i}`, { persist: true })
    })

    const pila = screen.getByRole('region', { name: 'Avisos' })
    expect(pila.className).toContain('max-h-[50dvh]')
    expect(pila.className).toContain('overflow-y-auto')
    // y el ancho no pasa del de la pantalla
    expect(pila.className).toContain('calc(100vw-2rem)')
  })
})

describe('INF-2: el mismo aviso no se repite mientras sigue en pantalla', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('50 llamadas iguales dejan un solo aviso', () => {
    montar()
    act(() => {
      for (let i = 0; i < 50; i++) notify().error('No se pudo cargar la información. Verificá tu conexión.')
    })

    expect(avisos()).toHaveLength(1)
  })

  it('un aviso repetido renueva el tiempo del que hay, no suma otro', () => {
    montar()
    act(() => { notify().error('Sin señal') })
    act(() => { vi.advanceTimersByTime(4000) })
    act(() => { notify().error('Sin señal') })
    act(() => { vi.advanceTimersByTime(4000) })

    // Pasaron 8 s desde el primero, pero sólo 4 desde el último: sigue.
    expect(avisos()).toHaveLength(1)
    act(() => { vi.advanceTimersByTime(2000) })
    expect(avisos()).toHaveLength(0)
  })

  it('si el repetido pide persistir, el que hay pasa a persistente', () => {
    montar()
    act(() => { notify().error('Falló el cobro') })
    act(() => { notify().error('Falló el cobro', { persist: true }) })
    act(() => { vi.advanceTimersByTime(60_000) })

    expect(textos()).toEqual(['Falló el cobro'])
  })

  it('avisos distintos no se pisan', () => {
    montar()
    act(() => {
      notify().error('uno')
      notify().error('dos')
      notify().warning('uno')
    })

    expect(avisos()).toHaveLength(3)
  })
})
