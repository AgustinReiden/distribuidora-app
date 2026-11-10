/**
 * FRT-3 (#1517): si la consulta de totales falla, los tiles de /pedidos mostraban
 * "0" y "$0" como si fueran datos (el resumen vacío de relleno). Y mientras la
 * consulta todavía carga, pasa lo mismo con cada cambio de filtro o de búsqueda.
 *
 * Con `cargando` o `error` el tile dice "—", y con `error` además aparece un aviso
 * con "Reintentar". Sin esas props nada cambia: los ceros reales se siguen viendo.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

import PedidoStats from '../PedidoStats'
import type { PedidoStatsSummary } from '../../../hooks/queries'

const VACIO: PedidoStatsSummary = {
  pendientes: { count: 0, monto: 0 },
  enPreparacion: { count: 0, monto: 0 },
  enCamino: { count: 0, monto: 0 },
  entregados: { count: 0, monto: 0 },
  impagos: { count: 0, monto: 0 },
  total: { count: 0, monto: 0 },
  aproximado: false,
}

describe('PedidoStats — carga y error (FRT-3)', () => {
  it('sin props de estado, un resumen en cero se ve en cero (es un dato real)', () => {
    render(<PedidoStats summary={VACIO} />)

    expect(screen.queryByText('—')).not.toBeInTheDocument()
    expect(screen.getAllByText('0').length).toBeGreaterThan(0)
  })

  it('con error los tiles no muestran ceros: muestran "—" y el aviso', () => {
    render(<PedidoStats summary={VACIO} error />)

    expect(screen.getByRole('alert')).toHaveTextContent('No se pudieron calcular los totales')
    expect(screen.queryByText('0')).not.toBeInTheDocument()
    expect(screen.queryByText(/\$\s*0,00/)).not.toBeInTheDocument()
    // Seis tiles, con conteo y monto cada uno.
    expect(screen.getAllByText('—').length).toBeGreaterThanOrEqual(6)
  })

  it('"Reintentar" del aviso llama a onReintentar', async () => {
    const onReintentar = vi.fn()
    render(<PedidoStats summary={VACIO} error onReintentar={onReintentar} />)

    await userEvent.click(screen.getByRole('button', { name: 'Reintentar' }))

    expect(onReintentar).toHaveBeenCalledTimes(1)
  })

  it('cargando muestra "—" sin alarma: todavía no se sabe', () => {
    render(<PedidoStats summary={VACIO} cargando />)

    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.queryByText('0')).not.toBeInTheDocument()
    expect(screen.getAllByText('—').length).toBeGreaterThanOrEqual(6)
  })

  it('el aviso de "totales aproximados" no se muestra sobre datos que no existen', () => {
    render(<PedidoStats summary={{ ...VACIO, aproximado: true }} error />)

    expect(screen.queryByText(/Totales aproximados/)).not.toBeInTheDocument()
  })
})
