/**
 * El chip de cupo muestra el conteo vivo de `promos_cupo` (#1283), no
 * `usos_pendientes`, y dice qué cuenta: el corte de la promo (#1300).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import VistaPromociones from '../VistaPromociones'
import type { PromocionConDetalles } from '../../../hooks/queries/usePromocionesQuery'
import { LEYENDA_CUPO, type CupoPromo } from '../../../utils/cupoPromo'

const promo = (extra: Partial<PromocionConDetalles> = {}): PromocionConDetalles => ({
  id: '34',
  nombre: 'Cola+ Limon',
  tipo: 'bonificacion',
  activo: true,
  fecha_inicio: '2020-01-01',
  fecha_fin: null,
  created_at: '2026-09-01T00:00:00Z',
  updated_at: '2026-09-01T00:00:00Z',
  productos: [],
  reglas: [],
  usos_pendientes: 158,
  limite_usos: 20,
  regalo_mueve_stock: true,
  ...extra,
} as PromocionConDetalles)

const renderVista = (p: PromocionConDetalles, cupos?: Map<string, CupoPromo>) => render(
  <VistaPromociones
    promociones={[p]}
    loading={false}
    onNuevaPromocion={vi.fn()}
    onEditarPromocion={vi.fn()}
    onEliminarPromocion={vi.fn()}
    onToggleActivo={vi.fn()}
    productoNombres={new Map()}
    cupos={cupos}
  />,
)

const cupo = (usos: number): Map<string, CupoPromo> =>
  new Map([['34', { promocionId: '34', limite: 20, usos, quedan: 20 - usos }]])

describe('VistaPromociones — el chip de cupo (#1283)', () => {
  it('muestra el conteo vivo, no usos_pendientes', () => {
    renderVista(promo(), cupo(16))
    expect(screen.getByText('Cupo: 16 de 20')).toBeInTheDocument()
    expect(screen.queryByText(/158/)).not.toBeInTheDocument()
  })

  it('dice que cuenta el corte y que sustituir no lo mueve', () => {
    renderVista(promo(), cupo(16))
    expect(screen.getByText(LEYENDA_CUPO)).toBeInTheDocument()
  })

  it('va también en una promo con fracción, donde usos_pendientes es el resto de la barra', () => {
    renderVista(promo({ regalo_mueve_stock: false, unidades_por_bloque: 6 }), cupo(16))
    expect(screen.getByText('Cupo: 16 de 20')).toBeInTheDocument()
  })

  it('en rojo al llegar al límite', () => {
    renderVista(promo(), cupo(20))
    expect(screen.getByText('Cupo: 20 de 20')).toHaveClass('bg-red-100')
  })

  it('sin el conteo no inventa nada', () => {
    renderVista(promo())
    expect(screen.queryByText(/Cupo:/)).not.toBeInTheDocument()
    expect(screen.queryByText(LEYENDA_CUPO)).not.toBeInTheDocument()
  })
})
