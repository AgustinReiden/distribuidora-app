/**
 * ModalResolverSalvedad — «A cargo de empleados» (gastos 7). Sólo el admin ve la opción, y sólo
 * con un motivo que deja mercadería perdida; elegirla exige al menos una línea completa y el
 * cargo viaja en el mismo `onResolver`.
 */
import { describe, it, expect, vi, type Mock } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/usePersonalQuery', () => ({
  useEmpleadosParaElegirQuery: () => ({
    data: [
      { id: 1, nombre: 'Ana Gómez', usuario_id: null, vehiculo_id: null, activo: true },
      { id: 2, nombre: 'Beto Ríos', usuario_id: 'u-admin', vehiculo_id: null, activo: true },
    ],
  }),
}))

import ModalResolverSalvedad, { type ModalResolverSalvedadProps } from './ModalResolverSalvedad'
import type { SalvedadItemDBExtended } from '../../types'

type OnResolver = ModalResolverSalvedadProps['onResolver']

const salvedad = (motivo: string): SalvedadItemDBExtended => ({
  id: '55',
  pedido_id: '9',
  pedido_item_id: '90',
  producto_id: '3',
  cantidad_original: 10,
  cantidad_afectada: 4,
  cantidad_entregada: 6,
  motivo,
  monto_afectado: 4000,
  precio_unitario: 1000,
  estado_resolucion: 'pendiente',
  stock_devuelto: false,
  producto_nombre: 'Aceite Girasol 900ml',
}) as unknown as SalvedadItemDBExtended

function renderModal(motivo: string, props: Partial<ModalResolverSalvedadProps> = {}) {
  const onResolver: Mock<OnResolver> = vi.fn<OnResolver>(() => Promise.resolve({ success: true }))
  render(
    <ModalResolverSalvedad
      salvedad={salvedad(motivo)}
      onResolver={onResolver}
      onClose={vi.fn()}
      puedeCargarAEmpleados
      usuarioId="u-admin"
      {...props}
    />,
  )
  return { onResolver, user: userEvent.setup() }
}

const opcionACargo = () => screen.queryByRole('button', { name: /a cargo de empleados/i })
const campoNotas = () => screen.getByPlaceholderText(/describa como se resuelve/i)
const botonResolver = () => screen.getByRole('button', { name: /^resolver salvedad$/i })

describe('ModalResolverSalvedad — qué se ofrece', () => {
  it.each(['producto_danado', 'producto_vencido', 'faltante_stock'])(
    'el admin ve «A cargo de empleados» con el motivo %s',
    motivo => {
      renderModal(motivo)
      expect(opcionACargo()).toBeInTheDocument()
    },
  )

  it.each(['cliente_rechaza', 'error_pedido', 'diferencia_precio', 'entregado_otro_cliente', 'otro'])(
    'con el motivo %s no se ofrece',
    motivo => {
      renderModal(motivo)
      expect(opcionACargo()).toBeNull()
    },
  )

  it('el encargado no la ve, ni siquiera con un motivo de mercadería perdida', () => {
    renderModal('producto_danado', { puedeCargarAEmpleados: false })

    expect(opcionACargo()).toBeNull()
    // Lo demás sigue ahí.
    expect(screen.getByRole('button', { name: /nota de crédito/i })).toBeInTheDocument()
  })

  it('el texto viejo «Descuento a Transportista» ya no aparece', () => {
    renderModal('producto_danado')

    expect(screen.queryByText(/descuento a transportista/i)).toBeNull()
  })
})

describe('ModalResolverSalvedad — A cargo de empleados', () => {
  it('elegirla muestra la sección de reparto; otra resolución la esconde', async () => {
    const { user } = renderModal('producto_danado')
    expect(screen.queryByRole('heading', { name: 'A cargo de empleados' })).toBeNull()

    await user.click(opcionACargo()!)
    expect(screen.getByRole('heading', { name: 'A cargo de empleados' })).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /absorción empresa/i }))
    expect(screen.queryByRole('heading', { name: 'A cargo de empleados' })).toBeNull()
  })

  it('exige al menos una línea', async () => {
    const { user, onResolver } = renderModal('producto_danado')
    await user.click(opcionACargo()!)
    await user.type(campoNotas(), 'Se cayó del camión')

    await user.click(botonResolver())

    expect(onResolver).not.toHaveBeenCalled()
    expect(screen.getByText(/elegí a quién se le carga/i)).toBeVisible()
  })

  it('una línea a medias bloquea', async () => {
    const { user, onResolver } = renderModal('producto_vencido')
    await user.click(opcionACargo()!)
    await user.type(campoNotas(), 'Se venció en el depósito')
    await user.click(screen.getByRole('button', { name: /\+ empleado/i }))

    await user.click(botonResolver())

    expect(onResolver).not.toHaveBeenCalled()
    expect(screen.getByText(/completá el empleado y el monto/i)).toBeVisible()
  })

  it('manda los cargos junto con la resolución', async () => {
    const { user, onResolver } = renderModal('producto_danado')
    await user.click(opcionACargo()!)
    await user.type(campoNotas(), 'Se cayó del camión')
    await user.click(screen.getByRole('button', { name: /\+ empleado/i }))
    await user.selectOptions(screen.getByLabelText(/^empleado 1$/i), 'Ana Gómez')
    await user.type(screen.getByLabelText(/^monto a cargo 1$/i), '1500,50')

    await user.click(botonResolver())

    expect(onResolver).toHaveBeenCalledTimes(1)
    expect(onResolver.mock.calls[0][0]).toEqual({
      salvedadId: '55',
      estadoResolucion: 'descuento_transportista',
      notas: 'Se cayó del camión',
      cargos: [{ empleado_id: 1, monto: 1500.5 }],
    })
  })

  it('no ofrece al propio usuario', async () => {
    const { user } = renderModal('producto_danado')
    await user.click(opcionACargo()!)
    await user.click(screen.getByRole('button', { name: /\+ empleado/i }))

    expect(screen.getByRole('option', { name: 'Ana Gómez' })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: 'Beto Ríos' })).toBeNull()
  })

  it('con otra resolución no viaja ningún cargo, aunque haya quedado una línea cargada', async () => {
    const { user, onResolver } = renderModal('producto_danado')
    await user.click(opcionACargo()!)
    await user.click(screen.getByRole('button', { name: /\+ empleado/i }))
    await user.click(screen.getByRole('button', { name: /absorción empresa/i }))
    await user.type(campoNotas(), 'La empresa asume la pérdida')

    await user.click(botonResolver())

    expect(onResolver).toHaveBeenCalledTimes(1)
    expect(onResolver.mock.calls[0][0]).toEqual({
      salvedadId: '55',
      estadoResolucion: 'absorcion_empresa',
      notas: 'La empresa asume la pérdida',
    })
  })
})
