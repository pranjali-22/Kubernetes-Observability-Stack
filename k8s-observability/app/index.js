const express = require('express');
const client = require('prom-client');
const winston = require('winston');

const app = express();
app.use(express.json());

// ─── Logger ───────────────────────────────────────────────────────────────────
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [new winston.transports.Console()],
});

// ─── Prometheus Metrics ────────────────────────────────────────────────────────
const register = new client.Registry();

// Collect default Node.js metrics (memory, CPU, GC, event loop lag, etc.)
client.collectDefaultMetrics({ register, prefix: 'nodejs_app_' });

// RED Method metrics
const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const httpRequestDurationSeconds = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

const httpRequestErrorsTotal = new client.Counter({
  name: 'http_request_errors_total',
  help: 'Total number of HTTP request errors (4xx + 5xx)',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const httpRequestsInFlight = new client.Gauge({
  name: 'http_requests_in_flight',
  help: 'Number of HTTP requests currently being processed',
  registers: [register],
});

// Business metrics
const ordersCreatedTotal = new client.Counter({
  name: 'orders_created_total',
  help: 'Total number of orders created',
  labelNames: ['status'],
  registers: [register],
});

const activeUsersGauge = new client.Gauge({
  name: 'active_users',
  help: 'Number of currently active users',
  registers: [register],
});

const dbQueryDurationSeconds = new client.Histogram({
  name: 'db_query_duration_seconds',
  help: 'Duration of database queries in seconds',
  labelNames: ['operation', 'table'],
  buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1],
  registers: [register],
});

// ─── Middleware ────────────────────────────────────────────────────────────────
app.use((req, res, next) => {
  // Skip metrics endpoint from tracking
  if (req.path === '/metrics') return next();

  const start = Date.now();
  httpRequestsInFlight.inc();

  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    const route = req.route?.path || req.path;
    const labels = {
      method: req.method,
      route,
      status_code: res.statusCode,
    };

    httpRequestsTotal.inc(labels);
    httpRequestDurationSeconds.observe(labels, duration);
    httpRequestsInFlight.dec();

    if (res.statusCode >= 400) {
      httpRequestErrorsTotal.inc(labels);
    }

    logger.info('request', {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      duration_ms: Math.round(duration * 1000),
    });
  });

  next();
});

// ─── Routes ────────────────────────────────────────────────────────────────────
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

app.get('/ready', (req, res) => {
  res.json({ status: 'ready' });
});

// Simulate a fast endpoint
app.get('/api/products', async (req, res) => {
  const end = dbQueryDurationSeconds.startTimer({ operation: 'SELECT', table: 'products' });
  await sleep(randomBetween(5, 50));
  end();

  res.json({
    products: Array.from({ length: 10 }, (_, i) => ({ id: i + 1, name: `Product ${i + 1}`, price: Math.random() * 100 })),
  });
});

// Simulate an endpoint with variable latency
app.get('/api/users/:id', async (req, res) => {
  const end = dbQueryDurationSeconds.startTimer({ operation: 'SELECT', table: 'users' });
  await sleep(randomBetween(10, 200));
  end();

  // Simulate 5% 404 rate
  if (Math.random() < 0.05) {
    return res.status(404).json({ error: 'User not found' });
  }

  activeUsersGauge.set(Math.floor(Math.random() * 500));

  res.json({ id: req.params.id, name: 'John Doe', email: 'john@example.com' });
});

// Simulate an endpoint with occasional errors
app.post('/api/orders', async (req, res) => {
  const end = dbQueryDurationSeconds.startTimer({ operation: 'INSERT', table: 'orders' });
  await sleep(randomBetween(50, 300));
  end();

  // Simulate 8% error rate to trigger alerts
  if (Math.random() < 0.08) {
    ordersCreatedTotal.inc({ status: 'failed' });
    return res.status(500).json({ error: 'Internal server error - order processing failed' });
  }

  ordersCreatedTotal.inc({ status: 'success' });
  res.status(201).json({ orderId: Math.random().toString(36).substr(2, 9), status: 'created' });
});

// Simulate a slow endpoint
app.get('/api/reports', async (req, res) => {
  await sleep(randomBetween(500, 2000));
  res.json({ report: 'generated', rows: Math.floor(Math.random() * 10000) });
});

// Simulate CPU-intensive endpoint
app.get('/api/compute', (req, res) => {
  const start = Date.now();
  let result = 0;
  for (let i = 0; i < 1e7; i++) result += Math.sqrt(i);
  res.json({ result: result.toFixed(2), duration_ms: Date.now() - start });
});

// Metrics endpoint for Prometheus scraping
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Error handler
app.use((err, req, res, next) => {
  logger.error('unhandled_error', { error: err.message, stack: err.stack });
  res.status(500).json({ error: 'Internal server error' });
});

// ─── Helpers ──────────────────────────────────────────────────────────────────
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function randomBetween(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

// ─── Start ────────────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  logger.info(`Server running on port ${PORT}`);
  // Simulate some background active users
  setInterval(() => {
    activeUsersGauge.set(Math.floor(Math.random() * 500 + 100));
  }, 5000);
});

module.exports = app;
