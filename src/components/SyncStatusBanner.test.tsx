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
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { SyncStatusBanner } from './SyncStatusBanner'
import { clearAllData, queueOperation, markAsFailed, db } from '../lib/offlineDb'

// La sesión activa del teléfono. Mutable para los tests de dispositivo
// compartido; `useSucursal` la lee en cada render.
const sesionActiva = vi.hoisted(() => ({ userId: 'user-A' as string | null, sucursalId: 1 as number | null }))

vi.mock('../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    userId: sesionActiva.userId,
    currentSucursalId: sesionActiva.sucursalId,
  }),
}))

async function encolarYFallar(n: number, motivo = 'error de red'): Promise<number> {
  const id = await queueOperation('CREATE_PEDIDO', { n }, undefined, 1)
  await markAsFailed(id, motivo)
  return id
}

async function fallidaDe(userId: string, sucursalId: number, motivo: string, payload: Record<string, unknown> = {}): Promise<number> {
  const id = await queueOperation('CREATE_PEDIDO', payload, userId, 1, sucursalId)
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
    sesionActiva.userId = 'user-A'
    sesionActiva.sucursalId = 1
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

  // PLT-N6 (#1305): el banner listaba las 10 fallidas de id más bajo y sacaba de
  // ahí el id máximo; con más de diez, la fallida nueva no entraba en la muestra
  // y un banner cerrado no reaparecía.
  it('con más de diez fallidas, una nueva reabre el banner cerrado', async () => {
    for (let n = 1; n <= 12; n++) await encolarYFallar(n)
    render(<SyncStatusBanner pollInterval={POLL_QUE_NO_LLEGA} />)
    const poll = pollDelBanner()

    await screen.findByRole('alert')
    await userEvent.click(screen.getByLabelText('Cerrar banner'))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    // Mismas doce, varios polls: sigue cerrado.
    for (let i = 0; i < 2; i++) await correrPoll(poll)
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()

    await encolarYFallar(13)
    await correrPoll(poll)

    expect(screen.getByRole('alert')).toBeInTheDocument()
    expect(screen.getByText(/13 operaciones fallaron/)).toBeInTheDocument()
  })

  it('el botón de eliminar borra las operaciones fallidas de IndexedDB, después de confirmar', async () => {
    const id = await encolarYFallar(1)
    render(<SyncStatusBanner pollInterval={100000} />)

    await screen.findByRole('alert')
    await userEvent.click(screen.getByRole('button', { name: 'Eliminar' }))
    const confirmacion = await screen.findByRole('dialog')
    await userEvent.click(within(confirmacion).getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => {
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    })
    expect(await db.pendingOperations.get(id)).toBeUndefined()
  })

  // #1264: "Eliminar" borraba para siempre, en un toque y sin rastro.
  it('eliminar pide confirmación: cancelar no borra nada', async () => {
    const id = await encolarYFallar(1)
    render(<SyncStatusBanner pollInterval={100000} />)

    await screen.findByRole('alert')
    await userEvent.click(screen.getByRole('button', { name: 'Eliminar' }))
    const confirmacion = await screen.findByRole('dialog')
    expect(within(confirmacion).getByText(/no se van? a sincronizar/i)).toBeInTheDocument()
    await userEvent.click(within(confirmacion).getByRole('button', { name: 'Cancelar' }))

    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(await db.pendingOperations.get(id)).toBeDefined()
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })

  /**
   * #1264 — DISPOSITIVO COMPARTIDO. El banner leía las fallidas de todo el
   * teléfono: el usuario B veía el motivo del rechazo de A (que puede nombrar
   * a un cliente) y "Reintentar" o "Eliminar" actuaban sobre los pedidos de A.
   * Eliminar los borraba para siempre sin que A se enterara.
   */
  describe('dispositivo compartido', () => {
    beforeEach(() => {
      sesionActiva.userId = 'user-B'
      sesionActiva.sucursalId = 1
    })

    it('B no ve las fallidas de A ni su motivo', async () => {
      await fallidaDe('user-A', 1, 'Cliente Almacén Don Pepe asignado a otro preventista')
      await fallidaDe('user-A', 1, 'otro rechazo de A')
      await fallidaDe('user-B', 1, 'rechazo de B')
      await fallidaDe('user-B', 2, 'rechazo de B en otra sucursal')

      render(<SyncStatusBanner pollInterval={100000} />)
      await screen.findByRole('alert')
      await userEvent.click(screen.getByLabelText('Expandir detalles'))

      expect(screen.getByText(/1 operación falló/)).toBeInTheDocument()
      expect(screen.getByText('rechazo de B')).toBeInTheDocument()
      expect(screen.queryByText(/Don Pepe/)).not.toBeInTheDocument()
      expect(screen.queryByText('rechazo de B en otra sucursal')).not.toBeInTheDocument()
    })

    it('sin fallidas propias, a B no le aparece el banner aunque A tenga', async () => {
      await fallidaDe('user-A', 1, 'rechazo de A')

      render(<SyncStatusBanner pollInterval={POLL_QUE_NO_LLEGA} />)
      // Un poll completo: sin esperarlo, la ausencia se cumple antes de leer nada.
      await correrPoll(pollDelBanner())

      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    })

    it('"Eliminar" de B borra sólo lo de B y deja rastro de lo borrado', async () => {
      const deA = await fallidaDe('user-A', 1, 'rechazo de A', { clienteId: '1', total: 500 })
      const deB = await fallidaDe('user-B', 1, 'rechazo de B', { clienteId: '2', total: 700 })

      render(<SyncStatusBanner pollInterval={100000} />)
      await screen.findByRole('alert')
      await userEvent.click(screen.getByRole('button', { name: 'Eliminar' }))
      await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Confirmar' }))

      await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
      expect(await db.pendingOperations.get(deB)).toBeUndefined()
      const opA = await db.pendingOperations.get(deA)
      expect(opA?.status).toBe('failed')

      const rastro = await db.syncEvents.filter(e => e.type === 'operation_discarded').toArray()
      expect(rastro).toHaveLength(1)
      expect(rastro[0].operationId).toBe(deB)
      expect(rastro[0].descartadaPor).toBe('user-B')
      expect(rastro[0].operacion?.payload).toEqual({ clienteId: '2', total: 700 })
    })

    it('"Reintentar" de B reintenta sólo lo de B', async () => {
      const deA = await fallidaDe('user-A', 1, 'rechazo de A')
      const deB = await fallidaDe('user-B', 1, 'rechazo de B')
      const onRetrySync = vi.fn()

      render(<SyncStatusBanner pollInterval={100000} onRetrySync={onRetrySync} />)
      await screen.findByRole('alert')
      await userEvent.click(screen.getByRole('button', { name: 'Reintentar' }))

      await waitFor(() => expect(onRetrySync).toHaveBeenCalledTimes(1))
      expect((await db.pendingOperations.get(deB))!.status).toBe('pending')
      const opA = (await db.pendingOperations.get(deA))!
      expect(opA.status).toBe('failed')
      expect(opA.lastError).toBe('rechazo de A')
    })
  })

  // #1153: el rechazo por un regalo que dejó de ser legal ofrece, por
  // operación, mandarlo sin el regalo.
  describe('Sincronizar sin el regalo', () => {
    const payloadConRegalo = {
      offlineUuid: 'uuid-1153',
      items: [
        { productoId: '1', cantidad: 10, precioUnitario: 100 },
        { productoId: '2', cantidad: 4, precioUnitario: 0, esBonificacion: true, promocionId: '15' },
      ],
    }

    async function fallar(rechazoRegalo: boolean): Promise<number> {
      const id = await queueOperation('CREATE_PEDIDO', payloadConRegalo, undefined, 5)
      await markAsFailed(id, 'La promo "X" está desactivada', { terminal: true, rechazoRegalo })
      return id
    }

    it('el botón aparece sólo en la operación con la marca', async () => {
      await fallar(false)
      await fallar(true)
      render(<SyncStatusBanner pollInterval={100000} />)
      await screen.findByRole('alert')
      await userEvent.click(screen.getByLabelText('Expandir detalles'))
      expect(screen.getAllByRole('button', { name: 'Sincronizar sin el regalo' })).toHaveLength(1)
    })

    it('sin la marca no hay botón', async () => {
      await fallar(false)
      render(<SyncStatusBanner pollInterval={100000} />)
      await screen.findByRole('alert')
      await userEvent.click(screen.getByLabelText('Expandir detalles'))
      expect(screen.queryByRole('button', { name: 'Sincronizar sin el regalo' })).not.toBeInTheDocument()
    })

    it('el click quita el regalo, vuelve la operación a la cola y pide sincronizar', async () => {
      const id = await fallar(true)
      const onRetrySync = vi.fn()
      render(<SyncStatusBanner pollInterval={100000} onRetrySync={onRetrySync} />)
      await screen.findByRole('alert')
      await userEvent.click(screen.getByLabelText('Expandir detalles'))
      await userEvent.click(screen.getByRole('button', { name: 'Sincronizar sin el regalo' }))

      await waitFor(() => expect(onRetrySync).toHaveBeenCalledTimes(1))
      const op = (await db.pendingOperations.get(id))!
      expect(op.status).toBe('pending')
      expect(op.payload.offlineUuid).toBe('uuid-1153')
      expect(op.payload.items).toEqual([{ productoId: '1', cantidad: 10, precioUnitario: 100 }])
      await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
    })
  })
})
