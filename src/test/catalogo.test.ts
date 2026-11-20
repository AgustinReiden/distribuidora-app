import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  problemaDeSearchPath,
  problemasDeTabla,
  SQL_REALTIME,
  SQL_ROL_SIN_ACTIVO_SIN_API,
  SQL_SEARCH_PATH_FUNCIONES,
  SQL_TABLAS_ANON_CATALOGO,
  // @ts-expect-error -- módulo .mjs de scripts/, sin tipos
} from '../../scripts/lib/catalogo.mjs'
import {
  guardasNegadasAbiertas,
  soloCodigoSql,
  terminosDeOr,
  // @ts-expect-error -- módulo .mjs de scripts/, sin tipos
} from '../../scripts/lib/guardas.mjs'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { mensajesQueFiltran } from '../../scripts/lib/mensajes.mjs'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { destino, esLocal } from '../../scripts/lib/pg.mjs'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { normalizarFirma, veredicto } from '../../scripts/lib/ensayos.mjs'

/**
 * Lo que deciden los gates que leen el catálogo directo (#1564, #1595, #1601): Realtime,
 * guardas con NOT (… OR …), mensajes de error de los triggers, y las listas de excepciones,
 * que sólo se achican. Texto, no ejecución: los casos son cuerpos de función como los
 * escribe el repo. Los mismos gates, contra una base de verdad, los prueba sql-local.yml.
 */

const raiz = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts')
const leerJson = (f: string) => JSON.parse(fs.readFileSync(path.join(raiz, f), 'utf8'))

describe('problemasDeTabla (Realtime)', () => {
  const sana = { rls: true, anon_algo: false, auth_tabla: true, auth_columnas: true }

  it('una tabla con RLS y SELECT de tabla entera para authenticated no tiene problemas (pedidos)', () => {
    expect(problemasDeTabla(sana)).toEqual([])
  })

  it('SELECT por columna para authenticated es rojo: productos y pedido_items', () => {
    const p = problemasDeTabla({ ...sana, auth_tabla: false })
    expect(p).toHaveLength(1)
    expect(p[0]).toMatch(/por columnas/)
  })

  it('sin RLS, o legible por anon, es rojo', () => {
    expect(problemasDeTabla({ ...sana, rls: false })[0]).toMatch(/sin RLS|no tiene RLS/)
    expect(problemasDeTabla({ ...sana, anon_algo: true })[0]).toMatch(/anon/)
  })

  it('una tabla que authenticated no lee no tiene nada que hacer en la publicación', () => {
    expect(problemasDeTabla({ ...sana, auth_tabla: false, auth_columnas: false })[0]).toMatch(/no la lee/)
  })
})

describe('SQL_REALTIME', () => {
  it('mira sólo la publicación supabase_realtime, no la de Broadcast con particiones diarias', () => {
    // Prod tiene también supabase_realtime_messages_publication con realtime.messages_AAAA_MM_DD,
    // que cambian de nombre todos los días y authenticated no lee: no puede poner el gate rojo.
    expect(SQL_REALTIME).toMatch(/pubname = 'supabase_realtime'/)
    expect(SQL_REALTIME).not.toMatch(/LIKE/i)
    expect(SQL_REALTIME).not.toMatch(/messages/)
  })
})

describe('guardasNegadasAbiertas (SEG-1b)', () => {
  // marcar_no_entregado antes de #1601: el transportista del pedido puede ser NULL.
  const primero = `
    BEGIN
      IF NOT (v_pedido.transportista_id = auth.uid() OR v_rol IN ('admin', 'encargado')) THEN
        RAISE EXCEPTION 'sin permiso';
      END IF;
    END`
  // La forma que el SQL de auditoria_rpcs_definer() no veía: la columna NO es el primer término.
  const segundo = `
    BEGIN
      v_uid := auth.uid();
      IF NOT (v_rol IN ('admin', 'encargado') OR v_pedido.transportista_id = v_uid) THEN
        RAISE EXCEPTION 'sin permiso';
      END IF;
    END`

  it('marca la columna comparada con auth.uid() en cualquier término del OR', () => {
    expect(guardasNegadasAbiertas(primero)).toHaveLength(1)
    expect(guardasNegadasAbiertas(segundo)).toHaveLength(1)
  })

  it('marca la columna comparada con una variable que guarda auth.uid(), de un lado o del otro', () => {
    const alias = `v_yo uuid := auth.uid(); IF NOT (v_yo = p.chofer_id OR es_admin()) THEN RAISE EXCEPTION 'x'; END IF;`
    expect(guardasNegadasAbiertas(alias)).toHaveLength(1)
  })

  it('marca la negación de un solo término', () => {
    expect(guardasNegadasAbiertas(`IF NOT (ped.usuario_id = auth.uid()) THEN RAISE EXCEPTION 'x'; END IF;`)).toHaveLength(1)
  })

  it('no marca la que usa COALESCE ni IS NOT DISTINCT FROM', () => {
    expect(
      guardasNegadasAbiertas(`IF NOT (COALESCE(p.transportista_id, auth.uid()) <> auth.uid() OR v_rol = 'admin') THEN RAISE EXCEPTION 'x'; END IF;`),
    ).toEqual([])
    expect(
      guardasNegadasAbiertas(`IF NOT (p.transportista_id IS NOT DISTINCT FROM auth.uid() OR v_rol = 'admin') THEN RAISE EXCEPTION 'x'; END IF;`),
    ).toEqual([])
    expect(
      guardasNegadasAbiertas(`IF p.transportista_id IS DISTINCT FROM auth.uid() AND v_rol <> 'admin' THEN RAISE EXCEPTION 'x'; END IF;`),
    ).toEqual([])
  })

  it('no marca un NOT (…) sin una comparación con el usuario, ni lo que está en un comentario o un literal', () => {
    expect(guardasNegadasAbiertas(`IF NOT (v_rol IN ('admin') OR v_activo) THEN RAISE EXCEPTION 'x'; END IF;`)).toEqual([])
    expect(guardasNegadasAbiertas(`-- IF NOT (a.id = auth.uid() OR x) THEN\nBEGIN RETURN; END`)).toEqual([])
    expect(guardasNegadasAbiertas(`RAISE EXCEPTION 'IF NOT (a.id = auth.uid() OR x) THEN';`)).toEqual([])
    // Un NOT (…) en un WHERE no es una guarda: filtra filas.
    expect(guardasNegadasAbiertas(`SELECT 1 FROM t WHERE NOT (t.dueno = auth.uid() OR t.publico)`)).toEqual([])
  })

  it('terminosDeOr corta sólo los OR de nivel cero', () => {
    expect(terminosDeOr(`a = 1 OR (b = 2 OR c = 3) OR d = 4`)).toEqual(['a = 1', '(b = 2 OR c = 3)', 'd = 4'])
    // Los literales ya vienen vaciados por soloCodigoSql: un OR dentro de un paréntesis anidado no corta.
    expect(terminosDeOr(`a = 1 OR f(b OR c, d) OR e`)).toEqual(['a = 1', 'f(b OR c, d)', 'e'])
  })

  it('soloCodigoSql saca comentarios y vacía literales', () => {
    expect(soloCodigoSql(`a /* b */ 'c''d' -- e\nf`)).toBe(`a   ''  \nf`)
  })
})

describe('mensajesQueFiltran (1564-g3)', () => {
  it('un mensaje con sólo el id que mandó el mismo usuario no filtra nada', () => {
    expect(
      mensajesQueFiltran(`BEGIN RAISE EXCEPTION 'El pedido #% está %: no admite pagos.', NEW.pedido_id, v_estado USING ERRCODE = '22023'; END`),
    ).toEqual([])
    expect(mensajesQueFiltran(`BEGIN RAISE EXCEPTION 'Sin permiso' USING ERRCODE = '42501'; END`)).toEqual([])
  })

  it('el nombre de un cliente leído con un id de NEW es rojo (pedidos_cliente_asignado)', () => {
    const h = mensajesQueFiltran(`
      DECLARE v_cliente text;
      BEGIN
        SELECT COALESCE(c.nombre_fantasia, c.razon_social) INTO v_cliente FROM clientes c WHERE c.id = NEW.cliente_id;
        RAISE EXCEPTION 'Cliente asignado a otro preventista: % (#%)', v_cliente, NEW.cliente_id USING ERRCODE = '42501';
      END`)
    expect(h).toHaveLength(1)
    expect(h[0]).toMatch(/dato personal de clientes/)
  })

  it('un subselect adentro del RAISE a perfiles es rojo (pedidos_entrega_con_chofer)', () => {
    const h = mensajesQueFiltran(
      `BEGIN RAISE EXCEPTION 'No se entrega a nombre de %', COALESCE((SELECT nombre FROM public.perfiles WHERE id = NEW.transportista_id), 'ese usuario') USING ERRCODE = '23514'; END`,
    )
    expect(h).toHaveLength(1)
    expect(h[0]).toMatch(/perfiles/)
  })

  it('una columna sensible de NEW o OLD, o la fila entera, es rojo', () => {
    expect(mensajesQueFiltran(`BEGIN RAISE EXCEPTION 'costo %', NEW.costo_real; END`)[0]).toMatch(/NEW\.costo_real/)
    expect(mensajesQueFiltran(`BEGIN RAISE EXCEPTION 'saldo %', OLD.saldo_cuenta; END`)[0]).toMatch(/saldo_cuenta/)
    expect(mensajesQueFiltran(`BEGIN RAISE EXCEPTION 'fila %', to_jsonb(NEW); END`)[0]).toMatch(/fila entera/)
    expect(mensajesQueFiltran(`BEGIN RAISE EXCEPTION 'fila %', NEW; END`)[0]).toMatch(/fila entera/)
  })

  it('el nombre de un producto o de una promo no cuenta: no son datos personales', () => {
    expect(
      mensajesQueFiltran(`
        DECLARE v_nombre text;
        BEGIN
          SELECT nombre INTO v_nombre FROM productos WHERE id = NEW.producto_id;
          RAISE EXCEPTION 'El producto "%" no puede venderse a precio 0', v_nombre USING ERRCODE = 'check_violation';
        END`),
    ).toEqual([])
  })

  it('un RAISE en un comentario no cuenta', () => {
    expect(mensajesQueFiltran(`-- RAISE EXCEPTION 'x %', NEW.saldo_cuenta;\nBEGIN RETURN NEW; END`)).toEqual([])
  })
})

describe('las listas de excepciones sólo se achican', () => {
  it('mensajes-trigger-permitidas.json: las dos del hallazgo al nacer el gate, y cada una con su motivo', () => {
    const { funciones } = leerJson('mensajes-trigger-permitidas.json') as { funciones: Record<string, string> }
    const alNacer = ['pedidos_cliente_asignado()', 'pedidos_entrega_con_chofer()']
    for (const [firma, motivo] of Object.entries(funciones)) {
      expect(alNacer).toContain(firma)
      expect(motivo.length).toBeGreaterThan(20)
    }
  })

  it('cruce-ids-permitidas.json: nace vacía (la pasada de la reauditoría del 12/11 dio limpio)', () => {
    const { funciones } = leerJson('cruce-ids-permitidas.json') as { funciones: Record<string, string> }
    expect(Object.keys(funciones)).toEqual([])
  })

  it('rol-sin-activo-permitidas.json "impl": las ocho del hallazgo al nacer el gate (1595-b4)', () => {
    const { impl } = leerJson('rol-sin-activo-permitidas.json') as { impl: Record<string, string> }
    const alNacer = [
      'crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)',
      'get_audit_history(text,text,integer)',
      'get_suspicious_activity(integer)',
      'imputar_credito_a_pedido_impl(bigint,bigint,numeric)',
      'marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)',
      'marcar_pagos_masivo_impl(bigint[],text,date)',
      'registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)',
      'registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)',
    ]
    for (const firma of Object.keys(impl)) expect(alNacer).toContain(firma)
  })

  it('ensayos-sql-excepciones.json "ensayos" sólo se achica: ninguno nuevo respecto de los del hallazgo al nacer el gate (más los de #1647 que fallan por la base de CI)', () => {
    const { ensayos } = leerJson('ensayos-sql-excepciones.json') as { ensayos: Record<string, { firma: string; motivo: string }> }
    const alNacer = [
      'test-alicuota-linea-recreada-1274.sql',
      'test-alta-en-zona-propia-1553.sql',
      'test-alta-reparto-rol-1112.sql',
      'test-anular-compra-nc-1095.sql',
      'test-anular-salvedad-compra-editada.sql',
      'test-anular-salvedad-lote-bolsa.sql',
      'test-anular-salvedad-pedido-cancelado.sql',
      'test-asignacion-zonas-lecturas-1314-1316.sql',
      'test-aviso-admin-1189.sql',
      'test-cancelar-sin-huella-1114.sql',
      'test-cargo-1.sql',
      'test-cargo-4.sql',
      'test-cargo-5.sql',
      'test-cartera-chofer-y-asignacion-1182-1183.sql',
      'test-checks-1043.sql',
      'test-cobros-por-rpc-1246-1249.sql',
      'test-columnas-protegidas-1151-1155-1156.sql',
      'test-combo-salvedad-1192.sql',
      'test-comisiones-1320-1321.sql',
      'test-compra-costos-decimales-y-version-1557.sql',
      'test-compra-nc-rest-1113.sql',
      'test-contadores-recorrido-1397.sql',
      'test-contenedor-y-canje-a-su-lote-1558.sql',
      'test-control-rendicion-sucursal-nula.sql',
      'test-credito-suelto-1512.sql',
      'test-cupo-promo-y-combo-1300-1301-1283.sql',
      'test-desactivado-sin-rol-1490.sql',
      'test-devolucion-bolsa-1085.sql',
      'test-dia-argentino-1277.sql',
      'test-duplicado-operable-y-cartera-1186-1187.sql',
      'test-edicion-creditos-1446.sql',
      'test-edicion-regalos-salvedades-1323-1327.sql',
      'test-fecha-pedido-piso-1514.sql',
      'test-frenos-nan-ola2-1603.sql',
      'test-gastos-1.sql',
      'test-gastos-2.sql',
      'test-gastos-3.sql',
      'test-gastos-4.sql',
      'test-gastos-5.sql',
      'test-gastos-6.sql',
      'test-gastos-7.sql',
      'test-gastos-personal-1521.sql',
      'test-gastos-rendicion-e-iva-1562.sql',
      'test-gates-1330.sql',
      'test-geolocalizacion-1602.sql',
      'test-grants-rest-1134-1135.sql',
      'test-horario-preventista-1178.sql',
      'test-limpieza-1336-1368-1383.sql',
      'test-limpieza-antes-del-fork-1475.sql',
      'test-lotes-trazabilidad-1054-1073.sql',
      'test-mermas-paginadas-1146.sql',
      'test-minimo-cliente-salvedad-1559.sql',
      'test-movimientos-sin-sucursal-1488.sql',
      'test-nota-credito-lotes-1079.sql',
      'test-pedido-baja-1131.sql',
      'test-pedido-sin-items-1078.sql',
      'test-permisos-1291-1272.sql',
      'test-permisos-1474.sql',
      'test-permisos-cuenta-costos.sql',
      'test-permisos-definer-sin-rol.sql',
      'test-permisos-plata-rest.sql',
      'test-permisos-rol-personal-pagos-1519.sql',
      'test-permisos-sucursal-1374-1334.sql',
      'test-permisos-sucursal-1438.sql',
      'test-permisos-tablero.sql',
      'test-permisos-vb-costos-proveedores.sql',
      'test-politica-precios-1157-1159.sql',
      'test-precio-servidor-1138-1139.sql',
      'test-promo-contenedores-1501.sql',
      'test-promo-fecha-replay-bot-1152-1153-1154.sql',
      'test-promo-vigente-excluyente-1136-1137.sql',
      'test-promos-regalos-1592.sql',
      'test-promos-y-combos-1556.sql',
      'test-quien-marco-la-entrega-1555.sql',
      'test-rama-admin-sucursal-1244.sql',
      'test-regalo-alta-1123.sql',
      'test-regalo-tramo-anterior-1565.sql',
      'test-regalos-vendido-y-foto-1363-1376.sql',
      'test-rendicion-y-entregas-1547-1548.sql',
      'test-reportes-cierran-1297.sql',
      'test-reportes-ola2-1603.sql',
      'test-restos-nucleo-1520.sql',
      'test-resumen-cuenta-1044.sql',
      'test-rol-preventista-extra-1179.sql',
      'test-roles-columnas-caja-1170-1171-1175.sql',
      'test-rutas-1313.sql',
      'test-saldo-bajos-1492.sql',
      'test-salvedad-anulada-1504.sql',
      'test-salvedad-anulada-foto-1595.sql',
      'test-salvedad-anular-1140-1142.sql',
      'test-salvedad-anular-1161-1164.sql',
      'test-salvedad-huella-1126-1127.sql',
      'test-salvedad-replay-lock-1508.sql',
      'test-stock-cambio-cliente-y-canje-1594.sql',
      'test-stock-integridad-1254-1255-1256.sql',
      'test-stock-planilla-y-locks-1295-1296.sql',
      'test-stock-promos-orden-1460.sql',
      'test-triggers-y-deposito-1245.sql',
      'test-usuarios-retencion-ola2-1603.sql',
      'test-venta-edicion-1398.sql',
      'test-venta-j-1098.sql',
      'test-venta-minimo-iva-1470.sql',
      'test-volver-a-pendiente-1313.sql',
    ]
    for (const archivo of Object.keys(ensayos)) expect(alNacer).toContain(archivo)
  })

  it('ensayos-sql-excepciones.json: cada excepción es un ensayo que existe y dice por qué', () => {
    const { ensayos, omitir } = leerJson('ensayos-sql-excepciones.json') as {
      ensayos: Record<string, { firma: string; motivo: string }>
      omitir: Record<string, string>
    }
    // Los dos de concurrencia piden dos sesiones y confirman datos: no se corren nunca en CI.
    expect(Object.keys(omitir).sort()).toEqual([
      'test-concurrencia-monto-pagado-1247.sql',
      'test-concurrencia-pago-fifo.sql',
    ])
    for (const [archivo, v] of [...Object.entries(ensayos), ...Object.entries(omitir)]) {
      const motivo = typeof v === 'string' ? v : v.motivo
      if (typeof v !== 'string') expect(v.firma.length, `firma de ${archivo}`).toBeGreaterThan(5)
      expect(archivo).toMatch(/^test-.*\.sql$/)
      expect(fs.existsSync(path.join(raiz, archivo))).toBe(true)
      expect(motivo.length).toBeGreaterThan(10)
    }
  })
})

describe('el SQL de los complementos', () => {
  it('lee el catálogo y no escribe', () => {
    for (const sql of [SQL_TABLAS_ANON_CATALOGO, SQL_ROL_SIN_ACTIVO_SIN_API, SQL_SEARCH_PATH_FUNCIONES]) {
      expect(sql).toMatch(/\bSELECT\b/)
      expect(sql).not.toMatch(/\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE)\b/i)
    }
  })

  it('las `_impl` son las SIN EXECUTE para authenticated y no las de trigger', () => {
    expect(SQL_ROL_SIN_ACTIVO_SIN_API).toMatch(/NOT has_function_privilege\('authenticated'/)
    expect(SQL_ROL_SIN_ACTIVO_SIN_API).toMatch(/<> 'trigger'::regtype/)
  })

  it('el search_path mira las de public: las definer y las que fijan search_path', () => {
    expect(SQL_SEARCH_PATH_FUNCIONES).toMatch(/pronamespace = 'public'::regnamespace/)
    expect(SQL_SEARCH_PATH_FUNCIONES).toMatch(/p\.prosecdef OR EXISTS \(SELECT 1 FROM unnest\(p\.proconfig\) c WHERE c LIKE 'search_path=%'\)/)
  })
})

describe('problemaDeSearchPath (1564-b8 y 1564-g4)', () => {
  it('una INVOKER con search_path sin pg_temp al final es roja (la llama una definer y corre como postgres)', () => {
    expect(problemaDeSearchPath(['search_path=public'], false)).toMatch(/no termina en pg_temp/)
    expect(problemaDeSearchPath(['search_path=""'], false)).toMatch(/no termina en pg_temp/)
    expect(problemaDeSearchPath(['search_path=pg_temp, public'], false)).toMatch(/no al final/)
  })

  it('una INVOKER con pg_temp al final, o sin search_path (lo hereda; la SQL se inlinea), pasa', () => {
    expect(problemaDeSearchPath(['search_path=public, pg_temp'], false)).toBeNull()
    expect(problemaDeSearchPath(['search_path=pg_temp'], false)).toBeNull()
    expect(problemaDeSearchPath(null, false)).toBeNull()
    expect(problemaDeSearchPath(['statement_timeout=5s'], false)).toBeNull()
  })

  it('pg_temp al final está bien, conserve lo que conserve en el medio', () => {
    expect(problemaDeSearchPath(['search_path=public, pg_temp'])).toBeNull()
    expect(problemaDeSearchPath(['search_path=public, pg_catalog, pg_temp'])).toBeNull()
    expect(problemaDeSearchPath(['search_path=public, extensions, pg_temp', 'statement_timeout=5s'])).toBeNull()
    expect(problemaDeSearchPath(['statement_timeout=5s', 'search_path=pg_temp'])).toBeNull()
  })

  it("`SET search_path TO 'public'` (las 352 de antes de la migración) es rojo", () => {
    expect(problemaDeSearchPath(['search_path=public'])).toMatch(/no termina en pg_temp/)
    expect(problemaDeSearchPath(['search_path=public, pg_catalog'])).toMatch(/no termina en pg_temp/)
  })

  it('pg_temp en otro lugar que el final es rojo: se busca antes que lo que le sigue', () => {
    expect(problemaDeSearchPath(['search_path=pg_temp, public'])).toMatch(/no al final/)
  })

  it('pg_temp repetido es rojo aunque el último sea pg_temp: Postgres usa la primera aparición (H1 de la lente)', () => {
    expect(problemaDeSearchPath(['search_path=pg_temp, public, pg_temp'])).toMatch(/más de una vez/)
    expect(problemaDeSearchPath(['search_path=public, pg_temp, pg_temp'], false)).toMatch(/más de una vez/)
  })

  it('el SQL no filtra por prokind: un procedimiento con SET search_path también se mira (H2 de la lente)', () => {
    expect(SQL_SEARCH_PATH_FUNCIONES).not.toMatch(/prokind/)
  })

  it('una definer sin search_path es roja: usa el de quien la llama', () => {
    expect(problemaDeSearchPath(null)).toMatch(/no fija search_path/)
    expect(problemaDeSearchPath([])).toMatch(/no fija search_path/)
    expect(problemaDeSearchPath(['statement_timeout=5s'])).toMatch(/no fija search_path/)
  })

  it('un esquema que sólo se parece a pg_temp no cuenta', () => {
    expect(problemaDeSearchPath(['search_path=public, pg_temp_3'])).toMatch(/no termina en pg_temp/)
    expect(problemaDeSearchPath(['search_path=public, "pg_temp "'])).toMatch(/no termina en pg_temp/)
  })
})

describe('destino de la base de los gates', () => {
  // Se arma por partes: una URL con usuario y clave escrita entera la frena check-secrets.sh.
  const urlCon = (usuario: string, host = 'host') => ['postgresql:', '', `${usuario}:clave@${host}/postgres`].join('/')

  it('GATE_DB_CONTENEDOR manda sobre las URL, y GATE_DB_URL sobre SUPABASE_DB_URL', () => {
    expect(destino({ GATE_DB_CONTENEDOR: 'c1', GATE_DB_URL: 'postgresql://x' }).tipo).toBe('docker')
    expect(destino({ GATE_DB_URL: 'postgresql://a', SUPABASE_DB_URL: 'postgresql://b' }).url).toBe('postgresql://a')
    expect(destino({ SUPABASE_DB_URL: 'postgresql://b' }).url).toBe('postgresql://b')
    expect(destino({})).toBeNull()
  })

  it('lista blanca: sólo el contenedor local o una URL a localhost / 127.0.0.1 / ::1 es local (H6 de la lente de #1645)', () => {
    expect(esLocal(destino({ GATE_DB_CONTENEDOR: 'ci-sql' }))).toBe(true)
    expect(esLocal(destino({ GATE_DB_URL: urlCon('postgres', 'localhost:54430') }))).toBe(true)
    expect(esLocal(destino({ GATE_DB_URL: urlCon('postgres', '127.0.0.1:54430') }))).toBe(true)
    expect(esLocal(destino({ GATE_DB_URL: urlCon('postgres', '[::1]:54430') }))).toBe(true)
    // La de prod, una IP de afuera, una URL sin host (toma PGHOST del entorno) y service=… no lo son,
    // aunque la URL no nombre el ref de prod: antes la lista negra los dejaba pasar.
    expect(esLocal(destino({ GATE_DB_URL: urlCon('postgres.hmuchlzmuqqxcldbzkgc', 'aws-1.pooler.example:5432') }))).toBe(false)
    expect(esLocal(destino({ GATE_DB_URL: urlCon('postgres', '10.0.0.5:5432') }))).toBe(false)
    expect(esLocal(destino({ GATE_DB_URL: ['postgresql:', '', '', 'postgres'].join('/') }))).toBe(false)
    expect(esLocal(destino({ GATE_DB_URL: 'service=prod' }))).toBe(false)
    expect(esLocal(destino({ SUPABASE_DB_URL: urlCon('postgres', 'localhost:5432') }))).toBe(true)
    expect(esLocal(null)).toBe(false)
  })
})

describe('veredicto de un ensayo (H4 de la lente de #1645)', () => {
  it('«ENSAYO OK» en un NOTICE o en el mensaje de su excepción final es OK', () => {
    expect(veredicto('NOTICE:  ENSAYO OK\nERROR:  ENSAYO_ROLLBACK').ok).toBe(true)
    expect(veredicto('ERROR:  ENSAYO OK · R1 R2 R3 (todo revertido)').ok).toBe(true)
  })

  it('«ensayo #1234 OK» también lo es: antes el criterio buscaba el texto contiguo «ENSAYO OK» y no lo veía', () => {
    expect(veredicto('NOTICE:  ensayo #1074 OK (todo revertido)').ok).toBe(true)
  })

  it('un «ENSAYO FALLÓ» (con o sin tilde) no es OK aunque otra línea diga OK', () => {
    expect(veredicto('NOTICE:  ensayo OK parte 1\nERROR:  ENSAYO FALLÓ (2 fallas):\n  C1 mal').ok).toBe(false)
    expect(veredicto('ERROR:  ENSAYO FALLO · sin fixtures').ok).toBe(false)
  })

  it('«ENSAYO OK · 0 fallas» es OK: «fallas» en una línea de OK no es un veredicto', () => {
    expect(veredicto('ERROR:  ENSAYO OK · 0 fallas · notas: C3 sin obtener_resumen_compras').ok).toBe(true)
  })

  it('un ensayo que no dice nada no es OK', () => {
    expect(veredicto('')).toEqual({ ok: false, firma: 'no dijo ENSAYO OK' })
  })

  it('la firma de la falla trae la línea del veredicto y las dos siguientes, sin uuids ni números', () => {
    const v = veredicto(
      'ERROR:  ENSAYO FALLÓ (15):\n  C1 hay 84 checks, no 79\n  C2 RUTA-A no ve la parada 4521\n  C3 otra\nCONTEXT:  PL/pgSQL',
    )
    expect(v.ok).toBe(false)
    expect(v.firma).toBe('ENSAYO FALLÓ (N): | CN hay N checks, no N | CN RUTA-A no ve la parada N')
    expect(normalizarFirma('a 0238dba2-771c-447d-b7ae-3d1d8d9cdea9 b 12')).toBe('a <uuid> b N')
  })

  it('una firma distinta es otra falla: la excepción vieja no la tapa', () => {
    const antes = veredicto('ERROR:  el ensayo necesita un cliente activo en la sucursal 1').firma
    const ahora = veredicto('ERROR:  ENSAYO FALLÓ · V1 dio otra cosa').firma
    expect(ahora).not.toBe(antes)
  })
})
