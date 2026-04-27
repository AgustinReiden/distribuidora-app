// Handlers de comandos del bot. Phase 2 task 2.3 — command router con
// scope checks + 5 nuevos slash commands (/cliente, /producto, /saldo,
// /misclientes, /recorrido). Los comandos legacy /start, /ayuda, /vincular
// siguen handcoded acá porque tienen lógica especial (no necesitan tool
// invocation y deben funcionar incluso para usuarios no vinculados).
//
// Flujo de handleUpdate:
//   1. bootCommands() — registra tools + comandos en el primer call.
//   2. Audit del mensaje entrante (con perfil_id si está vinculado).
//   3. Si es un comando:
//      a. /start, /ayuda, /vincular → handler legacy.
//      b. Comando registrado en el router → scope check + invoke handler.
//      c. Comando desconocido → mensaje "no reconocido".
//   4. Si no es comando → placeholder hasta Phase 3 (Gemini).

import { canjearCodigo, resolveUserByTelegramId } from "../_shared/auth.ts";
import { logEvent } from "../_shared/audit.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";
import { escapeMarkdownV2, sendMessage } from "../_shared/telegram.ts";
import { registerAllTools } from "../_shared/tools/index.ts";
import type { ToolContext } from "../_shared/tools/base.ts";
import { runAgent } from "../_shared/gemini/agent.ts";
import type { BotRol, BotUser, TelegramUpdate, TelegramUser } from "../_shared/types.ts";

import { parseCommand } from "./commands/parser.ts";
import { getCommand, listCommands, registerCommand } from "./commands/router.ts";
import type { CommandSpec } from "./commands/types.ts";
import { clienteCommand } from "./commands/cliente.ts";
import { productoCommand } from "./commands/producto.ts";
import { saldoCommand } from "./commands/saldo.ts";
import { misClientesCommand } from "./commands/misclientes.ts";
import { recorridoCommand } from "./commands/recorrido.ts";
import { sugerenciasCommand } from "./commands/sugerencias.ts";

const CODIGO_REGEX = /^[A-Z0-9]{6}$/;

// ----------------------------------------------------------------------------
// Boot del registry. Idempotente — se llama al inicio de cada handleUpdate.
// El flag local evita registrar dos veces (si ya estaba booteado, los
// register* tirarían throw).
// ----------------------------------------------------------------------------

let _booted = false;

function bootCommands(): void {
  if (_booted) return;
  registerAllTools();
  registerCommand(clienteCommand);
  registerCommand(productoCommand);
  registerCommand(saldoCommand);
  registerCommand(misClientesCommand);
  registerCommand(recorridoCommand);
  registerCommand(sugerenciasCommand);
  _booted = true;
}

/** Test helper: permite a los tests resetear el flag. NO usar en producción. */
export function _resetBootForTests(): void {
  _booted = false;
}

// ----------------------------------------------------------------------------
// handleUpdate — entry point del webhook.
// ----------------------------------------------------------------------------

export async function handleUpdate(update: TelegramUpdate): Promise<void> {
  bootCommands();

  const msg = update.message;
  // El index.ts ya filtra updates sin message+text+from, pero hacemos un guard
  // defensivo para que este módulo sea testeable de forma aislada.
  if (!msg || !msg.text || !msg.from) return;

  const text = msg.text.trim();
  const chatId = msg.chat.id;
  const tgUser = msg.from;

  // Resolvemos al usuario UNA SOLA VEZ por update. Esto:
  //   1. Evita N lookups cuando el handler también necesita al user.
  //   2. Permite poblar perfil_id/rol en el audit del mensaje entrante,
  //      respetando el contrato "audit incluye identidad cuando se conoce".
  const user = await resolveUserByTelegramId(tgUser.id);

  // Audit del mensaje entrante (fail-closed: si esto explota, queremos saber).
  await logEvent({
    telegram_user_id: tgUser.id,
    perfil_id: user?.perfil_id,
    rol: user?.rol,
    tipo: "mensaje",
    texto_usuario: text,
  });

  const parsed = parseCommand(text);
  if (parsed) {
    // ----- Comandos legacy (siempre hardcodeados) ---------------------------
    if (parsed.command === "/start") {
      return handleStart(chatId, tgUser, user);
    }
    if (parsed.command === "/ayuda" || parsed.command === "/help") {
      return handleAyuda(chatId, tgUser.id, user);
    }
    if (parsed.command === "/vincular") {
      return handleVincular(chatId, tgUser, parsed.rawArgs);
    }

    // ----- Comandos del router ---------------------------------------------
    const cmd = getCommand(parsed.command);
    if (cmd) {
      // Scope check.
      if (cmd.scope !== "guest" && !user) {
        await sendMessage(
          chatId,
          "Necesitás vincularte primero. Mandá /vincular CODIGO.",
        );
        await logEvent({
          telegram_user_id: tgUser.id,
          tipo: "comando",
          tool_name: parsed.command.slice(1),
          resultado_meta: { blocked: "no_vinculado" },
        });
        return;
      }
      if (
        Array.isArray(cmd.scope) &&
        (!user || !cmd.scope.includes(user.rol))
      ) {
        const rolesTxt = cmd.scope.join(", ");
        await sendMessage(
          chatId,
          `Este comando es solo para: ${rolesTxt}.`,
        );
        await logEvent({
          telegram_user_id: tgUser.id,
          perfil_id: user?.perfil_id,
          rol: user?.rol,
          tipo: "comando",
          tool_name: parsed.command.slice(1),
          resultado_meta: { blocked: "rol_no_permitido", scope: cmd.scope },
        });
        return;
      }

      // Audit del comando ANTES de ejecutarlo (así si el handler explota,
      // sabemos que se intentó). El registry agregará tool_call/error
      // específicos por cada invokeTool.
      await logEvent({
        telegram_user_id: tgUser.id,
        perfil_id: user?.perfil_id,
        rol: user?.rol,
        tipo: "comando",
        tool_name: parsed.command.slice(1),
      });

      const toolCtx: ToolContext | null = user
        ? {
          perfil_id: user.perfil_id,
          rol: user.rol,
          sucursal_id: user.sucursal_id,
          supabase: getServiceRoleClient(),
        }
        : null;

      await cmd.handler({
        user,
        tgUser,
        chatId,
        rawArgs: parsed.rawArgs,
        toolCtx,
      });
      return;
    }

    // ----- Comando desconocido ---------------------------------------------
    await sendMessage(
      chatId,
      `Comando \`${escapeMarkdownV2(parsed.command)}\` no reconocido\\. Probá /ayuda\\.`,
      { parse_mode: "MarkdownV2" },
    );
    return;
  }

  // ----- Mensaje no-comando: invocar agente IA (Phase 3 task 3.2) -----------
  if (!user) {
    await sendMessage(
      chatId,
      "Hola! Todavía no estás vinculado al sistema.\n\n" +
        "Pedí un código en la app web (Perfil > Vincular Telegram) y mandalo así:\n" +
        "/vincular ABC123",
    );
    return;
  }

  // runAgent maneja audit + memory save por dentro. Solo entregamos el texto.
  // OJO: sendMessage SIN parse_mode — el LLM puede emitir texto que parezca
  // Markdown sin ser válido en MarkdownV2, y un parse error 400 deja al user
  // sin respuesta. Plain text es robusto. Si en el futuro queremos rich
  // formatting, hay que agregar un wrapper que sanitice MV2 (Phase 4+).
  try {
    const result = await runAgent({
      supabase: getServiceRoleClient(),
      user,
      telegram_user_id: tgUser.id,
      userMessage: text,
    });
    await sendMessage(chatId, result.text);
  } catch (err) {
    console.error("[handler] runAgent failed:", err);
    await logEvent({
      telegram_user_id: tgUser.id,
      perfil_id: user.perfil_id,
      rol: user.rol,
      tipo: "error",
      resultado_meta: {
        gemini: true,
        crashed: true,
        error: err instanceof Error ? err.message : String(err),
      },
    }).catch(() => {});
    await sendMessage(
      chatId,
      "Tuve un problema procesando tu mensaje. Probá de nuevo en un momento o usá /ayuda.",
    );
  }
}

// ----------------------------------------------------------------------------
// /start
// ----------------------------------------------------------------------------

async function handleStart(
  chatId: number,
  tgUser: TelegramUser,
  user: BotUser | null,
): Promise<void> {
  // Disclaimer de privacidad alineado con la sección "Privacidad y retención"
  // del README (90 días en bot_audit_log). Lo mandamos en /start porque es
  // el primer punto de contacto y el bot no tiene UI para aceptar términos.
  // En MarkdownV2 todos los `.` `!` etc. requieren escape; el `_..._` lo
  // renderiza Telegram como italics. Si en el futuro este string crece,
  // moverlo a una constante exportable.
  const privacyMv2 =
    "_Tus mensajes y las respuestas del bot quedan registrados " +
    "\\(90 días\\) para auditoría y mejora del servicio\\._";

  if (user) {
    const nombre = escapeMarkdownV2(tgUser.first_name);
    const rol = escapeMarkdownV2(user.rol);
    await sendMessage(
      chatId,
      `¡Hola, ${nombre}\\! Ya estás vinculado como *${rol}*\\.\n\n` +
        `Probá /ayuda para ver lo que puedo hacer\\.\n\n` +
        privacyMv2,
      { parse_mode: "MarkdownV2" },
    );
  } else {
    // El bloque "no vinculado" iba en plain text — para consistencia y para
    // que el italics del disclaimer renderee, lo migramos a MarkdownV2 con
    // los escapes apropiados.
    await sendMessage(
      chatId,
      "¡Hola\\! Soy el asistente de la distribuidora\\.\n\n" +
        "Para empezar necesito vincularte a tu cuenta:\n" +
        "1\\. Entrá a la app web\n" +
        "2\\. Andá a tu perfil \\> 'Vincular Telegram'\n" +
        "3\\. Copiá el código de 6 caracteres\n" +
        "4\\. Mandame: /vincular ABC123\n\n" +
        "Comandos disponibles: /ayuda\n\n" +
        privacyMv2,
      { parse_mode: "MarkdownV2" },
    );
  }

  await logEvent({
    telegram_user_id: tgUser.id,
    perfil_id: user?.perfil_id,
    rol: user?.rol,
    tipo: "comando",
    tool_name: "start",
    resultado_meta: { vinculado: !!user },
  });
}

// ----------------------------------------------------------------------------
// /ayuda
// ----------------------------------------------------------------------------

async function handleAyuda(
  chatId: number,
  telegramUserId: number,
  user: BotUser | null,
): Promise<void> {
  let texto: string;
  if (!user) {
    texto = "Todavía no estás vinculado.\n\n" +
      "Generá un código en la app web (Perfil > Vincular Telegram) y mandalo:\n" +
      "/vincular ABC123";
  } else {
    texto = ayudaPorRol(user.rol);
  }

  await sendMessage(chatId, texto);

  await logEvent({
    telegram_user_id: telegramUserId,
    perfil_id: user?.perfil_id,
    rol: user?.rol,
    tipo: "comando",
    tool_name: "ayuda",
    resultado_meta: { vinculado: !!user },
  });
}

/**
 * Lista los comandos del router que el rol `rol` puede invocar y los
 * concatena con los comandos legacy. Usamos `listCommands()` (deduplicado por
 * aliases) y filtramos por scope: "any" pasa siempre, BotRol[] solo si el rol
 * está incluido, "guest" siempre se muestra.
 */
function comandosDisponiblesPara(rol: BotRol): CommandSpec[] {
  return listCommands().filter((c) => {
    if (c.scope === "any" || c.scope === "guest") return true;
    return c.scope.includes(rol);
  });
}

function ayudaPorRol(rol: BotRol): string {
  const comunes = ["/start - Mensaje de bienvenida", "/ayuda - Ver esta lista"];

  // Comandos del router que el rol puede usar (formateados como
  // "<name> - <description>").
  const routerCmds = comandosDisponiblesPara(rol).map(
    (c) => `${c.name} - ${c.description}`,
  );

  // Teaser de Phase 3 (LLM) + cualquier extra específico de rol.
  let extras: string[];
  switch (rol) {
    case "admin":
      extras = [
        "",
        "Próximamente (Fase 3):",
        "- Consultas sobre ventas, stock y rendiciones",
        "- Reportes ejecutivos por sucursal",
      ];
      break;
    case "preventista":
      extras = [
        "",
        "Próximamente (Fase 3):",
        "- Crear pedidos por chat",
      ];
      break;
    case "transportista":
      extras = [
        "",
        "Próximamente (Fase 3):",
        "- Marcar entregas y registrar pagos",
      ];
      break;
    case "deposito":
      extras = ["", "Próximamente: consultas de stock y compras"];
      break;
    case "encargado":
      extras = [
        "",
        "Próximamente: vista de admin parcial (sin gestión de usuarios)",
      ];
      break;
    default:
      // Defensivo: si bot_usuarios.rol tuviera un valor fuera del union (por
      // ej. un rol nuevo agregado en perfiles que todavía no contemplamos
      // acá), no queremos un TypeError por hacer spread de undefined.
      // Logueamos warning y mostramos solo los comandos comunes.
      console.warn(`ayudaPorRol: rol no esperado "${rol as string}"`);
      extras = [];
      break;
  }

  return ["Comandos disponibles:", ...comunes, ...routerCmds, ...extras].join(
    "\n",
  );
}

// ----------------------------------------------------------------------------
// /vincular CODIGO
// ----------------------------------------------------------------------------

async function handleVincular(
  chatId: number,
  tgUser: TelegramUser,
  rawArgs: string,
): Promise<void> {
  // Tomamos el primer token como código — preservamos el comportamiento
  // original (`text.split(/\s+/)` / partes[1]). Si alguien manda
  // `/vincular ABC123 basura` tomamos "ABC123" e ignoramos lo demás.
  const trimmed = rawArgs.trim();
  const firstToken = trimmed.length > 0 ? trimmed.split(/\s+/)[0] : "";
  const codigo = firstToken.toUpperCase();

  if (!codigo) {
    await sendMessage(
      chatId,
      "Uso: /vincular CODIGO\n\n" +
        "Generá un código en la app web (Perfil > Vincular Telegram) y mandalo así:\n" +
        "/vincular ABC123",
    );
    // No auditamos el "uso vacío" como error: es información inválida cero,
    // no hay codigo_redacted que loguear.
    return;
  }

  if (!CODIGO_REGEX.test(codigo)) {
    await sendMessage(
      chatId,
      "Código inválido. Deben ser 6 caracteres (letras mayúsculas y números).\n\n" +
        "Ejemplo: /vincular ABC123",
    );
    await logEvent({
      telegram_user_id: tgUser.id,
      tipo: "comando",
      tool_name: "vincular",
      parametros: { codigo_redacted: redactCodigo(codigo) },
      resultado_meta: { success: false, error: "formato" },
    });
    return;
  }

  const result = await canjearCodigo({
    codigo,
    telegram_user_id: tgUser.id,
    telegram_username: tgUser.username,
  });

  if (result.ok) {
    const nombreSafe = escapeMarkdownV2(result.user.nombre || tgUser.first_name);
    const rolSafe = escapeMarkdownV2(result.user.rol);
    await sendMessage(
      chatId,
      `✅ Vinculado correctamente, ${nombreSafe}\\.\n\n` +
        `Rol: *${rolSafe}*\n` +
        `Probá /ayuda para ver lo que puedo hacer\\.`,
      { parse_mode: "MarkdownV2" },
    );
    await logEvent({
      telegram_user_id: tgUser.id,
      perfil_id: result.user.perfil_id,
      rol: result.user.rol,
      tipo: "comando",
      tool_name: "vincular",
      parametros: { codigo_redacted: redactCodigo(codigo) },
      resultado_meta: { success: true },
    });
    return;
  }

  // result.ok === false → mapear error a mensaje claro.
  const mensaje = mensajeErrorVincular(result.error);
  await sendMessage(chatId, mensaje);
  await logEvent({
    telegram_user_id: tgUser.id,
    tipo: "comando",
    tool_name: "vincular",
    parametros: { codigo_redacted: redactCodigo(codigo) },
    resultado_meta: { success: false, error: result.error },
  });
}

/**
 * Redacta un OTP para el audit log: muestra los primeros 2 chars + asterisks.
 * Aunque el código tiene TTL corto y se invalida al usarse, el audit queda en
 * DB y puede filtrarse a backups/exports — preferimos no persistir el OTP en
 * plaintext.
 */
function redactCodigo(codigo: string): string {
  return codigo.length === 6 ? `${codigo.slice(0, 2)}****` : "****";
}

function mensajeErrorVincular(
  error: "no_encontrado" | "expirado" | "ya_usado" | "perfil_invalido" | "rpc_error",
): string {
  switch (error) {
    case "no_encontrado":
      return "❌ Ese código no existe.\n\n" +
        "Generá uno nuevo en la app web (Perfil > Vincular Telegram).";
    case "expirado":
      return "❌ Ese código expiró (duran 10 minutos).\n\n" +
        "Generá uno nuevo en la app web (Perfil > Vincular Telegram).";
    case "ya_usado":
      return "❌ Ese código ya fue usado.\n\n" +
        "Generá uno nuevo en la app web (Perfil > Vincular Telegram).";
    case "perfil_invalido":
      return "❌ El perfil asociado al código está desactivado. " +
        "Hablá con un administrador.";
    case "rpc_error":
      return "❌ Hubo un error procesando tu código. Probá de nuevo en un momento.";
  }
}
