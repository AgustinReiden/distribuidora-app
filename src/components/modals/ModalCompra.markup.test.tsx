/**
 * Smoke de caracterización de ModalCompra antes del rediseño de UI.
 *
 * Son 2.700 líneas de formulario y este archivo NO intenta cubrirlas: cubre el
 * esqueleto que el rediseño va a mover —qué secciones existen y cuándo, el
 * camino mínimo "proveedor + producto + guardar", el toggle FC/ZZ por su
 * EFECTO, el alta de proveedor desde la compra, los cargos con su reparto, los
 * vencimientos por línea, y las dos salidas (X y Cancelar)— más las dos teclas
 * que importaban para la migración a `ModalBase` (WP-29, hecha):
 *
 *  - Escape. El modal hecho a mano no cerraba con él; Radix sí. Desde WP-29
 *    cierra SÓLO si la compra no tiene nada cargado (`compraTieneCambios`): con
 *    cualquier dato adentro se ignora, porque son horas de carga de una factura
 *    las que se perderían por un teclazo. La X y Cancelar cierran siempre.
 *  - Escape dentro del sub-buscador de productos cierra SOLO el dropdown. Ese
 *    handler es del `<input>`, y Radix escucha Escape antes (en captura): si
 *    no mirara que la lista está abierta, se comería el modal entero.
 *
 * El detalle fiscal (cargos, prorrateo, cuadre de II) vive testeado en
 * `ModalCompra.reducer` y en `utils/prorrateoCompra`; acá no se duplica.
 */
import { describe, it, expect, vi, beforeEach, afterAll, type Mock } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB, ProveedorDBExtended } from '../../types'

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

// Cargos de la última compra del proveedor: sin plantilla, para que la sección
// no ofrezca "traer los de la vez pasada".
vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: () => ({ data: null, isLoading: false }),
}))

/**
 * El modal de alta de proveedor, que ModalCompra abre anidado y carga lazy.
 *
 * Va stubbeado —mismo patrón que `ComprasContainer.productoRapido.test`— porque
 * el de verdad trae `useZonasEstandarizadasQuery` y `AddressAutocomplete`
 * (Google Maps), que no son de esta superficie. Lo que acá se caracteriza es el
 * CABLEADO de ModalCompra: que el botón abre el alta, que lo que ese modal
 * guarda llega a `onCrearProveedor`, y que el proveedor creado queda elegido en
 * la compra.
 */
vi.mock('./ModalProveedor', () => ({
  default: ({
    onSave,
    onClose,
  }: {
    onSave: (data: { nombre: string; cuit: string }) => Promise<void>
    onClose: () => void
  }) => (
    <div>
      <h2>Nuevo Proveedor</h2>
      <button
        type="button"
        onClick={() => {
          void onSave({ nombre: 'Proveedor Nuevo SRL', cuit: '30-99999999-9' })
        }}
      >
        Crear Proveedor
      </button>
      <button type="button" onClick={onClose}>
        Descartar el alta
      </button>
    </div>
  ),
}))

/**
 * El import de ítems desde Excel, el otro modal hecho a mano que la compra abre
 * anidado y lazy. Stubbeado por lo mismo que el alta de proveedor: el de verdad
 * parsea un archivo, y acá sólo importa el cableado con la compra.
 */
vi.mock('./ModalImportarCompra', () => ({
  default: ({ onClose }: { onClose: () => void }) => (
    <div>
      <h2>Importar Items desde Excel</h2>
      <button type="button" onClick={onClose}>
        Descartar la importación
      </button>
    </div>
  ),
}))

import ModalCompra, { type ModalCompraProps } from './ModalCompra'

type OnSave = ModalCompraProps['onSave']
type OnClose = ModalCompraProps['onClose']
type OnCrearProveedor = NonNullable<ModalCompraProps['onCrearProveedor']>

const PRODUCTOS = [
  {
    id: 'p1',
    nombre: 'Aceite Girasol 900ml',
    codigo: 'ACE900',
    stock: 12,
    costo_sin_iva: 100,
    impuestos_internos: 0,
    porcentaje_iva: 21,
    condicion_iva: 'gravado',
  },
  {
    id: 'p2',
    nombre: 'Fideos 500g',
    codigo: 'FID500',
    stock: 30,
    costo_sin_iva: 50,
    impuestos_internos: 0,
    porcentaje_iva: 21,
    condicion_iva: 'gravado',
  },
] as unknown as ProductoDB[]

const PROVEEDORES = [
  { id: 'prov-1', nombre: 'Manaos SA', cuit: '30-11111111-1' },
  { id: 'prov-2', nombre: 'Distribuidora Norte', cuit: null },
] as unknown as ProveedorDBExtended[]

function renderModal(
  over: {
    onSave?: Mock<OnSave>
    onClose?: Mock<OnClose>
    /** Sin esto el botón "Nuevo" del proveedor no se renderiza (ModalCompra.tsx:630). */
    onCrearProveedor?: Mock<OnCrearProveedor>
  } = {},
) {
  const onSave: Mock<OnSave> = over.onSave ?? vi.fn<OnSave>(() => Promise.resolve())
  const onClose: Mock<OnClose> = over.onClose ?? vi.fn<OnClose>()
  render(
    <ModalCompra
      productos={PRODUCTOS}
      proveedores={PROVEEDORES}
      onSave={onSave}
      onClose={onClose}
      onCrearProductoRapido={vi.fn()}
      onCrearProveedor={over.onCrearProveedor}
    />,
  )
  return { onSave, onClose, user: userEvent.setup() }
}

/**
 * El select de proveedor.
 *
 * BUG: ninguno de los selects del formulario tiene nombre accesible (los
 * `<label>` y los `<h3>` no están atados con `htmlFor`/`aria-labelledby`), así
 * que no se los puede pedir por nombre. Se lo ubica por su opción vacía, que es
 * única en el modal.
 */
function selectProveedor(): HTMLSelectElement {
  const placeholder = screen.getByRole('option', { name: 'Seleccionar proveedor...' })
  return placeholder.closest('select') as HTMLSelectElement
}

const buscador = (): HTMLElement =>
  screen.getByPlaceholderText('Buscar producto por nombre o codigo...')

/**
 * El campo "Fecha de Compra".
 *
 * BUG: su `<label>` no tiene `htmlFor` y el input no está anidado adentro, así
 * que el campo no tiene nombre accesible y `getByLabelText` no lo encuentra.
 * Tampoco tiene rol ARIA propio (`input[type=date]` no expone ninguno), así que
 * no hay cómo pedirlo por rol ni por texto: es el único `type="date"` del modal
 * y se lo ubica por ahí. Al migrar a `ModalBase` conviene atar el label y este
 * helper puede pasar a `getByLabelText`.
 */
function inputFecha(): HTMLInputElement {
  const inputs = Array.from(document.querySelectorAll<HTMLInputElement>('input[type="date"]'))
  expect(inputs).toHaveLength(1)
  return inputs[0]
}

/** Agrega una línea al detalle desde el sub-buscador. */
async function agregarProducto(user: ReturnType<typeof userEvent.setup>, nombre: string) {
  await user.click(buscador())
  await user.click(screen.getByRole('button', { name: new RegExp(nombre) }))
}

beforeEach(() => {
  // Se fija el reloj para que nada que lea la hora durante el test dependa del
  // día en que corre.
  //
  // HALLAZGO: para `state.fechaCompra` NO alcanza. El default sale de
  // `initialState` (ModalCompra.reducer.ts:578-594), que es una constante de
  // módulo: su `fechaLocalISO()` se evalúa al IMPORTAR el reducer, mucho antes
  // de este `beforeEach`, y además se congela para toda la corrida del archivo.
  // Por eso el test que asevera el payload escribe la fecha a mano en vez de
  // confiar en el default.
  vi.useFakeTimers({ shouldAdvanceTime: true })
  vi.setSystemTime(new Date('2026-09-17T15:00:00Z'))
})

afterAll(() => {
  vi.useRealTimers()
})

describe('ModalCompra — esqueleto del formulario', () => {
  it('arranca con las secciones de proveedor y productos, y sin las de totales', () => {
    renderModal()

    expect(screen.getByRole('heading', { name: /^nueva compra$/i, level: 2 })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /^proveedor/i })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Productos' })).toBeInTheDocument()
    expect(screen.getByText('No hay productos agregados')).toBeVisible()

    // Sin líneas no hay dónde prorratear ni qué totalizar.
    expect(screen.queryByRole('heading', { name: 'Cargos y prorrateo' })).toBeNull()
    expect(screen.queryByRole('heading', { name: 'Costo por producto' })).toBeNull()
    expect(screen.queryByRole('heading', { name: 'Resumen' })).toBeNull()
  })

  /**
   * Antes de WP-29 el contenedor era un `<div fixed>` sin `role="dialog"`: para
   * un lector de pantalla no había diálogo ni nombre. Ahora hay UNO, que se
   * llama como el título visible —"Nueva Compra"—, no uno inventado ni ninguno.
   */
  it('es un dialog cuyo nombre es "Nueva Compra"', () => {
    renderModal()

    const dialogos = screen.getAllByRole('dialog')
    expect(dialogos).toHaveLength(1)
    expect(screen.getByRole('dialog', { name: 'Nueva Compra' })).toBe(dialogos[0])
    expect(screen.getByRole('heading', { name: 'Nueva Compra', level: 2 })).toBeInTheDocument()
    expect(within(dialogos[0]).getByText('Registrar compra a proveedor')).toBeInTheDocument()
  })

  /**
   * Lo modal no se asevera con el atributo `aria-modal`: Radix 1.1.15 no lo
   * pone (#800). Lo que hace es marcar `aria-hidden` todo lo que queda fuera
   * del diálogo —un lector de pantalla no se escapa a la vista de atrás—, y es
   * eso lo que se fija acá.
   */
  it('es modal: la vista de atrás sale del árbol accesible', () => {
    render(
      <>
        <button type="button">Vista de fondo</button>
        <ModalCompra
          productos={PRODUCTOS}
          proveedores={PROVEEDORES}
          onSave={vi.fn<OnSave>()}
          onClose={vi.fn<OnClose>()}
        />
      </>,
    )

    expect(screen.getByRole('dialog', { name: 'Nueva Compra' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Vista de fondo' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Vista de fondo', hidden: true })).toBeInTheDocument()
  })

  it('agregar una línea abre cargos, costo por producto y resumen', async () => {
    const { user } = renderModal()

    await agregarProducto(user, 'Aceite Girasol 900ml')

    expect(screen.getByRole('heading', { name: 'Cargos y prorrateo' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Costo por producto' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Resumen' })).toBeInTheDocument()
  })

  /**
   * El toggle FC/ZZ.
   *
   * Los dos botones están SIEMPRE en el DOM y ninguno se deshabilita nunca
   * (ModalCompra.tsx:815-836): lo único que cambia al apretarlos es qué pinta
   * el resumen. Por eso acá se asevera ESO —el efecto— y no la existencia del
   * botón: un test que sólo lo busca y lo clickea pasa igual con el `onClick`
   * borrado, que es justo lo que el rediseño puede romper al re-estilar el
   * control segmentado.
   */
  it('el comprobante arranca en FC: el resumen abre gravado, IVA y percepciones', async () => {
    const { user } = renderModal()

    await agregarProducto(user, 'Aceite Girasol 900ml')

    expect(screen.getByText('Gravado (neto):')).toBeVisible()
    expect(screen.getByText(/IVA \(sobre neto/)).toBeVisible()
    // El bloque de percepciones es `esFC &&` (ModalCompra.tsx:2442).
    // BUG: el atajo "3% del gravado" está DENTRO del `<label>` "Percepción
    // IVA", y `<button>` es un elemento etiquetable: el label le gana al
    // contenido y el botón se anuncia "Percepción IVA", no por lo que hace. Se
    // lo pide por el nombre que tiene HOY.
    expect(screen.getByRole('button', { name: 'Percepción IVA' })).toBeVisible()
    expect(screen.getByText('Percepción IIBB')).toBeVisible()
    expect(screen.getByRole('button', { name: /control contra factura/i })).toBeVisible()
    expect(screen.queryByText('Subtotal Neto:')).toBeNull()
  })

  it('pasar a ZZ saca del resumen el gravado, el IVA y las percepciones', async () => {
    const { user } = renderModal()

    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /ZZ Sin Factura/i }))

    // En ZZ lo pagado ya incluye IVA e II: no hay "gravado", hay neto a secas.
    expect(screen.getByText('Subtotal Neto:')).toBeVisible()
    expect(screen.queryByText('Gravado (neto):')).toBeNull()
    expect(screen.queryByText(/IVA \(sobre neto/)).toBeNull()
    expect(screen.queryByRole('button', { name: 'Percepción IVA' })).toBeNull()
    expect(screen.queryByText('Percepción IIBB')).toBeNull()
    expect(screen.queryByRole('button', { name: /control contra factura/i })).toBeNull()

    // Y vuelve: el toggle es de ida y de vuelta, no un viaje de una sola mano.
    await user.click(screen.getByRole('button', { name: /FC Con Factura/i }))

    expect(screen.getByText('Gravado (neto):')).toBeVisible()
    expect(screen.queryByText('Subtotal Neto:')).toBeNull()
  })

  it('sin líneas no deja registrar la compra', () => {
    renderModal()

    expect(screen.getByRole('button', { name: /registrar compra/i })).toBeDisabled()
  })

  it('con líneas pero sin proveedor, avisa al intentar registrar', async () => {
    const { user, onSave } = renderModal()

    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    expect(await screen.findByText('Debe seleccionar un proveedor')).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })
})

describe('ModalCompra — cargar y guardar una factura', () => {
  it('elegir proveedor, agregar un producto con cantidad y costo, y registrar', async () => {
    const { user, onSave, onClose } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    expect(screen.getByRole('option', { name: /Manaos SA/ })).toBeEnabled()

    // La fecha se escribe a mano: el default es una constante de módulo con la
    // fecha del día en que se importó (ver el `beforeEach`).
    await user.clear(inputFecha())
    await user.type(inputFecha(), '2026-09-15')

    await user.type(screen.getByPlaceholderText('Ej: 0001-00012345'), '0001-00012345')

    await agregarProducto(user, 'Aceite Girasol 900ml')

    // El detalle se pinta dos veces (layout mobile + layout desktop): en jsdom
    // los dos están en el DOM porque sólo los separa CSS. Se edita el primero;
    // los dos NumberInput escriben en el mismo state.
    const inputsCantidad = screen.getAllByDisplayValue('1')
    await user.clear(inputsCantidad[0])
    await user.type(inputsCantidad[0], '4')

    const inputsNeto = screen.getAllByDisplayValue('100')
    await user.clear(inputsNeto[0])
    await user.type(inputsNeto[0], '150')

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    expect(onSave).toHaveBeenCalledTimes(1)
    const payload = onSave.mock.calls[0][0]

    // La cabecera, CERRADA: `toMatchObject` ve un campo cambiado o borrado pero
    // no uno agregado, así que la lista de claves va aparte. Un campo nuevo que
    // el rediseño agregue al payload tiene que decidirse a propósito, no
    // colarse.
    expect(Object.keys(payload).sort()).toEqual([
      'bonificaciones',
      'cambiosImpuestosInternos',
      'cargos',
      'fechaCompra',
      'formaPago',
      'iiDeclarado',
      'impuestosInternos',
      'items',
      'iva',
      'noGravado',
      'notas',
      'numeroFactura',
      'otrosImpuestos',
      'percepcionIibb',
      'percepcionIva',
      'proveedorId',
      'proveedorNombre',
      'subtotal',
      'tipoFactura',
      'total',
    ])

    // El payload COMPLETO que hoy sale del formulario con una línea cargada. Se
    // aseveran los 20 campos que existen de verdad (dumpeados del payload real,
    // no supuestos): el reseño de UI puede mover dónde se escribe cada uno, pero
    // no qué sale.
    expect(payload).toMatchObject({
      proveedorId: 'prov-1',
      // Con proveedor existente elegido viaja `null`, no el nombre: el nombre es
      // sólo para el alta de un proveedor nuevo desde la compra.
      proveedorNombre: null,
      numeroFactura: '0001-00012345',
      fechaCompra: '2026-09-15',
      // 4 u. x 150 sin bonificación; IVA 21% = 126; total 726.
      subtotal: 600,
      iva: 126,
      impuestosInternos: 0,
      percepcionIva: 0,
      percepcionIibb: 0,
      noGravado: 0,
      bonificaciones: 0,
      otrosImpuestos: 0,
      total: 726,
      cambiosImpuestosInternos: [],
      formaPago: 'efectivo',
      notas: '',
      tipoFactura: 'FC',
      cargos: [],
      iiDeclarado: {},
    })
    // La línea, exacta: `subtotal` ya viene con la bonificación aplicada y
    // `vencimientos` viaja siempre, aunque esté vacío (mig 224).
    expect(payload.items).toEqual([
      {
        productoId: 'p1',
        cantidad: 4,
        costoUnitario: 150,
        subtotal: 600,
        bonificacion: 0,
        porcentajeIva: 21,
        condicionIva: 'gravado',
        impuestosInternos: 0,
        vencimientos: [],
      },
    ])
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  /**
   * ZZ es un eje de negocio de primera: lo pagado ya incluye IVA e impuestos
   * internos, así que el payload tiene que salir sin nada encima. Las tres
   * puntas (`percepcionIva`, `percepcionIibb`, `noGravado`) y
   * `cambiosImpuestosInternos` salen de un ternario sobre `state.tipoFactura`
   * (ModalCompra.tsx:467-469 y 484): si el toggle deja de despachar
   * SET_TIPO_FACTURA, esto se pone rojo.
   */
  it('en ZZ el payload va sin IVA y descarta la percepción cargada en FC', async () => {
    const { user, onSave } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml')

    // Se carga la percepción ESTANDO en FC —el botón calcula el 3% del gravado—
    // y recién después se pasa a ZZ: el número queda en el state y lo que lo
    // borra es el ternario del submit, no el toggle.
    await user.click(screen.getByRole('button', { name: 'Percepción IVA' }))
    expect(screen.getByText('Percepciones (IVA + IIBB):')).toBeVisible()

    await user.click(screen.getByRole('button', { name: /ZZ Sin Factura/i }))
    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({
      tipoFactura: 'ZZ',
      // 1 u. a 100: lo pagado es todo, sin IVA ni II encima.
      subtotal: 100,
      iva: 0,
      impuestosInternos: 0,
      total: 100,
      percepcionIva: 0,
      percepcionIibb: 0,
      noGravado: 0,
      cambiosImpuestosInternos: [],
      iiDeclarado: {},
    })
  })

  it('agregar dos veces el mismo producto suma cantidad en vez de duplicar la línea', async () => {
    const { user, onSave } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml')
    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    expect(onSave.mock.calls[0][0].items).toEqual([
      expect.objectContaining({ productoId: 'p1', cantidad: 2 }),
    ])
  })

  it('el error del servidor queda visible y el modal NO se cierra', async () => {
    const onSave = vi.fn().mockRejectedValue(new Error('Ya existe una compra con esa factura'))
    const { user, onClose } = renderModal({ onSave })

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    expect(await screen.findByText('Ya existe una compra con esa factura')).toBeVisible()
    expect(onClose).not.toHaveBeenCalled()
  })
})

describe('ModalCompra — alta de un proveedor nuevo desde la compra', () => {
  it('sin onCrearProveedor no se ofrece dar de alta uno nuevo', () => {
    renderModal()

    expect(screen.queryByRole('button', { name: /^nuevo$/i })).toBeNull()
  })

  it('el proveedor recién creado queda elegido y la compra viaja con su id', async () => {
    const onCrearProveedor = vi.fn<OnCrearProveedor>(() =>
      Promise.resolve({ id: 'prov-9', nombre: 'Proveedor Nuevo SRL' } as ProveedorDBExtended),
    )
    const { user, onSave } = renderModal({ onCrearProveedor })

    await user.click(screen.getByRole('button', { name: /^nuevo$/i }))
    // El alta es un chunk lazy: hay que esperar a que resuelva.
    await user.click(await screen.findByRole('button', { name: 'Crear Proveedor' }))

    // ModalCompra completa los campos que el alta no trajo con `null`, no con
    // `undefined`, y lo da de alta activo.
    expect(onCrearProveedor).toHaveBeenCalledWith({
      nombre: 'Proveedor Nuevo SRL',
      cuit: '30-99999999-9',
      direccion: null,
      latitud: null,
      longitud: null,
      telefono: null,
      email: null,
      contacto: null,
      notas: null,
      activo: true,
    })
    // El alta se cerró sola al guardar.
    expect(screen.queryByRole('button', { name: 'Crear Proveedor' })).toBeNull()

    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    // HALLAZGO: viaja el ID del proveedor nuevo y `proveedorNombre` en null —o
    // sea, por este camino NUNCA se usa la rama `usarProveedorNuevo`
    // (ModalCompra.tsx:460-461), que queda sólo para el escaneo de factura.
    expect(onSave.mock.calls[0][0]).toMatchObject({
      proveedorId: 'prov-9',
      proveedorNombre: null,
    })
  })

  it('descartar el alta deja la compra sin proveedor', async () => {
    const onCrearProveedor = vi.fn<OnCrearProveedor>(() =>
      Promise.resolve({ id: 'prov-9' } as ProveedorDBExtended),
    )
    const { user, onSave } = renderModal({ onCrearProveedor })

    await user.click(screen.getByRole('button', { name: /^nuevo$/i }))
    await user.click(await screen.findByRole('button', { name: 'Descartar el alta' }))

    expect(onCrearProveedor).not.toHaveBeenCalled()

    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    expect(await screen.findByText('Debe seleccionar un proveedor')).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })
})

describe('ModalCompra — cargos y prorrateo', () => {
  /** La sección arranca plegada: el `<h3>` vive adentro del botón que la abre. */
  const abrirCargos = (user: ReturnType<typeof userEvent.setup>) =>
    user.click(screen.getByRole('button', { name: /cargos y prorrateo/i }))

  it('un cargo sin concepto frena el guardado antes de salir a la red', async () => {
    const { user, onSave } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml')
    await abrirCargos(user)
    await user.click(screen.getByRole('button', { name: /agregar cargo/i }))
    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    // `validarCargos` (ModalCompra.tsx:452): la RPC lo rechazaría igual, pero un
    // round trip para enterarse es un round trip de más.
    expect(
      await screen.findByText(
        'Hay un cargo sin concepto. Ponele un nombre (flete, pallets, separadores) o quitalo.',
      ),
    ).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('el cargo se reparte entre las líneas y viaja con sus pesos y sus banderas', async () => {
    const { user, onSave } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml') // 1 u. a 100
    await agregarProducto(user, 'Fideos 500g') // 1 u. a 50

    await abrirCargos(user)
    await user.click(screen.getByRole('button', { name: /agregar cargo/i }))
    await user.type(
      screen.getByPlaceholderText('Flete, pallets, separadores, bonificación...'),
      'Flete',
    )
    const monto = screen.getByPlaceholderText('0.00')
    await user.clear(monto)
    await user.type(monto, '300')

    // El reparto es visible antes de guardar: una fila por línea, con su peso
    // (cada una pintada dos veces, mobile + desktop, como el resto del detalle).
    await user.click(screen.getByRole('button', { name: /ver reparto entre 2 líneas/i }))
    expect(screen.getAllByTitle('0 excluye la línea de este cargo')).toHaveLength(4)

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    // Los pesos viajan por ÍNDICE del array de items, no por `lineaId`
    // (ModalCompra.tsx:496-499), y la base por defecto es el monto: el aceite
    // pesa 100 y los fideos 50.
    expect(onSave.mock.calls[0][0].cargos).toEqual([
      {
        concepto: 'Flete',
        monto: 300,
        // Defaults de la mig 192: el caso típico no lleva IVA, viene en el papel
        // y entra al costo.
        condicionIva: 'no_gravado',
        enFactura: true,
        prorrateaAlCosto: true,
        afectaBaseII: false,
        baseProrrateo: 'monto',
        pesos: { 0: 100, 1: 50 },
      },
    ])
  })

  it('poner en 0 el peso de una línea la excluye del cargo', async () => {
    const { user, onSave } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml')
    await agregarProducto(user, 'Fideos 500g')

    await abrirCargos(user)
    await user.click(screen.getByRole('button', { name: /agregar cargo/i }))
    await user.type(
      screen.getByPlaceholderText('Flete, pallets, separadores, bonificación...'),
      'Flete',
    )
    const monto = screen.getByPlaceholderText('0.00')
    await user.clear(monto)
    await user.type(monto, '300')
    await user.click(screen.getByRole('button', { name: /ver reparto entre 2 líneas/i }))

    // Los cuatro inputs son dos líneas × dos layouts (mobile, desktop): el
    // tercero es el de la segunda línea, los fideos.
    const pesos = screen.getAllByTitle('0 excluye la línea de este cargo')
    await user.clear(pesos[2])
    await user.type(pesos[2], '0')

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    expect(onSave.mock.calls[0][0].cargos).toEqual([
      expect.objectContaining({ concepto: 'Flete', pesos: { 0: 100, 1: 0 } }),
    ])
  })
})

describe('ModalCompra — vencimientos por línea (migs 223/224)', () => {
  it('el vencimiento cargado en la línea viaja aparte de los items', async () => {
    const { user, onSave } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml')

    const inputsCantidad = screen.getAllByDisplayValue('1')
    await user.clear(inputsCantidad[0])
    await user.type(inputsCantidad[0], '4')

    // El badge arranca en "Sin vencimiento" y el primer click ya crea la fila
    // con las unidades libres de la línea: el caso típico no pide tipear nada.
    await user.click(screen.getByRole('button', { name: 'Sin vencimiento' }))
    expect(screen.getByLabelText('Unidades del vencimiento 1')).toHaveValue(4)

    await user.type(screen.getByLabelText('Fecha de vencimiento 1'), '2027-03-01')

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    expect(onSave.mock.calls[0][0].items[0].vencimientos).toEqual([
      { fecha: '2027-03-01', cantidad: 4 },
    ])
  })

  it('etiquetar más unidades que la línea avisa y frena el guardado', async () => {
    const { user, onSave } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml') // queda en 1 u.

    await user.click(screen.getByRole('button', { name: 'Sin vencimiento' }))
    await user.type(screen.getByLabelText('Fecha de vencimiento 1'), '2027-03-01')
    const unidades = screen.getByLabelText('Unidades del vencimiento 1')
    await user.clear(unidades)
    await user.type(unidades, '5')

    expect(screen.getByText('Etiquetaste 5 u. y la línea tiene 1')).toBeVisible()

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))

    // `validarVencimientosLineas` (ModalCompra.tsx:441-447): etiquetar de MENOS
    // es legal —el resto queda en la bolsa sin vencimiento—, de más no.
    expect(
      await screen.findByText(
        '"Aceite Girasol 900ml": etiquetaste 5 u. con vencimiento y la línea tiene 1. Quitá las que sobran o subí la cantidad.',
      ),
    ).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })
})

describe('ModalCompra — sub-buscador de productos', () => {
  it('enfocar el buscador ofrece los productos y elegirlos los agrega al detalle', async () => {
    const { user } = renderModal()

    await user.click(buscador())
    expect(screen.getByRole('button', { name: /Aceite Girasol 900ml/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Fideos 500g/ })).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /Fideos 500g/ }))

    // La línea aparece en el detalle (dos veces: mobile + desktop) y el
    // dropdown se cerró.
    expect(screen.getAllByText('Fideos 500g').length).toBeGreaterThan(0)
    expect(screen.queryByRole('button', { name: /Aceite Girasol 900ml/ })).toBeNull()
  })

  it('filtra por nombre o código', async () => {
    const { user } = renderModal()

    await user.click(buscador())
    await user.type(buscador(), 'FID')

    expect(screen.getByRole('button', { name: /Fideos 500g/ })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Aceite Girasol 900ml/ })).toBeNull()
  })

  /**
   * El dropdown se cierra con un `mousedown` escuchado en el `document`. El
   * contenido de `ModalBase` corta la propagación de `mousedown` (ModalBase.tsx,
   * para que Radix no confunda un arrastre con un click afuera), así que un
   * listener en fase de burbujeo deja de enterarse de cualquier click adentro
   * del modal: el dropdown quedaría abierto tapando las líneas.
   */
  it('un click fuera del buscador cierra el dropdown', async () => {
    const { user } = renderModal()

    await user.click(buscador())
    expect(screen.getByRole('button', { name: /Aceite Girasol 900ml/ })).toBeInTheDocument()

    await user.click(screen.getByPlaceholderText('Ej: 0001-00012345'))

    expect(screen.queryByRole('button', { name: /Aceite Girasol 900ml/ })).toBeNull()
  })

  it('Escape dentro del buscador cierra SÓLO el dropdown, no el modal', async () => {
    const { user, onClose } = renderModal()

    await user.click(buscador())
    expect(screen.getByRole('button', { name: /Aceite Girasol 900ml/ })).toBeInTheDocument()

    await user.keyboard('{Escape}')

    expect(screen.queryByRole('button', { name: /Aceite Girasol 900ml/ })).toBeNull()
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: /^nueva compra$/i })).toBeInTheDocument()
  })
})

describe('ModalCompra — salidas del modal', () => {
  /**
   * La X del header.
   *
   * Hasta WP-29 era un botón sin `aria-label` ni texto y se la ubicaba por
   * descarte. La X de `ModalBase` se llama "Cerrar", y por ese nombre se la
   * busca.
   */
  const botonCerrar = (): HTMLElement => screen.getByRole('button', { name: 'Cerrar' })

  it('la X del header llama onClose', async () => {
    const { user, onClose } = renderModal()

    await user.click(botonCerrar())

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('Cancelar llama onClose', async () => {
    const { user, onClose } = renderModal()

    await user.click(screen.getByRole('button', { name: /^cancelar$/i }))

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  // La X y Cancelar son un click deliberado: cierran con la compra a medio
  // cargar, igual que antes de ModalBase. Lo que se frena es sólo Escape.
  it.each([
    ['la X', () => botonCerrar()],
    ['Cancelar', () => screen.getByRole('button', { name: /^cancelar$/i })],
  ])('%s cierra aunque la compra tenga datos cargados', async (_salida, boton) => {
    const { user, onClose, onSave } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.click(boton())

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
  })

  // El modal hecho a mano no escuchaba Escape. Con ModalBase (Radix) Escape
  // cierra, pero sólo si no hay nada que perder (`compraTieneCambios`). La
  // confirmación de descarte que se pensó para acá no hace falta: con la
  // compra a medio cargar, Escape directamente se ignora.
  it('con la compra sin tocar, Escape cierra sin guardar', async () => {
    const { user, onClose, onSave } = renderModal()

    await user.click(screen.getByPlaceholderText('Ej: 0001-00012345'))
    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('con un proveedor elegido y sin líneas, Escape NO cierra', async () => {
    const { user, onClose } = renderModal()

    await user.selectOptions(selectProveedor(), 'prov-1')
    await user.keyboard('{Escape}')

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog', { name: 'Nueva Compra' })).toBeInTheDocument()
    expect(selectProveedor()).toHaveValue('prov-1')
  })

  // Lo que se tipea en el alta rápida vive en el estado local del buscador, no
  // en el reducer: con el panel abierto se lo trata como carga.
  it('con el alta rápida de producto abierta, Escape NO cierra', async () => {
    const { user, onClose } = renderModal()

    await user.click(screen.getByRole('button', { name: 'Crear producto nuevo' }))
    await user.type(screen.getByPlaceholderText('Nombre del producto'), 'Gaseosa Cola 2.25L')
    await user.keyboard('{Escape}')

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByPlaceholderText('Nombre del producto')).toHaveValue('Gaseosa Cola 2.25L')
  })

  // El alta de proveedor es un modal hecho a mano anidado: para Radix sigue
  // siendo "adentro de la compra", así que su Escape le llega a la compra. Con
  // la compra sin tocar, cerraría las dos y se perdería lo tipeado en el alta.
  it('con el alta de proveedor abierta, Escape NO cierra la compra', async () => {
    const { user, onClose } = renderModal({ onCrearProveedor: vi.fn<OnCrearProveedor>() })

    await user.click(screen.getByRole('button', { name: /^nuevo$/i }))
    // El alta es un chunk lazy: hay que esperar a que resuelva.
    expect(await screen.findByRole('heading', { name: 'Nuevo Proveedor' })).toBeInTheDocument()

    await user.keyboard('{Escape}')

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Nuevo Proveedor' })).toBeInTheDocument()
    expect(screen.getByRole('dialog', { name: 'Nueva Compra' })).toBeInTheDocument()
  })

  // Ídem el import desde Excel: con la compra sin tocar, su Escape cerraría la
  // compra y el import juntos, y se perdería la vista previa ya parseada.
  it('con el import desde Excel abierto, Escape NO cierra la compra', async () => {
    const { user, onClose } = renderModal()

    await user.click(screen.getByRole('button', { name: /importar excel/i }))
    // Chunk lazy, como el alta de proveedor.
    expect(
      await screen.findByRole('heading', { name: 'Importar Items desde Excel' }),
    ).toBeInTheDocument()

    await user.keyboard('{Escape}')

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Importar Items desde Excel' })).toBeInTheDocument()
    expect(screen.getByRole('dialog', { name: 'Nueva Compra' })).toBeInTheDocument()
  })

  it('Escape tampoco cierra con una línea ya cargada', async () => {
    const { user, onClose } = renderModal()

    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.keyboard('{Escape}')

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('heading', { name: 'Resumen' })).toBeInTheDocument()
  })
})
