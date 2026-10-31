# Gastos, entrega 3 de 5: personal — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** El empleado existe en la app, con usuario o sin él, con su arreglo y su cuenta. La cuenta
registra sola la mercadería que se lleva con adelanto de sueldo y el reintegro del gasto que pagó
con su plata, y a mano los adelantos en efectivo y los ajustes. Personal se ve en tarjetas, cada
empleado tiene su ficha, y "Agregar gasto" del cierre precarga el vehículo habitual del chofer.

**Architecture:**
- **Tres tablas de server**: `empleados`, `empleado_arreglos` y `empleado_movimientos`. Tienen RLS
  sin policies y ningún privilegio para `authenticated` ni `anon`, como `pedido_promo_reglas`. Se
  leen y se escriben sólo por RPCs DEFINER, y la regla de quién ve a quién vive en un helper,
  `_empleado_visible`. Así un sueldo no sale nunca por REST, y no hay embeds nuevos que probar.
- **La cuenta es un libro.** El saldo es la suma de los movimientos, en vivo. Nada se edita ni se
  borra: un movimiento a mano se revierte con otro que apunta a él (`revierte_id`).
- **Los movimientos automáticos los concilia un trigger.** En `pagos` y en `gastos`, un trigger
  AFTER calcula cuánto tendría que haber en la cuenta por esa fila, lo compara con lo que ya hay y
  asienta la diferencia. Es la misma cuenta para un alta, un cambio de monto, un pedazo, un cambio
  de cliente o un borrado. Cubre todos los caminos que escriben pagos sin tocar ninguna función de
  cobro: las dos FIFO, las que parten un pago, `desafectar_sobrepago_pedido`,
  `cambiar_cliente_pedido`, el DELETE REST de `eliminarPago` y el INSERT REST que sigue vivo hasta
  #1246.
- **El rechazo del adelanto sin vínculo va en el mismo trigger de pagos.** No se tocan
  `registrar_pagos_pedido(_impl)` ni `_forma_pago_de_cobro`, que son de la tarjeta 2 de #1306.
- **`gastos.empleado_id`** habilita "Un empleado" en `_guardar_gasto`. Con
  `obtener_gastos_rendiciones` (ver la Tarea 2), son las dos funciones vivas que se reescriben,
  con guarda md5.

**Tech Stack:** React 19 + Vite + TanStack Query + Zod + vitest/testing-library; Supabase Postgres
(plpgsql, `migrations/`).

**Spec:** `docs/superpowers/specs/2026-10-28-gastos-y-cuentas-del-personal-design.md`. Para esta
entrega importan "Quién ve y hace qué", 1.4, 2 (vehículo habitual y quién lo usa), 3 (el
"Agregar gasto" del cierre), 4.1 a 4.4, 4.6, 5 y 7. El molde es el plan de la entrega 2,
`docs/superpowers/plans/2026-10-29-gastos-2-rendicion.md`. El contexto y los cruces están en el
issue #1332. Maqueta: `docs/superpowers/specs/2026-10-28-gastos-y-personal-maquetas.html`,
pestañas "Personal" y "Cuenta", y "Un empleado" en "Registrar gasto".

**Base de la rama:** `main` en `681afeba`, con las entregas 1 y 2 en prod (migs 411 a 413).

**Ejecución:** dos subsesiones, cada una en su worktree, cortadas de esta rama con el plan
commiteado:
- `gastos-3-sql` hace la Tarea 2 con Opus, esfuerzo high. Su nombre de turno es `gastos-3-sql`.
- `gastos-3-front` hace las Tareas 1 y 3 a 8 con Sonnet, esfuerzo high. Su nombre de turno es
  `gastos-3-front`.

La coordinadora (esta sesión) junta las ramas sólo con el OK del dueño, y después hace la Tarea 9.

## Lo que hay hoy (relevado en prod el 2026-10-29, sólo lectura)

- **Ledger:** la última es la 413, aplicada a las 19:37 UTC. `main` no cambió desde el #1331.
  - No hay PRs abiertos ni ramas sin mergear.
  - Las coordinadoras de #1306 y #1308 estaban corriendo sin tarjetas. Después del relevamiento,
    el mismo 29/10, lanzaron las tarjetas 1 a 4 de cada plan.
- **El adelanto de sueldo hoy:**
  - `formas_pago()` lo marca no dinerario, y `_forma_pago_de_cobro(forma, true)` lo rechaza. Por
    eso ya no lo aceptan `registrar_pagos_pedido`, los dos masivos ni `actualizar_forma_pago_pago`.
    Esta última tampoco cambia la forma de uno que ya es adelanto.
  - Entra por las dos FIFO de la ficha del cliente (`registrar_pago_cliente_fifo_impl` y
    `registrar_pago_combinado_cliente_fifo_impl`), que son de admin y encargado. El front las llama
    desde `ModalRegistrarPago` con `permitirAdelantoSueldo` (`ClientesContainer.tsx:636-647`).
  - También puede entrar por el INSERT REST que `authenticated` todavía tiene sobre `pagos`:
    `NNN_cobros_4_sin_insert_rest.sql`, de #1246, no está aplicada.
  - Los 8 históricos son los ids 5242 a 7777, del 01/09 al 24/10. Son de dos clientes de
    Tucumán, el 376 y el 9, y los cargó un admin. Ninguno tiene pedazos (`pago_origen_id`).
- **Cómo cambia un pago después de cargado:**
  - Se parte, en `aplicar_credito_cliente`, `imputar_credito_a_pedido_impl` y
    `_pagos_excedente_a_favor`: baja el monto de la fila y nace un pedazo con la misma forma y el
    mismo cliente, con `pago_origen_id = COALESCE(pago_origen_id, id)`.
  - `desafectar_sobrepago_pedido` lo baja o lo borra, y puede crear un pedazo.
  - `cambiar_cliente_pedido` le cambia el `cliente_id`.
  - `eliminarPago` lo borra por REST. Es sólo del admin, por `mt_pagos_delete`.
  - `pagos.id` es `integer`; `clientes.id` es `bigint`.
- **Gastos:**
  - `_guardar_gasto` (413, md5 `6056ce94ba972040a968111cb02af2f8`) rechaza `empleado` en el
    paso 8.
  - El CHECK `gastos_origen_pago_check` ya acepta `'empleado'`.
  - Hay 0 gastos y 0 vehículos.
- **Roles:**
  - El "admin de las dos" es `_tiene_todas_las_sucursales()` (DEFINER). `es_admin()` mira
    `perfiles.rol`.
  - Las sucursales activas son la 1, Tucumán, y la 2, Taco Pozo.
  - Hay 7 admins: 5 con Tucumán, 4 con Taco Pozo y 2 con las dos.
- **Auditoría:** `audit_log_changes()` va en todas las tablas de la 411.
- **Embeds:** PostgREST no toma como tabla puente una tabla cuyo PK es `id`: las FKs de un m2m
  tienen que ser parte del PK. Por eso las FKs de `empleados` a `perfiles`, `clientes` y
  `vehiculos` no vuelven ambiguo ningún embed que ya existe.

## Cruces y coordinación

- **#1306, tarjeta 2 (cobros):**
  - Esta entrega no toca ninguna de sus funciones: el rechazo va en un trigger nuevo.
  - Sí toca `ModalRegistrarPago`, con un prop y un aviso. La tarjeta arrancó el 29/10, después del
    relevamiento, y por #1293 cambia ese mismo bloque. Por eso esa parte de la Tarea 8 espera a que
    su PR entre a `main` y parte de su versión. Lo acordaron la tarjeta y su coordinadora.
  - La tarjeta 2 decidió #1293 así: `registrar_pagos_pedido` sigue sólo con plata, y el adelanto
    queda únicamente por el FIFO de la ficha. El modal deja de ofrecerlo cuando se elige una boleta.
    Es coherente con el trigger.
  - Antes de aplicar esta migración se le avisa a la coordinadora de #1306.
- **#1308, tarjeta 5 (#1322):** ver la decisión 1. Se le avisa a la coordinadora de #1308.
- **Rendición:** `confirmar_rendicion` y `resolver_rendicion` no se tocan; son de la tarjeta 7 de
  #1308 y de la 2 de #1306. `ModalCerrarRendicion` sí, sólo en el front.
- **Comisiones:** no se toca nada. #1320 se decide antes del plan de la entrega 4.
- **#1330:** los checks que propone esta entrega van ahí (decisión 6).
- **Después de esta entrega**, `_guardar_gasto` y los dos triggers nuevos son de Gastos. Una
  tarjeta que los toque parte del cuerpo vivo, con md5.

## Decisiones de este plan

Las propuso el diseñador del plan y el dueño las aprobó en chat el 2026-10-29 ("Sí, aprobadas").

1. **#1322 se reparte por archivos.**
   - Esta entrega arregla GAS-1, que vive en `_guardar_gasto` y `ModalGasto`, dos archivos que
     reescribe igual.
   - La tarjeta 5 de #1308 se queda con GAS-2 (`src/utils/vehiculos.ts`, que esta entrega no
     toca) y deja de esperar a Gastos.
   - El PR de esta entrega cierra #1322 (`Closes #1322`), porque entra después del de la tarjeta 5
     (#1352, con GAS-2, que dice "Part of #1322"). Así lo acordó la coordinadora de #1308 el 29/10.
   - La regla de GAS-1 en el server: en una edición, `litros` o `km_tablero` que no vienen en el
     JSON quedan como estaban, y un `null` explícito los borra. El modal manda esas dos claves sólo
     si el rubro las pide, y conoce el `pide_litros_km` de un rubro dado de baja por el embed.
   - *Alternativa:* esta entrega se queda con todo #1322.
2. **El rechazo del adelanto sin vínculo va en un trigger sobre `pagos`, no en las RPCs.** Cubre
   las FIFO, el REST y cualquier RPC que venga, y no pisa funciones de la tarjeta 2 de #1306. El
   modal avisa antes de mandar.
3. **"Nadie se paga a sí mismo" se extiende.** Sobre el empleado vinculado a su usuario nadie
   puede:
   - cargarle o revertirle movimientos;
   - cambiarle el arreglo;
   - darlo de baja o reactivarlo;
   - poner o sacar el vínculo de usuario.

   Sus otros datos sí los corrige. Tampoco carga ni edita un gasto que pagó ese empleado, porque el
   reintegro es plata a su favor: lo hace otro admin o el encargado. El spec nombraba sólo
   liquidar, pagar y los movimientos a mano.
4. **Arreglos:** uno nuevo vale desde después del último. Con la misma fecha que el último, lo
   corrige. No se borran.
5. **Revertir:** sólo los movimientos cargados a mano (adelanto, ajuste y saldo al empezar), una
   vez y con motivo. Los automáticos siguen a su pago o a su gasto.
6. **Auditoría:** esta migración no toca `auditoria_integridad()`, como pide #1308. Los checks van
   a #1330:
   - `EMP-A`: la mercadería de cada pago cuadra con su monto vivo;
   - `EMP-B`: el reintegro de cada gasto cuadra con el gasto.

   El ensayo los prueba igual. La entrega 2 sí parchó `GASTO-A`.
7. **Un pago con adelanto que cambia de cliente** (`cambiar_cliente_pedido`) se lleva el movimiento
   al empleado del cliente nuevo. Si el cliente nuevo no es la ficha de un empleado, se rechaza con
   un mensaje que pide anular el pago antes. Un empleado dado de baja ya no recibe adelantos.
8. **Al aplicar, el adelanto de sueldo se rechaza** hasta que des de alta a los empleados y
   vincules sus fichas de cliente; hoy son el 376 y el 9. Se usó 8 veces en dos meses.
9. **Filtros de Personal:**
   - Todos son los activos.
   - Con saldo son los de saldo distinto de 0, activos o no, porque el que se fue debiendo importa.
   - Inactivos son los dados de baja.

   El "Exportar" de la maqueta no entra.

## Global Constraints

- **`CLAUDE.md` de la raíz rige todo**, como en las entregas 1 y 2:
  - trampa 3: el número de migración se elige al aplicar;
  - trampa 5: los parámetros de RPC van en `INTEGER` o `BIGINT`, nunca en `SMALLINT`;
  - funciones nuevas con `REVOKE … FROM PUBLIC, anon`; las de server, además `authenticated`;
  - el día es el argentino: `_tablero_hoy()` en SQL, `America/Argentina/Tucuman` en el front;
  - toda lectura nueva de `clientes` decide qué hace con los inactivos: el buscador de la ficha
    del empleado los muestra.
- **Verificación**: antes de cerrar una tarea con front se corren `npm run typecheck`,
  `npm run lint`, `npm run test:run` (sin `.env`) y `npm run build`. El pre-commit corre la suite
  entera; nunca `--no-verify`. `test:run`, `build` y `git commit` van con el turno de
  `refs/turno/pesado` (#1332, "Cómo se trabajó", punto 3).
- **Migración**: `migrations/NNN_gastos_4_personal.sql`, con NNN literal.
  - **Nadie aplica**: la coordinadora aplica con el OK del dueño.
  - En prod (proyecto `hmuchlzmuqqxcldbzkgc`, `execute_sql`) se corren sólo SELECTs, el ensayo
    solo y el acumulado `BEGIN; SET LOCAL lock_timeout='5s'; <mig>; <ensayo>; ROLLBACK;`.
  - El veredicto del ensayo va en el `RAISE EXCEPTION` final: un `NOTICE` no vuelve por
    `execute_sql`. El acumulado lo manda la coordinadora, no un subagente.
- **Ensayos**: el molde es `scripts/test-gastos-3.sql`: un `DO $ensayo$`, canarios con ERRCODE
  `P0099` y cierre `ENSAYO OK` o `ENSAYO FALLÓ`.
  - Cada RPC se llama como el front: `SET LOCAL ROLE authenticated`, `request.jwt.claims` y
    `request.headers` con `x-sucursal-id`.
  - Los usuarios se eligen en runtime desde `perfiles` y `usuario_sucursales`:
    - `A1`, un admin con sólo Tucumán;
    - `AT`, un admin con sólo Taco Pozo;
    - `AD`, un admin de las dos;
    - `EN`, el encargado;
    - `TR`, un transportista.
- **Funciones**:
  - Las RPCs del front llevan `SECURITY DEFINER SET search_path = public`,
    `REVOKE ALL … FROM PUBLIC, anon` y `GRANT EXECUTE … TO authenticated, service_role`. Cada una
    nombra `es_admin()` o `es_encargado_o_admin()`, porque SEG-A busca un helper de rol en el
    texto.
  - Los helpers de server llevan `REVOKE ALL … FROM PUBLIC, anon, authenticated` y
    `GRANT EXECUTE … TO service_role`. Las funciones de trigger llevan el mismo `REVOKE` y ningún
    `GRANT`.
- **Tablas nuevas**:
  - `ENABLE ROW LEVEL SECURITY`, sin policies;
  - `REVOKE ALL … FROM PUBLIC, anon, authenticated`, también el SELECT: así no queda rojo
    `select_sin_policy`;
  - sin `GRANT` de secuencias;
  - `scripts/grants-rest.json` no cambia;
  - `audit_log_changes()` en `empleados` y `empleado_arreglos`.
- **Mensajes del server** (`RAISE EXCEPTION`, llegan en `error.message`):
  - Rol y visibilidad:
    - `'Sólo un admin ve y carga el personal'`
    - `'Ese empleado no existe o no lo podés ver'`
  - La ficha:
    - `'Hay un dato del empleado con un formato inválido'`
    - `'Falta el nombre y apellido'`
    - `'Elegí el puesto'`
    - `'No tenés asignada esa sucursal: el empleado va en una de tus sucursales'`
    - `'Sólo un admin de todas las sucursales carga un empleado de las dos'`
    - `'La sucursal y «las dos» sólo las cambia un admin de todas las sucursales'`
    - `'El CUIL tiene que tener 11 números'`
  - Los vínculos:
    - `'Ese usuario ya está vinculado a otro empleado'`
    - `'Ese usuario no tiene asignada la sucursal del empleado'`
    - `'Esa ficha de cliente ya está vinculada a otro empleado'`
    - `'El cliente tiene que ser de la sucursal del empleado'`
    - `'El vehículo no es de la sucursal del empleado o está dado de baja'`
  - Uno mismo:
    - `'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos'`
    - `'Un gasto que pagaste vos lo carga otro admin o el encargado'`
  - El arreglo:
    - `'Falta el primer arreglo: el sueldo, cada cuánto y desde cuándo se liquida'`
    - `'El sueldo no puede ser negativo'`
    - `'Un arreglo sin sueldo fijo tiene que comisionar'`
    - `'El sueldo es semanal o mensual'`
    - `'Un arreglo nuevo vale desde después del vigente (%): para corregir el vigente usá su misma fecha'`,
      con la fecha en `dd/mm/aaaa`
    - `'Ese empleado está dado de baja: reactivalo para cambiarle el arreglo'`
  - La baja:
    - `'La baja no puede ser de un día que todavía no llegó'`
    - `'La baja no puede ser antes de que empiece su primer arreglo'`
    - `'Ese empleado ya está dado de baja'`
    - `'Ese empleado ya está activo'`
  - Los movimientos a mano:
    - `'Un movimiento a mano es un adelanto en efectivo o un ajuste'`
    - `'El monto tiene que ser mayor a cero'`
    - `'El ajuste no puede ser cero'`
    - `'El ajuste necesita una observación que diga por qué'`
    - `'La fecha del movimiento no puede ser futura'`
  - Revertir:
    - `'Sólo se revierte un movimiento cargado a mano'`
    - `'Un movimiento que revierte a otro no se revierte: cargá uno nuevo'`
    - `'Ese movimiento ya está revertido'`
    - `'Escribí por qué se revierte'`
  - El adelanto de sueldo (trigger de pagos):
    - `'El adelanto de sueldo es sólo para la ficha de cliente de un empleado: vinculala desde Personal o elegí otra forma de pago'`
    - `'Ese cliente es la ficha de un empleado dado de baja: ya no se le dan adelantos de sueldo'`
    - `'Este pago es un adelanto de sueldo y el cliente nuevo no es la ficha de un empleado: anulá el pago antes de cambiar el cliente'`
  - El gasto pagado por un empleado:
    - `'Elegí qué empleado pagó el gasto'`
    - `'Ese empleado no es de la sucursal del gasto'`
    - `'Ese empleado está dado de baja'`
  - La observación de los movimientos automáticos, en `empleado_movimientos.observacion`. El
    primero de cada pago o gasto va en NULL. Los que lo corrigen:
    - de un pago: `'El pago cambió de monto'`, `'Se borró el pago'`,
      `'El pago pasó a otro cliente'`;
    - de un gasto: `'El gasto cambió de monto'`, `'Se anuló el gasto'`,
      `'El gasto pasó a otro empleado'`, `'El gasto dejó de estar pagado por un empleado'`.
  - El saldo al empezar es un ajuste con la observación `'Saldo al empezar'`.
- **Textos del front**: van en cada tarea, copiados de la maqueta. Plata con `formatPrecio`, y
  fechas `dd/mm/aaaa` con `formatFecha` (`src/utils/formatters.ts`). En los tests, un monto se
  compara contra `formatPrecio(x)`: `Intl` mete un espacio duro después del `$`.
- **Colores del saldo**: positivo es "a su favor" (verde, `emerald-700`); negativo es "debe"
  (rojo, `rose-700`); cero, gris. Es al revés que en Clientes, donde positivo es deuda.
- **Permisos.** Los valida el server; el front sólo esconde.
  - Personal es sólo del admin: ruta, menú y RPCs.
  - El encargado ve los nombres, sin sueldos, para elegir "Un empleado" en un gasto. Los ve el
    cierre para el vehículo habitual, y la ficha de pago para saber si el cliente es un empleado.
  - El empleado propio (`es_propio`): ver la decisión 3.
- **Modelo por tarea**: la migración con **Opus**, esfuerzo high. El front con **Sonnet**, esfuerzo
  high; si el review encuentra lógica floja en una tarea, se repite esa con Opus.

## Review Focus

1. **Un pago con adelanto que se parte o baja** (una salvedad, un crédito que se imputa en parte, un
   excedente que queda a favor). La cuenta tiene que reflejar lo vivo: ni descuento doble ni
   descuento perdido. Lo cubre el caso 5 del ensayo de la Tarea 2.
2. **Los 8 adelantos históricos** no entran nunca, ni con su cliente vinculado, ni si se les
   cambia el monto, se borran o se parten. Caso 6 del ensayo.
3. **Mostrar de más**:
   - un admin de una sola sucursal no ve gente de la otra ni a la "de las dos";
   - el encargado no ve un sueldo por ningún camino (las tablas, `listar_personal`,
     `empleados_para_elegir`).

   Casos 1 y 13 del ensayo, y los tests de ruta y menú de la Tarea 4.
4. **Nadie se carga plata a sí mismo**: ni un movimiento, ni un arreglo, ni el vínculo, ni la baja,
   ni un gasto que pagó él. Caso 3 del ensayo, y los botones escondidos de las Tareas 4, 6 y 7.
5. **Un gasto de "un empleado"** que se edita, cambia de empleado, pasa a la oficina o se anula deja
   el reintegro exacto (caso 8). Editar una carga de un rubro dado de baja no le borra los litros
   ni el km (caso 12 y el test de GAS-1 de la Tarea 7).

---

### Task 1: Tipos y reglas puras de Personal

Modelo: Sonnet, esfuerzo high.

**Files:**
- Create: `src/types/personal.ts`, `src/utils/personal.ts` y `src/utils/personal.test.ts`.
- Modify: `src/types/index.ts`, que suma `export * from './personal'`.

**Interfaces (Produces):**
- **`src/types/personal.ts`**, con los ids como `number`, salvo el del usuario:
  ```ts
  export type PuestoEmpleado = 'preventista' | 'transportista' | 'ayudante' | 'deposito' | 'administracion' | 'encargado' | 'otro'
  export type FrecuenciaSueldo = 'semanal' | 'mensual'
  export type TipoMovimientoEmpleado = 'mercaderia' | 'reintegro' | 'adelanto' | 'ajuste'
  export type FiltroPersonal = 'todos' | 'con_saldo' | 'inactivos'
  export interface ArregloEmpleado { id: number; vigente_desde: string; vigente_hasta: string | null; sueldo: number; frecuencia: FrecuenciaSueldo; comisiona: boolean }
  export interface Empleado {
    id: number; nombre: string; puesto: PuestoEmpleado; sucursal_id: number; de_las_dos: boolean
    cuil: string | null; fecha_ingreso: string | null; telefono: string | null
    activo: boolean; fecha_baja: string | null
    usuario: { id: string; nombre: string } | null
    cliente: { id: number; nombre_fantasia: string; activo: boolean } | null
    vehiculo: { id: number; patente: string; descripcion: string } | null
    arreglo: ArregloEmpleado | null   // el vigente hoy, o el primero si todavía no empezó
    arranque: string | null           // vigente_desde del primer arreglo
    saldo: number
    es_propio: boolean                // usuario.id = el que mira
  }
  export interface MovimientoEmpleado {
    id: number; fecha: string; tipo: TipoMovimientoEmpleado; monto: number
    saldo: number                     // acumulado, por (fecha, id)
    observacion: string | null; pago_id: number | null; pedido_id: number | null
    gasto: { id: number; rubro: string; vehiculo: string | null } | null
    revierte_id: number | null; revertido: boolean
    creado_por_nombre: string | null; created_at: string
  }
  export interface CuentaEmpleado { empleado: Empleado; arreglos: ArregloEmpleado[]; movimientos: MovimientoEmpleado[] }
  export interface EmpleadoParaElegir { id: number; nombre: string; usuario_id: string | null; vehiculo_id: number | null; activo: boolean }
  export interface GuardarArregloPayload { vigente_desde: string; sueldo: number; frecuencia: FrecuenciaSueldo; comisiona: boolean }
  export interface GuardarEmpleadoPayload {
    id?: number; nombre: string; puesto: PuestoEmpleado; sucursal_id: number; de_las_dos: boolean
    cuil: string | null; fecha_ingreso: string | null; telefono: string | null
    usuario_id: string | null; cliente_id: number | null; vehiculo_id: number | null
    arreglo?: GuardarArregloPayload   // sólo en el alta
    saldo_inicial?: number | null     // sólo en el alta; + a su favor, − debe
  }
  export interface MovimientoManualPayload { tipo: 'adelanto' | 'ajuste'; monto: number; fecha: string; observacion: string | null }
  ```
  En `MovimientoManualPayload`, el adelanto va positivo (el server lo guarda negativo) y el ajuste
  con su signo.
- **`src/utils/personal.ts`**:
  - `PUESTOS: ReadonlyArray<{ valor: PuestoEmpleado; etiqueta: string }>`, en el orden Preventista,
    Transportista, Ayudante, Depósito, Administración, Encargado, Otro.
  - `etiquetaPuesto(p: PuestoEmpleado): string`.
  - `inicioDelPeriodo(fecha: string, frecuencia: FrecuenciaSueldo): string`: el lunes de esa
    semana, o el día 1 de ese mes. La aritmética es de calendario sobre `YYYY-MM-DD`, sin zona.
  - `textoArregloCorto(a: Pick<ArregloEmpleado, 'sueldo' | 'frecuencia' | 'comisiona'>): string`:
    `'Semanal · {sueldo} + comisión'`, `'Mensual · {sueldo}'` o `'Semanal · sólo comisión'`.
  - `textoArregloLargo(a: ArregloEmpleado): string`:
    `'{sueldo} por semana · no comisiona · desde el {dd/mm/aaaa}'`, o `por mes` y `comisiona`.
  - `textoArregloAnterior(a: ArregloEmpleado): string`:
    `'Antes: {sueldo} por semana, del {desde} al {hasta}'`.
  - `estadoSaldo(saldo: number): 'a_favor' | 'debe' | 'al_dia'`. Si `|saldo| < 0.005`, es
    `'al_dia'`.
  - `conceptoDeMovimiento(m: MovimientoEmpleado): { titulo: string; detalle: string | null }`:
    - **títulos**:
      - `'Mercadería'`;
      - `'Reintegro de gasto'`;
      - `'Adelanto en efectivo'`;
      - `'Ajuste a favor'` o `'Ajuste en contra'`, según el signo;
      - con `revierte_id`, `'Revierte un adelanto en efectivo'` o `'Revierte un ajuste'`.
    - **detalle**: la `observacion` si hay. Si no:
      - mercadería: `'Pedido #{pedido_id} · pagado con adelanto de sueldo'`, o
        `'Pago a cuenta · pagado con adelanto de sueldo'` sin pedido;
      - reintegro: `'{rubro} {vehículo} · pagó con plata propia'`, sin el tramo del vehículo si no
        hay.
  - `filtrarPersonal(empleados: Empleado[], filtro: FiltroPersonal, busqueda: string): Empleado[]`:
    - busca sin tildes (`normalizeSearch`) en el nombre, el puesto, el usuario, el cliente y la
      patente;
    - ordena por nombre con `localeCompare('es')`;
    - los filtros son los de la decisión 9.
  - `contarPersonal(empleados: Empleado[]): Record<FiltroPersonal, number>`.
  - `normalizarCuil(texto: string): string | null`: deja los dígitos, o `null` si queda vacío.
  - `formatCuil(cuil: string): string`: `'20301234567'` da `'20-30123456-7'`.
  - `errorDeArreglo(a: GuardarArregloPayload, vigente: ArregloEmpleado | null): string | null`:
    los mensajes del server, salvo el de la baja. `vigente` es el último arreglo.
  - `errorDeMovimiento(m: MovimientoManualPayload, hoy: string): string | null`: los mensajes del
    server.

- [ ] **Step 1: Tests**, con estos valores:
  - `inicioDelPeriodo`:
    - `('2026-10-29', 'semanal')` y `('2026-11-01', 'semanal')` dan `'2026-10-26'`; la segunda es
      un domingo;
    - `('2026-10-26', 'semanal')` da `'2026-10-26'`;
    - `('2026-10-29', 'mensual')` da `'2026-10-01'`;
    - `('2026-03-01', 'semanal')` da `'2026-02-23'`.
  - `textoArregloCorto({ sueldo: 150000, frecuencia: 'semanal', comisiona: true })` es
    `` `Semanal · ${formatPrecio(150000)} + comisión` ``. Sin sueldo, con comisión, da
    `'Semanal · sólo comisión'`.
  - `textoArregloLargo` de 280000 semanal, sin comisión, desde `'2026-10-01'` da
    `` `${formatPrecio(280000)} por semana · no comisiona · desde el 01/10/2026` ``.
  - `textoArregloAnterior` de 250000 semanal, del `'2025-02-03'` al `'2026-09-30'`, da
    `` `Antes: ${formatPrecio(250000)} por semana, del 03/02/2025 al 30/09/2026` ``.
  - `estadoSaldo`: `13500` es `'a_favor'`, `-1` es `'debe'` y `0.004` es `'al_dia'`.
  - `conceptoDeMovimiento`:
    - una mercadería del pedido 8840, sin observación, da
      `{ titulo: 'Mercadería', detalle: 'Pedido #8840 · pagado con adelanto de sueldo' }`;
    - la misma con `'El pago cambió de monto'` da ese detalle;
    - un reintegro de Combustible con vehículo `'Partner AC456EF'` da
      `'Combustible Partner AC456EF · pagó con plata propia'`;
    - un ajuste de −3000 es `'Ajuste en contra'`;
    - una reversión de un adelanto es `'Revierte un adelanto en efectivo'`.
  - `filtrarPersonal` con cuatro empleados: activo con saldo 0, activo con −5000, inactivo con
    2000 e inactivo con 0.
    - `'todos'` da los dos activos;
    - `'con_saldo'` da el de −5000 y el inactivo de 2000;
    - `'inactivos'` da los dos inactivos;
    - `'rios'` encuentra a "Pablo Ríos";
    - `'ac456'` encuentra al de esa patente.
  - `formatCuil('20301234567') === '20-30123456-7'` y `normalizarCuil(' 20-30123456-7 ') === '20301234567'`.
  - `errorDeArreglo`:
    - con el vigente desde `'2026-10-26'`, una fecha `'2026-10-19'` da el mensaje con `26/10/2026`;
    - `'2026-10-26'` da `null`, porque corrige;
    - sueldo 0 sin comisión da `'Un arreglo sin sueldo fijo tiene que comisionar'`.
  - `errorDeMovimiento`:
    - un ajuste sin observación da su mensaje;
    - un adelanto de 0 da `'El monto tiene que ser mayor a cero'`;
    - una fecha mañana da `'La fecha del movimiento no puede ser futura'`.
- [ ] **Step 2: Ver que fallan.** `npx vitest run src/utils/personal.test.ts`
- [ ] **Step 3: Implementar; pasar; typecheck y lint.**
- [ ] **Step 4: Commit** `feat(personal): tipos y reglas puras de la cuenta del empleado`.

---

### Task 2: Migración — personal, cuenta y movimientos automáticos

Modelo: Opus, esfuerzo high. Crea tablas y triggers sobre `pagos` y `gastos`, y reescribe
`_guardar_gasto`. Antes de escribir, leer `migrations/CLAUDE.md` y el `CLAUDE.md` de la raíz.

**Files:**
- Create: `migrations/NNN_gastos_4_personal.sql` y `scripts/test-gastos-4.sql`.
- Modify: `scripts/test-gastos-1.sql` (cerca de la línea 544) y `scripts/test-gastos-3.sql` (cerca
  de la 415). El caso de `origen_pago: 'empleado'` sin `empleado_id` ahora espera
  `'Elegí qué empleado pagó el gasto'`.
- Modify: `src/test/rpcsSoloServidor.test.ts`. Suma con `'NNN_gastos_4'` los helpers
  `_empleado_visible`, `_empleado_json` y `_cuenta_empleado_conciliar`, y las funciones de trigger
  `pagos_cuenta_empleado` y `gastos_cuenta_empleado`.

**Interfaces (Produces):**

**Guarda `$vivas$`**: el md5 de `_guardar_gasto(jsonb,boolean)` es
`6056ce94ba972040a968111cb02af2f8`, con el molde de la 413.

**`empleados`**:
- `id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`;
- `sucursal_id bigint NOT NULL REFERENCES sucursales(id)`, la sucursal donde se cargó;
- `de_las_dos boolean NOT NULL DEFAULT false`;
- `nombre text NOT NULL`, con `CHECK (btrim(nombre) <> '')`;
- `puesto text NOT NULL`, con `CHECK` sobre los siete valores de `PuestoEmpleado`;
- `cuil text`, con `CHECK (cuil ~ '^[0-9]{11}$')`;
- `fecha_ingreso date` y `telefono text`;
- `usuario_id uuid UNIQUE REFERENCES perfiles(id)`;
- `cliente_id bigint UNIQUE REFERENCES clientes(id)`;
- `vehiculo_id bigint REFERENCES vehiculos(id)`;
- `activo boolean NOT NULL DEFAULT true` y `fecha_baja date`, con
  `CHECK (activo = (fecha_baja IS NULL))`;
- `creado_por uuid NOT NULL`, `created_at` y `updated_at timestamptz NOT NULL DEFAULT now()`.

Las FKs a `clientes` y `vehiculos` son simples, no compuestas: un empleado "de las dos" se vincula
a un cliente de cualquier sucursal. La regla la valida la RPC.

**`empleado_arreglos`**:
- `id` identity y `empleado_id bigint NOT NULL REFERENCES empleados(id)`;
- `vigente_desde date NOT NULL`;
- `sueldo numeric(12,2) NOT NULL CHECK (sueldo >= 0)`;
- `frecuencia text NOT NULL CHECK (frecuencia IN ('semanal','mensual'))`;
- `comisiona boolean NOT NULL`, con `CHECK (sueldo > 0 OR comisiona)`;
- `UNIQUE (empleado_id, vigente_desde)`;
- `creado_por`, `created_at` y `updated_at`.

**`empleado_movimientos`**:
- `id` identity y `empleado_id bigint NOT NULL REFERENCES empleados(id)`;
- `fecha date NOT NULL`;
- `tipo text NOT NULL CHECK (tipo IN ('mercaderia','reintegro','adelanto','ajuste'))`;
- `monto numeric(12,2) NOT NULL CHECK (monto <> 0)`;
- `observacion text`;
- `pago_id bigint` y `pedido_id bigint`, **sin FK**: el pago se puede borrar y el movimiento
  queda. `pedido_id` es la foto del pago al asentar;
- `gasto_id bigint REFERENCES gastos(id)`;
- `revierte_id bigint UNIQUE REFERENCES empleado_movimientos(id)`;
- `creado_por uuid` (NULL desde service_role) y `created_at`.
- CHECKs:
  - `(tipo = 'mercaderia') = (pago_id IS NOT NULL)`;
  - `(tipo = 'reintegro') = (gasto_id IS NOT NULL)`;
  - `revierte_id IS NULL OR tipo IN ('adelanto','ajuste')`;
  - `tipo <> 'adelanto' OR revierte_id IS NOT NULL OR monto < 0`;
  - `tipo <> 'ajuste' OR observacion IS NOT NULL`.
- Índices: `(empleado_id, fecha, id)`, `(pago_id) WHERE pago_id IS NOT NULL` y
  `(gasto_id) WHERE gasto_id IS NOT NULL`.

**`gastos`**:
- suma `empleado_id bigint REFERENCES empleados(id)`;
- `CHECK gastos_empleado_check ((origen_pago = 'empleado') = (empleado_id IS NOT NULL))`;
- índice `(empleado_id) WHERE origen_pago = 'empleado'`;
- un `COMMENT` en la columna, y el de `origen_pago` dice que "empleado" se habilita en gastos 4.

Un `COMMENT` en cada tabla nueva dice para qué es y que es sólo de server.

**Helpers de server:**
- **`_empleado_visible(p_sucursal_id bigint, p_de_las_dos boolean) RETURNS boolean STABLE`**:
  `es_admin() AND CASE WHEN p_de_las_dos THEN _tiene_todas_las_sucursales() ELSE p_sucursal_id = current_sucursal_id() END`.
- **`_empleado_json(p_e empleados) RETURNS jsonb STABLE`**: la forma de `Empleado` de la Tarea 1.
  - El `arreglo` es el de mayor `vigente_desde <= _tablero_hoy()`, o el primero si ninguno empezó.
  - `saldo` es la suma de los movimientos, y `es_propio` es `usuario_id = auth.uid()`.
  - `usuario`, `cliente` y `vehiculo` salen de sus tablas; el cliente lleva su `activo`.
- **`_cuenta_empleado_conciliar(p_tipo text, p_pago_id bigint, p_gasto_id bigint, p_empleado_id bigint, p_objetivo numeric, p_fecha date, p_pedido_id bigint, p_motivo text) RETURNS void`**:
  - **Fuente**: el pago si el tipo es `mercaderia`, o el gasto si es `reintegro`.
  - **Por empleado**: por cada empleado con movimientos de esa fuente, más `p_empleado_id`:
    - el objetivo es `p_objetivo` para `p_empleado_id` y 0 para los otros;
    - si la suma de lo que ya tiene difiere del objetivo, inserta la diferencia.
  - **Fecha**: si la fuente no tenía ningún movimiento, va `p_fecha` y `observacion` NULL. Si no,
    va `_tablero_hoy()` y `p_motivo`.
  - `creado_por` es `auth.uid()`.

> **Corregido después de las revisiones (29 y 30/10).** Manda la migración, y su cabecera tiene el
> detalle. La regla de abajo para un pedazo nuevo estaba mal: seguía al empleado de la raíz, y un
> pedazo de un pago que había cambiado de cliente se asentaba al empleado equivocado. Lo que quedó:
> - cada asiento de mercadería guarda la foto `pago_raiz_id` y `cliente_id`;
> - un pedazo nuevo toma al empleado con neto distinto de cero en los pagos vivos de su familia y
>   de su mismo cliente. Si no hay, usa la foto de los asientos, y si tampoco, el vinculado hoy;
> - no hay lock por raíz: el lock de fila de cada pago alcanza, y evita un deadlock con las
>   funciones de cobro;
> - se rechaza el DELETE REST de un adelanto de la ficha propia. Lo demás sobre un pedido propio
>   es el límite conocido de #1354;
> - la 424 sacó el INSERT REST de `pagos`, así que la migración no lo contempla.
>
> Cambiaron también estas reglas de la Tarea 2:
> - `empleados_para_elegir` usa el mismo filtro para admin y encargado:
>   `sucursal_id = current_sucursal_id() OR de_las_dos`. Son sólo nombres;
> - `guardar_empleado` acepta un vehículo de cualquier sucursal para un empleado "de las dos";
> - la baja tiene como piso `LEAST(arranque, _tablero_hoy())`;
> - en `_guardar_gasto`, la sucursal del empleado se mira sólo si el empleado cambió;
> - `obtener_gastos_rendiciones` devuelve `rubro.pide_litros_km`, y es la segunda función viva que
>   la migración reescribe, con guarda md5;
> - `empleado_movimientos.monto` es `numeric(14,2)`, y el saldo al empezar nunca lleva fecha futura.

**`pagos_cuenta_empleado()`**: trigger `trg_pagos_cuenta_empleado`, `AFTER INSERT OR DELETE OR
UPDATE OF monto, cliente_id, forma_pago, pago_origen_id ON pagos FOR EACH ROW`, SECURITY DEFINER.
Sea R la raíz, `COALESCE(pago_origen_id, id)` de la fila (NEW, u OLD en el DELETE):
1. `pg_advisory_xact_lock(hashtextextended('cuenta_empleado|pago|' || R, 0))`: serializa los
   pedazos de un mismo pago.
2. **Entra al libro** si es el INSERT de una raíz (`pago_origen_id IS NULL`) con
   `forma_pago = 'adelanto_sueldo'`, o si la fila o su raíz ya tienen movimientos. Si no entra, no
   hace nada. Así los 8 históricos, sus pedazos y todo lo cargado antes de la migración quedan
   afuera, sin un corte por id.
3. **El empleado**, que se busca así:
   - **sin cambio de cliente**: con movimientos propios en un UPDATE o un DELETE, es el de esos
     movimientos. Así no lo mueve un cambio posterior del vínculo;
   - **pedazo sin movimientos propios**: el empleado de los movimientos de la raíz;
   - **raíz nueva o cliente cambiado**: el empleado con `cliente_id = NEW.cliente_id`. Si no hay y
     es adelanto, se rechaza: con el primer mensaje del adelanto en una raíz, y con el del cambio
     de cliente si cambió. Si está dado de baja, el mensaje de la baja.
4. **El objetivo** es 0 en un DELETE o si ya no es adelanto. Si no, es `−NEW.monto`.
5. **Concilia** con `_cuenta_empleado_conciliar('mercaderia', id, NULL, empleado, objetivo, NEW.fecha, NEW.pedido_id, motivo)`.
   El motivo sale de qué cambió: el monto, el borrado o el cliente. Son los textos de Global
   Constraints.

**`gastos_cuenta_empleado()`**: trigger `trg_gastos_cuenta_empleado`, `AFTER INSERT OR UPDATE OF
monto_total, origen_pago, empleado_id, anulado_at ON gastos FOR EACH ROW`, SECURITY DEFINER.
- **Objetivo**: `+monto_total` para `empleado_id` si `origen_pago = 'empleado'` y no está anulado.
  Si no, 0.
- **Concilia** con `_cuenta_empleado_conciliar('reintegro', NULL, id, …, NEW.fecha, NULL, motivo)`.
- **Motivo**, por orden de prioridad: anulado, dejó de ser de un empleado, cambió de empleado,
  cambió de monto.

**`_guardar_gasto(p_gasto jsonb, p_desde_cierre boolean)`**: el cuerpo vivo de la 413, con estos
cambios:
- En el bloque de formato lee `v_emp := NULLIF(p_gasto->>'empleado_id','')::bigint`.
- **GAS-1** (decisión 1), antes del paso 6:
  - en una edición, si `NOT p_gasto ? 'litros'`, `v_litros` es `v_viejo.litros`;
  - si `NOT p_gasto ? 'km_tablero'`, la lectura de `vehiculo_km` del gasto no se toca, salvo que
    siga al vehículo y a la fecha del gasto si cambiaron;
  - en el alta, la clave ausente es NULL, como hoy.
- **Paso 8, rama `empleado`**, en este orden:
  1. `v_emp` tiene que venir;
  2. el empleado existe;
  3. `sucursal_id = v_suc OR de_las_dos`;
  4. está activo, o es el mismo que tenía el gasto;
  5. ni el empleado nuevo ni el viejo tienen `usuario_id = v_uid`: es el mensaje de "Un gasto que
     pagaste vos".

  Las ramas `oficina` y `rendicion` ponen `v_emp` en NULL.
- El `INSERT` y el `UPDATE` escriben `empleado_id`.
- `_anular_gasto` no cambia: el trigger compensa la anulación.

**RPCs del front:**
- **`listar_personal() RETURNS jsonb`** (STABLE): con `es_admin()`, o 42501 con
  `'Sólo un admin ve y carga el personal'`. Devuelve el array de `_empleado_json` de los visibles,
  por nombre, o `'[]'`.
- **`obtener_cuenta_empleado(p_empleado_id bigint) RETURNS jsonb`** (STABLE): con `es_admin()` y
  visible. Devuelve `{ empleado, arreglos, movimientos }`:
  - `arreglos` va de más nuevo a más viejo, con `vigente_hasta` igual al `vigente_desde` del
    siguiente menos un día;
  - `movimientos` va por `fecha DESC, id DESC`. Cada uno lleva su `saldo` acumulado por
    `(fecha, id)` y `revertido`. El gasto va como `{id, rubro: nombre, vehiculo: 'descripcion patente'}`.
    `creado_por_nombre` sale de `perfiles`.
- **`empleados_para_elegir() RETURNS jsonb`** (STABLE): con `es_encargado_o_admin()`.
  - El admin ve los visibles; el encargado, los de `current_sucursal_id()` y los "de las dos".
  - Devuelve sólo `{id, nombre, usuario_id, vehiculo_id, activo}`, activos e inactivos, por nombre.
- **`cliente_admite_adelanto_sueldo(p_cliente_id bigint) RETURNS boolean`** (STABLE): con
  `es_encargado_o_admin()`. Dice si hay un empleado activo con ese `cliente_id`.
- **`guardar_empleado(p_empleado jsonb) RETURNS bigint`**: alta sin `id`, edición con `id`.
  1. Rol y formato.
  2. En una edición, la fila `FOR UPDATE` y visible.
  3. **Sucursal**:
     - va en una sucursal activa que el admin tiene asignada;
     - `de_las_dos` pide `_tiene_todas_las_sucursales()`;
     - en una edición, cambiar `sucursal_id` o `de_las_dos` también.
  4. Nombre, puesto y CUIL normalizado a dígitos.
  5. **Uno mismo**: no se puede dar de alta con `usuario_id = auth.uid()`, ni cambiar el vínculo
     de usuario de un empleado propio.
  6. **Vínculos**:
     - el usuario tiene asignada la sucursal del empleado, o cualquiera si es "de las dos";
     - el cliente es de esa sucursal, salvo un empleado "de las dos";
     - el vehículo es de esa sucursal y activo, o el mismo que tenía.

     La unicidad se lee antes, para dar el mensaje propio y no el `23505`.
  7. **Alta**: el `arreglo` es obligatorio y se valida como en `guardar_arreglo_empleado`. Un
     `saldo_inicial` distinto de 0 entra como ajuste con `'Saldo al empezar'` y la fecha del
     arreglo.
  8. `INSERT` o `UPDATE` con `updated_at = now()`. Una edición ignora `arreglo` y `saldo_inicial`.
- **`guardar_arreglo_empleado(p_empleado_id bigint, p_arreglo jsonb) RETURNS bigint`**:
  - con rol, visible, no propio y activo;
  - la fila del empleado `FOR UPDATE`;
  - con una fecha posterior al último arreglo, `INSERT`;
  - con la misma fecha, `UPDATE` de ese arreglo;
  - con una anterior, el mensaje con la fecha del vigente.
- **`dar_de_baja_empleado(p_empleado_id bigint, p_fecha date) RETURNS void`** y
  **`reactivar_empleado(p_empleado_id bigint) RETURNS void`**: con rol, visible y no propio. La
  fecha de baja no es futura ni anterior al primer arreglo.
- **`registrar_movimiento_empleado(p_empleado_id bigint, p_movimiento jsonb) RETURNS bigint`**:
  - con rol, visible y no propio; un empleado inactivo también recibe movimientos;
  - `tipo` es `adelanto` o `ajuste`;
  - el adelanto tiene que ser > 0 y se guarda negativo;
  - el ajuste, distinto de 0 y con observación;
  - la fecha es hoy por defecto, y nunca futura.
- **`revertir_movimiento_empleado(p_movimiento_id bigint, p_motivo text) RETURNS bigint`**:
  - con rol, visible y no propio;
  - sólo para `adelanto` o `ajuste`, que no sean ya una reversión ni estén revertidos;
  - con motivo;
  - inserta el mismo tipo con `−monto`, `revierte_id`, la fecha de hoy y el motivo como
    observación.

**Verificación estructural** al final (`DO $verif$`):
- las tres tablas tienen RLS, 0 policies y ningún privilegio para `anon` ni `authenticated`;
- los dos triggers existen;
- `authenticated` no ejecuta los helpers ni las funciones de trigger, y `anon` no ejecuta nada
  nuevo;
- el md5 de `_guardar_gasto` ya no es el de la guarda.

- [ ] **Step 1: Ensayo `scripts/test-gastos-4.sql`.** Elige en runtime los usuarios de Global
  Constraints, un cliente `C1` de Tucumán sin pagos con adelanto, un `C2` de Taco Pozo y un pedido
  pendiente de `C1`. Aserciones:
  1. **Alta y visibilidad**:
     - `A1` da de alta a `E1` en Tucumán, semanal desde el lunes, con saldo inicial −5000. El saldo
       da −5000, con un movimiento `'Saldo al empezar'`;
     - `AT` no lo ve en `listar_personal`, y `obtener_cuenta_empleado` le da el mensaje de
       visibilidad;
     - `A1` no puede cargar uno "de las dos"; `AD` carga a `E2`, "de las dos", y `A1` no lo ve;
     - `EN` recibe 42501 en `listar_personal`. `empleados_para_elegir` le da sólo las cinco claves,
       sin `sueldo` ni `saldo`.
  2. **Vínculos**:
     - `E1` con `C1` anda;
     - otro empleado con el mismo usuario o el mismo cliente da su mensaje;
     - `E1` con `C2` da `'El cliente tiene que ser…'`, y `E2` con `C2` anda.
  3. **Uno mismo**:
     - `A1` no se puede dar de alta con su propio usuario;
     - `AD` da de alta a `E3` con el usuario de `A1`;
     - sobre `E3`, `A1` no puede registrar un movimiento, cambiar el arreglo, dar de baja ni
       cambiar el usuario. Sí puede cambiar el teléfono;
     - `guardar_gasto` con `origen_pago: 'empleado', empleado_id: E3`, cargado por `A1`, falla.
  4. **Mercadería**:
     - un pago FIFO con adelanto de 10000 sobre `C1`, como `A1`, deja en `E1` un movimiento de
       −10000 con su `pago_id`;
     - el mismo pago sobre un cliente sin vínculo da el primer mensaje del adelanto;
     - un pago en efectivo sobre `C1` no deja nada.
  5. **Sigue al pago** (las filas se cambian a mano dentro de la transacción):
     - bajar el monto a 7000 deja +3000, con `'El pago cambió de monto'`;
     - partirlo (baja la raíz a 4000 y nace un pedazo de 3000 con `pago_origen_id`) deja la suma de
       la familia en −7000;
     - borrar el pedazo deja +3000; borrar la raíz deja la familia en 0.
  6. **Históricos**:
     - `AD` vincula el cliente 376 a un empleado nuevo;
     - cambiar el monto del pago 7777, borrar el 7776 e insertar un pedazo del 7775 no deja ningún
       movimiento ni ningún rechazo.
  7. **Cambio de cliente**:
     - un adelanto vivo de `C1` que pasa a un cliente sin vínculo da el mensaje del cambio de
       cliente;
     - si pasa a la ficha de `E2`, queda +monto en `E1` y −monto en `E2`.
  8. **Reintegro**:
     - un gasto de 8000 pagado por `E1` deja +8000;
     - a 9000 deja +1000;
     - pasarlo a `E2` deja −9000 en `E1` y +9000 en `E2`;
     - anularlo deja −9000 en `E2`;
     - uno pagado por la oficina no deja nada;
     - `EN` carga uno pagado por `E1` y anda;
     - sin `empleado_id`, da `'Elegí qué empleado pagó el gasto'`;
     - con un empleado de otra sucursal o dado de baja, da su mensaje.
  9. **A mano**:
     - un adelanto de 20000 deja −20000;
     - un ajuste sin observación da su mensaje, y uno de +3000 con observación anda;
     - revertir el adelanto deja +20000; revertirlo otra vez, revertir la reversión o revertir una
       mercadería dan su mensaje;
     - una fecha futura da su mensaje.
  10. **Arreglos**:
      - uno anterior al vigente da el mensaje con la fecha;
      - con la misma fecha, lo reemplaza: no cambia la cantidad y cambia el sueldo;
      - uno posterior suma otro;
      - `obtener_cuenta_empleado` da los `vigente_hasta`.
  11. **Baja**:
      - una baja con fecha futura da su mensaje;
      - la baja deja `activo = false`;
      - un adelanto sobre `C1` da el mensaje del empleado dado de baja;
      - `cliente_admite_adelanto_sueldo(C1)` da `false`;
      - reactivar anda.
  12. **GAS-1**:
      - un combustible con 40 litros y km 10000 se edita sin las claves `litros` ni `km_tablero` y
        las conserva;
      - con `null` explícito, las borra.
  13. **Permisos**:
      - `anon` no ejecuta nada nuevo, y `authenticated` no ejecuta los helpers ni los triggers;
      - las tablas no tienen privilegios para `anon` ni `authenticated`;
      - `auditoria_definer_sin_rol()` no lista nada de esta migración.
  14. **Invariantes**, los de `EMP-A` y `EMP-B`:
      - para cada pago con movimientos, borrados incluidos, la suma es −monto vivo, o 0 si se borró
        o no es adelanto;
      - para cada gasto, es +monto si es de un empleado y no está anulado, o 0.
- [ ] **Step 2: Ensayo solo en prod → `ENSAYO FALLÓ`.**
- [ ] **Step 3: Migración**, con `SET LOCAL lock_timeout = '5s'` arriba. La cabecera va al estilo
  de la 413:
  - qué agrega y por qué;
  - por qué las tablas son de server;
  - cómo concilia el trigger y por qué no hay un corte por id;
  - el despliegue: el adelanto de sueldo se rechaza hasta vincular las fichas (decisión 8).
- [ ] **Step 4: Ensayos acumulados**:
  - `BEGIN; …mig…; …test-gastos-4…; ROLLBACK;` → `ENSAYO OK`;
  - `BEGIN; …mig…; …test-gastos-3…; ROLLBACK;` → OK: la rendición sigue andando con el
    `_guardar_gasto` nuevo;
  - en la misma transacción, `auditoria_integridad()->'critical_high_en_rojo'` da igual que antes.
- [ ] **Step 5: `npx vitest run src/test/rpcsSoloServidor.test.ts`, y commit**
  `feat(personal): empleados, arreglos y la cuenta con sus movimientos automáticos (mig NNN)`.

---

### Task 3: Datos de Personal

Modelo: Sonnet, esfuerzo high.

**Files:**
- Create: `src/hooks/queries/usePersonalQuery.ts` y `src/hooks/queries/usePersonalQuery.test.tsx`.
- Modify: `src/hooks/queries/index.ts`.

**Interfaces:**
- **Consumes**: los tipos de la Tarea 1 y las RPCs de la Tarea 2.
- **Produces**:
  - **Keys**: `personalKeys = { all: (sId) => ['personal', sId], lista: (sId) => [...all, 'lista'], cuenta: (sId, id: number) => [...all, 'cuenta', id], paraElegir: (sId) => [...all, 'para-elegir'], admiteAdelanto: (sId, clienteId: number) => [...all, 'admite-adelanto', clienteId] }`.
  - **Queries**:
    - `usePersonalQuery(): UseQueryResult<Empleado[]>`, con `rpc('listar_personal')` y `staleTime`
      30 s;
    - `useCuentaEmpleadoQuery(empleadoId: number | null): UseQueryResult<CuentaEmpleado>`, con
      `rpc('obtener_cuenta_empleado', { p_empleado_id })`;
    - `useEmpleadosParaElegirQuery(): UseQueryResult<EmpleadoParaElegir[]>`, con `staleTime`
      5 min;
    - `useClienteAdmiteAdelantoQuery(clienteId: number | string | null): UseQueryResult<boolean>`,
      habilitada sólo con id.
  - **Mutations**, todas `mutateAsync`, y todas invalidan `personalKeys.all(sId)`:
    - `useGuardarEmpleadoMutation()`, con `GuardarEmpleadoPayload` → `number`;
    - `useGuardarArregloMutation()`, con `{ empleadoId: number; arreglo: GuardarArregloPayload }`;
    - `useDarDeBajaEmpleadoMutation()`, con `{ empleadoId: number; fecha: string }`;
    - `useReactivarEmpleadoMutation()`, con `number`;
    - `useRegistrarMovimientoEmpleadoMutation()`, con
      `{ empleadoId: number; movimiento: MovimientoManualPayload }`;
    - `useRevertirMovimientoEmpleadoMutation()`, con `{ movimientoId: number; motivo: string }`.
  - **Errores**: van con `errorDeSupabase(error, 'Sin conexión: no se pudo …. Revisá la señal e intentá de nuevo.')`,
    con el verbo de cada uno ("cargar el personal", "guardar el empleado", "registrar el
    movimiento", etc.).
  - Todas las queries llevan `enabled: currentSucursalId != null`.

- [ ] **Step 1: Tests**, con el molde de `useGastosQuery.test.tsx`:
  - `usePersonalQuery` llama `listar_personal` sin argumentos y devuelve el array;
  - `useCuentaEmpleadoQuery(null)` no llama nada;
  - `useGuardarArregloMutation` manda `{ p_empleado_id: 7, p_arreglo: {...} }` e invalida
    `['personal', 1]`;
  - `useRegistrarMovimientoEmpleadoMutation` manda `{ p_empleado_id, p_movimiento }`;
  - `useClienteAdmiteAdelantoQuery('376')` manda `{ p_cliente_id: 376 }`;
  - un error de red da el mensaje con "Sin conexión".
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(personal): datos de la vista y de la cuenta`.

---

### Task 4: La vista Personal, su ruta y su menú

Modelo: Sonnet, esfuerzo high.

**Files:**
- Create:
  - `src/components/vistas/VistaPersonal.tsx` y `src/components/vistas/__tests__/VistaPersonal.test.tsx`;
  - `src/components/containers/PersonalContainer.tsx` y su test.
- Modify:
  - `src/components/layout/TopNavigation.tsx` y su test;
  - `src/App.tsx`;
  - `src/lib/guardasRutas.ts` y su test;
  - `src/lib/permisos.ts` y su test;
  - `src/hooks/__tests__/erroresCrudos.trinquete.test.ts`, si el container suma `catch`.

**Interfaces:**
- **Consumes**: las Tareas 1 y 3. Los modales de las Tareas 5 y 6 se cargan lazy; mientras no
  existan, el test del container los mockea.
- **Menú**: en el grupo Finanzas, después de Vehículos, va
  `{ id: 'personal', icon: IdCard, label: 'Personal', roles: ['admin'] }`. `IdCard` sale de
  `lucide-react`.
- **Ruta y permiso**:
  - la ruta es `/personal`, con `guardar('/personal', <PersonalContainer />)`;
  - su guarda es `'/personal': { permite: f => f.isAdmin, sino: A_PEDIDOS }`;
  - el permiso, `puedeAccederPersonal(rol)`: sólo admin.
- **`VistaPersonalProps`**:
  `{ empleados: Empleado[]; loading: boolean; error?: Error | null; onRetry?: () => void; sucursalActual: { id: number; nombre: string }; sucursales: Array<{ id: number; nombre: string }>; onNuevo: () => void; onEditar: (e: Empleado) => void; onDarDeBaja: (e: Empleado) => void; onReactivar: (e: Empleado) => void; onVerFicha: (e: Empleado) => void }`.
- **La vista** sigue la maqueta y el molde de `ClienteCard`, sin tocar `VistaClientes`:
  - **`PageHeader`**:
    - título `'Personal'`;
    - crumbs `['ADMINISTRACIÓN', <sucursal en mayúsculas>, '{n} EMPLEADO(S)']`;
    - acción: un `Button variant="hero"` con `UserPlus` y el texto `'Nuevo empleado'`.
  - **Buscador** con placeholder `'Buscar empleado'`.
  - **Pastillas**, en un `role="group"` con `aria-label="Filtrar personal"`: `'Todos · {n}'`,
    `'Con saldo · {n}'` e `'Inactivos'`. Se copia la `Pastilla` local de `VistaGastos`.
  - **La tarjeta**, por empleado:
    - **Línea de arriba**: `'{puesto} · {sucursal}'`, con `'Las dos'` para un empleado de las
      dos. Va el badge `'Inactivo'` si está dado de baja, o `'Tu cuenta'` si `es_propio`.
    - **Acciones**:
      - el lápiz, `aria-label="Editar empleado {nombre}"`;
      - desactivar, con `UserX`, `aria-label="Desactivar empleado {nombre}"` y
        `title="Desactivar. Su cuenta y su historial quedan."`. Sólo para un activo y no propio;
      - reactivar, con `RotateCcw`, `aria-label="Reactivar empleado {nombre}"`. Sólo para un
        inactivo y no propio.
    - **El cuerpo**:
      - el nombre en un `h3`;
      - el arreglo con `textoArregloCorto`, o `'Sin arreglo'`, más `' · empieza el {dd/mm}'` si
        el arranque es futuro;
      - los vínculos: `'Usuario {nombre}'` o `'Sin usuario en la app'`,
        `'Cliente “{nombre_fantasia}”'` y `'{descripción} {patente}'`.
    - **El pie**: `'Saldo'`, `'Saldo · a su favor'` o `'Saldo · debe'`, con
      `formatPrecio(Math.abs(saldo))` y los colores de Global Constraints, y el botón
      `'Ver ficha'`.
  - **Vacíos**: sin empleados, `'Todavía no hay empleados. Cargá el primero con «Nuevo empleado».'`;
    con filtro, `'Ningún empleado coincide.'`.
- **`PersonalContainer`**:
  - usa `usePersonalQuery` y abre lazy `ModalEmpleado`, `ModalCuentaEmpleado` y
    `ModalBajaEmpleado`;
  - reactivar llama la mutation y avisa con `notify`;
  - `useResetOnSucursalChange` cierra los modales.

- [ ] **Step 1: Tests:**
  - **Vista**:
    - "la tarjeta muestra puesto, sucursal, arreglo, vínculos y saldo": un preventista de
      Tucumán, semanal de 150000 con comisión, usuario prios, saldo −5000. Se ven
      `'Preventista · Tucumán'`, `'Usuario prios'`, `'Saldo · debe'` y `formatPrecio(5000)`;
    - "un empleado de las dos dice 'Las dos'";
    - "el filtro Con saldo trae también a un inactivo con saldo";
    - "la cuenta propia no tiene desactivar y dice 'Tu cuenta'";
    - "un inactivo tiene reactivar y no desactivar";
    - "buscar 'rios' deja a Pablo Ríos".
  - **Rutas y menú**:
    - `ENTRAN['/personal']` es `['admin']`;
    - el admin ve `'Personal'` en Finanzas y el encargado no;
    - `puedeAccederPersonal`: sólo admin.
  - **Container**:
    - "Ver ficha abre la cuenta con su id";
    - "reactivar llama la mutation y avisa".
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(personal): la vista Personal`.

---

### Task 5: Alta y edición del empleado

Modelo: Sonnet, esfuerzo high.

**Files:**
- Create: `src/components/modals/ModalEmpleado.tsx` y `ModalEmpleado.test.tsx`.
- Modify: `src/components/containers/PersonalContainer.tsx`, que arma sus props.

**Interfaces:**
- **Consumes**: las Tareas 1, 3 y 4.
- **Props**:
  ```ts
  export interface ModalEmpleadoProps {
    empleado: Empleado | null            // null: alta
    sucursalActual: { id: number; nombre: string }
    sucursalesUsuario: Array<{ id: number; nombre: string }>
    tieneTodasLasSucursales: boolean
    usuarios: Array<{ id: string; nombre: string }>
    clientes: Array<{ id: number; nombre_fantasia: string; activo: boolean }>
    vehiculos: Array<{ id: number; patente: string; descripcion: string }>
    ocupados: { usuarios: Set<string>; clientes: Set<number> }  // vinculados a otro empleado
    hoy: string
    onSave: (p: GuardarEmpleadoPayload) => Promise<void>
    onClose: () => void
  }
  ```
- **De dónde salen los props**, en el container:
  - `usuarios`, de `useUsuariosQuery`;
  - `clientes`, de `useClientesQuery({ includeInactivos: true })`;
  - `vehiculos`, de `useVehiculosQuery()`;
  - `ocupados`, de la lista de `usePersonalQuery`;
  - `tieneTodasLasSucursales`, con la misma cuenta que `usePropsModalGasto`.

  Los ids de clientes llegan como string en `ClienteDB`: el container los pasa con `Number(id)`.
- **Schema Zod co-locado**, exportado como `modalEmpleadoSchema`, con los mensajes del server.
  El arreglo es obligatorio sólo en el alta.
- **El modal**, con el orden y los textos de la maqueta:
  - **Título**: `'Nuevo empleado'` o `'Editar empleado'`.
  - **Datos**:
    - `'Nombre y apellido *'`;
    - `'Puesto *'`, en botones, con `PUESTOS`;
    - la sucursal: con `tieneTodasLasSucursales`, pastillas por sucursal más `'Las dos'`; si no,
      el texto fijo `'Sucursal {nombre}'`;
    - `'CUIL'`, `'Ingresó el'` y `'Teléfono'`.
  - **`'Vínculos (opcionales)'`**: tres `Combobox`, cada uno con `textoSinOpcion="Sin vínculo"`.
    Los ocupados no se ofrecen, salvo el actual.
    - `'Usuario de la app'`, con placeholder `'Buscá un usuario'` y la ayuda de la maqueta;
    - `'Ficha de cliente'`, con `'Buscá un cliente'` y su ayuda. Un inactivo se lista como
      `'{nombre} · inactivo'`;
    - `'Vehículo habitual'`, con `'Buscá por patente o modelo'`, y busca en la patente y la
      descripción.
  - **Alta, `'Primer arreglo'`**:
    - `'Sueldo fijo *'`;
    - `'Semanal'` o `'Mensual'` en pastillas;
    - el checkbox `'Comisiona'`, con la ayuda `'El porcentaje no va acá: sale de las reglas de comisión.'`;
    - `'Se liquida desde *'`: arranca en `inicioDelPeriodo(hoy, frecuencia)` y sigue a la
      frecuencia hasta que se lo toca. Su ayuda:
      `'Para alguien que ya trabajaba, es el primer día del período que todavía no le pagaste fuera de la app: lo de antes, incluidas las comisiones de lo entregado antes, se da por pagado. Para alguien nuevo, es su primer día.'`
    - el link `'+ Saldo al empezar'` abre un monto, `'A su favor'` o `'Debe'` en pastillas, y la
      ayuda `'Lo que le debían o debía al pasar a la app. Entra como un ajuste.'`.
  - **Edición, `'Arreglo vigente'`**: `textoArregloLargo` y
    `'Se cambia desde la ficha, para que conserve desde cuándo vale.'`.
  - **`es_propio`**: el combo de usuario queda deshabilitado, con
    `'Tu vínculo de usuario lo cambia otro admin.'`.
  - **Botones**: `'Cancelar'`, y `'Dar de alta'` o `'Guardar cambios'`.
- **Payload**:
  - `sucursal_id` es la elegida, o la actual con "Las dos" o sin elección;
  - el CUIL va normalizado;
  - `saldo_inicial` va con signo (+ a su favor, − debe), o `null`.

- [ ] **Step 1: Tests:**
  - "el alta manda el primer arreglo": un transportista, 280000 semanal sin comisión, con
    `hoy = '2026-10-29'`. El payload lleva `arreglo: { vigente_desde: '2026-10-26', sueldo: 280000, frecuencia: 'semanal', comisiona: false }`.
  - "la fecha sigue a la frecuencia": al pasar a Mensual da `'2026-10-01'`; si se toca a mano,
    deja de seguirla.
  - "saldo al empezar Debe 5000 manda `saldo_inicial: -5000`".
  - "sin sueldo y sin comisión no deja guardar, y avisa".
  - "quien no tiene todas las sucursales no ve 'Las dos'".
  - "un cliente vinculado a otro empleado no se ofrece, y uno inactivo dice 'inactivo'".
  - "editar no muestra el primer arreglo y no manda `arreglo`".
  - "la cuenta propia no deja cambiar el usuario".
  - "el CUIL '20-30123456-7' va como '20301234567', y uno de 10 números avisa".
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(personal): alta y edición del empleado`.

---

### Task 6: La cuenta del empleado

Modelo: Sonnet, esfuerzo high.

**Files:**
- Create:
  - `src/components/modals/ModalCuentaEmpleado.tsx` y su test;
  - `src/components/modals/ModalMovimientoEmpleado.tsx` y su test;
  - `src/components/modals/ModalArregloEmpleado.tsx` y su test;
  - `src/components/modals/ModalBajaEmpleado.tsx` y su test.
- Modify: `src/components/containers/PersonalContainer.tsx`.

**Interfaces:**
- **Consumes**: las Tareas 1, 3 y 5 (para "Editar vínculos").
- **`ModalCuentaEmpleado`**: `{ empleadoId: number; nombreSucursal: (id: number) => string; hoy: string; onEditar: (e: Empleado) => void; onClose: () => void }`.
  Usa adentro `useCuentaEmpleadoQuery` y las mutations de arreglo, movimiento y reversión.
  `ModalBase` va con `title="Cuenta del empleado"`, `description={nombre}` y
  `maxWidth="max-w-4xl"`.
  - **Encabezado**:
    - el nombre y los badges de puesto y sucursal;
    - `'CUIL {formatCuil} · ingresó el {dd/mm/aaaa}'`, con cada tramo sólo si hay dato;
    - los vínculos, como en la tarjeta;
    - el botón `'Editar vínculos'`, que llama `onEditar`;
    - si `es_propio`, `'Es tu cuenta: los movimientos y el arreglo los carga otro admin.'`.
  - **Tarjeta de saldo**:
    - `'Saldo de la cuenta'` y `formatPrecio(Math.abs(saldo))`;
    - `'A su favor: la empresa le debe'`, `'Debe: le debe a la empresa'` o `'Al día'`;
    - el botón `'Movimiento'`, con `Plus`, salvo si es propio.
  - **Tarjeta de arreglo**:
    - `'Arreglo vigente'`, `'{sueldo} por semana'` (o `por mes`) y
      `'{Comisiona|No comisiona} · desde el {dd/mm/aaaa}'`;
    - el anterior, con `textoArregloAnterior`;
    - el botón `'Cambiar arreglo'`, salvo si es propio o está inactivo.
  - **Pestañas**, con `ui/Tabs` y la etiqueta `'Cuenta del empleado'`: `'Movimientos'` y
    `'Arreglos'`.
    - **Movimientos** es una tabla `Fecha | Concepto | Importe | Saldo`:
      - el concepto sale de `conceptoDeMovimiento`;
      - el importe va con signo y color;
      - un movimiento revertido lleva el badge `'Revertido'`;
      - un adelanto o un ajuste no revertido, que no sea una reversión, en una cuenta que no es
        propia, tiene `'Revertir'` con `aria-label="Revertir {título} del {dd/mm}"`. Abre en la
        fila un motivo (`'Por qué se revierte *'`) con `'Revertir'` y `'Cancelar'`;
      - sin movimientos, `'Sin movimientos todavía.'`.
    - **Arreglos** lista cada uno con `textoArregloLargo` y `'hasta el {dd/mm/aaaa}'`, o
      `'vigente'`.
  - **Pie**:
    `'Saldo positivo: la empresa le debe. Negativo: él le debe a la empresa. La mercadería entra sola desde el pago con «adelanto de sueldo» en su ficha de cliente, y el reintegro desde el gasto pagado con plata propia.'`
  - **Modales anidados**: `ModalMovimientoEmpleado` y `ModalArregloEmpleado` se renderizan
    **dentro** de los children de `ModalBase` (regla de Radix del repo).
- **`ModalMovimientoEmpleado`**: `{ empleado: Pick<Empleado, 'id' | 'nombre'>; hoy: string; onSave: (m: MovimientoManualPayload) => Promise<void>; onClose: () => void }`.
  - **Título**: `'Nuevo movimiento'`, con la descripción en el nombre.
  - **Tipo**: pastillas `'Adelanto en efectivo'` y `'Ajuste'`. El ajuste suma `'A su favor'` y
    `'En contra'`.
  - **Campos**:
    - `'Monto *'`;
    - `'Fecha *'`, que arranca en hoy y tiene `max` hoy;
    - `'Observación'` en el adelanto, o `'Por qué *'` en el ajuste.
  - **Ayudas**:
    - adelanto: `'Plata que se le da a cuenta del sueldo. Sale de la oficina y se descuenta al liquidar.'`;
    - ajuste: `'A su favor suma a lo que la empresa le debe; en contra, a lo que él le debe a la empresa.'`
  - **Botón**: `'Registrar movimiento'`.
  - **Schema**: co-locado, y valida con `errorDeMovimiento`.
- **`ModalArregloEmpleado`**: `{ empleado: Pick<Empleado, 'id' | 'nombre'>; vigente: ArregloEmpleado | null; hoy: string; onSave: (a: GuardarArregloPayload) => Promise<void>; onClose: () => void }`.
  - **Título**: `'Cambiar arreglo'`.
  - **Campos**: los del primer arreglo de la Tarea 5, con `'Vale desde *'`.
    - Arranca en `inicioDelPeriodo(hoy, frecuencia)`.
    - Con la misma fecha que el vigente, dice `'Corrige el arreglo vigente.'`.
    - Con una anterior, el error de `errorDeArreglo`.
  - **Ayuda**: `'Los períodos anteriores conservan el arreglo que tenían.'`.
  - **Botón**: `'Guardar arreglo'`.
- **`ModalBajaEmpleado`**: `{ empleado: Empleado; hoy: string; onConfirmar: (fecha: string) => Promise<void>; onClose: () => void }`.
  - **Título**: `'Dar de baja a {nombre}'`.
  - **Fecha**: `'Fecha de baja *'`, que arranca en hoy y tiene `max` hoy.
  - **Textos**: `'Su cuenta y su historial quedan. Se puede reactivar.'`. Con saldo, en ámbar:
    `'Tiene un saldo de {monto} {a su favor|en contra}: queda en su cuenta.'`.
  - **Botón**: `'Dar de baja'`.

- [ ] **Step 1: Tests.** El de la cuenta mockea el módulo `hooks/queries/usePersonalQuery` y los
  dos modales anidados.
  - **La cuenta**:
    - "saldo a favor": con 13500, se ve `'A su favor: la empresa le debe'` y `formatPrecio(13500)`;
    - "los movimientos muestran concepto, importe y saldo": una mercadería del pedido 8840, de
      −10000, con saldo −15000;
    - "revertir pide motivo y llama la mutation con `{ movimientoId, motivo }`". Una mercadería no
      tiene `'Revertir'`, y uno revertido tampoco;
    - "la cuenta propia no tiene Movimiento, Cambiar arreglo ni Revertir";
    - "Movimiento abre el modal anidado dentro del diálogo": el stub está dentro del
      `role="dialog"`;
    - "la pestaña Arreglos muestra 'hasta el 30/09/2026' y 'vigente'".
  - **El movimiento**:
    - "un adelanto de 20000 manda `{ tipo: 'adelanto', monto: 20000, fecha: hoy, observacion: null }`";
    - "un ajuste En contra 3000 manda `monto: -3000`, y sin 'Por qué' no deja".
  - **El arreglo**: "la misma fecha que el vigente dice 'Corrige el arreglo vigente.'; una anterior
    no deja guardar".
  - **La baja**: "con saldo −5000 avisa 'en contra'; confirmar manda la fecha".
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(personal): la cuenta del empleado`.

---

### Task 7: Gastos pagados por un empleado, y GAS-1

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify:
  - `src/types/gastos.ts`, `src/hooks/queries/gastoColumnas.ts` y `src/hooks/queries/useGastosQuery.ts`;
  - `src/utils/rendicionGastos.ts` y su test;
  - `src/components/modals/ModalGasto.tsx` y su test;
  - `src/components/vistas/VistaGastos.tsx` y su test;
  - `src/components/containers/GastosContainer.tsx`;
  - `src/utils/exportGastos.ts` y su test;
  - `src/hooks/usePropsModalGasto.ts` y su test;
  - las fixtures de `Gasto` de la entrega 2 (la lista está en su Tarea 1), que suman
    `empleado_id: null`.

**Interfaces:**
- **Consumes**: `useEmpleadosParaElegirQuery` y `personalKeys` (Tarea 3), y la columna de la
  Tarea 2.
- **Tipos**:
  - `Gasto` suma `empleado_id: number | null`;
  - en `GuardarGastoPayload`, `origen_pago` pasa a `'oficina' | 'rendicion' | 'empleado'` y suma
    `empleado_id?: number | null`;
  - `litros` y `km_tablero` pasan a opcionales: en una edición, la clave ausente es "sin cambios".
- **Datos**:
  - `GASTO_COLUMNAS` suma `empleado_id`, y el embed de rubro pasa a
    `rubro:gasto_rubros(id,nombre,grupo,pide_litros_km)`, como suma de literales;
  - las mutations de guardar y anular gasto invalidan también `personalKeys.all(sId)`;
  - `payloadDeGasto` conserva `'empleado'` y su `empleado_id`, y el test de `rendicionGastos`
    cambia.
- **`usePropsModalGasto`** suma `rubrosCargando: boolean`, con el `isLoading` de rubros.
- **`ModalGasto`**:
  - **Props nuevas**: `empleados?: EmpleadoParaElegir[]` y `rubrosCargando?: boolean`.
  - **Con `empleados` y sin `desdeCierre`**, el bloque de plata suma la tercera pastilla,
    `'Un empleado'`, y la grilla pasa a tres columnas. Con ella:
    - un `Combobox` con placeholder `'Empleado'`;
    - ofrece los activos, menos el de `usuario_id === usuarioId`, más el actual en una edición;
    - `textoSinOpcion="Otro empleado"`;
    - la ayuda: `'Queda a su favor en su cuenta y se le devuelve con el sueldo.'`.
  - **Schema**: `origen_pago` suma `'empleado'`, y `superRefine` exige `empleado_id` con
    `'Elegí qué empleado pagó el gasto'`.
  - **Payload**: con `empleado`, su id; con otro origen, `empleado_id: null`.
  - **GAS-1**:
    - un rubro dado de baja usa el `pide_litros_km` del embed, no `false`;
    - `litros` y `km_tablero` van en el payload sólo si el rubro los pide;
    - con `rubrosCargando`, el botón de guardar queda deshabilitado.
- **`VistaGastos`**:
  - suma la prop `empleados: EmpleadoParaElegir[]`;
  - un gasto de un empleado lleva la línea `'Lo pagó {nombre} con su plata'`, u
    `'otro empleado'` si no está en la lista;
  - el grupo "Con qué plata" suma la pastilla `'Empleados'`, y `'La oficina'` deja de incluirlos;
  - un gasto pagado por el empleado del usuario no tiene lápiz, y dice
    `'Lo pagaste vos: lo cambia otro admin o el encargado'`. Anular sigue.
- **Excel**: `'Un empleado: {nombre}'` en "Con qué plata".
- **`GastosContainer`** pasa `empleados` a la vista y al modal.

- [ ] **Step 1: Tests:**
  - **ModalGasto**:
    - "Un empleado pide el empleado": sin elegir, el error del schema. Con Martín (id 4), el
      payload lleva `{ origen_pago: 'empleado', empleado_id: 4, rendicion_transportista_id: null, rendicion_fecha: null }`;
    - "no se ofrece el empleado propio";
    - "sin `empleados` no está 'Un empleado'", y desde el cierre tampoco;
    - "**GAS-1**: editar una carga de un rubro dado de baja que pide litros manda sus `litros` y
      su `km_tablero`. Un rubro que no los pide no manda esas claves";
    - "con `rubrosCargando` no deja guardar";
    - el test viejo que rechazaba `'empleado'` en el schema pasa a aceptarlo con `empleado_id`.
  - **Vista**:
    - "'Lo pagó Martín Sosa con su plata'";
    - "el filtro Empleados deja sólo esos";
    - "el propio no tiene lápiz y sí anular".
  - **Excel**: da `'Un empleado: Martín Sosa'`.
  - Los tests de las entregas 1 y 2 siguen verdes.
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(gastos): un gasto pagado por un empleado se le reintegra`.

---

### Task 8: El vehículo habitual y el aviso del adelanto

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify:
  - `src/components/modals/ModalCerrarRendicion.tsx` y su test;
  - `src/components/modals/ModalGasto.tsx` y su test;
  - `src/components/modals/ModalFichaVehiculo.tsx` y su test;
  - `src/components/containers/VehiculosContainer.tsx`;
  - `src/components/modals/ModalRegistrarPago.tsx` y `ModalRegistrarPago.adelantoSueldo.test.tsx`;
  - `src/components/containers/ClientesContainer.tsx`.

**Orden:**
- El vehículo habitual y la ficha del vehículo van primero.
- El aviso del adelanto (`ModalRegistrarPago.tsx`, su test y `ClientesContainer.tsx`) espera a que
  el PR de la tarjeta 2 de #1306 esté en `main`. Se trae con `sync_with_base_branch` y se parte de
  su versión:
  - `FORMAS_PAGO` sólo trae el adelanto con `permitirAdelantoSueldo && !pedidoSeleccionado`;
  - `handlePedidoChange` pasa a efectivo un adelanto ya elegido;
  - `renderModal(permitir, pedidos, onConfirmar)` cambia de firma.
- Si todo lo demás termina antes del merge, esa parte queda para el final y se le avisa a la
  coordinadora.

**Interfaces:**
- **Consumes**: `useEmpleadosParaElegirQuery` y `useClienteAdmiteAdelantoQuery` (Tarea 3), y la
  Tarea 7.
- **`ModalGasto`** suma `vehiculoInicialId?: number | null`. En un alta sin `borrador`, es el
  vehículo con que arranca si está en `vehiculos`. El vehículo precargado viaja sólo si el rubro
  elegido es del grupo Vehículos; lo que hace hoy el modal con un vehículo elegido a mano no
  cambia.
- **`ModalCerrarRendicion`**:
  - llama `useEmpleadosParaElegirQuery()`;
  - el vehículo habitual es el `vehiculo_id` del empleado activo con
    `usuario_id === transportistaId`;
  - "Agregar gasto" lo pasa como `vehiculoInicialId`, y "Editar" no;
  - **no** se suma una clave a `desdeCierre`: su test compara ese objeto exacto;
  - la nota del pie pasa a
    `'Si lo pagó con plata propia, no va acá: se carga como gasto de «Un empleado» y se le devuelve con el sueldo.'`
- **`ModalFichaVehiculo`** suma la prop `usadoPor: string[]`. Muestra
  `'Lo usan habitualmente: {nombres}'`, o `'Nadie lo tiene como vehículo habitual.'`.
  `VehiculosContainer` arma la lista desde `useEmpleadosParaElegirQuery`, con los activos de ese
  vehículo.
- **`ModalRegistrarPago`** suma `clienteEsEmpleado?: boolean | null`. Con `permitirAdelantoSueldo`,
  si el adelanto está elegido en el pago simple o en alguna línea del dividido:
  - con `false`, va un aviso ámbar con `role="alert"`:
    `'Este cliente no es la ficha de un empleado: el adelanto de sueldo no se le puede descontar. Vinculá la ficha desde Personal o elegí otra forma de pago.'`
    El botón de confirmar queda deshabilitado, y `handleSubmit` corta con el mismo texto en las
    tres ramas;
  - con `null` o `undefined`, `'Comprobando si es la ficha de un empleado…'`, y el botón
    deshabilitado;
  - con `true`, como hoy.

  El schema no cambia, para que `formasPago.espejo.test.ts` siga igual.
- **`ClientesContainer`** pasa
  `clienteEsEmpleado` desde `useClienteAdmiteAdelantoQuery(modal abierto && permitirAdelantoSueldo ? clientePago.id : null)`.

- [ ] **Step 1: Tests:**
  - **Cierre**:
    - "Agregar gasto precarga el vehículo habitual del chofer": el stub recibe
      `vehiculoInicialId: 3`;
    - "Editar no lo pasa";
    - "sin empleado vinculado, va `null`";
    - "la nota del pie dice 'Un empleado'".
  - **ModalGasto**:
    - "con `vehiculoInicialId` y un rubro de Vehículos, el payload lleva `vehiculo_id: 3`";
    - "con Librería, no lo lleva".
  - **Ficha del vehículo**: "'Lo usan habitualmente: Martín Sosa, Juan Paz'".
  - **Pago**:
    - "adelanto con un cliente que no es empleado: avisa y no deja confirmar";
    - "en el dividido, una línea con adelanto avisa igual";
    - "comprobando, no deja confirmar";
    - "con un empleado, registra como hoy";
    - "efectivo no avisa nada".
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(personal): el vehículo habitual y el aviso del adelanto de sueldo`.

---

### Task 9: Cierre — coordinación, verificación, aplicación y PR

Lo hace la coordinadora, con el OK del dueño para aplicar.

- [x] **Step 1: Antes de lanzar las subsesiones** (hecho el 29/10):
  - se le avisa a la coordinadora de #1306 que esta entrega toca `ModalRegistrarPago` y suma un
    trigger sobre `pagos`;
  - se le avisa a la de #1308 cómo queda #1322 (decisión 1);
  - se comenta en #1330 qué miran `EMP-A` y `EMP-B`.
- [ ] **Step 2: Juntar las ramas** con el OK del dueño. Correr `npm run typecheck`,
  `npm run lint`, `npm run test:run` sin `.env` y `npm run build`: las cuatro en verde.
- [ ] **Step 3: Ensayos acumulados en prod**, los de la Tarea 2, Step 4 → OK.
- [ ] **Step 4: Aplicar.** Con el OK del dueño:
  1. elegir el número con la trampa 3: el ledger, `origin/main`, las ramas abiertas y los
     worktrees;
  2. renombrar `NNN` en el archivo, en `rpcsSoloServidor.test.ts` y en los comentarios;
  3. aplicar con `apply_migration` y verificar `md5(statements[1])` contra el `md5sum` del archivo;
  4. volver a correr el job "Embeds de PostgREST" del PR (en borrador hasta acá) y mergear
     enseguida.

  El momento exacto lo confirma el dueño al dar el OK. Esta migración no cambia firmas que use el
  bundle viejo: la ventana entre aplicar y deployar sólo deja sin adelanto de sueldo a un cliente
  sin vínculo (decisión 8).
- [ ] **Step 5: Después de aplicar:**
  - `auditoria_grants_tablas()`, `auditoria_permisos_execute()` y `auditoria_definer_sin_rol()`:
    nada nuevo en rojo;
  - `auditoria_integridad()`, con los claims de un admin: igual que antes;
  - con la anon key, `POST /rest/v1/rpc/listar_personal` da 42501, y
    `GET /rest/v1/empleados?select=id&limit=0` también.
- [ ] **Step 6: PR** a `main`, con el título "Gastos 3/5: personal".
  - El cuerpo enlaza el spec, este plan y #1332, y dice que es la entrega 3 de 5.
  - Lleva `Closes #1322`, porque GAS-2 entró antes por #1352, y `Closes #1348`, el test intermitente
    de `ModalCerrarRendicion`.
  - Avisa que el dueño tiene que dar de alta a los empleados y vincular las fichas 376 y 9 para que
    vuelva el adelanto de sueldo.
- [ ] **Step 7: Actualizar #1332**: la entrega 3 en prod y lo que queda para la 4.
