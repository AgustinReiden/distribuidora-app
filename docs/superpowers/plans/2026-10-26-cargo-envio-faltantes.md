# Cargo de envío: lo que falta — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Completar el cargo de envío de main (mig 389) con lo acordado: edición que recalcula o
pregunta, venta sin envío en reportes y métricas de envío, IVA del envío en FC, renglón en los PDFs,
bot con el modo y el cargo, y los huecos de cobro/idempotencia/entrega.

**Architecture:** Se construye sobre `pedidos.cargo_envio` y `politicas_comerciales.modo_minimo_pedido`
(mig 389). Se agrega `pedidos.cargo_envio_estado`. Las reglas puras viven en SQL y en
`src/utils/montoMinimo.ts` con un gate de paridad nuevo. Cada camino que reescribe `total_neto`/
`total_iva` suma el desglose del cargo efectivo. Los reportes de venta usan `GREATEST(total - cargo_envio, 0)`.

**Tech Stack:** React 19 + Vite + TanStack Query + Dexie + vitest; Supabase Postgres (plpgsql,
`migrations/`); edge functions Deno.

**Spec:** `docs/superpowers/specs/2026-10-26-cargo-envio-faltantes-design.md`. Leé también la cabecera
de `migrations/389_cargo_de_envio_bajo_el_minimo.sql`: es el modelo sobre el que se construye.

## Global Constraints

- `CLAUDE.md` de la raíz rige todo: trampa 3 (número de migración al aplicar), 5 (al cambiar una
  firma, dropear la vieja; params nunca `SMALLINT`), 6 (todo `UPDATE` que cambie `total` o
  `cargo_envio` nombra `total` y `monto_pagado`), 8, y la regla de permisos de funciones.
- `npm ci` hecho. Antes de cerrar una tarea con front: `npm run typecheck`, `npm run lint`,
  `npm run test:run`, `npm run build`. Con Deno: `deno task check|lint|test` en `supabase/functions/`.
  El pre-commit corre la suite entera; nunca `--no-verify`.
- Migraciones: `migrations/NNN_cargo_<k>_<tema>.sql` (NNN literal; el controlador la renombra al
  aplicar). **Nadie aplica**: el controlador aplica con el OK del dueño. Los implementadores sólo
  corren en prod (proyecto `hmuchlzmuqqxcldbzkgc`, `execute_sql`) SELECTs de lectura, el ensayo solo,
  y ensayos `BEGIN; SET LOCAL lock_timeout='5s'; <migraciones 1..k de este plan>; <ensayo k>; ROLLBACK;`.
- Ensayos: molde `scripts/test-venta-j-1098.sql` (`DO $ensayo$`, canarios con `RAISE … ERRCODE
  'P0099'`, cierre `ENSAYO OK`/`ENSAYO FALLÓ`). Antes de la migración, el ensayo solo da `FALLÓ`.
  Cada check de integridad nuevo o cambiado lleva un canario que demuestra que **muerde**.
- Parches por ancla sobre la definición **viva** en prod (`pg_get_functiondef` + reemplazo exacto una
  vez, molde `pg_temp.rr_parchar` de la 373 o `_mig389_parchear` de la 389).
- **Compatibilidad**: toda migración tiene que funcionar con el front que está en producción (se aplica
  antes del deploy). Agregar claves a un JSON de respuesta, sí; cambiar firmas sin default, no.
- Funciones SQL nuevas de server: `REVOKE ALL … FROM PUBLIC, anon, authenticated`; las del espejo
  además `GRANT EXECUTE … TO service_role`. RPCs del front: `REVOKE … FROM PUBLIC, anon` + `GRANT …
  TO authenticated`, `SECURITY DEFINER SET search_path = public`.
- Valores fijos: IVA del envío en FC **21 %** (neto `round(c/1.21, 2)`, IVA `c − neto`); ZZ todo neto;
  VB nada. Umbrales con `>=`. Estados `'no_aplica' | 'cobrado' | 'gratis' | 'bonificado'`. Decisión
  `'cobrar' | 'no_cobrar'`. Código de rechazo `'requiere_decision_envio'`. Venta de productos =
  `GREATEST(total - cargo_envio, 0)`. Cargo efectivo = `total - GREATEST(total - cargo_envio, 0)`.
- Copy (es-AR, `formatCurrency`/`formatPrecio`): diálogo `El pedido quedó en $X. ¿Agregar envío de $Y?`
  / `El pedido quedó en $X. ¿Sacar el envío de $Y?`; renglón de PDF `Envío`.
- Ninguna sucursal cambia de `bloquear` hasta que este PR esté aplicado y desplegado.
- Modelo por tarea: migraciones que cambian funciones de prod con **Opus**; front con **Sonnet**.

## Review Focus

1. **Pedido FC con cargo y salvedad parcial**: después de la salvedad, `total_neto + total_iva` sigue
   incluyendo el desglose del cargo (los caminos rehacen neto/IVA desde las líneas). Ensayo de Tarea 2.
2. **Edición sin cruce de franja después de que cambió el costo**: conserva el cargo viejo. Espejo y
   ensayo de Tareas 1 y 3.
3. **Rechazo total y anulación**: el cargo efectivo vuelve a 0 y vuelve a aparecer; las métricas no lo
   cuentan mientras es 0. Ensayos de Tareas 2 y 8.
4. **Reintento idempotente de un pedido con cargo**: se reconoce como propio. Test de Tarea 4.
5. **Sucursal en `bloquear`**: ni edición, ni PDF, ni export, ni reporte muestran "Envío". Tests de
   Tareas 3, 5, 7 y 8.

---

### Task 1: Reglas puras en TS + fixture de paridad

Modelo: Sonnet, esfuerzo high.

**Files:** Modify `src/utils/montoMinimo.ts`, `src/utils/montoMinimo.test.ts`. Create
`src/utils/cargoEnvio.espejo.json`, `src/utils/cargoEnvio.espejo.test.ts`.

**Interfaces (Produces, en `montoMinimo.ts`):**
- `cargoEnvioPedido(total, regla)`: además devuelve 0 si `total <= 0` (spec §9).
- `type CargoEnvioEstado = 'no_aplica' | 'cobrado' | 'gratis' | 'bonificado'`; `type DecisionEnvio = 'cobrar' | 'no_cobrar'`.
- `politicaCobraCargo(regla): boolean` — `(modo === 'cargo' || modo === 'escalas') && cargoEnvio > 0 && umbralEnvioGratis(regla) > 0`.
- `umbralEnvioGratis(regla): number` — `montoMinimo` en `cargo`, `montoEnvioGratis` en `escalas`, 0 en `bloquear`.
- `franjaCargo(total, regla): 'debajo' | 'arriba'` — `debajo` ⇔ `0 < total < umbralEnvioGratis(regla)`.
- `cargoTrasEdicion(a: { estado: CargoEnvioEstado; cargoActual: number; totalViejo: number; totalNuevo: number; regla: ReglaMinimoPedido; esPreventista: boolean; decision: DecisionEnvio | null }): { cargo: number; estado: CargoEnvioEstado; requiereDecision: boolean }` — reglas del spec §1 y "Adaptación": `no_aplica` o `!politicaCobraCargo` ⇒ sin cambios; sin cruce de franja ⇒ sin cambios; cruce + preventista ⇒ `debajo` → `cobrado` con `regla.cargoEnvio`, `arriba` → `gratis`/0 (su decisión se ignora); cruce + admin/encargado sin decisión ⇒ actual + `requiereDecision: true`; `cobrar` ⇒ `cobrado` con `regla.cargoEnvio`; `no_cobrar` ⇒ `bonificado` si `debajo`, `gratis` si `arriba`.
- `cargoDesglose(cargo: number, tipoFactura: string | null | undefined): { neto: number; iva: number }`.
- `ventaDePedido(p: { total: number; cargo_envio?: number | null }): number` = `max(total - (cargo_envio ?? 0), 0)`.

- [ ] **Step 1: Tests** en `montoMinimo.test.ts` con `R = { modo: 'escalas', montoMinimo: 5000, montoEnvioGratis: 15000, cargoEnvio: 500 }` y `C = { modo: 'cargo', montoMinimo: 15000, montoEnvioGratis: 0, cargoEnvio: 500 }`:
  `cargoEnvioPedido(0, C) === 0`; `franjaCargo(14999.99, R) === 'debajo'`, `franjaCargo(15000, R) === 'arriba'`, `franjaCargo(0, C) === 'arriba'`;
  `cargoDesglose(500, 'FC')` → `{ neto: 413.22, iva: 86.78 }`, ZZ → `{500, 0}`, VB → `{0, 0}`;
  `cargoTrasEdicion` sin cruce con `cargoEnvio` subido a 700 conserva 500; con regla `bloquear` no cambia nada ni pide decisión; admin que cruza sin decidir → `requiereDecision: true`; `no_cobrar` debajo → `bonificado`; preventista con `no_cobrar` → `cobrado` 500; `no_aplica` nunca gana; `ventaDePedido({ total: 12500, cargo_envio: 500 }) === 12000`, `({ total: 0, cargo_envio: 500 }) === 0`.
- [ ] **Step 2: Ver que fallan.** `npx vitest run src/utils/montoMinimo.test.ts`.
- [ ] **Step 3: Implementar.** El encabezado del bloque nuevo dice que es espejo de las funciones SQL `cargo_*` de `NNN_cargo_1_base` (gate `cargoEnvio.espejo.json`).
- [ ] **Step 4: Fixture** `cargoEnvio.espejo.json` con claves `cargo_envio_pedido`, `desglose`, `tras_edicion` (forma de `combos.espejo.json`, entradas snake_case, esperados derivados a mano), cubriendo cada rama de arriba más: exacto del umbral, `escalas` bajo el mínimo (0 en el alta), FC 1000 y 333,33, admin `cobrar` hacia `arriba`, preventista `cobrar`, `bonificado` sin cruce. Test `cargoEnvio.espejo.test.ts` que lo recorre (molde `combos.espejo.test.ts`).
- [ ] **Step 5: Correr; typecheck; lint; commit** `feat(cargo-envio): reglas puras de edición, desglose y venta sin cargo`.

---

### Task 2: Migración 1 — estado del cargo, R4, puras SQL y desglose fiscal

Modelo: Opus, esfuerzo high.

**Files:** Create `migrations/NNN_cargo_1_base.sql`, `scripts/test-cargo-1.sql`, `scripts/espejo-cargo-envio.mjs`. Modify `.github/workflows/integridad.yml` (step junto al de combos), `src/test/rpcsSoloServidor.test.ts` si lista funciones de server.

**Interfaces (Produces):**
- `pedidos.cargo_envio_estado text NOT NULL DEFAULT 'no_aplica'`, CHECK de valores, CHECK `pedidos_cargo_estado_coherente`: `estado IN ('cancelado','anulado') OR ((cargo_envio_estado = 'cobrado') = (cargo_envio > 0))`. Backfill: `cargo_envio > 0` ⇒ `'cobrado'` (hoy 0 filas).
- `pedido_cargo_envio(numeric, bigint)` (misma firma): devuelve 0 si `COALESCE(p_total,0) <= 0` (antes del resto, después del GUC forzado).
- Puras (IMMUTABLE, espejo de Tarea 1): `cargo_envio_desglose(p_cargo numeric, p_tipo_factura text, OUT neto numeric, OUT iva numeric)`; `cargo_tras_edicion(p_estado text, p_cargo_actual numeric, p_total_viejo numeric, p_total_nuevo numeric, p_modo text, p_monto_minimo numeric, p_monto_envio_gratis numeric, p_cargo_vigente numeric, p_es_preventista boolean, p_decision text, OUT cargo numeric, OUT estado text, OUT requiere_decision boolean)`; `cargo_envio_pedido_puro(p_total numeric, p_modo text, p_monto_minimo numeric, p_monto_envio_gratis numeric, p_cargo numeric) RETURNS numeric` (la regla de alta sin leer la tabla; `pedido_cargo_envio` pasa a llamarla).
- `crear_pedido_completo` y `crear_pedido_completo_bot`: fijan `cargo_envio_estado` (`no_aplica` si VB, canje o la política no cobra; `cobrado` si cargo > 0; si no `gratis`) y suman `cargo_envio_desglose(cargo, tipo)` al `total_neto`/`total_iva` del cierre. `crear_pedido_completo` agrega `'total'` (con cargo) a su respuesta; `crear_pedido_idempotente`, en la rama idempotente, devuelve `total` y `cargo_envio` del existente.
- `registrar_salvedad`, `anular_salvedad`, `cambiar_tipo_factura_pedido` (ZZ↔FC): al rehacer `total_neto`/`total_iva` suman el desglose del **cargo efectivo** (0 si `SUM(subtotal) = 0`). `actualizar_pedido_items` se toca en la Tarea 3.
- Ninguna firma cambia.

- [ ] **Step 1: Ensayo `scripts/test-cargo-1.sql`** (política forzada en un subbloque: modo `escalas` 5000/15000/500):
  alta de 12000 → `cargo_envio 500`, `estado 'cobrado'`, respuesta con `total 12500`; alta de 16000 → `gratis`; alta con política `bloquear` → `no_aplica`; alta VB → `no_aplica`, 0; alta de puro regalo en modo `cargo` 15000/500 → cargo 0 y VENTA-A en 0;
  alta FC de 12000 → `total_neto + total_iva = total` (±0,01) e IVA incluye 86,78;
  salvedad parcial sobre ese FC → neto + IVA = total; rechazo total → total 0, neto/IVA sin el cargo; anularla → vuelve el cargo y su desglose;
  ZZ→FC→ZZ sobre un pedido con cargo → neto/IVA cierran en cada paso;
  `crear_pedido_idempotente` reintentado → devuelve `total` y `cargo_envio`;
  CHECK `pedidos_cargo_estado_coherente`: `cobrado` con cargo 0 falla;
  las puras dan los esperados de 6 casos del fixture; permisos: `anon` y `authenticated` sin EXECUTE en las puras, `service_role` sí.
- [ ] **Step 2: Ensayo solo en prod → `ENSAYO FALLÓ`.**
- [ ] **Step 3: Migración** (parches por ancla sobre lo vivo; bloque `$verif$` de permisos sin llamar a `auditoria_integridad()`; `SET LOCAL lock_timeout = '5s'` arriba).
- [ ] **Step 4: Ensayar** `BEGIN; …mig 1…; …ensayo 1…; ROLLBACK;` → `ENSAYO OK`; dentro de la misma transacción `auditoria_integridad()->'critical_high_en_rojo'` igual que antes.
- [ ] **Step 5: `scripts/espejo-cargo-envio.mjs`** (molde `espejo-combos.mjs`, con `--sql`, exit 2 si no puede mirar —también ante un `fetch` que tira—, exit 1 si difiere) + step `Paridad del cargo de envío (TS vs SQL)` en `integridad.yml`. Correr su `--sql` dentro de un ensayo con la mig 1 → todas `ok = true`.
- [ ] **Step 6: Commit** `feat(cargo-envio): estado del cargo, desglose fiscal y regla sin productos (mig NNN)`.

---

### Task 3: Edición — migración 2 + front

Modelo: Opus, esfuerzo high.

**Files:** Create `migrations/NNN_cargo_2_edicion.sql`, `scripts/test-cargo-2.sql`, `src/components/modals/ModalEditarPedido.cargo.test.tsx`. Modify `src/utils/rechazoDeNegocio.ts` (+ test), `src/components/containers/PedidosContainer.tsx` (`handleGuardarItemsEdicion`, prop `onSaveItems`), `src/components/modals/ModalEditarPedido.tsx`.

**Interfaces:**
- Consumes: `cargo_tras_edicion`, `cargo_envio_desglose` (Tarea 2); `cargoTrasEdicion`, `reglaMinimoDe`, `franjaCargo` (Tarea 1).
- Produces: `actualizar_pedido_items(p_pedido_id bigint, p_items_nuevos jsonb, p_usuario_id uuid, p_decision_envio text DEFAULT NULL)`; **`DROP FUNCTION public.actualizar_pedido_items(bigint, jsonb, uuid)`** en la misma migración y mismos grants vivos. Total viejo de productos = `GREATEST(total - cargo_envio, 0)` (ya lo calcula la 389). Rol: `perfiles.rol` en (`admin`,`encargado`) ⇒ no preventista. Si `requiere_decision`: `{success:false, errores:[…], codigo:'requiere_decision_envio', cargo, franja}` **antes** de tocar líneas o stock. El `UPDATE` final: `total = v_total_nuevo + (v_total_nuevo > 0 ? cargo_nuevo : 0)`, `cargo_envio`, `cargo_envio_estado`, neto/IVA + desglose del cargo efectivo, `monto_pagado = monto_pagado`.
- Front: `CODIGO_REQUIERE_DECISION_ENVIO`, `esRechazoDeEnvio(err)`, `RechazoDeNegocioError(msg, codigo, detalle?)`; `onSaveItems?: (items, origenes?, decisionEnvio?: DecisionEnvio) => Promise<void>`; `ModalEditarPedido` recibe `esPreventista`. El diálogo se renderiza **dentro** del modal Radix. Antes de la migración (`cargo_envio_estado` ausente) se comporta como `no_aplica`.

- [ ] **Step 1: Ensayo** (rol con `SET LOCAL ROLE authenticated` + claims; pedido creado en el bloque con `escalas` 5000/15000/500): preventista 16000→12000 → `cobrado`, total 12500; 12000→16000 → `gratis`; 12000→13000 con cargo vigente 700 → conserva 500; admin cruza sin decisión → código y **líneas y stock sin cambios**; admin `no_cobrar` → `bonificado`, luego preventista sin cruce → sigue `bonificado`; encargado = admin; preventista con `no_cobrar` → ignorado; política `bloquear` → nada cambia; `no_aplica` nunca gana; FC: neto + IVA = total tras cada edición; firma de 3 args no existe; VENTA-A en 0.
- [ ] **Step 2: Ensayo solo → FALLÓ; migración; ensayo acumulado (mig 1 + 2) → OK.**
- [ ] **Step 3: Tests del front:** desglose Productos/Envío/Total antes y después de editar; admin que cruza ve el diálogo dentro del modal y su respuesta viaja; preventista no ve diálogo; el rechazo `requiere_decision_envio` abre el diálogo y reintenta; sucursal en `bloquear`: ni diálogo ni "Envío"; `esRechazoDeEnvio` reconoce el código y conserva el detalle.
- [ ] **Step 4: Implementar; las cuatro verificaciones; commit(s)** `feat(cargo-envio): la edición recalcula o pregunta por el cargo (mig NNN)`.

---

### Task 4: Front — cobro del alta, idempotencia y entrega con salvedad

Modelo: Sonnet, esfuerzo high.

**Files:** Modify `src/components/containers/PedidosContainer.tsx` (~1641 `montoDelAlta`), `src/hooks/queries/usePedidosQuery.ts` (`leerPedidoExistente`, `esNuestro` ~472, `CrearPedidoResult`), `src/hooks/useOfflineSync.ts` (`verificarRespuestaIdempotente`), `src/components/modals/ModalEntregaConSalvedad.tsx` (~221), `src/types/hooks.ts` (`cargo_envio_estado?`). Tests junto a cada uno.

**Interfaces:** `CrearPedidoResult` suma `cargoEnvio?: number | null`; `leerPedidoExistente` devuelve `{ clienteId, total, cargoEnvio }` (select `'cliente_id, total, cargo_envio'`).

- [ ] **Step 1: Tests:** `alta pagada registra el pago por productos + cargo devuelto por el server` (mock `{ id: '9', cargoEnvio: 500 }`, carrito 12000 → `registrarPago` con 12500); `si el cargo del server difiere del mostrado avisa` (`notify.warning`, y para 0 el texto `El pedido no lleva envío`); `la respuesta idempotente de un pedido con cargo es nuestra` (existente `{total: 12500, cargoEnvio: 500}`, input 12000) y `otro pedido con total igual a input + 500 sin cargo no es nuestro`; `useOfflineSync`: `un reintento offline de un pedido con cargo no queda fallido`; `ModalEntregaConSalvedad`: `el total efectivo a cobrar suma el cargo` y `si se rechaza todo no lo suma`.
- [ ] **Step 2: Ver que fallan; implementar** (`montoDelAlta` = `totalConDescuento + (pedidoCreado?.cargoEnvio ?? 0)` para `pagado`; parcial con `Math.min` al total del server; comparaciones con `total - (cargoEnvio ?? 0)`; la suma de la entrega redondeada a centavos antes de decidir "sin productos").
- [ ] **Step 3: Las cuatro verificaciones; commit** `fix(cargo-envio): el cobro del alta, el reintento y la entrega cuentan el cargo`.

---

### Task 5: Comanda, recibo A4 y hoja de ruta

Modelo: Sonnet, esfuerzo medium.

**Files:** Modify `src/lib/pdf/reciboPedido.ts` (A4 antes de `// === TOTAL ===`; comanda antes de `TOTAL:`), `src/lib/pdf/hojaRutaOptimizada.ts` (op antes de `Total pedido:`). Tests en `src/lib/pdf/__tests__/`.

**Interfaces:** cargo efectivo = `pedido.total - ventaDePedido(pedido)` (Tarea 1); renglón `Envío` + `formatPrecio` sólo si > 0.

- [ ] **Step 1: Tests:** con cargo, A4 y comanda muestran `Envío` antes de `TOTAL:`; sin cargo (o con rechazo total) no aparece la palabra `Envío` en los tres renders; hoja de ruta con cargo suma el op.
- [ ] **Step 2: Ver que fallan; implementar; `npx vitest run src/lib/pdf`; verificaciones; commit** `feat(cargo-envio): el envío en la comanda, el recibo y la hoja de ruta`.

---

### Task 6: Bot — migración 3 + edge functions

Modelo: Opus, esfuerzo high.

**Files:** Create `migrations/NNN_cargo_3_bot.sql`, `scripts/test-cargo-3.sql`, `supabase/functions/_shared/pricing/cargoEnvio.ts` (copia de `motivoRechazoMinimo` y `cargoEnvioPedido` con R4) y `supabase/functions/tests/cargoEnvio.test.ts` (recorre `src/utils/cargoEnvio.espejo.json`, clave `cargo_envio_pedido`). Modify `supabase/functions/_shared/tools/preventista/previsualizar_pedido.ts` (~384), `crear_pedido.ts`, `supabase/functions/_shared/gemini/prompts/preventista.ts` (~L55 y ejemplo ~L64), `supabase/functions/tests/previsualizar_pedido.test.ts`.

**Interfaces:**
- `bot_pedidos_pendientes.cargo_mostrado numeric(12,2) NOT NULL DEFAULT 0` (grants: igual que la tabla).
- `crear_pedido_completo_bot` (firma igual): si `pedido_cargo_envio(...)` difiere de `v_pendiente.cargo_mostrado` (±0,01) devuelve `{success:false, error:'El costo de envío cambió desde la vista previa. Pedí la vista previa de nuevo.'}` sin consumir el pendiente.
- `previsualizar_pedido`: lee `monto_minimo_pedido, modo_minimo_pedido, monto_envio_gratis, cargo_envio_pedido`; rechaza sólo si `motivoRechazoMinimo` da motivo; guarda `cargo_mostrado`; el retorno suma `cargo_envio` y `total_a_pagar` sólo si el cargo > 0. `crear_pedido.ts` devuelve `{ pedido_id, total, cargo_envio }` del server.
- Compatibilidad: con `cargo_mostrado` default 0 y todas las sucursales en `bloquear`, el bot desplegado sigue andando.

- [ ] **Step 1: Ensayo:** pendiente con `cargo_mostrado 500` y política vigente 500 → crea con cargo; política cambiada a 700 → error y el pendiente sigue sin consumir; política `bloquear` y 0 → `no_aplica`.
- [ ] **Step 2: Ensayo solo → FALLÓ; migración; ensayo acumulado (mig 1..3) → OK.**
- [ ] **Step 3: Tests Deno:** en modo `cargo` bajo el mínimo no rechaza y el pendiente guarda `cargo_mostrado`; en `escalas` bajo el mínimo rechaza; en `bloquear` no aparece `cargo_envio`; `cargoEnvio.test.ts` pasa contra el JSON.
- [ ] **Step 4: Implementar; `deno task check|lint|test`; commit** `feat(cargo-envio): el bot respeta el modo y muestra el cargo (mig NNN)`.

---

### Task 7: Reportes SQL — venta sin cargo (migración 4)

Modelo: Opus, esfuerzo high.

**Files:** Create `migrations/NNN_cargo_4_reportes.sql`, `scripts/test-cargo-4.sql`. Modify `CLAUDE.md` (sección "Venta por vendedor": sexta parte `monto = GREATEST(total - cargo_envio, 0)`; una línea nueva: el cargo vive en `pedidos.cargo_envio` dentro de `total`, sus caminos y su desglose fiscal, migs 389 y NNN).

**Interfaces:** cada función que suma `pedidos.total` como venta, ticket o base de comisión pasa a `GREATEST(p.total - p.cargo_envio, 0)`; las de `total_neto`/`total_iva` como venta (`venta_neta` del gerencial) restan el desglose del cargo efectivo; `posicion_fiscal` **no** se toca (el IVA del envío se declara). No se tocan cobranza, deuda, saldo, recorridos, rendiciones ni `jornadas_transportista*`. Lista inicial: `reporte_gerencial` (`kpis.venta`, `venta_neta`, `ticket`, `mensual`, `serie_diaria`, `top_clientes`, márgenes, `base_comision`, `vendedores[].base_nc`, semáforos de metas), `reporte_ventas_por_cliente`, `reporte_ventas_por_preventista` (sólo `totalVentas`), `obtener_estadisticas_pedidos`, `bot_mis_ventas`, `bot_ventas_periodo`, `bot_digest_preventista`, `bot_metricas_admin_dia` (venta y ticket), `clientes_ritmo_compra`, `bot_sugerir_visitas_rfm`, `reporte_alerta_detalle` (venta 90 días), `jornadas_preventista`, `jornada_preventista_detalle`.

- [ ] **Step 1: Confirmar la lista en prod** (`pg_get_functiondef ~ 'canal <> ''cambio''' AND ~* '\mtotal\M'`); cada función al header: se migra o por qué no.
- [ ] **Step 2: Ensayo** en dos partes: (a) foto de la salida de cada función migrada (90 días, todas las sucursales) antes y después dentro de la transacción → iguales; (b) en un subbloque, a un pedido entregado real se le suma `cargo_envio 500` y `total += 500`: la venta de cada función migrada **no cambia** y saldo/cobranza **sí** suben 500.
- [ ] **Step 3: Ensayo solo → la parte (b) FALLA; migración; ensayo acumulado → OK.**
- [ ] **Step 4: `CLAUDE.md`; commit** `feat(cargo-envio): la venta de los reportes es de productos (mig NNN)`.

---

### Task 8: Front — sumas de venta, impacto y export de pedidos

Modelo: Sonnet, esfuerzo medium.

**Files:** Modify `src/utils/metricasDashboard.ts`, `src/hooks/queries/useMetricasQuery.ts` (selects suman `cargo_envio`), `src/hooks/queries/usePedidoStatsQuery.ts`, `src/utils/ventaCliente.ts`, `src/services/analyticsExport.ts` (`fetchClientesDimension`), el impacto de `/configuracion` en `usePoliticasComercialesQuery.ts` (lee `total` de 90 días), el export Excel de `PedidosContainer.tsx`, `supabase/functions/_shared/tools/common/ficha_cliente.ts`. Tests de cada util.

**Interfaces:** todas las sumas de venta usan `ventaDePedido` (Tarea 1). El Excel suma la columna `Envío` sólo si algún pedido exportado tiene cargo efectivo > 0.

- [ ] **Step 1: Tests:** en cada util `un pedido con cargo cuenta sólo sus productos como venta` (12500/500 → 12000); impacto: un pedido con cargo cuenta por sus productos; export: sin cargo no hay columna `Envío`, con uno aparece y el total no cambia.
- [ ] **Step 2: Ver que fallan; implementar; verificaciones + `deno task test`; commit** `feat(cargo-envio): las sumas de venta del front excluyen el cargo`.

---

### Task 9: Métricas de envío en el reporte gerencial (migración 5 + vista)

Modelo: Opus, esfuerzo high.

**Files:** Create `migrations/NNN_cargo_5_gerencial.sql`, `scripts/test-cargo-5.sql`. Modify `src/components/vistas/VistaReportesGerenciales.tsx`, `src/utils/exportGerencial.ts`, el tipo de respuesta de `reporte_gerencial`. Test `VistaReportesGerenciales.envios.test.tsx` (o el existente) y `exportGerencial.test.ts`.

**Interfaces:** `reporte_gerencial` suma `envios = { recaudado, cobrados, gratis, bonificados, pct_cobrado, venta_productos, venta_total }` sobre los pedidos que cuentan como venta con productos (`GREATEST(total - cargo_envio, 0) > 0`); `recaudado` = suma del cargo efectivo; `cobrados` = `cargo_envio_estado = 'cobrado'` con cargo efectivo > 0; `pct_cobrado = cobrados / NULLIF(cobrados + gratis + bonificados, 0)`; `venta_total = venta_productos + recaudado`. Sin pedidos `cobrado|gratis|bonificado` en el período ⇒ `envios = null`. La vista muestra el bloque "Envíos" sólo si no es `null`; el export suma la sección.

- [ ] **Step 1: Ensayo:** dos `cobrado` de 500, uno `gratis`, uno `bonificado`, uno `cobrado` con rechazo total → `recaudado 1000`, `cobrados 2`, `gratis 1`, `bonificados 1`, `pct_cobrado 0.5`; sin pedidos con cargo → `null`; `kpis.venta` no cambia.
- [ ] **Step 2: Ensayo solo → FALLÓ; migración (parche sobre la versión de la Tarea 7); ensayo acumulado (mig 1..5) → OK.**
- [ ] **Step 3: Tests de vista y export:** con `envios` muestra los siete números; con `null` no aparece la palabra `Envío`.
- [ ] **Step 4: Implementar; verificaciones; commit** `feat(cargo-envio): métricas de envío en el reporte gerencial (mig NNN)`.

---

## Cierre

- [ ] Revisión final de la rama; el controlador pide al dueño el OK para aplicar las migraciones 1..5 en
  orden, las aplica, corre cada ensayo solo (`ENSAYO OK`) y el `--sql` del espejo; abre el PR.
