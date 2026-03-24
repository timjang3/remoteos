ALTER TABLE "client_sessions" RENAME COLUMN "token" TO "token_hash";--> statement-breakpoint
ALTER TABLE "device_enrollments" RENAME COLUMN "token" TO "token_hash";--> statement-breakpoint
ALTER TABLE "devices" RENAME COLUMN "device_secret" TO "device_secret_hash";--> statement-breakpoint
ALTER TABLE "pairings" RENAME COLUMN "pairing_code" TO "pairing_code_hash";--> statement-breakpoint
ALTER TABLE "pairings" RENAME COLUMN "client_token" TO "client_token_hash";--> statement-breakpoint
ALTER TABLE "pairings" RENAME COLUMN "pairing_url" TO "pairing_base_url";--> statement-breakpoint
DROP INDEX "client_sessions_token_idx";--> statement-breakpoint
DROP INDEX "device_enrollments_token_idx";--> statement-breakpoint
DROP INDEX "devices_device_secret_idx";--> statement-breakpoint
DROP INDEX "pairings_pairing_code_idx";--> statement-breakpoint
DROP INDEX "pairings_client_token_idx";--> statement-breakpoint
CREATE UNIQUE INDEX "client_sessions_token_hash_idx" ON "client_sessions" USING btree ("token_hash");--> statement-breakpoint
CREATE UNIQUE INDEX "device_enrollments_token_hash_idx" ON "device_enrollments" USING btree ("token_hash");--> statement-breakpoint
CREATE UNIQUE INDEX "devices_device_secret_hash_idx" ON "devices" USING btree ("device_secret_hash");--> statement-breakpoint
CREATE UNIQUE INDEX "pairings_pairing_code_hash_idx" ON "pairings" USING btree ("pairing_code_hash");--> statement-breakpoint
CREATE INDEX "pairings_client_token_hash_idx" ON "pairings" USING btree ("client_token_hash");