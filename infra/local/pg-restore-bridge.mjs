/**
 * Temporary TCP forwarding for a manually approved private PostgreSQL
 * restore. This profile is OFF in normal Compose startup.
 * Never log traffic, passwords or SQL payloads.
 */
import net from "node:net";

const listener = net.createServer((client) => {
  const db = net.connect({ host: "db", port: 5432 });
  client.on("error", () => db.destroy());
  db.on("error", () => client.destroy());
  client.pipe(db);
  db.pipe(client);
});
listener.on("error", () => {
  console.error("Temporary PostgreSQL restore bridge failed");
  process.exitCode = 1;
});
listener.listen({host: "0.0.0.0", port: 15432});
