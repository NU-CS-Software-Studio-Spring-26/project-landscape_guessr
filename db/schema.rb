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

ActiveRecord::Schema[8.1].define(version: 2026_04_17_192424) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "games", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "score"
    t.string "status"
    t.datetime "updated_at", null: false
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

  create_table "images", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "latitude"
    t.decimal "longitude"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url"
  end

  add_foreign_key "guesses", "games"
  add_foreign_key "guesses", "images"
end
