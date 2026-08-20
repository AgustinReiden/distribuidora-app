/**
 * Los cargos prorrateados al editar una compra (mig 194).
 *
 * Esto se testea porque acá el fallo es MUDO. `actualizar_compra_items` borra y
 * recrea las líneas en cada edición y el CASCADE se lleva puesto el vector de
 * pesos, así que un modal que no reenvía los cargos deja el flete colgado sin
 * ninguna línea: la compra se guarda bien, el costo de los productos baja un
 * 16% y no hay ningún error en ningún lado.
 *
 * Y los pesos van por ÍNDICE del payload nuevo, no por id de línea: los
 * compra_items.id de esta compra dejan de existir en el mismo UPDATE.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../utils/formatters', () => ({
  formatPrecio: (value) => `$${Number(value).toFixed(2)}`,
}))

import ModalEditarCompra from './ModalEditarCompra'

const compraBase = (overrides = {}) => ({
  id: 500,
  estado: 'recibida',
  tipo_factura: 'FC',
  proveedor: { id: 6, nombre: 'Manaos' },
  numero_factura: 'A0005-461415',
  fecha_compra: '2026-08-18',
  total: 3630,
  otros_impuestos: 0,
  percepcion_iva: 0,
  percepcion_iibb: 0,
  no_gravado: 0,
  ii_declarado: { 4.1667: 1234.5 },
  items: [
    {
      id: 91, producto_id: 1, cantidad: 10, costo_unitario: 100, bonificacion: 0,
      porcentaje_iva: 21, condicion_iva: 'gravado', impuestos_internos: 0,
      producto: { nombre: 'Lima Limon 600' },
    },
    {
      id: 92, producto_id: 2, cantidad: 5, costo_unitario: 200, bonificacion: 0,
      porcentaje_iva: 21, condicion_iva: 'gravado', impuestos_internos: 0,
      producto: { nombre: 'Bidon 20L' },
    },
  ],
  // A propósito fuera de orden: el payload se reordena por `orden`.
  cargos: [
    {
      id: 7, orden: 1, concepto: 'Pallets', monto: 162000, condicion_iva: 'no_gravado',
      en_factura: true, prorratea_al_costo: true, afecta_base_ii: false, base_prorrateo: 'cantidad',
      repartos: [{ compra_item_id: 91, peso: 10 }, { compra_item_id: 92, peso: 5 }],
    },
    {
      id: 6, orden: 0, concepto: 'Separadores bidon', monto: 8800, condicion_iva: 'no_gravado',
      en_factura: true, prorratea_al_costo: true, afecta_base_ii: false, base_prorrateo: 'unidades',
      repartos: [{ compra_item_id: 92, peso: 1 }],
    },
  ],
  ...overrides,
})

const props = (compra, onGuardar = vi.fn().mockResolvedValue(undefined)) => ({
  compra, usuarioId: 'u1', onGuardar, onClose: vi.fn(), guardando: false,
})

const guardar = (user) => user.click(screen.getByRole('button', { name: /guardar/i }))

/**
 * El botón de borrar de la línea `i`. Hay dos layouts en el DOM —tarjeta y
 * tabla— y CSS decide cuál se ve; en jsdom se toma el de la tarjeta.
 */
const borrarLinea = (user, i) =>
  user.click(screen.getAllByRole('button', { name: /eliminar item/i })[i])

describe('ModalEditarCompra · cargos prorrateados', () => {
  it('reenvía los cargos con los pesos por índice del payload nuevo', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarCompra {...props(compraBase(), onGuardar)} />)

    await guardar(user)

    const enviado = onGuardar.mock.calls[0][0]
    expect(enviado.cargos).toEqual([
      // Ordenados por `orden`, no por como vinieron.
      expect.objectContaining({ concepto: 'Separadores bidon', monto: 8800, pesos: { 1: 1 } }),
      expect.objectContaining({ concepto: 'Pallets', monto: 162000, pesos: { 0: 10, 1: 5 } }),
    ])
    // Las banderas fiscales viajan tal cual: acá no se editan.
    expect(enviado.cargos[1]).toMatchObject({
      condicionIva: 'no_gravado', enFactura: true, prorrateaAlCosto: true,
      afectaBaseII: false, baseProrrateo: 'cantidad',
    })
    // Y la apertura del II también, o el factor de ajuste se revierte solo.
    expect(enviado.iiDeclarado).toEqual({ 4.1667: 1234.5 })
  })

  it('borrar una línea corre los índices y suelta su peso', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarCompra {...props(compraBase(), onGuardar)} />)

    await borrarLinea(user, 0)
    await guardar(user)

    const enviado = onGuardar.mock.calls[0][0]
    expect(enviado.items).toHaveLength(1)
    // El bidón pasa a ser el índice 0 y el peso de la línea borrada desaparece:
    // mandarlo apuntaría a un índice que ya no existe y la RPC lo rechaza.
    expect(enviado.cargos.map(c => c.pesos)).toEqual([{ 0: 1 }, { 0: 5 }])
  })

  it('bloquea la edición que dejaría un cargo sin ninguna línea', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockResolvedValue(undefined)
    render(<ModalEditarCompra {...props(compraBase(), onGuardar)} />)

    // Los separadores sólo pesan sobre el bidón: sin esa línea, esos 8.800
    // desaparecen del costo sin que nadie los vea irse.
    await borrarLinea(user, 1)
    await guardar(user)

    expect(onGuardar).not.toHaveBeenCalled()
    expect(screen.getByText(/Separadores bidon.*sin ninguna l.nea/i)).toBeInTheDocument()
  })

  it('sin cargos leídos manda null, no una lista vacía', async () => {
    // `[]` significa "esta compra no tiene ninguno" y pasa el guard de la RPC
    // borrándolos; `null` significa "no los conozco" y es lo único que lo
    // dispara. La distinción es la que separa un rechazo de una pérdida muda.
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockResolvedValue(undefined)
    const compra = compraBase()
    delete compra.cargos
    delete compra.ii_declarado
    render(<ModalEditarCompra {...props(compra, onGuardar)} />)

    await guardar(user)

    expect(onGuardar.mock.calls[0][0].cargos).toBeNull()
    expect(onGuardar.mock.calls[0][0].iiDeclarado).toBeNull()
  })

  it('muestra el rechazo de la RPC en vez de tragárselo', async () => {
    // Las RPCs devuelven {success:false} con HTTP 200; el container lo convierte
    // en Error. Sin esto el mensaje sólo vivía en un toast que se va solo.
    const user = userEvent.setup()
    const onGuardar = vi.fn().mockRejectedValue(
      new Error('Esta compra tiene cargos prorrateados. Actualizá la aplicación (recargá la página) antes de editarla.'),
    )
    render(<ModalEditarCompra {...props(compraBase(), onGuardar)} />)

    await guardar(user)

    expect(await screen.findByText(/Actualizá la aplicación/i)).toBeInTheDocument()
  })

  it('lista los cargos como informativos: no se editan y no entran al total', () => {
    render(<ModalEditarCompra {...props(compraBase())} />)
    expect(screen.getByText(/Separadores bidon \$8800.00 · Pallets \$162000.00/)).toBeInTheDocument()
    // El total sigue siendo el de las líneas: los cargos van al costo unitario
    // de los productos, no a la cabecera de la compra.
    expect(screen.getByText('$2420.00')).toBeInTheDocument()
  })
})
