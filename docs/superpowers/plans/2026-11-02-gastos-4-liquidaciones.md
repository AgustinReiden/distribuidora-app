# Gastos, entrega 4 de 5: liquidaciones — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Liquidar cierra un período de un empleado: suma a su cuenta el sueldo, las comisiones y
los ajustes, y registra el pago en la misma acción. El sueldo viene del arreglo y se corrige a mano.
Las comisiones las calcula el server y quedan congeladas línea por línea, y un cambio posterior
entra como ajuste. El pago sale de la oficina o de una rendición pendiente. Sólo se anula la última
liquidación, y Personal avisa quién tiene un período para liquidar.

**Architecture:**
- **Una sola comisión.** La cuenta por línea sale de `calcular_comisiones` a `_comision_lineas`, que
  usan el cálculo y la liquidación. La migración prueba que `calcular_comisiones` da exactamente lo
  mismo que antes para todos los meses.
- **La foto es un libro.** `empleado_liquidacion_lineas` guarda deltas: la primera fila de una línea
  lleva su base y las siguientes, la diferencia. Lo congelado es la suma de las filas vigentes. Así
  un ajuste no pisa nada, y anular una liquidación es marcar sus filas como no vigentes.
- **La línea no se identifica por `pedido_items.id`.** `actualizar_pedido_items` borra y reinserta
  las líneas, así que cada edición cambia los ids. La clave es producto + combo + origen de precio:
  misma clave quiere decir misma regla, así que se agrupa y se suma. Cada fila guarda además quién
  era el vendedor, porque `pedidos.usuario_id` cambia.
- **El sueldo no se calcula.** La pantalla trae el fijo del arreglo y el admin lo corrige a mano, con
  motivo. Las comisiones sí salen del server: `previsualizar_liquidacion` y `liquidar_empleado` usan
  los mismos helpers. El front manda lo que vio (`a_pagar_esperado`), y si algo cambió en el medio el
  server rechaza.
- **El pago puede salir de una rendición.** El movimiento `pago` guarda la rendición, y
  `obtener_resumen_rendiciones` suma un total por rendición, sin nombres. Una rendición cerrada no
  cambia nunca.
- **Las guardas van en triggers.** Un arreglo o una baja que caen dentro de lo ya liquidado se
  rechazan en `empleado_arreglos` y `empleados`, sea cual sea el camino.

**Tech Stack:** React 19 + Vite + TanStack Query + Zod + vitest/testing-library; Supabase Postgres
(plpgsql, `migrations/`).

**Spec:** `docs/superpowers/specs/2026-10-28-gastos-y-cuentas-del-personal-design.md`. Para esta
entrega importan "Quién ve y hace qué", 3 (pago de sueldos), 4.2, 4.3, 4.7, 4.8, 4.9 y 5. El molde
es `docs/superpowers/plans/2026-10-29-gastos-3-personal.md`. El contexto, los cruces y cómo se
trabajó están en el issue #1332, incluido su comentario del 02/11. Maqueta:
`docs/superpowers/specs/2026-10-28-gastos-y-personal-maquetas.html`, pestañas "Cuenta" y "Liquidar".

**Base de la rama:** `main` en `c3002360`, con las entregas 1 a 3 en prod (migs 411 a 413 y 430). El
plan se escribió sobre `471a88b5`, y se revisó contra lo que entró después (ver "Lo que hay hoy").

**Ejecución:** dos subsesiones, cada una en su worktree, cortadas de esta rama con el plan
commiteado:
- `gastos-4-sql` hace la Tarea 2 con Opus, esfuerzo high. Su nombre de turno es `gastos-4-sql`.
- `gastos-4-front` hace las Tareas 1 y 3 a 7 con Sonnet, esfuerzo high. Su nombre de turno es
  `gastos-4-front`.

La coordinadora (esta sesión) junta las ramas sólo con el OK del dueño, y después hace la Tarea 8.

## Lo que hay hoy (relevado en prod el 2026-11-02, sólo lectura)

- **Ledger:** la última es la 435. La 430 quedó antes de las 431b a d y después de la 431a. Las 432 y
  433 ya están en `main`. La 434 (gates, PR #1386) y la 435 (permisos por sucursal, PR #1384) están
  aplicadas, con sus PRs abiertos.
- **Lo que cambió mientras se armaba el plan:**
  - Ninguna de las cuatro tocó las seis funciones que se reescriben: sus md5 siguen iguales.
  - La 434 sumó **COMIS-06**, que le pide a `calcular_comisiones` que su cuerpo nombre
    `comision_pct_vigencias` y `baja_desde`. Con esa lógica en `_comision_lineas`, daría rojo: la
    migración repone el check (Reescrituras).
  - El gate de sucursal cruzada ve toda FK simple entre dos tablas con `sucursal_id`, y su lista de
    excepciones sólo se achica. Por eso la foto de `empleado_liquidaciones` no se llama así.
  - La 435 hace que `control_rendicion_cerrado` levante 42501 para una sucursal que no es del usuario.
    Lo que escribe el pago no lo nota, porque va por la sucursal activa. Anular o revertir ese pago
    sin tener esa sucursal da ese error: lo tiene que hacer otro admin (caso 17).
  - EMP-A y EMP-B miran sólo `mercaderia` y `reintegro`, y REPORTE-A sólo `reporte_*` y `tablero_*`:
    esta entrega no los afecta.
- **#1320:** cerrado de verdad por la 421, con la decisión del dueño del 29/10 en el issue.
  `calcular_comisiones` ya tiene `comision_pct_vigencias` y `baja_desde`, y no cambió después de la
  421. La tarjeta 5 de #1308 terminó, así que esas funciones ya no tienen dueño ajeno.
- **Personal en prod:** 0 empleados, 0 arreglos, 0 movimientos, 0 gastos y 0 vehículos. Las fichas
  376 y 9 están sin vincular, y desde la 430 todo adelanto de sueldo se rechaza. El último fue el
  24/10. El dueño todavía no probó las entregas 1, 2 y 3.
- **`pedidos.fecha_entrega` es `timestamptz`.**
  - Se llena al marcar entregado, y "Volver a pendiente" la pone en NULL (420).
  - De 7.245 entregados, 6 no la tienen, todos de agosto de 2026. Desde septiembre, ninguno.
  - Desde julio, el retraso contra `pedidos.fecha` tiene mediana de 1 a 2 días, p90 de 1 a 5 y un
    máximo de 25.
  - Hasta un 8 % de la venta de un mes (septiembre en Tucumán) se entrega en el mes siguiente: por
    eso la vista Comisiones y lo liquidado no van a coincidir.
- **Las líneas:** 7 pedidos tienen dos líneas con el mismo producto, combo y origen, y 32 líneas no
  tienen producto. `subtotal` es `numeric(10,2)`, y `combo_id`, `bigint`.
- **Quién vende:** todos venden sólo en su sucursal. Desde agosto vendieron 13 usuarios, 4 de ellos
  admins y un encargado, que comisionan con `pct_otros` (0 %). Tres de los preventistas ya están
  inactivos.
- **El %:** 2 % preventista y 0 % el resto, en las tres filas de `comision_pct_vigencias`. Hay 0
  reglas.
- **`cambiar_cliente_pedido`** rechaza un pedido entregado o cancelado, así que no toca lo liquidado.
- **El vendedor de un pedido sí cambia.** `actualizar_preventista_pedido`, sólo del admin, le cambia
  `usuario_id` a un pedido en cualquier estado. Desde agosto hubo 124 cambios: 34 después de entregar,
  el más tardío a los 4 días. Con liquidaciones semanales, el pedido ya puede estar pagado (decisión
  15).
- **Un pedido no se borra desde la app.** `eliminar_pedido_completo` no tiene EXECUTE para
  `authenticated`, y `pedidos` no tiene DELETE. El último entregado borrado es de antes de junio.
- **La rendición:**
  - El efectivo a entregar se calcula en el front (`efectivoAEntregar`), con `total_efectivo` y
    `total_gastos` de `obtener_resumen_rendiciones`.
  - Esa función devuelve `TABLE (...)`: sumarle una columna obliga a dropearla y recrearla con sus
    grants. La llaman el admin, el encargado y el transportista, que ve sólo su fila.
  - Una rendición cerrada no se puede reabrir desde la app: no hay RPC ni botón.
  - `_guardar_gasto` ya valida la rendición de un gasto: transportista y día, día no futuro,
    transportista de la sucursal, lock con `_rendicion_clave` y `_rendicion_bloquear`, y
    `control_rendicion_cerrado`. Ese es el molde.
- **Los md5 de prod** de lo que se reescribe (`md5(prosrc)`; la 430 quedó con CRLF, ver #1332):

  | Función | md5 de prod | Sin CR |
  |---|---|---|
  | `calcular_comisiones(date,date,bigint[])` | `40b1b721846688a357b452bcb1c7c5c9` | el mismo |
  | `obtener_resumen_rendiciones(date,date,uuid)` | `06aae115f4ac237d59623f1b0ff7a886` | el mismo |
  | `_empleado_json(empleados)` | `c164580110b99447eb285b86b202c7c6` | `4acf474e981e4dfaa3e728077b168862` |
  | `obtener_cuenta_empleado(bigint)` | `44334922227243cf5579ff63c44301ac` | `eb8c1bd24ed6825dee11e0c1aca7e157` |
  | `registrar_movimiento_empleado(bigint,jsonb)` | `dfd8bc320f8684c8058132be4f6c4f7e` | `dc604593a271fecdb5ee9ac345615831` |
  | `revertir_movimiento_empleado(bigint,text)` | `568c4c4addc9253637e34273c5b779b9` | `c66aa4f64d86336a6b2b2c42e65a6c16` |
  | `auditoria_comision_mes_cerrado()` | `9ff7f5190c33ad1bbd04931c54b5d506` | el mismo |

## Cruces y coordinación

- **#1350 (comisiones de un mes cerrado):** se cierra con esta entrega (decisión 8).
- **#1354 (el admin se baja su propio adelanto):** se cierra con esta entrega (decisión 9).
  `registrar_salvedad`, `actualizar_pedido_items` y `cambiar_cliente_pedido` no se tocan.
- **`actualizar_preventista_pedido`** no se toca: el cambio de vendedor se resuelve del lado de la
  liquidación (decisión 15).
- **#1269 (estado de resultados):** esta entrega le deja `personal_por_mes` (decisión 10).
- **#1330 (Gates):** la tarjeta 8 de #1308 ya está aplicada (434), y su PR #1386 cierra el issue. Los
  checks de esta entrega van a un issue nuevo (decisión 11), y mientras tanto los prueba el ensayo.
- **#1386 y #1384:** tocan `CLAUDE.md`, `src/test/rpcsSoloServidor.test.ts` y scripts de gates. Si
  entran antes, los conflictos son de sumar las dos cosas. Las subsesiones no mergean `main`: lo hace
  la coordinadora en la Tarea 8.
- **Rendición:** `resolver_rendicion` no se toca, y `confirmar_rendicion` sí (ver "Desvíos de la
  ejecución"). También cambian
  `obtener_resumen_rendiciones`, `VistaRendiciones` y `ModalCerrarRendicion`, para sumar el total
  pagado al personal. Las tarjetas que eran dueñas de esas funciones ya terminaron; igual, antes de
  aplicar se mira el md5.
- **`empleado_movimientos`, `_guardar_gasto` y los dos triggers de cuenta** son de Gastos. Esta
  entrega toca sólo la tabla.

## Decisiones de este plan

El dueño las aprobó una por una en chat el 2026-11-02. La 5 y la 13 cambian el diseño, que ya quedó
corregido en esas secciones.

1. **Se puede liquidar el período en curso.** Los semanales se pagan antes del domingo.
   - Se liquida desde el primer día del período (`desde <= hoy`), nunca uno que no empezó.
   - Las comisiones son las entregadas hasta ese momento. Lo que se entregue después entra en el
     período siguiente: la condición es "hasta el último día", sin piso, así que no se pierde.
2. **La comisión va con cada liquidación**, con la frecuencia del arreglo: la del semanal, por semana.
3. **La línea congelada se identifica por producto + combo + origen de precio** (ver Architecture).
   Si una edición cambia el origen, es otra línea: la vieja vuelve a 0 con su % y la nueva usa la
   regla vigente a `pedidos.fecha`.
4. **La baja no corta el período.** Lo que se entregue después de que se fue se le liquida igual, en
   un período con sueldo 0. Si no, se perdería la comisión de lo que vendió antes de irse, que es un
   anti-objetivo del diseño.
5. **El sistema no calcula el sueldo.**
   - La pantalla trae entero el sueldo del arreglo vigente el primer día del período, y el admin lo
     corrige a mano si faltó, entró, se fue o le cambió el arreglo.
   - Si el monto difiere del arreglo, el motivo es obligatorio y queda en su cuenta.
   - La pantalla avisa si el arreglo cambia dentro del período, y si entró o se fue en él.
   - Un período entero después de la baja trae 0.
   - Sale del diseño el prorrateo por días corridos. Reactivar no registra nada: los días afuera no
     cobran porque el admin los corrige en la pantalla.
6. **Lo liquidado no se cambia de costado.**
   - Un arreglo no puede valer desde un día ya liquidado, ni corregirse uno así.
   - Una baja no puede ser anterior al último día liquidado.
   - En los dos casos, el mensaje manda a anular la liquidación.
7. **El pago.**
   - En la liquidación va de 0 a lo que le toca. Más que eso es un adelanto, y se carga aparte.
   - El pago suelto es un tercer tipo en "+ Movimiento", sin tope, y se revierte como un adelanto.
     El pago de una liquidación se revierte anulándola.
8. **#1350 se cierra con esta entrega** (`Closes #1350`). La foto es la liquidación: lo pagado no se
   mueve por rol, categoría ni datos de la venta. La vista Comisiones y el reporte gerencial siguen
   siendo un cálculo, y la vista lo aclara (Tarea 6).
9. **#1354 se cierra con esta entrega** (`Closes #1354`). Alcanza con el rastro, puesto a la vista:
   los movimientos del período que disparó el propio empleado llevan la marca "Lo cargó su propio
   usuario" en la pantalla de liquidar. El control está en quien paga.
10. **`personal_por_mes` trae el sueldo y la comisión por separado.** La comisión ya está en
    Contribución en el reporte gerencial y en el diseño de #1269. Queda anotado ahí que Personal suma
    sólo el sueldo, o la comisión se cuenta dos veces.
    - El sueldo se reparte por días entre los meses del período. El de un empleado "de las dos" va
      como compartido.
    - La comisión va al mes de entrega, en la sucursal del pedido, y el ajuste, al mes del `hasta`.
    - Sólo trae lo liquidado.
11. **Auditoría:** como en la entrega 3, la migración no suma checks a `auditoria_integridad()`. El
    dueño los quería en #1330, pero #1386 cierra ese issue, así que van a uno nuevo que lo cite:
    - `LIQ-A`: los movimientos de cada liquidación vigente suman lo mismo que sus conceptos menos lo
      pagado;
    - `LIQ-B`: ninguna línea tiene dos filas no-ajuste vigentes con el mismo vendedor. Con vendedores
      distintos es legítimo, hasta que el anterior tenga su ajuste (decisión 15);
    - `LIQ-C`: los pagos al personal de una rendición cerrada no cambiaron después del cierre.
12. **Se liquida sólo el período pendiente más viejo.** Las flechas de la maqueta no entran.
13. **El pago puede salir de una rendición.** Revierte lo que decía el diseño, que lo había sacado
    para que el encargado no viera sueldos.
    - Entran la liquidación y el pago suelto. El adelanto en efectivo sigue saliendo de la oficina.
    - Cada pago sale de una sola plata: para partirlo se hace un pago parcial y después uno suelto.
    - Sólo de una rendición pendiente. Una cerrada se rechaza, como un gasto.
    - El encargado y el chofer ven sólo un total, sin nombres: "− $280.000 pagados al personal con
      esa plata". El detalle es del admin. Con un solo pago, quien conozca el caso puede deducirlo: el
      dueño lo aceptó.
    - Al anular con la rendición pendiente, el pago se revierte y el efectivo vuelve. Con la rendición
      ya cerrada, **el pago queda**: la plata salió de verdad y la rendición no cambia. La nueva
      liquidación lo descuenta sola.
    - Un pago suelto de una rendición cerrada no se revierte: se corrige con un ajuste.
14. **La pastilla "sin liquidar" aparece dos días antes de que termine el período**, y no después
    como decía el spec: los semanales se pagan viernes o sábado, y si no el filtro "Para liquidar"
    estaría vacío justo ese día.
15. **Un pedido liquidado que cambia de vendedor le sale al anterior y le entra al nuevo.** La foto
    guarda el vendedor de cada línea.
    - El empleado anterior recibe un ajuste negativo en su próxima liquidación, con `'El pedido pasó
      a otro vendedor'`.
    - El nuevo lo liquida como un pedido más, si su arreglo comisionaba el día de la entrega.
    - Si el nuevo cobra primero, el pedido queda en los dos hasta el ajuste del anterior: los dos
      ven el rastro, y el neto cierra.
    - Si el usuario se revincula a otro empleado sin que cambie el vendedor del pedido, no pasa
      nada: el pedido sigue en el empleado que lo cobró.

## Desvíos de la ejecución

Lo que cambió al ejecutar, sobre lo que dice el resto del plan:

- **`confirmar_rendicion` se toca.** Con el pago desde una rendición, un pago que entraba con el
  cierre abierto no se veía, y después ya no se podía revertir. Ahora compara lo pagado contra
  `pagos_personal_visto`, como hace con los gastos, y lo que falta en un bundle viejo vale 0.
- **`$vivas$` lleva ocho funciones**, con `confirmar_rendicion` (`d56e43a8227cdeb00a10d3a6e2320a65`).
- **`_empleado_periodo_siguiente` salta hasta la primera comisión pendiente** después de una baja.
  Con el plan, una entrega posterior a la semana siguiente a la baja no se liquidaba nunca.
- **La vista previa trae `liquidacion` y `rendicion` en cada movimiento**, con el helper
  `_movimiento_origen_json` que comparte con la cuenta.
- **`ModalLiquidar` queda atado al período que abrió.** Si un `refetch` trae otro, no deja confirmar.
  Las cuatro mutations de plata invalidan en `onSettled`, y Enter no confirma.
- **La regresión de la 435 se arregló aparte**, en la 436 (#1390): frenaba `test-gastos-3` y
  `test-gastos-4`, y ningún gasto nuevo se podía cargar.
- **Los hallazgos menores que no se arreglaron** van al issue de los checks `LIQ` (Tarea 8, Step 7).

## Global Constraints

- **`CLAUDE.md` de la raíz rige todo**, como en las entregas anteriores:
  - trampa 3: el número de migración se elige al aplicar;
  - trampa 5: los parámetros de RPC van en `INTEGER` o `BIGINT`, nunca en `SMALLINT`;
  - al cambiar el retorno de una función se dropea la vieja, y se reponen sus grants;
  - el día es el argentino: `_tablero_hoy()` en SQL, y `fecha_entrega` se corta con
    `(x AT TIME ZONE 'America/Argentina/Buenos_Aires')::date`, nunca con `::date` pelado.
- **Verificación**: antes de cerrar una tarea con front se corren `npm run typecheck`,
  `npm run lint`, `npm run test:run` (sin `.env`) y `npm run build`. El pre-commit corre la suite
  entera; nunca `--no-verify`. `test:run`, `build` y `git commit` van con el turno de
  `refs/turno/pesado` (#1332, "Cómo se trabajó", punto 3).
- **Migración**: `migrations/NNN_gastos_5_liquidaciones.sql`, con NNN literal.
  - **Nadie aplica**: la coordinadora aplica con el OK del dueño.
  - En prod (proyecto `hmuchlzmuqqxcldbzkgc`, `execute_sql`) se corren sólo SELECTs, el ensayo solo
    y el acumulado `BEGIN; SET LOCAL lock_timeout='5s'; <mig>; <ensayo>; ROLLBACK;`.
  - El veredicto del ensayo va en el `RAISE EXCEPTION` final. El acumulado lo manda la coordinadora,
    no un subagente.
  - **Si un clasificador de seguridad corta la copia del SQL a `execute_sql`, no se busca otra vía:
    se le avisa al dueño.** En la entrega 3 los corrió él desde el SQL Editor.
- **Ensayos**: el molde es `scripts/test-gastos-4.sql`: un `DO $ensayo$`, canarios con ERRCODE
  `P0099`, cierre `ENSAYO OK` o `ENSAYO FALLÓ`, cada RPC llamada como el front (`pg_temp.como`) y
  usuarios elegidos en runtime (`a1`, `at`, `ad`, `en`, `tr`).
- **Funciones**:
  - Las RPCs del front llevan `SECURITY DEFINER SET search_path = public`,
    `REVOKE ALL … FROM PUBLIC, anon` y `GRANT EXECUTE … TO authenticated, service_role`. Cada una
    nombra `es_admin()`.
  - Los helpers de server llevan `REVOKE ALL … FROM PUBLIC, anon, authenticated` y
    `GRANT EXECUTE … TO service_role`. Las funciones de trigger llevan el mismo `REVOKE` y ningún
    `GRANT`.
- **Tablas nuevas**: `ENABLE ROW LEVEL SECURITY`, sin policies; `REVOKE ALL … FROM PUBLIC, anon,
  authenticated`; sin `GRANT` de secuencias; `scripts/grants-rest.json` no cambia; audit sólo en
  `empleado_liquidaciones`.
- **Quién**: admin, y `_empleado_visible`. El encargado no ve nada de personal: en la rendición ve
  sólo el total. El empleado propio (`es_propio`) no liquida, no anula y no se registra pagos.
- **Mensajes del server** (`RAISE EXCEPTION`, llegan en `error.message`):
  - `'Sólo un admin ve y carga el personal'` y `'Ese empleado no existe o no lo podés ver'`, los de
    siempre;
  - Uno mismo: `'Tu propia cuenta la maneja otro admin: no podés liquidarte ni registrarte pagos'`;
  - Liquidar:
    - `'Ese empleado no tiene nada para liquidar'`
    - `'El período todavía no empezó'`
    - `'Ese período ya no es el próximo a liquidar: volvé a abrir la liquidación'`
    - `'Algo cambió desde que abriste la liquidación: revisá los números antes de confirmar'`
    - `'El sueldo no puede ser negativo'`
    - `'Escribí por qué cambia el sueldo'`
    - `'El pago no puede ser negativo'`
    - `'No se le puede pagar más de lo que le toca: si le adelantás plata, cargá un adelanto'`
    - `'La fecha del pago no puede ser futura'`
    - `'Hay un dato de la liquidación con un formato inválido'`
  - La rendición del pago:
    - `'Elegí de qué rendición sale la plata: el transportista y el día'`
    - `'La rendición no puede ser de un día que todavía no llegó'`
    - `'Ese transportista no es de esta sucursal'`
    - `'Esa rendición ya está cerrada: pagá con la oficina o elegí otra'`
    - `'Ese pago salió de una rendición ya cerrada: no se revierte, corregilo con un ajuste'`
  - Anular:
    - `'Esa liquidación no existe o no la podés ver'`
    - `'Esa liquidación ya está anulada'`
    - `'Sólo se anula la última liquidación de cada empleado'`
    - `'Escribí por qué se anula'`
  - Las guardas:
    - `'Ya se liquidó hasta el %: un arreglo nuevo vale desde el día siguiente, o anulá esa liquidación'`
    - `'Ya se liquidó hasta el %: la baja va desde esa fecha, o anulá esa liquidación'`
    - con la fecha en `dd/mm/aaaa`
  - Movimientos a mano:
    - `'Un movimiento a mano es un adelanto en efectivo, un pago o un ajuste'`
    - `'Un pago de una liquidación se revierte anulando la liquidación'`
  - Motivos de ajuste, en `empleado_liquidacion_lineas.motivo`: `'Se canceló el pedido'`,
    `'El pedido volvió a pendiente'`, `'El pedido pasó a otro vendedor'`,
    `'Cambió la boleta del pedido'`, `'Línea nueva en el pedido'`.
- **Textos del front**: van en cada tarea, copiados de la maqueta. Plata con `formatPrecio`, y en los
  tests se compara contra `formatPrecio(x)`. Fechas con `fechaCompleta`. Los colores de saldo son los
  de la entrega 3: positivo verde (`emerald-700`), negativo rojo (`rose-700`).
- **Modales anidados**: `ModalLiquidar` va **dentro** de los children del `ModalBase` de la cuenta
  (regla de Radix del repo). Su schema Zod va co-locado.
- **Modelo por tarea**: la migración con **Opus**, esfuerzo high. El front con **Sonnet**, esfuerzo
  high; si el review encuentra lógica floja en una tarea, se repite esa con Opus.

## Review Focus

1. **Editar un pedido ya liquidado sin cambiarle nada.** `actualizar_pedido_items` rehace las líneas
   con ids nuevos. No tiene que aparecer ningún ajuste ni perderse el % congelado. Caso 8b del
   ensayo.
2. **Un pedido liquidado que cambia de vendedor.** Pasa seguido y hasta 4 días después de entregar.
   Al anterior le sale como ajuste y al nuevo le entra: nadie se queda con una comisión ajena ni la
   pierde. Caso 8i.
3. **Un pedido liquidado que vuelve a pendiente y se entrega de nuevo, o se cancela.** Sale como
   ajuste negativo y vuelve como positivo, con el % congelado. Ni comisión doble ni perdida. Casos
   8d y 8e.
4. **El empleado que se va a mitad de período con pedidos en la calle.** Lo que se entregue después
   se liquida con sueldo 0, sin perderse. Caso 4.
5. **Un sueldo pagado con una rendición que después se cierra.** Anular la liquidación no le cambia
   el efectivo a entregar a esa rendición, y el pago no se cuenta dos veces al volver a liquidar.
   Caso 17.

---

### Task 1: Tipos y reglas puras de la liquidación

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/types/personal.ts`, `src/utils/personal.ts` y `src/utils/personal.test.ts`.
- Modify: `src/components/vistas/VistaPersonal.tsx`, sólo para pasarles `hoy` a `filtrarPersonal` y
  `contarPersonal`: su `const hoy` sube antes de los `useMemo`. Lo demás de la vista es de la Tarea 6.
- Modify: los fixtures de `Empleado`, `MovimientoEmpleado` y `CuentaEmpleado` en
  `ModalCuentaEmpleado.test.tsx`, `VistaPersonal.test.tsx`, `usePersonalQuery.test.tsx` y los demás
  que marque `tsc`.

**Interfaces (Produces):**
- **`src/types/personal.ts`** suma:
  ```ts
  export type TipoMovimientoEmpleado =
    | 'mercaderia' | 'reintegro' | 'adelanto' | 'ajuste'
    | 'sueldo' | 'comision' | 'ajuste_comision' | 'pago'
  export type FiltroPersonal = 'todos' | 'para_liquidar' | 'con_saldo' | 'inactivos'
  export type OrigenPagoEmpleado = 'oficina' | 'rendicion'
  export type AvisoLiquidacion = 'comisiona_sin_usuario' | 'arreglo_cambia' | 'periodo_parcial'
  export interface PeriodoLiquidacion { desde: string; hasta: string; frecuencia: FrecuenciaSueldo }
  export interface PeriodoPendiente extends PeriodoLiquidacion {
    mas_vencidos: number               // períodos terminados sin liquidar, además de éste
  }
  export interface RendicionDelPago { transportista_nombre: string; fecha: string }
  // Empleado suma: periodo: PeriodoPendiente | null
  // MovimientoEmpleado suma:
  //   liquidacion: (PeriodoLiquidacion & { id: number; pedidos: number; anulada: boolean }) | null
  //   rendicion: RendicionDelPago | null
  // CuentaEmpleado suma: liquidaciones: LiquidacionResumen[]
  export interface LiquidacionResumen extends PeriodoLiquidacion {
    id: number; sueldo: number; comision: number; ajuste: number
    a_pagar: number; pagado: number; fecha_pago: string
    rendicion: RendicionDelPago | null
    anulada_at: string | null; motivo_anulacion: string | null
    creado_por_nombre: string | null
    es_la_ultima: boolean              // la última vigente del empleado
  }
  export interface PedidoLiquidado { pedido_id: number; fecha: string; entregado_el: string; cliente: string; base: number; comision: number }
  export interface AjusteLiquidado { pedido_id: number; motivo: string; base: number; comision: number }
  export interface MovimientoDelPeriodo { id: number; fecha: string; tipo: TipoMovimientoEmpleado; monto: number; observacion: string | null; pedido_id: number | null; gasto: MovimientoEmpleado['gasto']; revierte_id: number | null; por_el_mismo: boolean }
  export interface VistaPreviaLiquidacion {
    periodo: PeriodoPendiente
    puede_liquidar: boolean            // desde <= hoy y no es el propio
    en_curso: boolean                  // hoy <= hasta
    sueldo: { propuesto: number; arreglo_desde: string | null }
    comisiones: { total: number; base: number; detalle: PedidoLiquidado[] }
    ajustes: { total: number; detalle: AjusteLiquidado[] }
    movimientos: MovimientoDelPeriodo[]
    saldo_anterior: number
    saldo_actual: number
    a_pagar: number                    // con el sueldo propuesto
    avisos: AvisoLiquidacion[]
  }
  export interface DetalleLiquidacion extends LiquidacionResumen {
    sueldo_propuesto: number; motivo_sueldo: string | null
    pedidos: PedidoLiquidado[]; ajustes: AjusteLiquidado[]
  }
  export interface PlataDelPago {
    origen_pago: OrigenPagoEmpleado
    rendicion_transportista_id: string | null
    rendicion_fecha: string | null
  }
  export interface LiquidarPayload extends PlataDelPago {
    desde: string; hasta: string
    sueldo: number; motivo_sueldo: string | null
    pago: number; fecha_pago: string
    a_pagar_esperado: number
  }
  // MovimientoManualPayload: tipo pasa a 'adelanto' | 'ajuste' | 'pago'; el pago va positivo,
  // y suma los campos opcionales de PlataDelPago
  ```
- **`src/utils/personal.ts`** suma o cambia:
  - `textoPeriodo(p: PeriodoLiquidacion): string`:
    - semanal: `'Semana {dd/mm} al {dd/mm}'`;
    - mensual de mes entero: `'{Mes} {aaaa}'`;
    - mensual parcial: `'{dd/mm} al {dd/mm}'`.
  - `paraLiquidar(p: PeriodoPendiente | null, hoy: string): boolean`: `p.desde <= hoy` y
    `p.hasta − hoy <= DIAS_ANTES_DE_CERRAR`, en días de calendario (decisión 14). La constante vale
    `2`, con un comentario de por qué.
  - `aPagar(v: VistaPreviaLiquidacion, sueldo: number): number`: `saldo_actual + sueldo +
    comisiones.total + ajustes.total`, redondeado a 2.
  - `conceptoDeMovimiento`, con los tipos nuevos:
    - `sueldo`: `{ titulo: 'Sueldo fijo', detalle }`, con el período, más `' · {observacion}'` si hay;
    - `comision`: `'Comisión'`, con `'{n} pedido(s) · {período}'`;
    - `ajuste_comision`: `'Ajuste de comisión'`, con el período;
    - `pago` de una liquidación: `'Pago'`, con `'Liquidación {período} · la pagó la oficina'`, o
      `'Liquidación {período} · {rendición}'`. Si quedó de una anulada, `'Liquidación {período},
      anulada · {rendición}'`;
    - `pago` suelto: `'Pago'`, con la observación, o `'Pago suelto · lo pagó la oficina'`, o
      `'Pago suelto · {rendición}'`;
    - `{rendición}` es `'salió de la rendición de {chofer} del {dd/mm}'`;
    - con `revierte_id`: `'Revierte un pago'`, `'Revierte un sueldo'`, `'Revierte una comisión'` y
      `'Revierte un ajuste de comisión'`, y los dos que ya hay. La observación es el detalle.
  - `filtrarPersonal` y `contarPersonal` reciben `hoy: string` y suman `para_liquidar`:
    `paraLiquidar(e.periodo, hoy)`.
  - `errorDeMovimiento`: el pago pide monto > 0 y no pide observación.
  - `errorDeSueldo(sueldo: number, propuesto: number, motivo: string | null): string | null`: los
    mensajes del server. Sin diferencia, no pide motivo.
  - `errorDePago(pago: number, tope: number, fecha: string, hoy: string): string | null`: los
    mensajes del server. `tope` es lo que da `aPagar`.

- [ ] **Step 1: Tests**, con estos valores:
  - `textoPeriodo`:
    - `{ desde: '2026-10-26', hasta: '2026-11-01', frecuencia: 'semanal' }` da `'Semana 26/10 al 01/11'`;
    - `{ desde: '2026-10-01', hasta: '2026-10-31', frecuencia: 'mensual' }` da `'Octubre 2026'`;
    - `{ desde: '2028-02-01', hasta: '2028-02-29', frecuencia: 'mensual' }` da `'Febrero 2028'`;
    - `{ desde: '2026-10-15', hasta: '2026-10-31', frecuencia: 'mensual' }` da `'15/10 al 31/10'`.
  - `paraLiquidar`, con `desde: '2026-10-26', hasta: '2026-11-01'`:
    - hoy `'2026-10-29'` (jueves) da `false`;
    - hoy `'2026-10-30'` (viernes) da `true`;
    - hoy `'2026-11-05'` da `true`;
    - `null` da `false`;
    - un período que no empezó da `false`.
  - `aPagar`, con saldo −22.800, comisiones 368.600 y ajustes −1.240: con sueldo 650.000 da 994.560.
  - `conceptoDeMovimiento`:
    - un sueldo de esa semana da `{ titulo: 'Sueldo fijo', detalle: 'Semana 26/10 al 01/11' }`, y con
      observación `'Faltó dos días'`, `'Semana 26/10 al 01/11 · Faltó dos días'`;
    - una comisión de 142 pedidos da `'142 pedidos · Semana 26/10 al 01/11'`, y de 1 pedido, `'1 pedido · …'`;
    - un pago con liquidación da `'Liquidación Semana 26/10 al 01/11 · la pagó la oficina'`;
    - el mismo con rendición de `'Martín Sosa'` del `'2026-10-30'` da
      `'Liquidación Semana 26/10 al 01/11 · salió de la rendición de Martín Sosa del 30/10'`;
    - de una anulada da `'Liquidación Semana 26/10 al 01/11, anulada · salió de la rendición de Martín Sosa del 30/10'`;
    - un pago sin liquidación ni observación da `'Pago suelto · lo pagó la oficina'`;
    - una reversión de un pago da `'Revierte un pago'`, con la observación como detalle.
  - `filtrarPersonal(…, 'para_liquidar', '', hoy)` deja sólo a los de período para liquidar, y
    `contarPersonal` los cuenta.
  - `errorDeMovimiento`: un pago de 0 da `'El monto tiene que ser mayor a cero'`; un pago de 1000 sin
    observación da `null`.
  - `errorDeSueldo`:
    - `(-1, 70000, null)` da `'El sueldo no puede ser negativo'`;
    - `(70000, 70000, null)` da `null`;
    - `(50000, 70000, null)` y `(50000, 70000, '  ')` dan `'Escribí por qué cambia el sueldo'`;
    - `(50000, 70000, 'Faltó dos días')` da `null`.
  - `errorDePago`:
    - `(-1, 100, hoy, hoy)` da `'El pago no puede ser negativo'`;
    - `(101, 100, hoy, hoy)` da el mensaje de "más de lo que le toca";
    - `(0, -500, hoy, hoy)` da `null`: el que debe no cobra;
    - una fecha mañana da `'La fecha del pago no puede ser futura'`.
- [ ] **Step 2: Ver que fallan.** `npx vitest run src/utils/personal.test.ts`
- [ ] **Step 3: Implementar; pasar; typecheck y lint.**
- [ ] **Step 4: Commit** `feat(personal): tipos y reglas puras de la liquidación`.

---

### Task 2: Migración — liquidaciones y comisiones congeladas

Modelo: Opus, esfuerzo high. Cambia `calcular_comisiones`, que alimenta la vista Comisiones y el
reporte gerencial, y `obtener_resumen_rendiciones`, que alimenta el control de rendiciones. Antes de
escribir, leer `migrations/CLAUDE.md`, el `CLAUDE.md` de la raíz y el comentario del 02/11 en #1332.

**Files:**
- Create: `migrations/NNN_gastos_5_liquidaciones.sql` y `scripts/test-gastos-5.sql`.
- Modify: `scripts/test-gastos-4.sql`: el caso que espera `'Un movimiento a mano es un adelanto en
  efectivo o un ajuste'` (cerca de la línea 829) espera el mensaje nuevo.
- Modify: `src/test/rpcsSoloServidor.test.ts`, que suma con `'NNN_gastos_5'` los helpers y las
  funciones de trigger de abajo.
- Modify: `CLAUDE.md`, en Convenciones, junto a "Venta por vendedor":
  ```
  - **La comisión de un pedido es una: `_comision_lineas`** (gastos 5). La usan
    `calcular_comisiones` y la liquidación; un cálculo nuevo por pedido sale de ahí, no de una copia.
    Una línea congelada se identifica por producto + combo + origen (`clave`), nunca por
    `pedido_items.id`: `actualizar_pedido_items` borra y reinserta las líneas. Lo pagado es la foto
    (`empleado_liquidacion_lineas`, un libro de deltas, con el vendedor de cada línea: si cambia
    `pedidos.usuario_id`, al anterior le sale como ajuste). `calcular_comisiones` es un cálculo y va
    por `pedidos.fecha`, así que su total puede no coincidir con lo liquidado.
    El efectivo a entregar resta también los pagos al personal de esa rendición
    (`total_pagos_personal`), que el encargado ve sólo como un total.
  ```

**Interfaces (Produces):**

**Guarda `$vivas$`**: las siete funciones de la tabla de arriba, con el md5 **de prod**, con el CR.
Re-consultarlos antes de escribir. Las reescrituras parten del cuerpo del archivo 430 (LF), de la
421 para `calcular_comisiones`, y del `prosrc` vivo para `obtener_resumen_rendiciones` y
`auditoria_comision_mes_cerrado`. Esta última es de la 434: su archivo no está en esta rama.

**Cambios a `empleado_movimientos`**:
- suma `liquidacion_id bigint REFERENCES empleado_liquidaciones(id)`;
- suma `rendicion_transportista_id uuid REFERENCES perfiles(id)`, `rendicion_fecha date` y
  `rendicion_sucursal_id bigint REFERENCES sucursales(id)`, la rendición de la que salió un pago;
- el CHECK de `tipo` suma `'sueldo', 'comision', 'ajuste_comision', 'pago'`;
- `empleado_movimientos_revierte_a_mano` pasa a aceptar `revierte_id` en todos menos `mercaderia` y
  `reintegro`;
- nuevos:
  - `tipo NOT IN ('sueldo','comision','ajuste_comision') OR liquidacion_id IS NOT NULL`;
  - `tipo <> 'pago' OR revierte_id IS NOT NULL OR monto < 0`;
  - `(rendicion_fecha IS NULL) = (rendicion_transportista_id IS NULL)` y
    `(rendicion_fecha IS NULL) = (rendicion_sucursal_id IS NULL)`;
  - `rendicion_fecha IS NULL OR tipo = 'pago'`.
- índices `(liquidacion_id) WHERE liquidacion_id IS NOT NULL` y
  `(rendicion_sucursal_id, rendicion_fecha) WHERE rendicion_fecha IS NOT NULL`.

**`empleado_liquidaciones`**:
- `id` identity y `empleado_id bigint NOT NULL REFERENCES empleados(id)`;
- `desde date NOT NULL`, `hasta date NOT NULL`, con `CHECK (hasta >= desde)`;
- `frecuencia text NOT NULL CHECK (frecuencia IN ('semanal','mensual'))`;
- `sucursal_al_liquidar bigint NOT NULL REFERENCES sucursales(id)` y `de_las_dos boolean NOT NULL`,
  la foto del empleado al liquidar. No se llama `sucursal_id` a propósito, y un comentario lo dice:
  es una foto, no la sucursal de la fila. Con ese nombre, `empleado_id` sería un par de
  `auditoria_sucursal_cruzada`, y una FK compuesta frenaría cambiarle la sucursal al empleado;
- `saldo_anterior numeric(14,2) NOT NULL`, `a_pagar numeric(14,2) NOT NULL`;
- `pagado numeric(14,2) NOT NULL CHECK (pagado >= 0)` y `fecha_pago date NOT NULL`;
- `creado_por uuid NOT NULL`, `created_at`;
- `anulada_at timestamptz`, `anulada_por uuid`, `motivo_anulacion text`, con
  `CHECK ((anulada_at IS NULL) = (motivo_anulacion IS NULL))`;
- índice único `(empleado_id, desde) WHERE anulada_at IS NULL`.

**`empleado_liquidacion_conceptos`**: la base para sumar aguinaldo y lo demás sin rehacer tablas.
- `id` identity y `liquidacion_id bigint NOT NULL REFERENCES empleado_liquidaciones(id)`;
- `concepto text NOT NULL CHECK (concepto IN ('sueldo','comision','ajuste_comision'))`;
- `monto numeric(14,2) NOT NULL`;
- `detalle jsonb NOT NULL DEFAULT '{}'`. En el sueldo: `{ arreglo_id, propuesto, motivo }`. En la
  comisión y el ajuste: `{ pedidos, base }`.
- Un concepto por tipo, y el de sueldo va aunque dé 0: guarda el propuesto y el motivo.

**`empleado_liquidacion_lineas`**: la foto. Sus montos son deltas.
- `id` identity, `liquidacion_id` y `empleado_id`, con sus FKs;
- `pedido_id bigint NOT NULL REFERENCES pedidos(id)`, RESTRICT: un pedido liquidado no se borra;
- `usuario_id uuid NOT NULL`, la foto del vendedor del pedido al congelar (decisión 15);
- `clave text NOT NULL`, `producto_id bigint`, `combo_id bigint`, `origen_precio text`;
- `regla_id bigint`, sin FK, NULL si fue el default;
- `pct numeric(5,2) NOT NULL`;
- `base numeric(16,6) NOT NULL`, `comision numeric(16,6) NOT NULL`;
- `tipo text NOT NULL CHECK (tipo IN ('inicial','linea_nueva','ajuste'))`;
- `motivo text`, con `CHECK ((tipo = 'inicial') = (motivo IS NULL))`;
- `entregado_el date NOT NULL`, la foto del día de entrega;
- `vigente boolean NOT NULL DEFAULT true`;
- índice único `(pedido_id, clave, usuario_id) WHERE tipo <> 'ajuste' AND vigente`;
- índices `(empleado_id) WHERE vigente` y `(liquidacion_id)`.

Un `COMMENT` en cada tabla nueva dice para qué es y que es sólo de server.

**Helpers de server:**
- **`_comision_lineas(p_pedido_ids bigint[]) RETURNS TABLE (pedido_id bigint, usuario_id uuid,
  sucursal_id bigint, fecha date, producto_id bigint, combo_id bigint, origen_precio text,
  categoria_id uuid, clave text, base numeric, pct numeric, regla_id bigint)`**, `LANGUAGE sql
  STABLE`. Una fila por línea, con los CTE `ped`, `vend`, `pct_mes`, `it` y `con_pct` de
  `calcular_comisiones`, sin el filtro de fechas ni de sucursales:
  - `ped` conserva `estado = 'entregado'`, `canal <> 'cambio'`, sin VB y `usuario_id IN perfiles`;
  - `regla_id` sale de la misma subconsulta que el `pct`, y es NULL con el default;
  - `clave` es `COALESCE(producto_id::text,'-') || '|' || COALESCE(combo_id::text,'-') || '|' || COALESCE(origen_precio,'-')`.
- **`calcular_comisiones`**: el mismo cuerpo, con `con_pct` reemplazado por
  `SELECT … FROM _comision_lineas(ARRAY(SELECT p.id FROM pedidos p WHERE p.fecha BETWEEN p_desde AND
  p_hasta AND p.sucursal_id = ANY(v_sucursales)))`. El JSON de salida no cambia en nada.
- **`_empleado_dia_de_entrega(p_fecha_entrega timestamptz, p_fecha date) RETURNS date IMMUTABLE`**:
  `COALESCE((p_fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, p_fecha)`. El
  COALESCE es para que un entregado sin `fecha_entrega` no quede sin comisionar para siempre: los 6
  que hay son de antes de cualquier arranque.
- **`_periodo_que_contiene(p_dia date, p_frecuencia text) RETURNS TABLE (inicio date, fin date)`
  IMMUTABLE**: lunes a domingo, o día 1 al último.
- **`_empleado_ultima_hasta(p_empleado_id bigint) RETURNS date STABLE`**: el mayor `hasta` vigente.
- **`_empleado_periodo_siguiente(p_e empleados) RETURNS TABLE (desde date, hasta date, frecuencia
  text, mas_vencidos integer) STABLE`**:
  - `desde` es `ultima_hasta + 1`, o el arranque (`min(vigente_desde)`) si no liquidó nunca;
  - la frecuencia es la del arreglo vigente a `desde`;
  - `hasta` es el `fin` de `_periodo_que_contiene(desde, frecuencia)`. **La baja no lo corta**
    (decisión 4);
  - `mas_vencidos` cuenta los períodos siguientes con `fin < hoy`, recorriéndolos con la frecuencia
    de cada uno, y no pasa de la baja;
  - sin arreglos, no devuelve filas.
- **`_liquidacion_sueldo_propuesto(p_e empleados, p_desde date, p_hasta date) RETURNS TABLE
  (arreglo_id bigint, arreglo_desde date, sueldo numeric, avisos text[]) STABLE`**:
  - el arreglo es el vigente a `p_desde`;
  - `sueldo` es el suyo entero, o 0 si `p_desde > fecha_baja`;
  - `arreglo_cambia` si otro arreglo empieza entre `p_desde + 1` y `p_hasta`;
  - `periodo_parcial` si `p_desde` no es el `inicio` de `_periodo_que_contiene`, o si `fecha_baja`
    cae entre `p_desde` y `p_hasta − 1`.
- **`_liquidacion_lineas(p_e empleados, p_hasta date) RETURNS TABLE (pedido_id bigint, usuario_id
  uuid, clave text, producto_id bigint, combo_id bigint, origen_precio text, regla_id bigint, pct
  numeric, base numeric, comision numeric, tipo text, motivo text, entregado_el date) STABLE`**. Las
  dos mitades:
  - **`inicial`**: los pedidos con `usuario_id` el del empleado, de sus sucursales (`sucursal_id =
    e.sucursal_id OR e.de_las_dos`), con día de entrega entre el arranque y `p_hasta`, cuyo arreglo
    vigente ese día comisiona, y sin filas vigentes **con ese mismo vendedor**
    (`l.usuario_id = p.usuario_id`). Con otro vendedor en las filas, el pedido cambió de manos y
    entra. Con el mismo, ya se liquidó, aunque el usuario se haya revinculado a otro empleado. Las
    líneas de `_comision_lineas`, agrupadas por `(pedido_id, clave)` con `SUM(base)`.
  - **`ajuste` y `linea_nueva`**: los pedidos con filas vigentes de este empleado. Un `FULL JOIN`
    entre lo congelado (`SUM(base)` de las vigentes por `(pedido_id, clave)`, con su `pct`, su
    `regla_id` y su `usuario_id`) y lo vivo (`_comision_lineas` agrupado igual). Lo vivo cuenta sólo
    si `pedidos.usuario_id` sigue siendo el de la foto; si no, vale 0:
    - congelada, con viva o sin ella: `base = viva − congelada`, `pct` congelado, tipo `ajuste`. Si
      `abs(comision) < 0.005`, no hay fila;
    - sólo viva: `linea_nueva`, con el `pct` y la `regla_id` de `_comision_lineas`.
    - el `motivo`, en este orden: `linea_nueva` da `'Línea nueva en el pedido'`; otro vendedor,
      `'El pedido pasó a otro vendedor'`; y por `pedidos.estado`: `cancelado`,
      `'Se canceló el pedido'`; `pendiente` o `asignado`, `'El pedido volvió a pendiente'`;
      `entregado`, `'Cambió la boleta del pedido'`.
  - `comision = base * pct / 100`. Un pedido pagado entero con adelanto no tiene líneas vivas: si
    estaba congelado, sale como ajuste; si no, no entra.
- **`_liquidacion_json(p_e empleados, p_desde date, p_hasta date, p_sueldo numeric DEFAULT NULL)
  RETURNS jsonb STABLE`**: la forma de `VistaPreviaLiquidacion` de la Tarea 1, sin `periodo`,
  `puede_liquidar` ni `en_curso`. `p_sueldo` NULL usa el propuesto:
  - `comisiones` (`detalle` por pedido, con cliente por `nombre_fantasia`) y `ajustes` (por pedido y
    motivo), con el total redondeado a 2;
  - `movimientos`: los posteriores al último de su última liquidación vigente, que no sean de una
    liquidación, o que sean un pago de una anulada sin revertir. Con
    `por_el_mismo = (creado_por = usuario_id)`;
  - `saldo_actual` es la suma del libro, y `saldo_anterior = saldo_actual − SUM(movimientos)`;
  - `a_pagar = round(saldo_actual + sueldo + comisión + ajustes, 2)`;
  - `avisos`: los de `_liquidacion_sueldo_propuesto`, más `comisiona_sin_usuario` si algún arreglo
    del período comisiona y no hay usuario.
- **`_pago_de_rendicion(p_datos jsonb, p_fecha_pago date) RETURNS TABLE (transportista_id uuid,
  fecha date, sucursal_id bigint)`**, de escritura. Con `origen_pago` `'oficina'` no devuelve filas.
  Con `'rendicion'`, en este orden: transportista y día presentes, día no futuro, transportista de
  `current_sucursal_id()`, `_rendicion_bloquear` con `_rendicion_clave`, y
  `control_rendicion_cerrado` en falso. Cualquier otro `origen_pago` da el mensaje de formato.
- **`personal_por_mes(p_desde date, p_hasta date, p_sucursales bigint[]) RETURNS TABLE (mes date,
  empleado_id bigint, sucursal_id bigint, compartido boolean, concepto text, monto numeric)` STABLE**,
  con el molde de `gastos_por_mes` y la decisión 10. Trae lo de `p_sucursales` y todos los
  compartidos. Un sueldo de un período que cruza de mes se reparte por días, y el último mes absorbe
  el redondeo.

**Triggers:**
- **`empleado_arreglos_periodo_cerrado()`**, `BEFORE INSERT OR UPDATE OF vigente_desde, sueldo,
  frecuencia, comisiona ON empleado_arreglos`: si `NEW.vigente_desde <= ultima_hasta`, el mensaje de
  la guarda.
- **`empleados_periodo_cerrado()`**, `BEFORE UPDATE OF fecha_baja ON empleados`: si
  `NEW.fecha_baja < ultima_hasta`, el mensaje de la guarda.

**Reescrituras:**
- **`_empleado_json`** suma `'periodo'`: sale de `_empleado_periodo_siguiente`, con `mas_vencidos`.
  Es NULL si el `desde` es posterior a `fecha_baja` y no quedan entregados sin liquidar del usuario.
  Los ajustes no se miran acá, para no recalcular en cada tarjeta: la ficha los ve por la vista previa.
- **`obtener_cuenta_empleado`** suma `'liquidaciones'` (`LiquidacionResumen`, de más nueva a más
  vieja, con las anuladas) y, en cada movimiento, `'liquidacion'` (`{ id, desde, hasta, frecuencia,
  pedidos, anulada }` o NULL) y `'rendicion'` (`{ transportista_nombre, fecha }` o NULL).
- **`auditoria_comision_mes_cerrado`**, parche por ancla sobre el cuerpo vivo, sólo en el último
  sumando (`CREATE OR REPLACE`, conserva sus grants): el `bool_and` de `comision_pct_vigencias` y
  `baja_desde` pasa a mirar `_comision_lineas`, que es donde va a estar esa lógica, y se suma que
  `calcular_comisiones` nombre `_comision_lineas`. Sigue por nombre y sin cast, y una función que
  no exista da 1. Con esto, ni el cálculo ni el helper pueden dejar de leer lo que regía.
- **`registrar_movimiento_empleado`** acepta `'pago'`: `> 0`, se guarda negativo, y la observación
  es opcional. No tiene tope. Pasa por `_pago_de_rendicion`, y con rendición su fecha es la de la
  rendición. El adelanto y el ajuste ignoran esas claves.
- **`revertir_movimiento_empleado`** acepta un `pago` con `liquidacion_id IS NULL`, y copia su
  rendición. Con liquidación da su mensaje. Con rendición, toma el lock, y si está cerrada da su
  mensaje. `'Sólo se revierte un movimiento cargado a mano'` sigue para el resto.
- **`obtener_resumen_rendiciones`**: suma la columna `total_pagos_personal numeric`, al final de la
  tabla. Como cambia el retorno, va `DROP FUNCTION` y `CREATE`, reponiendo sus `REVOKE` y `GRANT`. Un
  CTE `pagos_personal_agg`, con el molde de `gastos_agg`: `−SUM(m.monto)` por
  `(rendicion_transportista_id, rendicion_fecha)`, de `rendicion_sucursal_id = v_sucursal_id`, en el
  rango y con el mismo filtro de transportista. Suma también a `fechas_activas`: un día con sólo un
  pago al personal tiene que aparecer en la grilla (mig 245). No devuelve nombres.

**RPCs del front:**
- **`previsualizar_liquidacion(p_empleado_id bigint) RETURNS jsonb`** (STABLE), con rol y visible.
  Sin arreglos da NULL. Toma `_empleado_periodo_siguiente` y `_liquidacion_json`. Si el `desde` es
  posterior a la baja y comisiones y ajustes dan 0, da NULL. Le suma `periodo`, `puede_liquidar`
  (`desde <= hoy` y no propio) y `en_curso` (`hoy <= hasta`).
- **`liquidar_empleado(p_empleado_id bigint, p_liquidacion jsonb) RETURNS bigint`**, con
  `LiquidarPayload`:
  1. Rol, y el empleado `FOR UPDATE` y visible.
  2. No propio.
  3. Formato.
  4. El período pedido es el de `_empleado_periodo_siguiente`; si no, su mensaje. `desde <= hoy`.
     Después de la baja y con todo en 0, `'Ese empleado no tiene nada para liquidar'`.
  5. `sueldo >= 0`, y si difiere del propuesto, `motivo_sueldo` obligatorio.
  6. `_liquidacion_json` con ese sueldo: su `a_pagar` tiene que ser `a_pagar_esperado`, redondeados a
     2.
  7. `pago` entre 0 y `GREATEST(a_pagar, 0)`, y `fecha_pago <= hoy`.
  8. Con `pago > 0`, `_pago_de_rendicion`. Con rendición, `fecha_pago` pasa a ser su día.
  9. Inserta la liquidación, el concepto de sueldo, los de comisión y ajuste si no dan 0, y las
     líneas con `_liquidacion_lineas`.
  10. Inserta los movimientos, en este orden y sin los que dan 0: `sueldo` con `motivo_sueldo` como
      observación, `comision`, `ajuste_comision`, los tres con `fecha = LEAST(hasta, hoy)`; y `pago`
      con `fecha_pago`, monto negativo y su rendición. Todos con `liquidacion_id`.
- **`anular_liquidacion(p_liquidacion_id bigint, p_motivo text) RETURNS void`**:
  1. Rol, el empleado `FOR UPDATE` y visible; no propio.
  2. No está anulada, es la vigente de mayor `desde` y hay motivo.
  3. Por cada movimiento suyo, otro con `−monto`, `revierte_id`, el mismo tipo, `liquidacion_id`,
     la fecha de hoy y el motivo como observación. El `pago` de una rendición toma el lock: si la
     rendición está pendiente se revierte con sus mismos datos, y si está cerrada **queda sin
     revertir** (decisión 13).
  4. Pone `vigente = false` en sus líneas, y `anulada_at`, `anulada_por` y `motivo_anulacion`.
- **`obtener_liquidacion(p_liquidacion_id bigint) RETURNS jsonb`** (STABLE): con rol y visible, la
  forma de `DetalleLiquidacion`, desde lo congelado y no desde lo vivo.

**Verificación estructural** al final (`DO $verif$`), con el molde de la 430: RLS sin policies, sin
privilegios, triggers presentes, helpers no alcanzables, RPCs alcanzables sólo por `authenticated`.
`obtener_resumen_rendiciones` conserva sus EXECUTE.

**Prueba de que `calcular_comisiones` no se movió.** Dentro de la migración, con el molde del
`DO $ensayo$` de la 241 (claims de un admin de las dos sucursales): antes del `CREATE OR REPLACE`
guarda en una tabla temporal `calcular_comisiones` de cada mes de 2026 para las sucursales 1 y 2, y
después compara `jsonb` contra `jsonb`. Si un mes difiere, la migración aborta.

- [ ] **Step 1: Ensayo `scripts/test-gastos-5.sql`.** Elige a `a1`, `at`, `ad`, `en`, `tr`, un
  preventista `P1` de Tucumán y un cliente `C1`, y crea como postgres los pedidos que necesita. `L`
  es el lunes de hace cuatro semanas. Aserciones:
  1. **Una sola comisión**: en octubre de 2026, la suma de `_comision_lineas` por vendedor da la
     `base` y la `comision` de `calcular_comisiones`, redondeadas a 2.
  2. **Períodos**:
     - `E1`, semanal desde `L`, propone `(L, L+6)`, y después de liquidar, `(L+7, L+13)`;
     - un mensual da del 1 al último;
     - con arranque miércoles, de ese miércoles al domingo.
  3. **Sueldo**:
     - semanal de 70.000 propone 70.000, sin avisos;
     - con arranque miércoles propone 70.000 entero, con `periodo_parcial`;
     - de 70.000 a 84.000 el miércoles propone 70.000, con `arreglo_cambia`, y la semana siguiente
       84.000;
     - corregido a 50.000 con motivo deja un movimiento de +50.000 con ese motivo, y el concepto
       guarda `propuesto` 70.000;
     - corregido sin motivo, o negativo, dan su mensaje;
     - corregido a 0 con motivo no crea movimiento de sueldo, y sí el concepto.
  4. **Baja**:
     - baja el miércoles: la semana propone el sueldo entero, con `periodo_parcial`;
     - un pedido entregado el viernes después de liquidar esa semana sigue sin liquidar. Abre un
       período con sueldo 0 que lo liquida;
     - sin nada pendiente, `previsualizar_liquidacion` da NULL y `liquidar_empleado` rechaza.
  5. **Reactivar**: baja y reactivar no dejan ningún registro de días. El período siguiente propone
     el sueldo entero, y su pedido entregado en el medio comisiona.
  6. **Qué entra**:
     - entregado en el período: sí;
     - antes del arranque: no;
     - cancelado, canal `cambio` o VB: no;
     - de otro usuario u otra sucursal: no;
     - entregado con el arreglo que no comisiona: no, ni después de que empiece a comisionar;
     - tomado el viernes y entregado el lunes: en la semana del lunes;
     - `fecha_entrega` a las 22:30 argentinas del domingo: en esa semana;
     - sin `fecha_entrega`: por `pedidos.fecha`;
     - pagado en parte con adelanto: con el factor; entero: no entra.
  7. **Congelar**: con 2 %, una línea de 100.000 deja `base` 100.000, `pct` 2, comisión 2.000 y
     `regla_id` NULL. Una regla aplicable deja su id y su %. Un producto en combo y suelto son dos
     claves; dos líneas iguales son una sola, sumada.
  8. **Ajustes**, sobre un pedido congelado, en la liquidación siguiente:
     - a. una salvedad que baja la base 10.000 da −200, y cambia el % vigente a 5 sin que importe;
     - b. borrar y reinsertar sus líneas iguales, con ids nuevos, **no da ningún ajuste**;
     - c. una línea nueva usa la regla vigente a `pedidos.fecha`, con tipo `linea_nueva`;
     - d. cancelarlo da −lo congelado, con `'Se canceló el pedido'`;
     - e. volver a pendiente da el negativo, y entregarlo de nuevo, el positivo, con el % congelado;
     - f. un adelanto de sueldo cargado después baja la base por el factor;
     - g. subir el % o dar de baja una regla no da ningún ajuste;
     - h. con el usuario revinculado a `E2`, sin cambiar el vendedor del pedido: el ajuste va a `E1`,
       y `E2` no recibe el pedido como nuevo;
     - i. con `actualizar_preventista_pedido` hacia el usuario de `E2`: `E1` recibe −lo congelado con
       `'El pedido pasó a otro vendedor'`, y `E2` lo liquida como `inicial`. Si vuelve a `E1`, a `E2`
       le sale y a `E1` le vuelve con el % congelado. El neto de cada uno da lo correcto.
  9. **Pago**:
     - pagar todo deja el saldo en 0;
     - parcial deja la diferencia a favor;
     - 0 no crea movimiento de pago;
     - más de lo que toca, negativo o con fecha futura dan su mensaje;
     - un `a_pagar_esperado` viejo da `'Algo cambió…'`, y nada queda escrito;
     - el que debe (`a_pagar < 0`) liquida con pago 0.
  10. **Orden y en curso**:
      - un período que no es el siguiente da su mensaje;
      - uno que no empezó, también;
      - el período en curso se liquida; un pedido entregado después entra en el siguiente;
      - reintentar la misma confirmación da `'Ese período ya no es el próximo…'`, sin duplicar;
      - el índice único frena dos liquidaciones vigentes del mismo período.
  11. **Anular**:
      - sólo la última; sin motivo, o ya anulada, dan su mensaje;
      - el saldo vuelve exacto, y cada movimiento tiene su reversión;
      - los pedidos quedan libres, y volver a liquidar da el mismo `a_pagar`;
      - anular una liquidación con ajustes los deja como pendientes de nuevo.
  12. **Guardas**:
      - un arreglo con fecha dentro de lo liquidado, o corregir uno así, dan su mensaje;
      - una baja anterior al `hasta`, también;
      - después de anular, ambos andan.
  13. **Uno mismo**: `a1` sobre su propio empleado no previsualiza con `puede_liquidar`, no liquida,
      no anula y no se carga un pago. La vista previa marca `por_el_mismo` en un movimiento que
      disparó él.
  14. **Mostrar de más**: `at` no ve a un empleado de Tucumán en ninguna RPC nueva, `en` recibe 42501,
      `a1` no ve a uno de las dos. El JSON de `empleados_para_elegir` sigue sin sueldos.
  15. **Pago suelto**: se registra negativo, se revierte, y el de una liquidación no se revierte.
  16. **`personal_por_mes`**: un sueldo semanal que cruza de mes suma lo mismo que su concepto, con
      el último mes absorbiendo el redondeo; uno de las dos va como compartido; una liquidación
      anulada no cuenta.
  17. **Rendición**:
      - liquidar con 100.000 de la rendición de `tr` de hoy, pendiente: `total_pagos_personal` da
        100.000 y el movimiento guarda la rendición;
      - un día con sólo ese pago aparece en la grilla;
      - `en` lee ese total en `obtener_resumen_rendiciones` y ninguna columna trae un nombre del
        empleado; `tr` ve sólo su fila;
      - sin transportista, con día futuro o con un transportista de otra sucursal dan su mensaje;
      - una rendición cerrada da su mensaje;
      - un pago suelto de rendición suma al total; el adelanto no acepta rendición;
      - anular con la rendición pendiente: el total vuelve a 0;
      - anular con la rendición cerrada: el pago queda, el total no cambia, el saldo lo refleja y la
        nueva liquidación lo descuenta, con el pago en `movimientos`;
      - revertir un pago suelto de una rendición cerrada da su mensaje;
      - `ad`, con la sucursal 2 activa, paga a un empleado de Tucumán con una rendición de la sucursal
        2. `a1`, que no tiene esa sucursal, anula o revierte y recibe 42501, y nada queda escrito;
      - con 0 pagos, `efectivo − gastos` da lo mismo que antes para todas las rendiciones de octubre.
  18. **Permisos**: `anon` no ejecuta nada nuevo; `authenticated` no ejecuta los helpers ni los
      triggers; las tablas no tienen privilegios; `auditoria_definer_sin_rol()` no lista nada nuevo;
      `auditoria_sucursal_cruzada()` no suma ningún par.
  19. **Invariantes**: `LIQ-A`, `LIQ-B` y `LIQ-C` de la decisión 11 dan 0 al final de todo lo anterior,
      y `auditoria_comision_mes_cerrado()` da 0.
- [ ] **Step 2: Ensayo solo en prod → `ENSAYO FALLÓ`.**
- [ ] **Step 3: Migración**, con `SET LOCAL lock_timeout = '5s'` arriba y la cabecera al estilo de la
  430: qué agrega, por qué la clave no es el id, cómo lee el libro de deltas, qué pasa con la
  rendición y el despliegue.
- [ ] **Step 4: Ensayos acumulados**, cada uno con la migración entera:
  - `test-gastos-5` → `ENSAYO OK`;
  - `test-gastos-4` → OK: Personal sigue andando;
  - `test-gastos-3` → OK: la rendición sigue andando;
  - `test-comisiones-1320-1321` → OK: el cálculo sigue igual;
  - `test-gates-1330`, si #1386 ya entró a `main`, → OK;
  - `auditoria_integridad()->'critical_high_en_rojo'` da 0, igual que antes.
- [ ] **Step 5: `npx vitest run src/test/rpcsSoloServidor.test.ts`, y commit**
  `feat(personal): liquidaciones y comisiones congeladas (mig NNN)`.

---

### Task 3: Datos de las liquidaciones

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/hooks/queries/usePersonalQuery.ts`, `usePersonalQuery.test.tsx` e `index.ts`.

**Interfaces:**
- **Consumes**: los tipos de la Tarea 1 y las RPCs de la Tarea 2.
- **Produces**:
  - **Keys**: `personalKeys` suma
    `vistaPrevia: (sId, id: number) => [...all, 'vista-previa', id]` y
    `liquidacion: (sId, id: number) => [...all, 'liquidacion', id]`.
  - **Queries**:
    - `useVistaPreviaLiquidacionQuery(empleadoId: number | null): UseQueryResult<VistaPreviaLiquidacion | null>`,
      con `staleTime: 0`, por el mismo motivo que la cuenta: los pagos mueven el saldo sin invalidar;
    - `useLiquidacionQuery(liquidacionId: number | null): UseQueryResult<DetalleLiquidacion>`.
  - **Mutations**, que invalidan `personalKeys.all(sId)` y, con un pago de rendición, la lista de
    `useRendiciones`:
    - `useLiquidarEmpleadoMutation()`, con `{ empleadoId: number; liquidacion: LiquidarPayload }` →
      `number`;
    - `useAnularLiquidacionMutation()`, con `{ liquidacionId: number; motivo: string }`.
    - `useRegistrarMovimientoEmpleadoMutation` y `useRevertirMovimientoEmpleadoMutation` suman esa
      misma invalidación.
  - **Errores**: `errorDeSupabase` con
    `'Sin conexión: no se pudo confirmar la liquidación. Revisá la cuenta del empleado antes de reintentar, puede haber quedado registrada.'`,
    y los de las queries con el molde de siempre.

- [ ] **Step 1: Tests:**
  - `useVistaPreviaLiquidacionQuery(null)` no llama nada, y con id llama `previsualizar_liquidacion`
    con `{ p_empleado_id }`;
  - `useLiquidarEmpleadoMutation` manda `{ p_empleado_id: 7, p_liquidacion: {...} }` e invalida
    `['personal', 1]`;
  - "un pago de rendición invalida también las rendiciones";
  - `useAnularLiquidacionMutation` manda `{ p_liquidacion_id, p_motivo }`;
  - un error de red da el mensaje con "Sin conexión".
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(personal): datos de las liquidaciones`.

---

### Task 4: La pantalla de liquidar

Modelo: Sonnet, esfuerzo high.

**Files:**
- Create: `src/components/modals/ModalLiquidar.tsx` y `ModalLiquidar.test.tsx`.
- Create: `src/components/modals/SelectorPlata.tsx`, el bloque "Con qué plata se paga", que usan este
  modal y el del movimiento.

**Interfaces:**
- **Consumes**: las Tareas 1 y 3.
- **Produces**: `SelectorPlata`, con `{ valor: PlataDelPago; onChange: (v: PlataDelPago) => void; transportistas: Array<{ id: string; nombre: string }>; hoy: string }`.
- **Props**: `{ empleado: Pick<Empleado, 'id' | 'nombre' | 'puesto' | 'sucursal_id' | 'de_las_dos'>; nombreSucursal: (id: number) => string; transportistas: Array<{ id: string; nombre: string }>; hoy: string; onClose: () => void }`.
  Usa adentro `useVistaPreviaLiquidacionQuery` y `useLiquidarEmpleadoMutation`.
- **Schema Zod co-locado**, exportado como `modalLiquidarSchema`, con los campos de texto del
  formulario, y `superRefine` con `parseMonto` (`MENSAJE_MONTO_ILEGIBLE`), `errorDeSueldo`,
  `errorDePago` y la rendición con `'Elegí de qué rendición sale la plata: el transportista y el día'`.
- **El modal**, con los textos de la maqueta. `ModalBase` con `title="Liquidar a {nombre}"` y
  `maxWidth="max-w-2xl"`:
  - **Subtítulo**: `'{Puesto} · {sucursal o Las dos} · se le paga por {semana|mes}'`.
  - **Período**: etiqueta `'Período'` y `'{textoPeriodo} · {dd/mm} al {dd/mm}'`, sin flechas.
    Debajo, según el caso:
    - con `mas_vencidos > 0`: `'Quedan {n} período(s) más sin liquidar.'`;
    - con `en_curso`: `'Este período todavía no terminó: lo que se entregue después entra en el siguiente.'`
  - **Avisos** ámbar:
    - `comisiona_sin_usuario`: `'Comisiona, pero no tiene un usuario vinculado: no se le pueden calcular pedidos.'`
    - `arreglo_cambia`: `'El arreglo cambia en este período: revisá el sueldo.'`
    - `periodo_parcial`: `'Entró o se fue en este período: revisá el sueldo.'`
  - **Las filas**, en una tarjeta:
    - `'Sueldo fijo'`, con un campo de monto que arranca en `sueldo.propuesto` y la línea
      `'Arreglo vigente desde el {dd/mm/aaaa}'`. Si el monto difiere, aparece `'Por qué cambia el sueldo *'`;
    - `'Comisiones'`:
      `'{n} pedido(s) entregado(s) sin liquidar · base {base} · ver pedidos'`. Sin pedidos no va.
      "ver pedidos" despliega ahí mismo una tabla `Pedido | Entregado | Cliente | Base | Comisión`;
    - `'Ajuste de comisión'`, una fila por ajuste: `'{motivo} · pedido #{id}'`;
    - una fila por movimiento, con `conceptoDeMovimiento`. Si `por_el_mismo`, va el badge ámbar
      `'Lo cargó su propio usuario'`;
    - `'Saldo anterior'`, con `'Sin saldo pendiente'` si es 0;
    - `'A pagar'`, grande, sobre fondo gris, con `aPagar(vista, sueldo)`: se mueve con el sueldo. Si
      da negativo, dice `'Queda debiendo'` con el valor absoluto, en rojo.
  - **Pago**:
    - `'Monto que se le paga'`, que sigue a `A pagar` (0 si es negativo) hasta que se lo toca, con la
      ayuda `'Si se le paga menos, lo que falta queda a su favor en la cuenta.'`. Con `A pagar <= 0`
      queda deshabilitado en 0;
    - `'Con qué plata se paga'`, sólo con monto > 0: las pastillas `'La pagó la oficina'` y
      `'Con la plata de una rendición'`, como en la maqueta;
    - con la oficina, `'Fecha del pago'`, que arranca en hoy, con `max` hoy;
    - con una rendición, `'Transportista'` en un `Combobox` y `'Día de la rendición'`, con `max` hoy,
      que reemplaza a la fecha, y la ayuda
      `'Se descuenta del efectivo a entregar de esa rendición. El encargado y el chofer ven sólo el total pagado al personal.'`
  - **Info** azul:
    `'Al confirmar, las comisiones de esos {n} pedidos quedan fijas. Un pedido que se entregue después entra en la próxima liquidación, y una salvedad sobre uno ya liquidado entra como ajuste.'`
    Sin pedidos no va.
  - **Botones**: `'Cancelar'` y `'Confirmar y registrar el pago'`.
- **Al confirmar**: manda `LiquidarPayload`, con `a_pagar_esperado` igual a `aPagar(vista, sueldo)` y
  `motivo_sueldo` sólo si difiere. Avisa con `notify.success('Liquidación registrada')` y cierra. Un
  error se muestra en el modal, que se queda abierto y **pide de nuevo la vista previa**: el mensaje
  de "Algo cambió" lo necesita.
- **Sin vista previa** (`null`): `'No hay nada para liquidar.'`. Cargando, y error con
  `QueryErrorState`, como la cuenta.

- [ ] **Step 1: Tests**, mockeando `hooks/queries/usePersonalQuery`:
  - "muestra sueldo, comisiones, ajuste, movimiento, saldo anterior y a pagar": 650.000 + 368.600 −
    1.240 − 22.800 = 994.560;
  - "corregir el sueldo mueve A pagar y el monto, y pide el motivo";
  - "sin motivo no deja; con motivo manda `sueldo` y `motivo_sueldo`";
  - "sin cambios manda `motivo_sueldo: null`";
  - "'arreglo_cambia' y 'periodo_parcial' avisan que se revise el sueldo";
  - "ver pedidos despliega la tabla";
  - "confirmar manda el período, el pago, la fecha y `a_pagar_esperado`";
  - "pagar menos manda ese monto";
  - "tocar el monto deja de seguir a A pagar";
  - "más de lo que toca no deja, con el mensaje del server";
  - "'280.000' se lee como 280000, y un texto ilegible avisa";
  - "con la rendición pide transportista y día, y manda `{ origen_pago: 'rendicion', rendicion_transportista_id, rendicion_fecha }`";
  - "con pago 0 no pregunta con qué plata";
  - "con A pagar negativo dice 'Queda debiendo' y el monto queda en 0";
  - "con `en_curso` lo avisa";
  - "con `mas_vencidos` lo avisa";
  - "un movimiento `por_el_mismo` lleva el badge";
  - "`comisiona_sin_usuario` avisa";
  - "un error del server se muestra, no cierra y vuelve a pedir la vista previa";
  - "`null` dice 'No hay nada para liquidar.'".
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(personal): la pantalla de liquidar`.

---

### Task 5: Liquidar desde la cuenta, y las liquidaciones

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/components/modals/ModalCuentaEmpleado.tsx` y su test.
- Modify: `src/components/modals/ModalMovimientoEmpleado.tsx` y su test.

**Interfaces:**
- **Consumes**: las Tareas 1, 3 y 4.
- **`ModalCuentaEmpleado`**:
  - usa `useVistaPreviaLiquidacionQuery(empleadoId)`, `useAnularLiquidacionMutation` y
    `useTransportistasQuery`, con el mismo armado de `GastosContainer`, y `useLiquidacionQuery` para
    el detalle que se despliega;
  - **tarjeta de saldo**: con vista previa, `'Próxima liquidación: {textoPeriodo}. A pagar, estimado: {a_pagar}.'`.
    Con `puede_liquidar`, el botón primario `'Liquidar semana'` o `'Liquidar mes'`, con `HandCoins`,
    antes de `'Movimiento'`;
  - `ModalLiquidar` va **dentro** de los children de `ModalBase`, como los otros dos: `anidado` suma
    `'liquidar'`;
  - **pestañas**: `'Movimientos'`, `'Liquidaciones'` (con `HandCoins`) y `'Arreglos'`, en ese orden;
  - **pestaña Liquidaciones**, una fila por liquidación:
    - `textoPeriodo`, y `'Pagado {pagado} el {dd/mm/aaaa}'`, más `'de {a_pagar}'` si se pagó menos, y
      `' · de la rendición de {chofer} del {dd/mm}'` si salió de ahí;
    - `'Sueldo {x} · Comisión {y}'`, más `' · Ajuste {z}'` si hay;
    - el badge `'Anulada'` y su motivo si está anulada;
    - `'Ver detalle'`, que despliega el sueldo (con el propuesto y el motivo si difiere), los pedidos
      y los ajustes de `useLiquidacionQuery`;
    - `'Anular'` si `es_la_ultima`, no está anulada y la cuenta no es propia. Abre en la fila
      `'Por qué se anula *'`, con el mismo patrón de `Revertir`, y avisa
      `'Se revierten sus movimientos y sus pedidos vuelven a quedar sin liquidar. Si el pago salió de una rendición ya cerrada, ese pago queda.'`;
    - sin filas, `'Todavía no se le liquidó nada.'`;
  - **`sePuedeRevertir`** suma `m.tipo === 'pago' && m.liquidacion === null`;
  - **el pie** suma `' El sueldo y las comisiones entran al liquidar.'`;
  - `propio`: sin `'Liquidar'` ni `'Anular'`.
- **`ModalMovimientoEmpleado`**:
  - suma la prop `transportistas`;
  - suma la pastilla `'Pago'`, entre `'Adelanto en efectivo'` y `'Ajuste'`;
  - su ayuda: `'Plata que se le paga de lo que tiene a favor.'`;
  - su observación es opcional, y el payload va con `tipo: 'pago'` y el monto positivo;
  - con `'Pago'`, `SelectorPlata` de la Tarea 4. El adelanto y el ajuste no lo llevan.

- [ ] **Step 1: Tests:**
  - **La cuenta**:
    - "muestra la próxima liquidación y el estimado";
    - "'Liquidar semana' abre el modal anidado dentro del diálogo", con el stub dentro del
      `role="dialog"`;
    - "una mensual dice 'Liquidar mes'";
    - "sin `puede_liquidar` no hay botón, y sí el texto";
    - "la pestaña Liquidaciones muestra período, pagado y sueldo";
    - "pagó menos: 'de {a_pagar}'";
    - "pagada con una rendición lo dice";
    - "'Anular' sólo en la última, pide motivo y llama la mutation con `{ liquidacionId, motivo }`";
    - "una anulada dice 'Anulada' y su motivo, sin 'Anular'";
    - "'Ver detalle' pide `useLiquidacionQuery` con su id";
    - "la cuenta propia no tiene 'Liquidar' ni 'Anular'";
    - "un pago suelto tiene 'Revertir', y uno de una liquidación no".
  - **El movimiento**:
    - "un pago de 50000 manda `{ tipo: 'pago', monto: 50000, fecha: hoy, observacion: null, origen_pago: 'oficina', … }`";
    - "con una rendición pide transportista y día";
    - "un adelanto no ofrece la rendición";
    - "un pago de 0 no deja".
- [ ] **Step 2: Ver que fallan; implementar; pasar; typecheck y lint.**
- [ ] **Step 3: Commit** `feat(personal): liquidar desde la cuenta y anular la última`.

---

### Task 6: Personal avisa, y Comisiones aclara

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/components/vistas/VistaPersonal.tsx` y su test.
- Modify: `src/components/vistas/VistaComisiones.tsx` y su test.

**Interfaces:**
- **Consumes**: la Tarea 1.
- **`VistaPersonal`**:
  - las pastillas pasan a `'Todos · {n}'`, `'Para liquidar · {n}'`, `'Con saldo · {n}'` e
    `'Inactivos'`;
  - **la tarjeta**: si `paraLiquidar(e.periodo, hoy)`, debajo de los vínculos, una pastilla ámbar con
    `Clock`: `'{textoPeriodo} sin liquidar'`, más `' y {n} más'` con `mas_vencidos > 0`.
  - `'Ningún empleado coincide.'` sigue para el filtro sin resultados.
- **`VistaComisiones`**: al final del texto del pie (cerca de la línea 247) suma:
  `'Este cálculo va por la fecha del pedido, y lo liquidado a cada empleado va por la fecha de entrega: por eso su total del mes puede no coincidir.'`

- [ ] **Step 1: Tests:**
  - **Personal**:
    - "la tarjeta dice 'Semana 26/10 al 01/11 sin liquidar'";
    - "con más vencidos dice 'y 2 más'";
    - "el filtro Para liquidar deja sólo esos, y la pastilla los cuenta";
    - "un período que todavía no cierra no muestra la pastilla".
  - **Comisiones**: "aclara que el total puede no coincidir con lo liquidado".
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(personal): quién tiene un período para liquidar`.

---

### Task 7: Los pagos al personal en la rendición

Modelo: Sonnet, esfuerzo high.

**Files:**
- Modify: `src/types/hooks.ts` y `src/hooks/supabase/useRendiciones.ts`.
- Modify: `src/utils/rendicionGastos.ts` y su test.
- Modify: `src/components/vistas/VistaRendiciones.tsx` y su test.
- Modify: `src/components/modals/ModalCerrarRendicion.tsx` y su test.

**Interfaces:**
- **Consumes**: la columna `total_pagos_personal` de la Tarea 2.
- **Tipos y datos**: el resumen de rendición suma `total_pagos_personal: number`, mapeado con
  `Number(r.total_pagos_personal) || 0`.
- **`efectivoAEntregar(efectivoCobrado: number, gastos: number, pagosPersonal = 0): number`**.
- **`VistaRendiciones`**:
  - el bloque "Efectivo a entregar" aparece también con `total_pagos_personal > 0`, y lo resta;
  - la línea de detalle arma sus tramos, cada uno sólo si hay:
    `'{efectivo} cobrados en efectivo − {gastos} de {n} gastos pagados con esa plata − {pagos} pagados al personal con esa plata'`;
  - con el efectivo negativo y pagos > 0, la alerta dice
    `'Los gastos y los pagos al personal superan el efectivo cobrado.'`. Sin pagos, sigue la de hoy.
- **`ModalCerrarRendicion`**:
  - suma la prop `totalPagosPersonal?: number`, 0 por defecto, que la vista le pasa desde el resumen;
  - `aEntregar` lo resta;
  - suma una línea fija `'Pagos al personal con esta plata: {monto}'`, sin acciones ni nombres.

- [ ] **Step 1: Tests:**
  - **Efectivo**: `efectivoAEntregar(500000, 50000, 100000)` da 350.000, y sin el tercero da 450.000.
  - **Vista**:
    - "resta los pagos y lo dice en la línea";
    - "sin pagos, el texto es el de hoy";
    - "un día con sólo un pago muestra el bloque";
    - "no hay ningún nombre de empleado".
  - **Cierre**:
    - "descuenta los pagos del efectivo a entregar";
    - "muestra la línea de pagos, sin acciones";
    - "sin pagos no va la línea".
- [ ] **Step 2: Ver que fallan; implementar; pasar; las cuatro verificaciones.**
- [ ] **Step 3: Commit** `feat(personal): los pagos al personal en la rendición`.

---

### Task 8: Cierre — verificación, aplicación y PR

Lo hace la coordinadora, con el OK del dueño para aplicar.

- [ ] **Step 1: Juntar las ramas** con el OK del dueño, y traer `main` con
  `sync_with_base_branch`. Correr `npm run typecheck`, `npm run lint`,
  `npm run test:run` sin `.env` y `npm run build`: las cuatro en verde.
- [ ] **Step 2: Mirar la pantalla en un navegador de verdad.** Los modales anidados de Personal sólo
  se probaron en jsdom (#1332). Con `npm run dev` y un mock de las RPCs, o con el dueño, confirmar
  que `ModalLiquidar` queda arriba del overlay de la cuenta y que se puede tipear en el sueldo y en
  el monto. Sin sesión de prueba, se le pide al dueño y queda dicho en el PR.
- [ ] **Step 3: Ensayos acumulados en prod**, los de la Tarea 2, Step 4 → OK.
- [ ] **Step 4: Aplicar.** Con el OK del dueño, fuera del horario de cierre de rendiciones (9 h, 17 a
  18 h y 20 a 21 h):
  1. elegir el número con la trampa 3: el ledger, `origin/main`, las ramas abiertas y los worktrees;
  2. renombrar `NNN` en el archivo, en `rpcsSoloServidor.test.ts` y en los comentarios;
  3. aplicar con `apply_migration` y verificar `md5(statements[1])` contra el `md5sum` del archivo;
  4. mergear enseguida. Esta entrega no suma embeds, así que el gate no frena el orden: el PR va en
     borrador hasta acá. El bundle viejo sigue andando, porque la migración sólo agrega claves y una
     columna.

  Si `apply_migration` o el ensayo se cortan por un clasificador, se para y se le avisa al dueño.
- [ ] **Step 5: Después de aplicar:**
  - `auditoria_grants_tablas()`, `auditoria_permisos_execute()`, `auditoria_definer_sin_rol()` y
    `auditoria_sucursal_cruzada()`: nada nuevo en rojo;
  - `auditoria_integridad()`, con los claims de un admin: igual que antes;
  - con la anon key, `POST /rest/v1/rpc/previsualizar_liquidacion` da 42501;
  - `calcular_comisiones` de octubre, con los claims de un admin, da lo mismo que antes de aplicar;
  - `obtener_resumen_rendiciones` de los últimos 7 días anda y trae `total_pagos_personal` en 0.
- [ ] **Step 6: PR** a `main`, con el título "Gastos 4/5: liquidaciones".
  - El cuerpo enlaza el spec, este plan y #1332, y dice que es la entrega 4 de 5.
  - Lleva `Closes #1350` y `Closes #1354`.
- [ ] **Step 7: Los issues:**
  - un issue nuevo con `LIQ-A`, `LIQ-B` y `LIQ-C`, qué mira cada uno, y que cita #1330;
  - #1269: `personal_por_mes`, y que Personal suma sólo el sueldo (decisión 10);
  - #1332: la entrega 4 en prod, lo que aprendió y lo que queda para la 5.
