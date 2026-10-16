/**
 * `ModalEntregaConSalvedad` — el lote sobre un combo (#1192).
 *
 * El resumen tiene que decir la verdad antes de confirmar: si el cliente
 * rechaza parte de un combo, el combo se rompe y el total a cobrar sube. El
 * dry-run de combos recibe todas las salvedades de líneas de combo del lote,
 * con su motivo, y sólo en el paso de confirmación.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ComboImpactoSalvedad } from '../../utils/comboSalvedad'
import type { SalvedadComboSimulada } from '../../hooks/queries/useSimularSalvedadComboQuery'
import type { PedidoDB, RegistrarSalvedadResult } from '../../types'

let combosSimulados: ComboImpactoSalvedad[] = []
const llamadasCombo: Array<{ salvedades: SalvedadComboSimulada[]; enabled: boolean | undefined }> = []

vi.mock('../../hooks/queries', () => ({
  useSimularSalvedadesPromoImpactoQuery: () => ({ data: [], isLoading: false }),
  useSimularSalvedadesComboImpactoQuery: (
    _pedidoId: unknown,
    salvedades: SalvedadComboSimulada[],
    opciones?: { enabled?: boolean },
  ) => {
    llamadasCombo.push({ salvedades, enabled: opciones?.enabled })
    return { data: opciones?.enabled ? combosSimulados : [], isLoading: false }
  },
}))

import ModalEntregaConSalvedad from './ModalEntregaConSalvedad'

// Fernet 10.000 + Coca 2.500, combo a 9.800 (Fernet 7.840, Coca 1.960).
const PEDIDO = {
  id: '50',
  cliente_id: '9',
  estado: 'en_preparacion',
  total: 9800,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Norte' },
  items: [
    { id: '201', pedido_id: '50', producto_id: '1', producto: { nombre: 'Fernet' }, cantidad: 1,
      precio_unitario: 7840, combo_id: '7', precio_sin_combo_unitario: 10000 },
    { id: '202', pedido_id: '50', producto_id: '2', producto: { nombre: 'Coca 2,25' }, cantidad: 1,
      precio_unitario: 1960, combo_id: '7', precio_sin_combo_unitario: 2500 },
  ],
} as unknown as PedidoDB

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

beforeEach(() => {
  combosSimulados = [ROTO]
  llamadasCombo.length = 0
})

async function rechazarCoca(motivo: string) {
  const user = userEvent.setup()
  const OK: RegistrarSalvedadResult[] = [{ success: true }]
  render(
    <ModalEntregaConSalvedad
      pedido={PEDIDO}
      onSave={vi.fn().mockResolvedValue(OK)}
      onMarcarEntregado={vi.fn().mockResolvedValue(undefined)}
      onClose={vi.fn()}
    />,
  )
  await user.click(screen.getByText('Coca 2,25'))
  await user.selectOptions(screen.getByRole('combobox'), motivo)
  await user.click(screen.getByRole('button', { name: /continuar/i }))
}

describe('ModalEntregaConSalvedad — combo roto por el cliente (#1192)', () => {
  it('el resumen muestra el combo roto, el recargo y el total que sube', async () => {
    await rechazarCoca('cliente_rechaza')

    expect(screen.getByTestId('resumen-combos-rotos')).toHaveTextContent(
      /Fernet \+ Coca: quedan 0 de 1 - vuelven a su precio sin combo: 1 Fernet/,
    )
    expect(screen.getByTestId('recargo-combos')).toHaveTextContent(/Recargo por combo roto:\s*\+\$\s?2\.160/)
    // 9.800 - 1.960 + 2.160 = 10.000
    expect(screen.getByText('Total efectivo a cobrar:').nextSibling).toHaveTextContent(/\$\s?10\.000/)
  })

  it('el dry-run recibe las salvedades de combo con su motivo, y sólo en la confirmación', async () => {
    await rechazarCoca('cliente_rechaza')
    const habilitadas = llamadasCombo.filter(l => l.enabled)
    expect(habilitadas.length).toBeGreaterThan(0)
    expect(habilitadas[habilitadas.length - 1]?.salvedades).toEqual([
      { pedidoItemId: '202', cantidadAfectada: 1, motivo: 'cliente_rechaza' },
    ])
  })

  it('sin recargo (motivo nuestro) no hay fila de recargo y el total es el de siempre', async () => {
    combosSimulados = [{ ...ROTO, combos_despues: 1, recargo: 0,
      productos: ROTO.productos.map(p => ({ ...p, fuera_despues: 0 })) }]
    await rechazarCoca('faltante_stock')

    expect(screen.queryByTestId('resumen-combos-rotos')).not.toBeInTheDocument()
    expect(screen.queryByTestId('recargo-combos')).not.toBeInTheDocument()
    expect(screen.getByText('Total efectivo a cobrar:').nextSibling).toHaveTextContent(/\$\s?7\.840/)
  })
})
