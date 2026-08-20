# Plan de Auditoría de Integridad de Datos — ManaosApp

> Objetivo: poder **presentar y explicar cada número con confianza**, garantizar la integridad de **todos** los datos, y que el **origen** de cada cifra sea trazable y reproducible. No es un one‑shot: define un **proceso repetible**.
>
> Estado: baseline verificado en vivo contra prod (`hmuchlzmuqqxcldbzkgc`) el 2026‑06‑29. Cada invariante se corrió contra los datos reales.

---

## 1. Resumen ejecutivo (estado actual)

La integridad **de fondo está sana**. Los fixes de junio (migs 098‑104 + el de bonificación de subunidad) cerraron los agujeros que rompían los números. El relevamiento por dominio encontró **0 corrupciones que afecten las cifras presentables**; lo que queda son (a) un puñado de artefactos legacy aislados, (b) gaps de **trazabilidad** (no de valor), y (c) la ausencia de un **gate automático** que evite que esto vuelva a divergir.

| Dominio | Integridad | Hallazgo principal |
|---|---|---|
| Ventas / pedidos | ✅ Sólida | `total = Σ(subtotal)` en 2787/2787 entregados. Riesgo de raíz: el total lo calcula el **cliente**, no el server. |
| Costos / margen | ✅ Sólida | Snapshot de costo congelado **funcionando** (8/8 pedidos de las últimas 2 h). 0 productos bajo costo. 1 sin costo (M00011). |
| Bonificaciones / promos | ✅ Sólida | 0 bonif con precio (el fix de subunidad **sostiene**). Acumuladores en rango. |
| Mermas | ✅ Sólida | KPI excluye promo y usa huso AR (verificado contra cálculo manual). Riesgo: valuadas a costo **vivo**, no congelado. |
| Stock / ledger | ✅ Sólida | `productos.stock == última fila del ledger` 100%. 0 negativos. Riesgo: 44% de movimientos sin trazabilidad (`origen='auto'`). |
| Cuenta corriente / pagos | ✅ Sólida | `saldo_cuenta = Σ(total − pagado)` reconcilia 712/714 clientes. 0 pagos a cancelados. |
| Compras | ✅ Buena | ZZ con IVA 0 ✓. Riesgo: costo editable a mano sin audit trail; overload legacy de 11 args. |
| Cambios / comisiones | ⚠️ Riesgo de proceso | La pantalla de Comisiones usa **otra fórmula** que el reporte (no filtra canal/sucursal): hoy coinciden por casualidad. |
| **Proceso (repo = prod)** | ⚠️ **El más importante** | Las 6 funciones críticas **coinciden** repo↔prod (los fixes sí se commitearon). PERO no hay gate que lo garantice a futuro. |

**La causa de la "vergüenza" no es que los números estén mal hoy — es que no había forma de *demostrar* que estuvieran bien.** Este plan instala esa demostración.

---

## 2. Diccionario de números (cómo defender cada cifra)

Para una presentación, cada número debe tener una frase de origen. Esta es la fuente única de verdad:

| Número | Fuente / fórmula | Cómo explicarlo en 1 frase |
|---|---|---|
| **Venta** | `Σ pedidos.total` WHERE `estado='entregado' AND canal='app'`, por sucursal y fecha | "Lo efectivamente entregado por la app; cada total cuadra al centavo con sus renglones (2787/2787)." |
| **CMV / costo** | `Σ cantidad × COALESCE(costo_unitario_al_crear, costo_vivo×(1+imp.int.))` items no‑bonif | "Costo **congelado al momento de la venta** (no el actual), por eso el margen de un mes cerrado no cambia si reprecio un producto." |
| **Margen comercial / neto** | `venta − CMV` ; neto `− bonificaciones` | "Margen sin contar regalos; el neto descuenta el costo de las bonificaciones." |
| **Bonificaciones** | `Σ costo_bonif` (fracción ÷ `unidades_por_bloque`) | "Costo real de lo regalado; las fracciones se valorizan por botella, no por fardo." |
| **Mermas (KPI)** | `Σ cantidad × costo` WHERE `motivo NOT IN (promociones, promociones_reversion)`, fecha AR | "Pérdida real por rotura/vencimiento; **no** incluye los movimientos contables de promos." |
| **Cuenta corriente (saldo)** | `clientes.saldo_cuenta = Σ(total − monto_pagado)` de pedidos no cancelados | "Lo que cada cliente debe = sus compras menos sus pagos; reconcilia en 712/714." |
| **Comisión** | `Σ pedidos.total` no‑cancelados por `usuario_id` × 2% | "2% sobre la venta cargada (no la entregada) de cada vendedor." ⚠️ Ver gap §4. |
| **Vendedor de la venta** | `pedidos.usuario_id` (acreditado) ; `creado_por` = quién la cargó | "La venta se acredita al vendedor elegido; `creado_por` registra quién la tipeó." |

---

## 3. La batería de invariantes (el corazón del proceso repetible)

Cada invariante es una afirmación que **siempre** debe cumplirse, escrita como un SQL que devuelve el **conteo de violaciones (0 = OK)**. Se empaquetan en un RPC `auditoria_integridad()` (ver §5) que corre todas y devuelve un tablero PASS/FAIL. Resultado actual entre paréntesis.

### Ventas
- **VENTA‑A** (crítica, PASS=0): `total = Σ(subtotal)` por pedido no cancelado. *Única red contra el total calculado client‑side.*
- **VENTA‑B/F/G** (PASS): sin `subtotal<0`, sin `total<0`, sin `cantidad<=0`.
- **VENTA‑C/D** (PASS): `estado` y `canal` dentro del dominio permitido.
- **VENTA‑H** (PASS): `pedido_items.sucursal_id = pedidos.sucursal_id`.
- **VENTA‑I** (FAIL=4, low): cancelado con `total<>0` → 4 legacy de abril (ids 629,663,682,707). *Reconciliar.*
- **VENTA‑J** (FAIL=1, low): entregado sin items → id 652. *Reconciliar.*
- **VENTA‑M** (PASS): coherencia `estado_pago` ↔ `monto_pagado`.

### Costos / margen
- **COSTO‑A** (alta, PASS): pedidos nuevos (post‑deploy) con líneas no‑bonif y `costo_unitario_al_crear` NULL → 0 (el snapshot puebla; verificado 8/8 últimas 2 h).
- **COSTO‑B** (media, FAIL=1): productos con ventas y `costo_sin_iva` NULL/0 → 1 (M00011). *Cargar costo.*
- **COSTO‑C** (media, PASS=0): productos con `precio < costo_real`. *Atrapa venta bajo costo.*

### Bonificaciones / promos
- **BONIF‑A** (alta, PASS=0): `es_bonificacion=true` con `subtotal<>0` o `precio_unitario<>0`. *Protege el fix de subunidad.*
- **BONIF‑B** (PASS=0): item con `subtotal=0` y `es_bonificacion=false` (venta gratis sin marcar).
- **BONIF‑C** (media, ajustar): `promo_ajustes` de **consumo** sin `merma_id` → los 6 actuales son sustitución/pedido‑eliminado (legítimos); acotar el check a `observaciones` de consumo.
- **BONIF‑D** (PASS=0): `promociones.usos_pendientes < 0` o stock de contenedor negativo.

### Mermas
- **MERMA‑A/C/E/H** (PASS): motivo válido; producto existe; negativos solo en `promociones_reversion`; sin stock negativo.
- **MERMA‑B** (alta, PASS=0): asiento `stock_nuevo = GREATEST(stock_anterior − cantidad, 0)`.
- **MERMA‑D** (crítica, PASS=0): el KPI del reporte coincide con el cálculo manual (excluye promo, huso AR).
- **MERMA‑I** (media, FAIL=56): mermas reales sin `usuario_id` (gap de trazabilidad).

### Stock / ledger
- **STK‑A** (crítica, PASS=0): `productos.stock = última fila de stock_historico`.
- **STK‑B/E/F** (PASS/WARN): sin stock negativo (1 evento histórico ya prevenido por mig 104); sucursal coherente.
- **STK‑D** (alta, FAIL=7729): movimientos `origen='auto'` sin referencia (44%). *Trazabilidad — ver §4.*

### Cuenta corriente / pagos
- **CC‑A** (crítica, FAIL=2/714): `saldo_cuenta = Σ(total − monto_pagado)` no cancelados. *Reconciliar los 2.*
- **CC‑pagos‑cancel** (alta, PASS=0): pagos imputados a pedidos cancelados.
- **CC‑B** (informativa, 69): `monto_pagado = Σ(pagos del pedido)` — diferencias esperadas por efectivo al entregar (sin fila en `pagos`); usar con criterio.

### Compras
- **COMPRA‑A1** (PASS=0): `total = subtotal + iva + otros`.
- **COMPRA‑A2** (media, FAIL=5): `subtotal = Σ(items.subtotal)` → 5 compras legacy con carga incompleta (ids 5,6,19,39,40). *Reconciliar + validar en el RPC.*
- **COMPRA‑B** (PASS=0): ZZ con `iva<>0`.
- **COMPRA‑C/E/F/G/H** (PASS): costo>0; bonif en [0,100); snapshot stock coherente; sucursal coherente; cantidad>0.
- **COMPRA‑D** (media, WARN=19): costo del producto ≠ última compra → ediciones manuales legítimas, pero **sin audit trail** (§4).

### Cambios / comisiones
- **CAMBIO‑01/02/03** (PASS): cambio con `total=0`; excluido del reporte; 1:1 con `recorrido_cambios`.
- **COMIS‑01/02** (media, FAIL=2): ventas entregadas sin `usuario_id` (ids 904, 872, $75.400). *Asignar vendedor.*
- **COMIS‑04** (alta, FAIL de código): la pantalla de Comisiones no filtra `canal`/`sucursal` como el RPC (§4).
- **COMIS‑05** (alta, ✅ resuelto): `creado_por` poblado en pedidos nuevos → verificado 8/8 últimas 2 h.

### Proceso (repo = prod)
- **META‑03** (crítica, PASS=0): cuerpo en vivo de las 6 funciones críticas == su archivo de migración.
- **META‑01** (crítica, PASS=0): toda función viva tiene origen en el repo (excepto las de extensión).
- **META‑02/04** (WARN): overloads legacy duplicados; sin gate de CI para las ~140 funciones no‑críticas (§4).

---

## 4. Backlog priorizado (gaps a cerrar)

**P0 — coherencia de proceso del origen (lo que evita la "vergüenza")**
1. **Gate CI repo=prod**: job que crea una branch efímera de Supabase, aplica `000_baseline + 001..N`, y diffea `pg_get_functiondef` de **todas** las funciones contra prod (md5 por firma); falla si hay >0 divergencias. Cierra el agujero de raíz (edits in‑place sin commit). *(META‑03/04)*
2. **Política escrita + enforcement**: prohibido `apply_migration`/edit in‑place sin archivo `migrations/NNN` commiteado. Regenerar `000_baseline` trimestralmente y commitear el diff como evidencia de no‑drift.
3. **Adoptar tabla de migraciones aplicadas** (hash del archivo) para demostrar que prod = `baseline + 001..N`.

**P1 — fuentes duplicadas / trazabilidad de números**
4. **Unificar Comisiones**: que la pantalla consuma la sección `vendedores` del RPC `reporte_gerencial` (fuente única), o agregarle los filtros `canal='app'` + `sucursal_id`. Hoy divergirá cuando entre el primer cambio. *(COMIS‑04)*
5. **Audit trail del costo**: log de cambios de `costo_sin_iva` (producto, valor anterior/nuevo, usuario, motivo, fecha) en cada edición manual; sin esto el margen no es 100% defendible. *(COMPRA‑D)*
6. **Trazabilidad del ledger de stock**: mover mermas/ajustes manuales a RPC que seteen `app.stock_origen` + `referencia`; eliminar el `.update({stock})` directo de `useMermas.ts`. *(STK‑D)*

**P2 — robustez estructural (que la integridad no dependa del camino)**
7. **Total server‑side**: recalcular/validar `pedidos.total` dentro de `crear_pedido_completo` o trigger CHECK `total = Σ(subtotal)`. *(VENTA‑A como red)*
8. **Snapshot de costo en mermas** (`mermas_stock.costo_unitario_al_crear`) para que el KPI de un mes cerrado sea reproducible. *(MERMA riesgo)*
9. **CHECK constraints** que respalden las invariantes que hoy solo garantiza el RPC (costo>0, cantidad>0, sucursal coherente, etc.).
10. **DROP de overloads legacy** (`registrar_compra_completa` 11‑arg, `registrar_salvedad` 7‑arg) tras verificar callers. *(META‑02)*
11. `usuario_id` NOT NULL al pasar a `entregado/app`; `usuario_id` de merma NOT NULL para motivos reales.

**P3 — reconciliaciones puntuales (datos legacy, $0 de impacto en KPIs)**
12. 4 cancelados con total≠0, 1 entregado sin items (652), 2 saldos a reconciliar (CC‑A), 5 compras con subtotal≠items, 2 ventas sin vendedor (904, 872).

---

## 5. Proceso repetible — 3 capas

### Capa 1 · RPC `auditoria_integridad()` (corre la batería)
Una función `SECURITY DEFINER` que ejecuta **todas** las invariantes de §3 y devuelve un JSONB:
```sql
-- Esqueleto (cada check devuelve conteo de violaciones; 0 = OK)
CREATE OR REPLACE FUNCTION public.auditoria_integridad()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT jsonb_build_object(
    'generado_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('id','VENTA-A','sev','critical','viol',
        (SELECT count(*) FROM (SELECT p.id FROM pedidos p LEFT JOIN pedido_items pi ON pi.pedido_id=p.id
           WHERE p.estado NOT IN ('cancelado','anulado') GROUP BY p.id,p.total HAVING abs(p.total-coalesce(sum(pi.subtotal),0))>0.01) x)),
      jsonb_build_object('id','STK-A','sev','critical','viol',
        (SELECT count(*) FROM productos p JOIN (SELECT DISTINCT ON (producto_id,sucursal_id) producto_id,sucursal_id,stock_nuevo
           FROM stock_historico ORDER BY producto_id,sucursal_id,created_at DESC,id DESC) u
           ON u.producto_id=p.id AND u.sucursal_id=p.sucursal_id WHERE p.stock<>u.stock_nuevo)),
      jsonb_build_object('id','CC-A','sev','critical','viol',
        (SELECT count(*) FROM clientes c WHERE abs(coalesce(c.saldo_cuenta,0) -
           coalesce((SELECT sum(p.total-coalesce(p.monto_pagado,0)) FROM pedidos p
             WHERE p.cliente_id=c.id AND p.estado NOT IN ('cancelado','anulado')),0))>0.01))
      -- ... el resto de los checks de §3 ...
    )
  );
$$;
REVOKE EXECUTE ON FUNCTION public.auditoria_integridad() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.auditoria_integridad() TO authenticated, service_role;
```
- **Corrida programada**: un cron diario (pg_cron o el cron de Claude Code) llama al RPC; si algún check `critical/high` > 0, manda alerta (Telegram/digest).
- **Panel**: una sección en `/reportes-gerenciales` que muestra el tablero verde/rojo en vivo.

### Capa 2 · Checklist pre‑presentación (humano, 2 min)
Antes de presentar números, correr `auditoria_integridad()` y confirmar:
- [ ] Checks `critical` y `high` en verde (0 violaciones).
- [ ] El período presentado sale del **RPC `reporte_gerencial`** (no de la pantalla de Comisiones ni del bot suelto).
- [ ] Si se cita comisión, viene de la sección `vendedores` del RPC.
- [ ] Las cifras de cuenta corriente/mermas/stock se explican con el **diccionario §2**.

### Capa 3 · Gate de proceso en CI (repo = prod)
El job de §4‑P0: en cada PR que toque `migrations/` y nightly, validar que `baseline + migs` reproduce **exactamente** las funciones de prod. Es la garantía estructural de que el código que produce los números es trazable.

---

## 6. Impacto estimado

| Antes | Después |
|---|---|
| "No puedo garantizar ni explicar los números." | Tablero objetivo (verde/rojo) + diccionario de origen por número. |
| Integridad verificada a mano, una vez. | `auditoria_integridad()` corre la batería en segundos, a demanda y programada. |
| Drift repo↔prod invisible hasta la próxima auditoría manual. | Gate de CI lo detecta en cada PR; imposible que reaparezca silencioso. |
| Comisión y reporte pueden divergir sin aviso. | Fuente única; el check COMIS‑04 alerta divergencia. |
| Cambios de costo/stock sin rastro. | Audit trail de costo + trazabilidad de movimientos de stock. |

---

## 7. Plan de implementación (orden sugerido)
1. **Capa 1 — RPC `auditoria_integridad()`** con los ~40 checks de §3 (1 migración). Da valor inmediato y es la base de todo. *(bajo riesgo, additive)*
2. **Capa 2 — checklist** (este doc) + **panel** en `/reportes-gerenciales`.
3. **P0 — gate CI repo=prod** + política escrita. *(cierra la causa raíz)*
4. **P1** — unificar Comisiones, audit trail de costo, trazabilidad de stock.
5. **P2/P3** — robustez estructural y reconciliaciones legacy.

> Cada capa es desplegable de forma independiente. La Capa 1 + el gate de CI (P0) son lo que convierte "creo que los números están bien" en "puedo demostrarlo".
