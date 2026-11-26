/**
 * Fr-B1 de #1554 (T14 de #1690): el panel de la parada activa mostraba el TOTAL junto al chip
 * PARCIAL / A COBRAR. Un parcial de 1.000 con 400 cobrados decía «PARCIAL $ 1.000»: el chofer
 * creía que tenía que cobrar 1.000. Tiene que decir lo que falta.
 */
import type { ComponentProps } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import SheetParada from './SheetParada'
import type { PedidoConCliente } from './useEntregaParada'

const parada = (extra: Record<string, unknown>): PedidoConCliente => ({
  id: '1', total: 1000, monto_pagado: 0, estado: 'asignado', estado_pago: 'pendiente', orden_entrega: 1,
  forma_pago: 'efectivo', items: [], cliente: { id: 'c1', nombre_fantasia: 'Kiosco Sur', direccion: 'San Martín 123' },
  ...extra,
}) as unknown as PedidoConCliente

function montar(p: PedidoConCliente) {
  const props: ComponentProps<typeof SheetParada> = {
    paradas: [p], paradaActiva: p, distanciaMetros: null, llegaste: false,
    onSeleccionarParada: vi.fn(), onEntregar: vi.fn(), onNoEntregar: vi.fn(), onSalvedad: vi.fn(), linksRutaMaps: [],
  }
  render(<SheetParada {...props} />)
  fireEvent.click(screen.getByRole('button', { name: /abrir el detalle de la parada/i }))
}

/** Lo que dice la línea del chip de estado de pago. */
const lineaDelChip = (chip: string): string => screen.getByText(chip).parentElement!.textContent ?? ''

describe('SheetParada — el chip de pago dice lo que falta cobrar (Fr-B1)', () => {
  it('PARCIAL: muestra el saldo y no el total', () => {
    montar(parada({ estado_pago: 'parcial', monto_pagado: 400 }))
    const linea = lineaDelChip('PARCIAL')
    expect(linea).toMatch(/Falta\s*\$\s*600,00/)
    expect(linea).toMatch(/de\s*\$\s*1\.000,00/)
  })

  it('A COBRAR sin nada pagado: el saldo es el total', () => {
    montar(parada({ estado_pago: 'pendiente', monto_pagado: 0 }))
    expect(lineaDelChip('A COBRAR')).toMatch(/\$\s*1\.000,00/)
  })

  it('PAGADO: no queda nada por cobrar y se ve el total de la boleta', () => {
    montar(parada({ estado_pago: 'pagado', monto_pagado: 1000 }))
    const linea = lineaDelChip('PAGADO')
    expect(linea).toMatch(/\$\s*1\.000,00/)
    expect(linea).not.toMatch(/Falta/)
  })
})
