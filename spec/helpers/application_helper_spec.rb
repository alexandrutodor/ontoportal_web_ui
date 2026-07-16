require 'rails_helper'
require 'flipper/adapters/memory'

RSpec.describe ApplicationHelper, type: :helper do
  describe '#biomixer_replacement_enabled?' do
    let(:memory_flipper) { Flipper.new(Flipper::Adapters::Memory.new) }

    before do
      allow(Flipper).to receive(:enabled?) do |feature_name, actor = nil|
        memory_flipper.enabled?(feature_name, actor)
      end
    end

    it 'returns false by default and true when the biomixer_replacement feature is enabled' do
      expect(helper.biomixer_replacement_enabled?).to be(false)

      memory_flipper.enable('biomixer_replacement')

      expect(helper.biomixer_replacement_enabled?).to be(true)
    end

    it 'returns false again when the biomixer_replacement feature is disabled' do
      memory_flipper.enable('biomixer_replacement')
      memory_flipper.disable('biomixer_replacement')

      expect(helper.biomixer_replacement_enabled?).to be(false)
    end

    it 'passes the supplied user actor to Flipper' do
      user = Struct.new(:flipper_id).new('User;42')
      memory_flipper.enable_actor('biomixer_replacement', user)

      expect(helper.biomixer_replacement_enabled?(user)).to be(true)
      expect(helper.biomixer_replacement_enabled?).to be(false)
    end
  end
end
