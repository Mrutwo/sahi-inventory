// Database tests for the סח"י schema, run against an embedded Postgres (PGlite)
// with a small Supabase emulation layer (auth.uid(), anon/authenticated roles,
// Supabase's permissive default grants). Run: npm test
import { test, describe, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

const here = new URL('.', import.meta.url);
const migrationsDir = new URL('../migrations/', here);

const USERS = {
  admin: { id: randomUUID(), email: 'coordinator@example.org', name: 'רכזת' },
  a: { id: randomUUID(), email: 'volunteer.a@example.org', name: 'מתנדב א' },
  b: { id: randomUUID(), email: 'volunteer.b@example.org', name: 'מתנדבת ב' },
  pending: { id: randomUUID(), email: 'new@example.org', name: 'חדש' },
  leaver: { id: randomUUID(), email: 'leaver@example.org', name: 'עוזב' },
};
const JOIN_CODE = 'SAHI-2026';

async function createDb() {
  const db = await PGlite.create();
  await db.exec(await readFile(new URL('support/supabase-stub.sql', here), 'utf8'));
  const files = (await readdir(migrationsDir)).filter((f) => f.endsWith('.sql')).sort();
  for (const f of files) {
    await db.exec(await readFile(new URL(f, migrationsDir), 'utf8'));
  }
  for (const u of Object.values(USERS)) {
    await db.query(
      `insert into auth.users (id, email, raw_user_meta_data) values ($1, $2, $3)`,
      [u.id, u.email, { display_name: u.name }],
    );
  }
  await db.query(`select private.bootstrap_admin($1, $2)`, [USERS.admin.email, JOIN_CODE]);
  return db;
}

// Runs a query as an API user (authenticated with the given user, or anon).
async function as(db, user, sql, params = []) {
  await db.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user ? user.id : '']);
  await db.exec(`set role ${user ? 'authenticated' : 'anon'}`);
  try {
    return await db.query(sql, params);
  } finally {
    await db.exec('reset role');
    await db.query(`select set_config('request.jwt.claim.sub', '', false)`);
  }
}

const rpc = async (db, user, fn, args) => {
  const keys = Object.keys(args);
  const sql = `select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`;
  const res = await as(db, user, sql, keys.map((k) => args[k]));
  return res.rows[0].r;
};

const addStock = (db, user, args) => rpc(db, user, 'add_stock', args);
const adjust = (db, user, args) => rpc(db, user, 'adjust_stock', args);

async function item(db, name, unit) {
  const res = await db.query(
    `select * from public.inventory_items where name_key = public.normalize_product_name($1) and unit_code = $2`,
    [name, unit],
  );
  return res.rows[0];
}

const num = (v) => Number(v);

async function rejectsWith(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.match(String(err.message), new RegExp(code));
    return true;
  });
}

let db;
before(async () => {
  db = await createDb();
  for (const u of [USERS.a, USERS.b, USERS.leaver]) {
    const r = await rpc(db, u, 'join_with_code', { p_code: JOIN_CODE });
    assert.equal(r.status, 'joined');
  }
});

describe('schema & reference data', () => {
  test('seeds units and categories', async () => {
    const units = await db.query(`select code, dimension from public.units order by sort_order`);
    assert.deepEqual(units.rows.map((r) => r.code), ['unit', 'box', 'bottle', 'package', 'kg', 'g', 'liter']);
    const cats = await db.query(`select name_he from public.categories order by sort_order`);
    assert.equal(cats.rows.length, 8);
    assert.equal(cats.rows.at(-1).name_he, 'אחר');
  });

  test('normalizes product names consistently', async () => {
    const cases = [
      ['  אורז   בסמטי ', 'אורז בסמטי'],
      ['אוֹרֶז', 'אורז'],
      ['אֹרֶז', 'ארז'],
      ['ק״ג', 'ק"ג'],
      ['Pasta  BARILLA', 'pasta barilla'],
      ['טונה\tבשמן', 'טונה בשמן'],
    ];
    for (const [input, expected] of cases) {
      const r = await db.query(`select public.normalize_product_name($1) as k`, [input]);
      assert.equal(r.rows[0].k, expected, input);
    }
  });

  test('realtime publication includes the shared tables', async () => {
    const r = await db.query(
      `select tablename from pg_publication_tables where pubname = 'supabase_realtime' order by 1`,
    );
    assert.deepEqual(r.rows.map((x) => x.tablename),
      ['categories', 'inventory', 'products', 'profiles', 'stock_movements']);
  });
});

describe('access control', () => {
  test('anonymous users cannot read or call anything', async () => {
    await rejectsWith(as(db, null, `select * from public.inventory_items`), 'permission denied');
    await rejectsWith(as(db, null, `select * from public.products`), 'permission denied');
    await rejectsWith(
      as(db, null, `select public.add_stock('אורז', 'unit', 1)`),
      'permission denied',
    );
  });

  test('pending users see only their own profile and cannot change stock', async () => {
    const inv = await as(db, USERS.pending, `select * from public.inventory_items`);
    assert.equal(inv.rows.length, 0);
    const profiles = await as(db, USERS.pending, `select id, role from public.profiles`);
    assert.equal(profiles.rows.length, 1);
    assert.equal(profiles.rows[0].role, 'pending');
    await rejectsWith(addStock(db, USERS.pending, { p_name: 'אורז', p_unit_code: 'unit', p_quantity: 1 }), 'SAHI_NOT_MEMBER');
  });

  test('wrong join codes are rejected and rate limited', async () => {
    const u = { id: randomUUID(), email: 'bruteforce@example.org', name: 'x' };
    await db.query(`insert into auth.users (id, email) values ($1, $2)`, [u.id, u.email]);
    for (let i = 0; i < 5; i++) {
      const r = await rpc(db, u, 'join_with_code', { p_code: `WRONG-${i}` });
      assert.equal(r.status, 'invalid_code');
    }
    const blocked = await rpc(db, u, 'join_with_code', { p_code: JOIN_CODE });
    assert.equal(blocked.status, 'too_many_attempts');
  });

  test('join code is case-insensitive and trimmed', async () => {
    const u = { id: randomUUID(), email: 'casing@example.org', name: 'y' };
    await db.query(`insert into auth.users (id, email) values ($1, $2)`, [u.id, u.email]);
    const r = await rpc(db, u, 'join_with_code', { p_code: '  sahi-2026 ' });
    assert.equal(r.status, 'joined');
  });

  test('profile is created from sign-up metadata', async () => {
    const r = await db.query(`select display_name, role from public.profiles where id = $1`, [USERS.pending.id]);
    assert.deepEqual(r.rows[0], { display_name: 'חדש', role: 'pending' });
  });

  test('members cannot write tables directly', async () => {
    await rejectsWith(
      as(db, USERS.a, `insert into public.products (name, unit_code) values ('x', 'unit')`),
      'permission denied',
    );
    await rejectsWith(as(db, USERS.a, `update public.inventory set quantity = 999`), 'permission denied');
    await rejectsWith(as(db, USERS.a, `delete from public.stock_movements`), 'permission denied');
    await rejectsWith(as(db, USERS.a, `update public.profiles set role = 'admin'`), 'permission denied');
  });

  test('private settings (join code hash) are not readable', async () => {
    await rejectsWith(as(db, USERS.admin, `select * from private.app_settings`), 'permission denied');
  });

  test('internal helpers are not callable by API users', async () => {
    await rejectsWith(
      as(db, USERS.admin, `select private.bootstrap_admin('a@b.c', '123456')`),
      'permission denied',
    );
  });

  test('only admins can list and manage members', async () => {
    await rejectsWith(as(db, USERS.a, `select * from public.admin_list_members()`), 'SAHI_NOT_ADMIN');
    const r = await as(db, USERS.admin, `select * from public.admin_list_members()`);
    assert.ok(r.rows.some((m) => m.email === USERS.a.email));
    await rejectsWith(
      rpc(db, USERS.a, 'admin_update_member', { p_user_id: USERS.b.id, p_role: 'admin', p_is_active: true }),
      'SAHI_NOT_ADMIN',
    );
  });

  test('the last admin cannot be demoted or deactivated', async () => {
    await rejectsWith(
      rpc(db, USERS.admin, 'admin_update_member', { p_user_id: USERS.admin.id, p_role: 'volunteer', p_is_active: true }),
      'SAHI_LAST_ADMIN',
    );
  });

  test('deactivating a volunteer revokes access immediately', async () => {
    await addStock(db, USERS.leaver, { p_name: 'קמח', p_unit_code: 'kg', p_quantity: 2 });
    await rpc(db, USERS.admin, 'admin_update_member', { p_user_id: USERS.leaver.id, p_role: 'volunteer', p_is_active: false });
    const inv = await as(db, USERS.leaver, `select * from public.inventory_items`);
    assert.equal(inv.rows.length, 0);
    await rejectsWith(addStock(db, USERS.leaver, { p_name: 'קמח', p_unit_code: 'kg', p_quantity: 1 }), 'SAHI_ACCOUNT_DISABLED');
    const rejoin = await rpc(db, USERS.leaver, 'join_with_code', { p_code: JOIN_CODE });
    assert.equal(rejoin.status, 'account_disabled');
    // History written by the volunteer stays readable for everyone else.
    const hist = await as(db, USERS.a, `select actor_name from public.activity_feed where product_name = 'קמח'`);
    assert.equal(hist.rows[0].actor_name, USERS.leaver.name);
  });
});

describe('adding products & aggregation', () => {
  test('adding a new product creates it with its first movement', async () => {
    const r = await addStock(db, USERS.a, { p_name: 'אורז', p_unit_code: 'unit', p_quantity: 10, p_notes: 'תרומה מהסופר' });
    assert.equal(r.kind, 'create');
    assert.equal(num(r.previous_quantity), 0);
    assert.equal(num(r.new_quantity), 10);
    const it = await item(db, 'אורז', 'unit');
    assert.equal(num(it.quantity), 10);
    assert.equal(it.updated_by_name, USERS.a.name);
    const cat = await db.query(`select slug from public.categories where id = $1`, [it.category_id]);
    assert.equal(cat.rows[0].slug, 'other', 'missing category falls back to "אחר"');
  });

  test('a second volunteer adding the same product increases the same row', async () => {
    const r = await addStock(db, USERS.b, { p_name: '  אוֹרֶז ', p_unit_code: 'unit', p_quantity: 5 });
    assert.equal(r.kind, 'increase');
    assert.equal(num(r.new_quantity), 15);
    const rows = await db.query(`select count(*)::int as n from public.products where name_key = 'אורז'`);
    assert.equal(rows.rows[0].n, 1);
  });

  test('incompatible units are never combined', async () => {
    await addStock(db, USERS.a, { p_name: 'אורז', p_unit_code: 'kg', p_quantity: 3 });
    assert.equal(num((await item(db, 'אורז', 'unit')).quantity), 15);
    assert.equal(num((await item(db, 'אורז', 'kg')).quantity), 3);
  });

  test('retrying the same request does not add stock twice', async () => {
    const requestId = randomUUID();
    const args = { p_name: 'טונה', p_unit_code: 'box', p_quantity: 32, p_request_id: requestId };
    const first = await addStock(db, USERS.a, args);
    const second = await addStock(db, USERS.a, args);
    assert.equal(first.replayed, false);
    assert.equal(second.replayed, true);
    assert.equal(second.movement_id, first.movement_id);
    assert.equal(num((await item(db, 'טונה', 'box')).quantity), 32);
  });

  test('invalid input is rejected', async () => {
    await rejectsWith(addStock(db, USERS.a, { p_name: '   ', p_unit_code: 'unit', p_quantity: 1 }), 'SAHI_INVALID_NAME');
    await rejectsWith(addStock(db, USERS.a, { p_name: 'שמן', p_unit_code: 'bottle', p_quantity: 0 }), 'SAHI_INVALID_QUANTITY');
    await rejectsWith(addStock(db, USERS.a, { p_name: 'שמן', p_unit_code: 'bottle', p_quantity: -4 }), 'SAHI_INVALID_QUANTITY');
    await rejectsWith(addStock(db, USERS.a, { p_name: 'שמן', p_unit_code: 'bottle', p_quantity: 1.5 }), 'SAHI_WHOLE_NUMBER_REQUIRED');
    await rejectsWith(addStock(db, USERS.a, { p_name: 'שמן', p_unit_code: 'barrels', p_quantity: 1 }), 'SAHI_INVALID_UNIT');
    await rejectsWith(addStock(db, USERS.a, { p_name: 'שמן', p_unit_code: 'bottle', p_quantity: 2000000 }), 'SAHI_QUANTITY_TOO_LARGE');
    await rejectsWith(
      addStock(db, USERS.a, { p_name: 'שמן', p_unit_code: 'bottle', p_quantity: 1, p_category_id: randomUUID() }),
      'SAHI_INVALID_CATEGORY',
    );
    await rejectsWith(addStock(db, USERS.a, { p_name: 'א'.repeat(121), p_unit_code: 'unit', p_quantity: 1 }), 'SAHI_INVALID_NAME');
    const r = await addStock(db, USERS.a, { p_name: 'סוכר', p_unit_code: 'kg', p_quantity: 2.5 });
    assert.equal(num(r.new_quantity), 2.5, 'fractions are fine for weight');
  });
});

describe('stock adjustments', () => {
  test('increase and decrease record full movements', async () => {
    await addStock(db, USERS.a, { p_name: 'פסטה', p_unit_code: 'package', p_quantity: 40 });
    const p = await item(db, 'פסטה', 'package');
    const dec = await adjust(db, USERS.b, { p_product_id: p.id, p_delta: -12, p_reason: 'distribution' });
    assert.equal(dec.kind, 'decrease');
    assert.equal(num(dec.previous_quantity), 40);
    assert.equal(num(dec.new_quantity), 28);
    const inc = await adjust(db, USERS.a, { p_product_id: p.id, p_delta: 2 });
    assert.equal(num(inc.new_quantity), 30);
    const hist = await as(db, USERS.a,
      `select kind, quantity_delta, previous_quantity, new_quantity, reason, created_by, actor_name
         from public.activity_feed where product_id = $1 order by id`, [p.id]);
    assert.deepEqual(hist.rows.map((h) => [h.kind, num(h.quantity_delta)]), [['create', 40], ['decrease', -12], ['increase', 2]]);
    assert.equal(hist.rows[1].reason, 'distribution');
    assert.equal(hist.rows[1].created_by, USERS.b.id);
    assert.equal(hist.rows[1].actor_name, USERS.b.name);
  });

  test('stock can never go negative', async () => {
    const p = await item(db, 'פסטה', 'package');
    await rejectsWith(adjust(db, USERS.a, { p_product_id: p.id, p_delta: -31 }), 'SAHI_INSUFFICIENT_STOCK');
    assert.equal(num((await item(db, 'פסטה', 'package')).quantity), 30);
  });

  test('a product reaching zero stays in the inventory with its history', async () => {
    await addStock(db, USERS.a, { p_name: 'חלב', p_unit_code: 'liter', p_quantity: 12 });
    const p = await item(db, 'חלב', 'liter');
    await adjust(db, USERS.a, { p_product_id: p.id, p_delta: -12 });
    const after = await item(db, 'חלב', 'liter');
    assert.equal(after.is_active, true);
    assert.equal(num(after.quantity), 0);
  });

  test('concurrent deltas from two volunteers are both applied', async () => {
    const p = await item(db, 'טונה', 'box');
    const before = num(p.quantity);
    // PGlite serializes statements on one connection; real concurrency is
    // covered by the row lock (FOR UPDATE) + relative update in adjust_stock
    // and by the live sync check (live/sync-check.mjs).
    await Promise.all([
      adjust(db, USERS.a, { p_product_id: p.id, p_delta: 5 }),
      adjust(db, USERS.b, { p_product_id: p.id, p_delta: -3 }),
    ]);
    assert.equal(num((await item(db, 'טונה', 'box')).quantity), before + 2);
  });

  test('setting an exact count requires the latest version (no lost updates)', async () => {
    await addStock(db, USERS.a, { p_name: 'שמן', p_unit_code: 'bottle', p_quantity: 12 });
    const seenByA = await item(db, 'שמן', 'bottle');
    const seenByB = await item(db, 'שמן', 'bottle');
    const r = await rpc(db, USERS.a, 'set_stock', {
      p_product_id: seenByA.id, p_new_quantity: 18, p_expected_version: seenByA.stock_version,
    });
    assert.equal(num(r.previous_quantity), 12);
    assert.equal(num(r.new_quantity), 18);
    await rejectsWith(
      rpc(db, USERS.b, 'set_stock', { p_product_id: seenByB.id, p_new_quantity: 5, p_expected_version: seenByB.stock_version }),
      'SAHI_VERSION_CONFLICT',
    );
    assert.equal(num((await item(db, 'שמן', 'bottle')).quantity), 18);
  });
});

describe('editing products', () => {
  test('rename, recategorize and notes are recorded as an edit', async () => {
    const p = await item(db, 'פסטה', 'package');
    const cat = (await db.query(`select id from public.categories where slug = 'grains'`)).rows[0].id;
    const r = await rpc(db, USERS.a, 'update_product', {
      p_product_id: p.id, p_expected_version: p.product_version, p_name: 'פסטה ספגטי',
      p_category_id: cat, p_unit_code: 'package', p_notes: 'מדף עליון',
    });
    assert.equal(r.changed, true);
    const after = await item(db, 'פסטה ספגטי', 'package');
    assert.equal(after.product_version, p.product_version + 1);
    const edit = await db.query(`select details from public.stock_movements where product_id = $1 and kind = 'edit'`, [p.id]);
    assert.deepEqual(edit.rows[0].details.name, { from: 'פסטה', to: 'פסטה ספגטי' });
    assert.equal(edit.rows[0].details.category.to, 'קטניות ודגנים');
  });

  test('stale edits are rejected', async () => {
    const p = await item(db, 'פסטה ספגטי', 'package');
    await rejectsWith(rpc(db, USERS.b, 'update_product', {
      p_product_id: p.id, p_expected_version: p.product_version - 1, p_name: 'x',
      p_category_id: p.category_id, p_unit_code: 'package',
    }), 'SAHI_VERSION_CONFLICT');
  });

  test('renaming into an existing product is rejected', async () => {
    const p = await item(db, 'פסטה ספגטי', 'package');
    await addStock(db, USERS.a, { p_name: 'קוסקוס', p_unit_code: 'package', p_quantity: 3 });
    await rejectsWith(rpc(db, USERS.a, 'update_product', {
      p_product_id: p.id, p_expected_version: p.product_version, p_name: 'קוסקוס',
      p_category_id: p.category_id, p_unit_code: 'package',
    }), 'SAHI_DUPLICATE_PRODUCT');
  });

  test('unit changes are only allowed when safe', async () => {
    const tuna = await item(db, 'טונה', 'box');
    await rejectsWith(rpc(db, USERS.a, 'update_product', {
      p_product_id: tuna.id, p_expected_version: tuna.product_version, p_name: 'טונה',
      p_category_id: tuna.category_id, p_unit_code: 'kg',
    }), 'SAHI_UNSAFE_UNIT_CHANGE');
    await rejectsWith(rpc(db, USERS.a, 'update_product', {
      p_product_id: tuna.id, p_expected_version: tuna.product_version, p_name: 'טונה',
      p_category_id: tuna.category_id, p_unit_code: 'package',
    }), 'SAHI_UNSAFE_UNIT_CHANGE');

    // kg -> g converts the quantity exactly.
    const sugar = await item(db, 'סוכר', 'kg');
    await rpc(db, USERS.a, 'update_product', {
      p_product_id: sugar.id, p_expected_version: sugar.product_version, p_name: 'סוכר',
      p_category_id: sugar.category_id, p_unit_code: 'g',
    });
    const grams = await item(db, 'סוכר', 'g');
    assert.equal(num(grams.quantity), 2500);
    const mv = await db.query(`select kind, previous_quantity, new_quantity, details from public.stock_movements
                               where product_id = $1 and kind = 'unit_change'`, [sugar.id]);
    assert.equal(num(mv.rows[0].previous_quantity), 2.5);
    assert.equal(num(mv.rows[0].new_quantity), 2500);
    assert.deepEqual(mv.rows[0].details.unit, { from: 'kg', to: 'g' });

    // Empty stock: any unit change is fine.
    const milk = await item(db, 'חלב', 'liter');
    await rpc(db, USERS.a, 'update_product', {
      p_product_id: milk.id, p_expected_version: milk.product_version, p_name: 'חלב',
      p_category_id: milk.category_id, p_unit_code: 'bottle',
    });
    assert.ok(await item(db, 'חלב', 'bottle'));
  });
});

describe('removing products & history', () => {
  test('only admins can remove a product; history is preserved', async () => {
    const p = await item(db, 'קוסקוס', 'package');
    await rejectsWith(rpc(db, USERS.a, 'archive_product', { p_product_id: p.id }), 'SAHI_NOT_ADMIN');
    const r = await rpc(db, USERS.admin, 'archive_product', { p_product_id: p.id, p_reason: 'פג תוקף' });
    assert.equal(r.kind, 'archive');
    assert.equal(num(r.previous_quantity), 3);
    const after = await item(db, 'קוסקוס', 'package');
    assert.equal(after.is_active, false);
    assert.equal(num(after.quantity), 0);
    const hist = await db.query(`select kind from public.stock_movements where product_id = $1 order by id`, [p.id]);
    assert.deepEqual(hist.rows.map((h) => h.kind), ['create', 'archive']);
    await rejectsWith(adjust(db, USERS.a, { p_product_id: p.id, p_delta: 1 }), 'SAHI_PRODUCT_ARCHIVED');
  });

  test('adding an archived product again restores it instead of duplicating', async () => {
    const r = await addStock(db, USERS.b, { p_name: 'קוסקוס', p_unit_code: 'package', p_quantity: 4 });
    assert.equal(r.kind, 'increase');
    const after = await item(db, 'קוסקוס', 'package');
    assert.equal(after.is_active, true);
    assert.equal(num(after.quantity), 4);
    const hist = await db.query(`select kind from public.stock_movements where product_id = $1 order by id`, [after.id]);
    assert.deepEqual(hist.rows.map((h) => h.kind), ['create', 'archive', 'restore', 'increase']);
  });

  test('stock history cannot be altered, even by the database owner', async () => {
    await rejectsWith(db.query(`update public.stock_movements set quantity_delta = 0`), 'SAHI_HISTORY_IMMUTABLE');
    await rejectsWith(db.query(`delete from public.stock_movements`), 'SAHI_HISTORY_IMMUTABLE');
    await rejectsWith(db.query(`truncate public.stock_movements cascade`), 'SAHI_HISTORY_IMMUTABLE');
  });

  test('products with history cannot be hard-deleted', async () => {
    await assert.rejects(db.query(`delete from public.products where name_key = 'אורז'`));
  });
});

describe('profiles', () => {
  test('volunteers can change their own display name only', async () => {
    await rpc(db, USERS.a, 'update_my_profile', { p_display_name: '  יוסי   כהן ' });
    const row = await db.query(`select display_name from public.profiles where id = $1`, [USERS.a.id]);
    assert.equal(row.rows[0].display_name, 'יוסי כהן');
    await rejectsWith(rpc(db, USERS.a, 'update_my_profile', { p_display_name: '   ' }), 'SAHI_INVALID_DISPLAY_NAME');
  });

  test('admins can set a new join code', async () => {
    await rejectsWith(rpc(db, USERS.admin, 'admin_set_join_code', { p_code: '123' }), 'SAHI_INVALID_JOIN_CODE');
    await rpc(db, USERS.admin, 'admin_set_join_code', { p_code: 'NEW-CODE-77' });
    const u = { id: randomUUID(), email: 'late@example.org' };
    await db.query(`insert into auth.users (id, email) values ($1, $2)`, [u.id, u.email]);
    assert.equal((await rpc(db, u, 'join_with_code', { p_code: JOIN_CODE })).status, 'invalid_code');
    assert.equal((await rpc(db, u, 'join_with_code', { p_code: 'new-code-77' })).status, 'joined');
  });
});
