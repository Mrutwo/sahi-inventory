// Live end-to-end check against a real Supabase project (no iOS device needed).
// Signs in two volunteers as two independent sessions and verifies:
//   1. a change made by B reaches A through Realtime without polling
//   2. concurrent stock adjustments from both sessions are all applied
//   3. idempotent retries do not double count
//
// Usage (both accounts must already be active members):
//   set SUPABASE_URL=https://xxxx.supabase.co
//   set SUPABASE_ANON_KEY=...
//   set SAHI_A_EMAIL=... & set SAHI_A_PASSWORD=...
//   set SAHI_B_EMAIL=... & set SAHI_B_PASSWORD=...
//   npm run sync-check
//
// It uses one product named "בדיקת סנכרון" and returns its stock to the
// starting value at the end.
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const env = (k) => {
  const v = process.env[k];
  if (!v) {
    console.error(`Missing environment variable ${k}`);
    process.exit(2);
  }
  return v;
};

const url = env('SUPABASE_URL');
const key = env('SUPABASE_ANON_KEY');
const PRODUCT = 'בדיקת סנכרון';

async function session(email, password, label) {
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await client.auth.signInWithPassword({ email, password });
  if (error) throw new Error(`${label}: sign-in failed: ${error.message}`);
  return client;
}

async function call(client, fn, args) {
  const { data, error } = await client.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

async function quantity(client, productId) {
  const { data, error } = await client.from('inventory_items').select('quantity').eq('id', productId).single();
  if (error) throw new Error(error.message);
  return Number(data.quantity);
}

const ok = (msg) => console.log(`  ✔ ${msg}`);

const a = await session(env('SAHI_A_EMAIL'), env('SAHI_A_PASSWORD'), 'A');
const b = await session(env('SAHI_B_EMAIL'), env('SAHI_B_PASSWORD'), 'B');
console.log('Signed in two independent sessions.');

// Make sure the test product exists.
const created = await call(a, 'add_stock', { p_name: PRODUCT, p_unit_code: 'unit', p_quantity: 1, p_notes: 'sync-check' });
const productId = created.product_id;
const start = await quantity(a, productId);

// 1. Realtime: A listens, B writes.
const received = new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('A did not receive the change within 15 s')), 15000);
  const channel = a
    .channel('sync-check')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'inventory', filter: `product_id=eq.${productId}` }, (payload) => {
      clearTimeout(timer);
      resolve({ payload, channel });
    })
    .subscribe(async (status) => {
      if (status === 'SUBSCRIBED') {
        await call(b, 'adjust_stock', { p_product_id: productId, p_delta: 5, p_reason: 'sync-check' });
      }
    });
});
const { payload, channel } = await received;
ok(`A received B's change in realtime (new quantity ${payload.new.quantity})`);
await a.removeChannel(channel);

// 2. Concurrent updates: 10 increments from each session at the same time.
await Promise.all([
  ...Array.from({ length: 10 }, () => call(a, 'adjust_stock', { p_product_id: productId, p_delta: 1 })),
  ...Array.from({ length: 10 }, () => call(b, 'adjust_stock', { p_product_id: productId, p_delta: 1 })),
]);
const afterConcurrent = await quantity(b, productId);
if (afterConcurrent !== start + 25) throw new Error(`expected ${start + 25}, got ${afterConcurrent}`);
ok(`20 concurrent adjustments from two sessions all applied (${start} → ${afterConcurrent})`);

// 3. Idempotency: the same request sent twice counts once.
const requestId = randomUUID();
await Promise.allSettled([
  call(a, 'adjust_stock', { p_product_id: productId, p_delta: 1, p_request_id: requestId }),
  call(a, 'adjust_stock', { p_product_id: productId, p_delta: 1, p_request_id: requestId }),
]);
await call(a, 'adjust_stock', { p_product_id: productId, p_delta: 1, p_request_id: requestId });
const afterRetry = await quantity(a, productId);
if (afterRetry !== afterConcurrent + 1) throw new Error(`retry double-counted: ${afterRetry}`);
ok('retried request applied exactly once');

// 4. Stale exact-count update is rejected.
const { data: snap } = await a.from('inventory_items').select('stock_version').eq('id', productId).single();
await call(b, 'adjust_stock', { p_product_id: productId, p_delta: 1 });
const { error: stale } = await a.rpc('set_stock', { p_product_id: productId, p_new_quantity: 0, p_expected_version: snap.stock_version });
if (!stale || !stale.message.includes('SAHI_VERSION_CONFLICT')) throw new Error('stale set_stock was not rejected');
ok('stale exact-count update rejected (no lost update)');

// Clean up: return to the starting quantity minus the 1 we added at the start.
const end = await quantity(a, productId);
await call(a, 'adjust_stock', { p_product_id: productId, p_delta: -(end - start + 1), p_reason: 'sync-check cleanup' });
ok('cleaned up test stock');

await a.auth.signOut();
await b.auth.signOut();
console.log('All live checks passed.');
process.exit(0);
