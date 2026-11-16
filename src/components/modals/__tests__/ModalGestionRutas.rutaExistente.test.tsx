/**
 * «Armar ruta» no se puede confirmar sin saber si el chofer ya tiene una ruta (#1549, FRT-04).
 *
 * EL HUECO
 * --------
 * El modal tomaba sólo `data` de `useRecorridoExistenteQuery`. Si la consulta fallaba,
 * `rutaExistente` quedaba `undefined`, igual que mientras cargaba: no se precargaban las
 * paradas, `editando` quedaba en false y el botón se podía apretar. `aplicar_orden_ruta`
 * deja como ruta la lista que recibe, así que armar «una ruta nueva» con un solo pedido
 * sacaba de la ruta del chofer a todas las demás paradas, que ya estaban en la calle.
 *
 * En «Dividir entre varios» pasa lo mismo con `useRutasEnCursoMultiQuery`: sin esa consulta
 * desaparece el aviso «ya tiene ruta armada».
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PedidoDB, PerfilDB } from '../../../types'

type EstadoQuery = {
  data: unknown
  isError: boolean
  refetch: ReturnType<typeof vi.fn>
}

const { existente, multi, otrasFechas } = vi.hoisted(() => ({
  existente: { data: undefined, isError: false, refetch: vi.fn() } as EstadoQuery,
  multi: { data: undefined, isError: false, refetch: vi.fn() } as EstadoQuery,
  otrasFechas: { data: [] as unknown[], isError: false, refetch: vi.fn() },
}))

vi.mock('../../../hooks/queries', () => ({
  useDepositoCoords: () => ({ lat: -26.8, lng: -65.2 }),
  useDestinoCoords: () => null,
  useSetDepositoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useSetDestinoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCambiarTransportistaRutaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useRecorridoExistenteQuery: () => existente,
  useRutasEnCursoQuery: () => otrasFechas,
  useRutasEnCursoMultiQuery: () => multi,
}))

vi.mock('../../../hooks/useOptimizarRuta', () => ({
  horarioParaRutear: () => null,
}))

import ModalGestionRutas from '../ModalGestionRutas'

const TRANSPORTISTA = { id: 't1', nombre: 'Tomás Chofer' } as PerfilDB

const pedido = (id: string): PedidoDB =>
  ({
    id, estado: 'en_preparacion', total: 100, items: [], fecha: '2026-11-12',
    cliente: { id: `c${id}`, nombre_fantasia: `Cliente ${id}`, latitud: -26.8, longitud: -65.2 },
  }) as unknown as PedidoDB

const parada = (id: string): PedidoDB => ({ ...pedido(id), estado: 'asignado' }) as PedidoDB

function montar() {
  const onArmarRuta = vi.fn()
  const onArmarRutaMulti = vi.fn()
  const elemento = () => (
    <ModalGestionRutas
      transportistas={[TRANSPORTISTA]}
      pedidos={[pedido('76')]}
      onArmarRuta={onArmarRuta}
      onArmarRutaMulti={onArmarRutaMulti}
      onExportarPDF={vi.fn()}
      onClose={vi.fn()}
      loading={false}
      guardando={false}
      rutaOptimizada={null}
      error={null}
    />
  )
  const { rerender } = render(elemento())
  // Las consultas están mockeadas con objetos mutables: re-renderizar lee el estado nuevo.
  return { onArmarRuta, onArmarRutaMulti, volverARenderizar: () => rerender(elemento()) }
}

async function elegirChoferYTildarElPedido() {
  const user = userEvent.setup()
  await user.selectOptions(screen.getByRole('combobox'), 't1')
  return user
}

const botonArmar = () => screen.getByRole('button', { name: /Armar ruta del día/ })

beforeEach(() => {
  existente.data = undefined
  existente.isError = false
  existente.refetch = vi.fn()
  multi.data = undefined
  multi.isError = false
  multi.refetch = vi.fn()
})

describe('ModalGestionRutas — un solo chofer (#1549)', () => {
  it('si la consulta de la ruta existente falla, avisa y no deja armar', async () => {
    existente.isError = true
    const { onArmarRuta } = montar()
    const user = await elegirChoferYTildarElPedido()

    expect(screen.getByRole('alert')).toHaveTextContent(/No se pudo cargar la ruta que Tomás Chofer ya tiene/)
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()

    // Aun con el pedido tildado a mano, no se confirma.
    await user.click(screen.getByRole('checkbox', { name: /#76 - Cliente 76/ }))
    expect(botonArmar()).toBeDisabled()
    await user.click(botonArmar())
    expect(onArmarRuta).not.toHaveBeenCalled()
  })

  it('el botón Reintentar vuelve a pedir la ruta existente', async () => {
    existente.isError = true
    montar()
    const user = await elegirChoferYTildarElPedido()

    await user.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(existente.refetch).toHaveBeenCalledTimes(1)
  })

  it('mientras la ruta existente carga, tampoco deja armar', async () => {
    const { onArmarRuta } = montar()
    const user = await elegirChoferYTildarElPedido()

    expect(screen.getByRole('status')).toHaveTextContent(/Verificando si Tomás Chofer ya tiene una ruta armada/)
    await user.click(screen.getByRole('checkbox', { name: /#76 - Cliente 76/ }))
    expect(botonArmar()).toBeDisabled()
    expect(onArmarRuta).not.toHaveBeenCalled()
  })

  it('al reintentar con éxito se precargan las paradas de la ruta y se puede armar', async () => {
    existente.isError = true
    const { onArmarRuta, volverARenderizar } = montar()
    const user = await elegirChoferYTildarElPedido()
    expect(botonArmar()).toBeDisabled()

    // Llega la ruta que el chofer ya tenía: 3 paradas.
    existente.isError = false
    existente.data = { recorridoId: '9', paradas: [parada('73'), parada('74'), parada('75')] }
    volverARenderizar()

    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(await screen.findByText(/Ya hay una ruta armada para/)).toBeInTheDocument()
    // Las 3 paradas vienen tildadas: el botón arma con 3 (no con 0 ni con sólo la nueva).
    expect(botonArmar()).toBeEnabled()
    expect(botonArmar()).toHaveTextContent('(3)')
    await user.click(botonArmar())
    expect(onArmarRuta).toHaveBeenCalledTimes(1)
    expect((onArmarRuta as unknown as { mock: { calls: unknown[][] } }).mock.calls[0][1]).toHaveLength(3)
  })

  it('si el chofer no tiene ruta (la consulta devolvió null), arma como siempre', async () => {
    existente.data = null
    const { onArmarRuta } = montar()
    const user = await elegirChoferYTildarElPedido()

    await user.click(screen.getByRole('checkbox', { name: /#76 - Cliente 76/ }))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(botonArmar()).toBeEnabled()
    await user.click(botonArmar())
    expect(onArmarRuta).toHaveBeenCalledTimes(1)
  })

  it('si ya la había cargado y un refetch falla, no se queda sin poder armar', async () => {
    // react-query conserva `data` ante un error de refetch: la ruta que se ve es la última buena.
    existente.data = { recorridoId: '9', paradas: [parada('73')] }
    existente.isError = true
    montar()
    await elegirChoferYTildarElPedido()

    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(botonArmar()).toBeEnabled()
  })
})

describe('ModalGestionRutas — dividir entre varios (#1549)', () => {
  async function irADividirConUnChofer() {
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Dividir entre varios' }))
    await user.click(screen.getByRole('checkbox', { name: 'Tomás Chofer' }))
    return user
  }
  const botonDividir = () => screen.getByRole('button', { name: /Dividir y armar/ })

  it('si no se pudo ver qué rutas tienen los choferes, avisa y no deja dividir', async () => {
    multi.isError = true
    const { onArmarRutaMulti } = montar()
    const user = await irADividirConUnChofer()

    expect(screen.getByRole('alert')).toHaveTextContent(/No se pudo comprobar si los choferes elegidos ya tienen ruta/)
    expect(botonDividir()).toBeDisabled()
    await user.click(botonDividir())
    expect(onArmarRutaMulti).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(multi.refetch).toHaveBeenCalledTimes(1)
  })

  it('con las rutas leídas (aunque sea ninguna), divide', async () => {
    multi.data = []
    const { onArmarRutaMulti } = montar()
    const user = await irADividirConUnChofer()

    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(botonDividir()).toBeEnabled()
    await user.click(botonDividir())
    expect(onArmarRutaMulti).toHaveBeenCalledTimes(1)
  })
})
