"use strict";
require('dotenv').config({ path: require('node:path').join(__dirname, '.env'), quiet: true });
const { createApp } = require('./app-api');
const db = require('./db');
const port = Number(process.env.APP_API_PORT) || 3001;
const server = createApp().listen(port, '127.0.0.1', () => console.log(`Sitewise application API: http://localhost:${port}`));
for (const signal of ['SIGINT','SIGTERM']) process.on(signal, () => server.close(() => db.closePool().finally(() => process.exit())));
