/**
 * INF-5 (#1563): las notificaciones guardadas son del usuario y se borran al salir.
 *
 * Llevan montos y nombres de clientes. Antes vivían en `localStorage` bajo la clave
 * global `notifications` y sobrevivían al logout: el siguiente usuario de ese
 * teléfono veía las 50 del anterior.
 */
import React from 'react'
import { describe, it, expect, beforeEach } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { NotificationProvider, useNotification } from './NotificationContext'
import {
  claveNotificaciones,
  fijarUsuarioNotificaciones,
  olvidarNotificacionesDe,
} from '../utils/notificacionesGuardadas'

const wrapper = ({ children }: { children: React.ReactNode }) => <NotificationProvider>{children}</NotificationProvider>

function guardadas(usuarioId: string): Array<{ message?: string }> {
  return JSON.parse(localStorage.getItem(claveNotificaciones(usuarioId)) ?? '[]')
}

describe('INF-5: notificaciones por usuario', () => {
  beforeEach(() => {
    localStorage.clear()
    act(() => fijarUsuarioNotificaciones(null))
  })

  it('se guardan bajo el usuario de la sesión, y el siguiente no ve las del anterior', () => {
    act(() => fijarUsuarioNotificaciones('user-A'))
    const { result } = renderHook(() => useNotification(), { wrapper })

    act(() => result.current.error('Cobro a Kiosco X rechazado'))
    expect(result.current.notifications).toHaveLength(1)
    expect(guardadas('user-A').map(n => n.message)).toEqual(['Cobro a Kiosco X rechazado'])
    expect(localStorage.getItem('notifications')).toBeNull()

    // A sale (el logout las borra) y entra B en el mismo teléfono.
    act(() => {
      olvidarNotificacionesDe('user-A')
      fijarUsuarioNotificaciones(null)
    })
    expect(result.current.notifications).toEqual([])
    act(() => fijarUsuarioNotificaciones('user-B'))
    expect(result.current.notifications).toEqual([])
    expect(localStorage.getItem(claveNotificaciones('user-A'))).toBeNull()

    act(() => result.current.error('Otra cosa'))
    expect(guardadas('user-B').map(n => n.message)).toEqual(['Otra cosa'])
  })

  it('cambiar de usuario sin logout no le escribe la lista de uno al otro', () => {
    act(() => fijarUsuarioNotificaciones('user-A'))
    const { result } = renderHook(() => useNotification(), { wrapper })
    act(() => result.current.error('de A'))

    act(() => fijarUsuarioNotificaciones('user-B'))
    expect(result.current.notifications).toEqual([])
    expect(guardadas('user-B')).toEqual([])
    expect(guardadas('user-A').map(n => n.message)).toEqual(['de A'])
  })

  it('sin usuario quedan en memoria, y la clave global vieja se borra', () => {
    localStorage.setItem('notifications', JSON.stringify([{ id: 1, title: 'de alguien' }]))
    const { result } = renderHook(() => useNotification(), { wrapper })

    expect(result.current.notifications).toEqual([])
    expect(localStorage.getItem('notifications')).toBeNull()

    act(() => result.current.error('en memoria'))
    expect(result.current.notifications).toHaveLength(1)
    expect(Object.keys(localStorage).filter(k => k.startsWith('notifications'))).toEqual([])
  })
})
