/**
 * ModalPedido en CELULAR: el alta de pedido como bottom sheet (WP-46, #771).
 *
 * El smoke (`ModalPedido.smoke.test.tsx`) corre sin ninguna noción de ancho, y
 * sin ancho el alta es el `ModalBase` de escritorio de siempre. Acá se fija el
 * ancho con un `matchMedia` controlable (375 px, un celular) y se asevera que el
 * sheet conserva lo que el smoke le exige al diálogo: el rol y el nombre, el
 * toggle FC/ZZ del header, el contrato ARIA del cajón del carrito, que tocar
 * afuera NO cierra, y el mismo pedido al confirmar. Más dos cosas propias del
 * sheet: el corte de 640 px y que cruzar el corte con el alta abierta no pierde
 * nada.
 *
 * El harness es copia del smoke (que lo copia de `PedidosContainer`): no se
 * importa de ahí porque importar un archivo de tests registra sus tests.
 */
import { useState } from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, screen, within } from '@testing-library/react'
import userEvent, { PointerEventsCheckLevel } from '@testing-library/user-event'

const { estadoMock } = vi.hoisted(() => ({
  estadoMock: {
    preventistasAsignables: [] as Array<{ id: string; nombre: string }>,
  },
}))

vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({
    politicas: {
      montoMinimoPedido: 0,
      comisionPctPreventista: 2,
      comisionPctOtros: 0,
      diasAlertaVencimiento: 60,
      diasCriticoVencimiento: 15,
      mostrarSinStock: true,
    },
  }),
}))

vi.mock('../../hooks/queries/useUsuariosQuery', () => ({
  usePreventistasAsignablesQuery: () => ({ data: estadoMock.preventistasAsignables }),
}))

const googleMapsCaido = {
  isLoaded: false,
  isLoading: false,
  error: 'Google Maps no se carga en tests',
  load: async (): Promise<void> => {},
}
vi.mock('../../hooks/useGoogleMaps', () => ({
  useGoogleMaps: () => googleMapsCaido,
  default: () => googleMapsCaido,
  loadGoogleMapsAPI: async (): Promise<void> => {},
}))

// Resolución de precios neutra, como en el smoke: el total es la suma cruda.
vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: (
    items: Array<{ productoId: string; cantidad: number; precioUnitario: number }>,
  ) => ({
    preciosResueltos: new Map(),
    faltantes: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set<string>() },
    faltantesBonificacion: [],
    itemsFinales: items,
    totalFinal: 0,
    totalOriginal: 0,
    ahorro: 0,
    hayDescuento: false,
    itemsConDescuentoCliente: items,
    totalConDescuentoCliente: 0,
    hayDescuentoCliente: false,
    hayDescuentoTotal: false,
    descuentoClientePct: new Map<string, number>(),
    descuentoPorCategoria: new Set<string>(),
    isLoading: false,
    moqMap: new Map<string, number>(),
    minimosProducto: undefined,
    violacionesMOQ: [],
  }),
}))

import ModalPedido, { type NuevoPedidoState } from './ModalPedido'
import { fechaLocalISO } from '../../utils/formatters'
import type { ClienteDB, ProductoDB } from '../../types'
import type { VeredictoDuplicadoRPC } from '../../utils/duplicadoCliente'

// ---------------------------------------------------------------------------
// Ancho de la ventana: un matchMedia que entiende `min-width` (y su negación con
// `not all and`), con listeners de `change` que se disparan al cambiar el ancho.
// No se mockea el hook: así también se prueba que el alta pregunta por el corte
// de 640 px y no por otro.
// ---------------------------------------------------------------------------

type Listener = (evento: { matches: boolean }) => void

let ancho = 375
let listas: Array<{ query: string; listeners: Set<Listener> }> = []
const matchMediaOriginal = window.matchMedia

function evaluar(query: string): boolean {
  const min = /\(min-width:\s*(\d+(?:\.\d+)?)px\)/.exec(query)
  const max = /\(max-width:\s*(\d+(?:\.\d+)?)px\)/.exec(query)
  const coincide = min ? ancho >= Number(min[1]) : max ? ancho <= Number(max[1]) : false
  return /^\s*not\s+all\s+and\s/.test(query) ? !coincide : coincide
}

function instalarMatchMedia(): void {
  window.matchMedia = vi.fn((query: string) => {
    const listeners = new Set<Listener>()
    listas.push({ query, listeners })
    return {
      get matches() {
        return evaluar(query)
      },
      media: query,
      onchange: null,
      addEventListener: (_tipo: string, l: Listener) => listeners.add(l),
      removeEventListener: (_tipo: string, l: Listener) => listeners.delete(l),
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    } as unknown as MediaQueryList
  }) as unknown as typeof window.matchMedia
}

/** Como girar el teléfono o achicar la ventana: avisa a cada MediaQueryList. */
function cambiarAncho(nuevo: number): void {
  ancho = nuevo
  act(() => {
    for (const { query, listeners } of listas) {
      for (const l of [...listeners]) l({ matches: evaluar(query) })
    }
  })
}

beforeEach(() => {
  ancho = 375
  listas = []
  estadoMock.preventistasAsignables = []
  instalarMatchMedia()
})

afterEach(() => {
  window.matchMedia = matchMediaOriginal
})

// ---------------------------------------------------------------------------
// Fixtures y harness (copia del smoke)
// ---------------------------------------------------------------------------

const PRODUCTOS: ProductoDB[] = [
  { id: '1', nombre: 'Gaseosa Cola 2L', precio: 1250, stock: 40, categoria: 'Bebidas' },
  { id: '2', nombre: 'Galletitas Surtidas', precio: 800, stock: 3, categoria: 'Almacen' },
]

const CLIENTES: ClienteDB[] = [
  {
    id: '10',
    nombre_fantasia: 'Kiosco El Sol',
    razon_social: 'El Sol SRL',
    direccion: 'San Martin 100',
    horarios_atencion: '08:00-18:00',
    tipo_factura_default: 'FC',
  },
]

interface HarnessProps {
  onGuardarSpy: (payload: NuevoPedidoState) => void
  onCloseSpy: () => void
  onCrearClienteSpy: (cliente: Record<string, unknown>) => void
  onActualizarPrecioSpy: (productoId: string, precio: number) => void
  onVerificarDuplicado?: (data: {
    direccion: string | null
    latitud: number | null
    longitud: number | null
  }) => Promise<VeredictoDuplicadoRPC>
}

function Harness({
  onGuardarSpy,
  onCloseSpy,
  onCrearClienteSpy,
  onActualizarPrecioSpy,
  onVerificarDuplicado,
}: HarnessProps) {
  const [clientes, setClientes] = useState<ClienteDB[]>(CLIENTES)
  const [pedido, setPedido] = useState<NuevoPedidoState>({
    clienteId: '',
    items: [],
    notas: '',
    formaPago: 'efectivo',
    estadoPago: 'pendiente',
    montoPagado: 0,
    fecha: fechaLocalISO(),
    tipoFactura: 'ZZ',
  })

  return (
    <ModalPedido
      productos={PRODUCTOS}
      clientes={clientes}
      categorias={['Bebidas', 'Almacen']}
      nuevoPedido={pedido}
      guardando={false}
      isAdmin
      currentUserId="u-1"
      onClose={onCloseSpy}
      onGuardar={() => onGuardarSpy(pedido)}
      onClienteChange={(clienteId) =>
        setPedido(prev => ({
          ...prev,
          clienteId,
          tipoFactura:
            clientes.find(c => String(c.id) === String(clienteId))?.tipo_factura_default ?? 'ZZ',
        }))
      }
      onAgregarItem={(productoId, cantidad = 1, precio) => {
        setPedido(prev => {
          const existe = prev.items.find(i => i.productoId === productoId)
          if (existe) {
            return {
              ...prev,
              items: prev.items.map(i =>
                i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i,
              ),
            }
          }
          const producto = PRODUCTOS.find(p => p.id === productoId)
          return {
            ...prev,
            items: [
              ...prev.items,
              { productoId, cantidad, precioUnitario: precio ?? producto?.precio ?? 0 },
            ],
          }
        })
      }}
      onActualizarCantidad={(productoId, cantidad) => {
        setPedido(prev =>
          cantidad <= 0
            ? { ...prev, items: prev.items.filter(i => i.productoId !== productoId) }
            : {
                ...prev,
                items: prev.items.map(i => (i.productoId === productoId ? { ...i, cantidad } : i)),
              },
        )
      }}
      onActualizarPrecio={(productoId, precio) => {
        onActualizarPrecioSpy(productoId, precio)
        setPedido(prev => ({
          ...prev,
          items: prev.items.map(i =>
            i.productoId === productoId ? { ...i, precioUnitario: precio, precioOverride: true } : i,
          ),
        }))
      }}
      onCrearCliente={async (clienteData) => {
        onCrearClienteSpy(clienteData)
        const creado: ClienteDB = {
          id: '99',
          nombre_fantasia: String(clienteData.nombreFantasia ?? ''),
          razon_social: String(clienteData.razonSocial ?? ''),
          direccion: String(clienteData.direccion ?? ''),
          horarios_atencion: String(clienteData.horariosAtencion ?? ''),
        }
        setClientes(prev => [...prev, creado])
        return { id: '99' }
      }}
      onVerificarDuplicado={onVerificarDuplicado}
      onNotasChange={(notas) => setPedido(prev => ({ ...prev, notas }))}
      onFormaPagoChange={(formaPago) => setPedido(prev => ({ ...prev, formaPago }))}
      onEstadoPagoChange={(estadoPago) => setPedido(prev => ({ ...prev, estadoPago }))}
      onTipoFacturaChange={(tipoFactura) => setPedido(prev => ({ ...prev, tipoFactura }))}
      onPreventistaChange={(preventistaId) => setPedido(prev => ({ ...prev, preventistaId }))}
    />
  )
}

function montar(
  props: Partial<Pick<HarnessProps, 'onVerificarDuplicado'>> = {},
  opciones: { permitirClickAfuera?: boolean } = {},
) {
  const onGuardarSpy = vi.fn()
  const onCloseSpy = vi.fn()
  const onCrearClienteSpy = vi.fn()
  const onActualizarPrecioSpy = vi.fn()
  const user = userEvent.setup(
    opciones.permitirClickAfuera ? { pointerEventsCheck: PointerEventsCheckLevel.Never } : {},
  )
  const utils = render(
    <Harness
      onGuardarSpy={onGuardarSpy}
      onCloseSpy={onCloseSpy}
      onCrearClienteSpy={onCrearClienteSpy}
      onActualizarPrecioSpy={onActualizarPrecioSpy}
      {...props}
    />,
  )
  return { user, onGuardarSpy, onCloseSpy, onCrearClienteSpy, onActualizarPrecioSpy, ...utils }
}

const dialogo = () => screen.getByRole('dialog', { name: 'Nuevo Pedido' })
/** El sheet se marca con `data-slot="bottom-sheet"`; ModalBase no lo tiene. */
const esSheet = () => dialogo().getAttribute('data-slot') === 'bottom-sheet'
const botonCarrito = () => screen.getByRole('button', { name: /unidad|unidades|sin productos/i })
const botonConfirmar = () => screen.getByRole('button', { name: 'Confirmar' })

async function elegirCliente(user: ReturnType<typeof userEvent.setup>, nombre: string) {
  await user.type(screen.getByPlaceholderText(/buscar por nombre/i), nombre)
  await user.click(await screen.findByRole('option', { name: new RegExp(nombre, 'i') }))
}

async function agregarProducto(user: ReturnType<typeof userEvent.setup>, busqueda: string) {
  const buscador = screen.getByPlaceholderText(/buscar producto/i)
  await user.clear(buscador)
  await user.type(buscador, busqueda)
  await user.click(screen.getByText('+ Agregar'))
}

/** El flujo del camino feliz del smoke, sin aserciones: deja el pedido listo. */
async function armarPedido(user: ReturnType<typeof userEvent.setup>) {
  await elegirCliente(user, 'Kiosco El Sol')
  await agregarProducto(user, 'Gaseosa')
  await user.click(botonCarrito())
  const cantidad = screen.getByRole('textbox', { name: 'Cantidad' })
  await user.clear(cantidad)
  await user.type(cantidad, '6')
  await user.keyboard('{Enter}')
  await user.selectOptions(screen.getByDisplayValue('Efectivo'), 'transferencia')
  await user.type(screen.getByPlaceholderText(/observaciones/i), 'Dejar en el depósito')
}

// ---------------------------------------------------------------------------

describe('ModalPedido en celular — el envoltorio', () => {
  it('a 375 px abre como bottom sheet, con rol de diálogo modal y el nombre "Nuevo Pedido"', () => {
    montar()

    expect(dialogo()).toBeInTheDocument()
    expect(esSheet()).toBe(true)
    expect(dialogo()).toHaveAttribute('aria-modal', 'true')
    // Lo mismo que el smoke le pide al diálogo al abrir.
    expect(screen.getByText('Gaseosa Cola 2L')).toBeInTheDocument()
    expect(botonConfirmar()).toBeDisabled()
  })

  it('el corte es 640 px: a 639 es sheet, a 640 es el diálogo de escritorio', () => {
    ancho = 639
    const { unmount } = montar()
    expect(esSheet()).toBe(true)
    unmount()

    ancho = 640
    montar()
    expect(esSheet()).toBe(false)
    expect(dialogo()).toHaveAttribute('aria-modal', 'true')
  })

  it('el toggle FC/ZZ está en el header del sheet y funciona', async () => {
    const { user, onGuardarSpy } = montar()

    // En el header: al lado del título, no dentro del cuerpo que scrollea.
    const titulo = within(dialogo()).getByRole('heading', { name: 'Nuevo Pedido' })
    const toggle = screen.getByRole('combobox', { name: 'Tipo de factura' })
    expect(titulo.parentElement?.parentElement).toContainElement(toggle)
    expect(toggle).toHaveValue('ZZ')

    await elegirCliente(user, 'Kiosco El Sol')
    expect(toggle).toHaveValue('FC')

    await user.selectOptions(toggle, 'ZZ')
    await agregarProducto(user, 'Gaseosa')
    await user.click(botonConfirmar())

    expect(onGuardarSpy).toHaveBeenCalledWith(expect.objectContaining({ tipoFactura: 'ZZ' }))
  })

  it('el cajón del carrito conserva su contrato: aria-expanded, aria-controls y aria-hidden', async () => {
    const { user } = montar()

    await agregarProducto(user, 'Gaseosa')
    const cajon = document.getElementById('carrito-drawer')
    expect(cajon).not.toBeNull()
    expect(dialogo()).toContainElement(cajon)
    expect(botonCarrito()).toHaveAttribute('aria-controls', 'carrito-drawer')
    expect(botonCarrito()).toHaveAttribute('aria-expanded', 'false')
    expect(cajon).toHaveAttribute('aria-hidden', 'true')
    expect(screen.queryByRole('heading', { name: /productos en el pedido/i })).not.toBeInTheDocument()

    await user.click(botonCarrito())
    expect(botonCarrito()).toHaveAttribute('aria-expanded', 'true')
    expect(cajon).toHaveAttribute('aria-hidden', 'false')
    expect(screen.getByRole('heading', { name: 'Productos en el pedido (1)' })).toBeInTheDocument()

    await user.click(botonCarrito())
    expect(botonCarrito()).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('heading', { name: /productos en el pedido/i })).not.toBeInTheDocument()
  })

  it('tocar el overlay NO cierra: el carrito armado no se tira por un toque al costado', async () => {
    const { user, onCloseSpy } = montar({}, { permitirClickAfuera: true })

    await agregarProducto(user, 'Gaseosa')

    // El overlay del sheet es el hermano anterior del panel, como en el test
    // de ModalFiltrosPedidos que prueba lo contrario (que ahí SÍ cierra).
    const overlay = dialogo().previousElementSibling
    expect(overlay).toBeInstanceOf(HTMLElement)
    await user.click(overlay as HTMLElement)

    expect(onCloseSpy).not.toHaveBeenCalled()
    expect(dialogo()).toBeInTheDocument()
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)
  })

  it('Escape y la X siguen cerrando', async () => {
    const { user, onCloseSpy } = montar()

    await user.keyboard('{Escape}')
    expect(onCloseSpy).toHaveBeenCalledTimes(1)

    await user.click(within(dialogo()).getByRole('button', { name: 'Cerrar' }))
    expect(onCloseSpy).toHaveBeenCalledTimes(2)
  })
})

describe('ModalPedido en celular — Escape en la edición de precio (#853)', () => {
  it('cancela sólo la edición: el sheet sigue abierto y, ya cancelada, Escape vuelve a cerrarlo', async () => {
    const { user, onCloseSpy, onActualizarPrecioSpy } = montar()
    expect(esSheet()).toBe(true)

    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())
    await user.click(screen.getByText(/1\.250,00 c\/u/))
    const input = screen.getByRole('spinbutton')
    await user.clear(input)
    await user.type(input, '1')
    await user.keyboard('{Escape}')

    // El pedido a medio armar sigue ahí y el precio no cambió.
    expect(onActualizarPrecioSpy).not.toHaveBeenCalled()
    expect(onCloseSpy).not.toHaveBeenCalled()
    expect(dialogo()).toBeInTheDocument()
    expect(screen.queryByRole('spinbutton')).not.toBeInTheDocument()
    expect(screen.getByText(/1\.250,00 c\/u/)).toBeInTheDocument()
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)

    // Sin edición en curso, Escape cierra el sheet como siempre.
    await user.keyboard('{Escape}')
    expect(onCloseSpy).toHaveBeenCalledTimes(1)
  })
})

describe('ModalPedido en celular — confirmar', () => {
  it('sin cliente el Confirmar está apagado (#732), y elegirlo lo habilita', async () => {
    const { user, onGuardarSpy } = montar()

    await agregarProducto(user, 'Gaseosa')
    expect(botonConfirmar()).toBeDisabled()
    await user.click(botonConfirmar())
    expect(onGuardarSpy).not.toHaveBeenCalled()

    await elegirCliente(user, 'Kiosco El Sol')
    expect(botonConfirmar()).toBeEnabled()
  })

  it('el mismo armado confirma el MISMO pedido en el sheet que en el diálogo de escritorio', async () => {
    const enCelular = montar()
    expect(esSheet()).toBe(true)
    await armarPedido(enCelular.user)
    await enCelular.user.click(botonConfirmar())
    expect(enCelular.onGuardarSpy).toHaveBeenCalledTimes(1)
    const pedidoCelular = enCelular.onGuardarSpy.mock.calls[0][0]
    enCelular.unmount()

    ancho = 1280
    const enEscritorio = montar()
    expect(esSheet()).toBe(false)
    await armarPedido(enEscritorio.user)
    await enEscritorio.user.click(botonConfirmar())
    expect(enEscritorio.onGuardarSpy).toHaveBeenCalledTimes(1)
    const pedidoEscritorio = enEscritorio.onGuardarSpy.mock.calls[0][0]

    expect(pedidoCelular).toEqual(pedidoEscritorio)
    expect(pedidoCelular).toEqual(
      expect.objectContaining({
        clienteId: '10',
        items: [expect.objectContaining({ productoId: '1', cantidad: 6, precioUnitario: 1250 })],
        tipoFactura: 'FC',
        formaPago: 'transferencia',
        notas: 'Dejar en el depósito',
      }),
    )
  })
})

describe('ModalPedido en celular — cruzar el corte con el alta abierta', () => {
  it('girar el teléfono no cambia el envoltorio ni pierde el pedido ni lo tipeado', async () => {
    const { user, onGuardarSpy } = montar()

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')
    // Estado que vive DENTRO del modal (no en el container): una búsqueda de
    // producto tipeada y el cajón abierto.
    const buscador = screen.getByPlaceholderText(/buscar producto/i)
    await user.clear(buscador)
    await user.type(buscador, 'Gal')
    await user.click(botonCarrito())
    const antes = dialogo()

    cambiarAncho(812) // apaisado: ya es "escritorio" para el corte de 640

    expect(dialogo()).toBe(antes)
    expect(esSheet()).toBe(true)
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)
    expect(botonCarrito()).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByPlaceholderText(/buscar producto/i)).toHaveValue('Gal')
    expect(screen.getByText('San Martin 100')).toBeInTheDocument()

    await user.click(botonConfirmar())
    expect(onGuardarSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        clienteId: '10',
        items: [expect.objectContaining({ productoId: '1', cantidad: 1 })],
      }),
    )
  })

  it('al revés también: abierto en escritorio, achicar la ventana no lo pasa a sheet', async () => {
    ancho = 1280
    const { user } = montar()
    await agregarProducto(user, 'Gaseosa')
    const antes = dialogo()

    cambiarAncho(375)

    expect(dialogo()).toBe(antes)
    expect(esSheet()).toBe(false)
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)
  })
})

describe('ModalPedido en celular — alta rápida de cliente', () => {
  it('el aviso de duplicado se confirma desde el sheet y deja el cliente elegido', async () => {
    const veredictoAvisa: VeredictoDuplicadoRPC = {
      bloquea: false,
      avisa: true,
      motivo: 'distancia',
      distancia_m: 15.6,
      cliente_visible: { id: 5, codigo: 5, nombre: 'Fulano', activo: true },
    }
    const onVerificarDuplicado = vi.fn().mockResolvedValue(veredictoAvisa)
    const { user, onCrearClienteSpy } = montar({ onVerificarDuplicado })
    expect(esSheet()).toBe(true)

    await user.click(screen.getByRole('button', { name: '+ Nuevo' }))
    await user.type(screen.getByPlaceholderText('Nombre fantasia *'), 'Despensa Nueva')
    await user.type(screen.getByPlaceholderText('Nombre completo *'), 'Nueva SRL')
    await user.type(screen.getByPlaceholderText('Escribí la dirección...'), 'Avellaneda 55')
    await user.click(screen.getByRole('button', { name: 'Crear y seleccionar' }))

    expect(await screen.findByText(/está a 15,6 m/)).toBeInTheDocument()
    expect(onCrearClienteSpy).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Sí, es otro comercio: crear igual' }))

    expect(onCrearClienteSpy).toHaveBeenCalledTimes(1)
    expect(onCrearClienteSpy).toHaveBeenCalledWith(
      expect.objectContaining({ nombreFantasia: 'Despensa Nueva', duplicadoConfirmado: true }),
    )
    // Queda elegido después del await de onCrearCliente, fuera del act() del
    // clic: hay que esperar el render (#1006).
    expect(await screen.findByText('Despensa Nueva')).toBeInTheDocument()

    // Con el cliente recién creado elegido, el Confirmar ya no lo frena #732.
    await agregarProducto(user, 'Gaseosa')
    expect(botonConfirmar()).toBeEnabled()
  })
})
