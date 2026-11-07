# frozen_string_literal: true

# ONTO-T-J07: the server row layouts must match what form_auto_complete_controller.js reads.
# formatItem: single-ontology row[7] = definition; all-ontologies row[7] = ontology, row[9] = definition.
# onSelect: li.extra = row.slice(1), so hidden concept id = row[1], ontology id = row[3], full id = row[4].
require 'minitest/autorun'
require 'ostruct'
require 'cgi'
require 'active_support/all'

# Only build_json_search_row is under test; its parents and concerns are not needed.
class ApplicationController; def self.skip_before_action(*); end; def self.layout(*); end; end
module SearchAggregator; end
module SearchContent; end
module FederationHelper; end
require_relative '../../app/controllers/search_controller'

class MappingPickerRowContractCheck < Minitest::Test
  RESULT = OpenStruct.new(
    id: 'http://ex.org/C1', prefLabel: 'Gamma', obsolete?: false, synonym: ['g'],
    definition: ['Def one', 'two'], links: { 'ontology' => 'http://data.ex/ontologies/ONT1' }
  )

  def row(single, target: 'name')
    c = SearchController.allocate
    c.define_singleton_method(:params) { { target: target } }
    c.define_singleton_method(:search_concept_label) { |label, _q| label }
    c.send(:build_json_search_row, RESULT, 'gam', single)
  end

  def test_single_ontology_row
    r = row(true)
    assert_equal 8, r.length
    assert_equal ['Gamma', 'http://ex.org/C1', '', 'ONT1', 'http://ex.org/C1', 'Gamma', 'g'], r[0, 7]
    assert_equal 'Def one. two', CGI.unescape(r[7]), 'row[7] is the definition in single mode'
  end

  def test_all_ontologies_row
    r = row(false)
    assert_equal 10, r.length
    assert_equal 'ONT1', r[3], 'hidden ontology id (extra[2]) is the acronym'
    assert_equal 'ONT1', r[7], 'row[7] is the ontology shown by the all-ontologies formatter'
    assert_equal 'Def one. two', CGI.unescape(r[9]), 'row[9] is the definition in all-ontologies mode'
  end

  def test_hidden_identifiers_agree_between_modes
    s = row(true, target: 'uri')
    a = row(false, target: 'uri')
    assert_equal s[1..5], a[1..5], 'extra[0..4] read by onSelect are identical in both layouts'
  end
end
