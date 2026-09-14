/**
 * El panel de pendientes mostraba "Cliente desconocido" para TODOS los
 * pedidos offline: App.tsx nunca le pasaba la prop `clientes`, y aunque se la
 * hubiera pasado, comparaba `c.id` (que en runtime llega `number`, ver
 * CLAUDE.md "Los ids son bigint") contra `clienteId` (`string`) con `===`
 * estricto, que nunca matchea.
 *
 * El arreglo saca esa comparación: el nombre se acuña al encolar el pedido
 * (ver `PedidoOffline.clienteNombre` en useOfflineSync) y el panel sólo lo
 * muestra, sin depender de una lista de clientes cargada aparte.
 */
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import OfflineIndicator from './OfflineIndicator'

describe('OfflineIndicator', () => {
  it('muestra el nombre del cliente acuñado al encolar, sin lista de clientes', async () => {
    render(
      <OfflineIndicator
        isOnline={false}
        pedidosPendientes={[{
          offlineId: 'op_1',
          clienteId: '5',
          clienteNombre: 'Almacén Don José',
          items: [],
          total: 100,
          creadoOffline: new Date().toISOString(),
        }]}
      />
    )

    await userEvent.click(screen.getByRole('button', { name: /sin conexion/i }))
    expect(await screen.findByText('Almacén Don José')).toBeInTheDocument()
  })

  it('muestra "Cliente desconocido" cuando el pedido no trae clienteNombre', async () => {
    render(
      <OfflineIndicator
        isOnline={false}
        pedidosPendientes={[{
          offlineId: 'op_2',
          clienteId: '7',
          items: [],
          total: 50,
          creadoOffline: new Date().toISOString(),
        }]}
      />
    )

    await userEvent.click(screen.getByRole('button', { name: /sin conexion/i }))
    expect(await screen.findByText('Cliente desconocido')).toBeInTheDocument()
  })
})
