require "test_helper"

class ImageSetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob   = users(:bob)
    sign_in_as @alice
  end

  test "index shows my sets and public sets" do
    get image_sets_path
    assert_response :success
  end

  test "create makes a new set for current user" do
    assert_difference("ImageSet.count", 1) do
      post image_sets_path, params: { image_set: { name: "New Set", visibility: "private" } }
    end
    set = ImageSet.last
    assert_equal @alice, set.user
    # New sets land on the manage-images page so the user can immediately
    # upload — see ImageSetsController#create.
    assert_redirected_to locations_image_set_path(set)
  end

  test "show is accessible for public set by any logged-in user" do
    get image_set_path(image_sets(:alice_public))
    assert_response :success
  end

  test "show redirects for private set owned by other user" do
    sign_in_as @bob
    get image_set_path(image_sets(:alice_private))
    assert_redirected_to image_sets_path
  end

  test "edit is forbidden for non-owner of private set" do
    sign_in_as @bob
    # set_image_set denies access to private sets not owned by the user
    get edit_image_set_path(image_sets(:alice_private))
    assert_redirected_to image_sets_path
  end

  test "edit is forbidden for non-owner of public set" do
    sign_in_as @bob
    get edit_image_set_path(image_sets(:alice_public))
    assert_redirected_to image_set_path(image_sets(:alice_public))
  end

  test "locations edit screen is accessible to owner" do
    get locations_image_set_path(image_sets(:alice_private))
    assert_response :success
  end

  test "update_locations saves new coords for owner" do
    item = image_set_items(:alice_private_one)
    put locations_image_set_path(image_sets(:alice_private)),
        params: { image_set_items: { item.id.to_s => { latitude: "10.5", longitude: "20.5" } } }
    assert_redirected_to locations_image_set_path(image_sets(:alice_private))
    assert_equal 10.5, item.reload.latitude.to_f
  end

  test "update_locations preserves page and per_page on save" do
    # Regression: the form's hidden :page / :per_page fields feed back
    # into the redirect so the user lands on the same slice they were
    # editing. Without the hidden fields the redirect dropped them and
    # bounced the user to page 1 / default size.
    item = image_set_items(:alice_private_one)
    put locations_image_set_path(image_sets(:alice_private)),
        params: {
          page: "2", per_page: "25",
          image_set_items: { item.id.to_s => { latitude: "10.5", longitude: "20.5" } }
        }
    assert_redirected_to locations_image_set_path(image_sets(:alice_private), page: "2", per_page: "25")
  end

  test "destroy deletes the set" do
    set = @alice.image_sets.create!(name: "Temp", visibility: "private")
    assert_difference("ImageSet.count", -1) do
      delete image_set_path(set)
    end
    assert_redirected_to image_sets_path
  end

  test "remove_item destroys the item and redirects with a flash" do
    # Regression: the remove_item route nests under :image_set_id, not :id,
    # so set_image_set used to read params[:id] and raise RecordNotFound.
    item = image_set_items(:alice_private_one)
    assert_difference("ImageSetItem.count", -1) do
      delete image_set_remove_item_path(image_sets(:alice_private), item),
             headers: { "Referer" => locations_image_set_path(image_sets(:alice_private)) }
    end
    assert_redirected_to locations_image_set_path(image_sets(:alice_private))
    assert_match(/removed/i, flash[:notice])
  end

  test "update_locations saves a new title (delegating to Image)" do
    # alice_only image is NOT in the default set, so the editable_by?
    # guard lets the title propagate. (The previous version of this
    # test used alice_private_one — image_one — which is in the
    # default set and is now correctly locked from non-admin edits.)
    item = image_set_items(:alice_private_alice_only)
    original = item.image.title
    put locations_image_set_path(image_sets(:alice_private)),
        params: { image_set_items: { item.id.to_s => { title: "Renamed", latitude: item.latitude.to_s, longitude: item.longitude.to_s } } }
    assert_redirected_to locations_image_set_path(image_sets(:alice_private))
    assert_equal "Renamed", item.image.reload.title
  ensure
    item&.image&.update(title: original) if original
  end

  test "update_locations rejects title change on default-set image" do
    # Vandalism guard: image_one is in the default set AND in alice's
    # private set. Without the editable_by? check on the bulk-edit
    # path, alice could rename it here and propagate the change to
    # every default-set game. Coords still update (those are per-set
    # overrides on ImageSetItem, not on the canonical Image).
    item = image_set_items(:alice_private_one)
    original_title = item.image.title
    put locations_image_set_path(image_sets(:alice_private)),
        params: { image_set_items: { item.id.to_s => { title: "Vandalized", latitude: "1.5", longitude: "2.5" } } }
    assert_response :unprocessable_entity
    assert_match(/locked.*default set/i, flash.now[:alert].to_s)
    assert_equal original_title, item.image.reload.title
  end

  test "add_image creates item with validated https URL and coordinates" do
    set = image_sets(:alice_private)
    url = "https://example.com/unique-#{SecureRandom.hex(4)}.jpg"

    assert_difference("ImageSetItem.count", 1) do
      post add_image_image_set_path(set),
           params: {
             url: url, title: "New spot",
             latitude: "46.2", longitude: "7.1"
           },
           headers: { "Referer" => locations_image_set_path(set) }
    end

    item = set.image_set_items.joins(:image).find_by!(images: { url: url })
    assert_in_delta 46.2, item.latitude.to_f
    assert_in_delta 7.1, item.longitude.to_f
    assert_equal "New spot", item.image.title
  end

  test "add_image rejects http URL and missing coordinates" do
    set = image_sets(:alice_private)

    assert_no_difference("ImageSetItem.count") do
      post add_image_image_set_path(set),
           params: { url: "http://example.com/bad.jpg", title: "X" },
           headers: { "Referer" => locations_image_set_path(set) }
    end
    assert_match(/https/i, flash[:alert])

    assert_no_difference("ImageSetItem.count") do
      post add_image_image_set_path(set),
           params: {
             url: "https://example.com/ok.jpg", title: "X",
             latitude: "", longitude: "7.0"
           },
           headers: { "Referer" => locations_image_set_path(set) }
    end
    assert_match(/required/i, flash[:alert])
  end

  # === AI flow ===

  test "ai_new requires authentication" do
    delete session_path # log out
    get ai_new_image_sets_path
    assert_redirected_to new_session_path
  end

  test "ai_new renders the prompt form for logged-in user" do
    get ai_new_image_sets_path
    assert_response :success
    assert_match(/AI Image Set/i, response.body)
    assert_match(/user_message/, response.body)
  end

  test "ai_generate rejects empty prompt" do
    post ai_generate_image_sets_path, params: { user_message: "" }
    assert_redirected_to ai_new_image_sets_path
    assert_match(/Type a prompt first/i, flash[:alert])
  end

  test "ai_generate enforces daily rate limit" do
    # Burn the daily quota directly in the AiUsage table — the rate
    # limit is now AR-backed (not cache-backed), so this is enough.
    AiUsage.create!(user: @alice, day: Date.current, count: 20)
    post ai_generate_image_sets_path, params: { user_message: "volcanoes" }
    assert_response :too_many_requests
    assert_match(/Daily AI limit reached/, response.body)
  end

  test "ai_generate creates an AiGeneration, enqueues the job, and redirects" do
    assert_difference("AiGeneration.count", 1) do
      assert_enqueued_with(job: AiGenerationJob) do
        post ai_generate_image_sets_path, params: { user_message: "volcanoes in Japan" }
      end
    end
    gen = AiGeneration.last
    assert_equal @alice, gen.user
    assert_equal "pending", gen.status
    assert_equal "volcanoes in Japan", gen.user_message
    assert_redirected_to ai_new_image_sets_path(generation_id: gen.id)
  end

  test "ai_generate bumps the daily counter before enqueueing" do
    assert_difference("AiUsage.where(user: @alice, day: Date.current).sum(:count)", 1) do
      post ai_generate_image_sets_path, params: { user_message: "volcanoes" }
    end
  end

  test "ai_new with ?generation_id renders the progress banner for in-progress" do
    gen = AiGeneration.create!(user: @alice, status: "running", phase: "thinking",
                                user_message: "volcanoes")
    get ai_new_image_sets_path(generation_id: gen.id)
    assert_response :success
    assert_match(/ai-generation-poll/, response.body)
  end

  test "ai_new with ?generation_id for another user falls through to fresh form" do
    gen = AiGeneration.create!(user: @bob, status: "running", user_message: "x")
    get ai_new_image_sets_path(generation_id: gen.id)
    assert_response :success
    # No poll controller — view rendered the empty prompt form instead.
    refute_match(/ai-generation-poll/, response.body)
  end

  test "ai_generation_status returns JSON for owner" do
    gen = AiGeneration.create!(user: @alice, status: "running", phase: "counting",
                                progress_message: "Counting matches…",
                                user_message: "x")
    get ai_generation_status_path(gen.id)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "running",          body["status"]
    assert_equal "counting",         body["phase"]
    assert_equal "Counting matches…", body["progress_message"]
  end

  test "ai_generation_status 404s for another user's record" do
    gen = AiGeneration.create!(user: @bob, status: "running", user_message: "x")
    get ai_generation_status_path(gen.id)
    assert_response :not_found
  end

  test "ai_generation_status reports stuck-running record as failed" do
    gen = AiGeneration.create!(user: @alice, status: "running", user_message: "x")
    gen.update_columns(updated_at: 10.minutes.ago)
    get ai_generation_status_path(gen.id)
    body = JSON.parse(response.body)
    assert_equal "failed", body["status"]
    assert_match(/timed out/i, body["error"])
  end

  test "ai_create rejects missing generation_id" do
    post ai_create_image_sets_path, params: { name: "x" }
    assert_redirected_to ai_new_image_sets_path
    assert_match(/No AI proposal to import/i, flash[:alert])
  end

  test "ai_create rejects an unfinished generation" do
    gen = AiGeneration.create!(user: @alice, status: "running", user_message: "x")
    post ai_create_image_sets_path, params: { generation_id: gen.id, name: "x" }
    assert_redirected_to ai_new_image_sets_path
  end

  test "ai_create makes a set from the AiGeneration record, enqueues import, redirects to show" do
    gen = AiGeneration.create!(
      user: @alice, status: "completed", user_message: "volcanoes in Japan",
      model_used: "flash",
      conversation_json: [ { role: "user", text: "volcanoes in Japan" } ].to_json,
      result_json: {
        sparql_pattern: "?item wdt:P31 wd:Q8072 .",
        set_name:       "Volcanoes of Japan",
        explanation:    "Finding volcanoes.",
        cannot_answer:  false
      }.to_json
    )

    assert_difference("ImageSet.count", 1) do
      assert_enqueued_with(job: AiImportImagesJob) do
        post ai_create_image_sets_path, params: {
          generation_id: gen.id,
          name:          "Volcanoes of Japan",
          visibility:    "private"
        }
      end
    end
    set = ImageSet.last
    assert_equal "Volcanoes of Japan", set.name
    assert_equal "?item wdt:P31 wd:Q8072 .", set.ai_query
    assert_equal "flash", set.ai_model
    assert_equal "pending", set.import_state
    assert_redirected_to set
  end

  test "ai_create defaults to private and rejects invalid visibility" do
    gen = AiGeneration.create!(
      user: @alice, status: "completed", user_message: "x",
      result_json: { sparql_pattern: "?item wdt:P31 wd:Q8072 .",
                     set_name: "X", explanation: "x",
                     cannot_answer: false }.to_json
    )
    post ai_create_image_sets_path, params: {
      generation_id: gen.id, name: "X", visibility: "wide-open"
    }
    assert_equal "private", ImageSet.last.visibility
  end

  test "ai_create ignores cross-user generation_id" do
    gen = AiGeneration.create!(
      user: @bob, status: "completed", user_message: "x",
      result_json: { sparql_pattern: "?item wdt:P31 wd:Q1 .",
                     set_name: "X", explanation: "x",
                     cannot_answer: false }.to_json
    )
    assert_no_difference("ImageSet.count") do
      post ai_create_image_sets_path, params: { generation_id: gen.id, name: "X" }
    end
    assert_redirected_to ai_new_image_sets_path
  end

  test "retry_import re-enqueues the import job and resets progress columns" do
    set = ImageSet.create!(user: @alice, name: "Failed AI Set", visibility: "private",
                            ai_query: "?item wdt:P31 wd:Q8072 .",
                            import_state: "failed",
                            import_error: "WikidataImporter::Error: 502",
                            import_progress: 0, import_total: 0)

    assert_enqueued_with(job: AiImportImagesJob) do
      post retry_import_image_set_path(set)
    end
    set.reload
    assert_equal "pending", set.import_state
    assert_nil set.import_error
    assert_redirected_to set
  end

  test "retry_import refuses completed sets" do
    set = ImageSet.create!(user: @alice, name: "Done AI Set", visibility: "private",
                            ai_query: "?item wdt:P31 wd:Q8072 .",
                            import_state: "completed")
    assert_no_enqueued_jobs do
      post retry_import_image_set_path(set)
    end
    assert_redirected_to set
    assert_match(/already completed/i, flash[:alert])
  end

  test "retry_import allows stuck non-failed sub-states (worker crash recovery)" do
    %w[pending fetching looking_up_images inserting].each do |stuck_state|
      set = ImageSet.create!(user: @alice, name: "Stuck #{stuck_state}", visibility: "private",
                              ai_query: "?item wdt:P31 wd:Q8072 .",
                              import_state: stuck_state, import_progress: 42, import_total: 100)
      assert_enqueued_with(job: AiImportImagesJob) do
        post retry_import_image_set_path(set)
      end
      set.reload
      assert_equal "pending", set.import_state, "expected #{stuck_state} → pending"
      assert_equal 0, set.import_progress
      assert_redirected_to set
    end
  end

  test "retry_import refuses non-AI sets" do
    set = ImageSet.create!(user: @alice, name: "Manual Set", visibility: "private",
                            import_state: "failed")
    assert_no_enqueued_jobs do
      post retry_import_image_set_path(set)
    end
    assert_redirected_to set
    assert_match(/isn't an AI-generated set/i, flash[:alert])
  end

  test "retry_import is owner-only" do
    set = ImageSet.create!(user: @bob, name: "Bob's Failed", visibility: "public",
                            ai_query: "?item wdt:P31 wd:Q8072 .",
                            import_state: "failed")
    assert_no_enqueued_jobs do
      post retry_import_image_set_path(set)
    end
    assert_redirected_to set
    assert_match(/permission/i, flash[:alert])
  end

  test "import_status returns JSON for owner" do
    set = ImageSet.create!(user: @alice, name: "AI Set",
                            visibility: "private", import_state: "importing",
                            import_progress: 10, import_total: 50)
    get import_status_image_set_path(set)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "importing", body["state"]
    assert_equal 10, body["progress"]
    assert_equal 50, body["total"]
  end

  test "import_status is owner-only (no info leak to other users)" do
    sign_in_as @bob
    set = ImageSet.create!(user: @alice, name: "Alice's failing set",
                            visibility: "public", import_state: "failed",
                            import_error: "Net::ReadTimeout: query.wikidata.org timed out at /app/lib/foo.rb")
    get import_status_image_set_path(set)
    # @bob shouldn't see Alice's import_error message — require_owner
    # redirects with an alert.
    assert_redirected_to set
    assert_match(/permission/i, flash[:alert])
  end

  test "import_status returns JSON 403 (not HTML redirect) for non-owner JSON request" do
    # The poll banner fetches with Accept: application/json. Without the
    # respond_to in require_owner, the auth failure returned a 302→200 HTML
    # body and the client's res.json() threw.
    sign_in_as @bob
    set = ImageSet.create!(user: @alice, name: "Alice's set",
                            visibility: "public", import_state: "importing")
    get import_status_image_set_path(set), headers: { "Accept" => "application/json" }
    assert_response :forbidden
    assert_equal "application/json", response.media_type
  end

  # === Cancel an in-flight AI generation ===

  test "ai_generation_cancel flips an in-progress record to canceled and redirects" do
    gen = AiGeneration.create!(user: @alice, status: "running", phase: "counting",
                                user_message: "x")
    post ai_generation_cancel_path(gen.id)
    assert_redirected_to ai_new_image_sets_path
    gen.reload
    assert_equal "canceled", gen.status
    assert_nil gen.phase
  end

  test "ai_generation_cancel is a no-op on already-completed records" do
    gen = AiGeneration.create!(user: @alice, status: "completed", user_message: "x")
    post ai_generation_cancel_path(gen.id)
    gen.reload
    assert_equal "completed", gen.status
  end

  test "ai_generation_cancel 404s (silently redirects) for another user's record" do
    gen = AiGeneration.create!(user: @bob, status: "running", user_message: "x")
    post ai_generation_cancel_path(gen.id)
    assert_redirected_to ai_new_image_sets_path
    # Bob's record was NOT canceled — alice can't cancel it.
    assert_equal "running", gen.reload.status
  end
end
