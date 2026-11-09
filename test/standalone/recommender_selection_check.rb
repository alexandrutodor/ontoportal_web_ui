# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'ostruct'
require 'uri'
require 'cgi'

# In native container (onto-q02-proof:af254f34), gems are located in /usr/local/bundle/ruby/3.1.0
if Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems') && (ENV['GEM_PATH'].nil? || !ENV['GEM_PATH'].include?('/usr/local/bundle/ruby/3.1.0'))
  Gem.use_paths(nil, Gem.path + ['/usr/local/bundle/ruby/3.1.0'])
end

NATIVE_IMAGE_ENV = Dir.exist?('/usr/local/bundle/ruby/3.1.0/gems')

begin
  require 'rails'
  require 'action_controller'
  require 'action_view'
  require 'haml'
  require 'haml/plugin'
  require 'view_component'
  require 'view_component/version' rescue nil

  vc_version = defined?(ViewComponent::VERSION::STRING) ? ViewComponent::VERSION::STRING : (Gem.loaded_specs['view_component']&.version&.to_s || 'unknown')
  FRAMEWORK_MODE = "real Rails ActionController/ActionView #{ActionPack::VERSION::STRING} with ViewComponent #{vc_version} and Haml #{Haml::VERSION}"
rescue LoadError => e
  raise "Native container environment detected but failed to load Rails libraries: #{e}" if NATIVE_IMAGE_ENV

  module ActionController
    class Parameters < Hash
      def initialize(hash = {})
        super()
        merge!(hash)
      end
    end

    class Base
      attr_accessor :params

      def self.layout(*)
      end

      def view_context
        nil
      end
    end
  end

  FRAMEWORK_MODE = "host fallback (requires native container for full ViewComponent/Haml execution: #{e.message})"
end

# Load real production helper
require_relative '../../app/helpers/urls_helper'

class ApplicationController < ActionController::Base
  def determine_layout
    false
  end

  def t(key, **_opts)
    key
  end
end

module ApplicationHelper
  include UrlsHelper
end

module LinkedData
  module Client
    module HTTP
      def self.post(_uri, _params)
        []
      end
    end
  end
end

$REST_URL = 'https://data.stage.matportal.org'
$API_KEY = 'test-isolated-key'

require_relative '../../app/controllers/recommender_controller'

if defined?(ViewComponent::Base)
  module Display; end
  module Input; end

  require_relative '../../app/components/display/progress_bar_component'
  require_relative '../../app/components/input/radio_chip_component'
end

class RecommenderSelectionCheck < Minitest::Test
  def setup
    @controller = RecommenderController.new
    @view_context = ActionController::Base.new.view_context
  end

  # Helper to construct synthetic recommender DTOs matching backend schema
  def build_recommendation(score, acronym: 'ONTO', normalized_score: nil, annotations_count: 1)
    norm = normalized_score || score
    OpenStruct.new(
      evaluationScore: score,
      ontologies: [
        OpenStruct.new(acronym: acronym, id: "http://example.org/ontologies/#{acronym}")
      ],
      coverageResult: OpenStruct.new(
        normalizedScore: norm,
        annotations: Array.new(annotations_count) do |i|
          OpenStruct.new(
            text: "sample #{acronym} term #{i + 1}",
            annotatedClass: OpenStruct.new(
              links: { 'self' => "http://example.org/ontologies/#{acronym}/classes/term_#{i + 1}" }
            )
          )
        end
      ),
      acceptanceResult: OpenStruct.new(normalizedScore: norm),
      detailResult: OpenStruct.new(normalizedScore: norm),
      specializationResult: OpenStruct.new(normalizedScore: norm)
    )
  end

  # Helper to run RecommenderController#index with mocked HTTP.post
  def run_index(recommendations, params = { input: 'graphene conductivity sample' })
    controller = RecommenderController.new
    controller.params = ActionController::Parameters.new(params)
    LinkedData::Client::HTTP.stub(:post, recommendations) do
      controller.index
    end
    controller.instance_variable_get(:@results)
  end

  # Test 1: Framework mode check
  def test_framework_mode_and_environment
    skip "Host fallback environment: #{FRAMEWORK_MODE}" if FRAMEWORK_MODE.start_with?('host fallback')

    assert_includes FRAMEWORK_MODE, 'real Rails ActionController/ActionView'
    assert_includes FRAMEWORK_MODE, 'ViewComponent'
    assert_includes FRAMEWORK_MODE, 'Haml'
  end

  # Test 2: Scores spanning one/two/three digit displays (e.g. 9%, 10%, 100%) in varied orders
  # Lexical comparison would incorrectly order "9.0" > "100.0" and "9.0" > "10.0".
  # Numeric comparison correctly identifies 100.0% (1.0) as the winner regardless of order.
  def test_one_two_three_digit_displays_and_varied_order
    scenarios = [
      # Ascending order: [9%, 10%, 100%] -> index 2 wins
      {
        inputs: [0.09, 0.10, 1.00],
        expected_winner_idx: 2,
        expected_scores: ['9.0', '10.0', '100.0']
      },
      # Descending order: [100%, 10%, 9%] -> index 0 wins
      {
        inputs: [1.00, 0.10, 0.09],
        expected_winner_idx: 0,
        expected_scores: ['100.0', '10.0', '9.0']
      },
      # Mixed order: [10%, 100%, 9%] -> index 1 wins
      {
        inputs: [0.10, 1.00, 0.09],
        expected_winner_idx: 1,
        expected_scores: ['10.0', '100.0', '9.0']
      },
      # Mixed order: [9%, 100%, 10%] -> index 1 wins
      {
        inputs: [0.09, 1.00, 0.10],
        expected_winner_idx: 1,
        expected_scores: ['9.0', '100.0', '10.0']
      }
    ]

    scenarios.each_with_index do |scenario, s_idx|
      recs = scenario[:inputs].each_with_index.map do |score, i|
        build_recommendation(score, acronym: "ONTO_#{s_idx}_#{i}")
      end

      results = run_index(recs)

      assert_equal 3, results.length
      assert_equal 1, results.count { |r| r[:highlighted] },
                   "Scenario #{s_idx}: exactly one result must be highlighted"

      winner_idx = scenario[:expected_winner_idx]
      assert results[winner_idx][:highlighted],
             "Scenario #{s_idx}: index #{winner_idx} (score #{scenario[:inputs][winner_idx]}) must be highlighted"

      scores = results.map { |r| r[:final_score] }
      assert_equal scenario[:expected_scores], scores
    end
  end

  # Test 3: Later higher values do not accumulate earlier highlights
  # The original defect repeatedly set max_by during loop iterations without resetting,
  # leaving all monotonically increasing rows marked highlighted.
  def test_later_higher_values_do_not_accumulate_earlier_highlights
    recs = [
      build_recommendation(0.20, acronym: 'FIRST_LOW'),
      build_recommendation(0.40, acronym: 'SECOND_MID'),
      build_recommendation(0.80, acronym: 'THIRD_HIGH')
    ]

    results = run_index(recs)

    assert_equal 3, results.length
    assert_equal 1, results.count { |r| r[:highlighted] }, 'Must highlight exactly one result, not accumulate'
    refute results[0][:highlighted], 'First lower result must not remain highlighted'
    refute results[1][:highlighted], 'Second lower result must not remain highlighted'
    assert results[2][:highlighted], 'Third highest result must be highlighted'
  end

  # Test 4: Earlier higher values maintain single winner when subsequent rows are lower
  def test_earlier_higher_values_maintain_single_winner
    recs = [
      build_recommendation(0.85, acronym: 'HIGH_EARLY'),
      build_recommendation(0.30, acronym: 'LOW_LATE'),
      build_recommendation(0.50, acronym: 'MID_LATE')
    ]

    results = run_index(recs)

    assert_equal 3, results.length
    assert_equal 1, results.count { |r| r[:highlighted] }
    assert results[0][:highlighted], 'First highest result must be highlighted'
    refute results[1][:highlighted]
    refute results[2][:highlighted]
  end

  # Test 5: Exact numeric ties preserve stable first backend order
  def test_exact_numeric_ties_preserve_first_backend_order
    # Head tie: index 0 and 1 have identical score 0.85
    recs_head = [
      build_recommendation(0.85, acronym: 'TIE_A'),
      build_recommendation(0.85, acronym: 'TIE_B'),
      build_recommendation(0.60, acronym: 'LOWER_C')
    ]

    results_head = run_index(recs_head)
    assert_equal 3, results_head.length
    assert_equal 1, results_head.count { |r| r[:highlighted] }
    assert results_head[0][:highlighted], 'First occurrence of tied score must win'
    refute results_head[1][:highlighted], 'Second occurrence of tied score must not win'
    refute results_head[2][:highlighted]

    # Non-head tie: index 1 and 2 have identical score 0.90
    recs_tail = [
      build_recommendation(0.50, acronym: 'LOW_A'),
      build_recommendation(0.90, acronym: 'TIE_B'),
      build_recommendation(0.90, acronym: 'TIE_C')
    ]

    results_tail = run_index(recs_tail)
    assert_equal 3, results_tail.length
    assert_equal 1, results_tail.count { |r| r[:highlighted] }
    refute results_tail[0][:highlighted]
    assert results_tail[1][:highlighted], 'First occurrence of tied maximum must win'
    refute results_tail[2][:highlighted], 'Second occurrence of tied maximum must not win'
  end

  # Test 6: Close unrounded values that share formatted display (e.g. 0.90501 vs 0.90504)
  # Both format to "90.5". Comparing formatted rounded strings would yield a false tie,
  # but true unrounded numeric comparison must select the actual maximum.
  def test_close_unrounded_values_sharing_display
    # Case A: Later row has higher unrounded value (0.90501 vs 0.90504)
    recs_later_wins = [
      build_recommendation(0.90501, acronym: 'SLIGHTLY_LOWER'),
      build_recommendation(0.90504, acronym: 'SLIGHTLY_HIGHER')
    ]

    results_a = run_index(recs_later_wins)
    assert_equal 2, results_a.length
    assert_equal '90.5', results_a[0][:final_score], 'Display format must be rounded 90.5'
    assert_equal '90.5', results_a[1][:final_score], 'Display format must be rounded 90.5'
    assert_equal 1, results_a.count { |r| r[:highlighted] }
    refute results_a[0][:highlighted], 'Lower unrounded value must not be highlighted'
    assert results_a[1][:highlighted], 'Higher unrounded value must win even though display strings match'

    # Case B: Earlier row has higher unrounded value (0.90504 vs 0.90501)
    recs_earlier_wins = [
      build_recommendation(0.90504, acronym: 'SLIGHTLY_HIGHER'),
      build_recommendation(0.90501, acronym: 'SLIGHTLY_LOWER')
    ]

    results_b = run_index(recs_earlier_wins)
    assert_equal 2, results_b.length
    assert_equal '90.5', results_b[0][:final_score]
    assert_equal '90.5', results_b[1][:final_score]
    assert_equal 1, results_b.count { |r| r[:highlighted] }
    assert results_b[0][:highlighted], 'Earlier higher unrounded value must be highlighted'
    refute results_b[1][:highlighted]
  end

  # Test 7: Singleton recommendation
  def test_singleton_recommendation
    recs = [build_recommendation(0.654, acronym: 'SINGLE')]
    results = run_index(recs)

    assert_equal 1, results.length
    assert_equal 1, results.count { |r| r[:highlighted] }
    assert results[0][:highlighted], 'Single recommendation must be highlighted'
    assert_equal '65.4', results[0][:final_score]
  end

  # Test 8: Empty recommendations
  def test_empty_recommendations
    results = run_index([])

    assert_empty results
    assert_equal 0, results.count { |r| r[:highlighted] }
  end

  # Test 9: Score formatting contract and preservation of all remaining fields
  # - All 5 percentage scores must remain formatted Strings with one decimal place.
  # - Display::ProgressBarComponent concatenates @progress + '%' and would raise TypeError with Floats.
  # - Ontologies and annotations structures must be preserved.
  def test_score_formatting_and_field_integrity
    rec = build_recommendation(0.8765, acronym: 'TEST_ONTO', annotations_count: 2)
    results = run_index([rec])

    assert_equal 1, results.length
    row = results.first

    expected_keys = %i[
      ontologies
      final_score
      coverage_score
      acceptance_score
      details_score
      specialization_score
      annotations
      highlighted
    ]
    assert_equal expected_keys.sort, row.keys.sort, 'Row keys must strictly match existing contract'

    # All percentage score fields must be Strings, not Floats
    score_fields = %i[final_score coverage_score acceptance_score details_score specialization_score]
    score_fields.each do |field|
      val = row[field]
      assert_kind_of String, val, "Field #{field} must be a String, not Float/Numeric"
      assert_match(/\A\d+\.\d\z/, val, "Field #{field} ('#{val}') must match single decimal format")
    end

    # Specific formatted values (0.8765 * 100 = 87.65 -> IEEE-754 rounds to 87.6)
    assert_equal '87.6', row[:final_score]
    assert_equal '87.6', row[:coverage_score]
    assert_equal '87.6', row[:acceptance_score]
    assert_equal '87.6', row[:details_score]
    assert_equal '87.6', row[:specialization_score]

    # Ontologies array structure
    assert_equal 1, row[:ontologies].length
    assert_equal 'TEST_ONTO', row[:ontologies].first[:acronym]
    assert_equal 'http://example.org/ontologies/TEST_ONTO', row[:ontologies].first[:link]

    # Annotations array structure with url_to_endpoint applied
    assert_equal 2, row[:annotations].length
    assert_equal 'sample TEST_ONTO term 1', row[:annotations].first[:text]
    assert_equal 'ontologies/TEST_ONTO/classes/term_1', row[:annotations].first[:link]

    assert_equal true, row[:highlighted]
  end

  # Test 10: Render actual existing ProgressBarComponent and RadioChipComponent under real ViewComponent/Haml
  # Confirms that view layer consumes formatted String percentage without TypeError and
  # renders exactly one checked radio input across all results.
  def test_render_actual_components_viewcomponent_haml
    skip 'ViewComponent rendering requires native container environment' unless defined?(ViewComponent::Base)
    recs = [
      build_recommendation(0.90501, acronym: 'ONTO_A', annotations_count: 2),
      build_recommendation(0.90504, acronym: 'ONTO_B', annotations_count: 4),
      build_recommendation(0.45000, acronym: 'ONTO_C', annotations_count: 1)
    ]

    results = run_index(recs)
    assert_equal 3, results.length

    rendered_bars = []
    rendered_radios = []

    results.each_with_index do |result, idx|
      # 1. Render ProgressBarComponent for final_score
      progress_component = Display::ProgressBarComponent.new(progress: result[:final_score])
      bar_html = progress_component.render_in(@view_context)
      rendered_bars << bar_html

      # Assert progress bar text contains String percentage concatenation
      assert_includes bar_html, "class=\"progress-bar-component\""
      assert_includes bar_html, "<div class=\"progress-bar-component-text\">#{result[:final_score]}%</div>"
      assert_includes bar_html, "style=\"width: #{result[:final_score]}%;\""

      # 2. Render RadioChipComponent for highlighted recommendation
      radio_component = Input::RadioChipComponent.new(
        label: "#{result[:annotations].length} annotations",
        name: 'highlighted_recommendation',
        value: result[:annotations],
        checked: result[:highlighted]
      )
      radio_html = radio_component.render_in(@view_context)
      rendered_radios << radio_html

      # Assert radio chip contains expected label and attributes
      assert_includes radio_html, "data-controller='radio-chip'"
      assert_includes radio_html, "#{result[:annotations].length} annotations"

      if result[:highlighted]
        assert_includes radio_html, 'checked',
                        "Winning row #{idx} (#{result[:ontologies].first[:acronym]}) must render with checked attribute"
      else
        refute_includes radio_html, 'checked',
                        "Non-winning row #{idx} (#{result[:ontologies].first[:acronym]}) must not render with checked attribute"
      end
    end

    # Confirm exactly ONE radio across all rows rendered with 'checked'
    checked_count = rendered_radios.count { |html| html.include?('checked') }
    assert_equal 1, checked_count, 'Exactly one rendered RadioChipComponent must have the checked attribute'

    # Empty result test for rendering
    empty_results = run_index([])
    empty_radios = empty_results.map do |r|
      Input::RadioChipComponent.new(
        label: '0 annotations',
        name: 'highlighted_recommendation',
        value: [],
        checked: r[:highlighted]
      ).render_in(@view_context)
    end
    assert_equal 0, empty_radios.count { |html| html.include?('checked') }
  end
end
