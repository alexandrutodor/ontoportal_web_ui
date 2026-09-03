# frozen_string_literal: true

require 'test_helper'

class SearchControllerTest < ActionDispatch::IntegrationTest
  test 'should get search index' do
    get '/search'
    assert_response :success
  end

  test 'should get search index with hybrid toggle' do
    get '/search', params: { query: 'melanoma', hybrid: '1' }
    assert_response :success
    assert_select '#hybrid_search_results_container'
  end

  test 'should get hybrid search JSON endpoint' do
    get '/search/hybrid', params: { query: 'melanoma', k: '60' }, as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 'melanoma', data['query']
    assert_equal 60, data['k']
    assert data.key?('results')
    assert data.key?('total_results')
    assert data.key?('channel_counts')
  end

  test 'should get recommender pareto endpoint via JSON' do
    post '/recommender/pareto', params: { input: 'gene expression cancer', license_filter: 'permissive' }, as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal 'gene expression cancer', data['input']
    assert_equal 'permissive', data['license_filter']
    assert data.key?('frontier')
    assert data.key?('fronts')
    assert data.key?('total_evaluated')
  end

  test 'recommender create routes to pareto when algorithm=pareto is passed' do
    post '/recommender', params: { input: 'biomarker', algorithm: 'pareto' }, as: :json
    assert_response :success

    data = JSON.parse(response.body)
    assert data.key?('frontier')
    assert data.key?('total_evaluated')
  end
end
