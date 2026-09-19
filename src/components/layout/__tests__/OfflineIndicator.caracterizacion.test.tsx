/**
 * Caracterización de OfflineIndicator: complementa a OfflineIndicator.test.tsx
 * (que cubre el nombre de cliente en los pedidos pendientes) con el resto del
 * comportamiento actual, antes de reemplazarlo por una pila común de avisos.
 *
 * No toca OfflineIndicator.test.tsx.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import OfflineIndicator from '../OfflineIndicator'
import { formatPrecio } from '../../../utils/formatters'

const pedido1 = {
  offlineId: 'op_1',
  clienteId: '5',
  clienteNombre: 'Almacén Don José',
  items: [{ producto_id: '1', cantidad: 2 }],
  total: 15000,
  creadoOffline: '2026-04-21T10:00:00.000Z',
}

const pedido2 = {
  offlineId: 'op_2',
  clienteId: '9',
  clienteNombre: 'Kiosco La Esquina',
  items: [],
  total: 3200,
  creadoOffline: '2026-04-21T11:00:00.000Z',
}

/**
 * formatPrecio usa Intl.NumberFormat('es-AR', ...), que separa el símbolo
 * del monto con un espacio NO separable (código 160, NBSP). getByText
 * normaliza el texto del DOM (colapsa cualquier whitespace, incluido el
 * NBSP, a un espacio común) pero NO normaliza el string que se le pasa como
 * matcher — así que hay que normalizarlo a mano para que la comparación
 * coincida.
 */
const NBSP_RE = new RegExp(String.fromCharCode(160), 'g')

function textoMonto(monto: number): string {
  return formatPrecio(monto).replace(NBSP_RE, ' ')
}

describe('OfflineIndicator — caracterización', () => {
  it('no renderiza nada online y sin pendientes', () => {
    const { container } = render(<OfflineIndicator isOnline pedidosPendientes={[]} mermasPendientes={[]} />)
    expect(container.firstChild).toBeNull()
  })

  it('offline sin pendientes muestra el aviso de sin conexion', () => {
    render(<OfflineIndicator isOnline={false} />)
    expect(screen.getByRole('button', { name: /sin conexion/i })).toBeInTheDocument()
  })

  it('offline con un pendiente muestra la cantidad', () => {
    render(<OfflineIndicator isOnline={false} pedidosPendientes={[pedido1]} />)
    const boton = screen.getByRole('button', { name: /sin conexion/i })
    expect(boton).toHaveTextContent('1')
  })

  it('online con pendientes muestra la cantidad en singular', () => {
    render(<OfflineIndicator isOnline pedidosPendientes={[pedido1]} />)
    expect(screen.getByRole('button', { name: /1 pendiente/i })).toBeInTheDocument()
  })

  it('online con varios pendientes muestra la cantidad en plural', () => {
    render(<OfflineIndicator isOnline pedidosPendientes={[pedido1, pedido2]} />)
    expect(screen.getByRole('button', { name: /2 pendientes/i })).toBeInTheDocument()
  })

  it('se puede expandir y lista cada pedido pendiente con su cliente y su total', async () => {
    render(<OfflineIndicator isOnline pedidosPendientes={[pedido1, pedido2]} />)

    await userEvent.click(screen.getByRole('button', { name: /2 pendientes/i }))

    expect(screen.getByText('Pendientes de sincronizar')).toBeInTheDocument()
    expect(screen.getByText('Almacén Don José')).toBeInTheDocument()
    expect(screen.getByText(textoMonto(pedido1.total))).toBeInTheDocument()
    expect(screen.getByText('Kiosco La Esquina')).toBeInTheDocument()
    expect(screen.getByText(textoMonto(pedido2.total))).toBeInTheDocument()
  })

  it('se puede volver a colapsar clickeando el boton principal', async () => {
    render(<OfflineIndicator isOnline pedidosPendientes={[pedido1]} />)

    const boton = screen.getByRole('button', { name: /1 pendiente/i })
    await userEvent.click(boton)
    expect(screen.getByText('Pendientes de sincronizar')).toBeInTheDocument()

    await userEvent.click(boton)
    expect(screen.queryByText('Pendientes de sincronizar')).not.toBeInTheDocument()
  })

  it('el boton de sincronizar llama a onSincronizar', async () => {
    const onSincronizar = vi.fn()
    render(<OfflineIndicator isOnline pedidosPendientes={[pedido1]} onSincronizar={onSincronizar} />)

    await userEvent.click(screen.getByRole('button', { name: /1 pendiente/i }))
    await userEvent.click(screen.getByRole('button', { name: 'Sincronizar ahora' }))

    expect(onSincronizar).toHaveBeenCalledTimes(1)
  })

  it('con sincronizando=true el boton de sincronizar se deshabilita y cambia de texto', async () => {
    const onSincronizar = vi.fn()
    render(
      <OfflineIndicator
        isOnline
        pedidosPendientes={[pedido1]}
        sincronizando
        onSincronizar={onSincronizar}
      />
    )

    await userEvent.click(screen.getByRole('button', { name: /1 pendiente/i }))

    const botonSincronizar = screen.getByRole('button', { name: /sincronizando/i })
    expect(botonSincronizar).toBeDisabled()
    // BUG: al estar disabled, userEvent no lo puede clickear (el atributo
    // `disabled` bloquea el evento de click nativo), así que un click sobre
    // el botón mientras sincronizando=true NO dispara onSincronizar. Es el
    // comportamiento actual, no un fix.
    await userEvent.click(botonSincronizar)
    expect(onSincronizar).not.toHaveBeenCalled()
  })

  it('offline con pendientes muestra el aviso de "se sincronizará" en vez del boton', async () => {
    render(<OfflineIndicator isOnline={false} pedidosPendientes={[pedido1]} />)

    await userEvent.click(screen.getByRole('button', { name: /sin conexion/i }))

    expect(screen.getByText('Se sincronizara cuando vuelva la conexion')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Sincronizar ahora' })).not.toBeInTheDocument()
  })
})
