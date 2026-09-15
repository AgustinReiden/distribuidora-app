# CLAUDE.md

App de gestión para una distribuidora de alimentos. React 19 + Vite en el front,
Supabase (Postgres + Auth + RLS) en el back, edge functions en Deno.

## Correr y verificar

```bash
npm ci                 # los worktrees nacen sin node_modules — ver Trampas
npm run dev            # Vite
npm run typecheck      # tsc --noEmit
npm run lint           # eslint
npm run test:run       # vitest (~100 archivos, ~1400 tests)
npm run build          # vite build + PWA
```

Antes de dar algo por terminado corré las cuatro: `typecheck`, `lint`, `test:run`, `build`.
El pre-commit ya corre `check-secrets.sh`, `lint-staged` y los tests.

Edge functions (Deno, desde `supabase/functions/`): `deno task check`, `deno task lint`,
`deno task test`.

E2E: `npm run test:e2e` (Playwright, chromium).

`npm run check:migrations` **no corre localmente**: necesita `SUPABASE_URL` y
`SUPABASE_SERVICE_ROLE_KEY`, que no están en `.env`. Es un gate de CI
(`.github/workflows/integridad.yml`), no un comando de desarrollo.

Deploy: push a `main` → webhook de Coolify. La config de nginx de producción **vive en el
panel de Coolify**, no en el `nginx.conf` del repo — editar el repo no cambia nada.
Verificá siempre con `curl -I`, nunca leyendo el archivo.

## Dónde va cada cosa

Cada hecho vive en **un** solo lugar, elegido por quién lo verifica:

| Quién lo verifica | Dónde vive |
|---|---|
| Un script o CI | un test o un check |
| Regla que aplica siempre | este archivo |
| Algo por hacer | **issue de GitHub** |
| Por qué este código es así | comentario al lado del código |
| Hecho externo, no está en el repo | memoria |

Si no entra claro en una caja, probablemente no hace falta escribirlo.

## Estructura

- `src/components/containers/` — donde viven de verdad los handlers y los modales
- `src/hooks/queries/` — capa de datos (TanStack Query). Es la que se usa.
- `src/hooks/supabase/`, `src/hooks/state/` — hooks de datos y de estado
- `src/lib/` — `supabase.ts`, `schemas.ts` (Zod), `offlineDb.ts` (Dexie), `permisos.ts`
- `src/utils/` — lógica pura, es donde van los cálculos testeables
- `migrations/` — SQL numerado. Ver Trampas.
- `supabase/functions/` — edge functions Deno (bot de Telegram, optimizar-ruta)

La política comercial configurable no vive en el código: está en la tabla
`politicas_comerciales` (una fila por sucursal) y se edita en `/configuracion`. Un
parámetro de negocio que cambia va ahí, no en una constante, una env var ni una columna
suelta en `sucursales`.

## Convenciones

- **Nada de refactors de paso.** Un bug que no es el que viniste a arreglar → issue.
- Lógica de negocio en `src/utils/` con tests, no adentro de los componentes.
- Los schemas Zod de un modal lazy van **co-locados en el modal**, no importados de un
  chunk compartido: si no, un bundle viejo del PWA valida contra un schema desincronizado
  y tira "Invalid input" sin ningún error de chunk.
- **Toda función nueva** de `public` nace con `EXECUTE` para `PUBLIC` — sea `SECURITY
  DEFINER` o no — y Supabase además se lo concede a `anon` por separado. Hay que
  **revocar las dos mitades en la misma migración** (`REVOKE ... FROM PUBLIC, anon`);
  `GRANT TO authenticated` no lo revierte. El gate de CI (`scripts/check-permisos.mjs`)
  falla ante **cualquier** función alcanzable con la anon key, no solo las definer.
  Una función de **trigger** no necesita `EXECUTE` para nadie: la invoca el executor como
  parte del DML, no el caller. Dejala en `postgres` + `service_role`, como
  `completar_origen_precio_item` (148) o `validar_precio_item_pedido`.
- Los ids son `bigint` y llegan como `number` en runtime: usá `z.coerce.string()`, no
  `z.string()`.
- **Las 4 RPCs de pago son wrappers**: la lógica vive en `<nombre>_impl` (mig 167, por la
  idempotencia). Si editás la RPC y no el `_impl`, no cambia nada y no falla nada.
- Una confirmación disparada desde un modal Radix tiene que renderizarse **dentro** del
  modal. Como hermano en el container queda detrás del overlay y falla en silencio.
- **Toda lectura nueva de `clientes` decide qué hace con los inactivos.** Un cliente con
  pedidos no se puede borrar (la FK es RESTRICT desde la mig 200), así que desactivarlo es la
  única salida y siempre va a haber inactivos. `fetchClientes` filtra `activo = true` por
  defecto (`includeInactivos` para el panel, que es desde donde se reactiva). Lo operativo
  —selectores, rutas, recorridos— los oculta; el historial —reportes, cuenta corriente y los
  embeds `cliente:clientes(*)`— **tiene** que seguir viéndolos, que es de lo que se trata la
  baja lógica. Una consulta que no elige está eligiendo mal por omisión.
- **El stock por lote lo lleva un trigger, no las RPCs.** `trg_lotes_sincronizar` (mig 223)
  consume FEFO y devuelve al lote en cada `UPDATE productos.stock`, leyendo el mismo
  `app.stock_origen` que ya usa el ledger. Un camino nuevo que **baje** stock no tiene que
  tocar `producto_lotes`: el trigger se encarga. Uno que lo **devuelva** —cancelación,
  salvedad, edición a la baja— sí tiene que etiquetarse con un origen de la lista blanca del
  trigger, o esas unidades vuelven a la bolsa "sin vencimiento" en vez de a su lote y el
  contador miente para abajo sin que falle nada. Tres corolarios que ya mordieron (migs 229 y
  234):
  - **La devolución que se cancela sola NO va etiquetada.** La salvedad por dañado o vencido
    devuelve las unidades y las merma en el mismo movimiento (mig 234). Si esa devolución lleva
    un origen de la lista blanca vuelve al lote por FEFO, pero la bajada de la merma sale de la
    **bolsa** primero —el camino de bajada del trigger no mira el origen—, así que el lote queda
    **+N** y la bolsa **−N** en cada rotura: el mismo contador mintiendo, para arriba. Medido
    con un lote de 100 con 50 vivas y bolsa 40: con `'salvedad'` el lote termina en 53, con
    `'salvedad_merma'` en 50. Las dos patas tienen que caer del mismo lado del mostrador. La
    regla de arriba rige la devolución que **queda** devuelta; ésta no lo está ni un renglón
    después.
  - `set_config` es **por transacción, no por función**. Una función que setea el origen y la
    llama otra que ya seteó el suyo le pisa la etiqueta al resto del cuerpo del caller. Si es
    un helper con varios llamadores —`revertir_bloques_auto_ajuste` es el caso— tiene que
    **guardar y restaurar** los cuatro GUCs alrededor de su `UPDATE`.
  - El gate es el check **STK-F** de `auditoria_integridad()`: falla si una función de `public`
    sube `productos.stock` de forma incremental sin mencionar `app.stock_origen`. Tiene dos
    excepciones listadas a propósito (`registrar_compra_completa`, `registrar_ingreso_sucursal`):
    suben mercadería nueva, que va a la bolsa por diseño. Si agregás una función que sube stock,
    etiquetala o el gate se pone rojo.
- **El criterio de merma y la cascada de costo viven en una función, no en cada reporte.**
  `mermas_valorizadas(desde, hasta, sucursales)` (mig 238) es la única implementación del
  corte por día argentino, la exclusión de `promociones`/`promociones_reversion` y la
  valuación; `reporte_gerencial` y `reporte_mermas` la **consumen**, y por eso
  `totales.costo == kpis.mermas` cierra por construcción. La cascada sola es
  `costo_valuacion(snapshot, promedio, real, sin_iva, ii)`, y **`IS NULL` sobre ella ES el
  predicado `sin_costo`** — no mires `costo_sin_iva` por tu cuenta, que fue justo el bug de
  #511. Un reporte nuevo que valorice mermas o decida "sin costo" llama a estas dos; si
  reescribís el criterio, el gate `scripts/check-integridad.mjs` se pone rojo.

- **`productos.costo_promedio` no puede ser base de sí mismo.** El promedio vivo ya incluye la
  compra que estás por recalcular; la base es `compra_items.costo_promedio_anterior`, el
  snapshot que guardan `registrar_compra_completa` y `actualizar_compra_items` (mig 236). Sin
  ese snapshot —líneas anteriores a la 236— no se toca el promedio y se avisa: moverlo sin
  saber de dónde arranca lo corre hacia el costo de la última factura en **cada** edición (100
  u. a 10 más 100 u. a 20 dan 15 al registrar y 17,50 tras una edición sin cambios). Y el costo
  de **reposición** (`costo_real` / `costo_sin_iva` / `costo_con_iva`) es otra cosa: sólo lo
  pisa la compra más nueva del producto (`v_es_mas_reciente`), mientras que el stock y el
  promedio suman siempre, venga la factura con la fecha que venga.
- **Cancelar una compra le borra los lotes** (`borrar_lotes_compra_cancelada`, mig 224). Todo
  camino que cancele una compra decide **antes** qué hace con ellos: `anular_compra_atomica`
  cancela primero, para que la bajada de stock no consuma FEFO de lotes ajenos y encima borre
  los propios (229); `cambiar_proveedor_compra` los reapunta al clon antes de cancelar (236,
  #566). Reapuntar y no clonar-y-borrar: `producto_lotes.compra_id` apunta a la compra, no a la
  línea, y así se conserva `cantidad_restante` sin duplicar la suma ni por un instante.
- **La asignación de un cliente tiene TRES estados, no dos**: sin asignar / asignado a X /
  `reservado_admin` (mig 214). Son excluyentes. Cuidado con que "sin asignar" significa
  **visible para todos los preventistas** (mig 028), o sea lo contrario de reservado. Y
  `reservado_admin` **no** es "solo lo ve admin": lo ven también encargado, transportista y
  depósito, y el preventista que ya le vendió —esa excepción es la que evita que sus pedidos
  viejos pierdan el cliente y desaparezcan por los `!inner` de `usePedidosQuery`—. Todo
  camino nuevo que ofrezca clientes *para operar* lo excluye; todo camino de *historial* lo
  sigue mostrando.

## Trampas

**1. Corré los tests sin `.env`.** Tener `.env` local enmascara fallos de import que CI sí
detecta. La corrida sin `.env` es la que vale.

**2. Los worktrees nacen sin `.env` y sin `node_modules`.** La pantalla en blanco y la
pila de errores de typecheck en un worktree recién creado son **ambientales**, no del
código. Corré `npm ci` antes de diagnosticar nada.

**3. `migrations/` es una vista curada, no un espejo de producción.** La fuente de verdad
es el ledger de prod (`supabase_migrations.schema_migrations`). Y el número de una
migración **se reserva aplicándola, no escribiendo el archivo**: elegí el número al final,
justo antes de aplicar. Tres fuentes distintas pueden ocupar el mismo número —
`origin/main`, el ledger, y las ramas abiertas de otras sesiones— y a la tercera no se la
puede consultar. Ya falló tres veces. Detalle en `migrations/MANIFEST.md`.
Si tocás el MANIFEST §D, tocá también el mapa `CONSOLIDACIONES` de
`scripts/check-migrations.mjs`: son espejo, y desalinearlos deja el gate rojo para siempre.

**4. `es_preventista()` NO significa "es preventista".** Devuelve `true` también para
`admin` y `encargado` (y para quien tenga el rol extra en `perfil_roles`). Ídem
`es_transportista()`, que incluye a `admin`. Un `CREATE OR REPLACE` descuidado de esos
helpers revierte el multi-rol en silencio.

**5. Un embed ambiguo de PostgREST rompe la consulta entera.** Dos FKs a la misma tabla ⇒
`PGRST201`, y falla **toda** la query, no sólo el embed. El `select` es un string: no lo
ven ni `tsc` ni eslint ni los tests. Probá todo embed nuevo con `curl` + anon key antes
de mergear. Ya rompió "Armar ruta" en producción.

Pariente de la misma familia: **dos sobrecargas SQL con rangos `[obligatorios, total]`
superpuestos** hacen que PostgREST no sepa cuál llamar y tire `PGRST203`, también en
runtime y también invisible para `tsc` y para los tests. Al cambiarle la firma a una
función, **dropeá la vieja** — no dejes las dos conviviendo "por compatibilidad".

**6. Antes de una migración de datos, fijate qué más depende de esa columna.** Dos cosas
que ya mordieron en la misma migración:
- `trigger_actualizar_saldo_pedido` es `AFTER UPDATE **OF total, monto_pagado**`. Esa
  lista de columnas hace que mover `cliente_id` **no** lo dispare: la reatribución se
  veía hecha y los saldos quedaban sin actualizar. Si tocás una columna, chequeá
  `pg_get_triggerdef` — un `UPDATE OF` no cubre lo que no nombra.
- Las FKs del aislamiento por sucursal son **compuestas** (`pedidos_cliente_id_fkey` es
  `(cliente_id, sucursal_id) → clientes(id, sucursal_id)`). Al recrear una, preservá las
  dos columnas: dejarla simple rompe el aislamiento y no falla nada visible.

**7. Nunca `npm audit fix --force`.** Degrada `exceljs` a 3.4.0 y rompe todos los exports
a Excel. El gate de CI es `--audit-level=high --omit=dev`; los `moderate` conviven a
propósito. Para arreglar un high: `npm audit fix --package-lock-only`.

**8. Un mínimo de pedido no puede ser un CHECK sobre `pedidos.total`.** Parece el lugar
obvio para la compra mínima (mig 204/205), y rompe la cancelación: `cancelar_pedido` pone
`total = 0` (mig 175) y el invariante `VENTA-I` de `auditoria_integridad()` **exige** que un
pedido cancelado tenga total 0 (mig 105). Las dos reglas se contradicen y ningún código lo
dice. Por eso se valida **al crear** —dentro de `crear_pedido_completo` y de
`crear_pedido_completo_bot`— y nunca como constraint ni como trigger sobre el `UPDATE` del
total. Corolario: la política rige el alta, no retroactivamente. Cuando el mínimo sube, los
pedidos viejos por debajo eran legales cuando se crearon y tienen que seguir siéndolo.

## Los pendientes van a issues

No crear `PENDIENTES.md` ni "estado del proyecto.md", y no anotar pendientes en memoria
ni en `docs/`. Ninguno de esos lugares tiene un "cerrar", así que nada se da de baja nunca
y terminan contradiciéndose. Un pendiente sin issue es un pendiente perdido.
