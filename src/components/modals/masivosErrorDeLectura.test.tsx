/**
 * H2 de la revisión de C7 (#1598, 1598-b7): los tres modales masivos leían la lista con
 * `{ data = [], isLoading }` e ignoraban el error. Con la lectura fallada mostraban «No hay pedidos
 * pendientes…» (falso: la sucursal no está vacía, no se pudo leer) y sin «Reintentar». Regla del
 * proyecto: un error no se muestra como «sin datos». Ahora cada pantalla muestra `QueryErrorState`
 * con el «Reintentar» del `refetch` de su lectura.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import type { PerfilDB } from '../../types'

const refetch = vi.fn()
const lectura = {
  valor: { data: [] as unknown[], isLoading: false, isError: true, refetch },
}

vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { diasAtrasFechaPedido: 5 } }),
}))
vi.mock('../../hooks/queries', () => ({
  usePedidosNoEntregadosQuery: () => lectura.valor,
  usePedidosParaEntregaYPagoQuery: () => lectura.valor,
  usePedidosNoPagadosQuery: () => lectura.valor,
  useRendicionCerradaQuery: () => ({ data: false }),
}))

import ModalEntregasMasivas from './ModalEntregasMasivas'
import ModalEntregaYPagoMasivos from './ModalEntregaYPagoMasivos'
import ModalPagosMasivos from './ModalPagosMasivos'

const choferes = [{ id: 'c-1', nombre: 'Chofer Uno' }] as unknown as PerfilDB[]
const props = { onConfirm: vi.fn().mockResolvedValue(undefined), onClose: vi.fn(), guardando: false, isAdmin: true }

const pantallas: Array<[string, () => React.ReactElement, RegExp]> = [
  ['Entregas masivas', () => <ModalEntregasMasivas transportistas={choferes} {...props} />, /No hay pedidos disponibles para entregar/],
  ['Entrega y pago masivos', () => <ModalEntregaYPagoMasivos transportistas={choferes} {...props} />, /No hay pedidos disponibles para entregar o cobrar/],
  ['Pagos masivos', () => <ModalPagosMasivos {...props} />, /No hay pedidos pendientes de pago/],
]

describe.each(pantallas)('%s · si la lectura falla', (_nombre, modal, vacio) => {
  beforeEach(() => {
    refetch.mockClear()
    lectura.valor = { data: [], isLoading: false, isError: true, refetch }
  })

  it('muestra el error con su «Reintentar» y no dice que no hay pedidos', () => {
    render(modal())
    expect(screen.getByText('No se pudo cargar.')).toBeInTheDocument()
    expect(screen.queryByText(vacio)).not.toBeInTheDocument()
  })

  it('«Reintentar» vuelve a pedir la lectura', () => {
    render(modal())
    fireEvent.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('sin error y sin pedidos, el vacío de siempre', () => {
    lectura.valor = { data: [], isLoading: false, isError: false, refetch }
    render(modal())
    expect(screen.getByText(vacio)).toBeInTheDocument()
    expect(screen.queryByText('No se pudo cargar.')).not.toBeInTheDocument()
  })
})
