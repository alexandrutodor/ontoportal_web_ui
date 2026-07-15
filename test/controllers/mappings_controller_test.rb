# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class MappingsAuthenticationRoutesTest < ActionDispatch::IntegrationTest
  test 'anonymous users are redirected from the new mapping form' do
    get '/mappings/new'

    assert_redirected_to '/'
  end

  test 'anonymous users are redirected from mapping upload' do
    post '/mappings/loader'

    assert_redirected_to '/'
  end

  test 'anonymous users are redirected from mapping create' do
    post '/mappings'

    assert_redirected_to '/'
  end

  test 'anonymous users are redirected from every mapping update verb' do
    post '/mappings/1'
    assert_redirected_to '/'

    patch '/mappings/1'
    assert_redirected_to '/'

    put '/mappings/1'
    assert_redirected_to '/'
  end

  test 'anonymous users are redirected from mapping destroy' do
    delete '/mappings/1'

    assert_redirected_to '/'
  end
end

class MappingsControllerAuthenticatedTest < ActionController::TestCase
  tests MappingsController

  ResponseStub = Struct.new(:errors, :created, keyword_init: true)

  setup do
    @request.session[:user] = Object.new
  end

  test 'authenticated users can upload mappings' do
    response = ResponseStub.new(errors: nil, created: [])
    call = nil

    LinkedData::Client::HTTP.stub(:post, ->(*args, **kwargs) {
      call = [args, kwargs]
      response
    }) do
      post :loader_process
    end

    assert_redirected_to '/mappings'
    assert_equal ['/mappings/load'], call.first
    assert_equal({ file: nil }, call.last)
  end
end
