# Faltantes de rendición: imputar la diferencia

Diseño aprobado por el dueño el 2026-11-03, de a una decisión. Es parte del módulo de gastos y
cuentas del personal (`2026-10-28-gastos-y-cuentas-del-personal-design.md`, #1332), pero va como
una entrega propia, antes de las roturas a cargo del empleado (§4.5 de ese diseño).

Las decisiones que tomé yo, no el dueño, van marcadas **[diseñador]**.

## Por qué

El dueño preguntó: «Si una rendición tiene disconformidad, ¿cómo queda? Debería haber una
solución: ingresar el monto y elegir una causal, y según la causal se imputa como deuda al
empleado o como gasto».

**Hoy** (relevado del código y de prod el 2026-11-03):

- Al cerrar, el encargado o el admin eligen «Disconformidad» y escriben un texto obligatorio
  («faltan $5.000»). La fila de `rendiciones_control` queda en `estado = 'disconformidad'`.
- **La diferencia sólo existe en ese texto.** La app nunca registra cuánta plata entregó el chofer.
  El efectivo a entregar sigue igual, no hay gasto ni movimiento en la cuenta de nadie, y ningún
  número la suma. Los clientes no se enteran: su pago entró completo. El agujero queda en la caja
  de la empresa, invisible.
- **Disconformidad no es cerrada** (`estado IN ('confirmada','resuelta')` es cerrada). No hay
  foto de los cobros (#1248), y sus gastos se pueden cambiar desde Gastos
  (`control_rendicion_cerrado`). Los cobros del día quedan bloqueados en cuanto se confirma un día
  posterior de la sucursal (`ultima_fecha_caja_cerrada`).
- **Resolver** (`resolver_rendicion`) la pueden usar el admin y el encargado, salvo el encargado
  sobre su propia rendición. Pide sólo un texto, lo agrega a las observaciones con nombre y fecha,
  y la pasa a `resuelta`, que la cierra y le toma la foto. No mueve plata.
- **En prod** hubo 3 disconformidades, todas de Taco Pozo:
  - 11/06, «Transporte Taco Pozo», $1.000: sigue abierta.
  - 29/06, Jony, $100: sigue abierta.
  - 01/09, Juan, $1.000: resuelta el 08/09 («se le cobró»).

  Ninguna de esas tres personas tiene ficha de empleado. Las 327 rendiciones controladas en la app
  son de Taco Pozo, y los 8 empleados cargados son de Tucumán, que todavía no controla
  rendiciones.

## Objetivos

- Que un faltante de rendición termine con su monto y su causal en un lugar con plata: la cuenta
  de un empleado o un gasto.
- Que lo imputado baje el efectivo a entregar, para que la rendición cuadre con lo que se entregó y
  quede cerrada.
- Que se pueda deshacer de una vez, sin dejar pedazos.

## Fuera de alcance

- **Sobrantes**, cuando el chofer entrega de más **[diseñador]**. Casi siempre son un cobro sin
  registrar, y se arreglan registrándolo. Las líneas de esta entrega son faltantes, siempre con
  monto > 0.
- **Imputar desde «Cerrar rendición»** (decisión 6). El cierre no cambia.
- **Roturas a cargo del empleado** (decisión 7). Van en una entrega aparte, que reutiliza lo que
  deje esta.
- **Registrar «lo que entregó el chofer»** como un número de la rendición. Se muestra el efectivo
  a entregar que queda después de imputar, y el admin lo compara con lo que recibió.
- **Las fichas de Taco Pozo y el control de rendiciones en Tucumán**: los decide el dueño, no esta
  entrega.

## Anti-objetivos

- **Una deuda guardada sin ficha de empleado.** Nada la descontaría nunca, y sería el problema de
  hoy con otro nombre.
- **Que una rendición cerrada cambie su efectivo a entregar sin que alguien la vuelva a mirar.** Por
  eso lo imputado se deshace todo junto y desde la rendición, nunca un pedazo suelto desde Personal
  o desde Gastos.
- **Mezclar los faltantes con los pagos al personal** **[diseñador]**. El encargado ve los pagos al
  personal como un total sin nombres, y un faltante no es un pago.

## Decisiones del dueño (2026-11-03)

1. **Tres causales:**

   | Causal | A dónde va |
   |---|---|
   | A cargo del empleado (la plata no aparece) | Deuda en la cuenta de un empleado: la liquidación se la descuenta |
   | Robo o pérdida | Gasto de esa rendición, en un rubro nuevo, «Faltantes de caja», que absorbe la empresa |
   | Gasto que no se cargó (pagó nafta o un peaje y no lo anotó) | Gasto de esa rendición, con el rubro que corresponda |

2. **Resolver una disconformidad es sólo del admin**, con cualquier causal. El encargado sigue
   cerrando y marcando la disconformidad, pero ya no la resuelve. Hoy sí puede: cambia.
3. **A quién se le carga la deuda:** el admin elige el empleado de una lista de la sucursal, que
   arranca con el vinculado al usuario de esa rendición, si lo hay. Puede ser otro, como un
   ayudante o un preventista. **Sin ficha no se puede:** la opción avisa «Para cargársela a alguien,
   primero dalo de alta en Personal», y la rendición queda en disconformidad hasta entonces.
4. **Se puede repartir:** una resolución lleva varias líneas, cada una con su monto y su causal.
   Abajo se ve en cuánto queda el efectivo a entregar.
5. **Se deshace con un solo botón,** «Deshacer resolución», sólo del admin y con motivo. Deshace
   todo lo que imputó esa resolución y la rendición vuelve a disconformidad. Desde Personal o desde
   Gastos no se deshace un pedazo.
6. **Se imputa sólo desde «Resolver»**, aunque sean dos pasos (cerrar con disconformidad y después
   resolver).
7. **Va separado de las roturas:** primero los faltantes, después las roturas.

## Cómo funciona

### Resolver

- El modal «Resolver disconformidad» lo abre sólo el admin, y mantiene lo de hoy: las observaciones
  previas y «¿Cómo se resolvió?», obligatorio.
- **Suma una sección «Diferencia»** con líneas. Cada línea tiene un monto mayor a 0 y una causal:
  - **A cargo del empleado:** se elige el empleado. Si no hay ninguno en la sucursal, la causal
    muestra el aviso de la decisión 3 y no se puede elegir.
  - **Robo o pérdida:** sólo el monto. El gasto se arma solo, con el rubro «Faltantes de caja».
  - **Gasto que no se cargó:** se carga el gasto completo, con rubro, vehículo, comprobante y lo que
    pida el rubro, con el mismo `ModalGasto` en borrador que usa «Agregar gasto» en el cierre. La
    plata queda fija en esta rendición, y el monto de la línea es el del gasto.
- **Debajo de las líneas:** «A entregar $800.000 · imputado $5.000 · queda $795.000».
- **Lo imputado no puede dejar el efectivo a entregar en negativo** **[diseñador]**: «Lo imputado
  supera lo que había para entregar». No puede faltar más de lo que había.
- **Las líneas son opcionales** **[diseñador]**. Resolver sólo con el texto sigue valiendo, para
  cuando la plata apareció o el empleado la repuso, como en el caso de Juan.
- **Todo va en una transacción:** crea los movimientos y los gastos, guarda el texto y pasa la
  rendición a `resuelta`, que le toma la foto como hoy. Si se cancela el modal, no se guarda nada.
- **Si algo de la rendición cambió mientras el modal estaba abierto** (sus gastos o sus pagos al
  personal), se rechaza igual que en `confirmar_rendicion`: «…cambiaron mientras la resolvías: tocá
  Refrescar y volvé a abrir».

### La deuda

- **Es un movimiento nuevo de la cuenta del empleado**, de un tipo propio, «faltante», con signo
  negativo. Apunta a la rendición por su clave (transportista, fecha, sucursal), como los pagos al
  personal. Se lee «Faltante de rendición del 11/06 (Transporte Taco Pozo)».
- **La liquidación lo descuenta sola,** porque el saldo es la suma de los movimientos.
- **Su fecha es la del día en que se imputa** (día argentino), no la de la rendición
  **[diseñador]**. Así aparece entre los movimientos de la próxima liquidación, que toma los
  posteriores a la última. Igual entraría en el saldo, pero quedaría escondido en el «saldo
  anterior». La fecha de la rendición va en el concepto. La compensación de «Deshacer» lleva la
  fecha del día en que se deshace.
- **El empleado** tiene que estar activo y ser de la sucursal de la rendición, o de las dos. El
  admin no se lo carga a su propia ficha: es la regla de Personal, nadie se carga movimientos a sí
  mismo.
- **Desde Personal no se revierte.** «Revertir» lo rechaza con «Se deshace desde la rendición».

### El gasto

- **Robo o pérdida** es un gasto de la rendición con el rubro «Faltantes de caja» (grupo Otros),
  sin comprobante. La causal y la observación de la línea van en su nota. El rubro lo crea la
  migración.
- **Gasto que no se cargó** es un gasto común de la rendición, con el rubro que se elija.
- **Los dos llevan la fecha de la rendición**, que es cuando pasó, y caen en el mes en que pasaron
  **[diseñador]**. Una pérdida de junio resuelta en noviembre es un gasto de junio.
- **El rubro es uno solo para toda la red:** `gasto_rubros` no tiene sucursal.
- **Los dos se ven en Gastos** como cualquier gasto de rendición, pero **marcados como de la
  resolución**: no se editan ni se quitan sueltos, ni desde Gastos ni desde «Editar cierre». Lo que
  quedó mal se arregla con «Deshacer resolución».

### El efectivo a entregar

- **A entregar** = efectivo cobrado − gastos (incluidos los de la resolución) − pagos al personal
  − faltantes a cargo de empleados.
- **Los gastos de la resolución** suman a «Gastos pagados con esa plata», como hoy cualquier gasto
  de la rendición. **Las deudas** van en un renglón propio, «Faltantes a cargo de empleados»,
  aparte de «Pagos al personal» **[diseñador]**. Ese renglón aparece en la tarjeta de la vista
  Rendiciones, en el cierre y en «Mis cobros».
- **El chofer ve en «Mis cobros»** las líneas de su rendición: causal, monto y a quién se le cargó
  **[diseñador]**. Es su rendición y, casi siempre, su deuda.

### Deshacer

- **«Deshacer resolución»** aparece para el admin en toda rendición resuelta, tenga líneas o sólo
  el texto, y en una con líneas vivas que haya cambiado de estado después, por «Editar cierre» o
  por un cambio de entrega **[diseñador]**. Pide un motivo, que se suma a las observaciones con
  nombre y fecha, como al resolver.
- **Una línea viva es una no anulada.** Deshacer anula las líneas, no las borra. La tarjeta, el
  cierre y «Mis cobros» muestran sólo las vivas, y las anuladas quedan como historial
  **[diseñador]**. Se puede resolver, deshacer y volver a resolver las veces que haga falta.
- **Deshace todo junto:**
  - **cada deuda** se compensa con un movimiento a favor en la cuenta del empleado, porque el libro
    no se borra. Si ya se descontó en una liquidación, la próxima se la devuelve;
  - **los gastos de la resolución** se anulan;
  - **la rendición** vuelve a disconformidad, y su foto se suelta, como hoy cuando una rendición
    cerrada vuelve a abrirse. Si se había reabierto sola y estaba pendiente (sin fila de control),
    queda pendiente **[diseñador]**.
- **Después** se resuelve de nuevo, bien.

### El encargado

- Ve la disconformidad igual que hoy, sin el botón «Resolver». En su lugar: «La resuelve un admin».
- `resolver_rendicion` pasa a ser sólo de admin en el server. Hoy no lo es.

### Lo que no cambia

- «Cerrar rendición», sus dos estados y quién la cierra.
- Qué es una rendición cerrada, la foto (#1248) y las guardas de caja.
- La regla del encargado sobre su propia rendición.
- **Una rendición que se reabre sola** porque cambió la fecha de entrega de un pedido de ese día
  (`anular_control_por_cambio_fecha_entrega` borra su control). Lo imputado sigue restando, igual
  que sus gastos y sus pagos al personal. Por eso lo imputado se ata a la clave de la rendición y no
  al `id` de `rendiciones_control`, que puede desaparecer.

## Lo que tiene que respetar

- **Las reglas del `CLAUDE.md` de la raíz:**
  - funciones `SECURITY DEFINER` que validan el rol adentro, con `REVOKE … FROM PUBLIC, anon`, y
    la lista de `scripts/rpcs-definer-permitidas.json`;
  - una tabla nueva sin escritura REST;
  - el día argentino;
  - dropear la firma vieja si cambia (PGRST203);
  - parámetros en `INTEGER`.
- **El lock de la rendición** (`_rendicion_bloquear`) en todo camino que escriba lo imputado, igual
  que los pagos al personal (entrega 4).
- **«Editar cierre» sobre una rendición con líneas vivas:**
  - las muestra sin dejar tocarlas;
  - rechaza el cierre si se resolvió o se deshizo mientras el modal estaba abierto, igual que con
    `pagos_personal_visto`. El paso 4b de `confirmar_rendicion` hoy suma **todos** los movimientos
    con esa rendición, así que una deuda nueva entraría en esa suma, salvo que se filtre por tipo;
  - no puede mandar la rendición a disconformidad mientras tenga líneas vivas: «Deshacé la
    resolución primero».
- **El orden dentro de la transacción evita saltar guardas.** Resolver escribe las líneas, los
  movimientos y los gastos mientras la rendición sigue en disconformidad, que no es cerrada y
  `control_rendicion_cerrado` deja pasar. Recién al final la pasa a `resuelta`. Deshacer primero
  la vuelve a disconformidad y después anula y compensa. No hace falta un GUC ni un parámetro para
  saltear la guarda.
- **Los gastos de la resolución pasan por `_guardar_gasto`**, igual que los del cierre, así que
  valen sus reglas. `GASTO-A` de `auditoria_integridad()` da 0 porque nacen con el mismo `now()`
  que `resuelta_at`.
- **Las funciones que se reescriben parten del cuerpo vivo,** con guarda `$vivas$`. Ojo con el CRLF
  de la 430 y la 437 (#1332).
- **Los checks de auditoría que se propongan se anotan en #1330**, no se suman acá. Por ejemplo:
  una línea viva sin su movimiento o su gasto, o un movimiento «faltante» cuya rendición no tiene
  líneas.
- **El orden de despliegue** de las entregas anteriores: PR en borrador, gate de embeds, aplicar
  fuera del horario de cierre y mergear enseguida.

## Lo que queda para el builder

- **Cómo se guardan las líneas.** Sugiero una tabla propia, una fila por línea, con la clave de la
  rendición, la causal, el monto, el empleado o el gasto, quién y cuándo, y la anulación. Sirve
  para mostrar la resolución, para deshacerla de una vez y para los checks. La otra opción es
  marcar los gastos y los movimientos.
- **Si «Deshacer» es una RPC aparte** o un modo de la de resolver.
- **Los textos exactos y el diseño del modal,** siguiendo los del cierre.
- **Cómo se lee lo imputado** en la tarjeta, el cierre y «Mis cobros»: si `obtener_resumen_rendiciones`
  suma una columna o si sale de otra lectura.

## Casos de prod al desplegar

- **Las dos disconformidades de junio** (11/06 y 29/06) siguen abiertas, y de personas sin ficha.
  Se pueden resolver con las causales de gasto o sólo con el texto. No se migra nada.
- **La resuelta del 01/09** no cambia.
