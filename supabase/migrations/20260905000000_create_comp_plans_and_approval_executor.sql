-- R5b: compensation plans + atomic approval execution.
-- Idempotent schema capture for objects initially prototyped in Supabase.

-- ============================================================
-- Compensation plans
-- ============================================================
CREATE TABLE IF NOT EXISTS public.crm_comp_plans (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_email TEXT NOT NULL,
  owner_name TEXT NOT NULL DEFAULT '',
  rate_pct NUMERIC NOT NULL CHECK (rate_pct >= 0 AND rate_pct <= 1),
  tier_label TEXT,
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to DATE,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.crm_comp_plan_audit (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  plan_id UUID NOT NULL REFERENCES public.crm_comp_plans(id),
  actor_email TEXT NOT NULL,
  action TEXT NOT NULL CHECK (
    action IN ('create', 'rate_change', 'supersede', 'reactivate')
  ),
  old_rate_pct NUMERIC,
  new_rate_pct NUMERIC,
  old_tier_label TEXT,
  new_tier_label TEXT,
  old_effective_to DATE,
  new_effective_to DATE,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comp_plans_owner
  ON public.crm_comp_plans(owner_email, effective_from);
CREATE UNIQUE INDEX IF NOT EXISTS idx_comp_plans_one_active
  ON public.crm_comp_plans(owner_email)
  WHERE effective_to IS NULL;

CREATE OR REPLACE FUNCTION public.touch_comp_plan()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.log_comp_plan_change()
RETURNS trigger
LANGUAGE plpgsql
-- SECURITY DEFINER: the trigger fires on client-side admin rate changes
-- (SECURITY INVOKER context); the audit table is SELECT-only under RLS, so
-- the trigger itself must own the audit INSERT — clients still cannot
-- write audit rows directly (no INSERT policy on crm_comp_plan_audit).
-- Pinned search_path; no client-controlled input beyond row values.
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.crm_comp_plan_audit (
      plan_id, actor_email, action, new_rate_pct, new_tier_label
    ) VALUES (
      NEW.id, coalesce(auth.jwt() ->> 'email', 'system'), 'create',
      NEW.rate_pct, NEW.tier_label
    );
  ELSIF TG_OP = 'UPDATE' AND (
    NEW.rate_pct <> OLD.rate_pct
    OR NEW.effective_to IS DISTINCT FROM OLD.effective_to
    OR NEW.tier_label IS DISTINCT FROM OLD.tier_label
  ) THEN
    INSERT INTO public.crm_comp_plan_audit (
      plan_id, actor_email, action, old_rate_pct, new_rate_pct,
      old_tier_label, new_tier_label, old_effective_to, new_effective_to
    ) VALUES (
      NEW.id,
      coalesce(auth.jwt() ->> 'email', 'system'),
      CASE
        WHEN NEW.effective_to IS DISTINCT FROM OLD.effective_to THEN 'supersede'
        ELSE 'rate_change'
      END,
      OLD.rate_pct, NEW.rate_pct, OLD.tier_label, NEW.tier_label,
      OLD.effective_to, NEW.effective_to
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_comp_plan_touch ON public.crm_comp_plans;
CREATE TRIGGER trg_comp_plan_touch
  BEFORE UPDATE ON public.crm_comp_plans
  FOR EACH ROW EXECUTE FUNCTION public.touch_comp_plan();

DROP TRIGGER IF EXISTS trg_comp_plan_audit ON public.crm_comp_plans;
CREATE TRIGGER trg_comp_plan_audit
  AFTER INSERT OR UPDATE ON public.crm_comp_plans
  FOR EACH ROW EXECUTE FUNCTION public.log_comp_plan_change();

ALTER TABLE public.crm_comp_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_comp_plan_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS comp_plans_read ON public.crm_comp_plans;
CREATE POLICY comp_plans_read ON public.crm_comp_plans
  FOR SELECT TO authenticated USING (true);

-- Rate changes are financial-control writes: admins only.
DROP POLICY IF EXISTS comp_plans_write ON public.crm_comp_plans;
CREATE POLICY comp_plans_write ON public.crm_comp_plans
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role_id IN (
          SELECT id FROM public.sys_roles
          WHERE name IN ('maf_admin', 'maf_superadmin')
        )
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role_id IN (
          SELECT id FROM public.sys_roles
          WHERE name IN ('maf_admin', 'maf_superadmin')
        )
    )
  );

DROP POLICY IF EXISTS comp_audit_read ON public.crm_comp_plan_audit;
CREATE POLICY comp_audit_read ON public.crm_comp_plan_audit
  FOR SELECT TO authenticated USING (true);

-- Atomic supersession prevents a failed insert or concurrent edit from
-- leaving an owner without an active plan.
CREATE OR REPLACE FUNCTION public.supersede_comp_plan(
  p_plan_id UUID,
  p_new_rate_pct NUMERIC,
  p_new_tier_label TEXT DEFAULT NULL
)
RETURNS public.crm_comp_plans
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_current public.crm_comp_plans%ROWTYPE;
  v_created public.crm_comp_plans%ROWTYPE;
BEGIN
  IF p_new_rate_pct < 0 OR p_new_rate_pct > 1 THEN
    RAISE EXCEPTION 'Compensation rate must be between 0 and 1';
  END IF;

  -- Authority gate: only MAF admins/superadmins change comp rates.
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
      AND profiles.role_id IN (
        SELECT id FROM public.sys_roles
        WHERE name IN ('maf_admin', 'maf_superadmin')
      )
  ) THEN
    RAISE EXCEPTION 'Only MAF admins can change comp plan rates';
  END IF;

  SELECT * INTO v_current
  FROM public.crm_comp_plans
  WHERE id = p_plan_id AND effective_to IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active compensation plan not found';
  END IF;

  UPDATE public.crm_comp_plans
  SET effective_to = CURRENT_DATE
  WHERE id = v_current.id;

  INSERT INTO public.crm_comp_plans (
    owner_email, owner_name, rate_pct, tier_label,
    effective_from, effective_to, created_by
  ) VALUES (
    v_current.owner_email,
    v_current.owner_name,
    p_new_rate_pct,
    coalesce(p_new_tier_label, v_current.tier_label),
    CURRENT_DATE,
    NULL,
    auth.uid()
  )
  RETURNING * INTO v_created;

  RETURN v_created;
END;
$$;

REVOKE ALL ON FUNCTION public.supersede_comp_plan(UUID, NUMERIC, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.supersede_comp_plan(UUID, NUMERIC, TEXT) TO authenticated;

-- The initial owner plan is a decided business configuration. It is seeded
-- only when no active Garry plan exists, so reapplying is harmless.
INSERT INTO public.crm_comp_plans (
  owner_email, owner_name, rate_pct, tier_label, effective_from
)
SELECT
  'founder@example.com', 'Garry', 0.08, 'Founding Principal',
  DATE '2026-09-05'
WHERE NOT EXISTS (
  SELECT 1 FROM public.crm_comp_plans
  WHERE owner_email = 'founder@example.com' AND effective_to IS NULL
);

-- ============================================================
-- Approval requests RLS rewrite + atomic executor
-- ============================================================
ALTER TABLE public.crm_approval_requests ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  DROP POLICY IF EXISTS crm_approval_requests_authenticated
    ON public.crm_approval_requests;
  DROP POLICY IF EXISTS crm_approval_requests_read
    ON public.crm_approval_requests;
  DROP POLICY IF EXISTS crm_approval_requests_insert
    ON public.crm_approval_requests;
  DROP POLICY IF EXISTS crm_approval_requests_admin_decide
    ON public.crm_approval_requests;
  DROP POLICY IF EXISTS crm_approval_requests_admin_delete
    ON public.crm_approval_requests;
  DROP POLICY IF EXISTS crm_approval_requests_decide
    ON public.crm_approval_requests;
  DROP POLICY IF EXISTS crm_approval_requests_execute
    ON public.crm_approval_requests;
END;
$$;

CREATE POLICY crm_approval_requests_read ON public.crm_approval_requests
  FOR SELECT TO authenticated USING (true);

-- Agent queueing: any authenticated session can enqueue a request for
-- review (the queue is transparent; decisions are gated). Forged rows are
-- structurally blocked: a queued request MUST arrive PENDING with no
-- decision/execution fields — no client can fabricate an APPROVED or
-- EXECUTED row.
CREATE POLICY crm_approval_requests_insert ON public.crm_approval_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    status = 'PENDING'
    AND decided_by IS NULL
    AND decided_at IS NULL
    AND execution_result IS NULL
  );

-- Decide (PENDING -> APPROVED/REJECTED): MAF admins only. The original
-- admin_decide policy is preserved — the earlier any-authenticated
-- rewrite was a regression and is gone.
CREATE POLICY crm_approval_requests_decide ON public.crm_approval_requests
  FOR UPDATE TO authenticated
  USING (
    status = 'PENDING'
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role_id IN (
          SELECT id FROM public.sys_roles
          WHERE name IN ('maf_admin', 'maf_superadmin')
        )
    )
  )
  WITH CHECK (status IN ('APPROVED', 'REJECTED'));

-- Execute transition (APPROVED -> EXECUTED/EXECUTION_SKIPPED): the RPC's
-- internal admin gate is the authority; this RLS leg lets the RPC's
-- status update land, admin-scoped as defense in depth.
CREATE POLICY crm_approval_requests_execute ON public.crm_approval_requests
  FOR UPDATE TO authenticated
  USING (
    status = 'APPROVED'
    AND EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role_id IN (
          SELECT id FROM public.sys_roles
          WHERE name IN ('maf_admin', 'maf_superadmin')
        )
    )
  )
  WITH CHECK (status IN ('EXECUTED', 'EXECUTION_SKIPPED'));

CREATE POLICY crm_approval_requests_admin_delete ON public.crm_approval_requests
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role_id IN (
          SELECT id FROM public.sys_roles
          WHERE name IN ('maf_admin', 'maf_superadmin')
        )
    )
  );

-- ============================================================
-- Atomic approval executor
-- ============================================================
CREATE OR REPLACE FUNCTION public.execute_crm_approval_request(
  p_request_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_request public.crm_approval_requests%ROWTYPE;
  v_params JSONB;
  v_detail TEXT;
  v_target_id UUID;
  v_rows INTEGER;
  v_task_id UUID;
  v_actioned BOOLEAN := false;
  v_status TEXT := 'EXECUTION_SKIPPED';
BEGIN
  -- Authority gate: only MAF admins/superadmins execute agent actions.
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
      AND profiles.role_id IN (
        SELECT id FROM public.sys_roles
        WHERE name IN ('maf_admin', 'maf_superadmin')
      )
  ) THEN
    RAISE EXCEPTION 'Only MAF admins can execute approval requests';
  END IF;

  SELECT * INTO v_request
  FROM public.crm_approval_requests
  WHERE id = p_request_id AND status = 'APPROVED'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Approval request not found or not in APPROVED state';
  END IF;

  v_params := coalesce(v_request.params, '{}'::jsonb);

  CASE v_request.action
    WHEN 'move_stage' THEN
      IF nullif(v_params ->> 'deal_id', '') IS NULL
         OR nullif(v_params ->> 'stage', '') IS NULL THEN
        RAISE EXCEPTION 'move_stage requires deal_id and stage';
      END IF;

      v_target_id := (v_params ->> 'deal_id')::UUID;
      UPDATE public.crm_deals
      SET stage = v_params ->> 'stage'
      WHERE id = v_target_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows <> 1 THEN
        RAISE EXCEPTION 'Deal not found: %', v_target_id;
      END IF;

      v_actioned := true;
      v_status := 'EXECUTED';
      v_detail := format('Stage moved to %s', v_params ->> 'stage');

    WHEN 'create_task' THEN
      IF nullif(v_params ->> 'title', '') IS NULL THEN
        RAISE EXCEPTION 'create_task requires a title';
      END IF;

      INSERT INTO public.crm_tasks (
        title, deal_id, assigned_to, due_date, status
      ) VALUES (
        v_params ->> 'title',
        nullif(v_params ->> 'deal_id', '')::UUID,
        coalesce(nullif(v_params ->> 'assigned_to', ''), 'garry'),
        nullif(v_params ->> 'due_date', '')::DATE,
        'pending'
      )
      RETURNING id INTO v_task_id;

      v_actioned := true;
      v_status := 'EXECUTED';
      v_detail := format('Task created: %s', v_task_id);

    WHEN 'send_email' THEN
      -- External communications remain blocked without G's explicit send-it.
      v_detail := 'Awaiting explicit send-it from G — email drafted, not sent';

    ELSE
      v_detail := format('Unsupported action type: %s', v_request.action);
  END CASE;

  UPDATE public.crm_approval_requests
  SET
    status = v_status,
    execution_result = jsonb_build_object(
      'actioned', v_actioned,
      'detail', v_detail,
      'executed_at', now()
    )
  WHERE id = v_request.id;

  RETURN jsonb_build_object(
    'actioned', v_actioned,
    'detail', v_detail,
    'status', v_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.execute_crm_approval_request(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_crm_approval_request(UUID) TO authenticated;