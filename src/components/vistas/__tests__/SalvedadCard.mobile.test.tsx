/**
 * #1116 — en el celular la tarjeta de salvedad cortaba el «Monto».
 *
 * El encabezado era una sola fila: a la izquierda producto/cliente/transportista,
 * a la derecha «Afectado», «Monto» y el chevron en un bloque `flex-shrink-0`.
 * Ese bloque no se encoge, así que a 375 px terminaba en x ≈ 461: el Monto
 * quedaba fuera de pantalla y la página entera ganaba scroll horizontal.
 *
 * jsdom no hace layout, así que se fija la estructura responsive (mismo criterio
 * que TopNavigation y Combobox): en mobile los números bajan a su propia fila y
 * sólo desde `sm` vuelven a la derecha sin encogerse; la columna de texto puede
 * achicarse (`min-w-0`) para que el `truncate` del producto funcione.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import type { SalvedadItemDBExtended } from '../../../types'

// La vista importa la capa de datos, que crea el cliente real al importarse.
vi.mock('../../../lib/supabase', () => ({ supabase: {} }))

import { SalvedadCard } from '../VistaSalvedades'

const SALVEDAD = {
  id: '1',
  pedido_id: '10',
  producto_nombre: 'Gaseosa Cola 2,25 L x6 retornable',
  cliente_nombre: 'Almacén Don Pepe',
  transportista_nombre: 'Juan Reparto',
  motivo: 'faltante_stock',
  estado_resolucion: 'pendiente',
  cantidad_original: 12,
  cantidad_afectada: 2,
  cantidad_entregada: 10,
  monto_afectado: 4250,
  created_at: '2026-10-12T23:30:00Z',
} as unknown as SalvedadItemDBExtended

function renderCard() {
  render(
    <SalvedadCard
      salvedad={SALVEDAD}
      onResolver={vi.fn()}
      onAnular={vi.fn()}
      puedeAnular={false}
      puedeResolver={false}
    />,
  )
  // «Monto» → su columna → el bloque de números → la fila del encabezado.
  const numeros = screen.getByText('Monto').parentElement!.parentElement!
  const fila = numeros.parentElement!
  // La columna de texto es el hijo de la fila que no es el bloque de números
  // (adentro tiene otro `flex-1 min-w-0`, el de los renglones: ése ya estaba bien).
  const texto = [...fila.children].find(h => h !== numeros) as HTMLElement
  return { numeros, fila, texto }
}

describe('SalvedadCard en el celular (#1116)', () => {
  it('el encabezado apila en mobile y vuelve a una fila desde sm', () => {
    const { fila } = renderCard()
    expect(fila).toHaveClass('flex-col', 'sm:flex-row')
  })

  it('los números no se niegan a encogerse en mobile: sólo desde sm', () => {
    const { numeros } = renderCard()
    expect(numeros).not.toHaveClass('flex-shrink-0')
    expect(numeros).toHaveClass('sm:flex-shrink-0')
  })

  it('la columna de texto puede achicarse, así el nombre del producto trunca', () => {
    const { texto } = renderCard()
    expect(texto).toHaveClass('min-w-0')
  })

  it('siguen estando Afectado y Monto, con sus valores', () => {
    renderCard()
    expect(screen.getByText('Afectado')).toBeInTheDocument()
    expect(screen.getByText('2 u.')).toBeInTheDocument()
    expect(screen.getByText(/4\.250/)).toBeInTheDocument()
  })
})
