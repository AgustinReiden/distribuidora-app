# Arnés de concurrencia real (#1288, plan #1378 · tarjeta 1)

Prueba **varias transacciones a la vez** contra la base: cobros cruzados, ventas con
stock justo, cancelaciones, rendiciones, rutas y una carga de "cajas". Todo lo anterior
(`scripts/test-*.sql`) eran ensayos de **una** sesión; los dos que necesitaban concurrencia
(`test-concurrencia-pago-fifo.sql` y `test-concurrencia-monto-pagado-1247.sql`) pedían dos
`psql` a mano. Acá se automatiza con una función de prueba que abre las conexiones.

> **Nunca contra prod.** Corre en un Postgres descartable dentro de Docker, en la PC. El
> arnés se niega si la URL de la base o la de la API nombran el ref de prod
> (`hmuchlzmuqqxcldbzkgc`). Prod sólo se **lee** (la huella del schema), nunca se escribe.

## Qué hay acá

| Archivo | Para qué |
|---|---|
| `docker-local.mjs` | Levanta y borra el contenedor (por defecto `conc-pg`, puerto 54330; `CONC_NOMBRE` y `CONC_PUERTO` lo cambian para convivir con otros; imagen `supabase/postgres:17.6.1.178`), le carga el dump del schema de prod, le aplica las migraciones posteriores y corre la huella. |
| `huella-esquema.sql` | Huella del schema `public` (funciones por `md5(prosrc)`, columnas, constraints, índices, triggers, policies, permisos…). Es **sólo lectura**: el mismo SQL corre contra prod y contra la base local, y se comparan los hashes. |
| `harness.mjs` | El código de la función `harness`. Genérico: recibe guiones JSON y los corre en conexiones paralelas. Mide esperas de lock, `40P01` y latencias. |
| `run.mjs` | El corredor (Node, sin dependencias). Manda cada escenario a la función y arma las tablas para #1288. |
| `escenarios.mjs` | C1 a C12 como datos: `setup` por ronda, `workers`, `verify`. Para agregar un caso, sumar una variante acá. |
| `fixtures.sql` | Sucursales `CONC-A`/`CONC-B`/`CONC-C`, usuarios `@conc.test`, productos y clientes. Todo en el schema `conc` y filas `CONC-*`. |
| `controles-negativos.sql`, `controles-negativos-orden.sql`, `controles-negativos-contenedores.sql`, `controles-negativos-promos.sql` | Rompen a propósito locks de la copia local (en cuatro grupos) para comprobar que el arnés se pone rojo (ver "Controles negativos"). |
| `controles-negativos-t10.sql` | Saca dos partes del arreglo de la tarjeta 10 de #1378 (#1439) para ver que cada una hace falta (ver su encabezado). |
| `controles-negativos-t13.sql` | Saca de a una las tres partes del arreglo de la tarjeta 13 de #1378 (#1446): el pre-bloqueo de los llamadores, el del trigger y su orden (ver su encabezado). |
| `controles-negativos-t14.sql` | Saca a la vez los seis pre-bloqueos de la tarjeta 14 de #1378 (#1460), uno por función: cada variante de `t14` cruza una sola contra la venta (ver su encabezado). |
| `controles-negativos-t15.sql` | Saca los dos pre-bloqueos de la tarjeta 15 de #1378 (#1460): el de `cambiar_cliente_pedido` (C1) y el de las rutas en `imputar_credito_a_pedido_impl` (C7) (ver su encabezado). |
| `controles-negativos-t6.sql`, `controles-negativos-t6b.sql` | Sacan, en dos grupos que no se corren juntos, las partes del arreglo de la tarjeta 6 de #1477 (#1473): los productos de los ítems nuevos en el pre-bloqueo del cambio de cliente (ADV-5), el de la RPC del regalo de una promo con el UPDATE REST de vuelta (ADV-2) y la espera acotada de los precios en masa (ADV-3); y el pre-bloqueo de productos entero del cambio de cliente (ADV-1) (ver sus encabezados). |
| `controles-negativos-t6o.sql` | Con el arreglo de #1501 (punto 1) aplicado, el trigger de sentencia de los contenedores vuelve a ignorar el aviso de `cambiar_regalo_promocion`: T6o vuelve a dar `40P01` (ver su encabezado). |
| `controles-negativos-a2.sql` | Saca los dos pre-bloqueos del alta de la tarjeta 2 de #1477 (#1469): la venta sigue aplicando el saldo a favor al final, pero toma la boleta y el crédito después del cliente (ver su encabezado). |

**Por qué no está en `supabase/functions/`:** `deploy-functions.yml` despliega esa carpeta a
prod al mergear. Esto es JS plano (no TS) para que tampoco lo tomen `tsc` ni ESLint del front.

## Por qué la base sale de un dump y no de `migrations/`

Re-aplicar `migrations/` en orden sobre una base vacía **no reconstruye prod**: la carpeta es
una vista curada del ledger, y muchas migraciones traen arreglos de datos de prod pegados al
DDL (la 062 re-inserta una sustitución del pedido 1966) o guardas de md5 hechas para fallar en
cualquier base que no sea prod. Con una transacción por archivo fallan 165 de 459; sin la
transacción envolvente fallan 118 y el schema queda con 148 funciones distintas y 6 tablas de
menos. **Medir sobre eso sería medir otra app**, así que la base se arma con un dump del
schema vivo y se verifica con la huella.

## Cómo se repite

1. **Docker Desktop abierto.** Se cierra al terminar (desde la bandeja, nunca matándolo).
2. **Dump de prod.** Lo genera el dueño con `supabase db dump --linked` (schema `public`, grants
   incluidos, **sin datos**). Vive **fuera del repo** y no se commitea ni se copia a ningún
   worktree.
3. **Base local.**
   ```bash
   export CONC_NOMBRE=conc-pg CONC_PUERTO=54330                        # opcional: si hay otros contenedores en la PC
   node scripts/concurrencia/docker-local.mjs up                       # contenedor + Postgres 17.6
   node scripts/concurrencia/docker-local.mjs dump C:/ruta/schema-prod.sql
   ```
   `dump` vacía los privilegios por defecto de la imagen (le dan permisos a `anon` sobre todo lo
   que se crea en `public`), carga el dump y deja lo que el dump no trae de `auth` (ver
   "Diferencias con Supabase real"). Tiene que dar `errores: 0`.

   **El dump es una foto.** Lo que se aplicó a prod después de generarlo (el ledger tiene fecha y
   hora) hay que sumarlo al contenedor, **en el orden del ledger** (no el numérico), con
   `node scripts/concurrencia/docker-local.mjs aplicar migrations/<NNN>_….sql` (copia el archivo
   en LF y lo corre con `ON_ERROR_STOP`: si la guarda de md5 de la migración no coincide, el
   dump no es el mismo prod). Antes de aplicar cada archivo se comprueba que su `md5` sea el
   `md5(statements[1])` del ledger (`supabase_migrations.schema_migrations`, sólo lectura): lo
   que aplica prod es lo que se mide, no lo que haya en `main` ese día.
   - El dump del 02/11 de las 16:45 necesitó, en este orden: 436, 437, 439, 438, 440, 442, 443,
     441 y 444.
   - **La 437 se aplicó a prod desde un archivo con CRLF** (su md5 del ledger es el del archivo
     crudo) y los cuerpos de sus funciones guardan los `\r`: se aplica con `--tal-cual`, que no
     normaliza a LF. En LF la huella de `funcion` no coincide.
   - La 437 trae un ensayo que pide un admin activo de las sucursales 1 y 2 (en prod existe).
     `docker-local.mjs semilla` lo siembra y `sin-semilla` lo borra (y lista las tablas que
     hayan quedado con filas: ninguna). Las 440 y 442 también lo piden. **Nunca después de
     `fixtures`:** sin la semilla, la secuencia les da a CONC-A y CONC-B los ids 1 y 2, y
     `sin-semilla` borra las sucursales 1 y 2 sin cascada. Los usuarios quedan apuntando a
     sucursales que no existen, y el próximo `fixtures` crea otras CONC-A y CONC-B. Una
     migración posterior se aplica antes de cargar los fixtures, o se rearma la base.
   - La 441 puede estar en `main` con otro nombre o con otra primera línea; vale lo que dice el
     ledger.
   - **La 456 es una migración de datos de prod** y falla en la base vacía ("hay 0 bonificaciones sin factor, se
     esperaban 70"). Sin ella la huella da distinto sólo en `constraint`
     (`pedido_items_origen_unidades_por_bloque_check` sin `'inferido_constante'`): se aplica sólo su DDL, el
     `ALTER TABLE … ADD CONSTRAINT` y el `COMMENT` del final, con `docker-local.mjs sql`.
   - **La 461 y la 465 traen un bloque `$premisas_datos$`** (md5 de datos de prod: las rendiciones viejas y clientes,
     y `transferencias_stock`) que en la base vacía falla. Se aplican desde una copia sin ese bloque; lo demás no
     depende de datos y la huella da igual.
   - **La 463 toca `storage.objects`** (tres policies, en la premisa y en el DROP/CREATE), que la imagen no trae y la
     huella no mira, y crea `auditoria_storage`, que lee `storage.buckets`. Se aplica desde una copia sin esas tres
     policies y con `SET check_function_bodies = off` al principio.
4. **Huella contra prod.** Mismo SQL en las dos bases; **cero diferencias** o se frena:
   ```bash
   node scripts/concurrencia/docker-local.mjs huella
   ```
   y el contenido de `huella-esquema.sql` (sin los comentarios) por `execute_sql` sobre prod,
   sólo lectura. Cada categoría tiene que dar el mismo `n` y el mismo `h`. Se compara **la
   consulta completa del archivo en las dos bases**: una categoría suelta, escrita aparte, no es
   equivalente (en local da otro hash que dentro del `UNION` completo). Si no cierra, no se
   mide: se baja por cubos (ver el encabezado del archivo) hasta ver qué objeto difiere.
5. **Función de prueba** (desde un directorio limpio, para que Deno no levante el
   `node_modules` del repo):
   ```bash
   mkdir harness-run && cp scripts/concurrencia/harness.mjs harness-run/
   cd harness-run
   HARNESS_TOKEN=<al azar> SUPABASE_DB_URL=postgresql://postgres:pw@localhost:54330/postgres \
     deno run -A --node-modules-dir=none harness.mjs        # escucha en :8000
   ```
6. **Correr.**
   ```bash
   export HARNESS_URL=http://localhost:8000/ HARNESS_TOKEN=<el mismo> HARNESS_KEY=local
   node scripts/concurrencia/run.mjs info        # host, puerto, rol, max_connections
   node scripts/concurrencia/run.mjs fixtures    # carga fixtures.sql (idempotente)
   node scripts/concurrencia/run.mjs audit       # auditoria_integridad(): la línea base
   node scripts/concurrencia/run.mjs c1          # … c2 … c8, o `todos`
   node scripts/concurrencia/run.mjs c4 --variante C4a --rondas 40   # una sola variante
   ```
   Escribe `scripts/concurrencia/resultados/<escenario>.md` (la tabla para pegar en #1288)
   y `.json` (el crudo, con cada ronda). Esa carpeta no se commitea.
7. **Borrar el contenedor** al terminar cada corrida: `node scripts/concurrencia/docker-local.mjs down`.

**Lo que confirma una rendición no se repite sobre la misma base.** Cada ronda usa un día propio y
una rendición confirmada cierra la caja de su sucursal hasta ese día y todos los anteriores, sin
reabrirse: una segunda tanda cae en `42501 La caja de la sucursal esta cerrada` desde el setup. Las
variantes usan tramos de días crecientes, **en el orden en que corren**: en `CONC-B`, C6, C6b, C6c y
C6d (ventana de 900 días); en `CONC-C`, C6g y C6h (ventana de 1500); en `CONC-A`, la C6e de #1418 y la C9 de #1412 confirman rendiciones en sus propios tramos de días, y C7 queda fuera de ellos (ver el comentario de `c7()`). Por eso `c6` y `c7`
corren enteros y en ese orden (`todos` ya lo hace). Las de `t10` (tarjeta 10 de #1378) que confirman
rendiciones eligen solas su día en `CONC-A`, del 5000 al 4602 hacia atrás de hoy, y las de rutas no
gastan días (choferes nuevos en cada ronda): `t10` corre antes que C6e y C9, o sobre una base nueva.
Una prueba de humo de esas variantes gasta días de su tramo: después se reconstruye el contenedor. Para repetir una de ellas (o toda la
corrida): `up`, `dump`, `aplicar` (cada migración posterior), `fixtures`, `audit`.

(El mismo arnés sirve contra una rama de Supabase: se despliega `harness.mjs` como edge
function con `__HARNESS_TOKEN__` cambiado por un token al azar, y `HARNESS_URL` apunta a
`https://<ref-de-la-rama>.supabase.co/functions/v1/harness` con la anon key de la rama en
`HARNESS_KEY`. Ahí no hace falta el dump: la rama nace del ledger de prod, y la 062 es
esperable que choque igual. No se probó.)

## Cómo se lee un resultado

- **Estado final correcto** es el veredicto: sale de invariantes medidos en la base
  (`monto_pagado` = suma de pagos; stock = inicial − lo vendido vivo; ninguna boleta
  pagada de más), no de "no tiró error". Una ronda cuenta como correcta sólo si pasa el
  `verify`, su preparación no falló y ningún trabajador tiró un error inesperado que no sea
  un deadlock (ése tiene su columna): así un guion que nunca llega a correr no pasa "por
  no haber cambiado nada". En C4, C5 y C6 donde no hay un número único, la
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
- Las variantes **C6b, C6c, C6d, C6g y C6h** fuerzan el cruce con un tercer trabajador que retiene el pago más
  viejo (`SELECT … FOR UPDATE` y 250 ms de espera) mientras la confirmación y el otro trabajador se
  ponen en cola; C6 sola, con 6 ms de jitter, casi no puede caer en una ventana de microsegundos y
  su "0" no dice que el cruce no exista. Lo mismo hacen **C11b, C11c, C10b y C10d**: un trabajador
  retiene el producto de menor id mientras la venta espera en él y la operación (editar, sustituir
  o dividir) entra después; si la operación bloqueara de mayor a menor, tomaría el otro producto y
  se cruzaría. Las tasas de deadlock de esas variantes (y las de C7, que fuerza el arranque
  simultáneo) dicen que el cruce **existe**, no cuán seguido pasa en producción.
- **C8** es un dato para diseñar el fork, sin un mínimo fijado: ventas por segundo, latencias,
  esperas por relación y las tablas que más escriben. En Docker depende de la PC (anotarla
  junto a los números) y **no es la capacidad de prod**.

## Controles negativos

Un "200/200" sólo vale si el arnés habría dicho otra cosa con un bug. Hay cuatro archivos, **uno por
grupo, y no se corren juntos**: cada uno rompe a propósito unos locks de la copia local y las
variantes que los cubren tienen que ponerse en rojo.

- `controles-negativos.sql` saca el `FOR UPDATE` de la boleta en `recalcular_monto_pagado_pedido`
  (#1247) y, en `crear_pedido_completo`, el de la fila de `productos` y el pre-bloqueo de productos de la 455: C1c da
  0 rondas correctas, con `monto_pagado=30` sobre pagos por 80, y `auditoria_integridad()` marca `CC-B`. C3a y C3d se
  ponen en rojo por el `23514` del CHECK `productos_stock_no_negativo` (466) en la venta que llega segunda: desde la
  466 el stock ya no puede quedar negativo, así que no aparece `STK-B` (#1499). C1a sigue en verde sin el lock del trigger: la
  RPC `registrar_pagos_pedido_impl` lockea la boleta por su cuenta, y por eso C1c existe aparte.
- `controles-negativos-orden.sql` pasa el `ORDER BY id` del lock de productos de
  `actualizar_pedido_items` (#1296), `sustituir_regalo_pedido` y `dividir_regalo_pedido` (#1326)
  a `ORDER BY id DESC`: C11b, C10b y C10d tienen que dar `40P01` en casi todas las rondas. Las de
  arranque simultáneo (C11a, C10a, C10c) caen en la ventana sólo a veces.
- `controles-negativos-contenedores.sql` (#1398) va **después** de la migración que hace que la
  venta bloquee los contenedores de sus promos: pasa ese pre-bloqueo de `crear_pedido_completo` y
  del bot a `ORDER BY id DESC`, y C12b y C12e vuelven a dar `40P01`. Sin la migración, C12b, C12d,
  C12e y C12f ya dan `40P01`: ésa es la medición de antes, y C12i y C12j (ids que no cruzan) dan 0
  con y sin ella.
- `controles-negativos-promos.sql` (#1398, #1442), también después de esa migración y con la 451:
  saca sólo el pre-bloqueo de las promos. C12k2 vuelve a dar `40P01` y C12m, el `40001` de
  `trg_verificar_modo_regalo_item`: la línea se selló con el modo viejo y la foto con el nuevo.

**Por qué no juntos:** sin el `FOR UPDATE` de `crear_pedido_completo` (el segundo cambio del primer
archivo) la venta toma los productos recién en su `UPDATE` de stock, en el orden del JSON, y las
variantes de orden dejan de medir lo que dicen. Se aprendió a las malas: la primera pasada de C10 y
C11 con las cinco mutaciones a la vez dio un C11c distinto de C11b.

Se corre con **una carpeta `--out` por variante** (`run.mjs` escribe `<grupo>.md` y pisa el de la
variante anterior), **al final de la corrida** (deja datos rotos y la auditoría en rojo), se
restauran las funciones desde `conc.mut_orig` (el `RESTAURAR` de `controles-negativos.sql`) y se
repite la huella.

## Diferencias con Supabase real

- **Postgres:** 17.6 en x86_64 contra 17.6 en aarch64; una sola máquina, sin red entre la
  función de prueba y la base, y sin PostgREST ni pgbouncer en el medio. Las latencias son de
  referencia.
- **Schema `auth`:** la imagen trae el de un GoTrue viejo (sin `email_confirmed_at`,
  `banned_until`…) y sin el trigger `on_auth_user_created`. `docker-local.mjs dump` crea el
  trigger (el de prod, literal) y reemplaza `auth.uid()`, `auth.role()` y `auth.email()` por los
  de Supabase actual, que leen `request.jwt.claims` además de los GUC sueltos. Nada de lo que
  se mide pasa por `auth.users` más allá del alta de los usuarios de prueba.
- **Huella:** los `CHECK` se comparan sin paréntesis ni casts a `text`/`varchar`. El dump de
  prod trae `(ARRAY['a'::varchar, …])::text[]` y al releerlo 17.6 lo guarda como
  `ARRAY[('a'::varchar)::text, …]` (y aplana `(a AND b) AND c`): es el mismo predicado
  impreso distinto, y con el texto crudo 17 de 219 no coinciden.
- **Sin datos:** la base nace vacía; los datos son los de `fixtures.sql`.

## Cómo funciona por dentro

- Cada trabajador es **una transacción** en **su propia conexión** (`postgres.js`, `max: 1`).
  Se hace pasar por el usuario con `SET LOCAL ROLE authenticated` + `request.jwt.claims` +
  `x-sucursal-id`, como PostgREST, así que valen los mismos permisos que en producción.
- Todos arrancan de una puerta común; `jitter_ms` desparrama el arranque para barrer la
  ventana del cruce, y un `select pg_sleep(…)` como paso final retiene los locks para forzarlo.
- Los pasos comparten variables: la primera fila de cada paso se mezcla en el contexto
  (`{{r.pedido_id}}`). La carga (C8) repite una secuencia vender → cobrar por caja.
- Las RPCs se llaman por su nombre público: el arnés no redefine ni toca ninguna función.
