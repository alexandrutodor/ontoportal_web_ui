require 'test_helper'
require 'minitest/mock'

class DatasetsControllerTest < ActionController::TestCase
  tests DatasetsController

  setup do
    @base_url = 'https://datasets.example.test/api'
    @original_url = ENV['DATASETS_API_URL']
    ENV['DATASETS_API_URL'] = @base_url
  end

  teardown do
    ENV['DATASETS_API_URL'] = @original_url
  end

  test 'feature off returns 404 without a provider request' do
    stub_request(:get, %r{datasets\.example\.test}).to_raise('must not call provider')
    Flipper.stub(:enabled?, false) { get :index }
    assert_response :not_found
    assert_not_requested :get, %r{datasets\.example\.test}
  end

  test 'enabled index renders normalized catalogue records' do
    stub_request(:get, %r{datasets\.example\.test/api/datasets\?})
      .to_return(status: 200, body: { datasets: [{ id: 'one', title: 'One', description: 'A dataset' }] }.to_json)
    Flipper.stub(:enabled?, ->(feature, _actor = nil) { feature.to_sym == :datasets }) { get :index }
    assert_response :success
    assert_includes response.body, 'One'
  end

  test 'invalid ids return 404 without a provider request' do
    Flipper.stub(:enabled?, ->(feature, _actor = nil) { feature.to_sym == :datasets }) do
      get :show, params: { id: '../secret' }
    end
    assert_response :not_found
    assert_not_requested :get, %r{datasets\.example\.test}
  end

  test 'enabled route reports missing provider configuration as 503' do
    ENV.delete('DATASETS_API_URL')
    Flipper.stub(:enabled?, ->(feature, _actor = nil) { feature.to_sym == :datasets }) do
      get :index
    end
    assert_response :service_unavailable
  end
end
