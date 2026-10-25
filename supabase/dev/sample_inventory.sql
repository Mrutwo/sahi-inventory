-- =============================================================================
-- DEVELOPMENT ONLY — example records for trying the app on a local or test
-- project. These are NOT real inventory. Never run this on the production
-- project used by volunteers.
--
-- Run from the SQL editor (as postgres) after the migration.
-- =============================================================================
do $$
declare
  r record;
  v_product uuid;
begin
  for r in
    select * from (values
      ('אורז',  25::numeric, 'unit',   'grains'),
      ('שמן',   18::numeric, 'bottle', 'oil_spices'),
      ('פסטה',  40::numeric, 'unit',   'grains'),
      ('טונה',  32::numeric, 'box',    'canned'),
      ('חלב',   12::numeric, 'liter',  'dairy'),
      ('סוכר',  15::numeric, 'kg',     'basics')
    ) as t(name, qty, unit, category)
  loop
    insert into public.products (name, unit_code, category_id, notes)
    values (r.name, r.unit, (select id from public.categories where slug = r.category), 'נתוני דוגמה לפיתוח')
    on conflict do nothing
    returning id into v_product;

    if v_product is not null then
      insert into public.inventory (product_id, quantity) values (v_product, r.qty);
      insert into public.stock_movements (product_id, kind, quantity_delta, previous_quantity, new_quantity, unit_code, reason, actor_name)
      values (v_product, 'create', r.qty, 0, r.qty, r.unit, 'נתוני דוגמה לפיתוח', 'נתוני דוגמה');
    end if;
  end loop;
end;
$$;
