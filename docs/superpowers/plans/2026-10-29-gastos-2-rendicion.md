# Gastos, entrega 2 de 5: rendición — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un gasto pagado con la plata de una rendición se registra como gasto y se descuenta del
**efectivo a entregar**. Ese número aparece en la tarjeta de Rendiciones, en "Cerrar rendición" y
en "Mis cobros" del transportista. Los gastos del cierre se guardan con el cierre, y
`rendicion_gastos` se retira.

**Architecture:**
- **Vínculo por clave, no por FK a `rendiciones_control`.** El gasto guarda
  `rendicion_transportista_id` y `rendicion_fecha`; la sucursal es la del gasto. Una rendición
  pendiente no tiene fila en `rendiciones_control`, y `trg_pedidos_anular_control` borra la de una
  cerrada cuando cambia una entrega (#1175). Con una FK, ese borrado se llevaría los gastos o
  quedaría trabado.
- **Una sola puerta para escribir gastos.** El cuerpo de `guardar_gasto` y `anular_gasto` pasa a
  `_guardar_gasto` y `_anular_gasto`, de server, con un parámetro `p_desde_cierre`. Desde la vista
  Gastos, un gasto de una rendición cerrada se rechaza. Desde `confirmar_rendicion` se acepta,
  porque eso es "Editar cierre".
- **El cierre manda cambios, no la lista entera.** `confirmar_rendicion` recibe
  `{vistos, guardar, quitar}`:
  - `vistos` son los gastos que mostró el modal. Si no coinciden con los vivos, alguien cargó o
    quitó uno mientras tanto, y el cierre se rechaza.
  - `guardar` lleva sólo lo nuevo y lo editado. Así un encargado vuelve a confirmar sin tocar los
    gastos que cargó un admin.
- **Un lock por rendición** (`pg_advisory_xact_lock`) en `confirmar_rendicion`,
  `resolver_rendicion` y toda escritura de un gasto de rendición. El orden es fijo: primero la
  rendición y después la fila del gasto.
- **El efectivo a entregar se calcula en el front** (`src/utils/rendicionGastos.ts`): efectivo
  cobrado menos gastos. El server da los dos sumandos: `obtener_resumen_rendiciones` suma `gastos`
  en `total_gastos`, y `obtener_gastos_rendiciones` (nueva) da la lista.

**Tech Stack:** React 19 + Vite + TanStack Query + Zod + vitest/testing-library; Supabase Postgres
(plpgsql, `migrations/`).

**Spec:** `docs/superpowers/specs/2026-10-28-gastos-y-cuentas-del-personal-design.md`. Para esta
entrega importan "Quién ve y hace qué", 1.2 (quién edita), 1.3 (el modal abierto desde el
cierre), 1.4, 3, 5 y 7. La base es el plan de la entrega 1,
`docs/superpowers/plans/2026-10-28-gastos-1-vehiculos-rubros-y-gastos.md`, con su código
(`migrations/411_gastos_1_tablas_y_rpcs.sql`, `ModalGasto`, `useGastosQuery`). Maqueta:
`docs/superpowers/specs/2026-10-28-gastos-y-personal-maquetas.html`, pestaña "Rendición" y bloque
"Con qué plata" de "Registrar gasto".

**Base de la rama:** la entrega 1 es el PR #1287, abierto al escribir esto, con las migs 411 y 412
ya aplicadas en prod. Esta rama la lleva mergeada. El PR de esta entrega va después de que #1287
entre a `main`.

## Lo que hay hoy (relevado en prod el 2026-10-29, sólo lectura)

- **`confirmar_rendicion(p_fecha, p_transportista_id, p_estado, p_observaciones DEFAULT NULL,
  p_gastos jsonb DEFAULT '[]')`**:
  - hace upsert de `rendiciones_control` por `(fecha, transportista_id, sucursal_id)`, con
    `current_sucursal_id()`, y pone `resuelta_at` en NULL;
  - inserta `p_gastos` en `rendicion_gastos`;
  - no mira ninguna guarda de caja.
- **`rendicion_gastos`** tiene 0 filas. La leen sólo `confirmar_rendicion` y
  `obtener_resumen_rendiciones`. En esta última, `gastos_agg` además aporta filas a
  `fechas_activas` (#639), así que una rendición con sólo gastos aparece en la grilla.
- **Estados**:
  - cerrada es `estado IN ('confirmada','resuelta')`;
  - una rendición pendiente no tiene fila;
  - `disconformidad` no está cerrada.
- **La foto (#1248)**: `trg_rendiciones_control_foto` la toma sólo al pasar a cerrada. "Editar
  cierre" sobre una confirmada no la rehace.
- **Las guardas**:
  - `rendicion_dia_cerrada` y `ultima_fecha_caja_cerrada` frenan pagos;
  - `control_rendicion_cerrado(transportista, sucursal, fecha)` es la de una rendición (#1175): es
    DEFINER, está en la lista blanca de SEG-A y `authenticated` la ejecuta;
  - ninguna frena "Editar cierre".
- **Reapertura**: `trg_pedidos_anular_control` y `desmarcar_rendicion_controlada` borran la fila
  de control, y la rendición vuelve a pendiente.
- **La vista del transportista** es `VistaRendiciones` en modo "Mis cobros" (#724), de sólo
  lectura. Las RPCs de lectura le devuelven sólo lo suyo; la tabla `gastos` no la puede leer (RLS).
- **Acciones por estado**: "Editar cierre" aparece en confirmada y resuelta; disconformidad ofrece
  sólo "Resolver".
- **`obtener_detalle_rendicion`** nunca sumó gastos: es el detalle de pagos por cliente, así que no
  cambia. La lista de gastos sale de la RPC nueva.

## Decisiones de este plan

Las propuso el diseñador del plan y el dueño las aprobó en chat el 2026-10-29 ("Sí, aprobadas"),
junto con aplicar la migración fuera del horario de cierre (Tarea 8).

1. **"Pendiente" es "no cerrada".** Un gasto de rendición se carga, se cambia o se anula desde
   Gastos mientras la rendición no esté confirmada ni resuelta; disconformidad incluida. La guarda
   es `control_rendicion_cerrado`. `rendicion_dia_cerrada` y `ultima_fecha_caja_cerrada` siguen
   frenando pagos y no se suman a los gastos, porque hoy no frenan "Editar cierre".
2. **Quitar en el cierre un gasto ya guardado lo anula** con el motivo "Quitado en el cierre de la
   rendición". Quién y cuándo quedan en la anulación.
3. **Sin vehículo habitual.** Vive en el empleado (entrega 3), así que el modal del cierre abre sin
   vehículo y la entrega 3 lo precarga.
4. **Efectivo a entregar negativo**: se muestra en rojo, con "Los gastos superan el efectivo
   cobrado."
5. **La rendición muestra todos sus gastos**, también uno compartido: es plata de esa rendición.
6. **El transportista** tiene que tener asignada la sucursal del gasto, y la rendición no puede ser
   de un día que todavía no llegó.

## Global Constraints

- **`CLAUDE.md` de la raíz rige todo**, como en la entrega 1:
  - trampa 3: el número de migración se elige al aplicar;
  - trampa 5: los parámetros de RPC van en `INTEGER`, y al cambiar una firma se dropea la vieja;
  - funciones nuevas con `REVOKE … FROM PUBLIC, anon`; las de server, además `authenticated`;
  - "el día es el argentino": `_tablero_hoy()` en SQL, `America/Argentina/Tucuman` en el front.
- **Verificación**: `npm ci` ya está hecho. Antes de cerrar una tarea con front se corren
  `npm run typecheck`, `npm run lint`, `npm run test:run` (sin `.env`) y `npm run build`. El
  pre-commit corre la suite entera; nunca `--no-verify`.
- **Migración**: `migrations/NNN_gastos_3_rendicion.sql`, con NNN literal.
  - **Nadie aplica**: el controlador aplica con el OK del dueño.
  - En prod (proyecto `hmuchlzmuqqxcldbzkgc`, `execute_sql`) se corren sólo SELECTs, el ensayo
    solo y el acumulado `BEGIN; SET LOCAL lock_timeout='5s'; <mig>; <ensayo>; ROLLBACK;`. Las migs
    411 y 412 ya están en prod, así que el acumulado lleva sólo la nueva.
- **Ensayos**: el molde es el del plan 1, `scripts/test-venta-j-1098.sql`: un `DO $ensayo$`,
  canarios con ERRCODE `P0099` y cierre `ENSAYO OK` o `ENSAYO FALLÓ`.
  - Cada RPC se llama como el front, con `SET LOCAL ROLE authenticated`, `request.jwt.claims` y
    `request.headers` con `x-sucursal-id`, igual que en `scripts/test-cargo-2.sql`.
  - Los usuarios se eligen en runtime desde `perfiles` y `usuario_sucursales`: un admin con una
    sola sucursal, un encargado y dos transportistas de esa sucursal.
- **Funciones**:
  - Las RPCs del front llevan `SECURITY DEFINER SET search_path = public`,
    `REVOKE ALL … FROM PUBLIC, anon` y `GRANT EXECUTE … TO authenticated, service_role`. Cada una
    nombra un helper de rol (`es_encargado_o_admin()`, `es_transportista()`), porque SEG-A
    (`auditoria_definer_sin_rol`) busca eso en el texto.
  - Los helpers de server llevan `REVOKE ALL … FROM PUBLIC, anon, authenticated` y
    `GRANT EXECUTE … TO service_role`.
- **Gates**:
  - no hay tablas nuevas ni escritura REST: `scripts/grants-rest.json` no cambia;
  - los helpers nuevos van a `RPCS_SIN_EXECUTE_PARA_AUTHENTICATED` de
    `src/test/rpcsSoloServidor.test.ts`.
- **Mensajes del server** (`RAISE EXCEPTION`, llegan en `error.message`):
  - `'Elegí de qué rendición salió la plata: el transportista y el día'`
  - `'La rendición no puede ser de un día que todavía no llegó'`
  - `'Ese transportista no es de la sucursal del gasto'`
  - `'Esa rendición ya está cerrada: el gasto se carga desde «Editar cierre» en Rendiciones'`
  - `'Este gasto es de una rendición cerrada: se cambia desde «Editar cierre» en Rendiciones'`
  - `'Este gasto es de una rendición cerrada: se quita desde «Editar cierre» en Rendiciones'`
  - `'Los gastos del cierre vienen con un formato inválido'`
  - `'Los gastos de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre'`
  - `'Ese gasto no es de esta rendición o ya está anulado'`
  - `'Un gasto viene dos veces en el cierre'`
  - `'El gasto cambió mientras lo guardabas: volvé a intentarlo'`
  - Un error de un gasto del cierre se prefija con `'En el gasto de <rubro>: '`, o con
    `'En un gasto del cierre: '` si el rubro no existe.
  - El motivo de la anulación al quitar en el cierre es `'Quitado en el cierre de la rendición'`.
  - "Un empleado" sigue rechazado con el mensaje de la 411.
- **Textos del front**:
  - **Bloque de plata en `ModalGasto`**: "Con qué plata se pagó" con asterisco y las pastillas "La
    oficina" y "Una rendición". Con rendición, un buscador con placeholder "Transportista" y un
    día con `aria-label="Día de la rendición"`. Ayuda: "Se descuenta del efectivo que entrega ese
    día. Si esa rendición ya está cerrada, el gasto se carga desde «Editar cierre» en
    Rendiciones."
  - **`ModalGasto` desde el cierre**:
    - la línea "Con la plata de la rendición de **{nombre}** del {dd/mm}. Se descuenta del
      efectivo que entrega.";
    - el botón "Agregar a la rendición" en el alta y "Aplicar cambios" en la edición;
    - la nota "Se guarda cuando confirmes el cierre.".
  - **Tarjeta**: "Efectivo a entregar". Con gastos, la línea "{$X} cobrados en efectivo − {$Y} de
    {n} gasto pagado con esa plata", o "{n} gastos pagados" en plural. Si da negativo: "Los gastos
    superan el efectivo cobrado."
  - **Cierre**:
    - el bloque "Efectivo", con "Cobrado en efectivo", "Gastos pagados con esa plata ({n})" y "A
      entregar";
    - la sección "Gastos pagados con la plata del día", con el botón "Agregar gasto";
    - la ayuda "Abre el mismo «Registrar gasto», con la plata fija en esta rendición. Cada gasto
      queda en Gastos con su rubro y su vehículo.";
    - sin gastos, "Sin gastos pagados con esta plata";
    - un gasto quitado dice "Se quita al confirmar" y tiene "Deshacer";
    - la nota del pie: "Si lo pagó con plata propia, no va acá.". La entrega 3 completa la frase.
  - **Vista Gastos**:
    - la línea "Rendición de {nombre} del {dd/mm}";
    - el grupo de pastillas "Con qué plata", con "Todas", "La oficina" y "Rendiciones";
    - en una rendición cerrada, "Se cambia desde «Editar cierre»".
  - **Excel**: la columna "Con qué plata", con "La oficina" o "Rendición de {nombre} del
    {dd/mm/aaaa}".
  - Plata con `formatPrecio`.
- **Permisos.** Los valida el server; el front sólo esconde.
  - Un gasto de rendición sigue las reglas de cualquier gasto: el admin, los de su sucursal; el
    encargado, sólo los suyos y sin compartido. La regla está en `puedeTocarGasto`.
  - Además, uno de una rendición cerrada se toca sólo desde el cierre.
  - El transportista ve su efectivo a entregar y sus gastos, y nada de otro: la RPC da 42501.
  - Los sueldos nunca se pagan con plata de una rendición. Esta entrega no los toca; la 4 no ofrece
    esa opción.
- **Modelo por tarea**: la migración con **Opus**, esfuerzo high. El front con **Sonnet**, esfuerzo
  high; si el review encuentra lógica floja en una tarea, se repite esa con Opus.

## Review Focus

1. **Rendición cerrada, desde Gastos.** Desde la vista Gastos no se puede:
   - cargar un gasto a una rendición confirmada;
   - editar o anular uno de una rendición cerrada;
   - moverlo de una rendición cerrada a la oficina.

   Cada intento recibe el mensaje que manda a «Editar cierre», y la vista no ofrece lápiz ni
   anular. Lo cubren el ensayo de la Tarea 2 y el test de la Tarea 5.
2. **El encargado reconfirma un cierre con gastos del admin.** Si no los toca, anda, porque no
   viajan en `guardar`. Si los toca, se rechaza con el prefijo del gasto. Lo cubren el ensayo de la
   Tarea 2, el test de `cambiosDelCierre` (Tarea 1) y el de la Tarea 6.
3. **Alguien carga o quita un gasto mientras otro cierra.** El cierre falla con "Los gastos de esta
   rendición cambiaron…" y no se guarda nada: ni gastos ni estado. Ensayo de la Tarea 2.
4. **Gastos que superan el efectivo cobrado.** El efectivo a entregar da negativo, en rojo y con
   el aviso, en la tarjeta, en el cierre y en "Mis cobros". Tests de las Tareas 1, 6 y 7.
5. **Rendición que vuelve a abrirse**, por disconformidad, por `desmarcar_rendicion_controlada` o
   por un cambio de entrega que borra el control. Sus gastos se vuelven a editar desde Gastos y
   siguen restando. Ensayo de la Tarea 2.

---

### Task 1: Tipos y reglas puras del efectivo y del cierre

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/types/gastos.ts`, `src/utils/gastos.ts` y `src/utils/gastos.test.ts`.
- Modify: las fixtures de `Gasto` en `src/components/modals/ModalFichaVehiculo.test.tsx`,
  `src/components/modals/ModalGasto.test.tsx`,
  `src/components/vistas/__tests__/VistaGastos.test.tsx`, `src/utils/exportGastos.test.ts` y
  `src/utils/vehiculos.test.ts`. Suman `rendicion_transportista_id: null` y
  `rendicion_fecha: null`.
- Create: `src/utils/rendicionGastos.ts` y `src/utils/rendicionGastos.test.ts`.

**Interfaces (Produces):**
- **`src/types/gastos.ts`**:
  - `Gasto` suma `rendicion_transportista_id: string | null` y `rendicion_fecha: string | null`.
  - `GuardarGastoPayload`:
    - `origen_pago` pasa a `'oficina' | 'rendicion'`;
    - suma `rendicion_transportista_id?: string | null` y `rendicion_fecha?: string | null`.
  - `export interface GastoDeRendicion extends Gasto { km_tablero: number | null }`: un elemento
    de `obtener_gastos_rendiciones`, que siempre trae `rubro` y `vehiculo`.
  - `export interface CambiosGastosRendicion { vistos: number[]; guardar: GuardarGastoPayload[]; quitar: number[] }`:
    lo que recibe `confirmar_rendicion` en `p_gastos_rendicion`.
- **`src/utils/gastos.ts`**:
  `puedeTocarGasto(g: Pick<Gasto, 'compartido' | 'creado_por'>, quien: { esAdmin: boolean; usuarioId: string; tieneTodasLasSucursales: boolean }): boolean`.
  Es la regla que hoy vive inline en `VistaGastos` (`puedeTocar`).
- **`src/utils/rendicionGastos.ts`**:
  - `claveRendicion(transportistaId: string, fecha: string): string` → `` `${transportistaId}|${fecha}` ``.
  - `efectivoAEntregar(efectivoCobrado: number, gastos: number): number`: la resta redondeada a 2
    decimales.
  - `payloadDeGasto(g: Gasto & { km_tablero?: number | null }): GuardarGastoPayload`: todas las
    claves de `GuardarGastoPayload`, con `id`, y `km_tablero` en `null` si no viene. Un
    `origen_pago` distinto de `'rendicion'` da `'oficina'`.
  - `export interface ItemCierre { clave: string; original: GastoDeRendicion | null; payload: GuardarGastoPayload; editado: boolean; quitado: boolean }`.
  - `itemsDelCierre(gastos: GastoDeRendicion[]): ItemCierre[]`: un ítem por gasto, con clave
    `` `g${id}` ``, sin editar ni quitar.
  - `totalDelCierre(items: ItemCierre[]): { cantidad: number; total: number }`: los no quitados;
    suma `payload.monto_total`.
  - `cambiosDelCierre(items: ItemCierre[], vistos: number[]): CambiosGastosRendicion`:
    - `guardar` lleva el `payload` de los no quitados que son nuevos (`original` null) o editados;
    - `quitar` lleva el `id` de los quitados que tienen `original`;
    - un ítem nuevo que después se quitó no va a ningún lado.

- [ ] **Step 1: Tests**, con estos valores:
  - `efectivoAEntregar(1245300, 50000) === 1195300`, `efectivoAEntregar(0, 50000) === -50000` y
    `efectivoAEntregar(100.1, 0.2) === 99.9`.
  - `payloadDeGasto` de un combustible con factura A, vehículo 3, 38,5 litros, km 184230, de la
    rendición `('tr-1', '2026-10-28')`, da exactamente
    `{ id: 7, fecha: '2026-10-28', rubro_id: 1, monto_total: 50000, comprobante: 'factura_a', comprobante_numero: '0005-00012345', alicuota_iva: 21, iva: 8677.69, percepcion_iva: 0, percepcion_iibb: 0, otros_impuestos: 0, sucursal_id: 1, compartido: false, vehiculo_id: 3, litros: 38.5, km_tablero: 184230, mes_imputado: '2026-10-01', repartir_meses: 1, origen_pago: 'rendicion', rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28', observacion: null }`.
  - `cambiosDelCierre` con los ítems 7 (sin tocar), 8 (editado), 9 (quitado), uno nuevo y otro
    nuevo quitado, y vistos `[7, 8, 9]`, da
    `{ vistos: [7, 8, 9], guardar: [payload8, payloadNuevo], quitar: [9] }`.
  - `totalDelCierre` de 50000, 12000 quitado y 8500 da `{ cantidad: 2, total: 58500 }`.
  - `puedeTocarGasto`:
    - un admin, con un compartido ajeno y sin todas las sucursales → `false`; con todas → `true`;
    - un encargado, con uno suyo → `true`; con uno ajeno → `false`; con uno suyo pero compartido →
      `false`.
- [ ] **Step 2: Ver que fallan.** `npx vitest run src/utils/rendicionGastos.test.ts src/utils/gastos.test.ts`
- [ ] **Step 3: Implementar**, actualizar las fixtures y correr typecheck y lint.
- [ ] **Step 4: Commit** `feat(gastos): reglas puras del efectivo a entregar y del cierre`.

---

### Task 2: Migración 3 — los gastos de la rendición

Modelo: Opus, esfuerzo high. Cambia funciones vivas (`confirmar_rendicion`, `resolver_rendicion`,
`obtener_resumen_rendiciones`, `guardar_gasto` y `anular_gasto`). Cada una se parchea sobre su
definición **viva** (`pg_get_functiondef`), no sobre un archivo viejo.

**Files:**
- Create: `migrations/NNN_gastos_3_rendicion.sql` y `scripts/test-gastos-3.sql`.
- Modify: `scripts/test-rendicion-congelada-1248.sql`. Sus tres llamadas a `confirmar_rendicion`
  pasan a la firma nueva, con `p_gastos_rendicion` en
  `'{"vistos":[],"guardar":[],"quitar":[]}'`.
- Modify: `src/test/rpcsSoloServidor.test.ts`. Suma `_guardar_gasto`, `_anular_gasto`,
  `_rendicion_clave` y `_rendicion_bloquear` con `'NNN_gastos_3'`.

**Interfaces (Produces):**

**`gastos`**:
- `rendicion_transportista_id uuid`, con FK a `perfiles(id)` (NO ACTION, como
  `pagos.usuario_id`). Es la única FK de `gastos` a `perfiles`; `creado_por` y `anulado_por`
  siguen sin FK.
- `rendicion_fecha date`.
- `CHECK gastos_rendicion_check`: con `origen_pago = 'rendicion'` van las dos columnas, y con
  cualquier otro origen las dos en NULL.
- Índice `gastos_rendicion_idx` sobre `(sucursal_id, rendicion_fecha, rendicion_transportista_id)`
  `WHERE origen_pago = 'rendicion'`.
- Un `COMMENT` en cada columna.

**Helpers de server**:
- `_rendicion_clave(p_transportista_id uuid, p_fecha date, p_sucursal_id bigint) RETURNS bigint IMMUTABLE`:
  `hashtextextended('rendicion|' || transportista || '|' || fecha || '|' || sucursal, 0)`, con el
  molde de las migs 167 y 235.
- `_rendicion_bloquear(p_claves bigint[]) RETURNS void`: `pg_advisory_xact_lock` de cada clave no
  nula, sin repetir y en orden ascendente, en un `FOR`. El orden evita el deadlock entre dos
  transacciones que mueven gastos entre las mismas dos rendiciones.

**`_guardar_gasto(p_gasto jsonb, p_desde_cierre boolean) RETURNS bigint`** (SECURITY DEFINER, de
server). Es el cuerpo vivo de `guardar_gasto` (411) con estos cambios:
- Lee `rendicion_transportista_id` y `rendicion_fecha` del jsonb, dentro del mismo bloque de
  formato.
- **El paso 8 (origen) se reemplaza**:
  - con `oficina`, las dos columnas van en NULL, venga lo que venga;
  - con `rendicion`, en este orden:
    1. las dos tienen que venir;
    2. `rendicion_fecha <= _tablero_hoy()`;
    3. el transportista tiene la sucursal del gasto en `usuario_sucursales`;
  - con `empleado`, el mensaje de la 411.
- **Orden de locks: primero la rendición y después la fila del gasto, en todo camino.**
  - Con `p_desde_cierre`, `confirmar_rendicion` ya bloqueó la rendición, así que el `FOR UPDATE`
    del paso 3 queda como está.
  - Sin `p_desde_cierre`, el paso 3 lee el gasto **sin lock**. El `FOR UPDATE` pasa a un paso 8b,
    justo antes del 9:
    1. `_rendicion_bloquear` con las claves de la rendición vieja y la nueva que no sean NULL. En
       un alta, sólo la nueva.
    2. En una edición, se relee el gasto `FOR UPDATE`. Si su rendición cambió entre las dos
       lecturas: `'El gasto cambió mientras lo guardabas…'`.
    3. Los pasos 9 y 10 miran la fila releída.
- **Paso 10 nuevo, la rendición cerrada** (sin `p_desde_cierre`):
  - si la rendición vieja está cerrada (`control_rendicion_cerrado`): `'Este gasto es de una
    rendición cerrada: se cambia…'`;
  - si la nueva está cerrada: `'Esa rendición ya está cerrada…'`.
- El `INSERT` y el `UPDATE` escriben las dos columnas nuevas.
- **`guardar_gasto(p_gasto jsonb)`** queda como wrapper: el guard
  `IF NOT public.es_encargado_o_admin()` con el mensaje de la 411, y
  `RETURN public._guardar_gasto(p_gasto, false)`. Misma firma: conserva los grants.

**`_anular_gasto(p_gasto_id bigint, p_motivo text, p_desde_cierre boolean) RETURNS void`** (de
server). Es el cuerpo vivo de `anular_gasto`, con el mismo orden de locks:
- con `p_desde_cierre`, `FOR UPDATE` directo;
- sin él, se lee sin lock; si el gasto es de rendición, se la bloquea; después se relee
  `FOR UPDATE`.

Las validaciones de hoy corren sobre la fila releída. Si la rendición está cerrada y no es
`p_desde_cierre`: `'Este gasto es de una rendición cerrada: se quita…'`. `anular_gasto(bigint,
text)` queda como wrapper con el guard de rol.

**`confirmar_rendicion`**:
- `DROP FUNCTION public.confirmar_rendicion(date, uuid, text, text, jsonb)`.
- `CREATE FUNCTION public.confirmar_rendicion(p_fecha date, p_transportista_id uuid, p_estado text, p_gastos_rendicion jsonb, p_observaciones text DEFAULT NULL) RETURNS bigint`.
  `p_gastos_rendicion` va antes de `p_observaciones` porque no tiene default. El front llama por
  nombre.
- En orden:
  1. Sucursal, rol y estado, como hoy.
  2. `_rendicion_bloquear(ARRAY[_rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)])`.
  3. **Formato**: un objeto con `vistos` y `quitar` (arrays de números) y `guardar` (array de
     objetos); una clave ausente es `[]`. Si no: `'Los gastos del cierre vienen con un formato
     inválido'`.
  4. **Vivos**: los ids de `gastos` con `origen_pago = 'rendicion'`, esta clave y
     `anulado_at IS NULL`. Comparados como conjunto contra `vistos`, si difieren: `'Los gastos de
     esta rendición cambiaron…'`.
  5. **Ids**: cada id de `quitar` y cada `id` de `guardar` tienen que ser vivos (`'Ese gasto no es
     de esta rendición…'`). Ninguno se repite ni está en las dos listas (`'Un gasto viene dos veces
     en el cierre'`).
  6. **Quitar**: `_anular_gasto(id, 'Quitado en el cierre de la rendición', true)` para cada uno.
  7. **Guardar**: cada elemento se pisa con
     `jsonb_build_object('origen_pago','rendicion','rendicion_transportista_id',p_transportista_id,'rendicion_fecha',p_fecha,'sucursal_id',v_sucursal_id)`
     y va a `_guardar_gasto(elem, true)`. Un error se vuelve a lanzar con el prefijo
     `'En el gasto de <rubro>: '`.
  8. **El upsert de `rendiciones_control`**, idéntico al de hoy.
  9. `RETURN` del id.
- No escribe `rendicion_gastos`.
- `REVOKE ALL … FROM PUBLIC, anon` y `GRANT EXECUTE … TO authenticated, service_role`.

**`resolver_rendicion`**: suma `PERFORM public._rendicion_bloquear(ARRAY[public._rendicion_clave(p_transportista_id, p_fecha, v_sucursal_id)])`
antes de leer el control. Lo demás, igual.

**`obtener_resumen_rendiciones`**: misma firma y mismo retorno (`CREATE OR REPLACE`). Sólo cambia
la CTE `gastos_agg`, que sigue aportando filas a `fechas_activas`:
```sql
gastos_agg AS (
  SELECT g.rendicion_transportista_id AS t_id, g.rendicion_fecha AS f,
         SUM(g.monto_total)::numeric AS tot_g, COUNT(*)::bigint AS cant_g
    FROM gastos g
   WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
     AND g.sucursal_id = v_sucursal_id
     AND g.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
     AND (p_transportista_id IS NULL OR g.rendicion_transportista_id = p_transportista_id)
   GROUP BY 1, 2
)
```

**`obtener_gastos_rendiciones(p_fecha_desde date, p_fecha_hasta date, p_transportista_id uuid DEFAULT NULL) RETURNS jsonb`**
(nueva, SECURITY DEFINER, STABLE):
- **Roles**: los mismos que `obtener_resumen_rendiciones` (#724). Admin y encargado ven cualquiera
  de la sucursal; el transportista, sólo lo suyo, con 42501 si pide otro.
- **Devuelve** un array, `'[]'` si no hay nada, con los gastos vivos de rendición de la sucursal
  actual en el rango. Están ordenados por `rendicion_fecha DESC`, transportista e id. Cada
  elemento lleva:
  - las columnas de `GASTO_COLUMNAS`, más `rendicion_transportista_id` y `rendicion_fecha`;
  - `rubro: {id, nombre, grupo}`;
  - `vehiculo: {id, patente, descripcion}` o null;
  - `km_tablero`, la lectura de `vehiculo_km` del gasto, o null.

**`rendicion_gastos`**: si tiene filas, la migración aborta con
`'rendicion_gastos tiene filas: revisalas antes de retirarla'`. Si no, `DROP TABLE`.

**Auditoría**: check **`GASTO-A`** (high) en `auditoria_integridad()`. Hoy no hay ningún id
`GASTO-*`: igual, al aplicar se revisa la lista viva.
- **Qué cuenta**: gastos de rendición, anulados incluidos, cuya rendición está cerrada y cuyo
  `updated_at` es posterior al cierre. El cierre es `resuelta_at` si la rendición está resuelta y
  `controlada_at` si está confirmada.
- **Por qué da 0 en todo camino legítimo**:
  - "Editar cierre" escribe el gasto y `controlada_at` con el mismo `now()`;
  - un cambio durante la disconformidad es anterior a `resuelta_at`.
- **Molde**: el del check más reciente de la función viva.

**Verificación estructural** al final de la migración (`DO $verif$`):
- queda una sola `confirmar_rendicion`, y
  `to_regprocedure('public.confirmar_rendicion(date,uuid,text,text,jsonb)')` es NULL;
- `to_regclass('public.rendicion_gastos')` es NULL;
- `authenticated` no ejecuta los cuatro helpers, y `anon` no ejecuta nada nuevo.

- [ ] **Step 1: Ensayo `scripts/test-gastos-3.sql`.** Elige un día D sin fila de control para
  el transportista T. El ensayo corre en una transacción que se deshace, así que puede borrar o
  crear controles. Aserciones:
  1. **Pendiente**: un gasto de rendición `(T, D)` de 8000 anda. `obtener_resumen_rendiciones(D, D, T)`
     da `total_gastos` 8000 y `cantidad_gastos` 1, aunque T no tenga pagos ese día.
  2. **Lectura**: `obtener_gastos_rendiciones(D, D, NULL)`:
     - como T, trae ese gasto con su `rubro` y `km_tablero`;
     - como el otro transportista, no lo trae;
     - como T pidiendo al otro, da 42501.
  3. **Validaciones**: falla cada una con su mensaje:
     - un gasto de rendición sin día;
     - con D en el futuro;
     - con un transportista sin la sucursal;
     - con `origen_pago: 'empleado'`.
  4. **Cierre**: como admin, `confirmar_rendicion(D, T, 'confirmada', {vistos:[g1], guardar:[nuevo de 5000], quitar:[]})`.
     El estado queda confirmada, hay 2 gastos vivos y `total_gastos` da 13000.
  5. **Cerrada**: desde `guardar_gasto` y `anular_gasto` falla cada caso con su mensaje:
     - editar g1;
     - anular g1;
     - mover g1 a la oficina;
     - cargar uno nuevo a `(T, D)`.
  6. **Editar cierre**: `vistos [g1,g2]`, con g1 a 9000 en `guardar` y g2 en `quitar`. g2 queda
     anulado con el motivo del spec; `total_gastos` da 9000 y el estado sigue confirmada.
  7. **Concurrencia**: con `vistos [g1]` mientras hay otro vivo → `'Los gastos de esta rendición
     cambiaron…'`, sin cambios en el estado ni en los gastos. Un id de otra rendición en `quitar`
     → `'Ese gasto no es de esta rendición…'`.
  8. **Encargado**:
     - reconfirma con `guardar: []` y un gasto del admin vivo, y anda;
     - si manda ese gasto en `guardar`, falla con `'En el gasto de … : El encargado sólo edita…'`.
  9. **Reapertura**:
     - tras `confirmar_rendicion(…, 'disconformidad', …)`, g1 se edita desde `guardar_gasto`;
     - tras `resolver_rendicion` ya no;
     - tras `desmarcar_rendicion_controlada`, otra vez sí.
  10. **Firmas y permisos**:
      - la firma vieja no existe, y `rendicion_gastos` tampoco;
      - `anon` no ejecuta nada nuevo;
      - `authenticated` no ejecuta los cuatro helpers;
      - `auditoria_definer_sin_rol()` no lista ninguna función de esta migración.
  11. **GASTO-A**: da 0 después de todo lo anterior. Con la rendición confirmada otra vez, un
      `UPDATE gastos SET updated_at = now() + interval '1 minute'` sobre g1 lo pone en 1.
- [ ] **Step 2: Ensayo solo en prod → `ENSAYO FALLÓ`.**
- [ ] **Step 3: Migración**, con `SET LOCAL lock_timeout = '5s'` arriba. El comentario de cabecera
  va al estilo de la 411:
  - qué agrega y por qué;
  - el vínculo por clave;
  - el orden de locks;
  - el despliegue: va junto con el front, porque el bundle viejo manda `p_gastos`.
- [ ] **Step 4: Ensayos acumulados**:
  - `BEGIN; …mig…; …test-gastos-3…; ROLLBACK;` → `ENSAYO OK`;
  - `BEGIN; …mig…; …test-rendicion-congelada-1248…; ROLLBACK;` → OK, para que la foto de #1248
    siga andando con la firma nueva;
  - en la misma transacción, `auditoria_integridad()->'critical_high_en_rojo'` da igual que antes.
- [ ] **Step 5: `npx vitest run src/test/rpcsSoloServidor.test.ts`, y commit**
  `feat(gastos): los gastos de la rendición se guardan con el cierre (mig NNN)`.

---

### Task 3: Datos — columnas, rendiciones y props del modal

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify:
  - `src/hooks/queries/gastoColumnas.ts`, que suma `rendicion_transportista_id,rendicion_fecha`
    como literal;
  - `src/hooks/queries/useGastosQuery.ts`, su test y `src/hooks/queries/index.ts`;
  - `src/hooks/supabase/useRendiciones.ts`;
  - `src/types/hooks.ts` (`src/types/index.ts` lo re-exporta entero: no cambia);
  - `src/hooks/supabase/useRendiciones.errores.test.ts` y `src/hooks/queries/errores.compras.test.tsx`,
    con los argumentos nuevos de `confirmarRendicion`.
- Create: `src/hooks/usePropsModalGasto.ts` y su test.

**Interfaces:**
- **Consumes**: los tipos de la Tarea 1 y las RPCs de la Tarea 2.
- **Produces**:
  - `gastosKeys.todas = () => ['gastos'] as const`: el prefijo de todas las sucursales.
  - `useRendicionesCerradasQuery(claves: Array<{ transportista_id: string; fecha: string }>): UseQueryResult<Set<string>>`:
    - lee `from('rendiciones_control').select('transportista_id,fecha').in('estado', ['confirmada','resuelta']).in('fecha', <fechas únicas>)`
      (la RLS deja leer a admin y encargado, en la sucursal actual);
    - devuelve las `claveRendicion` que coinciden con alguna clave pedida;
    - key `[...gastosKeys.all(suc), 'rendiciones-cerradas', <fechas únicas ordenadas>]`;
    - `enabled` sólo con claves;
    - `staleTime` 30 s.
  - `ResumenRendicionDiaria` (`src/types/hooks.ts`):
    - suma `gastos: GastoDeRendicion[]`;
    - el comentario de `total_gastos` pasa a "gastos pagados con la plata de esta rendición
      (`gastos.monto_total`, sin anulados)";
    - se borra `RendicionGastoInput`.
  - `useRendiciones`:
    - **`fetchResumen`** pide en paralelo `obtener_resumen_rendiciones` y
      `obtener_gastos_rendiciones`, con el mismo rango y transportista:
      - el error del resumen se mira primero, con su mensaje de hoy;
      - el de los gastos lleva `'Sin conexión: no se pudieron cargar los gastos de las rendiciones. Revisá la señal e intentá de nuevo.'`;
      - cada resumen recibe los gastos de su `claveRendicion`, o `[]`.
    - **`confirmarRendicion(fecha: string, transportistaId: string, estado: 'confirmada' | 'disconformidad', observaciones: string | null, gastos: CambiosGastosRendicion)`**
      manda `{ p_fecha, p_transportista_id, p_estado, p_observaciones, p_gastos_rendicion: gastos }`.
      El hook sigue sin TanStack: sus tests lo renderizan sin `QueryClientProvider`.
  - `usePropsModalGasto(): Pick<ModalGastoProps, 'rubros' | 'vehiculos' | 'sucursalActual' | 'sucursalesUsuario' | 'sucursalesActivas' | 'esAdmin' | 'usuarioId' | 'tieneTodasLasSucursales' | 'onCrearRubro'>`.
    Es lo que hoy arma `GastosContainer`:
    - `rubros`, sólo los activos;
    - `tieneTodasLasSucursales`, comparando con `useSucursalesActivasQuery`;
    - `onCrearRubro`, sólo para el admin, con `useGuardarRubroGastoMutation`.

- [ ] **Step 1: Tests:**
  - `useRendicionesCerradasQuery` con las claves `[{tr-1, 2026-10-27}, {tr-2, 2026-10-28}]`:
    - encadena `in('estado', ['confirmada','resuelta'])` e `in('fecha', ['2026-10-27','2026-10-28'])`;
    - si la base devuelve `(tr-1, 27)` y `(tr-1, 28)`, el `Set` tiene sólo `'tr-1|2026-10-27'`.
  - `confirmarRendicion` manda `p_gastos_rendicion` tal cual y no manda `p_gastos`.
  - `fetchResumen`:
    - un resumen `(tr-1, 2026-10-05)` recibe el gasto con `rendicion_transportista_id: 'tr-1'` y
      `rendicion_fecha: '2026-10-05'`;
    - otro sin gastos recibe `[]`;
    - si falla `obtener_gastos_rendiciones`, la carga falla con su mensaje.
  - `usePropsModalGasto`:
    - un encargado no tiene `onCrearRubro`;
    - un usuario con todas las sucursales activas da `tieneTodasLasSucursales: true`;
    - los rubros inactivos no vienen.
  - Los tests de errores de `useRendiciones` pasan con la firma nueva.
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(gastos): datos de los gastos de cada rendición`.

---

### Task 4: ModalGasto — con qué plata, desde el cierre y en borrador

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/components/modals/ModalGasto.tsx` y `src/components/modals/ModalGasto.test.tsx`.

**Interfaces:**
- **Consumes**: los tipos de la Tarea 1.
- **Produces**: `ModalGastoProps` suma
  ```ts
  /** Para "Una rendición". Sin la lista, la plata es siempre la oficina. */
  transportistas?: Array<{ id: string; nombre: string }>
  /** Abierto desde "Cerrar rendición": la plata es esa rendición y el modal trabaja en borrador. */
  desdeCierre?: { transportistaId: string; transportistaNombre: string; fecha: string }
  /** Los valores con que arranca. Pisan los de `gasto` y traen sus km: no se piden al server. */
  borrador?: GuardarGastoPayload | null
  ```
- **Schema**:
  - `origen_pago` pasa a `z.enum(['oficina', 'rendicion'])`;
  - suma `rendicion_transportista_id` (`z.string().nullable().optional()`) y `rendicion_fecha`
    (fecha ISO, nullable);
  - el `superRefine` exige las dos con `rendicion`, con el mensaje
    `'Elegí de qué rendición salió la plata: el transportista y el día'`.
- **El bloque "Con qué plata se pagó"** va después del bloque de sucursal. Aparece sólo con
  `transportistas` y sin `desdeCierre`.
  - Pastillas "La oficina" y "Una rendición".
  - Con rendición:
    - un `Combobox` de transportista, que busca por nombre;
    - el día, que arranca en la fecha del gasto y la sigue hasta que se lo cambia a mano;
    - la ayuda de Global Constraints.
  - Al editar un gasto de rendición, arranca en rendición, con su transportista y su día. Si el
    transportista no está en la lista, el `Combobox` muestra `textoSinOpcion="Otro usuario"`.
- **Con `desdeCierre`**:
  - en lugar del bloque va la línea fija;
  - la fecha del gasto arranca en `desdeCierre.fecha`;
  - el payload lleva `origen_pago: 'rendicion'` y esa rendición;
  - el botón y la nota son los de Global Constraints.
- **Con `borrador`**: el estado inicial sale de él (monto, comprobante, desglose, vehículo,
  litros, km, mes, reparto, sucursal, compartido, observación y origen), y `useKmDelGastoQuery`
  no se pide. `gasto` se sigue usando para las etiquetas de un rubro o un vehículo dado de baja y
  para la regla de compartido.
- **Payload**: con `oficina`, `rendicion_transportista_id` y `rendicion_fecha` van en `null`.

- [ ] **Step 1: Tests:**
  - "la plata arranca en la oficina": el payload lleva `origen_pago: 'oficina'` y las dos
    columnas de rendición en `null`.
  - "una rendición pide transportista y día":
    - sin transportista, el error del schema;
    - con Tito y el día 2026-10-28, el payload lleva `{ origen_pago: 'rendicion', rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28' }`.
  - "el día sigue a la fecha": cambiar la fecha a 2026-10-27 mueve el día; después de tocar el
    día, cambiar la fecha ya no lo mueve.
  - "sin transportistas no hay bloque de plata".
  - "desde el cierre":
    - no está "Con qué plata se pagó";
    - está "Con la plata de la rendición de Martín Sosa del 28/10";
    - el botón dice "Agregar a la rendición";
    - el payload sale con esa rendición y con `fecha: '2026-10-28'`.
  - "borrador": precarga el monto, el rubro y `km_tablero: 184230`, y no consulta `vehiculo_km`.
    Se ve en el mock de `from`.
  - "editar un gasto de rendición desde Gastos": arranca en "Una rendición" con su transportista.
  - Los tests de la entrega 1 siguen verdes.
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(gastos): el modal sabe con qué plata se pagó`.

---

### Task 5: Vista Gastos — la plata de cada gasto y las rendiciones cerradas

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify:
  - `src/components/vistas/VistaGastos.tsx` y `src/components/vistas/__tests__/VistaGastos.test.tsx`;
  - `src/components/containers/GastosContainer.tsx`;
  - `src/utils/exportGastos.ts` y `src/utils/exportGastos.test.ts`.

**Interfaces:**
- **Consumes**: `puedeTocarGasto` y `claveRendicion` (Tarea 1), y `useRendicionesCerradasQuery`
  y `usePropsModalGasto` (Tarea 3). También la Tarea 4 y `useTransportistasQuery`.
- **`VistaGastosProps`** suma `transportistas: Array<{ id: string; nombre: string }>` y
  `rendicionesCerradas: Set<string>`.
- **Vista**:
  - un gasto de rendición suma la línea "Rendición de {nombre} del {dd/mm}"; si no está en la
    lista, el nombre es "otro usuario";
  - las pastillas "Con qué plata" filtran por `origen_pago`;
  - `puedeTocar` pasa a `puedeTocarGasto`;
  - si el gasto es de una rendición cerrada (`rendicionesCerradas.has(claveRendicion(...))`), no
    hay lápiz ni anular, y se ve "Se cambia desde «Editar cierre»".
- **`GastosContainer`**:
  - arma los props comunes del modal con `usePropsModalGasto()`;
  - pasa `transportistas` (`id`, `nombre` de `useTransportistasQuery`) a la vista y al modal;
  - pide `useRendicionesCerradasQuery` con las claves de los gastos de rendición del mes.
- **Excel**: `OpcionesExportGastos` suma `transportistas?`, y la columna "Con qué plata" va
  después de "Sucursal".

- [ ] **Step 1: Tests:**
  - "un gasto de rendición dice 'Rendición de Tito Transportista del 28/10'".
  - "el filtro Rendiciones deja sólo esos, y La oficina sólo los otros".
  - "una rendición cerrada: sin lápiz ni anular, con 'Se cambia desde «Editar cierre»'". Con la
    clave fuera del `Set`, el lápiz está.
  - El Excel da `'Rendición de Tito Transportista del 28/10/2026'` y `'La oficina'`.
  - Los tests de permisos de la entrega 1 siguen verdes con `puedeTocarGasto`.
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(gastos): la vista Gastos muestra con qué plata se pagó`.

---

### Task 6: Cerrar rendición con gastos

Modelo: Sonnet, esfuerzo high. La lógica vive en la Tarea 1; acá se cablea.

**Files:**
- Modify: `src/components/modals/ModalCerrarRendicion.tsx`. Se van el texto libre, `NumberInput`
  y la cabecera que habla de `rendicion_gastos`.
- Create: `src/components/modals/ModalCerrarRendicion.test.tsx`.

**Interfaces:**
- **Consumes**: las Tareas 1, 3 y 4.
- **Produces**: `ModalCerrarRendicionProps`
  ```ts
  {
    fecha: string; transportistaId: string; transportistaNombre: string
    totalCobrado: number; totalEntregado: number; totalEntregas: number; totalCtasCte: number
    totalEfectivo: number
    gastos: GastoDeRendicion[]     // los vivos de esta rendición
    observacionesPrevias?: string | null
    onConfirmar: (estado: 'confirmada' | 'disconformidad', observaciones: string | null,
                  gastos: CambiosGastosRendicion) => Promise<void>
    onClose: () => void
    guardando: boolean
  }
  ```
- **Comportamiento**:
  - **Estado inicial**: `items` sale de `itemsDelCierre(gastos)` y `vistos`, de los ids de
    `gastos` al montar.
  - **Bloque "Efectivo"**, debajo del resumen de hoy: muestra `totalEfectivo`, el total de
    `totalDelCierre(items)` y `efectivoAEntregar`. Si da negativo, va en rojo con el aviso.
  - **Cada fila de la lista** muestra:
    - "{rubro} · {vehículo}", con los datos de `original` o, en un borrador, de los rubros y
      vehículos de `usePropsModalGasto`;
    - el comprobante, con su número y "{litros} litros";
    - el monto;
    - "Editar" y "Quitar" (`aria-label` "Editar gasto de {rubro}" y "Quitar gasto de {rubro}"),
      si la fila es un borrador o si `puedeTocarGasto(original, …)`.
  - **Quitar**: un borrador se va de la lista. Uno guardado queda tachado, con "Se quita al
    confirmar" y "Deshacer".
  - **"Agregar gasto" y "Editar"** abren `ModalGasto` (lazy) **dentro** de los children de
    `ModalBase`, no como hermano (regla de Radix del repo). Lleva:
    - los props de `usePropsModalGasto()`;
    - `desdeCierre={{ transportistaId, transportistaNombre, fecha }}`;
    - en la edición, `gasto={item.original}` y `borrador={item.payload}`.
  - **`onSave`** no llama al server:
    - un alta suma un ítem con clave `` `n${contador}` ``;
    - una edición reemplaza el payload y marca `editado`.
  - **Confirmar** llama `onConfirmar(estado, observaciones, cambiosDelCierre(items, vistos))`.
    Cancelar no manda nada.

- [ ] **Step 1: Tests.** Se mockean `usePropsModalGasto` y `./ModalGasto`; el stub muestra sus
  props y tiene un botón que llama `onSave` con un payload fijo.
  - "efectivo a entregar": `totalEfectivo` 1245300 y un gasto de 50000 → "A entregar" con
    `/1\.195\.300,00/`.
  - "agregar suma al borrador sin ir al server": el stub recibe `desdeCierre` con esa rendición y
    sin `borrador`. Después del `onSave`, la fila aparece y "A entregar" baja.
  - "quitar uno guardado lo tacha y lo saca del total; deshacer lo devuelve".
  - "confirmar manda los cambios":
    - con los gastos 7 y 8, editar el 7, quitar el 8 y agregar uno;
    - `onConfirmar` recibe `('confirmada', null, { vistos: [7, 8], guardar: [payload7, payloadNuevo], quitar: [8] })`.
  - "el encargado no tiene Editar ni Quitar en un gasto del admin, y puede confirmar igual": manda
    `guardar: []`.
  - "con gastos de más, A entregar va en rojo y avisa 'Los gastos superan el efectivo cobrado.'".
  - "cancelar no confirma".
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(gastos): el cierre de la rendición carga los gastos del día`.

---

### Task 7: La tarjeta y "Mis cobros" muestran el efectivo a entregar

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/components/vistas/VistaRendiciones.tsx` y
  `src/components/vistas/__tests__/VistaRendiciones.test.tsx`.

**Interfaces:**
- **Consumes**: las Tareas 1, 3 y 6.
- **`ResumenCard`**:
  - después del desglose por forma de pago va el bloque "Efectivo a entregar", con
    `efectivoAEntregar(total_efectivo, total_gastos)` y la línea de Global Constraints;
  - sale si `total_efectivo > 0` o si `cantidad_gastos > 0`;
  - debajo, una pastilla por gasto de `resumen.gastos`: "{rubro} · {descripción} {patente} ·
    {monto}", y sin vehículo, sin ese tramo;
  - reemplaza el indicador ámbar "N gastos · $X" (el de observaciones queda);
  - lo ven la oficina y el transportista.
- **El cierre** recibe `transportistaId`, `totalEfectivo={total_efectivo}` y `gastos`.
  `handleCerrar(estado, observaciones, cambios)` llama `confirmarRendicion` con los cambios.
- **Después de confirmar bien**, `queryClient.invalidateQueries({ queryKey: gastosKeys.todas() })`,
  para que la vista Gastos no muestre una lista vieja.
- **El test** pasa a envolver `renderVista` en un `QueryClientProvider`. Su mock de
  `hooks/queries` suma `gastosKeys: { todas: () => ['gastos'] }`: la vista no suma queries, pero
  importa las keys del barrel.

- [ ] **Step 1: Tests:**
  - **El stub del cierre**:
    - llama `onConfirmar(…, { vistos: [], guardar: [], quitar: [] })`;
    - `confirmar_rendicion` sale con `p_gastos_rendicion: { vistos: [], guardar: [], quitar: [] }`
      y sin `p_gastos`.
  - "la tarjeta muestra el efectivo a entregar":
    - el pendiente con `total_efectivo` 50000, `total_gastos` 8000 y `cantidad_gastos` 1;
    - `obtener_gastos_rendiciones` devuelve un combustible de 8000, Partner AC456EF, de
      `('tr-1', '2026-10-05')`;
    - la tarjeta dice "Efectivo a entregar", `/42\.000,00/`, "de 1 gasto pagado con esa plata" y
      "Combustible · Partner AC456EF".
  - "negativo": efectivo 0 y gastos 5000 → "Los gastos superan el efectivo cobrado.".
  - "sin efectivo ni gastos no hay bloque".
  - "el transportista lo ve en Mis cobros" (bloque de #724).
  - "el cierre recibe transportistaId, totalEfectivo y los gastos de su tarjeta": el stub los
    muestra.
  - "`fetchResumen` pide `obtener_gastos_rendiciones` con el mismo rango y transportista".
  - Los tests de hoy siguen verdes.
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(gastos): la rendición muestra el efectivo a entregar`.

---

### Task 8: Cierre — verificación, aplicación y PR

Lo hace el controlador, con el OK del dueño para aplicar.

- [ ] **Step 1: Verificaciones locales.** `npm run typecheck`, `npm run lint`, `npm run test:run`
  sin `.env` y `npm run build`. Las cuatro en verde.
- [ ] **Step 2: Ensayos acumulados en prod**, los dos de la Tarea 2, Step 4 → OK.
- [ ] **Step 3: Antes de aplicar:**
  - #1287 tiene que estar en `main`;
  - se aplica fuera del horario de cierre (aprobado por el dueño), porque hay una ventana entre la
    migración y el deploy del front. En ella, cerrar una rendición falla con `PGRST202`: el bundle
    viejo manda `p_gastos`, que ya no existe. No se guarda nada y se reintenta después de recargar.
    El momento exacto lo confirma el dueño al dar el OK para aplicar.
- [ ] **Step 4: Aplicar.** Con el OK:
  1. elegir el número con la trampa 3: el ledger, `origin/main` y las ramas abiertas;
  2. renombrar `NNN`;
  3. aplicar con `apply_migration`;
  4. mergear el PR enseguida, que el push a `main` despliega;
  5. tocar `migrations/MANIFEST.md` sólo si la migración lo requiere.
- [ ] **Step 5: Después de aplicar:**
  - `SELECT auditoria_grants_tablas()`, `SELECT auditoria_permisos_execute()` y
    `SELECT * FROM auditoria_definer_sin_rol()`: nada nuevo en rojo;
  - con la anon key, `POST /rest/v1/rpc/confirmar_rendicion` con los parámetros nuevos da
    `42501`: resolvió y hay una sola sobrecarga. Con `p_gastos` da `PGRST202`;
  - `auditoria_integridad()`: `GASTO-A` en 0.
- [ ] **Step 6: PR** a `main`, con el título "Gastos 2/5: rendición". El cuerpo enlaza el spec y
  este plan, y dice que es la entrega 2 de 5 y que #1269 y #1270 siguen abiertos. Sin `Closes`.
