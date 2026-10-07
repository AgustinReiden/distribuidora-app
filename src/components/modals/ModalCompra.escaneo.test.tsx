/**
 * Escáner de facturas, Entrega A: el schema de la respuesta de la edge function
 * y el cableado en el modal (subida namespaced por sucursal → functions.invoke
 * → vista previa con advertencias → APLICAR_ESCANEO).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB, ProveedorDBExtended } from '../../types'

const upload = vi.fn((_path: string, _file: File, _opts?: unknown) => Promise.resolve({ data: { path: _path }, error: null }))
const createSignedUrl = vi.fn((ruta: string, _segundos: number) =>
  Promise.resolve({ data: { signedUrl: `https://firmada.test/${ruta}?token=x` }, error: null }))
const invoke = vi.fn((_nombre: string, _opts: { body: { path: string } }) =>
  Promise.resolve({ data: null as unknown, error: null as unknown }))

vi.mock('../../lib/supabase', () => ({
  supabase: {
    storage: { from: vi.fn(() => ({ upload, createSignedUrl })) },
    functions: { invoke: (nombre: string, opts: { body: { path: string } }) => invoke(nombre, opts) },
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => 3),
}))

vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: () => ({ data: null, isLoading: false }),
  useCostosAnterioresQuery: () => ({ data: undefined }),
  useComprasMismaFacturaQuery: () => ({ data: [] }),
}))
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  const conceptos: unknown[] = [], medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: conceptos }),
    useCargoMedidasQuery: () => ({ data: medidas }),
    useProductoMedidasQuery: () => ({ data: ficha }),
  }
})
// Escáner B (mig 292): la vista previa pide las equivalencias y lo ya comprado
// al proveedor. Acá, sin nada aprendido: el matcher trabaja con el catálogo solo.
vi.mock('../../hooks/queries/useEscaneoQuery', () => {
  const CANDIDATOS_VACIOS = { equivalencias: [], comprados: [] }
  return {
    CANDIDATOS_VACIOS,
    useCandidatosEscaneoQuery: () => ({ data: CANDIDATOS_VACIOS, isLoading: false }),
    useRegistrarEquivalenciasMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
    guardarEquivalenciasDeCompra: vi.fn().mockResolvedValue(null),
  }
})
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('./ModalProveedor', () => ({ default: () => null }))
vi.mock('./ModalImportarCompra', () => ({ default: () => null }))

import ModalCompra from './ModalCompra'
import { RespuestaEscaneoSchema } from './ModalCompra.escaneo'
import { AuthDataProvider, type AuthDataContextValue } from '../../contexts/AuthDataContext'

const PRODUCTOS = [
  { id: 'p1', nombre: 'Manaos Cola 3L', codigo: 'MC3000', stock: 12, costo_sin_iva: 900, impuestos_internos: 8.6956, porcentaje_iva: 21, condicion_iva: 'gravado' },
] as unknown as ProductoDB[]
const PROVEEDORES = [
  { id: 'prov-1', nombre: 'Refres Now SA', cuit: '30-71234567-1' },
] as unknown as ProveedorDBExtended[]

function respuestaOk() {
  return {
    success: true,
    modelo: 'gemini-test',
    advertencias: [
      { nivel: 'aviso', codigo: 'LINEA_ILEGIBLE', linea: 2, mensaje: 'La línea 2 no se leyó con claridad: comparala con el papel.' },
      { nivel: 'error', codigo: 'TOTAL_NO_CUADRA', mensaje: 'Neto + IVA da $12.045,25, pero el total leído es $13.045,25.' },
    ],
    data: {
      version: 2,
      tipoComprobante: 'A',
      tipoFactura: 'FC',
      puntoVenta: '0005',
      numero: '00455160',
      numeroCompleto: '0005-00455160',
      fechaEmision: '2026-09-30',
      proveedor: { nombre: 'Refres Now SA', cuit: '30-71234567-1' },
      condicionVenta: 'Contado',
      items: [
        { codigo: 'MC3000', descripcion: 'Manaos Cola 3L', cantidad: 10, unidad: 'bulto', unidadesPorBulto: 6, precioUnitarioNeto: 1000, bonificacionPct: 10, importeNeto: 9000, alicuotaIva: 21, impuestoInternoMonto: null, legible: true },
        { codigo: null, descripcion: 'PRODUCTO DESCONOCIDO', cantidad: 2, unidad: null, unidadesPorBulto: null, precioUnitarioNeto: 50, bonificacionPct: 0, importeNeto: 100, alicuotaIva: 21, impuestoInternoMonto: null, legible: false },
      ],
      pie: {
        netoGravado: 9100, noGravado: null, exento: null,
        iva: [{ alicuota: 21, monto: 1911 }],
        impuestosInternos: [], percepcionIva: null, percepcionIibb: null, otrosTributos: null,
        descuentosPie: [], total: 13045.25,
      },
      confianza: 0.9,
    },
  }
}

const AUTH = { isAdminOrEncargado: true } as AuthDataContextValue

function renderModal(
  auth: AuthDataContextValue | null = AUTH,
  { productos = PRODUCTOS, onSave = vi.fn(() => Promise.resolve()) }: { productos?: ProductoDB[]; onSave?: (...args: unknown[]) => Promise<void> } = {},
) {
  const modal = (
    <ModalCompra productos={productos} proveedores={PROVEEDORES} onSave={onSave} onClose={vi.fn()} sucursalId={3} />
  )
  render(auth ? <AuthDataProvider value={auth}>{modal}</AuthDataProvider> : modal)
  return userEvent.setup()
}

function inputArchivo(): HTMLInputElement {
  const input = document.querySelector('input[type="file"]')
  if (!(input instanceof HTMLInputElement)) throw new Error('no hay input de archivo')
  return input
}

beforeEach(() => {
  upload.mockClear()
  invoke.mockReset()
  window.localStorage.clear()
})

describe('RespuestaEscaneoSchema', () => {
  it('acepta la respuesta v2 de la edge function', () => {
    expect(RespuestaEscaneoSchema.safeParse(respuestaOk()).success).toBe(true)
  })

  it('acepta el error con mensaje', () => {
    const r = RespuestaEscaneoSchema.safeParse({ success: false, error: 'Escanear facturas es sólo para admin o encargado.' })
    expect(r.success).toBe(true)
  })

  it('rechaza la forma vieja de n8n (sin version ni pie)', () => {
    const vieja = {
      success: true,
      data: { proveedorNombre: 'X', items: [{ descripcion: 'a', cantidad: 1, costoUnitario: 1, bonificacion: 0, iva: 21 }], confianza: 1 },
    }
    expect(RespuestaEscaneoSchema.safeParse(vieja).success).toBe(false)
  })

  it('rechaza números como texto, fecha no ISO y confianza fuera de rango', () => {
    const conTexto = respuestaOk()
    ;(conTexto.data.items[0] as Record<string, unknown>).cantidad = '10'
    expect(RespuestaEscaneoSchema.safeParse(conTexto).success).toBe(false)
    const fecha = respuestaOk()
    fecha.data.fechaEmision = '30/09/2026'
    expect(RespuestaEscaneoSchema.safeParse(fecha).success).toBe(false)
    const conf = respuestaOk()
    conf.data.confianza = 93
    expect(RespuestaEscaneoSchema.safeParse(conf).success).toBe(false)
  })
})

describe('escaneo en el modal', () => {
  it('sin admin/encargado no aparece el botón', () => {
    renderModal({ isAdminOrEncargado: false } as AuthDataContextValue)
    expect(screen.queryByRole('button', { name: 'Escanear Factura' })).toBeNull()
  })

  it('sube a <sucursal>/<uuid>.pdf, llama a la edge function y muestra las advertencias', async () => {
    invoke.mockResolvedValueOnce({ data: respuestaOk(), error: null })
    const user = renderModal()
    expect(screen.getByRole('button', { name: 'Escanear Factura' })).toBeInTheDocument()
    expect(inputArchivo().accept).toBe('image/*,application/pdf')

    await user.upload(inputArchivo(), new File(['%PDF-1.7'], 'factura.pdf', { type: 'application/pdf' }))

    expect(await screen.findByText('Factura escaneada')).toBeInTheDocument()
    expect(upload).toHaveBeenCalledTimes(1)
    const [path, , opts] = upload.mock.calls[0]
    expect(path).toMatch(/^3\/[0-9a-f-]{36}\.pdf$/)
    expect(opts).toEqual({ contentType: 'application/pdf' })
    expect(invoke).toHaveBeenCalledWith('escanear-factura', { body: { path } })

    const lista = screen.getByRole('list', { name: 'Advertencias del escaneo' })
    const items = within(lista).getAllByRole('listitem').map(li => li.textContent)
    // Los errores primero.
    expect(items[0]).toMatch(/total leído es \$13\.045,25/)
    expect(items[1]).toMatch(/línea 2 no se leyó/)
    expect(screen.getByText(/se carga como FC/)).toBeInTheDocument()
  })

  it('"Aplicar datos" vincula por código, deja el resto pendiente y prellena el control', async () => {
    invoke.mockResolvedValueOnce({ data: respuestaOk(), error: null })
    const user = renderModal()
    await user.upload(inputArchivo(), new File(['x'], 'foto.jpg', { type: 'image/jpeg' }))
    await user.click(await screen.findByRole('button', { name: 'Aplicar datos' }))

    await waitFor(() => expect(screen.queryByText('Factura escaneada')).toBeNull())
    expect(screen.getByPlaceholderText('Ej: 0001-00012345')).toHaveValue('0005-00455160')
    // El ítem no vinculado queda para revisión humana.
    expect(screen.getByText('PRODUCTO DESCONOCIDO')).toBeInTheDocument()
  })

  /**
   * "Aprieto 'Aplicar datos' y en esa vista previa no me deja scrollear". jsdom
   * no mide, así que se fija la cadena de clases que hace que el scroll exista:
   * la caja del diálogo con alto tope, la columna con `min-h-0`, lo fijo con
   * tope propio y la tabla de revisión ADENTRO del único `overflow-y-auto`.
   */
  it('lo fijo arriba tiene tope y la revisión queda dentro del área que scrollea', async () => {
    invoke.mockResolvedValueOnce({ data: respuestaOk(), error: null })
    const user = renderModal()
    await user.upload(inputArchivo(), new File(['x'], 'foto.jpg', { type: 'image/jpeg' }))

    const dialogo = screen.getByRole('dialog')
    expect(dialogo).toHaveClass('flex', 'flex-col', 'max-h-[90vh]', 'overflow-hidden')
    // La columna del modal: hija directa de la de ModalBase, las dos con min-h-0.
    const area = dialogo.querySelector('.flex-1.overflow-y-auto') as HTMLElement
    const columna = area.parentElement!
    expect(columna).toHaveClass('flex', 'flex-1', 'min-h-0', 'flex-col')
    expect(columna.parentElement).toHaveClass('flex', 'flex-1', 'min-h-0', 'flex-col')

    // La vista previa (antes de aplicar) es fija pero no puede comerse el área.
    const preview = screen.getByText('Factura escaneada').closest('.max-h-\\[45vh\\]') as HTMLElement
    expect(preview).toHaveClass('overflow-y-auto', 'flex-shrink-0')
    expect(preview.parentElement).toBe(columna)
    expect(area).not.toContainElement(preview)

    await user.click(screen.getByRole('button', { name: 'Aplicar datos' }))
    const tabla = await screen.findByRole('table', { name: 'Líneas de la factura' })
    // Después de aplicar, la revisión (que en el bundle viejo era un panel fijo
    // sin tope) vive dentro del área que scrollea, y nada en el medio la recorta.
    expect(area).toContainElement(tabla)
    for (let el = tabla.parentElement; el && el !== area; el = el.parentElement) {
      expect(el.className).not.toMatch(/\boverflow-hidden\b|(^|\s)h-\[|(^|\s)max-h-/)
    }
  })

  it('un error de la función muestra el mensaje en castellano del body', async () => {
    const context = new Response(JSON.stringify({ success: false, error: 'El archivo no pertenece a tu sucursal activa.' }), { status: 403 })
    invoke.mockResolvedValueOnce({ data: null, error: Object.assign(new Error('Edge Function returned a non-2xx status code'), { context }) })
    const user = renderModal()
    await user.upload(inputArchivo(), new File(['x'], 'foto.png', { type: 'image/png' }))
    expect(await screen.findByText('El archivo no pertenece a tu sucursal activa.')).toBeInTheDocument()
  })

  it('una respuesta con forma inesperada no llega a la vista previa', async () => {
    invoke.mockResolvedValueOnce({ data: { success: true, data: { proveedorNombre: 'X' } }, error: null })
    const user = renderModal()
    await user.upload(inputArchivo(), new File(['x'], 'foto.png', { type: 'image/png' }))
    expect(await screen.findByText(/no tiene el formato esperado/)).toBeInTheDocument()
    expect(screen.queryByText('Factura escaneada')).toBeNull()
  })

  it('un formato no soportado no se sube', async () => {
    const user = userEvent.setup({ applyAccept: false })
    renderModal()
    await user.upload(inputArchivo(), new File(['x'], 'planilla.xlsx', { type: 'application/vnd.ms-excel' }))
    expect(await screen.findByText(/Formato no soportado/)).toBeInTheDocument()
    expect(upload).not.toHaveBeenCalled()
    expect(invoke).not.toHaveBeenCalled()
  })
})

/**
 * Entrega C: la pantalla de revisión rápida. Una tabla con cada renglón de la
 * factura, su estado, el producto elegido y el teclado para resolverla en un
 * minuto.
 */
describe('revisión rápida de la factura escaneada', () => {
  const CATALOGO = [
    ...PRODUCTOS,
    { id: 'p2', nombre: 'Agua Villamanaos Sin Gas 600 cc x 12', codigo: 'AV600', stock: 0, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
    { id: 'p3', nombre: 'Manaos Naranja 3L', codigo: 'MN3000', stock: 0, impuestos_internos: 8.6956, porcentaje_iva: 21, condicion_iva: 'gravado' },
  ] as unknown as ProductoDB[]

  /** Cuatro renglones: uno por código (vinculado), dos parecidos (sugeridos) y uno desconocido. */
  function respuestaCuatroLineas() {
    const r = respuestaOk()
    const base = r.data.items[0]
    ;(r.data as { items: unknown[] }).items = [
      base,
      { ...base, codigo: null, descripcion: 'AGUA VILLAMANAOS SIN GAS 600CC X12', cantidad: 2, unidad: 'bulto', unidadesPorBulto: 12, precioUnitarioNeto: 6000, bonificacionPct: 0, importeNeto: 12000 },
      { ...r.data.items[1] },
      { ...base, codigo: null, descripcion: 'NARANJA MANAOS 3 LITROS', cantidad: 4, unidad: null, unidadesPorBulto: null, precioUnitarioNeto: 900, bonificacionPct: 0, importeNeto: 3600 },
    ]
    return r
  }

  async function escanearYAplicar(onSave?: (...args: unknown[]) => Promise<void>) {
    invoke.mockResolvedValueOnce({ data: respuestaCuatroLineas(), error: null })
    const user = renderModal(AUTH, { productos: CATALOGO, onSave })
    await user.upload(inputArchivo(), new File(['x'], 'foto.jpg', { type: 'image/jpeg' }))
    await user.click(await screen.findByRole('button', { name: 'Aplicar datos' }))
    await screen.findByRole('table', { name: 'Líneas de la factura' })
    return user
  }

  const fila = (n: number) => screen.getByRole('row', { name: new RegExp(`^Línea ${n}:`) })
  const registrar = () => screen.getByRole('button', { name: /Registrar Compra/ })
  const aviso = () => screen.queryByText(/Faltan resolver/, { selector: 'p[role="status"]' })

  it('muestra las tres situaciones: vinculado, sugerido con su porcentaje y sin coincidencia', async () => {
    await escanearYAplicar()
    expect(within(fila(1)).getByText('✓ vinculado')).toBeInTheDocument()
    expect(within(fila(2)).getByText('? sugerido 85%')).toBeInTheDocument()
    expect(within(fila(3)).getByText('✗ sin coincidencia')).toBeInTheDocument()
    expect(within(fila(4)).getByText(/\? sugerido 8\d%/)).toBeInTheDocument()
    expect(within(fila(1)).getByText('MC3000')).toBeInTheDocument()
    // La advertencia que apunta a la línea 2 de la factura va en su renglón.
    expect(within(fila(2)).getByText(/línea 2 no se leyó/)).toBeInTheDocument()
    // La de la factura entera, arriba de la tabla.
    expect(within(screen.getByRole('list', { name: 'Advertencias de la factura' })).getByText(/total leído/)).toBeInTheDocument()
    expect(aviso()).toHaveTextContent('Faltan resolver 3 líneas')
  })

  it('Enter acepta la sugerencia y salta a la próxima pendiente; las flechas mueven entre filas', async () => {
    const user = await escanearYAplicar()
    fila(2).focus()
    await user.keyboard('{Enter}')
    expect(within(fila(2)).getByText('✓ vinculado')).toBeInTheDocument()
    await waitFor(() => expect(fila(3)).toHaveFocus())
    await user.keyboard('{ArrowDown}')
    expect(fila(4)).toHaveFocus()
    await user.keyboard('{ArrowUp}{ArrowUp}')
    expect(fila(2)).toHaveFocus()
  })

  it('"Aceptar todas las sugeridas ≥ 85%" pide confirmación adentro del modal', async () => {
    const user = await escanearYAplicar()
    await user.click(screen.getByRole('button', { name: 'Aceptar todas las sugeridas ≥ 85% (1)' }))
    const confirmacion = screen.getByRole('alertdialog', { name: 'Aceptar sugeridas' })
    // Adentro del diálogo de la compra: un hermano afuera quedaría detrás del overlay.
    expect(screen.getByRole('dialog', { name: 'Nueva Compra' })).toContainElement(confirmacion)
    await user.click(within(confirmacion).getByRole('button', { name: 'Sí, aceptar 1' }))
    expect(within(fila(2)).getByText('✓ vinculado')).toBeInTheDocument()
    // La de menos de 85% sigue esperando.
    expect(within(fila(4)).getByText(/\? sugerido/)).toBeInTheDocument()
  })

  it('con líneas sin resolver no se puede registrar; omitir cuenta como resuelta', async () => {
    const user = await escanearYAplicar()
    expect(registrar()).toBeDisabled()
    fila(2).focus()
    await user.keyboard('{Enter}')
    await user.click(screen.getByRole('button', { name: 'Omitir la línea 3' }))
    expect(aviso()).toHaveTextContent('Faltan resolver 1 línea de la factura')
    expect(registrar()).toBeDisabled()
    await user.click(screen.getByRole('button', { name: 'Omitir la línea 4' }))
    expect(aviso()).toBeNull()
    expect(registrar()).toBeEnabled()
  })

  it('el buscador de la fila ordena con el matcher, y al guardar se mandan las equivalencias con la conversión confirmada', async () => {
    const onSave = vi.fn((..._args: unknown[]) => Promise.resolve())
    const user = await escanearYAplicar(onSave)
    // Línea 2: aceptar y confirmar que el bulto trae 12 (lo ofrece la factura).
    fila(2).focus()
    await user.keyboard('{Enter}')
    await user.click(within(fila(2)).getByRole('button', { name: 'Convertir a unidades: 12 por bulto' }))
    expect(within(fila(2)).getByText('2 bultos × 12 = 24 u')).toBeInTheDocument()
    // Línea 3: B abre el buscador; "naranja" trae la Naranja aunque el nombre no empiece así.
    fila(3).focus()
    await user.keyboard('b')
    const buscador = screen.getByRole('combobox', { name: 'Producto de la línea 3' })
    expect(buscador).toHaveFocus()
    await user.keyboard('naranja')
    await user.keyboard('{Enter}')
    expect(within(fila(3)).getByText('✓ vinculado')).toBeInTheDocument()
    // Línea 4: también es la Naranja → las dos se van a sumar.
    fila(4).focus()
    await user.keyboard('{Enter}')
    expect(screen.getAllByText(/Se van a sumar con la línea/)).toHaveLength(2)

    await user.click(registrar())
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const payload = onSave.mock.calls[0][0] as {
      equivalenciasEscaneo: unknown[];
      items: Array<{ productoId: string; cantidad: number; costoUnitario: number }>;
    }
    expect(payload.equivalenciasEscaneo).toEqual([
      { producto_id: 'p1', codigo_proveedor: 'MC3000', descripcion: 'Manaos Cola 3L' },
      { producto_id: 'p2', codigo_proveedor: null, descripcion: 'AGUA VILLAMANAOS SIN GAS 600CC X12', unidades_por_bulto: 12 },
      { producto_id: 'p3', codigo_proveedor: null, descripcion: 'PRODUCTO DESCONOCIDO' },
      { producto_id: 'p3', codigo_proveedor: null, descripcion: 'NARANJA MANAOS 3 LITROS' },
    ])
    expect(payload.items.map(i => [i.productoId, i.cantidad, i.costoUnitario])).toEqual([
      ['p1', 10, 1000], ['p2', 24, 500], ['p3', 6, 50],
    ])
  })

  it('"Ver factura" la abre al lado con una URL firmada corta', async () => {
    const user = await escanearYAplicar()
    await user.click(screen.getByRole('button', { name: 'Ver factura' }))
    const img = await screen.findByRole('img', { name: 'Factura escaneada' })
    const [ruta, segundos] = createSignedUrl.mock.calls[0]
    expect(ruta).toMatch(/^3\/[0-9a-f-]{36}\.jpg$/)
    expect(segundos).toBeLessThanOrEqual(600)
    expect(img).toHaveAttribute('src', expect.stringContaining('https://firmada.test/3/'))
  })
})
