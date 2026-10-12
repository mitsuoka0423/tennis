import { serve } from "@hono/node-server";
import { openDb } from "../db.ts";
import { todayJst } from "../time.ts";
import { createApp } from "../web/app.ts";

const db = openDb(process.env.DB_PATH ?? "tournaments.sqlite");
const port = Number(process.env.PORT ?? 8080);
serve({ fetch: createApp(db, () => todayJst()).fetch, port, hostname: "0.0.0.0" });
console.log(`http://localhost:${port}`);
