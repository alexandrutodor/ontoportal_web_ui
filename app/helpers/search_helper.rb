# frozen_string_literal: true

module SearchHelper
  def channel_label(channel)
    case channel.to_sym
    when :curie_exact
      'CURIE / IRI Exact'
    when :bm25
      'Lexical BM25'
    when :vector_similarity
      'Dense Vector'
    when :mapping_expansion
      'SSSOM Mapping'
    else
      channel.to_s.humanize
    end
  end

  def channel_badge_class(channel)
    case channel.to_sym
    when :curie_exact
      'badge badge-primary bg-primary text-white'
    when :bm25
      'badge badge-info bg-info text-white'
    when :vector_similarity
      'badge badge-success bg-success text-white'
    when :mapping_expansion
      'badge badge-warning bg-warning text-dark'
    else
      'badge badge-secondary bg-secondary text-white'
    end
  end

  def format_rrf_score(score)
    return '0.000' if score.nil? || score.to_f.zero?
    sprintf('%.4f', score)
  end
end
