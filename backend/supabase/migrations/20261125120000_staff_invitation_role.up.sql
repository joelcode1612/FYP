ALTER TABLE public.staff_invitations
  ADD COLUMN IF NOT EXISTS invited_role text,
  ADD COLUMN IF NOT EXISTS provisioning_claimed_at timestamptz;

UPDATE public.staff_invitations
SET invited_role = 'agent'
WHERE invited_role IS NULL;

ALTER TABLE public.staff_invitations
  ALTER COLUMN invited_role SET DEFAULT 'agent',
  ALTER COLUMN invited_role SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'staff_invitations_invited_role_check'
      AND conrelid = 'public.staff_invitations'::regclass
  ) THEN
    ALTER TABLE public.staff_invitations
      ADD CONSTRAINT staff_invitations_invited_role_check
      CHECK (invited_role IN ('agent', 'owner'));
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS staff_invitations_email_role_idx
  ON public.staff_invitations (invited_email, invited_role);
