/**
 * Columnas de `perfiles` que el front lee por REST (#1601, 1601-b5; decisión del dueño D53:
 * «los emails de los demás usuarios los leen admin y encargado»).
 *
 * Todas menos `email`. El email de otro usuario sale de la RPC `emails_de_usuarios()`, que
 * se lo da sólo a admin y encargado (y a cada uno el suyo); el propio sale de la sesión.
 * Cuando se aplique el cierre de D53 (el `REVOKE SELECT` de `perfiles.email` para
 * `authenticated`), la tabla pasa a concederse columna por columna, y en PostgREST un `*` o
 * un `email` en el `select` hace fallar la consulta ENTERA, para todos los roles (trampa 5
 * de CLAUDE.md). Por eso ninguna consulta de perfiles pide `*` ni `email`, ni un `.select()`
 * pelado después de un update: lo vigila `perfilColumnas.test.ts`.
 *
 * Un literal de string, como PRODUCTO_COLUMNAS: supabase-js tipa el `select` desde el texto.
 */
export const PERFIL_COLUMNAS = 'id, nombre, rol, activo, created_at, zona'
