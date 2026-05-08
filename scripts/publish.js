#!/usr/bin/env node

/**
 * Question Publisher CLI for World Quiz
 *
 * Reads built JSON question packages from data/questions/<theme>/
 * and publishes them to a live SpacetimeDB instance using the
 * official JavaScript SDK.
 *
 * Usage:
 *   node scripts/publish.js [--theme <theme>] [--server <url>] [--db-name <name>]
 *
 * Environment:
 *   SPACETIMEDB_TOKEN  - Optional override for the auth token
 */

// Polyfill Promise.withResolvers for Node.js 20
if (!Promise.withResolvers) {
  Promise.withResolvers = function () {
    let resolve, reject;
    const promise = new Promise((res, rej) => {
      resolve = res;
      reject = rej;
    });
    return { promise, resolve, reject };
  };
}

require('undici');
const fs = require('fs');
const path = require('path');
const spacetime = require('spacetimedb');

// ============================================================================
// CLI Argument Parsing
// ============================================================================

function parseArgs() {
  const args = process.argv.slice(2);
  const options = {
    theme: null,
    server: 'ws://127.0.0.1:3000',
    dbName: 'world-quiz',
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--theme':
        options.theme = args[++i];
        break;
      case '--server':
        options.server = args[++i];
        break;
      case '--db-name':
        options.dbName = args[++i];
        break;
      default:
        console.error(`Unknown argument: ${args[i]}`);
        process.exit(1);
    }
  }

  return options;
}

// ============================================================================
// Token Resolution
// ============================================================================

function resolveToken() {
  if (process.env.SPACETIMEDB_TOKEN) {
    return process.env.SPACETIMEDB_TOKEN;
  }

  const cliTomlPath = path.join(
    process.env.HOME || process.env.USERPROFILE || '.',
    '.config',
    'spacetime',
    'cli.toml'
  );

  if (!fs.existsSync(cliTomlPath)) {
    throw new Error(
      `No SpacetimeDB token found. Please run: spacetime login --server-issued-login local`
    );
  }

  const toml = fs.readFileSync(cliTomlPath, 'utf8');
  const match = toml.match(/spacetimedb_token\s*=\s*"([^"]+)"/);
  if (!match) {
    throw new Error(
      `No token found in ${cliTomlPath}. Please run: spacetime login --server-issued-login local`
    );
  }

  return match[1];
}

// ============================================================================
// SpacetimeDB Remote Module Schema (manual binding for admin reducers)
// ============================================================================

const abortSyncReducer = {};

const addQuestionBatchReducer = {
  questions: spacetime.t.array(
    spacetime.t.object({
      category: spacetime.t.string(),
      difficulty: spacetime.t.string(),
      question_text: spacetime.t.string(),
      correct_answer: spacetime.t.string(),
      choices: spacetime.t.array(spacetime.t.string()),
      image_asset: spacetime.t.option(spacetime.t.string()),
      theme: spacetime.t.string(),
      translation_key: spacetime.t.string(),
      language: spacetime.t.string(),
      disabled: spacetime.t.bool(),
    })
  ),
};

const finalizeSyncReducer = {
  active_translation_keys: spacetime.t.array(spacetime.t.string()),
};

const syncStateRow = spacetime.t.row({
  id: spacetime.t.u8().primaryKey(),
  sync_in_progress: spacetime.t.bool(),
  publisher_identity: spacetime.t.identity(),
  started_at: spacetime.t.timestamp(),
});

const tablesSchema = spacetime.schema({
  sync_state: spacetime.table(
    {
      name: 'sync_state',
      indexes: [
        {
          accessor: 'id',
          name: 'sync_state_id_idx',
          algorithm: 'btree',
          columns: ['id'],
        },
      ],
      constraints: [
        { name: 'sync_state_id_key', constraint: 'unique', columns: ['id'] },
      ],
    },
    syncStateRow
  ),
});

const reducersSchema = spacetime.reducers(
  spacetime.reducerSchema('abort_sync', abortSyncReducer),
  spacetime.reducerSchema('add_question_batch', addQuestionBatchReducer),
  spacetime.reducerSchema('finalize_sync', finalizeSyncReducer)
);

const proceduresSchema = spacetime.procedures();

const REMOTE_MODULE = {
  versionInfo: { cliVersion: '2.1.0' },
  tables: tablesSchema.schemaType.tables,
  reducers: reducersSchema.reducersType.reducers,
  procedures: proceduresSchema.procedures,
};

class DbConnection extends spacetime.DbConnectionImpl {
  static builder() {
    return new spacetime.DbConnectionBuilder(
      REMOTE_MODULE,
      (config) => new DbConnection(config)
    );
  }

  subscriptionBuilder() {
    return new spacetime.SubscriptionBuilderImpl(this);
  }
}

// ============================================================================
// Retry Utility
// ============================================================================

async function withRetry(operation, label, maxRetries = 3) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await operation();
    } catch (err) {
      const isLast = attempt === maxRetries;
      console.error(
        `${label} failed (attempt ${attempt}/${maxRetries}): ${
          err?.message || err
        }`
      );
      if (isLast) throw err;
      const delay = Math.min(1000 * Math.pow(2, attempt - 1), 8000);
      console.log(`Retrying ${label} in ${delay}ms...`);
      await new Promise((res) => setTimeout(res, delay));
    }
  }
}

// ============================================================================
// Question File Loading
// ============================================================================

function loadQuestions(theme, baseDir) {
  const themeDir = path.join(baseDir, theme);
  if (!fs.existsSync(themeDir)) {
    throw new Error(`Theme directory not found: ${themeDir}`);
  }

  const files = fs.readdirSync(themeDir);
  const jsonFiles = files.filter((f) => f.endsWith('.json'));

  const allQuestions = [];
  for (const file of jsonFiles) {
    const filePath = path.join(themeDir, file);
    const raw = fs.readFileSync(filePath, 'utf8');
    const questions = JSON.parse(raw);
    if (!Array.isArray(questions)) {
      throw new Error(`Expected array in ${filePath}`);
    }
    // Ensure disabled field is present (build tool omits it, server defaults to false)
    for (const q of questions) {
      if (q.disabled === undefined) {
        q.disabled = false;
      }
    }
    allQuestions.push(...questions);
    console.log(`  Loaded ${questions.length} questions from ${theme}/${file}`);
  }

  return allQuestions;
}

function getThemes(baseDir) {
  if (!fs.existsSync(baseDir)) {
    throw new Error(`Questions base directory not found: ${baseDir}`);
  }
  return fs
    .readdirSync(baseDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
}

// ============================================================================
// Sync Lock Handling
// ============================================================================

function isSyncLockStale(syncState) {
  if (!syncState.sync_in_progress) {
    return false;
  }
  const nowMicros = BigInt(Date.now()) * 1000n;
  const startedMicros = syncState.started_at.microsSinceUnixEpoch;
  const elapsedSecs = Number(nowMicros - startedMicros) / 1_000_000;
  return elapsedSecs >= 300; // 5 minutes
}

// ============================================================================
// Main Publisher Logic
// ============================================================================

async function main() {
  const options = parseArgs();
  const token = resolveToken();
  const questionsBaseDir = path.join(__dirname, '..', 'data', 'questions');

  const themes = options.theme
    ? [options.theme]
    : getThemes(questionsBaseDir);

  console.log(`Themes to publish: ${themes.join(', ')}`);
  console.log(`Target: ${options.server} / ${options.dbName}`);

  // Load all questions
  const questionsByTheme = {};
  let totalQuestions = 0;
  for (const theme of themes) {
    const questions = loadQuestions(theme, questionsBaseDir);
    questionsByTheme[theme] = questions;
    totalQuestions += questions.length;
  }

  console.log(`Total questions to publish: ${totalQuestions}`);

  // Connect to SpacetimeDB
  const conn = DbConnection.builder()
    .withUri(options.server)
    .withDatabaseName(options.dbName)
    .withToken(token)
    .onConnectError((_ctx, err) => {
      console.error('Connection error:', err?.message || err);
    })
    .onDisconnect(() => {
      console.log('Disconnected from SpacetimeDB');
    })
    .build();

  // Wait for connection and subscription
  await new Promise((resolve, reject) => {
    let resolved = false;

    conn.onConnect((c, identity, _token) => {
      console.log(`Connected as ${identity.toHexString()}`);

      c.subscriptionBuilder()
        .onApplied(() => {
          if (!resolved) {
            resolved = true;
            resolve();
          }
        })
        .onError((err) => {
          if (!resolved) {
            resolved = true;
            reject(err);
          }
        })
        .subscribe('SELECT * FROM sync_state');
    });

    conn.onConnectError((_, err) => {
      if (!resolved) {
        resolved = true;
        reject(err);
      }
    });

    setTimeout(() => {
      if (!resolved) {
        resolved = true;
        reject(new Error('Connection timeout'));
      }
    }, 10000);
  });

  // Check for stale sync lock
  let syncState = null;
  for (const row of conn.db.sync_state.iter()) {
    syncState = row;
  }

  if (syncState && isSyncLockStale(syncState)) {
    console.log('Detected stale sync lock (>5 min). Calling abort_sync...');
    await withRetry(
      () => conn.reducers.abortSync(),
      'abort_sync'
    );
    console.log('Sync lock cleared.');
  }

  // Collect all translation keys for finalize_sync
  const allTranslationKeys = new Set();

  // Publish questions in batches
  const BATCH_SIZE = 50;
  let publishedCount = 0;

  for (const theme of themes) {
    const questions = questionsByTheme[theme];
    console.log(`\nPublishing ${questions.length} questions for theme "${theme}"...`);

    for (let i = 0; i < questions.length; i += BATCH_SIZE) {
      const batch = questions.slice(i, i + BATCH_SIZE);
      const batchNum = Math.floor(i / BATCH_SIZE) + 1;
      const totalBatches = Math.ceil(questions.length / BATCH_SIZE);

      // Collect translation keys
      for (const q of batch) {
        allTranslationKeys.add(q.translation_key);
      }

      await withRetry(
        () => conn.reducers.addQuestionBatch({ questions: batch }),
        `add_question_batch ${batchNum}/${totalBatches} (${theme})`
      );

      publishedCount += batch.length;
      console.log(
        `  Sent batch ${batchNum}/${totalBatches} (${batch.length} questions) - total published: ${publishedCount}/${totalQuestions}`
      );
    }
  }

  // Call finalize_sync
  const translationKeysArray = Array.from(allTranslationKeys);
  console.log(
    `\nCalling finalize_sync with ${translationKeysArray.length} unique translation keys...`
  );

  await withRetry(
    () => conn.reducers.finalizeSync({ active_translation_keys: translationKeysArray }),
    'finalize_sync'
  );

  console.log('finalize_sync completed successfully.');
  console.log(`\nPublish complete: ${publishedCount} questions published across ${themes.length} theme(s).`);

  conn.disconnect();

  // Give disconnect a moment to propagate before exiting
  await new Promise((res) => setTimeout(res, 500));
  process.exit(0);
}

main().catch((err) => {
  console.error('Fatal error:', err?.message || err);
  process.exit(1);
});
