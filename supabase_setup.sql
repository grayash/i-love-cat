-- =====================================================================
-- 고양이 성분표 분석기 · 게시판용 Supabase 설정
-- Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 Run 하세요. (여러 번 실행해도 안전)
-- 저장하는 정보: 제품명·브랜드·종류, 성분 점수, 독성 성분 여부, 별점, 익명 기기 ID
-- 저장하지 않는 정보: 사진, 성분표 전문 텍스트, 이름·이메일 등 개인정보
-- =====================================================================

-- 1) 테이블 ------------------------------------------------------------
create table if not exists public.products (
  id         uuid primary key default gen_random_uuid(),
  name_key   text not null unique,
  name       text not null check (char_length(name) between 2 and 60),
  brand      text check (brand is null or char_length(brand) <= 30),
  type       text not null check (type in ('dry','wet','treat')),
  hidden     boolean not null default false,      -- 부적절한 이름은 true 로 바꾸면 게시판에서 숨겨져요
  created_by text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.analysis_log (
  product_id uuid not null references public.products(id) on delete cascade,
  device_id  text not null check (char_length(device_id) between 8 and 64),
  day        date not null default current_date,
  score      int  not null check (score between 0 and 100),
  has_danger boolean not null default false,
  primary key (product_id, device_id, day)         -- 같은 기기는 하루 1회만 집계
);

create table if not exists public.ratings (
  product_id uuid not null references public.products(id) on delete cascade,
  device_id  text not null check (char_length(device_id) between 8 and 64),
  stars      int  not null check (stars between 1 and 5),
  updated_at timestamptz not null default now(),
  primary key (product_id, device_id)              -- 같은 기기는 제품당 1표(다시 누르면 수정)
);

-- 2) 직접 접근 차단 (행 단위 보안) ---------------------------------------
alter table public.products     enable row level security;
alter table public.analysis_log enable row level security;
alter table public.ratings      enable row level security;
revoke all on public.products, public.analysis_log, public.ratings from anon, authenticated;

-- 3) 게시판용 집계 뷰 (읽기 전용) ----------------------------------------
create or replace view public.board_products as
select p.id, p.name, p.brand, p.type,
       coalesce(a.analyzer_count, 0) as analyzer_count,
       a.avg_score,
       coalesce(a.danger_count, 0)   as danger_count,
       coalesce(r.rating_count, 0)   as rating_count,
       r.avg_stars
from public.products p
left join (
  select product_id,
         count(distinct device_id)           as analyzer_count,
         round(avg(score))::int              as avg_score,
         count(*) filter (where has_danger)  as danger_count
  from public.analysis_log group by product_id
) a on a.product_id = p.id
left join (
  select product_id,
         count(*)                            as rating_count,
         round(avg(stars)::numeric, 2)       as avg_stars
  from public.ratings group by product_id
) r on r.product_id = p.id
where not p.hidden;

grant select on public.board_products to anon, authenticated;

-- 4) 쓰기 함수 ---------------------------------------------------------
-- 분석 결과 등록 (제품이 없으면 만들고, 오늘 분석 기록을 남김)
create or replace function public.record_analysis(
  p_name text, p_brand text, p_type text, p_device text, p_score int, p_danger boolean
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_name  text := btrim(coalesce(p_name, ''));
  v_brand text := nullif(btrim(coalesce(p_brand, '')), '');
  v_key   text;
  v_id    uuid;
begin
  if p_type not in ('dry','wet','treat') then raise exception 'invalid type'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'invalid name'; end if;
  if v_brand is not null and char_length(v_brand) > 30 then raise exception 'invalid brand'; end if;
  if p_device is null or char_length(p_device) < 8 or char_length(p_device) > 64 then raise exception 'invalid device'; end if;
  if p_score is null or p_score < 0 or p_score > 100 then raise exception 'invalid score'; end if;

  v_key := p_type || ':' ||
           regexp_replace(lower(coalesce(v_brand, '')), '[\s\-_.·,()\[\]/]+', '', 'g') || ':' ||
           regexp_replace(lower(v_name),               '[\s\-_.·,()\[\]/]+', '', 'g');

  select id into v_id from public.products where name_key = v_key;
  if v_id is null then
    -- 한 기기가 하루에 새 제품을 너무 많이 만드는 것을 막음
    if (select count(*) from public.products
         where created_by = p_device and created_at > now() - interval '1 day') >= 10 then
      raise exception 'too many new products today';
    end if;
    insert into public.products (name_key, name, brand, type, created_by)
    values (v_key, v_name, v_brand, p_type, p_device)
    on conflict (name_key) do nothing
    returning id into v_id;
    if v_id is null then select id into v_id from public.products where name_key = v_key; end if;
  end if;

  insert into public.analysis_log (product_id, device_id, score, has_danger)
  values (v_id, p_device, p_score, coalesce(p_danger, false))
  on conflict (product_id, device_id, day)
  do update set score = excluded.score, has_danger = excluded.has_danger;

  return v_id;
end $$;

-- 기호성 별점 (해당 제품을 직접 분석한 기기만 가능)
create or replace function public.rate_product(p_product uuid, p_device text, p_stars int)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_stars is null or p_stars < 1 or p_stars > 5 then raise exception 'invalid stars'; end if;
  if p_device is null or char_length(p_device) < 8 or char_length(p_device) > 64 then raise exception 'invalid device'; end if;
  if not exists (select 1 from public.analysis_log where product_id = p_product and device_id = p_device) then
    raise exception 'analyze this product first';
  end if;
  insert into public.ratings (product_id, device_id, stars)
  values (p_product, p_device, p_stars)
  on conflict (product_id, device_id)
  do update set stars = excluded.stars, updated_at = now();
end $$;

revoke all on function public.record_analysis(text,text,text,text,int,boolean) from public;
revoke all on function public.rate_product(uuid,text,int) from public;
grant execute on function public.record_analysis(text,text,text,text,int,boolean) to anon, authenticated;
grant execute on function public.rate_product(uuid,text,int) to anon, authenticated;

-- ============================================================
-- 의견 받기 게시판 (익명). 쓰기는 함수로만, 읽기는 공개 뷰로만 가능해요.
-- 숨기고 싶은 글은 Table Editor 에서 feedback.hidden 을 true 로 바꾸면 돼요.
-- ============================================================
create table if not exists public.feedback (
  id         uuid primary key default gen_random_uuid(),
  category   text not null check (category in ('praise','idea','bug')),
  body       text not null check (char_length(body) between 2 and 300),
  device_id  text not null,
  hidden     boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;

create or replace view public.feedback_public as
  select id, category, body, created_at
  from public.feedback
  where not hidden
  order by created_at desc
  limit 100;
grant select on public.feedback_public to anon, authenticated;

create or replace function public.submit_feedback(p_device text, p_category text, p_body text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_body text := btrim(coalesce(p_body, ''));
begin
  if p_device is null or char_length(p_device) < 8 or char_length(p_device) > 64 then raise exception 'invalid device'; end if;
  if p_category not in ('praise','idea','bug') then raise exception 'invalid category'; end if;
  if char_length(v_body) < 2 or char_length(v_body) > 300 then raise exception 'invalid body'; end if;
  if (select count(*) from public.feedback
       where device_id = p_device and created_at > now() - interval '1 day') >= 5 then
    raise exception 'too many feedback today';
  end if;
  insert into public.feedback (category, body, device_id) values (p_category, v_body, p_device);
end $$;
revoke all on function public.submit_feedback(text,text,text) from public;
grant execute on function public.submit_feedback(text,text,text) to anon, authenticated;
