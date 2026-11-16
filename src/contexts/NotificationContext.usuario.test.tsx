/**
 * INF-5 (#1563) e INF-1 (#1600): lo que dejan los avisos en el teléfono, y de quién son.
 *
 * Las notificaciones guardadas llevaban montos y nombres de clientes bajo la clave
 * global `notifications` y sobrevivían al logout. Se borraron (nada las leía): hoy no
 * se escribe ninguna, y las que quedaron de versiones anteriores se barren. Los avisos
 * que se quedan en pantalla hasta que se cierran tampoco pasan de un usuario a otro.
 */
import React from 'react'
import { describe, it, expect, beforeEach } from 'vitest'
import { act, renderHook, screen } from '@testing-library/react'
import { NotificationProvider, useNotification } from './NotificationContext'
import {
  fijarUsuarioNotificaciones,
  olvidarNotificacionesGuardadas,
} from '../utils/notificacionesGuardadas'

const wrapper = ({ children }: { children: React.ReactNode }) => <NotificationProvider>{children}</NotificationProvider>

describe('notificaciones guardadas en el teléfono', () => {
  beforeEach(() => {
    localStorage.clear()
    act(() => fijarUsuarioNotificaciones(null))
  })

  it('no se escribe ninguna: un aviso no deja nada en localStorage', () => {
    act(() => fijarUsuarioNotificaciones('user-A'))
    const { result } = renderHook(() => useNotification(), { wrapper })

    act(() => result.current.error('Cobro a Kiosco X rechazado', { persist: true }))

    expect(Object.keys(localStorage).filter(k => k.startsWith('notifications'))).toEqual([])
  })

  it('al montar se borran las que dejaron versiones anteriores, la global y las de cada usuario', () => {
    localStorage.setItem('notifications', JSON.stringify([{ id: 1, title: 'de alguien' }]))
    localStorage.setItem('notifications:user-A', JSON.stringify([{ id: 2, title: 'Cobro a Kiosco X' }]))
    localStorage.setItem('otra-clave', 'queda')

    renderHook(() => useNotification(), { wrapper })

    expect(localStorage.getItem('notifications')).toBeNull()
    expect(localStorage.getItem('notifications:user-A')).toBeNull()
    expect(localStorage.getItem('otra-clave')).toBe('queda')
  })

  it('olvidarNotificacionesGuardadas barre las de todos los usuarios (el logout no sabe de quién eran)', () => {
    localStorage.setItem('notifications:user-A', '[]')
    localStorage.setItem('notifications:user-B', '[]')

    olvidarNotificacionesGuardadas()

    expect(localStorage.getItem('notifications:user-A')).toBeNull()
    expect(localStorage.getItem('notifications:user-B')).toBeNull()
  })
})

describe('los avisos fijos son de quien los vio', () => {
  let hook: ReturnType<typeof renderHook<ReturnType<typeof useNotification>, unknown>>
  const notify = () => hook.result.current
  const montar = () => {
    hook = renderHook(() => useNotification(), { wrapper })
  }

  beforeEach(() => {
    localStorage.clear()
    act(() => fijarUsuarioNotificaciones(null))
  })

  it('el aviso de antes de salir se ve al volver a entrar el mismo usuario', () => {
    act(() => fijarUsuarioNotificaciones('user-A'))
    montar()
    act(() => notify().warning('Quedan 2 operaciones sin sincronizar', { persist: true }))

    act(() => fijarUsuarioNotificaciones(null))
    expect(screen.getByText('Quedan 2 operaciones sin sincronizar')).toBeInTheDocument()
    act(() => fijarUsuarioNotificaciones('user-A'))
    expect(screen.getByText('Quedan 2 operaciones sin sincronizar')).toBeInTheDocument()
  })

  it('si entra otro usuario en el mismo teléfono, no ve los avisos fijos del anterior', () => {
    act(() => fijarUsuarioNotificaciones('user-A'))
    montar()
    act(() => notify().error('Cobro a Kiosco X rechazado', { persist: true }))
    expect(screen.getByText('Cobro a Kiosco X rechazado')).toBeInTheDocument()

    act(() => fijarUsuarioNotificaciones(null))
    act(() => fijarUsuarioNotificaciones('user-B'))

    expect(screen.queryByText('Cobro a Kiosco X rechazado')).toBeNull()
  })
})
