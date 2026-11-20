/**
 * Los modales hechos a mano (no pasan por `ui/Dialog` ni `BottomSheet`) también se cierran con el «atrás» del
 * teléfono (decisión 4 del dueño, #1603): la nota de crédito de compra, el alta de proveedor y la importación
 * desde Excel. Con el alta de proveedor / la importación dentro de la compra, el «atrás» cierra SÓLO el de
 * arriba y la compra queda.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/react'
import { asentar, atras, marca } from '../../test/atrasHelpers'
import { reiniciarAtrasModales } from '../../utils/atrasModales'
import ModalNotaCredito from './ModalNotaCredito'
import ModalProveedor from './ModalProveedor'
import ModalImportarCompra from './ModalImportarCompra'
import type { ModalNotaCreditoProps } from './ModalNotaCredito'

vi.mock('../../hooks/queries', () => ({
  useZonasEstandarizadasQuery: () => ({ data: [] }),
}))
vi.mock('../AddressAutocomplete', () => ({
  AddressAutocomplete: () => <input aria-label="direccion" />,
}))

const compra: ModalNotaCreditoProps['compra'] = {
  id: '313',
  numero_factura: 'A-0001-00000001',
  tipo_factura: 'FC',
  impuestos_internos: 0,
  items: [
    { id: '1', producto_id: '10', producto: { id: '10', nombre: 'Agua' }, cantidad: 10, costo_unitario: 100, subtotal: 1000, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
  ],
}

beforeEach(() => {
  reiniciarAtrasModales()
  window.history.replaceState(null, '', '/')
})
afterEach(async () => {
  cleanup()
  await asentar()
  reiniciarAtrasModales()
})

describe('modales hechos a mano · el «atrás» del teléfono', () => {
  it.each([
    ['la nota de crédito de compra', (onClose: () => void) => <ModalNotaCredito compra={compra} notasExistentes={[]} onSave={vi.fn()} onClose={onClose} />],
    ['el alta de proveedor', (onClose: () => void) => <ModalProveedor proveedor={null} onSave={vi.fn()} onClose={onClose} />],
    ['la importación desde Excel', (onClose: () => void) => <ModalImportarCompra productos={[]} onImportar={vi.fn()} onClose={onClose} />],
  ])('%s: suma una entrada y el «atrás» le pide el cierre, sin navegar', async (_nombre, modal) => {
    window.history.pushState({ pantalla: 'compras' }, '', '/compras')
    const onClose = vi.fn()
    render(modal(onClose))
    await asentar()
    expect(marca()).toBe(1)

    await atras()

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(window.location.pathname).toBe('/compras')
  })

  it('apilado sobre otra ventana, el «atrás» cierra sólo el de arriba', async () => {
    const abajo = vi.fn()
    const arriba = vi.fn()
    render(
      <>
        <ModalProveedor proveedor={null} onSave={vi.fn()} onClose={abajo} />
        <ModalImportarCompra productos={[]} onImportar={vi.fn()} onClose={arriba} />
      </>,
    )
    await asentar()
    expect(marca()).toBe(2)

    await atras()

    expect(arriba).toHaveBeenCalledTimes(1)
    expect(abajo).not.toHaveBeenCalled()
  })
})
