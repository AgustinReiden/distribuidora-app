# Gastos, entrega 6: faltantes de rendición — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Al resolver una disconformidad, el admin imputa la plata que faltó, en una o varias
líneas con su monto y su causal. «A cargo del empleado» es una deuda en su cuenta. «Robo o pérdida»
y «gasto que no se cargó» son gastos de la rendición. Lo imputado baja el efectivo a entregar, y se
deshace de una vez con «Deshacer resolución».

**Architecture:**
- **Las líneas viven en una tabla propia**, `rendicion_faltantes`, atada a la **clave** de la
  rendición (transportista, fecha, sucursal) y no al `id` de `rendiciones_control`: ese control se
  borra cuando cambia la fecha de entrega de un pedido del día. Cada línea apunta a lo que creó: un
  movimiento o un gasto. Deshacer anula la línea y no la borra.
- **La deuda es un movimiento `faltante`** de `empleado_movimientos`, negativo, con las columnas
  `rendicion_*`, como el pago al personal de la entrega 4. La liquidación lo descuenta sola. Su
  compensación es otro `faltante`, positivo, con `revierte_id`.
- **Los gastos de la resolución son gastos comunes de la rendición**, escritos por `_guardar_gasto`
  como los del cierre. Un trigger sobre `gastos` impide cambiar o anular uno con una línea viva, sea
  por el camino que sea. Por eso deshacer anula primero la línea y después el gasto.
- **El efectivo a entregar** resta, además, los faltantes a cargo de empleados.
  `obtener_resumen_rendiciones` suma la columna `total_faltantes_empleados`, y
  `total_pagos_personal` pasa a contar sólo `tipo = 'pago'`. `confirmar_rendicion` compara también
  lo que vio el modal de faltantes (`faltantes_visto`), como hace con los pagos al personal.
- **`resolver_rendicion` cambia de firma y pasa a ser sólo de admin.** Recibe `p_resolucion jsonb
  DEFAULT NULL`, así que el bundle viejo sigue resolviendo sólo con el texto. Al encargado le llega
  un mensaje claro.

**Tech Stack:** React 19 + Vite + TanStack Query + Zod + vitest/testing-library; Supabase Postgres
(plpgsql, `migrations/`).

**Spec:** `docs/superpowers/specs/2026-11-03-faltantes-de-rendicion-design.md`, aprobado por el
dueño el 2026-11-03. Es parte del módulo de `docs/superpowers/specs/2026-10-28-gastos-y-cuentas-del-personal-design.md`
(§3 y §4.3) y del issue #1332. El molde es `docs/superpowers/plans/2026-11-02-gastos-4-liquidaciones.md`.

**Base de la rama:** `main` en `0811835e`, con las migraciones hasta la 439 en prod.

**Ejecución:** dos subsesiones, cada una en su worktree, cortadas de esta rama con el plan
commiteado:
- `gastos-6-sql` hace la Tarea 2 con Opus, esfuerzo high. Su nombre de turno es `gastos-6-sql`.
- `gastos-6-front` hace las Tareas 1 y 3 a 6 con Sonnet, esfuerzo high. Su nombre de turno es
  `gastos-6-front`.

La coordinadora (la sesión que escribió este plan) junta las ramas sólo con el OK del dueño, y
después hace la Tarea 7.

## Lo que hay hoy (relevado en prod el 2026-11-03, sólo lectura)

**md5 de las funciones que se tocan:** `md5(prosrc)` crudo. Las de la 437 y la 430 tienen CRLF.

| Función | md5 en prod | CRLF | Última migración |
|---|---|---|---|
| `resolver_rendicion(date,uuid,text)` | `a30b741cf968581a460a8a4d109dd00f` | no | 423 |
| `confirmar_rendicion(date,uuid,text,jsonb,text)` | `077a9f784e5ac2e704f355c805b1b286` | sí | 437 |
| `obtener_resumen_rendiciones(date,date,uuid)` | `97d90bcd2d841417d715603fbd31c4ef` | sí | 437 |
| `revertir_movimiento_empleado(bigint,text)` | `10b93a53646eb5e1d6d43a5863c0374b` | sí | 437 |

Se re-consultan antes de escribir la guarda.

**Lo demás:**
- **Las disconformidades**: hay 3 en la historia, todas de Taco Pozo. Dos siguen abiertas, y
  ninguna de las tres personas tiene ficha de empleado.
- **`empleado_movimientos`**:
  - `empleado_movimientos_tipo_check` no tiene `'faltante'`;
  - `empleado_movimientos_rendicion_pago` exige `tipo = 'pago'` cuando hay rendición;
  - `empleado_movimientos_revierte_a_mano` ya deja revertir todo menos `mercaderia` y `reintegro`;
  - no tiene triggers ni grants.
- **`revertir_movimiento_empleado`**:
  - copia las tres `rendicion_*` en la reversión;
  - rechaza los tipos fuera de `adelanto`, `ajuste` y `pago` con un mensaje genérico.
- **El lock**: `registrar_movimiento_empleado` toma primero el empleado (`FOR UPDATE`) y después la
  rendición (`_rendicion_bloquear`). Una función nueva que toque los dos sigue ese orden.
- **`_guardar_gasto(jsonb, boolean)`**:
  - con `true` (`p_desde_cierre`), el que llama ya tiene el lock de la rendición y no se mira si
    está cerrada;
  - exige rol encargado o admin, un comprobante de la lista (`'ninguno'` sirve) y `monto_total > 0`;
  - pide que el transportista sea de la sucursal del gasto;
  - no compara `fecha` con `rendicion_fecha`;
  - `mes_imputado` sale de la fecha si no viene.
- **`_anular_gasto(bigint, text, boolean)`**: pide motivo y pone `anulado_at`, `anulado_por`,
  `motivo_anulacion` y `updated_at`.
- **`gastos`**: tiene SELECT para `authenticated` y nada de escritura REST. Sus triggers son
  `audit_gastos` y `trg_gastos_cuenta_empleado`.
- **`gasto_rubros`**:
  - tiene 18 rubros, sin sucursal;
  - el índice único es `lower(btrim(nombre))`;
  - el grupo `otros` existe;
  - no hay ningún rubro «Faltantes de caja».
- **`empleados_para_elegir()`**:
  - es de encargado o admin;
  - devuelve `{id, nombre, usuario_id, vehiculo_id, activo}`, de la sucursal activa o de las dos;
  - trae también los inactivos.
- **`GASTO-A`** cuenta los gastos con `updated_at > resuelta_at` (o `controlada_at`). Un gasto escrito
  en la misma transacción que resuelve comparte el `now()` y da 0.
- **El gate de las RPCs definer** (`scripts/check-rpcs-definer.mjs`, #1291):
  - un parámetro uuid de usuario (`p_transportista_id`) tiene que aparecer acotado en el texto: con
    `auth.uid()`, o cruzado con `usuario_sucursales` en un statement que mira la sucursal activa;
  - `scripts/rpcs-definer-permitidas.json` sólo se achica.
- **El front**:
  - `useRendiciones` es estado local, sin TanStack. `fetchResumen` pide `obtener_resumen_rendiciones`
    y `obtener_gastos_rendiciones` con `Promise.all`, y agrupa con `claveRendicion`;
  - `VistaRendiciones` toma los roles de `useAuthData()`;
  - `ResumenCard` no recibe `isAdmin`;
  - `ModalResolverRendicion` no tiene test propio.
- **Ensayos que llaman a `resolver_rendicion`**:
  - `test-gastos-3.sql`;
  - `test-rendicion-congelada-1248.sql`;
  - `test-rendicion-nucleo-1328-1329.sql`;
  - `test-fechas-utc-1298.sql`.

  Lo llaman con tres argumentos, por nombre o por posición.

## Cruces y coordinación

- **#1330 (gates):** los checks que propone esta entrega van al issue de la Tarea 7, Step 6. El
  ensayo los prueba mientras tanto.
- **Entrega 5 (roturas a cargo del empleado):** va después (decisión 7 del spec). Reusa el selector
  de empleado y el patrón de movimiento con origen.
- **`rendicion_control_foto`, `_rendicion_pagos`, `control_rendicion_cerrado`, `_guardar_gasto` y
  `_anular_gasto` no se tocan.**
- **Antes de lanzar las subsesiones**, la coordinadora vuelve a mirar el ledger y `main` (#1332,
  comentario del 02/11).

## Decisiones de este plan

Las del dueño están en el spec. Estas son de cómo se construye:

1. **`resolver_rendicion(p_fecha date, p_transportista_id uuid, p_observaciones text, p_resolucion
   jsonb DEFAULT NULL)`.** La firma vieja de tres argumentos se dropea en la misma migración
   (PGRST203). Con `p_resolucion` NULL no hay líneas ni comparación: es el bundle viejo. No se
   rechaza, porque resolver sólo con texto sigue valiendo.
2. **El rubro de «Robo o pérdida»** se busca por nombre (`lower(btrim(nombre)) = 'faltantes de
   caja'`, activo). Si no está, la resolución lo dice. No se suma una columna de clave a
   `gasto_rubros` por un solo rubro.
3. **El gasto de «Robo o pérdida»** lleva:
   - `fecha` = `rendicion_fecha` y `comprobante = 'ninguno'`;
   - `observacion` = `'Robo o pérdida · diferencia de la rendición de {transportista} del {dd/mm/aaaa}'`,
     más `' · {observación de la línea}'` si la hay.
4. **El gasto de «Gasto que no se cargó»** es el payload de `ModalGasto` con `desdeCierre`, como en
   el cierre: su fecha arranca en la de la rendición. El server le fuerza `origen_pago`,
   `rendicion_*` y `sucursal_id`, como el paso 7 de `confirmar_rendicion`. A su observación le suma
   `' · Diferencia de la rendición del {dd/mm/aaaa}'`. El monto de la línea tiene que ser igual a
   `monto_total`. En la vista Gastos, esa observación es la marca.
5. **El movimiento `faltante`** lleva:
   - `fecha` = `_tablero_hoy()`, y `observacion` = la observación de la línea (puede ser NULL);
   - las tres `rendicion_*`;
   - `creado_por` = `auth.uid()`.

   El concepto lo arma el front con `rendicion`.
6. **El orden de los locks** es el de `registrar_movimiento_empleado`:
   - se parsea y se valida el formato;
   - se toman los empleados de las líneas, `FOR UPDATE` y por id ascendente;
   - después la rendición, con `_rendicion_bloquear`.

   Deshacer lee primero los empleados de las líneas vivas. Si después del lock de la rendición las
   líneas vivas nombran otro empleado, rechaza con «La resolución cambió…».
7. **Se reusa la comparación de lo visto.** Los pasos 4 y 4b de `confirmar_rendicion` salen a un
   helper de server, `_rendicion_cambio_visto(p_sucursal_id bigint, p_transportista_id uuid, p_fecha
   date, p_vistos jsonb, p_pagos_personal_visto numeric, p_faltantes_visto numeric) RETURNS text`.
   Devuelve NULL si nada cambió, o `'gastos'`, `'pagos'` o `'faltantes'`. Lo usan
   `confirmar_rendicion` y `resolver_rendicion`, cada una con su mensaje: así hay una sola definición
   de «lo que vio el modal».
8. **El efectivo a entregar del server** (para el tope) es el mismo que arma el front:
   - **efectivo**: `SUM(monto)` de `_rendicion_pagos(v_suc, p_fecha, p_fecha)` con `t_id` igual al
     transportista y `forma_pago = 'efectivo'`;
   - **menos los gastos**: los vivos de la rendición;
   - **menos los pagos al personal**: `−SUM(monto)` de `tipo = 'pago'`;
   - **menos los faltantes a cargo de empleados**: `−SUM(monto)` de `tipo = 'faltante'`.

   El tope es `efectivo − gastos − pagos − faltantes − SUM(líneas nuevas) >= 0`, redondeado a 2.
9. **Las lecturas de las líneas** salen de una RPC nueva, `obtener_faltantes_rendiciones(p_fecha_desde
   date, p_fecha_hasta date, p_transportista_id uuid DEFAULT NULL) RETURNS jsonb`. Su molde de rol y
   de transportista es `obtener_gastos_rendiciones`: encargado y admin ven la sucursal activa, y el
   transportista sólo lo suyo. Devuelve sólo las vivas.
10. **Deshacer está disponible** en una rendición `resuelta`, o en una con líneas vivas en
    cualquier estado. Si tiene fila de control, la pasa a `disconformidad`, borra `resuelta_at` y
    `resuelta_por`, y suma el motivo a las observaciones. Sin fila (pendiente), no crea ninguna.
11. **El encargado** sigue cerrando y marcando la disconformidad. En la tarjeta, en lugar de
    «Resolver», ve `'La resuelve un admin'`. Hoy no hay ninguna resolución hecha por un encargado en
    prod (la del 01/09 la hizo un admin).

## Global Constraints

- **`CLAUDE.md` de la raíz rige todo**:
  - trampa 3: el número de migración se elige al aplicar;
  - trampa 5: parámetros en `INTEGER` o `BIGINT`, y la firma vieja se dropea;
  - al cambiar el retorno de una función se dropea y se reponen sus grants;
  - el día es el argentino (`_tablero_hoy()`, y `AT TIME ZONE 'America/Argentina/Buenos_Aires'` para
    la hora de las observaciones);
  - las reglas de tabla nueva y de función nueva.
- **Verificación**: antes de cerrar una tarea con front se corren `npm run typecheck`,
  `npm run lint`, `npm run test:run` (sin `.env`) y `npm run build`. El pre-commit corre la suite
  entera; nunca `--no-verify`. `test:run`, `build` y `git commit` van con el turno de
  `refs/turno/pesado` (#1332, "Cómo se trabajó", punto 3).
- **Migración**: `migrations/NNN_gastos_6_faltantes_rendicion.sql`, con NNN literal.
  - **Nadie aplica**: aplica la coordinadora, con el OK del dueño.
  - En prod (proyecto `hmuchlzmuqqxcldbzkgc`, `execute_sql`) se corren sólo SELECTs, el ensayo solo
    y el acumulado `BEGIN; SET LOCAL lock_timeout='5s'; <mig>; <ensayo>; ROLLBACK;`.
  - El veredicto del ensayo va en el `RAISE EXCEPTION` final. El acumulado lo manda la coordinadora,
    no un subagente.
  - **Si un clasificador de seguridad corta la copia del SQL a `execute_sql`, no se busca otra vía:
    se le avisa al dueño.** En las entregas 3 y 4 los corrió él desde el SQL Editor, con archivos
    armados por script.
- **Ensayo**: `scripts/test-gastos-6.sql`, con el molde de `scripts/test-gastos-5.sql`:
  - un `DO $ensayo$`, con `pg_temp.como` y `pg_temp.falla`;
  - usuarios reales elegidos en runtime, y choferes y encargado creados en `auth.users`;
  - el cierre es `ENSAYO OK · …` o `ENSAYO FALLÓ · …`.
- **Funciones**:
  - Las RPCs del front llevan `SECURITY DEFINER SET search_path = public`, `REVOKE ALL … FROM
    PUBLIC, anon` y `GRANT EXECUTE … TO authenticated, service_role`. Cada una nombra `es_admin()`
    o `es_encargado_o_admin()`.
  - Los helpers de server y la función de trigger llevan `REVOKE ALL … FROM PUBLIC, anon,
    authenticated`. El helper suma `GRANT EXECUTE … TO service_role`, y la de trigger no lleva grant.
  - `p_transportista_id` se acota en el texto, para el gate de #1291:
    - en las de escritura, con `IF NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE
      us.usuario_id = p_transportista_id AND us.sucursal_id = v_sucursal_id) THEN RAISE EXCEPTION
      'Ese transportista no es de esta sucursal'`;
    - en la de lectura, con el molde de `obtener_gastos_rendiciones`.

    No se suma nada a `scripts/rpcs-definer-permitidas.json`.
- **Tabla nueva** `rendicion_faltantes`:
  - `ENABLE ROW LEVEL SECURITY`, sin policies;
  - `REVOKE ALL … FROM PUBLIC, anon, authenticated`;
  - sin `GRANT` de secuencias; `scripts/grants-rest.json` no cambia.
- **Mensajes del server** (`RAISE EXCEPTION`, llegan en `error.message`):
  - **Resolver:**
    - `'Sólo un admin resuelve una disconformidad'` (42501)
    - `'Solo se pueden resolver rendiciones en disconformidad (estado actual: %)'` y
      `'No existe rendicion para (%, %)'`, los de hoy
    - `'Ese transportista no es de esta sucursal'`
    - `'Escribí cómo se resolvió'`
    - `'La resolución viene con un formato inválido'`
    - `'Cada línea lleva un monto mayor a 0'`
    - `'Elegí a qué empleado se le carga el faltante'`
    - `'Ese empleado no existe o no lo podés ver'`, el de siempre
    - `'Ese empleado está dado de baja'`
    - `'Ese empleado no es de esta sucursal'`
    - `'Tu propia cuenta la maneja otro admin: no podés cargarte un faltante'`
    - `'Lo imputado supera lo que había para entregar'`
    - `'Falta el rubro «Faltantes de caja»: dalo de alta o reactivalo en Gastos'`
    - `'Los gastos de esta rendición cambiaron mientras la resolvías: tocá Refrescar y volvé a abrir'`
    - `'Los pagos al personal de esta rendición cambiaron mientras la resolvías: tocá Refrescar y volvé a abrir'`
    - un error de `_guardar_gasto` en una línea sale como `'En la línea de {rubro}: {mensaje}'`
  - **Deshacer:**
    - `'Sólo un admin deshace una resolución'` (42501)
    - `'Escribí por qué se deshace'`
    - `'No hay nada para deshacer en esta rendición'`
    - `'La resolución cambió mientras la deshacías: volvé a intentar'`
  - **Cierre (`confirmar_rendicion`):**
    - `'Los faltantes de esta rendición cambiaron mientras la cerrabas: tocá Refrescar y volvé a abrir el cierre'`
    - `'Esta rendición tiene una diferencia imputada: para volver a disconformidad, deshacé la resolución'`
  - **La guarda de gastos:** `'Este gasto es de la resolución de una diferencia: se deshace con «Deshacer resolución» en Rendiciones'`
  - **Personal:** `'Un faltante de rendición se deshace desde la rendición, con «Deshacer resolución»'`
  - **Observaciones:** el sello de resolver es el de hoy, y el de deshacer es
    `'[Deshecha por {nombre} el {dd/mm/aaaa HH24:MI}]: {motivo}'`, con la hora argentina.
- **Textos del front**:
  - **Causales** (`ETIQUETA_CAUSAL`): `'A cargo del empleado'`, `'Robo o pérdida'`,
    `'Gasto que no se cargó'`.
  - **La sección:**
    - `'Diferencia'`, con la ayuda `'Opcional: cargá la plata que faltó y a dónde va.'`;
    - el botón `'+ Agregar línea'` y los campos `'Monto'`, `'Empleado'` y `'Observación (opcional)'`;
    - para un gasto, `'Cargar el gasto'`;
    - la cuenta: `'A entregar {a} · imputado {i} · queda {q}'`.
  - **Avisos:** sin empleados, `'Para cargársela a alguien, primero dalo de alta en Personal'`; con
    tope pasado, `'Lo imputado supera lo que había para entregar'`.
  - **Encargado:** `'La resuelve un admin'`.
  - **Deshacer:**
    - el título y el botón: `'Deshacer resolución'`;
    - el texto: `'Se compensan las deudas, se anulan los gastos de la resolución y la rendición vuelve a disconformidad.'`;
    - el campo: `'¿Por qué se deshace?'`, obligatorio.
  - **Tarjeta y «Mis cobros»:**
    - el tramo de la línea de detalle: `'{monto} de faltantes a cargo de empleados'`;
    - el título de la lista: `'Diferencia imputada'`;
    - la marca de un gasto: `'De la resolución de la diferencia'`.
  - **Editar cierre:**
    - la línea fija: `'Faltantes a cargo de empleados: {monto}'`;
    - la marca de un gasto: `'De la resolución de la diferencia'`;
    - con «Disconformidad» deshabilitado: `'Deshacé la resolución primero'`.
  - **Personal:**
    - el concepto: `'Faltante de rendición del {dd/mm} ({transportista})'`;
    - el de su compensación: `'Se deshizo un faltante de rendición'`;
    - en lugar de «Revertir»: `'Se deshace desde la rendición'`.
  - Plata con `formatPrecio`; en los tests se compara contra `formatPrecio(x)`.
- **Modales anidados**:
  - `ModalGasto` va **dentro** del árbol de `ModalResolverRendicion`, como en el cierre;
  - `ModalDeshacerResolucion` es un modal propio que abre la vista.

  Los schemas Zod van co-locados.
- **Modelo por tarea**: la migración con **Opus**, esfuerzo high. El front con **Sonnet**, esfuerzo
  high; si el review encuentra lógica floja en una tarea, se repite esa con Opus.

## Review Focus

1. **Algo cambió mientras el admin resolvía.** Otro admin cargó un gasto desde Gastos, o pagó un
   sueldo con esa rendición. La resolución se rechaza y nada queda escrito. Caso 9 del ensayo, y el
   test de la Tarea 4 que congela lo visto.
2. **Deshacer una deuda que ya se descontó en una liquidación.** La próxima liquidación se la
   devuelve, y el saldo queda exacto. Caso 13c.
3. **Una rendición resuelta que se reabre sola** porque cambió la fecha de entrega de un pedido del
   día. Lo imputado sigue restando, «Deshacer» sigue disponible y la rendición queda pendiente.
   Caso 14.
4. **Tocar un gasto de la resolución por otro camino**: desde Gastos con la rendición reabierta, o
   desde «Editar cierre». El server lo rechaza con su mensaje y no cambia nada. Caso 11.
5. **El bundle viejo del PWA.** El admin resuelve con tres argumentos, sólo con texto, y anda. El
   encargado recibe `'Sólo un admin resuelve una disconformidad'`. «Editar cierre» sin
   `faltantes_visto` en una rendición sin faltantes anda igual que hoy. Caso 16.

---

### Task 1: Tipos y reglas puras de los faltantes

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/types/gastos.ts`, `src/types/hooks.ts` y `src/types/personal.ts`.
- Create: `src/utils/faltantesRendicion.ts` y `src/utils/faltantesRendicion.test.ts`.
- Modify: `src/utils/rendicionGastos.ts` y su test.
- Modify: `src/utils/personal.ts` y su test.

**Interfaces (Produces):**
- En `src/types/gastos.ts`:
  ```ts
  export type CausalFaltante = 'empleado' | 'robo_perdida' | 'gasto_no_cargado'
  export interface FaltanteDeRendicion {
    id: number; transportista_id: string; fecha: string; causal: CausalFaltante; monto: number
    observacion: string | null; empleado: { id: number; nombre: string } | null
    gasto_id: number | null; rubro_nombre: string | null
    creado_por_nombre: string | null; created_at: string
  }
  export type LineaResolucion =
    | { causal: 'empleado'; monto: number; empleado_id: number; observacion: string | null }
    | { causal: 'robo_perdida'; monto: number; observacion: string | null }
    | { causal: 'gasto_no_cargado'; monto: number; gasto: GuardarGastoPayload }
  export interface ResolucionRendicion {
    lineas: LineaResolucion[]; vistos: GastoVisto[]; pagos_personal_visto: number
  }
  ```
  `CambiosGastosRendicion` suma `faltantes_visto: number`.
- `ResumenRendicionDiaria` (`src/types/hooks.ts`) suma `total_faltantes_empleados: number` y
  `faltantes: FaltanteDeRendicion[]`.
- `TipoMovimientoEmpleado` (`src/types/personal.ts`) suma `'faltante'`.
- En `src/utils/faltantesRendicion.ts`:
  - `ETIQUETA_CAUSAL: Record<CausalFaltante, string>`, `MENSAJE_SIN_EMPLEADOS` y `MENSAJE_SUPERA`,
    con los textos de Global Constraints;
  - `totalImputado(lineas: ReadonlyArray<{ monto: number }>): number`, redondeado a 2;
  - `quedaAEntregar(aEntregar: number, lineas: ReadonlyArray<{ monto: number }>): number`;
  - `empleadosParaFaltante(empleados: EmpleadoParaElegir[], usuarioId: string | null): EmpleadoParaElegir[]`:
    los activos y sin el del usuario, por nombre;
  - `empleadoSugerido(empleados: EmpleadoParaElegir[], transportistaId: string): number | null`;
  - `gastosDeResolucion(faltantes: FaltanteDeRendicion[]): Set<number>`;
  - `textoFaltante(f: FaltanteDeRendicion): string`.
- En `src/utils/rendicionGastos.ts`:
  - `efectivoAEntregar(efectivoCobrado: number, gastos: number, pagosPersonal = 0, faltantesEmpleados = 0): number`;
  - `cambiosDelCierre(items, vistos, pagosPersonalVisto, faltantesVisto = 0): CambiosGastosRendicion`.
- En `src/utils/personal.ts`, `conceptoDeMovimiento` suma el caso `'faltante'`, y
  `TITULO_REVERSION.faltante = 'Se deshizo un faltante de rendición'`.

- [ ] **Step 1: Tests:**
  - **`totalImputado`**: `[{monto: 1000.005}, {monto: 2000}]` da 3000.01; vacío da 0.
  - **`quedaAEntregar`**: `quedaAEntregar(800000, [{monto: 3000}, {monto: 2000}])` da 795000.
  - **`empleadosParaFaltante`**:
    - saca los inactivos y el que tiene `usuario_id` del usuario;
    - ordena por nombre;
    - con todos inactivos da `[]`.
  - **`empleadoSugerido`**:
    - da el id del activo con `usuario_id === transportistaId`;
    - sin vinculado, o con el vinculado inactivo, da `null`.
  - **`gastosDeResolucion`**: da los `gasto_id` no nulos.
  - **`textoFaltante`**:
    - empleado: `'A cargo de Marcos Delgado · ' + formatPrecio(2000)`;
    - robo: `'Robo o pérdida · ' + formatPrecio(1000)`;
    - gasto: `'Gasto que no se cargó: Peajes y estacionamiento · ' + formatPrecio(500)`;
    - cada uno con `' · {observación}'` si la hay.
  - **`efectivoAEntregar(500000, 50000, 100000, 20000)`** da 330000; sin el cuarto, 350000.
  - **`cambiosDelCierre`** con `faltantesVisto` 5000 lo manda como `faltantes_visto`; sin él, 0.
  - **`conceptoDeMovimiento`**:
    - un `faltante` con rendición de «Transporte Taco Pozo» del 2026-06-11 titula
      `'Faltante de rendición del 11/06 (Transporte Taco Pozo)'`, con la observación de detalle;
    - su compensación titula `'Se deshizo un faltante de rendición'`.
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.** Al sumar
  `'faltante'`, el `switch` exhaustivo de `conceptoDeMovimiento` lo pide. Si `typecheck` marca otro
  `switch` o `Record` sobre `TipoMovimientoEmpleado`, se completa en esta tarea.
- [ ] **Step 3: Commit** `feat(rendiciones): tipos y reglas de los faltantes`.

---

### Task 2: Migración — faltantes de rendición

Modelo: Opus, esfuerzo high. Cambia `confirmar_rendicion` y `obtener_resumen_rendiciones`, que son
el corazón del control de rendiciones. Antes de escribir, leer el `CLAUDE.md` de la raíz,
`migrations/CLAUDE.md` y el comentario del 02/11 en #1332 (CRLF y md5).

**Files:**
- Create: `migrations/NNN_gastos_6_faltantes_rendicion.sql` y `scripts/test-gastos-6.sql`.
- Modify: `src/test/rpcsSoloServidor.test.ts`, que suma `_rendicion_cambio_visto` y
  `rendicion_faltantes_guarda_gasto` con `'NNN_gastos_6'`.
- Modify: los ensayos que esperan que el encargado resuelva (ver Step 4).
- Modify: `CLAUDE.md`, en Convenciones, después de la línea de «La comisión de un pedido es una»:
  ```
  - **Un faltante de rendición se imputa al resolverla** (gastos 6): `rendicion_faltantes`, una
    línea por causal, atada a la clave de la rendición y no a `rendiciones_control.id`. La deuda es
    un movimiento `faltante` con las `rendicion_*`; los gastos son de la rendición, y un trigger no
    deja tocar uno con una línea viva. El efectivo a entregar resta los dos.
    `total_pagos_personal` es sólo `tipo = 'pago'`: una suma nueva de movimientos por rendición
    elige sus tipos. Se deshace todo junto (`deshacer_resolucion_rendicion`), nunca un pedazo.
  ```

**Interfaces (Produces):**

**Guarda `$vivas$`**: las cuatro funciones de «Lo que hay hoy», con el md5 de prod re-consultado.
Las reescrituras parten:
- de `prosrc` vivo para `confirmar_rendicion`, `obtener_resumen_rendiciones` y
  `revertir_movimiento_empleado`, contando con el `\r\n`;
- de la 423 para `resolver_rendicion`.

**`empleado_movimientos`**:
- `empleado_movimientos_tipo_check` suma `'faltante'`;
- `empleado_movimientos_rendicion_pago` pasa a `rendicion_fecha IS NULL OR tipo IN ('pago', 'faltante')`;
- se suman:
  - `empleado_movimientos_faltante_negativo`:
    `CHECK (tipo <> 'faltante' OR revierte_id IS NOT NULL OR monto < 0)`;
  - `empleado_movimientos_faltante_rendicion`:
    `CHECK (tipo <> 'faltante' OR rendicion_fecha IS NOT NULL)`.

**`gasto_rubros`**: `INSERT ('Faltantes de caja', 'otros', 'faltante robo perdida', false, NULL, false)`,
con `ON CONFLICT DO NOTHING` sobre el índice de nombre.

**`rendicion_faltantes`**:
- **la clave**: `id` identity, más `rendicion_transportista_id uuid NOT NULL REFERENCES perfiles(id)`,
  `rendicion_fecha date NOT NULL` y `rendicion_sucursal_id bigint NOT NULL REFERENCES sucursales(id)`.
  No se llama `sucursal_id`, para que `auditoria_sucursal_cruzada` no la cruce con el empleado;
- **la causal**: `causal text NOT NULL CHECK (causal IN ('empleado','robo_perdida','gasto_no_cargado'))`;
- **el monto**: `monto numeric(14,2) NOT NULL CHECK (monto > 0)`;
- **a qué apunta**: `empleado_id bigint REFERENCES empleados(id)`,
  `movimiento_id bigint UNIQUE REFERENCES empleado_movimientos(id)` y
  `gasto_id bigint UNIQUE REFERENCES gastos(id)`, con
  `CHECK ((causal = 'empleado') = (empleado_id IS NOT NULL AND movimiento_id IS NOT NULL AND gasto_id IS NULL))`
  y `CHECK ((causal <> 'empleado') = (gasto_id IS NOT NULL AND empleado_id IS NULL AND movimiento_id IS NULL))`;
- **el resto**: `observacion text`, `creado_por uuid NOT NULL` y `created_at timestamptz NOT NULL DEFAULT now()`;
- **la anulación**: `anulada_at timestamptz`, `anulada_por uuid` y `motivo_anulacion text`, con
  `CHECK ((anulada_at IS NULL) = (motivo_anulacion IS NULL))`;
- índice `(rendicion_sucursal_id, rendicion_fecha, rendicion_transportista_id) WHERE anulada_at IS NULL`.

**`rendicion_faltantes_guarda_gasto()` RETURNS trigger**: `SECURITY DEFINER`, `BEFORE UPDATE OR
DELETE ON gastos FOR EACH ROW`. Si existe una línea con `gasto_id = OLD.id` y `anulada_at IS NULL`,
levanta el mensaje de la guarda con `ERRCODE '42501'`.

**`_rendicion_cambio_visto(...)`**: la de la decisión 7. Con el contenido de los pasos 4 y 4b de
`confirmar_rendicion` y un 4c nuevo:
- **4**: los gastos vivos `(id, updated_at)` contra `p_vistos`. Si difieren, da `'gastos'`;
- **4b**: `−SUM(monto)` de `tipo = 'pago'` contra `p_pagos_personal_visto`. Si difiere, da `'pagos'`;
- **4c**: `−SUM(monto)` de `tipo = 'faltante'` contra `p_faltantes_visto`. Si difiere, da
  `'faltantes'`.

**`confirmar_rendicion`** (parche sobre el cuerpo vivo, misma firma):
- el formato acepta `faltantes_visto` número, que vale 0 si no viene;
- los pasos 4 y 4b pasan a `_rendicion_cambio_visto`, con los mismos mensajes de hoy más el de
  faltantes;
- con `p_estado = 'disconformidad'` y alguna línea viva, rechaza con su mensaje;
- lo demás queda igual. Un gasto de la resolución en `quitar` o `guardar` lo frena la guarda, y
  sale con el prefijo «En el gasto de …» de hoy.

**`obtener_resumen_rendiciones`** (`DROP` + `CREATE`, mismos grants):
- suma la columna `total_faltantes_empleados numeric`, al final;
- `pagos_personal_agg` filtra `m.tipo = 'pago'`;
- un `faltantes_agg` igual, con `tipo = 'faltante'`, que también aporta a `fechas_activas`.

Antes del `DROP`, buscar llamadores con `prosrc ~ 'obtener_resumen_rendiciones'`.

**`revertir_movimiento_empleado`** (parche): antes del rechazo por tipo, `IF v_m.tipo = 'faltante'
THEN RAISE EXCEPTION` con el mensaje de Personal.

**`resolver_rendicion(p_fecha date, p_transportista_id uuid, p_observaciones text, p_resolucion jsonb DEFAULT NULL) RETURNS bigint`**,
en este orden:
1. sucursal activa y `es_admin()`, o el mensaje de resolver (42501);
2. `p_observaciones` sin blancos, o `'Escribí cómo se resolvió'`. Hoy lo exige sólo el front;
3. el transportista en `usuario_sucursales` de la sucursal activa;
4. el formato de `p_resolucion`:
   - `{lineas: [...], vistos: [...], pagos_personal_visto: n}`;
   - cada línea es un objeto con `causal`, `monto` número y, según la causal, `empleado_id` número,
     `observacion` texto o null, o `gasto` objeto;
   - si algo no cuadra, el mensaje de formato;
   - `monto <= 0` da su mensaje, y el monto se redondea a 2;
   - en `gasto_no_cargado`, un `monto` distinto de `gasto.monto_total` es formato inválido;
5. los empleados de las líneas, `FOR UPDATE` y por id ascendente. Para cada uno, en este orden:
   - no existe o no es visible (`_empleado_visible`);
   - `NOT activo`;
   - `sucursal_id <> v_suc AND NOT de_las_dos`;
   - `usuario_id = auth.uid()`.

   Cada caso con su mensaje;
6. `_rendicion_bloquear` de la clave;
7. la fila de control, que tiene que existir y estar en `disconformidad`, con los mensajes de hoy.
   Afirmar que no hay líneas vivas; si las hay, es formato inválido;
8. con `p_resolucion` no nulo, `_rendicion_cambio_visto(…, p_faltantes_visto => 0)`: si da
   `'gastos'` o `'pagos'`, su mensaje de resolver;
9. el tope de la decisión 8;
10. para cada línea, en el orden en que vino:
    - **empleado**: el `INSERT` del movimiento de la decisión 5, y la línea con `movimiento_id`;
    - **robo o pérdida**: `_guardar_gasto(…, true)` con el rubro de la decisión 2 y el gasto de la
      decisión 3, y la línea con `gasto_id`;
    - **gasto que no se cargó**: `_guardar_gasto(gasto || forzados, true)`, como en la decisión 4,
      con el prefijo de error. Sin `id`: un gasto que ya existe es formato inválido.

    Cada línea guarda `observacion` y `creado_por`;
11. el `UPDATE` de la fila a `resuelta`, con el sello de hoy. La foto la toma el trigger;
12. devuelve el id del control.

**`deshacer_resolucion_rendicion(p_fecha date, p_transportista_id uuid, p_motivo text) RETURNS void`**:
1. sucursal activa y `es_admin()`, o su mensaje (42501); el motivo sin blancos, o su mensaje;
2. el transportista de la sucursal, como en resolver;
3. los empleados de las líneas vivas de la clave, `FOR UPDATE` y por id ascendente;
4. `_rendicion_bloquear` de la clave. Se releen las líneas vivas: si nombran un empleado que no se
   lockeó, da el mensaje de «cambió»;
5. sin fila `resuelta` y sin líneas vivas, `'No hay nada para deshacer en esta rendición'`;
6. con fila de control: `estado = 'disconformidad'`, `resuelta_at` y `resuelta_por` NULL, y el sello
   de deshacer en `observaciones`. La foto la suelta el trigger;
7. para cada línea viva, primero `anulada_at = now()`, `anulada_por = auth.uid()` y
   `motivo_anulacion = btrim(p_motivo)`, y después:
   - **empleado**: un `faltante` con `monto = −monto del original`, `revierte_id`,
     `fecha = _tablero_hoy()`, las mismas `rendicion_*`, `observacion = btrim(p_motivo)` y
     `creado_por`;
   - **gasto**: `_anular_gasto(gasto_id, 'Se deshizo la resolución de la diferencia: ' || btrim(p_motivo), true)`.

**`obtener_faltantes_rendiciones(...)`**: la de la decisión 9. Devuelve un array de objetos con la
forma de `FaltanteDeRendicion` de la Tarea 1, con:
- `transportista_id` y `fecha`: los de la clave (`rendicion_transportista_id` y `rendicion_fecha`);
- `empleado`: `{id, nombre}` o null;
- `rubro_nombre`: el del gasto, o null;
- `creado_por_nombre`: de `perfiles`.

Ordena por fecha y por `id`.

**Permisos**:
- `resolver_rendicion`, `deshacer_resolucion_rendicion` y `obtener_faltantes_rendiciones`: para
  `authenticated` y `service_role`;
- `_rendicion_cambio_visto`: sólo `service_role`;
- la función de trigger: ninguno.

**Verificación estructural** (`DO $verif$` al final):
- `to_regprocedure('public.resolver_rendicion(date,uuid,text)')` es NULL, y queda una sola
  `resolver_rendicion`;
- `anon` no ejecuta nada nuevo, y `authenticated` no ejecuta los dos helpers;
- `rendicion_faltantes` sin privilegios para `anon` ni `authenticated`;
- el rubro existe y está activo.

- [ ] **Step 1: Ensayo `scripts/test-gastos-6.sql`.** Casos:
  1. **Guarda**: sin la migración da `ENSAYO FALLÓ · … (falta la migracion gastos_6)`.
  2. **Quién**:
     - el encargado `en` resuelve una disconformidad ajena y recibe `'Sólo un admin resuelve…'`;
     - el transportista `tr` también;
     - `en` deshace y recibe `'Sólo un admin deshace…'`.
  3. **Sólo texto**: `a1` resuelve con `p_resolucion` `{lineas: [], vistos, pagos_personal_visto}`.
     Queda `resuelta`, con la foto (`rendicion_pagos_confirmados` con filas) y el sello. Ninguna
     línea.
  4. **Deuda**, con una disconformidad de `tr` con 50.000 en efectivo y un gasto de 10.000:
     - una línea de 3.000 a `E1` deja un movimiento `faltante` −3.000, con la clave, `fecha = hoy` y
       `creado_por = a1`, y la línea con `movimiento_id`;
     - `obtener_resumen_rendiciones` da `total_faltantes_empleados` 3.000 y
       `total_pagos_personal` 0.
  5. **Robo o pérdida** de 1.000: un gasto con el rubro, `comprobante = 'ninguno'`,
     `fecha = rendicion_fecha` y la observación de la decisión 3. `total_gastos` suma 1.000.
  6. **Gasto que no se cargó**: con el rubro «Peajes y estacionamiento» y 500, la línea con ese
     `gasto_id`. Con `monto` 600 contra `monto_total` 500 da formato inválido.
  7. **Varias líneas y tope**:
     - 3.000 a `E1`, 2.000 a `E2` y 1.000 de robo dan tres líneas;
     - una que pase el tope (`50.000 − 10.000 − lo anterior`) da `'Lo imputado supera…'`, y nada
       queda escrito: ni movimientos, ni gastos, ni líneas, y la rendición sigue en disconformidad.
  8. **Validaciones**:
     - monto 0 o negativo;
     - causal desconocida;
     - empleado sin `empleado_id`, inexistente, dado de baja, de Taco Pozo para una rendición de
       Tucumán, o el propio de `a1`;
     - rendición confirmada;
     - transportista de otra sucursal.

     Cada una con su mensaje, y nada escrito.
  9. **Lo visto**:
     - un gasto cargado con `guardar_gasto` después de leer los vistos da el mensaje de gastos;
     - un pago suelto de rendición (`registrar_movimiento_empleado` con `origen_pago = 'rendicion'`)
       da el de pagos;
     - en ninguno de los dos queda nada escrito.
  10. **Personal**:
      - `revertir_movimiento_empleado` de un `faltante` da su mensaje;
      - `previsualizar_liquidacion` de `E1` trae el `faltante` en `movimientos`, y `a_pagar` baja
        3.000.
  11. **La guarda de gastos**:
      - con la rendición reabierta por `desmarcar_rendicion_controlada`, `guardar_gasto` sobre el
        gasto de robo da el mensaje de la guarda, y `anular_gasto` también;
      - con la rendición resuelta, `confirmar_rendicion` con ese gasto en `quitar` da
        `'En el gasto de Faltantes de caja: Este gasto es de la resolución…'`.
  12. **Editar cierre** sobre la resuelta con líneas:
      - con `faltantes_visto` correcto, confirma;
      - con uno viejo, da el mensaje de faltantes;
      - con `'disconformidad'`, da el de deshacer primero;
      - en ninguno se tocan las líneas.
  13. **Deshacer**:
      - a. sin motivo da su mensaje;
      - b. con motivo, sobre la resuelta del caso 7:
        - las tres líneas quedan anuladas;
        - `E1` y `E2` reciben su compensación positiva, con `revierte_id`, `fecha = hoy` y la clave;
        - el gasto de robo queda anulado con el motivo;
        - la rendición vuelve a `disconformidad`, sin foto y con el sello;
        - `total_faltantes_empleados` da 0, y `total_gastos` vuelve a 10.000;
      - c. con `E1` liquidado entre resolver y deshacer, la liquidación siguiente de `E1` suma 3.000,
        y el saldo de `E1` queda en lo que era antes de resolver;
      - d. resolver otra vez la misma rendición anda, y las líneas nuevas conviven con las anuladas;
      - e. deshacer una resuelta sólo con texto la vuelve a disconformidad, sin tocar nada más.
  14. **Reabierta sola**:
      - con líneas vivas, `desmarcar_rendicion_controlada` deja la rendición pendiente, y
        `total_faltantes_empleados` sigue en 3.000;
      - deshacer anula las líneas y no crea fila de control.
  15. **Nada para deshacer**: una rendición pendiente sin líneas da su mensaje.
  16. **Bundle viejo**:
      - `a1` llama con tres argumentos por nombre (como `useRendiciones.ts` hoy) y resuelve con
        texto;
      - `en` recibe el mensaje de resolver;
      - `confirmar_rendicion` sin `faltantes_visto` en una rendición sin faltantes confirma.
  17. **Lecturas**:
      - `obtener_faltantes_rendiciones` le da a `a1` y a `en` las líneas vivas de la sucursal, con
        empleado y rubro;
      - `tr` ve sólo las suyas, y con el id de otro transportista recibe 42501;
      - las anuladas no salen.
  18. **Lo de antes sigue igual**: un pago al personal de rendición sigue sumando a
      `total_pagos_personal`. Con 0 faltantes, `obtener_resumen_rendiciones` de octubre da lo mismo
      que antes en todas las columnas de antes.
  19. **Permisos**:
      - `anon` no ejecuta nada nuevo;
      - `authenticated` no ejecuta los helpers ni la de trigger;
      - la tabla no tiene privilegios;
      - `auditoria_definer_sin_rol()` no lista nada nuevo;
      - `auditoria_rpcs_definer()` no tiene hallazgos con las funciones nuevas;
      - `auditoria_sucursal_cruzada()` no suma ningún par.
  20. **Invariantes al final de todo**:
      - `GASTO-A` da 0;
      - toda línea viva tiene su movimiento sin revertir o su gasto sin anular, con el mismo monto;
      - todo `faltante` sin `revierte_id` tiene su línea;
      - `auditoria_integridad()->'critical_high_en_rojo'` da lo mismo al empezar y al final.
- [ ] **Step 2: Ensayo solo en prod → `ENSAYO FALLÓ`.**
- [ ] **Step 3: Migración**, con `SET LOCAL lock_timeout = '5s'` arriba y la cabecera al estilo de
  la 437:
  - qué agrega;
  - por qué la clave y no el id;
  - el orden de los locks;
  - qué pasa con el bundle viejo;
  - el despliegue.
- [ ] **Step 4: Ensayos acumulados**, cada uno con la migración entera:
  - `test-gastos-6` → `ENSAYO OK`;
  - `test-gastos-3`, `test-gastos-4` y `test-gastos-5` → OK;
  - `test-rendicion-congelada-1248`, `test-rendicion-nucleo-1328-1329` y `test-fechas-utc-1298` →
    OK. Donde esperen que un encargado resuelva, pasan a esperar el mensaje de resolver, y el
    desvío se anota;
  - `auditoria_integridad()->'critical_high_en_rojo'` igual que antes.
- [ ] **Step 5: `npx vitest run src/test/rpcsSoloServidor.test.ts src/test/fechasUtc.test.ts`, y
  commit** `feat(rendiciones): faltantes de rendición (mig NNN)`.

---

### Task 3: Datos de los faltantes

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/hooks/supabase/useRendiciones.ts`, `src/types/hooks.ts` (`UseRendicionesReturn`).
- Modify: `src/hooks/supabase/useRendiciones.gastos.test.ts` y `useRendiciones.errores.test.ts`.

**Interfaces:**
- **Consumes**: los tipos de la Tarea 1; las RPCs de la Tarea 2.
- **Produces**:
  - **`fetchResumen`**:
    - pide también `obtener_faltantes_rendiciones` con los mismos parámetros, en el mismo
      `Promise.all`;
    - mapea `total_faltantes_empleados` con `Number(r.total_faltantes_empleados) || 0`;
    - le pone a cada resumen sus `faltantes` por `claveRendicion`, o `[]`;
    - el mensaje sin conexión de los faltantes es
      `'Sin conexión: no se pudieron cargar las diferencias de las rendiciones. Revisá la señal e intentá de nuevo.'`.
  - **`resolverRendicion(fecha: string, transportistaId: string, observaciones: string, resolucion: ResolucionRendicion): Promise<void>`**
    manda `{ p_fecha, p_transportista_id, p_observaciones, p_resolucion: resolucion }`.
  - **`deshacerResolucion(fecha: string, transportistaId: string, motivo: string): Promise<void>`**
    llama a `deshacer_resolucion_rendicion` con `{ p_fecha, p_transportista_id, p_motivo }`. El error
    va con `errorNotificado(error, 'Error al deshacer la resolución', 'Sin conexión: …')`. Al
    terminar, refresca el último rango, como `resolverRendicion`.

- [ ] **Step 1: Tests:**
  - "trae los faltantes y los cuelga de su rendición";
  - "sin la columna, `total_faltantes_empleados` es 0";
  - "resolver manda la resolución entera";
  - "deshacer manda el motivo y refresca";
  - "un error de faltantes notifica con su mensaje".
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(rendiciones): datos de los faltantes`.

---

### Task 4: Resolver con la diferencia

Modelo: Sonnet, esfuerzo high. Es el modal más delicado de la entrega: si el review lo encuentra
flojo, se repite con Opus.

**Files:**
- Modify: `src/components/modals/ModalResolverRendicion.tsx`.
- Create: `src/components/modals/ModalResolverRendicion.test.tsx`.

**Interfaces:**
- **Consumes**:
  - `useEmpleadosParaElegirQuery` y `usePropsModalGasto`;
  - de la Tarea 1: `empleadosParaFaltante`, `empleadoSugerido`, `quedaAEntregar`, `ETIQUETA_CAUSAL`,
    `MENSAJE_SIN_EMPLEADOS`, `MENSAJE_SUPERA` y `gastosVistos`;
  - `ModalGasto` lazy, con `desdeCierre`.
- **Produces**: `ModalResolverRendicionProps` suma:
  - `transportistaId: string`;
  - `aEntregar: number`, el efectivo a entregar de hoy;
  - `gastos: GastoDeRendicion[]` y `totalPagosPersonal: number`;
  - `onResolver(observaciones: string, resolucion: ResolucionRendicion): Promise<void>`.

**Comportamiento:**
- **Lo que congela al abrir**: `vistos` (con `gastosVistos(gastos)`) y `pagos_personal_visto`, con
  `useState`, como el cierre.
- **La sección «Diferencia»**, entre las observaciones previas y «¿Cómo se resolvió?»:
  - **«+ Agregar línea»** abre una línea con las tres causales como botones. Cada línea se puede
    quitar;
  - **empleado**: el Combobox con `empleadosParaFaltante(empleados, usuarioId)`, que arranca en
    `empleadoSugerido`, más «Monto» y «Observación (opcional)». Sin empleados para elegir, la causal
    queda deshabilitada con `MENSAJE_SIN_EMPLEADOS`;
  - **robo o pérdida**: «Monto» y «Observación (opcional)»;
  - **gasto que no se cargó**: «Cargar el gasto» abre `ModalGasto` dentro de este modal, con
    `desdeCierre={{ transportistaId, transportistaNombre, fecha }}`. Al guardar, la línea muestra el
    rubro y el monto del gasto, con «Editar», que reabre el gasto con `borrador`;
  - **debajo**, la cuenta `'A entregar … · imputado … · queda …'`. Con `queda < 0`, `MENSAJE_SUPERA`
    en `role="alert"`.
- **El schema Zod**, co-locado:
  - el texto es obligatorio, como hoy;
  - cada monto es mayor a 0;
  - la línea de empleado tiene empleado, y la de gasto tiene el gasto cargado;
  - `queda >= 0`.

  «Marcar como resuelta» queda deshabilitado mientras no valide.
- **Al confirmar**: `onResolver(texto, { lineas, vistos, pagos_personal_visto })`. La línea de gasto
  lleva `monto: gasto.monto_total`.
- **Enter en un campo no confirma**, y Escape con el Combobox abierto lo cierra, no el modal: la
  guarda `src/utils/escapeConBuscador.ts`.

- [ ] **Step 1: Tests** (con los mocks de `ModalCerrarRendicion.test.tsx` para empleados,
  `usePropsModalGasto` y el stub de `ModalGasto`):
  - "sin líneas resuelve con el texto, `lineas: []` y lo visto al abrir";
  - "la línea de empleado arranca en el vinculado al transportista";
  - "sin empleados activos, la causal se deshabilita con el aviso";
  - "el propio admin no aparece en la lista";
  - "un gasto cargado se suma con su monto y se puede editar";
  - "imputar más de lo que había avisa y no deja confirmar";
  - "la cuenta muestra a entregar, imputado y queda";
  - "un refetch de gastos con el modal abierto no cambia los vistos que se mandan";
  - "monto 0 no deja confirmar".
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(rendiciones): resolver con la diferencia imputada`.

---

### Task 5: La vista Rendiciones: quién resuelve, deshacer y lo imputado

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/components/vistas/VistaRendiciones.tsx` y `__tests__/VistaRendiciones.test.tsx`.
- Create: `src/components/modals/ModalDeshacerResolucion.tsx` y su test.

**Interfaces:**
- **Consumes**: `resolverRendicion` y `deshacerResolucion` de la Tarea 3; `textoFaltante`,
  `gastosDeResolucion` y el `efectivoAEntregar` de cuatro argumentos de la Tarea 1; el modal de la
  Tarea 4.
- **Produces**:
  - `ResumenCard` suma `esAdmin?: boolean` y `onDeshacer(resumen)`;
  - `ModalDeshacerResolucionProps`:
    `{ fecha: string; transportistaNombre: string; onDeshacer: (motivo: string) => Promise<void>; onClose: () => void; guardando: boolean }`.

**Comportamiento:**
- **Los botones**, si no es `soloLectura`:
  - **disconformidad**:
    - el admin ve «Resolver»;
    - el encargado, que no es admin, ve `'La resuelve un admin'`;
    - la propia del encargado sigue con su texto de hoy;
  - **«Deshacer resolución»**: el admin lo ve si `estado === 'resuelta'` o `faltantes.length > 0`.
    Abre `ModalDeshacerResolucion`.
- **El bloque de efectivo**:
  - aparece también con `total_faltantes_empleados > 0`;
  - resta con `efectivoAEntregar(…, total_faltantes_empleados)`;
  - la línea de detalle suma el tramo `'{monto} de faltantes a cargo de empleados'`, sólo si hay.
- **La lista «Diferencia imputada»**: un renglón por línea viva, con `textoFaltante`. También en
  «Mis cobros», que es la misma tarjeta en `soloLectura`.
- **Los chips de gastos**: los de `gastosDeResolucion` llevan `'De la resolución de la diferencia'`.
- **`handleResolver` y `handleDeshacer`**:
  - pasan al modal lo que pide la Tarea 4;
  - al terminar bien invalidan `gastosKeys.todas()` y `personalKeys.all(sucursal)`, en
    `onSettled`/`finally`;
  - notifican `'Disconformidad resuelta'` y `'Resolución deshecha'`.
- **`ModalDeshacerResolucion`**:
  - lleva el texto de Global Constraints y «¿Por qué se deshace?», obligatorio;
  - su botón dice «Deshacer resolución»;
  - Enter no confirma.

- [ ] **Step 1: Tests:**
  - "el encargado ve 'La resuelve un admin' y no el botón";
  - "el admin ve Resolver y le pasa al modal a entregar, gastos y pagos";
  - "el admin ve Deshacer en una resuelta y en una con faltantes";
  - "deshacer manda el motivo e invalida gastos y personal";
  - "el efectivo resta los faltantes y lo dice en la línea";
  - "la lista de la diferencia sale también en Mis cobros";
  - "un gasto de la resolución lleva su marca";
  - "sin faltantes, todo queda como hoy";
  - del modal: "sin motivo no deja deshacer".
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.** Los tests de hoy que
  esperan «Resolver» para el encargado pasan a esperar el texto nuevo.
- [ ] **Step 3: Commit** `feat(rendiciones): sólo el admin resuelve, y se puede deshacer`.

---

### Task 6: Editar cierre y Personal con lo imputado

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/components/modals/ModalCerrarRendicion.tsx` y su test.
- Modify: `src/components/vistas/VistaRendiciones.tsx`, para pasar las props nuevas al cierre.
- Modify: `src/components/modals/ModalCuentaEmpleado.tsx` y su test (o el de `PersonalContainer`,
  donde vivan los de «Revertir»).

**Interfaces:**
- **Consumes**: `gastosDeResolucion`, `cambiosDelCierre` de cuatro argumentos y `efectivoAEntregar`.
- **Produces**: `ModalCerrarRendicionProps` suma `faltantes?: FaltanteDeRendicion[]` (`[]` por
  defecto) y `totalFaltantesEmpleados?: number` (0 por defecto).

**Comportamiento:**
- **En el cierre**:
  - congela `faltantesVisto = totalFaltantesEmpleados` al abrir y lo manda con `cambiosDelCierre`;
  - `aEntregar` lo resta;
  - suma la línea fija `'Faltantes a cargo de empleados: {monto}'` si es > 0, sin acciones;
  - los ítems cuyo `original.id` está en `gastosDeResolucion(faltantes)` salen sin «Editar» ni
    «Quitar», con la marca `'De la resolución de la diferencia'`. Siguen en `vistos`;
  - con `faltantes.length > 0`, «Disconformidad» queda deshabilitado con
    `'Deshacé la resolución primero'`.
- **En la cuenta del empleado**, un `faltante` sin reversión muestra `'Se deshace desde la
  rendición'` donde iría «Revertir». `sePuedeRevertir` ya lo deja afuera.

- [ ] **Step 1: Tests:**
  - "descuenta los faltantes del efectivo a entregar y muestra la línea";
  - "un gasto de la resolución no se edita ni se quita, y viaja en vistos";
  - "manda `faltantes_visto` congelado aunque llegue un refetch";
  - "con faltantes no deja elegir disconformidad";
  - "sin faltantes, el cierre queda como hoy";
  - de Personal: "un faltante dice que se deshace desde la rendición".
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(rendiciones): el cierre y la cuenta muestran lo imputado`.

---

### Task 7: Cierre — verificación, aplicación y PR

Lo hace la coordinadora, con el OK del dueño para aplicar.

- [ ] **Step 1: Juntar las ramas** con el OK del dueño, y traer `main` con
  `sync_with_base_branch`. Correr `npm run typecheck`, `npm run lint`, `npm run test:run` sin `.env`
  y `npm run build`: las cuatro en verde.
- [ ] **Step 2: Mirar la pantalla en un navegador de verdad.** Con `npm run dev` y las RPCs
  mockeadas, o con el dueño, confirmar que:
  - `ModalGasto` queda arriba del overlay de «Resolver»;
  - se puede tipear en los montos;
  - el Combobox de empleados abre adentro del modal.

  Si no hay sesión de prueba, se le pide al dueño y queda dicho en el PR.
- [ ] **Step 3: Ensayos acumulados en prod**, los de la Tarea 2, Step 4 → OK.
- [ ] **Step 4: Aplicar.** Con el OK del dueño, fuera del horario de cierre de rendiciones (9 h, 17 a
  18 h y 20 a 21 h):
  1. elegir el número con la trampa 3: el ledger, `origin/main`, las ramas abiertas y los worktrees;
  2. renombrar `NNN` en el archivo, en `rpcsSoloServidor.test.ts` y en los comentarios;
  3. aplicar con `apply_migration`, o desde el SQL Editor si pesa demasiado (#1332). Verificar
     `md5(replace(statements[1], chr(13), ''))` contra el `md5sum` del archivo en el índice
     (`git show :ruta | md5sum`);
  4. el PR va en borrador hasta acá. El bundle viejo sigue andando: resuelve con texto y no ve los
     faltantes. Igual se mergea enseguida: el admin con el bundle viejo resolvería sin poder
     imputar, y el encargado vería «Resolver» y recibiría el mensaje.

  Si un clasificador corta `apply_migration` o el ensayo, se para y se le avisa al dueño.
- [ ] **Step 5: Después de aplicar:**
  - `auditoria_grants_tablas()`, `auditoria_permisos_execute()`, `auditoria_definer_sin_rol()`,
    `auditoria_rpcs_definer()` y `auditoria_sucursal_cruzada()`: nada nuevo en rojo;
  - `auditoria_integridad()`, con los claims de un admin: igual que antes;
  - con la anon key, `POST /rest/v1/rpc/resolver_rendicion` da 42501, no `PGRST20x`;
  - `obtener_resumen_rendiciones` de los últimos 7 días anda y trae `total_faltantes_empleados` en 0;
  - existe el rubro «Faltantes de caja».
- [ ] **Step 6: PR** a `main`, con el título "Gastos 6: faltantes de rendición":
  - el cuerpo enlaza el spec, este plan y #1332;
  - dice que el encargado ya no resuelve disconformidades;
  - lleva la lista de pruebas para el dueño: resolver una de las dos de junio con «Robo o pérdida» o
    sólo con texto, y una con deuda cuando haya fichas en Taco Pozo.

  Después, un issue con los checks propuestos para #1330 (los invariantes del caso 20), y un
  comentario en #1332: la entrega 6 en prod, y lo que queda para las roturas.
