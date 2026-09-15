// Edge Function: telegram-webhook
//
// Endpoint que Telegram llama vía setWebhook. El flujo entero vive en
// `request.ts` (handleWebhookRequest) para poder testearlo sin levantar un
// servidor; acá sólo queda el binding HTTP.
//
// Variables de entorno requeridas (set en Supabase Dashboard):
//   - SUPABASE_URL                  (auto-inyectada por Supabase)
//   - SUPABASE_SERVICE_ROLE_KEY     (auto-inyectada por Supabase)
//   - TELEGRAM_BOT_TOKEN            (BotFather)
//   - TELEGRAM_WEBHOOK_SECRET       (string random, único por proyecto)

import { serve } from "std/http/server.ts";
import { handleWebhookRequest } from "./request.ts";

serve((req: Request) => handleWebhookRequest(req));
