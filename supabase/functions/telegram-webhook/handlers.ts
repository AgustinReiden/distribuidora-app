// Handlers de comandos del bot. Fase 1.2 — solo /start, /ayuda, /vincular.
// El LLM (Gemini) entra en Fase 3; mientras tanto, mensajes que no son
// comandos reciben un placeholder.

import { canjearCodigo, resolveUserByTelegramId } from "../_shared/auth.ts";
import { logEvent } from "../_shared/audit.ts";
import { escapeMarkdownV2, sendMessage } from "../_shared/telegram.ts";
import type { BotRol, BotUser, TelegramUpdate, TelegramUser } from "../_shared/types.ts";

const CODIGO_REGEX = /^[A-Z0-9]{6}$/;

export async function handleUpdate(update: TelegramUpdate): Promise<void> {
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

  // Comando /start (con o sin sufijo @bot_name que Telegram añade en grupos).
  if (text === "/start" || text.startsWith("/start@") || text.startsWith("/start ")) {
    return handleStart(chatId, tgUser, user);
  }

  // Comando /ayuda o /help (alias en inglés es común).
  if (
    text === "/ayuda" || text === "/help" ||
    text.startsWith("/ayuda@") || text.startsWith("/help@")
  ) {
    return handleAyuda(chatId, tgUser.id, user);
  }

  // Comando /vincular CODIGO.
  if (text.startsWith("/vincular ") || text.startsWith("/vincular@")) {
    // Soportar `/vincular@bot_name CODIGO`: dropeamos el primer token.
    const partes = text.split(/\s+/);
    const codigo = (partes[1] ?? "").toUpperCase();
    return handleVincular(chatId, tgUser, codigo);
  }
  if (text === "/vincular") {
    await sendMessage(
      chatId,
      "Uso: /vincular CODIGO\n\n" +
        "Generá un código en la app web (Perfil > Vincular Telegram) y mandalo así:\n" +
        "/vincular ABC123",
    );
    return;
  }

  // Mensaje normal: respuesta placeholder hasta Fase 3.
  if (!user) {
    await sendMessage(
      chatId,
      "Hola! Todavía no estás vinculado al sistema.\n\n" +
        "Pedí un código en la app web (Perfil > Vincular Telegram) y mandalo así:\n" +
        "/vincular ABC123",
    );
    return;
  }
  await sendMessage(
    chatId,
    "Recibí tu mensaje. El asistente IA todavía no está activo (próxima fase). " +
      "Mientras tanto: probá /ayuda para ver los comandos disponibles.",
  );
}

// ----------------------------------------------------------------------------
// /start
// ----------------------------------------------------------------------------

async function handleStart(
  chatId: number,
  tgUser: TelegramUser,
  user: BotUser | null,
): Promise<void> {
  if (user) {
    const nombre = escapeMarkdownV2(tgUser.first_name);
    const rol = escapeMarkdownV2(user.rol);
    await sendMessage(
      chatId,
      `¡Hola, ${nombre}\\! Ya estás vinculado como *${rol}*\\.\n\n` +
        `Probá /ayuda para ver lo que puedo hacer\\.`,
      { parse_mode: "MarkdownV2" },
    );
  } else {
    await sendMessage(
      chatId,
      "¡Hola! Soy el asistente de la distribuidora.\n\n" +
        "Para empezar necesito vincularte a tu cuenta:\n" +
        "1. Entrá a la app web\n" +
        "2. Andá a tu perfil > 'Vincular Telegram'\n" +
        "3. Copiá el código de 6 caracteres\n" +
        "4. Mandame: /vincular ABC123\n\n" +
        "Comandos disponibles: /ayuda",
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

function ayudaPorRol(rol: BotRol): string {
  const comunes = ["/start - Mensaje de bienvenida", "/ayuda - Ver esta lista"];
  // Fase 1.2: el LLM y las tools no están todavía. Mostramos solo lo que
  // realmente funciona + un teaser de lo que viene en Fase 3.
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
        "- Consultar tu lista de clientes",
        "- Ver resumen de pedidos del día",
        "- Crear pedidos por chat",
      ];
      break;
    case "transportista":
      extras = [
        "",
        "Próximamente (Fase 3):",
        "- Ver tu hoja de ruta",
        "- Marcar entregas y registrar pagos",
      ];
      break;
    case "deposito":
      extras = [
        "",
        "Próximamente: consultas de stock y compras",
      ];
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
  return ["Comandos disponibles:", ...comunes, ...extras].join("\n");
}

// ----------------------------------------------------------------------------
// /vincular CODIGO
// ----------------------------------------------------------------------------

async function handleVincular(
  chatId: number,
  tgUser: TelegramUser,
  codigo: string,
): Promise<void> {
  if (!codigo) {
    await sendMessage(
      chatId,
      "Uso: /vincular CODIGO\n\nEjemplo: /vincular ABC123",
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
