CREATE TABLE "mobile_auth_exchanges" (
	"code_hash" text PRIMARY KEY NOT NULL,
	"auth_token_ciphertext" text NOT NULL,
	"user_id" text NOT NULL,
	"user_name" text NOT NULL,
	"user_email" text NOT NULL,
	"user_image" text,
	"created_at" timestamp with time zone NOT NULL,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "mobile_auth_flows" (
	"flow_id_hash" text PRIMARY KEY NOT NULL,
	"provider" text NOT NULL,
	"redirect_uri" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE INDEX "mobile_auth_exchanges_expires_at_idx" ON "mobile_auth_exchanges" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "mobile_auth_flows_expires_at_idx" ON "mobile_auth_flows" USING btree ("expires_at");