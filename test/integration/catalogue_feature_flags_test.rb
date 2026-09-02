require 'test_helper'
require 'minitest/mock'

class CatalogueFeatureFlagsTest < ActionDispatch::IntegrationTest
  CATALOGUES = %i[datasets models workflows repositories].freeze

  setup do
    @original_url = ENV['DATASETS_API_URL']
    ENV['DATASETS_API_URL'] = 'https://datasets.example.test/api'
  end

  teardown do
    ENV['DATASETS_API_URL'] = @original_url
  end

  test 'all catalogue index and show routes are hidden when flags are disabled' do
    stub_request(:get, %r{datasets\.example\.test}).to_raise('must not call provider')

    with_enabled_catalogues do
      catalogue_paths.each_value do |paths|
        get paths[:index]
        assert_response :not_found
        get paths[:show]
        assert_response :not_found
      end
    end

    assert_not_requested :get, %r{datasets\.example\.test}
  end

  test 'enabling exactly one catalogue exposes only that index and show route' do
    CATALOGUES.each do |enabled|
      stub_request(:get, %r{datasets\.example\.test/api/datasets\?})
        .to_return(status: 200, body: { datasets: [{ id: 'one', title: 'One' }] }.to_json)
      stub_request(:get, %r{datasets\.example\.test/api/datasets/one})
        .to_return(status: 200, body: { id: 'one', title: 'One' }.to_json)

      with_enabled_catalogues(enabled) do
        get catalogue_paths.fetch(enabled).fetch(:index)
        assert_response :success
        get catalogue_paths.fetch(enabled).fetch(:show)
        assert_response :success

        CATALOGUES.reject { |resource| resource == enabled }.each do |resource|
          get catalogue_paths.fetch(resource).fetch(:index)
          assert_response :not_found
          get catalogue_paths.fetch(resource).fetch(:show)
          assert_response :not_found
        end
      end
    end
  end

  private

  def catalogue_paths
    {
      datasets: { index: datasets_path, show: dataset_path('one') },
      models: { index: models_path, show: model_path('mattergen') },
      workflows: { index: workflows_path, show: workflow_path('WF-AIIDA-QE-PW-BANDS') },
      repositories: { index: repositories_path, show: repository_path('quantum-espresso') }
    }
  end

  FEATURE_FLAGS = {
    datasets: :datasets,
    models: :models_catalogue,
    workflows: :workflows_catalogue,
    repositories: :repositories_catalogue
  }.freeze

  def with_enabled_catalogues(*enabled)
    enabled_flags = enabled.map { |key| FEATURE_FLAGS.fetch(key.to_sym, key.to_sym) }
    Flipper.stub(:enabled?, ->(feature, _actor = nil) { enabled_flags.include?(feature.to_sym) }) { yield }
  end
end
