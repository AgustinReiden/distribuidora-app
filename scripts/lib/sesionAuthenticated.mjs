/**
 * Un token de `authenticated` para probar consultas como la app (#1417).
 *
 * Con la anon key toda consulta da 42501 y con la service_role ninguna: ninguna
 * de las dos ve un select que `authenticated` no puede correr, que es lo que
 * tumbó la lista de Pedidos el 03/11 (#1416). Este token sí: PostgREST corre la
 * consulta con el rol del claim `role`, y Postgres chequea los grants de cada
 * tabla y columna del plan antes de leer una fila, así que con `limit=0` alcanza.
 *
 * Se firma con el JWT secret del proyecto (HS256, el legacy que verifica
 * PostgREST), dura cinco minutos y no es de nadie: el `sub` es el uuid nulo, así
 * que no crea sesiones en auth ni la RLS le muestra una fila. Decisión del dueño
 * (04/11): el secret vive sólo en integridad.yml, como la service_role.
 */
import { createHmac } from 'node:crypto'

export const SUB_SIN_USUARIO = '00000000-0000-0000-0000-000000000000'

const b64url = (texto) => Buffer.from(texto).toString('base64url')

/** JWT HS256 con rol `authenticated`, válido `segundos` desde `ahora` (epoch en segundos). */
export function tokenAuthenticated(secreto, { ahora = Math.floor(Date.now() / 1000), segundos = 300 } = {}) {
  if (!secreto) throw new Error('Falta el JWT secret')
  const cabecera = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const cuerpo = b64url(JSON.stringify({
    iss: 'supabase',
    aud: 'authenticated',
    role: 'authenticated',
    sub: SUB_SIN_USUARIO,
    iat: ahora,
    exp: ahora + segundos,
  }))
  const firma = createHmac('sha256', secreto).update(`${cabecera}.${cuerpo}`).digest('base64url')
  return `${cabecera}.${cuerpo}.${firma}`
}

/**
 * El control negativo: una consulta que authenticated NO puede correr. El costo de
 * cada venta no se lee por REST (#1003, mig 327; lo da `costos_pedido_items()` a admin
 * y encargado), y es la misma columna que tumbó Pedidos el 03/11. Si esta consulta
 * pasa, el token no corre como authenticated —o el costo quedó abierto— y las pruebas
 * en verde no prueban nada: el gate quedaría ciego otra vez, como con la anon key.
 */
export const CONTROL_SESION = { tabla: 'pedido_items', columna: 'costo_unitario_al_crear' }

/** null si el control mordió (42501); si no, por qué la sesión no está probando nada. */
export function fallaDelControl(status, cuerpo) {
  if (cuerpo?.code === '42501') return null
  if (status >= 200 && status < 300) {
    return `authenticated leyó ${CONTROL_SESION.tabla}.${CONTROL_SESION.columna}: el token no corre como authenticated, o el costo quedó abierto por REST`
  }
  return `se esperaba 42501 y dio HTTP ${status} ${cuerpo?.code ?? ''} ${cuerpo?.message ?? ''}`.trim()
}
