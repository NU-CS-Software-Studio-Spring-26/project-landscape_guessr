class DropVestigialAiColumns < ActiveRecord::Migration[8.1]
  # ai_fetch_strategy: introduced as part of an exhaustive/random_sample
  # toggle that we dropped in b38053d (sampling is always SHA512-random
  # now). Column was never wired to a reader.
  # ai_image_source: introduced as part of a P18/pageimages toggle that
  # we collapsed in bd0ec48 (pageimages always — P18 stays as fallback
  # inside WikipediaImageFetcher). No reader either.
  def change
    remove_column :image_sets, :ai_fetch_strategy, :string, default: "exhaustive"
    remove_column :image_sets, :ai_image_source, :string
  end
end
