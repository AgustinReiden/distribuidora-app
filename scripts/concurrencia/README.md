# Arnés de concurrencia real (#1288, plan #1378 · tarjeta 1)

Prueba **varias transacciones a la vez** contra la base: cobros cruzados, ventas con
stock justo, cancelaciones, rendiciones, rutas y una carga de "cajas". Todo lo anterior
(`scripts/test-*.sql`) eran ensayos de **una** sesión; los dos que necesitaban concurrencia
(`test-concurrencia-pago-fifo.sql` y `test-concurrencia-monto-pagado-1247.sql`) pedían dos
`psql` a mano. Acá se automatiza con una edge function de prueba que abre las conexiones.

> **Nunca contra prod.** Corre en una rama de Supabase que se crea para la corrida y se
> **borra al terminar**. El arnés se niega si la URL o la base nombran el ref de prod
> (`hmuchlzmuqqxcldbzkgc`), y nadie hace `merge_branch`.

## Qué hay acá

| Archivo | Para qué |
|---|---|
| `harness.mjs` | El código de la edge function `harness`. Genérico: recibe guiones JSON y los corre en conexiones paralelas. Mide esperas de lock, `40P01` y latencias. **Se despliega a mano, sólo en la rama.** |
| `run.mjs` | El corredor (Node, sin dependencias). Manda cada escenario a la función y arma las tablas para #1288. |
| `escenarios.mjs` | C1 a C8 como datos: `setup` por ronda, `workers`, `verify`. Para agregar un caso, sumar una variante acá. |
| `fixtures.sql` | Sucursales `CONC-A`/`CONC-B`, usuarios `@conc.test`, productos y clientes. Todo en el schema `conc` y filas `CONC-*`. |

**Por qué no está en `supabase/functions/`:** `deploy-functions.yml` despliega esa carpeta a
prod al mergear. Esto es JS plano (no TS) para que tampoco lo tomen `tsc` ni ESLint del front.

## Cómo se repite

1. **Costo.** `get_cost` (type `branch`, organización de la cuenta) y pedir el OK del dueño.
   El 30/10 y el 02/11 fue USD 0,01344 por hora. Sin OK explícito no se crea nada.
2. **Rama.** `create_branch` sobre `hmuchlzmuqqxcldbzkgc` (nace sin datos y re-aplica el
   ledger de prod). Si alguna migración vieja falla ahí, **se frena y se avisa**. Anotar el
   `project_ref` de la rama: de acá en adelante **todo** (`execute_sql`, `deploy_edge_function`)
   va a ese ref y a ningún otro.
3. **Desplegar `harness`** en la rama con `deploy_edge_function` (`name: harness`, un solo
   archivo `index.ts` con el contenido de `harness.mjs`), cambiando `__HARNESS_TOKEN__` por
   un token al azar (no lo commitees). `verify_jwt` queda en `true`: el corredor manda la anon
   key de la rama (`get_publishable_keys`) y el token en `x-harness-token`.
4. **Variables.**
   ```bash
   export HARNESS_URL=https://<ref-de-la-rama>.supabase.co/functions/v1/harness
   export HARNESS_TOKEN=<el del deploy>
   export HARNESS_KEY=<anon key de la rama>
   ```
5. **Correr.**
   ```bash
   node scripts/concurrencia/run.mjs info        # host, puerto, rol, max_connections
   node scripts/concurrencia/run.mjs fixtures    # carga fixtures.sql (idempotente)
   node scripts/concurrencia/run.mjs audit       # auditoria_integridad(): la línea base
   node scripts/concurrencia/run.mjs c1          # … c2 … c8, o `todos`
   node scripts/concurrencia/run.mjs c4 --variante C4a --rondas 40   # una sola variante
   ```
   Escribe `scripts/concurrencia/resultados/<escenario>.md` (la tabla para pegar en #1288)
   y `.json` (el crudo, con cada ronda). Esa carpeta no se commitea.
6. **Borrar la rama** (`delete_branch`) al terminar cada corrida, y si se la va a dejar quieta
   un rato, también.

## Cómo se lee un resultado

- **Estado final correcto** es el veredicto: sale de invariantes medidos en la base
  (`monto_pagado` = suma de pagos; stock = inicial − lo vendido vivo; ninguna boleta
  pagada de más), no de "no tiró error". En C4, C5 y C6 donde no hay un número único, la
  variante corre antes las mismas operaciones **una detrás de otra, en cada orden**, y la
  ronda concurrente pasa si termina en el estado de alguno de esos órdenes seriales.
- **Con solape** son las rondas en que las transacciones se pisaron en el tiempo;
  **rondas con espera de lock vista** son las que un muestreador (cada 3–4 ms) vio a
  alguna transacción esperando un lock, con la función que espera, la relación y quién la
  bloquea. Una ronda sin ninguna de las dos no probó el cruce.
- **40P01** cuenta las transacciones que Postgres abortó por deadlock; "base" es el contador
  `pg_stat_database.deadlocks` en el mismo lapso. El `where` del error trae la función y la
  línea de PL/pgSQL que estaba esperando.
- Los **errores de negocio** esperados de una variante (p. ej. `22023` en el sobrepago de C1d)
  no cuentan como inesperados; cualquier otro código, sí.
- **C8** es un dato para diseñar el fork, sin un mínimo fijado: ventas por segundo, latencias,
  esperas por relación y las tablas que más escriben. Depende del tamaño de cómputo de la
  rama (anotarlo junto a los números).

## Cómo funciona por dentro

- Cada trabajador es **una transacción** en **su propia conexión** (`postgres.js`, `max: 1`).
  Se hace pasar por el usuario con `SET LOCAL ROLE authenticated` + `request.jwt.claims` +
  `x-sucursal-id`, como PostgREST, así que valen los mismos permisos que en producción.
- Todos arrancan de una puerta común; `jitter_ms` desparrama el arranque para barrer la
  ventana del cruce, y un `select pg_sleep(…)` como paso final retiene los locks para forzarlo.
- Los pasos comparten variables: la primera fila de cada paso se mezcla en el contexto
  (`{{r.pedido_id}}`). La carga (C8) repite una secuencia vender → cobrar por caja.
- Las RPCs se llaman por su nombre público: el arnés no redefine ni toca ninguna función.
