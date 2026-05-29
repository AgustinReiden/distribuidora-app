# Auditoría integral 2026-05 — Distribuidora App

**Fecha:** 2026-05-28 · **Alcance:** código (React 19 + TS + PWA) + DB en vivo (Supabase `hmuchlzmuqqxcldbzkgc`) + Edge Functions/bot · **Roles cubiertos:** admin, preventista, preventista_taco, transportista, encargado, deposito.
**Método:** advisors de Supabase + introspección read-only de la DB de producción + suite de reconciliación de datos + auditoría de código por dominio. Las migraciones del repo NO reflejan el estado real (archivadas/renumeradas); la fuente de verdad fue la DB en vivo.

---

## 1. Resumen ejecutivo

La app está **más sana de lo que sugería la documentación previa**: los fixes críticos de febrero/abril (eliminación de `run_sql`, RLS en todas las tablas, fix de doble conteo de saldos, índices) **están aplicados en producción**. Saldos, totales de pedidos y stock están **íntegros** (0 divergencias en la reconciliación).

El riesgo real hoy se concentra en **permisos a nivel base de datos**, no en los datos:

- **P0 confirmado:** cualquier usuario autenticado puede **auto-ascenderse a `admin`** vía un `UPDATE` directo a `perfiles` (la RLS lo permite). Explotable con una request REST, sin pasar por la UI.
- **P0 confirmado:** **todas** las funciones `SECURITY DEFINER` (que bypassan RLS) son ejecutables por `anon` (sin login) y `authenticated`. Las RPCs del bot (`bot_ventas_periodo`, `bot_metricas_admin_dia`, `bot_historico_pagos_cliente`…) permiten leer ventas/pagos/PII de **cualquier sucursal** pasando un `sucursal_id` arbitrario.
- **P1:** el ledger de pagos no reconcilia contra pedidos (52 clientes / $2,6M) por pagos sobre pedidos cancelados no revertidos + dos mecanismos paralelos de `monto_pagado`. Los saldos igual cierran, pero la trazabilidad pago→pedido es poco confiable (relevante para AFIP/auditoría).
- **P1:** la sincronización offline puede **duplicar pedidos** (sin idempotencia), con doble descuento de stock.

Buenas noticias adicionales: el **bot de Telegram está muy bien construido** (webhook fail-closed, secret en tiempo constante, autorización por rol/sucursal consistente, escritura con confirmación humana e idempotente, sin inyección de prompt explotable). El único agujero del bot es que sus RPCs son llamables también desde la web (P0-2, ya cubierto por la migración 069).

**Migración [`069_audit_2026_05_hardening.sql`](../migrations/069_audit_2026_05_hardening.sql) preparada** con los fixes P0/P1 seguros y reversibles. **Pendiente de tu OK para aplicar** (ver §6).

---

## 2. Lo que está SANO (verificado en vivo) — no re-trabajar

| Verificación | Resultado |
|---|---|
| `run_sql`/`exec_sql`/`execute_sql` (inyección SQL) | **No existen** ✅ |
| Tablas `public` sin RLS | **0** (cobertura RLS completa) ✅ |
| `clientes.saldo_cuenta` vs `Σ(total − monto_pagado)` | **0 divergencias / $0 drift** (664 clientes) ✅ |
| `pedidos.total` vs `Σ(pedido_items.subtotal)` | **0 divergencias** ✅ |
| `pedidos.total` vs `total_neto + total_iva` | **0 divergencias** ✅ |
| `productos.stock` vs último `stock_historico` | **0 divergencias** · 0 stock negativo ✅ |
| `current_sucursal_id()` valida pertenencia del header `X-Sucursal-ID` | **Sí** — header forjado → NULL → 0 filas ✅ |
| RLS de escritura en productos/clientes/pedidos | Gateadas por `es_admin()`/`es_preventista()` + `sucursal_id` ✅ |
| Bot Telegram (webhook, secrets, authz, prompt-injection) | Sólido ✅ |

---

## 3. Hallazgos priorizados

> Severidad: **P0** crítico (arreglar ya) · **P1** alto · **P2** medio · **P3** bajo / nice-to-have / state-of-the-art.
> Estado: **069** = corregido en la migración preparada · **pendiente** = requiere código/decisión.

### P0 — Crítico

**P0-1 · Escalada de privilegios en `perfiles`** · `migrations/000_baseline.sql` (policy `perfiles_update_self`)
La policy `UPDATE` de `perfiles` para `public` usa `with_check (id = auth.uid())` **sin restringir columnas**. Cualquier usuario autenticado puede `PATCH /rest/v1/perfiles?id=eq.<su_id>` con `{"rol":"admin"}` y volverse admin. La UI solo expone esto a admins (`/usuarios` con `isAdmin`), pero el ataque es por API directa.
**Impacto:** toma de control total (cualquier rol → admin).
**Fix (069):** trigger `BEFORE UPDATE` que rechaza cambios de `rol`/`activo` salvo `es_admin()`.

**P0-2 · RPCs `SECURITY DEFINER` ejecutables por anon/authenticated** · 105 funciones; grants `PUBLIC` por defecto
Todas las funciones `SECURITY DEFINER` (bypassan RLS) tienen `EXECUTE` para `anon` y `authenticated` (proacl nulo = PUBLIC; los `DROP/CREATE` de migraciones resetearon los grants). Las más graves no tienen gate interno:
- **Bot/lectura sensible** (toman `sucursal_id`/`perfil_id` por parámetro, sin auth): `bot_ventas_periodo`, `bot_metricas_admin_dia`, `bot_ventas_por_preventista`, `bot_historico_pagos_cliente`, `bot_historico_pedidos_cliente`, `bot_mis_ventas`, `bot_buscar_cliente`, `obtener_resumen_cuenta_cliente_bot`, etc. → **un `preventista_taco` (o un anónimo) lee ventas/pagos/PII de cualquier sucursal**.
- **Escritura** sin auth: `crear_pedido_completo_bot`, `actualizar_orden_entrega_batch`, `limpiar_orden_entrega`, `aplicar_uso_promo_acumulador`, `revertir_bloques_auto_ajuste`.
**Impacto:** fuga de datos cross-sucursal + escalada + escritura no autorizada, incluso sin login.
**Fix (069):** RPCs del bot → solo `service_role`; funciones trigger → sin EXECUTE directo; RPCs mutadoras sin gate → se cierra `anon` (queda `authenticated`; falta gate de rol/sucursal → P1-3).

### P1 — Alto

**P1-1 · Trazabilidad pago→pedido + 2 pagos sobre pedidos cancelados** · `registrar_pago_cliente_fifo` + trigger `recalcular_monto_pagado_pedido`
**Los saldos de clientes son correctos**: `saldo_cuenta` vs `Σ(total − monto_pagado)` reconcilia con **0 divergencias**. La diferencia por cliente entre `Σ(pagos.monto)` y `Σ(pedidos.monto_pagado)` (52 clientes) es un **artefacto de atribución del FIFO** (reparte `monto_pagado` entre varios pedidos sin una fila de pago por pedido) — **NO es plata perdida**. Corrige el encuadre alarmista del "$2,6M".
Lo que sí requiere acción concreta (~7 casos):
- **2 pagos sobre pedidos cancelados ($68.200)**: pago **1599** (cliente 688, $61.200, 2026-05-20) y pago **275** (cliente 10, $7.000, 2026-04-13). Al cancelar, `monto_pagado→0` y el pago quedó sin destino (no acreditado al saldo del cliente).
- **5 pedidos sobrepagados** (`monto_pagado > total`): ej. pedido 1142 (total $20.800 / pagado $46.360).
**Estado: requiere tu decisión** para esos casos (reembolsar / acreditar a cuenta / reasignar a otros pedidos). Mejora opcional de trazabilidad: guardar `pago_id`↔`pedido_id` por aplicación FIFO.

**Resuelto (2026-05-28):** se descartaron los 2 pagos sobre pedidos cancelados (pago **1599** y **275**) y se cerró correctamente el pedido **733** (`total=0`, `monto_pagado=0`). Reconciliación global de saldos post-fix: **0 divergencias / $0 drift** (cliente 10 = $8.900, cliente 688 = $0, sin alterar saldos correctos).

**Decisión sobre los 5 sobrepagados (2026-05-28):** regla del negocio → **no modificar saldos con fecha ≥ 07/04/2026**. Los 5 sobrepagados (pedidos 1142, 1148, 1656, 1821, 2083) son **todos del 22/04/2026 o posterior** ⇒ **protegidos, no se tocan**. Se dejan como **crédito legítimo del cliente** (sobrepago reflejado en saldo negativo); los libros ya reconcilian (0 drift). No hay anomalías de saldo pre-07/04. **P1-1 cerrado.**

**Hallazgo nuevo (ligado a P1-6) — trigger de saldo por deltas:** `actualizar_saldo_pedido` mantiene `clientes.saldo_cuenta` por **deltas y NO excluye cancelados**. Si un pedido se cancela sin zerolear (como estaba el 733) o se zerolea más tarde, el saldo puede driftear (lo vi en vivo: zerolear el 733 sumó +$500 de más, corregido al instante). **Recomendado:** que la cancelación SIEMPRE zerolee `total`/`monto_pagado`, y/o que el trigger ignore estados `cancelado`/`anulado`. ⚠️ **Foot-gun para futuros fixes de datos: cualquier UPDATE a `pedidos` recalcula saldo por delta sin excluir cancelados.**

**Resuelto (2026-05-28, migración 072):** `actualizar_saldo_pedido` ahora trata `cancelado`/`anulado` como contribución 0. Fix **forward-only**: `CREATE OR REPLACE` no re-disparó sobre filas existentes → checksums de saldos/stock/ítems **idénticos** al baseline, reconciliación 0 drift. El foot-gun queda cerrado para futuras cancelaciones sin tocar nada histórico.

**P1-2 · Duplicación de pedidos en sync offline** · `src/hooks/useOfflineSync.ts:574`, `src/hooks/supabase/usePedidos.ts:321`, RPC `crear_pedido_completo`
No hay idempotencia end-to-end: si el `INSERT` se ejecuta pero la respuesta se pierde (corte de red post-commit), la op vuelve a `pending` y se **reinserta** → pedido duplicado + doble descuento de stock. La RPC del bot (`crear_pedido_completo_bot`) sí es idempotente; la web no replicó el patrón.
**Fix (pendiente):** `offline_id` UUID por pedido + columna `UNIQUE` + `INSERT ... ON CONFLICT (offline_id) DO NOTHING RETURNING id`. Igual para `CREATE_MERMA`.

**P1-3 · RPCs mutadoras sin gate de rol/sucursal (authenticated)** · `actualizar_orden_entrega_batch`, `limpiar_orden_entrega`, `aplicar_uso_promo_acumulador`, `revertir_bloques_auto_ajuste`
Hacen `UPDATE` ciego (ej. `UPDATE pedidos SET orden_entrega WHERE id=...`) sin verificar rol ni sucursal. 069 cierra `anon`, pero un `authenticated` cualquiera todavía puede invocarlas para pedidos/promos de **otra sucursal**.
**Fix (pendiente):** agregar al cuerpo `IF NOT es_encargado_o_admin() THEN RAISE...` + filtrar/validar `sucursal_id = current_sucursal_id()`.

**P1-4 · `obtener_resumen_compras` sin filtro de sucursal** · función homónima
Agrega compras de **todas las sucursales** (`FROM compras WHERE estado!='cancelada'`, sin `sucursal_id`). Fuga + dato incorrecto si la UI espera la sucursal activa.
**Fix (pendiente):** filtrar por `current_sucursal_id()` (o parámetro validado).

**P1-5 · `preventista_taco` ve montos que no debería** · `src/components/pedidos/PedidoStats.tsx:53`, `PedidoCard.tsx:443-577`, `src/components/vistas/VistaPedidos.tsx:200`
`PedidoStats` mapea taco a la rama `'admin'` (nunca recibe `isPreventistaTaco`) y `PedidoCard` muestra `total`/`monto_pagado`/precios **sin chequear rol**. Además `fetchClientes` (`useClientesQuery.ts:34`) trae `saldo_cuenta` y `obtenerResumenCuenta`/`fetchPagosCliente` se llaman **también para taco** → los datos viajan al browser aunque la UI los oculte.
**Fix (pendiente):** pasar `isPreventistaTaco` y gatear render; y a nivel DB, no devolver columnas sensibles a taco (vista/column-level o RPC que filtre por rol).

**P1-6 · `pedidos` editable por el preventista fuera de la ventana 15:30** · policy `mt_pedidos_update`
La RLS permite a `usuario_id = auth.uid()` actualizar su pedido sin límite temporal; la regla "mismo día < 15:30" vive solo en UI/RPC (`permisosPedido.ts`). Por API directa un preventista puede editar `total`/`estado` de su pedido en cualquier momento. Relacionado: las RLS usan el **rol global** (`es_admin()` lee `perfiles.rol`), así que el **rol por-sucursal** (`usuario_sucursales.rol`) no se aplica en escrituras.
**Fix (pendiente):** mover la regla temporal a la policy/trigger; decidir si el rol efectivo debe ser por-sucursal.

**P1-7 · Protección de contraseñas filtradas deshabilitada** · Auth settings
`auth_leaked_password_protection` off. **Fix:** activar en Dashboard → Authentication → Policies (1 click; no es SQL).

### P2 — Medio

| ID | Hallazgo | Ubicación | Nota |
|---|---|---|---|
| P2-1 | **`auth_rls_initplan`** x38: las policies re-evalúan `auth.uid()`/`current_sucursal_id()` por fila | 23+ tablas | Envolver en `(SELECT auth.uid())`. Gran mejora de performance a escala, bajo riesgo |
| P2-2 | **Múltiples policies permisivas** por acción (se evalúan todas) | `perfiles` (4 SELECT, 3 UPDATE), `usuario_sucursales` (2 SELECT), +otras | Consolidar |
| P2-3 | **IVA/neto sin redondear** → acumulación de centavos en `total_neto`/`total_iva` (fiscal) | `src/utils/calculations.ts:53,74,105` | `redondear(_,2)` por ítem. Hoy bajo impacto (totales reconcilian), pero riesgo en FC/AFIP |
| P2-4 | Offline: **logout no limpia cola/cache** → cross-usuario en el mismo dispositivo | `src/App.tsx:190`, `offlineDb.ts:216` | Llamar `clearAllData()`/`invalidateAllCache()` o filtrar por `userId` |
| P2-5 | Conflicto de stock offline: la venta se descarta como `failed` sin flujo de resolución | `useOfflineSync.ts:466-499` | Estado propio de conflicto + UI de resolución |
| P2-6 | `telegram-digest` compara el bearer con `!==` (no tiempo constante) | `supabase/functions/telegram-digest/index.ts:48` | Usar `timingSafeEqual` (consistencia) |
| P2-7 | `historico_pagos_cliente` no pre-valida sucursal del cliente antes del RPC | `_shared/tools/admin/historico_pagos_cliente.ts:56` | Confirmar que `bot_historico_pagos_cliente` filtra por `p_sucursal_id` |
| P2-8 | Descuento de cliente: el total mostrado ≠ guardado, y `ModalEditarPedido` lo pierde al editar | `usePromocionPedido`, `usePedidoHandlers.ts:434`, `ModalEditarPedido.tsx:420` | **Latente: 0/664 clientes usan `descuento_porcentaje`.** Arreglar antes de habilitar la feature |
| P2-9 | Calidad de datos | DB | 91 pedidos sin desglose fiscal; 5 sobrepagados; 5 clientes con saldo negativo; 2 productos sin histórico de stock |

### P3 — Bajo / nice-to-have / state-of-the-art

| ID | Tema | Detalle |
|---|---|---|
| P3-1 | **Cobertura de tests de plata = 0** | Sin tests de `calcularNetoVenta`/IVA, `useCalculosImpuestos`, ni del flujo guardar-pedido (descuento+promo+mayorista). Umbrales `vite.config.js`: 50/40/45/50. Subir a ~95% en `calculations.ts`/`precioMayorista.ts` |
| P3-2 | **Componentes gigantes** | `ModalCompra.tsx` (1799), `PedidosContainer.tsx` (1485), `ModalEditarPedido.tsx` (1008), `ModalPedido.tsx` (933), `AppModals.tsx` (643). Extraer hooks/subcomponentes |
| P3-3 | **Deuda de tipos** | `as any` 42 (26 en `AppModals.tsx`), `as unknown as` 47, `any` 21, `eslint-disable` 45 (10 `exhaustive-deps` = riesgo de stale closures en hooks de plata) |
| P3-4 | **3 fuentes de verdad de rol** | `perfil.rol` (global, menú), `effectiveRol` (por-sucursal, rutas), `permisos.ts`. Menú (rol global) vs rutas (rol sucursal) pueden divergir. Unificar |
| P3-5 | **Índices sin uso** x58 + duplicados x6 | Duplicados → 069. Revisar/eliminar los no usados (costo de escritura) |
| P3-6 | **Crecimiento sin tope** | `bot_audit_log`, `bot_conversaciones`, `audit_logs` → retención con `pg_cron` + `CHECK jsonb_array_length` |
| P3-7 | **Helpers de rol duplicados** | `is_admin`/`is_preventista`/`is_transportista` (SQL) coexisten con `es_admin`/… Limpiar |
| P3-8 | **Observabilidad** | Sentry OK; falta structured logging y enviar Web Vitals → Sentry |
| P3-9 | **Sync: dos sistemas sobre la misma cola** | `useOfflineQueue` (código muerto, procesadores rotos) coexiste con `useOfflineSync`. Eliminar uno |
| P3-10 | **`perfiles_select_all` USING(true)** | Todo usuario lee todos los perfiles (nombres/roles/sucursal). Aceptable para app interna; documentado. La escalada real era por UPDATE (P0-1), no por SELECT |
| P3-11 | **Bot multi-sucursal** | El bot usa `bot_usuarios.sucursal_id` (snapshot); un admin con 2 sucursales (Agustín, jareiden) recibe datos filtrados a 1 sin aviso. Comando `/sucursal` o parámetro opcional |
| P3-12 | **`baseService` cache sin scope de sucursal** | Latente (TTL=0 hoy). Si se activa, fuga cross-sucursal. Incluir `sucursalId` en la key |

---

## 4. Matriz por rol (verificada)

**Rutas** (guard en `src/App.tsx` por `effectiveRol`). **Escritura DB** gateada por helpers RLS: `es_admin()`=admin · `es_encargado_o_admin()`=admin+encargado · `es_preventista()`=admin+preventista+preventista_taco+encargado · `es_transportista()`=admin+transportista.

| Capacidad | admin | preventista | preventista_taco | transportista | encargado | deposito |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Crear cliente/pedido (`es_preventista`) | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| Ver montos/ventas/saldos | ✅ | ✅ | **❌ (pero hoy SÍ los ve — P1-5)** | ✅ | ✅ | ✅ |
| Editar productos/precios | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ stock (rol `deposito` en RLS productos) |
| Editar items de pedido | ✅ | ✅ propio < 15:30 (UI; **DB sin límite — P1-6**) | ✅ propio | ❌ | ✅ | ❌ |
| Cancelar/eliminar pedido | ✅ | ❌ | ❌ | ❌ | cancelar sí / eliminar ❌ | ❌ |
| Registrar pago | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ |
| Compras / rendiciones / recorridos | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ |
| Reportes/usuarios/proveedores/promos/transferencias | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Auto-ascenderse a admin (API directa)** | — | **SÍ (P0-1)** | **SÍ** | **SÍ** | **SÍ** | **SÍ** |
| **Leer ventas/pagos de otra sucursal vía RPC bot** | sí | **SÍ (P0-2)** | **SÍ** | **SÍ** | **SÍ** | **SÍ** |

Negativos a verificar tras los fixes: taco no ve montos (P1-5); ningún rol se auto-asciende (P0-1/069); ninguna RPC del bot responde a `authenticated` (P0-2/069); preventista no edita pedido ajeno ni de otra sucursal (RLS OK) ni el propio fuera de hora (P1-6).

---

## 5. Estado de fixes

| Hallazgo | Acción | Estado |
|---|---|---|
| P0-1, P0-2, P2 search_path, P3-5 dup índices | Migración **069** | ✅ Aplicada y verificada |
| P1-3 (gate rol/sucursal orden entrega), P1-4 (sucursal en resumen_compras) | Migración **070** | ✅ Aplicada y verificada |
| P1-2 (idempotencia offline) | Migración **071** (`crear_pedido_idempotente`) + frontend | ✅ Aplicada; typecheck + 40 tests + lint OK. Recomendado smoke test offline real |
| P1-5 (taco ve montos) | Frontend (PedidoCard/PedidoStats/VistaPedidos/PedidosContainer) | ✅ Aplicada; typecheck/lint OK |
| P1-1 (reconciliación pagos) | Saneo pagos de cancelados + regla "no tocar saldos ≥ 07/04" | ✅ Cerrado: 2 pagos de cancelados descartados, pedido 733 cerrado, 5 sobrepagados (todos ≥ 22/04) dejados como crédito. 0 drift global |
| P1-6 (trigger de saldo no excluía cancelados) | Migración **072** (forward-only) | ✅ Aplicada — checksums saldo/stock/ítems **intactos**, 0 drift. Ventana 15:30 ya estaba en `actualizar_pedido_items`. Rol por-sucursal en writes: pendiente (decisión de diseño, toca toda la RLS) |
| P1-7 (leaked password) | Toggle en Dashboard | ⏳ Manual (1 click) |
| P2/P3 | Backlog priorizado | Pendiente |

---

## 6. Migración 069 — qué hace y cómo aplicar/revertir

Archivo: [`migrations/069_audit_2026_05_hardening.sql`](../migrations/069_audit_2026_05_hardening.sql). **Reversible, no toca datos.**
1. Trigger anti auto-escalada en `perfiles` (P0-1).
2. RPCs del bot → solo `service_role` (P0-2). *La app web no las llama (verificado en el inventario de `.rpc()`); el bot usa `service_role`.*
3. Funciones trigger → sin EXECUTE directo (siguen disparándose).
4. Cierra `anon` en RPCs mutadoras sin gate (queda `authenticated`).
5. `search_path` fijo en 4 funciones.
6. Elimina 6 índices duplicados.

**Aplicar** (SQL Editor de Supabase o `supabase db push`), o pedímelo y la aplico vía MCP.
**Verificar después:** re-correr advisors (deben bajar los lints de search_path); confirmar que las RPCs del bot ya no son `authenticated`; smoke test de login y de cada rol; que un admin todavía puede cambiar roles en `/usuarios`.
**Rollback:** re-`GRANT EXECUTE ... TO authenticated`, `DROP TRIGGER trg_prevenir_autoescalada_perfil`, recrear índices.

---

## 7. Verificación end-to-end (cuando se apliquen los fixes)
- **DB:** `get_advisors` security+performance; queries read-only: ninguna RPC del bot con `authenticated`; reconciliaciones de §2 siguen en 0.
- **Código:** `npm run typecheck`, `npm run lint`, `npm run test:run`, `npm run build`; e2e por rol.
- **Funcional por rol:** loguear cada rol y verificar los negativos de §4 (taco sin montos; nadie se auto-asciende; no cross-sucursal).
- **No regresión:** crear/editar/cancelar pedido, registrar pago, compra, sync offline.

## 8. Checklist reutilizable (trimestral)
1. `get_advisors` (security + performance) → revisar nuevos lints.
2. Grants: 0 funciones `SECURITY DEFINER` con `EXECUTE` para `anon`; bot solo `service_role`.
3. Reconciliación §2 (saldos, totales, stock, pagos) → 0 divergencias.
4. Policies nuevas sin `USING(true)` salvo justificación; sin múltiples permisivas redundantes.
5. Cobertura de `calculations.ts`/`precioMayorista.ts` ≥ 95%.
6. Tamaño de `bot_audit_log`/`audit_logs`/`bot_conversaciones` (retención).
7. Funciones nuevas con `SET search_path`.

---

## Anexo — 2da tanda de avances (2026-05-28)

**Aplicado/cerrado adicional:**
- **P2-6 (telegram-digest tiempo constante):** corregido en fuente (`supabase/functions/telegram-digest/index.ts` ahora usa `timingSafeEqual`). Severidad muy baja (clave de alta entropía); sale con el próximo deploy del pipeline de edge functions (no forcé un redeploy por MCP para no arriesgar la función).
- **P3-6 (crecimiento sin tope) — parcial:** migración **073** agrega trigger `trg_cap_bot_conversaciones` que auto-recorta `mensajes` a los últimos 50 turnos (backstop; el backend ya mantiene ~12). Forward-only, no tocó datos. Retención de `bot_audit_log`/`audit_logs` NO se hizo: **pg_cron no está instalado** y las tablas son chicas (406 / 38.508 filas) → no urgente; revisar cuando crezcan.
- **P2-7 (`obtener_resumen_cuenta_cliente_bot` sin filtro de sucursal):** verificado que el **único caller** (`_shared/tools/common/ficha_cliente.ts`) ya pre-valida la sucursal del cliente (`.eq("sucursal_id", ctx.sucursal_id)`) + guardrail de admin + chequeo de asignación del preventista. El RPC sin filtro interno es **defensa-en-profundidad, no un hueco activo** → no requiere cambio.

**NO auto-aplicado (con motivo) — requieren tu decisión / branch con test / deploy:**
- **P2-1 (auth_rls_initplan, perf):** reescribir ~38 políticas RLS (envolver `auth.uid()` en `(select auth.uid())`). Semánticamente idéntico, pero reescribir tantas políticas en prod sin test funcional por rol es riesgoso y lo despriorizaste. Recomendado: hacerlo en una Supabase branch con verificación.
- **P2-3 (redondeo IVA) / P2-8 (descuento cliente):** tocan la matemática de plata (frontend). Latentes (0/664 clientes usan descuento; totales reconcilian). Cambiar reglas de redondeo necesita tu spec para no introducir diferencias de centavos.
- **P2-4 (logout no limpia cola offline) / P2-5 (conflicto de stock):** tocan el core de sync (riesgo de pérdida de datos / decisión de UX).
- **P1-6 parte 3 (rol por-sucursal en escrituras):** cambia `es_admin()`/`es_preventista()` → afecta TODA la RLS; decisión de diseño.
- **P3-1/2/3 (tests de plata, componentes gigantes, deuda de tipos):** proyectos de refactor (días/semanas), no fixes puntuales.
- **P1-7 (leaked password):** toggle manual en el Dashboard (sin API).

**Migraciones de la auditoría aplicadas en prod:** 069, 070, 071, 072, 073 (+ saneo de datos de pagos cancelados). Advisors de seguridad: 221 → 158 lints.
