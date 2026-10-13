/**
 * SheetParada — buscador de "Todas las paradas".
 *
 * El chofer busca un cliente entre SUS entregas: la búsqueda es en memoria sobre
 * `paradas` (la ruta puede venir del caché del teléfono, sin señal), sin tildes,
 * por nombre, razón social, dirección, aclaración o teléfono. Las filas que
 * quedan conservan su número de orden de ruta real, no el índice filtrado.
 */
import type { ComponentProps } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within, fireEvent } from '@testing-library/react'
import SheetParada from './SheetParada'
import type { PedidoConCliente } from './useEntregaParada'

const parada = (
  id: string,
  orden: number,
  cliente: Record<string, unknown>,
  extra: Record<string, unknown> = {},
): PedidoConCliente => ({
  id, total: 1000, monto_pagado: 0, estado: 'asignado', estado_pago: 'pendiente', orden_entrega: orden,
  items: [], cliente: { id: `c${id}`, ...cliente }, ...extra,
}) as unknown as PedidoConCliente

const PARADAS = [
  parada('1', 1, { nombre_fantasia: 'Kiosco Sur', razon_social: 'Pérez SRL', direccion: 'San Martín 123', telefono: '381 555-1234' }),
  parada('2', 2, { nombre_fantasia: 'Almacén Don Tito', direccion: 'Avenida Belgrano 900', aclaracion_direccion: 'portón verde' }),
  parada('3', 3, { nombre_fantasia: 'Despensa Lucía', direccion: 'Córdoba 45', telefono: '3815559999' },
    { estado: 'entregado', estado_entrega: 'entregado', estado_pago: 'pagado', notas: 'Dejar en mostrador',
      items: [{ id: 'i1', cantidad: 2, precio_unitario: 500, subtotal: 1000, producto: { nombre: 'Yerba 1kg' } }] }),
  parada('4', 4, { nombre_fantasia: 'Maxikiosco Norte', direccion: 'Tucumán 10' }),
]

function montar(over: Partial<ComponentProps<typeof SheetParada>> = {}) {
  const props = {
    paradas: PARADAS,
    paradaActiva: PARADAS[0],
    distanciaMetros: null,
    llegaste: false,
    onSeleccionarParada: vi.fn(),
    onEntregar: vi.fn(),
    onNoEntregar: vi.fn(),
    onSalvedad: vi.fn(),
    linksRutaMaps: [],
    ...over,
  }
  render(<SheetParada {...props} />)
  // El panel nace cerrado (aria-hidden): se abre tocando la barra, como el chofer.
  fireEvent.click(screen.getByRole('button', { name: /abrir el detalle de la parada/i }))
  return props
}

const buscador = () => screen.getByRole('searchbox', { name: /buscar cliente/i })
const buscar = (texto: string) => fireEvent.change(buscador(), { target: { value: texto } })
const lista = () => screen.getByRole('list', { name: /todas las paradas/i })
const filas = () => within(lista()).queryAllByRole('listitem')
const nombresVisibles = () => filas().map(f => f.textContent ?? '')

describe('SheetParada — buscador de paradas', () => {
  it('sin búsqueda muestra todas las paradas en orden de ruta', () => {
    montar()
    expect(filas()).toHaveLength(4)
  })

  it('busca por nombre de fantasía', () => {
    montar()
    buscar('tito')
    expect(nombresVisibles()).toHaveLength(1)
    expect(nombresVisibles()[0]).toContain('Almacén Don Tito')
  })

  it('busca por razón social', () => {
    montar()
    buscar('perez')
    expect(nombresVisibles()).toHaveLength(1)
    expect(nombresVisibles()[0]).toContain('Kiosco Sur')
  })

  it('busca por dirección sin tildes y por aclaración', () => {
    montar()
    buscar('cordoba')
    expect(nombresVisibles()).toHaveLength(1)
    expect(nombresVisibles()[0]).toContain('Despensa Lucía')

    buscar('porton verde')
    expect(nombresVisibles()).toHaveLength(1)
    expect(nombresVisibles()[0]).toContain('Almacén Don Tito')
  })

  it('busca por teléfono, con o sin separadores', () => {
    montar()
    buscar('5551234')
    expect(nombresVisibles()).toHaveLength(1)
    expect(nombresVisibles()[0]).toContain('Kiosco Sur')

    buscar('381-555-9999')
    expect(nombresVisibles()).toHaveLength(1)
    expect(nombresVisibles()[0]).toContain('Despensa Lucía')
  })

  it('las filas filtradas conservan su número de orden de ruta, no el índice', () => {
    montar()
    buscar('kiosco')
    // Kiosco Sur (1) y Maxikiosco Norte (4): orden de ruta, y el 4 sigue siendo 4.
    const f = filas()
    expect(f).toHaveLength(2)
    expect(f[0]).toHaveTextContent('Kiosco Sur')
    expect(within(f[0]).getByTestId('numero-parada')).toHaveTextContent('1')
    expect(f[1]).toHaveTextContent('Maxikiosco Norte')
    expect(within(f[1]).getByTestId('numero-parada')).toHaveTextContent('4')
  })

  it('sin orden_entrega usa la posición en la ruta completa, no en el filtro', () => {
    const sinOrden = PARADAS.map(p => ({ ...p, orden_entrega: null })) as unknown as PedidoConCliente[]
    montar({ paradas: sinOrden, paradaActiva: sinOrden[0] })
    buscar('norte')
    expect(within(filas()[0]).getByTestId('numero-parada')).toHaveTextContent('4')
  })

  it('estado vacío cuando nada coincide', () => {
    montar()
    buscar('zzz inexistente')
    expect(filas()).toHaveLength(0)
    expect(screen.getByText(/Ningún cliente coincide con/)).toHaveTextContent('Ningún cliente coincide con “zzz inexistente”')
  })

  it('la cruz borra la búsqueda y vuelve a mostrar todas', () => {
    montar()
    buscar('tito')
    expect(filas()).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: /borrar búsqueda/i }))
    expect(buscador()).toHaveValue('')
    expect(filas()).toHaveLength(4)
  })

  it('mientras busca, el detalle de la parada activa se esconde y vuelve al borrar', () => {
    montar()
    expect(screen.getByRole('button', { name: /no se pudo entregar/i })).toBeInTheDocument()
    buscar('tito')
    expect(screen.queryByRole('button', { name: /no se pudo entregar/i })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /borrar búsqueda/i }))
    expect(screen.getByRole('button', { name: /no se pudo entregar/i })).toBeInTheDocument()
  })

  it('sin texto no hay cruz', () => {
    montar()
    expect(screen.queryByRole('button', { name: /borrar búsqueda/i })).not.toBeInTheDocument()
  })

  it('tocar un resultado pendiente lo selecciona como parada activa', () => {
    const props = montar()
    buscar('norte')
    fireEvent.click(within(filas()[0]).getByRole('button'))
    expect(props.onSeleccionarParada).toHaveBeenCalledWith('4')
  })

  it('tocar uno ya entregado muestra su detalle en sólo lectura, sin cambiar la parada activa', () => {
    const props = montar()
    buscar('lucia')
    fireEvent.click(within(filas()[0]).getByRole('button'))

    expect(props.onSeleccionarParada).not.toHaveBeenCalled()
    const detalle = screen.getByRole('region', { name: /detalle de despensa lucía/i })
    expect(detalle).toHaveTextContent('Entregada')
    expect(detalle).toHaveTextContent('Córdoba 45')
    expect(detalle).toHaveTextContent('Dejar en mostrador')
    expect(detalle).toHaveTextContent('Yerba 1kg')
    // Sólo lectura: ni entregar, ni no entregar, ni salvedad.
    expect(within(detalle).queryByRole('button', { name: /entregar|completar/i })).not.toBeInTheDocument()
    expect(within(detalle).queryByRole('button', { name: /no se pudo entregar/i })).not.toBeInTheDocument()
    expect(within(detalle).queryByRole('button', { name: /reportar problema/i })).not.toBeInTheDocument()

    // Volver deja la búsqueda como estaba.
    fireEvent.click(within(detalle).getByRole('button', { name: /volver/i }))
    expect(screen.queryByRole('region', { name: /detalle de despensa lucía/i })).not.toBeInTheDocument()
    expect(buscador()).toHaveValue('lucia')
    expect(filas()).toHaveLength(1)
  })

  it('una no entregada también abre en sólo lectura', () => {
    const conNoEntregada = PARADAS.map(p => p.id === '2'
      ? { ...p, estado: 'pendiente', estado_entrega: 'no_entregado' }
      : p) as unknown as PedidoConCliente[]
    const props = montar({ paradas: conNoEntregada })
    buscar('tito')
    fireEvent.click(within(filas()[0]).getByRole('button'))
    expect(props.onSeleccionarParada).not.toHaveBeenCalled()
    expect(screen.getByRole('region', { name: /detalle de almacén don tito/i })).toHaveTextContent('No entregada')
  })
})
