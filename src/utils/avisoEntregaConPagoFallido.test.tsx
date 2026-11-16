/**
 * L5 (#1603): dos entregas distintas cuyo cobro falla por lo mismo dejaban UN aviso
 * fijo, porque el texto no llevaba el número de pedido y los avisos iguales se unen.
 */
import React from 'react'
import { describe, it, expect } from 'vitest'
import { act, renderHook, screen } from '@testing-library/react'
import { NotificationProvider, useNotification } from '../contexts/NotificationContext'
import { avisoEntregaConPagoFallido } from './avisoEntregaConPagoFallido'

describe('avisoEntregaConPagoFallido', () => {
  it('nombra el pedido y el motivo', () => {
    expect(avisoEntregaConPagoFallido(600, 'Sin conexión')).toBe(
      'El pedido #600 se entregó, pero falló el pago: Sin conexión. Registralo desde el menú de pago.',
    )
  })

  it('dos cobros fallidos de pedidos distintos dejan dos avisos; el mismo, uno', () => {
    const hook = renderHook(() => useNotification(), {
      wrapper: ({ children }: { children: React.ReactNode }) => <NotificationProvider>{children}</NotificationProvider>,
    })
    act(() => { hook.result.current.error(avisoEntregaConPagoFallido(600, 'Sin conexión'), { persist: true }) })
    act(() => { hook.result.current.error(avisoEntregaConPagoFallido(601, 'Sin conexión'), { persist: true }) })
    expect(screen.getAllByRole('alert')).toHaveLength(2)
    act(() => { hook.result.current.error(avisoEntregaConPagoFallido(601, 'Sin conexión'), { persist: true }) })
    expect(screen.getAllByRole('alert')).toHaveLength(2)
  })
})
