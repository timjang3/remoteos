DELETE FROM "pairings";
--> statement-breakpoint
ALTER TABLE "pairings"
ADD COLUMN IF NOT EXISTS "control_plane_base_url" text NOT NULL;
--> statement-breakpoint
ALTER TABLE "pairings"
ALTER COLUMN "control_plane_base_url" SET NOT NULL;
