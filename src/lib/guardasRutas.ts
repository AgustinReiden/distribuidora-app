/**
 * Guardas de rol de las rutas del router (#863).
 *
 * Qué es: la tabla ruta → (quién entra, adónde rebota el que no entra) de las
 * rutas con restricción de `src/App.tsx`. Es lógica pura, sin React.
 *
 * Quién la usa: `App.tsx` arma cada `<Route>` guardado con el helper `guardar`,
 * que lee esta tabla; no hay ningún `isAdmin ? <X /> : <Navigate …>` escrito a
 * mano en el bloque de rutas. Mover el predicado de una ruta acá cambia lo que
 * hace el router, y `guardasRutas.test.ts` lo vigila de dos lados: la matriz
 * rol × ruta de ese test, escrita a mano y NO derivada de esta tabla, es el
 * contrato de lo que cada rol puede abrir; y un chequeo estructural lee
 * `App.tsx` como texto para que ninguna ruta guardada quede fuera de la tabla
 * ni escriba su guarda por afuera. Si un cambio de acceso es a propósito, se
 * cambia la tabla y la matriz en el mismo PR.
 *
 * Qué NO es: esto NO reemplaza a `TopNavigation`. El menú tiene su propia tabla
 * de lo que MUESTRA (`RUTAS_PERMITIDAS_POR_ROL` en `TopNavigation.test.tsx`);
 * que una ruta no aparezca en el menú no la cierra, y que el router la deje
 * entrar no la pone en el menú. Son dos cosas y se prueban por separado.
 */

/**
 * Los flags de rol que usan las guardas, tal como los deriva `MainAppInner`
 * (rol efectivo de la sucursal). Son sólo los que las guardas leen hoy;
 * `isAdminOrEncargado` no es un flag: se deriva acá adentro.
 */
export interface FlagsRutas {
  isAdmin: boolean
  isPreventista: boolean
  isEncargado: boolean
  isDeposito: boolean
  /**
   * Rol primario transportista O rol extra de transportista (mig 155): es el
   * único flag que suma capacidades extra, igual que en `MainAppInner`.
   */
  isTransportista: boolean
}

export interface GuardaRuta {
  /** ¿Este rol puede abrir la ruta? */
  permite: (flags: FlagsRutas) => boolean
  /** Adónde va el `<Navigate>` cuando NO la puede abrir. */
  sino: string
  /**
   * Si está, la ruta no monta nada: el que SÍ puede abrirla es redirigido acá.
   * Es el caso de una ruta que sólo se conserva para no romper links guardados.
   */
  redirigeA?: string
}

const esAdminOrEncargado = (f: FlagsRutas): boolean => f.isAdmin || f.isEncargado

const A_PEDIDOS = '/pedidos'

/**
 * Rutas con guarda de rol. La clave es el `path` del `<Route>` de App.tsx.
 * Cada predicado es el que tenía App.tsx antes de la extracción: ningún rol
 * ganó ni perdió una ruta. Lo que cambió después lleva su issue al lado
 * (el transportista en /mis-entregas y /rendiciones, #723/#724).
 */
export const GUARDAS_RUTAS = {
  '/dashboard': {
    permite: f => f.isAdmin || f.isPreventista,
    sino: A_PEDIDOS,
  },
  // "Hoy" del preventista (WP-48, #773): sólo el rol primario preventista, que
  // es el que lo ve en el menú. El admin NO entra (#863).
  '/hoy': {
    permite: f => f.isPreventista,
    sino: A_PEDIDOS,
  },
  // #723: el transportista ve lo que repartió (otra RPC, misma pantalla).
  '/mis-entregas': {
    permite: f => f.isPreventista || f.isTransportista || esAdminOrEncargado(f),
    sino: A_PEDIDOS,
  },
  '/reportes': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
  '/usuarios': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
  '/configuracion': {
    permite: esAdminOrEncargado,
    sino: A_PEDIDOS,
  },
  '/recorridos': {
    permite: esAdminOrEncargado,
    sino: A_PEDIDOS,
  },
  '/recorrido-preventista': {
    permite: esAdminOrEncargado,
    sino: A_PEDIDOS,
  },
  '/compras': {
    permite: esAdminOrEncargado,
    sino: A_PEDIDOS,
  },
  '/proveedores': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
  // Clientes: todos menos depósito (#999). La lista muestra el saldo de cada
  // cliente y la ficha el límite de crédito, y depósito no ve montos: la RLS ya
  // no le devuelve clientes, así que entrar sería ver una lista vacía. Lo que
  // necesita de un cliente (nombre y dirección) le llega en las hojas de ruta.
  '/clientes': {
    permite: f => !f.isDeposito,
    sino: A_PEDIDOS,
  },
  // Vencimientos por lote (migs 223/224): depósito entra además de
  // admin/encargado. App.tsx lo escribía como `effectiveRol === 'deposito'`,
  // que es exactamente cómo se deriva `isDeposito`.
  '/vencimientos': {
    permite: f => esAdminOrEncargado(f) || f.isDeposito,
    sino: A_PEDIDOS,
  },
  // Las condiciones mayoristas viven dentro de Productos. La ruta sigue
  // existiendo sólo para no romper links guardados: el admin que entra no ve
  // un container, es redirigido; el resto rebota a /pedidos como siempre.
  '/condiciones-mayoristas': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
    redirigeA: '/productos?vista=condiciones',
  },
  '/horarios-clientes': {
    permite: esAdminOrEncargado,
    sino: A_PEDIDOS,
  },
  '/promociones': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
  '/transferencias': {
    permite: esAdminOrEncargado,
    sino: A_PEDIDOS,
  },
  // #724: el transportista entra a ver sólo su propia fila y sin acciones de
  // control; la que recorta es la RPC (obtener_resumen_rendiciones), no esto.
  '/rendiciones': {
    permite: f => esAdminOrEncargado(f) || f.isTransportista,
    sino: A_PEDIDOS,
  },
  '/salvedades': {
    permite: esAdminOrEncargado,
    sino: A_PEDIDOS,
  },
  '/analytics': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
  '/comisiones': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
  '/metas': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
  '/reportes-gerenciales': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
  // Es la única guarda que rebota a /dashboard y no a /pedidos. Es así desde
  // antes de esta tabla y se conserva tal cual: acá no se decide si es a
  // propósito. Quien no tiene dashboard sigue de largo hasta /pedidos.
  '/bot-telegram': {
    permite: f => f.isAdmin,
    sino: '/dashboard',
  },
  '/geolocalizacion': {
    permite: f => f.isAdmin,
    sino: A_PEDIDOS,
  },
} satisfies Record<string, GuardaRuta>

export type RutaGuardada = keyof typeof GUARDAS_RUTAS

/**
 * Rutas del router SIN guarda de rol: están afuera de la tabla a propósito.
 * `/` y `*` redirigen al aterrizaje; las otras dos las abre cualquiera.
 */
export const RUTAS_PUBLICAS = ['/', '/pedidos', '/productos', '*'] as const

/** ¿Este rol puede abrir la ruta? */
export function puedeEntrar(ruta: RutaGuardada, flags: FlagsRutas): boolean {
  return GUARDAS_RUTAS[ruta].permite(flags)
}

/**
 * Adónde manda el router a este rol en esa ruta. `null` = la ruta monta su
 * elemento. Un string = el router renderiza `<Navigate to={…} replace />`:
 * `sino` si no puede entrar, o `redirigeA` si entra a una ruta que sólo redirige.
 */
export function destinoDeRuta(ruta: RutaGuardada, flags: FlagsRutas): string | null {
  const guarda: GuardaRuta = GUARDAS_RUTAS[ruta]
  if (!guarda.permite(flags)) return guarda.sino
  return guarda.redirigeA ?? null
}
