/**
 * `RecorridoPreventistaContainer` (Fr-B10 de #1554, T14 de #1690): no tenía ningún test.
 *
 * Es sólo el pegamento entre las consultas (clientes y preventistas), el hook que optimiza la
 * ruta y el modal. Se fija qué le entrega al modal, qué hace cuando el modal pide optimizar y qué
 * hace al cerrarse: borra la ruta y vuelve UNA pantalla (no `history.back()` pelado).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

const { optimizarRuta, limpiarRuta, volverUnaPantalla, estadoHook, propsModal } = vi.hoisted(() => ({
  optimizarRuta: vi.fn(),
  limpiarRuta: vi.fn(),
  volverUnaPantalla: vi.fn(),
  estadoHook: {
    loading: false,
    rutaOptimizada: null as unknown,
    error: null as string | null,
  },
  propsModal: { actuales: null as null | Record<string, unknown> },
}))

const PREVENTISTAS = [{ id: 'p-1', nombre: 'Pablo Preventista' }]
const CLIENTES = [
  { id: '10', nombre_fantasia: 'Kiosco Norte', activo: true, preventista_ids: ['p-1'] },
  { id: '11', nombre_fantasia: 'Almacén Sur', activo: true, preventista_ids: ['p-1'] },
]

vi.mock('../../../hooks/queries', () => ({
  useClientesQuery: () => ({ data: CLIENTES }),
  usePreventistasQuery: () => ({ data: PREVENTISTAS }),
}))
vi.mock('../../../hooks/useOptimizarRutaPreventista', () => ({
  useOptimizarRutaPreventista: () => ({
    loading: estadoHook.loading,
    rutaOptimizada: estadoHook.rutaOptimizada,
    error: estadoHook.error,
    optimizarRuta,
    limpiarRuta,
  }),
}))
vi.mock('../../../utils/atrasModales', () => ({ volverUnaPantalla }))
vi.mock('../../modals/ModalOptimizarRutaPreventista', () => ({
  default: (props: Record<string, unknown>) => {
    propsModal.actuales = props
    return (
      <div role="dialog" aria-label="Optimizar ruta">
        <button onClick={() => (props.onOptimizar as (p: string, c: unknown[]) => void)('p-1', [CLIENTES[1]])}>stub-optimizar</button>
        <button onClick={props.onClose as () => void}>stub-cerrar</button>
        <p>loading {String(props.loading)}</p>
        <p>error {String(props.error)}</p>
      </div>
    )
  },
}))

import RecorridoPreventistaContainer from '../RecorridoPreventistaContainer'

describe('RecorridoPreventistaContainer', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    estadoHook.loading = false
    estadoHook.rutaOptimizada = null
    estadoHook.error = null
    propsModal.actuales = null
  })

  it('le entrega al modal los preventistas, los clientes y el estado del hook', async () => {
    estadoHook.loading = true
    estadoHook.error = 'No se pudo optimizar'
    estadoHook.rutaOptimizada = { total_clientes: 2 }
    render(<RecorridoPreventistaContainer />)

    await screen.findByRole('dialog', { name: 'Optimizar ruta' })
    expect(propsModal.actuales).toMatchObject({
      preventistas: PREVENTISTAS,
      clientes: CLIENTES,
      loading: true,
      error: 'No se pudo optimizar',
      rutaOptimizada: { total_clientes: 2 },
    })
  })

  it('al pedir optimizar manda al preventista y a los clientes elegidos', async () => {
    render(<RecorridoPreventistaContainer />)

    fireEvent.click(await screen.findByRole('button', { name: 'stub-optimizar' }))

    expect(optimizarRuta).toHaveBeenCalledTimes(1)
    expect(optimizarRuta).toHaveBeenCalledWith('p-1', [CLIENTES[1]])
  })

  it('al cerrar borra la ruta calculada y vuelve una pantalla', async () => {
    render(<RecorridoPreventistaContainer />)

    fireEvent.click(await screen.findByRole('button', { name: 'stub-cerrar' }))

    expect(limpiarRuta).toHaveBeenCalledTimes(1)
    expect(volverUnaPantalla).toHaveBeenCalledTimes(1)
    expect(optimizarRuta).not.toHaveBeenCalled()
  })
})
