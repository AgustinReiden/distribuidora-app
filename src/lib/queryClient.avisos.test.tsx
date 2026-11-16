/**
 * INF-2 (#1600): una consulta que falla no acumula avisos.
 *
 * `QueryCache.onError` llamaba a `error(message)` en cada fallo, y `error` persistía:
 * con una señal que no pasa datos, la campana (cada 60 s) y las demás consultas
 * sumaban 50 copias iguales que expulsaban los avisos importantes.
 */
import React from 'react'
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { act, renderHook, screen } from '@testing-library/react'
import { QueryClientProvider } from '@tanstack/react-query'
import { queryClient } from './queryClient'
import { NotificationProvider, useNotification } from '../contexts/NotificationContext'
import { crearFiltroDeAvisosDeConsulta, ESPERA_AVISO_DE_FONDO_MS } from './avisoConsultaFallida'

const AVISO = 'No se pudo cargar la información. Verificá tu conexión.'

let hook: ReturnType<typeof renderHook<ReturnType<typeof useNotification>, unknown>>
const notify = () => hook.result.current

const fallar = () => Promise.reject(new Error('sin señal'))
const avisos = () => screen.queryAllByRole('alert')

async function fallanVarias(n: number, prefijo: string, extra: Record<string, unknown> = {}) {
  await act(async () => {
    await Promise.allSettled(
      Array.from({ length: n }, (_, i) =>
        queryClient.fetchQuery({ queryKey: [prefijo, i], queryFn: fallar, retry: false, ...extra })
      )
    )
  })
}

describe('INF-2: consultas que fallan', () => {
  beforeEach(() => {
    queryClient.clear()
    hook = renderHook(() => useNotification(), {
      wrapper: ({ children }: { children: React.ReactNode }) => (
        <QueryClientProvider client={queryClient}>
          <NotificationProvider>{children}</NotificationProvider>
        </QueryClientProvider>
      ),
    })
  })

  it('50 fallos iguales dejan un solo aviso', async () => {
    await fallanVarias(50, 'inf2-cincuenta')

    expect(avisos()).toHaveLength(1)
    expect(avisos()[0].textContent).toBe(AVISO)
  })

  it('el aviso de una consulta fallida no persiste: se va solo', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    try {
      await fallanVarias(1, 'inf2-no-persiste')
      expect(avisos()).toHaveLength(1)

      await act(async () => { vi.advanceTimersByTime(6000) })

      expect(avisos()).toHaveLength(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it('no desaloja un aviso importante que ya estaba en pantalla', async () => {
    act(() => { notify().error('El cobro de $1.000 no se registró', { persist: true }) })

    await fallanVarias(50, 'inf2-importante')

    expect(screen.getByText('El cobro de $1.000 no se registró')).toBeInTheDocument()
    expect(avisos()).toHaveLength(2)
  })

  it('una consulta con meta.silentError no avisa', async () => {
    await fallanVarias(5, 'inf2-silenciosa', { meta: { silentError: true } })

    expect(avisos()).toHaveLength(0)
  })

  it('un sondeo que ya tenía datos y falla una y otra vez avisa una sola vez', async () => {
    queryClient.setQueryData(['inf2-sondeo'], ['lo que había'])
    for (let i = 0; i < 10; i++) {
      await act(async () => {
        await Promise.allSettled([
          queryClient.fetchQuery({ queryKey: ['inf2-sondeo'], queryFn: fallar, retry: false, staleTime: 0 }),
        ])
      })
    }

    expect(avisos()).toHaveLength(1)
  })
})

describe('crearFiltroDeAvisosDeConsulta', () => {
  const sinDatos = { state: { data: undefined }, observers: [] as Array<{ options: { refetchInterval?: unknown } }> }
  const conDatos = { state: { data: [1] }, observers: [] as Array<{ options: { refetchInterval?: unknown } }> }
  const sondeo = { state: { data: undefined }, observers: [{ options: { refetchInterval: 60_000 } }] }

  it('la primera carga que falla avisa siempre', () => {
    const debeAvisar = crearFiltroDeAvisosDeConsulta(() => 0)
    expect(debeAvisar(sinDatos)).toBe(true)
    expect(debeAvisar(sinDatos)).toBe(true)
  })

  it('silentError no avisa nunca', () => {
    const debeAvisar = crearFiltroDeAvisosDeConsulta(() => 0)
    expect(debeAvisar({ ...sinDatos, meta: { silentError: true } })).toBe(false)
  })

  it('las de fondo (con datos o con intervalo) avisan una vez cada tanto, no en cada intento', () => {
    let t = 1_000
    const debeAvisar = crearFiltroDeAvisosDeConsulta(() => t)

    expect(debeAvisar(conDatos)).toBe(true)
    t += 60_000
    expect(debeAvisar(sondeo)).toBe(false)
    expect(debeAvisar(conDatos)).toBe(false)
    t += ESPERA_AVISO_DE_FONDO_MS
    expect(debeAvisar(sondeo)).toBe(true)
  })

  it('un refetchInterval en false no es un sondeo', () => {
    const debeAvisar = crearFiltroDeAvisosDeConsulta(() => 0)
    const noEsSondeo = { state: { data: undefined }, observers: [{ options: { refetchInterval: false } }] }
    expect(debeAvisar(noEsSondeo)).toBe(true)
    expect(debeAvisar(noEsSondeo)).toBe(true)
  })
})

afterEach(() => {
  vi.useRealTimers()
})
