/**
 * `ModalSalvedadItem` — la salvedad sobre la línea de un combo (#1192).
 *
 * Si el cliente rechaza parte de un combo, el combo se rompe y lo que se queda
 * vuelve a su precio sin combo: el total puede SUBIR. El chofer lo tiene que
 * ver antes de confirmar ("si rechaza la Coca, el total sube $200"), y antes de
 * elegir el motivo, para que el cliente pueda quedarse el producto. Con un
 * motivo nuestro lo que se queda mantiene el precio de combo.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import type { ComboImpactoSalvedad } from '../../utils/comboSalvedad'
import type { SalvedadComboSimulada } from '../../hooks/queries/useSimularSalvedadComboQuery'

// Lo que contesta el dry-run según el motivo simulado.
let impactoPorMotivo: Record<string, ComboImpactoSalvedad[]> = {}
let errorSimulacion = false
const llamadas: Array<{ salvedades: SalvedadComboSimulada[]; enabled: boolean | undefined }> = []

vi.mock('../../hooks/queries', () => ({
  useSimularSalvedadPromoImpactoQuery: () => ({ data: [] }),
  useSimularSalvedadesComboImpactoQuery: (
    _pedidoId: unknown,
    salvedades: SalvedadComboSimulada[],
    opciones?: { enabled?: boolean },
  ) => {
    llamadas.push({ salvedades, enabled: opciones?.enabled })
    if (!opciones?.enabled || salvedades.length === 0) return { data: [], isError: false }
    return { data: impactoPorMotivo[salvedades[0].motivo] ?? [], isError: errorSimulacion }
  },
}))

import ModalSalvedadItem from './ModalSalvedadItem'
import type { PedidoItemDB } from '../../types'

// El ejemplo del issue: Fernet 10.000 + Coca 2.500, combo a 9.800.
const COCA_EN_COMBO = {
  id: 'item-coca',
  pedido_id: 'pedido-1',
  producto_id: 'coca',
  cantidad: 1,
  precio_unitario: 1960,
  combo_id: '7',
  precio_sin_combo_unitario: 2500,
  producto: { id: 'coca', nombre: 'Coca 2,25', codigo: 'C1' },
} as unknown as PedidoItemDB

const YERBA = {
  id: 'item-yerba',
  pedido_id: 'pedido-1',
  producto_id: 'yerba',
  cantidad: 1,
  precio_unitario: 1000,
  producto: { id: 'yerba', nombre: 'Yerba', codigo: 'Y1' },
} as unknown as PedidoItemDB

const ROTO: ComboImpactoSalvedad = {
  combo_id: 7,
  nombre: 'Fernet + Coca',
  combos_antes: 1,
  combos_despues: 0,
  recargo: 2160,
  productos: [
    { producto_id: 1, nombre: 'Fernet', fuera_antes: 0, fuera_despues: 1, precio_combo: 7840, precio_sin_combo: 10000 },
    { producto_id: 2, nombre: 'Coca 2,25', fuera_antes: 0, fuera_despues: 0, precio_combo: 1960, precio_sin_combo: 2500 },
  ],
}

const SE_MANTIENE: ComboImpactoSalvedad = { ...ROTO, combos_despues: 1, recargo: 0,
  productos: ROTO.productos.map(p => ({ ...p, fuera_despues: 0 })) }

beforeEach(() => {
  impactoPorMotivo = { cliente_rechaza: [ROTO], faltante_stock: [SE_MANTIENE], producto_danado: [SE_MANTIENE] }
  errorSimulacion = false
  llamadas.length = 0
})

describe('ModalSalvedadItem — combo roto por el cliente (#1192)', () => {
  it('antes de elegir el motivo, la opción "Cliente Rechaza" ya dice que el total sube $200', () => {
    render(<ModalSalvedadItem pedidoId="pedido-1" item={COCA_EN_COMBO} onSave={vi.fn()} onClose={vi.fn()} />)
    expect(screen.getByTestId('info-linea-combo')).toHaveTextContent(/si lo rechaza el cliente, el combo se rompe/i)
    expect(screen.getByTestId('aviso-combo-opcion')).toHaveTextContent(/Rompe el combo: el total sube \$\s?200/)
    // Se simula siempre con cliente_rechaza, sin esperar el motivo.
    expect(llamadas.some(l => l.enabled && l.salvedades[0]?.motivo === 'cliente_rechaza'
      && l.salvedades[0]?.pedidoItemId === 'item-coca' && l.salvedades[0]?.cantidadAfectada === 1)).toBe(true)
  })

  it('con "Cliente Rechaza" muestra la consecuencia y el botón avisa que se rompe el combo', () => {
    render(<ModalSalvedadItem pedidoId="pedido-1" item={COCA_EN_COMBO} onSave={vi.fn()} onClose={vi.fn()} />)
    fireEvent.click(screen.getByText('Cliente Rechaza'))
    const aviso = screen.getByTestId('aviso-combo-roto')
    expect(aviso).toHaveTextContent(/Se rompe un combo "Fernet \+ Coca"/)
    expect(aviso).toHaveTextContent(/Fernet: 1 vuelve a su precio sin combo \(\$\s?10\.000/)
    expect(aviso).toHaveTextContent(/Recargo por combo roto: \$\s?2\.160/)
    expect(aviso).toHaveTextContent(/El total del pedido sube \$\s?200/)
    expect(screen.getByRole('button', { name: /se rompe el combo/i })).toBeInTheDocument()
  })

  it('con un motivo nuestro mantiene el precio de combo y no avisa recargo', () => {
    render(<ModalSalvedadItem pedidoId="pedido-1" item={COCA_EN_COMBO} onSave={vi.fn()} onClose={vi.fn()} />)
    fireEvent.click(screen.getByText('Faltante de Stock'))
    expect(screen.queryByTestId('aviso-combo-roto')).not.toBeInTheDocument()
    expect(screen.getByTestId('aviso-combo-se-mantiene')).toHaveTextContent(/mantiene el precio de combo/i)
    expect(screen.queryByText(/Ajuste por combo/)).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /registrar salvedad/i })).toBeInTheDocument()
  })

  it('un motivo nuestro que rearma un combo muestra el ajuste (negativo)', () => {
    impactoPorMotivo.producto_danado = [{ ...SE_MANTIENE, recargo: -540 }]
    render(<ModalSalvedadItem pedidoId="pedido-1" item={COCA_EN_COMBO} onSave={vi.fn()} onClose={vi.fn()} />)
    fireEvent.click(screen.getByText('Producto Dañado'))
    expect(screen.getByTestId('aviso-combo-se-mantiene')).toHaveTextContent(/Ajuste por combo: -\$\s?540/)
  })

  it('si no se pudo simular, con "Cliente Rechaza" avisa igual que el total puede subir', () => {
    errorSimulacion = true
    impactoPorMotivo.cliente_rechaza = []
    render(<ModalSalvedadItem pedidoId="pedido-1" item={COCA_EN_COMBO} onSave={vi.fn()} onClose={vi.fn()} />)
    fireEvent.click(screen.getByText('Cliente Rechaza'))
    expect(screen.getByTestId('aviso-combo-sin-calculo')).toHaveTextContent(/el total puede subir/i)
  })

  it('una línea que no es de combo no simula combos ni muestra nada', () => {
    render(<ModalSalvedadItem pedidoId="pedido-1" item={YERBA} onSave={vi.fn()} onClose={vi.fn()} />)
    fireEvent.click(screen.getByText('Cliente Rechaza'))
    expect(screen.queryByTestId('info-linea-combo')).not.toBeInTheDocument()
    expect(screen.queryByTestId('aviso-combo-opcion')).not.toBeInTheDocument()
    expect(screen.queryByTestId('aviso-combo-roto')).not.toBeInTheDocument()
    expect(llamadas.every(l => !l.enabled)).toBe(true)
  })
})
