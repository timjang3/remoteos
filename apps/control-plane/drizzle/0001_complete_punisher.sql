CREATE TABLE "device_enrollments" (
	"id" text PRIMARY KEY NOT NULL,
	"device_id" text NOT NULL,
	"token" text NOT NULL,
	"status" text NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"approved_at" timestamp with time zone,
	"approved_by_user_id" text
);
--> statement-breakpoint
ALTER TABLE "device_enrollments" ADD CONSTRAINT "device_enrollments_device_id_devices_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "device_enrollments" ADD CONSTRAINT "device_enrollments_approved_by_user_id_user_id_fk" FOREIGN KEY ("approved_by_user_id") REFERENCES "public"."user"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "device_enrollments_token_idx" ON "device_enrollments" USING btree ("token");--> statement-breakpoint
CREATE INDEX "device_enrollments_device_id_idx" ON "device_enrollments" USING btree ("device_id");--> statement-breakpoint
CREATE INDEX "device_enrollments_approved_by_user_id_idx" ON "device_enrollments" USING btree ("approved_by_user_id");