/**
 * Cada barra de regalo muestra el N de SU contenedor (#950): si el contenedor
 * tiene `unidades_por_bulto`, ese; si no, el factor de la promo. Vale también
 * para la barra del sabor default, y sólo en las promos de fracción.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import VistaPromociones from '../VistaPromociones'
import type { PromocionConDetalles } from '../../../hooks/queries/usePromocionesQuery'
import type { PromoAcumuladorDB } from '../../../types'

const promo = (extra: Partial<PromocionConDetalles> = {}): PromocionConDetalles => ({
  id: '13',
  nombre: 'Promo Manaos 6 + 2 3L',
  tipo: 'bonificacion',
  activo: true,
  fecha_inicio: '2020-01-01',
  fecha_fin: null,
  created_at: '2026-09-01T00:00:00Z',
  updated_at: '2026-09-01T00:00:00Z',
  productos: [],
  reglas: [],
  usos_pendientes: 4,
  ajuste_automatico: true,
  regalo_mueve_stock: false,
  unidades_por_bloque: 6,
  producto_regalo_id: '82',
  ajuste_producto_id: '82',
  ...extra,
} as PromocionConDetalles)

const placer: PromoAcumuladorDB = {
  id: 'a1', promocion_id: '13', producto_regalo_id: '125', ajuste_producto_id: '125',
  usos_pendientes: 7, sucursal_id: 1, created_at: '', updated_at: '',
}

const renderVista = (p: PromocionConDetalles, bultos: Map<string, number>) => render(
  <VistaPromociones
    promociones={[p]}
    loading={false}
    onNuevaPromocion={vi.fn()}
    onEditarPromocion={vi.fn()}
    onEliminarPromocion={vi.fn()}
    onToggleActivo={vi.fn()}
    productoNombres={new Map([['82', 'Manzana 3L'], ['125', 'Placer 500']])}
    acumuladoresPorPromo={new Map([['13', [placer]]])}
    unidadesPorBulto={bultos}
  />,
)

describe('VistaPromociones — N de la barra por contenedor (#950)', () => {
  it('el sabor default y el otro sabor muestran el bulto de su contenedor', () => {
    renderVista(promo(), new Map([['82', 8], ['125', 12]]))
    expect(screen.getByText('4 / 8')).toBeInTheDocument()
    expect(screen.getByText('7 / 12')).toBeInTheDocument()
  })

  it('sin bulto cargado, el factor de la promo', () => {
    renderVista(promo(), new Map())
    expect(screen.getByText('4 / 6')).toBeInTheDocument()
    expect(screen.getByText('6 / 6')).toBeInTheDocument() // 7 clampeado al tope
  })
})
