# Registro de ensayos de restauración

Una entrada por ensayo, la más nueva arriba. Qué anotar: paso 12 de
[restore-runbook.md](restore-runbook.md).

---

## 2026-11-16 · Ensayo local de permisos (#1550, VAR-05)

**No es un ensayo de un backup real.** Se restauró una base local de esquema y fixtures, sin
cifrar, en Docker. Lo que prueba es el procedimiento de permisos del runbook (pasos 6 a 10), no
el backup cifrado ni un proyecto Supabase real.

### Qué se restauró

- **Fuente:** una base local en Docker (`supabase/postgres:17.6.1.178`, la versión de prod) con el
  esquema de prod —su huella era igual a la de prod en las 11 categorías, con el ledger en la
  507— más una migración todavía sin aplicar en prod y unas fixtures (699 filas en 7 tablas de
  `public`, 28 usuarios en `auth.users`). Sólo se leyó.
- **Dump:** `pg_dump` con los flags de `backup.yml`/`backup.ps1` (`--format=custom --no-owner
  --no-acl --verbose`), como el usuario `postgres`. Para los arreglos, el mismo dump sin
  `--no-acl`, y uno `--schema-only` como fuente alternativa de permisos.
- **Destino:** un contenedor nuevo de la misma imagen, sin tocar: es como un proyecto Supabase
  recién creado en lo que importa acá (los roles `anon`, `authenticated`, `service_role` y
  `postgres` sin superusuario, y los `ALTER DEFAULT PRIVILEGES` de fábrica que le dan `ALL` a los
  tres sobre lo que `postgres` crea en `public`). Se borró al terminar.
- **Restore:** `pg_restore --no-owner --no-acl --verbose` como `postgres`, como dice el runbook.
- **Chequeos:** los scripts `check-*.mjs` del repo, sin cambios, contra un imitador local de
  PostgREST que llama a cada `auditoria_*()` como `service_role`.

### Números

| Medida (schema `public`) | Fuente | Restore tal cual | Con el arreglo |
|---|---|---|---|
| Funciones (sin las de extensiones) | 575 | 575 | 575 |
| · ejecutables por `anon` (directo o por `PUBLIC`) | **0** | **575** | 0 |
| · · de ellas `SECURITY DEFINER` | 0 | **356** | 0 |
| · sin `EXECUTE` para `authenticated` (sólo de server) | 341 | **0** | 341 |
| · de trigger ejecutables por `anon`/`authenticated` | 0 | **109** | 0 |
| Tablas y vistas con algún privilegio para `anon` | 0 de 102 | **102** | 0 |
| Escrituras de `authenticated` a nivel tabla (INSERT/UPDATE/DELETE) | 45 | **306** | 45 |
| TRUNCATE/REFERENCES/TRIGGER/MAINTAIN de `authenticated` | 0 | **408** | 0 |
| Grants por columna | 82 | **0** | 82 |
| · `productos`: SELECT por columna / tabla entera (lee costos) | 26 / no | **0 / sí** | 26 / no |
| · `pedido_items`: SELECT por columna | 28 | **0** | 28 |
| · `pedidos`: UPDATE por columna | 8 columnas | **tabla entera** | 8 columnas |
| · `recorridos`: UPDATE por columna | 2 columnas | **tabla entera** | 2 columnas |
| Secuencias con algo para `anon` | 0 de 74 | **74** | 0 |
| · USAGE de `authenticated` / SELECT o UPDATE (`setval`) | 17 / 0 | **74 / 148** | 17 / 0 |
| Default de `postgres` en `public` | sin `anon`; `authenticated` lee tablas y ejecuta funciones | **el de fábrica** (`ALL` a `anon`) | el de la fuente |
| Dueño de las funciones definer | `postgres` | `postgres` | `postgres` |
| Tablas con RLS / sin RLS | 100 / 0 | 100 / 0 | 100 / 0 |
| Policies / triggers | 118 / 137 | 118 / 137 | 118 / 137 |
| Filas de `public` (md5 de los conteos por tabla) | — | iguales | iguales |

Huella del repo (`scripts/concurrencia/huella-esquema.sql`, etapa 1): con el restore tal cual
difieren `acl_columna`, `acl_tabla` y `funcion` (que incluye la ACL); columnas, constraints,
extensiones, índices, policies, triggers, vistas y el trigger de `auth.users` dan iguales. Con el
arreglo, **las 11 categorías dan iguales**, y también una huella semántica de todas las ACL de
`public` (funciones, relaciones, columnas) y de los dueños.

Chequeos sobre el restore tal cual:

| Chequeo | Resultado |
|---|---|
| `check-permisos` | rojo: 575 funciones ejecutables por `anon`, 109 de trigger por la app |
| `check-grants-tablas` | rojo: 1959 problemas (306 escrituras contra 48 del JSON) |
| `check-tablas-anon` | **verde**: RLS y las policies siguen frenando la lectura de tablas |
| `check-auth` | verde (la parte del signup no se pudo medir: ver abajo) |
| `check-storage` | no corre en local (ver abajo) |

`check-tablas-anon` solo no ve el problema. Los que lo ven son `check-permisos` y
`check-grants-tablas`. Con el arreglo, los cuatro que corren en local dan verde.

### Qué se probó para arreglarlo

| Variante | Resultado |
|---|---|
| Dump con permisos y restore con permisos, sin más | **No alcanza**: vuelven los 82 grants por columna, pero `anon` sigue con las 575 funciones, las 102 tablas y las 74 secuencias, y el default sigue siendo el de fábrica. Los GRANT/REVOKE de un dump se escriben contra el default de Postgres, no contra el de un proyecto Supabase. |
| Sacar los defaults de fábrica antes del restore (paso 6) y restaurar con permisos | Igual a la fuente. |
| Paso 6, restore `--no-acl` y después sólo las entradas `ACL`/`DEFAULT ACL` de `public` (paso 8), del mismo dump con permisos | Igual a la fuente. Es el que quedó en el runbook. |
| Ídem con un backup **sin** permisos y las entradas de otro dump (completo o `--schema-only`) | Igual a la fuente. Es el camino para los backups viejos. |
| Ya restaurado tal cual, `REVOKE ALL` en `public` y después los pasos 6 y 8 | Igual a la fuente. |
| Fuente de permisos a la que le faltan dos funciones y una tabla | `check-permisos` marca las dos funciones (quedan con `EXECUTE` de `PUBLIC`). La tabla queda sin acceso para la app (falla cerrada); `check-grants-tablas` no la ve porque no tiene escritura REST. |

Errores del restore: 57 con `--no-acl`, todos fuera de `public` (schemas que ya existen, objetos
de `auth`, event triggers y funciones de Supabase, `vault.secrets`). Restaurando los permisos de
todo el dump fueron 139 (los 82 de más son permisos de los schemas de Supabase y los defaults de
`supabase_admin`, que `postgres` no puede tocar): por eso el runbook aplica
sólo los de `public`, donde quedan 3 esperados (los defaults de `supabase_admin`). Tiempos en
local: 20 a 45 s por restore completo, permisos incluidos.

### Por qué los backups tienen que llevar los permisos

Sin `--no-acl` el dump trae los GRANT/REVOKE (en el ensayo, 837 entradas de `public` y 6 de
defaults) y pesa un 13 % más. Con `--no-acl` no hay de dónde sacar, si prod no está, qué 341
funciones son sólo de server, los 82 grants por columna, las 17 secuencias ni los defaults:
ningún archivo del repo los tiene completos (`grants-rest.json` lista sólo las escrituras y las
secuencias). Por eso `backup.yml` y `backup.ps1` dejan de pasar `--no-acl`. Un dump con permisos
se restaura igual con el runbook viejo (`--no-acl` los saltea).

### Fidelidad de la simulación, y qué no cubre

- **Cubre:** los privilegios por defecto de un proyecto nuevo (la imagen es la de Supabase, misma
  versión), restaurar como `postgres` sin superusuario, y los mismos flags de `pg_dump` y
  `pg_restore`.
- **No cubre:**
  - el `auth` y el `storage` de un proyecto real: los administran GoTrue y la API de storage. En
    la imagen local `auth` tiene 5 tablas y `storage` ninguna, así que no se probó si los usuarios
    pueden loguearse ni qué pasa con `storage.objects` y los archivos;
  - PostgREST: los chequeos corrieron contra un imitador que llama a las mismas RPCs; no se probó
    `NOTIFY pgrst` ni `check-embeds`;
  - el signup: `check-auth` leyó un `/auth/v1/settings` fijo, así que sólo se probó su mitad del
    trigger de `auth.users`;
  - `check-storage`: sin `storage.buckets` en la imagen no corre;
  - extensiones administradas por la plataforma más allá de las de la imagen;
  - el volumen de prod (la base del ensayo es chica) y el pooler.
- La fuente no es prod: es su esquema más una migración sin aplicar y fixtures. Los números de
  funciones pueden diferir en una de prod.

### Qué falta para un ensayo real (queda para el dueño)

- Un `.sql.gpg` real (del servidor o de Drive) y la passphrase.
- Un proyecto Supabase de staging vacío.
- Seguir el runbook entero, pasos 1 a 12, con los cinco chequeos del paso 10 contra ese proyecto
  y anotar acá los tiempos, los conteos contra prod y lo que quedó «a confirmar» en el paso 9
  (usuarios, archivos de `facturas`, secrets cargados, webhooks de base).
- Hasta que los backups lleven permisos, la única fuente fiel para el paso 8 es prod viva.

### Qué tiene que hacer el dueño para que los backups lleven permisos

- **Servidor Windows (diario):** el cambio del repo no cambia lo que corre. En el servidor, como
  Administrador, desde una copia actualizada del repo, volver a correr
  `scripts/backup/windows/instalar-tarea.ps1` con el mismo `-Usuario` con el que se instaló (pide
  la contraseña de esa cuenta), o copiar `backup.ps1` encima de
  `C:\ProgramData\distribuidora-backup\backup.ps1`. Después, `Start-ScheduledTask -TaskName
  'Backup Supabase distribuidora-app'` y mirar el log del día: la línea de `pg_restore --list` dice
  ahora `… entradas ACL de public`, y tiene que ser más de 0.
- **GitHub Action (mensual):** toma efecto al mergear a `main`; el próximo día 1, o a mano con
  `gh workflow run backup.yml`.
- Anotar acá la fecha del primer backup con permisos: los anteriores van por el camino de los
  backups viejos del paso 8.
