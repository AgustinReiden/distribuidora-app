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
