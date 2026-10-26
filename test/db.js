"use strict";

/**
 * PostgreSQL access for the Sitewise backend.
 *
 * This is the only module in the project that knows how to reach PostgreSQL.
 * Everything else goes through the helpers exported here, so there is exactly
 * one place to audit for credential handling and one place to change a
 * connection setting.
 *
 * ## Credential handling
 *
 * Every value comes from the environment (`.env`, loaded by `dotenv`). Nothing
 * is hardcoded, and nothing from the config is ever echoed back to a client:
 * the exported error type deliberately carries only a short, non-sensitive
 * reason. `pg`'s own errors are mapped before they leave this file, because a
 * raw driver error can include the connection string.
 *
 * ## Pooling
 *
 * A single `Pool` is created per process and reused. `pg` acquires and releases
 * connections per query, so no route needs to manage connections by hand — and
 * none may, because holding one across an `await` on unrelated work is the
 * usual way pools deadlock.
 *
 * ## Why the `PG*` names
 *
 * `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` are libpq's own
 * variable names. Using them means `psql`, `pg_dump` and this service all read
 * the same configuration, so a shell that can run `psql` can also run the
 * backend with no extra setup.
 */

const { Pool } = require("pg");

/** PostgreSQL's default port, used only if `PGPORT` is unset. */
const DEFAULT_PORT = 5432;

/**
 * Thrown for any database problem that should surface to an HTTP client.
 *
 * Carries a `status` and a `reason` that are safe to return verbatim. It never
 * wraps or forwards the driver's message, which may contain the host, user or
 * password.
 */
class DatabaseError extends Error {
  constructor(reason, status = 500, code = "DB_ERROR") {
    super(reason);
    this.name = "DatabaseError";
    this.reason = reason;
    this.status = status;
    this.code = code;
  }
}

let pool = null;

/**
 * Reads and validates the connection settings.
 *
 * Throws rather than returning a partial config: attempting a connection with
 * an empty password produces a confusing authentication error, whereas naming
 * the missing variable tells the operator exactly what to fix.
 */
function readConfig() {
  const raw = {
    host: process.env.PGHOST,
    port: process.env.PGPORT,
    database: process.env.PGDATABASE,
    user: process.env.PGUSER,
    password: process.env.PGPASSWORD,
  };

  const missing = Object.keys(raw).filter(
    (key) => raw[key] === undefined || raw[key] === "",
  );
  if (missing.length > 0) {
    throw new DatabaseError(
      `Database configuration is incomplete. Missing environment variable(s): ` +
        `${missing.join(", ")}. Copy test/.env.example to test/.env and fill ` +
        `it in.`,
      500,
      "DB_CONFIG_MISSING",
    );
  }

  const port = Number(raw.port);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new DatabaseError(
      `PGPORT must be a valid port number, received "${raw.port}".`,
      500,
      "DB_CONFIG_INVALID",
    );
  }

  const intFromEnv = (name, fallback) => {
    const value = Number(process.env[name]);
    return Number.isFinite(value) && value > 0 ? value : fallback;
  };

  return {
    host: raw.host,
    port,
    database: raw.database,
    user: raw.user,
    password: raw.password,
    max: intFromEnv("PGPOOL_MAX", 10),
    idleTimeoutMillis: intFromEnv("PGPOOL_IDLE_TIMEOUT_MS", 30000),
    connectionTimeoutMillis: intFromEnv("PGCONNECT_TIMEOUT_MS", 5000),
  };
}

/**
 * Returns the process-wide pool, creating it on first use.
 *
 * Lazy so that importing this module never opens a socket — the server can
 * start and serve its non-database routes even when PostgreSQL is down, and the
 * health check is what reports the outage.
 */
function getPool() {
  if (pool) return pool;

  const config = readConfig();
  pool = new Pool(config);

  // An idle client can fail (server restart, network drop). Without a listener
  // Node treats it as an unhandled 'error' event and terminates the process.
  // Logging keeps the service alive; the next query re-establishes.
  pool.on("error", (err) => {
    console.error(
      `[db] idle client error (code=${err.code || "unknown"}). ` +
        `The pool will reconnect on the next query.`,
    );
  });

  return pool;
}

/**
 * Runs a parameterised query.
 *
 * `text` must always use `$1`, `$2`, … placeholders. Values passed via `params`
 * are never interpolated into the SQL string by the driver, which is what
 * prevents SQL injection.
 */
async function query(text, params = []) {
  try {
    return await getPool().query(text, params);
  } catch (err) {
    throw toDatabaseError(err);
  }
}

/**
 * Maps a driver error onto a safe [DatabaseError].
 *
 * The driver's message is never forwarded: it can contain the host, port, role
 * and database name. Only the SQLSTATE code and a fixed, generic reason cross
 * the boundary.
 */
function toDatabaseError(err) {
  if (err instanceof DatabaseError) return err;

  switch (err.code) {
    // 28P01 / 28000 — authentication and authorisation.
    case "28P01":
    case "28000":
      return new DatabaseError(
        "The database rejected the configured credentials. Verify PGUSER and " +
          "PGPASSWORD, and confirm the role exists.",
        503,
        "DB_AUTH_FAILED",
      );
    // 3D000 — the database does not exist.
    case "3D000":
      return new DatabaseError(
        "The configured database does not exist on this server. Verify " +
          "PGDATABASE.",
        503,
        "DB_NOT_FOUND",
      );
    // 42P01 — a relation named in the SQL does not exist.
    case "42P01":
      return new DatabaseError(
        "A required table or view is missing. The schema may not have been " +
          "created yet.",
        500,
        "DB_RELATION_MISSING",
      );
    // 42501 — insufficient privilege.
    case "42501":
      return new DatabaseError(
        "The configured role lacks permission for this operation.",
        403,
        "DB_PERMISSION_DENIED",
      );
    default:
      break;
  }

  // Connection-level failures carry no SQLSTATE, only a syscall errno.
  if (
    err.code === "ECONNREFUSED" ||
    err.code === "ENOTFOUND" ||
    err.code === "ETIMEDOUT" ||
    err.code === "EHOSTUNREACH" ||
    err.code === "ECONNRESET"
  ) {
    return new DatabaseError(
      "Could not reach the PostgreSQL server. Confirm it is running and that " +
        "PGHOST and PGPORT are correct.",
      503,
      "DB_UNREACHABLE",
    );
  }

  return new DatabaseError(
    "The database query failed.",
    500,
    "DB_QUERY_FAILED",
  );
}

/**
 * Checks connectivity and reports the server identity.
 *
 * Read-only. Returns no configuration values — only what the server says about
 * itself, which is what an operator needs to confirm they reached the intended
 * instance.
 */
async function healthCheck() {
  const started = Date.now();

  const { rows } = await query(
    `SELECT
       current_database()            AS database,
       current_user                  AS role,
       current_setting('server_version') AS server_version,
       (SELECT count(*) FROM pg_extension WHERE extname = 'postgis') AS postgis,
       1                             AS probe`,
  );

  const row = rows[0];
  return {
    connected: row.probe === 1,
    database: row.database,
    role: row.role,
    serverVersion: row.server_version,
    postgisInstalled: Number(row.postgis) > 0,
    latencyMs: Date.now() - started,
  };
}

/**
 * Lists user schemas, tables and columns.
 *
 * Read-only introspection driven by the catalogue, so it stays correct as the
 * schema evolves. Internal schemas are excluded — they are not application
 * data and would only add noise.
 */
async function introspectSchema() {
  const tables = await query(
    `SELECT
       c.table_schema  AS schema,
       c.table_name    AS table,
       c.column_name   AS column,
       c.data_type     AS data_type,
       c.is_nullable   AS is_nullable
     FROM information_schema.columns c
     JOIN information_schema.tables t
       ON t.table_schema = c.table_schema
      AND t.table_name   = c.table_name
     WHERE t.table_type = 'BASE TABLE'
       AND c.table_schema NOT IN ('pg_catalog', 'information_schema', 'topology')
     ORDER BY c.table_schema, c.table_name, c.ordinal_position`,
  );

  const byTable = new Map();
  for (const r of tables.rows) {
    const key = `${r.schema}.${r.table}`;
    if (!byTable.has(key)) {
      byTable.set(key, { schema: r.schema, table: r.table, columns: [] });
    }
    byTable.get(key).columns.push({
      name: r.column,
      dataType: r.data_type,
      nullable: r.is_nullable === "YES",
    });
  }

  return [...byTable.values()];
}

/**
 * Closes the pool. Called on shutdown so in-flight connections are drained
 * rather than severed.
 */
async function closePool() {
  if (!pool) return;
  const current = pool;
  pool = null;
  await current.end();
}

module.exports = {
  DatabaseError,
  query,
  healthCheck,
  introspectSchema,
  closePool,
  getPool,
};
