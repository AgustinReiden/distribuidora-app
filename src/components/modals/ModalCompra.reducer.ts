/**
 * Estado del modal de compra: tipos, estado inicial y reducer.
 *
 * Vive fuera de ModalCompra.tsx por una razón concreta y no por prolijidad:
 * `react-refresh/only-export-components` prohíbe exportar valores desde un
 * archivo de componentes, así que mientras el reducer estuvo allá adentro no se
 * lo podía testear. Y es justo la lógica que se rompe en silencio — un peso que
 * queda pegado al producto equivocado no tira ninguna pantalla, sólo reparte
 * mal el flete.
 *
 * Además este módulo NO importa supabase, así que sus tests corren sin stubs de
 * entorno.
 */
import { fechaLocalISO } from '../../utils/formatters'
import { redondearSQL } from '../../utils/calculations'
import { OPCIONES_CONDICION_IVA } from '../../utils/condicionIva'
import { calcularCostosCompra, lineaParaMotor, resolverBasesII } from '../../utils/prorrateoCompra'
import type { PesosCargo, LineaCompra, CargoCompra, ResultadoBasesII } from '../../utils/prorrateoCompra'
import type { BaseProrrateoCompra, CargoPlantillaCompra, CompraCargoInput, CondicionIva, ProductoDB } from '../../types'
import { recalcularPesosDesactualizados } from '../../utils/pesosDesactualizados'
import {
  CONTEXTO_MEDIDAS_VACIO, conValorDeCompra, normalizarNombreConcepto, pesoPorMedida, resolverMedida,
} from '../../utils/medidasCargo'
import type { ConceptoCargo, ContextoMedidas, MedidasPorProducto } from '../../utils/medidasCargo'
import {
  alcanceBonificacionAnterior, analizarAlicuotasII, detectarBonificacionNoDescontada, esConceptoBonificacion,
} from '../../utils/detectarBonificacionNoDescontada'
import type { SugerenciaBonificacion } from '../../utils/detectarBonificacionNoDescontada'

/**
 * Un vencimiento de una línea de factura (migs 223/224).
 *
 * Es una lista y no un campo suelto porque una misma línea puede traer dos
 * lotes: llegan 20 cajas, 12 vencen en marzo y 8 en mayo. Cargar eso como dos
 * renglones del mismo producto obligaría a partir también el costo y la
 * bonificación, que son de la línea, no del lote.
 *
 * La suma de las cantidades puede ser MENOR que la cantidad de la línea: lo que
 * no se etiqueta queda en la bolsa "sin vencimiento" del producto, que es un
 * estado soportado. Nunca mayor.
 */
export interface VencimientoLinea {
  /** 'YYYY-MM-DD'. */
  fecha: string;
  cantidad: number;
}

/** Item de compra en el formulario */
export interface CompraItemForm {
  productoId: string;
  productoNombre: string;
  productoCodigo?: string | null;
  cantidad: number;
  bonificacion: number;
  costoUnitario: number;
  impuestosInternos: number;
  porcentajeIva: number;
  /** Condición de la línea (mig 177). Se siembra del producto y se puede pisar acá. */
  condicionIva: CondicionIva;
  stockActual: number;
  /**
   * Id local y estable de la línea, asignado por el reducer.
   *
   * Los cargos guardan sus pesos contra este id y no contra el índice del
   * array: borrar una línea corre los índices y el peso tipeado a mano
   * terminaría pegado a otro producto, en silencio. Es opcional porque los
   * items también se construyen afuera (ModalImportarCompra) — el reducer
   * numera todo lo que llegue sin id.
   */
  lineaId?: number;
  /**
   * Vencimientos de esta línea (migs 223/224). Opcional: cargarlos es opcional
   * y una línea sin vencimientos es perfectamente válida.
   *
   * No viaja en `p_items` de `registrar_compra_completa`: se manda aparte, con
   * `sincronizar_lotes_compra`, después de guardar la compra. Ver el encabezado
   * de la mig 224 para el porqué.
   */
  vencimientos?: VencimientoLinea[];
}

/**
 * Regla que pre-llena el vector de pesos de un cargo (`base_prorrateo` de la
 * mig 192). Sólo pre-llena: la verdad siempre es el vector.
 *
 * Es un alias del tipo compartido y no una copia: el mismo dominio viaja a la
 * RPC y vuelve en la plantilla del proveedor, y dos uniones separadas se
 * desincronizan sin que nada avise.
 */
export type BaseProrrateo = BaseProrrateoCompra

/**
 * Un cargo de la factura tal como se carga en el formulario: flete, pallets,
 * separadores, bonificación comercial.
 *
 * Espeja `CargoCompra` de prorrateoCompra.ts con los mismos nombres —el motor
 * lo consume tal cual— y le suma lo que sólo vive en la UI: la base que
 * pre-llena los pesos y qué pesos tocó el usuario a mano.
 *
 * No lleva alícuota de IVA propia a propósito: un cargo gravado tributa a la de
 * las líneas sobre las que cae.
 */
export interface CargoCompraForm {
  /** Id local del cargo (el de la base lo asigna la RPC al persistir). */
  id: number;
  concepto: string;
  /** SIN IVA. Negativo = bonificación. */
  monto: number;
  condicionIva: CondicionIva;
  /** Viene impreso en la factura: suma al cuadre contra el papel. */
  enFactura: boolean;
  /** Entra al costo unitario. Independiente de `enFactura`. */
  prorrateaAlCosto: boolean;
  /** Mueve la base de impuestos internos. Sólo aplica si es gravado. */
  afectaBaseII: boolean;
  /**
   * `true` si el flag de arriba lo tildó el usuario. Misma regla que los pesos:
   * lo que se toca a mano no se pisa nunca con lo deducido.
   *
   * Existe porque desde el solver (`resolverBasesII`) el valor por defecto de
   * `afectaBaseII` ya no es una suposición sino el resultado de resolver el
   * impuesto interno declarado contra las 2^N combinaciones posibles. Eso gana
   * contra el default y contra la plantilla del proveedor —que son adivinanzas—
   * pero no contra alguien que sabe qué acordó con el proveedor.
   */
  afectaBaseIIManual: boolean;
  baseProrrateo: BaseProrrateo;
  /** lineaId → peso. El 0 excluye la línea. */
  pesos: PesosCargo;
  /** lineaIds cuyo peso tipeó el usuario: el pre-llenado no los pisa. */
  pesosManuales: Record<number, true>;
  /**
   * Sólo al EDITAR una compra guardada (utils/hidratarCompra): la cantidad que
   * tenía cada línea cuando se fijó su peso manual. Si la cantidad cambia
   * después, ese peso puede haber quedado viejo —2 pallets para 240 u. ya no
   * son 2 si la línea pasa a 480— y la grilla lo marca "desactualizado" con un
   * "recalcular" a mano en vez de pisarlo solo (utils/pesosDesactualizados).
   *
   * `undefined` en una compra nueva: ahí el pre-llenado sigue a la cantidad y
   * lo tipeado a mano es decisión del que carga, sin referencia que comparar.
   *
   * Que esté definido es también la marca de "cargo guardado": una línea que se
   * agrega al editar entra a él con peso 0 en vez del pre-llenado (ver
   * `sincronizarCargos`). Re-elegir la base lo borra.
   */
  cantidadesReferencia?: Record<number, number>;
  /**
   * Concepto del catálogo (mig 278) del que salió el renglón. Sólo estadística
   * y plantilla: lo que se guarda en `compra_cargos` es la foto del renglón.
   * Opcional para no tocar a quien arma cargos a mano (tests, borradores viejos).
   */
  conceptoId?: string | null;
  /** "+ Crear 'X'": el concepto se da de alta en el catálogo al guardar. */
  conceptoNuevo?: boolean;
  /** Medida de la base 'medida' (Pallet, Separador, Lugar en el flete). */
  medidaId?: string | null;
  /**
   * mig 281 (#866). El cargo —gravado y fuera de la factura del proveedor,
   * típicamente el flete— viene con factura propia del transportista. Su IVA
   * es crédito fiscal (posicion_fiscal.iva_fletes), NO costo: el monto sigue
   * siendo neto. Sólo vale con `!enFactura && condicionIva === 'gravado'`
   * (`aplicaComprobanteTercero`); fuera de esa combinación no viaja.
   */
  comprobanteTercero?: boolean;
  /** IVA de la factura del tercero. `null`/ausente = 21% del monto (sigue al monto). */
  ivaTercero?: number | null;
  /** Transportista y N° de su comprobante (texto libre). */
  terceroNombre?: string | null;
  terceroComprobante?: string | null;
  /**
   * Sólo si vino de la plantilla del proveedor (la última compra). El vector de
   * esa compra, por producto, es el ALCANCE del cargo: una línea de un producto
   * que no está (o pesa 0) queda en 0, llegue cuando llegue —a mano, por Excel o
   * por el escaneo, que reemplaza las líneas después de elegir el proveedor—.
   * Con la base de la plantilla y que no sea 'medida', el peso es el de la
   * compra vieja; con 'medida' (o si se cambió la base) sale de la base.
   *
   * `tocado`: el usuario editó algo del renglón. Al cambiar de proveedor sólo se
   * reemplazan los de plantilla SIN monto y sin tocar.
   */
  plantilla?: { pesosPorProducto: Record<string, number>; base: BaseProrrateo; tocado: boolean };
  /**
   * #908. Sólo en una bonificación agregada desde la sugerencia de "bonificación
   * no descontada": los productos sobre los que se reparte. Una línea de otro
   * producto queda en 0 —incluida la que se agregue después—, que es la garantía
   * de que la bonificación nunca se derrama sobre otra alícuota de II, la soda
   * al 0% o un exento. Las del alcance siguen el pre-llenado de la base.
   */
  alcanceProductos?: string[];
}

/**
 * Lo editable de un cargo. El vector de pesos se toca sólo por SET_PESO_CARGO y
 * las marcas de manual las pone el reducer: si se pudieran mandar desde afuera,
 * cualquier cambio de campo podría clavar un flag sin que nadie lo haya tocado.
 */
export type CambiosCargo =
  Partial<Omit<CargoCompraForm, 'id' | 'pesos' | 'pesosManuales' | 'afectaBaseIIManual' | 'cantidadesReferencia' | 'plantilla' | 'conceptoNuevo' | 'alcanceProductos'>>

/** Resultado del escaneo de factura via n8n */
export interface FacturaEscaneada {
  proveedorNombre: string | null;
  proveedorCuit: string | null;
  numeroFactura: string | null;
  fechaCompra: string | null;
  items: Array<{
    codigo: string | null;
    descripcion: string;
    cantidad: number;
    costoUnitario: number;
    bonificacion: number;
    iva: number;
  }>;
  subtotal: number | null;
  iva: number | null;
  total: number | null;
  formaPago: string | null;
  confianza: number;
}

/** Item escaneado pendiente de revisión humana */
export type FacturaItemEscaneado = FacturaEscaneada['items'][number]

/**
 * Normaliza strings para comparar nombres/códigos: minúsculas,
 * trim, colapsa whitespace.
 */
function normalizarTexto(s: string | null | undefined): string {
  return (s ?? '').trim().toLowerCase().replace(/\s+/g, ' ')
}

/**
 * Auto-link estricto: solo retorna match si código exacto o nombre exacto
 * (case/espacios normalizados). Cualquier otra coincidencia (parcial,
 * substring) queda fuera para que el usuario decida.
 */
export function matchProductoEstricto(
  scanItem: FacturaItemEscaneado,
  productos: ProductoDB[]
): ProductoDB | null {
  const cod = normalizarTexto(scanItem.codigo)
  if (cod) {
    const porCodigo = productos.find(p => normalizarTexto(p.codigo) === cod)
    if (porCodigo) return porCodigo
  }
  const desc = normalizarTexto(scanItem.descripcion)
  if (desc) {
    const porNombre = productos.find(p => normalizarTexto(p.nombre) === desc)
    if (porNombre) return porNombre
  }
  return null
}

/** Construye un CompraItemForm a partir de un producto resuelto + datos de la factura. */
export function construirCompraItemDesdeScan(
  producto: ProductoDB,
  scanItem: FacturaItemEscaneado
): CompraItemForm {
  return {
    productoId: producto.id,
    productoNombre: producto.nombre,
    productoCodigo: producto.codigo || scanItem.codigo,
    cantidad: scanItem.cantidad || 1,
    bonificacion: scanItem.bonificacion || 0,
    costoUnitario: scanItem.costoUnitario || 0,
    // De la ficha, igual que `AGREGAR_ITEM` y que el import de Excel: el escaneo
    // NO trae la alícuota de impuesto interno (no está en `FacturaEscaneada`),
    // así que un 0 acá no era "la factura dice 0" sino "no lo sabemos". Costaba
    // dos veces: el costo de la compra salía sin la tasa entera —y con él el
    // costo_real y el CPP— y además la línea "difería" del maestro, así que al
    // registrar se le ponía `impuestos_internos = 0` al producto.
    impuestosInternos: producto.impuestos_internos ?? 0,
    // `??`, no `||`: un 0 legítimo del escaneo (línea exenta) se convertía en 21.
    porcentajeIva: scanItem.iva ?? producto.porcentaje_iva ?? 21,
    condicionIva: producto.condicion_iva ?? 'gravado',
    stockActual: producto.stock || 0
  }
}

/** Totales impresos en la factura física, para el panel "Control contra factura" (0 = no cargado) */
export interface ControlFactura {
  gravado: number;
  iva: number;
  impuestosInternos: number;
  percepciones: number;
  total: number;
}

/** Estado del reducer de compra */
export interface CompraState {
  /** Percepción de IVA de la factura (crédito fiscal, no costo) — solo FC */
  percepcionIva: number;
  /** Percepción de IIBB de la factura (crédito fiscal, no costo) — solo FC */
  percepcionIibb: number;
  /** Conceptos no gravados (ej: pallets valorizados) — solo FC */
  noGravado: number;
  /**
   * `true` si el usuario tipeó el no gravado. Misma regla que los pesos de un
   * cargo: lo escrito a mano no se pisa nunca con el pre-llenado.
   *
   * Existe porque el campo tiene dos orígenes legítimos. Casi siempre el número
   * del papel ES la suma de los cargos no gravados que vienen en la factura
   * —pallets, separadores—, y ésos ya están cargados abajo: pedirle al usuario
   * que los vuelva a tipear es pedirle un dato que el modal ya tiene, y si no
   * lo tipea el cuadre contra la factura se pone rojo por un importe que
   * nadie omitió. Pero una factura puede traer un no gravado que no se cargó
   * como cargo, y ahí la verdad es lo que el usuario escribe.
   */
  noGravadoManual: boolean;
  controlFactura: ControlFactura;
  /** Cargos de la factura (flete, pallets, bonificaciones). FC y ZZ: en ZZ el
   *  cargo suma al costo igual, sólo no se le agrega impuesto interno encima. */
  cargos: CargoCompraForm[];
  /**
   * Impuesto interno DECLARADO en la factura, abierto por alícuota:
   * tasa → monto. Alimenta el factor de ajuste de `calcularCostosCompra`.
   * Una tasa ausente no ajusta nada (que NO es lo mismo que declarar 0).
   */
  iiDeclarado: Record<number, number>;
  proveedorId: string;
  proveedorNombre: string;
  usarProveedorNuevo: boolean;
  numeroFactura: string;
  fechaCompra: string;
  formaPago: string;
  tipoFactura: 'ZZ' | 'FC';
  notas: string;
  items: CompraItemForm[];
  busquedaProducto: string;
  mostrarBuscador: boolean;
  modoItemRapido: boolean;
  guardando: boolean;
  error: string;
  // Escaneo de factura
  escaneando: boolean;
  resultadoEscaneo: FacturaEscaneada | null;
  errorEscaneo: string;
  /** Items del último escaneo que no se auto-vincularon y esperan decisión del usuario. */
  itemsPendientesScan: FacturaItemEscaneado[];
  /**
   * Unidades por medida (mig 278): el catálogo (sólo el puente a la base), la
   * ficha de la sucursal y lo tipeado en esta compra. Los dos primeros los
   * escribe el modal cuando llegan las queries; el tercero, la grilla de pesos.
   */
  medidas: ContextoMedidas;
  /**
   * El proveedor cuya plantilla de cargos ya se aplicó. Está en el estado (y no
   * en un ref) para que un borrador retomado no la vuelva a aplicar encima.
   */
  plantillaProveedorId: string | null;
  /**
   * #908. Claves de las sugerencias de bonificación no descontada que el usuario
   * descartó (`ii:<tasa>` o `papel`, ver SugerenciaBonificacion.clave). Por
   * clave y no por monto: descartada, no vuelve a aparecer en esta carga aunque
   * se toque una línea.
   */
  bonificacionesDescartadas: string[];
}

/** Tipos de acciones del reducer */
export type CompraActionType =
  | { type: 'SET_PROVEEDOR_ID'; payload: string }
  | { type: 'SET_PROVEEDOR_NOMBRE'; payload: string }
  | { type: 'SET_USAR_PROVEEDOR_NUEVO'; payload: boolean }
  | { type: 'SET_NUMERO_FACTURA'; payload: string }
  | { type: 'SET_FECHA_COMPRA'; payload: string }
  | { type: 'SET_FORMA_PAGO'; payload: string }
  | { type: 'SET_TIPO_FACTURA'; payload: 'ZZ' | 'FC' }
  | { type: 'SET_NOTAS'; payload: string }
  | { type: 'SET_BUSQUEDA'; payload: string }
  | { type: 'SET_MOSTRAR_BUSCADOR'; payload: boolean }
  | { type: 'SET_GUARDANDO'; payload: boolean }
  | { type: 'SET_ERROR'; payload: string }
  | { type: 'AGREGAR_ITEM'; payload: ProductoDB }
  | { type: 'ACTUALIZAR_ITEM'; payload: { index: number; campo: keyof CompraItemForm; valor: number | string } }
  // Condición y alícuota se setean juntas: la condición manda sobre la tasa.
  | { type: 'SET_CONDICION_ITEM'; payload: { index: number; clave: string } }
  // La sub-fila de vencimientos maneja su propia lista y empuja la foto entera.
  | { type: 'SET_VENCIMIENTOS_ITEM'; payload: { index: number; vencimientos: VencimientoLinea[] } }
  | { type: 'ELIMINAR_ITEM'; payload: number }
  | { type: 'LIMPIAR_BUSQUEDA' }
  | { type: 'SET_MODO_ITEM_RAPIDO'; payload: boolean }
  | { type: 'AGREGAR_ITEM_RAPIDO'; payload: { productoId: string; nombre: string; codigo: string; costoUnitario: number; impuestosInternos?: number } }
  | { type: 'IMPORTAR_ITEMS'; payload: CompraItemForm[] }
  | { type: 'SET_ESCANEANDO'; payload: boolean }
  | { type: 'SET_RESULTADO_ESCANEO'; payload: FacturaEscaneada | null }
  | { type: 'SET_ERROR_ESCANEO'; payload: string }
  | { type: 'APLICAR_ESCANEO'; payload: { proveedorId: string; proveedorNombre: string; numeroFactura: string; fechaCompra: string; formaPago: string; items: CompraItemForm[]; pendientes: FacturaItemEscaneado[] } }
  | { type: 'RESOLVER_PENDIENTE_VINCULAR'; payload: { index: number; producto: ProductoDB } }
  | { type: 'RESOLVER_PENDIENTE_CREAR'; payload: { index: number; producto: ProductoDB } }
  | { type: 'RESOLVER_PENDIENTE_OMITIR'; payload: { index: number } }
  | { type: 'LIMPIAR_PENDIENTES_SCAN' }
  | { type: 'SET_EXTRAS'; payload: Partial<Pick<CompraState, 'percepcionIva' | 'percepcionIibb' | 'noGravado'>> }
  // Suelta el no gravado tipeado y lo devuelve al pre-llenado por cargos.
  | { type: 'USAR_NO_GRAVADO_DE_CARGOS' }
  | { type: 'SET_CONTROL'; payload: Partial<ControlFactura> }
  | { type: 'APLICAR_BONIF_GLOBAL'; payload: number }
  // Cargos y prorrateo (mig 192). El vector de pesos no se toca desde acá salvo
  // por SET_PESO_CARGO: lo mantiene alineado el wrapper del reducer.
  | { type: 'AGREGAR_CARGO' }
  | { type: 'ACTUALIZAR_CARGO'; payload: { id: number; cambios: CambiosCargo } }
  | { type: 'ELIMINAR_CARGO'; payload: number }
  | { type: 'SET_PESO_CARGO'; payload: { cargoId: number; lineaId: number; peso: number } }
  | { type: 'SET_II_DECLARADO'; payload: { tasa: number; monto: number } }
  // Editar (B2): lleva los pesos manuales marcados como desactualizados a la
  // cantidad nueva de su línea, en proporción. Es el "recalcular" de la grilla.
  | { type: 'RECALCULAR_PESOS_DESACTUALIZADOS'; payload: { cargoId: number } }
  // Editar (B2): los vencimientos que la compra ya tiene, por producto. Se
  // precargan una vez, cuando llegan los lotes; la línea sin lotes no se toca.
  | { type: 'PRECARGAR_VENCIMIENTOS'; payload: Record<string, VencimientoLinea[]> }
  // Retomar un borrador (utils/borradorCompra): el estado entero, marcas de
  // manual incluidas. Pasa por el wrapper como cualquier otra acción.
  | { type: 'HIDRATAR'; payload: CompraState }
  // mig 278 · catálogo de conceptos y medidas.
  // Plantilla del proveedor: reemplaza los cargos de plantilla sin tocar y suma
  // los que falten. `cargos: []` = el proveedor no tiene compra con cargos.
  | { type: 'APLICAR_PLANTILLA_PROVEEDOR'; payload: { proveedorId: string; cargos: CargoPlantillaCompra[] } }
  // Elegir un concepto del catálogo PRECARGA sus defaults (todo sigue editable).
  | { type: 'ELEGIR_CONCEPTO'; payload: { id: number; concepto: ConceptoCargo } }
  // "+ Crear 'X'": el nombre tipeado, con los valores que ya tiene el renglón.
  | { type: 'CREAR_CONCEPTO'; payload: { id: number; nombre: string } }
  // Lo que llega de las queries: el puente medida → base y la ficha.
  | { type: 'SET_MEDIDAS_REFERENCIA'; payload: { bases: Record<string, string | null>; ficha: MedidasPorProducto<number> } }
  // U/medida tipeadas en una línea (directas o derivadas de los pallets). null = volver a la ficha.
  | { type: 'SET_MEDIDA_LINEA'; payload: { productoId: string; medidaId: string; unidadesPor: number | null } }
  | { type: 'SET_GUARDAR_EN_FICHA'; payload: { productoId: string; medidaId: string; guardar: boolean } }
  // #908 · bonificación no descontada. Aceptar agrega el cargo (nunca solo:
  // siempre por un clic); descartar la oculta para esa alícuota.
  | { type: 'AGREGAR_BONIFICACION_SUGERIDA'; payload: { sugerencia: SugerenciaBonificacion; concepto: ConceptoCargo | null } }
  | { type: 'DESCARTAR_BONIFICACION_SUGERIDA'; payload: { clave: string } };

// =============================================================================
// BORDE DEL MOTOR DE COSTOS
// =============================================================================

/**
 * Las líneas del formulario tal como las ve el motor.
 *
 * La regla de ZZ y el mapeo de campos viven en `lineaParaMotor`
 * (prorrateoCompra.ts), que es el mismo CASE que arma `v_items_motor` en la mig
 * 194 y que también usa el desglose de la cabecera. Acá sólo queda lo que es
 * propio del formulario: una línea sin `lineaId` no viaja, porque los pesos de
 * los cargos se guardan contra ese id y una línea sin id no podría recibir su
 * parte del flete.
 */
export function lineasParaMotor(items: CompraItemForm[], tipoFactura: 'ZZ' | 'FC'): LineaCompra[] {
  return items.flatMap(item =>
    item.lineaId === undefined ? [] : [lineaParaMotor(item, tipoFactura, item.lineaId)]
  )
}

/** El cargo del formulario sin lo que sólo vive en la UI (base y marcas de manual). */
export function cargosParaMotor(cargos: CargoCompraForm[]): CargoCompra[] {
  return cargos.map(c => ({
    id: c.id,
    concepto: c.concepto,
    monto: c.monto,
    condicionIva: c.condicionIva,
    enFactura: c.enFactura,
    prorrateaAlCosto: c.prorrateaAlCosto,
    afectaBaseII: c.afectaBaseII,
    pesos: c.pesos,
  }))
}

/**
 * Los cargos del formulario tal como los espera la RPC (mig 194): con los pesos
 * traducidos de `lineaId` a ÍNDICE del array de items que viaja en el MISMO
 * payload, base 0.
 *
 * La traducción es obligatoria, no cosmética. Adentro del modal el peso se
 * guarda contra `lineaId` porque el índice se corre al borrar una línea y el
 * peso terminaría pegado a otro producto. La RPC, en cambio, sólo puede hablar
 * de índices: `compra_items.id` todavía no existe cuando el cliente arma el
 * payload. Las dos verdades son correctas en su lado y el puente vive acá, en
 * un solo lugar, contra `items` — que tiene que ser EL MISMO array que se manda
 * como `p_items`.
 *
 * Una línea que ya no está se cae del vector en vez de viajar: la RPC rechaza
 * un índice fuera de rango, y hace bien, porque ese pedazo del cargo no
 * matchearía ninguna línea y se evaporaría del costo.
 */
/** ¿Este cargo puede traer factura de un tercero? (mig 281: gravado y fuera del papel del proveedor) */
export function aplicaComprobanteTercero(c: Pick<CargoCompraForm, 'enFactura' | 'condicionIva'>): boolean {
  return !c.enFactura && c.condicionIva === 'gravado'
}

/** IVA por defecto de la factura del tercero: 21% del monto, al centavo. */
export function ivaTerceroPorDefecto(monto: number): number {
  return Math.round(Math.abs(monto) * 21) / 100
}

/** El IVA que se muestra y se guarda: el tipeado, o el 21% del monto si nadie lo tocó. */
export function ivaTerceroEfectivo(c: Pick<CargoCompraForm, 'ivaTercero' | 'monto'>): number {
  return c.ivaTercero ?? ivaTerceroPorDefecto(c.monto)
}

export function cargosParaRPC(items: CompraItemForm[], cargos: CargoCompraForm[]): CompraCargoInput[] {
  const indicePorLinea = new Map<number, number>()
  items.forEach((item, i) => {
    if (item.lineaId !== undefined) indicePorLinea.set(item.lineaId, i)
  })
  return cargos.map(c => {
    const pesos: Record<number, number> = {}
    for (const [lineaId, peso] of Object.entries(c.pesos)) {
      const indice = indicePorLinea.get(Number(lineaId))
      if (indice === undefined) continue
      pesos[indice] = peso
    }
    return {
      concepto: c.concepto.trim(),
      monto: c.monto,
      condicionIva: c.condicionIva,
      enFactura: c.enFactura,
      prorrateaAlCosto: c.prorrateaAlCosto,
      afectaBaseII: c.afectaBaseII,
      baseProrrateo: c.baseProrrateo,
      pesos,
      conceptoId: c.conceptoId ?? null,
      medidaId: c.baseProrrateo === 'medida' ? (c.medidaId ?? null) : null,
      ...(c.conceptoNuevo && !c.conceptoId ? { crearConcepto: true } : {}),
      // mig 281: sólo viaja si aplica. Ausente = sin tercero (la RPC lo
      // normaliza a false/NULL), así que un cargo que dejó de aplicar —pasó a
      // "viene en la factura" o a no gravado— se guarda limpio.
      ...(c.comprobanteTercero && aplicaComprobanteTercero(c)
        ? {
            comprobanteTercero: true,
            ivaMonto: ivaTerceroEfectivo(c),
            terceroNombre: c.terceroNombre?.trim() || null,
            terceroComprobante: c.terceroComprobante?.trim() || null,
          }
        : {}),
    }
  })
}

/**
 * Lo que la RPC va a rechazar de los cargos, dicho antes de salir a la red.
 *
 * No es una segunda fuente de verdad: la validación que manda es la de la mig
 * 194 —corre aunque el cliente esté viejo— y ésta existe para que el usuario
 * lea el problema al lado del campo que lo causa en vez de un round trip
 * después. Si la RPC gana una regla nueva, ésta se queda corta y no de más:
 * el error igual llega y el modal lo muestra.
 *
 * El peso positivo sobre una línea de cantidad 0 —la otra causa de rechazo— no
 * se chequea acá porque los dos modales ya exigen cantidad > 0 antes.
 */
export function validarCargos(cargos: CargoCompraForm[]): string | null {
  for (const c of cargos) {
    const nombre = c.concepto.trim() || '(sin concepto)'
    if (!c.concepto.trim()) {
      return 'Hay un cargo sin concepto. Ponele un nombre (flete, pallets, separadores) o quitalo.'
    }
    for (const [lineaId, peso] of Object.entries(c.pesos)) {
      if (!Number.isFinite(peso) || peso < 0) {
        return `El cargo "${nombre}" tiene un peso inválido en la línea ${lineaId}. Los pesos son proporciones: el 0 excluye una línea, el negativo no existe.`
      }
    }
    const totalPeso = Object.values(c.pesos).reduce((acc, p) => acc + p, 0)
    if (c.prorrateaAlCosto && totalPeso === 0) {
      return `El cargo "${nombre}" no tiene ninguna línea asignada: con todos los pesos en 0 no llegaría a ningún costo. Asignale al menos una línea o destildá "se prorratea al costo".`
    }
  }
  return null
}

/**
 * Los cargos que la factura imprime como no gravados: no gravados (ni exentos)
 * Y en el papel.
 *
 * El filtro es el mismo `!gravado && enFactura` que usa `totales.noGravado` del
 * motor, y tiene que seguir siéndolo: los dos contestan la misma pregunta —qué
 * parte de esta compra el proveedor facturó fuera del IVA— y responderla
 * distinto pondría el cuadre contra la factura en rojo sin que nada esté mal.
 *
 * El flete queda afuera aunque no sea gravado: lo factura el transportista
 * aparte, así que no está en ESTE papel. Por eso el filtro mira `enFactura` y
 * no `prorrateaAlCosto`.
 */
export function cargosNoGravadosEnFactura(cargos: CargoCompraForm[]): CargoCompraForm[] {
  return cargos.filter(c => c.condicionIva !== 'gravado' && c.enFactura)
}

/**
 * Lo que suman esos cargos, que es lo que va a la cabecera "No gravado".
 *
 * Suma los MONTOS y no el prorrateo del motor a propósito: el motor reparte
 * sobre las líneas y un cargo sin ninguna línea asignada aportaría 0, pero en
 * la factura ese importe está impreso igual. La cabecera cuadra contra el
 * papel, no contra el reparto.
 */
export function noGravadoDeCargos(cargos: CargoCompraForm[]): number {
  return redondearSQL(
    cargosNoGravadosEnFactura(cargos).reduce((acc, c) => acc + (c.monto || 0), 0),
    2
  )
}

/** El II declarado que llega al motor. En ZZ la RPC lo descarta; acá también. */
export function iiDeclaradoParaMotor(
  iiDeclarado: Record<number, number>,
  tipoFactura: 'ZZ' | 'FC'
): Record<number, number> {
  return tipoFactura === 'ZZ' ? {} : iiDeclarado
}

/** Una alícuota de impuesto interno presente en la compra, calculada vs declarada. */
export interface CuadreII {
  tasa: number;
  /** II de esa alícuota SIN ajustar, tal como sale de las líneas y los cargos. */
  calculado: number;
  /** Lo que dice la factura. undefined = no se cargó. */
  declarado: number | undefined;
  /** declarado / calculado. 1 = no hay ajuste. */
  factor: number;
  /** (declarado − calculado) / calculado. 0 si no hay declarado. */
  desvio: number;
}

/**
 * Cuadre del impuesto interno alícuota por alícuota.
 *
 * El "calculado" sale del motor con la apertura VACÍA a propósito: es el número
 * contra el que se compara lo declarado, así que no puede venir ya ajustado por
 * lo declarado — daría ✓ siempre y el cuadre no diría nada.
 *
 * Las tasas se agrupan con la misma normalización a 4 decimales que usa el
 * motor: 4,1667 y 4,17 son buckets distintos a propósito (en compra_items
 * conviven las dos porque alguien tipeó 4,17), y si la factura declara sólo una
 * la otra no se ajusta y el cuadre lo muestra.
 *
 * Devuelve null si el motor no pudo calcular (un peso corrupto). El error
 * ruidoso es responsabilidad de la vista previa; acá alcanza con no mostrar un
 * cuadre inventado.
 */
export function cuadreImpuestoInterno(
  items: CompraItemForm[],
  cargos: CargoCompraForm[],
  iiDeclarado: Record<number, number>,
  tipoFactura: 'ZZ' | 'FC',
): CuadreII[] | null {
  const lineas = lineasParaMotor(items, tipoFactura)
  const declarados = iiDeclaradoParaMotor(iiDeclarado, tipoFactura)
  try {
    const sinAjuste = calcularCostosCompra(lineas, cargosParaMotor(cargos), {})
    const porLinea = new Map(sinAjuste.lineas.map(l => [l.id, l]))
    const porTasa = new Map<number, number>()
    for (const linea of lineas) {
      const tasa = redondearSQL(linea.impuestosInternos || 0, 4)
      if (tasa <= 0) continue
      const costos = porLinea.get(linea.id)
      porTasa.set(tasa, (porTasa.get(tasa) ?? 0) + (costos ? costos.iiUnitario * linea.cantidad : 0))
    }
    return Array.from(porTasa.entries())
      .sort((a, b) => a[0] - b[0])
      .map(([tasa, calculado]) => {
        const declarado = declarados[tasa]
        const hayAjuste = declarado !== undefined && calculado !== 0
        return {
          tasa,
          calculado,
          declarado,
          factor: hayAjuste ? declarado / calculado : 1,
          desvio: hayAjuste ? (declarado - calculado) / calculado : 0,
        }
      })
  } catch {
    return null
  }
}

/** Desvío a partir del cual el cuadre del II deja de ser redondeo y hay que mirarlo. */
export const DESVIO_II_TOLERADO = 0.005

/**
 * Qué bonificaciones bajan la base del impuesto interno, deducido del declarado.
 *
 * El borde del formulario para `resolverBasesII`: traduce las líneas y los
 * cargos, aplica la regla de ZZ (donde no hay apertura declarada que valga) y
 * devuelve null si el motor no pudo calcular, con el mismo criterio que
 * `cuadreImpuestoInterno` — un peso corrupto lo grita la vista previa de costos,
 * acá alcanza con no deducir nada.
 */
export function resolucionBasesII(
  items: CompraItemForm[],
  cargos: CargoCompraForm[],
  iiDeclarado: Record<number, number>,
  tipoFactura: 'ZZ' | 'FC',
): ResultadoBasesII | null {
  try {
    return resolverBasesII(
      lineasParaMotor(items, tipoFactura),
      cargosParaMotor(cargos),
      iiDeclaradoParaMotor(iiDeclarado, tipoFactura),
    )
  } catch {
    return null
  }
}

/**
 * #908 · Las bonificaciones no descontadas que sugiere la factura, desde el
 * formulario: traduce líneas y cargos al motor (con la regla de ZZ: ahí no hay
 * II declarado que valga) y saca las alícuotas que el usuario ya descartó.
 *
 * `control` lleva los totales que se usan para corroborar: el modal decide
 * cuáles son del papel (al editar, el total de referencia es el GUARDADO y no
 * el impreso, así que no corrobora nada y no se pasa).
 */
export function sugerenciasBonificacion(
  state: Pick<CompraState, 'items' | 'cargos' | 'iiDeclarado' | 'tipoFactura' | 'bonificacionesDescartadas'>,
  control: { gravadoImpreso: number; gravadoCalculado: number; totalImpreso: number; totalCalculado: number } | null,
  plantilla: CargoPlantillaCompra[] | null | undefined,
): SugerenciaBonificacion[] {
  if (state.tipoFactura === 'ZZ') return []
  const lineas = state.items.flatMap(item =>
    item.lineaId === undefined
      ? []
      : [{ ...lineaParaMotor(item, state.tipoFactura, item.lineaId), productoId: String(item.productoId) }]
  )
  const descartadas = state.bonificacionesDescartadas ?? []
  return detectarBonificacionNoDescontada({
    lineas,
    cargos: cargosParaMotor(state.cargos),
    iiDeclarado: iiDeclaradoParaMotor(state.iiDeclarado, state.tipoFactura),
    control,
    alcanceAnterior: alcanceBonificacionAnterior(plantilla),
  }).filter(s => !descartadas.includes(s.clave))
}

/**
 * #908 · Las alícuotas cuyo II declarado supera al calculado por EXACTAMENTE lo
 * que liquidó el proveedor sobre bonificaciones cargadas que no bajan la base.
 *
 * Existe para el resumen. Después de aceptar una sugerencia del caso A la
 * diferencia de esa alícuota NO desaparece: la bonificación no baja la base del
 * II (así la liquidó el proveedor), así que el calculado sigue debajo del
 * declarado y el factor proporcional del motor es el que lleva el costo al
 * declarado. El solver, con esa ecuación, no encuentra ninguna combinación que
 * cierre y diría "puede faltar un cargo", que es falso: el cargo está y explica
 * la diferencia. No se toca la cuenta del motor ni del solver (son espejo del
 * SQL); se cambia qué se le DICE al usuario.
 */
export function alicuotasIIExplicadas(
  state: Pick<CompraState, 'items' | 'cargos' | 'iiDeclarado' | 'tipoFactura'>,
): number[] {
  if (state.tipoFactura === 'ZZ') return []
  const lineas = state.items.flatMap(item =>
    item.lineaId === undefined
      ? []
      : [{ ...lineaParaMotor(item, state.tipoFactura, item.lineaId), productoId: String(item.productoId) }]
  )
  return (analizarAlicuotasII(lineas, cargosParaMotor(state.cargos), state.iiDeclarado) ?? [])
    .filter(a => a.estado === 'explicada')
    .map(a => a.tasa)
}

// Estado inicial
export const initialState: CompraState = {
  // Desglose fiscal extra (solo FC)
  percepcionIva: 0,
  percepcionIibb: 0,
  noGravado: 0,
  noGravadoManual: false,
  controlFactura:{ gravado: 0, iva: 0, impuestosInternos: 0, percepciones: 0, total: 0 },
  // Cargos y prorrateo
  cargos: [],
  iiDeclarado: {},
  // Proveedor
  proveedorId: '',
  proveedorNombre: '',
  usarProveedorNuevo: false,
  // Datos de compra
  numeroFactura: '',
  fechaCompra: fechaLocalISO(),
  formaPago: 'efectivo',
  tipoFactura: 'FC',
  notas: '',
  // Items
  items: [],
  // UI
  busquedaProducto: '',
  mostrarBuscador: false,
  modoItemRapido: false,
  guardando: false,
  error: '',
  // Escaneo
  escaneando: false,
  resultadoEscaneo: null,
  errorEscaneo: '',
  itemsPendientesScan: [],
  // Medidas (mig 278)
  medidas: CONTEXTO_MEDIDAS_VACIO,
  plantillaProveedorId: null,
  bonificacionesDescartadas: [],
}

// =============================================================================
// CARGOS: ids de línea y sincronización del vector de pesos
// =============================================================================

/**
 * Los cargos de la plantilla del proveedor que todavía no están cargados,
 * comparados por concepto normalizado.
 *
 * Existe para que el botón y el reducer no puedan discrepar: el botón dice
 * cuántos va a traer y el reducer trae exactamente esos. Sin el filtro, dos
 * clics dejan "Flete" dos veces con monto 0 y el usuario carga el importe en
 * uno de los dos — el otro queda como un cargo fantasma que no suma nada pero
 * hace fallar la RPC por no tener ninguna línea asignada.
 */
export function cargosPlantillaNuevos(
  cargos: CargoCompraForm[],
  plantilla: CargoPlantillaCompra[]
): CargoPlantillaCompra[] {
  // La misma normalización que el catálogo (mig 278): sin tildes, además de
  // minúsculas y espacios. "Bonificación" y "bonificacion" son el mismo cargo.
  const yaCargados = new Set(cargos.map(c => normalizarNombreConcepto(c.concepto)))
  return plantilla.filter(p => !yaCargados.has(normalizarNombreConcepto(p.concepto)))
}

/** Neto de una línea: cantidad × costo unitario, ya bonificado. */
function netoLinea(item: CompraItemForm): number {
  return (item.cantidad || 0) * (item.costoUnitario || 0) * (1 - (item.bonificacion || 0) / 100)
}

/**
 * Peso que le toca a una línea según la base del cargo. Sólo pre-llenado.
 *
 * A 4 decimales, que es la precisión de `compra_cargo_repartos.peso`: sin eso
 * el neto de la línea entra al campo con la cola binaria completa
 * (158823,75999999999) y el usuario ve un número que no puede leer ni corregir.
 */
function pesoPorBase(
  base: BaseProrrateo,
  item: CompraItemForm,
  medidaId: string | null | undefined = null,
  medidas: ContextoMedidas = CONTEXTO_MEDIDAS_VACIO,
): number {
  switch (base) {
    case 'monto': return redondearSQL(netoLinea(item), 4)
    case 'cantidad': return item.cantidad || 0
    // cantidad / unidades_por. Sin medida resuelta, 0: la grilla lo marca y el
    // guardado se traba hasta que se cargue o se excluya la línea con un 0.
    case 'medida': {
      const resuelta = resolverMedida(item.productoId, medidaId, medidas)
      return resuelta ? pesoPorMedida(item.cantidad || 0, resuelta.unidadesPor) : 0
    }
    default: return 1
  }
}

/**
 * ¿La línea está en el alcance del cargo? Siempre, salvo un cargo de plantilla
 * cuya compra vieja no tenía ese producto (o lo tenía en 0), o una bonificación
 * sugerida (#908) fuera de sus productos.
 */
export function lineaEnAlcance(cargo: CargoCompraForm, productoId: string | number): boolean {
  if (cargo.alcanceProductos) return cargo.alcanceProductos.includes(String(productoId))
  if (!cargo.plantilla) return true
  return (cargo.plantilla.pesosPorProducto[String(productoId)] ?? 0) > 0
}

/** El peso pre-llenado de una línea para un cargo: alcance de plantilla + base. */
function pesoPrellenado(cargo: CargoCompraForm, item: CompraItemForm, medidas: ContextoMedidas): number {
  if (!lineaEnAlcance(cargo, item.productoId)) return 0
  const p = cargo.plantilla
  if (p && cargo.baseProrrateo === p.base && cargo.baseProrrateo !== 'medida') {
    return p.pesosPorProducto[String(item.productoId)] ?? 0
  }
  return pesoPorBase(cargo.baseProrrateo, item, cargo.medidaId, medidas)
}

/**
 * Las líneas de un cargo por 'medida' que no tienen de dónde sacar las
 * unidades por medida: ni tipeadas acá, ni en la ficha, ni en la base.
 *
 * El peso tipeado a mano las saca (un 0 a mano es la exclusión explícita), y
 * también estar fuera del alcance de la plantilla.
 */
export function lineasSinMedida(
  cargo: CargoCompraForm,
  items: CompraItemForm[],
  medidas: ContextoMedidas,
): CompraItemForm[] {
  if (cargo.baseProrrateo !== 'medida' || !cargo.medidaId) return []
  return items.filter(item =>
    item.lineaId !== undefined &&
    !cargo.pesosManuales[item.lineaId] &&
    lineaEnAlcance(cargo, item.productoId) &&
    resolverMedida(item.productoId, cargo.medidaId, medidas) === null
  )
}

/**
 * Lo que la medida no deja guardar: un cargo por medida sin medida elegida, o
 * una línea sin unidades por medida. Bloquea A PROPÓSITO (decisión del dueño):
 * guardar con esa línea en 0 la sacaría del cargo en silencio, que es lo mismo
 * que repartir mal. La salida explícita es poner 0 de peso en esa línea.
 */
export function validarMedidasCargos(
  cargos: CargoCompraForm[],
  items: CompraItemForm[],
  medidas: ContextoMedidas,
): string | null {
  for (const c of cargos) {
    if (c.baseProrrateo !== 'medida') continue
    const nombre = c.concepto.trim() || '(sin concepto)'
    if (!c.medidaId) {
      return `El cargo "${nombre}" reparte por medida pero no tiene medida elegida (pallet, separador...).`
    }
    const faltan = lineasSinMedida(c, items, medidas)
    if (faltan.length > 0) {
      const lista = faltan.slice(0, 3).map(i => `"${i.productoNombre}"`).join(', ')
      const resto = faltan.length > 3 ? ` y ${faltan.length - 3} más` : ''
      return `El cargo "${nombre}" reparte por medida y no sabe cuántas unidades entran de ${lista}${resto}. Cargalas en el reparto, o poné 0 de peso para dejar la línea afuera.`
    }
  }
  return null
}

/**
 * Suma un lote de líneas nuevas sobre las que ya hay, una sola línea por
 * producto — la misma regla que `AGREGAR_ITEM`, que suma la cantidad en vez de
 * apilar un renglón repetido.
 *
 * El import de Excel y el escaneo apilaban: dos renglones del mismo producto en
 * la misma factura quedaban como dos `compra_items`, y todo lo que indexa los
 * items por `producto_id` los pisaba o los contaba dos veces (la nota de crédito
 * acreditaba el doble; el UNIQUE de `producto_lotes` de la mig 223 obliga a
 * agrupar los vencimientos por producto igual).
 *
 * LO QUE GANA AL FUSIONAR es la línea que ya estaba: su costo, su bonificación y
 * sus atributos fiscales. Si el segundo renglón traía otro precio, ese precio no
 * entra —y el subtotal deja de cuadrar contra el papel, que es justo lo que el
 * panel "Control contra factura" pinta en rojo—. Es la misma resolución que
 * aplica `AGREGAR_ITEM` cuando se agrega dos veces el mismo producto.
 */
function fusionarItems(existentes: CompraItemForm[], nuevos: CompraItemForm[]): CompraItemForm[] {
  const salida = [...existentes]
  const indicePorProducto = new Map<string, number>()
  salida.forEach((item, i) => indicePorProducto.set(String(item.productoId), i))

  for (const nuevo of nuevos) {
    const clave = String(nuevo.productoId)
    const i = indicePorProducto.get(clave)
    if (i === undefined) {
      indicePorProducto.set(clave, salida.length)
      salida.push(nuevo)
      continue
    }
    const previo = salida[i]
    const vencimientos = [...(previo.vencimientos ?? []), ...(nuevo.vencimientos ?? [])]
    salida[i] = {
      ...previo,
      cantidad: (previo.cantidad || 0) + (nuevo.cantidad || 0),
      // Sólo si alguno de los dos los traía: un `[]` donde antes había
      // `undefined` significaría "esta línea no carga vencimientos".
      ...(vencimientos.length > 0 ? { vencimientos } : {}),
    }
  }
  return salida
}

/** Numera las líneas que llegaron sin id local (importadas, escaneadas). */
function conLineaIds(items: CompraItemForm[]): CompraItemForm[] {
  if (items.every(i => i.lineaId !== undefined)) return items
  let proximo = items.reduce((max, i) => Math.max(max, i.lineaId ?? 0), 0) + 1
  return items.map(i => (i.lineaId !== undefined ? i : { ...i, lineaId: proximo++ }))
}

/**
 * Deja el vector de pesos de cada cargo alineado con las líneas que hay.
 *
 * Corre después de CUALQUIER cambio de items, no sólo al agregar o quitar una
 * línea: con la base en `monto` o en `cantidad`, tocar un costo o una cantidad
 * cambia el peso, y un vector viejo repartiría el flete con los números de
 * antes sin que nada lo avise.
 *
 * Lo que el usuario tipeó a mano no se pisa nunca acá: sobrevive mientras
 * exista la línea. La única forma de volver a la regla es re-elegir la base de
 * reparto (`ACTUALIZAR_CARGO` limpia las marcas), que es un gesto explícito;
 * sin esa salida un peso manual quedaría clavado para siempre.
 *
 * Las líneas borradas desaparecen del vector: si quedaran, `prorratearCargo`
 * les asignaría plata y la grilla dejaría de sumar el monto del cargo.
 */
function sincronizarCargos(
  cargos: CargoCompraForm[],
  items: CompraItemForm[],
  medidas: ContextoMedidas = CONTEXTO_MEDIDAS_VACIO,
): CargoCompraForm[] {
  if (cargos.length === 0) return cargos
  return cargos.map(cargo => {
    const pesos: PesosCargo = {}
    const pesosManuales: Record<number, true> = {}
    for (const item of items) {
      const id = item.lineaId
      if (id === undefined) continue
      if (cargo.pesosManuales[id] && cargo.pesos[id] !== undefined) {
        pesos[id] = cargo.pesos[id]
        pesosManuales[id] = true
      } else if (cargo.cantidadesReferencia && cargo.pesos[id] === undefined) {
        // Un cargo GUARDADO (se está editando la compra) y una línea que se
        // agregó en esta edición: entra excluida (0, manual). Su vector es el
        // que quedó registrado —en la 304 el flete va por pallets y la
        // bonificación sólo toca el 3L— y pre-llenar la línea nueva con la base
        // le movería el costo a las demás sin que nadie lo pida. Si tiene que
        // pagar parte del cargo, se le pone el peso a mano en la grilla.
        pesos[id] = 0
        pesosManuales[id] = true
      } else {
        pesos[id] = pesoPrellenado(cargo, item, medidas)
      }
    }
    return { ...cargo, pesos, pesosManuales }
  })
}

/**
 * Escribe en los cargos lo que el impuesto interno declarado permite deducir.
 *
 * Sólo si la deducción es ÚNICA. Con más de una combinación que cierre, o con
 * ninguna, no se toca nada: el modal avisa y el ajuste proporcional del motor
 * sigue siendo la red de seguridad, pero dicho como lo que es —una aproximación—
 * y no disfrazado de decisión.
 *
 * Los indeterminables no aparecen en la asignación, así que conservan su valor:
 * sobre ellos el solver no tiene nada que decir y pisarlos sería inventar.
 *
 * Devuelve el MISMO array si nada cambió. El punto fijo importa: aplicar la
 * solución cambia `afectaBaseII` de los candidatos, y volver a correr el solver
 * sobre el estado nuevo tiene que dar la misma solución —la búsqueda no mira el
 * valor actual de un candidato, sólo el de los no candidatos— o el reducer
 * quedaría oscilando entre dos estados en cada tecla.
 */
function resolverAfectaBaseII(
  cargos: CargoCompraForm[],
  items: CompraItemForm[],
  iiDeclarado: Record<number, number>,
  tipoFactura: 'ZZ' | 'FC',
): CargoCompraForm[] {
  const resolucion = resolucionBasesII(items, cargos, iiDeclarado, tipoFactura)
  if (resolucion?.estado !== 'unica') return cargos
  const deducido = resolucion.soluciones[0].asignacion
  let cambio = false
  const salida = cargos.map(c => {
    const valor = deducido[c.id]
    if (valor === undefined || c.afectaBaseIIManual || c.afectaBaseII === valor) return c
    cambio = true
    return { ...c, afectaBaseII: valor }
  })
  return cambio ? salida : cargos
}

// Reducer
function aplicarAccion(state: CompraState, action: CompraActionType): CompraState {
  switch (action.type) {
    case 'SET_PROVEEDOR_ID':
      return { ...state, proveedorId: action.payload }
    case 'SET_PROVEEDOR_NOMBRE':
      return { ...state, proveedorNombre: action.payload }
    case 'SET_USAR_PROVEEDOR_NUEVO':
      return { ...state, usarProveedorNuevo: action.payload }
    case 'SET_NUMERO_FACTURA':
      return { ...state, numeroFactura: action.payload }
    case 'SET_FECHA_COMPRA':
      return { ...state, fechaCompra: action.payload }
    case 'SET_FORMA_PAGO':
      return { ...state, formaPago: action.payload }
    case 'SET_TIPO_FACTURA':
      return { ...state, tipoFactura: action.payload }
    case 'SET_NOTAS':
      return { ...state, notas: action.payload }
    case 'SET_BUSQUEDA':
      return { ...state, busquedaProducto: action.payload, mostrarBuscador: true }
    case 'SET_MOSTRAR_BUSCADOR':
      return { ...state, mostrarBuscador: action.payload }
    case 'SET_GUARDANDO':
      return { ...state, guardando: action.payload }
    case 'SET_ERROR':
      return { ...state, error: action.payload }

    case 'AGREGAR_ITEM': {
      const producto = action.payload
      const existente = state.items.find(i => i.productoId === producto.id)

      if (existente) {
        return {
          ...state,
          items: state.items.map(i =>
            i.productoId === producto.id
              ? { ...i, cantidad: i.cantidad + 1 }
              : i
          ),
          busquedaProducto: '',
          mostrarBuscador: false
        }
      }

      return {
        ...state,
        items: [...state.items, {
          productoId: producto.id,
          productoNombre: producto.nombre,
          productoCodigo: producto.codigo,
          cantidad: 1,
          bonificacion: 0,
          costoUnitario: producto.costo_sin_iva || 0,
          impuestosInternos: producto.impuestos_internos || 0,
          porcentajeIva: producto.porcentaje_iva ?? 21,
          condicionIva: producto.condicion_iva ?? 'gravado',
          stockActual: producto.stock
        }],
        busquedaProducto: '',
        mostrarBuscador: false
      }
    }

    case 'ACTUALIZAR_ITEM':
      return {
        ...state,
        items: state.items.map((item, i) =>
          i === action.payload.index
            ? {
                ...item,
                [action.payload.campo]: action.payload.valor,
              }
            : item
        )
      }

    case 'SET_CONDICION_ITEM': {
      const opcion = OPCIONES_CONDICION_IVA.find(o => o.clave === action.payload.clave)
      if (!opcion) return state
      return {
        ...state,
        items: state.items.map((item, i) =>
          i === action.payload.index
            ? { ...item, condicionIva: opcion.condicion, porcentajeIva: opcion.porcentaje }
            : item
        )
      }
    }

    case 'SET_VENCIMIENTOS_ITEM':
      return {
        ...state,
        items: state.items.map((item, i) =>
          i === action.payload.index
            ? { ...item, vencimientos: action.payload.vencimientos }
            : item
        )
      }

    case 'ELIMINAR_ITEM':
      return {
        ...state,
        items: state.items.filter((_, i) => i !== action.payload)
      }

    case 'LIMPIAR_BUSQUEDA':
      return { ...state, busquedaProducto: '', mostrarBuscador: false }

    case 'SET_MODO_ITEM_RAPIDO':
      return { ...state, modoItemRapido: action.payload }

    case 'AGREGAR_ITEM_RAPIDO': {
      const { productoId, nombre, codigo, costoUnitario, impuestosInternos } = action.payload
      return {
        ...state,
        items: [...state.items, {
          productoId,
          productoNombre: nombre,
          productoCodigo: codigo,
          cantidad: 1,
          bonificacion: 0,
          costoUnitario,
          // La que la base derivó del encuadre elegido en el alta (mig 277).
          // Antes nacía en 0 siempre: así quedaron sin impuesto interno en el
          // costo la Citrus 3L y la Cola Lata dadas de alta desde una factura.
          impuestosInternos: impuestosInternos ?? 0,
          porcentajeIva: 21,
          condicionIva: 'gravado',
          stockActual: 0
        }],
        modoItemRapido: false,
        busquedaProducto: '',
        mostrarBuscador: false
      }
    }

    case 'IMPORTAR_ITEMS':
      return {
        ...state,
        items: fusionarItems(state.items, action.payload)
      }

    case 'SET_ESCANEANDO':
      return { ...state, escaneando: action.payload, errorEscaneo: '' }

    case 'SET_RESULTADO_ESCANEO':
      return { ...state, resultadoEscaneo: action.payload, escaneando: false }

    case 'SET_ERROR_ESCANEO':
      return { ...state, errorEscaneo: action.payload, escaneando: false }

    case 'APLICAR_ESCANEO': {
      const { proveedorId, proveedorNombre, numeroFactura, fechaCompra, formaPago, items, pendientes } = action.payload
      return {
        ...state,
        proveedorId,
        proveedorNombre,
        usarProveedorNuevo: !proveedorId && !!proveedorNombre,
        numeroFactura,
        fechaCompra: fechaCompra || state.fechaCompra,
        formaPago: formaPago || state.formaPago,
        // El escaneo REEMPLAZA las líneas, pero se fusiona igual: la fusión es
        // dentro del lote escaneado, que puede traer el mismo producto en dos
        // renglones de la misma factura.
        items: fusionarItems([], items),
        itemsPendientesScan: pendientes,
        resultadoEscaneo: null,
        errorEscaneo: ''
      }
    }

    case 'RESOLVER_PENDIENTE_VINCULAR':
    case 'RESOLVER_PENDIENTE_CREAR': {
      const { index, producto } = action.payload
      const scanItem = state.itemsPendientesScan[index]
      if (!scanItem) return state
      const nuevoItem = construirCompraItemDesdeScan(producto, scanItem)
      // Si ya existe un item con el mismo productoId, sumar cantidades
      const existenteIdx = state.items.findIndex(i => i.productoId === producto.id)
      const itemsActualizados = existenteIdx >= 0
        ? state.items.map((i, idx) =>
            idx === existenteIdx
              ? { ...i, cantidad: i.cantidad + nuevoItem.cantidad }
              : i
          )
        : [...state.items, nuevoItem]
      return {
        ...state,
        items: itemsActualizados,
        itemsPendientesScan: state.itemsPendientesScan.filter((_, i) => i !== index)
      }
    }

    case 'RESOLVER_PENDIENTE_OMITIR': {
      const { index } = action.payload
      return {
        ...state,
        itemsPendientesScan: state.itemsPendientesScan.filter((_, i) => i !== index)
      }
    }

    case 'LIMPIAR_PENDIENTES_SCAN':
      return { ...state, itemsPendientesScan: [] }

    case 'SET_EXTRAS':
      return {
        ...state,
        ...action.payload,
        // Tocar el campo lo saca del pre-llenado, igual que tipear un peso.
        // Se mira la CLAVE y no el valor: escribir un 0 sobre un pre-llenado de
        // 170.800 es "la factura no trae no gravado", que es un dato, no un
        // campo vacío.
        noGravadoManual: action.payload.noGravado !== undefined ? true : state.noGravadoManual,
      }

    case 'USAR_NO_GRAVADO_DE_CARGOS':
      // El wrapper recalcula el importe: acá sólo se suelta la marca de manual.
      return { ...state, noGravadoManual: false }

    case 'SET_CONTROL':
      return { ...state, controlFactura: { ...state.controlFactura, ...action.payload } }

    case 'APLICAR_BONIF_GLOBAL':
      return {
        ...state,
        items: state.items.map(item => ({ ...item, bonificacion: action.payload }))
      }

    case 'AGREGAR_CARGO': {
      const id = state.cargos.reduce((max, c) => Math.max(max, c.id), 0) + 1
      return {
        ...state,
        cargos: [...state.cargos, {
          id,
          concepto: '',
          monto: 0,
          // Defaults de la mig 192: el caso típico (flete, pallets) no lleva IVA,
          // viene en el papel y entra al costo.
          condicionIva: 'no_gravado',
          enFactura: true,
          prorrateaAlCosto: true,
          afectaBaseII: false,
          afectaBaseIIManual: false,
          baseProrrateo: 'monto',
          conceptoId: null,
          medidaId: null,
          // El wrapper los pre-llena con la base recién elegida.
          pesos: {},
          pesosManuales: {},
        }],
      }
    }

    case 'APLICAR_PLANTILLA_PROVEEDOR': {
      const { proveedorId, cargos: plantilla } = action.payload
      // Los de plantilla que nadie tocó y siguen sin monto son del proveedor
      // anterior: se van. Lo tocado (o con monto) es trabajo del usuario y queda.
      const conservados = state.cargos.filter(c => !(c.plantilla && !c.plantilla.tocado && !c.monto))
      const nuevos = cargosPlantillaNuevos(conservados, plantilla)
      let ultimoId = state.cargos.reduce((max, c) => Math.max(max, c.id), 0)
      return {
        ...state,
        plantillaProveedorId: proveedorId,
        cargos: [...conservados, ...nuevos.map((p): CargoCompraForm => ({
          id: ++ultimoId,
          concepto: p.concepto,
          conceptoId: p.conceptoId ?? null,
          medidaId: p.medidaId ?? null,
          // El monto NO se reusa: es lo único que cambia en cada factura.
          monto: 0,
          condicionIva: p.condicionIva,
          enFactura: p.enFactura,
          prorrateaAlCosto: p.prorrateaAlCosto,
          // Misma invariante que ACTUALIZAR_CARGO: el flag sólo existe para un
          // cargo gravado. Una fila vieja con la combinación imposible entra
          // saneada en vez de propagar estado invisible.
          afectaBaseII: p.condicionIva === 'gravado' && p.afectaBaseII,
          // La plantilla NO es una decisión manual: es lo que el proveedor hizo
          // la factura pasada, y el solver de esta factura la pisa si puede
          // deducir otra cosa.
          afectaBaseIIManual: false,
          baseProrrateo: p.baseProrrateo,
          // Los llena el wrapper con el alcance de la plantilla: no son
          // manuales, así cada línea que llegue después —a mano, por Excel o
          // por el escaneo— entra con la misma regla.
          pesos: {},
          pesosManuales: {},
          plantilla: { pesosPorProducto: p.pesosPorProducto, base: p.baseProrrateo, tocado: false },
        }))],
      }
    }

    case 'ELEGIR_CONCEPTO': {
      const { id, concepto } = action.payload
      return {
        ...state,
        cargos: state.cargos.map(c => {
          if (c.id !== id) return c
          const base = concepto.baseProrrateo
          const medidaId = base === 'medida' ? concepto.medidaId : (c.medidaId ?? null)
          const cambiaReparto = base !== c.baseProrrateo || (base === 'medida' && medidaId !== c.medidaId)
          const magnitud = Math.abs(c.monto)
          const actualizado: CargoCompraForm = {
            ...c,
            concepto: concepto.nombre,
            conceptoId: concepto.id,
            conceptoNuevo: false,
            // El signo del catálogo pone el toggle; el monto sigue siendo el que
            // se tipeó, con ese signo. Nadie lo multiplica dos veces.
            monto: concepto.signo < 0 ? -magnitud : magnitud,
            condicionIva: concepto.condicionIva,
            enFactura: concepto.enFactura,
            prorrateaAlCosto: concepto.prorrateaAlCosto,
            baseProrrateo: base,
            medidaId,
            ...(c.plantilla ? { plantilla: { ...c.plantilla, tocado: true } } : {}),
          }
          // afecta_base_ii NO viene del catálogo: lo deduce el solver. Sólo se
          // sanea si el concepto no es gravado, como en ACTUALIZAR_CARGO.
          if (actualizado.condicionIva !== 'gravado') {
            actualizado.afectaBaseII = false
            actualizado.afectaBaseIIManual = false
          }
          // Otra base (u otra medida) es pedir el pre-llenado, como elegirla en
          // el select. Si el reparto no cambia, los pesos tipeados quedan.
          if (cambiaReparto) {
            actualizado.pesosManuales = {}
            delete actualizado.cantidadesReferencia
          }
          return actualizado
        }),
      }
    }

    case 'CREAR_CONCEPTO': {
      const { id, nombre } = action.payload
      return {
        ...state,
        cargos: state.cargos.map(c => c.id !== id ? c : {
          ...c,
          concepto: nombre.trim(),
          conceptoId: null,
          conceptoNuevo: true,
          ...(c.plantilla ? { plantilla: { ...c.plantilla, tocado: true } } : {}),
        }),
      }
    }

    case 'SET_MEDIDAS_REFERENCIA':
      return {
        ...state,
        medidas: { ...state.medidas, bases: action.payload.bases, ficha: action.payload.ficha },
      }

    case 'SET_MEDIDA_LINEA': {
      const { productoId, medidaId, unidadesPor } = action.payload
      const medidas = conValorDeCompra(state.medidas, productoId, medidaId, unidadesPor)
      // Tipear las unidades de una línea ES pedir el pre-llenado de esa línea en
      // los cargos que reparten con esa medida (o con una que cae a ella): se le
      // saca la marca de manual para que el wrapper la recalcule.
      const lineas = state.items
        .filter(i => String(i.productoId) === String(productoId) && i.lineaId !== undefined)
        .map(i => i.lineaId as number)
      const cargos = state.cargos.map(c => {
        if (c.baseProrrateo !== 'medida' || !c.medidaId) return c
        const usaLaMedida = c.medidaId === medidaId || medidas.bases[c.medidaId] === medidaId
        if (!usaLaMedida || !lineas.some(l => c.pesosManuales[l])) return c
        const pesosManuales = { ...c.pesosManuales }
        for (const l of lineas) delete pesosManuales[l]
        return { ...c, pesosManuales }
      })
      return { ...state, medidas, cargos }
    }

    case 'SET_GUARDAR_EN_FICHA': {
      const { productoId, medidaId, guardar } = action.payload
      const valor = state.medidas.compra[productoId]?.[medidaId]
      if (!valor) return state
      return {
        ...state,
        medidas: {
          ...state.medidas,
          compra: {
            ...state.medidas.compra,
            [productoId]: { ...state.medidas.compra[productoId], [medidaId]: { ...valor, guardarEnFicha: guardar } },
          },
        },
      }
    }

    case 'ACTUALIZAR_CARGO': {
      const { id, cambios } = action.payload
      return {
        ...state,
        cargos: state.cargos.map(c => {
          if (c.id !== id) return c
          const actualizado = { ...c, ...cambios }
          // Cualquier edición lo saca de "plantilla sin tocar": cambiar de
          // proveedor ya no lo reemplaza.
          if (actualizado.plantilla) actualizado.plantilla = { ...actualizado.plantilla, tocado: true }
          // Escribir el concepto a mano lo despega del catálogo.
          if (cambios.concepto !== undefined) {
            actualizado.conceptoId = null
            actualizado.conceptoNuevo = false
          }
          // Tildar el casillero a mano lo saca de lo que deduce el solver, igual
          // que tipear un peso lo saca del pre-llenado. Se mira la CLAVE y no el
          // valor: destildar lo que el solver había prendido es una decisión
          // tanto como prenderlo.
          if (cambios.afectaBaseII !== undefined) actualizado.afectaBaseIIManual = true
          // El flag de base de II sólo existe para un cargo gravado: el motor lo
          // mira como `gravado && afectaBaseII`. Dejarlo prendido bajo una
          // condición que lo ignora es estado invisible que reaparece solo al
          // volver a "gravado", y además se persistiría así. Se va con la marca
          // de manual: la decisión era sobre un cargo gravado, y si vuelve a
          // serlo el solver tiene que poder opinar de nuevo.
          if (actualizado.condicionIva !== 'gravado') {
            actualizado.afectaBaseII = false
            actualizado.afectaBaseIIManual = false
          }
          // Elegir la base ES pedir el pre-llenado, así que borra las marcas de
          // manual y el wrapper recalcula el vector entero. Es la única salida
          // del usuario que se arrepintió de un peso tipeado a mano.
          if (cambios.baseProrrateo !== undefined || cambios.medidaId !== undefined) {
            actualizado.pesosManuales = {}
            // Re-elegir la base de un cargo guardado lo vuelve un cargo como
            // los de la carga: el pre-llenado sigue a la cantidad, y sin pesos
            // manuales no hay nada que pueda quedar desactualizado.
            delete actualizado.cantidadesReferencia
          }
          return actualizado
        }),
      }
    }

    case 'ELIMINAR_CARGO':
      return { ...state, cargos: state.cargos.filter(c => c.id !== action.payload) }

    case 'SET_PESO_CARGO': {
      const { cargoId, lineaId, peso } = action.payload
      // El peso se guarda tal cual llega: normalizarlo acá volvería un dato
      // corrupto indistinguible de un 0 deliberado, que es justo el mecanismo
      // de exclusión. Quien parsea es el formulario; quien avisa, la grilla.
      // Al editar, tipear el peso lo fija contra la cantidad de AHORA: deja de
      // estar desactualizado.
      const cantidadLinea = state.items.find(i => i.lineaId === lineaId)?.cantidad
      return {
        ...state,
        cargos: state.cargos.map(c =>
          c.id === cargoId
            ? {
                ...c,
                pesos: { ...c.pesos, [lineaId]: peso },
                pesosManuales: { ...c.pesosManuales, [lineaId]: true },
                ...(c.plantilla ? { plantilla: { ...c.plantilla, tocado: true } } : {}),
                ...(c.cantidadesReferencia && cantidadLinea !== undefined
                  ? { cantidadesReferencia: { ...c.cantidadesReferencia, [lineaId]: cantidadLinea } }
                  : {}),
              }
            : c
        ),
      }
    }

    case 'PRECARGAR_VENCIMIENTOS':
      return {
        ...state,
        items: state.items.map(item => {
          const vencimientos = action.payload[String(item.productoId)]
          return vencimientos ? { ...item, vencimientos } : item
        }),
      }

    case 'RECALCULAR_PESOS_DESACTUALIZADOS':
      return {
        ...state,
        cargos: state.cargos.map(c =>
          c.id === action.payload.cargoId ? recalcularPesosDesactualizados(c, state.items) : c
        ),
      }

    case 'SET_II_DECLARADO': {
      const { tasa, monto } = action.payload
      const iiDeclarado = { ...state.iiDeclarado }
      // Sin monto se BORRA la clave, no se guarda un 0: con declarado 0 y
      // calculado > 0 el factor de ajuste da 0 y el impuesto interno de esa
      // alícuota se borra entero. Vaciar el campo significa "no declarado".
      if (monto) iiDeclarado[tasa] = monto
      else delete iiDeclarado[tasa]
      return { ...state, iiDeclarado }
    }

    case 'AGREGAR_BONIFICACION_SUGERIDA': {
      const { sugerencia, concepto } = action.payload
      const productos = state.items
        .filter(i => i.lineaId !== undefined && sugerencia.lineaIds.includes(i.lineaId))
        .map(i => String(i.productoId))
      // Sin alcance (caso B con varias alícuotas y sin compra anterior) es
      // legal: el cargo entra con todos los pesos en 0 y el usuario elige las
      // líneas en la grilla; `validarCargos` traba el guardado hasta entonces.
      const sinAlcance = sugerencia.alcance === 'sin_alcance'
      if ((!sinAlcance && productos.length === 0) || !(sugerencia.monto > 0)) return state
      // El renglón de bonificación que trajo la plantilla y quedó sin monto es
      // el lugar que esta sugerencia viene a llenar: se reemplaza en vez de
      // dejar un "Bonificación $0" al lado que al guardar preguntaría si quitarlo.
      const cargos = state.cargos.filter(c => !(
        c.plantilla && !c.monto && c.condicionIva === 'gravado' && esConceptoBonificacion(c.concepto)
      ))
      const id = state.cargos.reduce((max, c) => Math.max(max, c.id), 0) + 1
      return {
        ...state,
        cargos: [...cargos, {
          id,
          concepto: concepto?.nombre ?? 'Bonificación',
          conceptoId: concepto?.id ?? null,
          medidaId: null,
          monto: -redondearSQL(sugerencia.monto, 2),
          condicionIva: 'gravado',
          enFactura: true,
          prorrateaAlCosto: true,
          // Caso A: lo decide el solver con el II declarado, como en cualquier
          // cargo gravado (deja `false`). Caso B: el II YA cierra sin este cargo,
          // así que `false` es la única respuesta compatible con la factura; se
          // fija a mano para que ninguna deducción posterior lo prenda.
          afectaBaseII: false,
          afectaBaseIIManual: sugerencia.caso === 'papel',
          baseProrrateo: 'monto',
          // Los llena el wrapper: neto de cada línea del alcance, 0 fuera.
          pesos: {},
          pesosManuales: {},
          alcanceProductos: productos,
        }],
      }
    }

    case 'DESCARTAR_BONIFICACION_SUGERIDA':
      if (state.bonificacionesDescartadas.includes(action.payload.clave)) return state
      return { ...state, bonificacionesDescartadas: [...state.bonificacionesDescartadas, action.payload.clave] }

    case 'HIDRATAR':
      // Tal cual llega; `compraReducer` además lo deja pasar sin re-sincronizar.
      return action.payload

    default:
      return state
  }
}

/**
 * El reducer real: aplica la acción y después deja el estado consistente.
 *
 * Numerar las líneas y re-sincronizar los pesos acá —y no adentro de cada
 * case— es deliberado: los items se reemplazan desde siete acciones distintas
 * (alta, alta rápida, import de Excel, escaneo, dos resoluciones de pendientes,
 * bonificación global) y olvidarse en una sola dejaría un cargo repartiendo
 * sobre líneas que ya no existen.
 *
 * El no gravado de cabecera sigue a los cargos por la misma razón: cambiar el
 * monto de los pallets o destildarles "viene en la factura" cambia lo que el
 * papel dice fuera del IVA, y un número viejo ahí pone el cuadre en rojo.
 *
 * Y `afectaBaseII` sigue al impuesto interno declarado, que es el dato con el
 * que se deduce. Por eso el guard mira también `iiDeclarado` y `tipoFactura`:
 * tipear el declarado no toca ni las líneas ni los cargos, y sin eso la
 * deducción no correría justo cuando aparece la información que la habilita.
 */
export function compraReducer(state: CompraState, action: CompraActionType): CompraState {
  // Hidratar NO pasa por el wrapper. Lo que llega es un estado ya consistente
  // —un borrador que salió de este mismo reducer, o una compra guardada
  // (utils/hidratarCompra)— y en el segundo caso re-sincronizar no es inocuo:
  // `sincronizarCargos`, `pesoPorBase` y `resolverAfectaBaseII` son
  // PRE-LLENADOS, y sobre una compra guardada cualquier cosa que recalculen
  // cambia el costo que se ve respecto del que se guardó. La hidratación ya
  // marca todo como manual; esto es la segunda llave.
  if (action.type === 'HIDRATAR') return action.payload
  const next = aplicarAccion(state, action)
  if (
    next.items === state.items &&
    next.cargos === state.cargos &&
    next.noGravadoManual === state.noGravadoManual &&
    next.iiDeclarado === state.iiDeclarado &&
    next.tipoFactura === state.tipoFactura &&
    next.medidas === state.medidas
  ) return next
  const items = conLineaIds(next.items)
  const cargos = resolverAfectaBaseII(
    sincronizarCargos(next.cargos, items, next.medidas), items, next.iiDeclarado, next.tipoFactura)
  return {
    ...next,
    items,
    cargos,
    noGravado: next.noGravadoManual ? next.noGravado : noGravadoDeCargos(cargos),
  }
}
