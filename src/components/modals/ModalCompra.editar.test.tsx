/**
 * ModalCompra en modo 'editar': la compra guardada en el formulario de carga,
 * con líneas y cargos editables. Reemplaza a ModalEditarCompra (retirado en la
 * entrega B2), así que acá viven también las intenciones de sus tests:
 * cambiar proveedor trabado con cambios, vencimientos precargados una vez,
 * cargos null ≠ [], el rechazo de la RPC adentro del modal, el cargo huérfano.
 *
 * Lo primero es la CARACTERIZACIÓN: abrir una compra con la forma de la 304 y
 * guardar sin tocar nada tiene que mandar exactamente lo que ya estaba —pesos
 * tipeados, costos, bonificaciones, no gravado, afecta_base_ii— y el costo
 * unitario que el motor deriva de ese payload tiene que ser el guardado.
 *
 * Datos sintéticos (src/test/fixtures/compraTestigoEdicion): el repo es público.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, within, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { CompraDBExtended } from '../../types'

vi.mock('../../lib/supabase', () => ({
  supabase: {
    storage: { from: vi.fn() },
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

vi.mock('../../hooks/queries/useComprasQuery', async (importOriginal) => {
  const real = await importOriginal<typeof import('../../hooks/queries/useComprasQuery')>()
  return {
    ...real,
    useCargosPlantillaProveedorQuery: () => ({ data: null }),
    useComprasMismaFacturaQuery: () => ({ data: [] }),
    useCostosAnterioresQuery: () => ({ data: undefined }),
  }
})

// Catálogo de cargos y medidas (mig 278): vacío, como antes de la migración.
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  // Referencias estables: el modal sincroniza su estado cuando cambian.
  const conceptos: unknown[] = [], medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: conceptos }),
    useCargoMedidasQuery: () => ({ data: medidas }),
    useProductoMedidasQuery: () => ({ data: ficha }),
  }
})
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))

import ModalCompra from './ModalCompra'
import { paramsActualizarCompraItems } from '../../hooks/queries/useComprasQuery'
import type { ActualizarCompraItemsInput } from '../../hooks/queries/useComprasQuery'
import { calcularCostosCompra, lineaParaMotor } from '../../utils/prorrateoCompra'
import { redondearSQL } from '../../utils/calculations'
import { compraTestigoEdicion, COSTOS_GUARDADOS_304 } from '../../test/fixtures/compraTestigoEdicion'

type Props = Parameters<typeof ModalCompra>[0]

const PRODUCTO_NUEVO = {
  id: '777', nombre: 'Soda 1,5L', codigo: 'S15', stock: 12, costo_sin_iva: 300,
  impuestos_internos: 4.5, porcentaje_iva: 21, condicion_iva: 'gravado', activo: true,
}

function renderEditar(compra: CompraDBExtended = compraTestigoEdicion(), props: Partial<Props> = {}) {
  const onGuardarEdicion = vi.fn<(input: ActualizarCompraItemsInput) => Promise<void>>(() => Promise.resolve())
  const onClose = vi.fn()
  const onCambiarProveedor = vi.fn()
  const todas: Props = {
    modo: 'editar',
    compra,
    productos: [PRODUCTO_NUEVO as never],
    proveedores: [],
    onClose,
    onGuardarEdicion,
    onCambiarProveedor,
    canCambiarProveedor: true,
    usuarioId: 'u1',
    sucursalId: 1,
    lotes: [],
    ...props,
  }
  const utils = render(<ModalCompra {...todas} />)
  return { ...utils, onGuardarEdicion, onClose, onCambiarProveedor, user: userEvent.setup(), props: todas }
}

const guardar = (user: ReturnType<typeof userEvent.setup>) =>
  user.click(screen.getByRole('button', { name: /Guardar cambios/ }))

const enviado = (fn: ReturnType<typeof renderEditar>['onGuardarEdicion']) => fn.mock.calls[0][0]

/** El input de cantidad de una línea (hay dos por línea: tarjeta y grilla). */
const cantidadDe = (valor: string) => screen.getAllByDisplayValue(valor)[0]

/** Reemplaza lo que tiene un input numérico por `valor`, sobre el MISMO nodo. */
async function tipear(user: ReturnType<typeof userEvent.setup>, input: HTMLElement, valor: string) {
  await user.clear(input)
  await user.type(input, valor)
}

// =============================================================================
// CARACTERIZACIÓN
// =============================================================================

describe("ModalCompra 'editar' · abrir la 304 y guardar sin tocar nada", () => {
  it('manda las líneas tal cual, en el orden de compra_items', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    await guardar(user)
    const input = enviado(onGuardarEdicion)
    const linea = (productoId: string, cantidad: number, costo: number, ii: number) => ({
      productoId, cantidad, costoUnitario: costo, subtotal: cantidad * costo, bonificacion: 0,
      porcentajeIva: 21, condicionIva: 'gravado', impuestosInternos: ii, vencimientos: [],
    })
    expect(input.items).toEqual([
      linea('501', 240, 1000, 0),
      linea('502', 160, 1500, 0),
      // El II del SNAPSHOT (10), no el de la ficha de hoy (99).
      linea('503', 60, 2000, 10),
      linea('504', 75, 800, 10),
    ])
  })

  it('manda los cargos con los pesos guardados, por índice, y las banderas intactas', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    await guardar(user)
    const input = enviado(onGuardarEdicion)
    expect(input.cargos).toEqual([
      {
        concepto: 'Flete', monto: 9000, condicionIva: 'no_gravado', enFactura: false,
        prorrateaAlCosto: true, afectaBaseII: false, baseProrrateo: 'cantidad',
        // Tipeados: si algo los recalculara serían 240 / 160 / 60 / 75.
        pesos: { 0: 4, 1: 1, 2: 1, 3: 0.5 },
        conceptoId: null,
        medidaId: null,
      },
      {
        concepto: 'Pallets', monto: 4000, condicionIva: 'no_gravado', enFactura: true,
        prorrateaAlCosto: true, afectaBaseII: false, baseProrrateo: 'cantidad',
        pesos: { 0: 2, 1: 2, 2: 1, 3: 1 },
        conceptoId: null,
        medidaId: null,
      },
      {
        concepto: 'Bonificacion 3L', monto: -6000, condicionIva: 'gravado', enFactura: true,
        prorrateaAlCosto: true, afectaBaseII: true, baseProrrateo: 'monto',
        // La línea 14 no tenía fila de reparto: viaja como 0 explícito, que es
        // lo mismo (el 0 es la exclusión).
        pesos: { 0: 0, 1: 0, 2: 120000, 3: 0 },
        conceptoId: null,
        medidaId: null,
      },
    ])
  })

  it('cabecera: totales iguales a los guardados, bonificaciones y no gravado sin cambio, percepciones no viajan', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    await guardar(user)
    const input = enviado(onGuardarEdicion)
    expect({
      subtotal: redondearSQL(input.subtotal, 2),
      iva: redondearSQL(input.iva, 2),
      impuestosInternos: redondearSQL(input.impuestosInternos!, 2),
      total: redondearSQL(input.total, 2),
    }).toEqual({ subtotal: 660000, iva: 137340, impuestosInternos: 17400, total: 813974.5 })
    expect(input).toMatchObject({
      compraId: '304', usuarioId: 'u1', bonificaciones: -6000, noGravado: 4000, iiDeclarado: null,
    })
    expect(input.percepcionIva).toBeUndefined()
    expect(input.percepcionIibb).toBeUndefined()
  })

  it('el payload de la RPC es exacto: p_items_nuevos, p_cargos y los totales', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    await guardar(user)
    const params = paramsActualizarCompraItems(enviado(onGuardarEdicion))
    expect(params.p_items_nuevos).toEqual([
      { producto_id: '501', cantidad: 240, costo_unitario: 1000, subtotal: 240000, bonificacion: 0, porcentaje_iva: 21, condicion_iva: 'gravado', impuestos_internos: 0 },
      { producto_id: '502', cantidad: 160, costo_unitario: 1500, subtotal: 240000, bonificacion: 0, porcentaje_iva: 21, condicion_iva: 'gravado', impuestos_internos: 0 },
      { producto_id: '503', cantidad: 60, costo_unitario: 2000, subtotal: 120000, bonificacion: 0, porcentaje_iva: 21, condicion_iva: 'gravado', impuestos_internos: 10 },
      { producto_id: '504', cantidad: 75, costo_unitario: 800, subtotal: 60000, bonificacion: 0, porcentaje_iva: 21, condicion_iva: 'gravado', impuestos_internos: 10 },
    ])
    expect(params.p_cargos).toEqual([
      { concepto: 'Flete', monto: 9000, condicion_iva: 'no_gravado', en_factura: false, prorratea_al_costo: true, afecta_base_ii: false, base_prorrateo: 'cantidad', pesos: { 0: 4, 1: 1, 2: 1, 3: 0.5 }, concepto_id: null, medida_id: null },
      { concepto: 'Pallets', monto: 4000, condicion_iva: 'no_gravado', en_factura: true, prorratea_al_costo: true, afecta_base_ii: false, base_prorrateo: 'cantidad', pesos: { 0: 2, 1: 2, 2: 1, 3: 1 }, concepto_id: null, medida_id: null },
      { concepto: 'Bonificacion 3L', monto: -6000, condicion_iva: 'gravado', en_factura: true, prorratea_al_costo: true, afecta_base_ii: true, base_prorrateo: 'monto', pesos: { 0: 0, 1: 0, 2: 120000, 3: 0 }, concepto_id: null, medida_id: null },
    ])
    expect(params).toMatchObject({
      p_compra_id: '304', p_usuario_id: 'u1', p_bonificaciones: -6000, p_no_gravado: 4000,
      p_percepcion_iva: null, p_percepcion_iibb: null, p_ii_declarado: null,
    })
  })

  it('el costo_real_unitario que el motor deriva de ESE payload es el guardado (espejo TS de la RPC)', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    await guardar(user)
    const input = enviado(onGuardarEdicion)
    // Como la RPC: líneas por índice del payload, pesos por índice.
    const lineas = input.items.map((it, i) => lineaParaMotor(it, 'FC', i))
    const cargos = input.cargos!.map((c, i) => ({ ...c, id: i }))
    const costos = calcularCostosCompra(lineas, cargos, input.iiDeclarado ?? {})
    const porProducto = Object.fromEntries(
      costos.lineas.map(l => [input.items[l.id].productoId, redondearSQL(l.costoRealUnitario, 4)]),
    )
    expect(porProducto).toEqual(COSTOS_GUARDADOS_304)
  })

  it('el cuadre del pie compara contra el total ORIGINAL y cierra', () => {
    renderEditar()
    const barra = screen.getByRole('group', { name: 'Cuadre contra el total original' })
    expect(within(barra).getByTestId('cuadre-total-original')).toHaveTextContent(/813\.974,5/)
    expect(within(barra).getByTestId('cuadre-diferencia')).toHaveTextContent('✓ Igual al original')
  })
})

// =============================================================================
// QUÉ SE EDITA Y QUÉ NO
// =============================================================================

describe("ModalCompra 'editar' · cabezal inmutable, borrador ausente", () => {
  it('el cabezal se muestra sin poder editarse; las líneas y los cargos sí', () => {
    renderEditar()
    expect(screen.getByRole('heading', { name: 'Editar Compra #304' })).toBeInTheDocument()
    expect(screen.getByText('Bebidas Testigo SA')).toBeInTheDocument()
    expect(screen.getByDisplayValue('A0005-00012345')).toBeDisabled()
    expect(screen.getByDisplayValue('2026-09-12')).toBeDisabled()
    expect(screen.getByDisplayValue('Transferencia')).toBeDisabled()
    expect(screen.getByRole('button', { name: /ZZ Sin Factura/ })).toBeDisabled()
    expect(screen.getByText('Llegó con un pallet roto')).toBeInTheDocument()
    // Lo editable.
    expect(cantidadDe('240')).toBeEnabled()
    expect(screen.getByDisplayValue('Flete')).toBeEnabled()
    expect(screen.getByRole('button', { name: /Agregar cargo/ })).toBeEnabled()
    expect(screen.getByPlaceholderText('Buscar producto por nombre o codigo...')).toBeEnabled()
    // Lo que es sólo de la carga no está.
    expect(screen.queryByRole('button', { name: /Registrar Compra/ })).toBeNull()
    expect(screen.queryByRole('button', { name: /Importar Excel/ })).toBeNull()
  })

  it('el impuesto interno de la línea no se tipea: sale del snapshot', () => {
    renderEditar()
    // Se muestra como texto (10%), no hay input con ese valor.
    expect(screen.getAllByText('10%').length).toBeGreaterThan(0)
    expect(screen.queryByDisplayValue('10')).toBeNull()
  })

  it('las percepciones se muestran pero no se editan', () => {
    renderEditar()
    expect(screen.getByText('Percepción IVA (sin cambio)')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /3% del gravado/ })).toBeNull()
  })

  describe('el borrador local', () => {
    let get: ReturnType<typeof vi.spyOn>
    let set: ReturnType<typeof vi.spyOn>
    beforeEach(() => {
      get = vi.spyOn(Storage.prototype, 'getItem')
      set = vi.spyOn(Storage.prototype, 'setItem')
    })
    afterEach(() => {
      get.mockRestore()
      set.mockRestore()
    })

    it('editar nunca lo lee ni lo escribe, aunque haya sucursal y usuario', async () => {
      localStorage.setItem('compra-borrador:1:u1', '{"version":1}')
      set.mockClear()
      get.mockClear()
      const { user } = renderEditar()
      await tipear(user, cantidadDe('240'), '241')
      await new Promise(r => setTimeout(r, 50))
      const tocaBorrador = (llamadas: unknown[][]) => llamadas.some(([clave]) => String(clave).includes('compra-borrador'))
      expect(tocaBorrador(get.mock.calls)).toBe(false)
      expect(tocaBorrador(set.mock.calls)).toBe(false)
      // Y no ofrece retomar el borrador de 'nueva'.
      expect(screen.queryByText(/Retomar/)).toBeNull()
      localStorage.removeItem('compra-borrador:1:u1')
    })
  })
})

// =============================================================================
// PESOS DESACTUALIZADOS
// =============================================================================

describe("ModalCompra 'editar' · cambiar una cantidad", () => {
  it('no pisa los pesos manuales: los marca y "recalcular" los lleva a la cantidad nueva', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    await tipear(user, cantidadDe('240'), '480')

    // Flete y Pallets son por cantidad: los dos quedan marcados en la línea 1.
    const avisos = await screen.findAllByTestId('peso-desactualizado')
    expect(avisos).toHaveLength(2)
    expect(avisos[0]).toHaveTextContent(/se fijó para 240 u\. y la línea ahora tiene 480\. Recalculado daría 8/)

    // Recalcular SÓLO el flete.
    const botones = screen.getAllByRole('button', { name: /Recalcular el peso desactualizado/ })
    await user.click(botones[0])
    expect(screen.getAllByTestId('peso-desactualizado')).toHaveLength(1)

    await guardar(user)
    const input = enviado(onGuardarEdicion)
    expect(input.cargos![0].pesos).toEqual({ 0: 8, 1: 1, 2: 1, 3: 0.5 })
    // Los pallets no se tocaron solos: siguen en 2 (marcados, pero es decisión del usuario).
    expect(input.cargos![1].pesos).toEqual({ 0: 2, 1: 2, 2: 1, 3: 1 })
    // La bonificación es por monto: no entra en la regla y conserva su vector.
    expect(input.cargos![2].pesos).toEqual({ 0: 0, 1: 0, 2: 120000, 3: 0 })
  })
})

// =============================================================================
// AGREGAR LÍNEAS
// =============================================================================

describe("ModalCompra 'editar' · agregar una línea", () => {
  it('del buscador: entra con los datos de la ficha y con peso 0 en los cargos guardados', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
    await user.click(screen.getByRole('button', { name: /Soda 1,5L/ }))
    // Sin peso, ningún cargo se repartiría sobre ella: hay que darle uno a mano.
    await guardar(user)
    const input = enviado(onGuardarEdicion)
    expect(input.items).toHaveLength(5)
    expect(input.items[4]).toMatchObject({ productoId: '777', cantidad: 1, costoUnitario: 300, impuestosInternos: 4.5 })
    for (const c of input.cargos!) expect(c.pesos[4]).toBe(0)
    // Lo que ya estaba no se movió.
    expect(input.cargos![0].pesos).toMatchObject({ 0: 4, 1: 1, 2: 1, 3: 0.5 })
  })

  it('con el alta rápida: crea el producto y lo agrega', async () => {
    const onCrearProductoRapido = vi.fn(() => Promise.resolve({
      id: '888', nombre: 'Tónica 1L', codigo: '', costo_sin_iva: 250, impuestos_internos: 0,
    } as never))
    const { user, onGuardarEdicion } = renderEditar(undefined, { onCrearProductoRapido })
    await user.click(screen.getByTitle('Crear producto nuevo'))
    await user.type(screen.getByPlaceholderText('Nombre del producto'), 'Tónica 1L')
    await user.click(screen.getByRole('button', { name: /Crear y Agregar/ }))
    await waitFor(() => expect(onCrearProductoRapido).toHaveBeenCalled())
    // El proveedor del producto arranca en el de la compra.
    expect(onCrearProductoRapido).toHaveBeenCalledWith(expect.objectContaining({ nombre: 'Tónica 1L', proveedorId: '7' }))
    await guardar(user)
    expect(enviado(onGuardarEdicion).items.map(i => i.productoId)).toEqual(['501', '502', '503', '504', '888'])
  })
})

// =============================================================================
// INVENTARIO DE ModalEditarCompra
// =============================================================================

describe("ModalCompra 'editar' · lo que hacía ModalEditarCompra", () => {
  it('borrar una línea corre los índices de los pesos', async () => {
    const compra = compraTestigoEdicion()
    const { user, onGuardarEdicion } = renderEditar(compra)
    // La papelera de la línea 1 (Agua 600 x12). Hay una por layout.
    const tarjeta = screen.getAllByText('Agua 600 x12')[0].closest('.bg-white')! as HTMLElement
    await user.click(within(tarjeta).getAllByRole('button').find(b => b.querySelector('svg.lucide-trash2, svg.lucide-trash-2'))!)
    await guardar(user)
    const input = enviado(onGuardarEdicion)
    expect(input.items.map(i => i.productoId)).toEqual(['502', '503', '504'])
    expect(input.cargos![0].pesos).toEqual({ 0: 1, 1: 1, 2: 0.5 })
  })

  it('bloquea el cargo huérfano: borrar la única línea donde pesaba', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    const tarjeta = screen.getAllByText('Gaseosa 3L')[0].closest('.bg-white')! as HTMLElement
    await user.click(within(tarjeta).getAllByRole('button').find(b => b.querySelector('svg.lucide-trash2, svg.lucide-trash-2'))!)
    await guardar(user)
    expect(onGuardarEdicion).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent(/"Bonificacion 3L" se quedaría sin ninguna línea/)
  })

  it('bloquea una bonificación de línea del 100%', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    await tipear(user, screen.getAllByDisplayValue('0')[0], '100')
    await guardar(user)
    expect(onGuardarEdicion).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent(/Bonificación fuera de rango/)
  })

  it('el rechazo de la RPC se muestra ADENTRO del modal y el modal queda abierto', async () => {
    const onGuardarEdicion = vi.fn(() => Promise.reject(new Error('No se puede editar una compra creada hace mas de 7 dias')))
    const { user, onClose } = renderEditar(undefined, { onGuardarEdicion })
    await guardar(user)
    expect(await screen.findByRole('alert')).toHaveTextContent(/hace mas de 7 dias/)
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Editar Compra #304' })).toBeInTheDocument()
  })

  it('sin el embed de cargos manda cargos: null y no ofrece editarlos', async () => {
    const { user, onGuardarEdicion } = renderEditar(compraTestigoEdicion({ cargos: undefined }))
    expect(screen.getByText(/No se pudieron leer los cargos/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Agregar cargo/ })).toBeNull()
    await guardar(user)
    expect(enviado(onGuardarEdicion)).toMatchObject({ cargos: null, bonificaciones: -6000 })
  })

  it('cambiar la condición de IVA de una línea viaja coherente (condición manda sobre alícuota)', async () => {
    const { user, onGuardarEdicion } = renderEditar()
    const selector = screen.getAllByDisplayValue('21%')[0] as HTMLSelectElement
    await user.selectOptions(selector, 'exento')
    await guardar(user)
    expect(enviado(onGuardarEdicion).items[0]).toMatchObject({ condicionIva: 'exento', porcentajeIva: 0 })
  })

  it('en ZZ la condición viaja como la guarda la RPC: gravado, sin alícuota ni II', async () => {
    const { user, onGuardarEdicion } = renderEditar(compraTestigoEdicion({ tipo_factura: 'ZZ', no_gravado: 0 }))
    await guardar(user)
    for (const it of enviado(onGuardarEdicion).items) {
      expect(it).toMatchObject({ condicionIva: 'gravado', porcentajeIva: 0, impuestosInternos: 0 })
    }
  })
})

describe("ModalCompra 'editar' · vencimientos", () => {
  const lotes = (cantidad: number) => [{ producto_id: 503, fecha_vencimiento: '2027-03-01', cantidad }]

  it('se precargan UNA vez, cuando llegan, y viajan en el payload', async () => {
    const r = renderEditar(undefined, { lotes: undefined })
    // Llegan después del montaje.
    r.rerender(<ModalCompra {...r.props} lotes={lotes(60)} />)
    // Un refresco de la query con otros lotes no pisa lo precargado.
    r.rerender(<ModalCompra {...r.props} lotes={lotes(5)} />)
    await guardar(r.user)
    const input = enviado(r.onGuardarEdicion)
    expect(input.items[2].vencimientos).toEqual([{ fecha: '2027-03-01', cantidad: 60 }])
    // Las líneas sin lote viajan con [] y no sin el campo: la RPC recibe la
    // FOTO completa y el hook la llama aunque esté vacía.
    expect(input.items[0].vencimientos).toEqual([])
  })

  it('etiquetar más que la línea bloquea el guardado y dice cuánto', async () => {
    const { user, onGuardarEdicion } = renderEditar(undefined, { lotes: lotes(61) })
    await guardar(user)
    expect(onGuardarEdicion).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent(/"Gaseosa 3L": etiquetaste 61 u\..*la línea tiene 60/)
  })

  it('etiquetar menos es legal', async () => {
    const { user, onGuardarEdicion } = renderEditar(undefined, { lotes: lotes(10) })
    await guardar(user)
    expect(onGuardarEdicion).toHaveBeenCalledTimes(1)
  })
})

describe("ModalCompra 'editar' · \"Cambiar proveedor\"", () => {
  const boton = () => screen.getByRole('button', { name: /Cambiar proveedor/ })

  it('no está si no es admin', () => {
    renderEditar(undefined, { canCambiarProveedor: false })
    expect(screen.queryByRole('button', { name: /Cambiar proveedor/ })).toBeNull()
  })

  it('habilitado sin cambios (la precarga de vencimientos no cuenta) y abre el flujo', async () => {
    const { user, onCambiarProveedor } = renderEditar(undefined, { lotes: [{ producto_id: 503, fecha_vencimiento: '2027-03-01', cantidad: 60 }] })
    expect(boton()).toBeEnabled()
    await user.click(boton())
    expect(onCambiarProveedor).toHaveBeenCalled()
  })

  it('se traba al cambiar una línea', async () => {
    const { user } = renderEditar()
    await tipear(user, cantidadDe('160'), '161')
    expect(boton()).toBeDisabled()
  })

  it('se traba al cambiar un CARGO (el flujo clona la compra de la base)', async () => {
    const { user } = renderEditar()
    const flete = screen.getByDisplayValue('Flete')
    // Combobox del catálogo (mig 278): Enter confirma "+ Crear".
    await user.type(flete, 'Flete Andreani{Enter}')
    expect(boton()).toBeDisabled()
    expect(screen.getByText(/Guardá los cambios primero/)).toBeInTheDocument()
  })

  it('se traba al tocar un vencimiento', async () => {
    const { user } = renderEditar()
    expect(boton()).toBeEnabled()
    await user.click(screen.getAllByRole('button', { name: /Sin vencimiento/ })[0])
    expect(boton()).toBeDisabled()
  })

  it('una compra cancelada no lo ofrece', () => {
    renderEditar(compraTestigoEdicion({ estado: 'cancelada' as never }))
    expect(screen.queryByRole('button', { name: /Cambiar proveedor/ })).toBeNull()
  })
})
