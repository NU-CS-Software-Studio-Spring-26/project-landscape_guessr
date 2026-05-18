# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_18_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "unaccent"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_generations", force: :cascade do |t|
    t.text "conversation_json"
    t.datetime "created_at", null: false
    t.text "error"
    t.string "model_used"
    t.string "phase"
    t.text "preview_json"
    t.string "progress_message"
    t.bigint "result_count"
    t.text "result_json"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.text "user_message"
    t.index ["user_id", "created_at"], name: "index_ai_generations_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_ai_generations_on_user_id"
  end

  create_table "ai_usages", force: :cascade do |t|
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.date "day", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "day"], name: "index_ai_usages_on_user_id_and_day", unique: true
  end

  create_table "challenge_images", force: :cascade do |t|
    t.decimal "answer_latitude"
    t.decimal "answer_longitude"
    t.bigint "challenge_id", null: false
    t.datetime "created_at", null: false
    t.bigint "image_id", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["challenge_id", "position"], name: "index_challenge_images_on_challenge_id_and_position", unique: true
    t.index ["challenge_id"], name: "index_challenge_images_on_challenge_id"
    t.index ["image_id"], name: "index_challenge_images_on_image_id"
  end

  create_table "challenges", force: :cascade do |t|
    t.bigint "challenger_id", null: false
    t.datetime "created_at", null: false
    t.bigint "image_set_id"
    t.string "token", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["challenger_id"], name: "index_challenges_on_challenger_id"
    t.index ["image_set_id"], name: "index_challenges_on_image_set_id"
    t.index ["token"], name: "index_challenges_on_token", unique: true
  end

  create_table "connected_services", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "provider", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["provider", "uid"], name: "index_connected_services_on_provider_and_uid", unique: true
    t.index ["user_id"], name: "index_connected_services_on_user_id"
  end

  create_table "game_images", force: :cascade do |t|
    t.decimal "answer_latitude"
    t.decimal "answer_longitude"
    t.datetime "created_at", null: false
    t.bigint "game_id", null: false
    t.bigint "image_id", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id", "position"], name: "index_game_images_on_game_id_and_position", unique: true
    t.index ["game_id"], name: "index_game_images_on_game_id"
    t.index ["image_id"], name: "index_game_images_on_image_id"
  end

  create_table "games", force: :cascade do |t|
    t.bigint "challenge_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "image_set_id"
    t.float "score"
    t.string "status"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["challenge_id"], name: "index_games_on_challenge_id"
    t.index ["image_set_id"], name: "index_games_on_image_set_id"
    t.index ["user_id"], name: "index_games_on_user_id"
  end

  create_table "guesses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "game_id", null: false
    t.bigint "image_id", null: false
    t.decimal "latitude"
    t.decimal "longitude"
    t.datetime "updated_at", null: false
    t.index ["game_id"], name: "index_guesses_on_game_id"
    t.index ["image_id"], name: "index_guesses_on_image_id"
  end

  create_table "image_ai_hints", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.bigint "image_id", null: false
    t.string "model"
    t.integer "prompt_version", default: 1, null: false
    t.string "status", default: "pending", null: false
    t.integer "tier", null: false
    t.datetime "updated_at", null: false
    t.index ["image_id", "tier"], name: "index_image_ai_hints_on_image_id_and_tier", unique: true
    t.index ["image_id"], name: "index_image_ai_hints_on_image_id"
  end

  create_table "image_set_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "image_id", null: false
    t.bigint "image_set_id", null: false
    t.decimal "latitude"
    t.decimal "longitude"
    t.datetime "updated_at", null: false
    t.index ["image_id"], name: "index_image_set_items_on_image_id"
    t.index ["image_set_id", "image_id"], name: "index_image_set_items_on_image_set_id_and_image_id", unique: true
    t.index ["image_set_id"], name: "index_image_set_items_on_image_set_id"
  end

  create_table "image_sets", force: :cascade do |t|
    t.text "ai_explanation"
    t.string "ai_model"
    t.text "ai_prompt"
    t.text "ai_query"
    t.jsonb "ai_region_filter"
    t.datetime "created_at", null: false
    t.jsonb "custom_areas", default: [], null: false
    t.text "import_error"
    t.integer "import_progress", default: 0, null: false
    t.string "import_state"
    t.integer "import_total"
    t.jsonb "import_warnings"
    t.boolean "is_system_default", default: false, null: false
    t.string "map_style", default: "outdoor-v2", null: false
    t.string "name", null: false
    t.bigint "parent_image_set_id"
    t.bigint "region_ids", default: [], array: true
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "visibility", default: "private", null: false
    t.index ["is_system_default"], name: "index_image_sets_one_system_default", unique: true, where: "(is_system_default = true)"
    t.index ["parent_image_set_id"], name: "index_image_sets_on_parent_image_set_id"
    t.index ["region_ids"], name: "index_image_sets_on_region_ids", using: :gin
    t.index ["user_id"], name: "index_image_sets_on_user_id"
  end

  create_table "images", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "latitude"
    t.decimal "longitude"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["latitude", "longitude"], name: "index_images_on_coords_not_null", where: "((latitude IS NOT NULL) AND (longitude IS NOT NULL))"
    t.index ["url"], name: "index_images_on_url", unique: true, where: "(url IS NOT NULL)"
  end

  create_table "regions", force: :cascade do |t|
    t.string "admin_level", null: false
    t.jsonb "boundary"
    t.datetime "created_at", null: false
    t.string "iso_code"
    t.float "max_lat"
    t.float "max_lng"
    t.float "min_lat"
    t.float "min_lng"
    t.string "name", null: false
    t.string "normalized_name"
    t.bigint "parent_id"
    t.integer "population"
    t.datetime "updated_at", null: false
    t.index ["admin_level"], name: "index_regions_on_admin_level"
    t.index ["iso_code"], name: "index_regions_on_iso_code"
    t.index ["name", "admin_level"], name: "index_regions_on_name_and_admin_level"
    t.index ["parent_id", "admin_level", "normalized_name"], name: "index_regions_on_parent_level_normname"
    t.index ["parent_id"], name: "index_regions_on_parent_id"
  end

  create_table "saved_practice_images", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "image_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["image_id"], name: "index_saved_practice_images_on_image_id"
    t.index ["user_id", "image_id"], name: "index_saved_practice_images_on_user_id_and_image_id", unique: true
    t.index ["user_id"], name: "index_saved_practice_images_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "email_verified_at"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.index "lower((username)::text)", name: "index_users_on_lower_username", unique: true
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_generations", "users"
  add_foreign_key "ai_usages", "users"
  add_foreign_key "challenge_images", "challenges"
  add_foreign_key "challenge_images", "images"
  add_foreign_key "challenges", "image_sets"
  add_foreign_key "challenges", "users", column: "challenger_id"
  add_foreign_key "connected_services", "users"
  add_foreign_key "game_images", "games"
  add_foreign_key "game_images", "images"
  add_foreign_key "games", "challenges"
  add_foreign_key "games", "image_sets"
  add_foreign_key "games", "users"
  add_foreign_key "guesses", "games"
  add_foreign_key "guesses", "images"
  add_foreign_key "image_ai_hints", "images"
  add_foreign_key "image_set_items", "image_sets"
  add_foreign_key "image_set_items", "images"
  add_foreign_key "image_sets", "image_sets", column: "parent_image_set_id"
  add_foreign_key "image_sets", "users"
  add_foreign_key "regions", "regions", column: "parent_id"
  add_foreign_key "saved_practice_images", "images"
  add_foreign_key "saved_practice_images", "users"
  add_foreign_key "sessions", "users"
end
