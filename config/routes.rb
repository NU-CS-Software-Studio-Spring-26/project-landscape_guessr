Rails.application.routes.draw do
  root "home#start"
  get "/about", to: "home#about"
  get "/legal", to: "home#legal"

  resource :session, only: %i[ new create destroy ]
  resources :passwords, param: :token, only: %i[ new create edit update ]
  resource :registration, only: %i[ new create ]
  resource :email_verification, only: %i[ show create ]
  resource :profile, only: %i[ show destroy ] do
    get   :setup_username
    patch :setup_username, action: :update_username
  end

  get "/auth/:provider/callback", to: "sessions/omni_auths#create", as: :omniauth_callback
  get "/auth/failure",            to: "sessions/omni_auths#failure"

  resources :challenges, param: :token, only: [ :index, :new, :create, :show, :destroy ] do
    member { post :play }
  end

  resources :guesses
  resources :games do
    member { get :results }
    collection { get :leaderboard }
  end
  resources :images do
    collection { get :map }
  end
  resources :image_sets do
    member do
      get  :locations
      put  :locations, action: :update_locations
      post :add_image
      post :attach_blob
      get  :processing_status
      get  :map
      get  :new_filtered
      get  :edit_filter
      patch :update_filter
      get :preview_filter_count
      post :preview_filter_count, action: :preview_filter_count
    end
    delete "items/:item_id", to: "image_sets#remove_item", as: :remove_item
  end
  resources :regions, only: [] do
    collection do
      get :search
      get :boundaries
      post :resolve
    end
  end
  get  "practice",       to: "practice#show"
  get  "practice/check", to: "practice#check", as: :practice_check
  get  "practice/hint", to: "practice#hint", as: :practice_hint
  get  "practice/saved", to: "practice#saved", as: :practice_saved
  post "practice/save",  to: "practice#save", as: :practice_save
  delete "practice/save/:image_id", to: "practice#unsave", as: :practice_unsave
  get  "scoring",        to: "home#scoring", as: :scoring
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
