/**
 * El banner de fallidas quedaba pegado: `isDismissed` se reseteaba a `false`
 * en cada poll (cada 10s) apenas `counts.failed > 0`, condición que seguía
 * siendo cierta para las MISMAS operaciones que la usuaria acababa de cerrar.
 * Sin forma de cerrarlo de verdad, la única salida visible era "Descartar",
 * que borra los pedidos fallidos.
 *
 * Estos tests fijan que cerrar el banner lo deja cerrado mientras no aparezca
 * una fallida nueva, y que reaparece cuando sí aparece una.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { SyncStatusBanner } from './SyncStatusBanner'
import { clearAllData, queueOperation, markAsFailed } from '../lib/offlineDb'

async function encolarYFallar(n: number, motivo = 'error de red'): Promise<number> {
  const id = await queueOperation('CREATE_PEDIDO', { n }, undefined, 1)
  await markAsFailed(id, motivo)
  return id
}

// Los polls los dispara el test, uno por uno, en vez de esperar el intervalo
// real (#987): con pollInterval={50} y la máquina cargada, cada poll (varias
// transacciones de IndexedDB) tardaba más que el intervalo, se apilaban y la
// fallida nueva podía no verse dentro del timeout. Con un intervalo que no
// llega a vencer durante el test, el único poll que corre es el que se pide.
const POLL_QUE_NO_LLEGA = 10 * 60 * 1000

/** El callback que el banner registró con setInterval: su `fetchStatus`. */
function pollDelBanner(): () => unknown {
  const llamada = vi.mocked(setInterval).mock.calls.find(([, ms]) => ms === POLL_QUE_NO_LLEGA)
  if (!llamada) throw new Error('El banner no registró su poll')
  return llamada[0] as () => unknown
}

/** Corre un poll completo y deja pintado lo que haya cambiado. */
async function correrPoll(poll: () => unknown): Promise<void> {
  await act(async () => {
    const fin = poll()
    // Si el poll dejara de devolver su promesa, "esperarlo" no esperaría nada
    // y las aserciones de ausencia pasarían solas.
    expect(fin).toBeInstanceOf(Promise)
    await fin
  })
}

describe('SyncStatusBanner', () => {
  beforeEach(async () => {
    vi.spyOn(globalThis, 'setInterval')
    await clearAllData()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('no se muestra sin operaciones fallidas', async () => {
    render(<SyncStatusBanner pollInterval={100000} />)
    await waitFor(() => {
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    })
  })

  it('se muestra cuando hay una operación fallida', async () => {
    await encolarYFallar(1)
    render(<SyncStatusBanner pollInterval={100000} />)

    expect(await screen.findByRole('alert')).toBeInTheDocument()
    expect(screen.getByText(/1 operación falló/)).toBeInTheDocument()
  })

  it('cerrar el banner lo deja cerrado aunque el poll siga viendo la misma fallida', async () => {
    await encolarYFallar(1)
    render(<SyncStatusBanner pollInterval={POLL_QUE_NO_LLEGA} />)
    const poll = pollDelBanner()

    await screen.findByRole('alert')
    await userEvent.click(screen.getByLabelText('Cerrar banner'))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    // Varios polls completos (misma fallida, sin cambios) sin que reaparezca.
    for (let i = 0; i < 3; i++) await correrPoll(poll)
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('reaparece cuando aparece una fallida nueva después de cerrarlo', async () => {
    await encolarYFallar(1)
    render(<SyncStatusBanner pollInterval={POLL_QUE_NO_LLEGA} />)
    const poll = pollDelBanner()

    await screen.findByRole('alert')
    await userEvent.click(screen.getByLabelText('Cerrar banner'))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    await encolarYFallar(2)
    await correrPoll(poll)

    expect(screen.getByRole('alert')).toBeInTheDocument()
    expect(screen.getByText(/2 operaciones fallaron/)).toBeInTheDocument()
  })

  it('el botón de eliminar borra las operaciones fallidas de IndexedDB', async () => {
    await encolarYFallar(1)
    render(<SyncStatusBanner pollInterval={100000} />)

    await screen.findByRole('alert')
    await userEvent.click(screen.getByRole('button', { name: 'Eliminar' }))

    await waitFor(() => {
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    })
  })
})
