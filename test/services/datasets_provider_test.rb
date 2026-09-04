# frozen_string_literal: true

require 'test_helper'

class DatasetsProviderTest < ActiveSupport::TestCase
  setup do
    @base_url = 'https://datasets.example.test/api'
  end

  test 'normalizes the small index contract and bounds the query in remote mode' do
    stub_request(:get, %r{datasets\.example\.test/api/datasets\?})
      .with(query: hash_including('q' => 'catalogue', 'page' => '2', 'per_page' => '20'))
      .to_return(status: 200, body: { datasets: [{ id: 'one', title: 'One', description: 'Description', publisher: 'Publisher' }], total: 1 }.to_json)

    result = DatasetsProvider.new(base_url: @base_url).index(query: 'catalogue', page: 2)

    assert_equal 1, result.records.length
    assert_equal 'one', result.records.first.id
    assert_equal 'One', result.records.first.title
  end

  test 'loads a detail record and rejects unsafe homepage URLs in remote mode' do
    stub_request(:get, 'https://datasets.example.test/api/datasets/one')
      .to_return(status: 200, body: { id: 'one', title: 'One', homepage: 'javascript:alert(1)' }.to_json)

    record = DatasetsProvider.new(base_url: @base_url).detail('one')

    assert_equal 'One', record.title
    assert_nil record.homepage
  end

  test 'invalid URI configuration raises service_unavailable' do
    error = assert_raises(DatasetsProvider::Error) { DatasetsProvider.new(base_url: 'not-a-valid-uri') }
    assert_equal :service_unavailable, error.status

    error = assert_raises(DatasetsProvider::Error) { DatasetsProvider.new(base_url: 'ftp://unsupported.test') }
    assert_equal :service_unavailable, error.status
  end

  test 'unconfigured base_url uses native catalogue backend' do
    provider = DatasetsProvider.new(base_url: nil)
    result = provider.index(query: '', page: 1)

    assert result.records.length > 0
    first_record = result.records.first
    assert first_record.id.present?
    assert first_record.title.present?

    detail = provider.detail(first_record.id)
    assert_equal first_record.title, detail.title

    search_result = provider.index(query: 'materials', page: 1)
    assert search_result.records.length > 0

    error = assert_raises(DatasetsProvider::Error) { provider.detail('non-existent-dataset-id') }
    assert_equal :not_found, error.status
  end

  test 'non-success and invalid JSON responses are safe errors' do
    stub_request(:get, 'https://datasets.example.test/api/datasets/one').to_return(status: 500, body: 'secret')
    error = assert_raises(DatasetsProvider::Error) { DatasetsProvider.new(base_url: @base_url).detail('one') }
    assert_equal :bad_gateway, error.status

    stub_request(:get, 'https://datasets.example.test/api/datasets/one').to_return(status: 404, body: 'secret')
    error = assert_raises(DatasetsProvider::Error) { DatasetsProvider.new(base_url: @base_url).detail('one') }
    assert_equal :not_found, error.status

    stub_request(:get, 'https://datasets.example.test/api/datasets/one').to_return(status: 200, body: '{')
    error = assert_raises(DatasetsProvider::Error) { DatasetsProvider.new(base_url: @base_url).detail('one') }
    assert_equal :bad_gateway, error.status

    stub_request(:get, 'https://datasets.example.test/api/datasets/one').to_return(status: 200, body: 'x' * (DatasetsProvider::MAX_RESPONSE_BYTES + 1))
    error = assert_raises(DatasetsProvider::Error) { DatasetsProvider.new(base_url: @base_url).detail('one') }
    assert_equal :bad_gateway, error.status

    stub_request(:get, 'https://datasets.example.test/api/datasets/one').to_timeout
    error = assert_raises(DatasetsProvider::Error) { DatasetsProvider.new(base_url: @base_url).detail('one') }
    assert_equal :service_unavailable, error.status

    stub_request(:get, 'https://datasets.example.test/api/datasets/one').to_raise(Errno::ECONNRESET)
    error = assert_raises(DatasetsProvider::Error) { DatasetsProvider.new(base_url: @base_url).detail('one') }
    assert_equal :service_unavailable, error.status
  end
end
