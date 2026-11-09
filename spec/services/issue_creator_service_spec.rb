# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'net/http'
require_relative '../../app/services/application_service'
require_relative '../../app/services/issue_creator_service'

RSpec.describe IssueCreatorService do
  let(:repo_query_definition) { double('GraphQL::Query::FindRepoQuery') }
  let(:mutation_definition) { double('GraphQL::Query::CreateIssueMutation') }
  let(:github_client) { double('GitHub::Client') }

  let(:configured_repo) { 'mock-owner/mock-repo' }
  let(:change_request_config) do
    {
      ontologies: {
        STY: { repository: configured_repo }
      }
    }
  end
  let(:rails_config) { double('Configuration', change_request: change_request_config) }

  let(:params) do
    {
      ont_acronym: 'STY',
      content: {
        title: 'test issue',
        body: 'lorem ipsum dolor sit amet'
      }
    }
  end

  let(:repo_id) { 'R_kgDOH12345' }
  let(:repo_lookup_data) do
    double('RepoLookupData', repository: double('Repository', id: repo_id))
  end
  let(:repo_lookup_response) do
    double('RepoLookupResponse', errors: double('Errors', any?: false), data: repo_lookup_data)
  end

  let(:issue_payload) do
    {
      'id' => 'ISSUE_kwDOH12345',
      'createdAt' => '2026-11-07T00:00:00Z',
      'number' => 42,
      'title' => 'test issue',
      'bodyText' => 'lorem ipsum dolor sit amet',
      'url' => 'https://github.com/mock-owner/mock-repo/issues/42',
      'repository' => {
        'nameWithOwner' => 'mock-owner/mock-repo'
      }
    }
  end
  let(:mutation_data) do
    double('MutationData', to_h: { 'createIssue' => { 'issue' => issue_payload } })
  end
  let(:mutation_response) do
    double('MutationResponse', errors: double('Errors', any?: false), data: mutation_data)
  end

  around(:each) do |example|
    config = WebMock::Config.instance
    original_allow_net_connect = config.allow_net_connect
    original_allow_localhost = config.allow_localhost
    original_allow = config.allow.is_a?(Array) ? config.allow.dup : config.allow
    original_net_http_connect_on_start = config.net_http_connect_on_start

    WebMock.disable_net_connect!
    begin
      example.run
    ensure
      WebMock.reset!
      if original_allow_net_connect
        WebMock.allow_net_connect!(net_http_connect_on_start: original_net_http_connect_on_start)
        config.allow_localhost = original_allow_localhost
        config.allow = original_allow
      else
        WebMock.disable_net_connect!(
          allow_localhost: original_allow_localhost,
          allow: original_allow,
          net_http_connect_on_start: original_net_http_connect_on_start
        )
      end
    end
  end

  before do
    stub_const('Rails', double('Rails', configuration: rails_config))
    stub_const('GitHub::Client', github_client)

    allow(github_client).to receive(:parse) do |query_string|
      if query_string.include?('repository(owner:')
        repo_query_definition
      elsif query_string.include?('createIssue(input:')
        mutation_definition
      else
        double('UnknownGraphQLDefinition')
      end
    end
  end

  describe 'network isolation' do
    it 'strictly intercepts outbound HTTP requests without opening network sockets' do
      expect {
        Net::HTTP.get(URI('https://api.github.com/graphql'))
      }.to raise_error(WebMock::NetConnectNotAllowedError)
    end
  end

  describe '#call' do
    it 'passes repository lookup variables and issue mutation variables, returning issue fields' do
      expect(github_client).to receive(:query).with(
        repo_query_definition,
        variables: { owner: 'mock-owner', name: 'mock-repo' }
      ).and_return(repo_lookup_response)

      expect(github_client).to receive(:query).with(
        mutation_definition,
        variables: {
          repositoryId: repo_id,
          title: 'test issue',
          body: 'lorem ipsum dolor sit amet'
        }
      ).and_return(mutation_response)

      issue = IssueCreatorService.call(params)

      expect(issue).to have_key('id')
      expect(issue['id']).to eq('ISSUE_kwDOH12345')
      expect(issue).to have_key('createdAt')
      expect(issue['createdAt']).to eq('2026-11-07T00:00:00Z')
      expect(issue['title']).to eq(params[:content][:title])
      expect(issue['bodyText']).to eq(params[:content][:body])
      expect(issue['number']).to eq(42)
      expect(issue['url']).to eq('https://github.com/mock-owner/mock-repo/issues/42')
    end

    context 'when repository lookup fails' do
      let(:lookup_errors) do
        double('LookupErrors', any?: true, :[] => ['Could not resolve to a Repository with the name mock-owner/mock-repo'])
      end
      let(:failed_repo_response) do
        double('FailedRepoResponse', errors: lookup_errors, data: nil)
      end

      it 'short-circuits and does not execute the mutation' do
        expect(github_client).to receive(:query).with(
          repo_query_definition,
          variables: { owner: 'mock-owner', name: 'mock-repo' }
        ).and_return(failed_repo_response)

        expect(github_client).not_to receive(:query).with(mutation_definition, any_args)

        expect {
          IssueCreatorService.call(params)
        }.to raise_error(
          IssueCreatorService::QueryError,
          'Could not resolve to a Repository with the name mock-owner/mock-repo'
        )
      end
    end

    context 'when issue mutation fails' do
      let(:mutation_errors) do
        double('MutationErrors', any?: true, :[] => ['Title cannot be blank, Body is invalid'])
      end
      let(:failed_mutation_response) do
        double('FailedMutationResponse', errors: mutation_errors, data: nil)
      end

      it 'raises QueryError with joined error details' do
        allow(github_client).to receive(:query).with(
          repo_query_definition,
          variables: { owner: 'mock-owner', name: 'mock-repo' }
        ).and_return(repo_lookup_response)

        allow(github_client).to receive(:query).with(
          mutation_definition,
          variables: {
            repositoryId: repo_id,
            title: 'test issue',
            body: 'lorem ipsum dolor sit amet'
          }
        ).and_return(failed_mutation_response)

        expect {
          IssueCreatorService.call(params)
        }.to raise_error(
          IssueCreatorService::QueryError,
          'Title cannot be blank, Body is invalid'
        )
      end
    end
  end
end
