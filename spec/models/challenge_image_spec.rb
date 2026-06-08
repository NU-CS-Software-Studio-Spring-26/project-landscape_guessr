require "rails_helper"

RSpec.describe ChallengeImage, type: :model do
  describe "associations" do
    it "belongs to a challenge" do
      ci = build(:challenge_image)
      expect(ci.challenge).to be_present
    end

    it "belongs to an image" do
      ci = build(:challenge_image)
      expect(ci.image).to be_present
    end
  end

  describe "after_destroy callback" do
    it "calls purge_if_orphan! on the associated image" do
      ci = create(:challenge_image)
      image = ci.image
      expect(image).to receive(:purge_if_orphan!)
      ci.destroy
    end

    it "does not destroy an image that still belongs to a set" do
      image = create(:image)
      ci = create(:challenge_image, image: image)
      image_set = create(:image_set)
      create(:image_set_item, image: image, image_set: image_set)
      original_id = image.id
      ci.destroy
      expect(Image.exists?(original_id)).to be true
    end
  end
end
