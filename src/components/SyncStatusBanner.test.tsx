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
import { describe, it, expect, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { SyncStatusBanner } from './SyncStatusBanner'
import { clearAllData, queueOperation, markAsFailed } from '../lib/offlineDb'

async function encolarYFallar(n: number, motivo = 'error de red'): Promise<number> {
  const id = await queueOperation('CREATE_PEDIDO', { n }, undefined, 1)
  await markAsFailed(id, motivo)
  return id
}

describe('SyncStatusBanner', () => {
  beforeEach(async () => {
    await clearAllData()
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
    render(<SyncStatusBanner pollInterval={50} />)

    await screen.findByRole('alert')
    await userEvent.click(screen.getByLabelText('Cerrar banner'))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    // Deja pasar varios polls (misma fallida, sin cambios) sin que reaparezca.
    await new Promise(resolve => setTimeout(resolve, 300))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('reaparece cuando aparece una fallida nueva después de cerrarlo', async () => {
    await encolarYFallar(1)
    render(<SyncStatusBanner pollInterval={50} />)

    await screen.findByRole('alert')
    await userEvent.click(screen.getByLabelText('Cerrar banner'))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    await encolarYFallar(2)

    await waitFor(() => {
      expect(screen.getByRole('alert')).toBeInTheDocument()
    }, { timeout: 2000 })
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
