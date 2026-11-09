# frozen_string_literal: true

# ONTO-T-J01: the ontology update path drops blank sample queries, so the client's single
# blank entry means "no sample queries" (the catalog path already rejects blank list values).
require 'minitest/autorun'
require 'active_support/all'
require 'action_controller'

module SubmissionUpdater; end
module TurboHelper; end
require_relative '../../app/controllers/concerns/ontology_updater'

class SampleQueriesParamsCheck < Minitest::Test
  class Host
    include OntologyUpdater
    attr_accessor :params
  end

  def ontology_params_for(ontology)
    host = Host.new
    host.params = ActionController::Parameters.new(ontology: ontology)
    host.ontology_params
  end

  def test_blank_entry_is_an_empty_list
    assert_equal [], ontology_params_for(sampleQueries: [''])['sampleQueries']
  end

  def test_queries_keep_order_and_blanks_are_dropped
    assert_equal ['SELECT 1', 'SELECT 2'], ontology_params_for(sampleQueries: ['SELECT 1', '', 'SELECT 2'])['sampleQueries']
  end

  def test_absent_sample_queries_stay_absent
    refute ontology_params_for(name: 'X').key?('sampleQueries')
  end
end
