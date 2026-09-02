require 'test_helper'

class DatasetsFeatureTest < ActionView::TestCase
  include ApplicationHelper

  test 'datasets flag is registered but disabled by default' do
    assert_not Flipper.enabled?(:datasets)
  end

  test 'blank provider configuration hides the navigation feature' do
    original_url = ENV['DATASETS_API_URL']
    ENV.delete('DATASETS_API_URL')
    Flipper.stub(:enabled?, true) { assert_not datasets_enabled? }
  ensure
    ENV['DATASETS_API_URL'] = original_url
  end
end
