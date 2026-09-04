# frozen_string_literal: true

require 'test_helper'

class AssistantNativeBackendTest < ActiveSupport::TestCase
  test 'streams responses for concept queries with SPARQL generation' do
    chunks = []
    payload = {
      prompt: 'Write a SPARQL query for this concept',
      context: {
        'concept_label' => 'Iron Alloy',
        'concept_id' => 'http://example.org/materials/iron-alloy',
        'ontology_acronym' => 'MATONT',
        'ontology_name' => 'Materials Ontology'
      }
    }

    AssistantNativeBackend.new.stream(payload) do |chunk|
      chunks << chunk
    end

    full_output = chunks.join
    assert_includes full_output, 'SPARQL Query for `Iron Alloy`'
    assert_includes full_output, 'http://example.org/materials/iron-alloy'
    assert_includes full_output, 'PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>'
    assert chunks.last.end_with?("[DONE]\n\n")
  end

  test 'streams general responses when context is empty' do
    chunks = []
    AssistantNativeBackend.new.stream(prompt: 'Hello') do |chunk|
      chunks << chunk
    end

    full_output = chunks.join
    assert_includes full_output, 'OntoPortal Semantic Assistant'
    assert chunks.last.end_with?("[DONE]\n\n")
  end
end
