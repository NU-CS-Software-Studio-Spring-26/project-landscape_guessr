Rails.application.routes.draw do
  root "home#start"

  resource :session, only: %i[ new create destroy ]
  resources :passwords, param: :token, only: %i[ new create edit update ]
  resource :registration, only: %i[ new create ]
  resource :profile, only: :show

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
      post :bulk_upload
    end
    delete "items/:item_id", to: "image_sets#remove_item", as: :remove_item
  end
  get "practice", to: "practice#show"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
