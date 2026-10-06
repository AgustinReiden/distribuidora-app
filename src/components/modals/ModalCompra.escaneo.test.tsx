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
const invoke = vi.fn((_nombre: string, _opts: { body: { path: string } }) =>
  Promise.resolve({ data: null as unknown, error: null as unknown }))

vi.mock('../../lib/supabase', () => ({
  supabase: {
    storage: { from: vi.fn(() => ({ upload })) },
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

function renderModal(auth: AuthDataContextValue | null = AUTH) {
  const modal = (
    <ModalCompra productos={PRODUCTOS} proveedores={PROVEEDORES} onSave={vi.fn(() => Promise.resolve())} onClose={vi.fn()} sucursalId={3} />
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
